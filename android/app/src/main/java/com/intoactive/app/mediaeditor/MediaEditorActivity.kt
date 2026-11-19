package com.intoactive.app.mediaeditor

import android.Manifest
import android.animation.ValueAnimator
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.CancellationSignal
import android.graphics.Bitmap
import android.util.Log
import android.net.Uri
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.os.Build
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.Outline
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.ClipDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import android.text.TextPaint
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.GestureDetector
import android.view.HapticFeedbackConstants
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.animation.AnimationUtils
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.Crop
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.OverlaySettings
import androidx.media3.effect.Presentation
import androidx.media3.effect.SpeedChangeEffect
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.effect.TextureOverlay
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.google.common.collect.ImmutableList
import com.editorapp.editor.R
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt
import org.json.JSONArray
import org.json.JSONObject

/** Height of the Filters panel's category tab row. */
private const val FILTER_CATEGORY_ROW_HEIGHT_DP = 30f
private const val TEXT_STYLE_PANEL_HEIGHT_DP = 160f
// Overlays need room for the filter thumbnails / chips above a slider.
private const val OVERLAY_STYLE_PANEL_HEIGHT_DP = 200f
// Taller than the default to fit the search box + category tabs (same as iOS).
private const val STICKERS_PANEL_HEIGHT_DP = 280f

/**
 * Milestone 1 proved the open/cancel/done round trip with a blank screen.
 * Milestone 2 replaces that with a real canvas: the selected image, decoded
 * and displayed full-screen (aspect-fit). Milestone 3 adds real video
 * playback (see the video branch in onCreate).
 * Built programmatically (no layout XML) to keep this a single file for now.
 */
@UnstableApi
class MediaEditorActivity : Activity() {

  companion object {
    private const val TIMELINE_ZOOM_MIN_DP = 10f
    private const val TIMELINE_ZOOM_MAX_DP = 240f
    const val EXTRA_URI = "uri"
    const val EXTRA_TYPE = "type"
    const val EXTRA_MUSIC_TRACKS_JSON = "music_tracks_json"
    // Story camera flow only — swaps the primary button's label to "Share
    // your story"; export/result plumbing is identical either way.
    const val EXTRA_IS_STORY_MODE = "is_story_mode"
    // Google Places key for the story rail's Location picker.
    const val EXTRA_PLACES_API_KEY = "places_api_key"

    const val EXTRA_RESULT_STATUS = "result_status"
    const val EXTRA_RESULT_CODE = "result_code"
    const val EXTRA_RESULT_MESSAGE = "result_message"
    const val EXTRA_RESULT_URI = "result_uri"
    const val EXTRA_RESULT_TYPE = "result_type"
    const val EXTRA_RESULT_WIDTH = "result_width"
    const val EXTRA_RESULT_HEIGHT = "result_height"
    const val EXTRA_RESULT_DURATION = "result_duration"
    // JSON array of location-sticker metadata — see locationStickerJson.
    const val EXTRA_RESULT_STICKERS_JSON = "result_stickers_json"
    /** Photo re-edit project JSON — in on open, out on a photo export. */
    const val EXTRA_EDIT_PROJECT = "edit_project"
    const val EXTRA_RESULT_EDIT_PROJECT = "result_edit_project"

    // Sticker library: see StickerCatalog (assets/sticker_catalog.json).

    // Decode the original up to this on the long side for export — well
    // above what any of this app's social-post use cases need, while still
    // bounding memory for an unusually large source photo.
    private const val MAX_EXPORT_PIXEL_SIZE = 4096
    // Overlay photos are a layer on the canvas, never the full export, so
    // ~1.5–2K is plenty of resolution while keeping memory bounded.
    private const val MAX_OVERLAY_DECODE_PX = 1440
    private const val MAX_OVERLAY_LONG_SIDE_PX = 2048
    /** Photo + music exports a VIDEO, so it uses a 1080p-class cap: the
     *  photo's own 4096 cap made every frame a needlessly huge encode. */
    private const val MAX_PHOTO_MUSIC_VIDEO_PIXEL_SIZE = 1920
    /** Story mode exports at most this many pixels WIDE (full-screen canvas,
     *  so ~1080x2400) — the resolution stories are displayed at. The canvas is
     *  taller than the photo, so the uncapped export was ~3000x7000. */
    private const val STORY_EXPORT_PIXEL_WIDTH = 1080f
    /** Story-mode rail label size — a step below EditorDesignTokens' trayLabel (11sp). */
    private const val STORY_RAIL_LABEL_SP = 10f
    private const val STORY_JPEG_QUALITY = 85

    // Dropped from 250 per the user's explicit "playing like stuck stuck
    // stuck... i want to display smooth" request — at 250ms the filmstrip's
    // auto-scroll-follow-playback (scrollTo in timelineRunnable below) only
    // updated 4x/second, visibly stepping instead of scrolling smoothly.
    // ~16ms matches a 60fps frame cadence; every other piece of work this
    // runnable does (highlight/layer-visibility checks) already early-
    // returns cheaply when nothing changed, so running it this often adds
    // negligible cost.
    private const val TIMELINE_POLL_INTERVAL_MS = 16L

    // Shared with refreshLayersPanel's own rowHeightPx/rowGapPx-based cap
    // and setUpEditingControls's video-controls-band reservation — a
    // SINGLE source of truth for "how tall can the layer-tracks panel
    // ever get" so the canvas's own reserved space (see
    // updateCanvasSizeForLayers) always matches exactly what the tracks
    // panel can actually grow to, on both the "no layers" and "many
    // layers, expanded" ends.
    // At most 3 rows (34dp + 6dp gap each) — more rows scroll inside this
    // area instead of shrinking the video preview further.
    private const val LAYER_TRACKS_MAX_HEIGHT_DP = 120f
    /** Max text/sticker/photo layers in a video (see canAddLayer). */
    private const val MAX_VIDEO_LAYERS = 10
    /** Default length of a newly added layer (Edits-style). */
    private const val NEW_LAYER_DEFAULT_MS = 3000L
    /** Fixed so the selection label can be placed left of it. */
    private const val ADD_LAYER_BUTTON_WIDTH_DP = 36f
    private const val LAYER_STATE_BUTTON_WIDTH_DP = 30f
    /** Fade in/out audio ramp length. */
    private const val AUDIO_FADE_MS = 1000L
    /** Original sound / music level while the voice-over plays (ducking). */
    private const val VOICE_DUCK_LEVEL = 0.3f
    private const val VOICE_PERMISSION_REQUEST_CODE = 7311
    /** Info pills viewers can tap (time / date are just labels). */
    private val TAPPABLE_INFO_KINDS = setOf("location", "link", "hashtag")
    /** Video editor's compact tool rail (photo editor keeps the tokens). */
    private const val COMPACT_TRAY_HEIGHT_DP = 62f
    private const val COMPACT_TRAY_ICON_DP = 24f
    // Gap between the layer-tracks panel's own top edge and the Split/
    // Delete/chevron row above it — shared between setUpEditingControls's
    // one-time chrome reservation and refreshLayersPanel's own live
    // positioning of that row, so they always agree.
    private const val LAYER_TRACKS_TOP_GAP_DP = 4f

    // Standard destructive-action red (matches iOS's systemRed, already
    // used implicitly via confirmDeleteLayer's .destructive alert style
    // on that platform) — the layer toolbar's "Delete" text label only.
    private val DESTRUCTIVE_RED = Color.rgb(0xFF, 0x3B, 0x30)

    private const val REQUEST_CODE_PICK_OVERLAY_IMAGE = 4201
    private const val REQUEST_CODE_PICK_SECOND_VIDEO_CLIP = 4202

    // Fixed square crop box for the overlay-image crop step — see
    // presentOverlayCropScreen's doc.
    private const val OVERLAY_CROP_BOX_SIZE_DP = 260f
    private const val OVERLAY_CROP_MIN_SCALE = 1f
    private const val OVERLAY_CROP_MAX_SCALE = 4f
  }

  private lateinit var mediaUri: String
  private lateinit var mediaType: String
  /** True when opened from the Story camera flow — see EXTRA_IS_STORY_MODE. */
  private var isStoryMode: Boolean = false
  /** Google Places key for the Location picker — see EXTRA_PLACES_API_KEY. */
  private var placesApiKey: String = ""
  private lateinit var root: ClippingRootLayout
  /** The canvas box's own root-relative rect — computed once in
   *  layoutImageCanvas. Registered as every layer's (base canvas + every
   *  text/sticker/overlay layer's) clip rect via root.setClipRect. Used to
   *  be "sized once, geometrically stable, never touched again" — no
   *  longer true as of [updateCanvasSizeForLayers], which re-runs
   *  layoutImageCanvas (and rescales every existing layer to match) once
   *  the layer-tracks panel's own visibility changes; see that function's
   *  own doc. */
  private var canvasBoxRect: Rect? = null
  /** [ImageCanvasChrome]/display-size inputs `layoutImageCanvas` needs,
   *  stashed so [updateCanvasSizeForLayers] can re-invoke it later with a
   *  different shrinkFactor — the ORIGINAL call site only ever ran once,
   *  before any layer existed to shrink the canvas for. */
  private var canvasChromeRef: ImageCanvasChrome? = null
  /** Real system status-bar / navigation-bar heights (see their
   *  computation in onCreate) — promoted from onCreate-local vals to
   *  instance properties so setUpEditingControls can read them too.
   *  Needed because targeting SDK 36 makes Android draw this window
   *  edge-to-edge unconditionally (no more automatic system-bar inset for
   *  non-edge-to-edge apps), so topBar/the bottom tray/every slide-up
   *  panel must explicitly push themselves clear of those regions now —
   *  per the user's explicit "top tab bar is mixing with cancel and done
   *  ... bottom navigation button and UI is mixing" screenshot report. */
  private var statusBarHeightPx = 0

  /** Story mode: breathing room between the status bar and the floating
   *  X / Undo / Redo / Share row (it sat flush under the status bar). */
  private val storyTopGapPx get() = if (isStoryMode) (24f * resources.displayMetrics.density).toInt() else 0
  private var navigationBarHeightPx = 0
  private var canvasDisplaySizeRef: Pair<Int, Int>? = null
  /** The extra bottom reservation (matching the layer-tracks panel's own
   *  height) LAST applied to the canvas by [updateCanvasSizeForLayers] —
   *  tracked so it can no-op when nothing's actually changing (it's
   *  called on every refreshLayersPanel pass, not just ones where the
   *  tracks' own height actually changed). */
  private var lastAppliedCanvasReservationPx = 0
  private var gestureCoordinator: LayerGestureCoordinator? = null

  // Text layers are independent of the image's own pan/zoom/rotate — added
  // as siblings in root, not children of imageView.
  private val textLayerViews = mutableListOf<TextView>()

  // Stickers reuse the exact same transformable TextView as text, now
  // displaying a bundled sticker image (via a compound drawable, see
  // applyStickerImage) instead of an emoji glyph — every existing
  // gesture/undo/export/per-layer-timing code path built for a plain
  // TextView keeps working unchanged. Kept in a separate list so layer-
  // management code can distinguish sticker vs. text layers (and group
  // them into their own row in the per-layer time-range editor).
  private val stickerLayerViews = mutableListOf<TextView>()

  // A second photo placed on top of the first — the "overlay" feature, per
  // the user's explicit request. Plain ImageViews, added to `root` exactly
  // like text/sticker layers (Gravity.CENTER, registered with the same
  // LayerGestureCoordinator, which is already generic over View — no new
  // gesture code needed on this platform, unlike iOS). Image-only for now
  // (not baked into video export) — same scope limit already accepted for
  // Vignette/Sharpen, for the same reason.
  private val imageOverlayLayerViews = mutableListOf<ImageView>()
  /** Non-null only while the photo picker is open FOR AN EXISTING overlay
   *  layer (via the toolbar's Edit action) — onActivityResult swaps that
   *  layer's image in place instead of adding a new layer. */
  private var editingImageOverlayLayer: ImageView? = null

  /** State for the overlay-image crop step (pan/zoom to fit a fixed box)
   *  — see presentOverlayCropScreen's doc. */
  private var overlayCropOverlayRef: View? = null
  private var overlayCropSourceBitmap: Bitmap? = null
  private var overlayCropEditingLayer: ImageView? = null
  private var overlayCropTranslationX = 0f
  private var overlayCropTranslationY = 0f
  private var overlayCropScale = 1f

  // On-canvas layer action toolbar (Delete/Duplicate/Edit) — appears above
  // whichever text/sticker layer was last tapped, tracks its position live
  // during drag/pinch/rotate (see LayerGestureCoordinator.onLayerTransformed),
  // and disappears when the canvas or empty margin is tapped instead. Never
  // set to the canvas layer (imageView/playerView) itself — see the
  // onLayerTapped wiring in onCreate.
  private var selectedLayerView: View? = null
    set(value) {
      field = value
      if (value != null) isVoiceRowSelected = false
      updateVideoSelectionLabel()
      syncLayerTrackSelection()
    }
  private var layerActionToolbarRef: View? = null
  /** Non-null only while the text-entry overlay is open FOR AN EXISTING
   *  layer (via the toolbar's Edit action) — confirmTextEntry() updates
   *  this layer in place instead of adding a new one. Reset to null by
   *  dismissTextEntryOverlay() so a later "Add Text" tap never reuses a
   *  stale target. */
  private var editingLayerView: TextView? = null

  // Undo/redo — per the user's explicit "for all activity we can undo or
  // redo anything" request, EVERY mutating action must push an entry here,
  // not just add/delete. (A prior version of this comment scoped undo down
  // to "adding/deleting text and sticker layers only" and explicitly
  // excluded pan/zoom/rotate and filter/adjustments as "a materially
  // bigger feature than basic" — that is exactly why undo kept reading as
  // "broken": it was never wired for the most common actions in the first
  // place, not regressed. Transform gestures and slider drags now push one
  // coalesced entry per gesture/drag via commitLayerTransformUndo and each
  // slider's touch-up handler, not one per intermediate tick.)
  private data class UndoableAction(val undo: () -> Unit, val redo: () -> Unit)
  private val undoStack = mutableListOf<UndoableAction>()
  /** Redesign Phase 5: while a tool panel is open, the undo-stack depth when
   *  it opened. ✕ undoes back to it; leaving any other way (Done, drag
   *  down, another tool) merges everything since into one undo step. */
  private var toolSessionTab: ImageEditorTab? = null
  private var toolSessionDepth = 0
  private val redoStack = mutableListOf<UndoableAction>()

  private fun pushUndo(undo: () -> Unit, redo: () -> Unit) {
    blurCoverRevision++
    undoStack.add(UndoableAction(undo, redo))
    redoStack.clear()
  }

  /** Restores a layer's translation/scale/rotation snapshot — the Android
   *  counterpart to EditableLayerView.applyInitialTransform on iOS. */
  private fun applyTransformSnapshot(target: View, snapshot: LayerGestureCoordinator.TransformSnapshot) {
    target.translationX = snapshot.translationX
    target.translationY = snapshot.translationY
    target.scaleX = snapshot.scaleX
    target.scaleY = snapshot.scaleY
    target.rotation = snapshot.rotation
    if (target === selectedLayerView) {
      repositionLayerActionToolbar()
      updateStickerDeleteBadge()
    }
  }

  private fun commitLayerTransformUndo(
    target: View,
    old: LayerGestureCoordinator.TransformSnapshot,
    new: LayerGestureCoordinator.TransformSnapshot,
  ) {
    pushUndo(
      undo = { applyTransformSnapshot(target, old) },
      redo = { applyTransformSnapshot(target, new) },
    )
  }
  private var selectedFilter = PhotoFilter.ORIGINAL
  /** 0..1 intensity of [selectedFilter] (Filters panel Strength slider). */
  private var filterStrength = 1f
  /** Filters panel Saturation (-1..1) and Sharpness (0..1), applied right
   *  after the filter. Reset to 0 whenever a different filter is picked. */
  private var filterSaturation = 0f
  private var filterSharpness = 0f
  private var brightness = 0f // -1..1
  private var contrast = 0f // -1..1 (0 = unchanged)
  private var saturation = 0f // -1..1 (0 = unchanged)
  // 5 additional adjustments, per the user's explicit request — same
  // -1..1 range and "always rebuilt from scratch" rule as B/C/S above.
  // Positive fade/shadow/warmth = fade out / lift shadows / warmer;
  // negative = the opposite (more vivid / deepen shadows / cooler).
  // Vignette/sharpen only have a meaningful positive direction (there's no
  // natural "negative vignette"), so negative values are treated as 0.
  // Vignette/sharpen are IMAGE-only for now (not baked into video export)
  // — doing this for video would need a custom Media3 GL effect, a
  // materially bigger scope than adding a ColorMatrix term.
  private var fade = 0f
  private var shadow = 0f
  private var vignette = 0f
  private var sharpen = 0f
  private var warmth = 0f
  // 2 more adjustments, per the user's follow-up request — same -1..1
  // range/rebuild rule. Highlights is Shadow's opposite-tone counterpart
  // (positive = tone down bright areas, negative = boost them) — same
  // contrast-bias approximation technique, just biased the other way.
  // Tint is Warmth's green-magenta counterpart to its blue-orange axis
  // (positive = greener, negative = magenta).
  private var highlights = 0f
  private var tint = 0f

  /** The 9 filter/adjustment fields that actually apply to VIDEO (see
   *  fade/shadow/vignette's own doc above — vignette/sharpen are image-
   *  only and never baked into video export, so they're deliberately left
   *  out of this and stay pure globals). Per the user's explicit "any
   *  clip including the first should be reorderable, and edits should
   *  stay with their own clip" request — until now these 9 fields were
   *  effectively single-instance globals implicitly meaning "the primary
   *  clip's settings" (only the primary clip could ever have them; a
   *  merged/additional clip structurally couldn't). [[clipFilterState]]
   *  below is the per-clip store; these 9 flat vars are now a "working
   *  copy" that always mirrors whichever clip is currently active
   *  (primary or a merged one) — see syncActiveClipFilterState. */
  private data class ClipFilterState(
    val filter: PhotoFilter = PhotoFilter.ORIGINAL,
    val filterStrength: Float = 1f,
    val filterSaturation: Float = 0f,
    val filterSharpness: Float = 0f,
    val brightness: Float = 0f,
    val contrast: Float = 0f,
    val saturation: Float = 0f,
    val fade: Float = 0f,
    val shadow: Float = 0f,
    val warmth: Float = 0f,
    val highlights: Float = 0f,
    val tint: Float = 0f,
  )
  /** Keyed by clip URI (mediaUri's current value counts as a key here too,
   *  same as additionalClipSegments/additionalClipDurationsMs/
   *  additionalClipThumbnailTiles are keyed by URI regardless of primary-
   *  vs-additional role) — every clip's own filter/adjustment values,
   *  surviving even while a DIFFERENT clip is the one currently being
   *  edited (or currently primary). */
  private val clipFilterState = mutableMapOf<String, ClipFilterState>()

  private fun currentFilterStateSnapshot(): ClipFilterState = ClipFilterState(
    filter = selectedFilter, filterStrength = filterStrength,
    filterSaturation = filterSaturation, filterSharpness = filterSharpness, brightness = brightness, contrast = contrast, saturation = saturation,
    fade = fade, shadow = shadow, warmth = warmth, highlights = highlights, tint = tint,
  )

  /** Loads `state` into the 9 flat working-copy vars AND re-syncs the
   *  Edit/Effect panels' own UI (sliders + filter-picker highlight) to
   *  match — a "reload" path that never existed before this session,
   *  since previously there was only ever one possible editing target
   *  (the primary clip) and the sliders/filter picker were simply never
   *  reloaded once built. */
  private fun applyFilterStateSnapshot(state: ClipFilterState) {
    selectedFilter = state.filter
    filterStrength = state.filterStrength
    filterSaturation = state.filterSaturation
    filterSharpness = state.filterSharpness
    brightness = state.brightness
    contrast = state.contrast
    saturation = state.saturation
    fade = state.fade
    shadow = state.shadow
    warmth = state.warmth
    highlights = state.highlights
    tint = state.tint
    syncAdjustSlidersToCurrentValues()
    updateFilterButtonHighlight()
  }

  /** Pushes the 9 flat working-copy vars' current values into each of
   *  their own SeekBars — setting `.progress` re-drives
   *  makeAdjustmentRow's own onProgressChanged (Android calls it for ANY
   *  progress change, user or programmatic), so this needs no separate
   *  "set the label/haptic too" logic. Vignette/sharpen are deliberately
   *  untouched (see ClipFilterState's own doc — they're not part of the
   *  per-clip video model). Each row is a LinearLayout(label, seekBar,
   *  valueLabel) per makeAdjustmentRow's own construction — getChildAt(1)
   *  reaches the SeekBar without needing makeAdjustmentRow to expose one. */
  private fun syncAdjustSlidersToCurrentValues() {
    val currentValues = mapOf(
      AdjustProperty.BRIGHTNESS to brightness,
      AdjustProperty.CONTRAST to contrast,
      AdjustProperty.SATURATION to saturation,
      AdjustProperty.FADE to fade,
      AdjustProperty.SHADOW to shadow,
      AdjustProperty.WARMTH to warmth,
      AdjustProperty.HIGHLIGHTS to highlights,
      AdjustProperty.TINT to tint,
    )
    for ((property, value) in currentValues) {
      val row = adjustSliderRowRefs[property] as? LinearLayout ?: continue
      val seekBar = row.getChildAt(1) as? SeekBar ?: continue
      seekBar.progress = ((value * 100) + 100).toInt()
    }
  }

  /** Called whenever activeClipUri changes (see updateActiveClipHighlight)
   *  — flushes the OUTGOING clip's current working-copy values into
   *  [[clipFilterState]], then loads the INCOMING clip's own stored
   *  values (or defaults, if it's never been individually edited) into
   *  the working copy. previousUri/newUri use the same "null = primary"
   *  convention activeClipUri itself already does. */
  private fun syncActiveClipFilterState(previousUri: String?, newUri: String?) {
    clipFilterState[previousUri ?: mediaUri] = currentFilterStateSnapshot()
    applyFilterStateSnapshot(clipFilterState[newUri ?: mediaUri] ?: ClipFilterState())
  }

  /** Set once, right after the downsampled decode completes — sharpen's
   *  live preview re-convolves from this untouched source each time,
   *  same "always rebuild from a base, never compound" rule as the
   *  ColorMatrix-based adjustments. */
  private var baseBitmapRef: Bitmap? = null

  // Milestone 5 UI polish (image editor only — mirrors the iOS
  // MediaEditorViewController structure): top icon row (cancel/undo/redo/
  // done) + bottom tab bar (Tools/Text/Sticker). Tools has no panel of its
  // own — pan/zoom/rotate work continuously on the canvas (crop was
  // removed at the user's request; only repositioning/zooming/rotating
  // remain).
  // Filters + Adjust used to be an "Effects" tab/panel, then moved to an
  // always-visible strip under the canvas (Instagram-style); per the
  // user's later "major change" request they're back to being tab-gated
  // panels again — now split into two (Effect for filters, Edit for
  // adjustments) flanking Text, see effectPanel/editPanel in
  // setUpImageEditingControls. Text stays a momentary action wired
  // straight to the existing text-entry overlay.
  // Stickers is a stateful tab reusing the SlideUpPanelView shell, per the
  // reference spec's explicit "grid (4 columns) of sticker thumbnails in
  // the panel."
  // Draw is a 3rd stateful tab, same SlideUpPanelView shell as Stickers —
  // per the user's explicit request for a freehand brush tool.
  // MUSIC is video-only (no tab button/panel built for image at all — see
  // setUpEditingControls) — consolidates what used to be several separate
  // floating controls (track picker, its volume/trim, original-clip mute/
  // volume) into one SlideUpPanelView, matching Stickers/Draw, per the
  // user's explicit "same UI as the image editor" request for video.
  // EFFECT (filters) and EDIT (adjustments) were an always-visible strip;
  // per the user's explicit "major change" request they're now gated
  // behind their own tabs, like everything else.
  // TEXT_STYLE: the selected text layer's Style panel (opened from its
  // toolbar, no tray tab of its own).
  // TOOLS_GRID: the redesign's Tools grid sheet (TOOLS in the bottom bar).
  private enum class ImageEditorTab { TOOLS, EFFECT, STICKERS, DRAW, EDIT, MUSIC, TEXT_STYLE, TOOLS_GRID }
  private var selectedImageEditorTab = ImageEditorTab.TOOLS
  private var effectPanelRef: SlideUpPanelView? = null
  private var editPanelRef: SlideUpPanelView? = null
  private var stickersPanelRef: SlideUpPanelView? = null
  private var drawPanelRef: SlideUpPanelView? = null
  private var musicPanelRef: SlideUpPanelView? = null
  private var toolsTabIconRef: EditorIconView? = null
  private var effectTabIconRef: EditorIconView? = null
  private var editTabIconRef: EditorIconView? = null
  private var stickersTabIconRef: EditorIconView? = null
  private var drawTabIconRef: EditorIconView? = null
  private var musicTabIconRef: EditorIconView? = null
  private var toolsTabLabelRef: TextView? = null
  private var effectTabLabelRef: TextView? = null
  private var editTabLabelRef: TextView? = null
  private var stickersTabLabelRef: TextView? = null
  private var drawTabLabelRef: TextView? = null
  private var musicTabLabelRef: TextView? = null
  // Small pill shown under a STATEFUL tab's label once selected (UI-
  // modernization item 4: a real selection indicator, not just a color
  // change) — Text/Overlay stay momentary actions with no selected state,
  // so they never get one wired up (see makeTabButton's 4th return value).
  private var toolsTabIndicatorRef: View? = null
  private var effectTabIndicatorRef: View? = null
  private var editTabIndicatorRef: View? = null
  private var stickersTabIndicatorRef: View? = null
  private var drawTabIndicatorRef: View? = null
  private var musicTabIndicatorRef: View? = null
  private var drawingCanvasRef: DrawingCanvasView? = null
  private var selectedDrawColor = Color.WHITE
  private var selectedDrawWidthPx = 0f
  private val drawColorButtonRefs = mutableListOf<View>()
  // Per the user's explicit "add multiple brush option" request.
  private var selectedBrushType = DrawingCanvasView.BrushType.PEN
  private val drawBrushTypeButtonRefs = mutableListOf<Pair<DrawingCanvasView.BrushType, View>>()
  /** The eraser keeps its own size, separate from the brushes'. */
  private var drawEraserWidthPx = 0f
  /** Draw panel tool: freehand brush, eraser, or drag-to-size shape (drawn
   *  with the selected brush). Same on iOS. */
  private enum class DrawTool(val title: String, val icon: EditorIcon) {
    BRUSH("Brush", EditorIcon.BRUSH), ERASER("Eraser", EditorIcon.ERASER), SHAPE("Shape", EditorIcon.SHAPES)
  }
  private var selectedDrawTool = DrawTool.BRUSH
  private var selectedDrawShape = DrawingCanvasView.ShapeType.RECTANGLE
  private val drawToolRefs = mutableListOf<Triple<DrawTool, View, Pair<EditorIconView, TextView>>>()
  private val drawShapeRefs = mutableListOf<Pair<DrawingCanvasView.ShapeType, View>>()
  private var drawBrushTilesRef: View? = null
  private var drawShapeTilesRef: View? = null
  private var drawWidthSeekBarRef: SeekBar? = null
  private var drawWidthToProgress: ((Float) -> Int)? = null
  private var drawColorScrollRef: View? = null

  // Adjust — Instagram's actual "Edit" model: an icon row (B/C/S), tap one
  // to swap in a single centered slider with a back arrow, rather than
  // showing all 3 sliders stacked at once. Lives inside editPanel, gated
  // behind the Edit tab (was an always-visible strip).
  private enum class AdjustProperty { BRIGHTNESS, CONTRAST, SATURATION, FADE, SHADOW, VIGNETTE, SHARPEN, WARMTH, HIGHLIGHTS, TINT, BLUR, AUTO }
  /** Auto-enhance toggle state: values it applied, and what they replaced.
   *  "On" whenever the sliders still exactly match autoEnhanceApplied.
   *  AUTO above isn't a slider — it's a one-tap action (didTapAutoEnhance). */
  private var autoEnhanceApplied: PhotoAutoEnhance? = null
  private var autoEnhanceBackup: PhotoAutoEnhance? = null
  private var autoEnhanceButtonRef: LinearLayout? = null
  // ---- Blur over layers ----

  /** The blurred picture-plus-layers, shown above the layers (touches pass
   *  through to them). Re-drawn whenever a layer moves or anything changes. */
  private var blurCoverRef: ImageView? = null
  private var unblurredPreviewBitmap: Bitmap? = null
  private var blurCoverSignature: List<Float> = emptyList()
  /** Bumped by every edit/undo/redo/preview change (style changes don't
   *  show up in a layer's position, so they're caught this way). */
  private var blurCoverRevision = 0
  private var blurCoverTicking = false

  /** Text, stickers, overlays and drawing currently on the picture. */
  private fun blurCoverLayerViews(): List<View> {
    val views = mutableListOf<View>()
    views += textLayerViews
    views += stickerLayerViews
    views += imageOverlayLayerViews
    drawingCanvasRef?.takeIf { it.allStrokes().isNotEmpty() }?.let { views += it }
    return views.filter { it.visibility == View.VISIBLE && it.parent === root }
  }

  /** Not while drawing or styling a layer — those show the layer sharp so
   *  you can see what you're doing. */
  private fun shouldShowBlurCover(): Boolean =
    mediaType == "image" && blur.isActive && !isShowingOriginal && unblurredPreviewBitmap != null &&
      selectedImageEditorTab != ImageEditorTab.DRAW && selectedImageEditorTab != ImageEditorTab.TEXT_STYLE &&
      blurCoverLayerViews().isNotEmpty()

  private fun blurCoverSignatureNow(views: List<View>): List<Float> {
    val sig = mutableListOf(views.size.toFloat(), blurCoverRevision.toFloat())
    canvasBoxRect?.let { sig += listOf(it.left.toFloat(), it.top.toFloat(), it.width().toFloat(), it.height().toFloat()) }
    for (v in views) {
      sig += listOf(
        root.indexOfChild(v).toFloat(), v.left.toFloat(), v.top.toFloat(), v.width.toFloat(), v.height.toFloat(),
        v.translationX, v.translationY, v.scaleX, v.scaleY, v.rotation,
      )
    }
    return sig
  }

  private val blurCoverFrameCallback = object : android.view.Choreographer.FrameCallback {
    override fun doFrame(frameTimeNanos: Long) {
      if (!blurCoverTicking) return
      updateBlurCover()
      if (blurCoverTicking) android.view.Choreographer.getInstance().postFrameCallback(this)
    }
  }

  private fun updateBlurCover() {
    if (!shouldShowBlurCover()) {
      blurCoverRef?.let {
        it.visibility = View.GONE
        it.setImageBitmap(null)
      }
      blurCoverTicking = false
      blurCoverSignature = emptyList()
      return
    }
    if (!blurCoverTicking) {
      blurCoverTicking = true
      android.view.Choreographer.getInstance().postFrameCallback(blurCoverFrameCallback)
    }
    val layers = blurCoverLayerViews()
    val signature = blurCoverSignatureNow(layers)
    if (signature == blurCoverSignature && blurCoverRef?.visibility == View.VISIBLE) return
    blurCoverSignature = signature
    renderBlurCover(layers)
  }

  private fun renderBlurCover(layers: List<View>) {
    val sharp = unblurredPreviewBitmap ?: return
    val imageView = imageViewRef ?: return
    val box = canvasBoxRect ?: return
    val cover = blurCoverRef ?: ImageView(this).apply {
      scaleType = ImageView.ScaleType.FIT_XY
      isClickable = false
      isFocusable = false
      importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
      blurCoverRef = this
    }
    // Picture without blur + the layers, as on screen (no selection border).
    val shownDrawable = imageView.drawable
    val selected = selectedLayerView
    val selectionForeground = selected?.foreground
    imageView.setImageBitmap(sharp)
    selected?.foreground = null
    val composite = renderCanvasComposite((listOf<View>(imageView) + layers).toSet())
    imageView.setImageDrawable(shownDrawable)
    selected?.foreground = selectionForeground
    if (composite == null) return
    val blurred = PhotoBlurRenderer.apply(composite, blur)
    if (blurred !== composite) composite.recycle()
    cover.setImageBitmap(blurred)
    cover.visibility = View.VISIBLE
    // Just above the top-most layer (below the layer bar and other chrome).
    val top = layers.maxOf { root.indexOfChild(it) }
    val params = FrameLayout.LayoutParams(box.width(), box.height(), Gravity.TOP or Gravity.START).apply {
      leftMargin = box.left
      topMargin = box.top
    }
    if (cover.parent !== root || root.indexOfChild(cover) != top + 1) {
      if (cover.parent === root) root.removeView(cover)
      val index = layers.maxOf { root.indexOfChild(it) } + 1
      root.addView(cover, index.coerceAtMost(root.childCount), params)
    } else {
      cover.layoutParams = params
    }
    if (isFilterStageActive) scheduleFilterStageRefresh()
  }

  /** Tilt-shift / background blur (photo only) — see PhotoBlur. */
  private var blur = PhotoBlur()
  private var blurOverlayRef: BlurFocusOverlayView? = null
  private val blurModeButtonRefs = mutableMapOf<PhotoBlur.Mode, TextView>()
  private var blurStrengthSeekBarRef: SeekBar? = null
  private var isSyncingBlurControls = false
  // Preview cache: the blurred copy only depends on the source + strength,
  // so dragging the sharp area just re-composites (cheap).
  private var blurCacheSource: Bitmap? = null
  private var blurCacheStrength = -1f
  private var blurCacheSmall: Bitmap? = null
  private var blurPreviewOutput: Bitmap? = null
  private var selectedAdjustProperty: AdjustProperty? = null
  private var adjustIconRowRef: View? = null
  private var adjustDetailRowRef: View? = null
  private val adjustSliderRowRefs = mutableMapOf<AdjustProperty, View>()
  /** Maps each filter to its rendered circular thumbnail — used both to
   *  fill in the live-rendered preview once the photo decodes
   *  (renderFilterThumbnails) and to draw the selected-state ring border
   *  (updateFilterButtonHighlight). */
  private val filterButtonRefs = mutableMapOf<PhotoFilter, ImageView>()

  // Text entry overlay — an on-canvas EditText with a font/colour/style
  // toolbar above the keyboard. Fonts are the bundled set in
  // TextFontCatalog (same files as iOS), drawn by TextLayerRenderer.
  private val textColorSwatches = listOf(
    Color.WHITE, Color.BLACK, Color.rgb(0x7C, 0x4D, 0xFF), Color.RED, Color.YELLOW, Color.BLUE,
    Color.parseColor("#34C759"), // green
    Color.parseColor("#FF9500"), // orange
    Color.parseColor("#FF2D55"), // pink
    Color.parseColor("#30B0C7"), // teal
    Color.parseColor("#AF52DE"), // purple
    Color.parseColor("#8E8E93"), // gray
    // Expanded from 12 to 18 per the user's explicit "add more colors"
    // follow-up — same hex values as iOS's textColorSwatches additions,
    // for visual parity.
    Color.parseColor("#5856D6"), // indigo
    Color.parseColor("#00C7BE"), // mint
    Color.parseColor("#32ADE6"), // cyan
    Color.parseColor("#A2845E"), // brown
    Color.parseColor("#B8860B"), // gold
    Color.parseColor("#FF00FF"), // magenta
  )
  private var textEntryOverlayRef: View? = null
  private var textEntryToolbarRef: View? = null
  private var textEntryEditTextRef: EditText? = null
  /** The look being chosen in the text-entry sheet. When editing an
   *  existing layer it starts from that layer's style, so the Style
   *  panel's settings (outline, arch…) are kept. */
  private var textEntryStyle = TextLayerStyle()
  private val textFontButtonRefs = mutableListOf<TextView>()
  private val textColorButtonRefs = mutableListOf<View>()
  private var textBoldButtonRef: TextView? = null
  private var textItalicButtonRef: TextView? = null
  private var textUnderlineButtonRef: TextView? = null
  private var textAlignButtonRef: EditorIconView? = null
  private var textBackgroundButtonRef: EditorIconView? = null

  // Text Style panel (Size / Outline / Shadow / Opacity / Stretch / Arch),
  // opened from the selected text layer's toolbar. Changes apply live to
  // the layer; one undo step is recorded when the panel closes. Same as iOS.
  private enum class TextStyleTool(val title: String) {
    FILTERS("Filters"), LIGHT("Light"), COLOR("Color"),
    SIZE("Size"), OUTLINE("Outline"), SHADOW("Shadow"), OPACITY("Opacity"), STRETCH("Stretch"), ARCH("Arch"),
    BLEND("Blend"), SHAPE("Shape"), BORDER("Border"), FLIP("Flip"), ERASER("Eraser"), CROP("Crop");

    companion object {
      val textTools = listOf(SIZE, OUTLINE, SHADOW, OPACITY, STRETCH, ARCH)
      val stickerTools = listOf(OPACITY, OUTLINE, SHADOW, FLIP)
      val overlayTools = listOf(FILTERS, LIGHT, COLOR, OPACITY, BLEND, SHAPE, BORDER, FLIP, ERASER, CROP)
    }
  }
  private class TextStyleSliderSpec(
    val title: String,
    val min: Int,
    val max: Int,
    val defaultValue: Int,
    val get: () -> Float,
    val set: (Float) -> Unit,
  )
  /** The look being edited — a text layer's, a sticker's or an overlay's
   *  (the same panel serves all three; one undo step per panel session). */
  private sealed class LayerStyleSnapshot {
    data class Text(val style: TextLayerStyle) : LayerStyleSnapshot()
    data class Sticker(val style: StickerStyle) : LayerStyleSnapshot()
    data class Overlay(val style: OverlayStyle, val strokes: List<OverlayEraseStroke>) : LayerStyleSnapshot()
  }
  /** An overlay's unstyled photo, uncropped source (for re-crop), look and
   *  eraser strokes; the ImageView shows the rendered result. */
  private class OverlayState(
    var base: Bitmap,
    var source: Bitmap?,
    var style: OverlayStyle,
    var strokes: List<OverlayEraseStroke>,
    var coloredKey: String? = null,
    var colored: Bitmap? = null,
  )
  private val overlayStates = mutableMapOf<ImageView, OverlayState>()
  private var overlayFilterThumbnails: Pair<Bitmap, Map<PhotoFilter, Bitmap>>? = null
  private var overlayEraseRestoreMode = false
  private var overlayEraserWidthDp = 28f
  private var overlayEraseCaptureRef: OverlayEraseCaptureView? = null
  private var textStyleChipRowRef: LinearLayout? = null
  private var textStyleChipScrollRef: View? = null
  private class TextStyleSliderRow(val view: View, val title: TextView, val seekBar: SeekBar, val value: TextView)
  private var textStylePanelRef: SlideUpPanelView? = null
  private var textStyleTarget: View? = null
  private var textStyleAtOpen: LayerStyleSnapshot? = null
  private var selectedTextStyleTool = TextStyleTool.SIZE
  private val textStyleToolRefs = mutableMapOf<TextStyleTool, Pair<View, Pair<TextView, View>>>()
  private val textStyleSliderRows = mutableListOf<TextStyleSliderRow>()
  private var textStyleFlipRowRef: View? = null
  private var isSyncingTextStyleSliders = false
  /** Look of each bundled-sticker layer (absent = default). */
  private val stickerStyles = mutableMapOf<TextView, StickerStyle>()
  private var stickerSearchRef: EditText? = null
  private val stickerCategoryTabRefs = mutableListOf<Pair<TextView, View>>()
  private var stickerGridRef: LinearLayout? = null
  private var stickerGridScrollRef: ScrollView? = null
  private var selectedStickerCategory = 0

  /** Reserved geometry for the top icon bar and bottom controls (tab bar +
   *  effects panel), used to size/center the canvas in its own dedicated
   *  area — see setUpImageEditingControls and layoutImageCanvas. */
  /** [bottomChromeHeightPx] is JUST the bottom tab tray's own height — the
   *  reference point every video-controls view (filmstripBand,
   *  playPauseButton, layerTracksScrollView, Split/Delete, the
   *  backdrop...) positions its OWN bottomMargin against, so it must stay
   *  exactly that and nothing more, or every one of those views would
   *  shift up/down right along with it. [canvasBottomReservationPx] is
   *  the SEPARATE, canvas-only value layoutImageCanvas actually sizes the
   *  box against — bottomChromeHeightPx PLUS the video-controls band's
   *  own base height (video only) — kept as its own field specifically
   *  so the two concerns (where do the CONTROLS sit vs. how much room
   *  does the CANVAS get) can never accidentally collapse into one again
   *  the way an earlier version of this fix briefly did. */
  private data class ImageCanvasChrome(
    val contentTopPx: Int,
    val bottomChromeHeightPx: Int,
    val canvasBottomReservationPx: Int,
    val horizontalMarginPx: Int,
  )

  // Kept alongside the local `val imageView` in onCreate so export (which
  // runs from finishSuccess, outside onCreate's scope) can read the
  // image's current transform. Null for video.
  private var imageViewRef: ImageView? = null
  /** A non-interactive sibling of imageView, always sized/positioned to
   *  match it exactly (see layoutImageCanvas) — a radial-gradient darkening
   *  drawn as a plain Drawable background rather than baked into the
   *  bitmap, so the vignette preview is cheap/live (no bitmap
   *  regeneration) the same way the ColorMatrix-based adjustments are. */
  private var vignetteOverlayRef: View? = null
  /** Static center crosshair, purely a visual aid (per the user's explicit
   *  request) — non-interactive, sized/positioned to match imageView (image)
   *  or playerView (video) exactly, same pattern as vignetteOverlayRef. */
  private var gridOverlayRef: View? = null
  private var topSafeAreaCoverRef: View? = null
  private var bottomSafeAreaCoverRef: View? = null
  /** The 4 letterbox-gutter covers described where they're created —
   *  positioned/sized in layoutImageCanvas. */
  private var canvasGutterTopRef: View? = null
  private var canvasGutterBottomRef: View? = null
  private var canvasGutterLeftRef: View? = null
  private var canvasGutterRightRef: View? = null
  /** The 3 "always visible" chrome pieces (top bar w/ Cancel/Undo/Redo/
   *  Done, bottom tab tray, Filters+Adjust strip) — all added to `root`
   *  early in setUpEditingControls, BEFORE any text/sticker/overlay layer
   *  a user adds later at runtime, so without re-fronting them (see
   *  keepSafeAreaCoversOnTop) a big enough layer renders ON TOP of them,
   *  hiding Cancel/Undo/Redo/Done — user-reported bug, 2026-08-17. */
  private var topBarRef: View? = null
  private var bottomTrayRef: View? = null
  /** Story-mode-only right-edge vertical icon rail (Text/Stickers/Filters/
   *  Overlay/Draw/Audio/Download) — null in the regular (non-story) chrome. */
  private var storyRailRef: View? = null
  /** Story-mode-only "now playing" badge (top-center, over the canvas) —
   *  shows the selected track's title + a play/pause toggle + a remove
   *  (X) button. Purely additive to story mode; the regular (non-story)
   *  editor's own Music tab/tray/panel (musicTrackCardRef etc.) is
   *  untouched by this and stays exactly as before. Null in the regular
   *  chrome, and also null (not built) whenever isStoryMode is false. */
  private var storyMusicBadgeRef: View? = null
  private var storyMusicBadgeTitleRef: TextView? = null
  private var storyMusicBadgePlayPauseIconRef: EditorIconView? = null
  // Story rail's Mute/unmute toggle (video only) — see toggleStoryOriginalAudioMute.
  private var storyMuteIconRef: EditorIconView? = null
  /** Story badge's music pause — kept until the user taps play again (or
   *  picks another track), so playback sync doesn't undo it. */
  private var isStoryMusicPausedByUser = false
  private var doneButtonRef: View? = null
  private var exportLoadingIndicatorRef: ProgressBar? = null
  // Shown while adding a second/merged video clip — matching iOS parity
  // (its own file-copy-out-of-Photos step is genuinely slow; Android's
  // content URI resolves fast, but per the user's explicit "make it same
  // for Android also" request this stays visible for the same brief
  // window regardless, in case a cloud-backed URI needs a moment).
  private var addVideoLoadingIndicatorRef: ProgressBar? = null
  // Guards against tapping Done again while an export is already running —
  // without this, repeated taps (e.g. while waiting on a slow export with
  // no visible progress) stack up multiple concurrent exports competing
  // for the same CPU, each taking even longer.
  private var isExporting = false
  /** True while the preview players are stopped for an export (their
   *  decoders freed for Transformer). Cancel restarts them. */
  private var previewStoppedForExport = false
  /** The video file the running export writes (deleted on Cancel). */
  private var activeExportOutputFile: File? = null
  // The in-flight export's own Transformer + progress-poll loop, exposed
  // at class scope (not local to exportVideoOnMainThread) so the
  // ExportProgressOverlayView's cancel button — a totally separate call
  // site — can actually stop it, not just hide the overlay while the
  // export secretly keeps running underneath.
  private var activeTransformer: Transformer? = null
  private var exportProgressHandler: Handler? = null
  private var exportProgressOverlayRef: ExportProgressOverlayView? = null

  // Video (Milestone 3). A fresh, dedicated ExoPlayer per editor session —
  // deliberately not routed through the app's IAVideoPlayerManager
  // singleton, which solves keeping ONE player alive across mount/unmount
  // for the feed's inline↔fullscreen↔PiP handoffs. The editor is a single
  // full-screen session with its own trim/seek controls; there's no handoff
  // to design for, so a dedicated player is simpler and has no shared state
  // with feed playback. Still the same media3/ExoPlayer engine already used
  // by IAVideo, just a separate instance.
  private var exoPlayer: ExoPlayer? = null
  private var timelinePollCleanup: (() -> Unit)? = null
  private var videoTrimViewRef: VideoTrimView? = null
  private var playPauseButtonRef: View? = null
  /** Video redesign: "0:04 / 0:18" beside play/pause. */
  private var videoTimeLabelRef: TextView? = null
  private var lastVideoTimeLabelText = ""
  private var splitSegmentButtonRef: View? = null
  private var deleteSegmentButtonRef: View? = null
  /** Translucent scrim behind the play/pause + trim scrubber (+ Split/
   *  Delete) row — this row already floats directly over the video's own
   *  bottom edge (see chrome.bottomChromeHeightPx, which reserves only the
   *  bottom tab tray, not a dedicated row for these controls), per the
   *  user's explicit "display these layer above video layer" request.
   *  Darkens the video behind the controls without intercepting touches
   *  meant for the buttons/scrubber above it. */
  private var videoControlsBackdropRef: View? = null
  /** `chrome.bottomChromeHeightPx` from setUpEditingControls, recorded
   *  once so refreshLayersPanel() (called later, outside that function's
   *  scope) can recompute every margin that's anchored against it. */
  private var videoChromeBottomHeightPx: Int = 0
  /** Fixed distance (from root's bottom) up to where the layer tracks
   *  area's own bottom edge sits — directly above the trim scrubber row,
   *  unaffected by row count. Split/Delete + the collapse chevron now
   *  sit ABOVE the tracks (not between them and the trim row — per the
   *  user's explicit "keep split and delete icon on top right side of
   *  all layer, not in the middle" correction), so their own margins are
   *  this plus however tall the tracks currently are — recomputed in
   *  refreshLayersPanel() every time that height changes. */
  private var layerTracksFixedBottomMarginPx: Int = 0
  /** Same bottomMargin filmstripBandRef itself uses (chrome height + the
   *  gap above it) — stashed so refreshLayersPanel() can size
   *  layerTracksPlayheadRef's height against it without needing
   *  setUpEditingControls's own local vars (trimViewHeightPx etc.), which
   *  aren't in scope there. See layerTracksPlayheadRef's own doc. */
  private var filmstripBandBottomMarginPx: Int = 0
  /** Per the user's explicit "if layers are active these video preview
   *  goes smaller... and if we minimise with a drop-down icon then video
   *  displays full screen" request. Deliberately does NOT resize the
   *  canvas itself (layoutImageCanvas sizes it once from the media's own
   *  aspect ratio — moving it would desync text/sticker layer positions
   *  from the export math, same reasoning as iOS's canvasClipContainerView
   *  doc). Instead this toggles videoControlsBackdropRef between a small
   *  translucent scrim (collapsed — the floating-over-video look already
   *  built) and a tall OPAQUE panel that visually reads as a dedicated
   *  area below the video, even though it's still the same overlay
   *  z-order mechanism. Defaults to expanded (false) so the very first
   *  layer added auto-expands; see registerLayerTiming's "first layer"
   *  reset. */
  private var isLayersAreaCollapsed = false
  private var layersAreaCollapseButtonRef: View? = null
  private var layersAreaCollapseLabelRef: TextView? = null
  private var layersAreaCollapseIconRef: EditorIconView? = null
  // Ordered, non-overlapping, ascending KEPT ranges of the original video
  // — replaces a single trimStartMs/trimEndMs pair per the user's
  // explicit "split into parts, delete any of them" request. Always at
  // least one element once duration is known (see the timelineRunnable
  // below).
  private var videoSegments: List<LongRange> = emptyList()
  // Extra videos the user picked to APPEND after the primary clip, in the
  // order added, per the user's explicit "doesn't matter how many video,
  // all video clips will be added to same video layer and will be played
  // in queue, same like Instagram" request. Each plays in FULL (no split/
  // trim/pan/zoom/filter/adjustments/text overlays of its own — those stay
  // primary-clip-only) but genuinely queues in both the live ExoPlayer
  // preview (via addMediaItem/removeMediaItem, see presentVideoClipPicker)
  // and the exported file (see exportVideo). Empty means no merge pending.
  private val additionalVideoClipUris = mutableListOf<String>()
  // Evenly time-sampled frames across each clip's OWN full real duration
  // (same tileCount/sampling formula as VideoTrimView.loadThumbnails) —
  // replaces a single frame-at-0 that used to get stretched/cropped
  // across a merged clip's entire (often much wider, and after a split,
  // per-segment) bar, per the user's explicit "video thumbnail should
  // not look zoomed... only show thumbnail up to exact same real timing
  // of video clip" report: a single far-off-aspect frame center-cropped
  // to fill a wide/narrow bar reads as an extreme, meaningless zoom, and
  // never actually reflected which real moment of the clip a given part
  // of the bar represents.
  private val additionalClipThumbnailTiles = mutableMapOf<String, List<Bitmap>>()
  private val mergedClipThumbnailTileCount = 8
  // Each clip's own real (untrimmed) duration, loaded async once per clip
  // — needed synchronously by refreshMergedClipsStrip's anchor math, so
  // it's cached here rather than re-derived on demand.
  private val additionalClipDurationsMs = mutableMapOf<String, Long>()
  // Per-merged-clip KEPT segments (each start..end in that clip's OWN
  // local ms, ordered/non-overlapping/ascending) — missing entry means
  // "not yet trimmed/split, use the full clip", per the user's explicit
  // "I want to adjust, trim... like Instagram" follow-up, later extended
  // to full multi-segment split/delete parity with the primary clip (per
  // the user's explicit "split/delete should work on merged clips too"
  // request) — mirrors `videoSegments`'s own model exactly, just keyed
  // per clip instead of there being only one. Set via mergedStripViewRef's
  // onRangeChanged (dragging directly on the seamless filmstrip row —
  // see refreshMergedClipsStrip's own doc) and by
  // splitActiveMergedClipSegment/deleteActiveMergedClipSegment; read by
  // makeAdditionalPlaylistMediaItems (both live preview and export),
  // which turns each kept segment into its OWN clipped MediaItem placed
  // consecutively in the playlist/sequence — ExoPlayer/Media3's own
  // native way to concatenate, needing no composition-bake the way iOS
  // does, and exactly why a merged clip needs no runtime gap-skip logic
  // of its own: each segment is already its own separate playlist entry.
  private val additionalClipSegments = mutableMapOf<String, MutableList<LongRange>>()
  // One stable, never-displayed View per clip — see proxyView(uri)'s own
  // doc for why this exists.
  private val additionalClipProxyViews = mutableMapOf<String, View>()
  // Per-clip anchor (sum of KEPT — not full — durations of clips before
  // it) as of the last refreshMergedClipsStrip() call — recomputed there,
  // read by mergedStripViewRef's onRangeChanged closure (set up once, so
  // unlike the old makeAdditionalClipsRow it can't just capture a local
  // var at creation time). Using kept (not full) duration is what makes
  // clips pack back-to-back with zero gap — an earlier version anchored
  // on full duration, which left a permanent gap sized to whatever had
  // been trimmed off the PRECEDING clip, straight contradicting the
  // "single continuous filmstrip" goal.
  // One anchor per KEPT SEGMENT now (was one per clip, back when a clip
  // only ever had a single kept span) — segmentAnchorsMs[uri]!![i] is
  // segment i's own fixed slot start as of the last refresh.
  private var mergedClipSegmentAnchorsMs: MutableMap<String, List<Long>> = mutableMapOf()
  // The exact segments list each clip's anchors/items were built from —
  // captured once per refreshMergedClipsStrip() call so onRangeChanged's
  // repeated per-tick delta math (see its own doc) has a STABLE reference
  // to add deltas to, rather than the live, already-mutating
  // additionalClipSegments map (which would double-count/drift across
  // ticks within the same drag). Also doubles as the clamp bound that
  // keeps one segment's edge-drag from crossing into an adjacent
  // segment's own space within the same clip.
  private var mergedClipReferenceSegmentsMs: MutableMap<String, List<LongRange>> = mutableMapOf()
  // Which merged-clip segment (if any) the user last TAPPED — the Delete
  // button's target when the active clip (not a layer) is what's
  // selected, mirroring videoTrimViewRef.selectedSegmentIndex/
  // selectedLayerSegmentIndex's identical role for the other two "what
  // should Delete act on" contexts.
  private var selectedMergedClipUri: String? = null
  private var selectedMergedClipSegmentIndex: Int? = null
  // Merged clips render as a direct, zero-gap continuation of
  // videoTrimViewRef's own filmstrip (one seamless strip, per the user's
  // explicit "true single continuous filmstrip" choice) rather than a
  // separate row in the Layers panel — see refreshMergedClipsStrip's own
  // doc. Single persistent instances, unlike the old makeAdditionalClipsRow
  // (which rebuilt a brand-new LayerRangeBarView every call) — reusing one
  // instance means an in-progress drag's own gesture is never at risk from
  // a mid-gesture rebuild.
  private var mergedStripViewRef: LayerRangeBarView? = null
  // videoTrimView/mergedStripView are children of filmstripScrollViewRef's
  // content row now (see setUpEditingControls) — bringToFront needs to
  // move the SCROLL VIEW itself, not its individual children, to affect
  // z-order relative to OTHER root-level siblings.
  private var filmstripRowContainerRef: View? = null

  // MARK: Instagram-style scrollable combined timeline
  //
  // Per the user's explicit reference screenshot + "full Instagram-style
  // scrolling timeline" choice: the WHOLE combined filmstrip (primary
  // clip's own kept segments + every merged clip's own kept range, still
  // packed back-to-back with zero gap exactly as before) now lives inside
  // a horizontally scrollable container at a FIXED pixels-per-second
  // scale, with a playhead line fixed at the visible viewport's own
  // center — scrolling the strip IS scrubbing, rather than the strip
  // resizing to fit a fixed viewport with an internal moving playhead
  // (the prior design). videoTrimViewRef/mergedStripViewRef's own
  // internal coordinate math (xFor/xForCompacted) needed NO changes for
  // this — both already derive positions purely from their own width and
  // durationMs, which now just happens to be set from a fixed pixel scale
  // instead of "fit available space."
  /** Pinch the timeline to zoom (Edits / CapCut style): 10–240 dp/s,
   *  default 40. Same as iOS. */
  private var timelineZoomDp = 40f
  private val timelinePointsPerSecondPx get() = timelineZoomDp * resources.displayMetrics.density
  private var filmstripScrollViewRef: HorizontalScrollView? = null
  // The actual direct child of `root` (filmstripScrollView + the fixed
  // playhead line are BOTH nested inside this) — bringToFront on
  // filmstripScrollViewRef itself only reorders it among filmstripBandRef's
  // own children, which has ZERO effect on its z-order relative to OTHER
  // direct children of `root` (like videoControlsBackdropRef) — that's
  // exactly the bug that let the backdrop's own bringToFront (needed so
  // it stays above on-canvas text/sticker/overlay layers) end up ABOVE
  // this whole band once it turns opaque, hiding the video row entirely.
  private var filmstripBandRef: View? = null
  private var filmstripPlayheadRef: View? = null
  /** A second, separate white line directly above filmstripPlayheadRef,
   *  spanning just the (dynamically-sized) layer-tracks area — a direct
   *  child of `root` sharing filmstripBandRef's own left/right margins and
   *  horizontal centering, so together the two views read as ONE
   *  continuous playhead line running through every row (video, text,
   *  sticker, music), not just the video filmstrip. Per the user's
   *  explicit "same [playhead] line should display on all layers also"
   *  report. Height/bottomMargin recomputed in refreshLayersPanel()
   *  every time the tracks area's own height changes (see
   *  filmstripBandBottomMarginPx's doc). */
  private var layerTracksPlayheadRef: View? = null
  // True only while the user's own finger is actively dragging/
  // decelerating the filmstrip — distinguishes a user-driven scrub (which
  // should both update the highlight AND, once released, actually seek
  // the player) from our OWN programmatic scrollTo calls that follow
  // hands-off playback (which should only update the highlight, never
  // re-trigger a seek — that would fight the player driving itself). Per
  // the user's explicit "make it auto scroll with video timing... once
  // user touch editor then stop scrolling" request, the filmstrip
  // auto-follows playback continuously (including across the queue's own
  // existing loop-back-to-start behavior) until this becomes true.
  private var isUserScrubbingFilmstrip = false
  // Separate from isUserScrubbingFilmstrip above, which the settle-check
  // runnable can (incorrectly) flip back to false mid-gesture: that check
  // only looks at "has scrollX stopped changing for 100ms", which a slow,
  // deliberate drag can satisfy during a brief in-gesture pause even
  // though the finger never actually lifted. Without this SEPARATE,
  // touch-event-driven flag, that false "settle" let the periodic
  // playback-follow poll below immediately yank the scroll back to the
  // player's actual (unchanged) position while the user was still mid-
  // drag — per the user's explicit "unable to scroll main video layer
  // from trailing side to heading side... snaps back" report. Set true
  // on ACTION_DOWN, false on ACTION_UP/CANCEL — the poll must stay
  // suppressed for as long as the finger is physically down, regardless
  // of what the scrollX-stability heuristic thinks.
  private var isFilmstripFingerDown = false
  // Set whenever the settle-check triggers seekCombinedTimeline (the
  // scroll came to rest and we're moving the player to match) — cleared
  // 400ms later. ExoPlayer's seekTo is ASYNCHRONOUS, and a seek that
  // crosses from one playlist item into another (e.g. scrolling from the
  // second merged clip back into the primary clip) lands noticeably
  // slower than a same-item seek; player.currentPosition/
  // currentMediaItemIndex keep reporting the OLD (pre-seek) position
  // until it actually completes. Without this cooldown, the periodic
  // playback-follow poll a few lines below could resume during that
  // window, read the stale pre-seek position, and yank the scroll back
  // to where the user scrolled FROM — repeatedly, once per poll tick,
  // until the seek finally landed — per the user's explicit "it came
  // back to it again and again" follow-up (the isFilmstripFingerDown fix
  // above solved the WHILE-DRAGGING case; this solves the AFTER-THE-
  // SCROLL-SETTLES case).
  private var filmstripSeekCooldownUntilMs = 0L
  // The REAL root cause behind "scroll back into the primary clip while
  // on a merged clip snaps forward again and again": nothing ever paused
  // the engine while the user scrubbed, so playback just kept running
  // forward in real time from wherever a seek landed — and since the user
  // is scrolling BACKWARD out of a later merged clip, any seek target is,
  // by definition, close to the primary clip's own tail (right next to
  // where the merged clip picks up), so a few hundred ms of continued
  // real playback was enough to re-reach that boundary and trigger the
  // existing "advance to the next queued clip" gap-skip logic — which is
  // what actually snapped the timeline back, over and over, for as long
  // as the user kept retrying. Set true on filmstrip ACTION_DOWN only if
  // playback was actually running at that moment; playback resumes on
  // ACTION_UP/CANCEL and this resets to false either way.
  private var wasPlayingBeforeFilmstripScrub = false
  // nil = the primary clip is the one currently highlighted/active.
  private var activeClipUri: String? = null
    set(value) {
      val changed = field != value
      field = value
      updateVideoSelectionLabel()
      // Per-clip volume / speed follow whichever clip is playing.
      if (changed) {
        exoPlayer?.volume = effectivePlayerVolume()
        applyPreviewSpeed()
      }
    }
  private var filmstripSettleCheckRunnable: Runnable? = null

  // Per-layer active time range + manual-hide state, per the user's
  // explicit "extend and reduce each layer's duration, just like
  // Instagram" request. Keyed by the layer View itself (View has no
  // custom equals()/hashCode(), so this is reference-identity keying,
  // same as iOS's ObjectIdentifier) rather than adding a field to
  // TextView/ImageView directly — those are plain platform types with no
  // room for a new property, and a side-map works uniformly for both.
  // Deliberately SEPARATE from the existing GONE-based soft-delete (see
  // deleteLayer) — combining both into one flag would make "deleted" and
  // "currently outside its time range" indistinguishable, breaking
  // undo/redo.
  // Multiple, non-overlapping segments per layer, mirroring how the
  // primary video's own [videoSegments] supports split/delete. Always
  // non-empty; splitting divides one entry into two adjacent ones
  // (splitLayerSegment), deleting removes just one entry
  // (deleteLayerSegment) unless it's the last, which deletes the whole
  // layer instead (a layer with 0 segments is meaningless).
  private data class LayerTiming(
    var segments: MutableList<LongRange>,
    /** Per-layer hide (eye button): invisible in the preview AND left out
     *  of the export, but still on its track so it can be shown again. */
    var isManuallyHidden: Boolean = false,
    /** Per-layer lock: no move/resize/rotate on the canvas, no trim/move on
     *  its track, no split/delete/edit. Reordering still works. */
    var isLocked: Boolean = false,
    /** Text animations (text layers): see TextAnimation for the types. */
    var anim: TextAnimConfig = TextAnimConfig.NONE,
  )
  private val layerTimings = mutableMapOf<View, LayerTiming>()
  /** Which of [selectedLayerView]'s own segments (if split) was last
   *  tapped in the layer-tracks row — Delete targets THIS one specifically
   *  when set (see deleteLayerSegment); null falls back to whichever
   *  segment contains the current playhead. Reset to null whenever
   *  selection changes via any OTHER path (canvas tap, duplicate, etc.)
   *  so a stale segment from a previously-selected layer never leaks into
   *  a new selection. */
  private var selectedLayerSegmentIndex: Int? = null
    set(value) { field = value; syncLayerTrackSelection() }
  /** Per-layer track rows — per the user's explicit "as we are getting
   *  these both layers in a separate Layers tab... display these both
   *  layers on screen" correction, these no longer live behind their own
   *  tab (there is no more LAYERS case in ImageEditorTab, or a Layers
   *  SlideUpPanelView): they're stacked directly above the Split/Delete +
   *  trim scrubber row, always visible on the Tools tab, matching the
   *  reference multi-track timeline where every layer's own track sits
   *  above the base video track in the same view. */
  private var layerTracksStackRef: LinearLayout? = null
  /** Layer row → its canvas layer view (rebuilt in refreshLayersPanel). */
  private val layerTrackRowOwners = mutableMapOf<View, View>()
  /** Whether the last refreshLayersPanel folded the tracks for Tune. */
  private var layersHiddenForTool = false
  /** "+ Layer" — opens the Add layer sheet (video, non-story). */
  private var addLayerButtonRef: View? = null
  /** Video: hold-to-compare in the play/split/delete row, left of "+". */
  private var videoCompareButtonRef: View? = null
  // Hide / lock for the selected text/sticker/photo layer — shown in the
  // play/split/delete row (in place of the selection label) while a layer
  // is selected.
  private var layerHideButtonRef: FrameLayout? = null
  private var layerLockButtonRef: FrameLayout? = null
  private var layerHideIconRef: EditorIconView? = null
  // Clip management (roadmap row 29): duplicate + per-clip volume, shown in
  // the same slots while a clip segment is selected on the video row.
  private var clipVolumeButtonRef: FrameLayout? = null
  private var clipVolumeIconRef: EditorIconView? = null
  /** Per-clip volume (0…1, default 1) × the original-audio volume, in the
   *  preview and the export. Key = clip URI (mediaUri = main clip). */
  private val clipVolumes = mutableMapOf<String, Float>()
  /** Speed control (roadmap row 28): per PART of a clip, like CapCut /
   *  Edits — split a clip and each part gets its own speed. Stored per clip
   *  as source-time spans; a part plays at the newest span covering its
   *  middle (default 1x), so both halves of a split keep the part's speed
   *  and split / delete / trim / undo need no bookkeeping here. */
  private data class SpeedSpan(val range: LongRange, val speed: Float)
  private val speedSpans = mutableMapOf<String, MutableList<SpeedSpan>>()
  /** Fade in/out audio (video editor): 1s ramps on the music (where it
   *  starts / ends) and the clip's own sound (video start / end). */
  private var audioFadeIn = false
  // Voice-over (one narration track, recorded from the playhead).
  private var voiceOverPath: String? = null
  /** Editor-made temp files (voice recordings, export silence gaps) —
   *  deleted in onDestroy; the exported file itself is never listed. */
  private val tempFilesToDelete = mutableListOf<File>()
  // Beat sync: beats of the chosen song (song time, ms) and the switch.
  private var musicBeatsMs: List<Long> = emptyList()
  private var beatSnapEnabled = false
  private var beatSyncNoteRef: TextView? = null
  private var skipNextBeatSnap = false
  /** Where it starts on the combined timeline, and its length. */
  private var voiceOverStartMs = 0L
  private var voiceOverDurationMs = 0L
  private var voicePlayer: android.media.MediaPlayer? = null
  private val voiceProxyView by lazy { View(this) }
  private var isVoiceRowSelected = false
    set(value) {
      field = value
      if (!value) voiceRangeBarRef?.setSelection(null, null)
    }
  /** The voice-over track's bar — its body drags only while selected. */
  private var voiceRangeBarRef: LayerRangeBarView? = null
  private var voiceRecorder: android.media.MediaRecorder? = null
  private var voiceRecorderPanelRef: View? = null
  private var voiceRecorderTimeRef: TextView? = null
  private var voiceRecordIconRef: EditorIconView? = null
  private var voiceRecordingStartMs = 0L
  private var voiceRecordingWallStart = 0L
  private var voiceRecordingPath: String? = null
  private val voiceRecordHandler = Handler(Looper.getMainLooper())
  private var audioFadeOut = false
  private var clipSpeedButtonRef: FrameLayout? = null
  private var clipSpeedIconRef: EditorIconView? = null
  /** Transitions (roadmap row 33): INTO a merged clip from the clip before
   *  it (1 fade, 2 slide, 3 zoom). Keyed by clip, so it moves with it. */
  private val transitionsIn = mutableMapOf<String, Int>()
  private var clipTransitionButtonRef: FrameLayout? = null
  private var clipTransitionIconRef: EditorIconView? = null
  /** Text animations: shown in compare's spot while a text layer is selected. */
  private var textAnimationButtonRef: FrameLayout? = null
  private var textAnimationIconRef: EditorIconView? = null
  private var clipVolumePanelRef: View? = null
  private var clipVolumeEditUri: String? = null
  private var layerLockIconRef: EditorIconView? = null
  private var addLayerSheetRef: View? = null
  /** The ScrollView wrapping [layerTracksStackRef] — its height is
   *  recomputed in refreshLayersPanel() to fit the current row count (up
   *  to a cap), and videoControlsBackdropRef's own height/position is
   *  recomputed alongside it so the scrim always covers exactly this plus
   *  the row cluster below it. */
  private var layerTracksScrollViewRef: View? = null

  // Kept alongside imageViewRef above so export (which also
  // runs from finishSuccess, outside onCreate's scope) can read the
  // video's current pan/zoom/rotate (its own translationX/Y/scaleX/Y/
  // rotation View properties, set directly by LayerGestureCoordinator —
  // there's no separate tracked state to read, unlike iOS). Null for image.
  private var playerViewRef: PlayerView? = null
  /** First frame, decoded once when the editor opens — the export box's
   *  fallback picture. */
  private var videoPosterFrame: Bitmap? = null

  // Music (Milestone 4, Day 23) — selection + preview only for now; baking
  // into the export (Day 25/26) lands later. A second, independent
  // ExoPlayer mixes with the main player's audio via the system's audio
  // mixer automatically — no manual mixing for preview.
  // Package-visible (not private): MusicApi.kt constructs these directly
  // from the live iTunes fetch, same as MediaEditorActivity's own bridge-
  // provided list did before.
  data class MusicTrack(
    val id: String,
    val title: String,
    val artist: String,
    val albumArt: String,
    val audioUrl: String,
    // 0 for tracks handed in from the RN bridge (staticMusicData.ts never
    // carried a duration) — only MusicApi's live iTunes-backed fetch
    // populates this, for the picker row's duration label.
    val durationMs: Long = 0,
  )
  private var musicTracks: List<MusicTrack> = emptyList()
  private var selectedMusicTrack: MusicTrack? = null
  private var musicPlayer: ExoPlayer? = null

  // Day 24 — music volume + trim. Trim reuses VideoTrimView exactly as-is
  // (already generic over "a duration + start/end handles + scrub"). Like
  // the main video's own trim (Day 18), this only tracks
  // musicTrimStartMs/EndMs as state for the
  // export to consume later (Day 25/26) — it doesn't clamp preview playback
  // to the range, same accepted limitation as the main trim.
  private var musicVolume = 1f
  // Trim UI removed per the user's explicit "remove this music trimmer"
  // request — these now just always span the full track (set once the
  // track's real duration resolves, see selectMusicTrack), so export
  // (which still reads them) always uses the whole song rather than a
  // user-picked portion.
  private var musicTrimStartMs: Long = 0
  private var musicTrimEndMs: Long = 0
  private var musicVolumeRowRef: View? = null

  // Music-as-a-layer (per the user's explicit "add one dedicated layer of
  // music... user can scroll and drag to change position" request) — WHEN
  // in the combined video timeline the (already-trimmed, musicTrimStartMs/
  // EndMs) song begins playing. The kept song duration itself stays
  // whatever the Music panel's own trim view says; this offset only
  // shifts its position, via the layer row's body-drag (see
  // LayerRangeBarView.allowBodyDrag). Distinct from musicTrimStartMs
  // (which portion of the SONG FILE plays) — this is where on the VIDEO
  // that portion starts.
  private var musicOffsetMs: Long = 0
  // One stable, never-displayed View used purely as this row's Item.id —
  // mirrors proxyView(uri)'s identical pattern for merged clips, needed
  // because LayerRangeBarView.Item.id is typed as View and music has no
  // real on-canvas view of its own.
  private val musicProxyView: View by lazy { View(this) }
  // Per the user's explicit "same split music layer also" request — the
  // music row can now be split/have portions deleted exactly like a text/
  // sticker layer's own segments. These are combined-timeline windows
  // during which the music is actually audible; a gap between two
  // segments (from deleting the one between them) mutes the song during
  // that window without skipping ahead in it — see
  // updateMusicPlaybackWindow/exportVideo's own music-loop doc for the
  // "anchor at segments[0]" continuity math. musicOffsetMs above still
  // tracks segments[0]'s own start (kept in sync on every edit) since
  // several existing call sites read it directly.
  private val musicSegments = mutableListOf<LongRange>()
  // Non-null ONLY while the music row (not a canvas layer, video segment,
  // or merged clip) is the current Split/Delete target — mutually
  // exclusive with the other selection state vars, each of which clears
  // this when THEY become the target.
  private var selectedMusicSegmentIndex: Int? = null
    set(value) {
      field = value
      if (value != null) isVoiceRowSelected = false
      updateVideoSelectionLabel()
    }

  // Chosen-track card (replaces the plain "SoundHelix Song 8"-style text
  // button once a track is picked) — per the user's explicit "update
  // choosen songs UI... provide music play pause button also remove
  // selected song icon" request. musicButtonRef itself becomes the EMPTY-
  // STATE "+ Choose Music Track" trigger only; once a track is selected,
  // it hides and this card takes over (tapping the card body still opens
  // the same picker to change track).
  private var musicButtonRef: View? = null
  private var musicTrackCardRef: View? = null
  private var musicTrackTitleRef: TextView? = null
  private var musicTrackSubtitleRef: TextView? = null
  private var musicChangeTrackRef: View? = null
  private var musicPlayPauseIconRef: EditorIconView? = null
  private var removeMusicButtonRef: View? = null

  // Day 25 — mixing the original video audio against the music, completing
  // AudioState's originalAudioVolume (declared since Milestone 1, unused
  // until now). Independent of whether music is even selected — you may
  // just want to mute/duck the original clip's audio. The separate
  // muteOriginalAudioButton/originalAudioMuted toggle was removed per the
  // user's explicit "remove Mute Audio button" request — dragging this
  // slider to 0% already IS mute, a dedicated button was redundant.
  private var originalAudioVolume = 1f

  /** Shared by the live preview and export so the two can never drift apart
   *  into different-looking pixel math. Defaults to the 9 flat working-
   *  copy vars (whichever clip is currently active/being edited, per
   *  syncActiveClipFilterState) — every EXISTING call site (image-mode
   *  preview, and the live-video PhotoFilterRgbMatrix lambda, which reads
   *  this fresh every frame) keeps working unchanged. Export passes an
   *  explicit `state` per clip instead, since it builds every clip's
   *  effects up front rather than reading whatever's currently active. */
  private fun combinedColorMatrix(state: ClipFilterState = currentFilterStateSnapshot()): ColorMatrix {
    // Fade folds into the same brightness/contrast terms as B/C/S, rather
    // than a separate matrix — positive fade = lower contrast + lifted
    // brightness (washed out); negative = the opposite (punchier).
    val fadeContrastDelta = if (state.fade >= 0) -0.35f * state.fade else 0.3f * -state.fade
    val fadeBrightnessDelta = if (state.fade >= 0) 0.12f * state.fade else 0f

    // The named filter (+ its Strength/Saturation) is NOT in here — it's a
    // lookup table applied before this matrix (FilterLut / FilterLutEffect).
    val combined = ColorMatrix()
    combined.postConcat(brightnessMatrix(state.brightness + fadeBrightnessDelta))
    combined.postConcat(contrastMatrix(1 + state.contrast + fadeContrastDelta))
    combined.postConcat(saturationMatrix(1 + state.saturation))
    if (state.warmth != 0f) {
      combined.postConcat(tintMatrix(rMul = 1 + 0.25f * state.warmth, gMul = 1f, bMul = 1 - 0.25f * state.warmth))
    }
    // Shadow: no true tone-selective curve is achievable with a linear
    // ColorMatrix (unlike iOS's CIHighlightShadowAdjust) — approximated in
    // both directions via a contrast bias instead: positive = a mild
    // brightness lift (raises shadows along with everything else);
    // negative = increased contrast (deepens shadows more than
    // highlights, since contrast's pivot sits at mid-gray).
    if (state.shadow > 0) {
      combined.postConcat(brightnessMatrix(state.shadow * 0.25f))
    } else if (state.shadow < 0) {
      combined.postConcat(contrastMatrix(1 - state.shadow * 0.3f))
    }
    // Highlights: Shadow's opposite-tone counterpart, same "no true tone-
    // selective curve, approximate via contrast/brightness bias" caveat —
    // positive = tone down bright areas (contrast reduction compresses
    // highlights toward mid-gray); negative = boost them (brightness lift
    // pushes bright areas closer to clipping).
    if (state.highlights > 0) {
      combined.postConcat(contrastMatrix(1 - state.highlights * 0.3f))
    } else if (state.highlights < 0) {
      combined.postConcat(brightnessMatrix(-state.highlights * 0.2f))
    }
    // Tint: Warmth's green-magenta counterpart to its blue-orange axis.
    if (state.tint != 0f) {
      combined.postConcat(tintMatrix(rMul = 1 - 0.15f * state.tint, gMul = 1 + 0.2f * state.tint, bMul = 1 - 0.15f * state.tint))
    }
    return combined
  }

  /** Video shader input for [state] (filter + Strength/Saturation/Sharpness). */
  private fun filterGpuParams(state: ClipFilterState = currentFilterStateSnapshot()) =
    FilterGpuParams(state.filter, state.filterStrength, state.filterSaturation, state.filterSharpness)

  /** The base preview bitmap with the selected filter's lookup table
   *  (Strength + Saturation baked in) applied. Cached, so Edit-panel
   *  slider ticks don't re-run the table over every pixel. */
  private var filteredPreviewCache: Triple<Bitmap, FilterLut.Key, Bitmap>? = null

  /** The Artistic effect drawn on the base preview (before Strength/
   *  Saturation), so dragging those sliders only re-blends. */
  private var artisticPreviewCache: Triple<Bitmap, PhotoFilter, Bitmap>? = null

  private fun filteredPreviewBase(base: Bitmap): Bitmap {
    val key = FilterLut.keyFor(selectedFilter, filterStrength, filterSaturation) ?: return base
    filteredPreviewCache?.let { (cachedBase, cachedKey, output) ->
      if (cachedBase === base && cachedKey == key) return output
    }
    val output = if (selectedFilter.category == FilterCategory.ARTISTIC) {
      val effect = artisticPreviewCache?.takeIf { it.first === base && it.second == selectedFilter }?.third
        ?: ArtisticEffects.render(selectedFilter, base).also { artisticPreviewCache = Triple(base, selectedFilter, it) }
      ArtisticEffects.blend(base, effect, filterStrength, filterSaturation)
    } else {
      FilterLut.apply(base, FilterLut.baked(key))
    }
    filteredPreviewCache = Triple(base, key, output)
    return output
  }

  private fun refreshPreview(target: ImageView) {
    // An edit (e.g. a second finger on a slider) ends a hold-to-compare,
    // otherwise release would restore a stale stashed preview.
    restoreEditedPreview()
    target.colorFilter = ColorMatrixColorFilter(combinedColorMatrix())
    // Sharpen isn't expressible as a ColorMatrix (it's a spatial
    // convolution, not a per-pixel color transform) — re-convolve from
    // the untouched base bitmap and swap it in directly. Falls back to
    // the plain base bitmap (still with the colorFilter above applied on
    // top) when sharpen is back at 0, so it never compounds.
    val base = baseBitmapRef
    if (base != null) {
      // Filter (lookup table) -> Filters-panel Sharpness -> Edit Sharpen.
      var preview = filteredPreviewBase(base)
      if (filterSharpness > 0) preview = sharpenBitmap(preview, filterSharpness)
      if (sharpen > 0) preview = sharpenBitmap(preview, sharpen)
      // The blur also covers text/stickers/overlays/drawing: the cover is
      // drawn from the picture WITHOUT blur plus the layers, then blurred.
      unblurredPreviewBitmap = if (mediaType == "image" && blur.isActive) preview else null
      if (mediaType == "image" && blur.isActive) preview = blurredPreview(preview)
      target.setImageBitmap(preview)
      target.invalidate() // blurPreviewOutput is reused in place
      blurCoverRevision++
      updateBlurCover()
    }
    updateAutoEnhanceButton()
    scheduleFilterStageRefresh()
  }

  // ---- Re-edit project (reopen an exported photo with layers editable) ----

  /** Set in onCreate when reopening a previous edit; consumed once the
   *  photo has loaded and the canvas has its final size. */
  private var pendingEditProject: JSONObject? = null
  /** Reused across re-edits so the same project folder is updated in place. */
  private var editProjectId: String? = null

  /** Layer centers are saved relative to the CANVAS (not root, which the
   *  layer views are actually centered in), normalized by canvas width, so
   *  a different canvas size on reopen still lands them in the same spot. */
  private fun layerBaseOffset(imageView: ImageView): PointF =
    PointF(root.width / 2f - imageView.left, root.height / 2f - imageView.top)

  /** Snapshots the editor into a project folder + JSON. Null on any failure
   *  (the export still succeeds; the photo just won't be re-editable). */
  private fun saveEditProject(): String? = runCatching {
    val imageView = imageViewRef ?: return null
    val canvasWidth = imageView.width.toFloat()
    if (mediaType != "image" || canvasWidth <= 0f) return null
    val id = editProjectId ?: UUID.randomUUID().toString()
    val dir = MediaEditorEditProject.dir(this, id).apply { mkdirs() }
    val sourceFile = File(dir, MediaEditorEditProject.SOURCE_FILE_NAME)
    if (!MediaEditorEditProject.isSameFile(mediaUri, sourceFile)) {
      if (!MediaEditorEditProject.copySource(this, mediaUri, sourceFile)) return null
    }
    dir.listFiles()?.filter { it.name.startsWith("overlay_") }?.forEach { it.delete() }
    dir.setLastModified(System.currentTimeMillis())

    val base = layerBaseOffset(imageView)
    val project = JSONObject().apply {
      put("version", MediaEditorEditProject.VERSION)
      put("id", id)
      put("canvasWidth", canvasWidth.toDouble())
      put("imageTx", (imageView.translationX / canvasWidth).toDouble())
      put("imageTy", (imageView.translationY / canvasWidth).toDouble())
      put("imageScale", imageView.scaleX.toDouble())
      put("imageRotation", imageView.rotation.toDouble())
      put("filter", selectedFilter.name)
      put("filterStrength", filterStrength.toDouble())
      put("filterSaturation", filterSaturation.toDouble())
      put("filterSharpness", filterSharpness.toDouble())
      put("brightness", brightness.toDouble())
      put("contrast", contrast.toDouble())
      put("saturation", saturation.toDouble())
      put("fade", fade.toDouble())
      put("shadow", shadow.toDouble())
      put("vignette", vignette.toDouble())
      put("sharpen", sharpen.toDouble())
      put("warmth", warmth.toDouble())
      put("highlights", highlights.toDouble())
      put("tint", tint.toDouble())
      put("blur", blur.toJson())
    }

    val strokes = JSONArray()
    drawingCanvasRef?.allStrokes()?.forEach { stroke ->
      val points = JSONArray()
      stroke.points.forEach { points.put((it.x / canvasWidth).toDouble()); points.put((it.y / canvasWidth).toDouble()) }
      strokes.put(JSONObject().apply {
        put("points", points)
        put("color", stroke.color)
        put("width", (stroke.widthPx / canvasWidth).toDouble())
        put("brush", stroke.brushType.name)
        put("seed", stroke.seed)
        stroke.shape?.let { put("shape", it.name) }
      })
    }
    project.put("strokes", strokes)

    // Deleted layers are only GONE (so undo can bring them back).
    val visible = (textLayerViews + stickerLayerViews + imageOverlayLayerViews)
      .filter { it.visibility == View.VISIBLE && it.parent === root }
      .sortedBy { root.indexOfChild(it) }
    val layers = JSONArray()
    visible.forEachIndexed { index, view ->
      val layer = JSONObject().apply {
        put("cx", ((base.x + view.translationX) / canvasWidth).toDouble())
        put("cy", ((base.y + view.translationY) / canvasWidth).toDouble())
        put("scale", view.scaleX.toDouble())
        put("rotation", view.rotation.toDouble())
      }
      if (view is ImageView) {
        // The unstyled photo; its look + eraser strokes go alongside.
        val state = overlayStates[view]
        val bitmap = state?.base ?: (view.drawable as? BitmapDrawable)?.bitmap ?: return@forEachIndexed
        val fileName = "overlay_$index.png"
        FileOutputStream(File(dir, fileName)).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        layer.put("kind", "image")
        layer.put("file", fileName)
        layer.put("width", view.layoutParams.width)
        layer.put("height", view.layoutParams.height)
        state?.let { layer.put("overlay", overlayLookJson(it.style, it.strokes)) }
      } else if (view is TextView) {
        val location = locationLayerStates[view]
        val assetName = stickerLayerAssetNames[view]
        when {
          location != null -> {
            layer.put("kind", "location")
            layer.put("name", location.name)
            layer.put("style", location.style)
            if (location.kind != "location") layer.put("infoKind", location.kind)
            location.value?.let { layer.put("infoValue", it) }
            location.latitude?.let { layer.put("lat", it) }
            location.longitude?.let { layer.put("lng", it) }
          }
          assetName != null -> {
            layer.put("kind", "sticker")
            layer.put("asset", assetName)
            stickerStyles[view]?.let { style ->
              layer.put("opacity", style.opacity.toDouble())
              layer.put("outline", style.outline.toDouble())
              layer.put("shadow", style.shadow.toDouble())
              layer.put("flipX", style.flipX)
              layer.put("flipY", style.flipY)
            }
          }
          view is StyledTextLayerView -> {
            val style = view.layerStyle
            layer.put("kind", "text")
            layer.put("text", view.text?.toString().orEmpty())
            layer.put("fontId", style.fontId)
            layer.put("color", style.color)
            layer.put("bold", style.isBold)
            layer.put("italic", style.isItalic)
            layer.put("underline", style.isUnderlined)
            layer.put("align", style.alignment.raw)
            layer.put("bg", style.background.ordinal)
            layer.put("size", style.size.toDouble())
            layer.put("outline", style.outline.toDouble())
            layer.put("shadow", style.shadow.toDouble())
            layer.put("opacity", style.opacity.toDouble())
            layer.put("stretchX", style.stretchX.toDouble())
            layer.put("stretchY", style.stretchY.toDouble())
            layer.put("arch", style.arch.toDouble())
          }
          else -> return@forEachIndexed
        }
      }
      layers.put(layer)
    }
    project.put("layers", layers)
    editProjectId = id
    project.toString()
  }.getOrElse {
    Log.w("MediaEditor", "saveEditProject failed", it)
    null
  }

  /** Rebuilds the saved edit: image pan/zoom, filter + adjustments, drawing
   *  and every layer, all still editable. Not undoable — it's the starting
   *  state, so the undo stack stays empty. */
  private fun restoreEditProjectIfNeeded() {
    val project = pendingEditProject ?: return
    pendingEditProject = null
    val imageView = imageViewRef ?: return
    val canvasWidth = imageView.width.toFloat()
    if (canvasWidth <= 0f) return
    val savedWidth = project.optDouble("canvasWidth", canvasWidth.toDouble()).toFloat()
    val k = if (savedWidth > 0f) canvasWidth / savedWidth else 1f
    val dir = MediaEditorEditProject.dir(this, project.optString("id"))

    imageView.translationX = project.optDouble("imageTx").toFloat() * canvasWidth
    imageView.translationY = project.optDouble("imageTy").toFloat() * canvasWidth
    val imageScale = project.optDouble("imageScale", 1.0).toFloat()
    imageView.scaleX = imageScale
    imageView.scaleY = imageScale
    imageView.rotation = project.optDouble("imageRotation").toFloat()

    fun f(key: String) = project.optDouble(key, 0.0).toFloat()
    applyFilterStateSnapshot(ClipFilterState(
      filter = runCatching { PhotoFilter.valueOf(project.optString("filter")) }.getOrDefault(PhotoFilter.ORIGINAL),
      filterStrength = project.optDouble("filterStrength", 1.0).toFloat(),
      filterSaturation = f("filterSaturation"), filterSharpness = f("filterSharpness"),
      brightness = f("brightness"), contrast = f("contrast"), saturation = f("saturation"),
      fade = f("fade"), shadow = f("shadow"), warmth = f("warmth"),
      highlights = f("highlights"), tint = f("tint"),
    ))
    vignette = f("vignette")
    sharpen = f("sharpen")
    blur = PhotoBlur.fromJson(project.optJSONObject("blur"))
    syncBlurControls()
    // Vignette/sharpen aren't part of ClipFilterState (image-only), so
    // their sliders are synced here.
    for ((property, value) in listOf(AdjustProperty.VIGNETTE to vignette, AdjustProperty.SHARPEN to sharpen)) {
      val seekBar = (adjustSliderRowRefs[property] as? LinearLayout)?.getChildAt(1) as? SeekBar ?: continue
      seekBar.progress = ((value * 100) + 100).toInt()
    }
    refreshPreview(imageView)
    updateVignetteOverlay()

    val strokes = project.optJSONArray("strokes") ?: JSONArray()
    for (i in 0 until strokes.length()) {
      val saved = strokes.optJSONObject(i) ?: continue
      val flat = saved.optJSONArray("points") ?: continue
      val points = (0 until flat.length() / 2).map { p ->
        PointF(flat.optDouble(p * 2).toFloat() * canvasWidth, flat.optDouble(p * 2 + 1).toFloat() * canvasWidth)
      }
      val brush = runCatching { DrawingCanvasView.BrushType.valueOf(saved.optString("brush")) }
        .getOrDefault(DrawingCanvasView.BrushType.PEN)
      drawingCanvasRef?.addStroke(DrawingCanvasView.Stroke(
        points, saved.optInt("color"), saved.optDouble("width").toFloat() * canvasWidth, brush, saved.optInt("seed"),
        saved.optString("shape").takeIf { it.isNotEmpty() }?.let { name ->
          runCatching { DrawingCanvasView.ShapeType.valueOf(name) }.getOrNull()
        },
      ))
    }

    val base = layerBaseOffset(imageView)
    val layers = project.optJSONArray("layers") ?: JSONArray()
    for (i in 0 until layers.length()) {
      val saved = layers.optJSONObject(i) ?: continue
      restoreLayer(saved, dir, base, canvasWidth, k)
    }
    keepSafeAreaCoversOnTop()
    refreshLayersPanel()
  }

  private fun restoreLayer(saved: JSONObject, dir: File, base: PointF, canvasWidth: Float, k: Float) {
    val view: View = when (saved.optString("kind")) {
      "image" -> {
        val bitmap = BitmapFactory.decodeFile(File(dir, saved.optString("file")).absolutePath) ?: return
        val overlay = ImageView(this).apply { scaleType = ImageView.ScaleType.FIT_CENTER }
        val (style, strokes) = saved.optJSONObject("overlay")?.let(::overlayLookFromJson) ?: (OverlayStyle() to emptyList())
        applyOverlay(overlay, bitmap, null, style, strokes)
        root.addView(overlay, FrameLayout.LayoutParams(saved.optInt("width"), saved.optInt("height"), Gravity.CENTER))
        imageOverlayLayerViews.add(overlay)
        overlay
      }
      "sticker", "location" -> {
        val label = TextView(this)
        if (saved.optString("kind") == "location") {
          applyLocationSticker(label, LocationLayerState(
            name = saved.optString("name"),
            style = saved.optInt("style"),
            latitude = if (saved.has("lat")) saved.optDouble("lat") else null,
            longitude = if (saved.has("lng")) saved.optDouble("lng") else null,
            kind = saved.optString("infoKind").ifEmpty { "location" },
            value = if (saved.has("infoValue")) saved.optString("infoValue") else null,
          ))
        } else {
          stickerStyles[label] = StickerStyle(
            opacity = saved.optDouble("opacity", 1.0).toFloat(),
            flipX = saved.optBoolean("flipX"),
            flipY = saved.optBoolean("flipY"),
            outline = saved.optDouble("outline", 0.0).toFloat(),
            shadow = saved.optDouble("shadow", 0.0).toFloat(),
          )
          if (!applyStickerImage(label, saved.optString("asset"))) return
        }
        root.addView(label, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        stickerLayerViews.add(label)
        label
      }
      "text" -> {
        val style = TextLayerStyle(
          fontId = saved.optString("fontId").ifEmpty { TextFontCatalog.optionId(saved.optString("font")) },
          color = saved.optInt("color", Color.WHITE),
          isBold = saved.optBoolean("bold"),
          isItalic = saved.optBoolean("italic"),
          isUnderlined = saved.optBoolean("underline"),
          alignment = TextAlign.fromRaw(saved.optInt("align", TextAlign.CENTER.raw)),
          background = TextBackgroundMode.values().getOrElse(saved.optInt("bg", 0)) { TextBackgroundMode.NONE },
          size = saved.optDouble("size", 1.0).toFloat(),
          outline = saved.optDouble("outline", 0.0).toFloat(),
          shadow = saved.optDouble("shadow", 0.0).toFloat(),
          opacity = saved.optDouble("opacity", 1.0).toFloat(),
          stretchX = saved.optDouble("stretchX", 1.0).toFloat(),
          stretchY = saved.optDouble("stretchY", 1.0).toFloat(),
          arch = saved.optDouble("arch", 0.0).toFloat(),
        )
        val label = StyledTextLayerView(this).apply { applyText(saved.optString("text"), style) }
        root.addView(label, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        textLayerViews.add(label)
        label
      }
      else -> return
    }
    root.setClipRect(view, canvasBoxRect)
    // Sizes are the saved (unscaled) ones, so canvas rescale goes into
    // scale only; centers are re-anchored from canvas-relative to root.
    view.translationX = saved.optDouble("cx").toFloat() * canvasWidth - base.x
    view.translationY = saved.optDouble("cy").toFloat() * canvasWidth - base.y
    val scale = saved.optDouble("scale", 1.0).toFloat() * k
    view.scaleX = scale
    view.scaleY = scale
    view.rotation = saved.optDouble("rotation").toFloat()
    gestureCoordinator?.addLayer(view)
    registerLayerTiming(view)
  }

  // ---- Auto-enhance (photo only) ----

  private fun currentAutoEnhanceValues() = PhotoAutoEnhance(brightness, contrast, saturation, warmth)

  private fun applyAutoEnhanceValues(values: PhotoAutoEnhance) {
    brightness = values.brightness
    contrast = values.contrast
    saturation = values.saturation
    warmth = values.warmth
    // Re-drives each slider (its listener re-sets the var + value label and
    // refreshes the preview) from the vars above.
    syncAdjustSlidersToCurrentValues()
    imageViewRef?.let { refreshPreview(it) }
  }

  /** One tap: balanced Brightness/Contrast/Saturation/Warm from the photo's
   *  own statistics. Tapping again (with those values untouched) restores
   *  what was there before. Undoable either way. */
  private fun didTapAutoEnhance() {
    val current = currentAutoEnhanceValues()
    val applied = autoEnhanceApplied
    val backup = autoEnhanceBackup
    val target = if (applied != null && backup != null && applied == current) {
      backup
    } else {
      val base = baseBitmapRef ?: return
      val computed = PhotoAutoEnhance.compute(base) ?: return
      autoEnhanceBackup = current
      autoEnhanceApplied = computed
      computed
    }
    autoEnhanceButtonRef?.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    if (target == current) {
      updateAutoEnhanceButton()
      return
    }
    applyAutoEnhanceValues(target)
    pushUndo(undo = { applyAutoEnhanceValues(current) }, redo = { applyAutoEnhanceValues(target) })
  }

  private fun updateAutoEnhanceButton() {
    val button = autoEnhanceButtonRef ?: return
    val isOn = autoEnhanceApplied != null && autoEnhanceApplied == currentAutoEnhanceValues()
    val color = if (isOn) EditorDesignTokens.Colors.accent else EditorDesignTokens.Colors.textSecondary
    (button.getChildAt(0) as? EditorIconView)?.let { it.iconTint = color; it.invalidate() }
    (button.getChildAt(1) as? TextView)?.setTextColor(color)
    button.isSelected = isOn
  }

  // ---- Blur / tilt-shift (photo only) ----

  private fun setUpBlurOverlay(imageView: ImageView) {
    val overlay = BlurFocusOverlayView(this).apply {
      visibility = View.GONE
      // Same untransformed box as the ImageView (see layoutImageCanvas),
      // so its matrix maps photo-local points straight into this view.
      photoMatrix = { imageView.matrix }
      photoSize = { imageView.width.toFloat() to imageView.height.toFloat() }
      onChange = { newBlur ->
        // Qualified: inside apply{}, a bare `blur` is the OVERLAY's own
        // property — the editor's blur never changed and stayed centered.
        this@MediaEditorActivity.blur = newBlur
        refreshPreview(imageView)
      }
      onGestureEnded = { before, after -> pushBlurUndo(before, after) }
    }
    blurOverlayRef = overlay
    root.addView(overlay, FrameLayout.LayoutParams(0, 0))
  }

  /** Guide + gestures only while the Blur tool is open with a mode on. */
  private fun updateBlurOverlay() {
    val overlay = blurOverlayRef ?: return
    val visible = selectedImageEditorTab == ImageEditorTab.EDIT &&
      selectedAdjustProperty == AdjustProperty.BLUR && blur.mode != PhotoBlur.Mode.OFF
    overlay.visibility = if (visible) View.VISIBLE else View.GONE
    if (!visible) return
    overlay.blur = blur
    // Above text/sticker layers so it wins the touches (a child that
    // consumes DOWN keeps the gesture from root's layer coordinator), but
    // still below the panel chrome.
    overlay.bringToFront()
    editPanelRef?.bringToFront()
    keepSafeAreaCoversOnTop()
  }

  private fun syncBlurControls() {
    val density = resources.displayMetrics.density
    blurModeButtonRefs.forEach { (mode, button) ->
      val selected = mode == blur.mode
      button.setTextColor(if (selected) Color.BLACK else EditorDesignTokens.Colors.textPrimary)
      button.background = GradientDrawable().apply {
        cornerRadius = 100f * density
        setColor(if (selected) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.elevatedSurface)
      }
    }
    blurStrengthSeekBarRef?.let {
      isSyncingBlurControls = true
      it.progress = (blur.strength * 100).roundToInt()
      isSyncingBlurControls = false
      it.isEnabled = blur.mode != PhotoBlur.Mode.OFF
      it.alpha = if (blur.mode != PhotoBlur.Mode.OFF) 1f else 0.4f
    }
    updateBlurOverlay()
  }

  private fun applyBlur(newBlur: PhotoBlur) {
    blur = newBlur
    syncBlurControls()
    imageViewRef?.let { refreshPreview(it) }
  }

  private fun pushBlurUndo(old: PhotoBlur, new: PhotoBlur) {
    if (old == new) return
    pushUndo(undo = { applyBlur(old) }, redo = { applyBlur(new) })
  }

  /** Blurred version of a preview bitmap, reusing the cached blurred copy
   *  while only the sharp area moves (dragging stays smooth). */
  private fun blurredPreview(source: Bitmap): Bitmap {
    if (blurCacheSource !== source || blurCacheStrength != blur.strength || blurCacheSmall == null) {
      blurCacheSmall = PhotoBlurRenderer.blurredSmallCopy(
        source, PhotoBlurRenderer.blurRadiusPx(blur, source.width, source.height),
      )
      blurCacheSource = source
      blurCacheStrength = blur.strength
    }
    val small = blurCacheSmall ?: return source
    // Never draw into the bitmap the compare button may have stashed.
    val reuse = blurPreviewOutput?.takeIf { it !== compareStashedBitmap }
    return PhotoBlurRenderer.composite(source, small, blur, reuse).also { blurPreviewOutput = it }
  }

  /** Off / Radial / Linear pills + strength slider, in the Adjust panel's
   *  single-row detail slot. */
  private fun makeBlurRow(): LinearLayout {
    val density = resources.displayMetrics.density
    val row = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    listOf(PhotoBlur.Mode.OFF to "Off", PhotoBlur.Mode.RADIAL to "Radial", PhotoBlur.Mode.LINEAR to "Linear")
      .forEachIndexed { index, (mode, title) ->
        val pill = TextView(this).apply {
          text = title
          textSize = 12f
          typeface = Typeface.DEFAULT_BOLD
          gravity = Gravity.CENTER
          setPadding((10f * density).toInt(), (5f * density).toInt(), (10f * density).toInt(), (5f * density).toInt())
          setOnClickListener {
            if (blur.mode == mode) return@setOnClickListener
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            val old = blur
            val new = blur.copy(mode = mode)
            applyBlur(new)
            pushBlurUndo(old, new)
          }
        }
        blurModeButtonRefs[mode] = pill
        row.addView(
          pill,
          LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            if (index > 0) marginStart = (6f * density).toInt()
          },
        )
      }
    val seekBar = makeStyledSeekBar().apply {
      max = 100
      progress = (blur.strength * 100).roundToInt()
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        var dragStart = blur
        override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
          if (isSyncingBlurControls) return
          blur = blur.copy(strength = progress / 100f)
          imageViewRef?.let { refreshPreview(it) }
        }
        override fun onStartTrackingTouch(seekBar: SeekBar) { dragStart = blur }
        override fun onStopTrackingTouch(seekBar: SeekBar) { pushBlurUndo(dragStart, blur) }
      })
    }
    blurStrengthSeekBarRef = seekBar
    row.addView(
      seekBar,
      LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = (12f * density).toInt() },
    )
    syncBlurControls()
    return row
  }

  // ---- Before/after compare (image editor, hold to see original) ----

  /** Edited preview stashed while the original is shown, restored on release. */
  private var compareStashedBitmap: Bitmap? = null
  private var compareStashedColorFilter: android.graphics.ColorFilter? = null
  /** Views hidden while the original is shown — only those that were visible. */
  private val compareHiddenViews = mutableListOf<View>()
  // Read on the GL thread by the video effects (hold-to-compare).
  @Volatile private var isShowingOriginal = false

  /** Video: forces the paused/playing frame to re-run the GL effects
   *  (same nudge-seek as refreshLivePreview). */
  private fun nudgeVideoFrameForCompare() {
    if (mediaType == "image") return
    val player = exoPlayer ?: return
    val currentPositionMs = player.currentPosition
    val durationMs = player.duration
    val nudgedPositionMs = if (durationMs > 0) (currentPositionMs + 1).coerceAtMost(durationMs) else currentPositionMs + 1
    player.seekTo(nudgedPositionMs)
    player.seekTo(currentPositionMs)
  }

  /** Shows the untouched photo: no filter/adjustments (incl. sharpen and
   *  vignette), and no text, stickers, overlay photos or drawing. Crop is
   *  kept, since the canvas box itself is the crop. */
  private fun showOriginalPreview() {
    if (isShowingOriginal) return
    scheduleFilterStageRefresh()
    isShowingOriginal = true
    val target = imageViewRef
    val base = baseBitmapRef
    if (target != null && base != null) {
      compareStashedBitmap = (target.drawable as? BitmapDrawable)?.bitmap
      compareStashedColorFilter = target.colorFilter
      target.colorFilter = null
      target.setImageBitmap(base)
    }
    val toHide = mutableListOf<View?>()
    toHide += textLayerViews
    toHide += stickerLayerViews
    toHide += imageOverlayLayerViews
    toHide += drawingCanvasRef
    toHide += vignetteOverlayRef
    toHide += layerActionToolbarRef
    toHide.filterNotNull().filter { it.visibility == View.VISIBLE }.forEach {
      it.visibility = View.INVISIBLE
      compareHiddenViews += it
    }
    updateBlurCover()
    nudgeVideoFrameForCompare()
  }

  private fun restoreEditedPreview() {
    if (!isShowingOriginal) return
    scheduleFilterStageRefresh()
    isShowingOriginal = false
    val target = imageViewRef
    val stashed = compareStashedBitmap
    if (target != null && stashed != null) {
      // Instant swap back — no re-run of sharpen's convolution.
      target.setImageBitmap(stashed)
      target.colorFilter = compareStashedColorFilter
    }
    compareStashedBitmap = null
    compareStashedColorFilter = null
    compareHiddenViews.forEach { it.visibility = View.VISIBLE }
    compareHiddenViews.clear()
    blurCoverRevision++
    updateBlurCover()
    nudgeVideoFrameForCompare()
  }

  private fun makeCompareButton(): View {
    val button = makeTopBarIconButton(EditorIcon.COMPARE) {}
    button.contentDescription = "Hold to compare with original"
    button.setOnTouchListener { v, event ->
      when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
          v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
          showOriginalPreview()
          true
        }
        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
          restoreEditedPreview()
          true
        }
        else -> true
      }
    }
    return button
  }

  /** Simple unsharp-mask convolution: for each pixel, push it away from
   *  its 3x3 neighborhood average by `amount` — the same technique CPU
   *  photo editors have used for decades, no GPU/RenderScript needed.
   *  Operates on a plain int pixel array (bulk get/setPixels), not
   *  per-pixel Bitmap.getPixel() calls, to keep this fast enough to run
   *  on every slider tick at preview resolution. */
  private fun sharpenBitmap(source: Bitmap, amount: Float): Bitmap {
    val width = source.width
    val height = source.height
    val pixels = IntArray(width * height)
    source.getPixels(pixels, 0, width, 0, 0, width, height)
    val output = pixels.copyOf()
    val strength = amount * 1.5f

    for (y in 1 until height - 1) {
      val rowOffset = y * width
      for (x in 1 until width - 1) {
        val center = pixels[rowOffset + x]
        val up = pixels[rowOffset - width + x]
        val down = pixels[rowOffset + width + x]
        val left = pixels[rowOffset + x - 1]
        val right = pixels[rowOffset + x + 1]

        val a = Color.alpha(center)
        val r = sharpenChannel(Color.red(center), Color.red(up), Color.red(down), Color.red(left), Color.red(right), strength)
        val g = sharpenChannel(Color.green(center), Color.green(up), Color.green(down), Color.green(left), Color.green(right), strength)
        val b = sharpenChannel(Color.blue(center), Color.blue(up), Color.blue(down), Color.blue(left), Color.blue(right), strength)
        output[rowOffset + x] = Color.argb(a, r, g, b)
      }
    }

    val result = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    result.setPixels(output, 0, width, 0, 0, width, height)
    return result
  }

  private fun sharpenChannel(center: Int, up: Int, down: Int, left: Int, right: Int, strength: Float): Int {
    val neighborAverage = (up + down + left + right) / 4f
    val sharpened = center + (center - neighborAverage) * strength
    return sharpened.toInt().coerceIn(0, 255)
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    FilterLut.init(this)
    // Music picker shows songs the moment it opens (video, photo, story).
    MusicApi.prefetchTrending()
    // Always draw edge-to-edge. The editor's chrome already leaves room for
    // the status/nav bars itself (statusBarHeightPx / navigationBarHeightPx
    // margins + the dark safe-area covers). Android 16+ forces edge-to-edge,
    // but the app theme opts out of it (windowOptOutEdgeToEdgeEnforcement),
    // so on Android 15 and older the system ALSO kept the content clear of
    // the bars — both gaps were applied, leaving a big empty band above the
    // nav bar (under LOOKS · TOOLS · EXPORT) and under the status bar.
    WindowCompat.setDecorFitsSystemWindows(window, false)
    @Suppress("DEPRECATION")
    run {
      window.statusBarColor = Color.TRANSPARENT
      window.navigationBarColor = Color.TRANSPARENT
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      // No light scrim behind the 3-button nav bar — the dark cover shows.
      window.isNavigationBarContrastEnforced = false
    }
    WindowInsetsControllerCompat(window, window.decorView).apply {
      isAppearanceLightStatusBars = false
      isAppearanceLightNavigationBars = false
    }
    // So the text-entry overlay's toolbar (Gravity.BOTTOM, docked to
    // `root`) ends up sitting right above the keyboard instead of behind
    // it — resizes the whole window's content area when the IME shows,
    // rather than the IME simply overlaying on top unchanged.
    window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)

    mediaUri = intent.getStringExtra(EXTRA_URI).orEmpty()
    mediaType = intent.getStringExtra(EXTRA_TYPE).orEmpty()
    isStoryMode = intent.getBooleanExtra(EXTRA_IS_STORY_MODE, false)
    placesApiKey = intent.getStringExtra(EXTRA_PLACES_API_KEY).orEmpty()
    // Re-edit: reopen the untouched source of a previous photo export (not
    // the flattened file in EXTRA_URI); layers are rebuilt once it loads.
    if (mediaType == "image") {
      MediaEditorEditProject.decode(this, intent.getStringExtra(EXTRA_EDIT_PROJECT))?.let { (project, source) ->
        pendingEditProject = project
        editProjectId = project.optString("id")
        mediaUri = Uri.fromFile(source).toString()
      }
    }
    val keepProjectId = editProjectId
    Thread { MediaEditorEditProject.pruneStale(applicationContext, keepProjectId) }.start()
    musicTracks = runCatching {
      val array = JSONArray(intent.getStringExtra(EXTRA_MUSIC_TRACKS_JSON).orEmpty())
      (0 until array.length()).map { i ->
        val obj = array.getJSONObject(i)
        MusicTrack(
          id = obj.getString("id"),
          title = obj.getString("title"),
          artist = obj.getString("artist"),
          albumArt = obj.getString("albumArt"),
          audioUrl = obj.getString("audioUrl"),
        )
      }
    }.getOrDefault(emptyList())

    root = ClippingRootLayout(this).apply {
      setBackgroundColor(EditorDesignTokens.Colors.canvasBackground)
      layoutParams = ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      )
    }

    // Opaque bars covering the status-bar area (top) and navigation-bar
    // area (bottom) — added FIRST here, then explicitly re-fronted after
    // every later layer addition (see keepSafeAreaCoversOnTop), so nothing
    // (a dragged text/sticker layer, or the image itself) can ever
    // visually show through those two edge strips, per the user's explicit
    // request. Uses the classic getIdentifier lookup (no new AndroidX
    // WindowInsets dependency needed) with a sane dp fallback if the
    // resource isn't present on some OEM build.
    statusBarHeightPx = run {
      val resourceId = resources.getIdentifier("status_bar_height", "dimen", "android")
      if (resourceId > 0) resources.getDimensionPixelSize(resourceId) else (24f * resources.displayMetrics.density).toInt()
    }
    navigationBarHeightPx = run {
      val resourceId = resources.getIdentifier("navigation_bar_height", "dimen", "android")
      if (resourceId > 0) resources.getDimensionPixelSize(resourceId) else (48f * resources.displayMetrics.density).toInt()
    }
    // The real bar sizes when available (Android 11+) — the dimen resources
    // don't always match (e.g. gesture nav is much shorter than the
    // 3-button bar, and some OEM status bars differ from the dimen).
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      val bars = windowManager.currentWindowMetrics.windowInsets
        .getInsets(android.view.WindowInsets.Type.statusBars() or android.view.WindowInsets.Type.navigationBars())
      if (bars.top > 0) statusBarHeightPx = bars.top
      if (bars.bottom > 0) navigationBarHeightPx = bars.bottom
    }
    // Story mode: no strip behind the status bar — the story shows through.
    val topSafeAreaCover = View(this).apply {
      setBackgroundColor(if (isStoryMode) Color.TRANSPARENT else EditorDesignTokens.Colors.chromeBackground)
    }
    topSafeAreaCoverRef = topSafeAreaCover
    root.addView(
      topSafeAreaCover,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, statusBarHeightPx, Gravity.TOP),
    )
    val bottomSafeAreaCover = View(this).apply { setBackgroundColor(EditorDesignTokens.Colors.chromeBackground) }
    bottomSafeAreaCoverRef = bottomSafeAreaCover
    root.addView(
      bottomSafeAreaCover,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, navigationBarHeightPx, Gravity.BOTTOM),
    )

    // Opaque bars filling the 4 "gutter" strips between the reserved
    // content area and the canvas box (imageView/playerView) itself — i.e.
    // the letterbox margin left over when the media's own aspect ratio
    // doesn't exactly match the content area's. Positioned/sized below in
    // layoutImageCanvas (same computed boxLeft/Top/Width/Height rect every
    // other canvas-aligned overlay already uses) and re-fronted alongside
    // the safe-area covers (keepSafeAreaCoversOnTop) so a dragged/pinched
    // overlay image can never visually spill outside the crop box, per the
    // user's explicit "overlay image should render into the cropping box,
    // not outside of it" request. Color.BLACK matches root's own
    // background exactly, so painting over a stray layer here is visually
    // seamless with the margin that was already there.
    val canvasGutterTop = View(this).apply { setBackgroundColor(EditorDesignTokens.Colors.canvasBackground) }
    val canvasGutterBottom = View(this).apply { setBackgroundColor(EditorDesignTokens.Colors.canvasBackground) }
    val canvasGutterLeft = View(this).apply { setBackgroundColor(EditorDesignTokens.Colors.canvasBackground) }
    val canvasGutterRight = View(this).apply { setBackgroundColor(EditorDesignTokens.Colors.canvasBackground) }
    canvasGutterTopRef = canvasGutterTop
    canvasGutterBottomRef = canvasGutterBottom
    canvasGutterLeftRef = canvasGutterLeft
    canvasGutterRightRef = canvasGutterRight
    listOf(canvasGutterTop, canvasGutterBottom, canvasGutterLeft, canvasGutterRight).forEach {
      root.addView(it, FrameLayout.LayoutParams(0, 0))
    }

    if (mediaType == "image") {
      val imageView = ImageView(this).apply {
        scaleType = ImageView.ScaleType.FIT_CENTER
      }
      imageViewRef = imageView
      // Placeholder size — replaced below by layoutImageCanvas() once the
      // photo's own aspect ratio is known, before the first layout pass
      // (see readDisplaySize's doc for why that ordering matters).
      root.addView(imageView, FrameLayout.LayoutParams(0, 0))

      // Non-interactive — added after imageView (so it draws on top) but
      // never clickable/touch-consuming, so it can't interfere with
      // LayerGestureCoordinator's pan/pinch/rotate handling on root.
      val vignetteOverlay = View(this).apply { isClickable = false }
      vignetteOverlayRef = vignetteOverlay
      root.addView(vignetteOverlay, FrameLayout.LayoutParams(0, 0))

      // Added after imageView/vignetteOverlay (drawn on top of both) but
      // before text/sticker layers (drawn under them, once added at
      // runtime) — a purely visual center guide, per the user's explicit
      // request, non-interactive so it can't interfere with gestures.
      // Not in story mode — the story fills the screen edge to edge, like
      // Instagram, with no grid guide over it.
      if (!isStoryMode) {
        val gridOverlay = GridOverlayView(this)
        gridOverlayRef = gridOverlay
        root.addView(gridOverlay, FrameLayout.LayoutParams(0, 0))
      }

      // Freehand draw/brush layer — sized/positioned to exactly match
      // imageView (see layoutImageCanvas), added after the grid (drawn on
      // top of it) but before any runtime-added text/sticker/overlay layers
      // (which will stack above it once added, same as everything else in
      // this file). Only intercepts touches while the Draw tab is selected.
      val drawingCanvas = DrawingCanvasView(this)
      drawingCanvasRef = drawingCanvas
      drawingCanvas.onStrokeFinished = { stroke ->
        pushUndo(
          undo = { drawingCanvasRef?.removeStroke(stroke) },
          redo = { drawingCanvasRef?.addStroke(stroke) },
        )
      }
      root.addView(drawingCanvas, FrameLayout.LayoutParams(0, 0))
      setUpBlurOverlay(imageView)

      val loadingIndicator = ProgressBar(this)
      root.addView(
        loadingIndicator,
        FrameLayout.LayoutParams(
          ViewGroup.LayoutParams.WRAP_CONTENT,
          ViewGroup.LayoutParams.WRAP_CONTENT,
          Gravity.CENTER,
        ),
      )

      // Listener attaches to root (never itself transformed); hit-tests
      // which registered layer a touch actually lands on and writes the
      // resulting transform to that layer — see LayerGestureCoordinator's
      // doc for why the listener and the transformed views must differ.
      val coordinator = LayerGestureCoordinator(this)
      coordinator.addLayer(imageView)
      coordinator.boundedLayer = imageView
      coordinator.onLayerLongPressed = { target ->
        if (target !== imageView) confirmDeleteLayer(target)
      }
      coordinator.onLayerTapped = { target ->
        if (target != null && target !== imageView) {
          if (target !== selectedLayerView) root.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
          selectLayer(target)
          cycleLocationLayerStyleIfNeeded(target)
        } else {
          deselectLayer()
        }
      }
      // No toolbar work while dragging: the Delete / Duplicate / Edit bar
      // sits at a fixed spot above the tools, and re-applying its layout
      // params on every move frame forced a full layout of the whole screen.
      coordinator.onLayerTransformed = if (isStoryMode) {
        { target -> if (target === selectedLayerView) updateStickerDeleteBadge() }
      } else null
      coordinator.onLayerTransformCommitted = { target, old, new -> commitLayerTransformUndo(target, old, new) }
      coordinator.isLayerTransformLocked = { layer -> isLayerLocked(layer) || isLayerUserHidden(layer) }
      coordinator.isLayerHitExcluded = { layer -> isLayerUserHidden(layer) }
      coordinator.onSnapChanged = { state -> showSnapGuides(state) }
      root.setOnTouchListener(coordinator)
      gestureCoordinator = coordinator
      // Yellow border shown by default (no overlay layer selected yet) —
      // see updateCanvasSelectionBorder's own doc.
      updateCanvasSelectionBorder()

      // Built before the canvas is sized below so the reserved chrome
      // height is known — gives the canvas a dedicated, non-overlapping
      // area above the bottom controls rather than under them, per the
      // user's explicit reference-screenshot request.
      val chrome = setUpEditingControls(imageView)
      val displaySize = MediaEditorCanvasLoader.readDisplaySize(this, mediaUri)
      canvasChromeRef = chrome
      canvasDisplaySizeRef = displaySize
      layoutImageCanvas(imageView, chrome, displaySize)

      val displayMetrics = resources.displayMetrics
      val reqWidth = displayMetrics.widthPixels
      val reqHeight = displayMetrics.heightPixels
      val mainHandler = Handler(Looper.getMainLooper())
      Thread {
        val bitmap = MediaEditorCanvasLoader.loadDownsampled(this, mediaUri, reqWidth, reqHeight)
        mainHandler.post {
          loadingIndicator.visibility = View.GONE
          if (bitmap != null) {
            imageView.setImageBitmap(bitmap)
            baseBitmapRef = bitmap
            renderFilterThumbnails(bitmap)
            // After layout, so the canvas box and root have final sizes.
            imageView.post { restoreEditProjectIfNeeded() }
          }
        }
      }.start()
    } else {
      // Inflated from XML (not a plain PlayerView(this)) specifically for
      // surface_type="texture_view" — a TextureView keeps showing the
      // LAST rendered frame instead of clearing to black while ExoPlayer
      // switches decoders at a playlist item boundary (merged-clip
      // transitions), unlike the default SurfaceView. Same fix already
      // proven in ia_player_view.xml (IAVideoView) for the identical
      // black-flash symptom — per the user's explicit "in between two
      // clips there is small micro second gap which display as black
      // screen" report. Controller UI deliberately disabled — the editor
      // builds its own play/pause now and timeline/trim controls;
      // media3's default transport overlay would only be in the way of
      // that (also set in the XML, useController here is redundant but
      // harmless belt-and-suspenders).
      val playerView = LayoutInflater.from(this).inflate(R.layout.media_editor_player_view, null) as PlayerView
      playerView.apply {
        useController = false
        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
      }
      playerViewRef = playerView
      // Placeholder size — replaced below by layoutImageCanvas() once the
      // video's own aspect ratio is known, mirroring the image branch, per
      // the user's explicit "same UI as the image editor" request (video
      // used to be a full-bleed MATCH_PARENT box here).
      root.addView(playerView, FrameLayout.LayoutParams(0, 0))

      val addVideoLoadingIndicator = ProgressBar(this).apply { visibility = View.GONE }
      addVideoLoadingIndicatorRef = addVideoLoadingIndicator
      root.addView(
        addVideoLoadingIndicator,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER),
      )

      // Same purely-visual, non-interactive overlays as the image branch —
      // sized/positioned below by layoutImageCanvas() once playerView's own
      // box is known.
      val vignetteOverlay = View(this).apply { isClickable = false }
      vignetteOverlayRef = vignetteOverlay
      root.addView(vignetteOverlay, FrameLayout.LayoutParams(0, 0))

      // No GridOverlayView here (unlike the image branch above) — per the
      // user's explicit "remove grid from video player of editor" request.
      // gridOverlayRef stays null for a video session; layoutImageCanvas's
      // own `gridOverlayRef?.layoutParams = ...` call is a safe no-op.
      val drawingCanvas = DrawingCanvasView(this)
      drawingCanvasRef = drawingCanvas
      drawingCanvas.onStrokeFinished = { stroke ->
        pushUndo(
          undo = { drawingCanvasRef?.removeStroke(stroke) },
          redo = { drawingCanvasRef?.addStroke(stroke) },
        )
      }
      root.addView(drawingCanvas, FrameLayout.LayoutParams(0, 0))

      val player = ExoPlayer.Builder(this).build()
      exoPlayer = player
      playerView.player = player
      // Same combined filter+adjustment matrix as the image preview,
      // applied live via media3's GL effects pipeline — `combinedColorMatrix()`
      // reads brightness/contrast/saturation/etc. fresh every frame (see
      // PhotoFilterRgbMatrix), so the shared filter/adjust sliders just
      // update those fields with no need to touch the player again.
      // Sharpen is the one exception (see its field's own doc) — it's a
      // spatial convolution, not expressible as a ColorMatrix term, so it
      // stays image-only.
      // Filter lookup table + Filters-panel Sharpness first, then the
      // Edit-panel adjustment matrix — same order as the photo path.
      player.setVideoEffects(listOf(
        // Hold-to-compare renders the untouched frame.
        FilterLutEffect { if (isShowingOriginal) filterGpuParams(ClipFilterState()) else filterGpuParams() },
        PhotoFilterRgbMatrix { if (isShowingOriginal) combinedColorMatrix(ClipFilterState()) else combinedColorMatrix() },
      ))
      // A playlist, not a single item, so merged clips (see
      // additionalVideoClipUris's own doc) can be appended live via
      // addMediaItem — REPEAT_MODE_ALL loops the WHOLE playlist back to
      // this primary clip once the last item finishes, matching the
      // user's explicit "played in queue, same like Instagram" request,
      // with no manual restart code needed (unlike iOS's AVQueuePlayer,
      // which consumes each item as playback advances past it).
      player.setMediaItem(MediaItem.fromUri(MediaMetadataReader.normalizedUri(mediaUri)))
      player.repeatMode = Player.REPEAT_MODE_ALL
      player.prepare()
      player.playWhenReady = true
      // Multi-clip case: REPEAT_MODE_ALL wraps the whole playlist back to
      // this primary clip with no manual seek code (see the property's own
      // doc above), so that wrap needs its own hook to also restart the
      // music — per the user's explicit "as video start playing in loop
      // again then the music should be reset and start again" request.
      // The single-clip case is covered separately, inline in the
      // gap-skip poll loop above (that manual seek pre-empts this natural
      // end-of-item transition before it would otherwise fire).
      player.addListener(object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
          if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT) resetMusicToLoopStart()
          // Per the user's explicit "on joint of both video, video is
          // flicking" report: the filmstrip's yellow border/duration-label
          // highlight and the auto-follow scroll position both only ever
          // updated from the ~16ms timelineRunnable poll, which reads
          // player.currentMediaItemIndex/currentPosition — but a clip-to-
          // clip transition (especially the gap-skip poll's own manual
          // seekToNextMediaItem() call above, for a trimmed primary clip)
          // is asynchronous, and a screen-recording frame-by-frame check
          // showed the ACTUAL rendered video content switching several
          // poll ticks (~80-100ms) before player.currentMediaItemIndex
          // itself reflected the new item — so for that whole window the
          // filmstrip kept showing the PREVIOUS clip highlighted/in view,
          // then abruptly popped to the new one once the poll finally
          // caught up. Updating right here — fired the instant ExoPlayer
          // itself considers the transition to have happened, regardless
          // of reason — closes that gap instead of waiting on the next
          // poll tick.
          if (!isUserScrubbingFilmstrip && !isFilmstripFingerDown) {
            updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer = false)
            filmstripScrollViewRef?.scrollTo(scrollXForCombinedTimeMs(combinedTimeForCurrentPlaybackMs()), 0)
          }
        }
      })

      val coordinator = LayerGestureCoordinator(this)
      coordinator.addLayer(playerView)
      coordinator.boundedLayer = playerView
      coordinator.onLayerLongPressed = { target ->
        if (target !== playerView) confirmDeleteLayer(target)
      }
      coordinator.onLayerTapped = { target ->
        if (target != null && target !== playerView) {
          if (target !== selectedLayerView) root.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
          selectLayer(target)
          cycleLocationLayerStyleIfNeeded(target)
        } else {
          deselectLayer()
        }
      }
      // No toolbar work while dragging: the Delete / Duplicate / Edit bar
      // sits at a fixed spot above the tools, and re-applying its layout
      // params on every move frame forced a full layout of the whole screen.
      coordinator.onLayerTransformed = if (isStoryMode) {
        { target -> if (target === selectedLayerView) updateStickerDeleteBadge() }
      } else null
      coordinator.onLayerTransformCommitted = { target, old, new -> commitLayerTransformUndo(target, old, new) }
      coordinator.isLayerTransformLocked = { layer -> isLayerLocked(layer) || isLayerUserHidden(layer) }
      coordinator.isLayerHitExcluded = { layer -> isLayerUserHidden(layer) }
      coordinator.onSnapChanged = { state -> showSnapGuides(state) }
      root.setOnTouchListener(coordinator)
      gestureCoordinator = coordinator
      // Yellow border shown by default (no overlay layer selected yet) —
      // see updateCanvasSelectionBorder's own doc.
      updateCanvasSelectionBorder()

      // Shared chrome (top bar, bottom tab tray, Filters+Adjust strip,
      // Stickers/Draw/Music panels) — same function the image branch uses,
      // passing null for the (image-only) live-preview ImageView. Built
      // before the canvas is sized below, same ordering as the image
      // branch, so the reserved chrome height is already known.
      val chrome = setUpEditingControls(null)
      val displaySize = MediaMetadataReader.read(this, mediaUri, mediaType)?.let { it.width to it.height }
      canvasChromeRef = chrome
      canvasDisplaySizeRef = displaySize
      layoutImageCanvas(playerView, chrome, displaySize)

      // Play/pause + trim scrubber have no equivalent in the image editor —
      // positioned in their own row directly above the shared Filters+
      // Adjust strip (chrome.bottomChromeHeightPx), rather than the
      // screen's true bottom edge, mirroring how the canvas itself now
      // stops above that same strip.
      // Play/pause sits to the LEFT of the scrubber, both in the same row
      // (previously play/pause was its own row directly above), per the
      // user's explicit reference screenshot of a Photos/iMovie-style trim
      // scrubber with transport controls beside it, not above it. An icon
      // button (not text) sized to just the accessibility-minimum tap
      // target, and outer margins matching the same "very close to the
      // screen edge" value already established for the crop box
      // (EditorDesignTokens' 4dp cropper margin) give the whole row its
      // width back, per the user's explicit "stretch closer to edges".
      val videoControlsGapPx = (12f * resources.displayMetrics.density).toInt()
      val trimViewHeightPx = (48f * resources.displayMetrics.density).toInt()
      val sideMarginPx = (4f * resources.displayMetrics.density).toInt()
      // Declared up-front (rather than beside the Split/Delete buttons
      // below, where they're used) so the backdrop's height — which spans
      // the whole floating control cluster including this row — can be
      // computed and added to `root` before playPauseButton/videoTrimView
      // are, keeping it behind all four controls in z-order.
      val splitDeleteButtonSizePx = (36f * resources.displayMetrics.density).toInt()
      val splitDeleteGlyphPx = EditorDesignTokens.dpToPx(22f, resources.displayMetrics.density)
      val splitDeleteRowGapPx = (8f * resources.displayMetrics.density).toInt()
      val splitDeleteButtonGapPx = (12f * resources.displayMetrics.density).toInt()
      // Matches splitDeleteGlyphPx (22dp) per the user's later, explicit
      // "play/pause icons should be the same size as the delete icon"
      // correction to the earlier "increase size of the play/pause icons"
      // request this constant originally implemented (which had bumped it
      // to 38dp, well past the scissors/trash icons beside it).
      val playPauseGlyphPx = splitDeleteGlyphPx
      val playPauseIconView = EditorIconView(this, EditorIcon.PAUSE).apply {
        iconTint = EditorDesignTokens.Colors.textPrimary
      }
      // Tracks the user's INTENDED play state, not the engine's transient
      // one — ExoPlayer's own `isPlaying` flips to false as soon as it
      // reaches STATE_ENDED at an item's natural end (the common
      // un-trimmed case, where trimEndMs == the clip's true end), so
      // gating trim-loop-resume on `player.isPlaying` at that exact
      // moment would wrongly read as "user paused" and never loop.
      var isVideoPlaying = true
      val playPauseButton = FrameLayout(this).apply {
        // Video redesign: the same dark glass circle as the top-bar controls.
        background = GradientDrawable().apply {
          shape = GradientDrawable.OVAL
          setColor(Color.argb(199, 0x20, 0x22, 0x27))
          setStroke(EditorDesignTokens.dpToPx(0.5f, resources.displayMetrics.density).coerceAtLeast(1), Color.argb(31, 255, 255, 255))
        }
        addView(playPauseIconView, FrameLayout.LayoutParams(playPauseGlyphPx, playPauseGlyphPx, Gravity.CENTER))
        setOnClickListener {
          if (isPressed) performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          if (player.isPlaying) {
            player.pause()
            musicPlayer?.pause()
            isVideoPlaying = false
            playPauseIconView.icon = EditorIcon.PLAY
          } else {
            player.play()
            musicPlayer?.play()
            isVideoPlaying = true
            playPauseIconView.icon = EditorIcon.PAUSE
          }
        }
      }

      val videoTrimView = VideoTrimView(this)
      videoTrimViewRef = videoTrimView
      playPauseButtonRef = playPauseButton

      // Scrim spans from just above the Split/Delete row down to the
      // canvas's own bottom edge (chrome.bottomChromeHeightPx above
      // root's bottom — the same reference the controls below anchor
      // against), so the whole floating control cluster sits on a
      // darkened band rather than directly on raw video pixels. Added
      // BEFORE the buttons below so it renders behind all of them, in
      // front of the video.
      val backdropExtraTopPaddingPx = (8f * resources.displayMetrics.density).toInt()
      val videoControlsBackdropHeightPx = videoControlsGapPx + trimViewHeightPx +
        splitDeleteRowGapPx + splitDeleteButtonSizePx + backdropExtraTopPaddingPx
      videoChromeBottomHeightPx = chrome.bottomChromeHeightPx
      val videoControlsBackdrop = View(this).apply {
        setBackgroundColor(Color.TRANSPARENT)
        isClickable = false
        isFocusable = false
      }
      videoControlsBackdropRef = videoControlsBackdrop
      root.addView(
        videoControlsBackdrop,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, videoControlsBackdropHeightPx, Gravity.BOTTOM)
          .apply { bottomMargin = chrome.bottomChromeHeightPx },
      )

      // Per-layer track rows — per the user's explicit "display these
      // both layers on screen" correction, stacked directly above the
      // trim scrubber (same left/right inset), always visible here
      // rather than behind a separate tab. Height starts at 0 (no
      // layers yet) and is recomputed by refreshLayersPanel() as layers
      // are added/removed, up to a cap — see that function's own doc.
      layerTracksFixedBottomMarginPx = chrome.bottomChromeHeightPx + videoControlsGapPx + trimViewHeightPx + splitDeleteRowGapPx
      filmstripBandBottomMarginPx = chrome.bottomChromeHeightPx + videoControlsGapPx
      // Fixed pixel width (placeholder here — kept in sync with the SAME
      // total combined width as videoTrimView+mergedStripView by
      // updateFilmstripLayout) so this vertical stack of rows is exactly
      // as wide as the shared scrollable timeline; its own horizontal
      // position is mirrored (not independently user-scrollable, unlike
      // iOS's dual-axis UIScrollView — see setOnScrollChangeListener
      // below) via a plain View.scrollTo() call, since a ScrollView only
      // supports ONE axis on Android and nesting a perpendicular one here
      // is more touch-arbitration risk than this needs.
      val layerTracksStack = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = ViewGroup.LayoutParams((100f * resources.displayMetrics.density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT)
      }
      layerTracksStackRef = layerTracksStack
      val layerTracksScrollView = ScrollView(this).apply {
        // Visible (fading) bar once there are more rows than the 3 that fit.
        isVerticalScrollBarEnabled = true
        // No stretch/glow overscroll — the rows felt "bouncy" while scrolling.
        overScrollMode = View.OVER_SCROLL_NEVER
        // THE actual root cause of the long-running "text/sticker layer
        // cut off on the left" bug: this is a VERTICAL ScrollView, reused
        // to hold HORIZONTALLY-positioned content (see
        // layerTracksStackRef's own doc). Android's clipToPadding=false
        // (set in updateFilmstripContentPaddingIfNeeded) only relaxes
        // clipping along a ScrollView's OWN scroll axis — vertical, here
        // — it does NOT affect the perpendicular (horizontal) axis, which
        // stays clipped to [paddingLeft, width-paddingRight] regardless.
        // That's why filmstripScrollView (a REAL HorizontalScrollView,
        // whose scroll axis genuinely IS horizontal) renders correctly
        // with the identical padding trick, while this view's content was
        // silently clipped at its own left-padding boundary — a screen X
        // that's FIXED (unrelated to scroll position), exactly matching
        // every debug screenshot this session: the row's own computed
        // position (xFor/getLocationOnScreen) was ALWAYS mathematically
        // correct and varied properly with scroll, yet the VISIBLE left
        // edge of every layer bar sat at the same fixed X every time.
        // clipChildren (unlike clipToPadding) applies uniformly to BOTH
        // axes, so disabling it here lets content draw across its full
        // width — still correctly bounded by `root`'s own clipping of
        // this view's outer edges (its left/right margins), matching the
        // video row's own visible window exactly.
        clipChildren = false
        addView(layerTracksStack)
      }
      layerTracksScrollViewRef = layerTracksScrollView
      root.addView(
        layerTracksScrollView,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, Gravity.BOTTOM)
          .apply {
            bottomMargin = layerTracksFixedBottomMarginPx
            // Matches filmstripBand's own leading/trailing margins EXACTLY
            // (not independently) so the visible window into this
            // mirrored-scroll content lines up with the video row's own
            // visible window — per the user's explicit reference
            // multi-track timeline. Play/pause used to be inline here
            // (reserving extra left/right space) but per the user's
            // explicit "utilise these left and right space from layers,
            // all layers should cover full width" request it now lives in
            // the top row instead (see playPauseButton below), so this is
            // plain sideMarginPx on both sides.
            leftMargin = sideMarginPx
            rightMargin = sideMarginPx
          },
      )

      // Extends the video row's own playhead line (filmstripPlayhead,
      // added further below) up through the layer-tracks area too — see
      // layerTracksPlayheadRef's own doc. Height/bottomMargin start at 0
      // here (no layers yet) and are recomputed by refreshLayersPanel()
      // in lockstep with layerTracksScrollView's own height, right above.
      val layerTracksPlayhead = View(this).apply { setBackgroundColor(Color.WHITE) }
      layerTracksPlayheadRef = layerTracksPlayhead
      root.addView(
        layerTracksPlayhead,
        FrameLayout.LayoutParams((2f * resources.displayMetrics.density).toInt(), 0, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL)
          .apply { bottomMargin = filmstripBandBottomMarginPx },
      )

      // Sits directly above the (collapsible) layer tracks, in the same
      // top band as Split/Delete below — toggling between CHEVRON_DOWN
      // (expanded — tap to collapse) and CHEVRON_UP (collapsed — tap to
      // re-expand). Height starts at 0 (hidden — no layers yet) and is
      // recomputed by refreshLayersPanel() alongside the tracks/scrim,
      // so a session with no text/sticker/overlay layers never reserves
      // this space.
      val layersAreaCollapseIcon = EditorIconView(this, EditorIcon.CHEVRON_UP).apply {
        iconTint = EditorDesignTokens.Colors.textPrimary
      }
      layersAreaCollapseIconRef = layersAreaCollapseIcon
      // Video redesign: "Layers · N ⌃" pill instead of a bare chevron
      // (count set in refreshLayersPanel).
      layersAreaCollapseIcon.iconTint = EditorDesignTokens.Colors.textSecondary
      val layersAreaCollapseLabel = TextView(this).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setTextColor(EditorDesignTokens.Colors.textSecondary)
        typeface = android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD)
        text = "Layers"
      }
      layersAreaCollapseLabelRef = layersAreaCollapseLabel
      val layersAreaCollapseButton = FrameLayout(this).apply {
        val pillPadPx = EditorDesignTokens.dpToPx(12f, resources.displayMetrics.density)
        setPadding(pillPadPx, 0, pillPadPx, 0)
        addView(
          LinearLayout(this@MediaEditorActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(layersAreaCollapseLabel, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(
              layersAreaCollapseIcon,
              LinearLayout.LayoutParams(
                EditorDesignTokens.dpToPx(12f, resources.displayMetrics.density),
                EditorDesignTokens.dpToPx(12f, resources.displayMetrics.density),
              ).apply { leftMargin = EditorDesignTokens.dpToPx(6f, resources.displayMetrics.density) },
            )
          },
          FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER),
        )
        setOnClickListener {
          root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          isLayersAreaCollapsed = !isLayersAreaCollapsed
          refreshLayersPanel()
        }
      }
      layersAreaCollapseButtonRef = layersAreaCollapseButton
      root.addView(
        layersAreaCollapseButton,
        // Board V7: pill on the left, "+ Layer" on the right of its row.
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, 0, Gravity.BOTTOM or Gravity.START)
          .apply {
            bottomMargin = layerTracksFixedBottomMarginPx
            leftMargin = EditorDesignTokens.dpToPx(4f, resources.displayMetrics.density)
          },
      )
      val addLayerButton = makeAddLayerButton()
      addLayerButtonRef = addLayerButton
      root.addView(
        addLayerButton,
        FrameLayout.LayoutParams(
          EditorDesignTokens.dpToPx(ADD_LAYER_BUTTON_WIDTH_DP, resources.displayMetrics.density),
          EditorDesignTokens.dpToPx(36f, resources.displayMetrics.density),
          Gravity.BOTTOM or Gravity.END,
        )
          .apply {
            bottomMargin = layerTracksFixedBottomMarginPx
            rightMargin = EditorDesignTokens.dpToPx(8f, resources.displayMetrics.density)
          },
      )
      val videoCompareButton = FrameLayout(this).apply {
        addView(
          EditorIconView(this@MediaEditorActivity, EditorIcon.COMPARE).apply { iconTint = EditorDesignTokens.Colors.textPrimary },
          FrameLayout.LayoutParams(EditorDesignTokens.dpToPx(22f, resources.displayMetrics.density), EditorDesignTokens.dpToPx(22f, resources.displayMetrics.density), Gravity.CENTER),
        )
        contentDescription = "Hold to compare with original"
        visibility = View.INVISIBLE
        setOnTouchListener { v, event ->
          when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
              v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
              showOriginalPreview()
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> restoreEditedPreview()
          }
          true
        }
      }
      videoCompareButtonRef = videoCompareButton
      root.addView(
        videoCompareButton,
        FrameLayout.LayoutParams(
          EditorDesignTokens.dpToPx(32f, resources.displayMetrics.density),
          EditorDesignTokens.dpToPx(36f, resources.displayMetrics.density),
          Gravity.BOTTOM or Gravity.END,
        ).apply { bottomMargin = layerTracksFixedBottomMarginPx },
      )
      val clipSpeedIcon = EditorIconView(this, EditorIcon.SPEED).apply { iconTint = EditorDesignTokens.Colors.textPrimary }
      clipSpeedIconRef = clipSpeedIcon
      val clipSpeedButton = FrameLayout(this).apply {
        addView(
          clipSpeedIcon,
          FrameLayout.LayoutParams(EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), Gravity.CENTER),
        )
        visibility = View.INVISIBLE
        contentDescription = "Clip speed"
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          showClipSpeedPicker()
        }
      }
      clipSpeedButtonRef = clipSpeedButton
      val transitionIcon = EditorIconView(this, EditorIcon.TRANSITION).apply { iconTint = EditorDesignTokens.Colors.textPrimary }
      val clipTransitionButton = FrameLayout(this).apply {
        addView(transitionIcon, FrameLayout.LayoutParams(EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), Gravity.CENTER))
        visibility = View.INVISIBLE
        contentDescription = "Transition into this clip"
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          showClipTransitionPicker()
        }
      }
      clipTransitionButtonRef = clipTransitionButton
      clipTransitionIconRef = transitionIcon
      val textAnimIcon = EditorIconView(this, EditorIcon.SPARKLE).apply { iconTint = EditorDesignTokens.Colors.textPrimary }
      val textAnimButton = FrameLayout(this).apply {
        addView(textAnimIcon, FrameLayout.LayoutParams(EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), Gravity.CENTER))
        visibility = View.INVISIBLE
        contentDescription = "Text animation"
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          showTextAnimationMenu()
        }
      }
      textAnimationButtonRef = textAnimButton
      textAnimationIconRef = textAnimIcon
      root.addView(
        textAnimButton,
        FrameLayout.LayoutParams(
          EditorDesignTokens.dpToPx(32f, resources.displayMetrics.density),
          EditorDesignTokens.dpToPx(36f, resources.displayMetrics.density),
          Gravity.BOTTOM or Gravity.END,
        ).apply { bottomMargin = layerTracksFixedBottomMarginPx },
      )
      root.addView(
        clipTransitionButton,
        FrameLayout.LayoutParams(
          EditorDesignTokens.dpToPx(32f, resources.displayMetrics.density),
          EditorDesignTokens.dpToPx(36f, resources.displayMetrics.density),
          Gravity.BOTTOM or Gravity.END,
        ).apply { bottomMargin = layerTracksFixedBottomMarginPx },
      )
      root.addView(
        clipSpeedButton,
        FrameLayout.LayoutParams(
          EditorDesignTokens.dpToPx(LAYER_STATE_BUTTON_WIDTH_DP, resources.displayMetrics.density),
          EditorDesignTokens.dpToPx(36f, resources.displayMetrics.density),
          Gravity.BOTTOM or Gravity.END,
        ).apply { bottomMargin = layerTracksFixedBottomMarginPx },
      )
      for (isVolume in listOf(true)) {
        val icon = EditorIconView(this, EditorIcon.VOLUME).apply { iconTint = EditorDesignTokens.Colors.textPrimary }
        val button = FrameLayout(this).apply {
          addView(icon, FrameLayout.LayoutParams(EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), Gravity.CENTER))
          visibility = View.INVISIBLE
          contentDescription = "Clip volume"
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            toggleClipVolumePanel()
          }
        }
        clipVolumeButtonRef = button
        clipVolumeIconRef = icon
        root.addView(
          button,
          FrameLayout.LayoutParams(
            EditorDesignTokens.dpToPx(LAYER_STATE_BUTTON_WIDTH_DP, resources.displayMetrics.density),
            EditorDesignTokens.dpToPx(36f, resources.displayMetrics.density),
            Gravity.BOTTOM or Gravity.END,
          ).apply { bottomMargin = layerTracksFixedBottomMarginPx },
        )
      }
      for (isLock in listOf(false, true)) {
        val icon = EditorIconView(this, if (isLock) EditorIcon.UNLOCK else EditorIcon.EYE).apply { iconTint = EditorDesignTokens.Colors.textPrimary }
        val button = FrameLayout(this).apply {
          addView(icon, FrameLayout.LayoutParams(EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), EditorDesignTokens.dpToPx(20f, resources.displayMetrics.density), Gravity.CENTER))
          visibility = View.INVISIBLE
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            if (isLock) toggleSelectedLayerLocked() else toggleSelectedLayerHidden()
          }
        }
        if (isLock) { layerLockButtonRef = button; layerLockIconRef = icon } else { layerHideButtonRef = button; layerHideIconRef = icon }
        root.addView(
          button,
          FrameLayout.LayoutParams(
            EditorDesignTokens.dpToPx(LAYER_STATE_BUTTON_WIDTH_DP, resources.displayMetrics.density),
            EditorDesignTokens.dpToPx(36f, resources.displayMetrics.density),
            Gravity.BOTTOM or Gravity.END,
          ).apply { bottomMargin = layerTracksFixedBottomMarginPx },
        )
      }
      // A fresh session has no layers yet, so nothing else lays out the
      // "Layers · N / + Layer" row until the first add — reserve it now.
      // Also re-applies the play row's visibility: updateImageEditorUI ran
      // inside setUpEditingControls, BEFORE the time label / "+" / compare
      // existed, so they stayed hidden on a fresh session until a tool
      // was opened once.
      root.post {
        refreshLayersPanel()
        updateImageEditorUI(animated = false)
      }

      // Moved up to the TOP row (same line as the collapse chevron and
      // Split/Delete, left-aligned) per the user's explicit "keep play
      // pause icon on left top same line we have keep trim and delete in
      // right top" request — it used to sit inline beside the filmstrip,
      // reserving left space from every layer track row below. bottomMargin
      // is re-synced to topBandBottomMarginPx in refreshLayersPanel
      // alongside Split/Delete, since that value shifts as the layer
      // tracks' own height changes. Sized to match the row's own height
      // (splitDeleteButtonSizePx) instead of the taller trimViewHeightPx it
      // used to use inline.
      root.addView(
        playPauseButton,
        FrameLayout.LayoutParams(splitDeleteButtonSizePx, splitDeleteButtonSizePx, Gravity.BOTTOM)
          .apply {
            bottomMargin = layerTracksFixedBottomMarginPx
            leftMargin = sideMarginPx
          },
      )
      val videoTimeLabel = TextView(this).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setTextColor(EditorDesignTokens.Colors.textPrimary)
        fontFeatureSettings = "tnum"
        gravity = Gravity.CENTER_VERTICAL
        isClickable = false
        isFocusable = false
        visibility = View.INVISIBLE
      }
      videoTimeLabelRef = videoTimeLabel
      root.addView(
        videoTimeLabel,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, splitDeleteButtonSizePx, Gravity.BOTTOM)
          .apply {
            bottomMargin = layerTracksFixedBottomMarginPx
            leftMargin = sideMarginPx + splitDeleteButtonSizePx + (10f * resources.displayMetrics.density).toInt()
          },
      )
      // Merged clips continue the SAME filmstrip row, immediately trailing
      // videoTrimView with ZERO gap — see VideoTrimView.squareTrailingCorners
      // / LayerRangeBarView.isMergedClipsContinuation for how the two
      // views' own drawing avoids a visible seam at this exact boundary.
      // Wrapped in one LinearLayout (fixed pixel widths, set in
      // updateFilmstripLayout from timelinePointsPerSecondPx — no more
      // weight-based proportional-fit) which is itself the CONTENT of a
      // HorizontalScrollView, per the user's explicit "full Instagram-
      // style scrolling timeline" choice — a longer combined video
      // produces a WIDER scrollable strip instead of a squeezed one.
      val mergedStripView = LayerRangeBarView(this)
      mergedStripViewRef = mergedStripView
      mergedStripView.isMergedClipsContinuation = true
      // newStartMs/newEndMs arrive in the bar's own COMPACTED coordinate
      // space (see refreshMergedClipsStrip's doc) — the matching entry in
      // mergedClipSegmentAnchorsMs[uri] is THIS segment's own fixed slot
      // start as of the last refresh, so (newStartMs - anchorMs) is a
      // DELTA from that slot's original edges, not an absolute real time.
      // Adding that delta to the STABLE reference segment (captured at
      // the same refresh, not the live-mutating additionalClipSegments
      // map) correctly handles the only drag type this row allows (edge-
      // drag — body/move is never enabled for mergedStripView). Clamped
      // against this clip's OWN immediately adjacent segment (if any) so
      // dragging one segment's edge can never cross into a neighboring
      // segment's own space and corrupt the resulting playlist's segment
      // order — mirrors VideoTrimView's own single-item "first segment's
      // start / last segment's end only" scope cut, just enforced via
      // clamping here instead since LayerRangeBarView already lets every
      // segment's own edges drag independently (the same capability
      // layer segments already rely on).
      mergedStripView.onRangeChanged = { id, segmentIndex, newStartMs, newEndMs ->
        val uri = additionalVideoClipUris.firstOrNull { proxyView(it) === id }
        val referenceSegments = uri?.let { mergedClipReferenceSegmentsMs[it] }
        val anchors = uri?.let { mergedClipSegmentAnchorsMs[it] }
        if (uri != null && referenceSegments != null && anchors != null &&
          referenceSegments.indices.contains(segmentIndex) && anchors.indices.contains(segmentIndex)
        ) {
          val fullDurationMs = additionalClipDurationsMs[uri] ?: 5000L
          val anchorMs = anchors[segmentIndex]
          val referenceSegment = referenceSegments[segmentIndex]
          val referenceLengthMs = referenceSegment.last - referenceSegment.first
          val floorMs = if (segmentIndex > 0) referenceSegments[segmentIndex - 1].last else 0L
          val ceilingMs = if (segmentIndex < referenceSegments.size - 1) referenceSegments[segmentIndex + 1].first else fullDurationMs
          var newLocalStartMs = (referenceSegment.first + (newStartMs - anchorMs)).coerceIn(floorMs, fullDurationMs)
          var newLocalEndMs = (referenceSegment.last + (newEndMs - (anchorMs + referenceLengthMs))).coerceIn(newLocalStartMs, fullDurationMs)
          newLocalStartMs = newLocalStartMs.coerceAtMost(ceilingMs)
          newLocalEndMs = newLocalEndMs.coerceAtMost(ceilingMs)
          val segments = additionalClipSegments[uri]
          if (segments != null && segments.indices.contains(segmentIndex)) {
            segments[segmentIndex] = newLocalStartMs..newLocalEndMs
            updateFilmstripLayout()
          }
        }
      }
      // Tracks which SEGMENT of the active merged clip was last tapped —
      // the Delete button's target, mirroring videoTrimViewRef's own
      // onSegmentSelected wiring. Which CLIP is "active" (yellow border,
      // trimmable, deletable-as-a-whole) is still driven entirely by
      // scroll position (see updateActiveClipHighlight) — this is only
      // about WHICH of that clip's own segments Split/Delete should
      // target.
      mergedStripView.onItemSelected = { id, segmentIndex ->
        val uri = additionalVideoClipUris.firstOrNull { proxyView(it) === id }
        if (uri != null) {
          deselectLayer()
          videoTrimViewRef?.clearSegmentSelection()
          selectedMergedClipUri = uri
          selectedMergedClipSegmentIndex = segmentIndex
          selectedMusicSegmentIndex = null
          isVoiceRowSelected = false
          updateLayerStateButtons()
        }
      }
      // Deferred to drag-END (not every onRangeChanged tick) so the
      // ExoPlayer playlist isn't rebuilt dozens of times per second while
      // the user is still actively dragging. Also re-packs every item's
      // anchor from the now-settled trims, immediately closing any gap
      // the drag just opened rather than leaving it until some other,
      // unrelated refresh happens to fire.
      mergedStripView.onDragEnded = {
        rebuildAdditionalPlaylistItems()
        refreshMergedClipsStrip()
      }
      // isFilmstripFingerDown (see its own doc) never gets set for THIS
      // gesture at all — once mergedStripView's onTouchEvent claims an
      // edge-drag (parent.requestDisallowInterceptTouchEvent(true)),
      // every later event for that gesture is dispatched straight to it,
      // bypassing filmstripScrollView's own dispatchTouchEvent (and
      // therefore its setOnTouchListener) entirely. So this callback —
      // not the outer touch listener — is the ONLY reliable signal for
      // this specific case, and it needs the SAME cooldown the settle-
      // check applies: an edge-drag never changes scrollX directly (it
      // resizes a segment instead), so no settle-check ever gets
      // scheduled for it, and without this the very next poll tick would
      // immediately re-sync scrollX to the (unchanged) player position —
      // this IS the actual "again and again" snap-back the user kept
      // hitting, since a normal scroll-back gesture starting near the
      // active clip's own left edge (exactly where you'd naturally grab
      // to drag it back into view) lands inside the edge hit-region.
      mergedStripView.onHandleDragStateChanged = { isDragging ->
        isUserScrubbingFilmstrip = isDragging
        if (!isDragging) filmstripSeekCooldownUntilMs = android.os.SystemClock.elapsedRealtime() + 400L
      }
      // Long-press + vertical drag reorders merged video clips relative
      // to each other — per the user's explicit "if i want to reorder
      // video clips in layers... i can by long press on these element and
      // drag it" request. A merged-clip row used to just `return false`
      // on a body touch, falling through natively to filmstripScrollView
      // (its real ancestor HorizontalScrollView) — now it must actively
      // claim that touch instead (to leave the reorder option open), so
      // it needs the SAME manual scroll-forwarding the non-merged rows
      // already use once a pending long-press gets cancelled by movement.
      mergedStripView.onUnhandledDragDeltaX = { deltaX ->
        filmstripScrollViewRef?.let { sv ->
          isUserScrubbingFilmstrip = true
          sv.scrollBy((-deltaX).toInt(), 0)
        }
      }
      mergedStripView.onReorderSwap = { a, b ->
        val uriA = additionalVideoClipUris.firstOrNull { proxyView(it) === a }
        val uriB = additionalVideoClipUris.firstOrNull { proxyView(it) === b }
        if (uriA != null && uriB != null) {
          val idxA = additionalVideoClipUris.indexOf(uriA)
          val idxB = additionalVideoClipUris.indexOf(uriB)
          val tmp = additionalVideoClipUris[idxA]
          additionalVideoClipUris[idxA] = additionalVideoClipUris[idxB]
          additionalVideoClipUris[idxB] = tmp
        }
      }
      mergedStripView.onReorderEnded = {
        rebuildAdditionalPlaylistItems()
        refreshMergedClipsStrip()
      }

      // Fixed pixel widths, both updated live by updateFilmstripLayout —
      // placeholder values here just avoid a zero-size flash before the
      // first real layout pass.
      val filmstripRowContainer = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(videoTrimView, LinearLayout.LayoutParams((100f * resources.displayMetrics.density).toInt(), trimViewHeightPx))
        addView(mergedStripView, LinearLayout.LayoutParams(0, trimViewHeightPx))
      }
      filmstripRowContainerRef = filmstripRowContainer
      // A dispatchTouchEvent override, NOT a plain HorizontalScrollView —
      // per the 3rd/definitive debug recording, LayerRangeBarView's
      // "reorder candidate found" ACTION_DOWN path claims the touch
      // (returns true) without calling requestDisallowInterceptTouchEvent,
      // so THIS ScrollView goes on to intercept natively mid-gesture once
      // ITS OWN touch slop is exceeded — genuinely scrolling correctly —
      // but because the original ACTION_DOWN went to that child first, the
      // setOnTouchListener below (which is only invoked when the
      // ScrollView ends up dispatching to itself, i.e. AFTER it decides to
      // intercept) never sees that DOWN, so isFilmstripFingerDown/
      // isUserScrubbingFilmstrip never flip true for that whole gesture —
      // confirmed by the debug overlay showing "OUTER listener saw
      // ACTION_MOVE" as the very FIRST event it logs for such a gesture,
      // never a DOWN. dispatchTouchEvent, unlike onTouchEvent/
      // setOnTouchListener, is invoked on this View for EVERY event that
      // reaches its bounds — before any decision about intercepting vs.
      // delegating to a child — so overriding it here is the one hook
      // that's reliably first regardless of which descendant ends up
      // claiming the gesture.
      val filmstripScrollView = object : HorizontalScrollView(this) {
        override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
          when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
              isUserScrubbingFilmstrip = true
              isFilmstripFingerDown = true
              if (exoPlayer?.isPlaying == true) {
                wasPlayingBeforeFilmstripScrub = true
                exoPlayer?.pause()
              }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
              isFilmstripFingerDown = false
              if (wasPlayingBeforeFilmstripScrub) {
                wasPlayingBeforeFilmstripScrub = false
                exoPlayer?.play()
              }
            }
          }
          return super.dispatchTouchEvent(ev)
        }
      }.apply {
        isHorizontalScrollBarEnabled = false
        overScrollMode = View.OVER_SCROLL_NEVER
        addView(filmstripRowContainer, ViewGroup.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, trimViewHeightPx))
        // Live, on every scroll delta regardless of source (user drag OR
        // our own programmatic scrollTo that follows hands-off playback)
        // — cheap (just flag toggles + a small items remap), so updating
        // it continuously is fine; the actual player SEEK only happens
        // once the user's drag settles (see the touch listener + settle
        // detector below).
        setOnScrollChangeListener { _, scrollX, _, _, _ ->
          // Per the user's explicit reference multi-track timeline, the
          // Text/Sticker/Overlay layer rows above must scroll in perfect
          // lockstep with the video row — a plain View.scrollTo (not a
          // second scroll view) since layerTracksStackRef isn't itself
          // independently user-scrollable (see its own setup doc).
          layerTracksStackRef?.scrollTo(scrollX, 0)
          updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer = isUserScrubbingFilmstrip)
          updateVideoTimeLabel(combinedTimeMs(scrollX))
          // Scheduled on every real scrollX change (not just while
          // isUserScrubbingFilmstrip is already true) since scroll
          // position is the one source of truth that's always correct,
          // regardless of which touch path (native ScrollView interception
          // vs. LayerRangeBarView's manual relay) actually caused it.
          scheduleFilmstripSettleCheck(this, scrollX)
        }
        setOnTouchListener { view, _ ->
          view.performClick()
          false
        }
      }
      filmstripScrollViewRef = filmstripScrollView

      val filmstripPlayhead = View(this).apply { setBackgroundColor(Color.WHITE) }
      filmstripPlayheadRef = filmstripPlayhead

      // A shared band container sized EXACTLY to the visible filmstrip
      // area — the scroll view and the fixed playhead line are both its
      // direct children, so Gravity.CENTER_HORIZONTAL on the playhead
      // lines up with the scroll view's own visible center with no
      // manual margin arithmetic needed.
      val filmstripBand = FrameLayout(this).apply {
        addView(filmstripScrollView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addView(
          filmstripPlayhead,
          FrameLayout.LayoutParams((2f * resources.displayMetrics.density).toInt(), ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER_HORIZONTAL),
        )
      }
      filmstripBandRef = filmstripBand
      root.addView(
        filmstripBand,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, trimViewHeightPx, Gravity.BOTTOM)
          .apply {
            bottomMargin = chrome.bottomChromeHeightPx + videoControlsGapPx
            // No longer reserves space for playPauseButton — moved to the
            // top row (see its own addView call) per the user's explicit
            // "utilise these left and right space from layers, all layers
            // should cover full width" request.
            leftMargin = sideMarginPx
            rightMargin = sideMarginPx
          },
      )
      videoTrimView.loadThumbnails(this, MediaMetadataReader.normalizedUri(mediaUri))
      videoTrimView.onSegmentsChanged = { segments ->
        videoSegments = segments
        updateFilmstripLayout()
      }
      // Same reasoning as mergedStripView's identical wiring above: an
      // edge-drag claims the gesture past filmstripScrollView's own
      // touch listener (isFilmstripFingerDown never fires for it), and
      // never itself changes scrollX, so no settle-check ever schedules
      // a cooldown for it — this callback has to set one directly.
      videoTrimView.onHandleDragStateChanged = { isDragging ->
        isUserScrubbingFilmstrip = isDragging
        if (!isDragging) filmstripSeekCooldownUntilMs = android.os.SystemClock.elapsedRealtime() + 400L
      }
      // Tapping a video segment and tapping a layer's own timeline row are
      // two different "what should Delete act on" contexts — deselecting
      // any layer here means a stale prior layer selection can never
      // silently steal a delete meant for the video segment the user just
      // tapped (see the delete button's own routing below).
      videoTrimView.onSegmentSelected = {
        isVoiceRowSelected = false
        deselectLayer()
        selectedMergedClipUri = null
        selectedMergedClipSegmentIndex = null
        selectedMusicSegmentIndex = null
        updateLayerStateButtons()
      }

      // Split cuts the segment under the current playhead into two;
      // Delete removes whichever segment the playhead currently sits in
      // (guarded against deleting the last remaining one) — per the
      // user's explicit "split video into multiple parts and delete any
      // of them" request. Row sits at the TOP of the whole cluster
      // (top-right), not sandwiched between the layer tracks and the
      // trim scrubber — per the user's explicit "keep split and delete
      // icon on top right side of all layer, not in the middle"
      // correction. Positioned relative to layerTracksFixedBottomMarginPx
      // + the tracks' OWN current height (0 initially), recomputed by
      // refreshLayersPanel() every time that height changes.
      val splitSegmentButton = FrameLayout(this).apply {
        addView(
          EditorIconView(this@MediaEditorActivity, EditorIcon.SPLIT).apply { iconTint = EditorDesignTokens.Colors.textPrimary },
          FrameLayout.LayoutParams(splitDeleteGlyphPx, splitDeleteGlyphPx, Gravity.CENTER),
        )
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          if (blockIfSelectedLayerLocked()) return@setOnClickListener
          // Beat sync: move the cut to the nearest beat first.
          if (beatSnapEnabled && !skipNextBeatSnap) {
            val now = combinedTimeForCurrentPlaybackMs()
            val beat = nearestBeatMs(now, 300)
            if (beat != null && kotlin.math.abs(beat - now) > 20) {
              seekCombinedTimeline(beat)
              filmstripScrollViewRef?.scrollTo(scrollXForCombinedTimeMs(beat), 0)
              updateVideoTimeLabel(beat)
              skipNextBeatSnap = true
              val button = it
              button.postDelayed({ button.performClick(); skipNextBeatSnap = false }, 200)
              return@setOnClickListener
            }
          }
          // Per the user's explicit "same split music layer also" request
          // — Split/Delete target the music row whenever IT was the last
          // thing tapped in the layer tracks (selectedMusicSegmentIndex),
          // same priority as a selected canvas layer below.
          if (selectedMusicSegmentIndex != null) {
            val index = musicSegments.indexOfFirst { combinedTimeForCurrentPlaybackMs() in it }
            if (index >= 0) {
              splitMusicSegment(index)
              return@setOnClickListener
            }
          }
          // Split/Delete now operate on the SELECTED LAYER's own segments
          // (at whichever one contains the current playhead) instead of
          // the video's own, whenever a layer is selected. Falls through
          // to the existing video-segment behavior below when no layer is
          // selected, completely unchanged.
          val layer = selectedLayerView
          if (layer != null) {
            val index = layerTimings[layer]?.segments?.indexOfFirst { combinedTimeForCurrentPlaybackMs() in it } ?: -1
            if (index >= 0) {
              splitLayerSegment(layer, index)
              return@setOnClickListener
            }
          }
          // Split/Delete now ALSO work on whichever MERGED clip is
          // currently active (yellow border, same clip the red delete-
          // whole-clip button targets) — per the user's explicit "why on
          // every click of scissors icon layer should cut in split
          // portion" report: this used to just silently seek back to the
          // primary clip and do nothing, which is exactly what looked
          // like "scissors isn't cutting."
          activeClipUri?.let { activeUri ->
            splitActiveMergedClipSegment(activeUri)
            return@setOnClickListener
          }
          val oldSegments = videoTrimView.segments
          if (videoTrimView.splitAtCurrentTime(player.currentPosition)) {
            root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            val newSegments = videoTrimView.segments
            pushUndo(
              undo = { videoTrimView.restoreSegments(oldSegments); videoSegments = oldSegments },
              redo = { videoTrimView.restoreSegments(newSegments); videoSegments = newSegments },
            )
          }
        }
      }
      val deleteSegmentButton = FrameLayout(this).apply {
        addView(
          EditorIconView(this@MediaEditorActivity, EditorIcon.DELETE).apply { iconTint = EditorDesignTokens.Colors.textPrimary },
          FrameLayout.LayoutParams(splitDeleteGlyphPx, splitDeleteGlyphPx, Gravity.CENTER),
        )
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
          if (blockIfSelectedLayerLocked()) return@setOnClickListener
          if (isVoiceRowSelected) {
            deleteVoiceOver()
            return@setOnClickListener
          }
          // Same music-row priority as Split above — targets whichever
          // segment was last TAPPED, falling back to "whichever contains
          // the playhead".
          if (selectedMusicSegmentIndex != null) {
            val tappedIndex = selectedMusicSegmentIndex?.takeIf { it in musicSegments.indices }
            val targetIndex = tappedIndex
              ?: musicSegments.indexOfFirst { combinedTimeForCurrentPlaybackMs() in it }.takeIf { it >= 0 }
            if (targetIndex != null) {
              deleteMusicSegment(targetIndex)
              return@setOnClickListener
            }
          }
          // Same routing as Split above, but targets whichever segment
          // the user last TAPPED in the layer-tracks row
          // (selectedLayerSegmentIndex), not necessarily the one under
          // the current playhead. Falls back to "whichever segment
          // contains the playhead" if selection came from somewhere else
          // (e.g. a canvas tap) rather than the row itself.
          val layer = selectedLayerView
          if (layer != null) {
            val timing = layerTimings[layer]
            if (timing != null) {
              val tappedIndex = selectedLayerSegmentIndex?.takeIf { it in timing.segments.indices }
              val targetIndex = tappedIndex
                ?: timing.segments.indexOfFirst { combinedTimeForCurrentPlaybackMs() in it }.takeIf { it >= 0 }
              if (targetIndex != null) {
                deleteLayerSegment(layer, targetIndex)
                return@setOnClickListener
              }
            }
          }
          // Same extension as Split above — Delete now ALSO works on
          // whichever MERGED clip is currently active, targeting
          // whichever of ITS OWN segments was last tapped
          // (selectedMergedClipSegmentIndex), falling back to "whichever
          // segment contains the playhead" exactly like the layer path
          // above.
          activeClipUri?.let { activeUri ->
            deleteActiveMergedClipSegment(activeUri)
            return@setOnClickListener
          }
          val position = player.currentPosition
          // Same "tapped portion wins over playhead position" preference
          // as the layer path above, now extended to the video's own
          // segments too, not just layers.
          val oldSegments = videoTrimView.segments
          val didDelete = videoTrimView.selectedSegmentIndex?.let { videoTrimView.deleteSegment(it) }
            ?: videoTrimView.deleteSegment(position)
          if (didDelete) {
            root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            val newSegments = videoTrimView.segments
            pushUndo(
              undo = { videoTrimView.restoreSegments(oldSegments); videoSegments = oldSegments },
              redo = { videoTrimView.restoreSegments(newSegments); videoSegments = newSegments },
            )
            // Jump playback to whatever segment now occupies this
            // position — matches the timelineRunnable's own gap-skip
            // logic, avoiding a visible freeze on the just-deleted frame.
            // When the playhead was inside (or past) the segment that just
            // got deleted AND it was the trailing-most one, there IS no
            // later segment to jump forward to — per the user's explicit
            // "it should stay at the same time where I deleted, not reset
            // to the start" report, that case now lands near the END of
            // whatever remains instead of falling all the way back to the
            // very first segment's start (which looked like the whole
            // video had reset to 0).
            //
            // "Near" the end, not exactly AT it: VideoTrimView's
            // minTrimDurationMs (2000L, private — kept here as a literal
            // with this note, matching this file's existing cross-file-
            // constant convention) requires BOTH halves of any split to be
            // >= that long, so landing precisely on the trailing edge
            // dropped the playhead into a permanently unsplittable dead
            // zone — every next scissors tap silently failed (segment too
            // short on the right) until the user manually scrubbed away
            // first, per the user's explicit "once I delete, I can't split
            // this same video again" report. Backing off by
            // minTrimDurationMs keeps the playhead at the closest position
            // that's still always immediately re-splittable, when the
            // remaining segment is long enough to have one; otherwise (a
            // remaining segment under 2x that, 4s) there's no valid split
            // point anywhere in it regardless of where the playhead lands,
            // so it simply clamps to the segment start.
            val matchingMinTrimDurationMs = 2000L
            val target = videoSegments.firstOrNull { it.first >= position }?.first
              ?: videoSegments.lastOrNull()?.let { (it.last - matchingMinTrimDurationMs).coerceAtLeast(it.first) }
              ?: 0L
            player.seekTo(target)
          }
        }
      }
      splitSegmentButtonRef = splitSegmentButton
      deleteSegmentButtonRef = deleteSegmentButton
      root.addView(
        deleteSegmentButton,
        FrameLayout.LayoutParams(splitDeleteButtonSizePx, splitDeleteButtonSizePx, Gravity.BOTTOM or Gravity.END)
          .apply {
            bottomMargin = layerTracksFixedBottomMarginPx
            rightMargin = sideMarginPx
          },
      )
      root.addView(
        splitSegmentButton,
        FrameLayout.LayoutParams(splitDeleteButtonSizePx, splitDeleteButtonSizePx, Gravity.BOTTOM or Gravity.END)
          .apply {
            bottomMargin = layerTracksFixedBottomMarginPx
            rightMargin = sideMarginPx + splitDeleteButtonSizePx + splitDeleteButtonGapPx
          },
      )
      // Video redesign: what Split/Delete will act on ("Clip 2", "Text"…).
      val videoSelectionLabel = TextView(this).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setTextColor(EditorDesignTokens.Colors.selectedToolTint)
        gravity = Gravity.CENTER_VERTICAL
        visibility = View.INVISIBLE
      }
      videoSelectionLabelRef = videoSelectionLabel
      root.addView(
        videoSelectionLabel,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, splitDeleteButtonSizePx, Gravity.BOTTOM or Gravity.END)
          .apply {
            bottomMargin = layerTracksFixedBottomMarginPx
            rightMargin = sideMarginPx + 2 * splitDeleteButtonSizePx + splitDeleteButtonGapPx + (4f * resources.displayMetrics.density).toInt()
          },
      )
      updateVideoSelectionLabel()
      // setUpEditingControls already ran updateImageEditorUI, but before any
      // of the transport views above existed — re-run it so story mode hides
      // play/pause, the filmstrip, split/delete and every layer track row.
      if (isStoryMode) updateImageEditorUI()

      // media3 has no built-in periodic-position callback absent the default
      // controller UI (which we've disabled) — poll currentPosition on a
      // Handler instead, the standard pattern for a custom transport UI.
      val timelineHandler = Handler(Looper.getMainLooper())
      val timelineRunnable = object : Runnable {
        override fun run() {
          // Preview stopped while exporting — nothing to follow.
          if (previewStoppedForExport) {
            timelineHandler.postDelayed(this, TIMELINE_POLL_INTERVAL_MS)
            return
          }
          // Per-part speed: follow whichever part is playing now.
          applyPreviewSpeed()
          // Configure the primary clip's OWN duration/segments/widths
          // FIRST, before anything below reads them — this must run
          // before the auto-scroll/highlight block, not after, or the
          // very first tick where player.duration becomes known would
          // compute a scroll/highlight position against a still-empty
          // videoSegments (durationMs == 0L), landing on the filmstrip's
          // own placeholder pre-layout width instead of its real one.
          if (player.duration > 0 && player.currentMediaItemIndex == 0 && videoTrimView.durationMs == 0L) {
            videoTrimView.configureFullRange(player.duration)
            videoSegments = listOf(0L..player.duration)
            correctFallbackLayerTimings(player.duration)
            updateFilmstripLayout()
          }
          // Instagram-style scrollable timeline: keep the active-clip
          // highlight (and, unless the user's own finger is actively
          // dragging it, the scroll position itself) in sync with ACTUAL
          // playback — regardless of whether the primary or a merged
          // clip is currently playing, and continuing seamlessly across
          // REPEAT_MODE_ALL's own loop-back-to-start.
          if (player.duration > 0) {
            updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer = false)
            // isFilmstripFingerDown (not just isUserScrubbingFilmstrip) —
            // see that flag's own doc: the settle-check can flip
            // isUserScrubbingFilmstrip back to false mid-drag during a
            // brief in-gesture pause, which used to let this same block
            // yank the scroll back to the player's position while the
            // finger was still physically down. filmstripSeekCooldownUntilMs
            // (see its own doc) covers the SEPARATE case right after the
            // scroll settles: the settle-check's own seekCombinedTimeline
            // call is asynchronous, so without this cooldown this block
            // could read the player's stale pre-seek position for a few
            // ticks and yank the scroll right back to where the user
            // scrolled FROM.
            val cooldownRemainingMs = filmstripSeekCooldownUntilMs - android.os.SystemClock.elapsedRealtime()
            if (!isUserScrubbingFilmstrip && !isFilmstripFingerDown && cooldownRemainingMs <= 0) {
              val currentCombinedMs = combinedTimeForCurrentPlaybackMs()
              val targetScrollX = scrollXForCombinedTimeMs(currentCombinedMs)
              filmstripScrollViewRef?.scrollTo(targetScrollX, 0)
              if (videoMiniScrubRowRef?.visibility == View.VISIBLE && !isDraggingVideoMiniSeekBar) {
                syncVideoMiniScrubber(currentCombinedMs)
              }
            }
            updateMusicPlaybackWindow()
          }
          // Only the PRIMARY clip's own timeline (playlist index 0)
          // drives the layer-visibility and gap-skip logic below —
          // merged clips (additionalVideoClipUris) always play in full,
          // in order, once reached; ExoPlayer's own playlist advancing +
          // REPEAT_MODE_ALL (set above) handle moving between them and
          // looping the whole queue with no help needed here.
          if (player.duration > 0 && player.currentMediaItemIndex == 0) {
            // Skip past any deleted gap (before the first segment,
            // between two kept segments, or after the last) — preview
            // should play back exactly what will be exported, not run
            // through content that's been cut. Gated on isVideoPlaying
            // (the user's INTENDED state), not player.isPlaying — see
            // that flag's own doc for why. An empty videoSegments means
            // "not yet configured", so this stays inert until a real
            // range is known.
            val position = player.currentPosition
            val currentIndex = videoSegments.indexOfLast { it.first <= position }
            if (isVideoPlaying && videoSegments.isNotEmpty()) {
              if (currentIndex < 0) {
                player.seekTo(videoSegments[0].first)
                player.play()
              } else if (position >= videoSegments[currentIndex].last) {
                val nextIndex = currentIndex + 1
                if (nextIndex < videoSegments.size) {
                  player.seekTo(videoSegments[nextIndex].first)
                  player.play()
                } else if (player.hasNextMediaItem()) {
                  // More clips queued after this one — hand off instead
                  // of looping back to THIS clip's own start, per the
                  // user's explicit "played in queue, same like
                  // Instagram" request.
                  player.seekToNextMediaItem()
                  player.play()
                } else {
                  // Single-clip loop-back-to-start — per the user's
                  // explicit "as video start playing in loop again then
                  // the music should be reset and start again" request,
                  // the music must restart here too, not keep running
                  // toward its own natural end.
                  player.seekTo(videoSegments[0].first)
                  player.play()
                  resetMusicToLoopStart()
                }
              }
            }
            updateLayerTimeVisibility()
            updateTransitionPreview()
            if (audioFadeIn || audioFadeOut || voiceOverPath != null) {
              val now = combinedTimeForCurrentPlaybackMs()
              // Only when it changed — each set is a message to the
              // playback thread, and this runs every 16 ms.
              val videoVolume = if (voiceRecorder != null) 0f else effectivePlayerVolume()
              exoPlayer?.let { if (kotlin.math.abs(it.volume - videoVolume) > 0.005f) it.volume = videoVolume }
              val musicLevel = musicVolume * musicFadeFactor(now) * voiceDuckFactor(now)
              musicPlayer?.let { if (kotlin.math.abs(it.volume - musicLevel) > 0.005f) it.volume = musicLevel }
            }
            updateVoicePlaybackWindow()
          }
          timelineHandler.postDelayed(this, TIMELINE_POLL_INTERVAL_MS)
        }
      }
      timelineHandler.post(timelineRunnable)
      timelinePollCleanup = { timelineHandler.removeCallbacks(timelineRunnable) }

      // Filter thumbnails need a still frame (unlike image's already-
      // decoded bitmap) — grabbed once, off the main thread, via
      // MediaMetadataRetriever, then reuses the exact same
      // renderFilterThumbnails(Bitmap) already built for images, so video's
      // filter row shows real live-rendered previews too, not a generic
      // icon, per the user's "same UI as the image editor" request.
      Thread {
        val retriever = android.media.MediaMetadataRetriever()
        val frameBitmap = runCatching {
          retriever.setDataSource(this, MediaMetadataReader.normalizedUri(mediaUri))
          retriever.scaledFrameAt(0, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC, PREVIEW_FRAME_MAX_SIDE)
        }.getOrNull()
        retriever.release()
        if (frameBitmap != null) {
          runOnUiThread {
            videoPosterFrame = frameBitmap
            renderFilterThumbnails(frameBitmap)
          }
        }
      }.start()
    }

    val exportLoadingIndicator = ProgressBar(this).apply { visibility = View.GONE }
    exportLoadingIndicatorRef = exportLoadingIndicator
    root.addView(
      exportLoadingIndicator,
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER,
      ),
    )

    setContentView(root)
  }

  override fun onBackPressed() {
    if (addLayerSheetRef != null) {
      dismissAddLayerSheet()
      return
    }
    finishCancelled()
  }

  // ExoPlayer keeps playing in the background, so the chosen music (and
  // the video preview) are paused whenever the editor leaves the screen —
  // app minimised or the editor finishing — and resumed only if they were
  // playing and the editor comes back (the play/pause icons stay right).
  private var resumeVideoOnForeground = false
  private var resumeMusicOnForeground = false

  override fun onPause() {
    super.onPause()
    // playWhenReady (intent): isPlaying is false while buffering, e.g.
    // right at a story loop restart, which then never resumed.
    resumeVideoOnForeground = !isFinishing && exoPlayer?.playWhenReady == true
    resumeMusicOnForeground = !isFinishing && musicPlayer?.playWhenReady == true
    exoPlayer?.pause()
    musicPlayer?.pause()
    updateStoryMusicBadge()
  }

  override fun onResume() {
    super.onResume()
    if (resumeVideoOnForeground) exoPlayer?.play()
    if (resumeMusicOnForeground) musicPlayer?.play()
    resumeVideoOnForeground = false
    resumeMusicOnForeground = false
    updateStoryMusicBadge()
  }

  override fun onDestroy() {
    super.onDestroy()
    voiceRecordHandler.removeCallbacksAndMessages(null)
    voiceRecorder?.let { runCatching { it.stop() }; it.release() }
    voiceRecorder = null
    voicePlayer?.release()
    voicePlayer = null
    // The export is finished (or abandoned) by now — drop our temp inputs.
    val files = tempFilesToDelete.toList()
    tempFilesToDelete.clear()
    Thread { files.forEach { runCatching { it.delete() } } }.start()
    // Closing mid-export: stop the Transformer and its progress poll too.
    stopExportProgressPolling()
    activeTransformer?.cancel()
    activeTransformer = null
    blurCoverTicking = false
    timelinePollCleanup?.invoke()
    timelinePollCleanup = null
    exoPlayer?.release()
    exoPlayer = null
    musicPlayer?.release()
    musicPlayer = null
  }

  // MARK: Image editor controls (Milestone 5 UI polish) — top icon row
  // (cancel/undo/redo/done) + bottom tab bar (Tools/Text/Sticker),
  // mirroring MediaEditorViewController's setUpImageEditingControls on iOS.
  // Icons are hand-drawn via EditorIconView (see that file's doc for why,
  // vs. vector-drawable XML or Unicode/emoji glyphs). Reads its visual
  // tokens (colors/spacing/sizing) from EditorDesignTokens.

  /** [imageViewForPreview] is non-null for an image session (used to
   *  refresh the live filter/adjustment preview via refreshPreview) and
   *  null for video, whose live filter/adjustment preview goes through the
   *  GL effects pipeline instead (see combinedColorMatrix's use in
   *  onCreate's video branch). That pipeline reads the adjustment fields
   *  fresh on every frame it actually RENDERS — true only while playing;
   *  when paused, refreshLivePreview force-reseeks to the current position
   *  to push a fresh frame through the pipeline instead (see its own body)
   *  — a genuine no-op ONLY turned out to be wrong (see the user's
   *  "changes should show at runtime, not only after Done + pressing
   *  play" report). Sharpen stays a genuine video no-op (not expressible
   *  as a ColorMatrix term). Originally image-only; unified onto video too
   *  per the user's explicit "same UI as the image editor" request —
   *  video's own former standalone button layout is gone (see onCreate's
   *  video branch). */
  private fun setUpEditingControls(imageViewForPreview: ImageView?): ImageCanvasChrome {
    val isImage = imageViewForPreview != null
    fun refreshLivePreview() {
      if (imageViewForPreview != null) {
        refreshPreview(imageViewForPreview)
        return
      }
      // Video's own GL effects pipeline (PhotoFilterRgbMatrix) reads
      // combinedColorMatrix() fresh on every frame it renders. A plain
      // seekTo(currentPosition) (this function's prior fix, gated to only
      // run while paused) was NOT reliable — per the user's explicit
      // "still not applying immediately as I'm selecting" follow-up
      // report, for BOTH filters and adjustments. ExoPlayer can treat a
      // seek to the position it's already at as a no-op and skip
      // reprocessing the frame, and apparently the effects pipeline isn't
      // always picked up promptly while genuinely playing either.
      // Nudging forward by a millisecond then back forces two REAL seeks,
      // guaranteeing the frame actually gets reprocessed with the latest
      // values — unconditionally, whether paused or playing, since gating
      // this on play state was itself part of what wasn't working.
      val player = exoPlayer ?: return
      val currentPositionMs = player.currentPosition
      val durationMs = player.duration
      val nudgedPositionMs = if (durationMs > 0) (currentPositionMs + 1).coerceAtMost(durationMs) else currentPositionMs + 1
      player.seekTo(nudgedPositionMs)
      player.seekTo(currentPositionMs)
    }
    val density = resources.displayMetrics.density
    val iconButtonSize = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.minTapTarget, density)
    val topBarHeightPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.topBarHeight, density)
    val topBarPaddingPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.topBarHorizontalPadding, density)
    // Kept intentionally small — user's explicit "make the cropper very
    // close to left/right of screen" request (was 20dp, still non-zero so
    // the border/handles never touch the physical screen edge).
    val horizontalMarginPx = (4f * density).toInt()
    val panelCollapsedHeightPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.panelCollapsedHeight, density)
    // Much shorter than the standard collapsed height — Effect's content
    // (a filter row) and Edit's (the adjust icon row / single-slider swap)
    // are both far more compact than Sticker/Draw/Music's content, and
    // using the standard height for those would leave a large dead empty
    // area below their actual content. (Video's play/pause + trim scrubber
    // row is hidden whenever any panel is open — see updateImageEditorUI —
    // so these no longer need extra height to dodge it, unlike an earlier
    // version of this fix.)
    val effectPanelHeightPx = EditorDesignTokens.dpToPx(currentEffectPanelHeightDp(), density)
    val editPanelHeightPx = EditorDesignTokens.dpToPx(104f, density)

    // Story mode: X / Undo / Redo / Share float straight over the story,
    // with no background strip behind them.
    val topBar = FrameLayout(this).apply {
      setBackgroundColor(if (isStoryMode) Color.TRANSPARENT else EditorDesignTokens.Colors.chromeBackground)
    }
    topBarRef = topBar
    root.addView(
      topBar,
      // topMargin = statusBarHeightPx: without it, Cancel/Undo/Redo/Done
      // rendered starting at the true top of the screen (y=0) — this
      // window draws edge-to-edge unconditionally now that targetSdk is
      // 36 (Android no longer auto-reserves the status-bar area for
      // apps that don't opt into edge-to-edge), so the real system
      // status bar's icons visually collided with them. See
      // statusBarHeightPx's own doc.
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, topBarHeightPx, Gravity.TOP)
        .apply { topMargin = statusBarHeightPx + storyTopGapPx },
    )

    // Cancel/Done are plain text labels (not icons) — matches the video
    // editor's own top bar, which has always used plain text "Cancel"/
    // "Done" Buttons, and per the user's explicit request to simplify
    // these away from the hand-drawn icon set. Undo/Redo stay as icons —
    // not part of that request, and there's no short standard word for
    // either that reads as cleanly as an arrow glyph.
    // Redesign: ✕ icon (was the text "Cancel") and a blue "Done" pill.
    val cancelButton = makeTopBarIconButton(EditorIcon.CLOSE) { finishCancelled() }.apply { contentDescription = "Cancel" }
    // Story mode floats these straight over the media (no top-bar strip),
    // so they get a drop shadow to stay readable over bright photos.
    val undoButton = makeTopBarIconButton(EditorIcon.UNDO, dropShadow = isStoryMode) { performUndo() }
    val redoButton = makeTopBarIconButton(EditorIcon.REDO, dropShadow = isStoryMode) { performRedo() }
    // Video editor: "Export" top right (no LOOKS · TOOLS · EXPORT bar there).
    val doneButtonLabel = if (isStoryMode) "Share" else if (isImage) "Done" else "Export"
    val doneButton = makeTopBarTextButton(doneButtonLabel, primary = true) { finishSuccess() }.apply {
      // Pill drawn 36dp tall inside the 44dp tap target.
      val inset = (4f * density).toInt()
      background = android.graphics.drawable.InsetDrawable(
        GradientDrawable().apply {
          cornerRadius = 100f * density
          setColor(EditorDesignTokens.Colors.accent)
        },
        0, inset, 0, inset,
      )
      setPadding((16f * density).toInt(), 0, (16f * density).toInt(), 0)
      (this as? TextView)?.textSize = 15f
    }
    if (isStoryMode) {
      // Same shadow as the story rail labels — see undoButton above.
      (doneButton as TextView).setShadowLayer(4f, 0f, 1f, Color.argb(160, 0, 0, 0))
    }
    // Video editor: Export is an icon (accent circle), not a text pill.
    val videoExportButton: View? = if (!isImage && !isStoryMode) {
      FrameLayout(this).apply {
        val inset = (4f * density).toInt()
        background = android.graphics.drawable.InsetDrawable(
          GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(EditorDesignTokens.Colors.accent)
          },
          inset, inset, inset, inset,
        )
        addView(
          EditorIconView(this@MediaEditorActivity, EditorIcon.EXPORT).apply { iconTint = Color.WHITE },
          FrameLayout.LayoutParams((20f * density).toInt(), (20f * density).toInt(), Gravity.CENTER),
        )
        contentDescription = "Export"
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          finishSuccess()
        }
      }
    } else null
    doneButtonRef = videoExportButton ?: doneButton
    // Needed by both chrome branches below (panel positioning further down
    // this function also reads it), so it's computed once regardless of
    // which chrome gets built.
    // Tool rail + (outside story mode) the LOOKS · TOOLS · EXPORT bar under it.
    // Photo editor only — the video editor dropped the bar (it took too
    // much height): Export is top right, Filters/Tune are on the tool rail.
    val lookToolsBarHeightPx = if (isStoryMode || !isImage) 0 else EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.lookToolsBarHeight, density)
    val bottomTabBarHeightPx = EditorDesignTokens.dpToPx(trayHeightDp(), density) + lookToolsBarHeightPx

    if (isStoryMode) {
      // Story-mode chrome: X close top-left, Undo/Redo + a "Share" button
      // tucked top-right (opposite the close button), a right-edge
      // vertical icon rail (Text/Stickers/Filters/Overlay[image-only]/
      // Draw/Audio/Download), and a "now playing" music badge — replaces
      // the Cancel/Undo/Redo/Done top bar + horizontal tab tray below.
      // Every icon calls the exact same engine methods/panels the regular
      // chrome uses further down in this function (panels are still built
      // unconditionally below, regardless of which chrome is active) —
      // only the chrome differs.
      // X / Undo / Redo / Share sit 15dp higher in story mode — per the
      // user's explicit Android-only "move them up by 15px" request. A pure
      // visual offset (like the rail's translationY below) so nothing laid
      // out relative to topBar moves with it.
      topBar.translationY = -(15f * density)
      val closeButton = makeTopBarIconButton(EditorIcon.CLOSE, dropShadow = true) { finishCancelled() }
      topBar.addView(
        closeButton,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL or Gravity.START)
          .apply { leftMargin = topBarPaddingPx },
      )
      // Share now lives in this same top-right row, outermost (closest to
      // the screen edge) — per the user's explicit "keep Share button on
      // right top, opposite to cross sign" request. doneButton is the
      // SAME shared button/click-target the regular (non-story) top bar
      // already uses at this exact Gravity.END position (see the `else`
      // branch below) — no separate bottom-tray container needed anymore.
      // Undo/Redo sit exactly centered in the bar, between X and Share.
      val storyUndoRedoRow = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(undoButton, LinearLayout.LayoutParams(iconButtonSize, iconButtonSize).apply {
          marginEnd = (4f * density).toInt()
        })
        addView(redoButton, LinearLayout.LayoutParams(iconButtonSize, iconButtonSize))
      }
      topBar.addView(
        storyUndoRedoRow,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER),
      )
      topBar.addView(
        doneButton,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL or Gravity.END)
          .apply { rightMargin = topBarPaddingPx },
      )

      // One circular dark icon button + a label to its left, matching the
      // Instagram-style reference screenshot. Floats over the canvas as an
      // absolute overlay on `root` (see below) rather than consuming
      // reserved chrome space like the bottom tray it replaces.
      fun storyRailButton(
        icon: EditorIcon,
        label: String,
        // Lets a caller (the Mute row) keep a reference to the created
        // EditorIconView so it can flip `.icon` in place later (mirrors
        // the video transport's own PLAY/PAUSE in-place swap) — every
        // other row ignores this, its icon never needs to change after
        // creation.
        onIconViewCreated: (EditorIconView) -> Unit = {},
        onClick: () -> Unit,
      ): View {
        val circleSizePx = EditorDesignTokens.dpToPx(40f, density)
        val glyphPx = EditorDesignTokens.dpToPx(20f, density)
        val iconView = EditorIconView(this, icon).apply { iconTint = Color.WHITE }
        onIconViewCreated(iconView)
        val circle = FrameLayout(this).apply {
          background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.argb(140, 0, 0, 0))
          }
          addView(iconView, FrameLayout.LayoutParams(glyphPx, glyphPx, Gravity.CENTER))
        }
        val labelView = TextView(this).apply {
          text = label
          setTextColor(Color.WHITE)
          // A little smaller than the shared trayLabel (11sp) — per the
          // user's explicit "keep text on the left, but a little smaller".
          textSize = STORY_RAIL_LABEL_SP
          gravity = Gravity.CENTER_VERTICAL
          isSingleLine = true
          setShadowLayer(4f, 0f, 1f, Color.argb(160, 0, 0, 0))
        }
        return LinearLayout(this).apply {
          orientation = LinearLayout.HORIZONTAL
          gravity = Gravity.CENTER_VERTICAL
          addView(
            labelView,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
              marginEnd = (8f * density).toInt()
            },
          )
          addView(circle, LinearLayout.LayoutParams(circleSizePx, circleSizePx))
          setOnClickListener {
            pauseVideoForToolInteraction()
            onClick()
          }
        }
      }

      val railButtons = mutableListOf(
        storyRailButton(EditorIcon.TOOL_TEXT, "Text") { presentTextEntryOverlay() },
        storyRailButton(EditorIcon.TOOL_STICKER, "Stickers") {
          selectedImageEditorTab = ImageEditorTab.STICKERS
          updateImageEditorUI(animated = true)
        },
        storyRailButton(EditorIcon.TOOL_FILTERS, "Filters") {
          selectedImageEditorTab = ImageEditorTab.EFFECT
          updateImageEditorUI(animated = true)
        },
        // Adjust (brightness, contrast, …) — the same Tune tool as the editor.
        storyRailButton(EditorIcon.TOOL_ADJUST, "Adjust") {
          selectedImageEditorTab = ImageEditorTab.EDIT
          updateImageEditorUI(animated = true)
        },
      )
      // Overlay is image-only — same engine limitation the regular tray
      // already respects (see its own "remove overlay from video" doc
      // further down): it never baked into exported video.
      if (isImage) {
        railButtons.add(storyRailButton(EditorIcon.TOOL_OVERLAY, "Overlay") { presentImageOverlayPicker() })
      }
      railButtons.add(
        storyRailButton(EditorIcon.TOOL_DRAW, "Draw") {
          selectedImageEditorTab = ImageEditorTab.DRAW
          updateImageEditorUI(animated = true)
        },
      )
      // Video only — a still image has no original audio track to mute.
      // Toggles the SAME originalAudioVolume state the regular (non-story)
      // editor's own volume slider already drives (unreachable in story
      // mode, since the rail skips straight to the picker) — not a revival
      // of a removed dedicated mute button (see originalAudioVolumeRow's
      // own "remove Mute Audio button" doc above), just a quick toggle for
      // a chrome that never exposes that slider. Per the user's explicit
      // "mute/unmute original video audio inside the story editor" request.
      if (!isImage) {
        railButtons.add(
          storyRailButton(
            EditorIcon.VOLUME,
            "Mute",
            onIconViewCreated = { storyMuteIconRef = it },
          ) { toggleStoryOriginalAudioMute() },
        )
      }
      // Intentionally unconditional (not `if (!isImage)`) for both image
      // and video — a photo's selected track now gets mixed into an
      // exported video by exportImageWithMusic (see finishSuccess), so
      // don't re-gate this to video-only.
      railButtons.add(storyRailButton(EditorIcon.TOOL_MUSIC, "Audio") { presentStoryMusicPicker() })
      railButtons.add(storyRailButton(EditorIcon.DOWNLOAD, "Download") { performDownloadToGallery() })
      railButtons.add(storyRailButton(EditorIcon.LOCATION, "Location") { presentLocationPicker() })
      // "Tags" (link / hashtag / time / date stickers) removed from the
      // story rail (user request).

      // 10 tools now (Adjust + Tags added) — tighter so the rail clears the
      // top bar's Share button on shorter screens.
      val railSpacingPx = (10f * density).toInt()
      val rail = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        // Right-aligned rows: labels differ in width, so left-aligned rows
        // left the circles staggered instead of in one vertical line.
        gravity = Gravity.END
        railButtons.forEachIndexed { index, button ->
          addView(
            button,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
              if (index > 0) topMargin = railSpacingPx
            },
          )
        }
      }
      storyRailRef = rail
      root.addView(
        rail,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL or Gravity.END)
          .apply { rightMargin = topBarPaddingPx },
      )
      // Shifted up from dead-center per the user's explicit "move the
      // right-hand icon rail a little more upside" request — translationY
      // (not a margin tweak) so it's a pure visual offset independent of
      // FrameLayout's own margin-vs-gravity inset math.
      rail.translationY = -(30f * density)

      // "Now playing" badge — top-center, below topBar (which stays a
      // solid chromeBackground strip even in story mode, see its own
      // setup above), over the canvas. Same dark-translucent-pill styling
      // as the rail's own circle buttons (Color.argb(140,0,0,0)). Hidden
      // by default; shown/updated by updateStoryMusicBadge(), called from
      // selectMusicTrack() on every selection change (pick AND clear).
      val storyMusicBadgePlayPauseIcon = EditorIconView(this, EditorIcon.PLAY).apply {
        iconTint = Color.WHITE
      }
      storyMusicBadgePlayPauseIconRef = storyMusicBadgePlayPauseIcon
      val storyMusicBadgeTitle = TextView(this).apply {
        setTextColor(Color.WHITE)
        textSize = 13f
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        // Long track names can't push the badge into the right-edge rail
        // or off-screen — the rail itself is vertically centered (see its
        // own Gravity.CENTER_VERTICAL/END placement above) so this top-
        // anchored badge mainly needs to stay clear of the screen edges.
        maxWidth = (resources.displayMetrics.widthPixels * 0.5f).toInt()
      }
      storyMusicBadgeTitleRef = storyMusicBadgeTitle
      val storyMusicBadgeCloseIcon = EditorIconView(this, EditorIcon.CLOSE).apply {
        iconTint = Color.WHITE
      }
      val storyMusicBadgeCloseButton = FrameLayout(this).apply {
        addView(storyMusicBadgeCloseIcon, FrameLayout.LayoutParams((16f * density).toInt(), (16f * density).toInt(), Gravity.CENTER))
        // Own click target (not just the badge body's) so removing the
        // track doesn't also toggle playback via the badge's own listener.
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
          selectMusicTrack(null)
        }
      }
      val storyMusicBadge = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        visibility = View.GONE
        background = GradientDrawable().apply {
          cornerRadius = (18f * density)
          setColor(Color.argb(140, 0, 0, 0))
        }
        setPadding((12f * density).toInt(), (6f * density).toInt(), (8f * density).toInt(), (6f * density).toInt())
        addView(storyMusicBadgePlayPauseIcon, LinearLayout.LayoutParams((18f * density).toInt(), (18f * density).toInt()).apply {
          marginEnd = (6f * density).toInt()
        })
        addView(
          storyMusicBadgeTitle,
          LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            marginEnd = (6f * density).toInt()
          },
        )
        addView(storyMusicBadgeCloseButton, LinearLayout.LayoutParams((28f * density).toInt(), (28f * density).toInt()))
        // Tapping the badge body (anywhere except the close icon, which
        // has its own listener above and consumes the touch first) toggles
        // playback of the preview player — direct musicPlayer control
        // rather than reusing the regular panel's playPauseButtonRef-
        // proxying toggle (musicPlayPauseButton, above), since that relies
        // on a main video transport that doesn't exist for a photo story.
        setOnClickListener { toggleStoryMusicPlayback() }
      }
      storyMusicBadgeRef = storyMusicBadge
      root.addView(
        storyMusicBadge,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL)
          .apply { topMargin = statusBarHeightPx + storyTopGapPx + topBarHeightPx + (12f * density).toInt() },
      )
      updateStoryMusicBadge()
      // No bottom tray in story mode anymore — doneButton moved into
      // storyUndoRedoRow above, and bottomTabBarHeightPx is unused on this
      // branch. bottomTrayRef stays null here (its z-order bringToFront()
      // call is a safe no-op on null); topBar itself already gets brought
      // to front elsewhere, which is what now carries the Share button.
    } else {
      topBar.addView(
        cancelButton,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL or Gravity.START)
          .apply { leftMargin = topBarPaddingPx },
      )
      // No Done here any more — EXPORT (bottom bar) saves. Compare (photo
      // and video) takes its place at the top right.
      // Video: Export takes the top-right spot; compare moves to the
      // play/split/delete row, left of "+" (see videoCompareButtonRef).
      topBar.addView(
        if (isImage) makeCompareButton() else (videoExportButton ?: doneButton),
        FrameLayout.LayoutParams(iconButtonSize, iconButtonSize, Gravity.CENTER_VERTICAL or Gravity.END)
          .apply { rightMargin = topBarPaddingPx },
      )

      val undoRedoRow = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(undoButton, LinearLayout.LayoutParams(iconButtonSize, iconButtonSize).apply {
          marginEnd = (4f * density).toInt()
        })
        addView(redoButton, LinearLayout.LayoutParams(iconButtonSize, iconButtonSize).apply {
          marginStart = (4f * density).toInt()
        })
      }
      topBar.addView(
        undoRedoRow,
        FrameLayout.LayoutParams(
          ViewGroup.LayoutParams.WRAP_CONTENT,
          ViewGroup.LayoutParams.WRAP_CONTENT,
          Gravity.CENTER,
        ),
      )

      val (toolsContainer, toolsIcon, toolsLabel, toolsIndicator) = makeTabButton(EditorIcon.TOOL_MOVE, "Tools", ImageEditorTab.TOOLS) {
        root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        selectedImageEditorTab = ImageEditorTab.TOOLS
        updateImageEditorUI(animated = true)
      }
      // Filters — left of Text, per the user's explicit tab-order request.
      // Was the always-visible filter row; now gated behind this tab.
      val (effectContainer, effectIcon, effectLabel, effectIndicator) = makeTabButton(EditorIcon.TOOL_FILTERS, "Filters", ImageEditorTab.EFFECT) {
        root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        selectedImageEditorTab = ImageEditorTab.EFFECT
        updateImageEditorUI(animated = true)
      }
      // Same rich on-canvas text-entry overlay (font/color/alignment toolbar
      // above the keyboard) for both media types — video previously had its
      // own simpler dialog (showAddTextDialog), now removed.
      val (textContainer, _, _, _) = makeTabButton(EditorIcon.TOOL_TEXT, "Text") { presentTextEntryOverlay() }
      // Adjustments (Brightness/Contrast/etc.) — right of Text, per the
      // user's explicit tab-order request. Was the always-visible adjust
      // icon row/single-slider swap; now gated behind this tab.
      val (editContainer, editIcon, editLabel, editIndicator) = makeTabButton(EditorIcon.TOOL_ADJUST, "Adjust", ImageEditorTab.EDIT) {
        root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        selectedImageEditorTab = ImageEditorTab.EDIT
        updateImageEditorUI(animated = true)
      }
      // Freehand draw/brush — 3rd stateful tab, reusing the exact same
      // SlideUpPanelView shell as Stickers (color row + brush-width slider
      // instead of a sticker grid). Selecting it deselects any active
      // text/sticker/overlay layer and hands ALL canvas touches to
      // drawingCanvasRef until the user switches away (see updateImageEditorUI).
      val (drawContainer, drawIcon, drawLabel, drawIndicator) = makeTabButton(EditorIcon.TOOL_DRAW, "Draw", ImageEditorTab.DRAW) {
        root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        selectedImageEditorTab = ImageEditorTab.DRAW
        updateImageEditorUI(animated = true)
      }
      // Same 40-emoji grid panel for both media types — video previously had
      // its own momentary list-dialog picker (showStickerPicker), now removed.
      val (stickerContainer, stickersIcon, stickersLabel, stickersIndicator) = makeTabButton(EditorIcon.TOOL_STICKER, "Sticker", ImageEditorTab.STICKERS) {
        root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        selectedImageEditorTab = ImageEditorTab.STICKERS
        updateImageEditorUI(animated = true)
      }
      // Momentary action, like Text/Sticker — opens the system photo picker
      // and adds the chosen photo as a new draggable/pinchable/rotatable
      // overlay layer, per the user's explicit request.
      val (overlayContainer, _, _, _) = makeTabButton(EditorIcon.TOOL_OVERLAY, "Overlay") { presentImageOverlayPicker() }
      // Video-only 6th tab — see the ImageEditorTab.MUSIC doc.
      val (musicContainer, musicIcon, musicLabel, musicIndicator) = makeTabButton(EditorIcon.TOOL_MUSIC, "Music", ImageEditorTab.MUSIC) {
        root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        selectedImageEditorTab = ImageEditorTab.MUSIC
        updateImageEditorUI(animated = true)
      }
      // Video-only, momentary action like Text/Overlay — opens a video
      // picker and appends the chosen clip after the current one, per the
      // user's explicit "add a new video and merge them" request. Takes
      // Overlay's old slot in the tray now that Overlay is video-excluded.
      val (addVideoContainer, _, _, _) = makeTabButton(EditorIcon.TOOL_ADD_VIDEO, "Clips") { presentVideoClipPicker() }
      // "Add Video" is the only two-word tray label — every other tab
      // container has no need for extra room since its label is a single
      // word — per the user's explicit "increase little more padding so it
      // will display nicely" report (after the single-line fix above
      // stopped the wrap-then-vertical-clip). Widened only for this one
      // container so the already-tuned tight spacing on every other tab is
      // unaffected.
      addVideoContainer.setPadding((6f * density).toInt(), 0, (6f * density).toInt(), 0)
      toolsTabIconRef = toolsIcon
      effectTabIconRef = effectIcon
      editTabIconRef = editIcon
      stickersTabIconRef = stickersIcon
      drawTabIconRef = drawIcon
      toolsTabLabelRef = toolsLabel
      effectTabLabelRef = effectLabel
      editTabLabelRef = editLabel
      stickersTabLabelRef = stickersLabel
      drawTabLabelRef = drawLabel
      toolsTabIndicatorRef = toolsIndicator
      effectTabIndicatorRef = effectIndicator
      editTabIndicatorRef = editIndicator
      stickersTabIndicatorRef = stickersIndicator
      drawTabIndicatorRef = drawIndicator
      if (!isImage) {
        musicTabIconRef = musicIcon
        musicTabLabelRef = musicLabel
        musicTabIndicatorRef = musicIndicator
      }

      // Free-scrolling tray: items size to their own content (not stretched
      // to fill the width) with a fixed gap between them, inside a
      // HorizontalScrollView so the tray can scroll if more tools are ever
      // added. Video gets a 6th item (Music) with no image equivalent.
      // isFillViewport + the inner LinearLayout's own `gravity = CENTER`
      // together give "centered when short, scrollable when long" for free:
      // fillViewport stretches the LinearLayout to at least the viewport's
      // width when its content is narrower, and gravity=CENTER then centers
      // its children within that stretched width.
      // Effect sits immediately left of Text, Edit immediately right of it —
      // per the user's explicit "major change" tab-order request.
      // "Tools" (pan/zoom/rotate) tab removed from the visible tray per the
      // user's explicit request — it was a no-op placeholder since pan/zoom/
      // rotate already work continuously on the canvas regardless of the
      // selected tab. `toolsContainer`/ImageEditorTab.TOOLS stay in code as
      // the internal "no other panel active" default/reset state (see
      // selectedImageEditorTab) — only its visible tab button is removed.
      val tabContainers = mutableListOf(
        effectContainer, textContainer, editContainer, drawContainer, stickerContainer,
      )
      // Overlay (image-over-image layer tool) is image-only, per the user's
      // explicit "remove overlay from video" request — it never baked into
      // exported video anyway (its drag/pinch/rotate worked live on video
      // as a side effect of the shared chrome, but export-baking was never
      // built for it).
      if (isImage) {
        tabContainers.add(overlayContainer)
      } else {
        tabContainers.add(musicContainer)
        tabContainers.add(addVideoContainer)
      }
      // Every tool fits across the screen in equal slots — no scrolling —
      // inside the floating glass capsule (12dp from the edges + 4dp).
      val bottomTabBar = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        val sidePx = (16f * density).toInt()
        setPadding(sidePx, 0, sidePx, 0)
        tabContainers.forEachIndexed { index, child ->
          addView(
            child,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
              if (index > 0) marginStart = (2f * density).toInt()
            },
          )
        }
      }
      // Floating frosted capsule + sliding lozenge (same as iOS pre-26).
      val glass = GlassCapsuleDrawable(density)
      toolGlassDrawableRef = glass
      val glassRow = ToolGlassRow(this, glass).apply {
        row = bottomTabBar
        slots = { tabContainers }
        onPick = { slot -> slot.performClick() }
        addView(bottomTabBar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
      }
      toolGlassRowRef = glassRow
      val bottomTrayScrollView = HorizontalScrollView(this).apply {
        isFillViewport = true
        isHorizontalScrollBarEnabled = false
        background = glass
        outlineProvider = glass.outlineProvider()
        // Native elevation shadow, cast using this background drawable's own
        // outline (rounded top corners) — Android's default ViewOutlineProvider
        // is BACKGROUND, so no extra outline setup is needed (item 3: reads
        // as a floating panel over the canvas instead of a flat strip flush
        // with the screen edge).
        elevation = EditorDesignTokens.dpToPx(8f, density).toFloat()
        addView(glassRow, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
      }
      bottomTrayRef = bottomTrayScrollView
      // Re-capture what's behind the glass whenever the screen redraws.
      root.viewTreeObserver.addOnPreDrawListener {
        scheduleToolGlassBackdrop()
        true
      }
      root.addView(
        bottomTrayScrollView,
        // bottomMargin = navigationBarHeightPx — same edge-to-edge fix as
        // topBar's topMargin above: without it, the tray's own icons sat
        // flush against the true bottom of the screen, mixing with the
        // system's own gesture pill / 3-button nav bar.
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, bottomTabBarHeightPx - lookToolsBarHeightPx, Gravity.BOTTOM)
          .apply { bottomMargin = navigationBarHeightPx + lookToolsBarHeightPx },
      )
      if (isImage) setUpLookToolsBar(lookToolsBarHeightPx)
    }

    // Circular thumbnails showing a live-rendered preview of the current
    // photo with each filter baked in (renderFilterThumbnails, called once
    // the photo finishes loading) rather than a generic icon — horizontally
    // scrollable via the same isFillViewport+gravity=CENTER pattern already
    // used for the bottom tray.
    val thumbnailSizePx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.thumbnailSize, density)
    val thumbnailGutterPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.thumbnailGutter, density)
    val filterRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
      // Artistic looks are photo only.
      PhotoFilter.values().filter { mediaType == "image" || it.category != FilterCategory.ARTISTIC }.forEachIndexed { index, filter ->
        val thumbnailView = ImageView(this@MediaEditorActivity).apply {
          scaleType = ImageView.ScaleType.CENTER_CROP
          setBackgroundColor(EditorDesignTokens.Colors.elevatedSurface)
        }
        val labelView = TextView(this@MediaEditorActivity).apply {
          text = filter.label
          setTextColor(EditorDesignTokens.Colors.textSecondary)
          textSize = EditorDesignTokens.TypeSizesSp.trayLabel
          gravity = Gravity.CENTER
        }
        val itemContainer = LinearLayout(this@MediaEditorActivity).apply {
          orientation = LinearLayout.VERTICAL
          gravity = Gravity.CENTER
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            val oldFilter = selectedFilter
            val oldStrength = filterStrength
            val oldSaturation = filterSaturation
            val oldSharpness = filterSharpness
            // Tapping the already-selected filter (it shows a pencil) opens its sliders.
            if (filter == oldFilter && filter != PhotoFilter.ORIGINAL) setFilterEditing(true)
            if (oldFilter != filter) {
              // A newly picked filter always starts at full strength, with
              // its own Saturation/Sharpness back at 0.
              fun pick(newFilter: PhotoFilter, strength: Float, saturation: Float, sharpness: Float) {
                selectedFilter = newFilter
                filterStrength = strength
                filterSaturation = saturation
                filterSharpness = sharpness
                refreshLivePreview()
                updateFilterButtonHighlight()
              }
              pick(filter, 1f, 0f, 0f)
              pushUndo(
                undo = { pick(oldFilter, oldStrength, oldSaturation, oldSharpness) },
                redo = { pick(filter, 1f, 0f, 0f) },
              )
            }
          }
          // Dark circle + pencil over the selected filter only.
          val editOverlay = FrameLayout(this@MediaEditorActivity).apply {
            background = GradientDrawable().apply {
              shape = GradientDrawable.OVAL
              setColor(Color.argb(115, 0, 0, 0))
            }
            visibility = View.GONE
            val iconSizePx = (22f * density).toInt()
            addView(
              EditorIconView(this@MediaEditorActivity, EditorIcon.EDIT).apply { iconTint = Color.WHITE },
              FrameLayout.LayoutParams(iconSizePx, iconSizePx, Gravity.CENTER),
            )
          }
          filterEditOverlayRefs[filter] = editOverlay
          val thumbnailFrame = FrameLayout(this@MediaEditorActivity).apply {
            addView(thumbnailView, FrameLayout.LayoutParams(thumbnailSizePx, thumbnailSizePx))
            addView(editOverlay, FrameLayout.LayoutParams(thumbnailSizePx, thumbnailSizePx))
          }
          addView(thumbnailFrame, LinearLayout.LayoutParams(thumbnailSizePx, thumbnailSizePx))
          addView(
            labelView,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
              topMargin = (4f * density).toInt()
            },
          )
        }
        filterButtonRefs[filter] = thumbnailView
        filterItemRefs[filter] = itemContainer
        addView(
          itemContainer,
          LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            if (index > 0) marginStart = thumbnailGutterPx
          },
        )
      }
    }
    val filterScrollView = HorizontalScrollView(this).apply {
      isFillViewport = true
      isHorizontalScrollBarEnabled = false
      addView(filterRow, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }
    filterScrollViewRef = filterScrollView
    val filterCategoryRow = makeFilterCategoryRow()
    filterCategoryRowRef = filterCategoryRow
    val filterScrollHeightPx = thumbnailSizePx + (4f * density).toInt() + (16f * density).toInt()

    // Adjust — Instagram's actual "Edit" model: an icon row, tap one to
    // swap in a single centered slider with a back arrow, rather than
    // showing all sliders stacked at once. 8 properties now (was 3), so
    // the icon row is horizontally scrollable, matching the filter row.
    val brightnessRow = makeAdjustmentRow("B") { brightness = it; refreshLivePreview() }
    val contrastRow = makeAdjustmentRow("C") { contrast = it; refreshLivePreview() }
    val saturationRow = makeAdjustmentRow("S") { saturation = it; refreshLivePreview() }
    val fadeRow = makeAdjustmentRow("Fade") { fade = it; refreshLivePreview() }
    val shadowRow = makeAdjustmentRow("Shadow") { shadow = it; refreshLivePreview() }
    // Vignette is its own overlay view (not part of refreshPreview), so the
    // Tune/filter stage snapshot must be redrawn too or the change only
    // showed after switching to another setting.
    val vignetteRow = makeAdjustmentRow("Vignette") { vignette = it; updateVignetteOverlay(); scheduleFilterStageRefresh() }
    val sharpenRow = makeAdjustmentRow("Sharpen") { sharpen = it; refreshLivePreview() }
    val warmthRow = makeAdjustmentRow("Warm") { warmth = it; refreshLivePreview() }
    val highlightsRow = makeAdjustmentRow("Highlights") { highlights = it; refreshLivePreview() }
    val tintRow = makeAdjustmentRow("Tint") { tint = it; refreshLivePreview() }
    val blurRow = makeBlurRow()
    val allAdjustRows = listOf(brightnessRow, contrastRow, saturationRow, fadeRow, shadowRow, vignetteRow, sharpenRow, warmthRow, highlightsRow, tintRow, blurRow)
    adjustSliderRowRefs[AdjustProperty.BRIGHTNESS] = brightnessRow
    adjustSliderRowRefs[AdjustProperty.CONTRAST] = contrastRow
    adjustSliderRowRefs[AdjustProperty.SATURATION] = saturationRow
    adjustSliderRowRefs[AdjustProperty.FADE] = fadeRow
    adjustSliderRowRefs[AdjustProperty.SHADOW] = shadowRow
    adjustSliderRowRefs[AdjustProperty.VIGNETTE] = vignetteRow
    adjustSliderRowRefs[AdjustProperty.SHARPEN] = sharpenRow
    adjustSliderRowRefs[AdjustProperty.WARMTH] = warmthRow
    adjustSliderRowRefs[AdjustProperty.HIGHLIGHTS] = highlightsRow
    adjustSliderRowRefs[AdjustProperty.TINT] = tintRow
    adjustSliderRowRefs[AdjustProperty.BLUR] = blurRow
    allAdjustRows.forEach { it.visibility = View.GONE }
    val adjustSlidersContainer = FrameLayout(this).apply {
      allAdjustRows.forEach { addView(it) }
    }

    // Icon + label per adjustment (was plain text labels only) — the
    // single biggest "looks dated" cue in the whole editor, per the
    // user's explicit "modernize the UI" request.
    fun makeAdjustIconButton(label: String, icon: EditorIcon, property: AdjustProperty): View {
      val iconSizePx = (16f * density).toInt()
      val iconView = EditorIconView(this, icon).apply {
        minimumWidth = iconSizePx
        minimumHeight = iconSizePx
        iconTint = EditorDesignTokens.Colors.textSecondary
      }
      val labelView = TextView(this).apply {
        text = label
        setTextColor(EditorDesignTokens.Colors.textSecondary)
        textSize = 12f
      }
      return LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        isClickable = true
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          didTapAdjustIcon(property)
        }
        addView(iconView, LinearLayout.LayoutParams(iconSizePx, iconSizePx))
        addView(
          labelView,
          LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            marginStart = (6f * density).toInt()
          },
        )
      }
    }
    val adjustIconOptions = listOf(
      Triple("Brightness", EditorIcon.SUN, AdjustProperty.BRIGHTNESS),
      Triple("Contrast", EditorIcon.CONTRAST_ICON, AdjustProperty.CONTRAST),
      Triple("Saturation", EditorIcon.DROPLET, AdjustProperty.SATURATION),
      Triple("Fade", EditorIcon.FADE, AdjustProperty.FADE),
      Triple("Shadow", EditorIcon.MOON, AdjustProperty.SHADOW),
      Triple("Vignette", EditorIcon.VIGNETTE, AdjustProperty.VIGNETTE),
      Triple("Sharpen", EditorIcon.TARGET, AdjustProperty.SHARPEN),
      Triple("Warm", EditorIcon.THERMOMETER, AdjustProperty.WARMTH),
      Triple("Highlights", EditorIcon.HIGHLIGHTER, AdjustProperty.HIGHLIGHTS),
      Triple("Tint", EditorIcon.PALETTE, AdjustProperty.TINT),
    ) + (
      // Photo only, like the rest of the canvas-geometry tools.
      if (isImage) listOf(Triple("Blur", EditorIcon.BLUR, AdjustProperty.BLUR)) else emptyList()
    ).let { options ->
      if (isImage) listOf(Triple("Auto", EditorIcon.WAND, AdjustProperty.AUTO)) + options else options
    }
    val adjustIconRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      adjustIconOptions.forEachIndexed { index, (label, icon, property) ->
        val button = makeAdjustIconButton(label, icon, property)
        if (property == AdjustProperty.AUTO) autoEnhanceButtonRef = button as? LinearLayout
        addView(
          button,
          LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT).apply {
            if (index > 0) marginStart = (12f * density).toInt()
          },
        )
      }
    }
    val adjustIconScrollView = HorizontalScrollView(this).apply {
      isHorizontalScrollBarEnabled = false
      addView(adjustIconRow, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }
    adjustIconRowRef = adjustIconScrollView

    val adjustBackButton = TextView(this).apply {
      text = "<"
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = 18f
      gravity = Gravity.CENTER
      setOnClickListener { didTapAdjustBack() }
    }
    val adjustDetailRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      visibility = View.GONE
      addView(adjustBackButton, LinearLayout.LayoutParams((32f * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
      addView(adjustSlidersContainer, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
    }
    adjustDetailRowRef = adjustDetailRow

    // Both states share ONE fixed-height FrameLayout — icon row and
    // single-slider-with-back-button never differ in height, so toggling
    // between them never resizes anything above/below it.
    val adjustRowHeightPx = (44f * density).toInt()
    val adjustContainer = FrameLayout(this).apply {
      addView(adjustIconScrollView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
      addView(adjustDetailRow, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    // Filter row lives in effectPanel's content — was an always-visible
    // strip; gated behind its own Effect tab per the user's explicit
    // "major change" request. No manual background/elevation styling
    // needed here (unlike the old filtersAdjustContainer) — SlideUpPanelView
    // already supplies that chrome itself, same as Sticker/Draw/Music.
    // Strength, then the filter's own Saturation (-100..100) and
    // Sharpness (0..100) — all three reset when a new filter is picked.
    val filterSliderRowViews = listOf(
      makeFilterSliderRow("Strength", 0f, 1f, { filterStrength }, { filterStrength = it }) { refreshLivePreview() },
      makeFilterSliderRow("Saturation", -1f, 0f, { filterSaturation }, { filterSaturation = it }) { refreshLivePreview() },
      makeFilterSliderRow("Sharpness", 0f, 0f, { filterSharpness }, { filterSharpness = it }) { refreshLivePreview() },
    )
    val effectPanel = SlideUpPanelView(this, "Filters", currentEffectPanelHeightDp()).apply {
      visibility = View.INVISIBLE
      // Category tabs (Classic / Film / Cinema / Vibes) above the thumbnails.
      val categoryRowHeightPx = (FILTER_CATEGORY_ROW_HEIGHT_DP * density).toInt()
      contentContainer.addView(
        filterCategoryRow,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, categoryRowHeightPx),
      )
      contentContainer.addView(
        filterScrollView,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, filterScrollHeightPx).apply {
          topMargin = categoryRowHeightPx
        },
      )
      // Adjust mode (pencil on the selected thumbnail): a "‹ Vivid" back row
      // replaces the tabs and the sliders replace the thumbnails.
      contentContainer.addView(
        makeFilterEditHeader(),
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, categoryRowHeightPx).apply {
          marginStart = (12f * density).toInt()
        },
      )
      filterSliderRowViews.forEachIndexed { index, row ->
        contentContainer.addView(
          row,
          FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (32f * density).toInt()).apply {
            topMargin = categoryRowHeightPx + ((6f + index * 36f) * density).toInt()
            marginStart = (20f * density).toInt()
            marginEnd = (20f * density).toInt()
          },
        )
      }
      onConfirm = {
        // Next time the panel opens it starts on the thumbnails again.
        setFilterEditing(false)
        selectedImageEditorTab = ImageEditorTab.TOOLS
        updateImageEditorUI(animated = true)
      }
    }
    effectPanelRef = effectPanel
    selectFilterCategory(selectedFilter.category)
    syncFilterSliders()
    root.addView(
      effectPanel,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, effectPanelHeightPx, Gravity.BOTTOM)
        // Story mode's bottom tab tray is hidden but still reserves this
        // same height underneath (bottomTrayRef stays null there instead
        // of pointing at it — see setUpEditingControls' isStoryMode
        // branch) — pinning to it unconditionally left a dead gap below
        // every panel. Per the user's explicit "no vertical distance
        // between bottom of device and bottom sheet" request, story mode
        // uses 0 instead — flush with the true screen edge.
        .apply { bottomMargin = if (isStoryMode) storyBottomInsetPx() else bottomTabBarHeightPx + navigationBarHeightPx },
    )

    // Adjust icon-row/single-slider swap lives in editPanel's content —
    // same "was always-visible, now gated behind a tab" change.
    // Header + one row — reduced from 140 (same as iOS).
    val editPanel = SlideUpPanelView(this, "Adjust", 104f).apply {
      visibility = View.INVISIBLE
      contentContainer.addView(
        adjustContainer,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, adjustRowHeightPx).apply {
          leftMargin = (16f * density).toInt()
          rightMargin = (16f * density).toInt()
        },
      )
      onConfirm = {
        selectedImageEditorTab = ImageEditorTab.TOOLS
        updateImageEditorUI(animated = true)
      }
    }
    editPanelRef = editPanel
    root.addView(
      editPanel,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, editPanelHeightPx, Gravity.BOTTOM)
        // Story mode's bottom tab tray is hidden but still reserves this
        // same height underneath (bottomTrayRef stays null there instead
        // of pointing at it — see setUpEditingControls' isStoryMode
        // branch) — pinning to it unconditionally left a dead gap below
        // every panel. Per the user's explicit "no vertical distance
        // between bottom of device and bottom sheet" request, story mode
        // uses 0 instead — flush with the true screen edge.
        .apply { bottomMargin = if (isStoryMode) storyBottomInsetPx() else bottomTabBarHeightPx + navigationBarHeightPx },
    )

    // Sticker library: search box, category tabs, and a grid of the
    // current category (or search results). The grid is rebuilt on each
    // change so only the visible set is decoded (StickerCatalog.thumbnail).
    val stickerSearch = EditText(this).apply {
      hint = "Search stickers"
      textSize = 14f
      setSingleLine()
      imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      setHintTextColor(EditorDesignTokens.Colors.textSecondary)
      val padH = (12f * density).toInt()
      setPadding(padH, 0, padH, 0)
      background = GradientDrawable().apply {
        cornerRadius = 10f * density
        setColor(EditorDesignTokens.Colors.elevatedSurface)
      }
      addTextChangedListener(object : android.text.TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(s: android.text.Editable?) { didChangeStickerSearch(s?.toString().orEmpty()) }
      })
      setOnEditorActionListener { view, _, _ ->
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(view.windowToken, 0)
        view.clearFocus()
        true
      }
    }
    stickerSearchRef = stickerSearch
    stickerCategoryTabRefs.clear()
    val stickerTabRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      StickerCatalog.categories(this@MediaEditorActivity).forEachIndexed { index, category ->
        val label = TextView(this@MediaEditorActivity).apply {
          text = category.title
          textSize = 13f
          gravity = Gravity.CENTER
        }
        val underline = View(this@MediaEditorActivity).apply { setBackgroundColor(EditorDesignTokens.Colors.textPrimary) }
        val tab = LinearLayout(this@MediaEditorActivity).apply {
          orientation = LinearLayout.VERTICAL
          gravity = Gravity.CENTER_HORIZONTAL
          setPadding((9f * density).toInt(), 0, (9f * density).toInt(), 0)
          addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
          addView(underline, LinearLayout.LayoutParams((16f * density).toInt(), (2f * density).toInt()).apply { topMargin = (3f * density).toInt() })
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            selectStickerCategory(index)
          }
        }
        stickerCategoryTabRefs.add(label to underline)
        addView(tab, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
      }
    }
    val stickerTabScroll = HorizontalScrollView(this).apply {
      isHorizontalScrollBarEnabled = false
      addView(stickerTabRow, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }
    val stickerGrid = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    stickerGridRef = stickerGrid
    val stickerGridScroll = ScrollView(this).apply {
      isVerticalScrollBarEnabled = false
      addView(stickerGrid, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
    stickerGridScrollRef = stickerGridScroll
    val stickerSearchHeightPx = (34f * density).toInt()
    val stickerTabHeightPx = (FILTER_CATEGORY_ROW_HEIGHT_DP * density).toInt()
    val stickersPanel = SlideUpPanelView(this, "Stickers", STICKERS_PANEL_HEIGHT_DP).apply {
      visibility = View.INVISIBLE
      contentContainer.addView(
        stickerSearch,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, stickerSearchHeightPx).apply {
          leftMargin = (16f * density).toInt()
          rightMargin = (16f * density).toInt()
        },
      )
      contentContainer.addView(
        stickerTabScroll,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, stickerTabHeightPx).apply {
          topMargin = stickerSearchHeightPx + (4f * density).toInt()
          leftMargin = (7f * density).toInt()
          rightMargin = (7f * density).toInt()
        },
      )
      contentContainer.addView(
        stickerGridScroll,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT).apply {
          topMargin = stickerSearchHeightPx + stickerTabHeightPx + (8f * density).toInt()
          leftMargin = (16f * density).toInt()
          rightMargin = (16f * density).toInt()
        },
      )
      configureExpandedHeight(windowHeightPx())
      onConfirm = {
        selectedImageEditorTab = ImageEditorTab.TOOLS
        updateImageEditorUI(animated = true)
      }
    }
    stickersPanelRef = stickersPanel
    root.addView(
      stickersPanel,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, EditorDesignTokens.dpToPx(STICKERS_PANEL_HEIGHT_DP, density), Gravity.BOTTOM)
        // Story mode's bottom tab tray is hidden but still reserves this
        // same height underneath (bottomTrayRef stays null there instead
        // of pointing at it — see setUpEditingControls' isStoryMode
        // branch) — pinning to it unconditionally left a dead gap below
        // every panel. Per the user's explicit "no vertical distance
        // between bottom of device and bottom sheet" request, story mode
        // uses 0 instead — flush with the true screen edge.
        .apply { bottomMargin = if (isStoryMode) storyBottomInsetPx() else 0 },
    )
    if (!isStoryMode) {
      // Reaches the screen bottom, covering the tool rail and LOOKS · TOOLS ·
      // EXPORT while open (same top edge as before: taller by their height).
      val coveredPx = bottomTabBarHeightPx + navigationBarHeightPx
      stickersPanel.setCollapsedHeightDp(STICKERS_PANEL_HEIGHT_DP + coveredPx / density, animated = false)
      stickersPanel.setPadding(0, 0, 0, navigationBarHeightPx)
      // Above the rail (8dp elevation).
      stickersPanel.elevation = 16f * density
    }
    stickersPanelFollowsKeyboard(stickersPanel, stickerSearch)
    selectStickerCategory(0)

    // Draw panel: same 12 color swatches as the text-entry toolbar (reused
    // directly, not a second palette) plus a brush-width slider — no font/
    // alignment concepts apply here, so it's a much smaller content area
    // than Stickers' grid.
    val drawSwatchSizePx = (28f * density).toInt()
    drawColorButtonRefs.clear()
    val drawColorRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      textColorSwatches.forEachIndexed { index, colorValue ->
        val swatch = View(this@MediaEditorActivity).apply {
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            selectedDrawColor = colorValue
            drawingCanvasRef?.currentColor = colorValue
            updateDrawPickerHighlights()
          }
        }
        drawColorButtonRefs.add(swatch)
        addView(swatch, LinearLayout.LayoutParams(drawSwatchSizePx, drawSwatchSizePx).apply {
          if (index > 0) marginStart = (10f * density).toInt()
        })
      }
    }
    val drawColorScroll = HorizontalScrollView(this).apply {
      isHorizontalScrollBarEnabled = false
      addView(drawColorRow)
    }

    // PicsArt-style row: Brush / Eraser / Shape tools, then the selected
    // tool's tiles — brushes show their real stroke and shapes their
    // outline, both drawn by the same code as the canvas. Same as iOS.
    drawBrushTypeButtonRefs.clear()
    drawShapeRefs.clear()
    drawToolRefs.clear()
    val tileWidthPx = (60f * density).toInt()
    val tileHeightPx = (44f * density).toInt()
    fun tile(description: String, bitmap: android.graphics.Bitmap, onClick: () -> Unit): View =
      FrameLayout(this).apply {
        contentDescription = description
        clipToOutline = true
        addView(
          ImageView(this@MediaEditorActivity).apply { setImageBitmap(bitmap) },
          FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          onClick()
        }
      }
    fun tileRow(tiles: List<View>): LinearLayout = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      tiles.forEachIndexed { index, view ->
        addView(view, LinearLayout.LayoutParams(tileWidthPx, tileHeightPx).apply {
          if (index > 0) marginStart = (8f * density).toInt()
        })
      }
    }
    val toolRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      DrawTool.values().forEachIndexed { index, tool ->
        val icon = EditorIconView(this@MediaEditorActivity, tool.icon)
        val label = TextView(this@MediaEditorActivity).apply {
          text = tool.title
          textSize = 11f
          gravity = Gravity.CENTER
        }
        val button = LinearLayout(this@MediaEditorActivity).apply {
          orientation = LinearLayout.VERTICAL
          gravity = Gravity.CENTER
          addView(icon, LinearLayout.LayoutParams((20f * density).toInt(), (20f * density).toInt()))
          addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = (2f * density).toInt()
          })
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            applyDrawTool(tool)
          }
        }
        drawToolRefs.add(Triple(tool, button, icon to label))
        addView(button, LinearLayout.LayoutParams((56f * density).toInt(), tileHeightPx).apply {
          if (index > 0) marginStart = (4f * density).toInt()
        })
      }
    }
    val brushTiles = tileRow(
      DrawingCanvasView.BrushType.values().filter { it != DrawingCanvasView.BrushType.ERASER }.map { brushType ->
        tile(brushType.title, DrawingCanvasView.previewBitmap(brushType, tileWidthPx, tileHeightPx)) {
          selectedBrushType = brushType
          applyDrawTool(DrawTool.BRUSH)
        }.also { drawBrushTypeButtonRefs.add(brushType to it) }
      },
    )
    val shapeTiles = tileRow(
      DrawingCanvasView.ShapeType.values().map { shape ->
        tile(shape.title, DrawingCanvasView.shapePreviewBitmap(shape, tileWidthPx, tileHeightPx, 2f * density)) {
          selectedDrawShape = shape
          applyDrawTool(DrawTool.SHAPE)
        }.also { drawShapeRefs.add(shape to it) }
      },
    )
    drawBrushTilesRef = brushTiles
    drawShapeTilesRef = shapeTiles
    val drawBrushTileRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      addView(toolRow)
      addView(
        View(this@MediaEditorActivity).apply { setBackgroundColor(EditorDesignTokens.Colors.divider) },
        LinearLayout.LayoutParams((1f * density).toInt(), (28f * density).toInt()).apply {
          marginStart = (10f * density).toInt()
          marginEnd = (10f * density).toInt()
        },
      )
      addView(brushTiles)
      addView(shapeTiles)
    }
    val drawBrushTypeRow: View = if (isStoryMode) {
      HorizontalScrollView(this).apply {
        isHorizontalScrollBarEnabled = false
        addView(drawBrushTileRow)
      }
    } else {
      // Regular editor: tools on their own row, then the brushes (or
      // shapes) on a scrolling row below.
      drawBrushTileRow.removeAllViews()
      val tileRow = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(brushTiles)
        addView(shapeTiles)
      }
      LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(toolRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(
          HorizontalScrollView(this@MediaEditorActivity).apply {
            isHorizontalScrollBarEnabled = false
            addView(tileRow)
          },
          LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = (12f * density).toInt()
          },
        )
      }
    }
    drawColorScrollRef = drawColorScroll
    drawColorScrollRef = drawColorScroll

    val drawWidthMinPx = 2f * density
    val drawWidthMaxPx = 28f * density
    selectedDrawWidthPx = 6f * density
    drawEraserWidthPx = 20f * density
    drawingCanvasRef?.currentWidthPx = selectedDrawWidthPx
    drawWidthToProgress = { widthPx -> (((widthPx - drawWidthMinPx) / (drawWidthMaxPx - drawWidthMinPx)) * 100).roundToInt().coerceIn(0, 100) }
    val drawWidthSeekBar = makeStyledSeekBar().apply {
      max = 100
      progress = (((selectedDrawWidthPx - drawWidthMinPx) / (drawWidthMaxPx - drawWidthMinPx)) * 100).toInt()
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
          if (!fromUser) return
          val widthPx = drawWidthMinPx + (drawWidthMaxPx - drawWidthMinPx) * (progress / 100f)
          if (selectedDrawTool == DrawTool.ERASER) drawEraserWidthPx = widthPx else selectedDrawWidthPx = widthPx
          drawingCanvasRef?.currentWidthPx = widthPx
        }
        override fun onStartTrackingTouch(seekBar: SeekBar) {}
        override fun onStopTrackingTouch(seekBar: SeekBar) {}
      })
    }
    drawWidthSeekBarRef = drawWidthSeekBar
    val drawWidthLabel = TextView(this).apply {
      text = "Size"
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      textSize = 12f
    }
    val drawWidthRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      addView(drawWidthLabel, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
      addView(
        drawWidthSeekBar,
        LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
          marginStart = (12f * density).toInt()
        },
      )
    }

    val drawPanelContent = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      addView(drawBrushTypeRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
      addView(
        drawColorScroll,
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          topMargin = (12f * density).toInt()
        },
      )
      addView(
        drawWidthRow,
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          topMargin = (12f * density).toInt()
        },
      )
    }
    // Collapsed height reduced from the shared 220dp default per the
    // user's explicit "make these height small of vertical container"
    // request — this panel's actual content (color row + brush-type row
    // + brush-size row) is much shorter than that, leaving a large dead
    // empty area below it otherwise. Mirrors the SAME override pattern
    // "Filters"/"Adjust" already use for their own more-compact content.
    val drawPanel = SlideUpPanelView(this, "Draw", 200f).apply {
      visibility = View.INVISIBLE
      contentContainer.addView(
        drawPanelContent,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          leftMargin = (16f * density).toInt()
          rightMargin = (16f * density).toInt()
        },
      )
      configureExpandedHeight(windowHeightPx())
      onConfirm = {
        selectedImageEditorTab = ImageEditorTab.TOOLS
        updateImageEditorUI(animated = true)
      }
    }
    drawPanelRef = drawPanel
    setUpTextStylePanel(if (isStoryMode) storyBottomInsetPx() else bottomTabBarHeightPx + navigationBarHeightPx)
    setUpToolsGridPanel(if (isStoryMode) storyBottomInsetPx() else bottomTabBarHeightPx + navigationBarHeightPx)
    setUpTune()
    setUpFullScreenToolPanels()
    // ✕ on every editing panel (not Tools grid / Music).
    listOfNotNull(effectPanelRef, editPanelRef, stickersPanelRef, drawPanelRef, textStylePanelRef).forEach { panel ->
      panel.onCancel = { cancelToolSession() }
    }
    root.addView(
      drawPanel,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, panelCollapsedHeightPx, Gravity.BOTTOM)
        // Story mode's bottom tab tray is hidden but still reserves this
        // same height underneath (bottomTrayRef stays null there instead
        // of pointing at it — see setUpEditingControls' isStoryMode
        // branch) — pinning to it unconditionally left a dead gap below
        // every panel. Per the user's explicit "no vertical distance
        // between bottom of device and bottom sheet" request, story mode
        // uses 0 instead — flush with the true screen edge.
        .apply { bottomMargin = if (isStoryMode) storyBottomInsetPx() else 0 },
    )
    if (!isStoryMode) {
      // Reaches the screen bottom, covering the tool rail and LOOKS · TOOLS ·
      // EXPORT while open. Just tall enough for its rows (header, tools, brushes, colours,
      // size) above the nav bar — no extra empty space.
      drawPanel.setCollapsedHeightDp(248f + navigationBarHeightPx / density, animated = false)
      // Apply it now: the panel was added at the shared default height, and
      // setCollapsedHeightDp only resizes a panel already at its old height —
      // the first open showed the default (size slider cut off).
      drawPanel.setExpanded(false, animated = false)
      drawPanel.setPadding(0, 0, 0, navigationBarHeightPx)
      // Above the rail (8dp elevation).
      drawPanel.elevation = 16f * density
    }
    updateDrawPickerHighlights()

    // Music panel (video only) — consolidates what used to be several
    // separate floating controls (track picker, its volume/trim, the
    // original clip's mute/volume) into one SlideUpPanelView, matching
    // Stickers/Draw. Reworked per the user's explicit "update UI of the
    // music trimmer + chosen song, provide a play/pause button, add a
    // remove-selected-song icon, both music controllers (added track +
    // original clip) should be here" request.
    if (!isImage) {
      // Empty-state trigger — shown only when no track is selected yet;
      // once one is, musicTrackCardRef (below) takes over and this hides.
      // Video redesign (mockup "Music & audio"): dashed "+ Choose music
      // track" empty state; 64dp track card (green art tile, title,
      // "artist · plays 0:00–0:18", round play/pause, ✕); "Change track";
      // UPPERCASE volume headers with the % on the right and a full-width
      // slider underneath.
      val musicButton = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        background = GradientDrawable().apply {
          cornerRadius = 14f * density
          setColor(Color.TRANSPARENT)
          setStroke((1.5f * density).toInt().coerceAtLeast(1), Color.rgb(0x3A, 0x3D, 0x43), 6f * density, 4f * density)
        }
        addView(TextView(this@MediaEditorActivity).apply {
          text = "+"
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
          setTextColor(EditorDesignTokens.Colors.textPrimary)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = (8f * density).toInt() })
        addView(TextView(this@MediaEditorActivity).apply {
          text = "Choose music track"
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
          setTextColor(EditorDesignTokens.Colors.textPrimary)
          typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        })
        setOnClickListener { showMusicPicker() }
      }
      musicButtonRef = musicButton

      val musicPlayPauseIcon = EditorIconView(this, EditorIcon.PAUSE).apply {
        iconTint = EditorDesignTokens.Colors.textPrimary
      }
      musicPlayPauseIconRef = musicPlayPauseIcon
      val musicPlayPauseButton = FrameLayout(this).apply {
        contentDescription = "Preview track"
        background = GradientDrawable().apply {
          shape = GradientDrawable.OVAL
          setColor(EditorDesignTokens.Colors.divider)
        }
        addView(musicPlayPauseIcon, FrameLayout.LayoutParams((16f * density).toInt(), (16f * density).toInt(), Gravity.CENTER))
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          playPauseButtonRef?.performClick()
          musicPlayPauseIconRef?.icon = if (exoPlayer?.playWhenReady == true) EditorIcon.PAUSE else EditorIcon.PLAY
        }
      }
      val musicTrackTitle = TextView(this).apply {
        setTextColor(EditorDesignTokens.Colors.textPrimary)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
      }
      musicTrackTitleRef = musicTrackTitle
      val musicTrackSubtitle = TextView(this).apply {
        setTextColor(EditorDesignTokens.Colors.textSecondary)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
      }
      musicTrackSubtitleRef = musicTrackSubtitle
      val removeMusicIcon = EditorIconView(this, EditorIcon.CLOSE).apply {
        iconTint = EditorDesignTokens.Colors.textSecondary
      }
      val removeMusicButton = FrameLayout(this).apply {
        contentDescription = "Remove track"
        addView(removeMusicIcon, FrameLayout.LayoutParams((18f * density).toInt(), (18f * density).toInt(), Gravity.CENTER))
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
          selectMusicTrack(null)
        }
      }
      removeMusicButtonRef = removeMusicButton
      val musicArt = FrameLayout(this).apply {
        background = GradientDrawable().apply {
          cornerRadius = 10f * density
          setColor(EditorDesignTokens.Colors.musicLayer)
        }
        addView(
          EditorIconView(this@MediaEditorActivity, EditorIcon.MUSIC).apply { iconTint = Color.WHITE },
          FrameLayout.LayoutParams((22f * density).toInt(), (22f * density).toInt(), Gravity.CENTER),
        )
      }
      val musicTitleColumn = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(musicTrackTitle)
        addView(musicTrackSubtitle, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          topMargin = (2f * density).toInt()
        })
      }
      val musicTrackCard = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding((10f * density).toInt(), 0, (8f * density).toInt(), 0)
        background = GradientDrawable().apply {
          setColor(EditorDesignTokens.Colors.elevatedSurface)
          cornerRadius = (14f * density)
        }
        addView(musicArt, LinearLayout.LayoutParams((44f * density).toInt(), (44f * density).toInt()))
        addView(musicTitleColumn, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
          marginStart = (12f * density).toInt()
          marginEnd = (8f * density).toInt()
        })
        addView(musicPlayPauseButton, LinearLayout.LayoutParams((40f * density).toInt(), (40f * density).toInt()))
        addView(removeMusicButton, LinearLayout.LayoutParams((40f * density).toInt(), (40f * density).toInt()))
      }
      musicTrackCardRef = musicTrackCard

      val changeTrackButton = TextView(this).apply {
        text = "Change track"
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setTextColor(EditorDesignTokens.Colors.selectedToolTint)
        gravity = Gravity.CENTER_VERTICAL
        setPadding((4f * density).toInt(), 0, (4f * density).toInt(), 0)
        visibility = if (selectedMusicTrack == null) View.GONE else View.VISIBLE
        setOnClickListener { showMusicPicker() }
      }
      musicChangeTrackRef = changeTrackButton

      fun sectionHeader(label: String) = TextView(this).apply {
        text = label
        setTextColor(EditorDesignTokens.Colors.textSecondary)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        letterSpacing = 0.06f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
      }
      val addedMusicHeader = sectionHeader("ADDED MUSIC")

      val (musicVolumeRow, musicVolumeSeekBar) = makeVolumeBlock("MUSIC VOLUME", (musicVolume * 100).toInt(), null) { percent ->
        musicVolume = percent / 100f
        musicPlayer?.volume = musicVolume
      }
      musicVolumeRow.visibility = if (selectedMusicTrack == null) View.GONE else View.VISIBLE
      musicVolumeRowRef = musicVolumeRow
      musicVolumeSeekBarRef = musicVolumeSeekBar

      val (originalAudioVolumeRow, originalAudioSeekBar) = makeVolumeBlock(
        "ORIGINAL AUDIO", (originalAudioVolume * 100).toInt(), "0% mutes the clip's own sound",
      ) { percent ->
        originalAudioVolume = percent / 100f
        exoPlayer?.volume = effectivePlayerVolume()
      }
      originalAudioVolumeSeekBarRef = originalAudioSeekBar

      val musicPanelContent = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(addedMusicHeader, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(musicButton, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (64f * density).toInt()).apply {
          topMargin = (8f * density).toInt()
          bottomMargin = (4f * density).toInt()
        })
        addView(musicTrackCard, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (64f * density).toInt()).apply {
          topMargin = (8f * density).toInt()
        })
        addView(changeTrackButton, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, (40f * density).toInt()).apply {
          topMargin = (4f * density).toInt()
        })
        addView(musicVolumeRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          topMargin = (8f * density).toInt()
        })
        if (mediaType != "image") {
          addView(originalAudioVolumeRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = (16f * density).toInt()
            bottomMargin = (12f * density).toInt()
          })
          if (!isStoryMode) {
            // Fade in/out audio: music + the clip's own sound.
            addView(TextView(this@MediaEditorActivity).apply {
              text = "FADE"
              setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
              letterSpacing = 0.06f
              typeface = Typeface.DEFAULT_BOLD
              setTextColor(EditorDesignTokens.Colors.textSecondary)
            })
            listOf("Fade in" to true, "Fade out" to false).forEach { (title, isIn) ->
              addView(android.widget.Switch(this@MediaEditorActivity).apply {
                text = title
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTextColor(EditorDesignTokens.Colors.textPrimary)
                isChecked = if (isIn) audioFadeIn else audioFadeOut
                setOnCheckedChangeListener { _, checked ->
                  if (isIn) audioFadeIn = checked else audioFadeOut = checked
                  exoPlayer?.volume = effectivePlayerVolume()
                }
              }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (44f * density).toInt()))
            }
            addView(TextView(this@MediaEditorActivity).apply {
              text = "1-second fade on the music and the video's own sound"
              setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
              setTextColor(EditorDesignTokens.Colors.textSecondary)
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
              bottomMargin = (12f * density).toInt()
            })
            // Beat sync.
            addView(TextView(this@MediaEditorActivity).apply {
              text = "BEAT SYNC"
              setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
              letterSpacing = 0.06f
              typeface = Typeface.DEFAULT_BOLD
              setTextColor(EditorDesignTokens.Colors.textSecondary)
            })
            addView(android.widget.Switch(this@MediaEditorActivity).apply {
              text = "Snap cuts to beat"
              setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
              setTextColor(EditorDesignTokens.Colors.textPrimary)
              isChecked = beatSnapEnabled
              setOnCheckedChangeListener { _, checked -> beatSnapEnabled = checked }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (44f * density).toInt()))
            addView(TextView(this@MediaEditorActivity).apply {
              setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
              setTextColor(EditorDesignTokens.Colors.textSecondary)
              beatSyncNoteRef = this
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
              bottomMargin = (12f * density).toInt()
            })
            updateBeatSyncNote()
          }
        }
      }
      val musicPanelScrollView = ScrollView(this).apply {
        isVerticalScrollBarEnabled = false
        addView(
          musicPanelContent,
          ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT),
        )
      }
      // Taller default than the standard panel token so the added-music
      // controls fit without needing a drag-to-expand first; the
      // original-audio section is still reachable via the scroll view
      // above even at this height.
      // Video's full-screen sheet fits the restyled card + both volumes.
      val musicPanelHeightDp = if (mediaType != "image" && !isStoryMode) 330f else 300f
      val musicPanelCollapsedHeightPx = EditorDesignTokens.dpToPx(musicPanelHeightDp, density)
      val musicPanel = SlideUpPanelView(this, "Music", musicPanelHeightDp).apply {
        visibility = View.INVISIBLE
        contentContainer.addView(
          musicPanelScrollView,
          FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT).apply {
            leftMargin = (16f * density).toInt()
            rightMargin = (16f * density).toInt()
          },
        )
        configureExpandedHeight(windowHeightPx())
        onConfirm = {
          selectedImageEditorTab = ImageEditorTab.TOOLS
          updateImageEditorUI(animated = true)
        }
      }
      musicPanelRef = musicPanel
      root.addView(
        musicPanel,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, musicPanelCollapsedHeightPx, Gravity.BOTTOM)
          // Story mode's bottom tab tray is hidden but still reserves this
        // same height underneath (bottomTrayRef stays null there instead
        // of pointing at it — see setUpEditingControls' isStoryMode
        // branch) — pinning to it unconditionally left a dead gap below
        // every panel. Per the user's explicit "no vertical distance
        // between bottom of device and bottom sheet" request, story mode
        // uses 0 instead — flush with the true screen edge.
        .apply { bottomMargin = if (isStoryMode) storyBottomInsetPx() else bottomTabBarHeightPx + navigationBarHeightPx },
      )
      applyFullScreenMusicPanel()
      updateMusicTrackUI()
    }

    updateImageEditorUI()
    updateFilterButtonHighlight()

    // Reserves space for the tab bar tray, PLUS — video only — the
    // always-visible video-controls band (play/pause + filmstrip + the
    // Split/Delete/chevron row above it) sitting between the canvas and
    // that tray. This band used to float as a plain OVERLAY on top of
    // the video's own bottom portion instead of getting reserved space —
    // per the user's explicit "video editor and layers portion to be
    // completely separate... video should be always above that section,
    // not below these editor tools" request, the canvas now aspect-fits
    // ABOVE this band instead of extending underneath it. Does NOT
    // include the layer-tracks panel's own height (0 when no layers
    // exist, up to LAYER_TRACKS_MAX_HEIGHT_DP when many) — that part is
    // dynamic, reserved separately by updateCanvasSizeForLayers each time
    // it actually changes, not baked into this one-time chrome value.
    //
    // NOT for effectPanel/editPanel/stickersPanel/drawPanel/musicPanel's
    // collapsed heights: those are all toggleable SlideUpPanelViews that
    // overlay the canvas when opened, rather than getting permanently
    // reserved space. Filters/Adjust used to be an always-visible strip
    // counted here; per the user's explicit "major change" request
    // they're now gated behind their own tabs, so the canvas reclaims
    // that space.
    // Includes statusBarHeightPx now that topBar itself carries that same
    // amount as its own topMargin (see topBar's addView call) rather than
    // starting at the true y=0 top of this edge-to-edge window.
    val contentTopPx = statusBarHeightPx + topBarHeightPx
    val videoControlsBaseBandHeightPx = if (isImage) {
      0
    } else {
      // Re-derived here (not reused directly) since the `val`s of the
      // same name a few hundred lines up are scoped to an inner
      // `.apply {}` block that's already closed by this point — same
      // dp values, recomputed rather than restructuring that block's
      // scope for one read at the very end of this function.
      val videoControlsGapPx = (12f * density).toInt()
      val trimViewHeightPx = (48f * density).toInt()
      val splitDeleteRowGapPx = (8f * density).toInt()
      val splitDeleteButtonSizePx = (36f * density).toInt()
      videoControlsGapPx + trimViewHeightPx + splitDeleteRowGapPx +
        EditorDesignTokens.dpToPx(LAYER_TRACKS_TOP_GAP_DP, density) + splitDeleteButtonSizePx
    }
    // Includes navigationBarHeightPx now that bottomTrayScrollView itself
    // carries that same amount as its own bottomMargin (see its addView
    // call) rather than sitting flush against the true y=screenHeight
    // bottom of this edge-to-edge window — every consumer of this value
    // (video-controls band, layer-tracks panel, filmstrip) is positioned
    // relative to the tray's TOP edge, so they all need the same offset.
    val bottomChromeHeightPx = bottomTabBarHeightPx + navigationBarHeightPx
    // Photo: the picture runs down behind the floating glass tool row (only
    // LOOKS · TOOLS · EXPORT + the nav bar are reserved), like Instagram's
    // bar over the feed. Video keeps its controls band above the row.
    val canvasBottomReservationPx = if (isImage && !isStoryMode) {
      EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.lookToolsBarHeight, density) + navigationBarHeightPx
    } else {
      bottomChromeHeightPx + videoControlsBaseBandHeightPx
    }
    return ImageCanvasChrome(contentTopPx, bottomChromeHeightPx, canvasBottomReservationPx, horizontalMarginPx)
  }

  /**
   * Sizes and centers the canvas (imageView or playerView — only
   * `.layoutParams` is used, so a plain `View` covers both) to the media's
   * own aspect ratio within the dedicated content area (margin on all
   * sides, stopping above the bottom controls) — instead of the old
   * full-bleed MATCH_PARENT box video used to have, per the user's
   * explicit "same UI as the image editor" request. Called once initially
   * (before the async downsampled decode/player setup starts, so the box
   * is already at its final size before any layer-positioning or export
   * math — both anchored to the canvas's own center — can run against it,
   * see readDisplaySize's doc), and again every time [updateCanvasSizeForLayers]
   * runs (see that function's own doc for the layer-rescale step this
   * requires).
   *
   * [extraBottomReservationPx] (0 = no change) reserves this many
   * ADDITIONAL pixels above `chrome`'s own (fixed, video-controls-band-
   * inclusive) bottom boundary before aspect-fitting — per the user's
   * explicit CapCut-reference "video displays in a smaller bordered
   * container when layers exist, bigger when they don't" request, this is
   * how the currently-visible layer-tracks panel's own height gets
   * reserved. Since the box is always centered within the resulting
   * content area, its CENTER point moves UPWARD as this grows (unlike a
   * pure shrink-in-place) — [updateCanvasSizeForLayers]'s own layer-
   * rescale math re-derives both the old and new center fresh each time
   * rather than assuming either stays fixed, so this doesn't need to
   * preserve any invariant here.
   */
  /** Rounds `view`'s own corners via a dynamic outline (reads the view's
   *  CURRENT width/height at draw time, so it stays correct across a
   *  later resize with no need to re-apply) — per the user's explicit
   *  CapCut-reference "container with border radius" request, applied to
   *  the canvas itself plus the vignette/drawing overlays that sit
   *  exactly on top of it (so a strong vignette or an in-progress stroke
   *  can't visibly poke a square corner out past the canvas's own
   *  rounded one). */
  /** Shared with updateCanvasSelectionBorder's own border drawable — that
   *  drawable is set as the SAME view's `foreground`, and `clipToOutline`
   *  clips EVERYTHING this view draws (content AND foreground) to this
   *  outline, so a border stroke with square corners gets its 4 corners
   *  clipped away by this rounded one wherever they don't match, per the
   *  user's explicit "yellow border is cutting on four edges... image is
   *  over border" screenshot report. Must stay in sync with that
   *  drawable's own cornerRadius, not just this outline's radius. */
  private val canvasCornerRadiusPx get() = 16f * resources.displayMetrics.density

  private fun applyRoundedCanvasCorners(view: View) {
    // Story mode's canvas is a full-screen edge-to-edge preview — square
    // corners, matching the reference Instagram-style story editor.
    val radiusPx = if (isStoryMode) 0f else canvasCornerRadiusPx
    view.outlineProvider = object : ViewOutlineProvider() {
      override fun getOutline(view: View, outline: Outline) {
        outline.setRoundRect(0, 0, view.width, view.height, radiusPx)
      }
    }
    view.clipToOutline = true
  }

  /** Story mode: how much of the bottom of the screen the system
   *  navigation bar covers, so the story canvas and panels end above it
   *  (the story is edge-to-edge otherwise). 0 when displayMetrics'
   *  height already excludes the bar. */
  private fun storyBottomInsetPx(): Int {
    // `root` always spans the whole window now (edge-to-edge is forced in
    // onCreate), so the nav bar always covers its bottom. The old
    // displayMetrics-based correction assumed the window might already
    // stop above the bar, which is no longer the case.
    return navigationBarHeightPx
  }

  /** Full height of this (edge-to-edge) window — what `root` spans.
   *  displayMetrics.heightPixels can't be used: on Android 15 and older,
   *  with the app theme's edge-to-edge opt-out, it leaves out the status
   *  AND nav bars (1440 instead of 1600 on a 720x1600 phone), which sized
   *  the video box 80dp too short and left an empty band under it. */
  private fun windowHeightPx(): Int {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      return windowManager.currentWindowMetrics.bounds.height()
    }
    val real = android.util.DisplayMetrics()
    @Suppress("DEPRECATION")
    windowManager.defaultDisplay.getRealMetrics(real)
    return real.heightPixels
  }

  private fun layoutImageCanvas(
    canvasView: View,
    chrome: ImageCanvasChrome,
    displaySize: Pair<Int, Int>?,
    extraBottomReservationPx: Int = 0,
  ) {
    val displayMetrics = resources.displayMetrics
    val screenWidthPx = displayMetrics.widthPixels
    val screenHeightPx = windowHeightPx()

    // Story mode's canvas is edge-to-edge (no chrome margin/reservation —
    // its top-bar/bottom-tray are hidden, replaced by a floating overlay
    // rail, see setUpStoryModeChrome) — the content area IS the screen.
    val contentLeftPx = if (isStoryMode) 0 else chrome.horizontalMarginPx
    val contentWidthPx = if (isStoryMode) screenWidthPx else screenWidthPx - 2 * chrome.horizontalMarginPx
    val contentTopPx = if (isStoryMode) 0 else chrome.contentTopPx
    // Extra breathing room (Android only) — per the user's explicit
    // "video playing container is cutting from below... make vertical
    // height of these video container little bit small for android
    // only" screenshot report: a portrait video's box height equals
    // contentHeightPx exactly (see the aspect-fit branch below), so it
    // was sitting right up against the reserved area's own bottom edge.
    val extraVerticalBreathingRoomPx = if (isStoryMode) 0 else (16f * displayMetrics.density).toInt()
    val contentHeightPx = if (isStoryMode) screenHeightPx - storyBottomInsetPx() else screenHeightPx - chrome.contentTopPx - chrome.canvasBottomReservationPx - extraBottomReservationPx - extraVerticalBreathingRoomPx

    val (boxWidthPx, boxHeightPx) = if (displaySize != null && displaySize.first > 0 && displaySize.second > 0) {
      val photoRatio = displaySize.first.toFloat() / displaySize.second.toFloat()
      val areaRatio = contentWidthPx.toFloat() / contentHeightPx.toFloat()
      if (isStoryMode && mediaType != "image") {
        // Story-mode VIDEO: aspect-FILL (cover the whole screen, crop the
        // overflow) instead of aspect-FIT below. Story-mode IMAGES take the
        // aspect-FIT branch like every other mode so a photo is exported
        // as-is, never auto-cropped to the screen's shape (matches iOS).
        // Same two formulas, branches swapped: fit
        // picks the axis that keeps the box fully INSIDE the area, fill
        // picks the other axis so the box covers the area and overflows
        // on the constrained axis (cropped by root's own clipChildren,
        // same as every text/sticker/overlay layer already relies on).
        if (photoRatio > areaRatio) {
          (contentHeightPx * photoRatio).toInt() to contentHeightPx
        } else {
          contentWidthPx to (contentWidthPx / photoRatio).toInt()
        }
      } else if (photoRatio > areaRatio) {
        contentWidthPx to (contentWidthPx / photoRatio).toInt()
      } else {
        (contentHeightPx * photoRatio).toInt() to contentHeightPx
      }
    } else {
      // Header read failed for some reason — still get the dedicated area,
      // just without aspect-matching; FIT_CENTER on the ImageView still
      // centers/aspect-fits the photo once it decodes.
      contentWidthPx to contentHeightPx
    }

    val boxLeftPx = contentLeftPx + (contentWidthPx - boxWidthPx) / 2
    // Vertically CENTERED (not top-aligned) — per the user's explicit
    // "landscape video displays at the top with empty space below, ideally
    // it should be centered" report. A prior fix had made this top-aligned
    // instead, for a portrait video only marginally shorter than the
    // content area (a small, evenly-split gap was barely visible above and
    // comparatively felt worse below) — but a landscape video is
    // dramatically shorter than a portrait content area, so top-aligning
    // it collects ALL of that much larger slack below the box, pinning the
    // video to the top exactly as reported. Centering is the standard,
    // orientation-agnostic behavior (matches CapCut/Instagram-style
    // editors) and keeps both cases reasonable.
    val boxTopPx = if (isStoryMode && boxHeightPx < contentHeightPx) {
      // Story (aspect-fit photo): the X / Undo / Share row and the rail
      // are overlays, so centre the photo on the WHOLE screen — including
      // the nav-bar strip, which shows as the same black — rather than on
      // the area above the nav bar (that left the photo visibly high).
      // Kept above the nav bar if the photo is too tall for that.
      ((screenHeightPx - boxHeightPx) / 2).coerceAtMost(contentHeightPx - boxHeightPx).coerceAtLeast(0)
    } else {
      contentTopPx + (contentHeightPx - boxHeightPx) / 2
    }

    // Registered as the base canvas's hard clip rect (see
    // ClippingRootLayout's doc) and stashed for every text/sticker/overlay
    // layer added afterward (addTextLayer/addStickerLayer/
    // addImageOverlayLayer + their duplicate paths) — per the user's
    // explicit "zoomed image should not display outside of that cropper
    // box" report. clampLayerWithinImageBounds alone only re-centers an
    // oversized layer, it can't stop it from visually overflowing once
    // it's bigger than the box itself.
    val boxRect = Rect(boxLeftPx, boxTopPx, boxLeftPx + boxWidthPx, boxTopPx + boxHeightPx)
    canvasBoxRect = boxRect
    root.setClipRect(canvasView, boxRect)

    canvasView.layoutParams = FrameLayout.LayoutParams(boxWidthPx, boxHeightPx).apply {
      leftMargin = boxLeftPx
      topMargin = boxTopPx
    }
    applyRoundedCanvasCorners(canvasView)
    vignetteOverlayRef?.layoutParams = FrameLayout.LayoutParams(boxWidthPx, boxHeightPx).apply {
      leftMargin = boxLeftPx
      topMargin = boxTopPx
    }
    vignetteOverlayRef?.let { applyRoundedCanvasCorners(it) }
    updateVignetteOverlay()
    gridOverlayRef?.layoutParams = FrameLayout.LayoutParams(boxWidthPx, boxHeightPx).apply {
      leftMargin = boxLeftPx
      topMargin = boxTopPx
    }
    drawingCanvasRef?.layoutParams = FrameLayout.LayoutParams(boxWidthPx, boxHeightPx).apply {
      leftMargin = boxLeftPx
      topMargin = boxTopPx
    }
    blurOverlayRef?.layoutParams = FrameLayout.LayoutParams(boxWidthPx, boxHeightPx).apply {
      leftMargin = boxLeftPx
      topMargin = boxTopPx
    }

    // The 4 letterbox-gutter covers — each fills exactly the strip between
    // the content area's own edge and the canvas box's corresponding edge.
    // Zero-size (a no-op) whenever the canvas box exactly fills the content
    // area on that axis, not a visual bug. In story mode (aspect-FILL) the
    // box can be LARGER than the content area on one axis — coerced to 0
    // rather than going negative, which FrameLayout.LayoutParams can't take.
    canvasGutterTopRef?.layoutParams = FrameLayout.LayoutParams(contentWidthPx, (boxTopPx - contentTopPx).coerceAtLeast(0)).apply {
      leftMargin = contentLeftPx
      topMargin = contentTopPx
    }
    canvasGutterBottomRef?.layoutParams = FrameLayout.LayoutParams(
      contentWidthPx,
      ((contentTopPx + contentHeightPx) - (boxTopPx + boxHeightPx)).coerceAtLeast(0),
    ).apply {
      leftMargin = contentLeftPx
      topMargin = boxTopPx + boxHeightPx
    }
    canvasGutterLeftRef?.layoutParams = FrameLayout.LayoutParams((boxLeftPx - contentLeftPx).coerceAtLeast(0), boxHeightPx).apply {
      leftMargin = contentLeftPx
      topMargin = boxTopPx
    }
    canvasGutterRightRef?.layoutParams = FrameLayout.LayoutParams(
      ((contentLeftPx + contentWidthPx) - (boxLeftPx + boxWidthPx)).coerceAtLeast(0),
      boxHeightPx,
    ).apply {
      leftMargin = boxLeftPx + boxWidthPx
      topMargin = boxTopPx
    }
  }

  /** Shrinks/grows the canvas box (video/image + its rounded corners,
   *  vignette, on-canvas layers) to reserve exactly [tracksHeightPx] of
   *  EXTRA space above the video-controls band — matching the layer-
   *  tracks panel's own CURRENT height (0 when no layers exist or the
   *  panel's collapsed, up to LAYER_TRACKS_MAX_HEIGHT_DP when expanded
   *  with many) — per the user's explicit CapCut-reference "video
   *  displays in a smaller bordered container when layers exist, bigger
   *  when they don't" request AND the later, separate "video editor and
   *  layers portion to be completely separate... video should be always
   *  above that section, not below these editor tools" request (the
   *  latter is why this reserves the tracks' own EXACT current height
   *  rather than applying an arbitrary shrink factor within a FIXED
   *  content area — see setUpEditingControls's own doc for the video-
   *  controls-band BASE reservation this builds on top of). Called on
   *  every refreshLayersPanel() pass; no-ops via
   *  [lastAppliedCanvasReservationPx] when the value hasn't actually
   *  changed, so re-running this on every layer add/delete/row-count
   *  change (not just crossing zero) is cheap.
   *
   *  The tricky part isn't resizing the canvas itself — layoutImageCanvas
   *  already does that — it's that every EXISTING text/sticker/overlay
   *  layer is positioned via `translationX/Y` + `scaleX/Y`, absolute-pixel
   *  offsets from ROOT's own center (see LayerGestureCoordinator), not
   *  anything relative to the canvas box. Resizing the box alone would
   *  leave every existing layer at its OLD absolute position/size,
   *  visually detached from the now-smaller (or bigger) video underneath
   *  it. Unlike a pure shrink-within-a-fixed-area, the box's own CENTER
   *  point now MOVES too (a bigger reservation shrinks contentHeightPx
   *  from a fixed top, so the centered box's own center point shifts
   *  upward) — this rescale is written to re-derive both the OLD and NEW
   *  center fresh from their own respective rects each time, never
   *  assuming they're equal, so that's already handled correctly. Fixing
   *  this is a scale-around-a-moving-pivot transform per layer: re-
   *  express each layer's current position relative to the box's OLD
   *  center, scale that offset by (newBoxWidth / oldBoxWidth), then
   *  convert back to a translationX/Y using the box's NEW center.
   *  scaleX/Y get the same factor so each layer's own SIZE shrinks/grows
   *  in step with the canvas too. Deliberately includes layers regardless
   *  of visibility (unlike allLayerViews(), which filters to VISIBLE) — a
   *  soft-deleted or eye-toggled-off layer that gets re-shown later must
   *  not reveal a stale, wrong-scale position from before the last
   *  resize. */
  private fun updateCanvasSizeForLayers(tracksHeightPx: Int) {
    if (tracksHeightPx == lastAppliedCanvasReservationPx) return
    val canvasView = imageViewRef ?: playerViewRef ?: return
    val chrome = canvasChromeRef ?: return
    val oldBoxRect = canvasBoxRect
    lastAppliedCanvasReservationPx = tracksHeightPx
    layoutImageCanvas(canvasView, chrome, canvasDisplaySizeRef, extraBottomReservationPx = tracksHeightPx)
    // Picking a track inside full-screen Music resizes the canvas: re-fit.
    if (isVideoStageActive) root.post { updateVideoStage(animated = false) }
    val newBoxRect = canvasBoxRect
    if (oldBoxRect == null || newBoxRect == null || oldBoxRect.width() <= 0) return
    val scaleFactor = newBoxRect.width().toFloat() / oldBoxRect.width().toFloat()
    val oldCenterX = oldBoxRect.exactCenterX()
    val oldCenterY = oldBoxRect.exactCenterY()
    val newCenterX = newBoxRect.exactCenterX()
    val newCenterY = newBoxRect.exactCenterY()
    val rootCenterX = root.width / 2f
    val rootCenterY = root.height / 2f
    val layers = (textLayerViews + stickerLayerViews + imageOverlayLayerViews).distinct()
    for (layer in layers) {
      val layerAbsX = rootCenterX + layer.translationX
      val layerAbsY = rootCenterY + layer.translationY
      val relX = (layerAbsX - oldCenterX) * scaleFactor
      val relY = (layerAbsY - oldCenterY) * scaleFactor
      layer.translationX = (newCenterX + relX) - rootCenterX
      layer.translationY = (newCenterY + relY) - rootCenterY
      layer.scaleX *= scaleFactor
      layer.scaleY *= scaleFactor
      root.setClipRect(layer, newBoxRect)
    }
    // Draw strokes aren't in `layers` above (baked point geometry, not a
    // translation/scale transform like text/sticker/overlay layers) — see
    // DrawingCanvasView.rescaleForCanvasResize's own doc for why this
    // needed a separate, analogous fix. drawingCanvasRef's own bounds
    // already exactly match the box (per its class doc), so a straight
    // `point * scaleFactor` (no center-offset math) keeps every stroke
    // anchored to the same relative spot on the photo/video.
    drawingCanvasRef?.rescaleForCanvasResize(scaleFactor)
  }

  /** Radial gradient darkening drawn as a plain Drawable background —
   *  transparent center, dark edges, intensity scaled by `vignette`. No
   *  effect (transparent background) when vignette is 0 or negative — see
   *  the property's own doc for why there's no "negative vignette." */
  private fun updateVignetteOverlay() {
    val overlay = vignetteOverlayRef ?: return
    if (vignette <= 0f || overlay.width <= 0 || overlay.height <= 0) {
      overlay.background = null
      return
    }
    val centerX = overlay.width / 2f
    val centerY = overlay.height / 2f
    val radius = kotlin.math.hypot(centerX, centerY)
    val edgeAlpha = (vignette * 200).toInt().coerceIn(0, 255)
    overlay.background = GradientDrawable().apply {
      // RECTANGLE (the default), NOT oval — the drawable must fill the
      // whole rectangular bounds so the radial gradient's darkening
      // actually reaches the corners; radius is computed to the corner
      // (see `hypot` above), not just to the nearest edge.
      shape = GradientDrawable.RECTANGLE
      gradientType = GradientDrawable.RADIAL_GRADIENT
      gradientRadius = radius
      // GradientDrawable spaces color stops evenly (no custom positions
      // API) — 3 stops means transparent for the first half of the
      // radius, then ramping to dark for the second half, which reads
      // closer to a real vignette than a linear fade from dead-center.
      colors = intArrayOf(Color.TRANSPARENT, Color.TRANSPARENT, Color.argb(edgeAlpha, 0, 0, 0))
    }
  }

  /** Sized to the HIG/accessibility minimum tap target
   *  (EditorDesignTokens.SpacingDp.minTapTarget) even though the drawn
   *  glyph itself is smaller and centered — no per-icon background needed
   *  now that these sit directly on the solid topBar chrome strip. */
  /** Tap target stays at the full `minTapTarget` (44dp, an accessibility
   *  minimum) but the glyph drawn inside it is the smaller
   *  `topBarIconGlyphSize` — matching iOS, where an SF Symbol renders at
   *  its own modest default point size centered inside a same-sized
   *  UIButton rather than filling the whole tap box. Previously the icon
   *  view's own bounds WERE the tap target, so the hand-drawn glyph filled
   *  nearly the entire 44dp box — the direct cause of the user's "top
   *  icons are too big" report. */
  private fun makeTopBarIconButton(icon: EditorIcon, dropShadow: Boolean = false, onClick: () -> Unit): View {
    val density = resources.displayMetrics.density
    val tapTargetPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.minTapTarget, density)
    val glyphPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.topBarIconGlyphSize, density)
    val iconView = EditorIconView(this, icon).apply {
      iconTint = EditorDesignTokens.Colors.textPrimary
      this.dropShadow = dropShadow
    }
    return FrameLayout(this).apply {
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        onClick()
      }
      addView(iconView, FrameLayout.LayoutParams(glyphPx, glyphPx, Gravity.CENTER))
    }.apply {
      minimumWidth = tapTargetPx
      minimumHeight = tapTargetPx
    }
  }

  /** Plain text top-bar button (Cancel/Done) — standard modal convention:
   *  [primary] (Done) is bold to read as the confirming action, Cancel is
   *  plain weight. Both are the same white (textPrimary) color now — per
   *  the user's explicit "make all Done button in white" request, applied
   *  to every primary button via this shared function (also "Use Photo")
   *  for visual consistency rather than special-casing just the literal
   *  "Done" label. */
  private fun makeTopBarTextButton(label: String, primary: Boolean = false, onClick: () -> Unit): View {
    val density = resources.displayMetrics.density
    val tapTargetPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.minTapTarget, density)
    return TextView(this).apply {
      text = label
      textSize = 16f
      setTypeface(typeface, if (primary) Typeface.BOLD else Typeface.NORMAL)
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      gravity = Gravity.CENTER
      minHeight = tapTargetPx
      setPadding((12f * density).toInt(), 0, (12f * density).toInt(), 0)
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        onClick()
      }
    }
  }

  /** Returns (container, iconView, labelView) — callers of a stateful tab
   *  (Tools/Stickers) keep the iconView reference to dim/highlight it later. */
  /// Icon/label are a CONSTANT white regardless of selection — per the
  /// user's explicit "make these icons color white and just make that
  /// which icons is active then show red dot below these icon" request
  /// (see updateImageEditorUI, which now only toggles the dot).
  /// Rounded-top-corners, opaque `chromeBackground` fill for the bottom
  /// tray + filter/adjust strip (item 3) — `GradientDrawable` supplies its
  /// own rounded-rect outline for elevation shadows automatically (the
  /// default `ViewOutlineProvider.BACKGROUND`), so setting `elevation` on
  /// a view using this background is enough to get a shadow shaped to
  /// match, no separate outline provider needed.
  private fun makeFloatingPanelBackground(density: Float): GradientDrawable {
    val radius = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.panelCornerRadius, density).toFloat()
    return GradientDrawable().apply {
      setColor(EditorDesignTokens.Colors.chromeBackground)
      cornerRadii = floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f)
    }
  }

  /** Pauses playback when the user taps any bottom tool-tray icon while
   *  the video is playing, per the user's explicit "tapping any creating
   *  tool should pause playing video" request. Reuses the exact same
   *  toggle as the main transport button (rather than calling
   *  exoPlayer/musicPlayer directly) so isVideoPlaying and every icon
   *  that mirrors it (playPauseIconView, musicPlayPauseIconRef) stay in
   *  sync. Guarded on isPlaying so it never resumes an already-paused
   *  video, and is a no-op in image mode (exoPlayer is null there). */
  private fun pauseVideoForToolInteraction() {
    // Story mode has no play/pause button to resume with, so the video
    // keeps looping while tools are used (Instagram-style).
    if (isStoryMode) return
    if (exoPlayer?.isPlaying == true) {
      playPauseButtonRef?.performClick()
    }
  }

  /** Stateful tabs' views, for the selected-tool look (see styleTabButtons). */
  private val tabButtonViews = mutableMapOf<ImageEditorTab, TabButtonViews>()

  /** Video editor (not photo, not story): compact tool rail. */
  private fun isCompactToolRail(): Boolean = !isStoryMode && mediaType != "image"

  private fun trayHeightDp(): Float =
    if (isCompactToolRail()) COMPACT_TRAY_HEIGHT_DP else EditorDesignTokens.SpacingDp.bottomTrayHeight

  /** [tab] = the stateful tab this button selects (null for momentary
   *  actions like Text/Overlay), so it can show the selected look. */
  private fun makeTabButton(icon: EditorIcon, label: String, tab: ImageEditorTab? = null, onClick: () -> Unit): TabButtonViews {
    val density = resources.displayMetrics.density
    // A little smaller than the token, so the row of equal slots breathes.
    // Video editor: a compact rail (smaller icons, shorter row) — the
    // full-size one looked heavy under the timeline.
    val iconSizePx = EditorDesignTokens.dpToPx(if (isCompactToolRail()) COMPACT_TRAY_ICON_DP else EditorDesignTokens.SpacingDp.trayIconSize - 1f, density)
    val iconView = EditorIconView(this, icon).apply {
      minimumWidth = iconSizePx
      minimumHeight = iconSizePx
      iconTint = Color.WHITE
    }
    val labelView = TextView(this).apply {
      text = label
      setTextColor(Color.WHITE)
      textSize = EditorDesignTokens.TypeSizesSp.trayLabel
      gravity = Gravity.CENTER
      // Without this, a two-word title like "Add Video" wraps onto a
      // second line at this WRAP_CONTENT width's natural break point —
      // every other tray label is a single word and never hit this — and
      // that second line then gets clipped by the tray row's own fixed
      // height. Forcing single-line makes it measure (and lay out) at
      // its true one-line width instead, matching every other label.
      isSingleLine = true
      // Equal-width slots: a long label ("Add Video") shrinks a little to fit.
      androidx.core.widget.TextViewCompat.setAutoSizeTextTypeUniformWithConfiguration(
        this, 10, EditorDesignTokens.TypeSizesSp.trayLabel.toInt(), 1, android.util.TypedValue.COMPLEX_UNIT_SP,
      )
    }
    // Reserves its 4dp of space unconditionally (INVISIBLE, never GONE) so
    // toggling it on/off never changes this container's own wrap height —
    // a height change here would re-center the icon/label within the tray
    // row's fixed height (bottomTabBar's own `gravity = CENTER`), reading
    // as a small jump every time selection changes.
    val indicatorSizePx = (4f * density).toInt()
    val indicatorView = View(this).apply {
      background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(EditorDesignTokens.Colors.danger)
      }
      visibility = View.INVISIBLE
    }
    val container = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      // Room for the selected-tool tile around icon + label.
      val padH = (2f * density).toInt()
      val padV = (4f * density).toInt()
      setPadding(padH, padV, padH, 0)
      setOnClickListener {
        pauseVideoForToolInteraction()
        onClick()
      }
      addView(iconView, LinearLayout.LayoutParams(iconSizePx, iconSizePx))
      addView(
        labelView,
        // Full slot width (auto-size needs a bounded width).
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          topMargin = (2f * density).toInt()
        },
      )
      addView(
        indicatorView,
        LinearLayout.LayoutParams(indicatorSizePx, indicatorSizePx).apply {
          topMargin = (3f * density).toInt()
        },
      )
    }
    return TabButtonViews(container, iconView, labelView, indicatorView).also { views ->
      tab?.let { tabButtonViews[it] = views }
    }
  }

  /** Redesign: the selected tool gets a soft tile behind it and a blue icon
   *  + label (the old red dots stay hidden). Same on iOS. */
  private fun styleTabButtons() {
    val density = resources.displayMetrics.density
    tabButtonViews.forEach { (tab, views) ->
      val selected = tab == selectedImageEditorTab
      views.indicator.visibility = View.INVISIBLE
      // The sliding glass lens marks the selected tool (no tile); selected
      // is full white + bold, the rest slightly dimmed — like Instagram.
      views.container.background = null
      val tint = if (selected) Color.WHITE else Color.argb(199, 255, 255, 255)
      views.icon.iconTint = tint
      views.label.setTextColor(tint)
      views.label.typeface = if (selected) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
    }
    val lensTarget = tabButtonViews[selectedImageEditorTab]?.container?.takeIf { it.parent === toolGlassRowRef?.row }
    toolGlassRowRef?.moveLens(lensTarget, animated = true)
  }

  // ---- Glass tool row backdrop ----

  private var toolGlassRowRef: ToolGlassRow? = null
  private var toolGlassDrawableRef: GlassCapsuleDrawable? = null
  private var toolGlassBackdropPosted = false
  private var toolGlassBackdropHash = 0

  /** At most ~12 captures a second; each only when the screen redrew. */
  private fun scheduleToolGlassBackdrop() {
    // Photo only: video sits above the row, so there's nothing behind it
    // (and its player surface can't be drawn into a bitmap anyway).
    if (toolGlassBackdropPosted || toolGlassDrawableRef == null || mediaType != "image") return
    toolGlassBackdropPosted = true
    root.postDelayed({
      toolGlassBackdropPosted = false
      captureToolGlassBackdrop()
    }, 80L)
  }

  /** Draws everything that sits behind the capsule (the photo, layers…)
   *  at 1/4 size, blurs it and hands it to the glass. Skipped when the
   *  result didn't change, so it doesn't keep redrawing itself. */
  private fun captureToolGlassBackdrop() {
    val tray = bottomTrayRef ?: return
    val glass = toolGlassDrawableRef ?: return
    if (tray.visibility != View.VISIBLE || tray.width <= 0 || tray.height <= 0) return
    val capsule = glass.capsule
    if (capsule.isEmpty) return
    val scale = 0.25f
    val w = (capsule.width() * scale).toInt().coerceAtLeast(1)
    val h = (capsule.height() * scale).toInt().coerceAtLeast(1)
    val left = tray.left + tray.translationX + capsule.left
    val top = tray.top + tray.translationY + capsule.top
    val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(EditorDesignTokens.Colors.chromeBackground)
    canvas.scale(scale, scale)
    canvas.translate(-left, -top)
    val trayIndex = root.indexOfChild(tray)
    val trayZ = tray.z
    val area = RectF(left, top, left + capsule.width(), top + capsule.height())
    try {
      for (i in 0 until root.childCount) {
        val child = root.getChildAt(i)
        if (child === tray || child.visibility != View.VISIBLE || child.alpha <= 0.01f) continue
        // Only what's drawn BEHIND the tray (lower z, or same z added earlier).
        if (child.z > trayZ || (child.z == trayZ && i > trayIndex)) continue
        val bounds = RectF(child.left + child.translationX, child.top + child.translationY,
          child.right + child.translationX, child.bottom + child.translationY)
        if (child.rotation == 0f && child.scaleX == 1f && child.scaleY == 1f && !RectF.intersects(bounds, area)) continue
        canvas.save()
        canvas.translate(child.left.toFloat(), child.top.toFloat())
        canvas.concat(child.matrix)
        child.draw(canvas)
        canvas.restore()
      }
    } catch (e: Exception) {
      // e.g. a hardware bitmap that can't be drawn in software — keep the plain glass.
      bitmap.recycle()
      return
    }
    val pixels = IntArray(w * h)
    bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
    val hash = pixels.contentHashCode()
    if (hash == toolGlassBackdropHash && glass.backdrop != null) {
      bitmap.recycle()
      return
    }
    toolGlassBackdropHash = hash
    // Light blur: frosted but still see-through.
    val blurred = PhotoBlurRenderer.blurredSmallCopy(bitmap, 6f)
    bitmap.recycle()
    // The old backdrop isn't recycled: the render thread may still be drawing it.
    glass.backdrop = blurred
    toolGlassRowRef?.backdropChanged()
  }

  private data class TabButtonViews(val container: LinearLayout, val icon: EditorIconView, val label: TextView, val indicator: View)

  /// `animated` is false only for the initial setup call (onCreate) — no
  /// bounce/crossfade on first appearance, only on an actual tab switch.
  private fun updateImageEditorUI(animated: Boolean = false) {
    if (selectedImageEditorTab != ImageEditorTab.STICKERS) {
      stickerSearchRef?.takeIf { it.hasFocus() }?.let { search ->
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(search.windowToken, 0)
        search.clearFocus()
      }
    }
    // Panels and video controls change what the layer bar must sit above.
    root.post { repositionLayerActionToolbar() }
    if (selectedImageEditorTab != ImageEditorTab.TEXT_STYLE) commitTextStyleEdit()
    if (toolSessionTab != null && toolSessionTab != selectedImageEditorTab) {
      mergeUndoSteps(toolSessionDepth)
      toolSessionTab = null
    }
    val sessionTabs = setOf(ImageEditorTab.EFFECT, ImageEditorTab.EDIT, ImageEditorTab.STICKERS, ImageEditorTab.DRAW, ImageEditorTab.TEXT_STYLE)
    if (toolSessionTab == null && selectedImageEditorTab in sessionTabs) {
      toolSessionTab = selectedImageEditorTab
      toolSessionDepth = undoStack.size
    }
    // Music isn't on the undo stack: snapshot it so ✕ can put it back.
    if (selectedImageEditorTab == ImageEditorTab.MUSIC) {
      if (musicSessionSnapshot == null) {
        musicSessionSnapshot = MusicSessionSnapshot(
          selectedMusicTrack, musicOffsetMs, musicSegments.toList(), selectedMusicSegmentIndex,
          musicTrimStartMs, musicTrimEndMs, musicVolume, originalAudioVolume,
        )
      }
    } else {
      musicSessionSnapshot = null
    }
    root.post {
      updateOverlayEraseCapture()
      updateTuneUI()
      updateBlurCover()
    }
    textStylePanelRef?.setPanelVisible(selectedImageEditorTab == ImageEditorTab.TEXT_STYLE, animated)
    toolsGridPanelRef?.setPanelVisible(selectedImageEditorTab == ImageEditorTab.TOOLS_GRID, animated)
    // Mockup: the photo is dimmed behind the Tools sheet.
    filterStageRef?.animate()?.alpha(if (selectedImageEditorTab == ImageEditorTab.TOOLS_GRID) 0.45f else 1f)
      ?.setDuration(if (animated) EditorDesignTokens.MotionMs.panelToggleDuration.toLong() else 0L)?.start()
    // Video redesign: the video dims behind the Tools sheet too.
    if (imageViewRef == null) {
      playerViewRef?.animate()?.alpha(if (selectedImageEditorTab == ImageEditorTab.TOOLS_GRID) 0.45f else 1f)
        ?.setDuration(if (animated) EditorDesignTokens.MotionMs.panelToggleDuration.toLong() else 0L)?.start()
    }
    updateLookToolsBar()
    effectPanelRef?.setPanelVisible(selectedImageEditorTab == ImageEditorTab.EFFECT, animated)
    updateFilterStage(animated)
    updateVideoStage(animated)
    editPanelRef?.setPanelVisible(selectedImageEditorTab == ImageEditorTab.EDIT && !isTuneActive, animated)
    stickersPanelRef?.setPanelVisible(selectedImageEditorTab == ImageEditorTab.STICKERS, animated)
    drawPanelRef?.setPanelVisible(selectedImageEditorTab == ImageEditorTab.DRAW, animated)
    musicPanelRef?.setPanelVisible(selectedImageEditorTab == ImageEditorTab.MUSIC, animated)
    updateBlurOverlay()
    // Trim scrubber + play/pause + per-layer track rows only make sense
    // on the Tools tab — any open panel (Effect/Edit/Sticker/Draw/Music)
    // floats in the exact same fixed position just above the tray and
    // visually collides with the panel's own content otherwise (user-
    // reported UI bug, screenshot), no matter how tall that panel is.
    // Hiding the row entirely here is simpler and more robust than the
    // per-panel extra-height workaround this replaces. All refs stay null
    // for an image session, so this is a no-op there.
    val showVideoControls = selectedImageEditorTab == ImageEditorTab.TOOLS
    // Story mode has no play/pause or main-video filmstrip at all — the
    // clip just loops continuously (Instagram-style).
    playPauseButtonRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    videoTimeLabelRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    // filmstripScrollViewRef/filmstripPlayheadRef are the 2 top-level
    // pieces of the Instagram-style scrollable timeline now — toggling
    // both together keeps them in sync instead of leaving one floating on
    // its own.
    filmstripScrollViewRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    filmstripPlayheadRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    layerTracksPlayheadRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    // Split/Delete (multi-segment editing) and the layer-tracks row are
    // regular-editor-only in story mode — per the user's explicit
    // "delete, split and layer should not display" request, a story video
    // is already trimmed to its final length before the editor even opens
    // (see processVideo in StoryCameraScreen/SimpleGalleryScreen), so
    // segment splitting has no story-mode affordance to justify it.
    // playPauseButtonRef/filmstrip stay governed by showVideoControls
    // alone — not part of this request.
    splitSegmentButtonRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    videoSelectionLabelRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    deleteSegmentButtonRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    updateLayerStateButtons()
    videoControlsBackdropRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    layerTracksScrollViewRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    // Music / voice-over count as layers too (same as refreshLayersPanel).
    val hasAnyLayer = allLayerViews().isNotEmpty() || selectedMusicTrack != null || voiceOverPath != null
    layersAreaCollapseButtonRef?.visibility = if (showVideoControls && !isStoryMode && hasAnyLayer) View.VISIBLE else View.INVISIBLE
    addLayerButtonRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    videoCompareButtonRef?.visibility = if (showVideoControls && !isStoryMode) View.VISIBLE else View.INVISIBLE
    // Again after the line above: a selected clip / text hides compare
    // (its slot holds Transition / the text-animation button then).
    updateLayerStateButtons()
    // The layer toolbar sits just above the tool rail — re-place it after
    // a full-screen tool (Tune / Filters / Text) hid and re-showed the rail.
    if (layerActionToolbarRef != null) root.post { repositionLayerActionToolbar() }
    // Re-lay out the layer tracks when entering/leaving Tune (see
    // refreshLayersPanel's toolHidesLayers).
    if (layerTracksStackRef != null && (selectedImageEditorTab == ImageEditorTab.EDIT) != layersHiddenForTool) {
      refreshLayersPanel()
    }

    // Draw intercepts every canvas touch while active (see
    // DrawingCanvasView's own doc) — deselect any active layer first so its
    // toolbar doesn't linger uninteractive over the canvas while drawing.
    drawingCanvasRef?.isDrawingEnabled = selectedImageEditorTab == ImageEditorTab.DRAW
    if (selectedImageEditorTab == ImageEditorTab.DRAW && drawingCanvasRef?.parent === root) {
      // New strokes go on top of everything added so far ("last added on
      // top"), same as iOS; layers added afterwards land above it.
      val canvasView = drawingCanvasRef
      if (canvasView != null && root.indexOfChild(canvasView) < root.childCount - 1) {
        canvasView.bringToFront()
        keepSafeAreaCoversOnTop()
      }
    }
    if (selectedImageEditorTab == ImageEditorTab.DRAW) deselectLayer()

    // Icon/label color is now a CONSTANT white regardless of selection —
    // per the user's explicit "make these icons color white and just
    // make that which icons is active then show red dot below these
    // icon" request. The active tab is now signaled ONLY by the red dot
    // (indicatorRef) below it — no more color cross-fade (animateTabColor,
    // which only ever existed for this, was removed).
    styleTabButtons()

    if (!animated) return

    val activeIcon = when (selectedImageEditorTab) {
      ImageEditorTab.TOOLS -> toolsTabIconRef
      ImageEditorTab.EFFECT -> effectTabIconRef
      ImageEditorTab.EDIT -> editTabIconRef
      ImageEditorTab.STICKERS -> stickersTabIconRef
      ImageEditorTab.DRAW -> drawTabIconRef
      ImageEditorTab.MUSIC -> musicTabIconRef
      ImageEditorTab.TEXT_STYLE -> null
      ImageEditorTab.TOOLS_GRID -> null
    }
    val halfDurationMs = (EditorDesignTokens.MotionMs.trayIconActiveDuration / 2).toLong()
    activeIcon?.animate()
      ?.scaleX(EditorDesignTokens.TRAY_ICON_ACTIVE_SCALE)
      ?.scaleY(EditorDesignTokens.TRAY_ICON_ACTIVE_SCALE)
      ?.setDuration(halfDurationMs)
      ?.withEndAction {
        activeIcon.animate().scaleX(1f).scaleY(1f).setDuration(halfDurationMs).start()
      }
      ?.start()
  }

  private fun didTapAdjustIcon(property: AdjustProperty) {
    if (property == AdjustProperty.AUTO) {
      didTapAutoEnhance()
      return
    }
    selectedAdjustProperty = property
    adjustSliderRowRefs.forEach { (key, row) -> row.visibility = if (key == property) View.VISIBLE else View.GONE }
    adjustIconRowRef?.visibility = View.GONE
    adjustDetailRowRef?.visibility = View.VISIBLE
    if (TUNE_ORDER.any { it.first == property }) tuneProperty = property
    updateBlurOverlay()
    updateTuneUI()
  }

  private fun didTapAdjustBack() {
    selectedAdjustProperty = null
    adjustIconRowRef?.visibility = View.VISIBLE
    adjustDetailRowRef?.visibility = View.GONE
    updateBlurOverlay()
    updateTuneUI()
  }

  // ── Tune (swipe to adjust) — redesign Phase 4, same as iOS ───────────
  //
  // While Adjust is open, a transparent surface over the photo takes
  // swipes: up/down picks the setting (list shown while choosing),
  // left/right changes its value. It drives the SAME Adjust SeekBars, so
  // the value, preview and saving are unchanged; one undo step per swipe.

  private val TUNE_ORDER = listOf(
    AdjustProperty.BRIGHTNESS to "Brightness", AdjustProperty.CONTRAST to "Contrast",
    AdjustProperty.SATURATION to "Saturation", AdjustProperty.WARMTH to "Warmth",
    AdjustProperty.HIGHLIGHTS to "Highlights", AdjustProperty.SHADOW to "Shadows",
    AdjustProperty.FADE to "Fade", AdjustProperty.TINT to "Tint",
    AdjustProperty.SHARPEN to "Sharpen", AdjustProperty.VIGNETTE to "Vignette",
  )
  private var tuneProperty = AdjustProperty.BRIGHTNESS
  private var tuneSurfaceRef: View? = null
  private var tunePillRef: LinearLayout? = null
  private var tunePillNameRef: TextView? = null
  private var tunePillValueRef: TextView? = null
  private var tunePillFillRef: View? = null
  private var tunePillTrackRef: FrameLayout? = null
  private var tuneListRef: LinearLayout? = null
  /** Mockup Tune screen chrome: bottom bar (✕ · compare · Tune · list · ✓)
   *  and the hint above it. While Tune is open the top bar, the Adjust
   *  panel, the tool rail and LOOKS · TOOLS · EXPORT are all hidden. */
  private var tuneBottomBarRef: View? = null
  private var tuneHintRef: TextView? = null
  /** The settings list opened from the bottom bar's list button: stays up
   *  and its rows can be tapped (a swipe's list is touch-through). */
  private var isTuneListPinned = false

  /** Adjust shows as the full-screen Tune mode except for Blur, which keeps
   *  the Adjust panel (it needs its mode buttons). Same as iOS. */
  /** Mockup Filters screen: the selected filter's name above the photo. */
  private var filterNameLabelRef: TextView? = null

  /** Filters and Text/Style open full screen like Tune (mockup): the sheet
   *  carries its own ✕ · title · ✓ bar and the top bar, tool rail and
   *  LOOKS · TOOLS · EXPORT are hidden. Story mode keeps its own chrome. */
  private val isFullScreenPanelTool: Boolean
    get() = !isStoryMode && (selectedImageEditorTab == ImageEditorTab.EFFECT || selectedImageEditorTab == ImageEditorTab.TEXT_STYLE ||
      (selectedImageEditorTab == ImageEditorTab.MUSIC && mediaType != "image"))

  private fun setUpFullScreenToolPanels() {
    if (isStoryMode) return
    val density = resources.displayMetrics.density
    listOfNotNull(effectPanelRef, textStylePanelRef).forEach { panel ->
      (panel.layoutParams as FrameLayout.LayoutParams).bottomMargin = 0
    }
    effectPanelRef?.useBottomActionBar("Filters", navigationBarHeightPx, EditorIcon.TOOL_ADJUST, "Strength and saturation") {
      if (selectedFilter != PhotoFilter.ORIGINAL) setFilterEditing(!isEditingFilter)
    }
    textStylePanelRef?.useBottomActionBar("Text", navigationBarHeightPx)
    applyFullScreenMusicPanel()
    val label = TextView(this).apply {
      text = selectedFilter.label
      textSize = 14f
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      gravity = Gravity.CENTER
      visibility = View.GONE
      elevation = 16f * density
    }
    filterNameLabelRef = label
    root.addView(label, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, (56f * density).toInt(), Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
      topMargin = statusBarHeightPx
    })
  }

  /** Video redesign: Music is full screen too (flush with the screen
   *  bottom, ✕ · Music · ✓ bar); ✕ puts back the track and volumes it had
   *  when opened. Also called once the Music panel exists — it's built
   *  after setUpFullScreenToolPanels runs, which left it sitting above the
   *  removed bottom tray's space (empty band under the sheet). */
  private fun applyFullScreenMusicPanel() {
    if (isStoryMode || mediaType == "image") return
    musicPanelRef?.let { panel ->
      (panel.layoutParams as FrameLayout.LayoutParams).bottomMargin = 0
      panel.useBottomActionBar("Music", navigationBarHeightPx)
      panel.onCancel = { cancelMusicSession() }
    }
  }

  /** Story mode: Tune hid the story's top bar + rail (restored on close). */
  private var storyChromeHiddenForTune = false

  private val isTuneActive: Boolean
    get() = selectedImageEditorTab == ImageEditorTab.EDIT && selectedAdjustProperty != AdjustProperty.BLUR

  /** One row per setting: (row, name, value). */
  private val tuneListRows = mutableListOf<Triple<LinearLayout, TextView, TextView>>()

  private fun tuneSeekBar(property: AdjustProperty): Pair<SeekBar, TextView?>? {
    val row = adjustSliderRowRefs[property] as? LinearLayout ?: return null
    val seekBar = row.getChildAt(1) as? SeekBar ?: return null
    return seekBar to (row.getChildAt(2) as? TextView)
  }

  private fun setUpTune() {
    val density = resources.displayMetrics.density
    val slop = android.view.ViewConfiguration.get(this).scaledTouchSlop
    var startX = 0f
    var startY = 0f
    var mode = 0 // 0 undecided, 1 choose, 2 adjust
    var startIndex = 0
    var startProgress = 0
    val surface = View(this).apply {
      visibility = View.GONE
      setOnTouchListener { view, event ->
        when (event.actionMasked) {
          MotionEvent.ACTION_DOWN -> {
            startX = event.rawX
            startY = event.rawY
            mode = 0
            startIndex = TUNE_ORDER.indexOfFirst { it.first == tuneProperty }.coerceAtLeast(0)
          }
          MotionEvent.ACTION_MOVE -> {
            val dx = event.rawX - startX
            val dy = event.rawY - startY
            if (mode == 0 && kotlin.math.hypot(dx, dy) > slop) {
              if (abs(dy) > abs(dx)) {
                mode = 1
                isTuneListPinned = false
                showTuneList(true)
              } else {
                mode = 2
                startProgress = tuneSeekBar(tuneProperty)?.first?.progress ?: 100
              }
            }
            when (mode) {
              1 -> {
                // 17dp of travel per setting — every setting stays reachable
                // within a fitted (shrunk) picture.
                val index = (startIndex + (dy / (17f * density)).roundToInt()).coerceIn(0, TUNE_ORDER.size - 1)
                if (TUNE_ORDER[index].first != tuneProperty) {
                  tuneProperty = TUNE_ORDER[index].first
                  view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                  refreshTunePill()
                }
              }
              2 -> {
                val seekBar = tuneSeekBar(tuneProperty)?.first
                if (seekBar != null) {
                  // A full-width swipe moves the value by about 1.6 (of -1…1).
                  val width = (view.width * view.scaleX).coerceAtLeast(1f)
                  seekBar.progress = (startProgress + dx / width * 160f).roundToInt().coerceIn(0, seekBar.max)
                  refreshTunePill()
                }
              }
            }
          }
          MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
            if (mode == 2) {
              val seekBar = tuneSeekBar(tuneProperty)?.first
              val oldProgress = startProgress
              val newProgress = seekBar?.progress ?: oldProgress
              if (seekBar != null && newProgress != oldProgress) {
                pushUndo(undo = { seekBar.progress = oldProgress; refreshTunePill() }, redo = { seekBar.progress = newProgress; refreshTunePill() })
              }
            } else if (mode == 1) {
              showTuneList(false)
              didTapAdjustIcon(tuneProperty) // show its slider in the panel too
            }
            mode = 0
            refreshTunePill()
          }
        }
        true
      }
    }
    tuneSurfaceRef = surface
    root.addView(surface, FrameLayout.LayoutParams(0, 0))

    val name = TextView(this).apply {
      textSize = 14f
      setTextColor(EditorDesignTokens.Colors.textPrimary)
    }
    val value = TextView(this).apply {
      textSize = 14f
      typeface = Typeface.DEFAULT_BOLD
      setTextColor(EditorDesignTokens.Colors.selectedToolTint)
    }
    tunePillNameRef = name
    tunePillValueRef = value
    val labels = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
      addView(name)
      addView(value, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        marginStart = (10f * density).toInt()
      })
    }
    val fill = View(this).apply { setBackgroundColor(EditorDesignTokens.Colors.accent) }
    val track = FrameLayout(this).apply {
      background = GradientDrawable().apply {
        cornerRadius = 2f * density
        setColor(EditorDesignTokens.Colors.divider)
      }
      clipToOutline = true
      addView(fill, FrameLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT))
    }
    tunePillFillRef = fill
    tunePillTrackRef = track
    val pill = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      visibility = View.GONE
      val padH = (14f * density).toInt()
      setPadding(padH, (8f * density).toInt(), padH, (9f * density).toInt())
      background = GradientDrawable().apply {
        cornerRadius = 18f * density
        setColor(ColorUtils.setAlphaComponent(EditorDesignTokens.Colors.panelBackground, 235))
      }
      addView(labels, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        gravity = Gravity.CENTER_HORIZONTAL
      })
      addView(track, LinearLayout.LayoutParams((142f * density).toInt(), (3f * density).toInt()).apply {
        topMargin = (6f * density).toInt()
      })
    }
    tunePillRef = pill
    root.addView(pill, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL))

    // Mockup look: a dark see-through card in the middle of the screen,
    // each row "Name ……… value", the current one filled blue. Same as iOS.
    tuneListRows.clear()
    val list = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      alpha = 0f
      visibility = View.GONE
      val pad = (8f * density).toInt()
      setPadding(pad, pad, pad, pad)
      background = GradientDrawable().apply {
        cornerRadius = 18f * density
        setColor(ColorUtils.setAlphaComponent(EditorDesignTokens.Colors.canvasBackground, 210))
      }
      TUNE_ORDER.forEach { (_, title) ->
        val name = TextView(this@MediaEditorActivity).apply {
          text = title
          textSize = 15f
          setTextColor(EditorDesignTokens.Colors.textPrimary)
        }
        val value = TextView(this@MediaEditorActivity).apply {
          textSize = 15f
          setTextColor(EditorDesignTokens.Colors.textSecondary)
          gravity = Gravity.END
        }
        val row = LinearLayout(this@MediaEditorActivity).apply {
          orientation = LinearLayout.HORIZONTAL
          gravity = Gravity.CENTER_VERTICAL
          val padH = (14f * density).toInt()
          setPadding(padH, 0, padH, 0)
          addView(name, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
          addView(value, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        val rowIndex = tuneListRows.size
        row.setOnClickListener {
          if (!isTuneListPinned) return@setOnClickListener
          tuneProperty = TUNE_ORDER[rowIndex].first
          isTuneListPinned = false
          showTuneList(false)
          didTapAdjustIcon(tuneProperty)
        }
        row.isClickable = false
        tuneListRows += Triple(row, name, value)
        addView(row, LinearLayout.LayoutParams((220f * density).toInt(), (38f * density).toInt()).apply {
          topMargin = (2f * density).toInt()
        })
      }
    }
    tuneListRef = list
    root.addView(list, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
    setUpTuneBottomBar()
    setUpVideoMiniScrubber()
  }

  private fun setUpTuneBottomBar() {
    val density = resources.displayMetrics.density
    val barContentPx = (64f * density).toInt()
    val iconPx = (48f * density).toInt()
    fun icon(kind: EditorIcon, label: String, tint: Int = EditorDesignTokens.Colors.textPrimary, onClick: () -> Unit) =
      EditorIconView(this, kind).apply {
        contentDescription = label
        iconTint = tint
        val pad = (12f * density).toInt()
        setPadding(pad, pad, pad, pad)
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          onClick()
        }
      }
    val cancel = icon(EditorIcon.CLOSE, "Cancel Tune") { cancelToolSession() }
    val apply = icon(EditorIcon.CHECK, "Apply Tune", EditorDesignTokens.Colors.selectedToolTint) {
      selectedImageEditorTab = ImageEditorTab.TOOLS
      updateImageEditorUI(animated = true)
    }
    val list = icon(EditorIcon.TOOL_ADJUST, "Show settings list") {
      isTuneListPinned = !isTuneListPinned
      showTuneList(isTuneListPinned)
    }
    val title = TextView(this).apply {
      text = "Tune"
      textSize = 15f
      typeface = Typeface.DEFAULT_BOLD
      setTextColor(EditorDesignTokens.Colors.textPrimary)
    }
    val center = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      addView(makeCompareButton(), LinearLayout.LayoutParams(iconPx, iconPx))
      addView(title, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        marginStart = (10f * density).toInt()
        marginEnd = (10f * density).toInt()
      })
      addView(list, LinearLayout.LayoutParams(iconPx, iconPx))
    }
    val bar = FrameLayout(this).apply {
      setBackgroundColor(EditorDesignTokens.Colors.chromeBackground)
      visibility = View.GONE
      // Above the tool rail's 8dp elevation (hidden anyway while Tune is open).
      elevation = 16f * density
      setPadding(0, 0, 0, navigationBarHeightPx)
      addView(View(this@MediaEditorActivity).apply { setBackgroundColor(EditorDesignTokens.Colors.divider) },
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (1f * density).toInt().coerceAtLeast(1), Gravity.TOP))
      addView(cancel, FrameLayout.LayoutParams(iconPx, iconPx, Gravity.START or Gravity.CENTER_VERTICAL).apply { leftMargin = (8f * density).toInt() })
      addView(center, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
      addView(apply, FrameLayout.LayoutParams(iconPx, iconPx, Gravity.END or Gravity.CENTER_VERTICAL).apply { rightMargin = (8f * density).toInt() })
    }
    tuneBottomBarRef = bar
    root.addView(bar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, barContentPx + navigationBarHeightPx, Gravity.BOTTOM))
    val hint = TextView(this).apply {
      text = "Swipe up / down to choose · left / right to adjust"
      textSize = 12f
      gravity = Gravity.CENTER
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      visibility = View.GONE
      elevation = 16f * density
    }
    tuneHintRef = hint
    root.addView(hint, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
      bottomMargin = barContentPx + navigationBarHeightPx + (10f * density).toInt()
    })
  }

  private fun showTuneList(show: Boolean) {
    val list = tuneListRef ?: return
    // Rows only take taps when opened from the bottom bar's list button.
    tuneListRows.forEach { it.first.isClickable = show && isTuneListPinned }
    if (show) {
      // Centred on the screen (Gravity.CENTER in root).
      refreshTunePill()
      list.visibility = View.VISIBLE
      list.bringToFront()
      list.animate().alpha(1f).setDuration(150).start()
    } else {
      list.animate().alpha(0f).setDuration(200).withEndAction { list.visibility = View.GONE }.start()
    }
  }

  /** Shown while Adjust is open (not for Blur, which has its own on-photo
   *  controls). Re-placed every time — the canvas/stage may have moved. */
  private fun updateTuneUI() {
    updateVideoMiniScrubber()
    val surface = tuneSurfaceRef ?: return
    val pill = tunePillRef ?: return
    val active = isTuneActive
    val shown = if (active) View.VISIBLE else View.GONE
    surface.visibility = shown
    pill.visibility = shown
    tuneBottomBarRef?.visibility = shown
    tuneHintRef?.visibility = shown
    // Story mode: the story's own close / undo / share bar and tool rail
    // fade out while Tune is open (its pill, sliders and ✕ / ✓ bar take
    // their place).
    if (isStoryMode && active != storyChromeHiddenForTune) {
      storyChromeHiddenForTune = active
      listOfNotNull(topBarRef, storyRailRef).forEach {
        it.visibility = if (active) View.INVISIBLE else View.VISIBLE
      }
    }
    // Story mode: the tool rail also steps aside while a bottom panel
    // (stickers, draw, filters, music…) is open — it drew over the panel
    // and covered its Done / tabs. Same as iOS.
    if (isStoryMode) {
      val hideRail = active || selectedImageEditorTab != ImageEditorTab.TOOLS
      storyRailRef?.visibility = if (hideRail) View.INVISIBLE else View.VISIBLE
    }
    // Mockup Tune / Filters / Text screens: nothing else on top or bottom.
    if (!isStoryMode) {
      val chrome = if (active || isFullScreenPanelTool) View.INVISIBLE else View.VISIBLE
      filterNameLabelRef?.visibility = if (selectedImageEditorTab == ImageEditorTab.EFFECT) View.VISIBLE else View.GONE
      topBarRef?.visibility = chrome
      bottomTrayRef?.visibility = chrome
      lookToolsBarRef?.visibility = chrome
    }
    // Blur selected from inside Adjust brings the panel back (and vice versa).
    editPanelRef?.setPanelVisible(selectedImageEditorTab == ImageEditorTab.EDIT && !active, animated = true)
    if (!active) {
      isTuneListPinned = false
      tuneListRef?.visibility = View.GONE
      return
    }
    val box = canvasBoxRect ?: return
    surface.scaleX = 1f
    surface.scaleY = 1f
    surface.translationY = 0f
    surface.layoutParams = FrameLayout.LayoutParams(box.width(), box.height()).apply {
      leftMargin = box.left
      topMargin = box.top
    }
    (pill.layoutParams as FrameLayout.LayoutParams).topMargin = statusBarHeightPx + (8f * resources.displayMetrics.density).toInt()
    pill.requestLayout()
    keepSafeAreaCoversOnTop()
    if (isFilterStageActive) applyFilterStageFit(animated = false) else surface.bringToFront()
    refreshTunePill()
    listOfNotNull(tuneBottomBarRef, tuneHintRef, pill).forEach { it.bringToFront() }
    videoMiniScrubRowRef?.takeIf { it.visibility == View.VISIBLE }?.bringToFront()
  }

  // ---- Video redesign: play + scrub row inside Tune and Filters ----

  private var videoMiniScrubRowRef: LinearLayout? = null
  private var videoMiniPlayIconRef: EditorIconView? = null
  private var videoMiniSeekBarRef: SeekBar? = null
  private var videoMiniTimeLabelRef: TextView? = null
  private var isDraggingVideoMiniSeekBar = false

  private fun formatMinSec(ms: Long): String {
    val secs = (ms.coerceAtLeast(0) / 1000).toInt()
    return String.format(java.util.Locale.US, "%d:%02d", secs / 60, secs % 60)
  }

  /** Lets the user play / scrub the video while Tune or Filters is open,
   *  to check the look on other frames. */
  private fun setUpVideoMiniScrubber() {
    if (mediaType == "image" || isStoryMode) return
    val density = resources.displayMetrics.density
    val playIcon = EditorIconView(this, EditorIcon.PLAY).apply { iconTint = EditorDesignTokens.Colors.textPrimary }
    videoMiniPlayIconRef = playIcon
    val playButton = FrameLayout(this).apply {
      contentDescription = "Play"
      addView(playIcon, FrameLayout.LayoutParams((16f * density).toInt(), (16f * density).toInt(), Gravity.CENTER))
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        playPauseButtonRef?.performClick()
        syncVideoMiniPlayIcon()
      }
    }
    val timeLabel = TextView(this).apply {
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      fontFeatureSettings = "tnum"
    }
    videoMiniTimeLabelRef = timeLabel
    val seekBar = makeStyledSeekBar().apply {
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
          if (!fromUser) return
          timeLabel.text = formatMinSec(progress.toLong())
          seekCombinedTimeline(progress.toLong())
        }
        override fun onStartTrackingTouch(seekBar: SeekBar) { isDraggingVideoMiniSeekBar = true }
        override fun onStopTrackingTouch(seekBar: SeekBar) { isDraggingVideoMiniSeekBar = false }
      })
    }
    videoMiniSeekBarRef = seekBar
    val row = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      visibility = View.GONE
      elevation = 16f * density
      background = GradientDrawable().apply {
        cornerRadius = 20f * density
        setColor(Color.argb(199, 0x20, 0x22, 0x27))
        setStroke(EditorDesignTokens.dpToPx(0.5f, density).coerceAtLeast(1), Color.argb(31, 255, 255, 255))
      }
      setPadding((2f * density).toInt(), 0, (14f * density).toInt(), 0)
      addView(playButton, LinearLayout.LayoutParams((36f * density).toInt(), (36f * density).toInt()))
      addView(seekBar, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
      addView(timeLabel, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
    videoMiniScrubRowRef = row
    root.addView(row, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (40f * density).toInt(), Gravity.BOTTOM).apply {
      leftMargin = (16f * density).toInt()
      rightMargin = (16f * density).toInt()
    })
  }

  private fun syncVideoMiniPlayIcon() {
    videoMiniPlayIconRef?.icon = if (exoPlayer?.playWhenReady == true) EditorIcon.PAUSE else EditorIcon.PLAY
  }

  private fun updateVideoMiniScrubber() {
    val row = videoMiniScrubRowRef ?: return
    val density = resources.displayMetrics.density
    val inTune = isTuneActive
    val inFilters = selectedImageEditorTab == ImageEditorTab.EFFECT
    row.visibility = if (inTune || inFilters) View.VISIBLE else View.GONE
    if (row.visibility != View.VISIBLE) return
    val bottomMarginPx = if (inTune) {
      val barHeight = tuneBottomBarRef?.layoutParams?.height ?: 0
      val hintHeight = tuneHintRef?.height?.takeIf { it > 0 } ?: (16f * density).toInt()
      barHeight + (10f * density).toInt() + hintHeight + (8f * density).toInt()
    } else {
      (effectPanelRef?.layoutParams?.height ?: 0) + (8f * density).toInt()
    }
    (row.layoutParams as FrameLayout.LayoutParams).let { params ->
      if (params.bottomMargin != bottomMarginPx) {
        params.bottomMargin = bottomMarginPx
        row.layoutParams = params
      }
    }
    syncVideoMiniPlayIcon()
    syncVideoMiniScrubber(combinedTimeForCurrentPlaybackMs())
    row.bringToFront()
  }

  private fun syncVideoMiniScrubber(currentMs: Long) {
    val seekBar = videoMiniSeekBarRef ?: return
    val totalMs = combinedLayerDurationMs()
    val total = totalMs.coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
    if (seekBar.max != total) seekBar.max = total
    seekBar.progress = currentMs.coerceIn(0L, totalMs).toInt()
    videoMiniTimeLabelRef?.text = formatMinSec(currentMs.coerceAtMost(totalMs))
  }

  private fun refreshTunePill() {
    tunePillNameRef?.text = TUNE_ORDER.firstOrNull { it.first == tuneProperty }?.second.orEmpty()
    val (seekBar, valueLabel) = tuneSeekBar(tuneProperty) ?: return
    tunePillValueRef?.text = valueLabel?.text ?: "${seekBar.progress - 100}"
    // Bar fills from the centre (0) toward the value's side.
    val track = tunePillTrackRef
    val fill = tunePillFillRef
    if (track != null && fill != null) {
      val trackWidth = (track.layoutParams?.width ?: 0).toFloat()
      val v = (seekBar.progress - 100) / 100f
      val fillWidth = abs(v) * trackWidth / 2f
      fill.layoutParams = (fill.layoutParams as FrameLayout.LayoutParams).apply {
        width = fillWidth.roundToInt()
        leftMargin = (if (v >= 0f) trackWidth / 2f else trackWidth / 2f - fillWidth).roundToInt()
      }
    }
    tuneListRows.forEachIndexed { index, (row, name, value) ->
      val property = TUNE_ORDER[index].first
      val on = property == tuneProperty
      row.background = if (on) GradientDrawable().apply {
        cornerRadius = 12f * resources.displayMetrics.density
        setColor(EditorDesignTokens.Colors.accent)
      } else null
      name.typeface = if (on) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
      value.setTextColor(if (on) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.textSecondary)
      value.text = tuneSeekBar(property)?.second?.text ?: "0"
    }
  }

  private fun updateFilterButtonHighlight() {
    filterNameLabelRef?.text = selectedFilter.label
    val density = resources.displayMetrics.density
    val strokeWidthPx = (3f * density).toInt()
    filterButtonRefs.forEach { (filter, view) ->
      view.background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(EditorDesignTokens.Colors.elevatedSurface)
        if (filter == selectedFilter) setStroke(strokeWidthPx, EditorDesignTokens.Colors.accent)
      }
    }
    // Undo/redo/re-edit can land on a filter from another tab — show it.
    if (selectedFilter != PhotoFilter.ORIGINAL && selectedFilter.category != selectedFilterCategory) {
      selectFilterCategory(selectedFilter.category)
    }
    syncFilterSliders()
  }

  /** One Filters-panel slider row (Strength / Saturation / Sharpness). */
  private class FilterSliderRow(
    val view: View,
    val seekBar: SeekBar,
    val valueLabel: TextView,
    val minValue: Float,
    val read: () -> Float,
  )
  private val filterSliderRows = mutableListOf<FilterSliderRow>()
  /** True while code (not the user) sets a seek bar, so its listener
   *  doesn't re-trigger a preview refresh. */
  private var isSyncingFilterSliders = false

  /** 176 = header + category tabs + thumbnails. 200 = adjust mode: back
   *  row + Strength/Saturation/Sharpness (opened from the pencil on the
   *  selected thumbnail). Same values as iOS. */
  private fun currentEffectPanelHeightDp(): Float = if (isEditingFilter) 200f else 176f

  // ---- Filter stage (whole picture visible above the Filters panel) ----
  //
  // The Filters panel would otherwise cover the lower part of the photo.
  // The canvas and its layers can't simply be shrunk (layers live directly
  // in `root`, and their positions feed export maths), so while the panel
  // is open they're made transparent and a snapshot of the finished
  // picture — drawn from those same views, so it's exactly what you'll
  // get — is shown fitted into the free space above the panel instead.
  // Same behaviour on iOS.

  private var filterStageRef: ImageView? = null
  private var isFilterStageActive = false
  private var filterStageRefreshPosted = false
  /** Views made transparent while the stage is shown, with their alpha. */
  private val filterStageHiddenViews = mutableListOf<Pair<View, Float>>()

  /** The views that make up the picture, drawn into the snapshot. */
  private fun filterStageContentViews(): Set<View> = buildSet {
    imageViewRef?.let(::add)
    addAll(textLayerViews)
    addAll(stickerLayerViews)
    addAll(imageOverlayLayerViews)
    vignetteOverlayRef?.let(::add)
    // Outside Draw the drawing is part of the picture, in its own place in
    // the stacking order (not lifted above later stickers/text).
    if (selectedImageEditorTab != ImageEditorTab.DRAW) drawingCanvasRef?.let(::add)
    // Blur over the layers (on top of them); hidden when not in use.
    blurCoverRef?.takeIf { it.parent === root }?.let(::add)
  }

  /** Views you interact with while their panel is open (draw on the
   *  canvas, drag the blur focus). They can't be a snapshot, so instead of
   *  being hidden they get the stage's own move/scale — touch events reach
   *  them in local coordinates, so drawing/dragging still lands correctly. */
  private fun filterStageTrackingViews(): List<View> =
    listOfNotNull(
      drawingCanvasRef?.takeIf { selectedImageEditorTab == ImageEditorTab.DRAW },
      blurOverlayRef?.takeIf { selectedImageEditorTab == ImageEditorTab.EDIT },
      tuneSurfaceRef?.takeIf { selectedImageEditorTab == ImageEditorTab.EDIT },
      overlayEraseCaptureRef,
    ).filter { it.parent === root }

  /** The open panel the picture has to fit above (photo only), or null. */
  private fun filterStagePanel(): SlideUpPanelView? = when (selectedImageEditorTab) {
    ImageEditorTab.TOOLS -> null
    ImageEditorTab.EFFECT -> effectPanelRef
    ImageEditorTab.EDIT -> editPanelRef
    ImageEditorTab.STICKERS -> stickersPanelRef
    ImageEditorTab.DRAW -> drawPanelRef
    ImageEditorTab.MUSIC -> musicPanelRef
    ImageEditorTab.TEXT_STYLE -> textStylePanelRef
    ImageEditorTab.TOOLS_GRID -> toolsGridPanelRef
  }

  private fun updateFilterStage(animated: Boolean) {
    val shouldShow = filterStagePanel() != null &&
      mediaType == "image" && imageViewRef != null && canvasBoxRect != null
    if (shouldShow && !isFilterStageActive) {
      enterFilterStage(animated)
    } else if (!shouldShow && isFilterStageActive) {
      exitFilterStage(animated)
    } else if (shouldShow) {
      // Switched straight from one panel to another: what's snapshotted vs
      // moved live depends on the panel, so rebuild the stage.
      exitFilterStage(animated = false)
      enterFilterStage(animated)
    }
  }

  /** Just under the open panel, above the canvas and every layer. */
  private fun placeFilterStageBelowPanel() {
    val stage = filterStageRef ?: return
    val params = stage.layoutParams
    if (stage.parent != null) root.removeView(stage)
    val index = filterStagePanel()?.let { root.indexOfChild(it) }?.takeIf { it >= 0 } ?: root.childCount
    root.addView(stage, index, params)
  }

  private fun enterFilterStage(animated: Boolean) {
    val box = canvasBoxRect ?: return
    val bitmap = renderFilterStageBitmap() ?: return
    isFilterStageActive = true
    stickerDeleteBadgeRef?.visibility = View.GONE
    val stage = filterStageRef ?: ImageView(this).apply {
      scaleType = ImageView.ScaleType.FIT_XY
      outlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
          outline.setRoundRect(0, 0, view.width, view.height, if (isStoryMode) 0f else canvasCornerRadiusPx)
        }
      }
      clipToOutline = true
    }.also { filterStageRef = it }
    stage.layoutParams = FrameLayout.LayoutParams(box.width(), box.height()).apply {
      leftMargin = box.left
      topMargin = box.top
    }
    placeFilterStageBelowPanel()
    stage.setImageBitmap(bitmap)
    stage.visibility = View.VISIBLE
    stage.scaleX = 1f
    stage.scaleY = 1f
    stage.translationY = 0f

    filterStageHiddenViews.clear()
    val toHide = filterStageContentViews() + listOfNotNull(layerActionToolbarRef, gridOverlayRef)
    toHide.forEach { view ->
      filterStageHiddenViews += view to view.alpha
      view.alpha = 0f
    }
    keepSafeAreaCoversOnTop()
    applyFilterStageFit(animated)
  }

  fun exitFilterStage(animated: Boolean) {
    if (!isFilterStageActive) return
    isFilterStageActive = false
    root.post { updateStickerDeleteBadge() }
    val stage = filterStageRef
    // Every view that may have been moved with the stage (the tab may have
    // changed since).
    val tracking = listOfNotNull(drawingCanvasRef, blurOverlayRef, overlayEraseCaptureRef, tuneSurfaceRef)
    val restore = {
      filterStageHiddenViews.forEach { (view, alpha) -> view.alpha = alpha }
      filterStageHiddenViews.clear()
      stage?.visibility = View.GONE
      stage?.setImageBitmap(null)
      tracking.forEach { it.animate().cancel(); it.scaleX = 1f; it.scaleY = 1f; it.translationY = 0f }
    }
    if (stage == null || !animated) {
      stage?.animate()?.cancel()
      restore()
      return
    }
    val durationMs = EditorDesignTokens.MotionMs.panelToggleDuration.toLong()
    val interpolator = AnimationUtils.loadInterpolator(this, android.R.interpolator.fast_out_slow_in)
    tracking.forEach { it.animate().scaleX(1f).scaleY(1f).translationY(0f).setDuration(durationMs).setInterpolator(interpolator).start() }
    stage.animate().scaleX(1f).scaleY(1f).translationY(0f)
      .setDuration(durationMs)
      .setInterpolator(interpolator)
      .withEndAction { if (!isFilterStageActive) restore() }
      .start()
  }

  /** Scales the stage (about the canvas centre) to fit between the top bar
   *  and the open panel's top, centred in that gap. Never enlarges. The
   *  tracking views get the same mapping (pivot = canvas centre). */
  private fun applyFilterStageFit(animated: Boolean) {
    val stage = filterStageRef ?: return
    val box = canvasBoxRect ?: return
    val panel = filterStagePanel() ?: return
    val density = resources.displayMetrics.density
    val gapPx = 8f * density
    var top = (topBarRef?.bottom ?: 0) + gapPx
    var bottom = panel.bottom - panel.restingHeightPx - gapPx
    if (isTuneActive) {
      // Tune screen: between the value pill and the hint above its bar.
      val pill = tunePillRef
      val hint = tuneHintRef
      if (pill != null && hint != null) {
        pill.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
        hint.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
        top = statusBarHeightPx + 8f * density + pill.measuredHeight + 16f * density
        val hintBottomMargin = (hint.layoutParams as FrameLayout.LayoutParams).bottomMargin
        bottom = root.height - hintBottomMargin - hint.measuredHeight - 12f * density
      }
    }
    val available = bottom - top
    if (available <= 0f || box.height() <= 0) return
    val scale = minOf(1f, available / box.height())
    val targetCenterY = top + available / 2f
    val translation = targetCenterY - box.exactCenterY()
    stage.pivotX = box.width() / 2f
    stage.pivotY = box.height() / 2f
    val tracking = filterStageTrackingViews()
    tracking.forEach {
      it.pivotX = box.exactCenterX() - it.left
      it.pivotY = box.exactCenterY() - it.top
    }
    if (!animated) {
      (tracking + stage).forEach {
        it.scaleX = scale
        it.scaleY = scale
        it.translationY = translation
      }
      return
    }
    val durationMs = EditorDesignTokens.MotionMs.panelToggleDuration.toLong()
    val interpolator = AnimationUtils.loadInterpolator(this, android.R.interpolator.fast_out_slow_in)
    (tracking + stage).forEach {
      it.animate().scaleX(scale).scaleY(scale).translationY(translation)
        .setDuration(durationMs)
        .setInterpolator(interpolator)
        .start()
    }
  }

  /** Coalesces the many refreshes a slider drag triggers into one per frame. */
  private fun scheduleFilterStageRefresh() {
    if (!isFilterStageActive || filterStageRefreshPosted) return
    filterStageRefreshPosted = true
    root.post {
      filterStageRefreshPosted = false
      if (!isFilterStageActive) return@post
      // Layers added while the stage is up (e.g. a sticker from the
      // Stickers panel) belong in the snapshot, not on top of it.
      val hidden = filterStageHiddenViews.map { it.first }.toSet()
      filterStageContentViews().filter { it !in hidden }.forEach { view ->
        filterStageHiddenViews += view to view.alpha
        view.alpha = 0f
      }
      renderFilterStageBitmap()?.let { filterStageRef?.setImageBitmap(it) }
      applyFilterStageFit(animated = true)
    }
  }

  /** Draws the canvas box's content (photo + layers, as on screen) into a
   *  bitmap — each view with its own move/scale/rotate, in z-order. A
   *  view's own alpha isn't applied by View.draw, so the transparent
   *  originals still draw fully here. */
  private fun renderFilterStageBitmap(): Bitmap? = renderCanvasComposite(filterStageContentViews())

  /** Draws [content] (children of root, in their stacking order) into a
   *  bitmap of the canvas box, as on screen. */
  private fun renderCanvasComposite(content: Set<View>): Bitmap? {
    val box = canvasBoxRect ?: return null
    if (box.width() <= 0 || box.height() <= 0) return null
    val bitmap = Bitmap.createBitmap(box.width(), box.height(), Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.translate(-box.left.toFloat(), -box.top.toFloat())
    for (i in 0 until root.childCount) {
      val view = root.getChildAt(i)
      if (view !in content || view.visibility != View.VISIBLE) continue
      canvas.save()
      canvas.translate(view.left.toFloat(), view.top.toFloat())
      canvas.concat(view.matrix)
      val blend = (view as? ImageView)?.let { overlayStates[it]?.style?.blend }
      if (blend != null && blend != OverlayBlendMode.NORMAL) {
        // view.draw ignores the view's layer paint, so blend explicitly.
        canvas.saveLayer(null, Paint().also { blend.applyTo(it) })
        view.draw(canvas)
        canvas.restore()
      } else {
        view.draw(canvas)
      }
      canvas.restore()
    }
    return bitmap
  }

  // ---- Filter adjust mode ----

  /** Sliders shown instead of the thumbnails (pencil on the selected filter). */
  private var isEditingFilter = false
  private val filterEditOverlayRefs = mutableMapOf<PhotoFilter, View>()
  private var filterCategoryRowRef: View? = null
  private var filterEditHeaderRef: View? = null
  private var filterEditHeaderLabelRef: TextView? = null

  private fun setFilterEditing(editing: Boolean) {
    val newValue = editing && selectedFilter != PhotoFilter.ORIGINAL
    if (newValue == isEditingFilter) return
    isEditingFilter = newValue
    syncFilterSliders()
  }

  /** "‹ Vivid" — back to the thumbnails. */
  private fun makeFilterEditHeader(): View {
    val density = resources.displayMetrics.density
    val label = TextView(this).apply {
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      textSize = 14f
      typeface = Typeface.DEFAULT_BOLD
    }
    filterEditHeaderLabelRef = label
    return LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      visibility = View.GONE
      val iconSizePx = (18f * density).toInt()
      addView(
        EditorIconView(this@MediaEditorActivity, EditorIcon.CHEVRON_LEFT).apply { iconTint = EditorDesignTokens.Colors.textPrimary },
        LinearLayout.LayoutParams(iconSizePx, iconSizePx),
      )
      addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        marginStart = (4f * density).toInt()
      })
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        setFilterEditing(false)
      }
      filterEditHeaderRef = this
    }
  }

  // ---- Filter category tabs ----

  private val filterItemRefs = mutableMapOf<PhotoFilter, View>()
  private val filterCategoryTabRefs = mutableMapOf<FilterCategory, Pair<TextView, View>>()
  private var filterScrollViewRef: HorizontalScrollView? = null
  private var selectedFilterCategory = FilterCategory.CLASSIC

  /** Text tabs, each with a small underline shown when selected. */
  private fun makeFilterCategoryRow(): LinearLayout {
    val density = resources.displayMetrics.density
    return LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
      FilterCategory.values().filter { mediaType == "image" || it != FilterCategory.ARTISTIC }.forEach { category ->
        val label = TextView(this@MediaEditorActivity).apply {
          text = category.label
          textSize = 13f
          gravity = Gravity.CENTER
        }
        val underline = View(this@MediaEditorActivity).apply {
          setBackgroundColor(EditorDesignTokens.Colors.textPrimary)
        }
        val tab = LinearLayout(this@MediaEditorActivity).apply {
          orientation = LinearLayout.VERTICAL
          gravity = Gravity.CENTER_HORIZONTAL
          setPadding((9f * density).toInt(), 0, (9f * density).toInt(), 0)
          addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
          addView(
            underline,
            LinearLayout.LayoutParams((16f * density).toInt(), (2f * density).toInt()).apply {
              topMargin = (3f * density).toInt()
            },
          )
          setOnClickListener {
            if (category != selectedFilterCategory) {
              it.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
              selectFilterCategory(category)
            }
          }
        }
        filterCategoryTabRefs[category] = label to underline
        addView(tab, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
      }
    }
  }

  /** Shows only [category]'s thumbnails (Original always stays first). */
  private fun selectFilterCategory(category: FilterCategory) {
    selectedFilterCategory = category
    filterItemRefs.forEach { (filter, view) ->
      view.visibility = if (filter == PhotoFilter.ORIGINAL || filter.category == category) View.VISIBLE else View.GONE
    }
    filterCategoryTabRefs.forEach { (tabCategory, refs) ->
      val (label, underline) = refs
      val selected = tabCategory == category
      label.setTextColor(if (selected) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.textSecondary)
      label.typeface = if (selected) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
      underline.visibility = if (selected) View.VISIBLE else View.INVISIBLE
    }
    filterScrollViewRef?.scrollTo(0, 0)
  }

  /** The rows are only meaningful for a real filter: for Original they're
   *  hidden and the panel shrinks to just the thumbnails (same on iOS). */
  private fun syncFilterSliders() {
    // Original has nothing to adjust (e.g. undo landed on it).
    if (selectedFilter == PhotoFilter.ORIGINAL) isEditingFilter = false
    scheduleFilterStageRefresh() // panel height may change
    val editing = isEditingFilter
    effectPanelRef?.setCollapsedHeightDp(currentEffectPanelHeightDp(), animated = true)
    filterCategoryRowRef?.visibility = if (editing) View.GONE else View.VISIBLE
    filterScrollViewRef?.visibility = if (editing) View.GONE else View.VISIBLE
    filterEditHeaderRef?.visibility = if (editing) View.VISIBLE else View.GONE
    filterEditHeaderLabelRef?.text = selectedFilter.label
    filterEditOverlayRefs.forEach { (filter, overlay) ->
      overlay.visibility = if (filter == selectedFilter && filter != PhotoFilter.ORIGINAL) View.VISIBLE else View.GONE
    }
    val visibility = if (editing) View.VISIBLE else View.GONE
    isSyncingFilterSliders = true
    filterSliderRows.forEach { row ->
      row.view.visibility = visibility
      val value = row.read()
      row.seekBar.progress = ((value - row.minValue) * 100).roundToInt()
      row.valueLabel.text = "${(value * 100).roundToInt()}"
    }
    isSyncingFilterSliders = false
  }

  /** Label + seek bar + value readout for one filter setting in
   *  [minValue]..1 (shown x100). Haptic tick on reaching [defaultValue];
   *  one undo entry per drag, same as the Adjust sliders. */
  private fun makeFilterSliderRow(
    title: String,
    minValue: Float,
    defaultValue: Float,
    read: () -> Float,
    write: (Float) -> Unit,
    onChange: () -> Unit,
  ): LinearLayout {
    val density = resources.displayMetrics.density
    val label = TextView(this).apply {
      text = title
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      textSize = 12f
    }
    val valueLabel = TextView(this).apply {
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = EditorDesignTokens.TypeSizesSp.sliderValue
      gravity = Gravity.END
    }
    val defaultProgress = ((defaultValue - minValue) * 100).roundToInt()
    val seekBar = makeStyledSeekBar().apply {
      max = ((1f - minValue) * 100).roundToInt()
      progress = ((read() - minValue) * 100).roundToInt()
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        var dragStartValue = defaultValue
        override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
          val value = minValue + progress / 100f
          valueLabel.text = "${(value * 100).roundToInt()}"
          if (isSyncingFilterSliders) return
          val wasDefault = ((read() - minValue) * 100).roundToInt() == defaultProgress
          write(value)
          if (progress == defaultProgress && !wasDefault) seekBar.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
          onChange()
        }
        override fun onStartTrackingTouch(seekBar: SeekBar) {
          dragStartValue = read()
        }
        override fun onStopTrackingTouch(seekBar: SeekBar) {
          val oldValue = dragStartValue
          val newValue = read()
          if (oldValue == newValue) return
          pushUndo(
            undo = { write(oldValue); onChange(); syncFilterSliders() },
            redo = { write(newValue); onChange(); syncFilterSliders() },
          )
        }
      })
    }
    return LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      // Fixed label width so the three sliders line up.
      addView(label, LinearLayout.LayoutParams((68f * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
      addView(
        seekBar,
        LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
          marginStart = (8f * density).toInt()
          marginEnd = (8f * density).toInt()
        },
      )
      addView(valueLabel, LinearLayout.LayoutParams((36f * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
      filterSliderRows += FilterSliderRow(this, seekBar, valueLabel, minValue, read)
    }
  }

  private fun performUndo() {
    val action = undoStack.removeLastOrNull() ?: return
    blurCoverRevision++
    action.undo()
    redoStack.add(action)
    // Undoing past where the open tool started: ✕ mustn't redo those.
    if (toolSessionTab != null && undoStack.size < toolSessionDepth) toolSessionDepth = undoStack.size
  }

  /** Folds every undo step since [depth] into one (a tool's whole session). */
  private fun mergeUndoSteps(depth: Int) {
    if (depth < 0 || undoStack.size - depth <= 1) return
    val actions = undoStack.subList(depth, undoStack.size).toList()
    repeat(actions.size) { undoStack.removeAt(undoStack.size - 1) }
    undoStack.add(UndoableAction(
      undo = { actions.asReversed().forEach { it.undo() } },
      redo = { actions.forEach { it.redo() } },
    ))
  }

  private data class MusicSessionSnapshot(
    val track: MusicTrack?,
    val offsetMs: Long,
    val segments: List<LongRange>,
    val selectedSegment: Int?,
    val trimStartMs: Long,
    val trimEndMs: Long,
    val musicVolume: Float,
    val originalVolume: Float,
  )
  /** Music as it was when the Music sheet opened (video redesign ✕). */
  private var musicSessionSnapshot: MusicSessionSnapshot? = null
  private var musicVolumeSeekBarRef: SeekBar? = null
  private var originalAudioVolumeSeekBarRef: SeekBar? = null

  /** ✕ on the full-screen Music sheet: put back the track, its timing and
   *  both volumes as they were when the sheet opened. */
  private fun cancelMusicSession() {
    root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    musicSessionSnapshot?.let { snap ->
      if (snap.track?.audioUrl != selectedMusicTrack?.audioUrl) selectMusicTrack(snap.track)
      musicOffsetMs = snap.offsetMs
      musicSegments.clear()
      musicSegments.addAll(snap.segments)
      selectedMusicSegmentIndex = snap.selectedSegment
      musicTrimStartMs = snap.trimStartMs
      musicTrimEndMs = snap.trimEndMs
      // Setting progress runs each row's own listener (label + volume).
      musicVolumeSeekBarRef?.progress = (snap.musicVolume * 100).toInt()
      originalAudioVolumeSeekBarRef?.progress = (snap.originalVolume * 100).toInt()
      musicVolume = snap.musicVolume
      musicPlayer?.volume = musicVolume
      originalAudioVolume = snap.originalVolume
      exoPlayer?.volume = effectivePlayerVolume()
      refreshLayersPanel()
    }
    musicSessionSnapshot = null
    selectedImageEditorTab = ImageEditorTab.TOOLS
    updateImageEditorUI(animated = true)
  }

  /** Video: views hidden while the video is shrunk above a full-screen
   *  sheet (on-canvas layers don't follow the player's scale here). */
  private val videoStageHiddenViews = mutableListOf<View>()
  private var isVideoStageActive = false

  /** Video redesign: while full-screen Filters or Music is open the video
   *  shrinks to sit between the top and the sheet (photos use the filter
   *  stage). Text/sticker/overlay layers and drawing hide meanwhile. */
  private fun updateVideoStage(animated: Boolean) {
    if (mediaType == "image" || isStoryMode) return
    val player = playerViewRef ?: return
    val density = resources.displayMetrics.density
    val panel = if (selectedImageEditorTab == ImageEditorTab.EFFECT || selectedImageEditorTab == ImageEditorTab.MUSIC) filterStagePanel() else null
    var scale = 1f
    var dy = 0f
    if (panel != null && player.height > 0 && player.width > 0 && root.height > 0) {
      val panelHeight = panel.layoutParams.height.takeIf { it > 0 } ?: panel.height
      val top = statusBarHeightPx + 56f * density
      // Filters also has the play + scrub row above its sheet.
      val bottom = root.height - panelHeight - 12f * density -
        (if (selectedImageEditorTab == ImageEditorTab.EFFECT) 52f * density else 0f)
      val available = bottom - top
      if (available > 80f * density) {
        scale = minOf(1f, available / player.height, (root.width - 32f * density) / player.width)
        dy = (top + available / 2f) - (player.top + player.height / 2f)
      }
    }
    val active = panel != null
    val duration = if (animated) EditorDesignTokens.MotionMs.panelToggleDuration.toLong() else 0L
    listOfNotNull(player, vignetteOverlayRef).forEach { v ->
      v.pivotX = v.width / 2f
      v.pivotY = v.height / 2f
      v.animate().scaleX(scale).scaleY(scale).translationY(dy).setDuration(duration).start()
    }
    // The canvas clip rect would cut off the moved video (layoutImageCanvas
    // re-sets it, so clear it on every pass while staged).
    if (active) root.setClipRect(player, null)
    if (active && !isVideoStageActive) {
      isVideoStageActive = true
      val toHide = mutableListOf<View?>()
      toHide += textLayerViews
      toHide += stickerLayerViews
      toHide += imageOverlayLayerViews
      toHide += drawingCanvasRef
      toHide += layerActionToolbarRef
      toHide.filterNotNull().filter { it.visibility == View.VISIBLE }.forEach {
        it.visibility = View.INVISIBLE
        videoStageHiddenViews += it
      }
    } else if (!active && isVideoStageActive) {
      isVideoStageActive = false
      videoStageHiddenViews.forEach { it.visibility = View.VISIBLE }
      videoStageHiddenViews.clear()
      player.postDelayed({
        if (!isVideoStageActive) root.setClipRect(player, canvasBoxRect)
      }, duration)
    }
  }

  /** ✕ on a tool panel: put back everything changed since it opened. */
  private fun cancelToolSession() {
    root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    if (selectedImageEditorTab == ImageEditorTab.TEXT_STYLE) {
      val target = textStyleTarget
      val snapshot = textStyleAtOpen
      if (target != null && snapshot != null) {
        // Not committed to the undo stack yet — restore it directly.
        textStyleTarget = null
        textStyleAtOpen = null
        applyStyleSnapshot(snapshot, target)
      }
    }
    if (toolSessionTab != null) {
      while (undoStack.size > toolSessionDepth) {
        undoStack.removeAt(undoStack.size - 1).undo()
      }
      toolSessionTab = null
    }
    if (selectedImageEditorTab == ImageEditorTab.EFFECT) setFilterEditing(false)
    selectedImageEditorTab = ImageEditorTab.TOOLS
    updateImageEditorUI(animated = true)
  }

  private fun performRedo() {
    val action = redoStack.removeLastOrNull() ?: return
    blurCoverRevision++
    action.redo()
    undoStack.add(action)
  }

  private fun confirmDeleteLayer(target: View) {
    if (isLayerLocked(target)) {
      android.widget.Toast.makeText(this, "Layer is locked. Unlock it to delete.", android.widget.Toast.LENGTH_SHORT).show()
      return
    }
    AlertDialog.Builder(this)
      .setTitle("Delete this layer?")
      .setPositiveButton("Delete") { _, _ -> deleteLayer(target) }
      .setNegativeButton("Cancel", null)
      .show()
  }

  private fun deleteLayer(target: View) {
    // Long-press → confirm (confirmDeleteLayer) can delete a layer that
    // was never explicitly tapped-selected first — if it WAS the current
    // selection, clear it now so its white border and the canvas's own
    // yellow one (see updateCanvasSelectionBorder) don't stay stuck on a
    // hidden layer.
    if (selectedLayerView === target) deselectLayer()
    target.visibility = View.GONE
    refreshLayersPanel()
    pushUndo(
      undo = { target.visibility = View.VISIBLE; refreshLayersPanel() },
      redo = { target.visibility = View.GONE; refreshLayersPanel() },
    )
  }

  /** Removes the whole music track — reached once deleteMusicSegment hits
   *  its last remaining segment (same confirm-then-delete shape as
   *  confirmDeleteLayer), per the user's explicit "provide functionality
   *  to remove full music layer" request. Long-press alone no longer
   *  triggers this directly — it just selects the tapped segment now,
   *  per the user's later "on long press these splitted portion should
   *  select only" correction. */
  private fun confirmDeleteMusicLayer() {
    if (selectedMusicTrack == null) return
    AlertDialog.Builder(this)
      .setTitle("Delete music?")
      .setPositiveButton("Delete") { _, _ -> selectMusicTrack(null) }
      .setNegativeButton("Cancel", null)
      .show()
  }

  // MARK: - Layers panel (per-layer time range + z-order)
  //
  // Per the user's explicit "each text/sticker/overlay element should have
  // its own layer, draggable to extend/reduce, and reorderable" request
  // (reference image: a stacked multi-track timeline). Two new
  // capabilities that didn't exist at all before this: (1) a layer can be
  // visible for only PART of the clip, not always the whole thing; (2) a
  // layer's stacking order (which renders on top of which) can be changed
  // after the fact, not just fixed at add-time. Reordering here is via
  // up/down buttons, not true drag-and-drop — a deliberate scope cut to
  // keep touch handling tractable, matching the same kind of cut made for
  // Draw/Overlay export-baking and video segment splitting earlier.
  // Export-time enforcement of these ranges is a separate, not-yet-built
  // follow-up — this pass covers live-preview + the editing UI only.

  /** Total KEPT duration across the PRIMARY clip AND every merged clip —
   *  the same combined, gap-compacted coordinate space
   *  [combinedTimeForCurrentPlaybackMs] reports during playback (clips
   *  packed back-to-back, deleted segments/trims removed). Layer timing
   *  ([registerLayerTiming]/[refreshLayersPanel]/[updateLayerTimeVisibility])
   *  is expressed in THIS space, not the primary clip's own raw local
   *  time, so a newly merged clip's timeline is covered too. */
  private fun combinedLayerDurationMs(): Long {
    val primaryKeptMs = videoSegments.sumOf { it.last - it.first }
    val mergedKeptMs = additionalVideoClipUris.sumOf { additionalClipKeptDurationMs(it) }
    return primaryKeptMs + mergedKeptMs
  }

  /** Sum of a merged clip's own KEPT segment durations — the "how much of
   *  this clip actually contributes to combined playback time" figure
   *  used everywhere a merged clip's span is needed (anchoring, filmstrip
   *  width, combined-timeline duration, the duration label). Falls back
   *  to the full clip when it hasn't been split/trimmed at all yet. */
  private fun additionalClipKeptDurationMs(uri: String): Long {
    val fullDurationMs = additionalClipDurationsMs[uri] ?: 5000L
    val segments = additionalClipSegments[uri]
    if (segments.isNullOrEmpty()) return fullDurationMs
    return segments.sumOf { it.last - it.first }
  }

  /** Registers a fresh [currentPlayhead, durationMs] time range for a
   *  newly-added layer — starts wherever playback currently is, runs to
   *  the end of the COMBINED (primary + every merged clip) timeline — a
   *  no-op for image sessions, which have no time axis. Call right after
   *  appending to textLayerViews/stickerLayerViews/imageOverlayLayerViews. */
  private fun registerLayerTiming(layer: View) {
    if (mediaType == "image") return
    // The FIRST layer in a fresh session should always auto-expand the
    // dedicated area (per the user's explicit "if layers are active
    // these video preview goes smaller" request) even if the user
    // collapsed it earlier this session and then deleted every layer —
    // once truly empty, a re-collapse from a past session shouldn't
    // linger. A later add while layers already exist respects whatever
    // the user last chose.
    if (layerTimings.isEmpty()) isLayersAreaCollapsed = false
    val resolvedDurationMs = combinedLayerDurationMs().takeIf { it > 0 } ?: 1L
    // Starts wherever playback currently is (the fixed white playhead
    // line) instead of always from the very beginning of the clip.
    // Clamped so scrubbing to the very last instant before adding still
    // leaves a usable, visible slice (matches the 500ms minimum segment
    // length used elsewhere) rather than a zero-length range. Every
    // newly-added layer keeps its own playhead-anchored start untouched
    // (no automatic even-split reflow against same-type siblings) —
    // layers added at the same/overlapping playhead position can
    // visually overlap; drag a layer's own range-bar segment to adjust
    // it manually if that happens.
    val playheadMs = combinedTimeForCurrentPlaybackMs()
    // Story mode: every layer shows for the WHOLE video (Instagram-style)
    // — there's no layer timeline there to adjust it with anyway.
    val startMs = if (isStoryMode) 0L else playheadMs.coerceIn(0, (resolvedDurationMs - 500L).coerceAtLeast(0))
    // Edits-style default length: 3 seconds from the playhead (or to the
    // end, if that's sooner) so new layers don't all pile up full-length.
    // Story mode keeps the whole video.
    val endMs = if (isStoryMode) resolvedDurationMs else minOf(resolvedDurationMs, startMs + NEW_LAYER_DEFAULT_MS)
    layerTimings[layer] = LayerTiming(mutableListOf(startMs..endMs))
    refreshLayersPanel()
    // Selection happened before this timing existed — show eye / lock now.
    updateLayerStateButtons()
  }

  /** The player's real duration resolves asynchronously (see the
   *  `timelineRunnable` polling loop) — a layer added in the brief window
   *  before it's known gets stamped with [registerLayerTiming]'s 0..1L
   *  sentinel fallback above. Once the real duration is known, stretch any
   *  timing still exactly at that sentinel out to the real full clip,
   *  otherwise it stays a barely-visible sliver in its LayerRangeBarView
   *  track forever (its range bar renders at 1/durationMs of the row's
   *  width). Sentinel is always this layer's SOLE segment at this point —
   *  a layer can't have been split yet in the brief window before the
   *  real duration resolves. */
  private fun correctFallbackLayerTimings(durationMs: Long) {
    if (durationMs <= 1L) return
    var didChange = false
    // Matched by upperBound alone (the fallback's fixed `1L` duration),
    // NOT the full `0L..1L` range — registerLayerTiming's playhead-
    // anchored start means the sentinel's start can be any value up to
    // 500ms, not just 0, so a `== 0L..1L` equality check silently failed
    // to correct any layer added after playback had already advanced even
    // slightly, leaving it stuck as a ~1ms sliver forever (looks like
    // "only visible at one position").
    for ((_, timing) in layerTimings) {
      if (timing.segments.size == 1 && timing.segments[0].last == 1L) {
        val start = timing.segments[0].first
        timing.segments[0] = start..durationMs
        didChange = true
      }
    }
    if (didChange) refreshLayersPanel()
  }

  /** Pushes every existing layer's end out to the current combined
   *  duration whenever a merged clip is added or its real duration
   *  resolves — per the "if I add new video then existing text/icon/
   *  music should be auto added on that layer too" behavior, mirroring
   *  the parity iOS implementation. Only the LAST segment ever extends —
   *  earlier segments (before a split, or an internal gap left by a
   *  deleted split portion) keep their own end exactly as the user set
   *  it. No-op once nothing's actually shorter than the new duration. */
  private fun extendLayerTimingsToCombinedDuration() {
    if (mediaType == "image" || layerTimings.isEmpty()) return
    val durationMs = combinedLayerDurationMs()
    if (durationMs <= 0) return
    var didChange = false
    for ((_, timing) in layerTimings) {
      val lastIndex = timing.segments.lastIndex
      if (lastIndex < 0) continue
      val last = timing.segments[lastIndex]
      if (last.last < durationMs) {
        timing.segments[lastIndex] = last.first..durationMs
        didChange = true
      }
    }
    if (didChange) {
      updateLayerTimeVisibility()
      refreshLayersPanel()
    }
  }

  /** For a duplicated layer: inherit the source's own time range rather
   *  than resetting to the full clip, so "duplicate" reads as a true copy
   *  (same visible window) instead of silently expanding it. */
  private fun copyOrRegisterLayerTiming(source: View, clone: View) {
    if (mediaType == "image") return
    val sourceTiming = layerTimings[source]
    if (sourceTiming != null) {
      // A copy starts visible and unlocked.
      layerTimings[clone] = sourceTiming.copy(segments = sourceTiming.segments.toMutableList(), isManuallyHidden = false, isLocked = false)
      refreshLayersPanel()
    } else {
      registerLayerTiming(clone)
    }
  }

  /** Splits `layer`'s segment at `index` into two, at the current
   *  combined-timeline playhead — mirrors the primary video's own Split
   *  button, scoped to one layer's own segment list instead of
   *  [videoSegments]. Refuses (no-op) if the playhead is too close to
   *  either edge of that segment to leave both halves >= the same 500ms
   *  minimum used throughout this file. */
  private fun splitLayerSegment(layer: View, index: Int) {
    val timing = layerTimings[layer] ?: return
    if (index !in timing.segments.indices) return
    val segment = timing.segments[index]
    val splitPointMs = combinedTimeForCurrentPlaybackMs()
    val minSegmentMs = 500L
    if (splitPointMs - segment.first < minSegmentMs || segment.last - splitPointMs < minSegmentMs) return
    val oldSegments = timing.segments.toList()
    timing.segments[index] = segment.first..splitPointMs
    timing.segments.add(index + 1, splitPointMs..segment.last)
    val newSegments = timing.segments.toList()
    root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    updateLayerTimeVisibility()
    refreshLayersPanel()
    pushUndo(
      undo = {
        layerTimings[layer]?.let { t ->
          t.segments.clear()
          t.segments.addAll(oldSegments)
          updateLayerTimeVisibility()
          refreshLayersPanel()
        }
      },
      redo = {
        layerTimings[layer]?.let { t ->
          t.segments.clear()
          t.segments.addAll(newSegments)
          updateLayerTimeVisibility()
          refreshLayersPanel()
        }
      },
    )
  }

  /** Deletes JUST segment `index` of `layer` (see [splitLayerSegment]'s
   *  own doc) — the segment is simply removed from the array (no
   *  absolute-time shifting of any remaining segments — a layer's
   *  segments are a VISIBILITY schedule, not video footage being
   *  spliced). If this was the layer's LAST remaining segment, deletes
   *  the whole layer instead (a layer with 0 segments is meaningless) via
   *  the SAME confirm/undo path a full layer deletion already uses. */
  private fun deleteLayerSegment(layer: View, index: Int) {
    val timing = layerTimings[layer] ?: return
    if (index !in timing.segments.indices) return
    if (timing.segments.size <= 1) {
      confirmDeleteLayer(layer)
      return
    }
    val oldSegments = timing.segments.toList()
    timing.segments.removeAt(index)
    val newSegments = timing.segments.toList()
    selectedLayerSegmentIndex = null
    root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    updateLayerTimeVisibility()
    refreshLayersPanel()
    pushUndo(
      undo = {
        layerTimings[layer]?.let { t ->
          t.segments.clear()
          t.segments.addAll(oldSegments)
          updateLayerTimeVisibility()
          refreshLayersPanel()
        }
      },
      redo = {
        layerTimings[layer]?.let { t ->
          t.segments.clear()
          t.segments.addAll(newSegments)
          updateLayerTimeVisibility()
          refreshLayersPanel()
        }
      },
    )
  }

  /** The merged-clip segment (uri, segmentIndex, realLocalMs) the player
   *  is CURRENTLY on, if any — null when the primary clip is active. Each
   *  kept segment is its own separate, ClippingConfiguration-windowed
   *  playlist entry (see makeAdditionalPlaylistMediaItems), so
   *  player.currentPosition is already 0-based within JUST that segment;
   *  adding the segment's own start within the original clip recovers the
   *  real absolute local time matching additionalClipSegments' own
   *  coordinate space (no "compacted -> real" walk needed, unlike iOS's
   *  composition-based approach — Android's playlist entries are already
   *  one-per-segment). */
  private fun currentMergedClipSegment(): Triple<String, Int, Long>? {
    val player = exoPlayer ?: return null
    if (player.currentMediaItemIndex == 0) return null
    val (uri, segmentIndex) = additionalPlaylistEntries().getOrNull(player.currentMediaItemIndex - 1) ?: return null
    val segment = additionalClipSegments[uri]?.getOrNull(segmentIndex) ?: return null
    return Triple(uri, segmentIndex, segment.first + player.currentPosition)
  }

  /** Seeks playback to a specific segment of a merged clip, at a position
   *  local to (0-based within) that segment's own ClippingConfiguration
   *  window. Used right after rebuildAdditionalPlaylistItems in the
   *  split/delete paths below — that call replaces every playlist entry
   *  from index 1 onward, including whichever one was just playing, so
   *  without an explicit seek back ExoPlayer falls back to playlist index
   *  0 (the primary clip) — per the user's explicit "I split it once, now
   *  I can't split again, scissors isn't cutting" report: the very next
   *  scissors tap saw the playhead sitting back at the primary clip's
   *  start (not this merged clip at all), silently tried to split THAT
   *  instead, and failed there too (too close to time 0). */
  private fun seekToMergedClipSegment(uri: String, segmentIndex: Int, localMs: Long) {
    val player = exoPlayer ?: return
    val playlistIndex = additionalPlaylistEntries().indexOf(uri to segmentIndex)
    if (playlistIndex < 0) return
    player.seekTo(playlistIndex + 1, localMs.coerceAtLeast(0))
  }

  /** Splits the currently-ACTIVE merged clip's own segment at the
   *  playhead — the merged-clip counterpart to
   *  videoTrimView.splitAtCurrentTime/splitLayerSegment, per the user's
   *  explicit "why on every click of scissors icon layer should cut in
   *  split portion" report (Split used to just silently jump back to the
   *  primary clip and do nothing whenever a merged clip was active). */
  private fun splitActiveMergedClipSegment(uri: String) {
    // Lazy-init BEFORE currentMergedClipSegment() reads it — that helper
    // requires additionalClipSegments[uri] to already exist (via
    // additionalClipSegments[uri]?.getOrNull(segmentIndex)), but a freshly-
    // added, never-split-or-trimmed clip has no entry yet. The getOrPut
    // below used to run AFTER this early return, so it never actually
    // executed — every scissors tap on a brand-new merged clip silently
    // failed no matter where the playhead was, per the user's explicit
    // "newly added video is not splitting" report.
    // deleteActiveMergedClipSegment already does its own getOrPut BEFORE
    // calling currentMergedClipSegment() (that's why deleting worked but
    // splitting didn't) — mirrored here.
    val segments = additionalClipSegments.getOrPut(uri) { mutableListOf(0L..additionalClipKeptDurationMs(uri)) }
    val (segUri, segmentIndex, splitPointMs) = currentMergedClipSegment() ?: return
    if (segUri != uri) return
    if (segmentIndex !in segments.indices) return
    val segment = segments[segmentIndex]
    val minSegmentMs = 500L
    if (splitPointMs - segment.first < minSegmentMs || segment.last - splitPointMs < minSegmentMs) return
    val oldSegments = segments.toList()
    segments[segmentIndex] = segment.first..splitPointMs
    segments.add(segmentIndex + 1, splitPointMs..segment.last)
    val newSegments = segments.toList()
    root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    refreshMergedClipsStrip()
    rebuildAdditionalPlaylistItems()
    // Land back in this same clip, right at the start of the new
    // right-hand half — see seekToMergedClipSegment's own doc for why
    // this is required, not optional, after rebuildAdditionalPlaylistItems.
    seekToMergedClipSegment(uri, segmentIndex + 1, 0L)
    pushUndo(
      undo = {
        additionalClipSegments[uri]?.let { s -> s.clear(); s.addAll(oldSegments) }
        refreshMergedClipsStrip()
        rebuildAdditionalPlaylistItems()
      },
      redo = {
        additionalClipSegments[uri]?.let { s -> s.clear(); s.addAll(newSegments) }
        refreshMergedClipsStrip()
        rebuildAdditionalPlaylistItems()
      },
    )
  }

  /** Deletes one segment of the currently-ACTIVE merged clip — targets
   *  whichever segment was last TAPPED (selectedMergedClipSegmentIndex,
   *  mirroring selectedLayerSegmentIndex/videoTrimView.
   *  selectedSegmentIndex's identical role), falling back to "whichever
   *  segment contains the playhead" otherwise. Silently refuses (matching
   *  this file's own "no distinct reject haptic" convention — see
   *  splitLayerSegment) to delete a clip's only remaining segment.
   *  Whole-clip removal (mergedStripDeleteButton) was removed per the
   *  user's explicit "remove these red delete icons" request — a merged
   *  clip can now only ever be trimmed down to a single segment, not
   *  removed entirely. */
  private fun deleteActiveMergedClipSegment(uri: String) {
    val segments = additionalClipSegments.getOrPut(uri) { mutableListOf(0L..additionalClipKeptDurationMs(uri)) }
    val tappedIndex = (if (selectedMergedClipUri == uri) selectedMergedClipSegmentIndex else null)?.takeIf { it in segments.indices }
    val current = currentMergedClipSegment()?.takeIf { it.first == uri }
    val targetIndex = tappedIndex ?: current?.second
    if (targetIndex == null || targetIndex !in segments.indices) return
    if (segments.size <= 1) {
      // Only piece left: offer to remove the whole clip (roadmap row 29).
      confirmRemoveMergedClip(uri)
      return
    }
    val referenceRealTimeMs = tappedIndex?.let { segments[it].first } ?: current?.third
    val oldSegments = segments.toList()
    segments.removeAt(targetIndex)
    val newSegments = segments.toList()
    if (selectedMergedClipUri == uri) {
      selectedMergedClipUri = null
      selectedMergedClipSegmentIndex = null
    }
    root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    refreshMergedClipsStrip()
    rebuildAdditionalPlaylistItems()
    // Same fix as splitActiveMergedClipSegment — land on whatever segment
    // now occupies the old position, or near (not exactly at) the end of
    // what remains if the trailing-most segment was the one deleted (2000L
    // matches VideoTrimView's own minTrimDurationMs, kept as a literal per
    // this file's existing cross-file-constant convention), so an
    // immediate next split on this same clip doesn't land in an
    // unsplittable dead zone right on the edge.
    val matchingMinTrimDurationMs = 2000L
    val nextIndex = referenceRealTimeMs?.let { ref -> newSegments.indexOfFirst { it.first >= ref } }?.takeIf { it >= 0 }
    if (nextIndex != null) {
      seekToMergedClipSegment(uri, nextIndex, 0L)
    } else {
      val lastIndex = newSegments.lastIndex
      val lastSegment = newSegments[lastIndex]
      val localMs = (lastSegment.last - lastSegment.first - matchingMinTrimDurationMs).coerceAtLeast(0)
      seekToMergedClipSegment(uri, lastIndex, localMs)
    }
    pushUndo(
      undo = {
        additionalClipSegments[uri]?.let { s -> s.clear(); s.addAll(oldSegments) }
        refreshMergedClipsStrip()
        rebuildAdditionalPlaylistItems()
      },
      redo = {
        additionalClipSegments[uri]?.let { s -> s.clear(); s.addAll(newSegments) }
        refreshMergedClipsStrip()
        rebuildAdditionalPlaylistItems()
      },
    )
  }

  /** The current z-order (bottom to top) of every NON-deleted text/
   *  sticker/overlay layer, read straight from `root`'s real child order —
   *  no parallel tracking array to keep in sync, since the ViewGroup's own
   *  child order already IS the actual render order. */
  private fun allLayerViews(): List<View> {
    val layerSet: Set<View> = (textLayerViews + stickerLayerViews).toSet() + imageOverlayLayerViews.toSet()
    return (0 until root.childCount).map { root.getChildAt(it) }
      .filter { it in layerSet && it.visibility == View.VISIBLE }
  }

  /** A short label for a layer's track row — its own text for a text
   *  layer, "Sticker" for a sticker (both are plain TextViews,
   *  distinguished via `stickerLayerAssetNames` since a sticker's text is
   *  cleared in favor of a compound drawable — see applyStickerImage), or
   *  a generic name for an image overlay (which has no text to show). */
  private fun layerDisplayLabel(layer: View): String = when {
    locationLayerStates.containsKey(layer) -> infoStickerTitle(locationLayerStates[layer]?.kind ?: "location")
    stickerLayerAssetNames.containsKey(layer) -> "Sticker"
    layer is TextView -> layer.text?.toString()?.takeIf { it.isNotEmpty() } ?: "Text"
    else -> "Overlay"
  }

  /** Called every time the set of layers, their timing, or their manual-
   *  hide state changes (and after toggling isLayersAreaCollapsed) —
   *  clears and rebuilds the track row stack with at most 3 rows (Text,
   *  Stickers, Overlay — only the non-empty ones, per the user's
   *  explicit "for multiple emojis multiple layer will not be created,
   *  all images will be in single layer one by one... same for text"
   *  correction), each a single LayerRangeBarView holding every layer of
   *  that type. Then grows or shrinks layerTracksScrollViewRef,
   *  layersAreaCollapseButtonRef, Split/Delete, and
   *  videoControlsBackdropRef to fit. Three states: no layers (everything
   *  back to base height, no chevron — matches the original floating-
   *  over-video look exactly), layers + expanded (opaque dedicated-
   *  looking area, tracks visible up to a cap), layers + collapsed
   *  (tracks hidden, only the chevron handle remains visible so the user
   *  can re-expand). */
  private fun refreshLayersPanel() {
    val stack = layerTracksStackRef ?: return
    stack.removeAllViews()
    // KEPT duration (matches videoTrimViewRef's own compacted total
    // exactly when merged clips exist) rather than the last segment's
    // raw upperBound — identical in the common (no split) case, but
    // keeps each row's own fixed-pixel width below at the SAME
    // pixels-per-second scale as the video row, per the user's explicit
    // "show layers above current video, same timeline" reference.
    //
    // Includes merged-clip duration too (not just the primary clip's own
    // kept duration) even though layer items themselves are still timed
    // within the primary clip only — this makes each row's own width
    // (and the `durationMs` LayerRangeBarView.configure() denominator)
    // scale in lockstep with layerTracksStackRef's full combined width
    // (set in updateFilmstripLayout). Since LayerRangeBarView's own
    // xFor/timeFor map time -> pixel as a plain (time/durationMs)*width
    // ratio, and BOTH durationMs and width now grow by the exact same
    // primaryWidthPx+mergedWidthPx factor, every existing item's
    // rendered pixel position is mathematically unchanged — only the
    // row's own trailing (empty) background now extends the full way to
    // the timeline's real end instead of stopping dead at the primary
    // clip's boundary, which is what the user's "text and sticker layer
    // is cutting when scrolling" report was seeing (the row's own view —
    // and its background paint — used to physically end there, so
    // scrolling past it revealed bare background instead of a
    // continuous, just-empty track).
    val primaryDurationMs = videoSegments.sumOf { it.last - it.first }.takeIf { it > 0 } ?: 1L
    val mergedDurationMs = additionalVideoClipUris.sumOf { additionalClipKeptDurationMs(it) }
    val durationMs = primaryDurationMs + mergedDurationMs
    val density = resources.displayMetrics.density
    // Raised from 28dp alongside capPx's own increase, per the user's
    // "increase height of that view" request — each row reads more
    // clearly with the extra vertical room.
    val rowHeightPx = (34f * density).toInt()
    val rowGapPx = (6f * density).toInt()
    // Fixed pixel width at the SAME timelinePointsPerSecondPx scale as
    // videoTrimViewRef — left-aligned at x=0 (marginStart 0) since
    // layerTracksScrollViewRef's own leading edge is now pinned to
    // filmstripScrollViewRef's exactly (see setUpEditingControls), with
    // NO extra margin hack needed any more. `durationMs` already includes
    // merged-clip time above, so this now matches layerTracksStackRef's
    // full combined width exactly — no separate empty-background gap to
    // leave past its own right edge any more.
    val rowWidthPx = ((durationMs / 1000.0) * timelinePointsPerSecondPx).toInt().coerceAtLeast(1)

    // Edits-style layers: every text/sticker/photo gets its OWN row,
    // ordered like the canvas stacking — the top row is the item drawn on
    // top. Long-press a row and drag up/down to change that order.
    layerTrackRowOwners.clear()
    var rowCount = 0
    for (layer in allLayerViews().reversed()) {
      val row = makeLayerTypeRow(listOf(layer), layerTrackColor(layer), durationMs)
      layerTrackRowOwners[row] = layer
      (row as? LayerRangeBarView)?.let { bar ->
        bar.onCrossRowReorderStep = { direction -> moveLayerTrackRow(row, direction) }
        // Drag a SELECTED layer's body to move it in time (length
        // unchanged). Only while unsplit — same rule as the music row.
        if (!isLayerLocked(layer) && (layerTimings[layer]?.segments?.size ?: 1) <= 1) {
          bar.allowBodyDrag = true
          bar.bodyDragRequiresSelection = true
        }
      }
      stack.addView(
        row,
        LinearLayout.LayoutParams(rowWidthPx, rowHeightPx).apply {
          topMargin = rowGapPx
        },
      )
      rowCount++
    }
    syncLayerTrackSelection()
    // Dedicated music row — per the user's explicit "add one dedicated
    // layer of music... user can scroll and drag to change position"
    // request. Only ever 0 or 1 item, so it's built separately rather
    // than forced into the groups loop above (which assumes a
    // layerTimings-backed View list — music's timing model is
    // musicOffsetMs/musicTrimStartMs/EndMs instead).
    if (selectedMusicTrack != null) {
      stack.addView(
        makeMusicRow(durationMs),
        LinearLayout.LayoutParams(rowWidthPx, rowHeightPx).apply {
          topMargin = rowGapPx
        },
      )
      rowCount++
    }
    if (voiceOverPath != null) {
      stack.addView(
        makeVoiceRow(durationMs),
        LinearLayout.LayoutParams(rowWidthPx, rowHeightPx).apply {
          topMargin = rowGapPx
        },
      )
      rowCount++
    }


    val hasLayers = rowCount > 0
    // Tune / Adjust / Vignette (the EDIT panel) hide the timeline — fold
    // the layer tracks (and the "Layers · N" row) away too so they don't
    // leave an empty band under the video. The user's own collapse choice
    // (isLayersAreaCollapsed) is untouched and returns afterwards.
    val toolHidesLayers = selectedImageEditorTab == ImageEditorTab.EDIT
    layersHiddenForTool = toolHidesLayers
    val expanded = hasLayers && !isLayersAreaCollapsed && !toolHidesLayers
    // Raised from 110dp per the user's explicit "increase height of that
    // view where we are displaying all layers" request — fits more
    // simultaneous rows before scrolling internally.
    val capPx = EditorDesignTokens.dpToPx(LAYER_TRACKS_MAX_HEIGHT_DP, density)
    val fitTracksHeightPx = minOf(rowCount * (rowHeightPx + rowGapPx), capPx)
    val tracksHeightPx = if (expanded) fitTracksHeightPx else 0
    // Reserves exactly this much EXTRA space (on top of
    // setUpEditingControls's own one-time base reservation, which already
    // covers the video row + Split/Delete row + the gap above the tracks)
    // above the video-controls band — per the user's explicit "video
    // should be always above that section, not below these editor tools"
    // request. No-ops when the height hasn't actually changed.
    // Video redesign: the "Layers · N" pill has its own row between the
    // play/split/delete row and the layer tracks — reserve it too.
    val chevronHeightPx = if (hasLayers && !toolHidesLayers) (28f * density).toInt() else 0
    val pillRowPx = if (hasLayers && !toolHidesLayers) chevronHeightPx + (2f * density).toInt() else 0
    updateCanvasSizeForLayers(tracksHeightPx + pillRowPx)
    val layerCount = allLayerViews().size + (if (selectedMusicTrack != null) 1 else 0) + (if (voiceOverPath != null) 1 else 0)
    // Collapsed: one coloured dot per layer type before the label (mockup).
    val dotColors = mutableListOf<Int>()
    if (!expanded) {
      if (textLayerViews.any { it.visibility == View.VISIBLE }) dotColors += EditorDesignTokens.Colors.textLayer
      if (stickerLayerViews.any { it.visibility == View.VISIBLE }) dotColors += EditorDesignTokens.Colors.stickerLayer
      // Photos: blue, matching their tracks.
      if (imageOverlayLayerViews.any { it.visibility == View.VISIBLE }) dotColors += EditorDesignTokens.Colors.accent
      if (selectedMusicTrack != null) dotColors += EditorDesignTokens.Colors.musicLayer
    }
    val pillBuilder = android.text.SpannableStringBuilder()
    dotColors.forEach { color ->
      val start = pillBuilder.length
      pillBuilder.append("●")
      pillBuilder.setSpan(android.text.style.ForegroundColorSpan(color), start, start + 1, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
      pillBuilder.setSpan(android.text.style.RelativeSizeSpan(0.7f), start, start + 1, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
    if (dotColors.isNotEmpty()) pillBuilder.append("  ")
    pillBuilder.append("Layers · $layerCount")
    layersAreaCollapseLabelRef?.text = pillBuilder
    val tracksTopGapPx = EditorDesignTokens.dpToPx(LAYER_TRACKS_TOP_GAP_DP, density)
    val splitDeleteButtonSizePx = (36f * density).toInt()
    val backdropTopPaddingPx = (6f * density).toInt()

    (layerTracksScrollViewRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.height = tracksHeightPx
      layerTracksScrollViewRef?.layoutParams = params
    }
    // Keeps layerTracksPlayheadRef's own top edge flush with
    // layerTracksScrollView's own top edge (both measured from the same
    // filmstripBandBottomMarginPx baseline) as the tracks area grows/
    // shrinks — see that view's own doc for why this makes the video
    // row's playhead line read as one continuous line through every row.
    (layerTracksPlayheadRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.height = layerTracksFixedBottomMarginPx + tracksHeightPx - filmstripBandBottomMarginPx
      layerTracksPlayheadRef?.layoutParams = params
    }

    // Split/Delete + the collapse chevron share this same top-band
    // reference — per the user's explicit "keep split and delete icon
    // on top right side of all layer, not in the middle" correction,
    // they no longer sit between the tracks and the trim scrubber.
    val pillBottomMarginPx = layerTracksFixedBottomMarginPx + tracksHeightPx + tracksTopGapPx
    val topBandBottomMarginPx = pillBottomMarginPx + pillRowPx

    (layersAreaCollapseButtonRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.height = chevronHeightPx
      params.bottomMargin = pillBottomMarginPx
      layersAreaCollapseButtonRef?.layoutParams = params
    }
    // "+ Layer" sits in the play/split/delete row, left of the scissors
    // (user's request — it overlapped the filmstrip in its own row); the
    // "Clip 2"/"Text" selection label moves left of it.
    val splitRightMarginPx = (splitSegmentButtonRef?.layoutParams as? FrameLayout.LayoutParams)?.rightMargin ?: 0
    val addLayerRightMarginPx = splitRightMarginPx + splitDeleteButtonSizePx + (8f * density).toInt()
    (addLayerButtonRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.bottomMargin = topBandBottomMarginPx + (splitDeleteButtonSizePx - params.height) / 2
      params.rightMargin = addLayerRightMarginPx
      addLayerButtonRef?.layoutParams = params
    }
    (videoSelectionLabelRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      // Left of compare (before/after, 32dp), which sits just left of "+".
      val compareWidthPx = if (videoCompareButtonRef != null) ((32f + 2f) * density).toInt() else 0
      params.rightMargin = addLayerRightMarginPx + (ADD_LAYER_BUTTON_WIDTH_DP * density).toInt() + compareWidthPx + (8f * density).toInt()
      videoSelectionLabelRef?.layoutParams = params
    }
    // Compare just left of "+", then lock, then eye.
    val compareRightMarginPx = addLayerRightMarginPx + (ADD_LAYER_BUTTON_WIDTH_DP * density).toInt() + (2f * density).toInt()
    listOf(videoCompareButtonRef, clipTransitionButtonRef, textAnimationButtonRef).forEach { button ->
      (button?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
        params.bottomMargin = topBandBottomMarginPx + (splitDeleteButtonSizePx - params.height) / 2
        params.rightMargin = compareRightMarginPx
        button.layoutParams = params
      }
    }
    val lockRightMarginPx = compareRightMarginPx + (32f * density).toInt() + (2f * density).toInt()
    val hideRightMarginPx = lockRightMarginPx + ((LAYER_STATE_BUTTON_WIDTH_DP + 2f) * density).toInt()
    listOf(
      layerLockButtonRef to lockRightMarginPx, layerHideButtonRef to hideRightMarginPx,
      // Speed sits in the eye button's slot (Duplicate was removed).
      clipVolumeButtonRef to lockRightMarginPx, clipSpeedButtonRef to lockRightMarginPx,
    ).forEach { (button, rightMarginPx) ->
      (button?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
        params.bottomMargin = topBandBottomMarginPx + (splitDeleteButtonSizePx - params.height) / 2
        params.rightMargin = rightMarginPx
        button.layoutParams = params
      }
    }
    // Called after every layer add/delete/reorder — would otherwise
    // re-show this button in story mode the moment a text/sticker layer
    // gets added, undoing updateImageEditorUI's own isStoryMode hide.
    // Only while the video controls are showing (Split mirrors them): a
    // full-screen panel such as Music hides them, and adding music there
    // re-ran this and floated the pill over the panel.
    val videoControlsShown = splitSegmentButtonRef?.visibility == View.VISIBLE
    layersAreaCollapseButtonRef?.visibility = if (hasLayers && !isStoryMode && videoControlsShown) View.VISIBLE else View.INVISIBLE
    layersAreaCollapseIconRef?.icon = if (expanded) EditorIcon.CHEVRON_DOWN else EditorIcon.CHEVRON_UP

    (deleteSegmentButtonRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.bottomMargin = topBandBottomMarginPx
      deleteSegmentButtonRef?.layoutParams = params
    }
    (splitSegmentButtonRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.bottomMargin = topBandBottomMarginPx
      splitSegmentButtonRef?.layoutParams = params
    }
    // Play/pause shares this same top-band reference now too — see its
    // own addView call.
    (playPauseButtonRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.bottomMargin = topBandBottomMarginPx
      playPauseButtonRef?.layoutParams = params
    }
    (videoTimeLabelRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.bottomMargin = topBandBottomMarginPx
      videoTimeLabelRef?.layoutParams = params
    }
    (videoSelectionLabelRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.bottomMargin = topBandBottomMarginPx
      videoSelectionLabelRef?.layoutParams = params
    }

    (videoControlsBackdropRef?.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
      params.height = topBandBottomMarginPx + splitDeleteButtonSizePx + backdropTopPaddingPx - videoChromeBottomHeightPx
      videoControlsBackdropRef?.layoutParams = params
    }
    videoControlsBackdropRef?.setBackgroundColor(
      if (expanded) EditorDesignTokens.Colors.chromeBackground else Color.TRANSPARENT,
    )
  }

  /** One row for an entire layer TYPE (all texts, all stickers, or all
   *  overlays) — a single LayerRangeBarView drawing each layer's own range
   *  as a separate colored, independently-draggable segment within the
   *  shared bar. Tapping/dragging an item selects its underlying layer
   *  (see onItemSelected below) — that reuses the existing on-canvas
   *  Delete/Duplicate/Edit toolbar for delete, and this bar's own edge-drag
   *  for trim, rather than inventing separate controls for either.
   *  Long-press + vertical drag reorders same-type layers relative to each
   *  other (both their canvas z-order and this row's own overlap-painting
   *  order) — per the user's explicit "provide functionality to all
   *  layer to reorder... select and reorder by long press" request,
   *  reintroducing reordering via a different gesture than the up/down
   *  arrow buttons removed earlier this session. */
  private fun makeLayerTypeRow(layers: List<View>, color: Int, durationMs: Long): View {
    return LayerRangeBarView(this).apply {
      snapTargets = { id, segment -> trackSnapTargets(id, segment) }
      // A layer that's been split (see splitLayerSegment) contributes
      // MULTIPLE items, all sharing its own `id` but distinguished by
      // segmentIndex.
      val items = layers.flatMap { layer ->
        val segments = layerTimings[layer]?.segments ?: mutableListOf(0L..durationMs)
        val baseLabel = layerDisplayLabel(layer)
        val badge = layerTrackBadge(layer)
        segments.mapIndexed { index, segment ->
          LayerRangeBarView.Item(
            id = layer,
            rangeStartMs = segment.first,
            rangeEndMs = segment.last,
            color = color,
            // Numbered only once split — an unsplit layer's single
            // segment keeps the plain label, exactly as before.
            label = if (segments.size > 1) "$baseLabel ${index + 1}" else baseLabel,
            segmentIndex = index,
            badge = badge.first,
            badgeFillsTile = badge.second,
            badgeText = if (badge.first == null) "T" else null,
            isDimmed = isLayerUserHidden(layer),
            statusIcons = listOfNotNull(
              if (isLayerUserHidden(layer)) androidx.core.content.ContextCompat.getDrawable(this@MediaEditorActivity, R.drawable.ic_editor_eye_off) else null,
              if (isLayerLocked(layer)) androidx.core.content.ContextCompat.getDrawable(this@MediaEditorActivity, R.drawable.ic_editor_lock) else null,
            ),
          )
        }
      }
      configure(durationMs, items)
      // Locked: no trim handles on its track.
      if (layers.size == 1 && isLayerLocked(layers[0])) edgeDragEnabled = false
      onRangeChanged = { id, segmentIndex, startMs, endMs ->
        layerTimings[id]?.let { current ->
          if (segmentIndex in current.segments.indices) {
            current.segments[segmentIndex] = startMs..endMs
            updateLayerTimeVisibility()
          }
        }
      }
      onItemSelected = { id, segmentIndex ->
        selectLayer(id, showToolbar = false)
        // Set AFTER selectLayer — selectLayer itself resets this to null
        // as its own default, this overrides it with the ACTUAL segment
        // the user tapped, which is what Delete should target (see
        // deleteLayerSegment).
        selectedLayerSegmentIndex = segmentIndex
      }
      // Redirects a swipe that misses every item's edge handle into an
      // actual scroll of the shared timeline — see LayerRangeBarView's
      // own onUnhandledDragDeltaX doc for why this row must do that
      // manually (unlike mergedStripView, it has no real ancestor scroll
      // container to fall through to). Setting isUserScrubbingFilmstrip
      // BEFORE scrollBy lets filmstripScrollViewRef's own existing
      // OnScrollChangeListener pick up the settle-check scheduling
      // exactly as it already does for a direct touch-drag there.
      onUnhandledDragDeltaX = { deltaX ->
        filmstripScrollViewRef?.let { sv ->
          isUserScrubbingFilmstrip = true
          sv.scrollBy((-deltaX).toInt(), 0)
        }
      }
      onReorderSwap = { a, b ->
        swapInLayerBackingArray(a, b)
        swapLayerZOrder(a, b)
      }
      onReorderEnded = {
        commitLayerReorderUndo()
        refreshLayersPanel()
      }
      // Beat sync: trimmed / moved edges land on the nearest beat.
      onDragEnded = {
        if (beatSnapEnabled) {
          layers.forEach { snapLayerTimingToBeats(it) }
          refreshLayersPanel()
        }
      }
      // Tap a track: if the playhead is outside that segment, jump to its
      // start so the item is actually visible on the video.
      onItemTapped = tapped@{ id, segmentIndex ->
        val segment = layerTimings[id]?.segments?.getOrNull(segmentIndex) ?: return@tapped
        val now = combinedTimeForCurrentPlaybackMs()
        if (now in segment) return@tapped
        pauseVideoForToolInteraction()
        seekCombinedTimeline(segment.first)
        filmstripScrollViewRef?.scrollTo(scrollXForCombinedTimeMs(segment.first), 0)
        updateVideoTimeLabel(segment.first)
      }
    }
  }

  /** Highlights the selected layer's track (white border + white trim
   *  handles), whether it was picked on the track or on the canvas, and
   *  after rows are rebuilt. Its body then drags to move it in time. */
  private fun syncLayerTrackSelection() {
    for ((row, owner) in layerTrackRowOwners) {
      val bar = row as? LayerRangeBarView ?: continue
      if (owner === selectedLayerView) bar.setSelection(owner, selectedLayerSegmentIndex ?: 0)
      else bar.setSelection(null, null)
    }
  }

  /** Track colour by layer type — text purple, sticker amber, photo blue. */
  private fun layerTrackColor(layer: View): Int = when {
    stickerLayerViews.any { it === layer } -> EditorDesignTokens.Colors.stickerLayer
    textLayerViews.any { it === layer } -> EditorDesignTokens.Colors.textLayer
    else -> EditorDesignTokens.Colors.accent
  }

  /** Moves [row] one slot up (-1) or down (+1) among the layer rows and
   *  swaps the matching canvas stacking. Returns how far the row moves in
   *  px (positive = down), or null at the ends / next to the music row. */
  private fun moveLayerTrackRow(row: View, direction: Int): Float? {
    val stack = layerTracksStackRef ?: return null
    val index = stack.indexOfChild(row)
    val layer = layerTrackRowOwners[row] ?: return null
    if (index < 0) return null
    val neighbor = stack.getChildAt(index + direction) ?: return null
    val neighborLayer = layerTrackRowOwners[neighbor] ?: return null
    // Move the NEIGHBOR, never the row under the finger — detaching the
    // touched view would cancel its gesture.
    if (pendingLayerReorderUndo == null) pendingLayerReorderUndo = captureLayerOrder()
    val params = neighbor.layoutParams
    stack.removeView(neighbor)
    stack.addView(neighbor, index, params)
    swapInLayerBackingArray(layer, neighborLayer)
    swapLayerZOrder(layer, neighborLayer)
    row.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    val pitch = row.height + ((row.layoutParams as? ViewGroup.MarginLayoutParams)?.topMargin ?: 0)
    // Keep the dragged row in view when there are more rows than fit —
    // the list scrolls along with it. Layout hasn't run yet, so compute
    // the row's new top from its index.
    var scrolled = 0
    (layerTracksScrollViewRef as? ScrollView)?.let { sv ->
      val newTop = stack.top + (index + direction) * pitch
      val newBottom = newTop + pitch
      val before = sv.scrollY
      val maxScroll = maxOf(0, stack.height - sv.height)
      var target = before
      if (newTop < before) target = newTop
      if (newBottom > before + sv.height) target = newBottom - sv.height
      target = target.coerceIn(0, maxScroll)
      if (target != before) {
        sv.scrollTo(sv.scrollX, target)
        scrolled = target - before
      }
    }
    // On-screen movement = movement in the stack minus the scroll.
    return (direction * pitch - scrolled).toFloat()
  }

  /** Layer stacking + backing arrays, so a track reorder can be undone. */
  private class LayerOrderSnapshot(
    val zOrder: List<View>,
    val text: List<TextView>,
    val sticker: List<TextView>,
    val image: List<ImageView>,
  )
  private var pendingLayerReorderUndo: LayerOrderSnapshot? = null

  private fun captureLayerOrder() = LayerOrderSnapshot(
    allLayerViews(), textLayerViews.toList(), stickerLayerViews.toList(), imageOverlayLayerViews.toList(),
  )

  private fun applyLayerOrder(snapshot: LayerOrderSnapshot) {
    // Only views still on the canvas — a later delete may have removed some.
    val live = allLayerViews().toSet()
    snapshot.zOrder.filter { it in live }.forEach { it.bringToFront() }
    keepSafeAreaCoversOnTop()
    fun <T : View> restore(list: MutableList<T>, order: List<T>) {
      val kept = order.filter { v -> list.any { it === v } }
      val rest = list.filter { v -> kept.none { it === v } }
      list.clear()
      list.addAll(kept + rest)
    }
    restore(textLayerViews, snapshot.text)
    restore(stickerLayerViews, snapshot.sticker)
    restore(imageOverlayLayerViews, snapshot.image)
    refreshLayersPanel()
  }

  /** Called when a track reorder gesture ends — one undo step per drag. */
  private fun commitLayerReorderUndo() {
    val before = pendingLayerReorderUndo ?: return
    pendingLayerReorderUndo = null
    val after = captureLayerOrder()
    if (before.zOrder == after.zOrder) return
    pushUndo(undo = { applyLayerOrder(before) }, redo = { applyLayerOrder(after) })
  }

  /** Track badge by layer type — the sticker/photo itself, or null (→ "T"). */
  private fun layerTrackBadge(layer: View): Pair<Bitmap?, Boolean> {
    if (layer is ImageView) {
      val bitmap = (layer.drawable as? BitmapDrawable)?.bitmap ?: return Pair(null, true)
      return Pair(layerTrackThumbnail(bitmap), true)
    }
    val assetName = stickerLayerAssetNames[layer] ?: return Pair(null, false)
    val bitmap = StickerCatalog.bitmap(this, assetName) ?: return Pair(null, false)
    return Pair(layerTrackThumbnail(bitmap), false)
  }

  /** Small copy so redrawing a track during a drag stays cheap. */
  private fun layerTrackThumbnail(bitmap: Bitmap): Bitmap {
    val maxSide = 22f * resources.displayMetrics.density * 2
    val scale = minOf(1f, maxSide / maxOf(bitmap.width, bitmap.height, 1))
    if (scale >= 1f) return bitmap
    return Bitmap.createScaledBitmap(bitmap, maxOf(1, (bitmap.width * scale).toInt()), maxOf(1, (bitmap.height * scale).toInt()), true)
  }

  /** Reorder support (see makeLayerTypeRow's own doc) — the two views
   *  that just swapped positions during a long-press drag are always from
   *  the SAME type array (a row only ever contains one type), so trying
   *  each in turn and returning as soon as both are found is enough. */
  private fun swapInLayerBackingArray(a: View, b: View) {
    // textLayerViews/stickerLayerViews/imageOverlayLayerViews are each
    // typed to their own concrete View subtype (not a shared
    // MutableList<View>), so this can't just iterate a listOf(...) of
    // them — a small generic helper instead, tried against each in turn.
    fun <T : View> trySwap(list: MutableList<T>): Boolean {
      val idxA = list.indexOfFirst { it === a }
      val idxB = list.indexOfFirst { it === b }
      if (idxA < 0 || idxB < 0) return false
      val tmp = list[idxA]
      list[idxA] = list[idxB]
      list[idxB] = tmp
      return true
    }
    trySwap(textLayerViews) || trySwap(stickerLayerViews) || trySwap(imageOverlayLayerViews)
  }

  /** Swaps ONLY these two layers' relative canvas z-order, leaving every
   *  other layer's relative order exactly as it was — derives the
   *  CURRENT true combined order from allLayerViews() (root's own actual
   *  child order, spanning all types) rather than assuming a fixed
   *  type-priority stacking, then re-applies it via the same
   *  bringToFront()-in-sequence + keepSafeAreaCoversOnTop() pattern
   *  already used elsewhere in this file for reasserting z-order safely. */
  private fun swapLayerZOrder(a: View, b: View) {
    val order = allLayerViews().toMutableList()
    val idxA = order.indexOf(a)
    val idxB = order.indexOf(b)
    if (idxA < 0 || idxB < 0) return
    order[idxA] = b
    order[idxB] = a
    order.forEach { it.bringToFront() }
    keepSafeAreaCoversOnTop()
  }

  /** The music row — see musicOffsetMs's own doc. No reorder wiring
   *  (nothing to reorder against with only one id). Supports BOTH body-
   *  drag (reposition where the track starts on the timeline, only while
   *  unsplit — see allowBodyDrag below) and edge-drag (trim each
   *  segment's own start/end), same as every other layer row — per the
   *  user's explicit "same leading/trailing drag handles on music too"
   *  request. The two never conflict: LayerRangeBarView's own hit-testing
   *  already checks the edge zones before falling through to body-drag
   *  (DragTarget.MOVE) for the middle region.
   *  Segment-based, mirroring makeLayerTypeRow's own per-segment Item
   *  list — per the user's explicit "same split music layer also"
   *  request. Only ever ONE underlying id (musicProxyView, music has no
   *  per-instance views like text/sticker do), but that id can now
   *  contribute MULTIPLE items once split, exactly like a layer's own
   *  segments. */
  private fun makeMusicRow(durationMs: Long): View {
    // 500L matches LayerRangeBarView's own private minRangeDurationMs —
    // not visible from here, so kept as a literal with this note.
    val minKeptDurationMs = 500L
    val fallbackKeptMs = (musicTrimEndMs - musicTrimStartMs).coerceAtLeast(minKeptDurationMs)
    val fallbackStartMs = musicOffsetMs.coerceIn(0, durationMs)
    val segments = musicSegments.ifEmpty { listOf(fallbackStartMs..(fallbackStartMs + fallbackKeptMs)) }
    val baseLabel = selectedMusicTrack?.title ?: "Music"
    return LayerRangeBarView(this).apply {
      snapTargets = { id, segment -> trackSnapTargets(id, segment) }
      // Body-drag (reposition the WHOLE track) only stays meaningful
      // before any split exists — once there are multiple pieces,
      // dragging one segment's body is ambiguous with scrolling the
      // shared timeline, same reasoning that already removed body-drag
      // from text/sticker/overlay rows entirely.
      allowBodyDrag = segments.size <= 1
      edgeDragEnabled = true
      configure(
        durationMs,
        segments.mapIndexed { index, segment ->
          LayerRangeBarView.Item(
            id = musicProxyView,
            rangeStartMs = segment.first,
            rangeEndMs = segment.last,
            color = EditorDesignTokens.Colors.musicLayer,
            // Numbered only once split — an unsplit track keeps the plain
            // label, exactly as before.
            label = if (segments.size > 1) "$baseLabel ${index + 1}" else baseLabel,
            segmentIndex = index,
            badgeText = "♪",
            markers = combinedBeatTimesMs(),
          )
        },
      )
      onRangeChanged = { _, segmentIndex, newStartMs, newEndMs ->
        if (segmentIndex in musicSegments.indices) {
          musicSegments[segmentIndex] = newStartMs..newEndMs
          // segments[0]'s own start IS musicOffsetMs — several other call
          // sites (export, updateMusicPlaybackWindow) still read it
          // directly.
          if (segmentIndex == 0) musicOffsetMs = newStartMs
          updateMusicPlaybackWindow()
        }
      }
      onItemSelected = { _, segmentIndex ->
        // Music becomes the Split/Delete target — clear every other
        // selection so they can't both claim the next scissors/trash tap,
        // mirroring mergedStripView.onItemSelected's identical clearing.
        deselectLayer()
        videoTrimViewRef?.clearSegmentSelection()
        selectedMergedClipUri = null
        selectedMergedClipSegmentIndex = null
        selectedMusicSegmentIndex = segmentIndex
      }
      onUnhandledDragDeltaX = { deltaX ->
        filmstripScrollViewRef?.let { sv ->
          isUserScrubbingFilmstrip = true
          sv.scrollBy((-deltaX).toInt(), 0)
        }
      }
      // Music never sets onReorderSwap (every segment shares the SAME id
      // — there's nothing to reorder against), so reordering is disabled;
      // long-press still selects the tapped segment (see
      // LayerRangeBarView.beginReorder's own doc) exactly like every
      // other row. Removing the whole track happens via
      // deleteMusicSegment once only one segment is left, not directly
      // from long-press.
      reorderEnabled = false
    }
  }

  /** Hides/shows every layer based on whether the current playhead falls
   *  within its own time range (combined with its manual eye-toggle
   *  state) — called from the video preview's periodic position poll, and
   *  immediately after any range/order/visibility change so there's never
   *  a stale frame waiting for the next poll tick. Uses `.alpha`, not
   *  `View.GONE` — that flag already means "deleted" (see deleteLayer),
   *  and reusing it here would make the two states indistinguishable. */
  private fun updateLayerTimeVisibility() {
    // combinedTimeForCurrentPlaybackMs(), not the player's own raw local
    // position — layers now extend across merged clips too (see
    // combinedLayerDurationMs's own doc), and the player's local position
    // resets to 0 once the playlist advances into a merged clip, which
    // would make every layer's range comparison meaningless during
    // merged-clip playback.
    val positionMs = combinedTimeForCurrentPlaybackMs()
    for (layer in allLayerViews()) {
      val timing = layerTimings[layer] ?: continue
      val inRange = timing.segments.any { positionMs in it }
      var targetAlpha = if (inRange && !timing.isManuallyHidden) 1f else 0f
      // Text animations: fade / pop / typewriter / slide at each piece's
      // start and end (same math as the export).
      if (layer in textLayerViews && layer !in stickerLayerViews) {
        val anim = TextAnimation.state(positionMs, timing.segments, timing.anim)
        targetAlpha *= anim.alpha
        applyTextAnimationPreview(layer, anim)
      }
      // Skip the redundant invalidate/redraw when nothing actually
      // changed — now called every ~16ms (was 250ms, see
      // TIMELINE_POLL_INTERVAL_MS's own doc), so avoiding needless
      // per-frame work here matters more than it used to.
      if (layer.alpha != targetAlpha) layer.alpha = targetAlpha
    }
  }

  /** Starts/pauses the music player as playback crosses any of the music
   *  row's own [musicSegments] windows on the combined timeline — per the
   *  user's explicit music-as-a-layer request, the track no longer just
   *  always starts at time 0, and (per the later "same split music layer
   *  also" request) can now have multiple such windows with gaps between
   *  them. Only manages the TRANSITION edges (start on entry, pause on
   *  exit) rather than continuously re-syncing every tick — matches the
   *  existing lightweight preview-only rigor already used for music
   *  elsewhere in this file (no frame-accurate re-seek loop). The SOURCE
   *  file position is always anchored to segments[0]'s own start (NOT
   *  whichever segment is currently active), so the song's own internal
   *  pacing stays continuous straight through a gap — entering a LATER
   *  segment resumes wherever the song would already be, rather than
   *  restarting from that segment's own beginning. */
  private fun updateMusicPlaybackWindow() {
    val player = musicPlayer ?: return
    if (selectedMusicTrack == null) return
    if (musicTrimEndMs <= musicTrimStartMs) return
    val anchorMs = musicSegments.firstOrNull()?.first ?: return
    val combinedMs = combinedTimeForCurrentPlaybackMs()
    val inWindow = musicSegments.any { combinedMs in it }
    // The story badge's pause must stick — this runs every playback tick
    // and would otherwise restart the music straight away.
    if (isStoryMusicPausedByUser) {
      if (player.isPlaying) player.pause()
      return
    }
    // playWhenReady (intent), not isPlaying: right after a seek the player
    // is buffering (isPlaying false), and treating that as "not playing"
    // re-seeked it every tick, so a later piece of split music never
    // started. Same for the video: it's briefly buffering when it jumps
    // over a removed part.
    if (exoPlayer?.playWhenReady == true && inWindow) {
      if (!player.playWhenReady || player.playbackState == androidx.media3.common.Player.STATE_ENDED) {
        player.seekTo(musicTrimStartMs + (combinedMs - anchorMs))
        player.play()
      }
    } else if (player.playWhenReady) {
      player.pause()
    }
  }

  /** Called every time video playback loops back to its own start (single-
   *  clip gap-skip restart, multi-clip REPEAT_MODE_ALL playlist wrap) —
   *  per the user's explicit "as video start playing in loop again then
   *  the music should be reset and start again, should not be play
   *  continuously" request. Without this, the music player just runs on
   *  its own continuous clock once started (updateMusicPlaybackWindow
   *  above only manages START/STOP transitions, never re-syncs mid-
   *  flight), so across a video loop it would keep advancing toward ITS
   *  OWN natural end instead of restarting alongside the video. */
  private fun resetMusicToLoopStart() {
    val player = musicPlayer ?: return
    if (selectedMusicTrack == null) return
    player.pause()
    player.seekTo(musicTrimStartMs)
    // Reuses the normal entry/exit decision (is time-0 actually inside a
    // music segment?) rather than assuming it should always resume — same
    // call the per-tick poll loop already makes.
    updateMusicPlaybackWindow()
  }

  /** Splits the music row's segment currently under the playhead — the
   *  music counterpart to splitLayerSegment/splitActiveMergedClipSegment.
   *  Per the user's explicit "same split music layer also" request. */
  private fun splitMusicSegment(index: Int) {
    if (index !in musicSegments.indices) return
    val segment = musicSegments[index]
    val splitPointMs = combinedTimeForCurrentPlaybackMs()
    val minSegmentMs = 500L
    // Silently refuses (matching this file's own "no distinct reject
    // haptic" convention — see splitActiveMergedClipSegment/
    // deleteActiveMergedClipSegment) when too close to either edge to
    // leave both halves >= minSegmentMs.
    if (splitPointMs - segment.first < minSegmentMs || segment.last - splitPointMs < minSegmentMs) return
    val oldSegments = musicSegments.toList()
    musicSegments[index] = segment.first..splitPointMs
    musicSegments.add(index + 1, splitPointMs..segment.last)
    val newSegments = musicSegments.toList()
    root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    updateMusicPlaybackWindow()
    refreshLayersPanel()
    pushUndo(
      undo = {
        musicSegments.clear(); musicSegments.addAll(oldSegments)
        updateMusicPlaybackWindow(); refreshLayersPanel()
      },
      redo = {
        musicSegments.clear(); musicSegments.addAll(newSegments)
        updateMusicPlaybackWindow(); refreshLayersPanel()
      },
    )
  }

  /** Deletes one segment of the music row — targets whichever segment was
   *  last TAPPED (selectedMusicSegmentIndex), falling back to "whichever
   *  segment contains the playhead" otherwise, mirroring
   *  deleteLayerSegment/deleteActiveMergedClipSegment. Refuses (matching
   *  Silently refuses (matching this file's own "no distinct reject
   *  haptic" convention — see deleteActiveMergedClipSegment) to delete
   *  the music's only remaining segment — same "nothing left to preview/
   *  export" guard every other segment-delete in this file uses. */
  private fun deleteMusicSegment(index: Int) {
    if (index !in musicSegments.indices) return
    // Same "last remaining segment" handoff as deleteLayerSegment: with
    // only one segment left there's nothing to split it FROM, so this is
    // really a request to remove the whole track — go through the
    // confirm dialog instead of silently no-oping.
    if (musicSegments.size <= 1) {
      confirmDeleteMusicLayer()
      return
    }
    val oldSegments = musicSegments.toList()
    musicSegments.removeAt(index)
    val newSegments = musicSegments.toList()
    if (selectedMusicSegmentIndex == index) selectedMusicSegmentIndex = null
    root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    updateMusicPlaybackWindow()
    refreshLayersPanel()
    pushUndo(
      undo = {
        musicSegments.clear(); musicSegments.addAll(oldSegments)
        updateMusicPlaybackWindow(); refreshLayersPanel()
      },
      redo = {
        musicSegments.clear(); musicSegments.addAll(newSegments)
        updateMusicPlaybackWindow(); refreshLayersPanel()
      },
    )
  }

  // MARK: - Layer selection + on-canvas action toolbar (Delete/Duplicate/Edit)

  /** Border width shared by every selection-border overlay (layers + the
   *  main canvas) — see updateCanvasSelectionBorder's own doc. */
  // Thin (was 2dp) — the user found the selected layer's border too heavy.
  private val selectionBorderWidthPx get() = (1f * resources.displayMetrics.density).toInt().coerceAtLeast(1)

  /** Yellow border on the main video/image canvas ONLY while no text/
   *  sticker/overlay layer is selected — per the user's explicit "only
   *  show yellow color border over main video layer, and remaining all
   *  layer should display white border... only when its touch" request.
   *  Exactly one thing on screen ever reads as "the current tap target":
   *  the canvas by default, or whichever layer was just tapped (its own
   *  white border, set directly in selectLayer/deselectLayer). Uses
   *  `.foreground` (drawn on top, API 23+) rather than `.background` —
   *  the canvas view's background IS the actual photo/video content, a
   *  background swap would hide it entirely. */
  /** The canvas no longer gets a yellow border (removed per the user's
   *  request); only a tapped layer shows its white selection border. */
  private fun updateCanvasSelectionBorder() {
    gestureCoordinator?.boundedLayer?.foreground = null
  }

  /** `showToolbar = false` — selected from its timeline track: highlight
   *  it (canvas border, track, split/delete target) without the floating
   *  Delete/Duplicate/Edit/Style toolbar, which only appears when the
   *  element itself is tapped on the video (user's request). */
  private fun selectLayer(target: View, showToolbar: Boolean = true) {
    // Another layer picked while the Animation sheet is open: finish
    // (keep) that edit first — the sheet belongs to the previous layer.
    if (textAnimationSheetRef != null && target !== selectedLayerView) textAnimationSheetRef?.onClose?.invoke(true)
    // Clear the PREVIOUS selection's own white border first, in case
    // selection switches directly from one layer to another without going
    // through deselectLayer in between (e.g. tapping a different layer
    // while one is already selected).
    selectedLayerView?.foreground = null
    selectedLayerView = target
    target.foreground = GradientDrawable().apply { setStroke(selectionBorderWidthPx, Color.WHITE) }
    updateCanvasSelectionBorder()
    // Reset here, not just in deselectLayer — this function is ALSO the
    // direct-switch path (tapping a different layer while one is already
    // selected), which never calls deselectLayer at all.
    // makeLayerTypeRow's onItemSelected sets this to the ACTUAL tapped
    // segment right after calling selectLayer, so this default only
    // sticks when selection came from somewhere else (a canvas tap,
    // duplicate, etc.).
    selectedLayerSegmentIndex = null
    // A layer is now the delete target — clear any stale white
    // selected-segment border still showing on the video's own row or a
    // merged clip's own row.
    videoTrimViewRef?.clearSegmentSelection()
    selectedMergedClipUri = null
    selectedMergedClipSegmentIndex = null
    selectedMusicSegmentIndex = null
    gestureCoordinator?.let {
      // Locks the base canvas (image/video — boundedLayer is always
      // exactly that view) out of pan/pinch/rotate while a text/sticker/
      // overlay layer is selected, per the user's explicit request —
      // manipulating a newly-added element should never also move/zoom/
      // rotate the photo underneath.
      it.interactionLockedLayer = it.boundedLayer
      // Instagram-style: once selected, pan/pinch/rotate anywhere on
      // screen keeps controlling THIS layer, even if fingers land outside
      // its current (possibly tiny) bounds — per the user's explicit
      // request ("i want same like instagram"). Without this, pinching a
      // shrunk-down layer easily misses its small hit target and (since
      // the canvas is now locked out too) resolves to nothing at all.
      it.fallbackTarget = target
    }
    // Locked (or hidden) layer: selectable so it can be unlocked, but it
    // can't be moved (see the coordinator's isLayerTransformLocked) and
    // gets no Delete/Duplicate/Edit toolbar.
    if (showToolbar && isLayerLocked(target)) {
      layerActionToolbarRef?.let { root.removeView(it) }
      layerActionToolbarRef = null
      android.widget.Toast.makeText(this, "Layer is locked", android.widget.Toast.LENGTH_SHORT).show()
    } else if (showToolbar && !isLayerUserHidden(target)) {
      showLayerActionToolbar()
    } else {
      layerActionToolbarRef?.let { root.removeView(it) }
      layerActionToolbarRef = null
    }
    updateStickerDeleteBadge()
  }

  private fun deselectLayer() {
    textAnimationSheetRef?.onClose?.invoke(true)
    if (selectedImageEditorTab == ImageEditorTab.TEXT_STYLE) {
      selectedImageEditorTab = ImageEditorTab.TOOLS
      updateImageEditorUI(animated = true)
    }
    selectedLayerView?.foreground = null
    selectedLayerView = null
    selectedLayerSegmentIndex = null
    updateCanvasSelectionBorder()
    gestureCoordinator?.let {
      it.interactionLockedLayer = null
      it.fallbackTarget = null
    }
    layerActionToolbarRef?.let { root.removeView(it) }
    layerActionToolbarRef = null
    updateStickerDeleteBadge()
  }

  // MARK: Story sticker ✕

  private var stickerDeleteBadgeRef: FrameLayout? = null

  /** Story mode: a small ✕ on the selected sticker's top-left corner that
   *  removes it (undoable). Follows the sticker while it's dragged,
   *  pinched or rotated; hidden while a tool panel shows the picture as a
   *  snapshot, and for locked/hidden layers. */
  private fun updateStickerDeleteBadge() {
    val target = selectedLayerView
    val show = isStoryMode && target != null && target in stickerLayerViews &&
      target.visibility == View.VISIBLE && !isFilterStageActive &&
      !isLayerLocked(target) && !isLayerUserHidden(target) && target.width > 0
    if (!show || target == null) {
      stickerDeleteBadgeRef?.visibility = View.GONE
      return
    }
    val density = resources.displayMetrics.density
    val sizePx = (26f * density).toInt()
    val badge = stickerDeleteBadgeRef ?: FrameLayout(this).apply {
      background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.argb(200, 0, 0, 0))
        setStroke((1.5f * density).toInt().coerceAtLeast(1), Color.WHITE)
      }
      elevation = 6f * density
      contentDescription = "Remove sticker"
      addView(
        EditorIconView(this@MediaEditorActivity, EditorIcon.CLOSE).apply { iconTint = Color.WHITE },
        FrameLayout.LayoutParams((12f * density).toInt(), (12f * density).toInt(), Gravity.CENTER),
      )
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        didTapDeleteSelectedLayer()
      }
      root.addView(this, FrameLayout.LayoutParams(sizePx, sizePx, Gravity.TOP or Gravity.START))
    }.also { stickerDeleteBadgeRef = it }
    // The sticker's own top-left corner, through its move/scale/rotate.
    val corner = floatArrayOf(0f, 0f)
    target.matrix.mapPoints(corner)
    badge.translationX = target.left + corner[0] - sizePx / 2f
    badge.translationY = target.top + corner[1] - sizePx / 2f
    if (badge.visibility != View.VISIBLE) {
      badge.visibility = View.VISIBLE
      badge.bringToFront()
      // Chrome (top bar, rail, panels) stays above the badge.
      storyRailRef?.bringToFront()
      storyMusicBadgeRef?.bringToFront()
      topBarRef?.bringToFront()
    }
  }

  /** Text/sticker layers (and their duplicates) are added to `root` at
   *  runtime, AFTER the safe-area covers — since `addView` appends to the
   *  top of the z-order, a newly-added layer would otherwise render ON TOP
   *  of the covers instead of being hidden behind them if dragged into
   *  those edge strips. Called after every new layer (and the layer
   *  toolbar) is added to keep the covers pinned at the very top. */
  private fun keepSafeAreaCoversOnTop() {
    topSafeAreaCoverRef?.bringToFront()
    bottomSafeAreaCoverRef?.bringToFront()
    canvasGutterTopRef?.bringToFront()
    canvasGutterBottomRef?.bringToFront()
    canvasGutterLeftRef?.bringToFront()
    canvasGutterRightRef?.bringToFront()
    if (isFilterStageActive) {
      // The fitted picture (and the views moving with it) sit above the
      // gutters, below the tray and panels.
      filterStageRef?.bringToFront()
      filterStageTrackingViews().filter { it.visibility == View.VISIBLE }.forEach { it.bringToFront() }
      // The Tune value pill / setting list float over the picture's top area.
      tunePillRef?.takeIf { it.visibility == View.VISIBLE }?.bringToFront()
      tuneListRef?.takeIf { it.visibility == View.VISIBLE }?.bringToFront()
      scheduleFilterStageRefresh()
    }
    // bringToFront() is cumulative — the LAST call in this function is the
    // FRONTMOST view. Order below (back to front): canvas gutters/safe-
    // area covers, then the video-controls band (backdrop/scrubber/
    // buttons), then the bottom tray, then every slide-up panel (so an
    // OPEN panel always visually covers the video-controls band and tray
    // beneath it — user-reported bug, screenshot: musicPanelRef used to
    // sit BEHIND videoControlsBackdropRef since that block used to run
    // AFTER topBarRef/bottomTrayRef/the panels), then topBarRef LAST so
    // Cancel/Undo/Redo/Done stay on top and tappable even while a panel
    // is open.
    // This row floats directly over the video's own bottom edge (see
    // videoControlsBackdropRef's own doc) rather than in dedicated space
    // below the canvas, so a large enough text/sticker/overlay layer can
    // geometrically reach into the same area — keep the scrim + controls
    // above any of those. Backdrop first so the buttons/scrubber/layer
    // tracks stay in front of it, not the other way around.
    videoControlsBackdropRef?.bringToFront()
    layerTracksScrollViewRef?.bringToFront()
    layersAreaCollapseButtonRef?.bringToFront()
    addLayerButtonRef?.bringToFront()
    videoCompareButtonRef?.bringToFront()
    clipTransitionButtonRef?.bringToFront()
    textAnimationButtonRef?.bringToFront()
    layerHideButtonRef?.bringToFront()
    layerLockButtonRef?.bringToFront()
    // Also above the (opaque once layers exist) backdrop.
    videoTimeLabelRef?.bringToFront()
    videoSelectionLabelRef?.bringToFront()
    clipSpeedButtonRef?.bringToFront()
    clipVolumeButtonRef?.bringToFront()
    playPauseButtonRef?.bringToFront()
    // filmstripScrollViewRef/filmstripPlayheadRef are BOTH nested inside
    // filmstripBandRef, not direct children of `root` — bringing THEM to
    // front only reorders within that small band, with zero effect on
    // the band's own z-order among root's OTHER children (like
    // videoControlsBackdropRef, right above). That gap let the backdrop
    // — correctly re-fronted above ON-CANVAS layers, but ALSO ending up
    // above this whole band as an unintended side effect — cover the
    // entire video row once it turned opaque (once any layer exists),
    // exactly matching the "video row blank after adding a layer" report.
    // Bringing the BAND itself to front fixes this at the root level;
    // fronting the two children afterward preserves their own internal
    // order (playhead above the scroll view) within the band.
    filmstripBandRef?.bringToFront()
    filmstripScrollViewRef?.bringToFront()
    filmstripPlayheadRef?.bringToFront()
    // A direct child of `root` (unlike filmstripPlayheadRef, nested in
    // filmstripBandRef) — must come after layerTracksScrollViewRef's own
    // bringToFront above so it renders above the tracks it overlays.
    layerTracksPlayheadRef?.bringToFront()
    splitSegmentButtonRef?.bringToFront()
    deleteSegmentButtonRef?.bringToFront()
    bottomTrayRef?.bringToFront()
    lookToolsBarRef?.bringToFront()
    effectPanelRef?.bringToFront()
    editPanelRef?.bringToFront()
    stickersPanelRef?.bringToFront()
    drawPanelRef?.bringToFront()
    textStylePanelRef?.bringToFront()
    toolsGridPanelRef?.bringToFront()
    musicPanelRef?.bringToFront()
    // The layer action bar sits in the gap above the tray/panels, over the
    // black canvas gutters — it must be above those to be visible.
    layerActionToolbarRef?.bringToFront()
    // Story mode's floating icon rail is a direct child of `root`, added
    // after the panels above — needs its own re-front for the same reason
    // they do, positioned just behind topBarRef.
    storyRailRef?.bringToFront()
    // Same reasoning as storyRailRef immediately above — another direct
    // child of `root` added after the panels.
    storyMusicBadgeRef?.bringToFront()
    // Fixes a user-reported bug: a big enough overlay/text/sticker layer
    // (added to `root` at runtime, AFTER these chrome pieces) rendered ON
    // TOP of them, hiding Cancel/Undo/Redo/Done entirely — topBarRef must
    // be the LAST call so it's frontmost no matter what else this
    // function just re-ordered above it.
    topBarRef?.bringToFront()
  }

  private fun showLayerActionToolbar() {
    layerActionToolbarRef?.let { root.removeView(it) }
    val density = resources.displayMetrics.density

    // Plain text labels, not icons — per the user's explicit request
    // (the hand-drawn icon set read as too custom/odd for a 3-item
    // action row). "Delete" is tinted danger-red, the same destructive-
    // action convention already used by confirmDeleteLayer's alert.
    fun actionButton(label: String, isDestructive: Boolean, onClick: () -> Unit): View = TextView(this).apply {
      text = label
      textSize = 13f
      setTextColor(if (isDestructive) DESTRUCTIVE_RED else EditorDesignTokens.Colors.textPrimary)
      setPadding((14f * density).toInt(), (10f * density).toInt(), (14f * density).toInt(), (10f * density).toInt())
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        onClick()
      }
    }

    fun divider(): View = View(this).apply {
      setBackgroundColor(EditorDesignTokens.Colors.divider)
    }
    val dividerWidthPx = (1f * density).toInt()
    val dividerVerticalMarginPx = (8f * density).toInt()

    val row = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      background = GradientDrawable().apply {
        cornerRadius = 20f * density
        setColor(EditorDesignTokens.Colors.panelBackground)
      }
      addView(actionButton("Delete", isDestructive = true) { didTapDeleteSelectedLayer() })
      addView(divider(), LinearLayout.LayoutParams(dividerWidthPx, ViewGroup.LayoutParams.MATCH_PARENT).apply {
        topMargin = dividerVerticalMarginPx
        bottomMargin = dividerVerticalMarginPx
      })
      addView(actionButton("Duplicate", isDestructive = false) { didTapDuplicateSelectedLayer() })
      addView(divider(), LinearLayout.LayoutParams(dividerWidthPx, ViewGroup.LayoutParams.MATCH_PARENT).apply {
        topMargin = dividerVerticalMarginPx
        bottomMargin = dividerVerticalMarginPx
      })
      addView(actionButton("Edit", isDestructive = false) { didTapEditSelectedLayer() })
      if (selectedLayerView?.let { styleSnapshot(it) } != null) {
        addView(divider(), LinearLayout.LayoutParams(dividerWidthPx, ViewGroup.LayoutParams.MATCH_PARENT).apply {
          topMargin = dividerVerticalMarginPx
          bottomMargin = dividerVerticalMarginPx
        })
        addView(actionButton("Style", isDestructive = false) { didTapStyleSelectedLayer() })
      }
      // Story videos have no layer tracks — text animations are picked here
      // (In plays as the story starts, Out as it ends, every loop). Not for
      // photo stories: they export as a single still image.
      val selected = selectedLayerView
      if (isStoryMode && mediaType != "image" && selected != null && selected in textLayerViews && selected !in stickerLayerViews) {
        addView(divider(), LinearLayout.LayoutParams(dividerWidthPx, ViewGroup.LayoutParams.MATCH_PARENT).apply {
          topMargin = dividerVerticalMarginPx
          bottomMargin = dividerVerticalMarginPx
        })
        addView(actionButton("Animate", isDestructive = false) { showTextAnimationMenu() })
      }
    }
    root.addView(row, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    layerActionToolbarRef = row
    repositionLayerActionToolbar()
    keepSafeAreaCoversOnTop()
  }

  /** The layer action bar always sits in one fixed place — centred just
   *  above the bottom editing tools — never over the layer or anywhere
   *  else, per the user's request. While a panel is open it's hidden
   *  rather than moved. Same on iOS. */
  private fun repositionLayerActionToolbar() {
    if (selectedLayerView == null) return
    val toolbar = layerActionToolbarRef ?: return
    toolbar.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
    val gapPx = 10f * resources.displayMetrics.density
    val left = ((root.width - toolbar.measuredWidth) / 2f).toInt().coerceAtLeast(0)
    val top = (layerToolbarBottomPx() - toolbar.measuredHeight - gapPx).toInt().coerceAtLeast(0)
    // Only touch layout when the spot actually changed (a new LayoutParams
    // always re-lays out the whole screen).
    val current = toolbar.layoutParams as? FrameLayout.LayoutParams
    if (current == null || current.leftMargin != left || current.topMargin != top) {
      toolbar.layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        leftMargin = left
        topMargin = top
      }
    }
    toolbar.visibility = if (selectedImageEditorTab == ImageEditorTab.TOOLS) View.VISIBLE else View.INVISIBLE
  }

  /** Top edge of the bottom editing tools (story mode has none: the
   *  screen's safe bottom). */
  private fun layerToolbarBottomPx(): Float {
    val tray = bottomTrayRef
    if (!isStoryMode && tray != null && tray.visibility == View.VISIBLE && tray.parent != null) {
      return tray.top + tray.translationY
    }
    return (root.height - if (isStoryMode) storyBottomInsetPx() else navigationBarHeightPx).toFloat() -
      8f * resources.displayMetrics.density
  }

  private fun didTapDeleteSelectedLayer() {
    val target = selectedLayerView ?: return
    deselectLayer()
    deleteLayer(target)
  }

  private fun didTapDuplicateSelectedLayer() {
    val selected = selectedLayerView ?: return
    if (!canAddLayer()) return
    if (selected is ImageView) {
      duplicateImageOverlayLayer(selected)
    } else if (selected is TextView) {
      duplicateTextOrStickerLayer(selected)
    }
  }

  private fun duplicateTextOrStickerLayer(source: TextView) {
    val density = resources.displayMetrics.density
    val offsetPx = 20f * density
    val isSticker = stickerLayerViews.contains(source)
    val clone = (if (source is StyledTextLayerView) StyledTextLayerView(this) else TextView(this)).apply {
      translationX = source.translationX + offsetPx
      translationY = source.translationY + offsetPx
      scaleX = source.scaleX
      scaleY = source.scaleY
      rotation = source.rotation
    }
    val locationState = locationLayerStates[source]
    if (locationState != null) {
      applyLocationSticker(clone, locationState)
    } else if (isSticker) {
      stickerStyles[source]?.let { stickerStyles[clone] = it }
      stickerLayerAssetNames[source]?.let { applyStickerImage(clone, it) }
    } else if (source is StyledTextLayerView && clone is StyledTextLayerView) {
      clone.applyText(source.text?.toString().orEmpty(), source.layerStyle)
    }
    root.addView(
      clone,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER),
    )
    root.setClipRect(clone, canvasBoxRect)
    if (isSticker) stickerLayerViews.add(clone) else textLayerViews.add(clone)
    gestureCoordinator?.addLayer(clone)
    selectLayer(clone)
    keepSafeAreaCoversOnTop()
    copyOrRegisterLayerTiming(source, clone)
    pushUndo(
      undo = {
        clone.visibility = View.GONE
        if (selectedLayerView === clone) deselectLayer()
        refreshLayersPanel()
      },
      redo = { clone.visibility = View.VISIBLE; refreshLayersPanel() },
    )
  }

  private fun duplicateImageOverlayLayer(source: ImageView) {
    val density = resources.displayMetrics.density
    val offsetPx = 20f * density
    val clone = ImageView(this).apply {
      setImageDrawable(source.drawable)
      overlayStates[source]?.let { state -> applyOverlay(this, state.base, state.source, state.style, state.strokes) }
      scaleType = ImageView.ScaleType.FIT_CENTER
      translationX = source.translationX + offsetPx
      translationY = source.translationY + offsetPx
      scaleX = source.scaleX
      scaleY = source.scaleY
      rotation = source.rotation
    }
    root.addView(
      clone,
      FrameLayout.LayoutParams(source.layoutParams.width, source.layoutParams.height, Gravity.CENTER),
    )
    root.setClipRect(clone, canvasBoxRect)
    imageOverlayLayerViews.add(clone)
    gestureCoordinator?.addLayer(clone)
    selectLayer(clone)
    keepSafeAreaCoversOnTop()
    copyOrRegisterLayerTiming(source, clone)
    pushUndo(
      undo = {
        clone.visibility = View.GONE
        if (selectedLayerView === clone) deselectLayer()
        refreshLayersPanel()
      },
      redo = { clone.visibility = View.VISIBLE; refreshLayersPanel() },
    )
  }

  private fun didTapEditSelectedLayer() {
    val selected = selectedLayerView ?: return
    if (selected is ImageView) {
      presentImageOverlayPickerForEdit(selected)
    } else if (selected is TextView) {
      val info = locationLayerStates[selected]
      if (info != null && info.kind != "location") {
        presentInfoStickerEditor(info.kind, editing = selected)
      } else if (info != null) {
        presentLocationPicker(editing = selected)
      } else if (stickerLayerViews.contains(selected)) {
        showStickerPickerForEdit(selected)
      } else {
        presentTextEntryOverlay(existing = selected)
      }
    }
  }

  /** Reopens the same image-grid Stickers panel used for adding one,
   *  rather than a standalone dialog — `editingStickerLayer` (checked by
   *  didTapStickerGridItem) makes the next tap replace this layer's image
   *  instead of adding a new layer. Replaces the old AlertDialog (which
   *  listed emoji glyphs as text) now that stickers are images. */
  private fun showStickerPickerForEdit(target: TextView) {
    editingStickerLayer = target
    selectedImageEditorTab = ImageEditorTab.STICKERS
    updateImageEditorUI(animated = true)
  }

  private fun updateStickerLayer(target: TextView, assetName: String) {
    val oldAssetName = stickerLayerAssetNames[target]
    if (!applyStickerImage(target, assetName)) return
    if (selectedLayerView === target) repositionLayerActionToolbar()
    pushUndo(
      undo = { oldAssetName?.let { applyStickerImage(target, it) } },
      redo = { applyStickerImage(target, assetName) },
    )
  }

  // ── Style panel (text layers, stickers and overlays) ─────────────────

  private fun canStyleSticker(view: View): Boolean =
    view is TextView && stickerLayerAssetNames.containsKey(view) && !locationLayerStates.containsKey(view)

  private fun styleSnapshot(view: View): LayerStyleSnapshot? = when {
    view is ImageView -> overlayStates[view]?.let { LayerStyleSnapshot.Overlay(it.style, it.strokes) }
    view is StyledTextLayerView -> LayerStyleSnapshot.Text(view.layerStyle)
    view is TextView && canStyleSticker(view) -> LayerStyleSnapshot.Sticker(stickerStyles[view] ?: StickerStyle())
    else -> null
  }

  private fun applyStyleSnapshot(snapshot: LayerStyleSnapshot, target: View) {
    when (snapshot) {
      is LayerStyleSnapshot.Text -> (target as? StyledTextLayerView)?.applyText(target.text?.toString().orEmpty(), snapshot.style)
      is LayerStyleSnapshot.Sticker -> (target as? TextView)?.let { applyStickerStyle(it, snapshot.style) }
      is LayerStyleSnapshot.Overlay -> (target as? ImageView)?.let { view ->
        overlayStates[view]?.let { applyOverlay(view, it.base, it.source, snapshot.style, snapshot.strokes) }
      }
    }
    refreshAfterTextLayerChange(target)
    if (textStyleTarget === target) syncTextStyleControls()
  }

  private fun applyStickerStyle(target: TextView, style: StickerStyle) {
    stickerStyles[target] = style
    stickerLayerAssetNames[target]?.let { applyStickerImage(target, it) }
  }

  private fun styleTools(view: View?): List<TextStyleTool> = when {
    view is ImageView -> TextStyleTool.overlayTools
    view is StyledTextLayerView || view == null -> TextStyleTool.textTools
    else -> TextStyleTool.stickerTools
  }

  /** Slider rows for [tool] on the current target, in display units (percent). */
  private fun textStyleSliderSpecs(tool: TextStyleTool): List<TextStyleSliderSpec> {
    val target = textStyleTarget ?: return emptyList()
    if (target is ImageView) {
      val state = overlayStates[target] ?: return emptyList()
      fun spec(title: String, min: Int, max: Int, default: Int, get: (OverlayStyle) -> Float, set: (OverlayStyle, Float) -> OverlayStyle) =
        TextStyleSliderSpec(title, min, max, default, { get(state.style) * 100 }) { value ->
          setOverlayStyle(target, set(state.style, value / 100f))
        }
      return when (tool) {
        TextStyleTool.FILTERS -> if (state.style.filter == PhotoFilter.ORIGINAL) emptyList()
          else listOf(spec("Strength", 0, 100, 100, { it.filterStrength }) { s, v -> s.copy(filterStrength = v) })
        TextStyleTool.LIGHT -> listOf(
          spec("Brightness", -100, 100, 0, { it.brightness }) { s, v -> s.copy(brightness = v) },
          spec("Contrast", -100, 100, 0, { it.contrast }) { s, v -> s.copy(contrast = v) },
        )
        TextStyleTool.COLOR -> listOf(
          spec("Saturation", -100, 100, 0, { it.saturation }) { s, v -> s.copy(saturation = v) },
          spec("Warmth", -100, 100, 0, { it.warmth }) { s, v -> s.copy(warmth = v) },
        )
        TextStyleTool.OPACITY -> listOf(spec("Opacity", 10, 100, 100, { it.opacity }) { s, v -> s.copy(opacity = v) })
        TextStyleTool.BORDER -> listOf(spec("Width", 0, 100, 0, { it.border }) { s, v -> s.copy(border = v) })
        TextStyleTool.ERASER -> listOf(TextStyleSliderSpec("Size", 8, 80, 28, { overlayEraserWidthDp }) { value -> overlayEraserWidthDp = value })
        else -> emptyList()
      }
    }
    if (target is StyledTextLayerView) {
      fun spec(title: String, min: Int, max: Int, default: Int, get: (TextLayerStyle) -> Float, set: (TextLayerStyle, Float) -> TextLayerStyle) =
        TextStyleSliderSpec(title, min, max, default, { get(target.layerStyle) * 100 }) { value ->
          target.applyText(target.text?.toString().orEmpty(), set(target.layerStyle, value / 100f))
        }
      return when (tool) {
        TextStyleTool.SIZE -> listOf(spec("Size", 50, 200, 100, { it.size }) { s, v -> s.copy(size = v) })
        TextStyleTool.OUTLINE -> listOf(spec("Outline", 0, 100, 0, { it.outline }) { s, v -> s.copy(outline = v) })
        TextStyleTool.SHADOW -> listOf(spec("Shadow", 0, 100, 0, { it.shadow }) { s, v -> s.copy(shadow = v) })
        TextStyleTool.OPACITY -> listOf(spec("Opacity", 10, 100, 100, { it.opacity }) { s, v -> s.copy(opacity = v) })
        TextStyleTool.STRETCH -> listOf(
          spec("Width", 50, 200, 100, { it.stretchX }) { s, v -> s.copy(stretchX = v) },
          spec("Height", 50, 200, 100, { it.stretchY }) { s, v -> s.copy(stretchY = v) },
        )
        TextStyleTool.ARCH -> listOf(spec("Arch", -100, 100, 0, { it.arch }) { s, v -> s.copy(arch = v) })
        else -> emptyList()
      }
    }
    val sticker = target as? TextView ?: return emptyList()
    fun spec(title: String, min: Int, max: Int, default: Int, get: (StickerStyle) -> Float, set: (StickerStyle, Float) -> StickerStyle) =
      TextStyleSliderSpec(title, min, max, default, { get(stickerStyles[sticker] ?: StickerStyle()) * 100 }) { value ->
        applyStickerStyle(sticker, set(stickerStyles[sticker] ?: StickerStyle(), value / 100f))
      }
    return when (tool) {
      TextStyleTool.OPACITY -> listOf(spec("Opacity", 10, 100, 100, { it.opacity }) { s, v -> s.copy(opacity = v) })
      TextStyleTool.OUTLINE -> listOf(spec("Outline", 0, 100, 0, { it.outline }) { s, v -> s.copy(outline = v) })
      TextStyleTool.SHADOW -> listOf(spec("Shadow", 0, 100, 0, { it.shadow }) { s, v -> s.copy(shadow = v) })
      else -> emptyList()
    }
  }

  /** Chips shown above the sliders for the selected tool (overlays only). */
  private fun rebuildStyleChips() {
    val row = textStyleChipRowRef ?: return
    row.removeAllViews()
    val overlay = textStyleTarget as? ImageView
    val state = overlay?.let { overlayStates[it] }
    if (overlay == null || state == null) {
      textStyleChipScrollRef?.visibility = View.GONE
      return
    }
    val density = resources.displayMetrics.density
    fun update(change: (OverlayStyle) -> OverlayStyle) {
      setOverlayStyle(overlay, change(state.style))
      refreshAfterTextLayerChange(overlay)
      syncTextStyleControls()
    }
    fun pill(title: String, selected: Boolean, onClick: () -> Unit): View = TextView(this).apply {
      text = title
      textSize = 13f
      gravity = Gravity.CENTER
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      setPadding((12f * density).toInt(), 0, (12f * density).toInt(), 0)
      background = GradientDrawable().apply {
        cornerRadius = 100f * density
        setColor(if (selected) EditorDesignTokens.Colors.accent else EditorDesignTokens.Colors.elevatedSurface)
      }
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        onClick()
      }
    }
    val chips = mutableListOf<Pair<View, LinearLayout.LayoutParams>>()
    val pillParams = { LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, (32f * density).toInt()) }
    when (selectedTextStyleTool) {
      TextStyleTool.FILTERS -> {
        val thumbnails = overlayFilterThumbnailBitmaps(state.base)
        val tilePx = (50f * density).toInt()
        PhotoFilter.values().forEach { filter ->
          val selected = filter == state.style.filter
          val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            addView(ImageView(this@MediaEditorActivity).apply {
              setImageBitmap(thumbnails[filter])
              scaleType = ImageView.ScaleType.CENTER_CROP
              clipToOutline = true
              background = GradientDrawable().apply {
                cornerRadius = 8f * density
                setColor(EditorDesignTokens.Colors.elevatedSurface)
              }
              foreground = if (selected) GradientDrawable().apply {
                cornerRadius = 8f * density
                setStroke((2f * density).toInt(), EditorDesignTokens.Colors.accent)
              } else null
            }, LinearLayout.LayoutParams(tilePx, tilePx))
            addView(TextView(this@MediaEditorActivity).apply {
              text = filter.label
              textSize = 10f
              gravity = Gravity.CENTER
              setTextColor(if (selected) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.textSecondary)
            }, LinearLayout.LayoutParams(tilePx + (8f * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
            setOnClickListener {
              it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
              update { s -> s.copy(filter = filter, filterStrength = 1f) }
            }
          }
          chips += column to LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
      }
      TextStyleTool.BLEND -> OverlayBlendMode.values().forEach { mode ->
        chips += pill(mode.title, mode == state.style.blend) { update { s -> s.copy(blend = mode) } } to pillParams()
      }
      TextStyleTool.SHAPE -> OverlayShape.values().forEach { shape ->
        chips += pill(shape.title, shape == state.style.shape) { update { s -> s.copy(shape = shape) } } to pillParams()
      }
      TextStyleTool.BORDER -> {
        val swatchPx = (26f * density).toInt()
        textColorSwatches.forEach { color ->
          val selected = color == state.style.borderColor
          chips += View(this).apply {
            background = GradientDrawable().apply {
              shape = GradientDrawable.OVAL
              setColor(color)
              setStroke((density * (if (selected) 2f else 1f)).toInt(), if (selected) EditorDesignTokens.Colors.accent else EditorDesignTokens.Colors.divider)
            }
            setOnClickListener {
              it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
              update { s -> s.copy(borderColor = color, border = if (s.border < 0.01f) 0.35f else s.border) }
            }
          } to LinearLayout.LayoutParams(swatchPx, swatchPx)
        }
      }
      TextStyleTool.ERASER -> {
        chips += pill("Erase", !overlayEraseRestoreMode) { overlayEraseRestoreMode = false; rebuildStyleChips() } to pillParams()
        chips += pill("Restore", overlayEraseRestoreMode) { overlayEraseRestoreMode = true; rebuildStyleChips() } to pillParams()
        chips += pill("Reset", false) {
          if (state.strokes.isNotEmpty()) {
            applyOverlay(overlay, state.base, state.source, state.style, emptyList())
            refreshAfterTextLayerChange(overlay)
          }
        } to pillParams()
      }
      else -> Unit
    }
    chips.forEachIndexed { index, (view, params) ->
      if (index > 0) params.marginStart = (8f * density).toInt()
      row.addView(view, params)
    }
    textStyleChipScrollRef?.visibility = if (chips.isEmpty()) View.GONE else View.VISIBLE
  }

  /** Every filter applied to a small copy of the overlay (cached per photo). */
  private fun overlayFilterThumbnailBitmaps(base: Bitmap): Map<PhotoFilter, Bitmap> {
    overlayFilterThumbnails?.takeIf { it.first === base }?.let { return it.second }
    val images = PhotoFilter.values().associateWith { filter ->
      OverlayRenderer.colorPass(base, OverlayStyle(filter = filter), 120)
    }
    overlayFilterThumbnails = base to images
    return images
  }

  private fun didTapStyleTool(tool: TextStyleTool) {
    if (tool == TextStyleTool.CROP) {
      // Not a mode: opens the crop screen for this overlay.
      val overlay = textStyleTarget as? ImageView ?: return
      val state = overlayStates[overlay] ?: return
      presentOverlayCropScreen(state.source ?: state.base, overlay)
      return
    }
    if (tool == selectedTextStyleTool) return
    selectedTextStyleTool = tool
    syncTextStyleControls()
  }

  /** While the overlay Eraser tool is open, a transparent view over the
   *  canvas takes the touches and turns them into erase/restore strokes on
   *  the target overlay. It moves with the fitted picture (a stage
   *  "tracking view"), so its local points are canvas points. */
  private fun updateOverlayEraseCapture() {
    val active = selectedImageEditorTab == ImageEditorTab.TEXT_STYLE &&
      selectedTextStyleTool == TextStyleTool.ERASER && textStyleTarget is ImageView
    val box = canvasBoxRect
    if (!active || box == null) {
      overlayEraseCaptureRef?.let {
        it.animate().cancel()
        root.removeView(it)
      }
      overlayEraseCaptureRef = null
      return
    }
    val capture = overlayEraseCaptureRef ?: OverlayEraseCaptureView(this).also { view ->
      view.onTouch = { x, y, isStart -> handleOverlayErase(view, x, y, isStart) }
      overlayEraseCaptureRef = view
      root.addView(view, FrameLayout.LayoutParams(box.width(), box.height()).apply {
        leftMargin = box.left
        topMargin = box.top
      })
    }
    capture.scaleX = 1f
    capture.scaleY = 1f
    capture.translationY = 0f
    keepSafeAreaCoversOnTop()
    if (isFilterStageActive) applyFilterStageFit(animated = false) else capture.bringToFront()
  }

  private fun handleOverlayErase(capture: View, x: Float, y: Float, isStart: Boolean) {
    val overlay = textStyleTarget as? ImageView ?: return
    val state = overlayStates[overlay] ?: return
    if (overlay.width <= 0 || overlay.height <= 0) return
    // Local point → where it is on the unscaled canvas → the overlay's own box.
    val inverse = android.graphics.Matrix()
    overlay.matrix.invert(inverse)
    val point = floatArrayOf(capture.left + x - overlay.left, capture.top + y - overlay.top)
    inverse.mapPoints(point)
    val normalized = PointF(point[0] / overlay.width, point[1] / overlay.height)
    val strokes = state.strokes.toMutableList()
    if (isStart || strokes.isEmpty()) {
      val widthPx = overlayEraserWidthDp * resources.displayMetrics.density
      strokes += OverlayEraseStroke(listOf(normalized), widthPx / (overlay.width * overlay.scaleX).coerceAtLeast(1f), overlayEraseRestoreMode)
    } else {
      val last = strokes.removeAt(strokes.size - 1)
      strokes += last.copy(points = last.points + normalized)
    }
    applyOverlay(overlay, state.base, state.source, state.style, strokes)
    scheduleFilterStageRefresh()
  }

  private fun setUpTextStylePanel(bottomMarginPx: Int) {
    val density = resources.displayMetrics.density
    val toolRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      TextStyleTool.values().forEach { tool ->
        val label = TextView(this@MediaEditorActivity).apply {
          text = tool.title
          textSize = 13f
          gravity = Gravity.CENTER
        }
        val underline = View(this@MediaEditorActivity).apply { setBackgroundColor(EditorDesignTokens.Colors.textPrimary) }
        val tab = LinearLayout(this@MediaEditorActivity).apply {
          orientation = LinearLayout.VERTICAL
          gravity = Gravity.CENTER_HORIZONTAL
          setPadding((10f * density).toInt(), 0, (10f * density).toInt(), 0)
          addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
          addView(underline, LinearLayout.LayoutParams((16f * density).toInt(), (2f * density).toInt()).apply { topMargin = (3f * density).toInt() })
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            didTapStyleTool(tool)
          }
        }
        textStyleToolRefs[tool] = tab to (label to underline)
        addView(tab, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
      }
    }
    val toolScroll = HorizontalScrollView(this).apply {
      isHorizontalScrollBarEnabled = false
      addView(toolRow, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    val chipRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    textStyleChipRowRef = chipRow
    val chipScroll = HorizontalScrollView(this).apply {
      isHorizontalScrollBarEnabled = false
      visibility = View.GONE
      addView(chipRow, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }
    textStyleChipScrollRef = chipScroll

    textStyleSliderRows.clear()
    repeat(2) { index ->
      val title = TextView(this).apply {
        setTextColor(EditorDesignTokens.Colors.textPrimary)
        textSize = 12f
      }
      val value = TextView(this).apply {
        setTextColor(EditorDesignTokens.Colors.textSecondary)
        textSize = EditorDesignTokens.TypeSizesSp.sliderValue
        gravity = Gravity.END
      }
      val seekBar = makeStyledSeekBar().apply {
        setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
          override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
            if (!isSyncingTextStyleSliders) didChangeTextStyleSlider(index, progress)
          }
          override fun onStartTrackingTouch(seekBar: SeekBar) {}
          override fun onStopTrackingTouch(seekBar: SeekBar) {}
        })
      }
      val row = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(title, LinearLayout.LayoutParams((68f * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(seekBar, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
          marginStart = (8f * density).toInt()
          marginEnd = (8f * density).toInt()
        })
        addView(value, LinearLayout.LayoutParams((36f * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
      }
      textStyleSliderRows += TextStyleSliderRow(row, title, seekBar, value)
    }

    // Flip (stickers, overlays): two pill buttons instead of sliders.
    fun flipButton(title: String, onClick: () -> Unit): View = TextView(this).apply {
      text = title
      textSize = 13f
      gravity = Gravity.CENTER
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      background = GradientDrawable().apply {
        cornerRadius = 100f * density
        setColor(EditorDesignTokens.Colors.elevatedSurface)
      }
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        onClick()
      }
    }
    val flipRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      visibility = View.GONE
      addView(flipButton("⇆  Horizontal") { didTapStickerFlip(horizontal = true) }, LinearLayout.LayoutParams(0, (36f * density).toInt(), 1f))
      addView(flipButton("⇅  Vertical") { didTapStickerFlip(horizontal = false) }, LinearLayout.LayoutParams(0, (36f * density).toInt(), 1f).apply {
        marginStart = (12f * density).toInt()
      })
    }
    textStyleFlipRowRef = flipRow

    // Chips, flip row and slider rows stack vertically; hidden ones take no space.
    val body = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      addView(chipScroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (66f * density).toInt()).apply {
        bottomMargin = (4f * density).toInt()
      })
      addView(flipRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        topMargin = (2f * density).toInt()
        marginStart = (13f * density).toInt()
        marginEnd = (13f * density).toInt()
      })
      textStyleSliderRows.forEach { row ->
        addView(row.view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (32f * density).toInt()).apply {
          bottomMargin = (4f * density).toInt()
          marginStart = (13f * density).toInt()
          marginEnd = (13f * density).toInt()
        })
      }
    }

    val rowHeightPx = (FILTER_CATEGORY_ROW_HEIGHT_DP * density).toInt()
    val panel = SlideUpPanelView(this, "Style", TEXT_STYLE_PANEL_HEIGHT_DP).apply {
      visibility = View.INVISIBLE
      contentContainer.addView(toolScroll, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, rowHeightPx).apply {
        marginStart = (7f * density).toInt()
        marginEnd = (7f * density).toInt()
      })
      contentContainer.addView(body, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        topMargin = rowHeightPx + (6f * density).toInt()
        marginStart = (7f * density).toInt()
        marginEnd = (7f * density).toInt()
      })
      configureExpandedHeight(windowHeightPx())
      onConfirm = {
        selectedImageEditorTab = ImageEditorTab.TOOLS
        updateImageEditorUI(animated = true)
      }
    }
    textStylePanelRef = panel
    root.addView(
      panel,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, EditorDesignTokens.dpToPx(TEXT_STYLE_PANEL_HEIGHT_DP, density), Gravity.BOTTOM)
        .apply { bottomMargin = bottomMarginPx },
    )
    syncTextStyleControls()
  }

  private fun didTapStyleSelectedLayer() {
    val target = selectedLayerView ?: return
    val snapshot = styleSnapshot(target) ?: return
    pauseVideoForToolInteraction()
    commitTextStyleEdit()
    textStyleTarget = target
    textStyleAtOpen = snapshot
    val tools = styleTools(target)
    if (selectedTextStyleTool !in tools || selectedTextStyleTool == TextStyleTool.CROP) selectedTextStyleTool = tools[0]
    textStylePanelRef?.setCollapsedHeightDp(if (target is ImageView) OVERLAY_STYLE_PANEL_HEIGHT_DP else TEXT_STYLE_PANEL_HEIGHT_DP, animated = false)
    textStylePanelRef?.setBarTitle(when {
      target is ImageView -> "Overlay"
      target is StyledTextLayerView -> "Text"
      else -> "Sticker"
    })
    syncTextStyleControls()
    selectedImageEditorTab = ImageEditorTab.TEXT_STYLE
    updateImageEditorUI(animated = true)
  }

  /** Puts the target's tools and the selected tool's values on screen. */
  private fun syncTextStyleControls() {
    val tools = styleTools(textStyleTarget)
    textStyleToolRefs.forEach { (tool, refs) ->
      val (tab, views) = refs
      val (label, underline) = views
      val selected = tool == selectedTextStyleTool
      tab.visibility = if (tool in tools) View.VISIBLE else View.GONE
      label.setTextColor(if (selected) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.textSecondary)
      label.typeface = if (selected) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
      underline.visibility = if (selected) View.VISIBLE else View.INVISIBLE
    }
    textStyleFlipRowRef?.visibility = if (selectedTextStyleTool == TextStyleTool.FLIP) View.VISIBLE else View.GONE
    rebuildStyleChips()
    updateOverlayEraseCapture()
    val specs = textStyleSliderSpecs(selectedTextStyleTool)
    isSyncingTextStyleSliders = true
    textStyleSliderRows.forEachIndexed { index, row ->
      val spec = specs.getOrNull(index)
      if (spec == null) {
        row.view.visibility = View.GONE
        return@forEachIndexed
      }
      row.view.visibility = View.VISIBLE
      row.title.text = spec.title
      row.seekBar.max = spec.max - spec.min
      val value = spec.get().roundToInt()
      row.seekBar.progress = value - spec.min
      row.value.text = "$value"
    }
    isSyncingTextStyleSliders = false
  }

  private fun didChangeTextStyleSlider(index: Int, progress: Int) {
    val target = textStyleTarget ?: return
    val spec = textStyleSliderSpecs(selectedTextStyleTool).getOrNull(index) ?: return
    var value = spec.min + progress
    // Snap to the default near it, with a tick, so it's easy to get back.
    if (abs(value - spec.defaultValue) <= 2) {
      if (abs(spec.get() - spec.defaultValue) > 0.5f) {
        textStyleSliderRows[index].seekBar.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
      }
      value = spec.defaultValue
    }
    textStyleSliderRows[index].value.text = "$value"
    spec.set(value.toFloat())
    refreshAfterTextLayerChange(target)
  }

  private fun didTapStickerFlip(horizontal: Boolean) {
    val target = textStyleTarget ?: return
    if (target is ImageView) {
      val state = overlayStates[target] ?: return
      setOverlayStyle(target, if (horizontal) state.style.copy(flipX = !state.style.flipX) else state.style.copy(flipY = !state.style.flipY))
      refreshAfterTextLayerChange(target)
      return
    }
    val sticker = target as? TextView ?: return
    if (!canStyleSticker(sticker)) return
    val style = stickerStyles[sticker] ?: StickerStyle()
    applyStickerStyle(sticker, if (horizontal) style.copy(flipX = !style.flipX) else style.copy(flipY = !style.flipY))
    refreshAfterTextLayerChange(sticker)
  }

  /** Records the whole panel session as one undo step. */
  private fun commitTextStyleEdit() {
    val target = textStyleTarget ?: return
    val oldSnapshot = textStyleAtOpen
    textStyleTarget = null
    textStyleAtOpen = null
    updateOverlayEraseCapture()
    val newSnapshot = styleSnapshot(target)
    if (oldSnapshot == null || newSnapshot == null || oldSnapshot == newSnapshot) return
    pushUndo(
      undo = { applyStyleSnapshot(oldSnapshot, target) },
      redo = { applyStyleSnapshot(newSnapshot, target) },
    )
  }

  private fun updateTextLayer(target: StyledTextLayerView, text: String, style: TextLayerStyle) {
    val oldText = target.text?.toString().orEmpty()
    val oldStyle = target.layerStyle
    target.applyText(text, style)
    refreshAfterTextLayerChange(target)
    pushUndo(
      undo = { target.applyText(oldText, oldStyle); refreshAfterTextLayerChange(target) },
      redo = { target.applyText(text, style); refreshAfterTextLayerChange(target) },
    )
  }

  /** A style change resizes the layer — re-place its toolbar once it has
   *  been laid out, and refresh the stage snapshot. */
  private fun refreshAfterTextLayerChange(target: View) {
    target.post {
      if (selectedLayerView === target) repositionLayerActionToolbar()
      scheduleFilterStageRefresh()
    }
  }

  /** [existing] is non-null only when opened via the layer toolbar's Edit
   *  action — prefills the overlay with that layer's current text/font/
   *  color/alignment and, on confirm, updates it in place instead of adding
   *  a new layer (see confirmTextEntry). */
  private fun presentTextEntryOverlay(existing: TextView? = null) {
    if (existing == null && !canAddLayer()) return
    // Close whatever stateful panel (Effect/Edit/Sticker/Draw/Music) is
    // currently open first — only one tool should ever be active at a
    // time, per the user's explicit request. A no-op if nothing was open.
    selectedImageEditorTab = ImageEditorTab.TOOLS
    updateImageEditorUI(animated = true)
    editingLayerView = existing
    textEntryStyle = (existing as? StyledTextLayerView)?.layerStyle ?: TextLayerStyle()
    val density = resources.displayMetrics.density

    val editText = EditText(this).apply {
      setText(existing?.text ?: "")
      background = null
      setHintTextColor(EditorDesignTokens.Colors.textSecondary)
      hint = "Enter text"
      minLines = 1
      val padH = (10f * density).toInt()
      val padV = (6f * density).toInt()
      setPadding(padH, padV, padH, padV)
    }
    textEntryEditTextRef = editText
    applyCurrentTextEntryStyle()

    val overlay = FrameLayout(this).apply {
      setBackgroundColor(Color.argb(128, 0, 0, 0))
      // Android draws higher-elevation views on top of lower ones WHEREVER
      // their bounds overlap, regardless of add order (unlike bringToFront,
      // which only reorders among EQUAL-elevation siblings) — bottomTrayRef/
      // filtersAdjustContainer carry an 8dp elevation from the floating-
      // panel treatment, so without an explicit elevation here (higher than
      // theirs) this full-screen scrim — and the font/color toolbar below —
      // render UNDER the tray instead of over it, leaving only whatever
      // toolbar content pokes out above the tray's own top edge visible.
      elevation = EditorDesignTokens.dpToPx(12f, density).toFloat()
      // A click on the dim background (not consumed by the EditText child
      // itself) dismisses — tapping inside the EditText to place the
      // cursor is handled by the EditText first and never reaches here.
      setOnClickListener { dismissTextEntryOverlay() }
      addView(
        editText,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER).apply {
          leftMargin = (24f * density).toInt()
          rightMargin = (24f * density).toInt()
        },
      )
    }
    root.addView(overlay, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    textEntryOverlayRef = overlay

    val toolbar = makeTextEntryToolbar().apply {
      elevation = EditorDesignTokens.dpToPx(12f, density).toFloat()
    }
    textEntryToolbarRef = toolbar
    root.addView(
      toolbar,
      // bottomMargin = navigationBarHeightPx — same edge-to-edge fix as
      // the main bottom tray: this toolbar sits well above the keyboard
      // (which isn't shown until the EditText is focused a moment later),
      // so without this its color row rendered right at the true bottom
      // of the screen, behind the system navigation bar, per the user's
      // explicit "these colors is hide behind these navigation bar"
      // screenshot report.
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM)
        .apply { bottomMargin = navigationBarHeightPx },
    )
    keepTextEntryAboveKeyboard(overlay, toolbar)

    editText.requestFocus()
    val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
    imm.showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
  }

  /** Docks the font/colour toolbar on top of the keyboard and centres the
   *  text field in the space above it. The app targets SDK 35+, where the
   *  window is always edge-to-edge and SOFT_INPUT_ADJUST_RESIZE no longer
   *  shrinks it, so the keyboard simply covered the toolbar. Uses how much
   *  the keyboard actually overlaps `root`, so it's also correct on older
   *  Android versions where the window still does get resized. */
  private fun keepTextEntryAboveKeyboard(overlay: View, toolbar: View) {
    fun update(insets: WindowInsetsCompat?) {
      if (textEntryToolbarRef !== toolbar) return
      val imeBottom = (insets ?: ViewCompat.getRootWindowInsets(root))
        ?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0
      val windowHeight = window.decorView.height
      val rootLocation = IntArray(2)
      root.getLocationInWindow(rootLocation)
      val rootBottomInWindow = rootLocation[1] + root.height
      val keyboardOverlap = if (imeBottom > 0) rootBottomInWindow - (windowHeight - imeBottom) else 0
      val bottom = maxOf(navigationBarHeightPx, keyboardOverlap)
      (toolbar.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
        if (params.bottomMargin != bottom) {
          params.bottomMargin = bottom
          toolbar.layoutParams = params
        }
      }
      val overlayBottomPadding = bottom + toolbar.height
      if (overlay.paddingBottom != overlayBottomPadding) {
        overlay.setPadding(0, statusBarHeightPx, 0, overlayBottomPadding)
      }
    }
    ViewCompat.setOnApplyWindowInsetsListener(overlay) { _, insets ->
      update(insets)
      insets
    }
    // Follows the keyboard while it slides in/out.
    ViewCompat.setWindowInsetsAnimationCallback(
      overlay,
      object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
        override fun onProgress(
          insets: WindowInsetsCompat,
          runningAnimations: MutableList<WindowInsetsAnimationCompat>,
        ): WindowInsetsCompat {
          update(insets)
          return insets
        }
      },
    )
    // The toolbar's own height is only known after its first layout.
    toolbar.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
      if (bottom - top != oldBottom - oldTop) update(null)
    }
    ViewCompat.requestApplyInsets(overlay)
    // Fallback in case an ancestor consumes the insets before they reach
    // the overlay: re-read them once the keyboard has had time to open.
    listOf(250L, 600L).forEach { delay -> overlay.postDelayed({ update(null) }, delay) }
  }

  private fun makeTextEntryToolbar(): View {
    val density = resources.displayMetrics.density
    val iconButtonSizePx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.minTapTarget, density)

    val cancelButton = makeTopBarIconButton(EditorIcon.CLOSE) { dismissTextEntryOverlay() }
    val confirmButton = makeTopBarIconButton(EditorIcon.CHECK) { confirmTextEntry() }
    val headerRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      addView(cancelButton, LinearLayout.LayoutParams(iconButtonSizePx, iconButtonSizePx))
      addView(View(this@MediaEditorActivity), LinearLayout.LayoutParams(0, 0, 1f))
      addView(confirmButton, LinearLayout.LayoutParams(iconButtonSizePx, iconButtonSizePx))
    }

    textFontButtonRefs.clear()
    val fontRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      TextFontCatalog.options.forEachIndexed { index, option ->
        val button = TextView(this@MediaEditorActivity).apply {
          text = option.label
          setTextColor(EditorDesignTokens.Colors.textSecondary)
          textSize = 15f * option.sizeFactor
          // Preview the font ITSELF, not a fixed default typeface — per
          // the user's "these fonts are very simple and basic" report,
          // which traced back to every button rendering its label in the
          // same generic typeface regardless of which font it represents,
          // so e.g. "Script"/"Casual" looked identical to "Classic" at a
          // glance.
          typeface = TextFontCatalog.typeface(this@MediaEditorActivity, option)
          // Grows the button's own tappable area well past its tight text
          // bounds — per the user's explicit "increase touchable area of
          // the fonts" report. Vertical padding also raises this row's own
          // min height toward the accessibility tap-target minimum.
          setPadding((8f * density).toInt(), (12f * density).toInt(), (8f * density).toInt(), (12f * density).toInt())
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            selectTextFont(option)
          }
        }
        textFontButtonRefs.add(button)
        addView(button, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          // Reduced from 14 since each button's own padding above now
          // contributes 8dp of horizontal space per side already.
          if (index > 0) marginStart = (2f * density).toInt()
        })
      }
    }

    val swatchSizePx = (24f * density).toInt()
    textColorButtonRefs.clear()
    val colorRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      textColorSwatches.forEachIndexed { index, colorValue ->
        val swatch = View(this@MediaEditorActivity).apply {
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            selectTextColor(colorValue)
          }
        }
        textColorButtonRefs.add(swatch)
        addView(swatch, LinearLayout.LayoutParams(swatchSizePx, swatchSizePx).apply {
          if (index > 0) marginStart = (10f * density).toInt()
        })
      }
    }

    val boldButton = TextView(this@MediaEditorActivity).apply {
      text = "B"
      setTypeface(Typeface.DEFAULT, Typeface.BOLD)
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = 15f
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        toggleTextBold()
      }
    }
    textBoldButtonRef = boldButton
    val italicButton = TextView(this@MediaEditorActivity).apply {
      text = "I"
      setTypeface(Typeface.DEFAULT, Typeface.ITALIC)
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = 15f
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        toggleTextItalic()
      }
    }
    textItalicButtonRef = italicButton
    val underlineButton = TextView(this@MediaEditorActivity).apply {
      text = "U"
      paintFlags = paintFlags or Paint.UNDERLINE_TEXT_FLAG
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = 15f
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        toggleTextUnderline()
      }
    }
    textUnderlineButtonRef = underlineButton
    // Cycles left → centre → right.
    val alignButton = EditorIconView(this, EditorIcon.ALIGN_CENTER).apply {
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        cycleTextAlignment()
      }
    }
    textAlignButtonRef = alignButton
    // Cycles none → solid → see-through background behind the text.
    val backgroundButton = EditorIconView(this, EditorIcon.TEXT_BG).apply {
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        cycleTextBackground()
      }
    }
    textBackgroundButtonRef = backgroundButton
    val iconSizePx = (22f * density).toInt()
    val styleRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      listOf(boldButton, italicButton, underlineButton).forEachIndexed { index, button ->
        addView(button, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          if (index > 0) marginStart = (16f * density).toInt()
        })
      }
      listOf(alignButton, backgroundButton).forEach { button ->
        addView(button, LinearLayout.LayoutParams(iconSizePx, iconSizePx).apply { marginStart = (16f * density).toInt() })
      }
    }

    // Colors get their OWN row below fonts — not side by side with them —
    // per the user's explicit request. Bold/Italic/Underline ride along on
    // the color row (a small, compact control) rather than getting a 3rd
    // row — same slot the old alignment picker used before it was removed
    // per the user's explicit request.
    val colorAndStyleRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      addView(styleRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
      addView(colorRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        marginStart = (20f * density).toInt()
      })
    }

    val fontScroll = HorizontalScrollView(this).apply {
      isHorizontalScrollBarEnabled = false
      addView(fontRow)
    }
    val colorScroll = HorizontalScrollView(this).apply {
      isHorizontalScrollBarEnabled = false
      addView(colorAndStyleRow)
    }

    return LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setBackgroundColor(EditorDesignTokens.Colors.panelBackground)
      // Top/bottom padding raised from 4dp/8dp — per the user's explicit
      // "when i click on text then bottom is opening at very low, open it
      // more" report, the toolbar felt cramped against its own edges.
      setPadding((12f * density).toInt(), (16f * density).toInt(), (12f * density).toInt(), (16f * density).toInt())
      // Root cause of the user's "if it's not click on exact touch then
      // these text bottomsheet closes" report: this toolbar sits ON TOP
      // of `overlay` (which has its own setOnClickListener dismissing the
      // whole sheet), but neither this LinearLayout nor its rows were
      // themselves clickable — so a tap landing in any GAP between font/
      // color buttons (not consumed by a child) fell through Android's
      // touch dispatch to the next view underneath whose bounds also
      // contain that point, i.e. `overlay`, dismissing the sheet. Marking
      // this toolbar clickable (no listener needed) makes it swallow any
      // stray tap within its own solid chrome bounds instead.
      isClickable = true
      addView(headerRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
      addView(fontScroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        topMargin = (14f * density).toInt()
      })
      addView(colorScroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        topMargin = (18f * density).toInt()
      })
      updateTextEntryPickerHighlights()
    }
  }

  private fun selectTextFont(option: TextFontOption) {
    textEntryStyle = textEntryStyle.copy(fontId = option.id)
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  private fun selectTextColor(colorValue: Int) {
    textEntryStyle = textEntryStyle.copy(color = colorValue)
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  private fun toggleTextBold() {
    textEntryStyle = textEntryStyle.copy(isBold = !textEntryStyle.isBold)
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  private fun toggleTextItalic() {
    textEntryStyle = textEntryStyle.copy(isItalic = !textEntryStyle.isItalic)
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  private fun toggleTextUnderline() {
    textEntryStyle = textEntryStyle.copy(isUnderlined = !textEntryStyle.isUnderlined)
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  private fun cycleTextAlignment() {
    val next = when (textEntryStyle.alignment) {
      TextAlign.LEFT -> TextAlign.CENTER
      TextAlign.CENTER -> TextAlign.RIGHT
      TextAlign.RIGHT -> TextAlign.LEFT
    }
    textEntryStyle = textEntryStyle.copy(alignment = next)
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  private fun cycleTextBackground() {
    val modes = TextBackgroundMode.values()
    textEntryStyle = textEntryStyle.copy(background = modes[(textEntryStyle.background.ordinal + 1) % modes.size])
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  /** Shows the chosen font/colour/bold/italic/underline/alignment/
   *  background on the text being typed (outline, arch etc. only show on
   *  the layer itself). Bold and italic use the same synthetic stroke and
   *  slant TextLayerRenderer draws, since the bundled fonts have one weight. */
  private fun applyCurrentTextEntryStyle() {
    val editText = textEntryEditTextRef ?: return
    val style = textEntryStyle
    val density = resources.displayMetrics.density
    val option = TextFontCatalog.option(style.fontId)
    val fontSizePx = TextFontCatalog.BASE_SIZE * option.sizeFactor * style.size.coerceIn(0.5f, 1.5f) * density
    val fill = TextLayerRenderer.fillColor(style)
    editText.typeface = TextFontCatalog.typeface(this, option)
    editText.setTextSize(TypedValue.COMPLEX_UNIT_PX, fontSizePx)
    editText.setTextColor(fill)
    editText.paint.style = if (style.isBold) Paint.Style.FILL_AND_STROKE else Paint.Style.FILL
    editText.paint.strokeWidth = if (style.isBold) TextLayerRenderer.BOLD_WIDTH * fontSizePx else 0f
    editText.paint.strokeJoin = Paint.Join.ROUND
    editText.paint.textSkewX = if (style.isItalic) -TextLayerRenderer.ITALIC_SKEW else 0f
    editText.paintFlags = if (style.isUnderlined) {
      editText.paintFlags or Paint.UNDERLINE_TEXT_FLAG
    } else {
      editText.paintFlags and Paint.UNDERLINE_TEXT_FLAG.inv()
    }
    editText.textAlignment = when (style.alignment) {
      TextAlign.LEFT -> View.TEXT_ALIGNMENT_TEXT_START
      TextAlign.CENTER -> View.TEXT_ALIGNMENT_CENTER
      TextAlign.RIGHT -> View.TEXT_ALIGNMENT_TEXT_END
    }
    editText.background = if (style.background == TextBackgroundMode.NONE) {
      null
    } else {
      GradientDrawable().apply {
        cornerRadius = 12f * density
        val alpha = if (style.background == TextBackgroundMode.TRANSLUCENT) TextLayerRenderer.TRANSLUCENT_ALPHA else 1f
        setColor(ColorUtils.setAlphaComponent(style.color, (alpha * 255).roundToInt()))
      }
    }
    editText.invalidate()
  }

  private fun updateTextEntryPickerHighlights() {
    val accent = EditorDesignTokens.Colors.accent
    val idle = EditorDesignTokens.Colors.textSecondary
    textFontButtonRefs.forEachIndexed { index, button ->
      button.setTextColor(if (TextFontCatalog.options[index].id == textEntryStyle.fontId) accent else idle)
    }
    textColorButtonRefs.forEachIndexed { index, swatch ->
      val isSelected = textColorSwatches[index] == textEntryStyle.color
      swatch.background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(textColorSwatches[index])
        val strokeWidthPx = (resources.displayMetrics.density * (if (isSelected) 2f else 1f)).toInt()
        setStroke(strokeWidthPx, if (isSelected) accent else EditorDesignTokens.Colors.divider)
      }
    }
    textBoldButtonRef?.setTextColor(if (textEntryStyle.isBold) accent else idle)
    textItalicButtonRef?.setTextColor(if (textEntryStyle.isItalic) accent else idle)
    textUnderlineButtonRef?.setTextColor(if (textEntryStyle.isUnderlined) accent else idle)
    textAlignButtonRef?.apply {
      icon = when (textEntryStyle.alignment) {
        TextAlign.LEFT -> EditorIcon.ALIGN_LEFT
        TextAlign.CENTER -> EditorIcon.ALIGN_CENTER
        TextAlign.RIGHT -> EditorIcon.ALIGN_RIGHT
      }
      iconTint = idle
    }
    textBackgroundButtonRef?.apply {
      icon = if (textEntryStyle.background == TextBackgroundMode.NONE) EditorIcon.TEXT_BG else EditorIcon.TEXT_BG_FILL
      iconTint = if (textEntryStyle.background == TextBackgroundMode.NONE) idle else accent
      alpha = if (textEntryStyle.background == TextBackgroundMode.TRANSLUCENT) TextLayerRenderer.TRANSLUCENT_ALPHA else 1f
    }
  }

  /** Same highlight recipe as updateTextEntryPickerHighlights's color
   *  swatches — a stroked circle, accent-colored + thicker when selected. */
  private fun updateDrawPickerHighlights() {
    drawColorButtonRefs.forEachIndexed { index, swatch ->
      val isSelected = textColorSwatches[index] == selectedDrawColor
      swatch.background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(textColorSwatches[index])
        val strokeWidthPx = (resources.displayMetrics.density * (if (isSelected) 2f else 1f)).toInt()
        setStroke(strokeWidthPx, if (isSelected) EditorDesignTokens.Colors.accent else EditorDesignTokens.Colors.divider)
      }
    }
    val density = resources.displayMetrics.density
    drawBrushTypeButtonRefs.forEach { (brushType, tile) ->
      val isSelected = brushType == selectedBrushType
      tile.background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = 10f * density
        setColor(EditorDesignTokens.Colors.elevatedSurface)
        if (isSelected) setStroke((2f * density).toInt(), EditorDesignTokens.Colors.accent)
      }
    }
    drawShapeRefs.forEach { (shapeType, tile) ->
      tile.background = GradientDrawable().apply {
        cornerRadius = 10f * density
        setColor(EditorDesignTokens.Colors.elevatedSurface)
        if (shapeType == selectedDrawShape) setStroke((2f * density).toInt(), EditorDesignTokens.Colors.accent)
      }
    }
    drawToolRefs.forEach { (tool, button, views) ->
      val selected = tool == selectedDrawTool
      val (icon, label) = views
      button.background = if (selected) {
        GradientDrawable().apply {
          cornerRadius = 10f * density
          setColor(EditorDesignTokens.Colors.elevatedSurface)
        }
      } else {
        null
      }
      icon.iconTint = if (selected) EditorDesignTokens.Colors.accent else EditorDesignTokens.Colors.textPrimary
      label.setTextColor(if (selected) EditorDesignTokens.Colors.accent else EditorDesignTokens.Colors.textPrimary)
    }
    drawBrushTilesRef?.visibility = if (selectedDrawTool == DrawTool.BRUSH) View.VISIBLE else View.GONE
    drawShapeTilesRef?.visibility = if (selectedDrawTool == DrawTool.SHAPE) View.VISIBLE else View.GONE
    // Colour doesn't apply to the eraser.
    val isEraser = selectedDrawTool == DrawTool.ERASER
    drawColorScrollRef?.alpha = if (isEraser) 0.35f else 1f
    drawColorButtonRefs.forEach { it.isEnabled = !isEraser }
  }

  /** Points the canvas at the tool: the eraser draws eraser strokes with
   *  its own size; a shape uses the selected brush's look. */
  private fun applyDrawTool(tool: DrawTool) {
    selectedDrawTool = tool
    drawingCanvasRef?.currentBrushType = if (tool == DrawTool.ERASER) DrawingCanvasView.BrushType.ERASER else selectedBrushType
    drawingCanvasRef?.currentShape = if (tool == DrawTool.SHAPE) selectedDrawShape else null
    val widthPx = if (tool == DrawTool.ERASER) drawEraserWidthPx else selectedDrawWidthPx
    drawingCanvasRef?.currentWidthPx = widthPx
    drawWidthToProgress?.let { drawWidthSeekBarRef?.progress = it(widthPx) }
    updateDrawPickerHighlights()
  }

  private fun confirmTextEntry() {
    val text = textEntryEditTextRef?.text?.toString()?.trim().orEmpty()
    val style = textEntryStyle
    val editing = editingLayerView as? StyledTextLayerView
    dismissTextEntryOverlay()
    if (text.isEmpty()) return
    if (editing != null) {
      updateTextLayer(editing, text, style)
    } else {
      addTextLayer(text, style)
    }
  }

  private fun dismissTextEntryOverlay() {
    textEntryEditTextRef?.let { editText ->
      val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
      imm.hideSoftInputFromWindow(editText.windowToken, 0)
    }
    textEntryOverlayRef?.let { root.removeView(it) }
    textEntryToolbarRef?.let { root.removeView(it) }
    textEntryOverlayRef = null
    textEntryToolbarRef = null
    textEntryEditTextRef = null
    editingLayerView = null
  }

  private fun addTextLayer(text: String, style: TextLayerStyle = TextLayerStyle()) {
    val textView = StyledTextLayerView(this).apply { applyText(text, style) }
    root.addView(
      textView,
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER,
      ),
    )
    root.setClipRect(textView, canvasBoxRect)
    textLayerViews.add(textView)
    gestureCoordinator?.addLayer(textView)
    // Auto-selected immediately — matches addImageOverlayLayer, and locks
    // the base canvas out of pan/pinch/rotate right away rather than only
    // once the user separately taps the new layer (see selectLayer).
    selectLayer(textView)
    keepSafeAreaCoversOnTop()
    registerLayerTiming(textView)
    // registerLayerTiming never sets this layer's own alpha/visibility —
    // that's the periodic timeline runnable's job, which only runs during
    // playback — per the user's explicit "adding a second text/sticker
    // doesn't show until I touch the screen" report: force it right here
    // instead of relying on some other, incidental trigger.
    updateLayerTimeVisibility()
    pushUndo(
      undo = {
        textView.visibility = View.GONE
        if (selectedLayerView === textView) deselectLayer()
        refreshLayersPanel()
      },
      redo = { textView.visibility = View.VISIBLE; refreshLayersPanel() },
    )
  }

  /** Sticker asset id for a sticker-image layer (bundled Twemoji artwork,
   *  see addStickerLayer) — the TextView shows the image via a fixed-size
   *  centered compound drawable (empty text) rather than an emoji glyph,
   *  so every existing text/sticker code path (gestures, undo/redo,
   *  per-layer time-range grouping, split/select/delete) built around a
   *  plain TextView keeps working unchanged; only the rendered CONTENT
   *  differs. Kept in its own map rather than on `.tag` (already holds
   *  TextLayerStyle, see its doc) so the two don't collide. */
  private val stickerLayerAssetNames = mutableMapOf<TextView, String>()

  private fun stickerImageSizePx(): Int = (64f * resources.displayMetrics.density).toInt()

  /** A sticker's artwork for export and its drawn side (export px) —
   *  styled at export resolution when it has a style. */
  private fun stickerExportBitmap(layer: TextView, assetName: String, exportScale: Float): Pair<Bitmap, Float>? {
    val base = StickerCatalog.bitmap(this, assetName) ?: return null
    val style = stickerStyles[layer]
    val side = stickerImageSizePx() * exportScale
    if (style == null || style.isDefault) return base to side
    return StickerStyleRenderer.render(base, side, style, 1f)
  }

  /** Returns false (leaving textView untouched) if the asset couldn't be
   *  resolved, so the caller can bail out rather than add a broken layer. */
  /** Keeps the layer's sticker style (e.g. when swapping the sticker via
   *  Edit): a styled sticker shows its rendered image, grown to fit its
   *  outline/shadow. */
  private fun applyStickerImage(textView: TextView, assetName: String): Boolean {
    val resId = resources.getIdentifier(assetName, "drawable", packageName)
    if (resId == 0) return false
    val style = stickerStyles[textView]
    val drawable: android.graphics.drawable.Drawable
    val sizePx: Int
    if (style == null || style.isDefault) {
      drawable = ContextCompat.getDrawable(this, resId) ?: return false
      sizePx = stickerImageSizePx()
    } else {
      val base = StickerCatalog.bitmap(this, assetName) ?: return false
      val density = resources.displayMetrics.density
      val (styled, side) = StickerStyleRenderer.render(base, stickerImageSizePx().toFloat(), style, 4f / density)
      drawable = BitmapDrawable(resources, styled)
      sizePx = side.roundToInt()
    }
    drawable.setBounds(0, 0, sizePx, sizePx)
    textView.text = null
    textView.gravity = Gravity.CENTER
    textView.setCompoundDrawables(null, drawable, null, null)
    stickerLayerAssetNames[textView] = assetName
    return true
  }

  /** Non-nil only while the Stickers panel is open FOR AN EXISTING sticker
   *  layer (via the toolbar's Edit action) — mirrors editingImageOverlayLayer
   *  below. The next grid tap swaps that layer's image in place instead of
   *  adding a new layer when this is set. */
  private var editingStickerLayer: TextView? = null

  private fun selectStickerCategory(index: Int) {
    selectedStickerCategory = index
    val search = stickerSearchRef
    if (search != null && search.text.isNotEmpty()) {
      search.setText("") // re-enters here via didChangeStickerSearch
      (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(search.windowToken, 0)
      search.clearFocus()
      return
    }
    highlightStickerTab(index)
    showStickerGrid(StickerCatalog.categories(this).getOrNull(index)?.stickers.orEmpty())
  }

  private fun highlightStickerTab(index: Int?) {
    stickerCategoryTabRefs.forEachIndexed { i, (label, underline) ->
      val selected = i == index
      label.setTextColor(if (selected) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.textSecondary)
      label.typeface = if (selected) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
      underline.visibility = if (selected) View.VISIBLE else View.INVISIBLE
    }
  }

  private fun didChangeStickerSearch(query: String) {
    val trimmed = query.trim()
    if (trimmed.isEmpty()) {
      selectStickerCategory(selectedStickerCategory)
      return
    }
    highlightStickerTab(null)
    showStickerGrid(StickerCatalog.search(this, trimmed))
  }

  /** Rebuilds the grid (5 columns) for [names]. */
  private fun showStickerGrid(names: List<String>) {
    val grid = stickerGridRef ?: return
    grid.removeAllViews()
    val density = resources.displayMetrics.density
    val gutterPx = (8f * density).toInt()
    // 6 smaller tiles a row (was 5 × 56dp).
    val cellPx = (46f * density).toInt()
    if (names.isEmpty()) {
      grid.addView(TextView(this).apply {
        text = "No stickers found"
        textSize = 13f
        gravity = Gravity.CENTER
        setTextColor(EditorDesignTokens.Colors.textSecondary)
      }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (60f * density).toInt()))
    }
    names.chunked(6).forEachIndexed { rowIndex, rowItems ->
      val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
      for (column in 0 until 6) {
        val assetName = rowItems.getOrNull(column)
        val cell: View = if (assetName == null) View(this) else ImageView(this).apply {
          setImageBitmap(StickerCatalog.thumbnail(this@MediaEditorActivity, assetName, cellPx))
          scaleType = ImageView.ScaleType.CENTER_INSIDE
          val pad = (6f * density).toInt()
          setPadding(pad, pad, pad, pad)
          background = GradientDrawable().apply {
            cornerRadius = 10f * density
            setColor(EditorDesignTokens.Colors.elevatedSurface)
          }
          contentDescription = assetName
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            didTapStickerGridItem(assetName)
          }
        }
        row.addView(cell, LinearLayout.LayoutParams(0, cellPx, 1f).apply { if (column > 0) marginStart = gutterPx })
      }
      grid.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        if (rowIndex > 0) topMargin = gutterPx
      })
    }
    stickerGridScrollRef?.scrollTo(0, 0)
  }

  /** While the search box is being typed in, lifts the Stickers panel
   *  above the keyboard (edge-to-edge: the window no longer resizes). */
  private fun stickersPanelFollowsKeyboard(panel: View, search: EditText) {
    val baseMargin = (panel.layoutParams as FrameLayout.LayoutParams).bottomMargin
    fun update(insets: WindowInsetsCompat?) {
      val imeBottom = (insets ?: ViewCompat.getRootWindowInsets(root))?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0
      val location = IntArray(2)
      root.getLocationInWindow(location)
      val overlap = if (imeBottom > 0 && search.hasFocus()) location[1] + root.height - (window.decorView.height - imeBottom) else 0
      val margin = maxOf(baseMargin, overlap)
      val params = panel.layoutParams as FrameLayout.LayoutParams
      if (params.bottomMargin != margin) {
        params.bottomMargin = margin
        panel.layoutParams = params
      }
    }
    ViewCompat.setOnApplyWindowInsetsListener(panel) { _, insets ->
      update(insets)
      insets
    }
    ViewCompat.setWindowInsetsAnimationCallback(
      panel,
      object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
        override fun onProgress(insets: WindowInsetsCompat, runningAnimations: MutableList<WindowInsetsAnimationCompat>): WindowInsetsCompat {
          update(insets)
          return insets
        }
      },
    )
    search.setOnFocusChangeListener { _, _ ->
      listOf(0L, 300L, 600L).forEach { delay -> panel.postDelayed({ update(null) }, delay) }
    }
  }

  private fun didTapStickerGridItem(assetName: String) {
    val editing = editingStickerLayer
    if (editing != null) {
      editingStickerLayer = null
      updateStickerLayer(editing, assetName)
      // Close the panel after replacing — matches the previous dialog's
      // dismiss-on-select behavior, unlike the "stays open" ADD flow below
      // (which lets the user drop several stickers in a row).
      selectedImageEditorTab = ImageEditorTab.TOOLS
      updateImageEditorUI(animated = true)
    } else {
      addStickerLayer(assetName)
      // Story (Instagram-style): the tray closes on pick so the new
      // sticker sits on the full-size story, selected — drag it right away
      // (with the tray open the picture is a shrunk snapshot).
      if (isStoryMode) {
        selectedImageEditorTab = ImageEditorTab.TOOLS
        updateImageEditorUI(animated = true)
        root.post { updateStickerDeleteBadge() }
      }
    }
  }

  private fun addStickerLayer(assetName: String) {
    // The Stickers panel stays open between picks — re-check per sticker.
    if (!canAddLayer()) return
    val textView = TextView(this)
    if (!applyStickerImage(textView, assetName)) return
    root.addView(
      textView,
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER,
      ),
    )
    root.setClipRect(textView, canvasBoxRect)
    stickerLayerViews.add(textView)
    gestureCoordinator?.addLayer(textView)
    selectLayer(textView)
    keepSafeAreaCoversOnTop()
    registerLayerTiming(textView)
    // registerLayerTiming never sets this layer's own alpha/visibility —
    // that's the periodic timeline runnable's job, which only runs during
    // playback — per the user's explicit "adding a second text/sticker
    // doesn't show until I touch the screen" report: force it right here
    // instead of relying on some other, incidental trigger.
    updateLayerTimeVisibility()
    pushUndo(
      undo = {
        textView.visibility = View.GONE
        if (selectedLayerView === textView) deselectLayer()
        refreshLayersPanel()
      },
      redo = { textView.visibility = View.VISIBLE; refreshLayersPanel() },
    )
  }

  // MARK: - Location layers (story rail's Location sticker)

  /** A Location layer's place name + pill style (0 white pill, 1 dark
   *  pill, 2 plain text). These are sticker layers (in stickerLayerViews,
   *  so gestures/undo/delete/layers panel keep working unchanged) whose
   *  art is a generated pill Bitmap rather than a bundled drawable — so
   *  they're kept here, NOT in stickerLayerAssetNames. */
  private data class LocationLayerState(
    val name: String,
    val style: Int,
    // Null when the place's coordinates couldn't be resolved — returned in
    // the export result's `stickers` so story viewers can open maps.
    val latitude: Double? = null,
    val longitude: Double? = null,
    /** Story info pills share this pill: "location", "link", "hashtag",
     *  "time" or "date". [value] = the link URL / the tag. */
    val kind: String = "location",
    val value: String? = null,
  )

  private val locationLayerStates = mutableMapOf<TextView, LocationLayerState>()

  /** Non-nil while the picker was opened via the toolbar's Edit action —
   *  the chosen place then renames that layer instead of adding one. */
  private var editingLocationLayer: TextView? = null
  /** Waiting on the runtime location-permission dialog. */
  private var pendingLocationCallback: ((LocationPickerDialog.LocationFix) -> Unit)? = null
  private val locationHandler = Handler(Looper.getMainLooper())
  private val locationPermissionRequestCode = 4101

  private val locationPillTypeface: Typeface by lazy {
    runCatching { Typeface.createFromAsset(assets, "fonts/DMSans-Bold.ttf") }.getOrDefault(Typeface.DEFAULT_BOLD)
  }

  private fun presentLocationPicker(editing: TextView? = null) {
    // Only one tool open at a time — same as the other rail tools.
    selectedImageEditorTab = ImageEditorTab.TOOLS
    updateImageEditorUI(animated = true)
    editingLocationLayer = editing
    LocationPickerDialog(
      this,
      placesApiKey,
      requestLocation = ::requestCurrentLocation,
      onDismiss = { editingLocationLayer = null },
    ) { place ->
      val target = editingLocationLayer
      if (target != null) updateLocationLayer(target, place) else addLocationLayer(place)
    }.show()
  }

  // MARK: Story info stickers (link, hashtag, time, date)

  private fun infoStickerTitle(kind: String): String = when (kind) {
    "link" -> "Link"
    "hashtag" -> "Hashtag"
    "time" -> "Time"
    "date" -> "Date"
    else -> "Location"
  }

  private fun infoNowText(kind: String): String {
    val now = java.util.Date()
    return if (kind == "time") {
      android.text.format.DateFormat.getTimeFormat(this).format(now)
    } else {
      java.text.SimpleDateFormat(android.text.format.DateFormat.getBestDateTimePattern(java.util.Locale.getDefault(), "EEE d MMM"), java.util.Locale.getDefault()).format(now)
    }
  }

  private fun showInfoStickerMenu() {
    selectedImageEditorTab = ImageEditorTab.TOOLS
    updateImageEditorUI(animated = true)
    AlertDialog.Builder(this)
      .setTitle("Add a sticker")
      .setItems(arrayOf("Link or program", "Hashtag", "Time", "Date")) { _, which ->
        when (which) {
          0 -> presentInfoStickerEditor("link", null)
          1 -> presentInfoStickerEditor("hashtag", null)
          2 -> addInfoSticker(LocationLayerState(infoNowText("time"), style = 0, kind = "time"))
          else -> addInfoSticker(LocationLayerState(infoNowText("date"), style = 0, kind = "date"))
        }
      }
      .setNegativeButton("Cancel", null)
      .show()
  }

  /** Link: URL (+ optional label; a program's share link opens the program).
   *  Hashtag: the tag. Time / date: refreshed to now. */
  private fun presentInfoStickerEditor(kind: String, editing: TextView?) {
    val old = editing?.let { locationLayerStates[it] }
    if (kind == "time" || kind == "date") {
      if (editing != null && old != null) updateInfoSticker(editing, old.copy(name = infoNowText(kind)))
      return
    }
    val isLink = kind == "link"
    val density = resources.displayMetrics.density
    val valueField = android.widget.EditText(this).apply {
      hint = if (isLink) "https://…" else "#fitness"
      inputType = if (isLink) android.text.InputType.TYPE_TEXT_VARIATION_URI else android.text.InputType.TYPE_CLASS_TEXT
      setText(old?.value?.let { if (isLink) it else "#$it" } ?: "")
    }
    val labelField = android.widget.EditText(this).apply {
      hint = "Label (optional)"
      setText(if (isLink) old?.name ?: "" else "")
    }
    val box = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      val pad = (20f * density).toInt()
      setPadding(pad, (8f * density).toInt(), pad, 0)
      addView(valueField)
      if (isLink) addView(labelField)
    }
    AlertDialog.Builder(this)
      .setTitle(if (isLink) "Link sticker" else "Hashtag sticker")
      .setMessage(if (isLink) "Paste a link — a program's Share link opens that program." else "Viewers tap it to search the tag.")
      .setView(box)
      .setNegativeButton("Cancel", null)
      .setPositiveButton(if (editing == null) "Add" else "Save") { _, _ ->
        val raw = valueField.text.toString().trim()
        if (isLink) {
          var url = raw
          if (url.isNotEmpty() && !url.contains("://")) url = "https://$url"
          val parsed = android.net.Uri.parse(url)
          if (parsed.scheme.isNullOrEmpty() || parsed.host.isNullOrEmpty()) {
            android.widget.Toast.makeText(this, "Enter a valid link", android.widget.Toast.LENGTH_SHORT).show()
            return@setPositiveButton
          }
          val typed = labelField.text.toString().trim()
          val name = typed.ifEmpty { parsed.host!!.removePrefix("www.") }
          val state = (old ?: LocationLayerState(name, style = 0, kind = "link")).copy(name = name, value = url, kind = "link")
          if (editing != null) updateInfoSticker(editing, state) else addInfoSticker(state)
        } else {
          val tag = raw.replace("#", "").replace(" ", "")
          if (tag.isEmpty()) return@setPositiveButton
          val state = (old ?: LocationLayerState("#$tag", style = 0, kind = "hashtag")).copy(name = "#$tag", value = tag, kind = "hashtag")
          if (editing != null) updateInfoSticker(editing, state) else addInfoSticker(state)
        }
      }
      .show()
  }

  private fun addInfoSticker(state: LocationLayerState) {
    if (!canAddLayer()) return
    val textView = TextView(this)
    applyLocationSticker(textView, state)
    root.addView(
      textView,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER),
    )
    root.setClipRect(textView, canvasBoxRect)
    stickerLayerViews.add(textView)
    gestureCoordinator?.addLayer(textView)
    selectLayer(textView)
    keepSafeAreaCoversOnTop()
    registerLayerTiming(textView)
    updateLayerTimeVisibility()
    pushUndo(
      undo = {
        textView.visibility = View.GONE
        if (selectedLayerView === textView) deselectLayer()
        refreshLayersPanel()
      },
      redo = { textView.visibility = View.VISIBLE; refreshLayersPanel() },
    )
  }

  private fun updateInfoSticker(target: TextView, new: LocationLayerState) {
    val old = locationLayerStates[target] ?: return
    applyLocationSticker(target, new)
    pushUndo(undo = { applyLocationSticker(target, old) }, redo = { applyLocationSticker(target, new) })
  }

  private fun addLocationLayer(place: PlacesApi.Place) {
    val textView = TextView(this)
    applyLocationSticker(textView, LocationLayerState(place.name, style = 0, place.latitude, place.longitude))
    root.addView(
      textView,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER),
    )
    root.setClipRect(textView, canvasBoxRect)
    stickerLayerViews.add(textView)
    gestureCoordinator?.addLayer(textView)
    selectLayer(textView)
    keepSafeAreaCoversOnTop()
    registerLayerTiming(textView)
    // Same forced visibility refresh as addStickerLayer — see its comment.
    updateLayerTimeVisibility()
    pushUndo(
      undo = {
        textView.visibility = View.GONE
        if (selectedLayerView === textView) deselectLayer()
        refreshLayersPanel()
      },
      redo = { textView.visibility = View.VISIBLE; refreshLayersPanel() },
    )
  }

  /** Shows the pill as the TextView's BACKGROUND (empty text), so the view
   *  wraps exactly to the pill's size and the pill stays centered on the
   *  layer's own center — the same center every export path draws at. */
  private fun applyLocationSticker(textView: TextView, state: LocationLayerState) {
    val pill = renderLocationPillBitmap(state, resources.displayMetrics.density)
    textView.text = null
    textView.setCompoundDrawables(null, null, null, null)
    textView.setPadding(0, 0, 0, 0)
    textView.background = BitmapDrawable(resources, pill)
    locationLayerStates[textView] = state
    if (selectedLayerView === textView) textView.post { repositionLayerActionToolbar() }
  }

  /** Tapping a Location layer cycles its style (Instagram-style). */
  private fun cycleLocationLayerStyleIfNeeded(target: View) {
    val layer = target as? TextView ?: return
    val old = locationLayerStates[layer] ?: return
    val new = old.copy(style = (old.style + 1) % 3)
    applyLocationSticker(layer, new)
    pushUndo(
      undo = { applyLocationSticker(layer, old) },
      redo = { applyLocationSticker(layer, new) },
    )
  }

  /** Edit → picked a different place: keeps style + transform. */
  private fun updateLocationLayer(target: TextView, place: PlacesApi.Place) {
    val old = locationLayerStates[target] ?: return
    val new = old.copy(name = place.name, latitude = place.latitude, longitude = place.longitude)
    applyLocationSticker(target, new)
    pushUndo(
      undo = { applyLocationSticker(target, old) },
      redo = { applyLocationSticker(target, new) },
    )
  }

  /** Renders the pin + UPPERCASE place-name pill. `pxPerDp` is the screen
   *  density for the live layer, or density × exportScale at export, so
   *  both come out crisp at the same relative size. */
  private fun renderLocationPillBitmap(state: LocationLayerState, pxPerDp: Float): Bitmap {
    val isPlain = state.style == 2
    val contentColor = if (state.style == 0) Color.parseColor("#1A1A1A") else Color.WHITE
    val heightPx = 40f * pxPerDp
    val paddingX = 14f * pxPerDp
    val iconPx = 18f * pxPerDp
    val gapPx = 6f * pxPerDp
    val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
      typeface = locationPillTypeface
      textSize = 16f * pxPerDp
      color = contentColor
      if (isPlain) setShadowLayer(3f * pxPerDp, 0f, 1f * pxPerDp, Color.argb(150, 0, 0, 0))
    }
    val label = TextUtils.ellipsize(state.name.uppercase(), paint, 260f * pxPerDp, TextUtils.TruncateAt.END).toString()
    val iconRes = when (state.kind) {
      "link" -> R.drawable.ic_editor_link
      "hashtag" -> null
      "time" -> R.drawable.ic_editor_clock
      "date" -> R.drawable.ic_editor_calendar
      else -> R.drawable.ic_editor_location
    }
    val iconSpace = if (iconRes == null) 0f else iconPx + gapPx
    val width = kotlin.math.ceil(paddingX * 2 + iconSpace + paint.measureText(label)).toInt().coerceAtLeast(1)
    val height = kotlin.math.ceil(heightPx).toInt().coerceAtLeast(1)
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    if (!isPlain) {
      val pillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = if (state.style == 0) Color.WHITE else Color.parseColor("#1A1A1A")
      }
      canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), height / 2f, height / 2f, pillPaint)
    }
    iconRes?.let { ContextCompat.getDrawable(this, it) }?.mutate()?.let { icon ->
      val left = paddingX.toInt()
      val top = ((height - iconPx) / 2f).toInt()
      val size = iconPx.toInt()
      if (isPlain) {
        // Soft offset copy standing in for the text's shadow layer.
        val offset = kotlin.math.max(1, pxPerDp.toInt())
        icon.setTint(Color.argb(110, 0, 0, 0))
        icon.setBounds(left, top + offset, left + size, top + offset + size)
        icon.draw(canvas)
      }
      icon.setTint(contentColor)
      icon.setBounds(left, top, left + size, top + size)
      icon.draw(canvas)
    }
    val metrics = paint.fontMetrics
    val baseline = height / 2f - (metrics.ascent + metrics.descent) / 2f
    canvas.drawText(label, paddingX + iconSpace, baseline, paint)
    return bitmap
  }

  /** Location-sticker metadata from the most recent export (photo, video
   *  or photo+music) — sent back with the result so story viewers can tap
   *  the sticker to open maps. Written by renderExport /
   *  exportVideoOnMainThread; read by finishSuccess. */
  @Volatile private var exportedLocationStickers = JSONArray()

  /** A text/sticker layer's center in export pixels, before any output
   *  crop offset — the one formula drawLayerForExport, the video overlay
   *  placement and locationStickerJson all share. */
  private fun layerCenterInExport(layer: View, layerBaseX: Float, layerBaseY: Float, exportScale: Float): PointF =
    PointF((layerBaseX + layer.translationX) * exportScale, (layerBaseY + layer.translationY) * exportScale)

  /** One `stickers` entry. x/y = center, w/h = the UNROTATED pill box
   *  (rendered pill size × layer scale, exactly what the export draws),
   *  all as fractions of the exported media; rotation in degrees
   *  clockwise (View.rotation — also what Canvas.rotate uses). */
  private fun locationStickerJson(
    layer: View,
    state: LocationLayerState,
    centerXPx: Float,
    centerYPx: Float,
    exportScale: Float,
    mediaWidth: Int,
    mediaHeight: Int,
  ): JSONObject {
    val pill = renderLocationPillBitmap(state, resources.displayMetrics.density * exportScale)
    val widthPx = pill.width * abs(layer.scaleX)
    val heightPx = pill.height * abs(layer.scaleY)
    pill.recycle()
    val w = mediaWidth.coerceAtLeast(1).toDouble()
    val h = mediaHeight.coerceAtLeast(1).toDouble()
    return JSONObject()
      .put("type", state.kind)
      .put("name", state.name)
      .put("url", if (state.kind == "link") state.value ?: "" else "")
      .put("tag", if (state.kind == "hashtag") state.value ?: "" else "")
      .put("lat", state.latitude ?: JSONObject.NULL)
      .put("lng", state.longitude ?: JSONObject.NULL)
      .put("x", centerXPx / w)
      .put("y", centerYPx / h)
      .put("w", widthPx / w)
      .put("h", heightPx / h)
      .put("rotation", layer.rotation.toDouble())
      .put("aspect", w / h)
  }

  /** Permission (if needed) → current position, for LocationPickerDialog. */
  private fun requestCurrentLocation(callback: (LocationPickerDialog.LocationFix) -> Unit) {
    val permissions = arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    if (permissions.any { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) {
      fetchCurrentLocation(callback)
      return
    }
    pendingLocationCallback = callback
    requestPermissions(permissions, locationPermissionRequestCode)
  }

  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    if (requestCode == VOICE_PERMISSION_REQUEST_CODE) {
      if (grantResults.any { it == PackageManager.PERMISSION_GRANTED }) showVoiceRecorderPanel()
      else android.widget.Toast.makeText(this, "Allow microphone access to record a voice-over", android.widget.Toast.LENGTH_SHORT).show()
      return
    }
    if (requestCode != locationPermissionRequestCode) return
    val callback = pendingLocationCallback ?: return
    pendingLocationCallback = null
    if (grantResults.any { it == PackageManager.PERMISSION_GRANTED }) {
      fetchCurrentLocation(callback)
    } else {
      callback(LocationPickerDialog.LocationFix.Denied)
    }
  }

  /** Framework LocationManager only (no Play Services): a recent last-
   *  known fix if there is one, else a fresh single fix, falling back to
   *  the last-known fix after 8s. */
  @android.annotation.SuppressLint("MissingPermission")
  private fun fetchCurrentLocation(callback: (LocationPickerDialog.LocationFix) -> Unit) {
    val manager = getSystemService(LOCATION_SERVICE) as? LocationManager
    if (manager == null) {
      callback(LocationPickerDialog.LocationFix.Unavailable)
      return
    }
    val providers = buildList {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(LocationManager.FUSED_PROVIDER)
      add(LocationManager.NETWORK_PROVIDER)
      add(LocationManager.GPS_PROVIDER)
    }.filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
    val lastKnown = providers
      .mapNotNull { runCatching { manager.getLastKnownLocation(it) }.getOrNull() }
      .maxByOrNull { it.time }

    var delivered = false
    var timeout: Runnable? = null
    var cancelRequest: (() -> Unit)? = null
    fun deliver(location: Location?) {
      if (delivered) return
      delivered = true
      timeout?.let { locationHandler.removeCallbacks(it) }
      runCatching { cancelRequest?.invoke() }
      callback(
        location?.let { LocationPickerDialog.LocationFix.Found(it.latitude, it.longitude) }
          ?: LocationPickerDialog.LocationFix.Unavailable,
      )
    }

    val provider = providers.firstOrNull()
    if (provider == null || (lastKnown != null && System.currentTimeMillis() - lastKnown.time < 2 * 60 * 1000L)) {
      deliver(lastKnown)
      return
    }
    timeout = Runnable { deliver(lastKnown) }.also { locationHandler.postDelayed(it, 8000L) }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      val signal = CancellationSignal()
      cancelRequest = { signal.cancel() }
      runCatching {
        manager.getCurrentLocation(provider, signal, mainExecutor) { location -> deliver(location ?: lastKnown) }
      }.onFailure { deliver(lastKnown) }
    } else {
      // All four methods implemented explicitly — older framework versions
      // have no default implementations for them.
      val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) { deliver(location) }
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
      }
      cancelRequest = { manager.removeUpdates(listener) }
      runCatching {
        @Suppress("DEPRECATION")
        manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
      }.onFailure { deliver(lastKnown) }
    }
  }

  // MARK: - Image overlay layers (one photo placed on top of another)

  private fun presentImageOverlayPicker() {
    if (!canAddLayer()) return
    // Close whatever stateful panel (Effect/Edit/Sticker/Draw/Music) is
    // currently open first — only one tool should ever be active at a
    // time, per the user's explicit request. A no-op if nothing was open.
    selectedImageEditorTab = ImageEditorTab.TOOLS
    updateImageEditorUI(animated = true)
    editingImageOverlayLayer = null
    launchImagePicker()
  }

  private fun presentImageOverlayPickerForEdit(layer: ImageView) {
    editingImageOverlayLayer = layer
    launchImagePicker()
  }

  /// Android 13+'s built-in photo picker (`ACTION_PICK_IMAGES`, no storage
  /// permission needed) with a classic `ACTION_GET_CONTENT` fallback for
  /// older devices — this app's minSdk is 24, below the picker's API 33
  /// floor.
  private fun launchImagePicker() {
    val intent = if (android.os.Build.VERSION.SDK_INT >= 33) {
      Intent(android.provider.MediaStore.ACTION_PICK_IMAGES)
    } else {
      Intent(Intent.ACTION_GET_CONTENT).apply { type = "image/*" }
    }
    startActivityForResult(intent, REQUEST_CODE_PICK_OVERLAY_IMAGE)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (resultCode != Activity.RESULT_OK) return
    val uri = data?.data ?: return
    if (requestCode == REQUEST_CODE_PICK_OVERLAY_IMAGE) {
      val editing = editingImageOverlayLayer
      Thread {
        // Downsampled + EXIF-rotated (same loader as the main canvas) — a
        // full-res decode of a 48MP+ photo is ~190MB and could OOM, and
        // skipping EXIF showed some overlays sideways.
        val bitmap = runCatching {
          MediaEditorCanvasLoader.loadDownsampled(
            this, uri.toString(), MAX_OVERLAY_DECODE_PX, MAX_OVERLAY_DECODE_PX,
          )?.let { capLongSide(it, MAX_OVERLAY_LONG_SIDE_PX) }
        }.getOrNull()
        runOnUiThread {
          // Added straight away at its own shape — cropping is optional,
          // later, from the overlay's Style → Crop (per the user's request).
          if (bitmap != null) {
            if (editing != null) updateImageOverlayLayer(editing, bitmap, bitmap) else addImageOverlayLayer(bitmap, bitmap)
          }
        }
      }.start()
    } else if (requestCode == REQUEST_CODE_PICK_SECOND_VIDEO_CLIP) {
      // Per the user's explicit "when adding new video it's taking much
      // time, show activity indicator until add" report: showing then
      // immediately hiding the indicator around a plain synchronous call
      // never actually rendered it — Android batches layout/draw into one
      // pass per frame, so toggling VISIBLE->GONE within the same
      // synchronous call stack (with no frame drawn in between) means the
      // indicator's VISIBLE state was never on-screen for even one frame,
      // no matter how long didPickSecondVideoClip's own work took. Posting
      // the actual work lets the VISIBLE state's own layout/draw pass run
      // first.
      addVideoLoadingIndicatorRef?.visibility = View.VISIBLE
      addVideoLoadingIndicatorRef?.post {
        didPickSecondVideoClip(uri.toString())
        addVideoLoadingIndicatorRef?.visibility = View.GONE
      }
    }
  }

  // MARK: - Merge extra videos (queued playback, same video layer)
  //
  // Per the user's explicit "doesn't matter how many video, all video
  // clips will be added to same video layer and will be played in queue,
  // same like Instagram" request — genuinely queues in the live ExoPlayer
  // preview (via addMediaItem/removeMediaItem) as well as the exported
  // file (see exportVideo). Trim is inline, directly in the primary
  // clip's own filmstrip row (see refreshMergedClipsStrip below), per the
  // user's explicit "true single continuous filmstrip" choice. No pan/
  // zoom/filter/adjustments/text overlays of their own — those stay
  // primary-clip-only.

  private fun presentVideoClipPicker() {
    selectedImageEditorTab = ImageEditorTab.TOOLS
    updateImageEditorUI(animated = true)
    val intent = if (android.os.Build.VERSION.SDK_INT >= 33) {
      Intent(android.provider.MediaStore.ACTION_PICK_IMAGES).apply {
        type = "video/*"
      }
    } else {
      Intent(Intent.ACTION_GET_CONTENT).apply { type = "video/*" }
    }
    startActivityForResult(intent, REQUEST_CODE_PICK_SECOND_VIDEO_CLIP)
  }

  private fun didPickSecondVideoClip(uri: String) {
    additionalVideoClipUris.add(uri)
    exoPlayer?.addMediaItems(makeAdditionalPlaylistMediaItems(uri))
    // Extends every layer to the new (fallback-estimated, since the real
    // duration hasn't loaded yet) total right away for immediate
    // feedback; corrected/grown further once the real duration resolves
    // in loadAdditionalClipDuration below.
    extendLayerTimingsToCombinedDuration()
    refreshMergedClipsStrip()
    loadAdditionalClipDuration(uri)
  }

  /** Every merged clip's own kept segment, flattened into the order it
   *  occupies the player's playlist — was a direct 1:1 "playlist index
   *  i+1 = additionalVideoClipUris[i]" mapping back when each clip only
   *  ever contributed ONE MediaItem; now each contributes one PER KEPT
   *  SEGMENT, so the mapping is built explicitly instead of computed
   *  inline. Index 0 of the actual player playlist is always the primary
   *  clip — entries here start at playlist index 1. */
  private fun additionalPlaylistEntries(): List<Pair<String, Int>> =
    additionalVideoClipUris.flatMap { uri ->
      val segments = additionalClipSegments[uri] ?: listOf(0L..(additionalClipDurationsMs[uri] ?: 5000L))
      segments.indices.map { uri to it }
    }

  /** A merged clip plays UNTRIMMED (one MediaItem, the whole asset)
   *  unless the user trimmed/split it via mergedStripViewRef's inline
   *  drag handles or its own Split/Delete, in which case one clipped
   *  MediaItem PER KEPT SEGMENT is returned, meant to be added to the
   *  playlist consecutively — ExoPlayer's playlist already plays queued
   *  items back-to-back with no gap, so a merged clip needs no
   *  composition-bake (unlike iOS's AVQueuePlayer/AVMutableComposition)
   *  and no gap-skip logic of its own: each kept segment is simply its
   *  own separate playlist entry. */
  private fun makeAdditionalPlaylistMediaItems(uri: String): List<MediaItem> {
    val segments = additionalClipSegments[uri] ?: return listOf(
      MediaItem.Builder().setUri(MediaMetadataReader.normalizedUri(uri)).build(),
    )
    return segments.map { segment ->
      MediaItem.Builder()
        .setUri(MediaMetadataReader.normalizedUri(uri))
        .setClippingConfiguration(
          MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs(segment.first)
            .setEndPositionMs(segment.last)
            .build(),
        )
        .build()
    }
  }

  /** A stable, never-displayed View per merged clip, existing SOLELY so
   *  LayerRangeBarView.Item can use it as an identity token — that API
   *  (also used by real on-canvas Text/Sticker/Overlay layers) needs a
   *  genuine View reference, and a clip has no on-canvas view of its own
   *  to borrow one from. Created once per uri and reused, so identity
   *  (and therefore which row item is "selected") stays stable across
   *  refreshMergedClipsStrip rebuilds. */
  private fun proxyView(uri: String): View = additionalClipProxyViews.getOrPut(uri) { View(this) }

  private fun loadAdditionalClipDuration(uri: String) {
    Thread {
      val metadata = MediaMetadataReader.read(this, uri, "video")
      val durationMs = metadata?.let { (it.durationSeconds * 1000).toLong() }
      if (durationMs != null && durationMs > 0) {
        runOnUiThread {
          additionalClipDurationsMs[uri] = durationMs
          // Corrects/grows the estimate-based extension didPickSecondVideoClip
          // already applied, now that the real duration is known.
          extendLayerTimingsToCombinedDuration()
          refreshMergedClipsStrip()
        }
      }
    }.start()
  }

  /** Repopulates the persistent mergedStripViewRef with current
   *  merged-clip state and recomputes its share of the seamless filmstrip
   *  row's width — called whenever any merged-clip-affecting state
   *  changes (add, remove, a clip's duration/thumbnail finishing its
   *  async load). Per the user's explicit "true single continuous
   *  filmstrip" choice, this clip's own frames render as a direct,
   *  zero-gap continuation of videoTrimViewRef's own filmstrip rather
   *  than a separate row in the Layers panel (see
   *  VideoTrimView.squareTrailingCorners and
   *  LayerRangeBarView.isMergedClipsContinuation for how the seam itself
   *  is drawn seamlessly).
   *
   *  Each kept SEGMENT gets a FIXED anchor — the sum of KEPT (not full)
   *  durations of everything before it, across every clip's own segments
   *  — that never moves until the NEXT call to this function, so the bar
   *  doesn't rescale itself out from under an in-progress drag. Its
   *  item's rangeStartMs/rangeEndMs = anchorMs..anchorMs+keptLengthMs
   *  (packed back-to-back with zero gap, not offset by the segment's own
   *  real position) — edge-drag semantics are recovered in onRangeChanged
   *  via a DELTA against the reference segment captured here
   *  (mergedClipReferenceSegmentsMs), rather than by baking the segment's
   *  own offset into the item's bar position — which makes
   *  LayerRangeBarView's existing edge-drag gesture land on a genuinely
   *  meaningful video-editing action with NO changes needed to that
   *  shared component's own drag logic: drag an edge → trims that side of
   *  THIS segment's own footage, clamped against its immediate neighbor
   *  segment (if any) within the same clip.
   *  An EARLIER version anchored on FULL duration instead — that left a
   *  PERMANENT gap (not just a cosmetic in-drag one) sized to whatever had
   *  been trimmed off the preceding clip, since the item's own rendered
   *  span stopped short of its anchor-to-anchor slot's full width. Fixed
   *  per the user's explicit "these clips are not displaying same...
   *  remove trimmed portion... keep all container UI same" report.
   *  A real limitation, still accepted per the user's own earlier explicit
   *  choice: since neighboring items don't reflow to stay adjacent MID-DRAG
   *  (only once refreshMergedClipsStrip runs again, e.g. onDragEnded),
   *  shrinking one item can leave a brief visual gap next to it until that
   *  happens — purely cosmetic and now self-corrects immediately on
   *  release rather than waiting for some unrelated event; the actual
   *  export/preview always concatenates clips using their real saved trim
   *  values regardless of any visual gap. */
  private fun refreshMergedClipsStrip() {
    val rangeBar = mergedStripViewRef ?: return
    var anchorMs = 0L
    val allAnchors = mutableMapOf<String, List<Long>>()
    val allReferenceSegments = mutableMapOf<String, List<LongRange>>()
    val items = mutableListOf<LayerRangeBarView.Item>()
    for (uri in additionalVideoClipUris) {
      val fullDurationMs = additionalClipDurationsMs[uri] ?: 5000L
      val segments = additionalClipSegments[uri] ?: listOf(0L..fullDurationMs)
      val isActive = uri == activeClipUri
      val segmentAnchors = mutableListOf<Long>()
      for ((index, segment) in segments.withIndex()) {
        val keptLengthMs = segment.last - segment.first
        segmentAnchors.add(anchorMs)
        items.add(
          LayerRangeBarView.Item(
            id = proxyView(uri),
            rangeStartMs = anchorMs,
            rangeEndMs = anchorMs + keptLengthMs,
            color = EditorDesignTokens.Colors.accent,
            // Numbered only once split — an unsplit clip's single segment
            // keeps the plain "Clip" label, matching layer segments' own
            // "only number once split" convention.
            label = if (segments.size > 1) "Clip ${index + 1}" else "Clip",
            segmentIndex = index,
            thumbnailTiles = tilesForMergedClipSegment(uri, segment, fullDurationMs),
            isActive = isActive,
            // Only the FIRST segment shows the duration label, matching
            // VideoTrimView's own "one label for the whole clip, not one
            // per segment" convention.
            durationLabel = if (isActive && index == 0) durationLabelText(uri) else null,
          ),
        )
        anchorMs += keptLengthMs
      }
      allAnchors[uri] = segmentAnchors
      allReferenceSegments[uri] = segments
    }
    mergedClipSegmentAnchorsMs = allAnchors
    mergedClipReferenceSegmentsMs = allReferenceSegments
    rangeBar.configure(anchorMs.coerceAtLeast(1), items)
    rangeBar.visibility = if (additionalVideoClipUris.isEmpty()) View.GONE else View.VISIBLE
    videoTrimViewRef?.squareTrailingCorners = additionalVideoClipUris.isNotEmpty()
    for (uri in additionalVideoClipUris) {
      if (additionalClipThumbnailTiles[uri] == null) loadAdditionalClipThumbnail(uri)
    }
    updateFilmstripLayout()
  }

  /** Picks WHICH of a clip's pre-sampled (evenly across its FULL real
   *  duration, from [loadAdditionalClipThumbnail]) frames fall within one
   *  KEPT segment's own real [segment] range, for that segment's own
   *  item to tile across just its own bar width — mirrors
   *  VideoTrimView.drawCompactedThumbnails' identical per-segment
   *  filter/fallback exactly, so a merged clip that's been split reads
   *  the same way the primary clip's own split segments already do:
   *  each piece shows real frames from its own real time range, and a
   *  segment too short to contain any sample point falls back to its
   *  single nearest neighboring frame instead of a solid color gap. */
  private fun tilesForMergedClipSegment(uri: String, segment: LongRange, fullDurationMs: Long): List<Bitmap> {
    val allTiles = additionalClipThumbnailTiles[uri] ?: return emptyList()
    val tileCount = allTiles.size
    if (tileCount == 0 || fullDurationMs <= 0) return emptyList()
    val matching = (0 until tileCount).filter { index ->
      val sampleTimeMs = (fullDurationMs * (index + 0.5) / tileCount).toLong()
      sampleTimeMs >= segment.first && sampleTimeMs <= segment.last
    }
    if (matching.isNotEmpty()) return matching.map { allTiles[it] }
    val midpointMs = (segment.first + segment.last) / 2
    val nearestIndex = (0 until tileCount).minByOrNull { index ->
      val sampleTimeMs = fullDurationMs * (index + 0.5) / tileCount
      kotlin.math.abs(sampleTimeMs - midpointMs)
    } ?: return emptyList()
    return listOf(allTiles[nearestIndex])
  }

  /** Sizes videoTrimViewRef/mergedStripViewRef at a FIXED pixels-per-
   *  second scale (timelinePointsPerSecondPx) rather than proportionally
   *  fitting the screen — per the user's explicit "full Instagram-style
   *  scrolling timeline" choice, a longer combined video produces a WIDER
   *  scrollable strip instead of a squeezed one. Called on every initial-
   *  duration load, primary split/delete change, and merged-clip trim/
   *  add/remove. */
  // MARK: Timeline pinch-to-zoom

  private var timelinePinchActive = false
  private var timelinePinchEligible = false
  private var timelinePinchAnchorMs = 0L
  private val timelineScaleDetector by lazy {
    ScaleGestureDetector(this, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
      override fun onScale(detector: ScaleGestureDetector): Boolean {
        val proposed = (timelineZoomDp * detector.scaleFactor).coerceIn(TIMELINE_ZOOM_MIN_DP, TIMELINE_ZOOM_MAX_DP)
        if (kotlin.math.abs(proposed - timelineZoomDp) < 0.01f) return true
        val hitLimit = (proposed == TIMELINE_ZOOM_MIN_DP || proposed == TIMELINE_ZOOM_MAX_DP)
        timelineZoomDp = proposed
        applyTimelineScale()
        if (hitLimit) root.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        return true
      }
    }).apply { isQuickScaleEnabled = false }
  }

  private fun isInTimelineArea(rawX: Float, rawY: Float): Boolean =
    listOfNotNull(filmstripScrollViewRef, layerTracksScrollViewRef).any { view ->
      if (!view.isShown) return@any false
      val r = android.graphics.Rect()
      view.getGlobalVisibleRect(r) && r.contains(rawX.toInt(), rawY.toInt())
    }

  /** Two fingers on the clips / layer tracks zoom the timeline around the
   *  playhead (the time under it stays put); the children's own touch is
   *  cancelled once the pinch starts. Returns true when it took the event. */
  private fun handleTimelinePinch(ev: MotionEvent): Boolean {
    if (mediaType == "image" || isStoryMode) return false
    when (ev.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        timelinePinchEligible = isInTimelineArea(ev.rawX, ev.rawY)
        timelinePinchActive = false
      }
    }
    if (!timelinePinchEligible) return false
    if (!timelinePinchActive && ev.pointerCount >= 2 && ev.actionMasked == MotionEvent.ACTION_POINTER_DOWN) {
      timelinePinchActive = true
      timelinePinchAnchorMs = combinedTimeMs(filmstripScrollViewRef?.scrollX ?: 0)
      setPreviewPlaying(false)
      val cancel = MotionEvent.obtain(ev).apply { action = MotionEvent.ACTION_CANCEL }
      super.dispatchTouchEvent(cancel)
      cancel.recycle()
    }
    timelineScaleDetector.onTouchEvent(ev)
    val consumed = timelinePinchActive
    if (ev.actionMasked == MotionEvent.ACTION_UP || ev.actionMasked == MotionEvent.ACTION_CANCEL) {
      timelinePinchActive = false
      timelinePinchEligible = false
    }
    return consumed
  }

  override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
    if (handleTimelinePinch(ev)) return true
    return super.dispatchTouchEvent(ev)
  }

  /** Re-sizes the clips strip and every track row for the current zoom,
   *  keeping the pinch's anchor time under the playhead. */
  private fun applyTimelineScale() {
    updateFilmstripLayout()
    layerTracksStackRef?.let { stack ->
      for (i in 0 until stack.childCount) {
        val bar = stack.getChildAt(i) as? LayerRangeBarView ?: continue
        val params = bar.layoutParams ?: continue
        params.width = ((bar.durationMs / 1000.0) * timelinePointsPerSecondPx).toInt().coerceAtLeast(1)
        bar.layoutParams = params
        bar.invalidate()
      }
    }
    videoTrimViewRef?.invalidate()
    mergedStripViewRef?.invalidate()
    val anchor = timelinePinchAnchorMs
    filmstripScrollViewRef?.post { filmstripScrollViewRef?.scrollTo(scrollXForCombinedTimeMs(anchor), 0) }
  }

  private fun updateFilmstripLayout() {
    val trimView = videoTrimViewRef ?: return
    val mergedView = mergedStripViewRef ?: return
    val trimParams = trimView.layoutParams as? LinearLayout.LayoutParams ?: return
    val mergedParams = mergedView.layoutParams as? LinearLayout.LayoutParams ?: return

    val primaryKeptDurationMs = videoSegments.sumOf { it.last - it.first }
    val mergedKeptDurationMs = additionalVideoClipUris.sumOf { additionalClipKeptDurationMs(it) }
    val primaryWidthPx = ((primaryKeptDurationMs / 1000.0) * timelinePointsPerSecondPx).toInt().coerceAtLeast(1)
    val mergedWidthPx = ((mergedKeptDurationMs / 1000.0) * timelinePointsPerSecondPx).toInt()
    trimParams.width = primaryWidthPx
    mergedParams.width = mergedWidthPx
    trimView.layoutParams = trimParams
    mergedView.layoutParams = mergedParams

    // Matches the SAME total width as videoTrimViewRef+mergedStripViewRef
    // combined — layerTracksStackRef's own scrollTo mirror (see
    // filmstripScrollViewRef's OnScrollChangeListener) needs this to be
    // the FULL combined width, not just whichever row is individually
    // widest, or it would run out of content to scroll into before the
    // video row does.
    layerTracksStackRef?.layoutParams?.let { params ->
      params.width = primaryWidthPx + mergedWidthPx
      layerTracksStackRef?.layoutParams = params
    }

    filmstripScrollViewRef?.post {
      updateFilmstripContentPaddingIfNeeded()
      updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer = isUserScrubbingFilmstrip)
      lastVideoTimeLabelText = ""
      updateVideoTimeLabel(combinedTimeMs(filmstripScrollViewRef?.scrollX ?: 0))
    }
  }

  private var videoSelectionLabelRef: TextView? = null

  private fun updateVideoSelectionLabel() {
    val label = videoSelectionLabelRef ?: return
    val text = when {
      selectedMusicSegmentIndex != null -> "Music"
      selectedLayerView != null -> if (selectedLayerView in textLayerViews) "Text" else "Sticker"
      activeClipUri != null && additionalVideoClipUris.indexOf(activeClipUri) >= 0 -> "Clip ${additionalVideoClipUris.indexOf(activeClipUri) + 2}"
      else -> ""
    }
    if (label.text.toString() != text) label.text = text
    updateLayerStateButtons()
  }

  // MARK: Speed control (roadmap row 28)

  /** A clip's kept parts in source time (main clip = mediaUri / null). */
  private fun clipParts(uri: String?): List<LongRange> =
    if (uri == null || uri == mediaUri) videoSegments
    else additionalClipSegments[uri] ?: listOf(0L..(additionalClipDurationsMs[uri] ?: 5000L))

  /** Speed of one part of a clip (its source range). */
  private fun partSpeed(uri: String?, part: LongRange): Float {
    val mid = part.first + (part.last - part.first) / 2
    return speedSpans[uri ?: mediaUri]?.lastOrNull { mid in it.range }?.speed ?: 1f
  }

  /** Sets one part's speed; a never-split merged clip covers its whole
   *  source so a late-loading duration can't move it. */
  private fun setPartSpeedSpan(uri: String, part: LongRange, speed: Float) {
    val spans = speedSpans.getOrPut(uri) { mutableListOf() }
    val range = if (uri != mediaUri && additionalClipSegments[uri] == null) 0L..(Long.MAX_VALUE / 4) else part
    spans.removeAll { it.range.first >= range.first && it.range.last <= range.last }
    spans.add(SpeedSpan(range, speed))
  }

  /** Every part on the combined timeline in order: (combined start, kept
   *  length, speed). */
  private fun timelineSpeedParts(): List<Triple<Long, Long, Float>> {
    val parts = mutableListOf<Triple<Long, Long, Float>>()
    for (block in timelineBlocks()) {
      var cursor = block.combinedStartMs
      for (part in clipParts(block.uri)) {
        val kept = part.last - part.first
        parts.add(Triple(cursor, kept, partSpeed(block.uri, part)))
        cursor += kept
      }
    }
    return parts
  }

  /** Speed of the part the player is in right now. */
  private fun currentPlayingPartSpeed(): Float {
    val player = exoPlayer ?: return 1f
    if (player.currentMediaItemIndex == 0) {
      val localMs = player.currentPosition
      val part = videoSegments.lastOrNull { it.first <= localMs } ?: videoSegments.firstOrNull() ?: return 1f
      return partSpeed(mediaUri, part)
    }
    val (uri, index) = additionalPlaylistEntries().getOrNull(player.currentMediaItemIndex - 1) ?: return 1f
    val part = clipParts(uri).getOrNull(index) ?: return 1f
    return partSpeed(uri, part)
  }

  /** Preview plays the current part at its own speed (pitch kept); called
   *  every timeline poll so the speed switches as playback crosses parts. */
  private fun applyPreviewSpeed() {
    val player = exoPlayer ?: return
    val speed = currentPlayingPartSpeed()
    if (player.playbackParameters.speed != speed) player.playbackParameters = androidx.media3.common.PlaybackParameters(speed)
  }

  /** The part the Speed sheet edits: the tapped part of the selected clip,
   *  else the one under the playhead, else its first. */
  private fun selectedSpeedPart(uri: String): Pair<Int, LongRange>? {
    val parts = clipParts(uri)
    val tapped = if (uri == mediaUri) videoTrimViewRef?.selectedSegmentIndex else selectedMergedClipSegmentIndex
    tapped?.let { i -> parts.getOrNull(i)?.let { return i to it } }
    val player = exoPlayer
    if (player != null) {
      if (uri == mediaUri && player.currentMediaItemIndex == 0) {
        val i = videoSegments.indexOfLast { it.first <= player.currentPosition }
        parts.getOrNull(i)?.let { return i to it }
      } else {
        additionalPlaylistEntries().getOrNull(player.currentMediaItemIndex - 1)?.takeIf { it.first == uri }?.let { (_, i) ->
          parts.getOrNull(i)?.let { return i to it }
        }
      }
    }
    return parts.firstOrNull()?.let { 0 to it }
  }

  private var speedSheetRef: View? = null
  private var speedValueRef: TextView? = null
  private var speedDurationRef: TextView? = null

  /** Edits-style Speed sheet (same design as iOS): ✕ · Speed · ✓, the big
   *  value, the clip's length before → after, and a ruler (0.25x–4x,
   *  doubling per step, 1x in the middle). The clip plays at the new speed
   *  while dragging. */
  /** Plays / pauses the preview like the play button, but by intent
   *  (playWhenReady) — isPlaying is false while buffering after a seek,
   *  which made a "pause if playing" check miss. */
  private fun setPreviewPlaying(play: Boolean) {
    val player = exoPlayer ?: return
    if (player.playWhenReady == play) return
    playPauseButtonRef?.performClick()
    if (player.playWhenReady != play) {
      // The button toggles on isPlaying; force the intended state.
      if (play) player.play() else { player.pause(); musicPlayer?.pause() }
      ((playPauseButtonRef as? ViewGroup)?.getChildAt(0) as? EditorIconView)?.icon = if (play) EditorIcon.PAUSE else EditorIcon.PLAY
    }
  }

  private fun showClipSpeedPicker() {
    val uri = selectedClipUriForActions() ?: return
    if (speedSheetRef != null) return
    val (partIndex, part) = selectedSpeedPart(uri) ?: return
    val original = partSpeed(uri, part)
    val originalSpans = speedSpans[uri]?.toList()
    val isMain = uri == mediaUri
    val sourceLengthMs = part.last - part.first
    val density = resources.displayMetrics.density
    fun px(dp: Float) = (dp * density).toInt()
    fun barButton(icon: EditorIcon, tint: Int, label: String, onClick: () -> Unit) = FrameLayout(this).apply {
      addView(EditorIconView(this@MediaEditorActivity, icon).apply { iconTint = tint }, FrameLayout.LayoutParams(px(22f), px(22f), Gravity.CENTER))
      contentDescription = label
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        onClick()
      }
    }
    val value = TextView(this).apply {
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
      typeface = Typeface.DEFAULT_BOLD
      fontFeatureSettings = "tnum"
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      gravity = Gravity.CENTER
    }
    val durations = TextView(this).apply {
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      fontFeatureSettings = "tnum"
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      gravity = Gravity.CENTER
    }
    val ruler = SpeedRulerView(this).apply {
      this.value = original
      onChange = { speed ->
        setPartSpeedSpan(uri, part, speed)
        applyPreviewSpeed()
        updateSpeedSheetLabels(speed, sourceLengthMs)
        refreshVideoTimeLabel()
      }
    }
    val sheet = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(px(12f), px(8f), px(12f), px(10f) + navigationBarHeightPx)
      background = GradientDrawable().apply {
        cornerRadii = floatArrayOf(22f * density, 22f * density, 22f * density, 22f * density, 0f, 0f, 0f, 0f)
        setColor(EditorDesignTokens.Colors.panelBackground)
      }
      isClickable = true
      addView(LinearLayout(this@MediaEditorActivity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(barButton(EditorIcon.CLOSE, EditorDesignTokens.Colors.textPrimary, "Cancel") { closeSpeedSheet(uri, part, originalSpans, apply = false) }, LinearLayout.LayoutParams(px(44f), px(44f)))
        addView(TextView(this@MediaEditorActivity).apply {
          text = "Speed"
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
          typeface = Typeface.DEFAULT_BOLD
          setTextColor(EditorDesignTokens.Colors.textPrimary)
          gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        addView(barButton(EditorIcon.CHECK, EditorDesignTokens.Colors.accent, "Apply speed") { closeSpeedSheet(uri, part, originalSpans, apply = true) }, LinearLayout.LayoutParams(px(44f), px(44f)))
      })
      addView(value, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(6f) })
      addView(durations, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(6f) })
      addView(ruler, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, px(72f)).apply { topMargin = px(14f) })
      addView(TextView(this@MediaEditorActivity).apply {
        text = "Voices keep their normal pitch"
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setTextColor(EditorDesignTokens.Colors.textSecondary)
        gravity = Gravity.CENTER
      }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(6f) })
    }
    root.addView(sheet, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
    // Above the tool rail, which has its own elevation (z-order alone
    // isn't enough — elevated views draw on top).
    sheet.elevation = 32f * density
    sheet.bringToFront()
    speedSheetRef = sheet
    speedValueRef = value
    speedDurationRef = durations
    updateSpeedSheetLabels(original, sourceLengthMs)

    // Play the part from its start so the new speed can be seen.
    timelineBlocks().firstOrNull { if (isMain) it.uri == null else it.uri == uri }?.let { block ->
      val partStartMs = block.combinedStartMs + clipParts(uri).take(partIndex).sumOf { it.last - it.first }
      seekCombinedTimeline(partStartMs)
      filmstripScrollViewRef?.scrollTo(scrollXForCombinedTimeMs(partStartMs), 0)
    }
    setPreviewPlaying(true)
    sheet.translationY = 320f * density
    sheet.animate().translationY(0f).setDuration(250).start()
  }

  private fun updateSpeedSheetLabels(speed: Float, sourceLengthMs: Long) {
    speedValueRef?.text = speedTitle(speed)
    fun fmt(ms: Long): String {
      val tenths = (ms / 100.0).roundToInt()
      return String.format(java.util.Locale.US, "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
    speedDurationRef?.text = "Part ${fmt(sourceLengthMs)} → ${fmt((sourceLengthMs / speed).toLong())}"
  }

  private fun speedTitle(speed: Float): String {
    val r = (speed * 100).roundToInt() / 100f
    return when {
      r % 1f == 0f -> "${r.toInt()}x"
      (r * 10) % 1f == 0f -> String.format(java.util.Locale.US, "%.1fx", r)
      else -> String.format(java.util.Locale.US, "%.2fx", r)
    }
  }

  private fun closeSpeedSheet(uri: String, part: LongRange, originalSpans: List<SpeedSpan>?, apply: Boolean) {
    val sheet = speedSheetRef ?: return
    val chosenSpans = speedSpans[uri]?.toList()
    speedSheetRef = null
    setPreviewPlaying(false)
    sheet.animate().translationY(sheet.height.toFloat()).setDuration(200).withEndAction { root.removeView(sheet) }.start()
    val changed = partSpeedOf(originalSpans, part) != partSpeedOf(chosenSpans, part)
    if (!apply || !changed) {
      setSpeedSpans(uri, originalSpans)
      return
    }
    setSpeedSpans(uri, chosenSpans)
    pushUndo(undo = { setSpeedSpans(uri, originalSpans) }, redo = { setSpeedSpans(uri, chosenSpans) })
  }

  private fun partSpeedOf(spans: List<SpeedSpan>?, part: LongRange): Float {
    val mid = part.first + (part.last - part.first) / 2
    return spans?.lastOrNull { mid in it.range }?.speed ?: 1f
  }

  private fun setSpeedSpans(uri: String, spans: List<SpeedSpan>?) {
    if (spans.isNullOrEmpty()) speedSpans.remove(uri) else speedSpans[uri] = spans.toMutableList()
    applyPreviewSpeed()
    refreshVideoTimeLabel()
    updateLayerStateButtons()
  }

  // MARK: Beat sync

  private fun updateBeatSyncNote() {
    beatSyncNoteRef?.text = when {
      selectedMusicTrack == null -> "Add a music track to find its beats"
      musicBeatsMs.isEmpty() -> "Finding the beats…"
      else -> "${musicBeatsMs.size} beats found · shown as dots on the music track. Cuts and layer edges snap to them."
    }
  }

  private fun detectBeats(track: MusicTrack) {
    Thread {
      val beats = BeatDetector.beatsMs(this, android.net.Uri.parse(track.audioUrl))
      runOnUiThread {
        if (selectedMusicTrack?.audioUrl != track.audioUrl) return@runOnUiThread
        musicBeatsMs = beats
        updateBeatSyncNote()
        refreshLayersPanel()
      }
    }.start()
  }

  /** Beats on the combined timeline: the chosen song section, placed where
   *  the music starts (same anchor as playback / export). */
  private fun combinedBeatTimesMs(): List<Long> {
    if (musicBeatsMs.isEmpty()) return emptyList()
    val anchor = musicSegments.firstOrNull()?.first ?: musicOffsetMs
    val times = musicBeatsMs.filter { it in musicTrimStartMs..musicTrimEndMs }.map { anchor + (it - musicTrimStartMs) }
    if (musicSegments.isEmpty()) return times
    return times.filter { t -> musicSegments.any { t in it } }
  }

  private fun nearestBeatMs(t: Long, withinMs: Long): Long? {
    val beat = combinedBeatTimesMs().minByOrNull { kotlin.math.abs(it - t) } ?: return null
    return if (kotlin.math.abs(beat - t) <= withinMs) beat else null
  }

  /** Snaps each edge of a layer's time pieces to a beat within 150 ms. */
  private fun snapLayerTimingToBeats(layer: View) {
    val timing = layerTimings[layer] ?: return
    timing.segments = timing.segments.map { seg ->
      val lo = nearestBeatMs(seg.first, 150) ?: seg.first
      val hi = nearestBeatMs(seg.last, 150) ?: seg.last
      if (hi - lo >= 500) lo..hi else seg
    }.toMutableList()
    updateLayerTimeVisibility()
  }

  // MARK: Voice-over

  /** Ducking (0.3 while the voice-over plays, 150 ms ramps) at combined time [t]. */
  private fun voiceDuckFactor(t: Long): Float {
    if (voiceOverPath == null || voiceOverDurationMs <= 0) return 1f
    val start = voiceOverStartMs
    val end = voiceOverStartMs + voiceOverDurationMs
    val ramp = 150L
    if (t <= start - ramp || t >= end + ramp) return 1f
    if (t in start..end) return VOICE_DUCK_LEVEL
    val edge = if (t < start) (start - t).toFloat() / ramp else (t - end).toFloat() / ramp
    return VOICE_DUCK_LEVEL + (1f - VOICE_DUCK_LEVEL) * edge.coerceIn(0f, 1f)
  }

  /** Export: a silent gap then the voice-over, as its own audio sequence. */
  private fun buildVoiceSequence(windowOutMs: LongRange?, totalOutMs: Long): EditedMediaItemSequence? {
    val path = voiceOverPath ?: return null
    val window = windowOutMs ?: return null
    val start = window.first.coerceIn(0, totalOutMs)
    val length = minOf(voiceOverDurationMs, totalOutMs - start)
    if (length <= 50) return null
    val items = mutableListOf<EditedMediaItem>()
    if (start > 0) {
      createSilentAudioFile(start)?.let { items.add(EditedMediaItem.Builder(MediaItem.fromUri(android.net.Uri.fromFile(it))).build()) }
    }
    val voiceItem = MediaItem.Builder()
      .setUri(android.net.Uri.fromFile(File(path)))
      .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setEndPositionMs(length).build())
      .build()
    items.add(EditedMediaItem.Builder(voiceItem).setRemoveVideo(true).build())
    return EditedMediaItemSequence(items)
  }

  /** Plays the voice-over in the preview while playback is inside its span. */
  private fun updateVoicePlaybackWindow() {
    val player = voicePlayer ?: return
    if (voiceRecorder != null) return
    val t = combinedTimeForCurrentPlaybackMs()
    val inside = t >= voiceOverStartMs && t < voiceOverStartMs + voiceOverDurationMs
    if (exoPlayer?.isPlaying == true && inside) {
      if (!player.isPlaying) {
        player.seekTo((t - voiceOverStartMs).toInt().coerceAtLeast(0))
        player.start()
      }
    } else if (player.isPlaying) {
      player.pause()
    }
  }

  private fun makeVoiceRow(durationMs: Long): View {
    val end = minOf(voiceOverStartMs + voiceOverDurationMs, durationMs)
    return LayerRangeBarView(this).apply {
      snapTargets = { id, segment -> trackSnapTargets(id, segment) }
      allowBodyDrag = true
      // Moves only once selected (tap first), like the layer tracks.
      bodyDragRequiresSelection = true
      edgeDragEnabled = false
      reorderEnabled = false
      configure(
        durationMs,
        listOf(
          LayerRangeBarView.Item(
            id = voiceProxyView,
            rangeStartMs = voiceOverStartMs.coerceAtMost((end - 100).coerceAtLeast(0)),
            rangeEndMs = end,
            color = EditorDesignTokens.Colors.voiceLayer,
            label = "Voice-over",
            badgeText = "🎙",
          ),
        ),
      )
      onRangeChanged = { _, _, newStartMs, _ ->
        voiceOverStartMs = newStartMs
        voicePlayer?.takeIf { it.isPlaying }?.pause()
      }
      voiceRangeBarRef = this
      if (isVoiceRowSelected) setSelection(voiceProxyView, 0)
      onItemSelected = { _, _ ->
        deselectLayer()
        videoTrimViewRef?.clearSegmentSelection()
        selectedMergedClipUri = null
        selectedMergedClipSegmentIndex = null
        selectedMusicSegmentIndex = null
        isVoiceRowSelected = true
        updateLayerStateButtons()
      }
      onUnhandledDragDeltaX = { deltaX ->
        filmstripScrollViewRef?.let { sv ->
          isUserScrubbingFilmstrip = true
          sv.scrollBy((-deltaX).toInt(), 0)
        }
      }
    }
  }

  private data class VoiceOverSnapshot(val path: String?, val startMs: Long, val durationMs: Long)

  private fun applyVoiceOver(snap: VoiceOverSnapshot) {
    voicePlayer?.release()
    voicePlayer = null
    voiceOverPath = snap.path
    voiceOverStartMs = snap.startMs
    voiceOverDurationMs = snap.durationMs
    snap.path?.let { path ->
      voicePlayer = runCatching { android.media.MediaPlayer().apply { setDataSource(path); prepare() } }.getOrNull()
    }
    isVoiceRowSelected = false
    refreshLayersPanel()
    exoPlayer?.volume = effectivePlayerVolume()
  }

  private fun deleteVoiceOver() {
    val before = VoiceOverSnapshot(voiceOverPath, voiceOverStartMs, voiceOverDurationMs)
    applyVoiceOver(VoiceOverSnapshot(null, 0, 0))
    pushUndo(undo = { applyVoiceOver(before) }, redo = { applyVoiceOver(VoiceOverSnapshot(null, 0, 0)) })
  }

  private fun presentVoiceRecorder() {
    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
      showVoiceRecorderPanel()
    } else {
      requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), VOICE_PERMISSION_REQUEST_CODE)
    }
  }

  /** Records narration from the playhead while the video plays muted. */
  private fun showVoiceRecorderPanel() {
    if (voiceRecorderPanelRef != null) return
    pauseVideoForToolInteraction()
    val density = resources.displayMetrics.density
    fun px(dp: Float) = (dp * density).toInt()
    val time = TextView(this).apply {
      text = "0:00"
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
      typeface = Typeface.DEFAULT_BOLD
      fontFeatureSettings = "tnum"
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      gravity = Gravity.CENTER
    }
    val recordIcon = EditorIconView(this, EditorIcon.MIC).apply { iconTint = Color.WHITE }
    val record = FrameLayout(this).apply {
      background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(EditorDesignTokens.Colors.danger) }
      addView(recordIcon, FrameLayout.LayoutParams(px(28f), px(28f), Gravity.CENTER))
      contentDescription = "Start recording"
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        toggleVoiceRecording()
      }
    }
    val panel = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(px(20f), px(18f), px(20f), px(12f) + navigationBarHeightPx)
      background = GradientDrawable().apply {
        cornerRadii = floatArrayOf(22f * density, 22f * density, 22f * density, 22f * density, 0f, 0f, 0f, 0f)
        setColor(EditorDesignTokens.Colors.panelBackground)
      }
      isClickable = true
      addView(TextView(this@MediaEditorActivity).apply {
        text = "Voice-over"
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
        typeface = Typeface.DEFAULT_BOLD
        setTextColor(EditorDesignTokens.Colors.textPrimary)
      })
      addView(TextView(this@MediaEditorActivity).apply {
        text = "Records from the playhead. Tap again to stop."
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setTextColor(EditorDesignTokens.Colors.textSecondary)
      })
      addView(time, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(10f) })
      addView(record, LinearLayout.LayoutParams(px(64f), px(64f)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = px(10f) })
      addView(TextView(this@MediaEditorActivity).apply {
        text = "Cancel"
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        setTextColor(EditorDesignTokens.Colors.textPrimary)
        gravity = Gravity.CENTER
        setPadding(0, px(12f), 0, px(4f))
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
          finishVoiceRecording(keep = false)
        }
      }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
    root.addView(panel, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
    panel.elevation = 32f * density
    panel.bringToFront()
    voiceRecorderPanelRef = panel
    voiceRecorderTimeRef = time
    voiceRecordIconRef = recordIcon
  }

  private val voiceRecordTick = object : Runnable {
    override fun run() {
      if (voiceRecorder == null) return
      val secs = ((android.os.SystemClock.elapsedRealtime() - voiceRecordingWallStart) / 1000).toInt()
      voiceRecorderTimeRef?.text = String.format(java.util.Locale.US, "%d:%02d", secs / 60, secs % 60)
      musicPlayer?.takeIf { it.isPlaying }?.pause()
      // Stop where the video ends (the take can't run past it).
      if (android.os.SystemClock.elapsedRealtime() - voiceRecordingWallStart >= combinedLayerDurationMs() - voiceRecordingStartMs - 50) {
        finishVoiceRecording(keep = true)
        return
      }
      voiceRecordHandler.postDelayed(this, 100)
    }
  }

  private fun toggleVoiceRecording() {
    if (voiceRecorder != null) {
      finishVoiceRecording(keep = true)
      return
    }
    val path = File(cacheDir, "voice-${UUID.randomUUID()}.m4a").absolutePath
    @Suppress("DEPRECATION")
    val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) android.media.MediaRecorder(this) else android.media.MediaRecorder()
    val started = runCatching {
      recorder.setAudioSource(android.media.MediaRecorder.AudioSource.MIC)
      recorder.setOutputFormat(android.media.MediaRecorder.OutputFormat.MPEG_4)
      recorder.setAudioEncoder(android.media.MediaRecorder.AudioEncoder.AAC)
      recorder.setAudioSamplingRate(44_100)
      recorder.setAudioEncodingBitRate(128_000)
      recorder.setOutputFile(path)
      recorder.prepare()
      recorder.start()
    }.isSuccess
    if (!started) {
      recorder.release()
      android.widget.Toast.makeText(this, "Couldn't start recording", android.widget.Toast.LENGTH_SHORT).show()
      return
    }
    voiceRecorder = recorder
    voiceRecordingPath = path
    tempFilesToDelete += File(path)
    voiceRecordingStartMs = combinedTimeForCurrentPlaybackMs()
    voiceRecordingWallStart = android.os.SystemClock.elapsedRealtime()
    voicePlayer?.takeIf { it.isPlaying }?.pause()
    // The video stays paused while recording (user request) — the mic only
    // hears the voice, and the take is placed at the playhead.
    setPreviewPlaying(false)
    exoPlayer?.volume = 0f
    musicPlayer?.takeIf { it.isPlaying }?.pause()
    voiceRecordIconRef?.icon = EditorIcon.PAUSE
    voiceRecordHandler.post(voiceRecordTick)
  }

  private fun finishVoiceRecording(keep: Boolean) {
    voiceRecordHandler.removeCallbacks(voiceRecordTick)
    val recorder = voiceRecorder
    val durationMs = android.os.SystemClock.elapsedRealtime() - voiceRecordingWallStart
    val stoppedOk = recorder?.let { runCatching { it.stop() }.isSuccess } ?: false
    recorder?.release()
    voiceRecorder = null
    setPreviewPlaying(false)
    exoPlayer?.volume = effectivePlayerVolume()
    voiceRecorderPanelRef?.let { root.removeView(it) }
    voiceRecorderPanelRef = null
    val path = voiceRecordingPath
    if (!keep || recorder == null) return
    if (!stoppedOk || path == null || durationMs < 300) {
      android.widget.Toast.makeText(this, "Too short — hold the recording a little longer", android.widget.Toast.LENGTH_SHORT).show()
      return
    }
    val before = VoiceOverSnapshot(voiceOverPath, voiceOverStartMs, voiceOverDurationMs)
    val after = VoiceOverSnapshot(path, voiceRecordingStartMs, durationMs)
    applyVoiceOver(after)
    pushUndo(undo = { applyVoiceOver(before) }, redo = { applyVoiceOver(after) })
  }

  // MARK: Text animations

  /** Preview of a text layer's animation: scale / slide / spin via the
   *  view's animation matrix (on top of the user's own transform, Android
   *  10+), typewriter / wipe via clip bounds. Alpha is applied by the
   *  caller. */
  private fun applyTextAnimationPreview(layer: View, anim: TextAnimation.State) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      if (anim.scale == 1f && anim.offsetX == 0f && anim.offsetY == 0f && anim.rotation == 0f) {
        if (layer.animationMatrix != null) layer.animationMatrix = null
      } else {
        val canvasWidth = canvasBoxRect?.width() ?: root.width
        val canvasHeight = canvasBoxRect?.height() ?: root.height
        // The matrix works in the layer's own (rotated, scaled) space, so
        // the on-screen offset is turned back by the layer's rotation.
        val dx = anim.offsetX * canvasWidth
        val dy = anim.offsetY * canvasHeight
        val r = Math.toRadians(-layer.rotation.toDouble())
        val localX = (dx * kotlin.math.cos(r) - dy * kotlin.math.sin(r)).toFloat() / layer.scaleX.coerceAtLeast(0.01f)
        val localY = (dx * kotlin.math.sin(r) + dy * kotlin.math.cos(r)).toFloat() / layer.scaleY.coerceAtLeast(0.01f)
        val m = android.graphics.Matrix()
        m.postScale(anim.scale, anim.scale, layer.width / 2f, layer.height / 2f)
        m.postRotate(anim.rotation, layer.width / 2f, layer.height / 2f)
        m.postTranslate(localX, localY)
        layer.animationMatrix = m
      }
    }
    val clip = if (anim.reveal < 1f) android.graphics.Rect(0, -layer.height, (layer.width * anim.reveal).toInt(), layer.height * 2) else null
    if (layer.clipBounds != clip) layer.clipBounds = clip
  }

  private var textAnimationSheetRef: TextAnimationSheetView? = null

  /** Opens the Animation sheet (In / Out / Loop tiles + duration, same
   *  design as iOS) for the selected text layer. Each pick plays on the
   *  video right away; ✕ reverts, ✓ keeps it as one undo step. */
  private fun showTextAnimationMenu() {
    if (textAnimationSheetRef != null) return
    val layer = selectedLayerView?.takeIf { it in textLayerViews && it !in stickerLayerViews } ?: return
    val original = layerTimings[layer]?.anim ?: return
    val sheet = TextAnimationSheetView(this, original, navigationBarHeightPx)
    sheet.onChange = { config, tab ->
      setTextAnimation(layer, config)
      previewTextAnimation(layer, tab)
    }
    sheet.onClose = { apply ->
      closeTextAnimationSheet()
      val chosen = layerTimings[layer]?.anim ?: original
      if (!apply) {
        setTextAnimation(layer, original)
      } else if (chosen != original) {
        pushUndo(undo = { setTextAnimation(layer, original) }, redo = { setTextAnimation(layer, chosen) })
      }
    }
    root.addView(sheet, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
    // Above the tool rail, which has its own elevation.
    sheet.elevation = 32f * resources.displayMetrics.density
    sheet.bringToFront()
    textAnimationSheetRef = sheet
    sheet.translationY = 420f * resources.displayMetrics.density
    sheet.animate().translationY(0f).setDuration(250).start()
  }

  private fun closeTextAnimationSheet() {
    val sheet = textAnimationSheetRef ?: return
    textAnimationSheetRef = null
    // Story mode has no play button: the story keeps looping.
    if (!isStoryMode) setPreviewPlaying(false)
    sheet.animate().translationY(sheet.height.toFloat()).setDuration(200).withEndAction { root.removeView(sheet) }.start()
  }

  /** Plays the part of the piece under the playhead where the open tab's
   *  animation shows: its start (In / Loop) or just before its end (Out). */
  private fun previewTextAnimation(layer: View, tab: Int) {
    val timing = layerTimings[layer] ?: return
    val now = combinedTimeForCurrentPlaybackMs()
    val seg = timing.segments.firstOrNull { now in it } ?: timing.segments.firstOrNull() ?: return
    var target = seg.first
    if (tab == 1) {
      val d = minOf(timing.anim.outDurationMs, (seg.last - seg.first) / 2)
      target = maxOf(seg.first, seg.last - d - 400)
    }
    seekCombinedTimeline(target)
    if (!isStoryMode) filmstripScrollViewRef?.scrollTo(scrollXForCombinedTimeMs(target), 0)
    setPreviewPlaying(true)
    // Music jumps with the video (re-placed by the playback window).
    if (!isStoryMusicPausedByUser) {
      musicPlayer?.pause()
      updateMusicPlaybackWindow()
    }
    updateLayerTimeVisibility()
  }

  private fun setTextAnimation(layer: View, config: TextAnimConfig) {
    val timing = layerTimings[layer] ?: return
    timing.anim = config
    updateLayerTimeVisibility()
    updateLayerStateButtons()
  }

  // MARK: Transitions (roadmap row 33)

  private fun showClipTransitionPicker() {
    val uri = selectedMergedClipUri ?: return
    val titles = arrayOf("None", "Fade", "Slide", "Zoom")
    val current = transitionsIn[uri] ?: 0
    AlertDialog.Builder(this)
      .setTitle("Transition into this clip")
      .setSingleChoiceItems(titles, current) { dialog, which ->
        dialog.dismiss()
        if (which == current) return@setSingleChoiceItems
        setTransition(which, uri)
        pushUndo(undo = { setTransition(current, uri) }, redo = { setTransition(which, uri) })
      }
      .setNegativeButton("Cancel", null)
      .show()
  }

  private fun setTransition(type: Int, uri: String) {
    if (type == 0) transitionsIn.remove(uri) else transitionsIn[uri] = type
    updateLayerStateButtons()
  }

  /** Live preview of transitions at clip boundaries (same look as the
   *  export's ClipTransitionEffect), on the video surface only. */
  private fun updateTransitionPreview() {
    val surface = playerViewRef?.videoSurfaceView ?: return
    var type = 0
    var amount = 0f
    var incoming = false
    if (transitionsIn.isNotEmpty() && mediaType != "image") {
      val t = combinedTimeForCurrentPlaybackMs()
      val d = ClipTransitionEffect.TRANSITION_DURATION_US / 1000
      val blocks = timelineBlocks()
      for (i in 1 until blocks.size) {
        val uri = blocks[i].uri ?: continue
        val kind = transitionsIn[uri] ?: continue
        val boundary = blocks[i].combinedStartMs
        if (t >= boundary - d && t < boundary) {
          type = kind; amount = 1f - (boundary - t).toFloat() / d; incoming = false
        } else if (t >= boundary && t < boundary + d) {
          type = kind; amount = 1f - (t - boundary).toFloat() / d; incoming = true
        }
      }
    }
    amount = amount.coerceIn(0f, 1f)
    if (type == 0 || amount <= 0f) {
      if (surface.alpha != 1f || surface.translationX != 0f || surface.scaleX != 1f) {
        surface.alpha = 1f; surface.translationX = 0f; surface.scaleX = 1f; surface.scaleY = 1f
      }
      return
    }
    when (type) {
      2 -> { surface.alpha = 1f; surface.scaleX = 1f; surface.scaleY = 1f; surface.translationX = amount * surface.width * (if (incoming) 1f else -1f) }
      3 -> { surface.alpha = 1f - amount; surface.translationX = 0f; surface.scaleX = 1f + 0.25f * amount; surface.scaleY = 1f + 0.25f * amount }
      else -> { surface.alpha = 1f - amount; surface.translationX = 0f; surface.scaleX = 1f; surface.scaleY = 1f }
    }
  }

  // MARK: Clip management (duplicate, per-clip volume, remove)

  private fun clipVolume(uri: String?): Float = clipVolumes[uri ?: mediaUri] ?: 1f

  /** Original-audio volume × the playing clip's own volume. */
  private fun effectivePlayerVolume(): Float =
    originalAudioVolume * clipVolume(activeClipUri) * originalFadeFactor(combinedTimeForCurrentPlaybackMs()) *
      voiceDuckFactor(combinedTimeForCurrentPlaybackMs())

  /** Fade in/out audio: gain (0…1) of the clip's own sound at combined time [t]. */
  private fun originalFadeFactor(t: Long): Float {
    if (!audioFadeIn && !audioFadeOut) return 1f
    val total = combinedLayerDurationMs()
    var g = 1f
    if (audioFadeIn) g = minOf(g, t / AUDIO_FADE_MS.toFloat())
    if (audioFadeOut && total > 0) g = minOf(g, (total - t) / AUDIO_FADE_MS.toFloat())
    return g.coerceIn(0f, 1f)
  }

  /** Fade in/out audio: gain of the music at combined time [t] (its own
   *  first start / last end). */
  private fun musicFadeFactor(t: Long): Float {
    if ((!audioFadeIn && !audioFadeOut) || musicSegments.isEmpty()) return 1f
    var g = 1f
    if (audioFadeIn) g = minOf(g, (t - musicSegments.first().first) / AUDIO_FADE_MS.toFloat())
    if (audioFadeOut) g = minOf(g, (musicSegments.last().last - t) / AUDIO_FADE_MS.toFloat())
    return g.coerceIn(0f, 1f)
  }

  /** The clip whose segment is selected on the video row (main clip =
   *  mediaUri), when no layer / music is the selection. */
  private fun selectedClipUriForActions(): String? {
    if (mediaType == "image" || isStoryMode || selectedLayerView != null || selectedMusicSegmentIndex != null) return null
    selectedMergedClipUri?.let { return it }
    if (videoTrimViewRef?.selectedSegmentIndex != null) return mediaUri
    return null
  }

  private data class MergedClipSnapshot(
    val uri: String,
    val index: Int,
    val segments: List<LongRange>?,
    val durationMs: Long?,
    val filter: ClipFilterState?,
    val volume: Float?,
    val speedSpans: List<SpeedSpan>? = null,
    val transition: Int? = null,
  )

  private fun insertMergedClip(snap: MergedClipSnapshot) {
    val previousMs = combinedTimeForCurrentPlaybackMs()
    additionalVideoClipUris.add(snap.index.coerceAtMost(additionalVideoClipUris.size), snap.uri)
    snap.segments?.let { additionalClipSegments[snap.uri] = it.toMutableList() }
    snap.durationMs?.let { additionalClipDurationsMs[snap.uri] = it }
    snap.filter?.let { clipFilterState[snap.uri] = it }
    snap.volume?.let { clipVolumes[snap.uri] = it }
    snap.speedSpans?.let { speedSpans[snap.uri] = it.toMutableList() }
    snap.transition?.let { transitionsIn[snap.uri] = it }
    rebuildAdditionalPlaylistItems()
    extendLayerTimingsToCombinedDuration()
    refreshMergedClipsStrip()
    seekCombinedTimeline(previousMs)
    if (snap.durationMs == null) loadAdditionalClipDuration(snap.uri)
    updateLayerStateButtons()
  }

  private fun removeMergedClip(uri: String): MergedClipSnapshot? {
    val index = additionalVideoClipUris.indexOf(uri)
    if (index < 0) return null
    // The playing clip's live filter edits live in the working copy.
    clipFilterState[activeClipUri ?: mediaUri] = currentFilterStateSnapshot()
    val snap = MergedClipSnapshot(
      uri, index, additionalClipSegments[uri]?.toList(), additionalClipDurationsMs[uri], clipFilterState[uri], clipVolumes[uri],
      speedSpans[uri]?.toList(), transitionsIn[uri],
    )
    val previousMs = combinedTimeForCurrentPlaybackMs()
    additionalVideoClipUris.removeAt(index)
    if (selectedMergedClipUri == uri) {
      selectedMergedClipUri = null
      selectedMergedClipSegmentIndex = null
    }
    rebuildAdditionalPlaylistItems()
    clampLayerTimingsToCombinedDuration()
    refreshMergedClipsStrip()
    seekCombinedTimeline(previousMs.coerceAtMost((combinedLayerDurationMs() - 100).coerceAtLeast(0)))
    updateLayerStateButtons()
    return snap
  }

  /** After the timeline got shorter: cut every layer's segments to the new
   *  end, keeping at least a short last piece so no layer is lost. */
  private fun clampLayerTimingsToCombinedDuration() {
    val durationMs = combinedLayerDurationMs()
    if (durationMs <= 0) return
    for (timing in layerTimings.values) {
      val clipped = timing.segments.mapNotNull { seg ->
        val lo = seg.first.coerceAtMost(durationMs)
        val hi = seg.last.coerceAtMost(durationMs)
        if (hi - lo >= 100) lo..hi else null
      }
      timing.segments = if (clipped.isEmpty()) mutableListOf((durationMs - 1000).coerceAtLeast(0)..durationMs) else clipped.toMutableList()
    }
    updateLayerTimeVisibility()
    refreshLayersPanel()
  }

  /** Removes a whole merged clip (asked when its only piece is deleted). */
  private fun confirmRemoveMergedClip(uri: String) {
    AlertDialog.Builder(this)
      .setTitle("Remove this clip?")
      .setPositiveButton("Remove") { _, _ ->
        val snap = removeMergedClip(uri) ?: return@setPositiveButton
        root.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        pushUndo(
          undo = { insertMergedClip(snap) },
          redo = { removeMergedClip(uri) },
        )
      }
      .setNegativeButton("Cancel", null)
      .show()
  }

  private fun toggleClipVolumePanel() {
    val uri = selectedClipUriForActions() ?: return
    if (clipVolumePanelRef != null && clipVolumeEditUri == uri) {
      hideClipVolumePanel()
      return
    }
    showClipVolumePanel(uri)
  }

  /** Small floating card above the play row: "Clip volume" + slider + %. */
  private fun showClipVolumePanel(uri: String) {
    hideClipVolumePanel()
    clipVolumeEditUri = uri
    val density = resources.displayMetrics.density
    fun px(dp: Float) = (dp * density).toInt()
    val value = TextView(this).apply {
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      fontFeatureSettings = "tnum"
      text = "${(clipVolume(uri) * 100).roundToInt()}%"
    }
    var before = clipVolume(uri)
    val seekBar = SeekBar(this).apply {
      max = 100
      progress = (clipVolume(uri) * 100).roundToInt()
      progressTintList = android.content.res.ColorStateList.valueOf(EditorDesignTokens.Colors.accent)
      thumbTintList = android.content.res.ColorStateList.valueOf(Color.WHITE)
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
          if (fromUser) setClipVolume(progress / 100f, uri)
          value.text = "$progress%"
        }
        override fun onStartTrackingTouch(bar: SeekBar) { before = clipVolume(uri) }
        override fun onStopTrackingTouch(bar: SeekBar) {
          val after = bar.progress / 100f
          val old = before
          if (old != after) pushUndo(undo = { setClipVolume(old, uri) }, redo = { setClipVolume(after, uri) })
        }
      })
    }
    val panel = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(px(16f), px(12f), px(16f), px(8f))
      background = GradientDrawable().apply {
        cornerRadius = 14f * density
        setColor(EditorDesignTokens.Colors.elevatedSurface)
      }
      isClickable = true
      addView(LinearLayout(this@MediaEditorActivity).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(TextView(this@MediaEditorActivity).apply {
          text = "Clip volume"
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
          setTextColor(EditorDesignTokens.Colors.textPrimary)
          typeface = Typeface.DEFAULT_BOLD
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        addView(value)
      })
      addView(seekBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(6f) })
    }
    val splitParams = splitSegmentButtonRef?.layoutParams as? FrameLayout.LayoutParams
    root.addView(panel, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
      leftMargin = px(16f)
      rightMargin = px(16f)
      bottomMargin = (splitParams?.bottomMargin ?: 0) + (splitParams?.height ?: px(36f)) + px(8f)
    })
    panel.bringToFront()
    clipVolumePanelRef = panel
  }

  private fun hideClipVolumePanel() {
    clipVolumePanelRef?.let { root.removeView(it) }
    clipVolumePanelRef = null
    clipVolumeEditUri = null
  }

  private fun setClipVolume(value: Float, uri: String) {
    clipVolumes[uri] = value
    exoPlayer?.volume = effectivePlayerVolume()
    updateLayerStateButtons()
  }

  // MARK: Snap guides

  private var snapGuidesViewRef: SnapGuidesView? = null
  private var lastSnapState = LayerSnapState.NONE

  /** Draws the guides a dragged layer is snapped to and plays a light tick
   *  each time a new guide engages. */
  private fun showSnapGuides(state: LayerSnapState) {
    val guides = snapGuidesViewRef ?: SnapGuidesView(this).also {
      root.addView(it, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
      snapGuidesViewRef = it
    }
    val previous = lastSnapState
    val gained = (state.centerX && !previous.centerX) || (state.centerY && !previous.centerY) ||
      (state.left && !previous.left) || (state.right && !previous.right) ||
      (state.top && !previous.top) || (state.bottom && !previous.bottom)
    if (gained) root.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    lastSnapState = state
    guides.canvasRect = canvasBoxRect
    guides.bringToFront()
    guides.state = state
  }

  // MARK: Per-layer hide / lock

  private fun isLayerUserHidden(layer: View): Boolean = layerTimings[layer]?.isManuallyHidden == true

  private fun isLayerLocked(layer: View): Boolean = layerTimings[layer]?.isLocked == true

  /** Eye + lock buttons: shown (in place of the selection label) only while
   *  a text/sticker/photo layer is selected in a video session. */
  private fun updateLayerStateButtons() {
    val hideButton = layerHideButtonRef ?: return
    val lockButton = layerLockButtonRef ?: return
    val controlsShown = splitSegmentButtonRef?.visibility == View.VISIBLE
    val layer = selectedLayerView
    val show = mediaType != "image" && !isStoryMode && layer != null && layer in layerTimings &&
      selectedMusicSegmentIndex == null && controlsShown
    hideButton.visibility = if (show) View.VISIBLE else View.INVISIBLE
    lockButton.visibility = if (show) View.VISIBLE else View.INVISIBLE
    val clipUri = if (show) null else selectedClipUriForActions()
    val showClip = clipUri != null && controlsShown
    // Clip volume button removed (user request) — Speed sits in its slot.
    clipVolumeButtonRef?.visibility = View.GONE
    clipSpeedButtonRef?.visibility = if (showClip) View.VISIBLE else View.INVISIBLE
    // Transition (into a merged clip) takes compare's spot while a clip is selected.
    val showTransition = showClip && selectedMergedClipUri != null
    clipTransitionButtonRef?.visibility = if (showTransition) View.VISIBLE else View.INVISIBLE
    val selectedText = selectedLayerView?.takeIf { it in textLayerViews && it !in stickerLayerViews && controlsShown && !isStoryMode }
    textAnimationButtonRef?.visibility = if (selectedText != null) View.VISIBLE else View.INVISIBLE
    selectedText?.let { layerTimings[it] }?.let { timing ->
      textAnimationIconRef?.iconTint = if (timing.anim.isNone) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.selectedToolTint
    }
    if (controlsShown) videoCompareButtonRef?.visibility = if (showClip || selectedText != null) View.INVISIBLE else View.VISIBLE
    if (showTransition) {
      clipTransitionIconRef?.iconTint = if ((transitionsIn[selectedMergedClipUri] ?: 0) == 0) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.selectedToolTint
    }
    if (clipUri != null && showClip) {
      val selectedPartSpeed = selectedSpeedPart(clipUri)?.let { partSpeed(clipUri, it.second) } ?: 1f
      clipSpeedIconRef?.iconTint = if (selectedPartSpeed == 1f) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.selectedToolTint
    }
    if (clipUri != null && showClip) clipVolumeIconRef?.icon = if (clipVolume(clipUri) <= 0f) EditorIcon.VOLUME_OFF else EditorIcon.VOLUME
    if (!showClip || clipUri != clipVolumeEditUri) hideClipVolumePanel()
    if (controlsShown) videoSelectionLabelRef?.visibility = if (show || showClip) View.INVISIBLE else View.VISIBLE
    if (!show || layer == null) return
    val hidden = isLayerUserHidden(layer)
    val locked = isLayerLocked(layer)
    layerHideIconRef?.icon = if (hidden) EditorIcon.EYE_OFF else EditorIcon.EYE
    layerHideIconRef?.iconTint = if (hidden) EditorDesignTokens.Colors.selectedToolTint else EditorDesignTokens.Colors.textPrimary
    hideButton.contentDescription = if (hidden) "Show layer" else "Hide layer"
    layerLockIconRef?.icon = if (locked) EditorIcon.LOCK else EditorIcon.UNLOCK
    layerLockIconRef?.iconTint = if (locked) EditorDesignTokens.Colors.selectedToolTint else EditorDesignTokens.Colors.textPrimary
    lockButton.contentDescription = if (locked) "Unlock layer" else "Lock layer"
  }

  private fun toggleSelectedLayerHidden() {
    val layer = selectedLayerView ?: return
    if (layer !in layerTimings) return
    val newValue = !isLayerUserHidden(layer)
    setLayerUserHidden(layer, newValue)
    pushUndo(
      undo = { setLayerUserHidden(layer, !newValue) },
      redo = { setLayerUserHidden(layer, newValue) },
    )
  }

  private fun toggleSelectedLayerLocked() {
    val layer = selectedLayerView ?: return
    if (layer !in layerTimings) return
    val newValue = !isLayerLocked(layer)
    setLayerLocked(layer, newValue)
    pushUndo(
      undo = { setLayerLocked(layer, !newValue) },
      redo = { setLayerLocked(layer, newValue) },
    )
  }

  private fun setLayerUserHidden(layer: View, hidden: Boolean) {
    val timing = layerTimings[layer] ?: return
    timing.isManuallyHidden = hidden
    if (hidden && layer === selectedLayerView) {
      layerActionToolbarRef?.let { root.removeView(it) }
      layerActionToolbarRef = null
    }
    updateLayerTimeVisibility()
    refreshLayersPanel()
    updateLayerStateButtons()
  }

  private fun setLayerLocked(layer: View, locked: Boolean) {
    val timing = layerTimings[layer] ?: return
    timing.isLocked = locked
    if (locked && layer === selectedLayerView) {
      layerActionToolbarRef?.let { root.removeView(it) }
      layerActionToolbarRef = null
    }
    refreshLayersPanel()
    updateLayerStateButtons()
  }

  /** True (and tells the user) when the selected layer is locked — used to
   *  stop split/delete on it. */
  private fun blockIfSelectedLayerLocked(): Boolean {
    if (selectedMusicSegmentIndex != null) return false
    val layer = selectedLayerView ?: return false
    if (!isLayerLocked(layer)) return false
    root.performHapticFeedback(HapticFeedbackConstants.REJECT)
    android.widget.Toast.makeText(this, "Layer is locked. Unlock it to edit.", android.widget.Toast.LENGTH_SHORT).show()
    return true
  }

  /** Video redesign: "current / total" (m:ss) beside play/pause; only
   *  touches the view when the text changes (scroll fires every frame). */
  /** A combined-timeline time as it plays out: each clip's part divided
   *  by that clip's speed (2x halves it, 0.5x doubles it). Same as iOS. */
  private fun playedOutTimeMs(combinedMs: Long): Long {
    var output = 0.0
    for ((start, kept, speed) in timelineSpeedParts()) {
      val played = (combinedMs - start).coerceIn(0L, kept)
      output += played / speed.coerceAtLeast(0.01f)
      if (combinedMs <= start + kept) break
    }
    return output.toLong()
  }

  /** Re-shows "0:04 / 0:18" right away (e.g. after a speed change). */
  private fun refreshVideoTimeLabel() {
    // The music card's "plays 0:00–m:ss" follows speed changes too.
    updateMusicTrackUI()
    lastVideoTimeLabelText = ""
    updateVideoTimeLabel(if (isUserScrubbingFilmstrip) combinedTimeMs(filmstripScrollViewRef?.scrollX ?: 0) else combinedTimeForCurrentPlaybackMs())
  }

  /** [currentMs] is a combined-timeline time; both numbers are shown as
   *  the video will actually play (speed changes included). */
  private fun updateVideoTimeLabel(currentMs: Long) {
    val label = videoTimeLabelRef ?: return
    val combinedTotalMs = combinedLayerDurationMs()
    fun fmt(ms: Long): String {
      val secs = (ms.coerceAtLeast(0) / 1000).toInt()
      return String.format(java.util.Locale.US, "%d:%02d", secs / 60, secs % 60)
    }
    val current = fmt(playedOutTimeMs(currentMs.coerceAtMost(combinedTotalMs)))
    val total = fmt(playedOutTimeMs(combinedTotalMs))
    val text = "$current / $total"
    if (text == lastVideoTimeLabelText) return
    lastVideoTimeLabelText = text
    val spannable = android.text.SpannableString(text)
    spannable.setSpan(android.text.style.StyleSpan(android.graphics.Typeface.BOLD), 0, current.length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    spannable.setSpan(android.text.style.ForegroundColorSpan(EditorDesignTokens.Colors.textSecondary), current.length, text.length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    label.text = spannable
  }

  /** Centers combined time 0 and the very end under the fixed playhead by
   *  padding the scroll view's content by half its OWN visible width on
   *  each side (with clipToPadding=false, so content can still scroll
   *  into that padding) — the standard "centered scrubber" padding trick.
   *  Recomputed defensively; only really changes with device rotation. */
  private fun updateFilmstripContentPaddingIfNeeded() {
    val scrollView = filmstripScrollViewRef ?: return
    val halfWidth = scrollView.width / 2
    if (halfWidth <= 0) return
    if (scrollView.paddingLeft != halfWidth || scrollView.paddingRight != halfWidth || scrollView.clipToPadding) {
      scrollView.clipToPadding = false
      scrollView.setPadding(halfWidth, 0, halfWidth, 0)
    }
    // layerTracksScrollViewRef needs the IDENTICAL left padding — its
    // child (layerTracksStackRef) is positioned starting at
    // (paddingLeft, paddingTop) by normal ViewGroup layout, same as any
    // FrameLayout/ScrollView; without this, layerTracksStackRef's own
    // content renders flush against ITS parent's left edge while
    // filmstripScrollViewRef's content is offset by halfWidth for the
    // SAME mirrored scrollX, permanently misaligning every layer track
    // from the video row by exactly halfWidth pixels — this is what the
    // user's "text and icon layer should start exactly same from video"
    // report was pointing at. layerTracksStackRef itself keeps its own
    // EXPLICIT width unsqueezed, since padding only affects a
    // WRAP_CONTENT/MATCH_PARENT child's available space, not one with a
    // fixed pixel width like this one.
    val layerTracksScrollView = layerTracksScrollViewRef as? ScrollView ?: return
    if (layerTracksScrollView.paddingLeft != halfWidth || layerTracksScrollView.clipToPadding) {
      layerTracksScrollView.clipToPadding = false
      layerTracksScrollView.setPadding(halfWidth, layerTracksScrollView.paddingTop, layerTracksScrollView.paddingRight, layerTracksScrollView.paddingBottom)
    }
  }

  // MARK: - Combined-timeline time mapping (primary segments + merged
  // clips, all packed back-to-back with zero gap, per
  // timelinePointsPerSecondPx's own doc)

  /** Where a dragged track edge snaps (with a haptic): every other track
   *  piece's start / end (text, sticker, photo, music, voice-over), the
   *  playhead and the cuts between clips. */
  private fun trackSnapTargets(id: View, segment: Int): List<Long> {
    val targets = mutableListOf(combinedTimeForCurrentPlaybackMs())
    for (block in timelineBlocks()) {
      targets += block.combinedStartMs
      targets += block.combinedStartMs + block.keptDurationMs
    }
    for ((layer, timing) in layerTimings) {
      timing.segments.forEachIndexed { index, piece ->
        if (layer === id && index == segment) return@forEachIndexed
        targets += piece.first
        targets += piece.last
      }
    }
    if (selectedMusicTrack != null) {
      musicSegments.forEachIndexed { index, piece ->
        if (musicProxyView === id && index == segment) return@forEachIndexed
        targets += piece.first
        targets += piece.last
      }
    }
    if (voiceOverPath != null && voiceProxyView !== id) {
      targets += voiceOverStartMs
      targets += voiceOverStartMs + voiceOverDurationMs
    }
    return targets
  }

  private data class TimelineBlock(val uri: String?, val keptDurationMs: Long, val combinedStartMs: Long)

  private fun timelineBlocks(): List<TimelineBlock> {
    val blocks = mutableListOf<TimelineBlock>()
    var cursor = 0L
    val primaryKeptMs = videoSegments.sumOf { it.last - it.first }
    blocks.add(TimelineBlock(null, primaryKeptMs, cursor))
    cursor += primaryKeptMs
    for (uri in additionalVideoClipUris) {
      val keptMs = additionalClipKeptDurationMs(uri)
      blocks.add(TimelineBlock(uri, keptMs, cursor))
      cursor += keptMs
    }
    return blocks
  }

  private fun combinedTimeMs(scrollX: Int): Long = ((scrollX.coerceAtLeast(0) / timelinePointsPerSecondPx) * 1000).toLong()

  private fun scrollXForCombinedTimeMs(combinedMs: Long): Int = ((combinedMs.coerceAtLeast(0) / 1000.0) * timelinePointsPerSecondPx).toInt()

  /** Which block (primary or a specific merged clip) a COMBINED time
   *  falls in, defaulting to the last block for anything at/past the end. */
  private fun timelineBlock(combinedMs: Long, blocks: List<TimelineBlock>): TimelineBlock? =
    blocks.firstOrNull { combinedMs >= it.combinedStartMs && combinedMs <= it.combinedStartMs + it.keptDurationMs } ?: blocks.lastOrNull()

  /** Derives the current combined-timeline position from the PLAYER's
   *  own actual state (which media item + its local position) — used to
   *  drive the highlight/auto-scroll during hands-off playback. ExoPlayer
   *  (unlike AVQueuePlayer) never removes played items from its own
   *  playlist. A merged clip's own segments are now potentially MULTIPLE
   *  separate playlist entries (see additionalPlaylistEntries) rather
   *  than always exactly one, so the entry at the current index is looked
   *  up via that mapping instead of a direct "index - 1" array read, and
   *  its own preceding segments' kept length is added in — mirroring
   *  EXACTLY how the primary clip's own multi-segment case just above
   *  already does this. */
  private fun combinedTimeForCurrentPlaybackMs(): Long {
    val player = exoPlayer ?: return 0L
    val localMs = player.currentPosition
    val blocks = timelineBlocks()
    if (player.currentMediaItemIndex == 0) {
      val primaryBlock = blocks.firstOrNull { it.uri == null } ?: return 0L
      val segmentIndex = videoSegments.indexOfLast { it.first <= localMs }
      if (segmentIndex < 0) return primaryBlock.combinedStartMs
      val keptBeforeThisSegmentMs = videoSegments.take(segmentIndex).sumOf { it.last - it.first }
      return primaryBlock.combinedStartMs + keptBeforeThisSegmentMs + (localMs - videoSegments[segmentIndex].first).coerceAtLeast(0)
    }
    val entries = additionalPlaylistEntries()
    val (uri, segmentIndex) = entries.getOrNull(player.currentMediaItemIndex - 1) ?: return 0L
    val block = blocks.firstOrNull { it.uri == uri } ?: return 0L
    val segments = additionalClipSegments[uri] ?: listOf(0L..(additionalClipDurationsMs[uri] ?: 5000L))
    val keptBeforeThisSegmentMs = segments.take(segmentIndex).sumOf { it.last - it.first }
    return block.combinedStartMs + keptBeforeThisSegmentMs + localMs.coerceAtLeast(0)
  }

  /** Which flat playlist index + local position to seek to for a given
   *  COMBINED time — the inverse of combinedTimeForCurrentPlaybackMs.
   *  Third element is the playlist index to pass to ExoPlayer's own
   *  seekTo(mediaItemIndex, positionMs) (0 for the primary clip; ignored
   *  by seekCombinedTimeline when isPrimary is true, which always seeks
   *  index 0). */
  private data class SeekTarget(val isPrimary: Boolean, val playlistIndex: Int, val localMs: Long)

  private fun realSeekTarget(combinedMs: Long): SeekTarget {
    val blocks = timelineBlocks()
    val block = timelineBlock(combinedMs, blocks) ?: return SeekTarget(true, 0, 0L)
    val offsetWithinBlockMs = (combinedMs - block.combinedStartMs).coerceAtLeast(0)
    if (block.uri == null) {
      var remaining = offsetWithinBlockMs
      for (segment in videoSegments) {
        val segLengthMs = segment.last - segment.first
        if (remaining <= segLengthMs) return SeekTarget(true, 0, segment.first + remaining)
        remaining -= segLengthMs
      }
      return SeekTarget(true, 0, videoSegments.lastOrNull()?.last ?: 0L)
    }
    // Walk this clip's OWN kept segments (mirroring the primary clip's
    // identical walk just above) to find which one the offset falls in
    // and the REAL local time within it, then translate that into the
    // matching flat playlist index via additionalPlaylistEntries.
    val segments = additionalClipSegments[block.uri] ?: listOf(0L..(additionalClipDurationsMs[block.uri] ?: 5000L))
    var remaining = offsetWithinBlockMs
    var targetSegmentIndex = segments.size - 1
    var targetLocalMs = segments.lastOrNull()?.last ?: 0L
    for ((index, segment) in segments.withIndex()) {
      val segLengthMs = segment.last - segment.first
      if (remaining <= segLengthMs) {
        targetSegmentIndex = index
        targetLocalMs = segment.first + remaining
        break
      }
      remaining -= segLengthMs
    }
    val entries = additionalPlaylistEntries()
    val flatIndex = entries.indexOf(block.uri to targetSegmentIndex)
    if (flatIndex < 0) return SeekTarget(true, 0, 0L)
    return SeekTarget(false, flatIndex + 1, targetLocalMs)
  }

  /** Actually moves playback to a combined-timeline position — deferred
   *  until a user's scrub gesture SETTLES (see the scroll-settle
   *  detector), not called on every scroll delta. ExoPlayer's direct
   *  seekTo(mediaItemIndex, positionMs) makes this trivial compared to
   *  iOS's AVQueuePlayer, which has no equivalent API. */
  private fun seekCombinedTimeline(combinedMs: Long) {
    val target = realSeekTarget(combinedMs)
    val player = exoPlayer ?: return
    player.seekTo(if (target.isPrimary) 0 else target.playlistIndex, target.localMs)
  }

  /** Live, cheap update of which clip is highlighted (yellow border +
   *  duration label) — called on EVERY scroll delta during a user drag
   *  (usingScrollOffsetInsteadOfPlayer: true) and from the periodic
   *  timeline runnable during hands-off playback (false, reads the
   *  player's own actual position instead). Never touches the player
   *  itself — see seekCombinedTimeline for the actual (deferred-to-
   *  settle) seek. */
  private fun updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer: Boolean) {
    val scrollView = filmstripScrollViewRef ?: return
    val blocks = timelineBlocks()
    val combinedMs = if (usingScrollOffsetInsteadOfPlayer) combinedTimeMs(scrollView.scrollX) else combinedTimeForCurrentPlaybackMs()
    val newActiveUri = timelineBlock(combinedMs, blocks)?.uri
    val newIsPrimaryActive = newActiveUri == null
    if (newActiveUri == activeClipUri && videoTrimViewRef?.isActiveClip == newIsPrimaryActive) return
    val previousActiveUri = activeClipUri
    activeClipUri = newActiveUri
    videoTrimViewRef?.isActiveClip = newIsPrimaryActive
    updateMergedStripActiveState()
    // Per the user's explicit "edits should stay with their own clip"
    // request — also fixes a pre-existing live-preview/export mismatch:
    // combinedColorMatrix() used to read the flat globals unconditionally
    // regardless of which clip was actually playing, so the primary
    // clip's filter/adjustments visibly bled over merged clips during
    // playback even though export correctly excluded them there. Only
    // fires on an ACTUAL clip-boundary crossing (see the early-return
    // guard above), not on every poll tick.
    if (newActiveUri != previousActiveUri) syncActiveClipFilterState(previousActiveUri, newActiveUri)
  }

  /** Updates ONLY the isActive/durationLabel flags on the merged-clip
   *  items already computed by the last refreshMergedClipsStrip() call —
   *  deliberately NOT a full refreshMergedClipsStrip() (which also
   *  recomputes anchors/widths and calls back into updateFilmstripLayout,
   *  which itself calls updateActiveClipHighlight — that would recurse).
   *  Cheap: just remaps the existing items list and re-configures. */
  private fun updateMergedStripActiveState() {
    val rangeBar = mergedStripViewRef ?: return
    val updatedItems = rangeBar.items.map { item ->
      val uri = additionalVideoClipUris.firstOrNull { proxyView(it) === item.id }
      val isActive = uri != null && uri == activeClipUri
      // Only the FIRST segment shows the duration label, matching
      // VideoTrimView's own "one label for the whole clip, not one per
      // segment" convention.
      val showLabel = isActive && uri != null && item.segmentIndex == 0
      item.copy(isActive = isActive, durationLabel = if (showLabel) durationLabelText(uri!!) else null)
    }
    rangeBar.configure(rangeBar.durationMs, updatedItems)
  }

  private fun durationLabelText(uri: String): String {
    return String.format("%.1fs", additionalClipKeptDurationMs(uri) / 1000.0)
  }

  /** Android has no built-in "scroll settled" callback the way
   *  UIScrollView's scrollViewDidEndDragging/DidEndDecelerating do — this
   *  polls scrollX every 100ms and considers the scroll settled once two
   *  consecutive checks read the same value (covers both "released with
   *  no fling" and "fling decelerated to a stop"). Restarted on every
   *  ACTION_DOWN via the scroll view's touch listener below. */
  private fun scheduleFilmstripSettleCheck(scrollView: HorizontalScrollView, lastScrollX: Int) {
    filmstripSettleCheckRunnable?.let { scrollView.removeCallbacks(it) }
    val runnable = Runnable {
      if (scrollView.scrollX == lastScrollX) {
        isUserScrubbingFilmstrip = false
        filmstripSeekCooldownUntilMs = android.os.SystemClock.elapsedRealtime() + 400L
        seekCombinedTimeline(combinedTimeMs(scrollView.scrollX))
      } else {
        scheduleFilmstripSettleCheck(scrollView, scrollView.scrollX)
      }
    }
    filmstripSettleCheckRunnable = runnable
    scrollView.postDelayed(runnable, 100L)
  }

  /** Full rebuild of every merged clip's entry in the player's playlist
   *  (indices 1..N; index 0 is always the primary clip) — simplest way to
   *  guarantee the live queue reflects whatever the user just trimmed via
   *  drag, without needing to track exactly which single clip a given
   *  drag touched. */
  private fun rebuildAdditionalPlaylistItems() {
    val player = exoPlayer ?: return
    val currentCount = player.mediaItemCount
    if (currentCount > 1) player.removeMediaItems(1, currentCount)
    player.addMediaItems(additionalVideoClipUris.flatMap { makeAdditionalPlaylistMediaItems(it) })
  }

  /** Samples [mergedClipThumbnailTileCount] frames evenly across this
   *  clip's OWN full real duration (same center-of-slice sampling formula
   *  as VideoTrimView.loadThumbnails) instead of a single frame at time
   *  0 — see [additionalClipThumbnailTiles]'s own doc for why. All frames
   *  are gathered before refreshing the strip once, rather than
   *  progressively like VideoTrimView does, since a merged clip's item
   *  (and therefore its thumbnailTiles) gets fully rebuilt on every
   *  refreshMergedClipsStrip() call anyway — refreshing per-frame here
   *  would just repeat that full rebuild N times for no visible benefit. */
  private fun loadAdditionalClipThumbnail(uri: String) {
    Thread {
      // MediaMetadataRetriever only implements Closeable (and gets a
      // `.use {}` extension) since API 29 — this app's minSdk is 24, so
      // release() in a plain try/finally is used instead, matching
      // MediaMetadataReader.readVideo's own established pattern.
      val retriever = android.media.MediaMetadataRetriever()
      val frames = try {
        retriever.setDataSource(this, MediaMetadataReader.normalizedUri(uri))
        val durationMs = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        val durationUs = durationMs * 1000L
        if (durationUs > 0) {
          (0 until mergedClipThumbnailTileCount).mapNotNull { index ->
            val timeUs = (durationUs * (index + 0.5) / mergedClipThumbnailTileCount).toLong()
            runCatching { retriever.scaledFrameAt(timeUs, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC, FILMSTRIP_FRAME_MAX_SIDE) }.getOrNull()
          }
        } else {
          emptyList()
        }
      } catch (e: Exception) {
        emptyList()
      } finally {
        retriever.release()
      }
      if (frames.isNotEmpty()) {
        runOnUiThread {
          additionalClipThumbnailTiles[uri] = frames
          refreshMergedClipsStrip()
        }
      }
    }.start()
  }


  /** A full-screen modal step between picking a photo for the Overlay
   *  feature and actually adding/updating the layer — per the user's
   *  explicit "overlay image should be cropped to a chosen size, don't
   *  display the full image" request. Deliberately reuses a plain pan/
   *  pinch + "never reveal empty space" clamp (same shape as
   *  LayerGestureCoordinator's own clampBoundedTranslation) rather than a
   *  new draggable/resizable crop-FRAME component: that class
   *  (CropOverlayView) was fully DELETED from this codebase already
   *  (confirmed by its absence — only comments in other files still
   *  reference it as historical context), so "reuse the existing crop
   *  tool" wasn't actually available — this lower-risk alternative was
   *  the user's explicit choice once that was surfaced. */
  private fun presentOverlayCropScreen(bitmap: Bitmap, editing: ImageView?) {
    overlayCropSourceBitmap = bitmap
    overlayCropEditingLayer = editing
    overlayCropTranslationX = 0f
    overlayCropTranslationY = 0f
    overlayCropScale = 1f

    val density = resources.displayMetrics.density
    val boxSizePx = (OVERLAY_CROP_BOX_SIZE_DP * density).toInt()

    val overlayContainer = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
    overlayCropOverlayRef = overlayContainer
    root.addView(overlayContainer, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

    val boxView = FrameLayout(this).apply {
      background = GradientDrawable().apply { setStroke((2f * density).toInt(), Color.WHITE) }
      clipToPadding = true
      clipChildren = true
    }
    overlayContainer.addView(boxView, FrameLayout.LayoutParams(boxSizePx, boxSizePx, Gravity.CENTER))

    // CENTER_CROP mirrors iOS's .scaleAspectFill here — the shorter source
    // dimension exactly fills the box before any user pinch-zoom is
    // layered on top via scaleX/scaleY below.
    val imageView = ImageView(this).apply {
      setImageBitmap(bitmap)
      scaleType = ImageView.ScaleType.CENTER_CROP
    }
    boxView.addView(imageView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    updateOverlayCropTransform(imageView)

    val hint = TextView(this).apply {
      text = "Pinch and drag to choose what's used"
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = 13f
      gravity = Gravity.CENTER
    }
    overlayContainer.addView(
      hint,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER).apply {
        bottomMargin = boxSizePx / 2 + (24f * density).toInt()
      },
    )

    val cancelButton = makeTopBarTextButton("Cancel") { dismissOverlayCropScreen() }
    val confirmButton = makeTopBarTextButton("Use Photo", primary = true) { confirmOverlayCrop() }
    overlayContainer.addView(
      cancelButton,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
        topMargin = (24f * density).toInt()
        leftMargin = (8f * density).toInt()
      },
    )
    overlayContainer.addView(
      confirmButton,
      FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.END).apply {
        topMargin = (24f * density).toInt()
        rightMargin = (8f * density).toInt()
      },
    )

    val scaleDetector = ScaleGestureDetector(
      this,
      object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
          val proposed = overlayCropScale * detector.scaleFactor
          overlayCropScale = proposed.coerceIn(OVERLAY_CROP_MIN_SCALE, OVERLAY_CROP_MAX_SCALE)
          clampOverlayCropTranslation()
          updateOverlayCropTransform(imageView)
          return true
        }
      },
    )
    var lastX = 0f
    var lastY = 0f
    imageView.setOnTouchListener { _, event ->
      scaleDetector.onTouchEvent(event)
      when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
          lastX = event.getX(0)
          lastY = event.getY(0)
        }
        MotionEvent.ACTION_MOVE -> {
          if (event.pointerCount == 1) {
            overlayCropTranslationX += event.getX(0) - lastX
            overlayCropTranslationY += event.getY(0) - lastY
            lastX = event.getX(0)
            lastY = event.getY(0)
            clampOverlayCropTranslation()
            updateOverlayCropTransform(imageView)
          }
        }
        MotionEvent.ACTION_POINTER_UP -> {
          // Re-anchor to whichever pointer remains so lifting one finger
          // mid-pinch doesn't register as a sudden pan jump.
          val remainingIndex = if (event.actionIndex == 0) 1 else 0
          if (event.pointerCount > remainingIndex) {
            lastX = event.getX(remainingIndex)
            lastY = event.getY(remainingIndex)
          }
        }
      }
      true
    }
  }

  /** Same shape as LayerGestureCoordinator's own clampBoundedTranslation:
   *  at the current scale, the max offset before an edge would recede
   *  past the box (revealing empty space) is `boxSize * (scale - 1) / 2`
   *  — valid here because the crop imageView's OWN (untransformed) size
   *  is fixed at exactly the box size (CENTER_CROP within that fixed
   *  frame already covers the box before any user zoom is applied). */
  private fun clampOverlayCropTranslation() {
    val boxSizePx = OVERLAY_CROP_BOX_SIZE_DP * resources.displayMetrics.density
    val maxOffset = boxSizePx * (overlayCropScale - 1f) / 2f
    overlayCropTranslationX = overlayCropTranslationX.coerceIn(-maxOffset, maxOffset)
    overlayCropTranslationY = overlayCropTranslationY.coerceIn(-maxOffset, maxOffset)
  }

  private fun updateOverlayCropTransform(imageView: ImageView) {
    imageView.translationX = overlayCropTranslationX
    imageView.translationY = overlayCropTranslationY
    imageView.scaleX = overlayCropScale
    imageView.scaleY = overlayCropScale
  }

  private fun confirmOverlayCrop() {
    val editing = overlayCropEditingLayer
    val source = overlayCropSourceBitmap
    val cropped = cropOverlayBitmapForConfirm()
    dismissOverlayCropScreen()
    if (cropped == null) return
    if (editing != null) {
      updateImageOverlayLayer(editing, cropped, source)
    } else {
      addImageOverlayLayer(cropped, source)
    }
  }

  private fun dismissOverlayCropScreen() {
    overlayCropOverlayRef?.let { root.removeView(it) }
    overlayCropOverlayRef = null
    overlayCropSourceBitmap = null
    overlayCropEditingLayer = null
  }

  /** Crops [overlayCropSourceBitmap] to exactly what's visible within the
   *  box, given the user's current pan/pinch state — the same "map a
   *  fixed on-screen box back into the source's own pixel grid" idea as
   *  the image editor's own export crop math, just CENTER_CROP instead of
   *  aspect-fit and with no filters/layers/rotation to also account for.
   *  The source is already EXIF-upright (see onActivityResult). */
  private fun cropOverlayBitmapForConfirm(): Bitmap? {
    val source = overlayCropSourceBitmap ?: return null
    val srcWidth = source.width.toFloat()
    val srcHeight = source.height.toFloat()
    if (srcWidth <= 0f || srcHeight <= 0f) return null

    val boxSizePx = OVERLAY_CROP_BOX_SIZE_DP * resources.displayMetrics.density
    // The scale that makes the shorter source dimension exactly fill the
    // box — i.e. CENTER_CROP's own implicit scale — before the user's own
    // overlayCropScale zoom is layered on top.
    val coverScale = boxSizePx / minOf(srcWidth, srcHeight)
    val renderScale = coverScale * overlayCropScale
    if (renderScale <= 0f) return null

    val cropSize = boxSizePx / renderScale
    val cropCenterX = srcWidth / 2f - overlayCropTranslationX / renderScale
    val cropCenterY = srcHeight / 2f - overlayCropTranslationY / renderScale
    val left = (cropCenterX - cropSize / 2f).coerceIn(0f, srcWidth)
    val top = (cropCenterY - cropSize / 2f).coerceIn(0f, srcHeight)
    val right = (cropCenterX + cropSize / 2f).coerceIn(0f, srcWidth)
    val bottom = (cropCenterY + cropSize / 2f).coerceIn(0f, srcHeight)
    val width = (right - left).toInt()
    val height = (bottom - top).toInt()
    if (width <= 0 || height <= 0) return null
    return Bitmap.createBitmap(source, left.toInt(), top.toInt(), width, height)
  }

  /** Scales [bitmap] down so its longer side is at most [maxLongSide]
   *  (inSampleSize only halves, so a decode can still land ~2x over). */
  private fun capLongSide(bitmap: Bitmap, maxLongSide: Int): Bitmap {
    val longSide = maxOf(bitmap.width, bitmap.height)
    if (longSide <= maxLongSide) return bitmap
    val scale = maxLongSide.toFloat() / longSide
    val scaled = Bitmap.createScaledBitmap(
      bitmap,
      (bitmap.width * scale).toInt().coerceAtLeast(1),
      (bitmap.height * scale).toInt().coerceAtLeast(1),
      true,
    )
    if (scaled !== bitmap) bitmap.recycle()
    return scaled
  }

  private fun overlayLookJson(style: OverlayStyle, strokes: List<OverlayEraseStroke>): JSONObject = JSONObject().apply {
    put("filter", style.filter.name)
    put("filterStrength", style.filterStrength.toDouble())
    put("brightness", style.brightness.toDouble())
    put("contrast", style.contrast.toDouble())
    put("saturation", style.saturation.toDouble())
    put("warmth", style.warmth.toDouble())
    put("opacity", style.opacity.toDouble())
    put("blend", style.blend.name)
    put("shape", style.shape.name)
    put("border", style.border.toDouble())
    put("borderColor", style.borderColor)
    put("flipX", style.flipX)
    put("flipY", style.flipY)
    put("eraseStrokes", JSONArray().apply {
      strokes.forEach { stroke ->
        put(JSONObject().apply {
          put("points", JSONArray().apply { stroke.points.forEach { put(it.x.toDouble()); put(it.y.toDouble()) } })
          put("width", stroke.width.toDouble())
          put("restore", stroke.restore)
        })
      }
    })
  }

  private fun overlayLookFromJson(json: JSONObject): Pair<OverlayStyle, List<OverlayEraseStroke>> {
    val style = OverlayStyle(
      filter = runCatching { PhotoFilter.valueOf(json.optString("filter")) }.getOrDefault(PhotoFilter.ORIGINAL),
      filterStrength = json.optDouble("filterStrength", 1.0).toFloat(),
      brightness = json.optDouble("brightness", 0.0).toFloat(),
      contrast = json.optDouble("contrast", 0.0).toFloat(),
      saturation = json.optDouble("saturation", 0.0).toFloat(),
      warmth = json.optDouble("warmth", 0.0).toFloat(),
      opacity = json.optDouble("opacity", 1.0).toFloat(),
      blend = runCatching { OverlayBlendMode.valueOf(json.optString("blend")) }.getOrDefault(OverlayBlendMode.NORMAL),
      shape = runCatching { OverlayShape.valueOf(json.optString("shape")) }.getOrDefault(OverlayShape.NONE),
      border = json.optDouble("border", 0.0).toFloat(),
      borderColor = json.optInt("borderColor", Color.WHITE),
      flipX = json.optBoolean("flipX"),
      flipY = json.optBoolean("flipY"),
    )
    val array = json.optJSONArray("eraseStrokes") ?: JSONArray()
    val strokes = (0 until array.length()).mapNotNull { i ->
      val entry = array.optJSONObject(i) ?: return@mapNotNull null
      val flat = entry.optJSONArray("points") ?: return@mapNotNull null
      val points = (0 until flat.length() / 2).map { p -> PointF(flat.optDouble(p * 2).toFloat(), flat.optDouble(p * 2 + 1).toFloat()) }
      OverlayEraseStroke(points, entry.optDouble("width").toFloat(), entry.optBoolean("restore"))
    }
    return style to strokes
  }

  /** Sets an overlay's photo/look/eraser and redraws it. */
  private fun applyOverlay(view: ImageView, base: Bitmap, source: Bitmap?, style: OverlayStyle, strokes: List<OverlayEraseStroke>) {
    val state = overlayStates[view]
    if (state == null) {
      overlayStates[view] = OverlayState(base, source, style, strokes)
    } else {
      if (state.base !== base) {
        state.colored = null
        state.coloredKey = null
      }
      state.base = base
      state.source = source
      state.style = style
      state.strokes = strokes
    }
    renderOverlayPreview(view)
  }

  private fun setOverlayStyle(view: ImageView, style: OverlayStyle) {
    val state = overlayStates[view] ?: return
    applyOverlay(view, state.base, state.source, style, state.strokes)
  }

  private fun renderOverlayPreview(view: ImageView) {
    val state = overlayStates[view] ?: return
    val key = state.style.colorKey
    val colored = state.colored?.takeIf { state.coloredKey == key }
      ?: OverlayRenderer.colorPass(state.base, state.style, OverlayRenderer.PREVIEW_MAX_SIDE).also {
        state.colored = it
        state.coloredKey = key
      }
    view.setImageBitmap(OverlayRenderer.composite(colored, state.style, state.strokes, colored.width, colored.height))
    // On-screen blend with what's underneath (export draws with the same mode).
    if (state.style.blend == OverlayBlendMode.NORMAL) {
      view.setLayerType(View.LAYER_TYPE_NONE, null)
    } else {
      view.setLayerType(View.LAYER_TYPE_HARDWARE, Paint().also { state.style.blend.applyTo(it) })
    }
  }

  private fun addImageOverlayLayer(bitmap: Bitmap, source: Bitmap? = null) {
    val density = resources.displayMetrics.density
    // Sized to a fixed initial on-screen box (long side capped, aspect
    // preserved) — a full-resolution photo would otherwise appear at some
    // enormous native size before the user pinches it down.
    val maxDimensionPx = (160f * density).toInt()
    val aspect = bitmap.width.toFloat() / bitmap.height.toFloat()
    val widthPx: Int
    val heightPx: Int
    if (aspect >= 1) {
      widthPx = maxDimensionPx
      heightPx = (maxDimensionPx / aspect).toInt()
    } else {
      widthPx = (maxDimensionPx * aspect).toInt()
      heightPx = maxDimensionPx
    }
    val overlayView = ImageView(this).apply { scaleType = ImageView.ScaleType.FIT_CENTER }
    applyOverlay(overlayView, bitmap, source, OverlayStyle(), emptyList())
    root.addView(overlayView, FrameLayout.LayoutParams(widthPx, heightPx, Gravity.CENTER))
    root.setClipRect(overlayView, canvasBoxRect)
    imageOverlayLayerViews.add(overlayView)
    gestureCoordinator?.addLayer(overlayView)
    selectLayer(overlayView)
    keepSafeAreaCoversOnTop()
    registerLayerTiming(overlayView)
    // Same fix as addTextLayer/addStickerLayer's identical call — see
    // their comment.
    updateLayerTimeVisibility()
    pushUndo(
      undo = { overlayView.visibility = View.GONE; refreshLayersPanel() },
      redo = { overlayView.visibility = View.VISIBLE; refreshLayersPanel() },
    )
  }

  /** New photo (Edit) or new crop (re-crop): keeps the look, but drops
   *  eraser strokes — they were drawn on the old picture. */
  private fun updateImageOverlayLayer(layer: ImageView, bitmap: Bitmap, source: Bitmap?) {
    val state = overlayStates[layer] ?: return
    val oldBase = state.base
    val oldSource = state.source
    val oldStrokes = state.strokes
    applyOverlay(layer, bitmap, source, state.style, emptyList())
    resizeOverlayBox(layer, bitmap)
    scheduleFilterStageRefresh()
    pushUndo(
      undo = {
        overlayStates[layer]?.let { applyOverlay(layer, oldBase, oldSource, it.style, oldStrokes) }
        resizeOverlayBox(layer, oldBase)
        scheduleFilterStageRefresh()
      },
      redo = {
        overlayStates[layer]?.let { applyOverlay(layer, bitmap, source, it.style, emptyList()) }
        resizeOverlayBox(layer, bitmap)
        scheduleFilterStageRefresh()
      },
    )
  }

  /** Re-fits an overlay's box to a new picture's proportions (after Edit
   *  or re-crop), keeping its longer side. */
  private fun resizeOverlayBox(layer: ImageView, bitmap: Bitmap) {
    val params = layer.layoutParams as? FrameLayout.LayoutParams ?: return
    if (params.width <= 0 || params.height <= 0 || bitmap.height <= 0) return
    val newAspect = bitmap.width.toFloat() / bitmap.height
    if (abs(newAspect - params.width.toFloat() / params.height) <= 0.01f) return
    val longSide = maxOf(params.width, params.height)
    params.width = if (newAspect >= 1f) longSide else (longSide * newAspect).roundToInt()
    params.height = if (newAspect >= 1f) (longSide / newAspect).roundToInt() else longSide
    layer.layoutParams = params
  }


  // MARK: Music (Day 23 — selection + preview only)

  /** Story rail's Audio button — pauses the looping video while the
   *  picker is up (its own track previews would overlap the video's
   *  audio), then resumes it on dismiss, since story mode has no play
   *  button to resume with. */
  private fun presentStoryMusicPicker() {
    val wasPlaying = exoPlayer?.playWhenReady == true
    if (wasPlaying) setPreviewPlaying(false)
    // A photo story has no video player: pause its song directly.
    val songWasPlaying = mediaType == "image" && musicPlayer?.playWhenReady == true
    if (songWasPlaying) musicPlayer?.pause()
    val trackBefore = selectedMusicTrack?.audioUrl
    MusicPickerDialog(this, onDismiss = {
      if (songWasPlaying && selectedMusicTrack?.audioUrl == trackBefore && !isStoryMusicPausedByUser) {
        musicPlayer?.play()
        updateStoryMusicBadge()
      }
      if (wasPlaying) setPreviewPlaying(true)
    }) { track -> selectMusicTrack(track) }.show()
  }

  private fun showMusicPicker() {
    // Rich picker (live trending/search via MusicApi, per-row preview) —
    // replaces the old plain AlertDialog list over the static bridge-
    // provided `musicTracks`, per the user's explicit "same as add post
    // screen selection process" request.
    MusicPickerDialog(this) { track -> selectMusicTrack(track) }.show()
  }

  /** Swaps between the empty-state "+ Choose Music Track" button and the
   *  chosen-track card (title + play/pause + remove), and syncs the
   *  play/pause icon to the current playback state — called on selection
   *  change and once at initial setup. */
  private fun updateMusicTrackUI() {
    val hasTrack = selectedMusicTrack != null
    musicButtonRef?.visibility = if (hasTrack) View.GONE else View.VISIBLE
    musicTrackCardRef?.visibility = if (hasTrack) View.VISIBLE else View.GONE
    musicTrackTitleRef?.text = selectedMusicTrack?.title
    musicChangeTrackRef?.visibility = if (hasTrack) View.VISIBLE else View.GONE
    musicTrackSubtitleRef?.text = selectedMusicTrack?.let { track ->
      if (mediaType == "image") return@let track.artist
      // As the video will play (speed changes included), like the time label.
      val plays = "plays 0:00–${formatMinSec(playedOutTimeMs(combinedLayerDurationMs()))}"
      if (track.artist.isEmpty()) plays else "${track.artist} · $plays"
    }
    musicVolumeRowRef?.visibility = if (hasTrack) View.VISIBLE else View.GONE
    musicPlayPauseIconRef?.icon = if (exoPlayer?.isPlaying == true) EditorIcon.PAUSE else EditorIcon.PLAY
  }

  /** Story-mode-only counterpart to updateMusicTrackUI() (which drives the
   *  regular, non-story editor's own track card and is left untouched) —
   *  shows/hides storyMusicBadgeRef and syncs its title + play/pause icon
   *  to selectedMusicTrack/musicPlayer. Called from selectMusicTrack() on
   *  every selection change, and from toggleStoryMusicPlayback() so the
   *  icon flips immediately on tap rather than waiting for some other
   *  event. No-op (storyMusicBadgeRef stays null) outside story mode. */
  private fun updateStoryMusicBadge() {
    val badge = storyMusicBadgeRef ?: return
    val hasTrack = selectedMusicTrack != null
    badge.visibility = if (hasTrack) View.VISIBLE else View.GONE
    storyMusicBadgeTitleRef?.text = selectedMusicTrack?.title
    storyMusicBadgePlayPauseIconRef?.icon = if (musicPlayer?.isPlaying == true) EditorIcon.PAUSE else EditorIcon.PLAY
  }

  /** Toggles playback of the story-mode music preview player directly
   *  (unlike the regular panel's musicPlayPauseButton, which proxies a
   *  click to the main video transport, playPauseButtonRef — there is no
   *  main video transport for a photo story, so this controls musicPlayer
   *  itself regardless of media type). */
  private fun toggleStoryMusicPlayback() {
    val player = musicPlayer ?: return
    if (player.isPlaying) {
      isStoryMusicPausedByUser = true
      player.pause()
    } else {
      isStoryMusicPausedByUser = false
      player.play()
    }
    updateStoryMusicBadge()
  }

  /** Toggles the ORIGINAL video clip's own audio on/off by driving
   *  originalAudioVolume (0f/1f) through the exact same live-volume write
   *  the regular editor's own slider callback uses (exoPlayer?.volume) —
   *  the same state exportVideo already reads (originalAudioEffectiveVolume
   *  at export time), so this stays correct on export with no export-side
   *  changes needed. Swaps storyMuteIconRef's icon in place (mirrors the
   *  video transport's own PLAY/PAUSE swap) to reflect current state. */
  private fun toggleStoryOriginalAudioMute() {
    originalAudioVolume = if (originalAudioVolume > 0f) 0f else 1f
    exoPlayer?.volume = effectivePlayerVolume()
    storyMuteIconRef?.icon = if (originalAudioVolume > 0f) EditorIcon.VOLUME else EditorIcon.VOLUME_OFF
  }

  /** Clears the chosen track entirely, per the user's explicit "remove
   *  selected song icon" request — reuses selectMusicTrack(null), the same
   *  path the picker's own "None" option already takes. */
  private fun selectMusicTrack(track: MusicTrack?) {
    musicPlayer?.release()
    musicPlayer = null
    selectedMusicTrack = track
    isStoryMusicPausedByUser = false
    musicOffsetMs = 0
    musicSegments.clear()
    selectedMusicSegmentIndex = null
    musicTrimStartMs = 0
    musicBeatsMs = emptyList()
    updateBeatSyncNote()
    updateMusicTrackUI()
    updateStoryMusicBadge()
    refreshLayersPanel()

    if (track == null) return
    if (!isStoryMode && mediaType != "image") detectBeats(track)
    val player = ExoPlayer.Builder(this).build()
    musicPlayer = player
    // Loops the preview continuously instead of stopping once the track
    // plays through once — per the user's explicit "play in loop" request.
    player.repeatMode = Player.REPEAT_MODE_ONE
    // Carries over whatever volume the user already dialed in for a
    // previous track rather than resetting to full volume every pick.
    player.volume = musicVolume
    player.setMediaItem(MediaItem.fromUri(track.audioUrl))
    player.addListener(object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        if (playbackState == Player.STATE_READY && player.duration > 0) {
          musicTrimEndMs = player.duration
          // Single starting segment spanning the full (kept) duration —
          // exactly the old single-window default before split existed.
          if (musicSegments.isEmpty()) {
            musicSegments.add(musicOffsetMs..(musicOffsetMs + player.duration))
          }
          refreshLayersPanel()
        }
      }
      // isPlaying isn't reliably true the instant play() is called (still
      // buffering) — this fires once it actually starts, so the story
      // badge's icon reflects real state instead of a synchronous guess
      // right after play(). No-ops outside story mode (updateStoryMusicBadge
      // itself guards on storyMusicBadgeRef being non-null).
      override fun onIsPlayingChanged(isPlaying: Boolean) {
        updateStoryMusicBadge()
      }
    })
    player.prepare()
    // A still image has no main player to match — picking a track there
    // should autoplay immediately (per the user's explicit "make song on
    // auto play" request), since there's no other transport state to
    // sync with. For video, keep matching whatever the main player is
    // doing right now rather than always autoplaying — picking a track
    // while paused shouldn't start audio.
    if (mediaType == "image" || exoPlayer?.isPlaying == true) {
      player.play()
    }
  }

  /** SeekBar has no negative range pre-API 26 (minSdk here is 24), so
   *  0..200 maps to -1f..1f via (progress - 100) / 100f. */
  /** Track/thumb sized to EditorDesignTokens.SpacingDp, a trailing numeric
   *  value readout (spec's "slider value labels: 13sp regular, tabular
   *  numerals"), and a light selection-changed haptic when the value
   *  arrives at one of the 3 snap points (min/center/max) — matching the
   *  spec's "selection-changed haptic on slider snap points (0, 50, 100)"
   *  applied to this slider's own -1..1 range. */
  private fun makeAdjustmentRow(labelText: String, onChange: (Float) -> Unit): LinearLayout {
    val density = resources.displayMetrics.density
    val label = TextView(this).apply {
      text = labelText
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      textSize = 12f
    }
    val valueLabel = TextView(this).apply {
      text = "0"
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = EditorDesignTokens.TypeSizesSp.sliderValue
      gravity = Gravity.END
    }
    val seekBar = makeStyledSeekBar().apply {
      max = 200
      progress = 100
      var previousValue = 0f
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
          val value = (progress - 100) / 100f
          onChange(value)

          val intValue = (value * 100).toInt()
          valueLabel.text = if (intValue > 0) "+$intValue" else "$intValue"

          val snapPoints = floatArrayOf(-1f, 0f, 1f)
          val snapThreshold = 0.04f
          for (snap in snapPoints) {
            val wasNear = abs(previousValue - snap) <= snapThreshold
            val isNear = abs(value - snap) <= snapThreshold
            if (isNear && !wasNear) {
              seekBar.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
              break
            }
          }
          previousValue = value
        }

        // Undo/redo for this slider: snapshot the value once when the drag
        // starts (not on every onProgressChanged tick, which would push one
        // undo entry per pixel of movement), then push a single entry
        // comparing that snapshot to wherever the drag ended up. Restoring
        // sets `.progress` directly — Android calls onProgressChanged for
        // ANY progress change (user or programmatic), so this re-drives the
        // exact same property-set/label/haptic logic above with no
        // duplicated restore code.
        var dragStartValue = 0f
        override fun onStartTrackingTouch(seekBar: SeekBar) {
          dragStartValue = (seekBar.progress - 100) / 100f
        }
        override fun onStopTrackingTouch(seekBar: SeekBar) {
          val newValue = (seekBar.progress - 100) / 100f
          if (dragStartValue == newValue) return
          val oldValue = dragStartValue
          pushUndo(
            undo = { seekBar.progress = ((oldValue * 100) + 100).toInt() },
            redo = { seekBar.progress = ((newValue * 100) + 100).toInt() },
          )
        }
      })
    }
    return LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
      addView(
        seekBar,
        LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
          marginStart = (8f * density).toInt()
          marginEnd = (8f * density).toInt()
        },
      )
      addView(valueLabel, LinearLayout.LayoutParams((36f * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
    }
  }

  /** Label + seek bar + trailing "NN%" readout — same shape as
   *  makeAdjustmentRow's label+slider+value layout, but for a plain
   *  0-100% range (music/original-audio volume) instead of a signed
   *  -100..+100 one. Per the user's explicit "show music percentage also"
   *  request. */
  /** Video redesign volume block: "HEADER ……… 80%" over a full-width
   *  slider, plus an optional footnote. */
  private fun makeVolumeBlock(header: String, initialPercent: Int, footnote: String?, onChange: (Int) -> Unit): Pair<LinearLayout, SeekBar> {
    val density = resources.displayMetrics.density
    val headerLabel = TextView(this).apply {
      text = header
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
      letterSpacing = 0.06f
      typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    val valueLabel = TextView(this).apply {
      text = "$initialPercent%"
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
      fontFeatureSettings = "tnum"
    }
    val seekBar = makeStyledSeekBar().apply {
      max = 100
      progress = initialPercent
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
          valueLabel.text = "$progress%"
          onChange(progress)
        }
        override fun onStartTrackingTouch(seekBar: SeekBar) {}
        override fun onStopTrackingTouch(seekBar: SeekBar) {}
      })
    }
    val block = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      addView(LinearLayout(this@MediaEditorActivity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(headerLabel, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        addView(valueLabel)
      })
      addView(seekBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (32f * density).toInt()).apply {
        topMargin = (4f * density).toInt()
      })
      if (footnote != null) {
        addView(TextView(this@MediaEditorActivity).apply {
          text = footnote
          setTextColor(EditorDesignTokens.Colors.textSecondary)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          topMargin = (4f * density).toInt()
        })
      }
    }
    return block to seekBar
  }

  private fun makeVolumePercentRow(labelText: String, initialPercent: Int, onChange: (Int) -> Unit): LinearLayout {
    val density = resources.displayMetrics.density
    val label = TextView(this).apply {
      text = labelText
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      textSize = 12f
    }
    val valueLabel = TextView(this).apply {
      text = "$initialPercent%"
      setTextColor(EditorDesignTokens.Colors.textSecondary)
      textSize = EditorDesignTokens.TypeSizesSp.sliderValue
      gravity = Gravity.END
    }
    val seekBar = makeStyledSeekBar().apply {
      max = 100
      progress = initialPercent
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
          valueLabel.text = "$progress%"
          onChange(progress)
        }
        override fun onStartTrackingTouch(seekBar: SeekBar) {}
        override fun onStopTrackingTouch(seekBar: SeekBar) {}
      })
    }
    return LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
      addView(
        seekBar,
        LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
          marginStart = (8f * density).toInt()
          marginEnd = (8f * density).toInt()
        },
      )
      addView(valueLabel, LinearLayout.LayoutParams((44f * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
    }
  }

  private fun makeStyledSeekBar(): SeekBar {
    val density = resources.displayMetrics.density
    val trackHeightPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.sliderTrackHeight, density)
    val thumbDiameterPx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.sliderThumbDiameter, density)

    val backgroundTrack = GradientDrawable().apply {
      setColor(EditorDesignTokens.Colors.divider)
      cornerRadius = trackHeightPx / 2f
    }
    val progressTrack = GradientDrawable().apply {
      setColor(EditorDesignTokens.Colors.accent)
      cornerRadius = trackHeightPx / 2f
    }
    val progressLayer = LayerDrawable(arrayOf(backgroundTrack, ClipDrawable(progressTrack, Gravity.START, ClipDrawable.HORIZONTAL))).apply {
      setId(0, android.R.id.background)
      setId(1, android.R.id.progress)
    }
    // Layered thumb: a soft dark halo (shadow-in-a-drawable, since a plain
    // GradientDrawable has no elevation of its own) sitting behind a
    // white disc with a thin accent-colored ring — reads as a real,
    // liftable control instead of a flat dot.
    val shadowInsetPx = (3f * density).toInt()
    val ringWidthPx = (2f * density).toInt()
    val thumbShadow = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(Color.argb(70, 0, 0, 0))
      setSize(thumbDiameterPx, thumbDiameterPx)
    }
    val thumbFace = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(EditorDesignTokens.Colors.textPrimary)
      setStroke(ringWidthPx, EditorDesignTokens.Colors.accent)
      setSize(thumbDiameterPx, thumbDiameterPx)
    }
    // LayerDrawable derives its own intrinsic size from its layers' sizes
    // + insets (it has no setSize of its own) — the shadow layer is
    // pushed down by shadowInsetPx while the face layer is pulled up by
    // the same amount, so the combined intrinsic height grows by exactly
    // that much, giving the halo room to peek out below the face.
    val thumbDrawable = LayerDrawable(arrayOf(thumbShadow, thumbFace)).apply {
      setLayerInset(0, 0, shadowInsetPx, 0, 0)
      setLayerInset(1, 0, 0, 0, shadowInsetPx)
    }

    return SeekBar(this).apply {
      progressDrawable = progressLayer
      thumb = thumbDrawable
      minimumHeight = trackHeightPx
      maxHeight = trackHeightPx
      splitTrack = false
    }
  }

  private fun finishCancelled() {
    exoPlayer?.pause()
    musicPlayer?.pause()
    val data = Intent().apply {
      putExtra(EXTRA_RESULT_STATUS, "cancelled")
    }
    setResult(Activity.RESULT_OK, data)
    finish()
  }

  // ── Redesign: LOOKS · TOOLS · EXPORT bar + Tools grid ─────────────────

  private var lookToolsBarRef: View? = null
  private val lookToolsItems = mutableListOf<Pair<TextView, View>>()
  private var toolsGridPanelRef: SlideUpPanelView? = null

  private fun setUpLookToolsBar(heightPx: Int) {
    val density = resources.displayMetrics.density
    lookToolsItems.clear()
    val row = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      setBackgroundColor(EditorDesignTokens.Colors.chromeBackground)
      val pad = (12f * density).toInt()
      setPadding(pad, 0, pad, 0)
      listOf<Pair<String, () -> Unit>>(
        "LOOKS" to { selectedImageEditorTab = ImageEditorTab.EFFECT; updateImageEditorUI(animated = true) },
        "TOOLS" to {
          selectedImageEditorTab = if (selectedImageEditorTab == ImageEditorTab.TOOLS_GRID) ImageEditorTab.TOOLS else ImageEditorTab.TOOLS_GRID
          updateImageEditorUI(animated = true)
        },
        "EXPORT" to { finishSuccess() },
      ).forEach { (title, action) ->
        val label = TextView(this@MediaEditorActivity).apply {
          text = title
          textSize = 13f
          letterSpacing = 0.08f
          typeface = Typeface.DEFAULT_BOLD
          setTextColor(EditorDesignTokens.Colors.textSecondary)
          gravity = Gravity.CENTER
        }
        val underline = View(this@MediaEditorActivity).apply {
          background = GradientDrawable().apply {
            cornerRadius = 2f * density
            setColor(EditorDesignTokens.Colors.accent)
          }
          visibility = View.INVISIBLE
        }
        val item = LinearLayout(this@MediaEditorActivity).apply {
          orientation = LinearLayout.VERTICAL
          gravity = Gravity.CENTER
          addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
          addView(underline, LinearLayout.LayoutParams((18f * density).toInt(), (3f * density).toInt()).apply { topMargin = (6f * density).toInt() })
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            pauseVideoForToolInteraction()
            action()
          }
        }
        lookToolsItems += label to underline
        addView(item, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
      }
    }
    // Hairline above the bar, as in the mockup.
    val bar = FrameLayout(this).apply {
      addView(row, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
      addView(View(this@MediaEditorActivity).apply { setBackgroundColor(EditorDesignTokens.Colors.divider) },
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (1f * density).toInt().coerceAtLeast(1), Gravity.TOP))
    }
    lookToolsBarRef = bar
    root.addView(bar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, heightPx, Gravity.BOTTOM).apply {
      bottomMargin = navigationBarHeightPx
    })
  }

  /** LOOKS is lit while Filters is open, TOOLS while the grid is open. */
  private fun updateLookToolsBar() {
    val active = listOf(selectedImageEditorTab == ImageEditorTab.EFFECT, selectedImageEditorTab == ImageEditorTab.TOOLS_GRID, false)
    lookToolsItems.forEachIndexed { index, (label, underline) ->
      val on = active.getOrElse(index) { false }
      label.setTextColor(if (on) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.textSecondary)
      underline.visibility = if (on) View.VISIBLE else View.INVISIBLE
    }
  }

  /** Every tool as a tile; a tap closes the grid and opens that tool. */
  private fun setUpToolsGridPanel(bottomMarginPx: Int) {
    val density = resources.displayMetrics.density
    val isImage = mediaType == "image"
    fun openTab(tab: ImageEditorTab) {
      selectedImageEditorTab = tab
      updateImageEditorUI(animated = true)
    }
    val tools = mutableListOf<Triple<EditorIcon, String, () -> Unit>>(
      Triple(EditorIcon.TOOL_ADJUST, "Tune") { openTab(ImageEditorTab.EDIT) },
      Triple(EditorIcon.TOOL_FILTERS, "Filters") { openTab(ImageEditorTab.EFFECT) },
    )
    if (isImage) {
      tools += Triple(EditorIcon.TOOL_AUTO, "Auto") { openTab(ImageEditorTab.EDIT); didTapAdjustIcon(AdjustProperty.AUTO) }
      tools += Triple(EditorIcon.TOOL_BLUR, "Blur") { openTab(ImageEditorTab.EDIT); didTapAdjustIcon(AdjustProperty.BLUR) }
    }
    tools += Triple(EditorIcon.TOOL_VIGNETTE, "Vignette") { openTab(ImageEditorTab.EDIT); didTapAdjustIcon(AdjustProperty.VIGNETTE) }
    tools += Triple(EditorIcon.TOOL_TEXT, "Text") { presentTextEntryOverlay() }
    tools += Triple(EditorIcon.TOOL_DRAW, "Draw") { openTab(ImageEditorTab.DRAW) }
    tools += Triple(EditorIcon.TOOL_STICKER, "Sticker") { if (canAddLayer()) openTab(ImageEditorTab.STICKERS) }
    if (isImage) {
      tools += Triple(EditorIcon.TOOL_OVERLAY, "Overlay") { presentImageOverlayPicker() }
    } else {
      tools += Triple(EditorIcon.TOOL_MUSIC, "Music") { openTab(ImageEditorTab.MUSIC) }
      tools += Triple(EditorIcon.TOOL_ADD_VIDEO, "Add clip") { presentVideoClipPicker() }
    }
    val gapPx = (10f * density).toInt()
    val tileHeightPx = (84f * density).toInt()
    val iconPx = (26f * density).toInt()
    // Mockup: tall enough for every tile row, down to the screen edge
    // (over the tool rail and the LOOKS · TOOLS · EXPORT bar).
    val rows = (tools.size + 3) / 4
    val panelHeightDp = 45f + 8f + rows * 84f + (rows - 1) * 10f + 16f + navigationBarHeightPx / density
    val grid = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      tools.chunked(4).forEachIndexed { rowIndex, rowTools ->
        val row = LinearLayout(this@MediaEditorActivity).apply { orientation = LinearLayout.HORIZONTAL }
        for (column in 0 until 4) {
          val tool = rowTools.getOrNull(column)
          val tile: View = if (tool == null) View(this@MediaEditorActivity) else LinearLayout(this@MediaEditorActivity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
              cornerRadius = 16f * density
              setColor(EditorDesignTokens.Colors.elevatedSurface)
            }
            addView(EditorIconView(this@MediaEditorActivity, tool.first), LinearLayout.LayoutParams(iconPx, iconPx))
            addView(TextView(this@MediaEditorActivity).apply {
              text = tool.second
              textSize = 12f
              isSingleLine = true
              setTextColor(EditorDesignTokens.Colors.textPrimary)
              gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
              topMargin = (8f * density).toInt()
            })
            setOnClickListener {
              it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
              pauseVideoForToolInteraction()
              // Close the grid first; the tool then opens its own panel/picker.
              selectedImageEditorTab = ImageEditorTab.TOOLS
              updateImageEditorUI(animated = false)
              tool.third()
            }
          }
          row.addView(tile, LinearLayout.LayoutParams(0, tileHeightPx, 1f).apply { if (column > 0) marginStart = gapPx })
        }
        addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          if (rowIndex > 0) topMargin = gapPx
        })
      }
    }
    val scroll = ScrollView(this).apply {
      isVerticalScrollBarEnabled = false
      addView(grid, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
    val panel = SlideUpPanelView(this, "Tools", panelHeightDp).apply {
      useCloseIconForConfirm()
      // Android draws higher-elevation views on top regardless of order —
      // the tool rail has 8dp, so the sheet needs more to cover it.
      elevation = 16f * density
      visibility = View.INVISIBLE
      contentContainer.addView(scroll, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT).apply {
        leftMargin = (16f * density).toInt()
        rightMargin = (16f * density).toInt()
      })
      configureExpandedHeight(windowHeightPx())
      onConfirm = { openTab(ImageEditorTab.TOOLS) }
    }
    toolsGridPanelRef = panel
    root.addView(panel, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, EditorDesignTokens.dpToPx(panelHeightDp, density), Gravity.BOTTOM).apply {
      bottomMargin = 0
    })
  }

  // region Add layer (Edits-style layers, boards V7/V8)

  /** Video sessions allow at most [MAX_VIDEO_LAYERS] text/sticker/photo
   *  layers (music isn't counted — there's only ever one track). Shows a
   *  short message and returns false when full. Image sessions: no limit. */
  private fun canAddLayer(): Boolean {
    if (mediaType == "image" || allLayerViews().size < MAX_VIDEO_LAYERS) return true
    root.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    android.widget.Toast.makeText(this, "Maximum $MAX_VIDEO_LAYERS layers. Delete one to add another.", android.widget.Toast.LENGTH_SHORT).show()
    return false
  }

  /** "+" add-layer icon, left of the scissors — plain white glyph, same
   *  style and size as the scissors/trash (no blue capsule or text). */
  private fun makeAddLayerButton(): View {
    val density = resources.displayMetrics.density
    return FrameLayout(this).apply {
      addView(
        EditorIconView(this@MediaEditorActivity, EditorIcon.PLUS).apply { iconTint = EditorDesignTokens.Colors.textPrimary },
        FrameLayout.LayoutParams((22f * density).toInt(), (22f * density).toInt(), Gravity.CENTER),
      )
      contentDescription = "Add a new layer"
      visibility = View.INVISIBLE
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        presentAddLayerSheet()
      }
    }
  }

  /** Bottom sheet listing what can be added as a new layer. Each tile just
   *  opens the tool that already exists; the new item then gets its own
   *  track starting at the playhead (registerLayerTiming). */
  private fun presentAddLayerSheet() {
    if (addLayerSheetRef != null) return
    val density = resources.displayMetrics.density
    fun px(dp: Float) = (dp * density).toInt()
    pauseVideoForToolInteraction()
    // Close any open tool first, same as every other tool entry point.
    selectedImageEditorTab = ImageEditorTab.TOOLS
    updateImageEditorUI(animated = false)
    fun openTab(tab: ImageEditorTab) {
      selectedImageEditorTab = tab
      updateImageEditorUI(animated = true)
    }

    val overlay = FrameLayout(this).apply {
      setBackgroundColor(Color.argb(115, 0, 0, 0))
      alpha = 0f
      elevation = 24f * density
      isClickable = true
      setOnClickListener { dismissAddLayerSheet() }
    }
    val sheet = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      isClickable = true // swallow taps so they don't dismiss
      setPadding(px(16f), px(10f), px(16f), px(16f) + navigationBarHeightPx)
      background = GradientDrawable().apply {
        val r = 22f * density
        cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
        setColor(EditorDesignTokens.Colors.panelBackground)
      }
    }
    sheet.addView(View(this).apply {
      background = GradientDrawable().apply {
        cornerRadius = 2f * density
        setColor(Color.rgb(0x3A, 0x3D, 0x43))
      }
    }, LinearLayout.LayoutParams(px(36f), px(4f)).apply { gravity = Gravity.CENTER_HORIZONTAL })

    val header = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    val titles = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    titles.addView(TextView(this).apply {
      text = "Add layer"
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      typeface = android.graphics.Typeface.DEFAULT_BOLD
    })
    titles.addView(TextView(this).apply {
      text = "Starts at ${formatMinSec(combinedTimeForCurrentPlaybackMs())} (playhead) · ${allLayerViews().size} of $MAX_VIDEO_LAYERS layers used"
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      setTextColor(EditorDesignTokens.Colors.textSecondary)
    }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(2f) })
    header.addView(titles, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
    header.addView(EditorIconView(this, EditorIcon.CLOSE).apply {
      iconTint = EditorDesignTokens.Colors.textPrimary
      contentDescription = "Close add layer"
      val pad = px(11f)
      setPadding(pad, pad, pad, pad)
      setOnClickListener { dismissAddLayerSheet() }
    }, LinearLayout.LayoutParams(px(44f), px(44f)))
    sheet.addView(header, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(10f) })

    data class Tile(val icon: EditorIcon, val color: Int, val name: String, val subtitle: String, val action: () -> Unit)
    val tiles = listOf(
      Tile(EditorIcon.TOOL_TEXT, EditorDesignTokens.Colors.textLayer, "Text", "Words, titles") { presentTextEntryOverlay() },
      Tile(EditorIcon.TOOL_STICKER, EditorDesignTokens.Colors.stickerLayer, "Sticker", "Library") { if (canAddLayer()) openTab(ImageEditorTab.STICKERS) },
      Tile(EditorIcon.TOOL_OVERLAY, EditorDesignTokens.Colors.accent, "Photo", "From gallery") { presentImageOverlayPicker() },
      Tile(EditorIcon.TOOL_MUSIC, EditorDesignTokens.Colors.musicLayer, "Music", if (selectedMusicTrack == null) "Add a track" else "Replace track") { openTab(ImageEditorTab.MUSIC) },
      Tile(EditorIcon.TOOL_ADD_VIDEO, Color.rgb(0x3A, 0x3D, 0x43), "Clip", "Adds to the end") { presentVideoClipPicker() },
      Tile(EditorIcon.MIC, EditorDesignTokens.Colors.voiceLayer, "Voice", if (voiceOverPath == null) "Record narration" else "Record again") { presentVoiceRecorder() },
    )
    val columns = 3
    tiles.chunked(columns).forEachIndexed { rowIndex, rowTiles ->
      val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
      for (column in 0 until columns) {
        val tile = rowTiles.getOrNull(column)
        val view: View = if (tile == null) View(this) else LinearLayout(this).apply {
          orientation = LinearLayout.VERTICAL
          gravity = Gravity.CENTER
          contentDescription = "${tile.name}, ${tile.subtitle}"
          background = GradientDrawable().apply {
            cornerRadius = 16f * density
            setColor(EditorDesignTokens.Colors.elevatedSurface)
          }
          addView(FrameLayout(this@MediaEditorActivity).apply {
            background = GradientDrawable().apply {
              cornerRadius = 12f * density
              setColor(tile.color)
            }
            addView(EditorIconView(this@MediaEditorActivity, tile.icon).apply { iconTint = Color.WHITE },
              FrameLayout.LayoutParams(px(22f), px(22f), Gravity.CENTER))
          }, LinearLayout.LayoutParams(px(40f), px(40f)))
          addView(TextView(this@MediaEditorActivity).apply {
            text = tile.name
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTextColor(EditorDesignTokens.Colors.textPrimary)
            isSingleLine = true
          }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(6f) })
          addView(TextView(this@MediaEditorActivity).apply {
            text = tile.subtitle
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setTextColor(EditorDesignTokens.Colors.textSecondary)
            isSingleLine = true
          })
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            dismissAddLayerSheet(animated = false)
            tile.action()
          }
        }
        row.addView(view, LinearLayout.LayoutParams(0, px(96f), 1f).apply { if (column > 0) marginStart = px(10f) })
      }
      sheet.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        topMargin = if (rowIndex == 0) px(14f) else px(10f)
      })
    }
    sheet.addView(TextView(this).apply {
      text = "Each new item gets its own track. Hold a track and drag up or down to change what sits on top."
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      setTextColor(EditorDesignTokens.Colors.textSecondary)
    }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(14f) })

    overlay.addView(sheet, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
    root.addView(overlay, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    addLayerSheetRef = overlay
    sheet.post {
      sheet.translationY = sheet.height.toFloat()
      overlay.animate().alpha(1f).setDuration(250).start()
      sheet.animate().translationY(0f).setDuration(250).setInterpolator(android.view.animation.DecelerateInterpolator()).start()
    }
  }

  private fun dismissAddLayerSheet(animated: Boolean = true) {
    val overlay = addLayerSheetRef ?: return
    addLayerSheetRef = null
    val sheet = (overlay as? ViewGroup)?.getChildAt(0)
    if (!animated || sheet == null) {
      root.removeView(overlay)
      return
    }
    sheet.animate().translationY(sheet.height.toFloat()).setDuration(200).start()
    overlay.animate().alpha(0f).setDuration(200).withEndAction { root.removeView(overlay) }.start()
  }

  // endregion

  private fun finishSuccess() {
    if (isExporting) return
    // Export reads the real canvas/layer views — bring them back first.
    exitFilterStage(animated = false)
    isExporting = true
    doneButtonRef?.isEnabled = false
    exportLoadingIndicatorRef?.visibility = View.VISIBLE

    // Story mode + a selected music track mixes the still photo + audio
    // into an exported VIDEO (see exportImageWithMusic's own doc) — every
    // other image case (no track selected, or the regular non-story
    // editor where Music isn't even offered for images) keeps the
    // original plain-image path below untouched.
    val isImageWithMusic = mediaType == "image" && isStoryMode && selectedMusicTrack != null

    if (mediaType == "image" && !isImageWithMusic) {
      exportImage { path, width, height ->
        val data = Intent()
        if (path != null) {
          data.putExtra(EXTRA_RESULT_STATUS, "success")
          data.putExtra(EXTRA_RESULT_TYPE, mediaType)
          data.putExtra(EXTRA_RESULT_URI, "file://$path")
          data.putExtra(EXTRA_RESULT_WIDTH, width)
          data.putExtra(EXTRA_RESULT_HEIGHT, height)
          data.putExtra(EXTRA_RESULT_DURATION, 0.0)
          data.putExtra(EXTRA_RESULT_STICKERS_JSON, exportedLocationStickers.toString())
          saveEditProject()?.let { data.putExtra(EXTRA_RESULT_EDIT_PROJECT, it) }
        } else {
          data.putExtra(EXTRA_RESULT_STATUS, "error")
          data.putExtra(EXTRA_RESULT_CODE, "export_failed")
          data.putExtra(EXTRA_RESULT_MESSAGE, "Could not export the edited image.")
        }
        setResult(Activity.RESULT_OK, data)
        finish()
      }
      return
    }

    // Video, OR a story-mode photo+music export (both go through
    // Transformer, so both take this same path — see isImageWithMusic
    // above). Video's own trim + crop/transform + filter + text/sticker
    // overlays get baked into an output file with its original audio
    // mixed against any selected music.
    //
    // Release the live-preview players FIRST — Transformer opens its own
    // decoder/encoder for the export, and leaving the preview's decoder
    // alive alongside it can exhaust the device's hardware codec sessions
    // (seen on-device as a MediaCodec NO_MEMORY/configure failure at
    // export's own decoder setup, nothing to do with crop/filter math).
    //
    // stop(), not release(): stopping also frees the decoders, but keeps the
    // players and all their wiring, so cancelling the export can bring the
    // preview straight back (release() left a dead editor after Cancel).
    // The frame on screen right now (filters included) for the export
    // box — copied from the preview's TextureView BEFORE the player stops.
    // Decoding a frame once the export runs could fail (the export holds
    // the phone's video decoders), which left the box empty.
    val previewFrame = (playerViewRef?.videoSurfaceView as? android.view.TextureView)?.let { view ->
      runCatching { if (view.isAvailable && view.width > 0) view.getBitmap() else null }.getOrNull()
    }?.takeUnless { isBlankFrame(it) }
    previewStoppedForExport = true
    exoPlayer?.stop()
    musicPlayer?.stop()

    // Full-screen progress overlay (per the user's explicit reference
    // screenshot) — video export can take a while, and the old small
    // exportLoadingIndicatorRef spinner gave no sense of progress or way
    // to back out. Blocks interaction with the editor underneath until
    // export finishes or the user cancels.
    val overlay = ExportProgressOverlayView(this)
    // Edge-to-edge window: keep its ✕ / text out of the status bar.
    overlay.setPadding(0, statusBarHeightPx, 0, 0)
    exportProgressOverlayRef = overlay
    overlay.onCancel = { cancelActiveExport() }
    (findViewById<View>(android.R.id.content) as ViewGroup).addView(
      overlay,
      ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
    )
    if (previewFrame != null) {
      overlay.setThumbnail(previewFrame)
    } else {
      videoPosterFrame?.takeUnless { isBlankFrame(it) }?.let { overlay.setThumbnail(it) }
      loadExportThumbnail { bitmap -> if (bitmap != null && !isBlankFrame(bitmap)) overlay.setThumbnail(bitmap) }
    }

    fun handleExportResult(path: String?, width: Int, height: Int, durationMs: Long, errorMessage: String?) {
      // A null overlay ref means cancelActiveExport() already ran —
      // Transformer.cancel() should itself prevent onCompleted/onError
      // from firing, but this guard is a cheap backstop against acting on
      // a stale callback that fires anyway (e.g. a race between cancel
      // and an in-flight completion).
      if (exportProgressOverlayRef == null) return
      stopExportProgressPolling()
      activeTransformer = null
      // Snap the smoothed display straight to 100% BEFORE tearing the
      // overlay down — per the user's own "don't make it fast" request
      // the ring intentionally climbs at a capped rate, which means it
      // can still be short of 100% at the exact moment the real export
      // finishes; without this it would otherwise just vanish mid-climb.
      exportProgressOverlayRef?.finishProgress()
      exportProgressOverlayRef?.let { (it.parent as? ViewGroup)?.removeView(it) }
      exportProgressOverlayRef = null
      val data = Intent()
      if (path != null) {
        data.putExtra(EXTRA_RESULT_STATUS, "success")
        // A photo+music export actually produced a video — report that,
        // not the original input's mediaType, so the RN bridge/JS side
        // (which branches on the returned type) uploads it correctly.
        data.putExtra(EXTRA_RESULT_TYPE, if (isImageWithMusic) "video" else mediaType)
        data.putExtra(EXTRA_RESULT_URI, "file://$path")
        data.putExtra(EXTRA_RESULT_WIDTH, width)
        data.putExtra(EXTRA_RESULT_HEIGHT, height)
        data.putExtra(EXTRA_RESULT_DURATION, durationMs / 1000.0)
        data.putExtra(EXTRA_RESULT_STICKERS_JSON, exportedLocationStickers.toString())
      } else {
        data.putExtra(EXTRA_RESULT_STATUS, "error")
        data.putExtra(EXTRA_RESULT_CODE, "export_failed")
        data.putExtra(EXTRA_RESULT_MESSAGE, errorMessage ?: "Could not export the edited video.")
      }
      setResult(Activity.RESULT_OK, data)
      finish()
    }

    if (isImageWithMusic) {
      exportImageWithMusic { path, width, height, durationMs, errorMessage ->
        handleExportResult(path, width, height, durationMs, errorMessage)
      }
    } else {
      exportVideo { path, width, height, durationMs, errorMessage ->
        handleExportResult(path, width, height, durationMs, errorMessage)
      }
    }
  }

  /** Story mode's "Download to gallery" rail action — exports the current
   *  edit via the exact same exportImage/exportVideo pipeline Share uses,
   *  then saves the result to the device's photo library and STAYS in the
   *  editor (unlike Share/finishSuccess, which calls setResult/finish()).
   *  Known simplification: unlike finishSuccess()'s video branch, this does
   *  NOT release/recreate the live preview players (exoPlayer/musicPlayer)
   *  first — accepting finishSuccess()'s own documented risk of hardware
   *  codec contention during export, since releasing them here would leave
   *  the editor's own preview broken afterward with no safe way to
   *  re-initialize it blind (untestable in the environment this was
   *  written in — flag for on-device verification). */
  private fun performDownloadToGallery() {
    if (isExporting) return
    pauseVideoForToolInteraction()
    isExporting = true
    exportLoadingIndicatorRef?.visibility = View.VISIBLE

    fun onExported(path: String?) {
      isExporting = false
      exportLoadingIndicatorRef?.visibility = View.GONE
      if (path == null) {
        android.widget.Toast.makeText(this, "Could not save to gallery. Please try again.", android.widget.Toast.LENGTH_SHORT).show()
        return
      }
      val saved = saveExportedFileToMediaStore(path, mediaType == "video")
      android.widget.Toast.makeText(
        this,
        if (saved) "Saved to gallery" else "Could not save to gallery. Please try again.",
        android.widget.Toast.LENGTH_SHORT,
      ).show()
    }

    if (mediaType == "image") {
      exportImage { path, _, _ -> onExported(path) }
    } else {
      exportVideo { path, _, _, _, _ -> onExported(path) }
    }
  }

  /** Adapted from modules/native-gallery/android/.../NativeGalleryModule
   *  .java's saveToCameraRoll — the same plain MediaStore/ContentResolver
   *  logic, with no RN bridge types, callable directly from this Activity
   *  (which already has `contentResolver` as an Activity). */
  private fun saveExportedFileToMediaStore(srcPath: String, isVideo: Boolean): Boolean {
    return try {
      val cleanPath = if (srcPath.startsWith("file://")) {
        android.net.Uri.parse(srcPath).path ?: srcPath
      } else {
        srcPath
      }
      val src = File(cleanPath)
      if (!src.exists()) return false

      val collection = if (isVideo) {
        android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI
      } else {
        android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI
      }
      val values = android.content.ContentValues().apply {
        put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, src.name)
      }

      if (android.os.Build.VERSION.SDK_INT >= 29) {
        val dir = if (isVideo) android.os.Environment.DIRECTORY_DCIM else android.os.Environment.DIRECTORY_PICTURES
        values.put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, dir)
        values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
        val uri = contentResolver.insert(collection, values) ?: return false
        val opened = contentResolver.openOutputStream(uri)?.use { out ->
          java.io.FileInputStream(src).use { input -> input.copyTo(out) }
          true
        } ?: false
        if (!opened) return false
        values.clear()
        values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
        contentResolver.update(uri, values, null, null)
      } else {
        val baseDir = android.os.Environment.getExternalStoragePublicDirectory(
          if (isVideo) android.os.Environment.DIRECTORY_DCIM else android.os.Environment.DIRECTORY_PICTURES,
        )
        if (!baseDir.exists()) baseDir.mkdirs()
        val dest = File(baseDir, src.name)
        java.io.FileInputStream(src).use { input ->
          FileOutputStream(dest).use { out -> input.copyTo(out) }
        }
        values.put(android.provider.MediaStore.MediaColumns.DATA, dest.absolutePath)
        contentResolver.insert(collection, values)
      }
      true
    } catch (e: Exception) {
      Log.e("MediaEditorActivity", "saveExportedFileToMediaStore failed", e)
      false
    }
  }

  /** Grabs the primary video's own first frame for the export-progress
   *  overlay's thumbnail — same MediaMetadataRetriever-on-a-background-
   *  Thread technique already used by loadAdditionalClipThumbnail, just
   *  targeting `mediaUri` instead of a merged clip's uri. */
  /** A copied surface can come back fully transparent (or all black);
   *  that counts as no picture, so the fallbacks / placeholder are used. */
  private fun isBlankFrame(bitmap: Bitmap): Boolean {
    if (bitmap.isRecycled || bitmap.width < 2 || bitmap.height < 2) return true
    return runCatching {
      var visible = 0
      for (ix in 1..5) for (iy in 1..5) {
        val pixel = bitmap.getPixel(bitmap.width * ix / 6, bitmap.height * iy / 6)
        if (Color.alpha(pixel) > 16 && (Color.red(pixel) + Color.green(pixel) + Color.blue(pixel)) > 24) visible++
      }
      visible == 0
    }.getOrDefault(false)
  }

  private fun loadExportThumbnail(onLoaded: (Bitmap?) -> Unit) {
    // The main clip's frame under the playhead (or its first kept frame),
    // trying a few ways — frame 0 at the nearest sync point alone came
    // back empty for some videos, leaving the export box blank.
    val firstKeptMs = videoSegments.firstOrNull()?.first ?: 0L
    val playheadMs = exoPlayer?.takeIf { it.currentMediaItemIndex == 0 }?.currentPosition ?: firstKeptMs
    Thread {
      val retriever = android.media.MediaMetadataRetriever()
      val bitmap = try {
        retriever.setDataSource(this, MediaMetadataReader.normalizedUri(mediaUri))
        retriever.scaledFrameAt(playheadMs * 1000, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC, PREVIEW_FRAME_MAX_SIDE)
          ?: retriever.scaledFrameAt(firstKeptMs * 1000, android.media.MediaMetadataRetriever.OPTION_CLOSEST, PREVIEW_FRAME_MAX_SIDE)
          ?: retriever.frameAtTime
      } catch (e: Exception) {
        null
      } finally {
        runCatching { retriever.release() }
      }
      runOnUiThread { onLoaded(bitmap) }
    }.start()
  }

  /** Polls Transformer's own progress (0-100) on a ~200ms cadence and
   *  feeds it to the visible overlay — Media3 has no push-based progress
   *  callback, `Transformer.getProgress` is the documented poll API. */
  private fun startExportProgressPolling(transformer: Transformer) {
    val handler = Handler(Looper.getMainLooper())
    exportProgressHandler = handler
    val holder = ProgressHolder()
    val poll = object : Runnable {
      override fun run() {
        if (activeTransformer !== transformer) return // cancelled/replaced — stop this loop
        transformer.getProgress(holder)
        exportProgressOverlayRef?.setProgress(holder.progress)
        handler.postDelayed(this, 200L)
      }
    }
    handler.post(poll)
  }

  private fun stopExportProgressPolling() {
    exportProgressHandler?.removeCallbacksAndMessages(null)
    exportProgressHandler = null
  }

  /** The export-progress overlay's X button — actually stops the
   *  underlying Transformer (not just hides the overlay while export
   *  secretly keeps running), discards any partial output, and returns
   *  the user to the editor rather than finishing the Activity. */
  private fun cancelActiveExport() {
    stopExportProgressPolling()
    activeTransformer?.cancel()
    activeTransformer = null
    // The half-written video is useless — don't leave it in the cache.
    activeExportOutputFile?.let { file -> Thread { runCatching { file.delete() } }.start() }
    activeExportOutputFile = null
    exportProgressOverlayRef?.let { (it.parent as? ViewGroup)?.removeView(it) }
    exportProgressOverlayRef = null
    isExporting = false
    doneButtonRef?.isEnabled = true
    restorePreviewAfterCancelledExport()
  }

  /** Back to a working editor after Cancel: reload the playlist (main clip +
   *  merged clips) into the stopped players, paused at the start. */
  private fun restorePreviewAfterCancelledExport() {
    if (!previewStoppedForExport) return
    previewStoppedForExport = false
    exoPlayer?.let { player ->
      player.setMediaItems(
        listOf(MediaItem.fromUri(MediaMetadataReader.normalizedUri(mediaUri))) +
          additionalVideoClipUris.flatMap { makeAdditionalPlaylistMediaItems(it) },
      )
      player.prepare()
      player.seekTo(0, videoSegments.firstOrNull()?.first ?: 0L)
      player.volume = effectivePlayerVolume()
      applyPreviewSpeed()
    }
    musicPlayer?.prepare()
    pauseVideoForToolInteraction()
  }

  // MARK: - Video Export (Day 26a + 26b + 26c)
  //
  // Bakes trim + crop/pan/zoom/rotate + filter into a real output file via
  // Media3 Transformer — the same decode/apply-effects/encode/mux pipeline
  // Transformer already provides, reusing the exact same Effect used for
  // live preview (PhotoFilterRgbMatrix, Day 20) so preview and export can
  // never visually drift apart. Day 26b adds text/sticker overlays via
  // Media3's own BitmapOverlay/OverlayEffect (found by decompiling
  // media3-effect-1.4.1.aar — same verification approach as the Crop bug
  // below): each visible layer is pre-rendered once to its own transparent-
  // background Bitmap (same TextPaint recipe as the image path's
  // drawLayerForExport) and placed via OverlaySettings, positioned in the
  // FINAL exportWidth x exportHeight frame (i.e. after Crop+Presentation),
  // matching the image export's rule that layers sit in canvas-space,
  // independent of the video's own pan/zoom/rotate.
  //
  // Day 26c bakes in original-audio volume/mute and music mixing. Volume
  // for either track is a `ChannelMixingAudioProcessor` holding an identity
  // matrix scaled by the desired volume (`ChannelMixingMatrix.create(n,
  // n).scaleBy(volume)`, registered for both mono and stereo since the
  // real channel count isn't known ahead of time) — Media3 has no simpler
  // "just set gain" audio effect, this is the documented mechanism
  // (`media3-common`'s own `ChannelMixingAudioProcessor`). Music mixing
  // uses `Composition.Builder(sequence1, sequence2, ...)`: the main video
  // is one `EditedMediaItemSequence`, and a selected music track becomes a
  // SECOND, independently-clipped, audio-only sequence
  // (`setRemoveVideo(true)`) — Transformer mixes every sequence's audio
  // together automatically, which is the whole purpose of a multi-sequence
  // Composition. Confirmed via decompiling media3-transformer-1.4.1.aar
  // that `Transformer.start(Composition, String)` exists as a direct
  // overload alongside the single-`EditedMediaItem` one already in use.
  //
  // OverlayEffect's coordinate frame comes from OverlayMatrixProvider, which
  // builds its matrix via raw android.opengl.Matrix.rotateM/translateM — a
  // Y-up, counterclockwise-positive convention on paper, the SAME one
  // already verified by the Crop math below (top/smaller-Y maps to larger
  // NDC Y) — which predicted layer.rotation would need to be NEGATED before
  // OverlaySettings.setRotationDegrees to match Android's own Y-down/
  // clockwise View.rotation convention. Device-tested and that prediction
  // was backwards: passing layer.rotation as-is (no negation) is what
  // actually matches the live preview. Lesson: OverlayEffect's overall
  // pipeline apparently re-flips Y somewhere between this matrix and the
  // final sampled frame (likely the same Y-flip BitmapOverlay applies when
  // uploading a Bitmap as a GL texture, since Android bitmaps are top-down
  // and GL textures are bottom-up) — bytecode alone wasn't enough to catch
  // that; only a device test with a rotated layer was conclusive.
  //
  // Crop math reuses the exact formula already proven by the image export
  // (Day 15): rotation/scale happen around the canvas's own center for both
  // playerView's live transform AND ScaleAndRotateTransformation below, so
  // pan reduces to a pure shift of the crop window in that same center-
  // relative space — this decomposition is only exact because scale is
  // uniform (scaleX == scaleY), which the pinch gesture guarantees.
  private fun exportVideo(onResult: (path: String?, width: Int, height: Int, durationMs: Long, errorMessage: String?) -> Unit) {
    val playerView = playerViewRef
    val canvasWidth = playerView?.width ?: 0
    val canvasHeight = playerView?.height ?: 0
    // MediaMetadataReader.read does real file I/O (opening/parsing the
    // container for duration/rotation/dimensions) — per the user's
    // explicit "export takes too long and sometimes crashes" report, this
    // used to run synchronously on the calling thread (the Done button's
    // own tap handler, i.e. the main thread), which can block it long
    // enough on a large file / slow storage to trip Android's ANR
    // watchdog — indistinguishable from a random "crash" to the user.
    // Moved to a background thread; everything else below (View property
    // reads, bitmap rendering, and Transformer.start() itself, which
    // requires a Looper thread) resumes on the main thread via
    // runOnUiThread, mirroring this file's own existing
    // loadAdditionalClipThumbnail Thread{...runOnUiThread{...}} pattern —
    // nothing else in this function's own logic changes.
    // Flushes whichever clip is CURRENTLY being edited (per
    // syncActiveClipFilterState's own "null = primary" convention) into
    // clipFilterState before export reads it — otherwise a just-changed
    // slider value wouldn't be reflected if the user tapped Done before
    // the playhead ever crossed back off that clip (the only OTHER time
    // this map gets updated).
    clipFilterState[activeClipUri ?: mediaUri] = currentFilterStateSnapshot()
    Thread {
      val metadata = MediaMetadataReader.read(this, mediaUri, mediaType)
      runOnUiThread {
        exportVideoOnMainThread(playerView, canvasWidth, canvasHeight, metadata, onResult)
      }
    }.start()
  }

  private fun exportVideoOnMainThread(
    playerView: PlayerView?,
    canvasWidth: Int,
    canvasHeight: Int,
    metadata: MediaMetadata?,
    onResult: (path: String?, width: Int, height: Int, durationMs: Long, errorMessage: String?) -> Unit,
  ) {
    if (playerView == null || canvasWidth <= 0 || canvasHeight <= 0 ||
      metadata == null || metadata.width <= 0 || metadata.height <= 0
    ) {
      onResult(null, 0, 0, 0, "Could not read the video canvas or metadata.")
      return
    }

    val nativeWidth = metadata.width
    val nativeHeight = metadata.height
    val videoAspect = nativeWidth.toFloat() / nativeHeight
    val canvasAspect = canvasWidth.toFloat() / canvasHeight
    val renderedWidthInCanvasPx = if (videoAspect > canvasAspect) {
      canvasWidth.toFloat()
    } else {
      canvasHeight * videoAspect
    }
    if (renderedWidthInCanvasPx <= 0) {
      onResult(null, 0, 0, 0, "Could not compute export scale.")
      return
    }
    val rawExportScale = nativeWidth / renderedWidthInCanvasPx

    // Crop feature removed — always export the full canvas (equivalent to
    // a crop rect that exactly matches the canvas bounds). This variable
    // (and the media3 Crop effect built from it below) stay, rather than
    // being deleted outright: pan has no dedicated effect in this
    // Transformer pipeline — it's expressed entirely by the Crop window's
    // POSITION (see cropInRotatedFrame below), so removing Crop would
    // silently remove pan too. Fixing this rect's SIZE to the full canvas
    // removes cropping while leaving pan's mechanism untouched.
    val cropRect = RectF(0f, 0f, canvasWidth.toFloat(), canvasHeight.toFloat())

    // Clamp so the crop's exported render size never exceeds
    // MAX_EXPORT_PIXEL_SIZE on its longest side — the same cap already
    // applied to image export's high-res source decode. Uncapped, a
    // high-res source video can push the exported frame size well past
    // what's reasonable for GPU texture limits / encoder max resolution on
    // some devices (and needlessly inflates output file size besides).
    val uncappedCropWidthExport = cropRect.width() * rawExportScale
    val uncappedCropHeightExport = cropRect.height() * rawExportScale
    val largestUncappedDimension = maxOf(uncappedCropWidthExport, uncappedCropHeightExport)
    val exportScale = if (largestUncappedDimension > MAX_EXPORT_PIXEL_SIZE) {
      rawExportScale * (MAX_EXPORT_PIXEL_SIZE / largestUncappedDimension)
    } else {
      rawExportScale
    }

    val canvasCenterXExport = (canvasWidth / 2f) * exportScale
    val canvasCenterYExport = (canvasHeight / 2f) * exportScale
    val panXExport = playerView.translationX * exportScale
    val panYExport = playerView.translationY * exportScale

    // Where the crop window lands relative to the video's own center, in a
    // frame that's already been rotated/scaled around that center — i.e.
    // the state AFTER ScaleAndRotateTransformation below, BEFORE this Crop.
    val cropInRotatedFrame = RectF(
      nativeWidth / 2f + cropRect.left * exportScale - canvasCenterXExport - panXExport,
      nativeHeight / 2f + cropRect.top * exportScale - canvasCenterYExport - panYExport,
      nativeWidth / 2f + cropRect.right * exportScale - canvasCenterXExport - panXExport,
      nativeHeight / 2f + cropRect.bottom * exportScale - canvasCenterYExport - panYExport,
    )
    // MediaCodec encoders commonly reject odd width/height.
    val exportWidth = ((cropInRotatedFrame.width().toInt().coerceAtLeast(2)) / 2) * 2
    val exportHeight = ((cropInRotatedFrame.height().toInt().coerceAtLeast(2)) / 2) * 2

    // Crop's NDC convention is Y-up (OpenGL) — pixel-space top (smaller Y)
    // maps to the LARGER NDC Y value.
    val leftNdc = 2f * cropInRotatedFrame.left / nativeWidth - 1f
    val rightNdc = 2f * cropInRotatedFrame.right / nativeWidth - 1f
    val topNdc = 1f - 2f * cropInRotatedFrame.top / nativeHeight
    val bottomNdc = 1f - 2f * cropInRotatedFrame.bottom / nativeHeight

    val scale = playerView.scaleX
    val rotationDeg = playerView.rotation

    // Explicit snapshot rather than combinedColorMatrix()'s own default
    // (which reads the live working-copy globals) — those globals reflect
    // whichever clip was LAST being edited (see syncActiveClipFilterState),
    // not necessarily mediaUri specifically, if the user's playhead was
    // sitting on a merged clip when they tapped Done. exportVideo already
    // flushed that clip's own values into clipFilterState just before this
    // ran, so this always resolves to the PRIMARY clip's own values.
    val primaryFilterState = clipFilterState[mediaUri] ?: ClipFilterState()

    val videoEffects = mutableListOf<Effect>()
    if (scale != 1f || rotationDeg != 0f) {
      videoEffects.add(
        ScaleAndRotateTransformation.Builder()
          .setScale(scale, scale)
          .setRotationDegrees(rotationDeg)
          .build(),
      )
    }
    // Crop's constructor order is (left, right, bottom, top) — verified by
    // inspecting media3-effect-1.4.1's decompiled bytecode directly, since
    // this is easy to get backwards from the class name alone (its own
    // internal assertions check right > left and top > bottom).
    videoEffects.add(Crop(leftNdc, rightNdc, bottomNdc, topNdc))
    videoEffects.add(Presentation.createForWidthAndHeight(exportWidth, exportHeight, Presentation.LAYOUT_SCALE_TO_FIT))
    // Same combined filter+adjustment matrix as live preview (see its use
    // in onCreate's video branch) — was filter-only through an earlier,
    // deliberately narrower pass; closing that gap is Phase 1a.
    if (primaryFilterState.filter != PhotoFilter.ORIGINAL) {
      val primaryFilterParams = filterGpuParams(primaryFilterState)
      videoEffects.add(FilterLutEffect { primaryFilterParams })
    }
    videoEffects.add(PhotoFilterRgbMatrix { combinedColorMatrix(primaryFilterState) })

    // Overlays are added LAST so they're positioned relative to the final
    // exportWidth x exportHeight frame (post-crop), same canvas-space rule
    // the image export and the live preview both already use.
    val cropRectExportLeft = cropRect.left * exportScale
    val cropRectExportTop = cropRect.top * exportScale
    // Text/sticker layers are children of `root`, added with
    // Gravity.CENTER — NOT children of playerView — so their on-screen
    // base position is root's own center, not playerView's. Convert
    // root's center into playerView's LOCAL coordinate space by
    // subtracting playerView's own on-screen offset within root — same
    // fix as renderExport's identical bug for image export.
    val layerBaseX = root.width / 2f - playerView.left
    val layerBaseY = root.height / 2f - playerView.top

    // Draw strokes, added FIRST so they sit under text/sticker/overlay
    // layers, matching renderExport's on-screen/image-export stacking
    // order (strokes drawn right after the base image, before any layer).
    // Unlike the layer loops below, drawingCanvasRef occupies playerView's
    // own STATIC box exactly (see layoutImageCanvas) — the same box the
    // Crop effect above already normalizes the exported frame to — so a
    // stroke point needs only `* exportScale`, no layerBaseX/Y correction
    // and no per-stroke anchor: one full-frame bitmap anchored dead-center.
    Log.d(
      "MediaEditor",
      "exportVideo: drawingCanvasRef=${drawingCanvasRef != null} strokes=${drawingCanvasRef?.allStrokes()?.size ?: -1} " +
        "imageOverlayLayerViews=${imageOverlayLayerViews.size} textLayerViews=${textLayerViews.size} stickerLayerViews=${stickerLayerViews.size}",
    )
    // (on-screen stacking index, overlay) — added to `overlays` sorted, so
    // the export keeps "last added on top" like the preview.
    // Each layer is kept as a spec (bitmap + placement + its time windows)
    // and turned into fresh overlay objects per exported item below, so
    // every kept segment / merged clip shows a layer only inside that
    // layer's own time windows on the combined timeline.
    val layerOverlays = mutableListOf<Pair<Int, TimedOverlaySpec>>()
    drawingCanvasRef?.let { drawView ->
      val strokesBitmap = renderStrokesOverlayBitmap(drawView, exportWidth, exportHeight, exportScale)
      Log.d("MediaEditor", "exportVideo: strokesBitmap=${strokesBitmap != null}")
      strokesBitmap?.let { bitmap ->
        layerOverlays += root.indexOfChild(drawView) to TimedOverlaySpec(bitmap, { _, _, _, _ -> OverlaySettings.Builder() }, null)
      }
    }

    val locationStickers = JSONArray()
    for (layer in textLayerViews + stickerLayerViews) {
      if (layer.visibility != View.VISIBLE) continue
      if (isLayerUserHidden(layer)) continue
      val bitmap = renderOverlayBitmap(layer, exportScale) ?: continue
      val layerCenter = layerCenterInExport(layer, layerBaseX, layerBaseY, exportScale)
      val overlayXExport = layerCenter.x - cropRectExportLeft
      val overlayYExport = layerCenter.y - cropRectExportTop
      locationLayerStates[layer]?.takeIf { it.kind in TAPPABLE_INFO_KINDS }?.let { state ->
        locationStickers.put(
          locationStickerJson(layer, state, overlayXExport, overlayYExport, exportScale, exportWidth, exportHeight),
        )
      }
      val backgroundAnchorX = 2f * overlayXExport / exportWidth - 1f
      val backgroundAnchorY = 1f - 2f * overlayYExport / exportHeight
      val layerRotation = layer.rotation
      val layerScaleX = layer.scaleX
      val layerScaleY = layer.scaleY
      val settings = { scaleMul: Float, anchorDx: Float, anchorDy: Float, rotationDeg: Float ->
        OverlaySettings.Builder()
          .setBackgroundFrameAnchor(backgroundAnchorX + anchorDx, backgroundAnchorY + anchorDy)
          .setRotationDegrees(layerRotation + rotationDeg)
          .setScale(layerScaleX * scaleMul, layerScaleY * scaleMul)
      }
      layerOverlays += root.indexOfChild(layer) to TimedOverlaySpec(
        bitmap, settings, layerTimings[layer]?.segments?.toList(),
        anim = if (layer in stickerLayerViews) TextAnimConfig.NONE else layerTimings[layer]?.anim ?: TextAnimConfig.NONE,
      )
    }
    // Overlay (image-over-image) layers — same base-anchor convention as
    // text/sticker above (see drawImageOverlayForExport's identical
    // convention for image export), just rasterizing the layer's own
    // bitmap instead of text.
    for (layer in imageOverlayLayerViews) {
      Log.d("MediaEditor", "exportVideo: overlay layer visibility=${layer.visibility} drawable=${layer.drawable}")
      if (layer.visibility != View.VISIBLE) continue
      if (isLayerUserHidden(layer)) continue
      val bitmap = renderOverlayImageBitmap(layer, exportScale) ?: continue
      val overlayXExport = (layerBaseX + layer.translationX) * exportScale - cropRectExportLeft
      val overlayYExport = (layerBaseY + layer.translationY) * exportScale - cropRectExportTop
      val backgroundAnchorX = 2f * overlayXExport / exportWidth - 1f
      val backgroundAnchorY = 1f - 2f * overlayYExport / exportHeight
      val layerRotation = layer.rotation
      val layerScaleX = layer.scaleX
      val layerScaleY = layer.scaleY
      val settings = { scaleMul: Float, anchorDx: Float, anchorDy: Float, rotationDeg: Float ->
        OverlaySettings.Builder()
          .setBackgroundFrameAnchor(backgroundAnchorX + anchorDx, backgroundAnchorY + anchorDy)
          .setRotationDegrees(layerRotation + rotationDeg)
          .setScale(layerScaleX * scaleMul, layerScaleY * scaleMul)
      }
      layerOverlays += root.indexOfChild(layer) to TimedOverlaySpec(bitmap, settings, layerTimings[layer]?.segments?.toList())
    }
    // sortedBy is stable: equal indexes keep their order.
    val overlaySpecs = layerOverlays.sortedBy { it.first }.map { it.second }
    exportedLocationStickers = locationStickers
    Log.d("MediaEditor", "exportVideo: total overlays=${overlaySpecs.size}")
    /** Fresh overlay objects for one exported item that starts at
     *  [itemCombinedStartMs] on the combined timeline (null = no layers). */
    fun overlayEffectFor(itemCombinedStartMs: Long, speed: Float = 1f): OverlayEffect? {
      if (overlaySpecs.isEmpty()) return null
      return OverlayEffect(ImmutableList.copyOf(overlaySpecs.map { it.makeOverlay(itemCombinedStartMs, speed) as TextureOverlay }))
    }

    val totalDurationMs = (metadata.durationSeconds * 1000).toLong()
    // Clamp each kept segment to the asset's real duration (in case it was
    // configured against a slightly different duration reading) and drop
    // any that collapse to nothing once clamped.
    val clampedSegments = videoSegments.mapNotNull { segment ->
      val start = segment.first.coerceIn(0, totalDurationMs)
      val end = segment.last.coerceIn(start, totalDurationMs)
      if (end > start) start..end else null
    }
    if (clampedSegments.isEmpty()) {
      onResult(null, 0, 0, 0, "Invalid trim range.")
      return
    }

    val originalAudioEffectiveVolume = originalAudioVolume
    // Each kept segment becomes its own EditedMediaItem, all sharing the
    // SAME effects (filter/adjust/overlays/audio volume) — concatenating
    // them back-to-back by putting them all in ONE EditedMediaItemSequence
    // is what actually drops the deleted parts from the exported file,
    // the same "list of clipped items in one sequence" mechanism already
    // used below to mix in a second (music) sequence, just applied within
    // the MAIN sequence instead.
    // Speed control: each item plays at its clip's speed (video + audio,
    // pitch kept). Layer windows / music stay in the editor's own time and
    // are mapped onto the output timeline.
    val speedBlocks = timelineSpeedParts()
    val toOutputMs: (Long) -> Long = { t ->
      var out = 0.0
      var result: Long? = null
      for ((start, kept, speed) in speedBlocks) {
        if (t <= start + kept) { result = (out + (t - start).coerceAtLeast(0) / speed).toLong(); break }
        out += kept / speed
      }
      result ?: out.toLong()
    }
    // Transitions: into each merged clip's first item, out of the last item
    // of whatever plays before it.
    val firstMergedUri = additionalVideoClipUris.firstOrNull()
    val primaryOutTransition = firstMergedUri?.let { transitionsIn[it] } ?: 0
    // Voice-over: its span on the output timeline (ducks the other audio).
    val voiceDuckWindowOutMs = voiceOverPath?.let {
      val start = toOutputMs(voiceOverStartMs)
      start..(start + voiceOverDurationMs)
    }
    var primaryItemStartMs = 0L
    val editedSegmentItems = clampedSegments.mapIndexed { segmentIndex, segment ->
      // Each part exports at its own speed.
      val primarySpeed = partSpeed(mediaUri, segment)
      val itemEffects = videoEffects.toMutableList()
      if (primarySpeed != 1f) itemEffects.add(0, SpeedChangeEffect(primarySpeed))
      if (segmentIndex == clampedSegments.lastIndex && primaryOutTransition != 0) {
        itemEffects.add(ClipTransitionEffect(0, primaryOutTransition, ((segment.last - segment.first) * 1000 / primarySpeed).toLong()))
      }
      overlayEffectFor(primaryItemStartMs, primarySpeed)?.let { itemEffects.add(it) }
      val itemOutStartMs = toOutputMs(primaryItemStartMs)
      primaryItemStartMs += segment.last - segment.first
      val segmentMediaItem = MediaItem.Builder()
        .setUri(MediaMetadataReader.normalizedUri(mediaUri))
        .setClippingConfiguration(
          MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs(segment.first)
            .setEndPositionMs(segment.last)
            .build(),
        )
        .build()
      val primaryFades = fadeAudioEffects(
        fadeIn = audioFadeIn && segmentIndex == 0,
        fadeOut = audioFadeOut && segmentIndex == clampedSegments.lastIndex && additionalVideoClipUris.isEmpty(),
        totalUs = ((segment.last - segment.first) * 1000 / primarySpeed).toLong(),
        itemOutStartMs = itemOutStartMs,
        duckWindowOutMs = voiceDuckWindowOutMs,
      )
      EditedMediaItem.Builder(segmentMediaItem)
        .setEffects(Effects(speedAudioEffects(primarySpeed) + audioEffectsFor(originalAudioEffectiveVolume * clipVolume(mediaUri)) + primaryFades, itemEffects))
        .build()
    }
    val totalKeptDurationMs = clampedSegments.sumOf { it.last - it.first }

    // Merged clips (see presentVideoClipPicker's own doc): each of their
    // own KEPT SEGMENTS is appended, in order, as one more EditedMediaItem
    // in the SAME sequence right after the primary clip's own kept
    // segments — that's what actually concatenates them all into one
    // continuous output, same "list of clipped items in one sequence"
    // mechanism as the primary clip's own segments just above, now simply
    // flat-mapped since makeAdditionalPlaylistMediaItems already returns
    // one MediaItem per kept segment (uses the user's saved segments —
    // see refreshMergedClipsStrip — exactly like the live preview does).
    // Each merged clip now carries its OWN filter/adjustments (see
    // clipFilterState's own doc) — per the user's explicit "edits should
    // stay with their own clip" request. No pan/zoom/text-overlays of
    // their own though — those remain primary-clip-only (pan/zoom isn't
    // even a real per-clip concept for video at all, see cropRect's own
    // doc above; text/sticker/overlay layers are positioned by TIME across
    // the whole combined timeline, not per-clip, and are unaffected by
    // reordering). Presentation still letterbox-fits each one's own
    // (possibly different) aspect ratio into the SAME exportWidth x
    // exportHeight every other item already renders to; Media3 applies
    // each source's own rotation metadata automatically here (unlike
    // iOS's custom AVVideoCompositing path, this pipeline needs no manual
    // fix).
    // Layers span the whole combined timeline in the editor, so they're
    // drawn over merged clips too (each only inside its own time windows).
    val mergedBlockStarts = timelineBlocks().filter { it.uri != null }.associate { it.uri to it.combinedStartMs }
    val additionalSegmentItems = additionalVideoClipUris.flatMap { additionalUri ->
      val additionalFilterState = clipFilterState[additionalUri] ?: ClipFilterState()
      val additionalFilterParams = filterGpuParams(additionalFilterState)
      var mergedItemStartMs = mergedBlockStarts[additionalUri] ?: totalKeptDurationMs
      val mergedSegments = additionalClipSegments[additionalUri]
      val mergedItems = makeAdditionalPlaylistMediaItems(additionalUri)
      val nextUri = additionalVideoClipUris.getOrNull(additionalVideoClipUris.indexOf(additionalUri) + 1)
      mergedItems.mapIndexed { mergedIndex, mediaItem ->
        val itemStartMs = mergedItemStartMs
        mergedSegments?.getOrNull(mergedIndex)?.let { mergedItemStartMs += it.last - it.first }
        val clipVideoEffects = mutableListOf<Effect>()
        val mergedSpeed = partSpeed(additionalUri, clipParts(additionalUri).getOrNull(mergedIndex) ?: 0L..0L)
        if (mergedSpeed != 1f) clipVideoEffects.add(SpeedChangeEffect(mergedSpeed))
        if (additionalFilterState.filter != PhotoFilter.ORIGINAL) clipVideoEffects.add(FilterLutEffect { additionalFilterParams })
        clipVideoEffects.add(PhotoFilterRgbMatrix { combinedColorMatrix(additionalFilterState) })
        clipVideoEffects.add(Presentation.createForWidthAndHeight(exportWidth, exportHeight, Presentation.LAYOUT_SCALE_TO_FIT))
        val inType = if (mergedIndex == 0) transitionsIn[additionalUri] ?: 0 else 0
        val outType = if (mergedIndex == mergedItems.lastIndex) nextUri?.let { transitionsIn[it] } ?: 0 else 0
        if (inType != 0 || outType != 0) {
          val pieceMs = mergedSegments?.getOrNull(mergedIndex)?.let { it.last - it.first } ?: (additionalClipDurationsMs[additionalUri] ?: 0L)
          clipVideoEffects.add(ClipTransitionEffect(inType, outType, (pieceMs * 1000 / mergedSpeed).toLong()))
        }
        overlayEffectFor(itemStartMs, mergedSpeed)?.let { clipVideoEffects.add(it) }
        EditedMediaItem.Builder(mediaItem)
          .setEffects(Effects(
            speedAudioEffects(mergedSpeed) + audioEffectsFor(originalAudioEffectiveVolume * clipVolume(additionalUri)) +
              fadeAudioEffects(
                fadeIn = false,
                fadeOut = audioFadeOut && additionalUri == additionalVideoClipUris.last() && mergedIndex == mergedItems.lastIndex,
                totalUs = ((mergedSegments?.getOrNull(mergedIndex)?.let { it.last - it.first } ?: (additionalClipDurationsMs[additionalUri] ?: 0L)) * 1000 / mergedSpeed).toLong(),
                itemOutStartMs = toOutputMs(itemStartMs),
                duckWindowOutMs = voiceDuckWindowOutMs,
              ),
            clipVideoEffects,
          ))
          .build()
      }
    }
    val allSegmentItems = editedSegmentItems + additionalSegmentItems

    val sequences = mutableListOf(EditedMediaItemSequence(allSegmentItems))
    val outputTotalMs = toOutputMs(combinedLayerDurationMs())
    buildMusicSequence(outputTotalMs, toOutputMs, voiceDuckWindowOutMs)?.let { sequences.add(it) }
    buildVoiceSequence(voiceDuckWindowOutMs, outputTotalMs)?.let { sequences.add(it) }

    val composition = Composition.Builder(sequences).build()

    val outputFile = File(cacheDir, "${UUID.randomUUID()}.mp4")
    activeExportOutputFile = outputFile
    val transformer = Transformer.Builder(this)
      .addListener(object : Transformer.Listener {
        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
          // Diagnostic for the "export has no audio" report — confirms
          // whether Transformer actually muxed an audio track into the
          // output (audioMimeType null/channelCount 0 would mean it
          // didn't, without ever raising onError) rather than leaving this
          // silent next time something regresses this again.
          Log.d(
            "MediaEditor",
            "exportVideo: completed, audioMimeType=${exportResult.audioMimeType} " +
              "channelCount=${exportResult.channelCount} audioSampleRate=${exportResult.sampleRate}",
          )
          onResult(outputFile.absolutePath, exportWidth, exportHeight, exportResult.durationMs, null)
        }
        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
          onResult(null, 0, 0, 0, exportException.message ?: exportException.toString())
        }
      })
      .build()
    activeTransformer = transformer
    startExportProgressPolling(transformer)
    transformer.start(composition, outputFile.absolutePath)
  }

  /** Builds the music-only EditedMediaItemSequence for [totalKeptDurationMs]
   *  of combined-timeline duration, from selectedMusicTrack/musicTrimStartMs/
   *  EndMs/musicSegments — factored out of exportVideoOnMainThread (its
   *  logic is unchanged, just moved verbatim) so exportImageWithMusic can
   *  reuse the exact same segment/gap/trim/volume mixing math against a
   *  synthetic still-image video's own duration instead of a real video's.
   *  Returns null when no track is selected or nothing survives clamping. */
  private fun buildMusicSequence(
    totalKeptDurationMs: Long,
    toOutputMs: (Long) -> Long = { it },
    voiceDuckWindow: LongRange? = null,
  ): EditedMediaItemSequence? {
    val musicTrack = selectedMusicTrack ?: return null
    if (musicTrimEndMs <= musicTrimStartMs || musicSegments.isEmpty()) return null
    // Per the user's explicit "same split music layer also" request —
    // music can have multiple segments (visibility windows on the combined
    // timeline, exactly like a text/sticker layer's own segments), each
    // clamped to the kept duration and inserted in order into ONE
    // sequence. Media3's EditedMediaItemSequence has no "start at N ms"
    // concept — items just play back-to-back — so a gap before a segment
    // (whether the very first one, per the original musicOffsetMs fix, or
    // a deleted middle portion) needs a silent item of that exact duration
    // inserted ahead of it, the SAME technique generalized to run between
    // every pair of segments, not only before the first. The SOURCE file
    // position for each segment is computed relative to the FIRST
    // segment's own start (anchorMs) so the song's own internal pacing
    // stays continuous straight through a gap — deleting a portion mutes
    // the output during that window without skipping ahead in the song,
    // matching how playback preview (updateMusicPlaybackWindow) already
    // behaves.
    val anchorMs = toOutputMs(musicSegments.first().first)
    val musicSequenceItems = mutableListOf<EditedMediaItem>()
    var previousEndMs = 0L
    for ((musicIndex, rawSegment) in musicSegments.withIndex()) {
      // Speed control: music windows mapped onto the output timeline.
      val segment = toOutputMs(rawSegment.first)..toOutputMs(rawSegment.last)
      val clampedStartMs = segment.first.coerceIn(0, totalKeptDurationMs)
      val clampedEndMs = segment.last.coerceIn(clampedStartMs, totalKeptDurationMs)
      if (clampedEndMs <= clampedStartMs) continue
      val gapMs = clampedStartMs - previousEndMs
      if (gapMs > 0) {
        val silentGapFile = createSilentAudioFile(gapMs)
        if (silentGapFile != null) {
          musicSequenceItems.add(EditedMediaItem.Builder(MediaItem.fromUri(android.net.Uri.fromFile(silentGapFile))).build())
        } else {
          Log.w("MediaEditor", "buildMusicSequence: silent gap file failed for a ${gapMs}ms gap, music segment will start early instead")
        }
      }
      val sourceStartMs = (musicTrimStartMs + (clampedStartMs - anchorMs)).coerceIn(musicTrimStartMs, musicTrimEndMs)
      val sourceEndMs = (musicTrimStartMs + (clampedEndMs - anchorMs)).coerceIn(sourceStartMs, musicTrimEndMs)
      if (sourceEndMs > sourceStartMs) {
        val musicItem = MediaItem.Builder()
          .setUri(musicTrack.audioUrl)
          .setClippingConfiguration(
            MediaItem.ClippingConfiguration.Builder()
              .setStartPositionMs(sourceStartMs)
              .setEndPositionMs(sourceEndMs)
              .build(),
          )
          .build()
        musicSequenceItems.add(
          EditedMediaItem.Builder(musicItem)
            .setRemoveVideo(true)
            .setEffects(Effects(
              audioEffectsFor(musicVolume) + fadeAudioEffects(
                fadeIn = audioFadeIn && musicIndex == 0,
                fadeOut = audioFadeOut && musicIndex == musicSegments.lastIndex,
                totalUs = (sourceEndMs - sourceStartMs) * 1000,
                itemOutStartMs = clampedStartMs,
                duckWindowOutMs = voiceDuckWindow,
              ),
              emptyList(),
            ))
            .build(),
        )
        previousEndMs = clampedStartMs + (sourceEndMs - sourceStartMs)
      } else {
        previousEndMs = clampedStartMs
      }
    }
    return if (musicSequenceItems.isNotEmpty()) EditedMediaItemSequence(musicSequenceItems) else null
  }

  /** Story-mode-only: mixes the current PHOTO edit + selected music track
   *  into an exported VIDEO — a still image has no native audio timeline,
   *  so this synthesizes one via Media3's built-in image-to-video support
   *  (an image-mime EditedMediaItem is auto-routed through ImageAssetLoader
   *  by DefaultAssetLoaderFactory — confirmed by decompiling
   *  media3-transformer-1.4.1's DefaultAssetLoaderFactory.isImage/
   *  createAssetLoader bytecode, and EditedMediaItem.Builder.setDurationUs/
   *  setFrameRate confirmed the same way; Transformer.Builder(this) already
   *  uses this default factory with no explicit override needed, exactly
   *  as exportVideoOnMainThread's own Transformer.Builder call already
   *  does), then reuses buildMusicSequence verbatim for the audio mixing.
   *  Deliberately reuses the EXISTING renderExport(...) image compositor
   *  (bakes filter/adjust/draw/text/sticker/overlay layers into one flat
   *  Bitmap, exactly like plain exportImage already does) as the still
   *  frame, rather than reconstructing exportVideoOnMainThread's
   *  playerView-pan/crop-specific videoEffects list — those describe a
   *  live video player's transform state, which has no equivalent for a
   *  static image that renderExport has already fully baked flat. */
  private fun exportImageWithMusic(onResult: (path: String?, width: Int, height: Int, durationMs: Long, errorMessage: String?) -> Unit) {
    val imageView = imageViewRef
    val mainHandler = Handler(Looper.getMainLooper())
    Thread {
      val highRes = MediaEditorCanvasLoader.loadDownsampled(
        this, mediaUri, MAX_PHOTO_MUSIC_VIDEO_PIXEL_SIZE, MAX_PHOTO_MUSIC_VIDEO_PIXEL_SIZE,
      )
      if (imageView == null || highRes == null) {
        mainHandler.post { onResult(null, 0, 0, 0, "Could not read the original image for export.") }
        return@Thread
      }
      val rendered = renderExport(imageView, highRes)
      if (rendered == null) {
        mainHandler.post { onResult(null, 0, 0, 0, "Could not render the edited image.") }
        return@Thread
      }
      val stillFrameFile = File(cacheDir, "${UUID.randomUUID()}.jpg")
      try {
        FileOutputStream(stillFrameFile).use { out -> rendered.compress(Bitmap.CompressFormat.JPEG, 92, out) }
      } catch (e: Exception) {
        mainHandler.post { onResult(null, 0, 0, 0, "Could not write the rendered frame to disk.") }
        return@Thread
      }
      val width = rendered.width
      val height = rendered.height
      mainHandler.post { exportImageWithMusicOnMainThread(stillFrameFile, width, height, onResult) }
    }.start()
  }

  private fun exportImageWithMusicOnMainThread(
    stillFrameFile: File,
    width: Int,
    height: Int,
    onResult: (path: String?, width: Int, height: Int, durationMs: Long, errorMessage: String?) -> Unit,
  ) {
    // 60s cap matches the app's story video length limit (see
    // StoryCameraScreen's MAX_RECORDING_MS); 15s fallback if the async
    // music-duration resolution from selectMusicTrack() hasn't finished by
    // export time — there's no trim UI forcing the user to wait for it.
    val rawDurationMs = musicTrimEndMs - musicTrimStartMs
    val targetDurationMs = if (rawDurationMs > 0) rawDurationMs.coerceAtMost(60_000L) else 15_000L

    val imageMediaItem = MediaItem.Builder()
      .setUri(android.net.Uri.fromFile(stillFrameFile))
      .setMimeType(MimeTypes.IMAGE_JPEG)
      .build()
    val imageItem = EditedMediaItem.Builder(imageMediaItem)
      .setDurationUs(targetDurationMs * 1000L)
      // The frame never changes: 5fps loses nothing visible and is 6x less
      // encode work than 30fps.
      .setFrameRate(5)
      .build()
    val sequences = mutableListOf(EditedMediaItemSequence(listOf(imageItem)))
    buildMusicSequence(targetDurationMs)?.let { sequences.add(it) }

    val composition = Composition.Builder(sequences).build()
    val outputFile = File(cacheDir, "${UUID.randomUUID()}.mp4")
    val transformer = Transformer.Builder(this)
      .addListener(object : Transformer.Listener {
        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
          onResult(outputFile.absolutePath, width, height, exportResult.durationMs, null)
        }
        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
          onResult(null, 0, 0, 0, exportException.message ?: exportException.toString())
        }
      })
      .build()
    activeTransformer = transformer
    startExportProgressPolling(transformer)
    transformer.start(composition, outputFile.absolutePath)
  }

  /** Registered for both mono and stereo since the real channel count of
   *  the source (video's own audio, or a music file) isn't known ahead of
   *  time — Media3 has no simpler "just set gain" audio effect; an
   *  identity ChannelMixingMatrix scaled by volume is the documented way
   *  to apply a flat gain via Transformer's Effects pipeline. */
  private fun volumeAudioProcessor(volume: Float): ChannelMixingAudioProcessor {
    val processor = ChannelMixingAudioProcessor()
    processor.putChannelMixingMatrix(ChannelMixingMatrix.create(1, 1).scaleBy(volume))
    processor.putChannelMixingMatrix(ChannelMixingMatrix.create(2, 2).scaleBy(volume))
    return processor
  }

  /** The audio-processor list to attach to an EditedMediaItem's Effects for
   *  a given gain — EMPTY (not a no-op identity processor) when volume is
   *  the untouched default of 1f. Per the user's "video exports without
   *  ANY audio at all, even the original clip's own track" report: every
   *  kept segment (one EditedMediaItem per segment since the multi-segment
   *  split/delete rewrite) was unconditionally getting its own
   *  ChannelMixingAudioProcessor instance even when the user never touched
   *  a volume slider. Media3's default (no audio effects requested at all)
   *  audio path is simpler/more reliably passthrough-capable than routing
   *  every segment through a stateful per-item AudioProcessor purely to
   *  apply a 1.0x identity gain — attaching one unconditionally, now that
   *  a single clip is commonly split into several consecutive
   *  EditedMediaItems in one sequence (new since yesterday, previously
   *  always exactly one item), is the most likely regression source for
   *  audio silently not surviving export. Skipping it entirely in the
   *  default case removes that risk for the common case (volume never
   *  touched) while still applying the real gain whenever the user
   *  actually changes it. */
  /** Speed control: time-stretches a clip's audio (pitch kept). */
  private fun speedAudioEffects(speed: Float): List<AudioProcessor> =
    if (speed == 1f) emptyList() else listOf(
      androidx.media3.common.audio.SpeedChangingAudioProcessor(object : androidx.media3.common.audio.SpeedProvider {
        override fun getSpeed(timeUs: Long): Float = speed
        override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = androidx.media3.common.C.TIME_UNSET
      }),
    )

  /** Fade in/out audio (export): ramps for one item playing [totalUs]. */
  /** [itemOutStartMs] / [duckWindowOutMs]: where the item and the
   *  voice-over sit on the OUTPUT timeline (ducking under the voice). */
  private fun fadeAudioEffects(
    fadeIn: Boolean,
    fadeOut: Boolean,
    totalUs: Long,
    itemOutStartMs: Long = 0,
    duckWindowOutMs: LongRange? = null,
  ): List<AudioProcessor> {
    val duck = duckWindowOutMs?.let { w ->
      val start = (w.first - itemOutStartMs) * 1000
      val end = (w.last - itemOutStartMs) * 1000
      if (end < -150_000 || start > totalUs + 150_000) null else start to end
    }
    if (!fadeIn && !fadeOut && duck == null) return emptyList()
    return listOf(
      FadeAudioProcessor(
        if (fadeIn) AUDIO_FADE_MS * 1000 else 0, if (fadeOut) AUDIO_FADE_MS * 1000 else 0, totalUs,
        duckStartUs = duck?.first ?: 0, duckEndUs = duck?.second ?: 0, duckLevel = VOICE_DUCK_LEVEL,
      ),
    )
  }

  private fun audioEffectsFor(volume: Float): List<AudioProcessor> =
    if (volume == 1f) emptyList() else listOf(volumeAudioProcessor(volume))

  /** Writes a silent mono 16-bit PCM WAV file of exactly [durationMs] to
   *  cacheDir. Used to delay the start of the music track in the export's
   *  music sequence (see its call site) — unlike iOS's composition-based
   *  insertTimeRange(at:), Media3's EditedMediaItemSequence has no notion
   *  of "start this item N ms in"; items simply play back-to-back, so the
   *  standard Transformer technique is prepending a silent item of the
   *  needed duration ahead of the real one in the same sequence. Returns
   *  null (caller falls back to no-offset) if the write fails. */
  private fun createSilentAudioFile(durationMs: Long): File? = runCatching {
    val sampleRate = 44100
    val numSamples = (sampleRate * durationMs / 1000L).toInt()
    val dataSize = numSamples * 2 // 16-bit mono, all-zero samples = silence
    val file = File(cacheDir, "silence_${UUID.randomUUID()}.wav")
    tempFilesToDelete += file
    FileOutputStream(file).use { out ->
      out.write(wavHeader(dataSize = dataSize, sampleRate = sampleRate, channels = 1, bitsPerSample = 16))
      out.write(ByteArray(dataSize))
    }
    file
  }.onFailure {
    Log.w("MediaEditor", "createSilentAudioFile: failed to write silence wav: ${it.message}")
  }.getOrNull()

  private fun wavHeader(dataSize: Int, sampleRate: Int, channels: Int, bitsPerSample: Int): ByteArray {
    val byteRate = sampleRate * channels * bitsPerSample / 8
    val blockAlign = channels * bitsPerSample / 8
    val buffer = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
    buffer.put("RIFF".toByteArray())
    buffer.putInt(36 + dataSize)
    buffer.put("WAVE".toByteArray())
    buffer.put("fmt ".toByteArray())
    buffer.putInt(16) // PCM fmt chunk size
    buffer.putShort(1) // PCM format
    buffer.putShort(channels.toShort())
    buffer.putInt(sampleRate)
    buffer.putInt(byteRate)
    buffer.putShort(blockAlign.toShort())
    buffer.putShort(bitsPerSample.toShort())
    buffer.put("data".toByteArray())
    buffer.putInt(dataSize)
    return buffer.array()
  }

  // MARK: - Export
  //
  // Export re-composites the exact same scene shown in the live preview —
  // image (filtered/adjusted) + its pan/zoom/rotate + every visible text/
  // sticker layer — at a higher resolution than the screen, then crops to
  // the crop frame. Everything scales up by one consistent factor derived
  // from how much higher-res the original file is than the on-screen
  // canvas, so the result is geometrically identical to what's on screen,
  // just at real quality — rather than trying to reverse-map crop
  // coordinates against the original file's pixel grid by hand.

  private fun exportImage(onResult: (path: String?, width: Int, height: Int) -> Unit) {
    val imageView = imageViewRef
    val mainHandler = Handler(Looper.getMainLooper())
    Thread {
      val highRes = MediaEditorCanvasLoader.loadDownsampled(this, mediaUri, MAX_EXPORT_PIXEL_SIZE, MAX_EXPORT_PIXEL_SIZE)
      if (imageView == null || highRes == null) {
        mainHandler.post { onResult(null, 0, 0) }
        return@Thread
      }
      val rendered = renderExport(imageView, highRes)
      if (rendered == null) {
        mainHandler.post { onResult(null, 0, 0) }
        return@Thread
      }
      val outputFile = File(cacheDir, "${UUID.randomUUID()}.jpg")
      try {
        val quality = if (isStoryMode) STORY_JPEG_QUALITY else 92
        FileOutputStream(outputFile).use { out -> rendered.compress(Bitmap.CompressFormat.JPEG, quality, out) }
        mainHandler.post { onResult(outputFile.absolutePath, rendered.width, rendered.height) }
      } catch (e: Exception) {
        mainHandler.post { onResult(null, 0, 0) }
      }
    }.start()
  }

  private fun renderExport(imageView: ImageView, highRes: Bitmap): Bitmap? {
    val canvasWidth = imageView.width
    val canvasHeight = imageView.height
    if (canvasWidth <= 0 || canvasHeight <= 0) return null

    val lutApplied = if (selectedFilter.category == FilterCategory.ARTISTIC) {
      ArtisticEffects.blend(highRes, ArtisticEffects.render(selectedFilter, highRes), filterStrength, filterSaturation)
    } else {
      FilterLut.apply(highRes, FilterLut.baked(FilterLut.keyFor(selectedFilter, filterStrength, filterSaturation)))
    }
    val filterSharpened = if (filterSharpness > 0) sharpenBitmap(lutApplied, filterSharpness) else lutApplied
    var filtered = applyColorMatrixToBitmap(filterSharpened, combinedColorMatrix())
    // Sharpen isn't expressible as a ColorMatrix — applied as a separate
    // convolution step, same algorithm (sharpenBitmap) as the live preview,
    // just running once here at full export resolution instead of on
    // every slider tick at preview resolution.
    if (sharpen > 0) {
      filtered = sharpenBitmap(filtered, sharpen)
    }
    // Blur after color + sharpen, same order as the live preview — unless
    // layers are on the picture: then the whole composite is blurred below.
    val blurComposite = mediaType == "image" && blur.isActive && blurCoverLayerViews().isNotEmpty()
    if (blur.isActive && !blurComposite) {
      filtered = PhotoBlurRenderer.apply(filtered, blur)
    }

    // How wide the image renders within the canvas under aspect-fit — from
    // that, the scale factor that maps one on-screen canvas pixel to one
    // pixel of the (higher-res) source image.
    val imageAspect = filtered.width.toFloat() / filtered.height.toFloat()
    val canvasAspect = canvasWidth.toFloat() / canvasHeight.toFloat()
    val renderedImageWidthInCanvasPx = if (imageAspect > canvasAspect) {
      canvasWidth.toFloat()
    } else {
      canvasHeight * imageAspect
    }
    if (renderedImageWidthInCanvasPx <= 0) return null
    // At `nativeExportScale` the source is drawn at its own pixel size.
    val nativeExportScale = filtered.width / renderedImageWidthInCanvasPx
    var exportScale = nativeExportScale
    if (isStoryMode) {
      exportScale = minOf(exportScale, STORY_EXPORT_PIXEL_WIDTH / canvasWidth)
    }
    // When the story cap shrinks the output, the source must shrink by the
    // same factor — drawing it at full pixel size into the smaller canvas
    // exported a zoomed-in center crop (matches the iOS fix).
    val imageDrawScale = exportScale / nativeExportScale

    // Crop feature removed — always export the full canvas (equivalent to
    // a crop rect that exactly matches the canvas bounds). Kept as an
    // explicit rect (rather than deleting the crop-offset math below)
    // since the offset it drives is otherwise 0 anyway, and this keeps
    // the pan/zoom/rotate compositing math (imageView.translationX/Y/
    // scaleX/Y/rotation, further down) completely unchanged.
    val cropRect = RectF(0f, 0f, canvasWidth.toFloat(), canvasHeight.toFloat())
    val cropRectExport = RectF(
      cropRect.left * exportScale,
      cropRect.top * exportScale,
      cropRect.right * exportScale,
      cropRect.bottom * exportScale,
    )
    val exportWidth = cropRectExport.width().toInt()
    val exportHeight = cropRectExport.height().toInt()
    if (exportWidth <= 0 || exportHeight <= 0) return null

    val output = Bitmap.createBitmap(exportWidth, exportHeight, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(output)
    canvas.translate(-cropRectExport.left, -cropRectExport.top)

    // Canvas-space center, constant regardless of the image's own
    // pan/zoom/rotate — the BASE IMAGE is drawn directly onto a canvas
    // sized to imageView's own dimensions, so its own local center
    // (canvasWidth/2, canvasHeight/2) is the correct reference.
    val canvasCenterX = canvasWidth / 2f
    val canvasCenterY = canvasHeight / 2f

    canvas.save()
    canvas.translate(canvasCenterX * exportScale, canvasCenterY * exportScale)
    canvas.translate(imageView.translationX * exportScale, imageView.translationY * exportScale)
    canvas.rotate(imageView.rotation)
    canvas.scale(imageView.scaleX * imageDrawScale, imageView.scaleY * imageDrawScale)
    canvas.drawBitmap(filtered, -filtered.width / 2f, -filtered.height / 2f, Paint(Paint.FILTER_BITMAP_FLAG))
    canvas.restore()

    // Draw/brush strokes — drawingCanvasRef is positioned to exactly match
    // imageView's own box (see layoutImageCanvas), so a recorded point is
    // ALREADY in this canvas's own local coordinate space and needs only a
    // straight `* exportScale`, unlike text/sticker/overlay layers below
    // (which are children of `root`, not imageView, and need the
    // layerBaseX/Y correction). Drawn right after the base image, matching
    // the on-screen stacking (added right after the grid, before any
    // runtime-added text/sticker/overlay layer).

    // Text/sticker layers are children of `root` (the whole-screen
    // container), added with Gravity.CENTER — NOT children of imageView —
    // so their on-screen base position is root's OWN center, not
    // imageView's. root's center rarely coincides with imageView's own
    // center once the top bar and bottom chrome (a different height each)
    // are reserved above/below the canvas box. Convert root's center into
    // imageView's LOCAL coordinate space (which this export bitmap's
    // coordinate space matches) by subtracting imageView's own on-screen
    // offset within root — same class of bug as iOS's `.center`-vs-
    // `.bounds` mixup, just arising from a different parent/child
    // relationship on this platform.
    val layerBaseX = root.width / 2f - imageView.left
    val layerBaseY = root.height / 2f - imageView.top

    // Drawn in add order, matching the on-screen stacking (each was added
    // as a later, higher-z-order sibling than the one before it). Overlay
    // images are always drawn last here — same approximation already
    // accepted for text-vs-sticker ordering (both lists are always
    // concatenated in this fixed order regardless of true add-order),
    // extended to the 3rd layer type rather than tracking one single
    // ordered list.
    // Drawing, text, stickers and overlays in their on-screen stacking
    // order (root child order), so whatever was added last is on top —
    // same as the preview. Strokes get their own layer (drawStrokes) so
    // the eraser can't erase the photo.
    val locationStickers = JSONArray()
    val textAndStickers = (textLayerViews + stickerLayerViews).toSet()
    for (i in 0 until root.childCount) {
      val child = root.getChildAt(i)
      if (child.visibility != View.VISIBLE) continue
      when {
        child === drawingCanvasRef -> drawingCanvasRef?.allStrokes()?.takeIf { it.isNotEmpty() }?.let { strokes ->
          DrawingCanvasView.drawStrokes(canvas, strokes, exportScale)
        }
        child is TextView && child in textAndStickers -> {
          drawLayerForExport(canvas, child, layerBaseX, layerBaseY, exportScale)
          // Same center drawLayerForExport draws at, minus the output
          // bitmap's crop offset (the canvas.translate above).
          locationLayerStates[child]?.takeIf { it.kind in TAPPABLE_INFO_KINDS }?.let { state ->
            val center = layerCenterInExport(child, layerBaseX, layerBaseY, exportScale)
            locationStickers.put(
              locationStickerJson(child, state, center.x - cropRectExport.left, center.y - cropRectExport.top, exportScale, exportWidth, exportHeight),
            )
          }
        }
        child is ImageView && child in imageOverlayLayerViews -> drawImageOverlayForExport(canvas, child, layerBaseX, layerBaseY, exportScale)
      }
    }
    exportedLocationStickers = locationStickers

    // With layers on the picture the blur goes over them too (same as the
    // preview): blur the composite so far instead of only the photo.
    if (blurComposite) {
      val blurred = PhotoBlurRenderer.apply(output, blur)
      canvas.save()
      canvas.translate(cropRectExport.left, cropRectExport.top)
      canvas.drawBitmap(blurred, 0f, 0f, null)
      canvas.restore()
      if (blurred !== output) blurred.recycle()
    }

    // Vignette — drawn last, over everything, matching the on-screen
    // overlay (updateVignetteOverlay). Undoes the outer crop-offset
    // translate first so this rect is expressed in the OUTPUT bitmap's
    // own absolute pixel bounds, not the (currently always-zero, since
    // crop was removed) crop-relative space everything above is drawn in.
    if (vignette > 0f) {
      canvas.save()
      canvas.translate(cropRectExport.left, cropRectExport.top)
      val radius = kotlin.math.hypot(exportWidth / 2f, exportHeight / 2f)
      val edgeAlpha = (vignette * 200).toInt().coerceIn(0, 255)
      val vignettePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        shader = RadialGradient(
          exportWidth / 2f,
          exportHeight / 2f,
          radius,
          intArrayOf(Color.TRANSPARENT, Color.TRANSPARENT, Color.argb(edgeAlpha, 0, 0, 0)),
          floatArrayOf(0f, 0.5f, 1f),
          Shader.TileMode.CLAMP,
        )
      }
      canvas.drawRect(0f, 0f, exportWidth.toFloat(), exportHeight.toFloat(), vignettePaint)
      canvas.restore()
    }

    return output
  }

  private fun applyColorMatrixToBitmap(source: Bitmap, matrix: ColorMatrix): Bitmap {
    val result = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(result)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { colorFilter = ColorMatrixColorFilter(matrix) }
    canvas.drawBitmap(source, 0f, 0f, paint)
    return result
  }

  /** Renders each filter's live thumbnail from the just-decoded photo —
   *  called once, right after the downsampled bitmap decode completes.
   *  Reuses FilterLut (the same per-filter lookup table the main preview
   *  already uses) applied to a small square crop instead of the full
   *  image — no duplicated filter math. */
  private fun renderFilterThumbnails(source: Bitmap) {
    val density = resources.displayMetrics.density
    val thumbnailSizePx = EditorDesignTokens.dpToPx(EditorDesignTokens.SpacingDp.thumbnailSize, density)

    // Center-crop to a square before filtering/scaling, so the thumbnail
    // isn't a squashed aspect-fit of the whole photo.
    val squareSide = minOf(source.width, source.height)
    val cropLeft = (source.width - squareSide) / 2
    val cropTop = (source.height - squareSide) / 2
    val square = Bitmap.createBitmap(source, cropLeft, cropTop, squareSide, squareSide)
    val thumbnailBase = Bitmap.createScaledBitmap(square, thumbnailSizePx, thumbnailSizePx, true)

    PhotoFilter.values().forEach { filter ->
      // Only the filters this session shows (no Artistic for video).
      if (!filterButtonRefs.containsKey(filter)) return@forEach
      val filtered = if (filter.category == FilterCategory.ARTISTIC) {
        ArtisticEffects.render(filter, thumbnailBase)
      } else {
        FilterLut.apply(thumbnailBase, FilterLut.baked(FilterLut.keyFor(filter, 1f, 0f)))
      }
      filterButtonRefs[filter]?.setImageBitmap(circularCrop(filtered))
    }
    updateFilterButtonHighlight()
  }

  /** Bakes circularity into the bitmap's own pixel data (transparent
   *  corners) rather than relying on View-level clipping. */
  private fun circularCrop(source: Bitmap): Bitmap {
    val size = minOf(source.width, source.height)
    val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(output)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    val radius = size / 2f
    canvas.drawCircle(radius, radius, radius, paint)
    paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
    canvas.drawBitmap(source, 0f, 0f, paint)
    return output
  }

  /** Re-derives text size from `layer.textSize * exportScale` (rather than
   *  rasterizing the small on-screen TextView and stretching it) so text
   *  stays crisp in the export. */
  private fun drawLayerForExport(
    canvas: Canvas,
    layer: TextView,
    canvasCenterX: Float,
    canvasCenterY: Float,
    exportScale: Float,
  ) {
    val center = layerCenterInExport(layer, canvasCenterX, canvasCenterY, exportScale)
    val centerX = center.x
    val centerY = center.y

    // Sticker layers (bundled image, not rendered text) draw their own
    // bitmap directly — same approach as drawImageOverlayForExport — so a
    // sticker's real artwork lands in the export instead of nothing (this
    // layer's `.text` is null once it holds a sticker image, see
    // applyStickerImage).
    // Location layers re-render their pill at export resolution (crisp),
    // same draw transform as the bundled-sticker branch below.
    locationLayerStates[layer]?.let { state ->
      val pill = renderLocationPillBitmap(state, resources.displayMetrics.density * exportScale)
      val halfW = pill.width / 2f
      val halfH = pill.height / 2f
      canvas.save()
      canvas.translate(centerX, centerY)
      canvas.rotate(layer.rotation)
      canvas.scale(layer.scaleX, layer.scaleY)
      canvas.drawBitmap(pill, null, RectF(-halfW, -halfH, halfW, halfH), null)
      canvas.restore()
      return
    }

    val stickerAssetName = stickerLayerAssetNames[layer]
    if (stickerAssetName != null) {
      val (source, side) = stickerExportBitmap(layer, stickerAssetName, exportScale) ?: (null to 0f)
      if (source != null) {
        val destSize = side
        val destRect = RectF(-destSize / 2f, -destSize / 2f, destSize / 2f, destSize / 2f)
        canvas.save()
        canvas.translate(centerX, centerY)
        canvas.rotate(layer.rotation)
        canvas.scale(layer.scaleX, layer.scaleY)
        canvas.drawBitmap(source, null, destRect, null)
        canvas.restore()
      }
      return
    }

    // Re-rendered at export resolution by the same renderer the on-screen
    // layer uses, so the export matches the preview exactly and stays crisp.
    val styled = layer as? StyledTextLayerView ?: return
    val density = resources.displayMetrics.density
    val rendered = TextLayerRenderer.render(this, styled.text?.toString().orEmpty(), styled.layerStyle, density * exportScale) ?: return
    canvas.save()
    canvas.translate(centerX, centerY)
    canvas.rotate(layer.rotation)
    canvas.scale(layer.scaleX, layer.scaleY)
    val left = -rendered.width / 2f
    val top = -rendered.height / 2f
    canvas.drawBitmap(
      rendered.bitmap, null,
      RectF(left, top, left + rendered.bitmap.width, top + rendered.bitmap.height),
      Paint(Paint.FILTER_BITMAP_FLAG),
    )
    canvas.restore()
    rendered.bitmap.recycle()
  }

  /** Image-overlay counterpart to drawLayerForExport — draws the overlay's
   *  own bitmap (already loaded at whatever resolution the system picker
   *  returned it) instead of rendering text, scaled from its on-screen
   *  layout size by the same exportScale factor everything else uses. */
  private fun drawImageOverlayForExport(
    canvas: Canvas,
    layer: ImageView,
    canvasCenterX: Float,
    canvasCenterY: Float,
    exportScale: Float,
  ) {
    val destWidth = layer.width * exportScale
    val destHeight = layer.height * exportScale
    // Re-rendered at export size from the unstyled photo (sharper than the
    // on-screen preview), then drawn with its blend mode.
    val state = overlayStates[layer]
    val bitmap = state?.let {
      OverlayRenderer.render(it.base, it.style, it.strokes, destWidth.roundToInt().coerceAtLeast(1), destHeight.roundToInt().coerceAtLeast(1))
    } ?: (layer.drawable as? BitmapDrawable)?.bitmap ?: return
    val centerX = (canvasCenterX + layer.translationX) * exportScale
    val centerY = (canvasCenterY + layer.translationY) * exportScale

    canvas.save()
    canvas.translate(centerX, centerY)
    canvas.rotate(layer.rotation)
    canvas.scale(layer.scaleX, layer.scaleY)
    val destRect = RectF(-destWidth / 2f, -destHeight / 2f, destWidth / 2f, destHeight / 2f)
    val paint = Paint(Paint.FILTER_BITMAP_FLAG).also { state?.style?.blend?.applyTo(it) }
    canvas.drawBitmap(bitmap, null, destRect, paint)
    canvas.restore()
  }

  /** Pre-renders one layer to its own tightly-cropped, transparent-
   *  background Bitmap for Media3's BitmapOverlay (Day 26b) — the video
   *  counterpart to drawLayerForExport, which draws straight into the
   *  image export's Canvas instead since that path has no per-frame GL
   *  effect pipeline to hand a Bitmap to. */
  private fun renderOverlayBitmap(layer: TextView, exportScale: Float): Bitmap? {
    // Sticker layers (bundled image, not rendered text) scale their own
    // bitmap directly — same approach as renderOverlayImageBitmap —
    // instead of the text path below, which would otherwise silently
    // drop every sticker (empty `.text`) from the exported video.
    locationLayerStates[layer]?.let { state ->
      return renderLocationPillBitmap(state, resources.displayMetrics.density * exportScale)
    }
    stickerLayerAssetNames[layer]?.let { assetName ->
      val (source, side) = stickerExportBitmap(layer, assetName, exportScale) ?: return null
      val destSize = side.toInt().coerceAtLeast(1)
      return Bitmap.createScaledBitmap(source, destSize, destSize, true)
    }
    val styled = layer as? StyledTextLayerView ?: return null
    val text = styled.text?.toString().orEmpty()
    if (text.isEmpty()) return null
    return TextLayerRenderer.render(this, text, styled.layerStyle, resources.displayMetrics.density * exportScale)?.bitmap
  }

  /** Image-overlay counterpart to renderOverlayBitmap — the video-export
   *  analog of drawImageOverlayForExport, which draws straight into the
   *  image export's Canvas instead since that path has no per-frame GL
   *  effect pipeline to hand a Bitmap to. Scaled to the layer's own
   *  on-screen display size (not the source bitmap's native resolution),
   *  matching drawImageOverlayForExport's destRect sizing exactly. */
  private fun renderOverlayImageBitmap(layer: ImageView, exportScale: Float): Bitmap? {
    val source = (layer.drawable as? BitmapDrawable)?.bitmap ?: return null
    val destWidth = (layer.width * exportScale).toInt().coerceAtLeast(1)
    val destHeight = (layer.height * exportScale).toInt().coerceAtLeast(1)
    return Bitmap.createScaledBitmap(source, destWidth, destHeight, true)
  }

  /** Draw/brush-stroke counterpart to renderOverlayBitmap — rasterizes
   *  every stroke onto a single full-frame-sized Bitmap (rather than one
   *  Bitmap per stroke) since strokes have no per-layer anchor/rotation/
   *  scale of their own, just absolute points already in the canvas's own
   *  local space (see the export-loop comment above for why no
   *  layerBaseX/Y correction is needed here, unlike text/sticker/overlay).
   *  Null when there are no strokes, so the caller can skip adding an
   *  empty overlay. */
  private fun renderStrokesOverlayBitmap(
    drawView: DrawingCanvasView,
    exportWidth: Int,
    exportHeight: Int,
    exportScale: Float,
  ): Bitmap? {
    val strokes = drawView.allStrokes()
    if (strokes.isEmpty()) return null
    val bitmap = Bitmap.createBitmap(exportWidth, exportHeight, Bitmap.Config.ARGB_8888)
    DrawingCanvasView.drawStrokes(Canvas(bitmap), strokes, exportScale)
    return bitmap
  }
}
