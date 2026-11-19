package com.intoactive.app.mediaeditor

import android.os.Handler
import android.os.Looper
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Google Places API (New) calls for the story rail's Location picker —
 * nearby places around the current position + free-text search. Same
 * OkHttp/main-thread-callback shape as MusicApi.
 */
object PlacesApi {

  /** `latitude`/`longitude` are null for autocomplete predictions until
   *  resolved via [details]. */
  data class Place(
    val id: String,
    val name: String,
    val address: String,
    val latitude: Double? = null,
    val longitude: Double? = null,
  )

  private val client = OkHttpClient.Builder()
    .connectTimeout(10, TimeUnit.SECONDS)
    .readTimeout(10, TimeUnit.SECONDS)
    .callTimeout(10, TimeUnit.SECONDS)
    .build()
  private val mainHandler = Handler(Looper.getMainLooper())
  private val jsonType = "application/json; charset=utf-8".toMediaType()
  private const val FIELD_MASK = "places.id,places.displayName,places.formattedAddress,places.location"

  private fun circle(latitude: Double, longitude: Double, radius: Double) = JSONObject().put(
    "circle",
    JSONObject()
      .put("center", JSONObject().put("latitude", latitude).put("longitude", longitude))
      .put("radius", radius),
  )

  /** Up to 10 places closest to the given position. */
  fun nearby(apiKey: String, latitude: Double, longitude: Double, callback: (Result<List<Place>>) -> Unit) {
    val body = JSONObject()
      .put("maxResultCount", 10)
      .put("rankPreference", "DISTANCE")
      .put("locationRestriction", circle(latitude, longitude, 1500.0))
    post(apiKey, "https://places.googleapis.com/v1/places:searchNearby", body, callback = callback)
  }

  /**
   * Google-Maps-style search. Text Search alone resolves an area name
   * ("andheri") to that ONE area, so three requests run in parallel and
   * are merged in this order, de-duplicated by place id / name:
   * autocomplete suggestions (Andheri East, Andheri Station, ...), exact
   * text matches, then "places in <query>" (spots inside that area).
   * Fails only if all three fail. Biased (not restricted) towards the
   * position when known.
   */
  fun search(apiKey: String, query: String, latitude: Double?, longitude: Double?, callback: (Result<List<Place>>) -> Unit) {
    val bias = if (latitude != null && longitude != null) circle(latitude, longitude, 50000.0) else null
    fun textBody(textQuery: String) = JSONObject().put("textQuery", textQuery).put("maxResultCount", 20)
      .apply { if (bias != null) put("locationBias", bias) }
    val autocompleteBody = JSONObject().put("input", query).apply { if (bias != null) put("locationBias", bias) }

    val results = arrayOfNulls<Result<List<Place>>>(3)
    var remaining = 3
    // Every callback below runs on the main thread (see post), so this
    // counter needs no locking.
    fun collect(index: Int, result: Result<List<Place>>) {
      results[index] = result
      if (--remaining > 0) return
      val lists = results.mapNotNull { it?.getOrNull() }
      if (lists.isEmpty()) {
        callback(Result.failure(results.firstNotNullOfOrNull { it?.exceptionOrNull() } ?: IOException("places search failed")))
        return
      }
      val seenIds = HashSet<String>()
      val seenNames = HashSet<String>()
      val merged = lists.flatten().filter { place ->
        val nameKey = place.name.lowercase() + "|" + place.address.lowercase()
        (place.id.isEmpty() || seenIds.add(place.id)) && seenNames.add(nameKey)
      }
      callback(Result.success(merged))
    }

    post(apiKey, "https://places.googleapis.com/v1/places:autocomplete", autocompleteBody, ::parseAutocomplete, fieldMask = null) { collect(0, it) }
    post(apiKey, "https://places.googleapis.com/v1/places:searchText", textBody(query)) { collect(1, it) }
    post(apiKey, "https://places.googleapis.com/v1/places:searchText", textBody("places in $query")) { collect(2, it) }
  }

