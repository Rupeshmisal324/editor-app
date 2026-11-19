package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs

/**
 * One row's draggable bar in the Layers panel — ALL layers of one type
 * (text, sticker, or overlay) share a SINGLE bar/row now, each drawn as
 * its own colored range within [0, durationMs] and independently
 * draggable, per the user's explicit "for multiple emojis multiple
 * layer will not be created, all images will be in single layer one by
 * one... same for text" correction (previously each layer got its own
 * row). Dragging an item's BODY moves its whole range (both edges shift
 * by the same delta, clamped to stay within [0, durationMs]); dragging
 * an EDGE resizes that side only (extend/reduce) — the two interactions
 * the user explicitly asked for ("drag to extend and reduce... just
 * like Instagram"). Coordinate-mapping/touch-radius approach mirrors
 * [VideoTrimView]'s proven plain-style geometry.
 */
internal class LayerRangeBarView(context: Context) : View(context) {

  data class Item(
    val id: View,
    var rangeStartMs: Long,
    var rangeEndMs: Long,
    val color: Int,
    val label: String,
    // Merged-video-clip rows (see MediaEditorActivity's
    // makeAdditionalClipsRow) draw the clip's own real frames instead of a
    // flat color fill — per the user's explicit "display full video on
    // layers" request. Text/Sticker/Overlay rows never set this, so their
    // existing flat-color-plus-label look is completely unchanged.
    // Evenly time-sampled across THIS item's own real segment range (see
    // MediaEditorActivity's tilesForMergedClipSegment) and tiled
    // left-to-right across this item's own bar width, exactly like
    // VideoTrimView's primary-clip filmstrip — replaces a single frame
    // that used to get aspect-cropped across the WHOLE item regardless of
    // how wide it was or which real moment(s) it actually spanned, per
    // the user's explicit "thumbnail should not look zoomed... show
    // thumbnail up to exact same real timing of video clip" report.
    val thumbnailTiles: List<Bitmap> = emptyList(),
    // Whether THIS item is the one currently under the playhead in
    // MediaEditorActivity's combined multi-clip timeline — per the
    // user's explicit Instagram-reference request, only the ACTIVE merged
    // clip shows the yellow border/handles/duration-label; others show a
    // plain thumbnail only. Text/Sticker/Overlay items never set this
    // (always false, no visible effect there).
    val isActive: Boolean = false,
    // Pre-formatted duration text ("12.3s") shown on this item only while
    // isActive — null for Text/Sticker/Overlay items.
    val durationLabel: String? = null,
    // Which of `id`'s own segments this is, when a layer has been split
    // into more than one (see MediaEditorActivity's splitLayerSegment/
    // deleteLayerSegment) — 0 for every never-split layer, and for
    // merged-clip/music items, which have exactly one segment each and
    // never split. Distinguishes "segment 2 of layer X" from "segment 1
    // of layer X" for selection/dragging purposes, since both share the
    // SAME `id` (the underlying view never changes — splitting divides
    // its TIME, not the view itself).
    val segmentIndex: Int = 0,
    // Edits-style layers: a small type badge at the bar's left edge — the
    // sticker/photo itself (`badgeFillsTile` = cropped to fill, for
    // photos) or a short glyph (`badgeText`, e.g. "T" / "♪").
    val badge: Bitmap? = null,
    val badgeFillsTile: Boolean = false,
    val badgeText: String? = null,
    // Per-layer hide: the bar is drawn faded.
    val isDimmed: Boolean = false,
    // Small white icons (hidden / locked) drawn at the bar's right end.
    val statusIcons: List<android.graphics.drawable.Drawable> = emptyList(),
    // Beat sync: beat times (same axis as rangeStartMs) drawn as dots.
    val markers: List<Long> = emptyList(),
  )

  var durationMs: Long = 1
    private set
  var items: List<Item> = emptyList()
    private set

