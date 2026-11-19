package com.intoactive.app.mediaeditor

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Floating frosted capsule behind the tool row — the same recipe as iOS
 * (pre-26) and the reference NavBarCapsuleView:
 *  - material: a blurred snapshot of what's behind ([backdrop]), the
 *    Android stand-in for the system's thin blur;
 *  - a light dark wash over it (black 15%);
 *  - a 0.5dp hairline rim (white 12%);
 *  - a soft drop shadow (the view's elevation, via [outlineProvider]).
 * The capsule is inset from the drawable's bounds by [insetH]/[insetV].
 */
internal class GlassCapsuleDrawable(density: Float) : Drawable() {
  val insetH = 12f * density
  // Taller capsule (70dp in the 76dp row).
  val insetV = 3f * density
  private val rimWidth = (0.5f * density).coerceAtLeast(1f)

  var backdrop: Bitmap? = null
    set(value) {
      field = value
      invalidateSelf()
    }

  val capsule = RectF()
  private val path = Path()
  private val backdropPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
    // System materials lift saturation a little.
    colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(1.2f) })
  }
  private val washPaint = Paint(Paint.ANTI_ALIAS_FLAG)
  private val rimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = rimWidth
    color = Color.argb(31, 255, 255, 255)
  }

  override fun onBoundsChange(bounds: android.graphics.Rect) {
    super.onBoundsChange(bounds)
    capsule.set(bounds.left + insetH, bounds.top + insetV, bounds.right - insetH, bounds.bottom - insetV)
    val r = capsule.height() / 2f
    path.reset()
    path.addRoundRect(capsule, r, r, Path.Direction.CW)
  }

  override fun draw(canvas: Canvas) {
    if (capsule.isEmpty) return
    val r = capsule.height() / 2f
    canvas.save()
    canvas.clipPath(path)
    val bmp = backdrop
    if (bmp != null && !bmp.isRecycled) canvas.drawBitmap(bmp, null, capsule, backdropPaint)
    // Wash: black 15% over the frost; a solid dark frost until a backdrop exists.
    washPaint.color = if (bmp != null) Color.argb(38, 0, 0, 0) else Color.argb(200, 30, 31, 35)
    canvas.drawRoundRect(capsule, r, r, washPaint)
    canvas.restore()
    val half = rimWidth / 2f
    canvas.drawRoundRect(capsule.left + half, capsule.top + half, capsule.right - half, capsule.bottom - half, r - half, r - half, rimPaint)
  }

  /** Outline for the soft elevation shadow: the capsule only. */
  fun outlineProvider(): ViewOutlineProvider = object : ViewOutlineProvider() {
    override fun getOutline(view: View, outline: Outline) {
      val w = view.width
      val h = view.height
      val l = insetH.toInt()
      val t = insetV.toInt()
      outline.setRoundRect(l, t, w - l, h - t, (h - 2 * t) / 2f)
      outline.alpha = 0.3f
    }
  }

  override fun setAlpha(alpha: Int) {}
  override fun setColorFilter(colorFilter: ColorFilter?) {}
  @Deprecated("Deprecated in Java")
  override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}

/**
 * The tool row inside the capsule, plus the selected-tool lozenge (a soft
 * light pill, white 12%) that slides between tools on a light spring
 * (0.35s response, 0.8 damping — the system bar's feel; same as iOS).
 * A quick second tap redirects the slide from where the lozenge visibly is.
 * Sliding a finger along the row drags the lozenge (slightly enlarged while
 * held, like the iOS tab bar); lifting picks the tool underneath.
 */
internal class ToolGlassRow(context: Context, private val glass: GlassCapsuleDrawable) : FrameLayout(context) {
  private val density = resources.displayMetrics.density
  private val lozenge = View(context)
  private val lozengeFill = GradientDrawable().apply { setColor(Color.argb(31, 255, 255, 255)) }
  private var slide: ValueAnimator? = null

  /** The tool slots (direct children of [row]) the lozenge can sit on. */
  var slots: () -> List<View> = { emptyList() }
  /** Called with the slot under the finger when a drag ends. */
  var onPick: ((View) -> Unit)? = null
  private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
  private var downX = 0f
  private var downY = 0f
  private var dragging = false
  /** The row the slots live in (added after the lozenge, so it's on top). */
  var row: ViewGroup? = null
  private var target: View? = null

  init {
    lozenge.background = lozengeFill
    lozenge.visibility = View.INVISIBLE
    lozenge.isClickable = false
    lozenge.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    addView(lozenge, LayoutParams(0, 0, Gravity.TOP or Gravity.START))
  }

  /** Kept for callers; the lozenge doesn't draw the backdrop. */
  fun backdropChanged() {}

  /** The slot, inset 4dp from the capsule's top and bottom. */
  private fun lozengeHeight(): Int = (height - 2 * glass.insetV - 8f * density).toInt().coerceAtLeast(0)
  private fun lozengeX(slot: View): Float = (row?.left ?: 0) + slot.left + 1f * density
  private fun lozengeWidth(slot: View): Int = (slot.width - 2f * density).toInt().coerceAtLeast(0)

