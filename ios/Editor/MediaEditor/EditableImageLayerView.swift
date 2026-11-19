import UIKit

/// A single, shared shape for the 3 callbacks every draggable/pinchable/
/// rotatable layer needs (text, sticker, or image overlay) — lets
/// `MediaEditorViewController`'s selection/toolbar code (`selectedLayer`,
/// `wireLayerCallbacks`, `confirmDeleteLayer`, etc.) operate on whichever
/// concrete layer type without needing to know which one it is.
protocol EditableLayerView: UIView {
  var onLongPress: (() -> Void)? { get set }
  var onTap: (() -> Void)? { get set }
  var onTransformChanged: (() -> Void)? { get set }
  /// Fires from this layer's OWN pan/pinch/rotate handlers (not the VC's
  /// shared ones) on every gesture state change — lets the VC track
  /// begin/end for undo/redo even while this layer isn't `selectedLayer`
  /// (its own gestures stay live then; see setOwnTransformGesturesEnabled).
  var onOwnGestureStateChanged: ((UIGestureRecognizer) -> Void)? { get set }

  /// Current transform components, read by the VC to snapshot/restore this
  /// layer's position/size/angle for undo/redo (see
  /// MediaEditorViewController.trackTransformGesture).
  var currentTranslation: CGPoint { get }
  var currentScale: CGFloat { get }
  var currentRotation: CGFloat { get }

  /// Set once by the VC (`wireLayerCallbacks`) to a closure returning
  /// imageView's CURRENT frame (in this layer's `referenceView`'s
  /// coordinate space) — lets every pan/pinch clamp this layer's own
  /// position/size so it can never end up outside the photo's visible
  /// bounds, per the user's explicit request that nothing added on top of
  /// the image should be draggable/resizable past its edges. `nil` (never
  /// actually left unset for a real layer) would mean unclamped.
  var boundsProvider: (() -> CGRect)? { get set }

  /// Snap guides: fires while this layer is dragged with which guides it
  /// is currently snapped to (empty when the drag ends) — the VC draws the
  /// guide lines and plays a light haptic when a new snap engages.
  var onSnapChanged: ((LayerSnapState) -> Void)? { get set }

  /// Toggles just this layer's OWN pan/pinch/rotate (tap/long-press stay
  /// active either way) — disabled while the VC's shared, view-wide
  /// gesture recognizers take over manipulating this layer (see
  /// `applyExternalPan`/etc below), so the two can't double-apply the same
  /// physical gesture.
  func setOwnTransformGesturesEnabled(_ enabled: Bool)
  /// Forwards a pan/pinch/rotation event from the VC's shared, view-wide
  /// gesture recognizers into this layer's own transform math — lets
  /// dragging/pinching keep controlling this layer from ANYWHERE on
  /// screen while it's selected, Instagram-style, not just within its own
  /// (possibly tiny) current bounds. Same underlying math as each layer's
  /// own private handlePan/handlePinch/handleRotation.
  func applyExternalPan(_ gesture: UIPanGestureRecognizer, in referenceView: UIView)
  func applyExternalPinch(_ gesture: UIPinchGestureRecognizer)
  func applyExternalRotation(_ gesture: UIRotationGestureRecognizer)

  /// Rescales this layer's translation + own scale by `factor`, keeping
  /// rotation unchanged — used when the canvas box itself is resized (see
  /// MediaEditorViewController.updateCanvasSizeForLayers) so an existing
  /// layer's position/size stays visually anchored to the same spot on
  /// the video/image instead of going stale relative to the new, smaller
  /// or bigger canvas. Safe to call with factor == 1 (no-op).
  func rescaleForCanvasResize(by factor: CGFloat)

  /// Sets this layer's transform directly — used both to seed a duplicate
  /// at the source's current translation/scale/rotation, and by the VC's
  /// undo/redo to restore a snapshot taken before/after a pan/pinch/rotate.
  func applyInitialTransform(translation: CGPoint, scale: CGFloat, rotation: CGFloat)
}

/// A text layer's animation: In (start of each time piece), Out (end of
/// it) and Loop (all the time it's on screen), each with its own length.
struct TextAnimConfig: Equatable {
  var inType = 0
  var outType = 0
  var loopType = 0
  var inDuration: Double = 0.5
  var outDuration: Double = 0.5
  /// One loop cycle, in seconds.
  var loopPeriod: Double = 1.0
  var isNone: Bool { inType == 0 && outType == 0 && loopType == 0 }
  static let none = TextAnimConfig()
}

