import AVFoundation
import UIKit

/// A horizontal timeline strip. Two visual styles share one class since
/// both the main video trim scrubber AND the music trim strip
/// (MediaEditorViewController's `musicTrimView`) are the same
/// `VideoTrimView` type:
///  - Plain style (default, used by music): dimmed background, a lighter
///    band for the current trim selection, two equal-sized yellow handle
///    bars, a playhead line. Drives `trimStart`/`trimEnd` + `onTrimChanged`,
///    a single kept range — music has no split/delete concept.
///  - Filmstrip style (opted into by calling `loadThumbnails`, used by the
///    main video scrubber only): real extracted video frame thumbnails
///    tiled edge-to-edge. Drives `segments`/`onSegmentsChanged` instead —
///    MULTIPLE kept ranges (per the user's explicit "split into parts,
///    delete any of them" request), each with its own rounded accent
///    border, portions outside ALL segments (both the outer trim and any
///    internal deleted gap) dimmed rather than hidden — matching the
///    native Photos/iMovie trim-tool look the user referenced directly.
///    Only the FIRST segment's start and the LAST segment's end are
///    draggable handles (the overall trim); internal split points are
///    fixed dividers in this pass, not independently adjustable — a
///    deliberate scope cut to keep touch handling tractable (see
///    `splitAtCurrentTime`/`deleteSegment`'s own docs for the full model).
/// Music has no video frames to extract, so it never calls
/// `loadThumbnails` and keeps the plain style/single-range API unchanged.
///
/// Dragging near an (outer) handle resizes the trim; dragging anywhere
/// else on the bar scrubs playback instead — "handles are the only
/// specific target, everywhere else falls to the other interaction," all
/// within one view (no second view underneath to fall through to here).
final class VideoTrimView: UIView {
  private(set) var duration: Double = 0
  // Plain-style API (music) — unchanged from before segments existed.
  private(set) var trimStart: Double = 0
  private(set) var trimEnd: Double = 0
  // Filmstrip-style API (video) — ordered, non-overlapping, ascending.
  // Always at least one element once `configureFullRange` has run.
  private(set) var segments: [ClosedRange<Double>] = []

  var currentTime: Double = 0 {
    didSet { setNeedsDisplay() }
  }

  /// True once one or more merged video clips (MediaEditorViewController's
  /// `mergedStripView`) are attached directly to this view's trailing edge
  /// with zero gap, forming one continuous filmstrip — squares off this
  /// view's own right-side corners (the overall filmstrip clip path AND
  /// the last kept segment's own border) so the two views' independently-
  /// rounded corners don't visibly double up into two separate pills at
  /// the seam. Default false (fully rounded) leaves the music trim view
  /// and the no-merged-clips video case pixel-identical to before.
  var squareTrailingCorners: Bool = false {
    didSet { setNeedsDisplay() }
  }

  /// Whether THIS clip (the primary) is the one currently under the
  /// playhead in MediaEditorViewController's combined multi-clip timeline
  /// — per the user's explicit Instagram reference ("highlighted video
  /// clip with yellow color only, display clip duration on that clip"),
  /// the yellow border/handles/duration-label now only show for whichever
  /// clip is ACTIVE, not every clip unconditionally. Defaults to true so
  /// a session with no merged clips at all (nothing else to compare
  /// against) stays pixel-identical to the original always-yellow look —
  /// only set to false by the controller once merged clips exist and a
  /// different one becomes active.
  var isActiveClip: Bool = true {
    didSet { setNeedsDisplay() }
  }

  /// Which kept segment the user last TAPPED (filmstrip style only) —
  /// shown with an added white border (see drawFilmstripStyle) and the
  /// target for `deleteSegment(at:)` — per the user's explicit "select a
  /// dedicated splitted portion... white border means selected
  /// portion... delete on click on delete icon" request, mirroring the
  /// identical selected-segment pattern already built for text/sticker/
  /// overlay layers (LayerRangeBarView). Cleared whenever the segment
  /// structure itself changes (split/delete) since indices can shift;
  /// NOT cleared by a plain handle drag (trimming the overall start/end
  /// doesn't change which index is which).
  private(set) var selectedSegmentIndex: Int?

