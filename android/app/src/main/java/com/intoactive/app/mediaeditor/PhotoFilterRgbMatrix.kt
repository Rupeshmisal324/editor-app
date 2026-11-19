package com.intoactive.app.mediaeditor

import android.graphics.ColorMatrix
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.RgbMatrix

/**
 * Adapts our shared android.graphics.ColorMatrix filter/adjustment math
 * (the exact matrices used for the image preview/export) into a Media3 GL
 * RgbMatrix, so the same named filters AND the brightness/contrast/etc.
 * adjustment sliders apply live to video playback instead of needing a
 * second, GL-specific implementation.
 *
 * `matrixProvider` is re-read on every call (once per frame) rather than
 * captured once, so switching the selected filter or dragging an
 * adjustment slider during playback takes effect on the next frame with
 * no need to rebuild the ExoPlayer effects chain.
 */
@UnstableApi
internal class PhotoFilterRgbMatrix(private val matrixProvider: () -> ColorMatrix) : RgbMatrix {

  override fun getMatrix(presentationTimeUs: Long, useHdr: Boolean): FloatArray {
    return toGlMatrix(matrixProvider())
  }

  companion object {
    // android.graphics.ColorMatrix stores a row-major 4x5 matrix (rows
    // R,G,B,A; columns R,G,B,A,translate) with translation in 0-255 scale.
    // Media3's RgbMatrix expects a column-major 4x4 multiplying (R,G,B,1),
    // in 0-1 scale. We drop the alpha column/row (always identity for our
    // filters) and fold the translate column into the "multiplies 1" column.
    private fun toGlMatrix(colorMatrix: ColorMatrix): FloatArray {
      val cm = colorMatrix.array
      return floatArrayOf(
        cm[0], cm[5], cm[10], 0f,
        cm[1], cm[6], cm[11], 0f,
        cm[2], cm[7], cm[12], 0f,
        cm[4] / 255f, cm[9] / 255f, cm[14] / 255f, 1f,
      )
    }
  }
}
