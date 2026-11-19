package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs

/**
 * A horizontal timeline strip. Two visual styles share one class since
 * both the main video trim scrubber AND the music trim strip (both
 * instantiated as plain `VideoTrimView(context)` in MediaEditorActivity)
 * are the same type:
 *  - Plain style (default, used by music): dimmed background, a lighter
 *    band for the current trim selection, two equal-sized yellow handle
 *    bars, a playhead line. Drives [trimStartMs]/[trimEndMs] +
 *    [onTrimChanged], a single kept range — music has no split/delete
 *    concept.
 *  - Filmstrip style (opted into by calling [loadThumbnails], used by the
 *    main video scrubber only): real extracted video frame thumbnails
 *    tiled edge-to-edge. Drives [segments]/[onSegmentsChanged] instead —
 *    MULTIPLE kept ranges (per the user's explicit "split into parts,
 *    delete any of them" request), each with its own rounded accent
 *    border, portions outside ALL segments (both the outer trim and any
 *    internal deleted gap) dimmed rather than hidden — matching the
 *    native Photos/iMovie trim-tool look the user referenced directly.
 *    Only the FIRST segment's start and the LAST segment's end are
 *    draggable handles (the overall trim); internal split points are
 *    fixed dividers in this pass, not independently adjustable — a
 *    deliberate scope cut to keep touch handling tractable (see
 *    [splitAtCurrentTime]/[deleteSegment]'s own docs for the full model).
 * Music has no video frames to extract, so it never calls
 * [loadThumbnails] and keeps the plain style/single-range API unchanged.
 *
 * Dragging near an (outer) handle resizes the trim; dragging anywhere
 * else on the bar scrubs playback instead — same "handles are the only
 * specific target, everywhere else falls to the other interaction" split
 * as CropOverlayView, just within one view instead of two layered ones
 * (no second view underneath to fall through to here).
 */
internal class VideoTrimView(context: Context) : View(context) {

  var durationMs: Long = 0
    private set
  // Plain-style API (music) — unchanged from before segments existed.
  var trimStartMs: Long = 0
    private set
  var trimEndMs: Long = 0
    private set
  // Filmstrip-style API (video) — ordered, non-overlapping, ascending.
  // Always at least one element once [configureFullRange] has run.
  var segments: List<LongRange> = emptyList()
    private set

  var currentPositionMs: Long = 0
    set(value) {
      field = value
      invalidate()
    }

  /** True once one or more merged video clips (MediaEditorActivity's
   *  mergedStripViewRef) are attached directly to this view's trailing
   *  edge with zero gap, forming one continuous filmstrip — squares off
   *  this view's own right-side corners (the overall filmstrip clip path
   *  AND the last kept segment's own border) so the two views'
   *  independently-rounded corners don't visibly double up into two
   *  separate pills at the seam. Default false (fully rounded) leaves the
   *  music trim view and the no-merged-clips video case pixel-identical
   *  to before. */
  var squareTrailingCorners: Boolean = false
    set(value) {
      field = value
      invalidate()
    }

  /** Whether THIS clip (the primary) is the one currently under the
   *  playhead in MediaEditorActivity's combined multi-clip timeline — per
   *  the user's explicit Instagram reference ("highlighted video clip
   *  with yellow color only, display clip duration on that clip"), the
   *  yellow border/handles/duration-label now only show for whichever
   *  clip is ACTIVE, not every clip unconditionally. Defaults to true so
   *  a session with no merged clips at all (nothing else to compare
   *  against) stays pixel-identical to the original always-yellow look —
   *  only set to false by the activity once merged clips exist and a
   *  different one becomes active. */
  var isActiveClip: Boolean = true
    set(value) {
      field = value
      invalidate()
    }

  /** Which kept segment the user last TAPPED (filmstrip style only) —
   *  drawn with an added white border (see drawFilmstripStyle) and the
   *  target for [deleteSegment] (index overload) — mirrors the identical
   *  selected-segment pattern already used for text/sticker/overlay layers
   *  (LayerRangeBarView). Cleared whenever the segment structure itself
   *  changes (split/delete), since indices can shift; NOT cleared by a
   *  plain handle drag (trimming the overall start/end doesn't change
   *  which index is which). */
  var selectedSegmentIndex: Int? = null
    private set

