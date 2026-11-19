package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.view.View

/** Thin guide lines over the canvas while a dragged layer is snapped:
 *  center lines run the full canvas, edge guides sit at the safe margin.
 *  Same look as iOS SnapGuidesView. Never takes touches. */
internal class SnapGuidesView(context: Context) : View(context) {
  var canvasRect: Rect? = null
  var state: LayerSnapState = LayerSnapState.NONE
    set(value) {
      if (field != value) {
        field = value
        invalidate()
      }
    }

  private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = EditorDesignTokens.Colors.accent
    style = Paint.Style.STROKE
    strokeWidth = resources.displayMetrics.density
  }

  init {
    isClickable = false
    isFocusable = false
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val box = canvasRect ?: return
    if (state.isEmpty) return
    val m = SNAP_EDGE_MARGIN_DP * resources.displayMetrics.density
    val l = box.left.toFloat()
    val t = box.top.toFloat()
    val r = box.right.toFloat()
    val b = box.bottom.toFloat()
    if (state.centerX) canvas.drawLine(box.exactCenterX(), t, box.exactCenterX(), b, paint)
    if (state.centerY) canvas.drawLine(l, box.exactCenterY(), r, box.exactCenterY(), paint)
    if (state.left) canvas.drawLine(l + m, t, l + m, b, paint)
    if (state.right) canvas.drawLine(r - m, t, r - m, b, paint)
    if (state.top) canvas.drawLine(l, t + m, r, t + m, paint)
    if (state.bottom) canvas.drawLine(l, b - m, r, b - m, paint)
  }
}
