import UIKit

/// One row's draggable bar in the Layers panel — ALL layers of one type
/// (text, sticker, or overlay) share a SINGLE bar/row now, each drawn as
/// its own colored range within [0, duration] and independently
/// draggable, per the user's explicit "for multiple emojis multiple
/// layer will not be created, all images will be in single layer one by
/// one... same for text" correction (previously each layer got its own
/// row — see git history/prior doc). Dragging an EDGE resizes that side
/// only (extend/reduce) — the user's explicit "drag to extend and
/// reduce... just like Instagram" request. Dragging an item's BODY used
/// to move its whole range, but that was removed once this bar got
/// embedded in the shared scrollable timeline — a body-drag is now
/// indistinguishable from "swipe to scroll the timeline," and letting
/// this view claim the touch was silently rescheduling whichever layer's
/// bar it landed on (see touchesBegan's own doc). Coordinate-mapping/
/// touch-radius approach mirrors `VideoTrimView`'s proven plain-style
/// geometry.
final class LayerRangeBarView: UIView {
  struct Item {
    let id: ObjectIdentifier
    var rangeStart: Double
    var rangeEnd: Double
    let color: UIColor
    let label: String
    // Which of `id`'s own segments this is, when a layer has been split
    // into more than one (see MediaEditorViewController's
    // `LayerTiming.segments` / didTapSplitSegment) — 0 for every
    // never-split layer, and for merged-clip/music items, which have
    // exactly one segment each and never split. Distinguishes "segment 2
    // of layer X" from "segment 1 of layer X" for selection/dragging
    // purposes, since both share the SAME `id` (the underlying view
    // never changes — splitting divides its TIME, not the view itself).
    var segmentIndex: Int = 0
    // Merged-video-clip rows (see MediaEditorViewController's
    // makeAdditionalClipsRow) draw the clip's own real frames instead of a
    // flat color fill — per the user's explicit "display full video on
    // layers" request. Text/Sticker/Overlay rows never set this, so their
    // existing flat-color-plus-label look is completely unchanged.
    // Evenly time-sampled across THIS item's own real segment range (see
    // MediaEditorViewController's tilesForMergedClipSegment) and tiled
    // left-to-right across this item's own bar width, exactly like
    // VideoTrimView's primary-clip filmstrip — replaces a single frame
    // that used to get aspect-cropped across the WHOLE item regardless of
    // how wide it was or which real moment(s) it actually spanned, per
    // the user's explicit "thumbnail should not look zoomed... show
    // thumbnail up to exact same real timing of video clip" report.
    var thumbnailTiles: [UIImage] = []
    // Whether THIS item is the one currently under the playhead in
    // MediaEditorViewController's combined multi-clip timeline — per the
    // user's explicit Instagram-reference request, only the ACTIVE merged
    // clip shows the yellow border/handles/duration-label; others show a
    // plain thumbnail only. Text/Sticker/Overlay items never set this
    // (always false, no visible effect there).
    var isActive: Bool = false
    // Pre-formatted duration text ("12.3s") shown on this item only while
    // isActive — nil for Text/Sticker/Overlay items.
    var durationLabel: String? = nil
    // Edits-style layers: a small type badge at the bar's left edge — a
    // white SF Symbol (text/music), the sticker itself, or the photo
    // (`badgeFillsTile`, cropped to fill the square).
    var badge: UIImage? = nil
    var badgeFillsTile: Bool = false
    /// Per-layer hide: the bar is drawn faded.
    var isDimmed: Bool = false
    /// Small white symbols (hidden / locked) drawn at the bar's right end.
    var statusIcons: [UIImage] = []
    /// Beat sync: beat times (same time axis as rangeStart) drawn as dots.
    var markers: [Double] = []
  }

  private(set) var duration: Double = 1
  private(set) var items: [Item] = []

