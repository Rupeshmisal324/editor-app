package com.intoactive.app.mediaeditor

import android.graphics.PointF
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import kotlin.math.abs
import kotlin.math.atan2

/**
 * Pan + pinch-zoom + two-finger rotate for a set of independently
 * manipulable layers (the background image, each text/sticker layer),
 * applied to a layer via its built-in scaleX/scaleY/translationX/
 * translationY/rotation. Also detects a long-press-without-movement on a
 * layer as its delete affordance (see onLayerLongPressed).
 *
 * Must be attached (via setOnTouchListener) to a STABLE ancestor that is
 * never itself transformed, not to a layer directly — once a view is
 * rotated/scaled, touches reported ON it are in its own distorted local
 * frame.
 *
 * On ACTION_DOWN this hit-tests every registered layer (topmost/most-
 * recently-added first) by mapping the touch point through that layer's
 * CURRENT transform into its own pre-transform bounds, and drives every
 * following event in this gesture to whichever one it landed inside.
 */
internal class LayerGestureCoordinator(context: android.content.Context) : View.OnTouchListener {

  // Back-to-front; hit-testing walks in reverse so the most recently added
  // (topmost) layer wins when layers overlap.
  private val layers = mutableListOf<View>()

  fun addLayer(view: View) {
    layers.add(view)
  }

  /** Fired when a registered layer is held without moving past the slop. */
  var onLayerLongPressed: ((View) -> Unit)? = null

  /**
   * Fired on a plain tap (down+up, no drag/pinch/rotate, no long-press
   * fired) — `null` means the tap landed outside every registered layer
   * (empty canvas margin, or the canvas layer itself if the caller excludes
   * it) and should be read as "deselect." Drives the on-canvas layer action
   * toolbar (Delete/Duplicate/Edit).
   */
  var onLayerTapped: ((View?) -> Unit)? = null

  /**
   * Fired every time a registered layer's pan/pinch/rotate mutates its
   * transform — lets the caller keep a floating UI element (the layer
   * action toolbar) tracking the layer's live on-screen position during a
   * drag, rather than only repositioning once the gesture ends.
   */
  var onLayerTransformed: ((View) -> Unit)? = null

  /** A layer's translation/scale/rotation at one point in time — used only
   *  to snapshot/restore for undo/redo (see [onLayerTransformCommitted]). */
  data class TransformSnapshot(
    val translationX: Float,
    val translationY: Float,
    val scaleX: Float,
    val scaleY: Float,
    val rotation: Float,
  )

  /**
   * Fired once per physical touch gesture that actually changed a layer's
   * transform (drag, pinch, and/or rotate — however many of those a single
   * gesture combined), with the before/after snapshot, so the caller can
   * push exactly one undo/redo entry per gesture rather than one per
   * ACTION_MOVE tick.
   */
  var onLayerTransformCommitted: ((target: View, old: TransformSnapshot, new: TransformSnapshot) -> Unit)? = null

  private fun snapshotOf(view: View) = TransformSnapshot(view.translationX, view.translationY, view.scaleX, view.scaleY, view.rotation)

  private var transformSnapshotAtDown: TransformSnapshot? = null

  private fun commitTransformIfChanged() {
    val target = activeTarget ?: return
    val old = transformSnapshotAtDown ?: return
    transformSnapshotAtDown = null
    val new = snapshotOf(target)
    if (new != old) onLayerTransformCommitted?.invoke(target, old, new)
  }

  private var hadMultiTouch = false
  private var longPressFired = false

  /**
   * The canvas layer (the background image or video, set by the caller
   * right after registering it via [addLayer]) — pan/zoom on THIS layer
   * only is clamped so it never reveals empty space around its own
   * original bounds, per the user's explicit "image should never go out
   * of bounds" request. Text/sticker layers are deliberately NOT bounded
   * this way — they're free-floating decoration, not the canvas itself.
   */
  var boundedLayer: View? = null