/// Text animations. Shared by the live preview, the sheet's tiles and the
/// video export so they all match (same math as Android TextAnimation —
/// keep the type numbers in sync).
enum TextAnimation {
  static let inTitles = ["None", "Fade", "Pop", "Typewriter", "Slide up", "Slide down", "Slide left", "Slide right",
                         "Zoom in", "Zoom out", "Bounce", "Spin", "Drop", "Swing", "Flash", "Wipe"]
  static let outTitles = ["None", "Fade", "Pop", "Slide down", "Slide up", "Slide left", "Slide right",
                          "Zoom in", "Zoom out", "Spin", "Flash", "Wipe"]
  static let loopTitles = ["None", "Pulse", "Heartbeat", "Wiggle", "Swing", "Float", "Sway", "Shake", "Blink", "Rotate", "Hop"]
  static let durationRange: ClosedRange<Double> = 0.2...2.0
  static let loopPeriodRange: ClosedRange<Double> = 0.4...3.0

  struct State: Equatable {
    var alpha: CGFloat = 1
    var scale: CGFloat = 1
    /// Horizontal offset as a fraction of the canvas width (+ = right).
    var offsetX: CGFloat = 0
    /// Vertical offset as a fraction of the canvas height (+ = down).
    var offsetY: CGFloat = 0
    /// Radians, + = clockwise on screen.
    var rotation: CGFloat = 0
    /// Typewriter / wipe: visible fraction of the text, left to right.
    var reveal: CGFloat = 1
    static let identity = State()
  }

  /// State at time `t` for a layer shown during `segments`.
  static func state(at t: Double, segments: [ClosedRange<Double>], config c: TextAnimConfig) -> State {
    guard !c.isNone,
          let seg = segments.first(where: { t >= $0.lowerBound && t <= $0.upperBound }) else { return .identity }
    var s = State()
    let length = seg.upperBound - seg.lowerBound
    guard length > 0 else { return s }
    if c.inType != 0 {
      let d = min(c.inDuration, length / 2)
      let p = d > 0 ? CGFloat(min(max((t - seg.lowerBound) / d, 0), 1)) : 1
      if p < 1 { applyIn(c.inType, p, &s) }
    }
    if c.outType != 0 {
      let d = min(c.outDuration, length / 2)
      let p = d > 0 ? CGFloat(min(max((seg.upperBound - t) / d, 0), 1)) : 1
      if p < 1 { applyOut(c.outType, p, &s) }
    }
    if c.loopType != 0 {
      let phase = CGFloat((t - seg.lowerBound) / max(c.loopPeriod, 0.1))
      applyLoop(c.loopType, phase, &s)
    }
    return s
  }

  /// `p` goes 0 → 1 as the text comes in.
  private static func applyIn(_ type: Int, _ p: CGFloat, _ s: inout State) {
    let e = easeOut(p)
    switch type {
    case 1: s.alpha *= e
    case 2: s.scale *= 0.4 + 0.6 * easeOutBack(p); s.alpha *= min(1, p * 3)
    case 3: s.reveal = min(s.reveal, (p * 12).rounded(.down) / 12)
    case 4: s.offsetY += (1 - e) * 0.08; s.alpha *= e
    case 5: s.offsetY -= (1 - e) * 0.08; s.alpha *= e
    case 6: s.offsetX += (1 - e) * 0.15; s.alpha *= e
    case 7: s.offsetX -= (1 - e) * 0.15; s.alpha *= e
    case 8: s.scale *= 0.2 + 0.8 * e; s.alpha *= e
    case 9: s.scale *= 2 - e; s.alpha *= e
    case 10: s.offsetY += (1 - easeOutBack(p, overshoot: 3)) * 0.1; s.alpha *= min(1, p * 4)
    case 11: s.rotation += -(1 - e) * .pi; s.scale *= 0.3 + 0.7 * e; s.alpha *= min(1, p * 3)
    case 12: s.offsetY -= (1 - easeOutBounce(p)) * 0.12; s.alpha *= min(1, p * 5)
    case 13: s.rotation += 0.45 * (1 - p) * cos(p * .pi * 3.5); s.alpha *= min(1, p * 4)
    case 14: s.alpha *= p > 0.85 ? 1 : (Int(p * 7) % 2 == 0 ? 0.15 : 1)
    case 15: s.reveal = min(s.reveal, e)
    default: break
    }
  }

