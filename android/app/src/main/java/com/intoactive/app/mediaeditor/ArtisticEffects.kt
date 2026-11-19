package com.intoactive.app.mediaeditor

import android.graphics.Bitmap
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * The Artistic looks (photo only). A line-by-line port of iOS's
 * ArtisticEffects in ios/PhotoFilter.swift — same integer maths, same
 * hash, same loop order — so both platforms draw the same picture. Keep
 * the two in sync: any change here must be made there too (and vice versa).
 * All sizes scale with the image's short side, so a thumbnail, the preview
 * and the full-size export look alike.
 */
internal object ArtisticEffects {

  /** Redraws [source] with [filter]'s effect (alpha kept). [source] itself
   *  is returned for a non-artistic filter. */
  /** Effects are drawn at most this big (long side) and scaled up after —
   *  full-size exports would otherwise need hundreds of MB. Same on iOS. */
  private const val MAX_PROCESSING_SIDE = 1600

  fun render(filter: PhotoFilter, source: Bitmap): Bitmap {
    if (filter.category != FilterCategory.ARTISTIC) return source
    val fullW = source.width
    val fullH = source.height
    if (fullW < 2 || fullH < 2) return source
    val longSide = max(fullW, fullH)
    if (longSide > MAX_PROCESSING_SIDE) {
      val w = max(2, (fullW.toFloat() * MAX_PROCESSING_SIDE / longSide).roundToInt())
      val h = max(2, (fullH.toFloat() * MAX_PROCESSING_SIDE / longSide).roundToInt())
      val small = Bitmap.createScaledBitmap(source, w, h, true)
      val drawn = renderAtSize(filter, small)
      return Bitmap.createScaledBitmap(drawn, fullW, fullH, true)
    }
    return renderAtSize(filter, source)
  }

  private fun renderAtSize(filter: PhotoFilter, source: Bitmap): Bitmap {
    val w = source.width
    val h = source.height
    val pixels = IntArray(w * h)
    source.getPixels(pixels, 0, w, 0, 0, w, h)
    val r = IntArray(w * h) { (pixels[it] shr 16) and 0xFF }
    val g = IntArray(w * h) { (pixels[it] shr 8) and 0xFF }
    val b = IntArray(w * h) { pixels[it] and 0xFF }
    val out = process(filter, r, g, b, w, h)
    for (i in pixels.indices) {
      pixels[i] = (pixels[i] and -0x1000000) or (out.r[i] shl 16) or (out.g[i] shl 8) or out.b[i]
    }
    val result = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    result.setPixels(pixels, 0, w, 0, 0, w, h)
    return result
  }

  private val srgbToLinear = FloatArray(256) { i ->
    val v = i / 255f
    if (v <= 0.04045f) v / 12.92f else ((v + 0.055f) / 1.055f).pow(2.4f)
  }

  /** Linear (0..1, 4096 steps) -> sRGB byte. */
  private val linearToSrgb = IntArray(4097) { i ->
    val v = i / 4096f
    val s = if (v <= 0.0031308f) v * 12.92f else 1.055f * v.pow(1f / 2.4f) - 0.055f
    (s * 255f + 0.5f).toInt().coerceIn(0, 255)
  }

  private fun encode(linear: Float): Int = linearToSrgb[(linear.coerceIn(0f, 1f) * 4096f + 0.5f).toInt()]

  /** Strength (blend source -> effect) and Saturation, both in linear
   *  light like iOS (CIDissolveTransition + CIColorControls). */
  fun blend(source: Bitmap, effect: Bitmap, strength: Float, saturation: Float): Bitmap {
    val t = strength.coerceIn(0f, 1f)
    val sat = 1f + saturation.coerceIn(-1f, 1f)
    if (t >= 0.995f && saturation == 0f) return effect
    if (t <= 0.005f && saturation == 0f) return source
    val w = effect.width
    val h = effect.height
    val src = IntArray(w * h)
    val fx = IntArray(w * h)
    source.getPixels(src, 0, w, 0, 0, w, h)
    effect.getPixels(fx, 0, w, 0, 0, w, h)
    for (i in fx.indices) {
      val a = src[i]
      val e = fx[i]
      var lr = srgbToLinear[(a shr 16) and 0xFF]
      var lg = srgbToLinear[(a shr 8) and 0xFF]
      var lb = srgbToLinear[a and 0xFF]
      lr += (srgbToLinear[(e shr 16) and 0xFF] - lr) * t
      lg += (srgbToLinear[(e shr 8) and 0xFF] - lg) * t
      lb += (srgbToLinear[e and 0xFF] - lb) * t
      if (sat != 1f) {
        val luma = 0.2125f * lr + 0.7154f * lg + 0.0721f * lb
        lr = luma + (lr - luma) * sat
        lg = luma + (lg - luma) * sat
        lb = luma + (lb - luma) * sat
      }
      fx[i] = (e and -0x1000000) or (encode(lr) shl 16) or (encode(lg) shl 8) or encode(lb)
    }
    val result = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    result.setPixels(fx, 0, w, 0, 0, w, h)
    return result
  }

