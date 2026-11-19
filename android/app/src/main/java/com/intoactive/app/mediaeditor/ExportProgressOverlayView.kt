package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.SweepGradient
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/** Full-screen, interaction-blocking overlay shown while a video export
 *  runs — per the user's explicit reference screenshot: an X (cancel) top-
 *  left, a large percentage readout, a "don't close the app" warning, and
 *  the video's own first-frame thumbnail inside a rounded frame with an
 *  animated rainbow gradient border that traces around the frame's
 *  perimeter proportionally to [setProgress]. Kept as its own focused view
 *  rather than inline in MediaEditorActivity (already very large) — call
 *  site wires [onCancel] and feeds progress via [setProgress]/[setThumbnail]. */
class ExportProgressOverlayView(context: Context) : FrameLayout(context) {

  private val percentLabel: TextView
  private val thumbnailView: ImageView
  private val ringView: GradientRingView
  private lateinit var placeholderView: View
  var onCancel: (() -> Unit)? = null

  init {
    setBackgroundColor(EditorDesignTokens.Colors.canvasBackground)
    // Swallow all touches so nothing underneath (canvas, tray, Done
    // button) is reachable while export is in flight.
    isClickable = true
    isFocusable = true

    val density = resources.displayMetrics.density
    fun dp(value: Float) = (value * density).toInt()

    val closeButton = TextView(context).apply {
      text = "✕" // plain "X" glyph — no extra drawable asset needed
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      textSize = 20f
      gravity = Gravity.CENTER
      setOnClickListener { onCancel?.invoke() }
    }
    addView(
      closeButton,
      LayoutParams(dp(44f), dp(44f), Gravity.TOP or Gravity.START).apply {
        leftMargin = dp(16f)
        topMargin = dp(16f)
      },
    )

    percentLabel = TextView(context).apply {
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      textSize = 32f
      typeface = Typeface.DEFAULT_BOLD
      gravity = Gravity.CENTER
      text = "0%"
    }
    val subtitleLabel = TextView(context).apply {
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = 14f
      gravity = Gravity.CENTER
      text = "Please don't close the app or lock your screen."
    }
    val textColumn = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      addView(percentLabel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
      addView(
        subtitleLabel,
        LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
          topMargin = dp(8f)
        },
      )
    }
    addView(
      textColumn,
      LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
        topMargin = dp(96f)
      },
    )

    val thumbCornerRadiusPx = dp(24f).toFloat()
    thumbnailView = ImageView(context).apply {
      scaleType = ImageView.ScaleType.CENTER_CROP
      clipToOutline = true
      outlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
          outline.setRoundRect(0, 0, view.width, view.height, thumbCornerRadiusPx)
        }
      }
      setBackgroundColor(EditorDesignTokens.Colors.elevatedSurface)
    }
    val ringInsetPx = dp(8f)
    ringView = GradientRingView(context, cornerRadiusPx = thumbCornerRadiusPx + ringInsetPx / 2f)

    val thumbWidthPx = dp(220f)
    val thumbHeightPx = dp(390f) // ~9:16, matches typical portrait video
    val thumbFrame = FrameLayout(context)
    thumbFrame.addView(thumbnailView, FrameLayout.LayoutParams(thumbWidthPx, thumbHeightPx, Gravity.CENTER))
    // Placeholder until (or if never) a real frame arrives: a play glyph
    // and "Exporting your video", so the box is never just empty.
    placeholderView = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      addView(EditorIconView(context, EditorIcon.PLAY).apply { iconTint = EditorDesignTokens.Colors.textSecondary },
        LinearLayout.LayoutParams(dp(44f), dp(44f)))
      addView(TextView(context).apply {
        text = "Exporting your video"
        textSize = 13f
        setTextColor(EditorDesignTokens.Colors.textSecondary)
        gravity = Gravity.CENTER
      }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10f) })
    }
    thumbFrame.addView(placeholderView, FrameLayout.LayoutParams(thumbWidthPx, thumbHeightPx, Gravity.CENTER))
    thumbFrame.addView(
      ringView,
      FrameLayout.LayoutParams(thumbWidthPx + ringInsetPx * 2, thumbHeightPx + ringInsetPx * 2, Gravity.CENTER),
    )
    addView(thumbFrame, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER))
  }

  fun setThumbnail(bitmap: Bitmap?) {
    thumbnailView.setImageBitmap(bitmap)
    placeholderView.visibility = if (bitmap != null) View.GONE else View.VISIBLE
  }

  // Smoothing: Transformer.getProgress reports in coarse, infrequent jumps
  // on-device — e.g. sitting at 0 then suddenly reporting 40%, then
  // jumping straight to 55%, 70% — per the user's explicit "it's jumping
  // by 10%, 15%... feels fake, make it increase smoothly in decimal
  // points, don't make it fast" report. Rather than display that raw,
  // jumpy value directly, a ~16ms ticker eases a locally-tracked
  // `displayedProgress` toward the latest reported `targetProgress` at a
  // fixed, deliberately gentle ceiling rate — real jumps in the
  // underlying value become a smooth climb instead of a visible snap.
  private var displayedProgress = 0f
  private var targetProgress = 0f
  private var tickerStarted = false
  private val progressHandler = Handler(Looper.getMainLooper())
  // ~18%/second ceiling at a 16ms tick — smooth and visibly gradual
  // without feeling sluggish; tune here if it still reads as too fast/slow.
  private val progressTicker = object : Runnable {
    override fun run() {
      if (displayedProgress < targetProgress) {
        displayedProgress = (displayedProgress + 0.003f).coerceAtMost(targetProgress)
        applyDisplayedProgress()
      }
      progressHandler.postDelayed(this, 16L)
    }
  }

  private fun applyDisplayedProgress() {
    percentLabel.text = "${(displayedProgress * 100).toInt()}%"
    ringView.progress = displayedProgress
  }

  /** [percent] 0-100, straight from the caller's raw (possibly jumpy)
   *  polling of the real export session — this only records it as the new
   *  TARGET; [progressTicker] is what actually moves the visible
   *  percentage/ring toward it, smoothly, over time. */
  fun setProgress(percent: Int) {
    targetProgress = percent.coerceIn(0, 100) / 100f
    if (!tickerStarted) {
      tickerStarted = true
      progressHandler.post(progressTicker)
    }
  }

  /** Jumps the displayed value straight to 100% and stops the ticker —
   *  called once the export has actually finished, so completion is never
   *  left waiting on the smoothing catching up. */
  fun finishProgress() {
    targetProgress = 1f
    displayedProgress = 1f
    applyDisplayedProgress()
    progressHandler.removeCallbacks(progressTicker)
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    progressHandler.removeCallbacks(progressTicker)
  }
}

