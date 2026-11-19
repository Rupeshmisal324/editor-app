package com.intoactive.app.mediaeditor

import android.app.Activity
import android.app.Dialog
import android.graphics.Outline
import android.graphics.drawable.GradientDrawable
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView

/**
 * Rich music-selection sheet for the native video editor's Android side —
 * mirrors iOS's MusicPickerViewController and the RN AddPosts screen's
 * music flow: live trending/search via MusicApi, a real RecyclerView list
 * with per-row artwork + play/pause preview, tap-a-row to select. Replaces
 * showMusicPicker()'s old plain AlertDialog list.
 */
class MusicPickerDialog(
  activity: Activity,
  private val onDismiss: (() -> Unit)? = null,
  private val onSelect: (MediaEditorActivity.MusicTrack) -> Unit,
) : Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen) {

  private val density = context.resources.displayMetrics.density
  private fun dp(v: Float) = (v * density).toInt()

  private lateinit var recyclerView: RecyclerView
  private lateinit var loadingLabel: TextView
  private lateinit var emptyLabel: TextView
  private val adapter = MusicAdapter()

  private var tracks: List<MediaEditorActivity.MusicTrack> = emptyList()
  private var previewPlayer: MediaPlayer? = null
  private var currentlyPlayingId: String? = null
  private val searchHandler = Handler(Looper.getMainLooper())
  private var pendingSearch: Runnable? = null
  /** The exact request `emptyLabel`'s tap-to-retry should repeat — nil
   *  once a request succeeds (even with zero results, that's a real
   *  "nothing found", not a failure to retry). */
  private var lastFailedLoad: (() -> Unit)? = null
  /** Trimmed search text; a late trending response must not overwrite
   *  results the user has since searched for. */
  private var currentQuery = ""

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    val root = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      setBackgroundColor(EditorDesignTokens.Colors.chromeBackground)
    }

    val closeButton = TextView(context).apply {
      text = "Cancel"
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      setOnClickListener { dismiss() }
    }
    root.addView(closeButton, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
      leftMargin = dp(16f); topMargin = dp(40f)
    })

    val searchBar = EditText(context).apply {
      hint = "Search songs"
      setHintTextColor(EditorDesignTokens.Colors.textSecondary)
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      background = GradientDrawable().apply {
        setColor(EditorDesignTokens.Colors.elevatedSurface)
        cornerRadius = dp(20f).toFloat()
      }
      setPadding(dp(16f), dp(10f), dp(16f), dp(10f))
      addTextChangedListener(object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(s: Editable?) { onSearchTextChanged(s?.toString().orEmpty()) }
      })
    }
    root.addView(searchBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
      leftMargin = dp(12f); rightMargin = dp(12f); topMargin = dp(12f); bottomMargin = dp(8f)
    })

    val listContainer = FrameLayout(context)
    recyclerView = RecyclerView(context).apply {
      layoutManager = LinearLayoutManager(context)
      adapter = this@MusicPickerDialog.adapter
    }
    listContainer.addView(recyclerView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

    // Plain "Loading…" text, vertically centered — per the user's explicit
    // "remove these activity indicator from these screen and just keep
    // these loading ... text into vertical center" follow-up, replacing
    // the spinner+caption pair entirely.
    loadingLabel = TextView(context).apply {
      text = "Loading…"
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = 14f
      visibility = View.GONE
    }
    listContainer.addView(
      loadingLabel,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER),
    )

    // Tappable — per the user's "many time API not get called and get
    // more much time" report, a genuine network failure now surfaces a
    // real "couldn't load" message the user can act on instead of an
    // unexplained empty screen (or, before MusicApi's timeout fix, an
    // effectively endless spinner).
    emptyLabel = TextView(context).apply {
      text = "No songs found"
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      gravity = Gravity.CENTER
      visibility = View.GONE
      setOnClickListener { lastFailedLoad?.invoke() }
    }
    listContainer.addView(
      emptyLabel,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL).apply {
        topMargin = dp(40f); leftMargin = dp(32f); rightMargin = dp(32f)
      },
    )

    root.addView(listContainer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

    setContentView(root)
    setOnDismissListener {
      pausePreview()
      onDismiss?.invoke()
    }
    loadTrending()
  }

  private fun setLoading(loading: Boolean) {
    // With songs already on screen, the list just fades while the new
    // ones load ("Loading…" drawn over the rows was unreadable).
    val hasList = tracks.isNotEmpty()
    loadingLabel.visibility = if (loading && !hasList) View.VISIBLE else View.GONE
    recyclerView.alpha = if (loading && hasList) 0.45f else 1f
    emptyLabel.visibility = if (!loading && tracks.isEmpty()) View.VISIBLE else View.GONE
    emptyLabel.text = if (lastFailedLoad != null) "Couldn't load songs — tap to retry" else "No songs found"
  }

  /** Shared success/failure handling for both trending and search — sets
   *  `tracks`/refreshes the list on success, or shows the tappable
   *  "couldn't load" state (with `retry` wired to repeat the SAME
   *  request) on failure. */
  private fun handle(result: Result<List<MediaEditorActivity.MusicTrack>>, retry: () -> Unit) {
    result.onSuccess {
      lastFailedLoad = null
      tracks = it
      setLoading(false)
      adapter.notifyDataSetChanged()
    }.onFailure {
      lastFailedLoad = retry
      tracks = emptyList()
      setLoading(false)
      adapter.notifyDataSetChanged()
    }
  }

  /** Called every time the sheet opens (and when search is cleared): the
   *  last good list shows instantly, and a fresh request always runs. */
  private fun loadTrending() {
    val cached = MusicApi.cachedTrending.orEmpty()
    if (cached.isEmpty()) setLoading(true) else handle(Result.success(cached), retry = {})
    MusicApi.fetchTrendingWithFallback { result ->
      if (currentQuery.isNotEmpty()) return@fetchTrendingWithFallback
      // Keep showing the cached list rather than replacing it with an
      // error or an empty result.
      if (cached.isNotEmpty() && result.getOrNull().isNullOrEmpty()) return@fetchTrendingWithFallback
      handle(result, retry = ::loadTrending)
    }
  }

  private fun onSearchTextChanged(text: String) {
    pendingSearch?.let { searchHandler.removeCallbacks(it) }
    val trimmed = text.trim()
    currentQuery = trimmed
    if (trimmed.isEmpty()) {
      loadTrending()
      return
    }
    setLoading(true)
    val runnable = Runnable {
      MusicApi.search(trimmed) { result ->
        if (currentQuery == trimmed) handle(result, retry = { onSearchTextChanged(text) })
      }
    }
    pendingSearch = runnable
    // Short pause after typing (results are cached per term, and a newer
    // search cancels the one in flight, so this can be quick).
    searchHandler.postDelayed(runnable, 300)
  }

  private fun pausePreview() {
    previewPlayer?.release()
    previewPlayer = null
    val previous = currentlyPlayingId ?: return
    currentlyPlayingId = null
    adapter.notifyItemChangedForId(previous)
  }

  private fun togglePlayPause(track: MediaEditorActivity.MusicTrack) {
    if (currentlyPlayingId == track.id) {
      pausePreview()
      return
    }
    val previousId = currentlyPlayingId
    previewPlayer?.release()
    currentlyPlayingId = track.id
    previousId?.let { adapter.notifyItemChangedForId(it) }
    adapter.notifyItemChangedForId(track.id)
    previewPlayer = MediaPlayer().apply {
      runCatching {
        setDataSource(track.audioUrl)
        setOnPreparedListener { it.start() }
        setOnCompletionListener {
          currentlyPlayingId = null
          adapter.notifyItemChangedForId(track.id)
        }
        prepareAsync()
      }
    }
  }

  private inner class MusicAdapter : RecyclerView.Adapter<MusicAdapter.ViewHolder>() {
    fun notifyItemChangedForId(id: String) {
      val index = tracks.indexOfFirst { it.id == id }
      if (index >= 0) notifyItemChanged(index)
    }

    inner class ViewHolder(val row: MusicPickerRowView) : RecyclerView.ViewHolder(row)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
      val row = MusicPickerRowView(parent.context)
      row.layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, dp(64f))
      return ViewHolder(row)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
      val track = tracks[position]
      holder.row.bind(track, isPlaying = currentlyPlayingId == track.id) { togglePlayPause(track) }
      holder.row.setOnClickListener {
        pausePreview()
        onSelect(track)
        dismiss()
      }
    }

    override fun getItemCount() = tracks.size
  }
}

