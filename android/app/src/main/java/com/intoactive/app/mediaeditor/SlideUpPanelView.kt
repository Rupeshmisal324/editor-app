package com.intoactive.app.mediaeditor

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewGroup
import android.view.animation.AnimationUtils
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.min

/**
 * Generic reusable slide-up contextual panel shell — mirrors iOS's
 * SlideUpPanelView. Drag handle + title/confirm header + a content slot
 * ([contentContainer]) that per-tool content plugs into (today: the
 * Effects tab's filter row + adjustment sliders). UI-only — this view has
 * no knowledge of filters/crop/text/stickers, it only hosts them.
 *
 * Collapsed height is fixed (EditorDesignTokens.SpacingDp.panelCollapsedHeight);
 * dragging the handle expands it up to
 * EditorDesignTokens.PANEL_EXPANDED_HEIGHT_FRACTION of the screen height.
 * Expanding OVERLAYS the canvas rather than resizing it — the canvas box
 * is sized once from the photo's own aspect ratio (see
 * MediaEditorActivity's layoutImageCanvas) and must stay geometrically
 * stable for CropOverlayView's one-time crop-rect initialization to stay
 * correct, so nothing about this panel's height ever feeds back into the
 * canvas's own layout.
 */
/**
 * [collapsedHeightDp] defaults to the standard token (Sticker/Draw/Music's
 * content all needs that much room) but is overridable — the Effect/Edit
 * panels' content (a filter row / an adjustment icon row) is much more
 * compact, and using the standard height for those would leave a large
 * dead empty area below their actual content.
 */
