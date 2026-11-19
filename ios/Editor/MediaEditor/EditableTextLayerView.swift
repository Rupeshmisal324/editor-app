import UIKit

/// A text layer that owns its own pan/pinch/rotate — independent of the
/// image's own transform and of every other text layer.
///
/// UIKit hit-tests to whichever view is topmost under a touch, so attaching
/// gestures directly to each layer "just works": a touch within this
/// label's bounds drives this label only; a touch elsewhere falls through
/// to whatever's underneath (another layer, or the image). No manual
/// coordination needed here — unlike Android, where a plain touch listener
/// requires exactly that (see LayerGestureCoordinator).
final class EditableTextLayerView: UILabel, EditableLayerView {
  // Read externally at export time to re-composite this layer at its
  // current position/scale/rotation onto the higher-res export canvas.
  private(set) var currentTranslation: CGPoint = .zero
  private(set) var currentScale: CGFloat = 1
  private(set) var currentRotation: CGFloat = 0

  private weak var referenceView: UIView?

  // Lowered from 0.3 per the user's explicit request — 0.3 didn't let a
  // layer shrink small enough.
  private static let minScale: CGFloat = 0.1
  private static let maxScale: CGFloat = 6

  // Stored so setOwnTransformGesturesEnabled can toggle just these 3 (tap
  // and long-press stay enabled always) — see that method's doc.
  private var panGesture: UIPanGestureRecognizer?
  private var pinchGesture: UIPinchGestureRecognizer?
  private var rotationGesture: UIRotationGestureRecognizer?

  /// Fires on long-press — the delete affordance for this layer. Kept as a
  /// plain gesture (not a corner button) since a button positioned at this
  /// view's corner would need its own hit-testing override once the view is
  /// rotated/scaled; long-press needs none of that.
  var onLongPress: (() -> Void)?

  /// Fires on a plain tap — selects this layer, showing the on-canvas
  /// action toolbar (Delete/Duplicate/Edit).
  var onTap: (() -> Void)?

  /// Fires every time pan/pinch/rotate updates this layer's transform —
  /// lets the toolbar track the layer's live on-screen position during a
  /// drag rather than only repositioning once the gesture ends.
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

  /// `referenceView` must be a view that is never itself transformed (the
  /// screen's root view) — translation/rotation/scale are all computed
  /// relative to it, exactly like the image's own gestures.
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

    // Both tap and pan start from the same single-finger touch-down —
    // without this, the two can race for recognition on the same touch,
    // which risked pan (drag-to-move) losing to tap (select) even on a
    // real drag. Making tap explicitly wait for pan to fail first removes
    // that ambiguity: a genuine tap (no real movement) still resolves
    // near-instantly, since pan fails immediately when the touch never
    // moves past its own threshold.
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

  /// Disables (or re-enables) just this layer's OWN pan/pinch/rotate —
  /// tap and long-press stay active either way. Used while this layer is
  /// the VC's `selectedLayer`: the VC's shared, view-wide gesture
  /// recognizers take over manipulating it (via `applyExternalPan`/etc,
  /// below) so pinching/dragging works anywhere on screen, Instagram-
  /// style, not just within this layer's own (possibly tiny, especially
  /// after a big pinch-to-shrink) current bounds — per the user's explicit
  /// request. Without disabling this layer's own recognizers too, a touch
  /// that happens to still land within its bounds would double-apply the
  /// same gesture (once via this layer's own handler, once via the VC's
  /// shared one), a visible "moves/scales twice as fast" bug.
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

  /// Same math as this layer's own `handlePan`, exposed so the VC's
  /// shared, view-wide pan gesture (active only while this layer is
  /// selected) can drive it too — see `setOwnTransformGesturesEnabled`.
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

  /// Text animation (preview only — never part of currentTranslation /
  /// currentScale, so export and gestures are unaffected).
  private(set) var animationState = TextAnimation.State.identity

  func setAnimationState(_ state: TextAnimation.State, canvasSize: CGSize) {
    guard state != animationState || canvasSize != animationCanvasSize else { return }
    animationState = state
    animationCanvasSize = canvasSize
    updateTransform()
  }
  private var animationCanvasSize: CGSize = .zero

