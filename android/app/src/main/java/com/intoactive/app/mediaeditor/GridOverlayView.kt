package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.View

/**
 * Static rule-of-thirds grid (2 vertical + 2 horizontal lines, dividing the
 * canvas into thirds) plus a solid border tracing the canvas box's own
 * edge — drawn over the canvas, purely a visual composition/crop-boundary
 * aid, per the user's explicit request ("add border layer... so user
 * should understand which is cropper border so where image get
 * cropped"). Non-interactive; sized/positioned once to match the canvas
 * box exactly (see layoutImageCanvas for image, matched-to-playerView for
 * video) and never touched again, consistent with this app's "canvas box
 * sized once, geometrically stable" rule elsewhere. The canvas box IS the
 * crop rect — export already crops to exactly this view's bounds — so no
 * separate crop-frame state is needed, just tracing the existing boundary.
 */
class GridOverlayView(context: Context) : View(context) {

  private val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.argb(77, 255, 255, 255)
    strokeWidth = 1f * resources.displayMetrics.density
  }
  // Same alpha as gridPaint — user's explicit "make these lines faded
  // (ALL)" follow-up.
  private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.argb(77, 255, 255, 255)
    style = Paint.Style.STROKE
    strokeWidth = 2f * resources.displayMetrics.density
  }

  init {
    isClickable = false
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val w = width.toFloat()
    val h = height.toFloat()
    val x1 = w / 3f
    val x2 = w * 2f / 3f
    val y1 = h / 3f
    val y2 = h * 2f / 3f
    canvas.drawLine(x1, 0f, x1, h, gridPaint)
    canvas.drawLine(x2, 0f, x2, h, gridPaint)
    canvas.drawLine(0f, y1, w, y1, gridPaint)
    canvas.drawLine(0f, y2, w, y2, gridPaint)
    // Inset by half the stroke width so the border draws fully inside the
    // view's bounds instead of being clipped at the edge.
    val borderInset = borderPaint.strokeWidth / 2f
    canvas.drawRect(borderInset, borderInset, w - borderInset, h - borderInset, borderPaint)
  }
}