  /// `p` goes 1 → 0 as the text leaves.
  private static func applyOut(_ type: Int, _ p: CGFloat, _ s: inout State) {
    let e = easeOut(p)
    switch type {
    case 1: s.alpha *= e
    case 2: s.scale *= 0.4 + 0.6 * e; s.alpha *= e
    case 3: s.offsetY += (1 - e) * 0.08; s.alpha *= e
    case 4: s.offsetY -= (1 - e) * 0.08; s.alpha *= e
    case 5: s.offsetX -= (1 - e) * 0.15; s.alpha *= e
    case 6: s.offsetX += (1 - e) * 0.15; s.alpha *= e
    case 7: s.scale *= 2 - e; s.alpha *= e
    case 8: s.scale *= 0.2 + 0.8 * e; s.alpha *= e
    case 9: s.rotation += (1 - e) * .pi; s.scale *= 0.3 + 0.7 * e; s.alpha *= e
    case 10: s.alpha *= p < 0.15 ? 0 : (Int(p * 7) % 2 == 0 ? 0.15 : 1)
    case 11: s.reveal = min(s.reveal, e)
    default: break
    }
  }

  /// `phase` counts loop cycles since the piece started.
  private static func applyLoop(_ type: Int, _ phase: CGFloat, _ s: inout State) {
    let w = 2 * CGFloat.pi * phase
    let f = phase - phase.rounded(.down)
    switch type {
    case 1: s.scale *= 1 + 0.07 * (0.5 - 0.5 * cos(w))
    case 2:
      func bump(_ x: CGFloat) -> CGFloat { (x >= 0 && x <= 0.14) ? sin(x / 0.14 * .pi) : 0 }
      s.scale *= 1 + 0.12 * bump(f) + 0.08 * bump(f - 0.22)
    case 3: s.rotation += 0.09 * sin(w * 2)
    case 4: s.rotation += 0.2 * sin(w)
    case 5: s.offsetY += 0.015 * sin(w)
    case 6: s.offsetX += 0.03 * sin(w)
    case 7: s.offsetX += 0.01 * sin(w * 6)
    case 8: s.alpha *= 0.25 + 0.75 * (0.5 + 0.5 * cos(w))
    case 9: s.rotation += w
    case 10: s.offsetY -= 0.035 * abs(sin(w / 2))
    default: break
    }
  }

  private static func easeOut(_ x: CGFloat) -> CGFloat { 1 - (1 - x) * (1 - x) }

  private static func easeOutBack(_ x: CGFloat, overshoot c1: CGFloat = 1.70158) -> CGFloat {
    let c3 = c1 + 1
    return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
  }

  private static func easeOutBounce(_ x: CGFloat) -> CGFloat {
    let n1: CGFloat = 7.5625, d1: CGFloat = 2.75
    if x < 1 / d1 { return n1 * x * x }
    if x < 2 / d1 { let y = x - 1.5 / d1; return n1 * y * y + 0.75 }
    if x < 2.5 / d1 { let y = x - 2.25 / d1; return n1 * y * y + 0.9375 }
    let y = x - 2.625 / d1
    return n1 * y * y + 0.984375
  }
}

/// Which snap guides a dragged layer is on (see LayerSnapper).
struct LayerSnapState: Equatable {
  var centerX = false
  var centerY = false
  var left = false
  var right = false
  var top = false
  var bottom = false
  static let none = LayerSnapState()
  var isEmpty: Bool { self == .none }
}

/// Snap guides for dragging a text/sticker/photo layer: its center snaps
/// to the canvas's vertical/horizontal center lines, and its (unrotated,
/// scaled) edges to a safe margin inside the canvas, when within
/// `threshold` points. Works on the UNSNAPPED position the finger implies,
/// so a layer pulls free again as soon as the finger moves past it.
enum LayerSnapper {
  static let threshold: CGFloat = 8
  static let edgeMargin: CGFloat = 16

