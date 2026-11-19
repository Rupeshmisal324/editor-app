package com.intoactive.app.mediaeditor

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlaySettings

/** A text layer's animation: In (start of each time piece), Out (end of
 *  it) and Loop (all the time it's on screen), each with its own length. */
internal data class TextAnimConfig(
  val inType: Int = 0,
  val outType: Int = 0,
  val loopType: Int = 0,
  val inDurationMs: Long = 500L,
  val outDurationMs: Long = 500L,
  /** One loop cycle. */
  val loopPeriodMs: Long = 1000L,
) {
  val isNone: Boolean get() = inType == 0 && outType == 0 && loopType == 0
  companion object { val NONE = TextAnimConfig() }
}

/**
 * Text animations. Same math (and type numbers) as iOS TextAnimation,
 * used by the live preview, the sheet's tiles and the export.
 */
internal object TextAnimation {
  val inTitles = arrayOf("None", "Fade", "Pop", "Typewriter", "Slide up", "Slide down", "Slide left", "Slide right",
    "Zoom in", "Zoom out", "Bounce", "Spin", "Drop", "Swing", "Flash", "Wipe")
  val outTitles = arrayOf("None", "Fade", "Pop", "Slide down", "Slide up", "Slide left", "Slide right",
    "Zoom in", "Zoom out", "Spin", "Flash", "Wipe")
  val loopTitles = arrayOf("None", "Pulse", "Heartbeat", "Wiggle", "Swing", "Float", "Sway", "Shake", "Blink", "Rotate", "Hop")
  val DURATION_RANGE_MS = 200L..2000L
  val LOOP_PERIOD_RANGE_MS = 400L..3000L

  /** [offsetX] / [offsetY] = fraction of the canvas width / height
   *  (+ = right / down); [rotation] in degrees, + = clockwise; [reveal] =
   *  visible fraction of the text, left to right (typewriter / wipe). */
  data class State(
    val alpha: Float = 1f,
    val scale: Float = 1f,
    val offsetX: Float = 0f,
    val offsetY: Float = 0f,
    val rotation: Float = 0f,
    val reveal: Float = 1f,
  )

  val IDENTITY = State()

  private class M { var alpha = 1f; var scale = 1f; var offsetX = 0f; var offsetY = 0f; var rotation = 0f; var reveal = 1f }

  fun state(tMs: Long, segments: List<LongRange>, c: TextAnimConfig): State {
    if (c.isNone) return IDENTITY
    val seg = segments.firstOrNull { tMs >= it.first && tMs <= it.last } ?: return IDENTITY
    val length = seg.last - seg.first
    if (length <= 0) return IDENTITY
    val s = M()
    if (c.inType != 0) {
      val d = minOf(c.inDurationMs, length / 2)
      val p = if (d > 0) ((tMs - seg.first).toFloat() / d).coerceIn(0f, 1f) else 1f
      if (p < 1f) applyIn(c.inType, p, s)
    }
    if (c.outType != 0) {
      val d = minOf(c.outDurationMs, length / 2)
      val p = if (d > 0) ((seg.last - tMs).toFloat() / d).coerceIn(0f, 1f) else 1f
      if (p < 1f) applyOut(c.outType, p, s)
    }
    if (c.loopType != 0) {
      val phase = (tMs - seg.first).toFloat() / c.loopPeriodMs.coerceAtLeast(100L)
      applyLoop(c.loopType, phase, s)
    }
    return State(s.alpha, s.scale, s.offsetX, s.offsetY, s.rotation, s.reveal)
  }

  private const val PI = Math.PI.toFloat()
  private const val RAD = 180f / PI