  /**
   * While set, [hitTest] skips this exact layer — used to lock the base
   * canvas (image/video) out of pan/pinch/rotate while a text/sticker/
   * overlay layer is selected, per the user's explicit request: dragging a
   * newly-added element shouldn't ever accidentally also move/zoom/rotate
   * the photo underneath. A touch that would have landed on the locked
   * layer now hits nothing (`hitTest` returns null), which the caller's
   * `onLayerTapped` already treats as "deselect" — so tapping the canvas
   * to deselect still works unchanged while locked.
   */
  var interactionLockedLayer: View? = null

  /**
   * The currently-selected layer, if any — set by the caller alongside
   * [interactionLockedLayer]. When a touch's raw hit-test misses every
   * registered layer, [activeTarget] falls back to THIS instead of null,
   * so pan/pinch/rotate keep controlling the selected layer even when the
   * user's fingers land outside its current (possibly tiny, especially
   * after a big pinch-to-shrink) visual bounds — matching Instagram's own
   * "once selected, drag/pinch anywhere to keep manipulating it" model,
   * per the user's explicit request. Deliberately NOT used for the tap-to-
   * select/deselect report (see [rawHitTarget]) — tapping truly empty
   * space must still deselect even while this fallback is set.
   */
  var fallbackTarget: View? = null

  /** Per-layer lock: a locked layer can still be tapped (to select it) but
   *  never moved, scaled or rotated. */
  var isLayerTransformLocked: ((View) -> Boolean)? = null

  /** Snap guides: which guides the dragged layer is on (empty when the
   *  drag ends). The activity draws them and plays a light haptic. */
  var onSnapChanged: ((LayerSnapState) -> Unit)? = null
  /** The finger's UNSNAPPED translation during a one-finger drag, so a
   *  snapped layer pulls free again once the finger moves on. */
  private var rawDragX = 0f
  private var rawDragY = 0f
  private var lastSnapState = LayerSnapState.NONE

  /** Per-layer hide: a hidden layer is invisible, so touches pass through it. */
  var isLayerHitExcluded: ((View) -> Boolean)? = null

  private var activeTarget: View? = null
  /** The RAW hit-test result at ACTION_DOWN (no fallback applied) — used
   *  only for tap reporting, so a tap on genuinely empty space still
   *  deselects even while [fallbackTarget] is set. */
  private var rawHitTarget: View? = null

  private val longPressHandler = Handler(Looper.getMainLooper())
  private var pendingLongPress: Runnable? = null
  private var downX = 0f
  private var downY = 0f