  /// `center` = the layer's untransformed center in the reference view;
  /// `halfSize` = half its scaled size; `box` = the canvas rect.
  static func snap(translation: CGPoint, center: CGPoint, halfSize: CGSize, box: CGRect) -> (CGPoint, LayerSnapState) {
    guard box != .zero else { return (translation, .none) }
    var state = LayerSnapState()
    var t = translation
    let cx = center.x + t.x
    let cy = center.y + t.y
    if abs(cx - box.midX) <= threshold {
      t.x = box.midX - center.x; state.centerX = true
    } else if abs((cx - halfSize.width) - (box.minX + edgeMargin)) <= threshold {
      t.x = box.minX + edgeMargin + halfSize.width - center.x; state.left = true
    } else if abs((cx + halfSize.width) - (box.maxX - edgeMargin)) <= threshold {
      t.x = box.maxX - edgeMargin - halfSize.width - center.x; state.right = true
    }
    if abs(cy - box.midY) <= threshold {
      t.y = box.midY - center.y; state.centerY = true
    } else if abs((cy - halfSize.height) - (box.minY + edgeMargin)) <= threshold {
      t.y = box.minY + edgeMargin + halfSize.height - center.y; state.top = true
    } else if abs((cy + halfSize.height) - (box.maxY - edgeMargin)) <= threshold {
      t.y = box.maxY - edgeMargin - halfSize.height - center.y; state.bottom = true
    }
    return (t, state)
  }
}

/// An image overlay layer (one photo placed on top of another) that owns
/// its own pan/pinch/rotate — added for the "overlay" feature (per the
/// user's explicit request), mirroring `EditableTextLayerView`'s gesture
/// code exactly. Kept as a separate, near-identical class rather than
/// refactoring both into one shared base: `UILabel` and `UIImageView`
/// don't share a common interactive superclass, and duplicating ~60 lines
/// of already-proven, already-device-tested gesture code is materially
/// lower-risk than a shared-base/generic refactor of `EditableTextLayerView`
/// itself with no device available to verify it didn't regress anything.
final class EditableImageLayerView: UIImageView, EditableLayerView {
  // Read externally at export time to re-composite this layer at its
  // current position/scale/rotation onto the higher-res export canvas —
  // same convention as EditableTextLayerView.
  private(set) var currentTranslation: CGPoint = .zero
  private(set) var currentScale: CGFloat = 1
  private(set) var currentRotation: CGFloat = 0

  private weak var referenceView: UIView?

  // Lowered from 0.3 per the user's explicit request — 0.3 didn't let a
  // layer shrink small enough, same fix as EditableTextLayerView.
  private static let minScale: CGFloat = 0.1
  private static let maxScale: CGFloat = 6

  var onLongPress: (() -> Void)?
  var onTap: (() -> Void)?
  var onTransformChanged: (() -> Void)?
  var onOwnGestureStateChanged: ((UIGestureRecognizer) -> Void)?
  var onSnapChanged: ((LayerSnapState) -> Void)?
  /// Unsnapped drag position (nil when not dragging) — see applyExternalPan.
  private var rawPanTranslation: CGPoint?
  /// Set once right after this layer is created (see wireLayerCallbacks) —
  /// the `didSet` applies the initial clip mask immediately rather than
  /// waiting for the first gesture, and updateTransform() re-applies it on
  /// every subsequent pan/pinch/rotate. See updateClipMask's doc for why a
  /// mask (not just clampTranslationWithinBounds) is needed.
  var boundsProvider: (() -> CGRect)? {
    didSet { updateClipMask() }
  }

  // MARK: Overlay look (filter/adjust/opacity/blend/shape/border/flip/eraser)

  /// The cropped photo, before any look is applied. `image` shows the
  /// rendered result (see OverlayRenderer); export re-renders from this.
  private(set) var baseImage: UIImage?
  /// The uncropped photo, for re-cropping (nil after re-opening a project:
  /// re-crop then starts from `baseImage`).
  var sourceImage: UIImage?
  private(set) var overlayStyle = OverlayStyle()
  private(set) var eraseStrokes: [OverlayEraseStroke] = []
  private var coloredCache: (key: String, base: ObjectIdentifier, image: CGImage)?