  /** [p] goes 0 → 1 as the text comes in. */
  private fun applyIn(type: Int, p: Float, s: M) {
    val e = easeOut(p)
    when (type) {
      1 -> s.alpha *= e
      2 -> { s.scale *= 0.4f + 0.6f * easeOutBack(p); s.alpha *= minOf(1f, p * 3f) }
      3 -> s.reveal = minOf(s.reveal, kotlin.math.floor(p * 12f) / 12f)
      4 -> { s.offsetY += (1f - e) * 0.08f; s.alpha *= e }
      5 -> { s.offsetY -= (1f - e) * 0.08f; s.alpha *= e }
      6 -> { s.offsetX += (1f - e) * 0.15f; s.alpha *= e }
      7 -> { s.offsetX -= (1f - e) * 0.15f; s.alpha *= e }
      8 -> { s.scale *= 0.2f + 0.8f * e; s.alpha *= e }
      9 -> { s.scale *= 2f - e; s.alpha *= e }
      10 -> { s.offsetY += (1f - easeOutBack(p, 3f)) * 0.1f; s.alpha *= minOf(1f, p * 4f) }
      11 -> { s.rotation += -(1f - e) * 180f; s.scale *= 0.3f + 0.7f * e; s.alpha *= minOf(1f, p * 3f) }
      12 -> { s.offsetY -= (1f - easeOutBounce(p)) * 0.12f; s.alpha *= minOf(1f, p * 5f) }
      13 -> { s.rotation += 0.45f * (1f - p) * kotlin.math.cos(p * PI * 3.5f) * RAD; s.alpha *= minOf(1f, p * 4f) }
      14 -> s.alpha *= if (p > 0.85f) 1f else if ((p * 7f).toInt() % 2 == 0) 0.15f else 1f
      15 -> s.reveal = minOf(s.reveal, e)
    }
  }

  /** [p] goes 1 → 0 as the text leaves. */
  private fun applyOut(type: Int, p: Float, s: M) {
    val e = easeOut(p)
    when (type) {
      1 -> s.alpha *= e
      2 -> { s.scale *= 0.4f + 0.6f * e; s.alpha *= e }
      3 -> { s.offsetY += (1f - e) * 0.08f; s.alpha *= e }
      4 -> { s.offsetY -= (1f - e) * 0.08f; s.alpha *= e }
      5 -> { s.offsetX -= (1f - e) * 0.15f; s.alpha *= e }
      6 -> { s.offsetX += (1f - e) * 0.15f; s.alpha *= e }
      7 -> { s.scale *= 2f - e; s.alpha *= e }
      8 -> { s.scale *= 0.2f + 0.8f * e; s.alpha *= e }
      9 -> { s.rotation += (1f - e) * 180f; s.scale *= 0.3f + 0.7f * e; s.alpha *= e }
      10 -> s.alpha *= if (p < 0.15f) 0f else if ((p * 7f).toInt() % 2 == 0) 0.15f else 1f
      11 -> s.reveal = minOf(s.reveal, e)
    }
  }

  /** [phase] counts loop cycles since the piece started. */
  private fun applyLoop(type: Int, phase: Float, s: M) {
    val w = 2f * PI * phase
    val f = phase - kotlin.math.floor(phase)
    when (type) {
      1 -> s.scale *= 1f + 0.07f * (0.5f - 0.5f * kotlin.math.cos(w))
      2 -> {
        fun bump(x: Float) = if (x in 0f..0.14f) kotlin.math.sin(x / 0.14f * PI) else 0f
        s.scale *= 1f + 0.12f * bump(f) + 0.08f * bump(f - 0.22f)
      }
      3 -> s.rotation += 0.09f * kotlin.math.sin(w * 2f) * RAD
      4 -> s.rotation += 0.2f * kotlin.math.sin(w) * RAD
      5 -> s.offsetY += 0.015f * kotlin.math.sin(w)
      6 -> s.offsetX += 0.03f * kotlin.math.sin(w)
      7 -> s.offsetX += 0.01f * kotlin.math.sin(w * 6f)
      8 -> s.alpha *= 0.25f + 0.75f * (0.5f + 0.5f * kotlin.math.cos(w))
      9 -> s.rotation += (phase * 360f) % 360f
      10 -> s.offsetY -= 0.035f * kotlin.math.abs(kotlin.math.sin(w / 2f))
    }
  }

  private fun easeOut(x: Float) = 1f - (1f - x) * (1f - x)

  private fun easeOutBack(x: Float, c1: Float = 1.70158f): Float {
    val c3 = c1 + 1f
    val y = x - 1f
    return 1f + c3 * y * y * y + c1 * y * y
  }

  private fun easeOutBounce(x: Float): Float {
    val n1 = 7.5625f
    val d1 = 2.75f
    return when {
      x < 1f / d1 -> n1 * x * x
      x < 2f / d1 -> { val y = x - 1.5f / d1; n1 * y * y + 0.75f }
      x < 2.5f / d1 -> { val y = x - 2.25f / d1; n1 * y * y + 0.9375f }
      else -> { val y = x - 2.625f / d1; n1 * y * y + 0.984375f }
    }
  }
}

