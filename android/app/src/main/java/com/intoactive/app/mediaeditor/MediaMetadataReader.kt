package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import java.io.File

internal data class MediaMetadata(
  val width: Int,
  val height: Int,
  val durationSeconds: Double,
)

/** Reads width/height/duration without decoding full pixel data. */
internal object MediaMetadataReader {

  fun read(context: Context, uriString: String, type: String): MediaMetadata? {
    return try {
      if (type == "image") readImage(context, uriString) else readVideo(context, uriString)
    } catch (e: Exception) {
      null
    }
  }

  /**
   * Some pickers hand back a plain absolute path with no scheme (mirrors the
   * iOS side of this same class of bug). Uri.parse() on that "succeeds" but
   * produces a schemeless Uri the ContentResolver can't open, so only trust
   * Uri.parse() when it actually found a scheme; otherwise treat the raw
   * string as a filesystem path.
   */
  fun normalizedUri(uriString: String): Uri {
    val parsed = Uri.parse(uriString)
    return if (parsed.scheme != null) parsed else Uri.fromFile(File(uriString))
  }

  private fun readImage(context: Context, uriString: String): MediaMetadata? {
    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    context.contentResolver.openInputStream(normalizedUri(uriString))?.use { stream ->
      BitmapFactory.decodeStream(stream, null, options)
    }
    if (options.outWidth <= 0 || options.outHeight <= 0) return null
    return MediaMetadata(options.outWidth, options.outHeight, 0.0)
  }

  private fun readVideo(context: Context, uriString: String): MediaMetadata? {
    val retriever = MediaMetadataRetriever()
    return try {
      retriever.setDataSource(context, normalizedUri(uriString))
      val width = retriever
        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
        ?.toIntOrNull() ?: return null
      val height = retriever
        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
        ?.toIntOrNull() ?: return null
      val rotation = retriever
        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
        ?.toIntOrNull() ?: 0
      val durationMs = retriever
        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
        ?.toLongOrNull() ?: 0L
      val swapped = rotation == 90 || rotation == 270
      MediaMetadata(
        width = if (swapped) height else width,
        height = if (swapped) width else height,
        durationSeconds = durationMs / 1000.0,
      )
    } finally {
      retriever.release()
    }
  }
}