/** Draws a rainbow-gradient stroke tracing `progress` (0-1) of a rounded
 *  rect's own perimeter, starting at the top edge — the "loading ring
 *  wrapped around the video frame" effect from the reference screenshot.
 *  `PathMeasure.getSegment` extracts exactly the fraction of the perimeter
 *  path already covered, rather than a plain circular arc, so it follows
 *  the rounded-rect shape itself. */
private class GradientRingView(context: Context, private val cornerRadiusPx: Float) : View(context) {
  var progress: Float = 0f
    set(value) {
      field = value.coerceIn(0f, 1f)
      invalidate()
    }

  // Widened from 4 per the user's explicit "increase the border width"
  // request — the reference screenshot's ring reads as a substantially
  // thicker band than a thin 4dp line.
  private val strokeWidthPx = resources.displayMetrics.density * 10f
  private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = strokeWidthPx
    strokeCap = Paint.Cap.ROUND
  }
  private val fullPath = Path()
  private val pathMeasure = PathMeasure()
  private val segmentPath = Path()

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    if (w <= 0 || h <= 0) return
    val inset = strokeWidthPx / 2f
    // Traced clockwise from the TOP CENTER (addRoundRect starts at a
    // corner), so the progress line grows out of the middle of the top
    // edge. Same as iOS.
    val l = inset
    val t = inset
    val r = w - inset
    val b = h - inset
    val rad = minOf(cornerRadiusPx, (r - l) / 2f, (b - t) / 2f)
    fullPath.reset()
    fullPath.moveTo((l + r) / 2f, t)
    fullPath.lineTo(r - rad, t)
    fullPath.arcTo(r - 2 * rad, t, r, t + 2 * rad, -90f, 90f, false)
    fullPath.lineTo(r, b - rad)
    fullPath.arcTo(r - 2 * rad, b - 2 * rad, r, b, 0f, 90f, false)
    fullPath.lineTo(l + rad, b)
    fullPath.arcTo(l, b - 2 * rad, l + 2 * rad, b, 90f, 90f, false)
    fullPath.lineTo(l, t + rad)
    fullPath.arcTo(l, t, l + 2 * rad, t + 2 * rad, 180f, 90f, false)
    fullPath.close()
    pathMeasure.setPath(fullPath, true)
    paint.shader = SweepGradient(
      w / 2f,
      h / 2f,
      intArrayOf(
        Color.parseColor("#FF3B30"), // red
        Color.parseColor("#FF9500"), // orange
        Color.parseColor("#FF2D95"), // pink
        Color.parseColor("#AF52DE"), // purple
        Color.parseColor("#5856D6"), // indigo
        Color.parseColor("#FF3B30"), // back to red, so the sweep loops seamlessly
      ),
      null,
    )
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (progress <= 0f) return
    val length = pathMeasure.length
    if (length <= 0f) return
    segmentPath.reset()
    pathMeasure.getSegment(0f, length * progress, segmentPath, true)
    canvas.drawPath(segmentPath, paint)
  }
}
