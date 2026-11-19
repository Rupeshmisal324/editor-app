package com.intoactive.app.mediaeditor

import android.os.Handler
import android.os.Looper
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONObject
import java.io.IOException
import java.net.URLEncoder
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Direct-from-device music search/trending, mirroring the RN reference
 * implementation (lib/services/ITunesMusicService.ts) on
 * the endpoints/field-mapping — same public, keyless Apple/iTunes JSON
 * endpoints, called natively instead of over the RN bridge so the native
 * video editor's own music picker doesn't need a JS round trip.
 */
object MusicApi {

  // Explicit short timeouts — the default OkHttpClient timeout (10s
  // connect, but NO read/call timeout at all, i.e. unbounded) let a
  // slow/hung response leave the picker's spinner running indefinitely
  // with no feedback, per the user's explicit "many time API not get
  // called and get more much time" report.
  private val client = OkHttpClient.Builder()
    .connectTimeout(10, TimeUnit.SECONDS)
    .readTimeout(10, TimeUnit.SECONDS)
    .callTimeout(10, TimeUnit.SECONDS)
    .build()
  private val mainHandler = Handler(Looper.getMainLooper())

  /** Apple storefronts use lowercase ISO alpha-2 country codes. Resolved
   *  on-device, no backend — same fallback as the RN reference's
   *  DEFAULT_STOREFRONT. */
  private val storefront: String
    get() {
      val code = Locale.getDefault().country
      if (code.isNullOrEmpty() || code == "UN") return "in"
      return code.lowercase()
    }

  /** Last non-empty trending list. The picker shows it instantly on open
   *  while a fresh request runs (every open hits the API). An EMPTY result
   *  is never cached — it used to be, which left the picker on "No songs
   *  found" for the rest of the session with no further API calls. */
  var cachedTrending: List<MediaEditorActivity.MusicTrack>? = null
    private set

  /** Apple's chart feed can take 30 s+ to answer, while catalogue search
   *  answers in well under a second. So both start together and the
   *  picker gets whichever list arrives first; a chart that lands later
   *  still becomes the cached list for the next open. Same as iOS. */
  fun fetchTrendingWithFallback(callback: (Result<List<MediaEditorActivity.MusicTrack>>) -> Unit) {
    var delivered = false
    var failures = 0
    fun finish(result: Result<List<MediaEditorActivity.MusicTrack>>) {
      if (delivered) return
      if (result.getOrNull()?.isNotEmpty() == true) {
        delivered = true
        callback(result)
        return
      }
      failures++
      if (failures == 2) { delivered = true; callback(result) }
    }
    fetchTrending { result ->
      result.getOrNull()?.takeIf { it.isNotEmpty() }?.let { cachedTrending = it }
      finish(result)
    }
    search("top hits", cancelPrevious = false) { result ->
      if (cachedTrending == null) result.getOrNull()?.takeIf { it.isNotEmpty() }?.let { cachedTrending = it }
      finish(result)
    }
  }

  private var isPrefetching = false

  /** Warms the list (and the connection) as soon as an editor opens, so
   *  the picker shows songs the moment it appears. */
  fun prefetchTrending() {
    if (cachedTrending != null || isPrefetching) return
    isPrefetching = true
    fetchTrendingWithFallback { isPrefetching = false }
  }

  /** The chart feed alone: short timeout, no retry (search covers for it). */
  private val feedClient by lazy { client.newBuilder().callTimeout(6, TimeUnit.SECONDS).build() }

