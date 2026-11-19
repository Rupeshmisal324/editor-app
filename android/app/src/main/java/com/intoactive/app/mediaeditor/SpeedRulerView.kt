package com.intoactive.app.mediaeditor

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Edits-style speed ruler (same design as iOS SpeedRulerView): 0.25x–4x on
 * a doubling scale (1x centred), small ticks every quarter step, labelled
 * major ticks at 0.25 / 0.5 / 1 / 2 / 4x, a round thumb on a filled track.
 * Drag or tap anywhere. Snaps to round values, with a haptic tick on each
 * major value.
 */
internal class SpeedRulerView(context: Context) : View(context) {
  var value: Float = 1f
    set(v) { field = v; invalidate() }
  var onChange: ((Float) -> Unit)? = null

  private val density = resources.displayMetrics.density
  private val tickPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
  private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.argb(179, 255, 255, 255)
    textSize = 11f * density
    textAlign = Paint.Align.CENTER
  }
  private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = EditorDesignTokens.Colors.accent }
  private val thumbPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    setShadowLayer(4f * density, 0f, density, Color.argb(102, 0, 0, 0))
  }

  init {
    setLayerType(LAYER_TYPE_SOFTWARE, null) // thumb shadow
    contentDescription = "Speed"
  }

  private val inset get() = 24f * density
  private fun xForLog(l: Double): Float = inset + ((l - MIN_LOG) / (MAX_LOG - MIN_LOG)).toFloat() * (width - inset * 2)
  private fun logForX(x: Float): Double {
    val f = ((x - inset) / (width - inset * 2).coerceAtLeast(1f)).toDouble().coerceIn(0.0, 1.0)
    return MIN_LOG + f * (MAX_LOG - MIN_LOG)
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val trackY = 26f * density
    var l = MIN_LOG
    while (l <= MAX_LOG + 0.001) {
      val major = abs(l - l.roundToInt()) < 0.001
      val tx = xForLog(l)
      tickPaint.alpha = if (major) 179 else 77
      val h = (if (major) 14f else 8f) * density
      canvas.drawRect(tx - 0.75f * density, trackY - h / 2, tx + 0.75f * density, trackY + h / 2, tickPaint)
      if (major) {
        val speed = 2.0.pow(l)
        val text = when {
          speed < 0.3 -> "0.25x"
          speed < 0.75 -> "0.5x"
          else -> "${speed.roundToInt()}x"
        }
        canvas.drawText(text, tx, trackY + 14f * density + labelPaint.textSize, labelPaint)
      }
      l += 0.25
    }
    val vx = xForLog(ln(value.toDouble()) / ln(2.0))
    val cx = xForLog(0.0)
    canvas.drawRect(minOf(vx, cx), trackY - 1.5f * density, maxOf(vx, cx), trackY + 1.5f * density, trackPaint)
    canvas.drawCircle(vx, trackY, 11f * density, thumbPaint)
  }

  @SuppressLint("ClickableViewAccessibility")
  override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        parent?.requestDisallowInterceptTouchEvent(true)
        update(event.x)
      }
      MotionEvent.ACTION_MOVE -> update(event.x)
    }
    return true
  }

  private fun update(x: Float) {
    val new = snapped(2.0.pow(logForX(x)).toFloat())
    if (new == value) return
    value = new
    if (new in MAJORS) performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    onChange?.invoke(new)
  }

  companion object {
    const val MIN_LOG = -2.0 // log2(0.25)
    const val MAX_LOG = 2.0  // log2(4)
    private val MAJORS = listOf(0.25f, 0.5f, 1f, 2f, 4f)

    /** Rounded so the readout stays tidy: 0.05 steps below 2x, 0.1 above. */
    fun snapped(speed: Float): Float {
      for (major in MAJORS) if (abs(speed - major) / major < 0.04f) return major
      val step = if (speed < 2f) 0.05f else 0.1f
      return ((speed / step).roundToInt() * step).coerceIn(0.25f, 4f)
    }
  }
}
