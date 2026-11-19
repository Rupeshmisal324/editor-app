package com.intoactive.app.mediaeditor

import android.graphics.Color

/**
 * Shared design tokens for the image editor's UI shell — colors, spacing,
 * typography, and motion timings, so every panel/component pulls from one
 * source instead of hardcoding values per-view. UI-only: does not touch
 * the existing crop/filter/text/sticker editing logic in
 * MediaEditorActivity — components read these tokens, nothing more.
 *
 * A plain Kotlin object of Color ints / raw dp Floats, not Compose
 * Color/Dp — this editor uses the classic Android View system throughout
 * (Activity/FrameLayout/LinearLayout/custom View subclasses), not Jetpack
 * Compose, even though Compose is already a dependency elsewhere in this
 * app (Zego SDK) — kept consistent with everything already built this
 * session. Spacing values are raw dp; call [dpToPx] with the Activity's
 * own density to convert, matching this file's existing
 * `(32f * density).toInt()` style.
 */
object EditorDesignTokens {

  object Colors {
    // Redesign palette (Snapseed-style, same values on iOS): one dark
    // ground for screen/top bar/tool bar, a lighter panel surface, tiles.
    val canvasBackground = Color.rgb(0x0E, 0x0F, 0x11)
    val chromeBackground = Color.rgb(0x0E, 0x0F, 0x11)
    /** Slide-up panels, the layer action bar and the text-entry toolbar. */
    val panelBackground = Color.rgb(0x17, 0x18, 0x1B)
    val elevatedSurface = Color.rgb(0x20, 0x22, 0x27)

    /** The editor's own accent — deliberately NOT the app's Color.accent
     *  (#9D0B0E): CLAUDE.md's Critical Rule #2 reserves that red for the
     *  iA logo mark only, never UI elements. Confirmed with the user. */
    val accent = Color.rgb(0x2F, 0x6F, 0xEB)
    /** Redesign (Snapseed-style): the soft tile behind the selected tool
     *  and that tool's icon/label colour. Same values on iOS. */
    val selectedToolTile = Color.rgb(0x20, 0x22, 0x27)
    val selectedToolTint = Color.rgb(0x8F, 0xB2, 0xFF)

    /** The video trim scrubber's border/handle color — deliberately plain
     *  yellow, matching the native Photos/iMovie trim-tool convention the
     *  user referenced directly, not the editor's own purple [accent]. */
    // Video redesign: the editor accent (was yellow), matching the image editor.
    val trimHandle = Color.rgb(0x2F, 0x6F, 0xEB)
    const val textPrimary = Color.WHITE
    val textSecondary = Color.rgb(0xA1, 0xA4, 0xAA)
    val divider = Color.rgb(0x2C, 0x2E, 0x33)

    /** Same red already used for the delete-icon-active-state elsewhere in
     *  this editor — reused (not the app's reserved logo-only accent red)
     *  for the bottom tray's active-tab indicator dot, per the user's
     *  explicit "icons white... active icon shows red dot below" request. */
    val danger = Color.parseColor("#E24B4A")

    /** The text layer row's color — was Color.parseColor("#7C3AED") (a
     *  brighter, less saturated violet) before the user's explicit "make
     *  these all three layers color dark, increase saturation... just
     *  like Instagram edit app" request. Violet-700; matches iOS's
     *  identical token. */
    val textLayer = Color.parseColor("#6D28D9")

    /** The sticker layer row's color — was Color.parseColor("#F59E0B") (a
     *  brighter, less saturated amber) before the same "dark, saturated,
     *  Instagram-style" request as [textLayer] above. Amber-700; matches
     *  iOS's identical token. */
    val stickerLayer = Color.parseColor("#B45309")

    /** The music layer row's color — was Color.parseColor("#22C55E") (a
     *  brighter, less saturated green) before the same "dark, saturated,
     *  Instagram-style" request as [textLayer] above. Emerald-700;
     *  matches iOS's identical token. */
    val musicLayer = Color.parseColor("#047857")
    /** Voice-over track (teal), same as iOS. */
    val voiceLayer = Color.parseColor("#0E7490")
  }

  object TypeSizesSp {
    const val trayLabel = 12f
    const val panelTitle = 15f
    const val sliderValue = 13f
  }

  object SpacingDp {
    const val topBarHeight = 52f
    const val topBarHorizontalPadding = 16f
    const val minTapTarget = 44f
    /** The VISIBLE glyph size inside a `minTapTarget` button — kept
     *  smaller than the tap target itself (same "44pt tap area, ~20pt
     *  glyph" relationship iOS gets for free from SF Symbols' own default
     *  point size inside a same-sized UIButton) so a top-bar icon reads as
     *  a standard, modestly-sized icon rather than filling its whole tap
     *  box. */
    // Bumped from 20 per the user's explicit "increase all icons size
    // little bit" follow-up (after switching to the new SVG icon set).
    const val topBarIconGlyphSize = 22f
    const val bottomTrayHeight = 76f
    /** Redesign: the LOOKS · TOOLS · EXPORT bar under the tool rail
     *  (regular editor only, not story mode). Same on iOS. */
    const val lookToolsBarHeight = 52f
    // Bumped from 24, then from 30 per the user's explicit "increase all
    // icons size little bit" follow-up (Android only) — still comfortably
    // fits within bottomTrayHeight alongside the label below it.
    const val trayIconSize = 34f
    // Bumped from 8, then from 13 per the user's explicit "increase
    // horizontal gap in each icon" follow-up (Android only).
    const val trayIconSpacing = 20f
    const val panelCollapsedHeight = 220f
    const val panelCornerRadius = 20f
    const val thumbnailSize = 64f
    const val thumbnailCornerRadius = 8f
    const val thumbnailGutter = 8f
    // Raised from 4f/20f (a flat, borderless thumb) — per the user's
    // explicit "these slider is looking very simple, improve UI of
    // these" report — see makeStyledSeekBar's own thumb-drawable doc.
    const val sliderTrackHeight = 8f
    const val sliderThumbDiameter = 26f
  }

  const val PANEL_EXPANDED_HEIGHT_FRACTION = 0.4f

  object MotionMs {
    const val panelToggleDuration = 220
    const val trayIconActiveDuration = 120
  }
  const val TRAY_ICON_ACTIVE_SCALE = 1.08f

  fun dpToPx(dp: Float, density: Float): Int = (dp * density).toInt()
}