  /// (id, segmentIndex, newStart, newEnd) — segmentIndex identifies WHICH
  /// of `id`'s own segments changed, see Item.segmentIndex's own doc.
  var onRangeChanged: ((ObjectIdentifier, Int, Double, Double) -> Void)?
  /// Fires when the user taps/drags an item — lets the owning VC select
  /// that layer on the canvas (showing its Delete/Duplicate/Edit toolbar)
  /// AND record which of its own segments (if split) is now the target
  /// for Split/Delete, so this bar's own drag-to-trim handles and the
  /// canvas's own delete affordance stay in sync about which layer/
  /// segment is "active".
  var onItemSelected: ((ObjectIdentifier, Int) -> Void)?
  /// Fires once when an active drag ends (touch up/cancelled) — additive,
  /// only needed by callers that want to defer expensive work (e.g.
  /// rebuilding a playback queue) until the drag settles rather than
  /// doing it on every onRangeChanged tick. Existing Text/Sticker/Overlay
  /// rows don't set this and are unaffected.
  var onDragEnded: (() -> Void)?
  /// Fires `true` when a HANDLE (start/end) drag begins and `false` when
  /// it ends — mirrors VideoTrimView's identical callback, letting an
  /// ancestor UIScrollView (MediaEditorViewController's
  /// filmstripScrollView) disable its own native panning for exactly the
  /// duration of a handle drag, once this bar is embedded in the
  /// Instagram-style scrollable timeline. Existing Text/Sticker/Overlay
  /// rows don't set this and are unaffected.
  var onHandleDragStateChanged: ((Bool) -> Void)?
  /// When false, a long-press just SELECTS the tapped item instead of
  /// entering reorder mode — for rows where reordering makes no sense
  /// (the music row: every segment shares the SAME `id`, so there's
  /// nothing to reorder against). Defaults to true so Text/Sticker/
  /// Overlay/merged-clip rows are completely unaffected.
  var reorderEnabled: Bool = true
  /// True ONLY for MediaEditorViewController's `mergedStripView` — that
  /// instance is positioned with zero gap directly against VideoTrimView's
  /// own (squareTrailingCorners) right edge, forming one continuous
  /// filmstrip, so it needs a matching black background (not the generic
  /// elevatedSurface used by Text/Sticker/Overlay rows) and a squared-off
  /// leading corner on its FIRST item only (so that one item doesn't show
  /// a rounded pill right at the seam). Text/Sticker/Overlay rows never
  /// set this and are completely unaffected.
  var isMergedClipsContinuation: Bool = false {
    didSet { setNeedsDisplay() }
  }
  private var selectedItemId: ObjectIdentifier?
  private var selectedSegmentIndex: Int?

  /// True ONLY for the dedicated music row — per the user's explicit
  /// "add one dedicated layer of music... user can scroll and drag to
  /// change position" request, dragging an item's BODY shifts its whole
  /// range (both edges by the same delta) instead of falling through to
  /// the ancestor scroll view. Text/Sticker/Overlay rows stay false
  /// (unaffected) — body-drag was deliberately removed from THEM earlier
  /// this session; re-enabling it only for music (which has exactly one
  /// item, so there's no overlap ambiguity) avoids reintroducing that bug.
  var allowBodyDrag: Bool = false
  /// Layer rows: the body moves the layer in time only once that item is
  /// SELECTED — so a swipe on an unselected layer still scrolls the
  /// timeline, and holding still on any layer still reorders it.
  var bodyDragRequiresSelection: Bool = false
  /// False ONLY for the music row — its duration is controlled entirely
  /// by the Music panel's own trim view (which portion of the song
  /// plays); this row exists purely to reposition WHEN it plays.
  var edgeDragEnabled: Bool = true
  /// Times a dragged edge snaps to (other tracks' starts / ends, the
  /// playhead, clip cuts), excluding the dragged item's own (id, segment).
  /// Within ~8pt the edge locks onto the time with a light haptic, like
  /// CapCut / Edits. nil = no snapping.
  var snapTargets: ((ObjectIdentifier, Int) -> [Double])?
  private var snapCache: [Double]?
  private var snappedTime: Double?
  private let snapHaptic = UIImpactFeedbackGenerator(style: .light)
  /// Fires (repeatedly, live) while a long-press-then-drag reorder is in
  /// progress, once per step-swap — (id of the item that moved, id of the
  /// item it swapped past). Per the user's explicit "reorder layers...
  /// select and reorder by long press" request. The owner should apply
  /// this to its OWN backing order + canvas z-order immediately, but
  /// defer a full rebuild to onReorderEnded.
  var onReorderSwap: ((ObjectIdentifier, ObjectIdentifier) -> Void)?
  /// Fires once when a reorder gesture ends — the safe point for the
  /// owner to do a full rebuild.
  var onReorderEnded: (() -> Void)?
  /// Edits-style layers (one item per row): while reordering, a vertical
  /// drag past `crossRowStep` asks the owner to move THIS row one slot up
  /// (-1) or down (+1) among its sibling rows. The owner returns how far
  /// the row moved in points (positive = moved down), or nil if it
  /// couldn't move, so the drag origin can follow the row.
  var onCrossRowReorderStep: ((Int) -> CGFloat?)?
  /// A quick tap (no drag, no long-press) on an item. When set, a tap on
  /// the bar's body also SELECTS that item (body taps otherwise do nothing).
  var onItemTapped: ((ObjectIdentifier, Int) -> Void)?
  private var tapCandidateIndex: Int?
  private var touchMovedBeyondSlop = false
  private let crossRowStep: CGFloat = 22