  /** Place Details (New) — only the coordinates, for an autocomplete
   *  prediction picked in the list. Main-thread callback like the others. */
  fun details(apiKey: String, placeId: String, callback: (Result<Pair<Double, Double>>) -> Unit) {
    val request = Request.Builder()
      .url("https://places.googleapis.com/v1/places/${java.net.URLEncoder.encode(placeId, "UTF-8")}")
      .header("X-Goog-Api-Key", apiKey)
      .header("X-Goog-FieldMask", "location")
      .get()
      .build()
    client.newCall(request).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        mainHandler.post { callback(Result.failure(e)) }
      }
      override fun onResponse(call: Call, response: Response) {
        val text = runCatching { response.use { if (it.isSuccessful) it.body?.string() else null } }.getOrNull()
        val coords = text?.let { runCatching { parseLocation(JSONObject(it)) }.getOrNull() }
        val result = if (coords == null) Result.failure(IOException("place details failed")) else Result.success(coords)
        mainHandler.post { callback(result) }
      }
    })
  }

  /** `{"location":{"latitude":..,"longitude":..}}` → pair, or null if absent. */
  private fun parseLocation(item: JSONObject): Pair<Double, Double>? {
    val location = item.optJSONObject("location") ?: return null
    if (!location.has("latitude") || !location.has("longitude")) return null
    return location.getDouble("latitude") to location.getDouble("longitude")
  }

  /** Always delivers on the main thread; any network/HTTP/parse error is a failure. */
  private fun post(
    apiKey: String,
    url: String,
    body: JSONObject,
    parser: (String) -> List<Place> = ::parse,
    fieldMask: String? = FIELD_MASK,
    callback: (Result<List<Place>>) -> Unit,
  ) {
    val request = Request.Builder()
      .url(url)
      .header("X-Goog-Api-Key", apiKey)
      .apply { if (fieldMask != null) header("X-Goog-FieldMask", fieldMask) }
      .post(body.toString().toRequestBody(jsonType))
      .build()
    client.newCall(request).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        mainHandler.post { callback(Result.failure(e)) }
      }
      override fun onResponse(call: Call, response: Response) {
        val text = runCatching { response.use { if (it.isSuccessful) it.body?.string() else null } }.getOrNull()
        val result = if (text == null) Result.failure(IOException("places request failed")) else Result.success(parser(text))
        mainHandler.post { callback(result) }
      }
    })
  }

  /** `{}` (no `places` key) is Google's "zero results" response, not an error. */
  private fun parse(body: String): List<Place> = runCatching {
    val places = JSONObject(body).optJSONArray("places") ?: JSONArray()
    (0 until places.length()).mapNotNull { i ->
      val item = places.getJSONObject(i)
      val name = item.optJSONObject("displayName")?.optString("text").orEmpty()
      if (name.isEmpty()) return@mapNotNull null
      val coords = parseLocation(item)
      Place(
        id = item.optString("id"),
        name = name,
        address = item.optString("formattedAddress"),
        latitude = coords?.first,
        longitude = coords?.second,
      )
    }
  }.getOrDefault(emptyList())

  /** Autocomplete's `suggestions[].placePrediction` — main text (e.g.
   *  "Andheri East") as the name, secondary text as the address. Query
   *  predictions (no placePrediction) are skipped. */
  private fun parseAutocomplete(body: String): List<Place> = runCatching {
    val suggestions = JSONObject(body).optJSONArray("suggestions") ?: JSONArray()
    (0 until suggestions.length()).mapNotNull { i ->
      val prediction = suggestions.getJSONObject(i).optJSONObject("placePrediction") ?: return@mapNotNull null
      val format = prediction.optJSONObject("structuredFormat")
      val name = format?.optJSONObject("mainText")?.optString("text").orEmpty()
        .ifEmpty { prediction.optJSONObject("text")?.optString("text").orEmpty() }
      if (name.isEmpty()) return@mapNotNull null
      Place(
        id = prediction.optString("placeId"),
        name = name,
        address = format?.optJSONObject("secondaryText")?.optString("text").orEmpty(),
      )
    }
  }.getOrDefault(emptyList())
}
