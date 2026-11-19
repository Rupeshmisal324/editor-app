package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.Drawable
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.DrawableCompat
import com.editorapp.editor.R

/**
 * SVG-derived vector-drawable line icons for the image editor's top bar /
 * bottom tab bar / panels — replaces the previous hand-drawn Canvas/Paint
 * shapes (kept working for a long time, but the user explicitly reported
 * them as "outdated" and asked for real SVG icons). Each [EditorIcon] maps
 * to one `res/drawable/ic_editor_*.xml` vector drawable (Feather/Lucide-
 * style outline icons, 24x24 viewport), tinted at draw time via
 * [DrawableCompat.setTint] so a single [iconTint] still recolors the whole
 * glyph regardless of which of its sub-paths are stroked vs. filled —
 * keeping this view's public API (constructor, mutable `icon`/`iconTint`)
 * identical to before, so none of its ~30+ call sites elsewhere in
 * MediaEditorActivity needed to change.
 */
enum class EditorIcon {
  CLOSE, CHECK, PLUS, UNDO, REDO, MOVE, SPARKLE, TEXT, FACE, DELETE, DUPLICATE, EDIT, OVERLAY, BRUSH, MUSIC,
  // Adjustment-row icons (Brightness/Contrast/.../Tint) — added per the
  // user's explicit "modernize the UI" request: that row was plain text
  // labels only, the biggest single "looks dated" cue on both platforms.
  SUN, CONTRAST_ICON, DROPLET, FADE, MOON, VIGNETTE, TARGET, THERMOMETER, HIGHLIGHTER, PALETTE,
  // Video transport — replaces the old text-label ("Play"/"Pause") button.
  PLAY, PAUSE,
  // Video trim row's "cut at playhead" action, per the user's explicit
  // "split into parts" request — DELETE (already above) is reused as-is
  // for "delete this part."
  SPLIT,
  // Layers panel's reorder buttons + per-layer visibility toggle, per the
  // user's explicit "drag layers up and down... just like Instagram"
  // request (reorder here is via these buttons, not true drag — see
  // MediaEditorActivity's own "Layers panel" doc for why).
  CHEVRON_UP, CHEVRON_DOWN, EYE, EYE_OFF,
  // Per-layer lock toggle (video layer tracks).
  LOCK, UNLOCK,
  // Video editor's top-right Export button.
  EXPORT,
  // Clip speed (gauge).
  SPEED,
  // Clip transition.
  TRANSITION,
  // Voice-over.
  MIC,
  // Story Tags rail (link / hashtag / time / date stickers).
  HASHTAG,
  // Merged-clip reorder buttons (Task 2), per the user's explicit "I want
  // to adjust, trim... like Instagram" follow-up.
  CHEVRON_LEFT, CHEVRON_RIGHT,
  // Layers tab icon — three stacked rounded rects, distinct from OVERLAY's
  // 2-rect overlap (already used by the unrelated "Overlay" image tab).
  STACK,
  // "Add Video" (merge-in-a-second-clip) tab icon — a plain "+", per the
  // user's explicit "add provision to add a new video and merge" request.
  ADD_VIDEO,
  // Story mode's right-edge icon rail "Download to gallery" action.
  DOWNLOAD,
  // Story mode's right-edge icon rail "Mute/unmute original video audio"
  // toggle (video only) — swaps in place the same way PLAY/PAUSE already
  // does, per the user's explicit "mute/unmute original audio" request.
  VOLUME, VOLUME_OFF,
  // Story mode's right-edge icon rail "Location" sticker action.
  LOCATION,
  // Image editor top bar "hold to compare with original" button.
  COMPARE,
  // Edit panel "Blur" (tilt-shift) adjustment.
  BLUR,
  // Edit panel "Auto" (one-tap enhance).
  WAND,
  // Text entry sheet: alignment (cycles) and text background (none /
  // solid / see-through).
  ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT, TEXT_BG, TEXT_BG_FILL,
  // Draw panel tools.
  ERASER, SHAPES,
  // Redesign tool-bar icons (same drawings as iOS tool_* assets).
  TOOL_FILTERS, TOOL_ADJUST, TOOL_TEXT, TOOL_DRAW, TOOL_STICKER, TOOL_OVERLAY, TOOL_MUSIC, TOOL_ADD_VIDEO, TOOL_MOVE, TOOL_AUTO, TOOL_BLUR, TOOL_VIGNETTE,
}