  private let edgeWidth: CGFloat = 8
  private let edgeTouchSlop: CGFloat = 14
  private let minRangeDuration: Double = 0.5

  /// Matches VideoTrimView's OWN filmstrip-style leading/trailing inset
  /// (filmstripHandleWidth/2 + filmstripHandleTouchSlop = 3 + 6) exactly
  /// for Text/Sticker/Overlay rows — VideoTrimView insets its OWN
  /// thumbnail drawing by this same amount (room for its trim-handle
  /// touch targets), so without a matching inset here an item's position
  /// would be a few points off from the video row's own displayed
  /// filmstrip content, not just this view's raw bounds. mergedStripView
  /// (isMergedClipsContinuation) must stay UN-inset — it sits with ZERO
  /// gap directly against videoTrimView's own trailing edge (see
  /// squareLeading below), so insetting it here would reintroduce that
  /// seam.
  // Time 0 / the end map exactly to this view's own edges (no inset), so
  // the timeline lines up with the white playhead line — the scroll math
  // (scrollOffsetX(forCombinedTime:)) puts time 0 at content x = 0. The
  // old 9pt inset left every bar starting to the right of the playhead.
  private let edgeInset: CGFloat = 0

  // .move only ever gets assigned when allowBodyDrag is true (music row).
  private enum DragTarget: Equatable { case start, end, move }
  private var activeItemIndex: Int?
  private var activeDrag: DragTarget?
  private var moveStartTouchX: CGFloat = 0
  private var moveStartRangeStart: Double = 0
  private var moveStartRangeDuration: Double = 0

  // Long-press-then-drag reorder (see onReorderSwap's own doc). Kept
  // fully independent of activeDrag — a pending long press is cancelled
  // the moment the finger moves beyond touch slop (a deliberate
  // hold-still is what distinguishes "I want to reorder" from "I'm
  // trimming/moving/scrolling"), and once it DOES fire, it wins outright
  // (activeDrag is cleared) since nothing could have moved yet.
  private var pendingLongPress: DispatchWorkItem?
  private var isReordering = false
  private var reorderIndex: Int?
  private var reorderStartY: CGFloat = 0
  private var downPoint: CGPoint = .zero
  private let longPressTimeout: TimeInterval = 0.45
  private let touchSlop: CGFloat = 10
  private let reorderStep: CGFloat = 28

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Highlights one item (or none) from outside — keeps the track in sync
  /// with the layer selected on the canvas, and across row rebuilds.
  func setSelection(id: ObjectIdentifier?, segmentIndex: Int?) {
    guard selectedItemId != id || selectedSegmentIndex != segmentIndex else { return }
    selectedItemId = id
    selectedSegmentIndex = id == nil ? nil : segmentIndex
    setNeedsDisplay()
  }

  func configure(duration: Double, items: [Item]) {
    self.duration = max(duration, 0.001)
    self.items = items
    if let selectedItemId, !items.contains(where: { $0.id == selectedItemId && $0.segmentIndex == selectedSegmentIndex }) {
      self.selectedItemId = nil
      self.selectedSegmentIndex = nil
    }
    setNeedsDisplay()
  }

  private func x(for time: Double) -> CGFloat {
    guard duration > 0, bounds.width > 0 else { return 0 }
    if isMergedClipsContinuation {
      return CGFloat(time / duration) * bounds.width
    }
    let usableWidth = bounds.width - edgeInset * 2
    guard usableWidth > 0 else { return edgeInset }
    return edgeInset + CGFloat(time / duration) * usableWidth
  }