  func applyOverlay(base: UIImage, style: OverlayStyle, strokes: [OverlayEraseStroke]) {
    baseImage = base
    overlayStyle = style
    eraseStrokes = strokes
    renderOverlay()
  }

  func applyOverlayStyle(_ style: OverlayStyle) {
    overlayStyle = style
    renderOverlay()
  }

  func setEraseStrokes(_ strokes: [OverlayEraseStroke]) {
    eraseStrokes = strokes
    renderOverlay()
  }

  private func renderOverlay() {
    guard let baseImage else { return }
    let key = overlayStyle.colorKey
    let colored: CGImage
    if let cache = coloredCache, cache.key == key, cache.base == ObjectIdentifier(baseImage) {
      colored = cache.image
    } else if let fresh = OverlayRenderer.colorPass(baseImage, style: overlayStyle, maxSide: OverlayRenderer.previewMaxSide) {
      colored = fresh
      coloredCache = (key, ObjectIdentifier(baseImage), fresh)
    } else {
      image = baseImage
      return
    }
    image = OverlayRenderer.composite(
      colored: colored, style: overlayStyle, strokes: eraseStrokes,
      pixelSize: CGSize(width: colored.width, height: colored.height)
    )
    // On-screen blend with what's underneath (export uses the CG blend mode).
    layer.compositingFilter = overlayStyle.blend.compositingFilterName
  }

  // Stored so setOwnTransformGesturesEnabled can toggle just these 3 —
  // same pattern as EditableTextLayerView.
  private var panGesture: UIPanGestureRecognizer?
  private var pinchGesture: UIPinchGestureRecognizer?
  private var rotationGesture: UIRotationGestureRecognizer?

  func enableGestures(in referenceView: UIView) {
    self.referenceView = referenceView
    isUserInteractionEnabled = true

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    pan.delegate = self
    pinch.delegate = self
    rotation.delegate = self
    longPress.delegate = self
    tap.delegate = self
    // Same tap-vs-drag disambiguation as EditableTextLayerView.
    tap.require(toFail: pan)

    addGestureRecognizer(pan)
    addGestureRecognizer(pinch)
    addGestureRecognizer(rotation)
    addGestureRecognizer(longPress)
    addGestureRecognizer(tap)

    panGesture = pan
    pinchGesture = pinch
    rotationGesture = rotation
  }

