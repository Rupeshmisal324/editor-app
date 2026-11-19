package com.intoactive.app.mediaeditor

import android.graphics.Bitmap
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * One-tap "Auto" enhance: analyses the photo and picks balanced values for
 * the EXISTING Brightness/Contrast/Saturation/Warm sliders, so the result
 * stays fully editable/undoable and goes through the normal preview/export
 * pipeline.
 *
 * 1. Decide the IDEAL tone curve in sRGB: an auto-levels stretch
 *    (0.5%–99.5% luminance → 0–1) at 75% strength, plus a gentle gamma for
 *    genuinely dark/bright photos.
 * 2. Search the Brightness/Contrast pair whose ACTUAL slider math best
 *    reproduces that curve, weighted across the photo's tonal range, with
 *    unrequested clipping heavily penalized. Android's sliders are sRGB
 *    ColorMatrix terms, brightness applied first, then contrast about 0.5
 *    (see combinedColorMatrix). iOS runs the same search against its own
 *    slider math (Core Image, linear light), so the two platforms produce
 *    the same LOOK even though the slider numbers differ.
 */
internal data class PhotoAutoEnhance(
  val brightness: Float,
  val contrast: Float,
  val saturation: Float,
  val warmth: Float,
) {
  companion object {
    /** Sampled at this long side — plenty for global statistics. */
    private const val SAMPLE_LONG_SIDE = 96

    fun compute(bitmap: Bitmap): PhotoAutoEnhance? {
      val longSide = max(bitmap.width, bitmap.height)
      if (longSide <= 0) return null
      val scale = min(1f, SAMPLE_LONG_SIDE.toFloat() / longSide)
      val w = max(1, (bitmap.width * scale).toInt())
      val h = max(1, (bitmap.height * scale).toInt())
      val small = Bitmap.createScaledBitmap(bitmap, w, h, true)
      val pixels = IntArray(w * h)
      small.getPixels(pixels, 0, w, 0, 0, w, h)
      if (small !== bitmap) small.recycle()
      if (pixels.isEmpty()) return null

      val histogram = DoubleArray(256)
      var satSum = 0.0
      var midR = 0.0
      var midB = 0.0
      var midCount = 0.0
      for (p in pixels) {
        val r = ((p shr 16) and 0xFF) / 255.0
        val g = ((p shr 8) and 0xFF) / 255.0
        val b = (p and 0xFF) / 255.0
        val lum = 0.299 * r + 0.587 * g + 0.114 * b
        histogram[(lum * 255).toInt().coerceIn(0, 255)] += 1.0
        val maxC = maxOf(r, g, b)
        val minC = minOf(r, g, b)
        satSum += if (maxC > 0) (maxC - minC) / maxC else 0.0
        // Warm slider multiplies sRGB values on Android → measure in sRGB.
        if (lum > 0.15 && lum < 0.85) { midR += r; midB += b; midCount += 1 }
      }
      val n = pixels.size.toDouble()
      fun percentile(fraction: Double): Double {
        val target = n * fraction
        var running = 0.0
        for (bin in 0 until 256) {
          running += histogram[bin]
          if (running > target) return bin / 255.0
        }
        return 1.0
      }
      val lo = percentile(0.005)
      val hi = max(percentile(0.995), lo + 0.05)

      // 1. Ideal tone curve.
      fun levels(x: Double) = x + 0.75 * ((x - lo) / (hi - lo) - x)
      var meanAfterLevels = 0.0
      for (bin in 0 until 256) {
        if (histogram[bin] > 0) meanAfterLevels += levels(bin / 255.0).coerceIn(0.0, 1.0) * histogram[bin]
      }
      meanAfterLevels /= n
      // Exposure only for genuinely dark/bright photos: pull the mean 60% of
      // the way back into 0.38..0.62 with a gamma.
      val targetMean = meanAfterLevels.coerceIn(0.38, 0.62)
      val fullGamma = ln(targetMean) / ln(meanAfterLevels.coerceIn(0.03, 0.97))
      val gamma = (1 + 0.6 * (fullGamma - 1)).coerceIn(0.6, 1.4)
      val idealCurve = DoubleArray(256) { bin -> levels((bin + 0.5) / 255).coerceIn(0.0, 1.0).pow(gamma) }

      // Every tone inside the photo's own range counts (not just the common
      // ones), so a few dark pixels can't be sacrificed to fit the bulk.
      val floorWeight = n / 256 * 0.6
      val weights = DoubleArray(256) { bin ->
        val x = bin / 255.0
        histogram[bin] + if (x in lo..hi) floorWeight else 0.0
      }

      // 2. Best-fit slider pair for Android's real slider math.
      fun error(b: Double, c: Double): Double {
        var total = 0.0
        for (bin in 0 until 256) {
          val weight = weights[bin]
          if (weight <= 0) continue
          val x = (bin + 0.5) / 255
          val raw = c * (x + b - 0.5) + 0.5
          val out = raw.coerceIn(0.0, 1.0)
          val target = idealCurve[bin]
          val d = out - target
          var e = d * d
          // Clipping the ideal curve doesn't ask for is much worse than a
          // slightly-off tone: crushed blacks / blown highlights.
          if (raw <= 0 && target > 0.004) e += 0.05 + 10 * target * target
          if (raw >= 1 && target < 0.99) e += 0.05 + 10 * (1 - target) * (1 - target)
          total += e * weight
        }
        // Small pull toward "no change" so near-perfect photos stay put.
        return total + n * 0.0003 * ((c - 1) * (c - 1) + b * b)
      }
      var bestB = 0.0
      var bestC = 1.0
      var bestError = error(0.0, 1.0)
      // Coarse grid, then a fine pass around the winner.
      var c = 0.7
      while (c <= 1.8001) {
        var b = -0.3
        while (b <= 0.4001) {
          val e = error(b, c)
          if (e < bestError) { bestError = e; bestB = b; bestC = c }
          b += 0.05
        }
        c += 0.05
      }
      val coarseB = bestB
      val coarseC = bestC
      for (ci in -5..5) {
        for (bi in -5..5) {
          val cc = coarseC + ci * 0.01
          val bb = coarseB + bi * 0.01
          val e = error(bb, cc)
          if (e < bestError) { bestError = e; bestB = bb; bestC = cc }
        }
      }

      // Saturation: half-way toward a natural ~0.30 mean (HSV saturation).
      // Near-B&W photos are left alone and mostly-neutral ones (white
      // subject) only get a small lift; contrast already adds some punch.
      val meanSat = satSum / n
      var saturation = 0.0
      if (meanSat > 0.06) {
        saturation = (0.5 * (0.30 / meanSat - 1) - 0.15 * (bestC - 1))
          .coerceIn(-0.1, if (meanSat < 0.12) 0.1 else 0.25)
      }

      // Warmth: correct a colour cast (grey-world on mid-tones). Blue casts
      // are corrected firmly; warm ones only lightly, since many photos
      // (food, sunsets, indoor light) are SUPPOSED to be warm.
      var warmth = 0.0
      if (midCount > n * 0.05) {
        val r = midR / midCount
        val b = midB / midCount
        if (r + b > 0) {
          val full = (b - r) / (0.25 * (r + b)) // makes mid-tone R == B
          if (abs(full) >= 0.1) {
            warmth = if (full > 0) min(full * 0.7, 0.6) else max(full * 0.25, -0.15)
          }
        }
      }

      fun rounded(v: Double): Float = (v * 100).roundToInt() / 100f
      return PhotoAutoEnhance(
        brightness = rounded(bestB),
        contrast = rounded(bestC - 1),
        saturation = rounded(saturation),
        warmth = rounded(warmth),
      )
    }
  }
}