  private func time(for x: CGFloat) -> Double {
    guard bounds.width > 0 else { return 0 }
    if isMergedClipsContinuation {
      return Double(max(0, min(x, bounds.width)) / bounds.width) * duration
    }
    let usableWidth = bounds.width - edgeInset * 2
    guard usableWidth > 0 else { return 0 }
    let clamped = max(0, min(x - edgeInset, usableWidth))
    return Double(clamped / usableWidth) * duration
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    ctx.setFillColor((isMergedClipsContinuation ? UIColor.black : EditorDesignTokens.Colors.elevatedSurface).cgColor)
    ctx.fill(bounds)

    for (index, item) in items.enumerated() {
      // Hidden layer: everything for this item is drawn at reduced alpha.
      if item.isDimmed {
        ctx.saveGState()
        ctx.setAlpha(0.4)
      }
      defer { if item.isDimmed { ctx.restoreGState() } }
      let startX = x(for: item.rangeStart)
      let endX = x(for: item.rangeEnd)
      let barRect = CGRect(x: startX, y: 2, width: max(endX - startX, 2), height: bounds.height - 4)
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
      var roundedCorners: UIRectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
      if isMergedClipsContinuation {
        roundedCorners.remove([.topLeft, .bottomLeft])
        if index < items.count - 1 { roundedCorners.remove([.topRight, .bottomRight]) }
      }
      let barPath = UIBezierPath(roundedRect: barRect, byRoundingCorners: roundedCorners, cornerRadii: CGSize(width: 6, height: 6))
      if !item.thumbnailTiles.isEmpty {
        ctx.saveGState()
        ctx.addPath(barPath.cgPath)
        ctx.clip()
        let tileWidth = barRect.width / CGFloat(item.thumbnailTiles.count)
        for (tileIndex, image) in item.thumbnailTiles.enumerated() {
          let tileRect = CGRect(x: barRect.minX + tileWidth * CGFloat(tileIndex), y: barRect.minY, width: tileWidth, height: barRect.height)
          Self.drawAspectFilled(image, in: tileRect, context: ctx)
        }
        ctx.restoreGState()
      } else {
        ctx.setFillColor(item.color.cgColor)
        ctx.addPath(barPath.cgPath)
        ctx.fillPath()
      }

      // Per the user's explicit "just like main video layer has handle to
      // drag... I want these same on all layers" request — every
      // edge-draggable item (Text/Sticker/Overlay; NOT a merged-clip row,
      // which keeps its own deliberate "plain thumbnail unless active"
      // Instagram-reference look from an earlier round, and not the Music
      // row, whose duration isn't edge-draggable at all) now always shows
      // a grip at each edge — so it visibly reads as draggable the same
      // way the video row's own trim handles do, even before it's
      // selected. Deliberately a neutral GRAY, never white, and — per the
      // user's own repeated, explicit "remove that white color... only
      // selected layer should have a white border" requirement — NO
      // full-perimeter outline at all when unselected, only the two edge
      // grips. Only the SELECTED item's own full white border (below)
      // ever draws a border around the whole bar, so selected vs.
      // unselected can never be confused at a glance.
      if edgeDragEnabled, !isMergedClipsContinuation {
        // Selected item: bigger white trim handles so it's obvious where
        // to drag; others keep the small gray grips.
        let isSelectedItem = item.id == selectedItemId && item.segmentIndex == selectedSegmentIndex
        let dimColor = isSelectedItem ? UIColor.white : UIColor(white: 0.68, alpha: 0.85)
        let dimHandleWidth: CGFloat = isSelectedItem ? 7 : 5
        let handleHeightFraction: CGFloat = isSelectedItem ? 0.6 : 0.5
        ctx.setFillColor(dimColor.cgColor)
        // Clamped inside the view: an item starting at 0:00 or ending at
        // the very end (e.g. a full-length music track) would otherwise
        // have half its handle cut off at the view's edge.
        let dimLeftHandleRect = CGRect(x: max(0, startX - dimHandleWidth / 2), y: bounds.height * (1 - handleHeightFraction) / 2, width: dimHandleWidth, height: bounds.height * handleHeightFraction)
        ctx.addPath(UIBezierPath(roundedRect: dimLeftHandleRect, cornerRadius: dimHandleWidth / 2).cgPath)
        ctx.fillPath()
        let dimRightHandleRect = CGRect(x: min(bounds.width - dimHandleWidth, endX - dimHandleWidth / 2), y: bounds.height * (1 - handleHeightFraction) / 2, width: dimHandleWidth, height: bounds.height * handleHeightFraction)
        ctx.addPath(UIBezierPath(roundedRect: dimRightHandleRect, cornerRadius: dimHandleWidth / 2).cgPath)
        ctx.fillPath()
      }

      // Yellow border + edge-grip handles + duration label for the merged
      // clip currently under the playhead ONLY, matching VideoTrimView's
      // OWN active-segment look exactly (EditorDesignTokens.Colors.
      // trimHandle) — per the user's explicit Instagram-reference request,
      // other (inactive) merged clips show a plain thumbnail with no
      // border. Text/Sticker/Overlay items are unaffected (isActive is
      // always false there).
      if item.isActive {
        ctx.setStrokeColor(EditorDesignTokens.Colors.trimHandle.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(barPath.cgPath)
        ctx.strokePath()

        let handleWidth: CGFloat = 6
        ctx.setFillColor(EditorDesignTokens.Colors.trimHandle.cgColor)
        let leftHandleRect = CGRect(x: startX - handleWidth / 2, y: bounds.height * 0.2, width: handleWidth, height: bounds.height * 0.6)
        ctx.addPath(UIBezierPath(roundedRect: leftHandleRect, cornerRadius: handleWidth / 2).cgPath)
        ctx.fillPath()
        let rightHandleRect = CGRect(x: endX - handleWidth / 2, y: bounds.height * 0.2, width: handleWidth, height: bounds.height * 0.6)
        ctx.addPath(UIBezierPath(roundedRect: rightHandleRect, cornerRadius: handleWidth / 2).cgPath)
        ctx.fillPath()

        if let durationLabel = item.durationLabel {
          let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.white,
          ]
          durationLabel.draw(at: CGPoint(x: startX + 6, y: 4), withAttributes: labelAttributes)
        }
      }

      if (item.id == selectedItemId && item.segmentIndex == selectedSegmentIndex) || (isReordering && index == reorderIndex) {
        ctx.setStrokeColor(UIColor.white.cgColor)
        // Thin selection outline (was 2).
        ctx.setLineWidth(1.25)
        ctx.addPath(barPath.cgPath)
        ctx.strokePath()
      }

      // Thumbnail items skip the text label entirely — video content
      // behind small white text reads poorly, and the thumbnail itself
      // already identifies the clip.
      var labelRect = barRect
      // Beat dots along the bottom of the bar.
      if !item.markers.isEmpty {
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
        for beat in item.markers where beat >= item.rangeStart && beat <= item.rangeEnd {
          let bx = x(for: beat)
          ctx.fillEllipse(in: CGRect(x: bx - 1.5, y: barRect.maxY - 6, width: 3, height: 3))
        }
      }
      // Hidden / locked symbols at the right end; the label stops before them.
      if !item.statusIcons.isEmpty, item.thumbnailTiles.isEmpty {
        let iconSide: CGFloat = 12
        let needed = CGFloat(item.statusIcons.count) * (iconSide + 4) + 8
        if barRect.width >= needed + 30 {
          var iconX = barRect.maxX - 8 - iconSide
          for icon in item.statusIcons.reversed() {
            let scale = min(iconSide / max(icon.size.width, 1), iconSide / max(icon.size.height, 1))
            let size = CGSize(width: icon.size.width * scale, height: icon.size.height * scale)
            icon.draw(in: CGRect(x: iconX + (iconSide - size.width) / 2, y: barRect.midY - size.height / 2, width: size.width, height: size.height))
            iconX -= iconSide + 4
          }
          labelRect.size.width = max(0, labelRect.width - needed)
        }
      }
      if let badge = item.badge, item.thumbnailTiles.isEmpty, barRect.width >= 34 {
        let side = min(22, barRect.height - 8)
        let tile = CGRect(x: barRect.minX + 6, y: barRect.midY - side / 2, width: side, height: side)
        ctx.saveGState()
        ctx.addPath(UIBezierPath(roundedRect: tile, cornerRadius: 5).cgPath)
        ctx.clip()
        if item.badgeFillsTile {
          Self.drawAspectFilled(badge, in: tile, context: ctx)
        } else {
          ctx.setFillColor(UIColor(white: 1, alpha: 0.22).cgColor)
          ctx.fill(tile)
          let box = tile.insetBy(dx: 3.5, dy: 3.5)
          let scale = min(box.width / max(badge.size.width, 1), box.height / max(badge.size.height, 1))
          let size = CGSize(width: badge.size.width * scale, height: badge.size.height * scale)
          badge.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
        }
        ctx.restoreGState()
        labelRect = CGRect(x: tile.maxX + 2, y: barRect.minY, width: max(0, labelRect.maxX - tile.maxX - 2), height: barRect.height)
      }
      guard item.thumbnailTiles.isEmpty, !item.label.isEmpty, labelRect.width > 16 else { continue }
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: UIColor.white,
      ]
      let textSize = item.label.size(withAttributes: attributes)
      // Name drawn ONCE, left-aligned (after the badge), shortened with
      // "…" when it doesn't fit — the user asked for no repeated names.
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byTruncatingTail
      var onceAttributes = attributes
      onceAttributes[.paragraphStyle] = paragraph
      let textRect = CGRect(
        x: labelRect.minX + 4, y: labelRect.midY - textSize.height / 2,
        width: max(0, labelRect.width - 8), height: textSize.height
      )
      item.label.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: onceAttributes, context: nil)
    }
  }

  /// Crops (rather than stretches) `image` to fill `rect` without
  /// distorting its aspect ratio — mirrors VideoTrimView's identical
  /// private helper (not shared directly since that one stays private to
  /// its own file); a plain `draw(in:)` would squeeze the frame to fit
  /// each item's own (usually much narrower) width.
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

  /// Hit-tests topmost (last-drawn) item first, so an overlapping pair
  /// resolves to whichever one currently reads on top. For merged-clip
  /// rows (isMergedClipsContinuation), only the ACTIVE item's edges are
  /// even eligible to recognize a drag. BODY (move) drags are disabled
  /// entirely for EVERY row now (previously only merged rows) — once
  /// embedded in the Instagram-style scrollable timeline, dragging a
  /// bar's body IS scrolling the timeline, so that gesture must fall
  /// through to the ancestor scroll view rather than being consumed here.
  /// Text/Sticker/Overlay rows used to keep body-drag-to-reschedule
  /// eligible, but that was removed after the user confirmed a swipe
  /// meant to scroll the shared timeline (which visually looks like one
  /// continuous scrollable strip) was silently rescheduling whichever
  /// layer's bar the touch happened to land on instead. Since
  /// layerTracksScrollView is a REAL horizontally-scrollable UIScrollView
  /// on this platform (unlike Android's manual scrollTo mirror), simply
  /// not claiming the touch here is enough — UIScrollView's own built-in
  /// touch-vs-pan-gesture arbitration (touchesShouldCancel) takes it from
  /// there once it detects panning motion, no manual forwarding needed.
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    let point = touch.location(in: self)
    activeItemIndex = nil
    activeDrag = nil
    isReordering = false
    reorderIndex = nil
    downPoint = point
    tapCandidateIndex = nil
    touchMovedBeyondSlop = false
    for index in items.indices.reversed() {
      let item = items[index]
      guard !isMergedClipsContinuation || item.isActive else { continue }
      let startX = x(for: item.rangeStart)
      let endX = x(for: item.rangeEnd)
      let target: DragTarget
      if edgeDragEnabled, abs(point.x - startX) <= edgeWidth / 2 + edgeTouchSlop {
        target = .start
      } else if edgeDragEnabled, abs(point.x - endX) <= edgeWidth / 2 + edgeTouchSlop {
        target = .end
      } else if allowBodyDrag, point.x >= startX, point.x <= endX,
                !bodyDragRequiresSelection || (item.id == selectedItemId && item.segmentIndex == selectedSegmentIndex) {
        target = .move
      } else {
        continue
      }
      activeItemIndex = index
      activeDrag = target
      if target == .move {
        moveStartTouchX = point.x
        moveStartRangeStart = item.rangeStart
        moveStartRangeDuration = item.rangeEnd - item.rangeStart
      }
      break
    }
    if let index = activeItemIndex {
      selectedItemId = items[index].id
      selectedSegmentIndex = items[index].segmentIndex
      onItemSelected?(items[index].id, items[index].segmentIndex)
      onHandleDragStateChanged?(true)
      setNeedsDisplay()
    }
    // Long-press-to-reorder is ONLY considered when this touch did NOT
    // already match an edge/body-move target above — scheduling it
    // unconditionally (this session's first attempt) raced every
    // start/end/move drag: if the user pressed then paused before
    // actually moving (a completely normal press-then-drag rhythm), the
    // long-press timer fired first and clobbered the in-progress drag by
    // clearing activeDrag, silently breaking trim/move entirely — this is
    // what the user was hitting with "unable to drag and trim music
    // layer". Now a touch that DID hit an edge or (music-only) the body
    // itself is claimed outright; only a touch that hit NEITHER (a
    // text/sticker/overlay row's plain body, which does nothing else, or
    // a merged-clip row's body) is eligible for reorder.
    tapCandidateIndex = activeItemIndex
    // A selected layer's body is a move target, but holding still on it
    // should still start a reorder (same as an unselected row).
    if let index = activeItemIndex, activeDrag == .move, bodyDragRequiresSelection {
      let work = DispatchWorkItem { [weak self] in self?.beginReorder(at: index) }
      pendingLongPress = work
      DispatchQueue.main.asyncAfter(deadline: .now() + longPressTimeout, execute: work)
    }
    if activeItemIndex == nil {
      let reorderCandidate = items.indices.reversed().first { idx in
        let item = items[idx]
        return (!isMergedClipsContinuation || item.isActive)
          && point.x >= x(for: item.rangeStart) && point.x <= x(for: item.rangeEnd)
      }
      tapCandidateIndex = reorderCandidate
      if let reorderCandidate {
        let work = DispatchWorkItem { [weak self] in self?.beginReorder(at: reorderCandidate) }
        pendingLongPress = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressTimeout, execute: work)
      }
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    let point = touch.location(in: self)
    if isReordering {
      if let step = onCrossRowReorderStep {
        let deltaY = point.y - reorderStartY
        if abs(deltaY) >= crossRowStep, let moved = step(deltaY < 0 ? -1 : 1) {
          // The row itself moved by `moved`, so the finger's position in
          // this row's own coordinates shifted the opposite way.
          reorderStartY = point.y - moved
        }
        return
      }
      guard let index = reorderIndex else { return }
      let deltaY = point.y - reorderStartY
      if deltaY <= -reorderStep, index > 0 {
        onReorderSwap?(items[index].id, items[index - 1].id)
        items.swapAt(index, index - 1)
        reorderIndex = index - 1
        reorderStartY = point.y
        setNeedsDisplay()
      } else if deltaY >= reorderStep, index < items.count - 1 {
        onReorderSwap?(items[index].id, items[index + 1].id)
        items.swapAt(index, index + 1)
        reorderIndex = index + 1
        reorderStartY = point.y
        setNeedsDisplay()
      }
      return
    }
    if abs(point.x - downPoint.x) > touchSlop || abs(point.y - downPoint.y) > touchSlop {
      touchMovedBeyondSlop = true
    }
    if pendingLongPress != nil, (abs(point.x - downPoint.x) > touchSlop || abs(point.y - downPoint.y) > touchSlop) {
      pendingLongPress?.cancel()
      pendingLongPress = nil
    }
    guard let activeDrag, let index = activeItemIndex, items.indices.contains(index) else { return }
    if snapCache == nil, let snapTargets {
      snapCache = snapTargets(items[index].id, items[index].segmentIndex)
      snapHaptic.prepare()
    }
    var snapped: Double?
    switch activeDrag {
    case .start:
      var t = time(for: point.x)
      if let target = nearestSnap(to: t) { t = target; snapped = target }
      items[index].rangeStart = max(0, min(t, items[index].rangeEnd - minRangeDuration))
    case .end:
      var t = time(for: point.x)
      if let target = nearestSnap(to: t) { t = target; snapped = target }
      items[index].rangeEnd = min(duration, max(t, items[index].rangeStart + minRangeDuration))
    case .move:
      let deltaTime = time(for: point.x) - time(for: moveStartTouchX)
      let maxStart = max(0, duration - moveStartRangeDuration)
      var newStart = max(0, min(moveStartRangeStart + deltaTime, maxStart))
      // Either edge can snap; the closer one wins.
      let startSnap = nearestSnap(to: newStart)
      let endSnap = nearestSnap(to: newStart + moveStartRangeDuration)
      if let s = startSnap, endSnap == nil || abs(s - newStart) <= abs(endSnap! - newStart - moveStartRangeDuration) {
        newStart = s; snapped = s
      } else if let e = endSnap {
        newStart = e - moveStartRangeDuration; snapped = e
      }
      newStart = max(0, min(newStart, maxStart))
      items[index].rangeStart = newStart
      items[index].rangeEnd = newStart + moveStartRangeDuration
    }
    if let snapped, snapped != snappedTime { snapHaptic.impactOccurred(); snapHaptic.prepare() }
    snappedTime = snapped
    onRangeChanged?(items[index].id, items[index].segmentIndex, items[index].rangeStart, items[index].rangeEnd)
    setNeedsDisplay()
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    // A quick tap: released before the long-press fired, never moved.
    if let onItemTapped, !isReordering, !touchMovedBeyondSlop,
       let index = tapCandidateIndex, items.indices.contains(index) {
      let item = items[index]
      selectedItemId = item.id
      selectedSegmentIndex = item.segmentIndex
      UISelectionFeedbackGenerator().selectionChanged()
      onItemSelected?(item.id, item.segmentIndex)
      setNeedsDisplay()
      endTouch()
      onItemTapped(item.id, item.segmentIndex)
      return
    }
    endTouch()
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    endTouch()
  }

  /// The closest snap time within ~8pt of `t`, if any.
  private func nearestSnap(to t: Double) -> Double? {
    guard let snapCache, !snapCache.isEmpty else { return nil }
    let usableWidth = isMergedClipsContinuation ? bounds.width : bounds.width - edgeInset * 2
    guard usableWidth > 0 else { return nil }
    let threshold = 8 / Double(usableWidth) * duration
    var best: Double?
    for target in snapCache where abs(target - t) <= threshold {
      if best == nil || abs(target - t) < abs(best! - t) { best = target }
    }
    return best
  }

  private func endTouch() {
    snapCache = nil
    snappedTime = nil
    pendingLongPress?.cancel()
    pendingLongPress = nil
    let wasDragging = activeDrag == .start || activeDrag == .end || activeDrag == .move
    if wasDragging { onHandleDragStateChanged?(false) }
    activeItemIndex = nil
    activeDrag = nil
    if wasDragging { onDragEnded?() }
    if isReordering {
      isReordering = false
      reorderIndex = nil
      setNeedsDisplay()
      if onCrossRowReorderStep != nil { onHandleDragStateChanged?(false) }
      onReorderEnded?()
    }
  }

  /// Fired once the long-press timer elapses without the finger having
  /// moved beyond touch slop — switches this gesture over to reorder mode
  /// outright, discarding whatever start/end/move interpretation
  /// touchesBegan may ALSO have assigned (nothing could have changed yet,
  /// since slop wasn't exceeded).
  private func beginReorder(at index: Int) {
    guard items.indices.contains(index) else { return }
    guard reorderEnabled else {
      // Rows with reordering disabled (the music row: every segment
      // shares the SAME id, so there's nothing to reorder against) still
      // need long-press to SELECT the tapped segment, same as every other
      // row — per the user's explicit "on long press these splitted
      // portion should select only" correction. Deleting the whole track
      // now happens via the normal per-segment delete icon once selected
      // (see deleteMusicSegment's own doc), not directly from long-press.
      selectedItemId = items[index].id
      selectedSegmentIndex = items[index].segmentIndex
      onItemSelected?(items[index].id, items[index].segmentIndex)
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      setNeedsDisplay()
      return
    }
    activeItemIndex = nil
    activeDrag = nil
    isReordering = true
    reorderIndex = index
    reorderStartY = downPoint.y
    // Rows now scroll vertically when there are many layers — lock the
    // timeline scroll views so the reorder drag isn't taken over by them.
    if onCrossRowReorderStep != nil { onHandleDragStateChanged?(true) }
    selectedItemId = items[index].id
    selectedSegmentIndex = items[index].segmentIndex
    onItemSelected?(items[index].id, items[index].segmentIndex)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    setNeedsDisplay()
  }
}