  class Planes(val r: IntArray, val g: IntArray, val b: IntArray)

  private fun process(filter: PhotoFilter, r: IntArray, g: IntArray, b: IntArray, w: Int, h: Int): Planes = when (filter) {
    PhotoFilter.SKETCH -> sketch(r, g, b, w, h)
    PhotoFilter.COMIC -> comic(r, g, b, w, h)
    PhotoFilter.HALFTONE -> halftone(r, g, b, w, h)
    PhotoFilter.PIXEL -> pixelate(r, g, b, w, h)
    PhotoFilter.CRYSTAL -> crystal(r, g, b, w, h)
    PhotoFilter.POSTER -> Planes(posterize(r, 5), posterize(g, 5), posterize(b, 5))
    PhotoFilter.NEON -> neon(r, g, b, w, h)
    else -> Planes(r, g, b)
  }

  // ---- Shared helpers (mirrored exactly in ios/PhotoFilter.swift) ----

  private fun luma(r: Int, g: Int, b: Int): Int = (r * 77 + g * 150 + b * 29) shr 8

  private fun lumaPlane(r: IntArray, g: IntArray, b: IntArray): IntArray =
    IntArray(r.size) { luma(r[it], g[it], b[it]) }

  /** Separable box blur, edges clamped, integer average. */
  private fun boxBlur(src: IntArray, w: Int, h: Int, radius: Int): IntArray {
    if (radius <= 0) return src
    val div = 2 * radius + 1
    val tmp = IntArray(w * h)
    val out = IntArray(w * h)
    for (y in 0 until h) {
      val row = y * w
      var sum = 0
      for (k in -radius..radius) sum += src[row + min(max(k, 0), w - 1)]
      for (x in 0 until w) {
        tmp[row + x] = sum / div
        sum += src[row + min(x + radius + 1, w - 1)] - src[row + max(x - radius, 0)]
      }
    }
    for (x in 0 until w) {
      var sum = 0
      for (k in -radius..radius) sum += tmp[min(max(k, 0), h - 1) * w + x]
      for (y in 0 until h) {
        out[y * w + x] = sum / div
        sum += tmp[min(y + radius + 1, h - 1) * w + x] - tmp[max(y - radius, 0) * w + x]
      }
    }
    return out
  }

  /** Sobel edge strength 0..255; `scale` compensates for a pre-blur. */
  private fun edges(l: IntArray, w: Int, h: Int, scale: Int): IntArray {
    val out = IntArray(w * h)
    for (y in 0 until h) {
      val ym = max(y - 1, 0) * w
      val yc = y * w
      val yp = min(y + 1, h - 1) * w
      for (x in 0 until w) {
        val xm = max(x - 1, 0)
        val xp = min(x + 1, w - 1)
        val gx = (l[ym + xp] + 2 * l[yc + xp] + l[yp + xp]) - (l[ym + xm] + 2 * l[yc + xm] + l[yp + xm])
        val gy = (l[yp + xm] + 2 * l[yp + x] + l[yp + xp]) - (l[ym + xm] + 2 * l[ym + x] + l[ym + xp])
        out[yc + x] = min(255, (abs(gx) + abs(gy)) * scale / 8)
      }
    }
    return out
  }

  private fun posterize(p: IntArray, levels: Int): IntArray {
    val n = levels - 1
    return IntArray(p.size) { ((p[it] * n + 127) / 255) * 255 / n }
  }

  /** Deterministic 0..<1 per grid cell — same bits as iOS's UInt32 maths. */
  private fun hashFraction(i: Int, j: Int, seed: Int): Float {
    var h = i * 374761393 + j * 668265263 + seed * 144665
    h = (h xor (h ushr 13)) * 1274126177
    h = h xor (h ushr 16)
    return (h ushr 8).toFloat() / 16777216f
  }