  private func updateTransform() {
    clampTranslationWithinBounds()
    var t = CGAffineTransform.identity
    t = t.translatedBy(x: currentTranslation.x + animationState.offsetX * animationCanvasSize.width,
                       y: currentTranslation.y + animationState.offsetY * animationCanvasSize.height)
    t = t.rotated(by: currentRotation + animationState.rotation)
    t = t.scaledBy(x: currentScale * animationState.scale, y: currentScale * animationState.scale)
    transform = t
    updateClipMask()
    updateRenderScale()
    onTransformChanged?()
  }

  /// Clips this layer's rendered content to the canvas box's own screen
  /// rect, recomputed on every transform change — per the user's explicit
  /// "zoomed [layer] should not display outside of that cropper box"
  /// report. `clampTranslationWithinBounds` alone can't prevent this: its
  /// own doc already calls out that an oversized layer (pinched bigger
  /// than the box itself) just gets RE-CENTERED, not resized, so it can
  /// still visually overflow on every side even while "correctly" clamped.
  ///
  /// `convert(_:from:)` does the real work: given the box's FIXED rect in
  /// `referenceView`'s (screen) space, it returns what that same rect maps
  /// to in THIS layer's own pre-transform local (bounds) space — a
  /// CAShapeLayer mask built from bounds-space stays visually pinned to
  /// the box on screen at ANY translation/rotation/scale this layer is
  /// currently at, since UIKit's own geometry engine (not manual math)
  /// computes the mapping.
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
    var localRect = convert(boxRect, from: referenceView)
    if animationState.reveal < 1 {
      // Typewriter: only the left part of the text shows.
      localRect = localRect.intersection(CGRect(x: 0, y: -bounds.height, width: bounds.width * animationState.reveal, height: bounds.height * 3))
    }
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

  /// Sets this layer's starting transform directly — used only when
  /// duplicating an existing layer, to seed the clone at the source's
  /// current translation/scale/rotation (plus a small offset) rather than
  /// starting from identity.
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

  // MARK: - Styled text content
  //
  // Text layers are drawn entirely by TextLayerRenderer (the same code
  // photo and video export use), not by UILabel's own text drawing — so
  // fonts, outline, shadow, background, stretch and arch look identical on
  // screen and in the exported file. `text` is still set so everything
  // that reads a layer's string keeps working. nil for sticker layers.
  private(set) var layerStyle: TextLayerStyle?

  func applyText(_ text: String, style: TextLayerStyle) {
    layerStyle = style
    self.text = text
    invalidateIntrinsicContentSize()
    updateRenderScale(force: true)
    setNeedsDisplay()
  }

  override var intrinsicContentSize: CGSize {
    guard let layerStyle else { return super.intrinsicContentSize }
    return TextLayerRenderer.measure(text: text ?? "", style: layerStyle)
  }

  override func drawText(in rect: CGRect) {
    guard let layerStyle else {
      super.drawText(in: rect)
      return
    }
    let scale = contentScaleFactor
    guard let rendered = TextLayerRenderer.render(text: text ?? "", style: layerStyle, scale: scale) else { return }
    let size = CGSize(width: CGFloat(rendered.image.width) / scale, height: CGFloat(rendered.image.height) / scale)
    let origin = CGPoint(x: bounds.midX - rendered.size.width / scale / 2, y: bounds.midY - rendered.size.height / scale / 2)
    UIImage(cgImage: rendered.image).draw(in: CGRect(origin: origin, size: size))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // The clip mask is built from bounds, which change whenever the
    // text's style (size, stretch, arch…) changes.
    if layerStyle != nil { updateClipMask() }
  }

  /// Renders sharper while the layer is pinched bigger (the transform
  /// scales the drawn bitmap), capped so a huge layer can't allocate a
  /// huge bitmap.
  private func updateRenderScale(force: Bool = false) {
    guard layerStyle != nil else { return }
    let screenScale = window?.screen.scale ?? UIScreen.main.scale
    var desired = (screenScale * min(max(currentScale, 1), 4) * 2).rounded() / 2
    let size = intrinsicContentSize
    let maxPixels: CGFloat = 12_000_000
    if size.width * size.height * desired * desired > maxPixels {
      desired = max(screenScale, (maxPixels / max(size.width * size.height, 1)).squareRoot())
    }
    if force || abs(contentScaleFactor - desired) > 0.01 {
      contentScaleFactor = desired
      setNeedsDisplay()
    }
  }

