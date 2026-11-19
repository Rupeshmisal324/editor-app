import UIKit

/// Generic reusable slide-up contextual panel shell: drag handle, a
/// title + confirm-button header, and a content slot (`contentContainer`)
/// that per-tool panels plug their own content into (today: the Effects
/// tab's filter row + adjustment sliders). UI-only — this view has no
/// knowledge of filters/crop/text/stickers, it only hosts them.
///
/// Collapsed height is fixed (`EditorDesignTokens.Spacing.panelCollapsedHeight`);
/// dragging the handle expands it up to
/// `EditorDesignTokens.Spacing.panelExpandedHeightFraction` of the screen
/// height. Expanding OVERLAYS the canvas rather than resizing it — the
/// canvas box is sized once from the photo's own aspect ratio (see
/// MediaEditorViewController's `imageContentAreaGuide` setup) and must stay
/// geometrically stable, since text/sticker layer positioning and export
/// math both anchor to the canvas's own center — so nothing about this
/// panel's height ever feeds back into the canvas's own constraints.
final class SlideUpPanelView: UIView {
  let contentContainer = UIView()
  private let handle = UIView()
  private let titleLabel = UILabel()
  let confirmButton = UIButton(type: .system)
  /// Redesign Phase 5: ✕ in the header, left of the title — shown only
  /// when `onCancel` is set (cancel = put the tool's changes back).
  let cancelButton = UIButton(type: .system)
  private var titleLeadingDefault: NSLayoutConstraint!
  private var titleLeadingAfterCancel: NSLayoutConstraint!
  var onCancel: (() -> Void)? {
    didSet {
      cancelButton.isHidden = onCancel == nil
      titleLeadingDefault.isActive = onCancel == nil
      titleLeadingAfterCancel.isActive = onCancel != nil
    }
  }

  private var heightConstraint: NSLayoutConstraint!
  private var contentTopConstraint: NSLayoutConstraint!
  private var contentBottomConstraint: NSLayoutConstraint!
  /// Mockup Filters / Text sheets: the header moves to a bottom bar
  /// (✕ · title [· accessory] · ✓) above the home indicator.
  private var bottomBar: UIView?
  private let barTitleLabel = UILabel()
  private var isBottomBarMode = false
  /// Height the caller asked for (header-style layout); the real height
  /// adds the bottom bar's difference on top.
  private var requestedCollapsedHeight: CGFloat
  private var collapsedHeight: CGFloat
  private var expandedHeight: CGFloat
  private var panStartHeight: CGFloat = 0

  var onConfirm: (() -> Void)?