  private fun sizeLozenge(slot: View) {
    val w = lozengeWidth(slot)
    val h = lozengeHeight()
    val params = lozenge.layoutParams as LayoutParams
    if (params.width != w || params.height != h) {
      params.width = w
      params.height = h
      lozenge.layoutParams = params
    }
    lozengeFill.cornerRadius = h / 2f
    lozenge.translationY = (height - h) / 2f
  }

  override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
    super.onLayout(changed, left, top, right, bottom)
    // A relayout moves the slots: snap the lozenge to its slot again.
    val slot = target
    if (changed && slot != null && slide?.isRunning != true) {
      post {
        sizeLozenge(slot)
        lozenge.translationX = lozengeX(slot)
      }
    }
  }

  fun moveLens(slot: View?, animated: Boolean) {
    target = slot
    if (dragging) return
    if (slot == null) {
      slide?.cancel()
      lozenge.visibility = View.INVISIBLE
      return
    }
    if (slot.width == 0) {
      post { moveLens(target, animated) }
      return
    }
    sizeLozenge(slot)
    val to = lozengeX(slot)
    // Snap when not animating, or on the very first placement.
    if (!animated || lozenge.visibility != View.VISIBLE) {
      slide?.cancel()
      lozenge.translationX = to
      lozenge.visibility = View.VISIBLE
      return
    }
    if (lozenge.translationX == to && slide?.isRunning != true) return
    springTo(to)
  }

  private fun visibleSlots() = slots().filter { it.visibility == View.VISIBLE && it.width > 0 }

  private fun nearestSlot(x: Float): View? =
    visibleSlots().minByOrNull { abs(lozengeX(it) + lozengeWidth(it) / 2f - x) }

  /** Animates the lozenge to [to] on the spring, then runs [end]. */
  private fun springTo(to: Float, end: (() -> Unit)? = null) {
    slide?.cancel()
    val from = lozenge.translationX
    slide = ValueAnimator.ofFloat(0f, 1f).apply {
      duration = 600L
      interpolator = SpringInterpolator(response = 0.35f, damping = 0.8f, totalSeconds = 0.6f)
      addUpdateListener { lozenge.translationX = from + (to - from) * (it.animatedValue as Float) }
      if (end != null) {
        addListener(object : android.animation.AnimatorListenerAdapter() {
          override fun onAnimationEnd(animation: android.animation.Animator) = end()
        })
      }
      start()
    }
  }

  override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
    when (ev.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        downX = ev.x
        downY = ev.y
        dragging = false
        // The surrounding HorizontalScrollView must not take sideways drags.
        parent?.requestDisallowInterceptTouchEvent(true)
      }
      MotionEvent.ACTION_MOVE -> {
        val dx = ev.x - downX
        if (abs(dx) > touchSlop && abs(dx) > abs(ev.y - downY)) {
          beginDrag(ev.x)
          return true
        }
      }
    }
    return false
  }

  private fun beginDrag(x: Float) {
    val slot = nearestSlot(x) ?: return
    dragging = true
    performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    slide?.cancel()
    sizeLozenge(slot)
    if (lozenge.visibility != View.VISIBLE) {
      lozenge.translationX = lozengeX(slot)
      lozenge.visibility = View.VISIBLE
    }
    // Held: a little bigger.
    lozenge.animate().scaleX(1.08f).scaleY(1.08f).setDuration(160L).start()
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    if (!dragging) return super.onTouchEvent(event)
    when (event.actionMasked) {
      MotionEvent.ACTION_MOVE -> {
        val all = visibleSlots()
        val first = all.firstOrNull() ?: return true
        val w = lozengeWidth(first)
        lozenge.translationX = (event.x - w / 2f).coerceIn(lozengeX(first), lozengeX(all.last()))
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        dragging = false
        parent?.requestDisallowInterceptTouchEvent(false)
        lozenge.animate().scaleX(1f).scaleY(1f).setDuration(200L).start()
        val picked = if (event.actionMasked == MotionEvent.ACTION_UP) nearestSlot(lozenge.translationX + lozenge.width / 2f) else null
        if (picked != null && picked !== target) {
          performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          // Text / Overlay / Add Video don't stay selected: the lozenge goes
          // back to the open tool once the tool has been picked.
          springTo(lozengeX(picked)) { moveLens(target, animated = true) }
          onPick?.invoke(picked)
        } else {
          val back = target
          if (back != null) springTo(lozengeX(back)) else lozenge.visibility = View.INVISIBLE
        }
      }
    }
    return true
  }
}

/** Damped spring from 0 to 1 (unit mass): ω = 2π / response, ζ = damping. */
private class SpringInterpolator(response: Float, private val damping: Float, private val totalSeconds: Float) :
  android.view.animation.Interpolator {
  private val omega = 2f * PI.toFloat() / response
  private val omegaD = omega * sqrt(1f - damping * damping)

  override fun getInterpolation(input: Float): Float {
    if (input >= 1f) return 1f
    val t = input * totalSeconds
    val decay = exp(-damping * omega * t)
    return 1f - decay * (cos(omegaD * t) + (damping * omega / omegaD) * sin(omegaD * t))
  }
}