  /** (id, segmentIndex, newStartMs, newEndMs) — segmentIndex identifies
   *  WHICH of `id`'s own segments changed, see Item.segmentIndex's own
   *  doc. */
  var onRangeChanged: ((id: View, segmentIndex: Int, startMs: Long, endMs: Long) -> Unit)? = null
  /** Fires when the user taps/drags an item — lets the owning Activity
   *  select that layer on the canvas (showing its Delete/Duplicate/Edit
   *  toolbar) AND record which of its own segments (if split) is now the
   *  target for Split/Delete, so this bar's own drag-to-trim handles and
   *  the canvas's own delete affordance stay in sync about which layer/
   *  segment is "active". */
  var onItemSelected: ((id: View, segmentIndex: Int) -> Unit)? = null
  /** Fires once when an active drag ends (ACTION_UP/CANCEL) — additive,
   *  only needed by callers that want to defer expensive work (e.g.
   *  rebuilding a playback queue) until the drag settles rather than
   *  doing it on every onRangeChanged tick. Existing Text/Sticker/Overlay
   *  rows don't set this and are unaffected. */
  var onDragEnded: (() -> Unit)? = null
  /** Fires `true` when a HANDLE (start/end) drag begins and `false` when
   *  it ends — mirrors VideoTrimView's identical callback, letting an
   *  ancestor scrollable container (MediaEditorActivity's
   *  filmstripScrollViewRef) disable its own touch interception for
   *  exactly the duration of a handle drag, once this bar is embedded in
   *  the Instagram-style scrollable timeline. Existing Text/Sticker/
   *  Overlay rows don't set this and are unaffected. */
  var onHandleDragStateChanged: ((Boolean) -> Unit)? = null
  /** Fires with the per-tick horizontal touch delta (current.x -
   *  previous.x) whenever the user drags anywhere on a Text/Sticker/
   *  Overlay row that ISN'T one of an item's own edge handles. Unlike
   *  mergedStripView (which sits inside a REAL HorizontalScrollView and
   *  can just `return false` to fall through to it), this row has no real
   *  ancestor scroll container — layerTracksStackRef only mirrors scroll
   *  programmatically — so it must actively forward the gesture instead
   *  of relying on Android's normal touch-dispatch fallthrough. Added
   *  after the user confirmed swiping directly on a colored bar (trying
   *  to scroll the shared timeline, since it visually looks like one
   *  continuous scrollable strip) was silently dragging that layer's own
   *  BODY instead — its whole time range would shift by the swipe's
   *  delta, exactly matching a reported "layer stuck at a weird partial
   *  range" bug. Body-drag-to-reschedule is removed entirely now (see
   *  onTouchEvent) in favor of this forwarding, matching how mergedStripView
   *  already disables its own body-drag for the identical reason. Never
   *  fires for isMergedClipsContinuation rows. */
  var onUnhandledDragDeltaX: ((Float) -> Unit)? = null
  /** True ONLY for the dedicated music row — per the user's explicit
   *  "add one dedicated layer of music... user can scroll and drag to
   *  change position" request, dragging an item's BODY shifts its whole
   *  range (both edges by the same delta) instead of being forwarded to
   *  the shared timeline scroll. Text/Sticker/Overlay rows stay false
   *  (unaffected) — body-drag was deliberately removed from THEM earlier
   *  this session after it kept misfiring against a timeline-scroll
   *  swipe; re-enabling it only for music (which has exactly one item, so
   *  there's no overlap ambiguity) avoids reintroducing that bug there. */
  var allowBodyDrag: Boolean = false
  /** Layer rows: the body moves the layer in time only once that item is
   *  SELECTED — so a swipe on an unselected layer still scrolls the
   *  timeline, and holding still on any layer still reorders it. */
  var bodyDragRequiresSelection: Boolean = false
  /** False ONLY for the music row — its duration is controlled entirely
   *  by the Music panel's own trim view (which portion of the song
   *  plays); this row exists purely to reposition WHEN it plays, so its
   *  edges aren't independently draggable (would be a second, redundant,
   *  semantically-conflicting way to change duration). */
  var edgeDragEnabled: Boolean = true
  /** Times a dragged edge snaps to (other tracks' starts / ends, the
   *  playhead, clip cuts), excluding the dragged item's own (id, segment).
   *  Within ~8dp the edge locks onto the time with a haptic tick, like
   *  CapCut / Edits. null = no snapping. */
  var snapTargets: ((View, Int) -> List<Long>)? = null
  private var snapCache: List<Long>? = null
  private var snappedTimeMs: Long? = null