  var onTrimChanged: ((Double, Double) -> Void)?
  var onSegmentsChanged: (([ClosedRange<Double>]) -> Void)?
  /// Fires whenever a segment gets tapped-selected (filmstrip style) —
  /// the owning VC uses this to deselect any currently-selected on-canvas
  /// layer, so Delete unambiguously targets whichever was tapped most
  /// recently (a video segment here, or a layer's own timeline row).
  var onSegmentSelected: ((Int) -> Void)?
  var onScrub: ((Double) -> Void)?
  /// Fires `true` when a HANDLE (start/end) drag begins and `false` when
  /// it ends — lets an ancestor UIScrollView (MediaEditorViewController's
  /// filmstripScrollView, once this view is embedded in the Instagram-
  /// style scrollable timeline) disable its own native panning for
  /// exactly the duration of a handle drag, so a trim-handle grab isn't
  /// stolen by the scroll view's default `touchesShouldCancelInContentView`
  /// behavior. A plain body drag (no handle) is deliberately NOT reported
  /// here — that's meant to fall through to the scroll view's own
  /// panning (scrubbing IS scrolling in that context) rather than firing
  /// onScrub, which is why isFilmstripStyle's own scrub case below is a
  /// no-op; only the plain (music) style still uses onScrub directly.
  var onHandleDragStateChanged: ((Bool) -> Void)?

  private let handleTouchSlop: CGFloat = 16
  // Filmstrip style's handle is a slimmer grip than plain style's, so a
  // tighter slop still leaves it comfortably grabbable while giving more
  // of the strip's own width back to the visible thumbnails, per the
  // user's explicit "reduce this space" follow-up.
  private let filmstripHandleTouchSlop: CGFloat = 6
  private let minTrimDuration: Double = 2.0
  // Splitting an existing (already-split, possibly short) segment used
  // minTrimDuration too — meaning a segment shorter than 4s (2 * 2.0)
  // could never be split again, no matter where you tapped, since no
  // valid split point could leave both halves >= 2.0s. Per the user's
  // explicit "I've already split it into many parts and then I can't
  // split that split video, why?" report: a SEPARATE, smaller minimum
  // just for splitting (matching the 0.5s convention already used for
  // layer-segment splits elsewhere in MediaEditorViewController) lets
  // splitting keep working on much shorter pieces, while minTrimDuration
  // itself still governs the overall trim handles (unrelated concern —
  // how short the WHOLE kept clip can shrink via dragging the outer
  // edges), left unchanged.
  private let minSplitSegmentDuration: Double = 0.5

  // Plain-style-only sizing.
  private let plainHandleWidth: CGFloat = 10
  // Filmstrip-style-only sizing. Both outer handles are the SAME
  // vertical-grip shape/size — originally the right handle was a bigger
  // rounded square with a chevron, but the user asked for the chevron
  // gone and then for the right handle to match the left one exactly,
  // "so it will look the same."
  private let cornerRadius: CGFloat = 10
  // Thin selected/active border (was 2.5).
  private let borderWidth: CGFloat = 1.5
  private let filmstripHandleWidth: CGFloat = 6
  // Width of the fixed divider drawn at each INTERNAL split point (not a
  // draggable handle, just a visual gap so two adjacent kept segments
  // still read as separate pieces).
  private let splitDividerWidth: CGFloat = 4

  // A handle's full touch target must fit on-screen at BOTH extremes —
  // mapping time 0/duration flush to the view's own x=0/width leaves half
  // of each handle's touch target outside the view's bounds and
  // effectively ungrabbable — fixed by insetting the coordinate mapping
  // itself, not just the starting values.
  private let horizontalInset: CGFloat = 24

  // Filmstrip style: no inset, so time 0 sits exactly on the timeline's
  // playhead line (matches LayerRangeBarView and the scroll math).
  private var leftInset: CGFloat {
    isFilmstripStyle ? 0 : horizontalInset
  }

  private var rightInset: CGFloat {
    isFilmstripStyle ? 0 : horizontalInset
  }

  private enum DragTarget: Equatable { case start, end, scrub }
  private var activeDrag: DragTarget?

  private var isFilmstripStyle = false
  // Keyed by tile index rather than a plain array, since thumbnails arrive
  // one at a time (each its own AVAssetImageGenerator request) and may
  // complete out of order.
  private var thumbnails: [Int: UIImage] = [:]
  private var thumbnailTileCount = 0
  private var thumbnailGeneration = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Called once duration becomes known (from setUpVideoPlayer) — defaults
  /// the trim selection to the full clip. Updates BOTH the plain-style
  /// (`trimStart`/`trimEnd`) and filmstrip-style (`segments`) state, since
  /// the caller doesn't know which style this instance is in.
  func configureFullRange(duration: Double) {
    self.duration = duration
    trimStart = 0
    trimEnd = duration
    segments = [0...duration]
    setNeedsDisplay()
  }

