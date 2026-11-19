package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Canvas
import android.graphics.Rect
import android.view.View
import android.widget.FrameLayout

/**
 * Plain FrameLayout that additionally hard-clips specific REGISTERED
 * children to an explicit [Rect] during drawing, regardless of how far
 * that child's own scaleX/scaleY/rotation/translationX/translationY has
 * moved or grown it. Used (see MediaEditorActivity) to keep the base
 * image/video canvas AND every text/sticker/overlay layer visually
 * confined to the crop box, per the user's explicit "zoomed image should
 * not display outside of that cropper box" report —
 * `clampLayerWithinImageBounds`/`clampBoundedTranslation` in
 * LayerGestureCoordinator only RE-CENTER an oversized layer, they can't
 * stop it from overflowing the box once it's bigger than the box itself
 * (their own doc already calls this out as a known gap).
 *
 * A real ancestor-based `clipChildren`/`clipToOutline` approach would need
 * these views to be direct children of a differently-sized/positioned
 * parent — but LayerGestureCoordinator's hit-testing (`toLocal`) and this
 * Activity's own `layerBaseX/Y` math both read `.left`/`.top` assuming
 * every manipulable layer is a DIRECT child of `root` itself (see those
 * functions' own docs). Reparenting would require reworking that math to
 * account for a new ancestor's offset. This achieves the same visual
 * result at the DRAW level instead, with zero changes to the existing
 * touch/position code: `canvas.clipRect(rect)` is set on `root`'s own
 * canvas BEFORE the child's transform is concatenated for drawing, so the
 * clip boundary stays fixed in `root`'s coordinate space regardless of
 * how much the child itself is zoomed/rotated/panned.
 */
class ClippingRootLayout(context: Context) : FrameLayout(context) {
  private val clipRects = mutableMapOf<View, Rect>()

  fun setClipRect(child: View, rect: Rect?) {
    if (rect == null) clipRects.remove(child) else clipRects[child] = rect
  }

  override fun drawChild(canvas: Canvas, child: View, drawingTime: Long): Boolean {
    val rect = clipRects[child] ?: return super.drawChild(canvas, child, drawingTime)
    canvas.save()
    canvas.clipRect(rect)
    val result = super.drawChild(canvas, child, drawingTime)
    canvas.restore()
    return result
  }
}