  private val scaleDetector = ScaleGestureDetector(
    context,
    object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
      override fun onScale(detector: ScaleGestureDetector): Boolean {
        val target = activeTarget ?: return false
        if (isLayerTransformLocked?.invoke(target) == true) return true
        // 1.0 (not the shared MIN_SCALE) for the canvas layer specifically
        // — its original bounds already exactly match the photo/video's
        // own aspect ratio, so scale 1.0 is already "fills the box";
        // anything smaller would reveal empty space around it.
        val minScale = if (target === boundedLayer) MIN_BOUNDED_SCALE else MIN_SCALE
        val proposed = target.scaleX * detector.scaleFactor
        val clamped = proposed.coerceIn(minScale, MAX_SCALE)
        target.scaleX = clamped
        target.scaleY = clamped
        clampBoundedTranslation(target)
        clampLayerWithinImageBounds(target)
        onLayerTransformed?.invoke(target)
        return true
      }
    },
  )

  private var lastX = 0f
  private var lastY = 0f
  private var lastAngle = 0f

  override fun onTouch(v: View, event: MotionEvent): Boolean {
    scaleDetector.onTouchEvent(event)

    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        rawHitTarget = hitTest(event.getX(0), event.getY(0))
        activeTarget = rawHitTarget ?: fallbackTarget
        transformSnapshotAtDown = activeTarget?.let { snapshotOf(it) }
        activeTarget?.let { rawDragX = it.translationX; rawDragY = it.translationY }
        lastX = event.getX(0)
        lastY = event.getY(0)
        downX = event.getX(0)
        downY = event.getY(0)
        hadMultiTouch = false
        longPressFired = false
        scheduleLongPress()
      }
      MotionEvent.ACTION_POINTER_DOWN -> {
        cancelPendingLongPress()
        reportSnap(LayerSnapState.NONE)
        hadMultiTouch = true
        if (event.pointerCount == 2) {
          lastAngle = angleBetween(event)
        }
      }
      MotionEvent.ACTION_MOVE -> {
        if (abs(event.getX(0) - downX) > LONG_PRESS_SLOP_PX || abs(event.getY(0) - downY) > LONG_PRESS_SLOP_PX) {
          cancelPendingLongPress()
        }
        val target = activeTarget ?: return true
        if (isLayerTransformLocked?.invoke(target) == true) return true
        if (event.pointerCount == 1) {
          rawDragX += event.getX(0) - lastX
          rawDragY += event.getY(0) - lastY
          target.translationX = rawDragX
          target.translationY = rawDragY
          lastX = event.getX(0)
          lastY = event.getY(0)
          clampBoundedTranslation(target)
          clampLayerWithinImageBounds(target)
          // Clamped too, so dragging back from past an edge responds at once.
          rawDragX = target.translationX
          rawDragY = target.translationY
          if (target !== boundedLayer) applySnap(target)
          onLayerTransformed?.invoke(target)
        } else if (event.pointerCount >= 2) {
          val angle = angleBetween(event)
          target.rotation += angle - lastAngle
          lastAngle = angle
          onLayerTransformed?.invoke(target)
        }
      }
      MotionEvent.ACTION_POINTER_UP -> {
        if (event.pointerCount == 2) {
          val remainingIndex = if (event.actionIndex == 0) 1 else 0
          lastX = event.getX(remainingIndex)
          lastY = event.getY(remainingIndex)
        }
      }
      MotionEvent.ACTION_UP -> {
        cancelPendingLongPress()
        val moved = abs(event.getX(0) - downX) > LONG_PRESS_SLOP_PX || abs(event.getY(0) - downY) > LONG_PRESS_SLOP_PX
        if (!hadMultiTouch && !moved && !longPressFired) {
          // Uses the RAW hit-test, not activeTarget (which may have used
          // the fallback) — a tap on genuinely empty space must still
          // deselect even while a layer is selected.
          onLayerTapped?.invoke(rawHitTarget)
        }
        commitTransformIfChanged()
        activeTarget = null
        reportSnap(LayerSnapState.NONE)
      }
      MotionEvent.ACTION_CANCEL -> {
        cancelPendingLongPress()
        commitTransformIfChanged()
        activeTarget = null
        reportSnap(LayerSnapState.NONE)
      }
    }
    return true
  }

  /**
   * At [target]'s current scale, the maximum offset in either axis before
   * an edge would recede past the layer's own original bounds (revealing
   * empty space) is `size * (scale - 1) / 2`. Ignores `rotation`
   * deliberately — bounding a rotated rectangle's coverage is a
   * materially bigger geometry problem, and rotation wasn't part of what
   * was asked for. No-op for anything other than [boundedLayer].
   */
  private fun clampBoundedTranslation(target: View) {
    if (target !== boundedLayer) return
    val maxOffsetX = target.width * (target.scaleX - 1f) / 2f
    val maxOffsetY = target.height * (target.scaleY - 1f) / 2f
    target.translationX = target.translationX.coerceIn(-maxOffsetX, maxOffsetX)
    target.translationY = target.translationY.coerceIn(-maxOffsetY, maxOffsetY)
  }

  /**
   * Clamps a non-canvas layer's (text/sticker/overlay) translation so its
   * own on-screen bounds never cross outside [boundedLayer]'s (the base
   * image/video's) fixed layout rect — per the user's explicit request
   * that nothing added on top of the photo should be draggable/resizable
   * outside the photo itself. [boundedLayer]'s left/top/width/height are
   * its LAYOUT bounds (set once, never touched again — see
   * MediaEditorActivity.layoutImageCanvas), not affected by its own
   * translationX/scaleX, so they're a stable rect to clamp against. Every
   * registered layer is a direct child of the same parent (`root`,
   * added with Gravity.CENTER), so `target.translationX == 0` means
   * exactly that parent's center — same convention this method relies on
   * to compute a layer's live on-screen center.
   *
   * Ignores `rotation` for the same reason clampBoundedTranslation does —
   * bounding a rotated rectangle's coverage is a materially bigger
   * geometry problem — using the layer's un-rotated scaled bounding box.
   */
  private fun clampLayerWithinImageBounds(target: View) {
    val bounds = boundedLayer ?: return
    if (target === bounds) return
    val parent = target.parent as? View ?: return

    val halfWidth = target.width * target.scaleX / 2f
    val halfHeight = target.height * target.scaleY / 2f
    val centerX = parent.width / 2f + target.translationX
    val centerY = parent.height / 2f + target.translationY

    val minCenterX = bounds.left + halfWidth
    val maxCenterX = bounds.left + bounds.width - halfWidth
    val clampedCenterX = if (minCenterX <= maxCenterX) centerX.coerceIn(minCenterX, maxCenterX) else bounds.left + bounds.width / 2f

    val minCenterY = bounds.top + halfHeight
    val maxCenterY = bounds.top + bounds.height - halfHeight
    val clampedCenterY = if (minCenterY <= maxCenterY) centerY.coerceIn(minCenterY, maxCenterY) else bounds.top + bounds.height / 2f

    target.translationX = clampedCenterX - parent.width / 2f
    target.translationY = clampedCenterY - parent.height / 2f
  }

  /** Snaps the dragged layer's center to the canvas center lines and its
   *  (unrotated, scaled) edges to a safe margin inside the canvas, within
   *  SNAP_THRESHOLD_DP. Same rules as iOS LayerSnapper. */
  private fun applySnap(target: View) {
    val bounds = boundedLayer ?: return
    val parent = target.parent as? View ?: return
    val density = target.resources.displayMetrics.density
    val threshold = SNAP_THRESHOLD_DP * density
    val margin = SNAP_EDGE_MARGIN_DP * density
    val halfW = target.width * target.scaleX / 2f
    val halfH = target.height * target.scaleY / 2f
    val baseX = parent.width / 2f
    val baseY = parent.height / 2f
    val cx = baseX + target.translationX
    val cy = baseY + target.translationY
    val left = bounds.left.toFloat()
    val top = bounds.top.toFloat()
    val right = left + bounds.width
    val bottom = top + bounds.height
    val midX = (left + right) / 2f
    val midY = (top + bottom) / 2f
    var state = LayerSnapState.NONE
    when {
      abs(cx - midX) <= threshold -> { target.translationX = midX - baseX; state = state.copy(centerX = true) }
      abs((cx - halfW) - (left + margin)) <= threshold -> { target.translationX = left + margin + halfW - baseX; state = state.copy(left = true) }
      abs((cx + halfW) - (right - margin)) <= threshold -> { target.translationX = right - margin - halfW - baseX; state = state.copy(right = true) }
    }
    when {
      abs(cy - midY) <= threshold -> { target.translationY = midY - baseY; state = state.copy(centerY = true) }
      abs((cy - halfH) - (top + margin)) <= threshold -> { target.translationY = top + margin + halfH - baseY; state = state.copy(top = true) }
      abs((cy + halfH) - (bottom - margin)) <= threshold -> { target.translationY = bottom - margin - halfH - baseY; state = state.copy(bottom = true) }
    }
    reportSnap(state)
  }

  private fun reportSnap(state: LayerSnapState) {
    if (state == lastSnapState) return
    lastSnapState = state
    onSnapChanged?.invoke(state)
  }

  private fun scheduleLongPress() {
    // Same reasoning as the tap report — long-pressing genuinely empty
    // space shouldn't trigger delete-confirm for an unrelated selected
    // layer just because it's the pan/pinch fallback target.
    val target = rawHitTarget ?: return
    val runnable = Runnable {
      longPressFired = true
      onLayerLongPressed?.invoke(target)
    }
    pendingLongPress = runnable
    longPressHandler.postDelayed(runnable, LONG_PRESS_TIMEOUT_MS)
  }

  private fun cancelPendingLongPress() {
    pendingLongPress?.let { longPressHandler.removeCallbacks(it) }
    pendingLongPress = null
  }

  private fun hitTest(x: Float, y: Float): View? {
    for (layer in layers.asReversed()) {
      if (layer.visibility != View.VISIBLE) continue
      if (layer === interactionLockedLayer) continue
      if (isLayerHitExcluded?.invoke(layer) == true) continue
      val local = toLocal(layer, x, y)
      if (local.x in 0f..layer.width.toFloat() && local.y in 0f..layer.height.toFloat()) {
        return layer
      }
    }
    return null
  }

  /**
   * Maps a point from the coordinator's (untransformed) coordinate space
   * into layer's own pre-transform local space — i.e. undoes layer's
   * current translation, rotation, and scale, in that reverse order.
   * Computed directly rather than via View.getMatrix() to avoid relying on
   * exactly which properties that matrix does or doesn't already include.
   */
  private fun toLocal(layer: View, x: Float, y: Float): PointF {
    val centerX = layer.left + layer.translationX + layer.width / 2f
    val centerY = layer.top + layer.translationY + layer.height / 2f
    val dx = x - centerX
    val dy = y - centerY

    val rad = Math.toRadians(-layer.rotation.toDouble())
    val cos = Math.cos(rad).toFloat()
    val sin = Math.sin(rad).toFloat()
    val unrotatedX = dx * cos - dy * sin
    val unrotatedY = dx * sin + dy * cos

    val scaleX = if (layer.scaleX == 0f) 1f else layer.scaleX
    val scaleY = if (layer.scaleY == 0f) 1f else layer.scaleY

    return PointF(
      unrotatedX / scaleX + layer.width / 2f,
      unrotatedY / scaleY + layer.height / 2f,
    )
  }

  private fun angleBetween(event: MotionEvent): Float {
    val dx = event.getX(1) - event.getX(0)
    val dy = event.getY(1) - event.getY(0)
    return Math.toDegrees(atan2(dy.toDouble(), dx.toDouble())).toFloat()
  }

  companion object {
    // Lowered from 0.3 per the user's explicit request — 0.3 didn't let a
    // text/sticker/overlay layer shrink small enough.
    private const val MIN_SCALE = 0.1f
    private const val MIN_BOUNDED_SCALE = 1f
    private const val MAX_SCALE = 6f
    private const val LONG_PRESS_TIMEOUT_MS = 500L
    private const val LONG_PRESS_SLOP_PX = 20f
  }
}

/** Which snap guides a dragged layer is on (see LayerGestureCoordinator.applySnap). */
internal data class LayerSnapState(
  val centerX: Boolean = false,
  val centerY: Boolean = false,
  val left: Boolean = false,
  val right: Boolean = false,
  val top: Boolean = false,
  val bottom: Boolean = false,
) {
  val isEmpty: Boolean get() = this == NONE
  companion object { val NONE = LayerSnapState() }
}

internal const val SNAP_THRESHOLD_DP = 8f
internal const val SNAP_EDGE_MARGIN_DP = 16f