  /// Splits whichever kept segment contains `time` into two segments at
  /// that exact point — the video-editing "split at playhead" action.
  /// No-ops (returns false) if `time` isn't strictly inside a kept
  /// segment (e.g. it's already exactly at a split point, or it falls in
  /// an already-deleted gap) or if either resulting half would be
  /// shorter than `minTrimDuration`.
  @discardableResult
  func splitAtCurrentTime(_ time: Double) -> Bool {
    guard let index = segments.firstIndex(where: { $0.lowerBound < time && time < $0.upperBound }) else { return false }
    let segment = segments[index]
    guard time - segment.lowerBound >= minSplitSegmentDuration, segment.upperBound - time >= minSplitSegmentDuration else { return false }
    segments.replaceSubrange(index...index, with: [segment.lowerBound...time, time...segment.upperBound])
    selectedSegmentIndex = nil
    onSegmentsChanged?(segments)
    setNeedsDisplay()
    return true
  }

  /// Removes whichever kept segment contains `time` — the video-editing
  /// "delete this part" action. Refuses (returns false) to delete the
  /// only remaining segment, since an empty timeline has nothing left to
  /// preview/export.
  @discardableResult
  func deleteSegment(containing time: Double) -> Bool {
    guard segments.count > 1, let index = segments.firstIndex(where: { $0.contains(time) }) else { return false }
    segments.remove(at: index)
    selectedSegmentIndex = nil
    onSegmentsChanged?(segments)
    setNeedsDisplay()
    return true
  }

  /// Removes segment `index` specifically — the counterpart to
  /// `deleteSegment(containing:)` for when the user has explicitly
  /// TAPPED a portion (`selectedSegmentIndex`) rather than scrubbed to
  /// one. Same "refuse to delete the only remaining segment" guard.
  /// Clears the tapped-segment selection without deleting anything —
  /// called by the owning VC when focus moves elsewhere (a layer gets
  /// selected instead), so this row's own white selected-border doesn't
  /// linger on a segment that's no longer the actual delete target.
  func clearSegmentSelection() {
    guard selectedSegmentIndex != nil else { return }
    selectedSegmentIndex = nil
    setNeedsDisplay()
  }

  @discardableResult
  func deleteSegment(at index: Int) -> Bool {
    guard segments.count > 1, segments.indices.contains(index) else { return false }
    segments.remove(at: index)
    selectedSegmentIndex = nil
    onSegmentsChanged?(segments)
    setNeedsDisplay()
    return true
  }

  private func x(for time: Double) -> CGFloat {
    let usableWidth = bounds.width - leftInset - rightInset
    guard duration > 0, usableWidth > 0 else { return leftInset }
    return leftInset + CGFloat(time / duration) * usableWidth
  }

  private func time(for x: CGFloat) -> Double {
    let usableWidth = bounds.width - leftInset - rightInset
    guard usableWidth > 0 else { return 0 }
    let clamped = min(max(x - leftInset, 0), usableWidth)
    return Double(clamped / usableWidth) * duration
  }

  /// Maps a REAL time to a pixel X assuming every kept segment is packed
  /// back-to-back with NO gap for any cut-away portion (leading, internal,
  /// or trailing) — used only when `squareTrailingCorners` is true, per
  /// the user's explicit "remove these unused and trimmed out portion...
  /// look attached" request. A deliberate, accepted trade-off of this
  /// mode: since no pixels are ever reserved for cut-away footage, once
  /// an edge is trimmed inward there is no more on-screen space to drag
  /// it back out again — recovering that footage needs a fresh edit, not
  /// a drag. `time` values inside an (invisible) cut-away gap clamp to
  /// that gap's nearest edge, so a fleeting real-time value (e.g. the
  /// playhead mid gap-skip) still lands somewhere sane.
  private func xCompacted(for time: Double) -> CGFloat {
    let filmstripWidth = bounds.width - leftInset - rightInset
    let totalKept = segments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
    guard totalKept > 0, filmstripWidth > 0 else { return leftInset }
    var compactedElapsed: Double = 0
    for segment in segments {
      if time < segment.lowerBound { break }
      compactedElapsed += max(0, min(time, segment.upperBound) - segment.lowerBound)
      if time <= segment.upperBound { break }
    }
    return leftInset + CGFloat(compactedElapsed / totalKept) * filmstripWidth
  }