private fun EditorIcon.drawableRes(): Int = when (this) {
  EditorIcon.CLOSE -> R.drawable.ic_editor_close
  EditorIcon.PLUS -> R.drawable.ic_editor_plus
  EditorIcon.CHECK -> R.drawable.ic_editor_check
  EditorIcon.ALIGN_LEFT -> R.drawable.ic_editor_align_left
  EditorIcon.ALIGN_CENTER -> R.drawable.ic_editor_align_center
  EditorIcon.ALIGN_RIGHT -> R.drawable.ic_editor_align_right
  EditorIcon.TEXT_BG -> R.drawable.ic_editor_text_bg
  EditorIcon.TEXT_BG_FILL -> R.drawable.ic_editor_text_bg_fill
  EditorIcon.ERASER -> R.drawable.ic_editor_eraser
  EditorIcon.SHAPES -> R.drawable.ic_editor_shapes
  EditorIcon.TOOL_FILTERS -> R.drawable.ic_tool_filters
  EditorIcon.TOOL_ADJUST -> R.drawable.ic_tool_adjust
  EditorIcon.TOOL_TEXT -> R.drawable.ic_tool_text
  EditorIcon.TOOL_DRAW -> R.drawable.ic_tool_draw
  EditorIcon.TOOL_STICKER -> R.drawable.ic_tool_sticker
  EditorIcon.TOOL_OVERLAY -> R.drawable.ic_tool_overlay
  EditorIcon.TOOL_MUSIC -> R.drawable.ic_tool_music
  EditorIcon.TOOL_ADD_VIDEO -> R.drawable.ic_tool_add_video
  EditorIcon.TOOL_MOVE -> R.drawable.ic_tool_move
  EditorIcon.TOOL_AUTO -> R.drawable.ic_tool_auto
  EditorIcon.TOOL_BLUR -> R.drawable.ic_tool_blur
  EditorIcon.TOOL_VIGNETTE -> R.drawable.ic_tool_vignette
  EditorIcon.UNDO -> R.drawable.ic_editor_undo
  EditorIcon.REDO -> R.drawable.ic_editor_redo
  EditorIcon.MOVE -> R.drawable.ic_editor_move
  EditorIcon.SPARKLE -> R.drawable.ic_editor_sparkle
  EditorIcon.TEXT -> R.drawable.ic_editor_text
  EditorIcon.FACE -> R.drawable.ic_editor_face
  EditorIcon.DELETE -> R.drawable.ic_editor_delete
  EditorIcon.DUPLICATE -> R.drawable.ic_editor_duplicate
  EditorIcon.EDIT -> R.drawable.ic_editor_edit
  EditorIcon.OVERLAY -> R.drawable.ic_editor_overlay
  EditorIcon.BRUSH -> R.drawable.ic_editor_brush
  EditorIcon.MUSIC -> R.drawable.ic_editor_music
  EditorIcon.SUN -> R.drawable.ic_editor_sun
  EditorIcon.CONTRAST_ICON -> R.drawable.ic_editor_contrast
  EditorIcon.DROPLET -> R.drawable.ic_editor_droplet
  EditorIcon.FADE -> R.drawable.ic_editor_fade
  EditorIcon.MOON -> R.drawable.ic_editor_moon
  EditorIcon.VIGNETTE -> R.drawable.ic_editor_vignette
  EditorIcon.TARGET -> R.drawable.ic_editor_target
  EditorIcon.THERMOMETER -> R.drawable.ic_editor_thermometer
  EditorIcon.HIGHLIGHTER -> R.drawable.ic_editor_highlighter
  EditorIcon.PALETTE -> R.drawable.ic_editor_palette
  EditorIcon.PLAY -> R.drawable.ic_editor_play
  EditorIcon.PAUSE -> R.drawable.ic_editor_pause
  EditorIcon.SPLIT -> R.drawable.ic_editor_split
  EditorIcon.CHEVRON_UP -> R.drawable.ic_editor_chevron_up
  EditorIcon.CHEVRON_DOWN -> R.drawable.ic_editor_chevron_down
  EditorIcon.EYE -> R.drawable.ic_editor_eye
  EditorIcon.EYE_OFF -> R.drawable.ic_editor_eye_off
  EditorIcon.LOCK -> R.drawable.ic_editor_lock
  EditorIcon.UNLOCK -> R.drawable.ic_editor_unlock
  EditorIcon.EXPORT -> R.drawable.ic_editor_export
  EditorIcon.SPEED -> R.drawable.ic_editor_speed
  EditorIcon.TRANSITION -> R.drawable.ic_editor_transition
  EditorIcon.MIC -> R.drawable.ic_editor_mic
  EditorIcon.HASHTAG -> R.drawable.ic_editor_hashtag
  EditorIcon.CHEVRON_LEFT -> R.drawable.ic_editor_chevron_left
  EditorIcon.CHEVRON_RIGHT -> R.drawable.ic_editor_chevron_right
  EditorIcon.STACK -> R.drawable.ic_editor_stack
  EditorIcon.ADD_VIDEO -> R.drawable.ic_editor_add_video
  EditorIcon.DOWNLOAD -> R.drawable.ic_editor_download
  EditorIcon.VOLUME -> R.drawable.ic_editor_volume
  EditorIcon.VOLUME_OFF -> R.drawable.ic_editor_volume_off
  EditorIcon.LOCATION -> R.drawable.ic_editor_location
  EditorIcon.COMPARE -> R.drawable.ic_editor_compare
  EditorIcon.BLUR -> R.drawable.ic_editor_blur
  EditorIcon.WAND -> R.drawable.ic_editor_wand
}