  private fun clamp255(v: Int): Int = min(255, max(0, v))

  // ---- Effects ----

  /** Pencil sketch: colour-dodge of the grey image with its blurred inverse. */
  private fun sketch(r: IntArray, g: IntArray, b: IntArray, w: Int, h: Int): Planes {
    val side = min(w, h)
    val gray = lumaPlane(r, g, b)
    val inverted = IntArray(w * h) { 255 - gray[it] }
    val radius = max(1, side / 120)
    val blurred = boxBlur(boxBlur(inverted, w, h, radius), w, h, radius)
    val out = IntArray(w * h)
    for (i in 0 until w * h) {
      val dodge = if (blurred[i] >= 255) 255 else min(255, gray[i] * 255 / (255 - blurred[i]))
      out[i] = 255 - min(255, (255 - dodge) * 2)
    }
    return Planes(out, out, out)
  }

  /** Comic: flat posterized colours with bold dark outlines. */
  private fun comic(r: IntArray, g: IntArray, b: IntArray, w: Int, h: Int): Planes {
    val side = min(w, h)
    val radius = max(1, side / 400)
    val br = boxBlur(r, w, h, radius)
    val bg = boxBlur(g, w, h, radius)
    val bb = boxBlur(b, w, h, radius)
    val edge = edges(lumaPlane(br, bg, bb), w, h, 2 * radius + 1)
    var mask = IntArray(w * h) { if (edge[it] > 50) 255 else 0 }
    mask = boxBlur(mask, w, h, side / 500)
    val sr = IntArray(w * h)
    val sg = IntArray(w * h)
    val sb = IntArray(w * h)
    for (i in 0 until w * h) {
      val l = luma(br[i], bg[i], bb[i])
      sr[i] = clamp255(l + (br[i] - l) * 3 / 2)
      sg[i] = clamp255(l + (bg[i] - l) * 3 / 2)
      sb[i] = clamp255(l + (bb[i] - l) * 3 / 2)
    }
    val outR = posterize(sr, 4)
    val outG = posterize(sg, 4)
    val outB = posterize(sb, 4)
    for (i in 0 until w * h) {
      if (mask[i] > 60) {
        outR[i] = 25; outG[i] = 22; outB[i] = 30
      }
    }
    return Planes(outR, outG, outB)
  }

  /** Colour halftone: one dot per cell on paper, bigger where darker. */
  private fun halftone(r: IntArray, g: IntArray, b: IntArray, w: Int, h: Int): Planes {
    val side = min(w, h)
    val cell = max(4, side / 40)
    val outR = IntArray(w * h)
    val outG = IntArray(w * h)
    val outB = IntArray(w * h)
    var cy = 0
    while (cy < h) {
      val y1 = min(cy + cell, h)
      var cx = 0
      while (cx < w) {
        val x1 = min(cx + cell, w)
        var sr = 0
        var sg = 0
        var sb = 0
        for (y in cy until y1) for (x in cx until x1) {
          val i = y * w + x
          sr += r[i]; sg += g[i]; sb += b[i]
        }
        val count = (y1 - cy) * (x1 - cx)
        val ar = sr / count
        val ag = sg / count
        val ab = sb / count
        val l = luma(ar, ag, ab)
        val dotR = clamp255(l + (ar - l) * 3 / 2)
        val dotG = clamp255(l + (ag - l) * 3 / 2)
        val dotB = clamp255(l + (ab - l) * 3 / 2)
        val radius = cell.toFloat() * 0.6f * sqrt(1f - l.toFloat() / 255f * 0.85f)
        val centerX = cx.toFloat() + cell.toFloat() * 0.5f
        val centerY = cy.toFloat() + cell.toFloat() * 0.5f
        for (y in cy until y1) {
          val dy = y.toFloat() + 0.5f - centerY
          for (x in cx until x1) {
            val dx = x.toFloat() + 0.5f - centerX
            val coverage = min(max(radius - sqrt(dx * dx + dy * dy) + 0.5f, 0f), 1f)
            val i = y * w + x
            outR[i] = (250f * (1f - coverage) + dotR.toFloat() * coverage + 0.5f).toInt()
            outG[i] = (246f * (1f - coverage) + dotG.toFloat() * coverage + 0.5f).toInt()
            outB[i] = (238f * (1f - coverage) + dotB.toFloat() * coverage + 0.5f).toInt()
          }
        }
        cx += cell
      }
      cy += cell
    }
    return Planes(outR, outG, outB)
  }