  var onTrimChanged: ((startMs: Long, endMs: Long) -> Unit)? = null
  var onSegmentsChanged: ((segments: List<LongRange>) -> Unit)? = null
  /** Fires whenever a segment gets tapped-selected (filmstrip style) — the
   *  owning Activity uses this to deselect any currently-selected on-canvas
   *  layer, so Delete unambiguously targets whichever was tapped most
   *  recently (a video segment here, or a layer's own timeline row). */
  var onSegmentSelected: ((index: Int) -> Unit)? = null
  var onScrub: ((positionMs: Long) -> Unit)? = null
  /** Fires `true` when a HANDLE (start/end) drag begins and `false` when
   *  it ends — lets an ancestor scrollable container (MediaEditorActivity's
   *  filmstripScrollViewRef, once this view is embedded in the Instagram-
   *  style scrollable timeline) disable its own touch interception for
   *  exactly the duration of a handle drag. A plain body drag (no handle)
   *  is deliberately NOT reported here — that's meant to fall through to
   *  the scroll container's own panning (scrubbing IS scrolling in that
   *  context) rather than firing onScrub, which is why isFilmstripStyle's
   *  own scrub case is a no-op; only the plain (music) style still scrubs
   *  directly. */
  var onHandleDragStateChanged: ((Boolean) -> Unit)? = null

  // Plain-style-only sizing.
  private val plainHandleWidthPx = dp(10f)
  // Filmstrip-style-only sizing. Both outer handles are the SAME
  // vertical-grip shape/size — originally the right handle was a bigger
  // rounded square with a chevron, but the user asked for the chevron
  // gone and then for the right handle to match the left one exactly,
  // "so it will look the same."
  private val cornerRadiusPx = dp(10f)
  // Per-corner radii for Path.addRoundRect (top-left, top-right,
  // bottom-right, bottom-left, each an rx/ry pair) — rounds only the LEFT
  // corners, used when squareTrailingCorners is set.
  private val squareTrailingCornerRadii
    get() = floatArrayOf(cornerRadiusPx, cornerRadiusPx, 0f, 0f, 0f, 0f, cornerRadiusPx, cornerRadiusPx)
  // Thin selected/active border (was 2.5dp).
  private val borderWidthPx = dp(1.5f)
  private val filmstripHandleWidthPx = dp(6f)
  // Width of the fixed divider drawn at each INTERNAL split point (not a
  // draggable handle, just a visual gap so two adjacent kept segments
  // still read as separate pieces).
  private val splitDividerWidthPx = dp(4f)

  private val handleTouchSlopPx = dp(16f)
  // Filmstrip style's handle is a slimmer grip than plain style's, so a
  // tighter slop still leaves it comfortably grabbable while giving more
  // of the strip's own width back to the visible thumbnails, per the
  // user's explicit "reduce this space" follow-up.
  private val filmstripHandleTouchSlopPx = dp(6f)
  private val minTrimDurationMs = 2000L
  // Splitting an existing (already-split, possibly short) segment used
  // minTrimDurationMs too — meaning a segment shorter than 4s (2 * 2000ms)
  // could never be split again, no matter where tapped, since no valid
  // split point could leave both halves >= 2000ms. Per the user's
  // explicit "I've already split it into many parts and then I can't
  // split that split video, why?" report: a SEPARATE, smaller minimum
  // just for splitting (matching the 500ms convention already used for
  // layer-segment splits elsewhere in MediaEditorActivity) lets splitting
  // keep working on much shorter pieces, while minTrimDurationMs itself
  // still governs the overall trim handles (unrelated concern — how short
  // the WHOLE kept clip can shrink via dragging the outer edges), left
  // unchanged.
  private val minSplitSegmentDurationMs = 500L

  // A handle's full touch target must fit on-screen at BOTH extremes —
  // mapping time 0/duration flush to the view's own x=0/width leaves half
  // of each handle's touch target outside the view's bounds and
  // effectively ungrabbable (same bug as CropOverlayView's initial crop
  // rect, fixed the same way: inset the coordinate mapping, not just the
  // starting values).
  private val horizontalInsetPx = dp(24f)

  private val leftInsetPx: Float
    // Filmstrip style: no inset, so time 0 sits exactly on the playhead line.
    get() = if (isFilmstripStyle) 0f else horizontalInsetPx

  private val rightInsetPx: Float
    get() = if (isFilmstripStyle) 0f else horizontalInsetPx