  func setOwnTransformGesturesEnabled(_ enabled: Bool) {
    panGesture?.isEnabled = enabled
    pinchGesture?.isEnabled = enabled
    rotationGesture?.isEnabled = enabled
  }

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began else { return }
    onLongPress?()
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
    onTap?()
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    onOwnGestureStateChanged?(gesture)
    guard let referenceView else { return }
    applyExternalPan(gesture, in: referenceView)
  }

  @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    onOwnGestureStateChanged?(gesture)
    applyExternalPinch(gesture)
  }

  @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
    onOwnGestureStateChanged?(gesture)
    applyExternalRotation(gesture)
  }

  func applyExternalPan(_ gesture: UIPanGestureRecognizer, in referenceView: UIView) {
    // Snap guides: follow the finger's UNSNAPPED position and snap from
    // that, so a snapped layer pulls free once the finger moves on.
    if gesture.state == .began || rawPanTranslation == nil { rawPanTranslation = currentTranslation }
    let translation = gesture.translation(in: referenceView)
    gesture.setTranslation(.zero, in: referenceView)
    var raw = rawPanTranslation ?? currentTranslation
    raw.x += translation.x
    raw.y += translation.y
    // Kept inside the canvas too, so dragging back from past an edge
    // responds straight away.
    currentTranslation = raw
    clampTranslationWithinBounds()
    raw = currentTranslation
    rawPanTranslation = raw
    var snapState = LayerSnapState.none
    if let box = boundsProvider?() {
      let half = CGSize(width: bounds.width * currentScale / 2, height: bounds.height * currentScale / 2)
      (currentTranslation, snapState) = LayerSnapper.snap(translation: raw, center: center, halfSize: half, box: box)
    } else {
      currentTranslation = raw
    }
    updateTransform()
    let ended = gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed
    if ended { rawPanTranslation = nil }
    onSnapChanged?(ended ? .none : snapState)
  }

  func applyExternalPinch(_ gesture: UIPinchGestureRecognizer) {
    let proposed = currentScale * gesture.scale
    currentScale = min(max(proposed, Self.minScale), Self.maxScale)
    gesture.scale = 1
    updateTransform()
  }

  func applyExternalRotation(_ gesture: UIRotationGestureRecognizer) {
    currentRotation += gesture.rotation
    gesture.rotation = 0
    updateTransform()
  }

  private func updateTransform() {
    clampTranslationWithinBounds()
    var t = CGAffineTransform.identity
    t = t.translatedBy(x: currentTranslation.x, y: currentTranslation.y)
    t = t.rotated(by: currentRotation)
    t = t.scaledBy(x: currentScale, y: currentScale)
    transform = t
    updateClipMask()
    onTransformChanged?()
  }

  /// Clips this layer's rendered content to the canvas box's own screen
  /// rect, recomputed on every transform change — per the user's explicit
  /// "zoomed overlay image should not display outside of that cropper
  /// box" report. `clampTranslationWithinBounds` alone can't prevent this:
  /// its own doc already calls out that an oversized layer (pinched
  /// bigger than the box itself) just gets RE-CENTERED, not resized, so it
  /// can still visually overflow on every side even while "correctly"
  /// clamped. Same technique as EditableTextLayerView's twin — see its
  /// doc for why `convert(_:from:)` is the right tool here.
  private let clipMaskLayer = CAShapeLayer()

  private func updateClipMask() {
    guard let boundsProvider, let referenceView else {
      if layer.mask != nil { layer.mask = nil }
      return
    }
    let boxRect = boundsProvider()
    guard boxRect != .zero else {
      if layer.mask != nil { layer.mask = nil }
      return
    }
    let localRect = convert(boxRect, from: referenceView)
    // One mask per layer, reused: a new mask layer on every drag frame
    // made Core Animation redo its offscreen pass each time (jank).
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    clipMaskLayer.path = CGPath(rect: localRect, transform: nil)
    CATransaction.commit()
    if layer.mask !== clipMaskLayer { layer.mask = clipMaskLayer }
  }

  /// Clamps `currentTranslation` so this layer's own (unrotated, per the
  /// same simplifying assumption the base canvas's own pan-clamp already
  /// makes) scaled bounding box never crosses outside boundsProvider()'s
  /// rect — per the user's explicit "text/images/emojis shouldn't go
  /// outside the image" request. `center` stays meaningful regardless of
  /// `.transform` (unlike `.frame`, which Apple's own docs call undefined
  /// once transform is non-identity) — adding currentTranslation to it
  /// gives the live effective on-screen center without needing to know
  /// this layer's own Auto Layout anchor offset from the VC.
  private func clampTranslationWithinBounds() {
    guard let bounds = boundsProvider?(), bounds != .zero else { return }
    let halfWidth = self.bounds.width * currentScale / 2
    let halfHeight = self.bounds.height * currentScale / 2
    let centerX = center.x + currentTranslation.x
    let centerY = center.y + currentTranslation.y

    let minCenterX = bounds.minX + halfWidth
    let maxCenterX = bounds.maxX - halfWidth
    let clampedCenterX = minCenterX <= maxCenterX ? min(max(centerX, minCenterX), maxCenterX) : bounds.midX

    let minCenterY = bounds.minY + halfHeight
    let maxCenterY = bounds.maxY - halfHeight
    let clampedCenterY = minCenterY <= maxCenterY ? min(max(centerY, minCenterY), maxCenterY) : bounds.midY

    currentTranslation = CGPoint(x: clampedCenterX - center.x, y: clampedCenterY - center.y)
  }

  /// Used only when duplicating an existing overlay layer, to seed the
  /// clone at the source's current translation/scale/rotation (plus a
  /// small offset) rather than starting from identity.
  func applyInitialTransform(translation: CGPoint, scale: CGFloat, rotation: CGFloat) {
    currentTranslation = translation
    currentScale = scale
    currentRotation = rotation
    updateTransform()
  }

  func rescaleForCanvasResize(by factor: CGFloat) {
    guard factor != 1 else { return }
    applyInitialTransform(
      translation: CGPoint(x: currentTranslation.x * factor, y: currentTranslation.y * factor),
      scale: currentScale * factor,
      rotation: currentRotation
    )
  }
}

extension EditableImageLayerView: UIGestureRecognizerDelegate {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }
}