  /// Inverse of `xCompacted` — maps a pixel X (in the compacted, gaps-
  /// removed space that function draws) back to the REAL time within
  /// whichever kept segment that position falls in.
  private func realTimeForCompacted(_ x: CGFloat) -> Double {
    let filmstripWidth = bounds.width - leftInset - rightInset
    let totalKept = segments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
    guard totalKept > 0, filmstripWidth > 0 else { return 0 }
    let clampedX = min(max(x - leftInset, 0), filmstripWidth)
    var remaining = Double(clampedX / filmstripWidth) * totalKept
    for segment in segments {
      let segmentLength = segment.upperBound - segment.lowerBound
      if remaining <= segmentLength {
        return segment.lowerBound + remaining
      }
      remaining -= segmentLength
    }
    return segments.last?.upperBound ?? duration
  }

  /// Whether cut-away portions should be compacted OUT of the timeline
  /// entirely (no pixels reserved for them) rather than shown as a
  /// dimmed gap. Originally only true when a merged clip is attached
  /// (`squareTrailingCorners`) — extended to ALSO cover any split primary
  /// clip (more than one kept segment) per the user's explicit "i have
  /// deleted these gray out portion... immediately there gray out
  /// portion should be removed quickly because we have deleted these so
  /// video should be play in proper manner" report: the dimmed-gap look
  /// was a deliberate native-Photos/iMovie-style choice from an earlier
  /// round, but the user now wants deleted footage to visibly disappear,
  /// not linger dimmed. `squareTrailingCorners` itself is UNCHANGED and
  /// still separately governs corner-rounding (the merged-clip seam) —
  /// this only changes which pixel-mapping/thumbnail-tiling strategy is
  /// used.
  ///
  /// Also true whenever the kept segments no longer cover the FULL
  /// original duration, even down to a single remaining segment — per
  /// the user's explicit "split the ending part and delete it, the
  /// trimmed portion is still empty/greyed out" report: splitting into 2
  /// segments then deleting one drops `segments.count` back to 1, which
  /// used to fall straight back to the plain (non-compacted) mapping —
  /// exactly the single most common case (trim off the end and delete
  /// it), silently letting the just-deleted tail reappear as blank space
  /// instead of being cropped away.
  private var shouldCompactGaps: Bool {
    if squareTrailingCorners || segments.count > 1 { return true }
    let totalKept = segments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
    return totalKept < duration - 0.01
  }

  /// Picks the compacted or plain mapping depending on shouldCompactGaps
  /// — every filmstrip-style call site (drawing AND touch) goes through
  /// this pair rather than branching individually, so the two mappings
  /// can never drift out of sync between what's drawn and what's touched.
  private func filmstripX(for time: Double) -> CGFloat {
    shouldCompactGaps ? xCompacted(for: time) : x(for: time)
  }

  private func filmstripTime(for x: CGFloat) -> Double {
    shouldCompactGaps ? realTimeForCompacted(x) : time(for: x)
  }

  /// Restores a specific previously-chosen trim (e.g. reopening a merged
  /// clip's own dedicated trim screen) instead of the full-range default
  /// `configureFullRange` already set — purely additive, doesn't change
  /// that method's own existing behavior for the primary clip's scrubber.
  func restoreSegments(_ segments: [ClosedRange<Double>]) {
    guard !segments.isEmpty else { return }
    self.segments = segments
    trimStart = segments.first?.lowerBound ?? trimStart
    trimEnd = segments.last?.upperBound ?? trimEnd
    setNeedsDisplay()
  }