  private val backgroundPaint = Paint().apply { color = Color.argb(64, 255, 255, 255) }
  private val selectedPaint = Paint().apply { color = Color.argb(150, 255, 255, 255) }
  private val playheadPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }

  private val filmstripBackgroundPaint = Paint().apply { color = Color.BLACK }
  private val filmstripDimPaint = Paint().apply { color = Color.argb(140, 0, 0, 0) }
  private val filmstripDividerPaint = Paint().apply { color = Color.BLACK }
  private val filmstripBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = EditorDesignTokens.Colors.trimHandle
    style = Paint.Style.STROKE
    strokeWidth = borderWidthPx
  }
  private val filmstripHandlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = EditorDesignTokens.Colors.trimHandle }
  // The specifically TAPPED segment (selectedSegmentIndex) gets an
  // ADDITIONAL white border on top of its own yellow one — mirrors the
  // identical selected-state look already used for text/sticker/overlay
  // layers. Layered on top, not replacing the yellow one, since that
  // separately signals "this whole clip is the active one."
  private val selectedSegmentBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    style = Paint.Style.STROKE
    strokeWidth = borderWidthPx
  }
  private val durationLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    textSize = dp(12f)
    isFakeBoldText = true
  }

  private enum class DragTarget { START, END, SCRUB }
  private var activeDrag: DragTarget? = null

  private var isFilmstripStyle = false
  // Keyed by tile index rather than a plain array, since thumbnails arrive
  // one at a time (each its own MediaMetadataRetriever call, off the main
  // thread) and are posted back to the UI thread as they complete.
  private val thumbnails = mutableMapOf<Int, Bitmap>()
  private var thumbnailTileCount = 0
  private var thumbnailGeneration = 0

  /** Called once duration becomes known — defaults the trim to the full
   *  clip. Updates BOTH the plain-style ([trimStartMs]/[trimEndMs]) and
   *  filmstrip-style ([segments]) state, since the caller doesn't know
   *  which style this instance is in. */
  fun configureFullRange(durationMs: Long) {
    this.durationMs = durationMs
    trimStartMs = 0
    trimEndMs = durationMs
    segments = listOf(0L..durationMs)
    invalidate()
  }

  /** Restores a specific previously-chosen trim (e.g. reopening a merged
   *  clip's own dedicated trim screen) instead of the full-range default
   *  [configureFullRange] already set — purely additive, doesn't change
   *  that method's own existing behavior for the primary clip's scrubber. */
  fun restoreSegments(newSegments: List<LongRange>) {
    if (newSegments.isEmpty()) return
    segments = newSegments
    trimStartMs = newSegments.first().first
    trimEndMs = newSegments.last().last
    invalidate()
  }

  /** Splits whichever kept segment contains [positionMs] into two segments
   *  at that exact point — the video-editing "split at playhead" action.
   *  No-ops (returns false) if [positionMs] isn't strictly inside a kept
   *  segment (e.g. it's already exactly at a split point, or it falls in
   *  an already-deleted gap) or if either resulting half would be
   *  shorter than [minSplitSegmentDurationMs]. */
  fun splitAtCurrentTime(positionMs: Long): Boolean {
    val index = segments.indexOfFirst { positionMs > it.first && positionMs < it.last }
    if (index < 0) return false
    val segment = segments[index]
    if (positionMs - segment.first < minSplitSegmentDurationMs || segment.last - positionMs < minSplitSegmentDurationMs) return false
    segments = segments.toMutableList().apply {
      removeAt(index)
      addAll(index, listOf(segment.first..positionMs, positionMs..segment.last))
    }
    selectedSegmentIndex = null
    onSegmentsChanged?.invoke(segments)
    invalidate()
    return true
  }

  /** Removes whichever kept segment contains [positionMs] — the video-
   *  editing "delete this part" action. Refuses (returns false) to
   *  delete the only remaining segment, since an empty timeline has
   *  nothing left to preview/export. */
  fun deleteSegment(positionMs: Long): Boolean {
    if (segments.size <= 1) return false
    val index = segments.indexOfFirst { positionMs >= it.first && positionMs <= it.last }
    if (index < 0) return false
    segments = segments.toMutableList().apply { removeAt(index) }
    selectedSegmentIndex = null
    onSegmentsChanged?.invoke(segments)
    invalidate()
    return true
  }

  /** Removes segment [index] specifically — the counterpart to
   *  [deleteSegment] (positionMs overload) for when the user has
   *  explicitly TAPPED a portion ([selectedSegmentIndex]) rather than
   *  scrubbed to one. Same "refuse to delete the only remaining segment"
   *  guard. */
  fun deleteSegment(index: Int): Boolean {
    if (segments.size <= 1 || index !in segments.indices) return false
    segments = segments.toMutableList().apply { removeAt(index) }
    selectedSegmentIndex = null
    onSegmentsChanged?.invoke(segments)
    invalidate()
    return true
  }

  /** Clears the tapped-segment selection without deleting anything —
   *  called by the owning Activity when focus moves elsewhere (a layer
   *  gets selected instead), so this view's own white selected-border
   *  doesn't linger on a segment that's no longer the actual delete
   *  target. */
  fun clearSegmentSelection() {
    if (selectedSegmentIndex == null) return
    selectedSegmentIndex = null
    invalidate()
  }

  /** Extracts [tileCount] evenly-spaced frames from the video at [uri] and
   *  tiles them across the strip as they arrive — the "real extracted
   *  thumbnails, not placeholder blocks" the reference image shows.
   *  Switches this instance into filmstrip style; only the main video
   *  scrubber calls this. Runs on a background thread (MediaMetadataRetriever
   *  is a blocking API, same pattern already used for the filter-thumbnail
   *  frame grab in MediaEditorActivity.onCreate's video branch);
   *  [thumbnailGeneration] guards against a stale reload (e.g. re-opening a
   *  different video) racing an in-flight one. */
  fun loadThumbnails(context: Context, uri: Uri, tileCount: Int = 8) {
    isFilmstripStyle = true
    thumbnailTileCount = tileCount
    thumbnails.clear()
    thumbnailGeneration++
    val generation = thumbnailGeneration

    Thread {
      val retriever = MediaMetadataRetriever()
      val durationUs = runCatching {
        retriever.setDataSource(context, uri)
        val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        durationMs * 1000L
      }.getOrDefault(0L)

      if (durationUs > 0) {
        for (index in 0 until tileCount) {
          if (generation != thumbnailGeneration) break
          // Frame sampled from the CENTER of each tile's time slice (not
          // its leading edge) — a more representative preview of that slice.
          val timeUs = (durationUs * (index + 0.5) / tileCount).toLong()
          val frame = runCatching {
            retriever.scaledFrameAt(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, FILMSTRIP_FRAME_MAX_SIDE)
          }.getOrNull()
          if (frame != null) {
            post {
              if (generation == thumbnailGeneration) {
                thumbnails[index] = frame
                invalidate()
              }
            }
          }
        }
      }
      retriever.release()
    }.start()
  }

  private fun xFor(timeMs: Long): Float {
    val usableWidth = width - leftInsetPx - rightInsetPx
    if (durationMs <= 0 || usableWidth <= 0) return leftInsetPx
    return leftInsetPx + (timeMs.toFloat() / durationMs) * usableWidth
  }

  private fun timeFor(x: Float): Long {
    val usableWidth = width - leftInsetPx - rightInsetPx
    if (usableWidth <= 0) return 0L
    val clamped = (x - leftInsetPx).coerceIn(0f, usableWidth)
    return ((clamped / usableWidth) * durationMs).toLong()
  }

  /** Maps a REAL time to a pixel X assuming every kept segment is packed
   *  back-to-back with NO gap for any cut-away portion (leading, internal,
   *  or trailing) — used only when [squareTrailingCorners] is true, per
   *  the user's explicit "remove these unused and trimmed out portion...
   *  look attached" request. A deliberate, accepted trade-off of this
   *  mode: since no pixels are ever reserved for cut-away footage, once
   *  an edge is trimmed inward there is no more on-screen space to drag
   *  it back out again — recovering that footage needs a fresh edit, not
   *  a drag. [timeMs] values inside an (invisible) cut-away gap clamp to
   *  that gap's nearest edge, so a fleeting real-time value (e.g. the
   *  playhead mid gap-skip) still lands somewhere sane. */
  private fun xForCompacted(timeMs: Long): Float {
    val filmstripWidth = width - leftInsetPx - rightInsetPx
    val totalKeptMs = segments.sumOf { it.last - it.first }
    if (totalKeptMs <= 0 || filmstripWidth <= 0) return leftInsetPx
    var compactedElapsedMs = 0L
    for (segment in segments) {
      if (timeMs < segment.first) break
      compactedElapsedMs += (minOf(timeMs, segment.last) - segment.first).coerceAtLeast(0)
      if (timeMs <= segment.last) break
    }
    return leftInsetPx + (compactedElapsedMs.toFloat() / totalKeptMs) * filmstripWidth
  }

  /** Inverse of [xForCompacted] — maps a pixel X (in the compacted, gaps-
   *  removed space that function draws) back to the REAL time within
   *  whichever kept segment that position falls in. */
  private fun realTimeForCompacted(x: Float): Long {
    val filmstripWidth = width - leftInsetPx - rightInsetPx
    val totalKeptMs = segments.sumOf { it.last - it.first }
    if (totalKeptMs <= 0 || filmstripWidth <= 0) return 0L
    val clampedX = (x - leftInsetPx).coerceIn(0f, filmstripWidth)
    var remainingMs = ((clampedX / filmstripWidth) * totalKeptMs).toLong()
    for (segment in segments) {
      val segmentLengthMs = segment.last - segment.first
      if (remainingMs <= segmentLengthMs) return segment.first + remainingMs
      remainingMs -= segmentLengthMs
    }
    return segments.lastOrNull()?.last ?: durationMs
  }

  /** Whether cut-away portions should be compacted OUT of the timeline
   *  entirely (no pixels reserved for them) rather than shown as a dimmed
   *  gap. Originally only true when a merged clip is attached
   *  ([squareTrailingCorners]) — extended to ALSO cover any split primary
   *  clip (more than one kept segment), so deleted footage visibly
   *  disappears from the filmstrip immediately instead of lingering as a
   *  dimmed remnant. [squareTrailingCorners] itself is UNCHANGED and still
   *  separately governs corner-rounding (the merged-clip seam) — this only
   *  changes which pixel-mapping/thumbnail-tiling strategy is used.
   *
   *  Also true whenever the kept segments no longer cover the FULL
   *  original duration, even down to a single remaining segment — per the
   *  user's explicit "split the ending part and delete it, the trimmed
   *  portion is still empty/greyed out" report: splitting into 2 segments
   *  then deleting one drops `segments.size` back to 1, which used to fall
   *  straight back to the plain (non-compacted) mapping — exactly the
   *  single most common case (trim off the end and delete it), silently
   *  letting the just-deleted tail reappear as blank space instead of
   *  being cropped away. */
  private val shouldCompactGaps: Boolean
    get() {
      if (squareTrailingCorners || segments.size > 1) return true
      val totalKeptMs = segments.sumOf { it.last - it.first }
      return totalKeptMs < durationMs - 10L
    }

  /** Picks the compacted or plain mapping depending on [shouldCompactGaps]
   *  — every filmstrip-style call site (drawing AND touch) goes through
   *  this pair rather than branching individually, so the two mappings
   *  can never drift out of sync between what's drawn and what's touched. */
  private fun filmstripXFor(timeMs: Long): Float = if (shouldCompactGaps) xForCompacted(timeMs) else xFor(timeMs)

  private fun filmstripTimeFor(x: Float): Long = if (shouldCompactGaps) realTimeForCompacted(x) else timeFor(x)

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (isFilmstripStyle) drawFilmstripStyle(canvas) else drawPlainStyle(canvas)
  }

  private fun drawPlainStyle(canvas: Canvas) {
    // Rounded container (matching the card it sits in) so the bar reads as
    // one cohesive control rather than a flat, decorative rectangle.
    val barRect = RectF(0f, 0f, width.toFloat(), height.toFloat())
    canvas.save()
    canvas.clipPath(Path().apply { addRoundRect(barRect, cornerRadiusPx, cornerRadiusPx, Path.Direction.CW) })
    canvas.drawRect(barRect, backgroundPaint)

    val startX = xFor(trimStartMs)
    val endX = xFor(trimEndMs)
    canvas.drawRect(startX, 0f, endX, height.toFloat(), selectedPaint)
    canvas.restore()

    // Handles drawn as rounded, vertically-inset "grip" pills — matching
    // the main video trim's own filmstrip-style handles — instead of full-
    // height rectangles. Per the user's "didn't realize those were
    // draggable handles" report: a thin bar spanning the full height reads
    // as a plain divider/marker, not an interactive control.
    val handleTop = height * 0.15f
    val handleBottom = height * 0.85f
    val startHandleRect = RectF(startX - plainHandleWidthPx / 2, handleTop, startX + plainHandleWidthPx / 2, handleBottom)
    canvas.drawRoundRect(startHandleRect, plainHandleWidthPx / 2, plainHandleWidthPx / 2, filmstripHandlePaint)
    val endHandleRect = RectF(endX - plainHandleWidthPx / 2, handleTop, endX + plainHandleWidthPx / 2, handleBottom)
    canvas.drawRoundRect(endHandleRect, plainHandleWidthPx / 2, plainHandleWidthPx / 2, filmstripHandlePaint)

    val playheadX = xFor(currentPositionMs)
    canvas.drawRect(playheadX - 1f, 0f, playheadX + 1f, height.toFloat(), playheadPaint)
  }

  private fun drawFilmstripStyle(canvas: Canvas) {
    val filmstripRect = RectF(leftInsetPx, 0f, width - rightInsetPx, height.toFloat())
    if (filmstripRect.width() <= 0 || segments.isEmpty()) return

    canvas.save()
    val clipPath = Path().apply {
      if (squareTrailingCorners) {
        addRoundRect(filmstripRect, squareTrailingCornerRadii, Path.Direction.CW)
      } else {
        addRoundRect(filmstripRect, cornerRadiusPx, cornerRadiusPx, Path.Direction.CW)
      }
    }
    canvas.clipPath(clipPath)

    canvas.drawRect(filmstripRect, filmstripBackgroundPaint)

    if (shouldCompactGaps) {
      drawCompactedThumbnails(canvas, filmstripRect)
    } else {
      val tileCount = thumbnailTileCount.coerceAtLeast(1)
      val tileWidth = filmstripRect.width() / tileCount
      for (index in 0 until tileCount) {
        val bitmap = thumbnails[index] ?: continue
        val tileRect = RectF(
          filmstripRect.left + tileWidth * index, 0f,
          filmstripRect.left + tileWidth * (index + 1), height.toFloat(),
        )
        drawAspectFilled(canvas, bitmap, tileRect)
      }

      // Dim every gap NOT covered by a kept segment — before the first
      // segment, after the last, and any internal deleted gap — matching
      // the native Photos/iMovie convention of always showing the full
      // filmstrip with cut-away portions darkened rather than hidden.
      // Only when NOT attached to a merged clip — see
      // drawCompactedThumbnails's own doc for why attached mode instead
      // removes cut-away portions entirely rather than dimming them.
      var cursor = filmstripRect.left
      for (segment in segments) {
        val segStartX = xFor(segment.first)
        val segEndX = xFor(segment.last)
        if (segStartX > cursor) {
          canvas.drawRect(cursor, 0f, segStartX, height.toFloat(), filmstripDimPaint)
        }
        cursor = segEndX
      }
      if (cursor < filmstripRect.right) {
        canvas.drawRect(cursor, 0f, filmstripRect.right, height.toFloat(), filmstripDimPaint)
      }
    }
    canvas.restore()

    // Thin fixed dividers at INTERNAL split points — not draggable
    // handles, just a visual seam indicating the primary clip's own
    // structure, shown regardless of active state.
    for (segment in segments.dropLast(1)) {
      val dividerX = filmstripXFor(segment.last)
      canvas.drawRect(dividerX - splitDividerWidthPx / 2, 0f, dividerX + splitDividerWidthPx / 2, height.toFloat(), filmstripDividerPaint)
    }

    // Each kept segment's own border, the outer draggable handles, and
    // the duration label are gated on isActiveClip — per the user's
    // explicit Instagram-reference request, only the clip currently
    // under the playhead shows this highlight; an inactive primary clip
    // (once merged clips exist and one of THEM is active) shows a plain
    // thumbnail-only strip instead. Only the FIRST segment's start and
    // the LAST segment's end are draggable (the overall trim); internal
    // split points have no handle of their own in this pass.
    if (isActiveClip) {
      for ((index, segment) in segments.withIndex()) {
        val segRect = RectF(filmstripXFor(segment.first), 0f, filmstripXFor(segment.last), height.toFloat())
        segRect.inset(borderWidthPx / 2, borderWidthPx / 2)
        // Only the LAST segment's right side ever touches the
        // merged-clips strip — earlier segments' right sides are the
        // internal split dividers above and stay fully rounded.
        if (index == segments.size - 1 && squareTrailingCorners) {
          val segPath = Path().apply { addRoundRect(segRect, squareTrailingCornerRadii, Path.Direction.CW) }
          canvas.drawPath(segPath, filmstripBorderPaint)
        } else {
          canvas.drawRoundRect(segRect, cornerRadiusPx, cornerRadiusPx, filmstripBorderPaint)
        }
      }

      selectedSegmentIndex?.let { index ->
        if (index in segments.indices) {
          val segment = segments[index]
          val segRect = RectF(filmstripXFor(segment.first), 0f, filmstripXFor(segment.last), height.toFloat())
          segRect.inset(borderWidthPx, borderWidthPx)
          canvas.drawRoundRect(segRect, (cornerRadiusPx - borderWidthPx).coerceAtLeast(0f), (cornerRadiusPx - borderWidthPx).coerceAtLeast(0f), selectedSegmentBorderPaint)
        }
      }

      val startX = filmstripXFor(segments.first().first)
      val endX = filmstripXFor(segments.last().last)
      val leftHandleRect = RectF(startX - filmstripHandleWidthPx / 2, height * 0.2f, startX + filmstripHandleWidthPx / 2, height * 0.8f)
      canvas.drawRoundRect(leftHandleRect, filmstripHandleWidthPx / 2, filmstripHandleWidthPx / 2, filmstripHandlePaint)
      val rightHandleRect = RectF(endX - filmstripHandleWidthPx / 2, height * 0.2f, endX + filmstripHandleWidthPx / 2, height * 0.8f)
      canvas.drawRoundRect(rightHandleRect, filmstripHandleWidthPx / 2, filmstripHandleWidthPx / 2, filmstripHandlePaint)

      // Duration label ("12.3s") — only once merged clips exist (matching
      // the reference, which only labels clips in a multi-clip context);
      // a lone, no-merge primary clip stays exactly as it always has.
      if (squareTrailingCorners) {
        val keptSeconds = segments.sumOf { it.last - it.first } / 1000.0
        canvas.drawText(String.format("%.1fs", keptSeconds), startX + dp(6f), dp(16f), durationLabelPaint)
      }
    }
  }

  /** Tiles thumbnails within EACH kept segment's own compacted pixel span
   *  only (no gap reserved before/between/after segments) — the filmstrip-
   *  style counterpart to the plain, even-across-full-width tiling above,
   *  used only when [squareTrailingCorners] is true. Each of the
   *  pre-sampled [thumbnails] (evenly spaced across the FULL real
   *  duration, from [loadThumbnails]) is assigned to whichever kept
   *  segment its own real sample time falls within, then re-tiled evenly
   *  across just that segment's own compacted rect — so segments with
   *  more sampled frames get proportionally more tiles, and a segment
   *  with none (very short, between two sample points) falls back to its
   *  nearest neighboring sample instead of a solid black gap — per the
   *  user's explicit "some splitted part is displaying in black color"
   *  report. */
  private fun drawCompactedThumbnails(canvas: Canvas, filmstripRect: RectF) {
    val totalKeptMs = segments.sumOf { it.last - it.first }
    if (totalKeptMs <= 0) return
    val tileCount = thumbnailTileCount.coerceAtLeast(1)
    var cursor = filmstripRect.left
    for (segment in segments) {
      val segmentPixelWidth = filmstripRect.width() * ((segment.last - segment.first).toFloat() / totalKeptMs)
      val segmentIndices = (0 until tileCount).filter { index ->
        val sampleTimeMs = (durationMs * (index + 0.5) / tileCount).toLong()
        sampleTimeMs >= segment.first && sampleTimeMs <= segment.last
      }
      if (segmentIndices.isNotEmpty()) {
        val tileWidth = segmentPixelWidth / segmentIndices.size
        for ((position, index) in segmentIndices.withIndex()) {
          val bitmap = thumbnails[index] ?: continue
          val tileRect = RectF(cursor + tileWidth * position, 0f, cursor + tileWidth * (position + 1), filmstripRect.height())
          drawAspectFilled(canvas, bitmap, tileRect)
        }
      } else {
        val midpointMs = (segment.first + segment.last) / 2
        val nearestIndex = (0 until tileCount).minByOrNull { index ->
          val sampleTimeMs = durationMs * (index + 0.5) / tileCount
          kotlin.math.abs(sampleTimeMs - midpointMs)
        }
        val bitmap = nearestIndex?.let { thumbnails[it] }
        if (bitmap != null) {
          val tileRect = RectF(cursor, 0f, cursor + segmentPixelWidth, filmstripRect.height())
          drawAspectFilled(canvas, bitmap, tileRect)
        }
      }
      cursor += segmentPixelWidth
    }
  }

  /** Crops (rather than stretches) [bitmap] to fill [destRect] without
   *  distorting its aspect ratio — a plain scaled `drawBitmap` would
   *  squeeze a 16:9 video frame into each tile's much narrower cell. */
  private fun drawAspectFilled(canvas: Canvas, bitmap: Bitmap, destRect: RectF) {
    if (bitmap.width <= 0 || bitmap.height <= 0) return
    val bitmapAspect = bitmap.width.toFloat() / bitmap.height
    val rectAspect = destRect.width() / destRect.height()
    val srcRect = if (bitmapAspect > rectAspect) {
      val srcWidth = (bitmap.height * rectAspect).toInt().coerceIn(1, bitmap.width)
      val left = (bitmap.width - srcWidth) / 2
      Rect(left, 0, left + srcWidth, bitmap.height)
    } else {
      val srcHeight = (bitmap.width / rectAspect).toInt().coerceIn(1, bitmap.height)
      val top = (bitmap.height - srcHeight) / 2
      Rect(0, top, bitmap.width, top + srcHeight)
    }
    canvas.drawBitmap(bitmap, srcRect, destRect, null)
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        val startX = if (isFilmstripStyle) filmstripXFor(segments.firstOrNull()?.first ?: 0L) else xFor(trimStartMs)
        val endX = if (isFilmstripStyle) filmstripXFor(segments.lastOrNull()?.last ?: durationMs) else xFor(trimEndMs)
        val startRadius = if (isFilmstripStyle) leftInsetPx else (plainHandleWidthPx / 2 + handleTouchSlopPx)
        val endRadius = if (isFilmstripStyle) rightInsetPx else (plainHandleWidthPx / 2 + handleTouchSlopPx)
        // An inactive filmstrip-style clip draws no handles at all (see
        // isActiveClip's own doc) — its own edges shouldn't be draggable
        // either, so a touch there just falls through as a plain
        // scrub/scroll touch like anywhere else on it.
        val handlesEnabled = !isFilmstripStyle || isActiveClip
        activeDrag = when {
          handlesEnabled && abs(event.x - startX) <= startRadius -> DragTarget.START
          handlesEnabled && abs(event.x - endX) <= endRadius -> DragTarget.END
          else -> DragTarget.SCRUB
        }
        if (activeDrag == DragTarget.START || activeDrag == DragTarget.END) {
          // Prevent an ancestor scrollable container (MediaEditorActivity's
          // filmstripScrollViewRef, once embedded in the Instagram-style
          // scrollable timeline) from intercepting this handle drag as
          // its own pan.
          parent?.requestDisallowInterceptTouchEvent(true)
          onHandleDragStateChanged?.invoke(true)
        } else if (isFilmstripStyle) {
          // Filmstrip style no longer scrubs via its own internal drag
          // once embedded in the scrollable timeline — returning false
          // here (see below) lets the touch fall through to the ancestor
          // scroll container's own panning instead. Only the plain
          // (music) style still scrubs directly. A touch that lands
          // within a specific kept segment (rather than becoming a pan)
          // ALSO selects that segment — see selectedSegmentIndex's own doc.
          val tappedIndex = segments.indexOfFirst { event.x >= filmstripXFor(it.first) && event.x <= filmstripXFor(it.last) }
          if (tappedIndex >= 0) {
            selectedSegmentIndex = tappedIndex
            performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)
            onSegmentSelected?.invoke(tappedIndex)
            invalidate()
          }
          return false
        } else {
          val scrubX = event.x.coerceIn(0f, width.toFloat())
          onScrub?.invoke(timeFor(scrubX))
        }
      }
      MotionEvent.ACTION_MOVE -> {
        val clampedX = event.x.coerceIn(0f, width.toFloat())
        val t = if (isFilmstripStyle) filmstripTimeFor(clampedX) else timeFor(clampedX)
        when (activeDrag) {
          DragTarget.START -> {
            if (isFilmstripStyle) {
              val first = segments.firstOrNull() ?: return true
              val maxStart = (first.last - minTrimDurationMs).coerceAtLeast(0)
              val newFirst = t.coerceIn(0, maxStart)..first.last
              segments = segments.toMutableList().apply { this[0] = newFirst }
              onSegmentsChanged?.invoke(segments)
            } else {
              val maxStart = (trimEndMs - minTrimDurationMs).coerceAtLeast(0)
              trimStartMs = t.coerceIn(0, maxStart)
              onTrimChanged?.invoke(trimStartMs, trimEndMs)
            }
          }
          DragTarget.END -> {
            if (isFilmstripStyle) {
              val last = segments.lastOrNull() ?: return true
              val minEnd = (last.first + minTrimDurationMs).coerceAtMost(durationMs)
              val newLast = last.first..t.coerceIn(minEnd, durationMs)
              segments = segments.toMutableList().apply { this[size - 1] = newLast }
              onSegmentsChanged?.invoke(segments)
            } else {
              val minEnd = (trimStartMs + minTrimDurationMs).coerceAtMost(durationMs)
              trimEndMs = t.coerceIn(minEnd, durationMs)
              onTrimChanged?.invoke(trimStartMs, trimEndMs)
            }
          }
          DragTarget.SCRUB -> if (!isFilmstripStyle) onScrub?.invoke(t)
          null -> return false
        }
        invalidate()
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        if (activeDrag == DragTarget.START || activeDrag == DragTarget.END) {
          onHandleDragStateChanged?.invoke(false)
        }
        activeDrag = null
      }
    }
    return true
  }

  private fun dp(value: Float): Float = value * resources.displayMetrics.density
}