  /** The closest snap time within ~8dp of [t], if any. */
  private fun nearestSnap(t: Long): Long? {
    val cache = snapCache ?: return null
    val usableWidth = width - edgeInsetPx * 2
    if (usableWidth <= 0f || durationMs <= 0) return null
    val threshold = (8f * resources.displayMetrics.density / usableWidth * durationMs).toLong()
    return cache.filter { kotlin.math.abs(it - t) <= threshold }.minByOrNull { kotlin.math.abs(it - t) }
  }
  /** Fires (repeatedly, live) while a long-press-then-drag reorder is in
   *  progress, once per step-swap — (id of the item that moved, id of the
   *  item it swapped past). Per the user's explicit "reorder layers...
   *  select and reorder by long press" request. The owner should apply
   *  this to its OWN backing order + canvas z-order immediately (cheap),
   *  but defer a full `refreshLayersPanel()`-style rebuild to
   *  [onReorderEnded] — rebuilding this row mid-gesture would detach the
   *  very View instance still receiving this touch stream. */
  var onReorderSwap: ((movedId: View, swappedPastId: View) -> Unit)? = null
  /** Fires once when a reorder gesture ends (ACTION_UP/CANCEL) — the safe
   *  point for the owner to do a full rebuild. */
  var onReorderEnded: (() -> Unit)? = null
  /** Edits-style layers (one item per row): while reordering, a vertical
   *  drag past [crossRowStepPx] asks the owner to move THIS row one slot
   *  up (-1) or down (+1) among its sibling rows. Returns how far the row
   *  moved in px (positive = down), or null if it couldn't move. Tracked
   *  in screen coordinates (rawY) because the row's own layout only
   *  updates on the next frame. */
  var onCrossRowReorderStep: ((direction: Int) -> Float?)? = null
  private val crossRowStepPx = dp(22f)
  /** A quick tap (no drag, no long-press) on an item. When set, a tap on
   *  the bar's body also SELECTS that item (body taps otherwise do nothing). */
  var onItemTapped: ((id: View, segmentIndex: Int) -> Unit)? = null
  private var tapCandidateIndex: Int? = null
  private var touchMovedBeyondSlop = false
  private val badgeTilePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(56, 255, 255, 255) }
  private val badgeBitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
  private val badgeTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    textAlign = Paint.Align.CENTER
    typeface = android.graphics.Typeface.DEFAULT_BOLD
  }
  private var downRawY = 0f
  private var reorderStartRawY = 0f
  /** When false, a long-press just SELECTS the tapped item instead of
   *  entering reorder mode — for rows where reordering makes no sense
   *  (the music row: every segment shares the SAME id, so there's
   *  nothing to reorder against). Defaults to true so Text/Sticker/
   *  Overlay/merged-clip rows are completely unaffected. */
  var reorderEnabled: Boolean = true
  /** True ONLY for MediaEditorActivity's mergedStripViewRef — that
   *  instance is positioned with zero gap directly against VideoTrimView's
   *  own (squareTrailingCorners) right edge, forming one continuous
   *  filmstrip, so it needs a matching black background (not the generic
   *  elevatedSurface used by Text/Sticker/Overlay rows) and a squared-off
   *  leading corner on its FIRST item only (so that one item doesn't show
   *  a rounded pill right at the seam). Text/Sticker/Overlay rows never
   *  set this and are completely unaffected. */
  var isMergedClipsContinuation: Boolean = false
    set(value) {
      field = value
      invalidate()
    }
  private var selectedItemId: View? = null
  private var selectedSegmentIndex: Int? = null

  private val edgeWidthPx = dp(8f)
  private val edgeTouchSlopPx = dp(14f)
  private val minRangeDurationMs = 500L

  // Matches VideoTrimView's OWN filmstrip-style leading/trailing inset
  // (filmstripHandleWidthPx/2 + filmstripHandleTouchSlopPx = dp(3f) +
  // dp(6f)) exactly for Text/Sticker/Overlay rows — VideoTrimView insets
  // its OWN thumbnail drawing by this same amount (room for its trim-
  // handle touch targets), so without a matching inset here an item's
  // position would be a few pixels off from the video row's own
  // displayed filmstrip content, not just its raw bounding box.
  // mergedStripView (isMergedClipsContinuation) must stay UN-inset — it
  // sits with ZERO gap directly against videoTrimView's own right edge
  // (see squareLeading below), so insetting it here would reintroduce
  // that seam.
  // Time 0 / the end map exactly to this view's own edges (no inset), so
  // the timeline lines up with the white playhead line — the scroll math
  // puts time 0 at content x = 0. The old 9dp inset left every bar
  // starting to the right of the playhead.
  private val edgeInsetPx = 0f

  private val backgroundPaint = Paint().apply { color = EditorDesignTokens.Colors.elevatedSurface }
  // Matches VideoTrimView's own filmstrip background exactly, so the
  // merged-clips row reads as a direct continuation of it rather than a
  // visibly different-colored strip.
  private val filmstripContinuationBackgroundPaint = Paint().apply { color = Color.BLACK }
  private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.MAGENTA }
  private val beatDotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(217, 255, 255, 255) }
  private val selectedStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    style = Paint.Style.STROKE
    // Thin selection outline (was 2dp).
    strokeWidth = dp(1.25f)
  }
  // Always-visible border + edge-grip handles for merged-clip items,
  // matching VideoTrimView's OWN kept-segment border/handle look exactly
  // (EditorDesignTokens.Colors.trimHandle) — per the user's explicit "add
  // yellow color border same as original video and scrubber to adjust"
  // request. Text/Sticker/Overlay items never draw these
  // (isMergedClipsContinuation is false there).
  private val mergedClipBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = EditorDesignTokens.Colors.trimHandle
    style = Paint.Style.STROKE
    strokeWidth = dp(1.5f)
  }
  private val mergedClipHandlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = EditorDesignTokens.Colors.trimHandle }
  private val mergedClipHandleWidthPx = dp(6f)
  private val mergedClipDurationLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    textSize = dp(12f)
    isFakeBoldText = true
  }
  // Always-visible grip at each edge of every edge-draggable item (Text/
  // Sticker/Overlay — NOT a merged-clip row or the Music row, see the
  // draw-site guard) so it visibly reads as draggable the same way the
  // video row's own trim handles do, even before it's selected. Neutral
  // gray, never white — only the SELECTED item's own full white border
  // (selectedStrokePaint) draws a border around the whole bar, so
  // selected vs. unselected can never be confused at a glance.
  private val dimHandlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(217, 173, 173, 173) }
  private val selectedHandlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
  private val dimHandleWidthPx = dp(5f)
  private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    textSize = dp(12f)
    textAlign = Paint.Align.CENTER
  }
  private val cornerRadiusPx = dp(6f)

  // MOVE only ever gets assigned when allowBodyDrag is true (music row) —
  // see onTouchEvent's own target-selection `when`.
  private enum class DragTarget { START, END, MOVE }
  private var activeItemIndex: Int? = null
  private var activeDrag: DragTarget? = null
  private var moveStartTouchX = 0f
  private var moveStartRangeStartMs = 0L
  private var moveStartRangeDurationMs = 0L
  // Set instead of activeItemIndex/activeDrag whenever ACTION_DOWN lands
  // on a Text/Sticker/Overlay row but doesn't hit any item's edge handle
  // — see onUnhandledDragDeltaX's own doc for why this row must forward
  // the gesture itself rather than falling through like mergedStripView
  // does.
  private var isForwardingUnhandledDrag = false
  private var lastUnhandledTouchX = 0f

  // Long-press-then-drag reorder (see onReorderSwap's own doc). Kept
  // fully independent of activeDrag/isForwardingUnhandledDrag — a pending
  // long press is cancelled the moment the finger moves beyond touch slop
  // (a deliberate hold-still is what distinguishes "I want to reorder"
  // from "I'm trimming/moving/scrolling"), and once it DOES fire, it wins
  // outright (activeDrag is cleared) since nothing could have moved yet.
  private val longPressHandler = Handler(Looper.getMainLooper())
  private var pendingLongPress: Runnable? = null
  private var isReordering = false
  private var reorderIndex: Int? = null
  private var reorderStartY = 0f
  private var downX = 0f
  private var downY = 0f
  private val longPressTimeoutMs = 450L
  private val touchSlopPx = dp(10f)
  private val reorderStepPx = dp(28f)

  // Whether THIS gesture currently holds filmstripScrollView's ancestor
  // interception disallowed on behalf of a pending-or-active reorder — see
  // the ACTION_DOWN/ACTION_MOVE/ACTION_UP sites that set/clear it for why
  // this needs to be claimed the moment a long-press is SCHEDULED, not
  // only once it fires.
  private var didDisallowInterceptForReorderCandidate = false

  /** Highlights one item (or none) from outside — keeps the track in sync
   *  with the layer selected on the canvas, and across row rebuilds. */
  fun setSelection(id: View?, segmentIndex: Int?) {
    if (selectedItemId === id && selectedSegmentIndex == segmentIndex) return
    selectedItemId = id
    selectedSegmentIndex = if (id == null) null else segmentIndex
    invalidate()
  }

  fun configure(durationMs: Long, items: List<Item>) {
    this.durationMs = durationMs.coerceAtLeast(1)
    this.items = items
    if (items.none { it.id === selectedItemId && it.segmentIndex == selectedSegmentIndex }) {
      selectedItemId = null
      selectedSegmentIndex = null
    }
    invalidate()
  }

  private fun xFor(timeMs: Long): Float {
    if (isMergedClipsContinuation) {
      if (width <= 0) return 0f
      return (timeMs.toFloat() / durationMs) * width
    }
    val usableWidth = width - edgeInsetPx * 2
    if (usableWidth <= 0) return edgeInsetPx
    return edgeInsetPx + (timeMs.toFloat() / durationMs) * usableWidth
  }


  private fun timeFor(x: Float): Long {
    if (isMergedClipsContinuation) {
      if (width <= 0) return 0L
      return ((x.coerceIn(0f, width.toFloat()) / width) * durationMs).toLong()
    }
    val usableWidth = width - edgeInsetPx * 2
    if (usableWidth <= 0) return 0L
    val clamped = (x - edgeInsetPx).coerceIn(0f, usableWidth)
    return ((clamped / usableWidth) * durationMs).toLong()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    canvas.drawRect(
      0f, 0f, width.toFloat(), height.toFloat(),
      if (isMergedClipsContinuation) filmstripContinuationBackgroundPaint else backgroundPaint,
    )

    for ((index, item) in items.withIndex()) {
      // Hidden layer: everything for this item is drawn at reduced alpha.
      val dimSave = if (item.isDimmed) canvas.saveLayerAlpha(0f, 0f, width.toFloat(), height.toFloat(), 102) else -1
      val startX = xFor(item.rangeStartMs)
      val endX = xFor(item.rangeEndMs)
      val barRect = RectF(startX, 2f, endX.coerceAtLeast(startX + 2f), height - 2f)
      // EVERY merged-clip item's leading corners are squared — item 0's
      // against VideoTrimView's own (squareTrailingCorners) right edge,
      // and index>0's against the PREVIOUS merged clip's own (also
      // squared) trailing corners — and every item except the LAST has
      // its trailing corners squared too, against the NEXT merged clip.
      // Only the very last item's trailing edge stays rounded, as a cap
      // for the whole combined timeline. Previously only item 0's leading
      // corners were ever squared, so any second-or-later merged clip
      // still drew fully rounded corners on both sides — since each
      // item's own thumbnail is clipped to its own barPath, that left a
      // visible lens-shaped notch of bare background peeking through at
      // every seam between two merged clips, exactly matching the user's
      // explicit "in between both video layer there should not be blank
      // space... it should be completely merged" report.
      val squareLeading = isMergedClipsContinuation
      val squareTrailing = isMergedClipsContinuation && index < items.size - 1
      val barPath = android.graphics.Path().apply {
        if (squareLeading || squareTrailing) {
          val topLeft = if (squareLeading) 0f else cornerRadiusPx
          val topRight = if (squareTrailing) 0f else cornerRadiusPx
          val bottomRight = if (squareTrailing) 0f else cornerRadiusPx
          val bottomLeft = if (squareLeading) 0f else cornerRadiusPx
          addRoundRect(barRect, floatArrayOf(topLeft, topLeft, topRight, topRight, bottomRight, bottomRight, bottomLeft, bottomLeft), android.graphics.Path.Direction.CW)
        } else {
          addRoundRect(barRect, cornerRadiusPx, cornerRadiusPx, android.graphics.Path.Direction.CW)
        }
      }
      if (item.thumbnailTiles.isNotEmpty()) {
        canvas.save()
        canvas.clipPath(barPath)
        val tileWidth = barRect.width() / item.thumbnailTiles.size
        for ((tileIndex, bitmap) in item.thumbnailTiles.withIndex()) {
          val tileRect = RectF(
            barRect.left + tileWidth * tileIndex, barRect.top,
            barRect.left + tileWidth * (tileIndex + 1), barRect.bottom,
          )
          drawAspectFilled(canvas, bitmap, tileRect)
        }
        canvas.restore()
      } else {
        barPaint.color = item.color
        canvas.drawPath(barPath, barPaint)
      }

      // Every edge-draggable item (Text/Sticker/Overlay; NOT a
      // merged-clip row, which keeps its own deliberate "plain thumbnail
      // unless active" look, and not the Music row, whose duration isn't
      // edge-draggable) always shows a grip at each edge, even before
      // it's selected — see dimHandlePaint's own doc.
      if (edgeDragEnabled && !isMergedClipsContinuation) {
        // Selected item: bigger white trim handles so it's obvious where
        // to drag; others keep the small gray grips.
        val isSelectedItem = item.id === selectedItemId && item.segmentIndex == selectedSegmentIndex
        val handleWidth = if (isSelectedItem) dp(7f) else dimHandleWidthPx
        val top = height * (if (isSelectedItem) 0.2f else 0.25f)
        val bottom = height * (if (isSelectedItem) 0.8f else 0.75f)
        val paint = if (isSelectedItem) selectedHandlePaint else dimHandlePaint
        // Clamped inside the view: an item starting at 0:00 or ending at
        // the very end (e.g. a full-length music track) would otherwise
        // have half its handle cut off at the view's edge.
        val leftX = maxOf(0f, startX - handleWidth / 2)
        val rightX = minOf(width - handleWidth, endX - handleWidth / 2)
        val dimLeftHandleRect = RectF(leftX, top, leftX + handleWidth, bottom)
        canvas.drawRoundRect(dimLeftHandleRect, handleWidth / 2, handleWidth / 2, paint)
        val dimRightHandleRect = RectF(rightX, top, rightX + handleWidth, bottom)
        canvas.drawRoundRect(dimRightHandleRect, handleWidth / 2, handleWidth / 2, paint)
      }

      // Yellow border + edge-grip handles + duration label for the merged
      // clip currently under the playhead ONLY, matching VideoTrimView's
      // OWN active-segment look exactly — per the user's explicit
      // Instagram-reference request, other (inactive) merged clips show
      // a plain thumbnail with no border. Text/Sticker/Overlay items are
      // unaffected (isActive is always false there).
      if (item.isActive) {
        canvas.drawPath(barPath, mergedClipBorderPaint)
        val leftHandleRect = RectF(startX - mergedClipHandleWidthPx / 2, height * 0.2f, startX + mergedClipHandleWidthPx / 2, height * 0.8f)
        canvas.drawRoundRect(leftHandleRect, mergedClipHandleWidthPx / 2, mergedClipHandleWidthPx / 2, mergedClipHandlePaint)
        val rightHandleRect = RectF(endX - mergedClipHandleWidthPx / 2, height * 0.2f, endX + mergedClipHandleWidthPx / 2, height * 0.8f)
        canvas.drawRoundRect(rightHandleRect, mergedClipHandleWidthPx / 2, mergedClipHandleWidthPx / 2, mergedClipHandlePaint)
        item.durationLabel?.let { canvas.drawText(it, startX + dp(6f), dp(16f), mergedClipDurationLabelPaint) }
      }

      if ((item.id === selectedItemId && item.segmentIndex == selectedSegmentIndex) || (isReordering && index == reorderIndex)) {
        canvas.drawPath(barPath, selectedStrokePaint)
      }

      // Thumbnail items skip the text label entirely — video content
      // behind small white text reads poorly, and the thumbnail itself
      // already identifies the clip.
      var labelRect = RectF(barRect)
      // Beat dots along the bottom of the bar.
      if (item.markers.isNotEmpty()) {
        for (beat in item.markers) {
          if (beat < item.rangeStartMs || beat > item.rangeEndMs) continue
          canvas.drawCircle(xFor(beat), barRect.bottom - dp(4.5f), dp(1.5f), beatDotPaint)
        }
      }
      // Hidden / locked icons at the right end; the label stops before them.
      var labelRightLimit = barRect.right
      if (item.statusIcons.isNotEmpty() && item.thumbnailTiles.isEmpty()) {
        val iconSide = dp(12f)
        val needed = item.statusIcons.size * (iconSide + dp(4f)) + dp(8f)
        if (barRect.width() >= needed + dp(30f)) {
          var iconX = barRect.right - dp(8f) - iconSide
          for (icon in item.statusIcons.asReversed()) {
            val top = (barRect.centerY() - iconSide / 2).toInt()
            icon.setBounds(iconX.toInt(), top, (iconX + iconSide).toInt(), top + iconSide.toInt())
            icon.draw(canvas)
            iconX -= iconSide + dp(4f)
          }
          labelRightLimit = barRect.right - needed
          labelRect.right = labelRightLimit
        }
      }
      if (item.thumbnailTiles.isEmpty() && (item.badge != null || item.badgeText != null) && barRect.width() >= dp(34f)) {
        val side = minOf(dp(22f), barRect.height() - dp(8f))
        val tile = RectF(barRect.left + dp(6f), barRect.centerY() - side / 2, barRect.left + dp(6f) + side, barRect.centerY() + side / 2)
        canvas.save()
        canvas.clipPath(Path().apply { addRoundRect(tile, dp(5f), dp(5f), Path.Direction.CW) })
        val bitmap = item.badge
        if (bitmap != null && item.badgeFillsTile) {
          drawAspectFilled(canvas, bitmap, tile)
        } else {
          canvas.drawRect(tile, badgeTilePaint)
          if (bitmap != null && bitmap.width > 0 && bitmap.height > 0) {
            val box = RectF(tile).apply { inset(dp(3.5f), dp(3.5f)) }
            val scale = minOf(box.width() / bitmap.width, box.height() / bitmap.height)
            val w = bitmap.width * scale
            val h = bitmap.height * scale
            canvas.drawBitmap(bitmap, null, RectF(box.centerX() - w / 2, box.centerY() - h / 2, box.centerX() + w / 2, box.centerY() + h / 2), badgeBitmapPaint)
          } else {
            item.badgeText?.let { glyph ->
              badgeTextPaint.textSize = dp(12f)
              canvas.drawText(glyph, tile.centerX(), tile.centerY() - (badgeTextPaint.descent() + badgeTextPaint.ascent()) / 2, badgeTextPaint)
            }
          }
        }
        canvas.restore()
        labelRect = RectF(tile.right + dp(2f), barRect.top, maxOf(tile.right + dp(2f), labelRightLimit), barRect.bottom)
      }
      if (item.thumbnailTiles.isEmpty() && item.label.isNotEmpty() && labelRect.width() > dp(16f)) {
        val textY = labelRect.centerY() - (labelPaint.descent() + labelPaint.ascent()) / 2
        val textWidth = labelPaint.measureText(item.label)
        canvas.save()
        canvas.clipRect(labelRect)
        // Name drawn ONCE, left-aligned (after the badge), shortened with
        // "…" when it doesn't fit — the user asked for no repeated names.
        val available = labelRect.width() - dp(8f)
        val text = if (textWidth <= available) item.label else {
          android.text.TextUtils.ellipsize(item.label, android.text.TextPaint(labelPaint), available, android.text.TextUtils.TruncateAt.END).toString()
        }
        labelPaint.textAlign = Paint.Align.LEFT
        canvas.drawText(text, labelRect.left + dp(4f), textY, labelPaint)
        labelPaint.textAlign = Paint.Align.CENTER
        canvas.restore()
      }
      if (dimSave >= 0) canvas.restoreToCount(dimSave)
    }
  }

  /** Crops (rather than stretches) `bitmap` to fill `rect` without
   *  distorting its aspect ratio — mirrors VideoTrimView's identical
   *  private helper (not shared directly since that one stays private to
   *  its own file); a plain draw would squeeze the frame to fit each
   *  item's own (usually much narrower) width. */
  private fun drawAspectFilled(canvas: Canvas, bitmap: Bitmap, rect: RectF) {
    if (bitmap.width <= 0 || bitmap.height <= 0) return
    val bitmapAspect = bitmap.width.toFloat() / bitmap.height
    val rectAspect = rect.width() / rect.height()
    val drawRect = if (bitmapAspect > rectAspect) {
      val scaledWidth = rect.height() * bitmapAspect
      RectF(rect.centerX() - scaledWidth / 2, rect.top, rect.centerX() + scaledWidth / 2, rect.bottom)
    } else {
      val scaledHeight = rect.width() / bitmapAspect
      RectF(rect.left, rect.centerY() - scaledHeight / 2, rect.right, rect.centerY() + scaledHeight / 2)
    }
    canvas.save()
    canvas.clipRect(rect)
    canvas.drawBitmap(bitmap, null, drawRect, null)
    canvas.restore()
  }

  /** For merged-clip rows (isMergedClipsContinuation), only the ACTIVE
   *  item's edges are even eligible to recognize a drag — dragging a
   *  clip's BODY falls through (`return false`) to the ancestor
   *  HorizontalScrollView it actually sits inside, which is Android's own
   *  normal touch-dispatch fallthrough. Text/Sticker/Overlay rows now get
   *  the same "body isn't draggable" treatment (their own
   *  onUnhandledDragDeltaX forwards the gesture manually instead, since
   *  they have no real ancestor scroll container to fall through to) —
   *  body-drag-to-reschedule an item used to be recognized here, but was
   *  removed after the user confirmed a swipe meant to scroll the shared
   *  timeline (which visually looks like one continuous scrollable strip)
   *  was silently rescheduling whichever layer's bar the touch happened
   *  to land on instead. An item's timing can now only be changed via its
   *  own edge handles. */
  override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        activeItemIndex = null
        activeDrag = null
        isForwardingUnhandledDrag = false
        isReordering = false
        reorderIndex = null
        downX = event.x
        downY = event.y
        downRawY = event.rawY
        tapCandidateIndex = null
        touchMovedBeyondSlop = false
        // Hit-test topmost (last-drawn) item first, so an overlapping
        // pair resolves to whichever one currently reads on top.
        for (index in items.indices.reversed()) {
          val item = items[index]
          if (isMergedClipsContinuation && !item.isActive) continue
          val startX = xFor(item.rangeStartMs)
          val endX = xFor(item.rangeEndMs)
          val target = when {
            edgeDragEnabled && abs(event.x - startX) <= edgeWidthPx / 2 + edgeTouchSlopPx -> DragTarget.START
            edgeDragEnabled && abs(event.x - endX) <= edgeWidthPx / 2 + edgeTouchSlopPx -> DragTarget.END
            allowBodyDrag && event.x in startX..endX &&
              (!bodyDragRequiresSelection || (item.id === selectedItemId && item.segmentIndex == selectedSegmentIndex)) -> DragTarget.MOVE
            else -> null
          } ?: continue
          activeItemIndex = index
          activeDrag = target
          if (target == DragTarget.MOVE) {
            moveStartTouchX = event.x
            moveStartRangeStartMs = item.rangeStartMs
            moveStartRangeDurationMs = item.rangeEndMs - item.rangeStartMs
          }
          break
        }
        activeItemIndex?.let { index ->
          selectedItemId = items[index].id
          selectedSegmentIndex = items[index].segmentIndex
          onItemSelected?.invoke(items[index].id, items[index].segmentIndex)
          parent?.requestDisallowInterceptTouchEvent(true)
          onHandleDragStateChanged?.invoke(true)
          invalidate()
        }
        // Long-press-to-reorder is ONLY considered when this touch did
        // NOT already match an edge/body-move target above — scheduling
        // it unconditionally (this session's first attempt) raced every
        // START/END/MOVE drag: if the user pressed then paused before
        // actually moving (a completely normal press-then-drag rhythm),
        // the long-press timer fired first and clobbered the in-progress
        // drag by clearing activeDrag, silently breaking trim/move
        // entirely — this is what the user was hitting with "unable to
        // drag and trim music layer". Now a touch that DID hit an edge or
        // (music-only) the body itself is claimed outright; only a touch
        // that hit NEITHER (a text/sticker/overlay row's plain body,
        // which does nothing else, or — now — a merged-clip row's body,
        // which used to just fall through to the ancestor scroll view)
        // is eligible for reorder.
        tapCandidateIndex = activeItemIndex
        // A selected layer's body is a move target, but holding still on
        // it should still start a reorder (same as an unselected row).
        val moveIndex = activeItemIndex
        if (moveIndex != null && activeDrag == DragTarget.MOVE && bodyDragRequiresSelection) {
          val runnable = Runnable { beginReorder(moveIndex) }
          pendingLongPress = runnable
          longPressHandler.postDelayed(runnable, longPressTimeoutMs)
        }
        if (activeItemIndex == null) {
          val reorderCandidate = items.indices.reversed().firstOrNull { idx ->
            val item = items[idx]
            (!isMergedClipsContinuation || item.isActive) &&
              event.x in xFor(item.rangeStartMs)..xFor(item.rangeEndMs)
          }
          tapCandidateIndex = reorderCandidate
          if (reorderCandidate != null) {
            val runnable = Runnable { beginReorder(reorderCandidate) }
            pendingLongPress = runnable
            longPressHandler.postDelayed(runnable, longPressTimeoutMs)
            // Don't ALSO start forwarding-to-scroll yet — if the long
            // press gets cancelled by movement (see ACTION_MOVE), that's
            // when the fallback (scroll-forward, or — merged rows —
            // falling through to the real ancestor HorizontalScrollView)
            // kicks in. Merged rows must actively CLAIM this touch
            // (return true, below) to keep the option open; the usual
            // return-false-to-fall-through can only happen at DOWN.
            if (isMergedClipsContinuation) {
              // Claim exclusivity from filmstripScrollView RIGHT NOW, not
              // only once the long press actually fires in beginReorder()
              // — per the user's explicit "long press then drag
              // horizontally moves ALL clips" report. Without this,
              // filmstripScrollView's OWN (smaller) touch slop can
              // intercept mid-gesture the instant the finger drifts even
              // slightly during this hold-still wait — well before this
              // view's own longer 450ms timer elapses — so the reorder
              // never gets a chance to start at all; the user just sees
              // the whole strip natively scroll instead (this is exactly
              // the mechanism filmstripScrollView's own dispatchTouchEvent
              // override doc, in MediaEditorActivity, already describes).
              // Released below the moment it's clear this ISN'T a
              // deliberate long-press (touch-slop cancellation), or once
              // the touch ends.
              parent?.requestDisallowInterceptTouchEvent(true)
              didDisallowInterceptForReorderCandidate = true
              return true
            }
          } else {
            if (isMergedClipsContinuation) return false
            isForwardingUnhandledDrag = true
            // rawX (screen-absolute), not event.x (view-local) — see the
            // ACTION_MOVE forwarding block's own doc for why.
            lastUnhandledTouchX = event.rawX
          }
        }
      }
      MotionEvent.ACTION_MOVE -> {
        if (isReordering && onCrossRowReorderStep != null) {
          val deltaY = event.rawY - reorderStartRawY
          if (abs(deltaY) >= crossRowStepPx) {
            onCrossRowReorderStep?.invoke(if (deltaY < 0) -1 else 1)?.let { moved -> reorderStartRawY += moved }
          }
          return true
        }
        if (isReordering) {
          val index = reorderIndex ?: return true
          val deltaY = event.y - reorderStartY
          if (deltaY <= -reorderStepPx && index > 0) {
            onReorderSwap?.invoke(items[index].id, items[index - 1].id)
            items = items.toMutableList().apply { val tmp = this[index]; this[index] = this[index - 1]; this[index - 1] = tmp }
            reorderIndex = index - 1
            reorderStartY = event.y
            invalidate()
          } else if (deltaY >= reorderStepPx && index < items.size - 1) {
            onReorderSwap?.invoke(items[index].id, items[index + 1].id)
            items = items.toMutableList().apply { val tmp = this[index]; this[index] = this[index + 1]; this[index + 1] = tmp }
            reorderIndex = index + 1
            reorderStartY = event.y
            invalidate()
          }
          return true
        }
        if (abs(event.x - downX) > touchSlopPx || abs(event.y - downY) > touchSlopPx) touchMovedBeyondSlop = true
        if (pendingLongPress != null && (abs(event.x - downX) > touchSlopPx || abs(event.y - downY) > touchSlopPx)) {
          pendingLongPress?.let { longPressHandler.removeCallbacks(it) }
          pendingLongPress = null
          // The long press never fired (this is a normal scroll swipe,
          // not a hold-still), and activeItemIndex was null the whole
          // time this was pending (that's WHY a reorder candidate was
          // even considered) — so this gesture now falls back to
          // scroll-forwarding, starting fresh from the current point.
          // Merged rows already claimed this touch (returned true at
          // DOWN, since return-false-to-fall-through only works AT DOWN)
          // so they need this same manual forwarding now too, unlike
          // their old default of a free native ancestor-scroll handoff.
          if (activeItemIndex == null) {
            if (isMergedClipsContinuation) {
              // This was just a normal scroll swipe, not a deliberate
              // long-press-then-drag reorder — hand exclusivity back to
              // filmstripScrollView (claimed above, right when the long
              // press was scheduled) so it can take over native scrolling
              // from here. onUnhandledDragDeltaX is NOT the right fallback
              // for merged rows — it never fires for them (see its own
              // doc) since they have a REAL ancestor scroll view to just
              // fall through to instead of forwarding manually.
              if (didDisallowInterceptForReorderCandidate) {
                parent?.requestDisallowInterceptTouchEvent(false)
                didDisallowInterceptForReorderCandidate = false
              }
            } else {
              isForwardingUnhandledDrag = true
              lastUnhandledTouchX = event.rawX
            }
          }
        }
        if (isForwardingUnhandledDrag) {
          // rawX (screen-absolute), NOT event.x (view-local) — this row
          // is a child of the very HorizontalScrollView it's forwarding
          // deltas TO, so onUnhandledDragDeltaX's own scrollBy call
          // physically moves THIS view on screen as a side effect.
          // event.x is reported relative to the view's CURRENT (just-
          // moved) position, so using it here fed each correction back
          // into the next delta calculation — the view sliding out from
          // under the finger by roughly the same amount the finger
          // itself moved, making the reported local delta collapse
          // toward zero after the first event and the gesture stop
          // responding almost immediately. rawX is screen-absolute and
          // completely unaffected by this view's own scrolling, so the
          // delta always reflects the finger's TRUE movement. Per the
          // user's explicit "only happens on layers other than the first
          // video clip" report — the primary clip's own VideoTrimView
          // has no equivalent claim-and-relay path (it just falls
          // through to native scrolling directly), which is exactly why
          // this bug was scoped to merged-clip rows only.
          onUnhandledDragDeltaX?.invoke(event.rawX - lastUnhandledTouchX)
          lastUnhandledTouchX = event.rawX
          return true
        }
        val index = activeItemIndex ?: return false
        val item = items.getOrNull(index) ?: return false
        if (snapCache == null) snapTargets?.let { snapCache = it(item.id, item.segmentIndex) }
        var snapped: Long? = null
        when (activeDrag) {
          DragTarget.START -> {
            var t = timeFor(event.x)
            nearestSnap(t)?.let { t = it; snapped = it }
            item.rangeStartMs = t.coerceIn(0, item.rangeEndMs - minRangeDurationMs)
          }
          DragTarget.END -> {
            var t = timeFor(event.x)
            nearestSnap(t)?.let { t = it; snapped = it }
            item.rangeEndMs = t.coerceIn(item.rangeStartMs + minRangeDurationMs, durationMs)
          }
          DragTarget.MOVE -> {
            val deltaMs = timeFor(event.x) - timeFor(moveStartTouchX)
            val maxStartMs = (durationMs - moveStartRangeDurationMs).coerceAtLeast(0)
            var newStartMs = (moveStartRangeStartMs + deltaMs).coerceIn(0, maxStartMs)
            // Either edge can snap; the closer one wins.
            val startSnap = nearestSnap(newStartMs)
            val endSnap = nearestSnap(newStartMs + moveStartRangeDurationMs)
            if (startSnap != null && (endSnap == null || kotlin.math.abs(startSnap - newStartMs) <= kotlin.math.abs(endSnap - newStartMs - moveStartRangeDurationMs))) {
              newStartMs = startSnap; snapped = startSnap
            } else if (endSnap != null) {
              newStartMs = endSnap - moveStartRangeDurationMs; snapped = endSnap
            }
            newStartMs = newStartMs.coerceIn(0, maxStartMs)
            item.rangeStartMs = newStartMs
            item.rangeEndMs = newStartMs + moveStartRangeDurationMs
          }
          null -> return false
        }
        if (snapped != null && snapped != snappedTimeMs) performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)
        snappedTimeMs = snapped
        onRangeChanged?.invoke(item.id, item.segmentIndex, item.rangeStartMs, item.rangeEndMs)
        invalidate()
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        snapCache = null
        snappedTimeMs = null
        // A quick tap: released before the long-press fired, never moved.
        val tapped = if (event.actionMasked == MotionEvent.ACTION_UP && onItemTapped != null && !isReordering && !touchMovedBeyondSlop) {
          tapCandidateIndex?.let { items.getOrNull(it) }
        } else {
          null
        }
        if (tapped != null) {
          selectedItemId = tapped.id
          selectedSegmentIndex = tapped.segmentIndex
          performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)
          onItemSelected?.invoke(tapped.id, tapped.segmentIndex)
          invalidate()
          post { onItemTapped?.invoke(tapped.id, tapped.segmentIndex) }
        }
        pendingLongPress?.let { longPressHandler.removeCallbacks(it) }
        pendingLongPress = null
        // Covers the "quick tap, released before either the long press
        // fired or touch-slop cancelled it" case — the two sites above
        // already release this for their own cases, this is the catch-all.
        if (didDisallowInterceptForReorderCandidate) {
          parent?.requestDisallowInterceptTouchEvent(false)
          didDisallowInterceptForReorderCandidate = false
        }
        val wasDragging = activeDrag != null
        if (wasDragging) onHandleDragStateChanged?.invoke(false)
        activeItemIndex = null
        activeDrag = null
        isForwardingUnhandledDrag = false
        if (wasDragging) onDragEnded?.invoke()
        if (isReordering) {
          isReordering = false
          reorderIndex = null
          invalidate()
          onReorderEnded?.invoke()
        }
      }
    }
    return true
  }

  /** Fired once the long-press timer elapses without the finger having
   *  moved beyond touch slop — switches this gesture over to reorder mode
   *  outright, discarding whatever START/END/MOVE interpretation
   *  ACTION_DOWN may ALSO have assigned (nothing could have changed yet,
   *  since slop wasn't exceeded). */
  private fun beginReorder(index: Int) {
    if (!reorderEnabled) {
      // Rows with reordering disabled (the music row: every segment
      // shares the SAME id, so there's nothing to reorder against) still
      // need long-press to SELECT the tapped segment, same as every other
      // row — per the user's explicit "on long press these splitted
      // portion should select only" correction. Deleting the whole track
      // now happens via the normal per-segment delete icon once selected
      // (see deleteMusicSegment's own doc), not directly from long-press.
      selectedItemId = items[index].id
      selectedSegmentIndex = items[index].segmentIndex
      onItemSelected?.invoke(items[index].id, items[index].segmentIndex)
      performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
      invalidate()
      return
    }
    if (activeDrag != null) onHandleDragStateChanged?.invoke(false)
    activeItemIndex = null
    activeDrag = null
    isForwardingUnhandledDrag = false
    isReordering = true
    reorderIndex = index
    reorderStartY = downY
    reorderStartRawY = downRawY
    selectedItemId = items[index].id
    selectedSegmentIndex = items[index].segmentIndex
    onItemSelected?.invoke(items[index].id, items[index].segmentIndex)
    parent?.requestDisallowInterceptTouchEvent(true)
    performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    invalidate()
  }

  private fun dp(value: Float): Float = value * resources.displayMetrics.density
}
