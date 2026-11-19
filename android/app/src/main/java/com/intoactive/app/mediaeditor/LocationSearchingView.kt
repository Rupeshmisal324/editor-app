package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import kotlin.math.PI
import kotlin.math.asin
import kotlin.math.sin

/**
 * Location picker's waiting state: radar rings pulsing out from a bobbing
 * map pin, with a line saying what is being looked up ("Finding places
 * near you…", "Searching “cafe”…"). Replaces the plain "Loading…" text.
 * Same design and timings as iOS's LocationSearchingView.
 */
class LocationSearchingView(context: Context) : LinearLayout(context) {
  private val density = context.resources.displayMetrics.density
  private fun dp(v: Float) = v * density

  private val graphic = Graphic(context)
  private val label = TextView(context).apply {
    setTextColor(EditorDesignTokens.Colors.textSecondary)
    textSize = 14f
    gravity = Gravity.CENTER
    maxLines = 2
  }

  init {
    orientation = VERTICAL
    gravity = Gravity.CENTER_HORIZONTAL
    visibility = GONE
    isClickable = false
    background = GradientDrawable().apply {
      cornerRadius = dp(20f)
      setColor(ColorUtils.setAlphaComponent(EditorDesignTokens.Colors.chromeBackground, 235))
    }
    setPadding(dp(20f).toInt(), dp(12f).toInt(), dp(20f).toInt(), dp(18f).toInt())
    minimumWidth = dp(220f).toInt()
    addView(graphic, LayoutParams(dp(120f).toInt(), dp(128f).toInt()))
    addView(label, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = dp(4f).toInt() })
  }

  val isAnimating get() = graphic.running

  fun start(message: String) {
    label.text = message
    visibility = VISIBLE
    graphic.start()
  }

  fun stop() {
    graphic.stop()
    visibility = GONE
  }

  override fun onDetachedFromWindow() {
    graphic.stop()
    super.onDetachedFromWindow()
  }

  private inner class Graphic(context: Context) : View(context) {
    var running = false
      private set
    private var startMs = 0L

    private val accent = EditorDesignTokens.Colors.accent
    private val ringStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = dp(2f); color = accent }
    private val ringFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = accent }
    private val pinPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = accent }
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = Color.WHITE }
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = Color.BLACK }
    private val pinPath = Path()
    private val oval = RectF()

    fun start() {
      if (running) return
      running = true
      startMs = SystemClock.uptimeMillis()
      postInvalidateOnAnimation()
    }

    fun stop() {
      running = false
    }

    override fun onDraw(canvas: Canvas) {
      if (!running) return
      val t = SystemClock.uptimeMillis() - startMs
      val cx = width / 2f
      val baseY = dp(76f)

      // Radar rings: three, a third of a cycle apart, growing and fading.
      for (i in 0 until 3) {
        val p = ((t % RING_PERIOD_MS) / RING_PERIOD_MS.toFloat() + i / 3f) % 1f
        val radius = dp(52f) * (0.15f + 0.85f * p)
        val alpha = 0.55f * (1f - p)
        ringFill.alpha = (alpha * 0.18f * 255).toInt()
        ringStroke.alpha = (alpha * 255).toInt()
        canvas.drawCircle(cx, baseY, radius, ringFill)
        canvas.drawCircle(cx, baseY, radius, ringStroke)
      }

      // Pin bobs up and down; its ground shadow shrinks while it's up.
      val bob = sin(PI * ((t % BOB_PERIOD_MS) / BOB_PERIOD_MS.toDouble())).toFloat()
      val lift = dp(10f) * bob
      val shadowScale = 1f - 0.35f * bob
      shadowPaint.alpha = ((0.35f - 0.17f * bob) * 255).toInt()
      oval.set(cx - dp(12f) * shadowScale, baseY - dp(4f) * shadowScale, cx + dp(12f) * shadowScale, baseY + dp(4f) * shadowScale)
      canvas.drawOval(oval, shadowPaint)

      // Teardrop: circle (r 13) whose two tangents meet at the tip.
      val r = dp(13f)
      val tipY = baseY - lift
      val centerY = tipY - dp(21f)
      val alpha = asin(r / dp(21f)) // tangent half-angle at the tip
      val startDeg = Math.toDegrees(PI - alpha).toFloat()
      val sweepDeg = Math.toDegrees(PI + 2 * alpha).toFloat()
      pinPath.reset()
      pinPath.moveTo(cx, tipY)
      oval.set(cx - r, centerY - r, cx + r, centerY + r)
      pinPath.arcTo(oval, startDeg, sweepDeg, false)
      pinPath.close()
      canvas.drawPath(pinPath, pinPaint)
      canvas.drawCircle(cx, centerY, dp(5f), dotPaint)

      postInvalidateOnAnimation()
    }
  }

  private companion object {
    const val RING_PERIOD_MS = 1800L
    const val BOB_PERIOD_MS = 900L
  }
}