  /// `collapsedHeight` defaults to the standard token (Sticker/Draw/Music's
  /// content all needs that much room) but is overridable — the Effect/Edit
  /// panels' content (a filter row / an adjustment icon row) is much more
  /// compact, and using the standard height for those would leave a large
  /// dead empty area below their actual content.
  init(title: String, collapsedHeight: CGFloat = EditorDesignTokens.Spacing.panelCollapsedHeight) {
    self.collapsedHeight = collapsedHeight
    self.requestedCollapsedHeight = collapsedHeight
    self.expandedHeight = collapsedHeight
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    // Liquid Glass sheet (see GlassSurfaceView), top corners rounded.
    GlassSurfaceView.install(behind: self, shape: .topRounded(EditorDesignTokens.Spacing.panelCornerRadius))
    layer.cornerRadius = EditorDesignTokens.Spacing.panelCornerRadius
    layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    clipsToBounds = true

    handle.backgroundColor = EditorDesignTokens.Colors.divider
    handle.layer.cornerRadius = 2.5
    handle.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.text = title
    titleLabel.textColor = EditorDesignTokens.Colors.textPrimary
    titleLabel.font = EditorDesignTokens.Typography.panelTitle
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    // Text "Done" (not a checkmark icon) per the user's explicit request —
    // reads more clearly as "finish and close this panel" than a bare glyph.
    confirmButton.setTitle("Done", for: .normal)
    // Matches the top bar's Cancel/Done/Undo/Redo (all textPrimary/white)
    // per the user's explicit "use same color of cancel and done and undo
    // and redo" request — was the editor's own accent purple, visually
    // inconsistent with every other Done/Cancel control in the editor.
    confirmButton.setTitleColor(EditorDesignTokens.Colors.selectedToolTint, for: .normal)
    confirmButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    confirmButton.translatesAutoresizingMaskIntoConstraints = false
    confirmButton.addTarget(self, action: #selector(didTapConfirm), for: .touchUpInside)

    contentContainer.translatesAutoresizingMaskIntoConstraints = false

    addSubview(handle)
    addSubview(titleLabel)
    addSubview(confirmButton)
    addSubview(contentContainer)
    cancelButton.setImage(UIImage(named: "ui_close")?.withRenderingMode(.alwaysTemplate), for: .normal)
    cancelButton.tintColor = EditorDesignTokens.Colors.textPrimary
    cancelButton.accessibilityLabel = "Cancel"
    cancelButton.isHidden = true
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.addTarget(self, action: #selector(didTapCancelButton), for: .touchUpInside)
    addSubview(cancelButton)

    heightConstraint = heightAnchor.constraint(equalToConstant: collapsedHeight)
    heightConstraint.isActive = true

    let tapTarget = EditorDesignTokens.Spacing.minTapTarget
    titleLeadingDefault = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
    titleLeadingAfterCancel = titleLabel.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 2)
    titleLeadingDefault.isActive = true
    NSLayoutConstraint.activate([
      // Compact header (~45pt: handle, title row) — same as Android.
      handle.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      handle.centerXAnchor.constraint(equalTo: centerXAnchor),
      handle.widthAnchor.constraint(equalToConstant: 36),
      handle.heightAnchor.constraint(equalToConstant: 5),

      titleLabel.topAnchor.constraint(equalTo: handle.bottomAnchor, constant: 6),

      cancelButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      cancelButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      cancelButton.widthAnchor.constraint(equalToConstant: tapTarget),
      cancelButton.heightAnchor.constraint(equalToConstant: tapTarget),

      confirmButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      confirmButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      confirmButton.heightAnchor.constraint(equalToConstant: tapTarget),

      contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    contentTopConstraint = contentContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8)
    contentBottomConstraint = contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
    contentTopConstraint.isActive = true
    contentBottomConstraint.isActive = true

    // Widen the handle's own effective touch target beyond its visual
    // 36x5pt strip by recognizing the pan on the whole top ~20pt band
    // instead — done by attaching the gesture to `self` and checking the
    // touch's starting point, rather than to `handle` directly, so a
    // slightly-off-target drag still works.
    let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    addGestureRecognizer(panGesture)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Adjusts the collapsed (and, unless `configureExpandedHeight` is called
  /// separately, expanded) height after construction — needed for panels
  /// whose correct height depends on state not yet known at property-
  /// initializer time (e.g. `isImage`, which isn't available until `init`
  /// runs), so it can't just be passed to `init(title:collapsedHeight:)`.
  /// `animated` slides the height change (e.g. the Filters panel growing
  /// when its slider rows appear); only animates while on screen.
  /// Height when not dragged open — what the picture above must fit around.
  var restingHeight: CGFloat { collapsedHeight }

  func setCollapsedHeight(_ requested: CGFloat, animated: Bool = false) {
    requestedCollapsedHeight = requested
    let height = requested + bottomBarExtraHeight
    guard height != collapsedHeight || heightConstraint.constant != height else { return }
    collapsedHeight = height
    expandedHeight = height
    heightConstraint.constant = height
    guard animated, !isHidden, window != nil else { return }
    UIView.animate(
      withDuration: EditorDesignTokens.Motion.panelToggleDuration,
      delay: 0,
      options: [.curveEaseOut, .beginFromCurrentState],
      animations: { self.superview?.layoutIfNeeded() }
    )
  }

  /// Called once (viewDidLoad) — the expanded height is a fraction of the
  /// SCREEN, not this view's own bounds, which aren't meaningfully
  /// resolved yet at that point anyway.
  func configureExpandedHeight(screenHeight: CGFloat) {
    expandedHeight = screenHeight * EditorDesignTokens.Spacing.panelExpandedHeightFraction
  }

  /// Bottom-bar mode adds (bar + home indicator + top padding) and drops
  /// the handle/title header and the old bottom padding.
  private var bottomBarExtraHeight: CGFloat {
    guard isBottomBarMode else { return 0 }
    let titleHeight: CGFloat = ceil(titleLabel.font.lineHeight)
    let oldHeader: CGFloat = 37 + titleHeight
    let safeBottom: CGFloat = window?.safeAreaInsets.bottom ?? safeAreaInsets.bottom
    return 80 + safeBottom - oldHeader
  }

  /// Mockup Filters / Text sheet: no handle or header; a bottom bar with
  /// ✕ (onCancel) · title [· accessory icon] · ✓ (onConfirm) instead.
  func useBottomActionBar(title: String, accessoryImageName: String? = nil, accessoryLabel: String? = nil, onAccessory: (() -> Void)? = nil) {
    guard !isBottomBarMode else { return }
    isBottomBarMode = true
    handle.isHidden = true
    titleLabel.isHidden = true
    confirmButton.isHidden = true
    cancelButton.alpha = 0
    cancelButton.isUserInteractionEnabled = false

    let bar = UIView()
    bar.translatesAutoresizingMaskIntoConstraints = false
    let hairline = UIView()
    hairline.backgroundColor = EditorDesignTokens.Colors.divider
    hairline.translatesAutoresizingMaskIntoConstraints = false
    func icon(_ name: String, _ label: String, tint: UIColor) -> UIButton {
      let button = UIButton(type: .system)
      button.setImage(UIImage(named: name)?.withRenderingMode(.alwaysTemplate), for: .normal)
      button.tintColor = tint
      button.accessibilityLabel = label
      button.translatesAutoresizingMaskIntoConstraints = false
      button.widthAnchor.constraint(equalToConstant: 48).isActive = true
      button.heightAnchor.constraint(equalToConstant: 48).isActive = true
      return button
    }
    let cancel = icon("ui_close", "Cancel \(title)", tint: EditorDesignTokens.Colors.textPrimary)
    cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
    let apply = icon("ui_check", "Apply \(title)", tint: EditorDesignTokens.Colors.selectedToolTint)
    apply.addAction(UIAction { [weak self] _ in self?.onConfirm?() }, for: .touchUpInside)
    barTitleLabel.text = title
    barTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    barTitleLabel.textColor = EditorDesignTokens.Colors.textPrimary
    let center = UIStackView(arrangedSubviews: [barTitleLabel])
    center.spacing = 14
    center.alignment = .center
    center.translatesAutoresizingMaskIntoConstraints = false
    if let accessoryImageName {
      let accessory = icon(accessoryImageName, accessoryLabel ?? title, tint: EditorDesignTokens.Colors.textPrimary)
      accessory.addAction(UIAction { _ in onAccessory?() }, for: .touchUpInside)
      center.addArrangedSubview(accessory)
    }
    for v in [hairline, cancel, center, apply] as [UIView] { bar.addSubview(v) }
    addSubview(bar)
    bottomBar = bar

    contentTopConstraint.isActive = false
    contentBottomConstraint.isActive = false
    contentTopConstraint = contentContainer.topAnchor.constraint(equalTo: topAnchor, constant: 12)
    contentBottomConstraint = contentContainer.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -4)
    NSLayoutConstraint.activate([
      contentTopConstraint,
      contentBottomConstraint,
      bar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor),
      bar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
      bar.heightAnchor.constraint(equalToConstant: 64),
      hairline.topAnchor.constraint(equalTo: bar.topAnchor),
      hairline.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1),
      cancel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
      cancel.centerYAnchor.constraint(equalTo: bar.topAnchor, constant: 30),
      apply.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
      apply.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
      center.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
      center.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
    ])
    setCollapsedHeight(requestedCollapsedHeight)
  }

  /// Bottom-bar title (e.g. "Text" / "Overlay" / "Sticker").
  func setBarTitle(_ title: String) {
    barTitleLabel.text = title
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if isBottomBarMode { setCollapsedHeight(requestedCollapsedHeight) }
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    if isBottomBarMode { setCollapsedHeight(requestedCollapsedHeight) }
  }

  /// Mockup Tools sheet: a ✕ in place of "Done" (same action: close).
  func useCloseIconForConfirm() {
    confirmButton.setTitle(nil, for: .normal)
    confirmButton.setImage(UIImage(named: "ui_close")?.withRenderingMode(.alwaysTemplate), for: .normal)
    confirmButton.tintColor = EditorDesignTokens.Colors.textPrimary
    confirmButton.accessibilityLabel = "Close"
  }

  @objc private func didTapCancelButton() {
    onCancel?()
  }

  @objc private func didTapConfirm() {
    onConfirm?()
  }

  /// Called when the panel is dragged down to close. Defaults to the same
  /// action as Done.
  var onDismissByDrag: (() -> Void)?

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    switch gesture.state {
    case .began:
      // Drag starts on the header (handle + title row) only, so it never
      // fights the content's own sliders/scrolling.
      guard gesture.location(in: self).y <= contentContainer.frame.minY else {
        gesture.state = .cancelled
        return
      }
      panStartHeight = heightConstraint.constant
    case .changed:
      let translation = gesture.translation(in: self)
      let newHeight = panStartHeight - translation.y
      if newHeight >= collapsedHeight {
        transform = .identity
        heightConstraint.constant = min(newHeight, expandedHeight)
        superview?.layoutIfNeeded()
      } else {
        // Below the collapsed height: slide the whole panel down.
        heightConstraint.constant = collapsedHeight
        transform = CGAffineTransform(translationX: 0, y: collapsedHeight - newHeight)
      }
    case .ended, .cancelled:
      let pulledDown = transform.ty
      if pulledDown > 0 {
        let velocity = gesture.velocity(in: superview).y
        if gesture.state == .ended && (pulledDown > 70 || velocity > 700) {
          dismissByDrag()
        } else {
          UIView.animate(withDuration: EditorDesignTokens.Motion.panelToggleDuration, delay: 0, options: .curveEaseOut) {
            self.transform = .identity
          }
        }
        return
      }
      let midpoint = (collapsedHeight + expandedHeight) / 2
      setExpanded(heightConstraint.constant > midpoint, animated: true)
    default:
      break
    }
  }