  /** Big square pixels (block average). */
  private fun pixelate(r: IntArray, g: IntArray, b: IntArray, w: Int, h: Int): Planes {
    val block = max(2, min(w, h) / 64)
    val outR = IntArray(w * h)
    val outG = IntArray(w * h)
    val outB = IntArray(w * h)
    var by = 0
    while (by < h) {
      val y1 = min(by + block, h)
      var bx = 0
      while (bx < w) {
        val x1 = min(bx + block, w)
        var sr = 0
        var sg = 0
        var sb = 0
        for (y in by until y1) for (x in bx until x1) {
          val i = y * w + x
          sr += r[i]; sg += g[i]; sb += b[i]
        }
        val count = (y1 - by) * (x1 - bx)
        val ar = sr / count
        val ag = sg / count
        val ab = sb / count
        for (y in by until y1) for (x in bx until x1) {
          val i = y * w + x
          outR[i] = ar; outG[i] = ag; outB[i] = ab
        }
        bx += block
      }
      by += block
    }
    return Planes(outR, outG, outB)
  }

  /** Crystal / stained glass: nearest jittered seed point (Voronoi cells). */
  private fun crystal(r: IntArray, g: IntArray, b: IntArray, w: Int, h: Int): Planes {
    val cell = max(4, min(w, h) / 36)
    val gridW = (w + cell - 1) / cell
    val gridH = (h + cell - 1) / cell
    val seedX = FloatArray(gridW * gridH)
    val seedY = FloatArray(gridW * gridH)
    val seedColor = IntArray(gridW * gridH)
    for (j in 0 until gridH) {
      for (i in 0 until gridW) {
        val sx = (i.toFloat() + 0.15f + 0.7f * hashFraction(i, j, 1)) * cell.toFloat()
        val sy = (j.toFloat() + 0.15f + 0.7f * hashFraction(i, j, 2)) * cell.toFloat()
        seedX[j * gridW + i] = sx
        seedY[j * gridW + i] = sy
        seedColor[j * gridW + i] = min(sy.toInt(), h - 1) * w + min(sx.toInt(), w - 1)
      }
    }
    val outR = IntArray(w * h)
    val outG = IntArray(w * h)
    val outB = IntArray(w * h)
    for (y in 0 until h) {
      val cj = y / cell
      val py = y.toFloat() + 0.5f
      for (x in 0 until w) {
        val ci = x / cell
        val px = x.toFloat() + 0.5f
        var best = Float.MAX_VALUE
        var bestSource = 0
        for (j in max(cj - 1, 0)..min(cj + 1, gridH - 1)) {
          for (i in max(ci - 1, 0)..min(ci + 1, gridW - 1)) {
            val s = j * gridW + i
            val dx = px - seedX[s]
            val dy = py - seedY[s]
            val d = dx * dx + dy * dy
            if (d < best) {
              best = d
              bestSource = seedColor[s]
            }
          }
        }
        val o = y * w + x
        outR[o] = r[bestSource]; outG[o] = g[bestSource]; outB[o] = b[bestSource]
      }
    }
    return Planes(outR, outG, outB)
  }

  /** Neon: glowing coloured edges on black. */
  private fun neon(r: IntArray, g: IntArray, b: IntArray, w: Int, h: Int): Planes {
    val side = min(w, h)
    val radius = max(1, side / 500)
    val edge = edges(boxBlur(lumaPlane(r, g, b), w, h, radius), w, h, 2 * radius + 1)
    val line = IntArray(w * h) { min(255, edge[it] * 3) }
    val glow = boxBlur(line, w, h, max(1, side / 300))
    val outR = IntArray(w * h)
    val outG = IntArray(w * h)
    val outB = IntArray(w * h)
    for (i in 0 until w * h) {
      val intensity = min(255, line[i] + glow[i])
      val l = luma(r[i], g[i], b[i])
      val cr = clamp255(l + (r[i] - l) * 2 + 40)
      val cg = clamp255(l + (g[i] - l) * 2 + 40)
      val cb = clamp255(l + (b[i] - l) * 2 + 40)
      outR[i] = min(255, cr * intensity / 255 + intensity / 6)
      outG[i] = min(255, cg * intensity / 255 + intensity / 6)
      outB[i] = min(255, cb * intensity / 255 + intensity / 6)
    }
    return Planes(outR, outG, outB)
  }
}
