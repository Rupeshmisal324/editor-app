import UIKit

/// Full-screen overlay shown while a video export runs — per the user's
/// explicit "user should wait until video is completely export, add UI for
/// that" request, matching a reference screenshot: a large percentage,
/// a "don't close the app" warning, and a rounded video-frame preview
/// traced by an animated rainbow progress ring (Instagram-story-ring
/// style) that fills in around the frame's perimeter as export advances.
/// Purely a display + cancel-button surface — owns no export logic itself;
/// the presenting controller calls `updateProgress`/`showCompleted` and
/// reads `onCancel`.
final class ExportProgressView: UIView {
  /// Fired when the user taps the close (X) button — the presenting
  /// controller is responsible for actually cancelling the underlying
  /// AVAssetExportSession and dismissing this view; this view never
  /// dismisses itself, so a cancel that fails/needs confirmation doesn't
  /// leave the UI in a confusing half-dismissed state.
  var onCancel: (() -> Void)?

  private let closeButton = UIButton(type: .system)
  private let percentageLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let previewContainer = UIView()
  private let previewImageView = UIImageView()
  private let placeholderView = UIStackView()
  // Two-layer approach: a full rainbow CAGradientLayer, masked by a
  // CAShapeLayer stroking the SAME rounded-rect path as previewContainer's
  // own border — only the masked (stroked) portion of the gradient is
  // visible, and animating the mask's strokeEnd from 0→1 makes the visible
  // gradient "trace around" the frame's perimeter as progress advances.
  private let progressGradientLayer = CAGradientLayer()
  private let progressMaskLayer = CAShapeLayer()
  private static let previewCornerRadius: CGFloat = 24
  // Widened from 4 per the user's explicit "increase the border width"
  // request — the reference screenshot's ring reads as a substantially
  // thicker band than a thin 4pt line.
  private static let ringWidth: CGFloat = 10
  private static let ringInset: CGFloat = 10

  // Smoothing: AVAssetExportSession.progress (see startExportProgressPolling's
  // own doc) reports in coarse, infrequent jumps on-device — e.g. sitting
  // at 0 then suddenly reporting 40%, then jumping straight to 55%, 70% —
  // per the user's explicit "it's jumping by 10%, 15%... feels fake, make
  // it increase smoothly in decimal points, don't make it fast" report.
  // Rather than display that raw, jumpy value directly, a CADisplayLink
  // eases a locally-tracked `displayedProgress` toward the latest reported
  // `targetProgress` at a fixed, deliberately gentle ceiling rate — real
  // jumps in the underlying value become a smooth climb instead of a
  // visible snap, and the ceiling keeps it from ever rushing to catch up.
  private var displayedProgress: Float = 0
  private var targetProgress: Float = 0
  private var displayLink: CADisplayLink?
  // ~12%/second ceiling at 60fps — smooth and visibly gradual without
  // feeling sluggish; tune here if it still reads as too fast/slow.
  private static let maxProgressPerFrame: Float = 0.002

  override init(frame: CGRect) {
    super.init(frame: frame)
    setUp()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setUp() {
    backgroundColor = EditorDesignTokens.Colors.canvasBackground

    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.tintColor = EditorDesignTokens.Colors.textPrimary
    closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
    closeButton.translatesAutoresizingMaskIntoConstraints = false

    percentageLabel.font = .systemFont(ofSize: 34, weight: .bold)
    percentageLabel.textColor = EditorDesignTokens.Colors.textPrimary
    percentageLabel.textAlignment = .center
    percentageLabel.text = "0.0%"
    percentageLabel.translatesAutoresizingMaskIntoConstraints = false

    subtitleLabel.font = .systemFont(ofSize: 15)
    subtitleLabel.textColor = EditorDesignTokens.Colors.textSecondary
    subtitleLabel.textAlignment = .center
    subtitleLabel.text = "Please don't close the app or lock your screen."
    subtitleLabel.numberOfLines = 0
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

    previewContainer.backgroundColor = .black
    previewContainer.layer.cornerRadius = Self.previewCornerRadius
    previewContainer.layer.cornerCurve = .continuous
    previewContainer.clipsToBounds = true
    previewContainer.translatesAutoresizingMaskIntoConstraints = false

    previewImageView.contentMode = .scaleAspectFit
    previewImageView.backgroundColor = .black
    previewImageView.translatesAutoresizingMaskIntoConstraints = false

    // Rainbow gradient — deliberately vivid, not one of the muted design
    // tokens, matching the reference screenshot's own ring exactly.
    progressGradientLayer.colors = [
      UIColor.systemRed.cgColor,
      UIColor.systemOrange.cgColor,
      UIColor.systemPink.cgColor,
      UIColor.systemPurple.cgColor,
      UIColor.systemBlue.cgColor,
      UIColor.systemRed.cgColor,
    ]
    progressGradientLayer.startPoint = CGPoint(x: 0, y: 0)
    progressGradientLayer.endPoint = CGPoint(x: 1, y: 1)

    progressMaskLayer.fillColor = nil
    progressMaskLayer.strokeColor = UIColor.white.cgColor
    progressMaskLayer.lineWidth = Self.ringWidth
    progressMaskLayer.lineCap = .round
    progressMaskLayer.strokeEnd = 0
    progressGradientLayer.mask = progressMaskLayer

    addSubview(closeButton)
    addSubview(percentageLabel)
    addSubview(subtitleLabel)
    addSubview(previewContainer)
    previewContainer.addSubview(previewImageView)
    // Placeholder until (or if never) a real frame arrives, so the box is
    // never just empty. Same as Android.
    let placeholderIcon = UIImageView(image: UIImage(systemName: "play.rectangle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)))
    placeholderIcon.tintColor = EditorDesignTokens.Colors.textSecondary
    let placeholderText = UILabel()
    placeholderText.text = "Exporting your video"
    placeholderText.font = .systemFont(ofSize: 13)
    placeholderText.textColor = EditorDesignTokens.Colors.textSecondary
    placeholderView.axis = .vertical
    placeholderView.alignment = .center
    placeholderView.spacing = 10
    placeholderView.addArrangedSubview(placeholderIcon)
    placeholderView.addArrangedSubview(placeholderText)
    placeholderView.translatesAutoresizingMaskIntoConstraints = false
    previewContainer.addSubview(placeholderView)
    NSLayoutConstraint.activate([
      placeholderView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
      placeholderView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
    ])
    layer.addSublayer(progressGradientLayer)

    let safe = safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
      closeButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
      closeButton.widthAnchor.constraint(equalToConstant: EditorDesignTokens.Spacing.minTapTarget),
      closeButton.heightAnchor.constraint(equalToConstant: EditorDesignTokens.Spacing.minTapTarget),

      percentageLabel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 24),
      percentageLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
      percentageLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),

      subtitleLabel.topAnchor.constraint(equalTo: percentageLabel.bottomAnchor, constant: 8),
      subtitleLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 32),
      subtitleLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -32),

      previewContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 40),
      previewContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
      previewContainer.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -80),
      previewContainer.widthAnchor.constraint(equalToConstant: 220),
      previewContainer.heightAnchor.constraint(equalToConstant: 380),
      previewContainer.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -24),

      previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
      previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
      previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
      previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // The ring sits OUTSIDE previewContainer's own bounds (ringInset), so
    // it reads as a distinct animated border rather than overlapping the
    // video frame's own content — matches the reference screenshot, where
    // the gradient ring is clearly a separate frame around the preview,
    // not drawn on top of it.
    let ringRect = previewContainer.frame.insetBy(dx: -Self.ringInset, dy: -Self.ringInset)
    progressGradientLayer.frame = ringRect
    let ringPath = Self.topCenterRoundedRectPath(
      CGRect(origin: .zero, size: ringRect.size),
      radius: Self.previewCornerRadius + Self.ringInset
    )
    progressMaskLayer.path = ringPath.cgPath
    progressMaskLayer.frame = CGRect(origin: .zero, size: ringRect.size)
  }

  /// A rounded rect traced clockwise from the TOP CENTER (UIBezierPath's
  /// own rounded rect starts at the top-left corner), so the progress line
  /// grows out of the middle of the top edge. Same as Android.
  private static func topCenterRoundedRectPath(_ rect: CGRect, radius: CGFloat) -> UIBezierPath {
    let r = min(radius, rect.width / 2, rect.height / 2)
    let path = UIBezierPath()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    path.addArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    path.addArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
    path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    path.addArc(withCenter: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    path.addArc(withCenter: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
    path.close()
    return path
  }

  /// `image` is a one-time snapshot of the canvas at the moment export
  /// started (this view has no access to a live player) — set once, not
  /// updated per-frame.
  func configure(previewImage: UIImage?) {
    previewImageView.image = previewImage
    placeholderView.isHidden = previewImage != nil
  }

  /// `progress` is 0...1, straight from the caller's raw (possibly jumpy)
  /// polling of the real export session — this only records it as the
  /// NEW TARGET; `tick()` is what actually moves the visible percentage/
  /// ring toward it, smoothly, over time. Starts the display link on
  /// first call rather than in `setUp()` so nothing animates before an
  /// export is actually reporting progress.
  func updateProgress(_ progress: Float) {
    targetProgress = max(0, min(1, progress))
    if displayLink == nil {
      let link = CADisplayLink(target: self, selector: #selector(tick))
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
  }

  /// Jumps the displayed value straight to 100% and stops the display
  /// link — called once the export has actually finished, so completion
  /// is never left waiting on the smoothing catching up.
  func finishProgress() {
    targetProgress = 1
    displayedProgress = 1
    applyDisplayedProgress()
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc private func tick() {
    guard displayedProgress < targetProgress else { return }
    displayedProgress = min(targetProgress, displayedProgress + Self.maxProgressPerFrame)
    applyDisplayedProgress()
  }

  private func applyDisplayedProgress() {
    percentageLabel.text = String(format: "%.1f%%", displayedProgress * 100)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progressMaskLayer.strokeEnd = CGFloat(displayedProgress)
    CATransaction.commit()
  }

  @objc private func didTapClose() {
    onCancel?()
  }

  deinit {
    displayLink?.invalidate()
  }
}
