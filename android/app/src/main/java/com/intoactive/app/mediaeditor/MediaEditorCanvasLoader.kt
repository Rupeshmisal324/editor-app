package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface

/**
 * Decodes an image for the editor canvas: downsampled to the display size (a
 * full-res decode of a 12MP+ photo risks OOM for no visual benefit at
 * preview scale) and EXIF-rotated upright (BitmapFactory does not auto-apply
 * orientation the way iOS's CGImageSource thumbnail transform does).
 */
internal object MediaEditorCanvasLoader {

  /**
   * Header-only read of the image's DISPLAY (post-EXIF-rotation) pixel
   * size, without decoding any pixel data — fast enough to call
   * synchronously, before the full downsampled decode (loadDownsampled,
   * which runs on a background thread) finishes. Needed to size the
   * editor's canvas box to the photo's own aspect ratio from the very
   * first layout pass: CropOverlayView captures its initial crop rect from
   * whatever size it first sees non-zero (see its onSizeChanged guard), so
   * the box must already be correctly shaped before that, not resized into
   * place later once the async decode completes.
   */
  fun readDisplaySize(context: Context, uriString: String): Pair<Int, Int>? {
    val uri = MediaMetadataReader.normalizedUri(uriString)
    val resolver = context.contentResolver

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

    val orientation = resolver.openInputStream(uri)?.use { stream ->
      ExifInterface(stream).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    } ?: ExifInterface.ORIENTATION_NORMAL
    val swapped = orientation == ExifInterface.ORIENTATION_ROTATE_90 || orientation == ExifInterface.ORIENTATION_ROTATE_270
    return if (swapped) bounds.outHeight to bounds.outWidth else bounds.outWidth to bounds.outHeight
  }

  fun loadDownsampled(context: Context, uriString: String, reqWidth: Int, reqHeight: Int): Bitmap? {
    val uri = MediaMetadataReader.normalizedUri(uriString)
    val resolver = context.contentResolver

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

    val decodeOptions = BitmapFactory.Options().apply {
      inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, reqWidth, reqHeight)
    }
    val bitmap = resolver.openInputStream(uri)?.use {
      BitmapFactory.decodeStream(it, null, decodeOptions)
    } ?: return null

    val orientation = resolver.openInputStream(uri)?.use { stream ->
      ExifInterface(stream).getAttributeInt(
        ExifInterface.TAG_ORIENTATION,
        ExifInterface.ORIENTATION_NORMAL,
      )
    } ?: ExifInterface.ORIENTATION_NORMAL

    return applyExifOrientation(bitmap, orientation)
  }

  private fun sampleSizeFor(origWidth: Int, origHeight: Int, reqWidth: Int, reqHeight: Int): Int {
    var sampleSize = 1
    while (origWidth / (sampleSize * 2) >= reqWidth && origHeight / (sampleSize * 2) >= reqHeight) {
      sampleSize *= 2
    }
    return sampleSize
  }

  private fun applyExifOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
    val matrix = Matrix()
    when (orientation) {
      ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
      ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
      ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
      ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
      ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
      else -> return bitmap
    }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
  }
}
