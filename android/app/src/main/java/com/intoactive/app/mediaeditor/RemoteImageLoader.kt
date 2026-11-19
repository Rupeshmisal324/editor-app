package com.intoactive.app.mediaeditor

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import android.widget.ImageView
import java.util.concurrent.Executors

/**
 * Minimal async image loader for the music picker's per-row artwork —
 * no Glide/Coil/Picasso dependency exists in this module (confirmed: none
 * declared in build.gradle), so this is a small URLSession-equivalent
 * loader: a background thread pool + BitmapFactory decode + an in-memory
 * LRU cache, with a per-ImageView tag guard against RecyclerView's cell
 * recycling racing an in-flight request.
 */
object RemoteImageLoader {
  private val executor = Executors.newFixedThreadPool(3)
  private val mainHandler = Handler(Looper.getMainLooper())
  private val cache = object : LruCache<String, Bitmap>(20 * 1024 * 1024) {
    override fun sizeOf(key: String, value: Bitmap) = value.byteCount
  }

  fun load(url: String, imageView: ImageView) {
    imageView.setImageDrawable(null)
    imageView.tag = url
    if (url.isEmpty()) return
    cache.get(url)?.let {
      imageView.setImageBitmap(it)
      return
    }
    executor.execute {
      val bitmap = runCatching {
        java.net.URL(url).openStream().use { BitmapFactory.decodeStream(it) }
      }.getOrNull() ?: return@execute
      cache.put(url, bitmap)
      mainHandler.post {
        // Guards against a recycled RecyclerView row: only apply if this
        // ImageView hasn't already been reassigned to a different item's
        // URL while the request was in flight.
        if (imageView.tag == url) imageView.setImageBitmap(bitmap)
      }
    }
  }
}