  // MARK: - Sticker image content (bundled asset stickers)
  //
  // Real graphic stickers (bundled Twemoji artwork) stay on this SAME
  // class rather than a separate view type, per the user's explicit
  // "replace fake emoji-as-text stickers with real stickers" request —
  // every existing text/sticker code path (undo/redo, per-layer time-
  // range grouping, split/select/delete, gestures, export) is keyed off
  // `EditableTextLayerView`/`stickerLayerViews` and keeps working
  // unchanged; only the rendered CONTENT swaps from a text glyph to a
  // bundled image. See MediaEditorViewController.addStickerLayer.
  private(set) var stickerAssetName: String?
  private var stickerImageView: UIImageView?
  private var stickerWidthConstraint: NSLayoutConstraint?
  private var stickerHeightConstraint: NSLayoutConstraint?

  var isStickerImageLayer: Bool { stickerAssetName != nil }

  /// The image this sticker currently displays — read by export/duplicate
  /// instead of re-loading `UIImage(named: stickerAssetName)`, since a
  /// location sticker's image is generated at runtime, not a bundled asset.
  var stickerImage: UIImage? { stickerImageView?.image }

  /// Story-mode location sticker state (nil for every other layer) — the
  /// place name + current style index, so tap-to-cycle/Edit/Duplicate can
  /// re-render the pill. See MediaEditorViewController.addLocationLayer.
  var locationName: String?
  var locationStyle: Int = 0
  /// The place's coordinate, when known — returned with the export result
  /// so story viewers can open it in Maps.
  var locationLatitude: Double?
  var locationLongitude: Double?
  var isLocationLayer: Bool { locationName != nil }
  /// Story info pills share the location pill: "location", "link",
  /// "hashtag", "time" or "date". `infoValue` = the link URL / the tag.
  var infoKind = "location"
  var infoValue: String?

  /// Initial on-screen size (points) for a newly-placed sticker image —
  /// fixed rather than derived from intrinsicContentSize (which a UILabel
  /// with no text/attributedText would compute as ~zero). Pinch-to-resize
  /// afterwards works exactly like text layers: via `currentScale`'s
  /// transform, not by changing this frame.
  private static let stickerImageSize: CGFloat = 64

  /// Look of a bundled sticker (opacity/flip/outline/shadow). The styled
  /// image becomes `stickerImage` and the layer grows to fit its outline/
  /// shadow, so export (which draws `stickerImage` into `bounds`) needs no
  /// special handling.
  private(set) var stickerStyle = StickerStyle()
  private var baseStickerImage: UIImage?
  private var baseStickerSize: CGSize = .zero

  /// Bundled stickers can be styled; location pills can't.
  var canStyleSticker: Bool { stickerAssetName != nil && !isLocationLayer }

  /// `size` defaults to the fixed square used by bundled stickers; a
  /// location sticker passes its pill's own (non-square) size. Keeps the
  /// current sticker style (e.g. when swapping the sticker via Edit).
  func applyStickerImage(_ image: UIImage, assetName: String, size: CGSize? = nil) {
    stickerAssetName = assetName
    baseStickerImage = image
    baseStickerSize = size ?? CGSize(width: Self.stickerImageSize, height: Self.stickerImageSize)
    renderSticker()
  }

  func applyStickerStyle(_ style: StickerStyle) {
    stickerStyle = style
    renderSticker()
  }

  private func renderSticker() {
    guard let baseStickerImage else { return }
    let rendered = StickerStyleRenderer.render(baseStickerImage, size: baseStickerSize, style: stickerStyle)
    let targetSize = rendered.size
    text = nil
    attributedText = nil
    if stickerImageView == nil {
      let imageView = UIImageView()
      imageView.contentMode = .scaleAspectFit
      imageView.isUserInteractionEnabled = false
      imageView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(imageView)
      NSLayoutConstraint.activate([
        imageView.topAnchor.constraint(equalTo: topAnchor),
        imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
        imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      ])
      let width = widthAnchor.constraint(equalToConstant: targetSize.width)
      let height = heightAnchor.constraint(equalToConstant: targetSize.height)
      NSLayoutConstraint.activate([width, height])
      stickerWidthConstraint = width
      stickerHeightConstraint = height
      stickerImageView = imageView
    }
    stickerWidthConstraint?.constant = targetSize.width
    stickerHeightConstraint?.constant = targetSize.height
    stickerImageView?.image = rendered.image
  }
}

extension EditableTextLayerView: UIGestureRecognizerDelegate {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }
}
