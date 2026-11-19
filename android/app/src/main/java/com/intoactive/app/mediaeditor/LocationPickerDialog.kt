package com.intoactive.app.mediaeditor

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.Intent
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.Editable
import android.text.TextUtils
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView

/**
 * Story rail's Location picker — nearby places (current position) plus
 * search, via PlacesApi. Same full-screen dark sheet as MusicPickerDialog.
 * The Activity owns permission + position lookup (`requestLocation`),
 * since a Dialog can't receive permission results itself.
 */
class LocationPickerDialog(
  private val activity: Activity,
  private val apiKey: String,
  private val requestLocation: ((LocationFix) -> Unit) -> Unit,
  private val onDismiss: (() -> Unit)? = null,
  private val onSelect: (PlacesApi.Place) -> Unit,
) : Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen) {

  sealed class LocationFix {
    data class Found(val latitude: Double, val longitude: Double) : LocationFix()
    object Denied : LocationFix()
    object Unavailable : LocationFix()
  }

  private val density = context.resources.displayMetrics.density
  private fun dp(v: Float) = (v * density).toInt()

  private lateinit var headerLabel: TextView
  private lateinit var loadingView: LocationSearchingView
  private lateinit var messageLabel: TextView
  private lateinit var settingsButton: TextView
  private val adapter = PlaceAdapter()

  private var places: List<PlacesApi.Place> = emptyList()
  /** Which settings the button opens: the app's permission (denied) or
   *  the phone's location switch (off). */
  private var settingsFor: LocationFix = LocationFix.Denied
  /** Null until the position lookup finishes. */
  private var locationFix: LocationFix? = null
  // Not `isShowing`: that only turns true AFTER onCreate returns, so a
  // location answer delivered synchronously from onCreate (location
  // services off, or a fresh last-known fix) was dropped and the sheet sat
  // on "Loading…" forever.
  private var isDismissed = false
  private var nearbyPlaces: List<PlacesApi.Place>? = null
  private val searchHandler = Handler(Looper.getMainLooper())
  private var pendingSearch: Runnable? = null
  /** Trimmed search text; a late response for an older query (or a late
   *  nearby response while searching) must not overwrite the list. */
  private var currentQuery = ""
  /** True while an autocomplete pick's coordinates are being fetched —
   *  further row taps are ignored until it finishes. */
  private var isResolvingPlace = false

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
      hint = "Search locations"
      isSingleLine = true
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

    headerLabel = TextView(context).apply {
      text = "Nearby"
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = 13f
      visibility = View.GONE
    }
    root.addView(headerLabel, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
      leftMargin = dp(16f); topMargin = dp(4f); bottomMargin = dp(4f)
    })

    val listContainer = FrameLayout(context)
    val recyclerView = RecyclerView(context).apply {
      layoutManager = LinearLayoutManager(context)
      adapter = this@LocationPickerDialog.adapter
    }
    listContainer.addView(recyclerView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

    // Animated pin + radar rings with what's being looked up (was a plain
    // "Loading…" line). Card background, so it also reads over the list
    // while a picked place's coordinates resolve.
    loadingView = LocationSearchingView(context)
    listContainer.addView(
      loadingView,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL).apply {
        topMargin = dp(48f)
      },
    )

    val messageStack = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
    }
    messageLabel = TextView(context).apply {
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      gravity = Gravity.CENTER
      visibility = View.GONE
    }
    messageStack.addView(messageLabel, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    settingsButton = TextView(context).apply {
      text = "Open Settings"
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      background = GradientDrawable().apply {
        setColor(EditorDesignTokens.Colors.elevatedSurface)
        cornerRadius = dp(18f).toFloat()
      }
      setPadding(dp(18f), dp(8f), dp(18f), dp(8f))
      visibility = View.GONE
      setOnClickListener {
        val intent = if (settingsFor == LocationFix.Unavailable) {
          Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
        } else {
          Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null))
        }
        runCatching { activity.startActivity(intent) }
      }
    }
    messageStack.addView(settingsButton, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
      topMargin = dp(14f)
    })
    listContainer.addView(
      messageStack,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL).apply {
        topMargin = dp(40f); leftMargin = dp(32f); rightMargin = dp(32f)
      },
    )

    root.addView(listContainer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

    setContentView(root)
    setOnDismissListener {
      isDismissed = true
      pendingSearch?.let { searchHandler.removeCallbacks(it) }
      onDismiss?.invoke()
    }

    if (!hasPlacesKey && !GeocoderPlaces.isAvailable) {
      showMessage("Location search unavailable")
      return
    }
    showLoading()
    requestLocation { fix ->
      if (isDismissed) return@requestLocation
      locationFix = fix
      if (currentQuery.length < MIN_QUERY_LENGTH) showNearby()
    }
  }

  private fun showLoading(message: String = NEARBY_MESSAGE) {
    places = emptyList()
    adapter.notifyDataSetChanged()
    headerLabel.visibility = View.GONE
    messageLabel.visibility = View.GONE
    settingsButton.visibility = View.GONE
    loadingView.start(message)
  }

  private fun showMessage(message: String, withSettingsButton: Boolean = false) {
    places = emptyList()
    adapter.notifyDataSetChanged()
    headerLabel.visibility = View.GONE
    loadingView.stop()
    messageLabel.text = message
    messageLabel.visibility = View.VISIBLE
    settingsButton.visibility = if (withSettingsButton) View.VISIBLE else View.GONE
  }

  private fun showPlaces(list: List<PlacesApi.Place>, header: String?, emptyMessage: String) {
    if (list.isEmpty()) return showMessage(emptyMessage)
    places = list
    adapter.notifyDataSetChanged()
    loadingView.stop()
    messageLabel.visibility = View.GONE
    settingsButton.visibility = View.GONE
    headerLabel.text = header.orEmpty()
    headerLabel.visibility = if (header != null) View.VISIBLE else View.GONE
  }

  /** Location off / not allowed: popular places in the user's country, so
   *  the sheet isn't empty (the header asks to turn location on). */
  private var suggestedPlaces: List<PlacesApi.Place>? = null

  private fun showSuggestions(fix: LocationFix) {
    val header = "Popular places · Turn on location for nearby  ›"
    suggestedPlaces?.let { return showSuggestionList(it, header, fix) }
    if (!hasPlacesKey) {
      // The keyless geocoder can't list popular places: ask for location
      // (search above still works).
      showMessage(
        if (fix == LocationFix.Denied) "Allow location to see places near you — or search above"
        else "Turn on your phone's location to see places near you — or search above",
        withSettingsButton = true,
      )
      settingsFor = fix
      settingsButton.text = if (fix == LocationFix.Denied) "Open Settings" else "Turn on location"
      return
    }
    showLoading("Finding popular places…")
    val country = java.util.Locale("", java.util.Locale.getDefault().country.ifEmpty { "IN" }).getDisplayCountry(java.util.Locale.ENGLISH)
    searchPlaces("popular places in $country", null, null) { result ->
      if (isDismissed || currentQuery.length >= MIN_QUERY_LENGTH || locationFix is LocationFix.Found) return@searchPlaces
      val list = result.getOrNull().orEmpty()
      if (list.isEmpty()) {
        if (fix == LocationFix.Denied) showMessage("Turn on location access to see nearby places", withSettingsButton = true)
        else showMessage("Couldn't get your location — turn on your location or search for a place instead")
        return@searchPlaces
      }
      suggestedPlaces = list
      showSuggestionList(list, header, fix)
    }
  }

  private fun showSuggestionList(list: List<PlacesApi.Place>, header: String, fix: LocationFix) {
    showPlaces(list, header, "No places found")
    // The header opens the right settings: app permission, or the phone's
    // location switch.
    headerLabel.setOnClickListener {
      val intent = if (fix == LocationFix.Denied) {
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null))
      } else {
        Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
      }
      runCatching { activity.startActivity(intent) }
    }
  }

  /** Back from Settings with location now allowed / on: load nearby. */
  override fun onWindowFocusChanged(hasFocus: Boolean) {
    super.onWindowFocusChanged(hasFocus)
    val fix = locationFix
    if (!hasFocus || isDismissed || (fix != LocationFix.Denied && fix != LocationFix.Unavailable)) return
    val granted = listOf(android.Manifest.permission.ACCESS_FINE_LOCATION, android.Manifest.permission.ACCESS_COARSE_LOCATION)
      .any { context.checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED }
    val manager = context.getSystemService(Context.LOCATION_SERVICE) as? android.location.LocationManager
    val enabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager?.isLocationEnabled == true else true
    if (!granted || !enabled) return
    locationFix = null
    requestLocation { newFix ->
      if (isDismissed) return@requestLocation
      locationFix = newFix
      if (currentQuery.length < MIN_QUERY_LENGTH) showNearby()
    }
  }

  /** The no-search state: nearby list, or suggestions when there's no
   *  location to search around. */
  private fun showNearby() {
    headerLabel.setOnClickListener(null)
    when (val fix = locationFix) {
      null -> showLoading()
      LocationFix.Denied, LocationFix.Unavailable -> showSuggestions(fix)
      is LocationFix.Found -> {
        nearbyPlaces?.let { return showPlaces(it, "Nearby", "No places found nearby") }
        showLoading()
        nearbyPlacesAround(fix.latitude, fix.longitude) { result ->
          if (isDismissed) return@nearbyPlacesAround
          result.onSuccess { nearbyPlaces = it }
          if (currentQuery.length >= MIN_QUERY_LENGTH) return@nearbyPlacesAround
          result.onSuccess { showPlaces(it, "Nearby", "No places found nearby") }
            .onFailure { showMessage("Couldn't load nearby places — search for a place instead") }
        }
      }
    }
  }

  /** Google Places with a key; otherwise Android's own (keyless) geocoder. */
  private val hasPlacesKey get() = apiKey.isNotBlank()

  private fun searchPlaces(query: String, latitude: Double?, longitude: Double?, callback: (Result<List<PlacesApi.Place>>) -> Unit) {
    if (hasPlacesKey) PlacesApi.search(apiKey, query, latitude, longitude, callback)
    else GeocoderPlaces.search(context, query, callback)
  }

  private fun nearbyPlacesAround(latitude: Double, longitude: Double, callback: (Result<List<PlacesApi.Place>>) -> Unit) {
    if (hasPlacesKey) PlacesApi.nearby(apiKey, latitude, longitude, callback)
    else GeocoderPlaces.nearby(context, latitude, longitude, callback)
  }

  private fun onSearchTextChanged(text: String) {
    if (!hasPlacesKey && !GeocoderPlaces.isAvailable) return
    pendingSearch?.let { searchHandler.removeCallbacks(it) }
    val trimmed = text.trim()
    currentQuery = trimmed
    if (trimmed.length < MIN_QUERY_LENGTH) {
      showNearby()
      return
    }
    showLoading("Searching “$trimmed”…")
    val runnable = Runnable {
      val found = locationFix as? LocationFix.Found
      searchPlaces(trimmed, found?.latitude, found?.longitude) { result ->
        if (isDismissed || currentQuery != trimmed) return@searchPlaces
        result.onSuccess { showPlaces(it, null, "No places found") }
          .onFailure { showMessage("Couldn't search locations — check your connection") }
      }
    }
    pendingSearch = runnable
    searchHandler.postDelayed(runnable, 350)
  }

  /** Autocomplete predictions carry no coordinates — fetch them via Place
   *  Details first. A failed lookup still selects the place (null coords;
   *  the sticker just won't open maps). */
  private fun selectPlace(place: PlacesApi.Place) {
    if (isResolvingPlace) return
    if (place.latitude != null || place.id.isEmpty()) {
      onSelect(place)
      dismiss()
      return
    }
    isResolvingPlace = true
    loadingView.start("Getting location…")
    PlacesApi.details(apiKey, place.id) { result ->
      isResolvingPlace = false
      if (isDismissed) return@details
      val coords = result.getOrNull()
      onSelect(place.copy(latitude = coords?.first, longitude = coords?.second))
      dismiss()
    }
  }

  private inner class PlaceAdapter : RecyclerView.Adapter<PlaceAdapter.ViewHolder>() {
    inner class ViewHolder(val row: LinearLayout, val title: TextView, val subtitle: TextView) : RecyclerView.ViewHolder(row)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
      val title = TextView(parent.context).apply {
        setTextColor(EditorDesignTokens.Colors.textPrimary)
        textSize = 15f
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
      }
      val subtitle = TextView(parent.context).apply {
        setTextColor(EditorDesignTokens.Colors.textSecondary)
        textSize = 12f
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
      }
      val row = LinearLayout(parent.context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(16f), 0, dp(16f), 0)
        isClickable = true
        addView(title, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(subtitle, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(2f) })
        layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, dp(60f))
      }
      return ViewHolder(row, title, subtitle)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
      val place = places[position]
      holder.title.text = place.name
      holder.subtitle.text = place.address
      holder.subtitle.visibility = if (place.address.isEmpty()) View.GONE else View.VISIBLE
      holder.row.setOnClickListener { selectPlace(place) }
    }

    override fun getItemCount() = places.size
  }

  private companion object {
    const val MIN_QUERY_LENGTH = 2
    const val NEARBY_MESSAGE = "Finding places near you…"
  }
}