/** One row: artwork + title/artist·duration + a play/pause preview icon. */
private class MusicPickerRowView(context: android.content.Context) : LinearLayout(context) {
  private val density = context.resources.displayMetrics.density
  private fun dp(v: Float) = (v * density).toInt()

  private val artwork = ImageView(context)
  private val titleLabel = TextView(context)
  private val subtitleLabel = TextView(context)
  private val playPauseIcon = EditorIconView(context, EditorIcon.PLAY)
  private var onPlayPauseTapped: (() -> Unit)? = null

  init {
    orientation = HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    setPadding(dp(16f), 0, dp(16f), 0)
    isClickable = true

    artwork.scaleType = ImageView.ScaleType.CENTER_CROP
    artwork.setBackgroundColor(EditorDesignTokens.Colors.elevatedSurface)
    artwork.clipToOutline = true
    artwork.outlineProvider = object : ViewOutlineProvider() {
      override fun getOutline(view: View, outline: Outline) {
        outline.setRoundRect(0, 0, view.width, view.height, dp(6f).toFloat())
      }
    }
    addView(artwork, LayoutParams(dp(44f), dp(44f)))

    titleLabel.setTextColor(EditorDesignTokens.Colors.textPrimary)
    titleLabel.textSize = 15f
    titleLabel.maxLines = 1
    titleLabel.ellipsize = android.text.TextUtils.TruncateAt.END
    subtitleLabel.setTextColor(EditorDesignTokens.Colors.textSecondary)
    subtitleLabel.textSize = 12f
    subtitleLabel.maxLines = 1
    subtitleLabel.ellipsize = android.text.TextUtils.TruncateAt.END

    val textStack = LinearLayout(context).apply {
      orientation = VERTICAL
      addView(titleLabel, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
      addView(subtitleLabel, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = dp(2f) })
    }
    addView(textStack, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply { leftMargin = dp(12f); rightMargin = dp(8f) })

    playPauseIcon.iconTint = EditorDesignTokens.Colors.accent
    playPauseIcon.setOnClickListener { onPlayPauseTapped?.invoke() }
    addView(playPauseIcon, LayoutParams(dp(32f), dp(32f)))
  }

  fun bind(track: MediaEditorActivity.MusicTrack, isPlaying: Boolean, onPlayPauseTapped: () -> Unit) {
    this.onPlayPauseTapped = onPlayPauseTapped
    RemoteImageLoader.load(track.albumArt, artwork)
    titleLabel.text = track.title
    subtitleLabel.text = if (track.durationMs > 0) {
      val totalSeconds = track.durationMs / 1000
      "${track.artist} · ${totalSeconds / 60}:${String.format("%02d", totalSeconds % 60)}"
    } else {
      track.artist
    }
    playPauseIcon.icon = if (isPlaying) EditorIcon.PAUSE else EditorIcon.PLAY
  }
}