  /** 1) Apple's "most-played" RSS feed gives the chart track IDs (no
   *  previewUrl). 2) iTunes lookup resolves those IDs to full track
   *  objects with the playable 30 s previewUrl, in chart order. */
  private fun fetchTrending(onResult: (Result<List<MediaEditorActivity.MusicTrack>>) -> Unit) {
    val storefront = storefront
    val feedUrl = "https://rss.marketingtools.apple.com/api/v2/$storefront/music/most-played/50/songs.json"
    enqueue(feedUrl, feedClient) { body ->
      if (body == null) return@enqueue onResult(Result.failure(IOException("trending feed request failed")))
      val ids = runCatching {
        val results = JSONObject(body).getJSONObject("feed").getJSONArray("results")
        (0 until results.length()).map { results.getJSONObject(it).getString("id") }
      }.getOrDefault(emptyList())
      if (ids.isEmpty()) return@enqueue onResult(Result.failure(IOException("trending feed had no ids")))
      val orderById = ids.withIndex().associate { (index, id) -> id to index }
      val lookupUrl = "https://itunes.apple.com/lookup?id=${ids.joinToString(",")}&country=$storefront&entity=song"
      enqueue(lookupUrl) lookupEnqueue@{ lookupBody ->
        if (lookupBody == null) return@lookupEnqueue onResult(Result.failure(IOException("trending lookup request failed")))
        onResult(Result.success(parseTracks(lookupBody).sortedBy { orderById[it.id] ?: Int.MAX_VALUE }))
      }
    }
  }

  /** Results by search term (this session) — retyping / backspacing to an
   *  earlier term shows its songs instantly. */
  private val searchCache = HashMap<String, List<MediaEditorActivity.MusicTrack>>()
  private var searchCall: Call? = null

  /** Search the iTunes catalogue directly, scoped to the user's storefront.
   *  A newer search cancels the one still in flight (the picker only shows
   *  the latest term anyway). */
  fun search(term: String, cancelPrevious: Boolean = true, callback: (Result<List<MediaEditorActivity.MusicTrack>>) -> Unit) {
    val key = term.lowercase()
    searchCache[key]?.let { callback(Result.success(it)); return }
    val storefront = storefront
    val encoded = URLEncoder.encode(term, "UTF-8")
    val url = "https://itunes.apple.com/search?term=$encoded&media=music&entity=song&country=$storefront&limit=50"
    val call = enqueue(url) { body ->
      if (body == null) {
        callback(Result.failure(IOException("search request failed")))
      } else {
        val tracks = parseTracks(body)
        if (tracks.isNotEmpty()) {
          if (searchCache.size > 40) searchCache.clear()
          searchCache[key] = tracks
        }
        callback(Result.success(tracks))
      }
    }
    if (cancelPrevious) {
      searchCall?.cancel()
      searchCall = call
    }
  }

  /** Runs the request on OkHttp's own background dispatcher and always
   *  delivers `onResult` on the main thread — every caller above updates
   *  UI state directly in its callback. `body` is null on any failure
   *  (network error, timeout, or non-2xx status). */
  private fun enqueue(url: String, httpClient: OkHttpClient = client, onResult: (String?) -> Unit): Call {
    val call = httpClient.newCall(Request.Builder().url(url).build())
    call.enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        // A cancelled (superseded) search reports nothing.
        if (call.isCanceled()) return
        mainHandler.post { onResult(null) }
      }
      override fun onResponse(call: Call, response: Response) {
        val body = response.use { if (it.isSuccessful) it.body?.string() else null }
        mainHandler.post { onResult(body) }
      }
    })
    return call
  }

  /** Shared response parsing for both the lookup and search endpoints —
   *  both return `{ results: [...] }` with the same iTunes track shape.
   *  Tracks with no playable previewUrl are dropped. */
  private fun parseTracks(body: String?): List<MediaEditorActivity.MusicTrack> {
    if (body == null) return emptyList()
    return runCatching {
      val results = JSONObject(body).getJSONArray("results")
      (0 until results.length()).mapNotNull { i ->
        val item = results.getJSONObject(i)
        val isTrack = item.optString("wrapperType") == "track" || item.optString("kind") == "song"
        val previewUrl = item.optString("previewUrl")
        if (!isTrack || previewUrl.isNullOrEmpty()) return@mapNotNull null
        val artwork = item.optString("artworkUrl100").ifEmpty { item.optString("artworkUrl60") }
        MediaEditorActivity.MusicTrack(
          id = item.optLong("trackId").toString(),
          title = item.optString("trackName", "Unknown Track"),
          artist = item.optString("artistName", "Unknown Artist"),
          albumArt = artwork,
          audioUrl = previewUrl,
          durationMs = item.optLong("trackTimeMillis", 0),
        )
      }
    }.getOrDefault(emptyList())
  }
}