  private func dismissByDrag() {
    UIView.animate(
      withDuration: EditorDesignTokens.Motion.panelToggleDuration,
      delay: 0,
      options: .curveEaseIn,
      animations: { self.transform = CGAffineTransform(translationX: 0, y: self.bounds.height) },
      completion: { _ in
        self.isHidden = true
        self.alpha = 0
        self.transform = .identity
        self.setExpanded(false, animated: false)
        (self.onDismissByDrag ?? self.onConfirm)?()
      }
    )
  }

  func setExpanded(_ expanded: Bool, animated: Bool) {
    heightConstraint.constant = expanded ? expandedHeight : collapsedHeight
    guard animated else {
      superview?.layoutIfNeeded()
      return
    }
    UIView.animate(
      withDuration: EditorDesignTokens.Motion.panelToggleDuration,
      delay: 0,
      options: .curveEaseOut,
      animations: { self.superview?.layoutIfNeeded() }
    )
  }

  /// Show/hide with a slide+fade, distinct from setExpanded's height
  /// resize — this is the panel appearing/disappearing entirely (switching
  /// tabs), not the drag-to-expand interaction.
  func setPanelVisible(_ visible: Bool, animated: Bool) {
    if visible {
      isHidden = false
      guard animated else {
        alpha = 1
        transform = .identity
        return
      }
      alpha = 0
      transform = CGAffineTransform(translationX: 0, y: 24)
      UIView.animate(withDuration: EditorDesignTokens.Motion.panelToggleDuration, delay: 0, options: .curveEaseOut) {
        self.alpha = 1
        self.transform = .identity
      }
    } else {
      guard animated else {
        isHidden = true
        return
      }
      UIView.animate(
        withDuration: EditorDesignTokens.Motion.panelToggleDuration,
        delay: 0,
        options: .curveEaseOut,
        animations: {
          self.alpha = 0
          self.transform = CGAffineTransform(translationX: 0, y: 24)
        },
        completion: { _ in
          self.isHidden = true
          self.transform = .identity
          // Collapse back down so it starts fresh (not still expanded)
          // the next time it's shown.
          self.setExpanded(false, animated: false)
        }
      )
    }
  }
}