  /// Extracts `tileCount` evenly-spaced frames from `asset` and tiles them
  /// across the strip as they arrive — the "real extracted thumbnails, not
  /// placeholder blocks" the reference image shows. Switches this instance
  /// into filmstrip style; only the main video scrubber calls this.
  ///
  /// Each tile is its own `generateCGImagesAsynchronously` call (rather
  /// than one batched request) so a completed frame can be matched back
  /// to its tile index via closure capture, with no need to reconcile
  /// requested-vs-returned CMTime values. `thumbnailGeneration` guards
  /// against a stale reload (e.g. re-opening a different video) racing an
  /// in-flight one.
  func loadThumbnails(from asset: AVAsset, tileCount: Int = 8) {
    isFilmstripStyle = true
    thumbnailTileCount = tileCount
    thumbnails = [:]
    thumbnailGeneration += 1
    let generation = thumbnailGeneration
    Task { [weak self] in
      guard let self, let loadedDuration = try? await asset.load(.duration) else { return }
      let seconds = CMTimeGetSeconds(loadedDuration)
      guard seconds.isFinite, seconds > 0 else { return }
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 240, height: 240)
      for index in 0..<tileCount {
        // Frame sampled from the CENTER of each tile's time slice (not its
        // leading edge) — a more representative preview of that slice.
        let time = CMTime(
          seconds: seconds * (Double(index) + 0.5) / Double(tileCount),
          preferredTimescale: 600
        )
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, cgImage, _, _, _ in
          guard let self, let cgImage, generation == self.thumbnailGeneration else { return }
          let image = UIImage(cgImage: cgImage)
          DispatchQueue.main.async {
            guard generation == self.thumbnailGeneration else { return }
            self.thumbnails[index] = image
            self.setNeedsDisplay()
          }
        }
      }
    }
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    if isFilmstripStyle {
      drawFilmstripStyle(in: ctx)
    } else {
      drawPlainStyle(in: ctx)
    }
  }

  private func drawPlainStyle(in ctx: CGContext) {
    // Rounded container (matching the card it sits in) so the bar reads as
    // one cohesive control rather than a flat, decorative rectangle.
    ctx.saveGState()
    ctx.addPath(UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath)
    ctx.clip()

    ctx.setFillColor(UIColor.white.withAlphaComponent(0.25).cgColor)
    ctx.fill(bounds)

    let startX = x(for: trimStart)
    let endX = x(for: trimEnd)
    ctx.setFillColor(UIColor.white.withAlphaComponent(0.6).cgColor)
    ctx.fill(CGRect(x: startX, y: 0, width: endX - startX, height: bounds.height))
    ctx.restoreGState()

    // Handles drawn as rounded, vertically-inset "grip" pills — matching
    // the main video trim's own filmstrip-style handles — instead of
    // full-height rectangles. Per the user's "didn't realize those were
    // draggable handles" report: a thin bar spanning the full height reads
    // as a plain divider/marker, not an interactive control.
    ctx.setFillColor(EditorDesignTokens.Colors.trimHandle.cgColor)
    let handleHeight = bounds.height * 0.7
    let handleY = (bounds.height - handleHeight) / 2
    let startHandleRect = CGRect(x: startX - plainHandleWidth / 2, y: handleY, width: plainHandleWidth, height: handleHeight)
    ctx.addPath(UIBezierPath(roundedRect: startHandleRect, cornerRadius: plainHandleWidth / 2).cgPath)
    ctx.fillPath()
    let endHandleRect = CGRect(x: endX - plainHandleWidth / 2, y: handleY, width: plainHandleWidth, height: handleHeight)
    ctx.addPath(UIBezierPath(roundedRect: endHandleRect, cornerRadius: plainHandleWidth / 2).cgPath)
    ctx.fillPath()

    let playheadX = x(for: currentTime)
    ctx.setFillColor(UIColor.white.cgColor)
    ctx.fill(CGRect(x: playheadX - 1, y: 0, width: 2, height: bounds.height))
  }

  private func drawFilmstripStyle(in ctx: CGContext) {
    let filmstripRect = CGRect(x: leftInset, y: 0, width: bounds.width - leftInset - rightInset, height: bounds.height)
    guard filmstripRect.width > 0, !segments.isEmpty else { return }

    ctx.saveGState()
    let filmstripPath = squareTrailingCorners
      ? UIBezierPath(roundedRect: filmstripRect, byRoundingCorners: [.topLeft, .bottomLeft], cornerRadii: CGSize(width: cornerRadius, height: cornerRadius))
      : UIBezierPath(roundedRect: filmstripRect, cornerRadius: cornerRadius)
    ctx.addPath(filmstripPath.cgPath)
    ctx.clip()

    ctx.setFillColor(UIColor.black.cgColor)
    ctx.fill(filmstripRect)

    if shouldCompactGaps {
      drawCompactedThumbnails(in: ctx, filmstripRect: filmstripRect)
    } else {
      let tileCount = max(thumbnailTileCount, 1)
      let tileWidth = filmstripRect.width / CGFloat(tileCount)
      for index in 0..<tileCount {
        guard let image = thumbnails[index] else { continue }
        let tileRect = CGRect(x: filmstripRect.minX + tileWidth * CGFloat(index), y: 0, width: tileWidth, height: bounds.height)
        Self.drawAspectFilled(image, in: tileRect, context: ctx)
      }

      // Dim every gap NOT covered by a kept segment — before the first
      // segment, after the last, and any internal deleted gap — matching
      // the native Photos/iMovie convention of always showing the full
      // filmstrip with cut-away portions darkened rather than hidden.
      // Only when NOT attached to a merged clip — see
      // drawCompactedThumbnails's own doc for why attached mode instead
      // removes cut-away portions entirely rather than dimming them.
      ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
      var cursor = filmstripRect.minX
      for segment in segments {
        let segStartX = x(for: segment.lowerBound)
        let segEndX = x(for: segment.upperBound)
        if segStartX > cursor {
          ctx.fill(CGRect(x: cursor, y: 0, width: segStartX - cursor, height: bounds.height))
        }
        cursor = segEndX
      }
      if cursor < filmstripRect.maxX {
        ctx.fill(CGRect(x: cursor, y: 0, width: filmstripRect.maxX - cursor, height: bounds.height))
      }
    }
    ctx.restoreGState()

    // Thin fixed dividers at INTERNAL split points — not draggable
    // handles, just a visual seam indicating the primary clip's own
    // structure, shown regardless of active state.
    ctx.setFillColor(UIColor.black.cgColor)
    for segment in segments.dropLast() {
      let dividerX = filmstripX(for: segment.upperBound)
      ctx.fill(CGRect(x: dividerX - splitDividerWidth / 2, y: 0, width: splitDividerWidth, height: bounds.height))
    }

    // Each kept segment's own border, the outer draggable handles, and
    // the duration label are gated on isActiveClip — per the user's
    // explicit Instagram-reference request, only the clip currently
    // under the playhead shows this highlight; an inactive primary clip
    // (once merged clips exist and one of THEM is active) shows a plain
    // thumbnail-only strip instead. Only the FIRST segment's start and
    // the LAST segment's end are draggable (the overall trim); internal
    // split points have no handle of their own in this pass.
    if isActiveClip {
      ctx.setStrokeColor(EditorDesignTokens.Colors.trimHandle.cgColor)
      ctx.setLineWidth(borderWidth)
      for (index, segment) in segments.enumerated() {
        let segRect = CGRect(x: filmstripX(for: segment.lowerBound), y: 0, width: filmstripX(for: segment.upperBound) - filmstripX(for: segment.lowerBound), height: bounds.height)
          .insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        // Only the LAST segment's right side ever touches the
        // merged-clips strip — earlier segments' right sides are the
        // internal split dividers above and stay fully rounded.
        let isLastSegment = index == segments.count - 1
        let segPath = (isLastSegment && squareTrailingCorners)
          ? UIBezierPath(roundedRect: segRect, byRoundingCorners: [.topLeft, .bottomLeft], cornerRadii: CGSize(width: cornerRadius, height: cornerRadius))
          : UIBezierPath(roundedRect: segRect, cornerRadius: cornerRadius)
        ctx.addPath(segPath.cgPath)
        ctx.strokePath()
      }

      // The specifically TAPPED segment (see selectedSegmentIndex's own
      // doc) gets an ADDITIONAL white border on top of its own yellow
      // one — per the user's explicit "white border means selected
      // portion" request, mirroring the identical selected-state look
      // already used for text/sticker/overlay layers. Layered on top,
      // not replacing the yellow one, since that separately signals
      // "this whole clip is the active one" (relevant once merged clips
      // exist) — an unrelated concept from "this specific portion is
      // selected."
      if let selectedSegmentIndex, segments.indices.contains(selectedSegmentIndex) {
        let segment = segments[selectedSegmentIndex]
        let segRect = CGRect(
          x: filmstripX(for: segment.lowerBound), y: 0,
          width: filmstripX(for: segment.upperBound) - filmstripX(for: segment.lowerBound), height: bounds.height
        ).insetBy(dx: borderWidth, dy: borderWidth)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(borderWidth)
        ctx.addPath(UIBezierPath(roundedRect: segRect, cornerRadius: max(0, cornerRadius - borderWidth)).cgPath)
        ctx.strokePath()
      }

      ctx.setFillColor(EditorDesignTokens.Colors.trimHandle.cgColor)
      let startX = filmstripX(for: segments.first!.lowerBound)
      let endX = filmstripX(for: segments.last!.upperBound)
      let leftHandleRect = CGRect(x: startX - filmstripHandleWidth / 2, y: bounds.height * 0.2, width: filmstripHandleWidth, height: bounds.height * 0.6)
      ctx.addPath(UIBezierPath(roundedRect: leftHandleRect, cornerRadius: filmstripHandleWidth / 2).cgPath)
      ctx.fillPath()
      let rightHandleRect = CGRect(x: endX - filmstripHandleWidth / 2, y: bounds.height * 0.2, width: filmstripHandleWidth, height: bounds.height * 0.6)
      ctx.addPath(UIBezierPath(roundedRect: rightHandleRect, cornerRadius: filmstripHandleWidth / 2).cgPath)
      ctx.fillPath()

      // Duration label ("12.3s") — only once merged clips exist (matching
      // the reference, which only labels clips in a multi-clip context);
      // a lone, no-merge primary clip stays exactly as it always has.
      if squareTrailingCorners {
        let keptSeconds = segments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        let text = String(format: "%.1fs", keptSeconds)
        let attributes: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
          .foregroundColor: UIColor.white,
        ]
        text.draw(at: CGPoint(x: startX + 6, y: 4), withAttributes: attributes)
      }
    }
  }

  /// Tiles thumbnails within EACH kept segment's own compacted pixel span
  /// only (no gap reserved before/between/after segments) — the filmstrip-
  /// style counterpart to the plain style's even-across-full-width tiling,
  /// used whenever shouldCompactGaps is true. Each of the pre-sampled
  /// `thumbnails` (evenly spaced across the FULL real duration, from
  /// `loadThumbnails`) is assigned to whichever kept segment its own real
  /// sample time falls within, then re-tiled evenly across just that
  /// segment's own compacted rect — so segments with more sampled frames
  /// get proportionally more tiles, and a segment with none (very short,
  /// between two sample points) falls back to its nearest neighboring
  /// sample instead of a solid black gap — per the user's explicit "some
  /// splitted part is displaying in black color" report.
  private func drawCompactedThumbnails(in ctx: CGContext, filmstripRect: CGRect) {
    let totalKept = segments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
    guard totalKept > 0 else { return }
    let tileCount = max(thumbnailTileCount, 1)
    var cursor = filmstripRect.minX
    for segment in segments {
      let segmentPixelWidth = filmstripRect.width * CGFloat((segment.upperBound - segment.lowerBound) / totalKept)
      let segmentIndices = (0..<tileCount).filter { index in
        let sampleTime = duration * (Double(index) + 0.5) / Double(tileCount)
        return sampleTime >= segment.lowerBound && sampleTime <= segment.upperBound
      }
      if !segmentIndices.isEmpty {
        let tileWidth = segmentPixelWidth / CGFloat(segmentIndices.count)
        for (position, index) in segmentIndices.enumerated() {
          guard let image = thumbnails[index] else { continue }
          let tileRect = CGRect(x: cursor + tileWidth * CGFloat(position), y: 0, width: tileWidth, height: filmstripRect.height)
          Self.drawAspectFilled(image, in: tileRect, context: ctx)
        }
      } else {
        // No sample point fell within this segment (very short, typically
        // from repeated splitting) — per the user's explicit "some
        // splitted part is displaying in black color" report, fall back
        // to whichever thumbnail sample is nearest in TIME to this
        // segment's own midpoint, stretched across its full rect, instead
        // of leaving a solid black gap.
        let midpoint = (segment.lowerBound + segment.upperBound) / 2
        let nearestIndex = (0..<tileCount).min(by: { a, b in
          let sampleA = duration * (Double(a) + 0.5) / Double(tileCount)
          let sampleB = duration * (Double(b) + 0.5) / Double(tileCount)
          return abs(sampleA - midpoint) < abs(sampleB - midpoint)
        })
        if let nearestIndex, let image = thumbnails[nearestIndex] {
          let tileRect = CGRect(x: cursor, y: 0, width: segmentPixelWidth, height: filmstripRect.height)
          Self.drawAspectFilled(image, in: tileRect, context: ctx)
        }
      }
      cursor += segmentPixelWidth
    }
  }

  /// Crops (rather than stretches) `image` to fill `rect` without
  /// distorting its aspect ratio — a plain `draw(in:)` would squeeze a
  /// 16:9 video frame into each tile's much narrower cell.
  private static func drawAspectFilled(_ image: UIImage, in rect: CGRect, context ctx: CGContext) {
    guard image.size.width > 0, image.size.height > 0 else { return }
    let imageAspect = image.size.width / image.size.height
    let rectAspect = rect.width / rect.height
    var drawRect = rect
    if imageAspect > rectAspect {
      let scaledWidth = rect.height * imageAspect
      drawRect = CGRect(x: rect.midX - scaledWidth / 2, y: rect.minY, width: scaledWidth, height: rect.height)
    } else {
      let scaledHeight = rect.width / imageAspect
      drawRect = CGRect(x: rect.minX, y: rect.midY - scaledHeight / 2, width: rect.width, height: scaledHeight)
    }
    ctx.saveGState()
    ctx.clip(to: rect)
    image.draw(in: drawRect)
    ctx.restoreGState()
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    let point = touch.location(in: self)
    let startX = isFilmstripStyle ? filmstripX(for: segments.first?.lowerBound ?? 0) : x(for: trimStart)
    let endX = isFilmstripStyle ? filmstripX(for: segments.last?.upperBound ?? duration) : x(for: trimEnd)
    let startRadius = isFilmstripStyle ? leftInset : (plainHandleWidth / 2 + handleTouchSlop)
    let endRadius = isFilmstripStyle ? rightInset : (plainHandleWidth / 2 + handleTouchSlop)
    // An inactive filmstrip-style clip draws no handles at all (see
    // isActiveClip's own doc) — its own edges shouldn't be draggable
    // either, so a touch there just falls through as a plain scrub/scroll
    // touch like anywhere else on it.
    let handlesEnabled = !isFilmstripStyle || isActiveClip

    if handlesEnabled, abs(point.x - startX) <= startRadius {
      activeDrag = .start
      onHandleDragStateChanged?(true)
    } else if handlesEnabled, abs(point.x - endX) <= endRadius {
      activeDrag = .end
      onHandleDragStateChanged?(true)
    } else {
      activeDrag = .scrub
      // Filmstrip style no longer scrubs via its own internal drag once
      // embedded in the scrollable timeline — that touch is meant to
      // fall through to the ancestor scroll view's own panning instead
      // (see onHandleDragStateChanged's own doc). Only the plain (music)
      // style still scrubs directly here. A filmstrip-style touch that
      // isn't a scroll (i.e. lands within a specific segment rather than
      // becoming a pan) instead SELECTS that segment — see
      // selectedSegmentIndex's own doc.
      if !isFilmstripStyle {
        onScrub?(time(for: point.x))
      } else if let index = segments.firstIndex(where: { point.x >= filmstripX(for: $0.lowerBound) && point.x <= filmstripX(for: $0.upperBound) }) {
        selectedSegmentIndex = index
        UISelectionFeedbackGenerator().selectionChanged()
        onSegmentSelected?(index)
        setNeedsDisplay()
      }
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first, let activeDrag else { return }
    let point = touch.location(in: self)
    let clampedX = min(max(point.x, 0), bounds.width)
    let t = isFilmstripStyle ? filmstripTime(for: clampedX) : time(for: clampedX)

    switch activeDrag {
    case .start:
      if isFilmstripStyle {
        guard var first = segments.first else { return }
        let maxStart = first.upperBound - minTrimDuration
        first = max(0, min(t, maxStart))...first.upperBound
        segments[0] = first
        onSegmentsChanged?(segments)
      } else {
        trimStart = max(0, min(t, trimEnd - minTrimDuration))
        onTrimChanged?(trimStart, trimEnd)
      }
    case .end:
      if isFilmstripStyle {
        guard var last = segments.last else { return }
        let minEnd = last.lowerBound + minTrimDuration
        last = last.lowerBound...min(duration, max(t, minEnd))
        segments[segments.count - 1] = last
        onSegmentsChanged?(segments)
      } else {
        trimEnd = min(duration, max(t, trimStart + minTrimDuration))
        onTrimChanged?(trimStart, trimEnd)
      }
    case .scrub:
      if !isFilmstripStyle {
        onScrub?(t)
      }
    }
    setNeedsDisplay()
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    if activeDrag == .start || activeDrag == .end {
      onHandleDragStateChanged?(false)
    }
    activeDrag = nil
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    if activeDrag == .start || activeDrag == .end {
      onHandleDragStateChanged?(false)
    }
    activeDrag = nil
  }
}
