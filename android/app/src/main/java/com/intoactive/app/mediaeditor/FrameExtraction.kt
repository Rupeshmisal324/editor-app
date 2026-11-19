package com.intoactive.app.mediaeditor

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build

/**
 * A video frame no bigger than [maxSide] px on its longest side. Filmstrip
 * and preview thumbnails only need a few hundred pixels, but
 * getFrameAtTime decodes the FULL frame (~33 MB for a 4K video), which
 * spiked memory on long / 4K videos. Android 8.1+ decodes straight to the
 * small size; older versions scale down right after and free the full one.
 */
internal fun MediaMetadataRetriever.scaledFrameAt(
  timeUs: Long,
  option: Int = MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
  maxSide: Int,
): Bitmap? {
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
    return getScaledFrameAtTime(timeUs, option, maxSide, maxSide)
  }
  val full = getFrameAtTime(timeUs, option) ?: return null
  val longest = maxOf(full.width, full.height)
  if (longest <= maxSide) return full
  val scale = maxSide.toFloat() / longest
  val small = Bitmap.createScaledBitmap(full, maxOf(1, (full.width * scale).toInt()), maxOf(1, (full.height * scale).toInt()), true)
  if (small !== full) full.recycle()
  return small
}

/** Filmstrip / merged-clip tiles. */
internal const val FILMSTRIP_FRAME_MAX_SIDE = 240
/** Filter-row source frame and export-progress thumbnail. */
internal const val PREVIEW_FRAME_MAX_SIDE = 720