/**
 * One layer of a video export (text, sticker, photo or the drawing),
 * kept as data so a fresh overlay can be made for every exported item
 * (kept segment or merged clip). [visibleRangesMs] are the layer's time
 * windows on the editor's combined timeline; null = the whole video.
 * [settings] builds the placement for an animation: a scale multiplier,
 * an anchor shift (NDC, + = right / up) and extra rotation (degrees).
 */
internal class TimedOverlaySpec(
  val bitmap: Bitmap,
  val settings: (scaleMul: Float, anchorDx: Float, anchorDy: Float, rotationDeg: Float) -> OverlaySettings.Builder,
  val visibleRangesMs: List<LongRange>?,
  val anim: TextAnimConfig = TextAnimConfig.NONE,
) {
  /** [speed] = the item's playback speed: frame times are in OUTPUT
   *  time, the layer windows in the clip's own time. */
  fun makeOverlay(itemCombinedStartMs: Long, speed: Float = 1f): BitmapOverlay = TimedBitmapOverlay(this, itemCombinedStartMs, speed)
}

/**
 * A bitmap overlay drawn only while the frame's combined-timeline time is
 * inside one of the layer's windows (alpha 0 otherwise), with its text
 * animation applied.
 *
 * Media3 adds an offset (earlier items' durations, plus an initial offset)
 * to each item's frame timestamps, and whether a clipped item's own
 * timestamps start at 0 isn't something to rely on. So the item's first
 * frame is taken as its start, and later frames are measured from it.
 * Each exported item gets its own instance, so this per-item state is safe.
 */
private class TimedBitmapOverlay(
  private val spec: TimedOverlaySpec,
  private val itemCombinedStartMs: Long,
  private val speed: Float,
) : BitmapOverlay() {
  private var firstFrameUs = Long.MIN_VALUE
  private val visibleSettings = spec.settings(1f, 0f, 0f, 0f).build()
  private val hiddenSettings = spec.settings(1f, 0f, 0f, 0f).setAlphaScale(0f).build()
  private val animated = !spec.anim.isNone
  private val reveals = spec.anim.inType == 3 || spec.anim.inType == 15 || spec.anim.outType == 11
  /** Typewriter: left-part copies of the bitmap, by reveal step. */
  private val revealCache = HashMap<Int, Bitmap>()

  private fun combinedMs(presentationTimeUs: Long): Long {
    if (firstFrameUs == Long.MIN_VALUE) firstFrameUs = presentationTimeUs
    return itemCombinedStartMs + ((presentationTimeUs - firstFrameUs).coerceAtLeast(0) / 1000 * speed).toLong()
  }

  private fun isVisible(ms: Long): Boolean {
    val ranges = spec.visibleRangesMs ?: return true
    // 1 ms tolerance so a frame landing exactly on an edge still counts.
    return ranges.any { ms >= it.first - 1 && ms <= it.last + 1 }
  }

  override fun getBitmap(presentationTimeUs: Long): Bitmap {
    if (!reveals) return spec.bitmap
    val ms = combinedMs(presentationTimeUs)
    val reveal = TextAnimation.state(ms, spec.visibleRangesMs ?: emptyList(), spec.anim).reveal
    if (reveal >= 1f) return spec.bitmap
    val step = (reveal * REVEAL_STEPS).toInt().coerceIn(0, REVEAL_STEPS)
    return revealCache.getOrPut(step) {
      // Same size as the full bitmap (keeps its placement), right part clear.
      val out = Bitmap.createBitmap(spec.bitmap.width, spec.bitmap.height, Bitmap.Config.ARGB_8888)
      val w = spec.bitmap.width * step / REVEAL_STEPS
      if (w > 0) Canvas(out).drawBitmap(spec.bitmap, Rect(0, 0, w, spec.bitmap.height), Rect(0, 0, w, spec.bitmap.height), null)
      out
    }
  }

  override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings {
    if (spec.visibleRangesMs == null && !animated) return visibleSettings
    val ms = combinedMs(presentationTimeUs)
    if (!isVisible(ms)) return hiddenSettings
    if (!animated) return visibleSettings
    val s = TextAnimation.state(ms, spec.visibleRangesMs ?: emptyList(), spec.anim)
    if (s == TextAnimation.IDENTITY) return visibleSettings
    return spec.settings(s.scale, s.offsetX * 2f, -s.offsetY * 2f, s.rotation).setAlphaScale(s.alpha.coerceIn(0f, 1f)).build()
  }

  override fun release() {
    super.release()
    revealCache.values.forEach { it.recycle() }
    revealCache.clear()
  }

  private companion object {
    const val REVEAL_STEPS = 24
  }
}
