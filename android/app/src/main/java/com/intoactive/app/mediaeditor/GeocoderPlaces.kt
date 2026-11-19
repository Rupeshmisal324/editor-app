package com.intoactive.app.mediaeditor

import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.os.Handler
import android.os.Looper
import java.util.Locale

/**
 * Keyless fallback for the story Location picker, used when no Google
 * Places API key is configured: Android's built-in Geocoder (Google Play
 * services' geocoding, no key needed). It knows addresses and areas rather
 * than every shop/venue, so results are areas, streets and landmarks.
 * Same callback shape as PlacesApi (main thread).
 */
internal object GeocoderPlaces {
  private val mainHandler = Handler(Looper.getMainLooper())

  val isAvailable: Boolean get() = Geocoder.isPresent()

  /** Places matching [query] (biased to nothing — Geocoder has no bias). */
  fun search(context: Context, query: String, callback: (Result<List<PlacesApi.Place>>) -> Unit) {
    Thread {
      val result = runCatching {
        @Suppress("DEPRECATION")
        Geocoder(context, Locale.getDefault()).getFromLocationName(query, 15).orEmpty()
          .mapNotNull { it.toPlace() }
          .distinctBy { it.name to it.address }
      }
      mainHandler.post { callback(result) }
    }.start()
  }

  /** The areas around a position, smallest first: neighbourhood, street,
   *  locality, district, state — e.g. "Andheri East", "Mumbai". */
  fun nearby(context: Context, latitude: Double, longitude: Double, callback: (Result<List<PlacesApi.Place>>) -> Unit) {
    Thread {
      val result = runCatching {
        @Suppress("DEPRECATION")
        val addresses = Geocoder(context, Locale.getDefault()).getFromLocation(latitude, longitude, 10).orEmpty()
        val places = mutableListOf<PlacesApi.Place>()
        for (address in addresses) {
          address.toPlace()?.let { places += it }
          val region = listOfNotNull(address.adminArea, address.countryName).joinToString(", ")
          for (name in listOfNotNull(address.subLocality, address.locality, address.subAdminArea, address.adminArea)) {
            places += PlacesApi.Place("", name, region, address.latitude, address.longitude)
          }
        }
        places.filter { it.name.isNotBlank() }.distinctBy { it.name }
      }
      mainHandler.post { callback(result) }
    }.start()
  }

  private fun Address.toPlace(): PlacesApi.Place? {
    val name = featureName?.takeIf { !it.all(Char::isDigit) }
      ?: subLocality ?: thoroughfare ?: locality ?: adminArea ?: return null
    val line = getAddressLine(0).orEmpty()
    return PlacesApi.Place("", name, line.ifEmpty { listOfNotNull(locality, adminArea, countryName).joinToString(", ") },
      if (hasLatitude()) latitude else null, if (hasLongitude()) longitude else null)
  }
}