class EditorIconView(context: Context, icon: EditorIcon) : View(context) {

  /** Mutable (unlike the other, fixed-purpose icon views) so the video
   *  transport button can swap PLAY/PAUSE in place on tap, rather than
   *  tearing down and re-adding a whole new view each toggle. */
  var icon: EditorIcon = icon
    set(value) {
      if (field == value) return
      field = value
      drawable = loadDrawable()
      shadowMask = null
      invalidate()
    }

  var iconTint: Int = Color.WHITE
    set(value) {
      field = value
      drawable?.let { DrawableCompat.setTint(it, value) }
      invalidate()
    }

  private var drawable: Drawable? = null

  /** Soft dark drop shadow under the glyph — for white icons that float
   *  straight over story media with no backing (story-mode X/Undo/Redo),
   *  so they stay readable over bright photos. Off by default. */
  var dropShadow: Boolean = false
    set(value) {
      if (field == value) return
      field = value
      shadowMask = null
      invalidate()
    }

  // Blurred alpha mask of the glyph, rebuilt only when the icon or its
  // drawn size changes (BlurMaskFilter is applied once, on the CPU, by
  // extractAlpha — so this works on hardware-accelerated canvases too).
  private var shadowMask: Bitmap? = null
  private var shadowMaskWidth = 0
  private var shadowMaskHeight = 0
  private val shadowMaskOffset = IntArray(2)
  private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(150, 0, 0, 0) }

  init {
    val minSizePx = (24f * resources.displayMetrics.density).toInt()
    minimumWidth = minSizePx
    minimumHeight = minSizePx
    drawable = loadDrawable()
  }

  private fun loadDrawable(): Drawable? {
    val d = ContextCompat.getDrawable(context, icon.drawableRes())?.let { DrawableCompat.wrap(it).mutate() }
    d?.let { DrawableCompat.setTint(it, iconTint) }
    return d
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val d = drawable ?: return
    val w = width
    val h = height
    if (w <= 0 || h <= 0) return
    // Square, centered, with only a small margin — the old hand-drawn
    // icons carried a ~24% pad per side (needed so their own thin
    // computed strokes didn't touch the tap target's edge), but that same
    // padding made these new vector-drawable glyphs read as noticeably
    // smaller than the Cancel/Done text next to them, per the user's
    // explicit "increase these all icons size... make it matching size to
    // Cancel and Done" screenshot report. Each icon's own artwork already
    // sits inset from its 24x24 viewport, so it doesn't need much more.
    // Padding is respected: a big tap target (e.g. 48dp) with padding
    // draws a normal-size glyph in its middle instead of filling it.
    val contentW = w - paddingLeft - paddingRight
    val contentH = h - paddingTop - paddingBottom
    if (contentW <= 0 || contentH <= 0) return
    val size = minOf(contentW, contentH)
    // Reduced again (was 0.06) per the user's follow-up "increase all
    // icons size little bit" — combined with the trayIconSize/
    // topBarIconGlyphSize token bumps above, for a further, still modest
    // size increase across every icon.
    val pad = (size * 0.03f).toInt()
    val left = paddingLeft + (contentW - size) / 2 + pad
    val top = paddingTop + (contentH - size) / 2 + pad
    d.setBounds(left, top, left + size - pad * 2, top + size - pad * 2)
    if (dropShadow) drawDropShadow(canvas, d)
    d.draw(canvas)
  }

  private fun drawDropShadow(canvas: Canvas, d: Drawable) {
    val bounds = d.copyBounds()
    val w = bounds.width()
    val h = bounds.height()
    if (w <= 0 || h <= 0) return
    if (shadowMask == null || shadowMaskWidth != w || shadowMaskHeight != h) {
      val glyph = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
      d.setBounds(0, 0, w, h)
      d.draw(Canvas(glyph))
      d.bounds = bounds
      val blurPaint = Paint().apply {
        maskFilter = BlurMaskFilter(3f * resources.displayMetrics.density, BlurMaskFilter.Blur.NORMAL)
      }
      shadowMask = glyph.extractAlpha(blurPaint, shadowMaskOffset)
      glyph.recycle()
      shadowMaskWidth = w
      shadowMaskHeight = h
    }
    val mask = shadowMask ?: return
    val dy = 1f * resources.displayMetrics.density
    canvas.drawBitmap(
      mask,
      (bounds.left + shadowMaskOffset[0]).toFloat(),
      bounds.top + shadowMaskOffset[1] + dy,
      shadowPaint,
    )
  }
}