class SlideUpPanelView(
  context: Context,
  title: String,
  collapsedHeightDp: Float = EditorDesignTokens.SpacingDp.panelCollapsedHeight,
) : LinearLayout(context) {

  val contentContainer = FrameLayout(context)
  var onConfirm: (() -> Unit)? = null

  /** Redesign Phase 5: ✕ in the header, left of the title — shown only
   *  when set (cancel = put the tool's changes back). Same as iOS. */
  var onCancel: (() -> Unit)? = null
    set(value) {
      field = value
      cancelButtonView?.visibility = if (value == null) View.GONE else View.VISIBLE
      (titleTextView?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
        params.leftMargin = ((if (value == null) 16f else 44f) * resources.displayMetrics.density).toInt()
        titleTextView?.layoutParams = params
      }
    }
  private var cancelButtonView: View? = null
  private var confirmTextView: View? = null
  private var confirmCloseIconView: View? = null

  /** Mockup Tools sheet: a ✕ in place of "Done" (same action: close). */
  fun useCloseIconForConfirm() {
    confirmTextView?.visibility = View.GONE
    confirmCloseIconView?.visibility = View.VISIBLE
  }
  private var titleTextView: View? = null
  private var handleBandView: View? = null
  private var headerRowView: View? = null
  private var barTitleView: TextView? = null
  /** Mockup Filters / Text sheets: header moved to a bottom bar — this is
   *  the extra height that adds (bar + nav bar − old header/padding). */
  private var bottomBarExtraPx = 0

  /** Mockup Filters / Text sheet: no handle or header; a bottom bar with
   *  ✕ (onCancel) · title [· accessory icon] · ✓ (onConfirm) instead.
   *  [bottomInsetPx] = navigation bar height (the bar sits above it). */
  fun useBottomActionBar(
    title: String,
    bottomInsetPx: Int,
    accessoryIcon: EditorIcon? = null,
    accessoryLabel: String? = null,
    onAccessory: (() -> Unit)? = null,
  ) {
    if (bottomBarExtraPx != 0) return
    handleBandView?.visibility = View.GONE
    headerRowView?.visibility = View.GONE
    (contentContainer.layoutParams as LayoutParams).apply {
      topMargin = (12f * density).toInt()
      bottomMargin = (4f * density).toInt()
    }
    val iconPx = (48f * density).toInt()
    fun icon(kind: EditorIcon, label: String, tint: Int, onClick: () -> Unit) =
      EditorIconView(context, kind).apply {
        contentDescription = label
        iconTint = tint
        val pad = (12f * density).toInt()
        setPadding(pad, pad, pad, pad)
        setOnClickListener { onClick() }
      }
    val titleView = TextView(context).apply {
      text = title
      textSize = 15f
      typeface = Typeface.DEFAULT_BOLD
      setTextColor(EditorDesignTokens.Colors.textPrimary)
    }
    barTitleView = titleView
    val center = LinearLayout(context).apply {
      orientation = HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      addView(titleView)
      if (accessoryIcon != null) {
        addView(
          icon(accessoryIcon, accessoryLabel ?: title, EditorDesignTokens.Colors.textPrimary) { onAccessory?.invoke() },
          LayoutParams(iconPx, iconPx).apply { marginStart = (6f * density).toInt() },
        )
      }
    }
    val barContentPx = (64f * density).toInt()
    val bar = FrameLayout(context).apply {
      setPadding(0, 0, 0, bottomInsetPx)
      addView(View(context).apply { setBackgroundColor(EditorDesignTokens.Colors.divider) },
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, density.toInt().coerceAtLeast(1), Gravity.TOP))
      addView(icon(EditorIcon.CLOSE, "Cancel $title", EditorDesignTokens.Colors.textPrimary) { onCancel?.invoke() },
        FrameLayout.LayoutParams(iconPx, iconPx, Gravity.START or Gravity.CENTER_VERTICAL).apply { leftMargin = (8f * density).toInt() })
      addView(center, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
      addView(icon(EditorIcon.CHECK, "Apply $title", EditorDesignTokens.Colors.selectedToolTint) { onConfirm?.invoke() },
        FrameLayout.LayoutParams(iconPx, iconPx, Gravity.END or Gravity.CENTER_VERTICAL).apply { rightMargin = (8f * density).toInt() })
    }
    addView(bar, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, barContentPx + bottomInsetPx))
    // New: 12 top + 4 + 64 bar + inset. Old: 17 handle + 28 header + 12.
    bottomBarExtraPx = ((12f + 4f + 64f - 17f - 28f - 12f) * density).toInt() + bottomInsetPx
    if (expandedHeightPx == collapsedHeightPx) expandedHeightPx += bottomBarExtraPx
    collapsedHeightPx += bottomBarExtraPx
    layoutParams = layoutParams.apply { height = collapsedHeightPx }
  }

  /** Bottom-bar title (e.g. "Text" / "Overlay" / "Sticker"). */
  fun setBarTitle(title: String) {
    barTitleView?.text = title
  }

  private val density = resources.displayMetrics.density
  private var collapsedHeightPx = EditorDesignTokens.dpToPx(collapsedHeightDp, density)

  /** Height when not dragged open — what the picture above must fit around. */
  val restingHeightPx: Int get() = collapsedHeightPx
  private var heightAnimator: ValueAnimator? = null
  private var expandedHeightPx = collapsedHeightPx
  private var dragStartHeightPx = collapsedHeightPx
  private var dragStartRawY = 0f

  init {
    orientation = VERTICAL
    background = GradientDrawable().apply {
      setColor(EditorDesignTokens.Colors.panelBackground)
      val radiusPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.panelCornerRadius, density).toFloat()
      cornerRadii = floatArrayOf(radiusPx, radiusPx, radiusPx, radiusPx, 0f, 0f, 0f, 0f)
    }

    val handleWidthPx = (36f * density).toInt()
    val handleHeightPx = (5f * density).toInt()
    val handle = View(context).apply {
      background = GradientDrawable().apply {
        setColor(EditorDesignTokens.Colors.divider)
        cornerRadius = handleHeightPx / 2f
      }
    }
    val handleBand = FrameLayout(context).apply {
      addView(handle, FrameLayout.LayoutParams(handleWidthPx, handleHeightPx, Gravity.CENTER))
    }
    // Compact header (45dp: 17 handle band + 28 title row) — same as iOS.
    addView(handleBand, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (17f * density).toInt()))
    handleBandView = handleBand

    val titleView = TextView(context).apply {
      text = title
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      textSize = EditorDesignTokens.TypeSizesSp.panelTitle
    }
    val tapTargetPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.minTapTarget, density)
    // Text "Done" (not a checkmark icon) per the user's explicit request —
    // reads more clearly as "finish and close this panel" than a bare glyph.
    val confirmButton = TextView(context).apply {
      text = "Done"
      // Matches the top bar's Cancel/Done/Undo/Redo (all textPrimary/
      // white) per the user's explicit "use same color of cancel and done
      // and undo and redo" request — was the editor's own accent purple,
      // visually inconsistent with every other Done/Cancel control.
      setTextColor(EditorDesignTokens.Colors.selectedToolTint)
      textSize = 16f
      setTypeface(typeface, Typeface.BOLD)
      gravity = Gravity.CENTER
      setPadding((16f * density).toInt(), 0, 0, 0)
      setOnClickListener { onConfirm?.invoke() }
    }
    titleTextView = titleView
    confirmTextView = confirmButton
    val closeIcon = EditorIconView(context, EditorIcon.CLOSE).apply {
      contentDescription = "Close"
      visibility = View.GONE
      val pad = (3f * density).toInt()
      setPadding(pad, pad, pad, pad)
      setOnClickListener { onConfirm?.invoke() }
    }
    confirmCloseIconView = closeIcon
    val cancelView = EditorIconView(context, EditorIcon.CLOSE).apply {
      contentDescription = "Cancel"
      visibility = View.GONE
      val pad = (3f * density).toInt()
      setPadding(pad, pad, pad, pad)
      setOnClickListener { onCancel?.invoke() }
    }
    cancelButtonView = cancelView
    val headerRow = FrameLayout(context).apply {
      addView(
        closeIcon,
        FrameLayout.LayoutParams((28f * density).toInt(), (28f * density).toInt(), Gravity.CENTER_VERTICAL or Gravity.END).apply {
          rightMargin = (12f * density).toInt()
        },
      )
      addView(
        cancelView,
        // Fits the 28dp header row (taller would be clipped).
        FrameLayout.LayoutParams((28f * density).toInt(), (28f * density).toInt(), Gravity.CENTER_VERTICAL or Gravity.START).apply {
          leftMargin = (12f * density).toInt()
        },
      )
      addView(
        titleView,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL or Gravity.START).apply {
          leftMargin = (16f * density).toInt()
        },
      )
      addView(
        confirmButton,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER_VERTICAL or Gravity.END).apply {
          rightMargin = (16f * density).toInt()
        },
      )
    }
    addView(headerRow, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (28f * density).toInt()))
    headerRowView = headerRow

    addView(contentContainer, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f).apply {
      bottomMargin = (12f * density).toInt()
    })

    layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, collapsedHeightPx)

    // Drag on the header (handle + title row; Done keeps its own taps):
    // up expands (panels that allow it), down past the collapsed height
    // slides the panel away and closes it like Done.
    val dragListener = View.OnTouchListener { _, event ->
      when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
          dragStartRawY = event.rawY
          dragStartHeightPx = layoutParams.height
          velocityTracker?.recycle()
          velocityTracker = VelocityTracker.obtain().apply { addMovement(event) }
          true
        }
        MotionEvent.ACTION_MOVE -> {
          velocityTracker?.addMovement(event)
          val newHeight = (dragStartHeightPx + (dragStartRawY - event.rawY)).toInt()
          if (newHeight >= collapsedHeightPx) {
            translationY = 0f
            layoutParams = layoutParams.apply { height = min(newHeight, expandedHeightPx) }
          } else {
            if (layoutParams.height != collapsedHeightPx) layoutParams = layoutParams.apply { height = collapsedHeightPx }
            translationY = (collapsedHeightPx - newHeight).toFloat()
          }
          true
        }
        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
          val tracker = velocityTracker
          tracker?.addMovement(event)
          tracker?.computeCurrentVelocity(1000)
          val velocityY = tracker?.yVelocity ?: 0f
          tracker?.recycle()
          velocityTracker = null
          val pulledDown = translationY
          if (pulledDown > 0f) {
            if (event.actionMasked == MotionEvent.ACTION_UP && (pulledDown > 70f * density || velocityY > 700f * density)) {
              dismissByDrag()
            } else {
              animate().translationY(0f)
                .setDuration(EditorDesignTokens.MotionMs.panelToggleDuration.toLong())
                .start()
            }
          } else {
            val expand = layoutParams.height > (collapsedHeightPx + expandedHeightPx) / 2
            setExpanded(expand, animated = true)
          }
          true
        }
        else -> false
      }
    }
    handleBand.setOnTouchListener(dragListener)
    headerRow.setOnTouchListener(dragListener)
  }

  private var velocityTracker: VelocityTracker? = null

  /** Called when the panel is dragged down to close. Defaults to Done's action. */
  var onDismissByDrag: (() -> Unit)? = null

  private fun dismissByDrag() {
    animate()
      .translationY(height.toFloat())
      .setDuration(EditorDesignTokens.MotionMs.panelToggleDuration.toLong())
      .setInterpolator(AnimationUtils.loadInterpolator(context, android.R.interpolator.fast_out_linear_in))
      .withEndAction {
        visibility = View.INVISIBLE
        alpha = 0f
        translationY = 0f
        setExpanded(false, animated = false)
        (onDismissByDrag ?: onConfirm)?.invoke()
      }
      .start()
  }

  /** Called once (onCreate) — the expanded height is a fraction of the
   *  SCREEN, not this view's own bounds, which aren't meaningfully
   *  resolved yet at that point anyway. */
  fun configureExpandedHeight(screenHeightPx: Int) {
    expandedHeightPx = (screenHeightPx * EditorDesignTokens.PANEL_EXPANDED_HEIGHT_FRACTION).toInt()
  }

  /** Changes the collapsed height after construction (e.g. the Filters
   *  panel growing when its slider rows appear). A panel that can't be
   *  dragged taller keeps expanded == collapsed. */
  fun setCollapsedHeightDp(heightDp: Float, animated: Boolean) {
    val newHeightPx = EditorDesignTokens.dpToPx(heightDp, density) + bottomBarExtraPx
    if (newHeightPx == collapsedHeightPx) return
    val wasCollapsed = layoutParams.height <= collapsedHeightPx
    if (expandedHeightPx == collapsedHeightPx) expandedHeightPx = newHeightPx
    collapsedHeightPx = newHeightPx
    if (wasCollapsed) setExpanded(false, animated && visibility == View.VISIBLE)
  }

  fun setExpanded(expanded: Boolean, animated: Boolean) {
    val targetHeightPx = if (expanded) expandedHeightPx else collapsedHeightPx
    heightAnimator?.cancel()
    heightAnimator = null
    if (!animated) {
      layoutParams = layoutParams.apply { height = targetHeightPx }
      return
    }
    heightAnimator = ValueAnimator.ofInt(layoutParams.height, targetHeightPx).apply {
      duration = EditorDesignTokens.MotionMs.panelToggleDuration.toLong()
      interpolator = AnimationUtils.loadInterpolator(context, android.R.interpolator.fast_out_slow_in)
      addUpdateListener { animator -> layoutParams = layoutParams.apply { height = animator.animatedValue as Int } }
      start()
    }
  }

  /** Show/hide with a slide+fade, distinct from [setExpanded]'s height
   *  resize — this is the panel appearing/disappearing entirely (switching
   *  tabs), not the drag-to-expand interaction. */
  fun setPanelVisible(visible: Boolean, animated: Boolean) {
    val slideDistancePx = 24f * density
    if (visible) {
      visibility = View.VISIBLE
      if (!animated) {
        alpha = 1f
        translationY = 0f
        return
      }
      alpha = 0f
      translationY = slideDistancePx
      animate().alpha(1f).translationY(0f)
        .setDuration(EditorDesignTokens.MotionMs.panelToggleDuration.toLong())
        .setInterpolator(AnimationUtils.loadInterpolator(context, android.R.interpolator.fast_out_slow_in))
        .start()
    } else {
      if (!animated) {
        visibility = View.INVISIBLE
        return
      }
      animate()
        .alpha(0f)
        .translationY(slideDistancePx)
        .setDuration(EditorDesignTokens.MotionMs.panelToggleDuration.toLong())
        .setInterpolator(AnimationUtils.loadInterpolator(context, android.R.interpolator.fast_out_slow_in))
        .withEndAction {
          visibility = View.INVISIBLE
          translationY = 0f
          setExpanded(false, animated = false)
        }
        .start()
    }
  }
}
