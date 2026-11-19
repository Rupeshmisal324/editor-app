import UIKit

/// Freehand draw/brush layer — pinned to exactly match imageView's own box
/// (see MediaEditorViewController.setUpDrawingCanvas), so a raw touch point
/// recorded here is already in the SAME local coordinate space as the
/// photo, needing only a straight `* exportScale` at export time.
///
/// Uses plain UIView touch overrides rather than a UIGestureRecognizer:
/// `isUserInteractionEnabled` toggles whether this view participates in
/// hit-testing at all (see MediaEditorViewController.updateImageEditorUI).
///
/// Every stroke — live preview, photo export, video export, brush tile
/// previews — is drawn by `DrawingCanvasView.draw(_:scale:in:)`, so they
/// always match. Android's DrawingCanvasView.kt is a line-by-line port
/// (same brushes, constants and pattern hash): change both together.
final class DrawingCanvasView: UIView {
  /// Raw values are saved in re-edit projects — never rename one.
  enum BrushType: String, CaseIterable {
    case pen, marker, highlighter, neon, dotted, spray, chalk, squares
    /// Clears earlier strokes (never the photo — strokes are always drawn
    /// into their own transparent layer).
    case eraser

    var title: String {
      switch self {
      case .pen: return "Pen"
      case .marker: return "Marker"
      case .highlighter: return "Highlighter"
      case .neon: return "Neon"
      case .dotted: return "Dotted"
      case .spray: return "Spray"
      case .chalk: return "Chalk"
      case .squares: return "Squares"
      case .eraser: return "Eraser"
      }
    }
  }

  /// Drag-to-size shapes, outlined with the selected brush. Raw values
  /// are saved in re-edit projects — never rename one.
  enum ShapeType: String, CaseIterable {
    case line, arrow, rectangle, oval, triangle, star, heart

    var title: String {
      switch self {
      case .line: return "Line"
      case .arrow: return "Arrow"
      case .rectangle: return "Rectangle"
      case .oval: return "Oval"
      case .triangle: return "Triangle"
      case .star: return "Star"
      case .heart: return "Heart"
      }
    }
  }

  /// Reference type so undo/redo can remove the exact instance (`===`).
  final class Stroke {
    var points: [CGPoint]
    let color: UIColor
    var widthPoints: CGFloat
    let brushType: BrushType
    /// Fixes the random texture (spray/chalk/squares) so it's identical on
    /// every redraw, in the export, and after re-opening the project.
    let seed: UInt32
    /// Non-nil for a shape: `points` is then just [drag start, drag end].
    let shape: ShapeType?
    init(points: [CGPoint], color: UIColor, widthPoints: CGFloat, brushType: BrushType = .pen, seed: UInt32 = 0, shape: ShapeType? = nil) {
      self.points = points
      self.color = color
      self.widthPoints = widthPoints
      self.brushType = brushType
      self.seed = seed
      self.shape = shape
    }
  }

  private(set) var strokes: [Stroke] = []
  private var currentPoints: [CGPoint] = []
  private var currentSeed: UInt32 = 0

  var currentColor: UIColor = .white
  var currentWidthPoints: CGFloat = 6
  var currentBrushType: BrushType = .pen
  /// Non-nil while the Shape tool is active: a drag draws this shape.
  var currentShape: ShapeType?

  /// Committed strokes rendered once, so a long drawing doesn't re-render
  /// every stroke on every finger move. Rebuilt when strokes change.
  private var committedImage: UIImage?

  /// Fired once a stroke is committed (finger lifted).
  var onStrokeFinished: ((Stroke) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func addStroke(_ stroke: Stroke) {
    strokes.append(stroke)
    invalidateCommitted()
  }

  func removeStroke(_ stroke: Stroke) {
    if let index = strokes.firstIndex(where: { $0 === stroke }) {
      strokes.remove(at: index)
    }
    invalidateCommitted()
  }

  private func invalidateCommitted() {
    committedImage = nil
    setNeedsDisplay()
  }

  private var committedSize: CGSize = .zero

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.size != committedSize {
      committedSize = bounds.size
      invalidateCommitted()
    }
  }

  /// Scales strokes in place when the canvas resizes (see
  /// MediaEditorViewController.updateCanvasSizeForLayers), keeping the same
  /// instances so undo/redo identity still works.
  func rescaleForCanvasResize(by factor: CGFloat) {
    guard factor != 1 else { return }
    for stroke in strokes {
      stroke.points = stroke.points.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
      stroke.widthPoints *= factor
    }
    currentPoints = currentPoints.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
    invalidateCommitted()
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    currentPoints = [touch.location(in: self)]
    currentSeed = UInt32.random(in: 1...UInt32.max)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    if currentShape != nil, let start = currentPoints.first {
      currentPoints = [start, touch.location(in: self)]
    } else {
      currentPoints.append(touch.location(in: self))
    }
    setNeedsDisplay()
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    finishStroke()
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    finishStroke()
  }

  private func finishStroke() {
    if currentPoints.count > 1, currentShape == nil || Self.dragLength(currentPoints) > 4 {
      let stroke = Stroke(
        points: currentPoints, color: currentColor, widthPoints: currentWidthPoints,
        brushType: currentBrushType, seed: currentSeed, shape: currentShape
      )
      strokes.append(stroke)
      // Bake it into the cached image instead of re-rendering everything.
      if let committedImage {
        self.committedImage = UIGraphicsImageRenderer(bounds: bounds).image { context in
          committedImage.draw(in: bounds)
          Self.draw(stroke, scale: 1, in: context.cgContext)
        }
      }
      onStrokeFinished?(stroke)
    }
    currentPoints = []
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    if committedImage == nil, !strokes.isEmpty, bounds.width > 0, bounds.height > 0 {
      committedImage = UIGraphicsImageRenderer(bounds: bounds).image { context in
        Self.draw(strokes, scale: 1, in: context.cgContext)
      }
    }
    committedImage?.draw(in: bounds)
    if currentPoints.count > 1 {
      // The view's own layer is transparent, so the eraser's clear blend
      // only clears drawing, never the photo underneath.
      Self.draw(
        Stroke(points: currentPoints, color: currentColor, widthPoints: currentWidthPoints, brushType: currentBrushType, seed: currentSeed, shape: currentShape),
        scale: 1, in: ctx
      )
    }
  }

  // MARK: - Shared stroke rendering

  /// Draws `strokes` in order into their OWN transparency layer, so an
  /// eraser stroke clears earlier strokes but not whatever `ctx` already
  /// holds (the photo, in photo export). Used by photo/video export.
  static func draw(_ strokes: [Stroke], scale: CGFloat, in ctx: CGContext) {
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for stroke in strokes { draw(stroke, scale: scale, in: ctx) }
    ctx.endTransparencyLayer()
  }

  /// One stroke, with points/width in canvas points multiplied by `scale`.
  static func draw(_ stroke: Stroke, scale: CGFloat, in ctx: CGContext) {
    guard stroke.points.count > 1 else { return }
    let width = stroke.widthPoints * scale
    let color = stroke.color
    // Freehand = one smoothed polyline; a shape = straight-edged outline(s).
    let polylines: [[CGPoint]]
    let path = CGMutablePath()
    if let shape = stroke.shape, let start = stroke.points.first, let end = stroke.points.last {
      polylines = shapePolylines(shape, from: start, to: end, width: stroke.widthPoints)
      for line in polylines where !line.isEmpty {
        path.addLines(between: line.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
      }
    } else {
      polylines = [stroke.points]
      path.addPath(buildSmoothedPath(points: stroke.points, scale: scale))
    }

    func strokePath(_ c: UIColor, _ w: CGFloat, cap: CGLineCap = .round) {
      ctx.addPath(path)
      ctx.setStrokeColor(c.cgColor)
      ctx.setLineWidth(w)
      ctx.setLineCap(cap)
      ctx.setLineJoin(.round)
      ctx.strokePath()
    }

    ctx.saveGState()
    switch stroke.brushType {
    case .pen:
      strokePath(color, width)
    case .marker:
      strokePath(color.withAlphaComponent(0.78), width, cap: .square)
    case .highlighter:
      strokePath(color.withAlphaComponent(0.35), width, cap: .square)
    case .neon:
      // Soft glow from wide translucent passes, then a bright core — no
      // shadow blur, which wouldn't scale with the export.
      strokePath(color.withAlphaComponent(0.12), width * 2.6)
      strokePath(color.withAlphaComponent(0.25), width * 1.8)
      strokePath(color, width)
      strokePath(UIColor.white.withAlphaComponent(0.9), width * 0.35)
    case .dotted:
      ctx.setLineDash(phase: 0, lengths: [0.001, width * 1.9])
      strokePath(color, width)
    case .spray:
      scatter(polylines, stroke: stroke, scale: scale, spacing: 0.3, perSample: 8, in: ctx) { random, sample in
        let r = stroke.widthPoints * 1.2 * random(0).squareRoot()
        let angle = random(1) * 2 * .pi
        return (CGPoint(x: sample.x + r * cos(angle), y: sample.y + r * sin(angle)),
                stroke.widthPoints * (0.04 + 0.06 * random(2)), false)
      }
      ctx.setFillColor(color.withAlphaComponent(0.85).cgColor)
      ctx.fillPath()
    case .chalk:
      strokePath(color.withAlphaComponent(0.35), width)
      scatter(polylines, stroke: stroke, scale: scale, spacing: 0.15, perSample: 6, in: ctx) { random, sample in
        let r = stroke.widthPoints * 0.5 * random(0).squareRoot()
        let angle = random(1) * 2 * .pi
        return (CGPoint(x: sample.x + r * cos(angle), y: sample.y + r * sin(angle)),
                stroke.widthPoints * (0.05 + 0.07 * random(2)), false)
      }
      ctx.setFillColor(color.withAlphaComponent(0.75).cgColor)
      ctx.fillPath()
    case .squares:
      scatter(polylines, stroke: stroke, scale: scale, spacing: 0.9, perSample: 1, in: ctx) { random, sample in
        let w = stroke.widthPoints
        return (CGPoint(x: sample.x + (random(0) - 0.5) * 1.8 * w, y: sample.y + (random(1) - 0.5) * 1.8 * w),
                w * (0.25 + 0.45 * random(2)) / 2, true)
      }
      ctx.setFillColor(color.withAlphaComponent(0.9).cgColor)
      ctx.fillPath()
    case .eraser:
      ctx.setBlendMode(.clear)
      strokePath(.black, width)
    }
    ctx.restoreGState()
  }

  /// Adds dots (or squares) along the stroke to `ctx`'s current path.
  /// Positions come from points sampled every `spacing × width` along the
  /// raw touch polyline (canvas points, before `scale`) and a hash of
  /// (seed, sample, dot) — so the texture doesn't depend on export scale.
  /// `place` returns centre, radius (half side for squares), isSquare.
  private static func scatter(
    _ polylines: [[CGPoint]],
    stroke: Stroke,
    scale: CGFloat,
    spacing: CGFloat,
    perSample: Int,
    in ctx: CGContext,
    place: ((Int) -> CGFloat, CGPoint) -> (CGPoint, CGFloat, Bool)
  ) {
    let step = max(stroke.widthPoints * spacing, 0.5)
    for (sampleIndex, sample) in polylines.flatMap({ samples($0, spacing: step) }).enumerated() {
      for dot in 0..<perSample {
        let random = { (k: Int) -> CGFloat in
          hashFraction(stroke.seed, UInt32(truncatingIfNeeded: sampleIndex), UInt32(truncatingIfNeeded: dot * 3 + k))
        }
        let (center, radius, isSquare) = place(random, sample)
        let rect = CGRect(x: (center.x - radius) * scale, y: (center.y - radius) * scale, width: radius * 2 * scale, height: radius * 2 * scale)
        if isSquare { ctx.addRect(rect) } else { ctx.addEllipse(in: rect) }
      }
    }
  }

  /// Points every `spacing` along the polyline, starting at its first point.
  private static func samples(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
    guard let first = points.first else { return [] }
    var result = [first]
    var carried: CGFloat = 0 // distance walked since the last sample
    for i in 1..<points.count {
      let a = points[i - 1], b = points[i]
      let segment = hypot(b.x - a.x, b.y - a.y)
      guard segment > 0 else { continue }
      var t = spacing - carried
      while t <= segment {
        result.append(CGPoint(x: a.x + (b.x - a.x) * t / segment, y: a.y + (b.y - a.y) * t / segment))
        t += spacing
      }
      carried = segment - (t - spacing)
    }
    return result
  }

  /// Deterministic 0..<1 from three integers — same bit operations as
  /// Android's hashFraction, so a pattern is identical on both platforms.
  static func hashFraction(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> CGFloat {
    var h = (a &* 0x9E37_79B1) ^ (b &* 0x85EB_CA77) ^ (c &* 0xC2B2_AE3D)
    h ^= h >> 15
    h = h &* 0x2C1B_3C6D
    h ^= h >> 12
    h = h &* 0x297A_2D39
    h ^= h >> 15
    return CGFloat(h & 0xFF_FFFF) / 16_777_216
  }

  /// A small sample stroke rendered with `brush` — the brush picker tiles.
  static func previewImage(brush: BrushType, size: CGSize) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { context in
      let w = size.width, h = size.height
      var points: [CGPoint] = []
      for i in 0...24 {
        let t = CGFloat(i) / 24
        points.append(CGPoint(x: w * (0.15 + 0.7 * t), y: h * (0.5 + 0.22 * sin(t * 2 * .pi))))
      }
      draw(Stroke(points: points, color: .white, widthPoints: h * 0.16, brushType: brush, seed: 12345), scale: 1, in: context.cgContext)
    }
  }

  static func dragLength(_ points: [CGPoint]) -> CGFloat {
    guard let a = points.first, let b = points.last else { return 0 }
    return hypot(b.x - a.x, b.y - a.y)
  }

  /// A shape's outline as polylines (closed ones repeat their first
  /// point), in canvas points, fitted to the drag from `a` to `b`.
  static func shapePolylines(_ shape: ShapeType, from a: CGPoint, to b: CGPoint, width: CGFloat) -> [[CGPoint]] {
    let minX = min(a.x, b.x), maxX = max(a.x, b.x), minY = min(a.y, b.y), maxY = max(a.y, b.y)
    let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    let rx = (maxX - minX) / 2, ry = (maxY - minY) / 2
    func closed(_ p: [CGPoint]) -> [CGPoint] { p.isEmpty ? p : p + [p[0]] }
    switch shape {
    case .line:
      return [[a, b]]
    case .arrow:
      let length = hypot(b.x - a.x, b.y - a.y)
      let head = min(max(width * 3, length * 0.25), length * 0.6)
      let angle = atan2(b.y - a.y, b.x - a.x)
      let h1 = CGPoint(x: b.x - head * cos(angle - 0.5), y: b.y - head * sin(angle - 0.5))
      let h2 = CGPoint(x: b.x - head * cos(angle + 0.5), y: b.y - head * sin(angle + 0.5))
      return [[a, b], [h1, b, h2]]
    case .rectangle:
      return [closed([CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)])]
    case .oval:
      return [closed((0..<72).map { i in
        let t = CGFloat(i) / 72 * 2 * .pi
        return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
      })]
    case .triangle:
      return [closed([CGPoint(x: cx, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)])]
    case .star:
      return [closed((0..<10).map { i in
        let r: CGFloat = i % 2 == 0 ? 1 : 0.45
        let t = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        return CGPoint(x: cx + rx * r * cos(t), y: cy + ry * r * sin(t))
      })]
    case .heart:
      // Classic heart curve, x ∈ [-16, 16], y ∈ [-17, 12] (y up), fitted.
      return [closed((0..<72).map { i in
        let t = CGFloat(i) / 72 * 2 * .pi
        let x = 16 * pow(sin(t), 3)
        let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
        return CGPoint(x: cx + rx * x / 16, y: minY + (maxY - minY) * (12 - y) / 29)
      })]
    }
  }

  /// A shape drawn with the pen — the Shape tool's tiles.
  static func shapePreviewImage(_ shape: ShapeType, size: CGSize) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { context in
      let side = min(size.width, size.height) * 0.62
      let a = CGPoint(x: size.width / 2 - side / 2, y: size.height / 2 - side / 2)
      let b = CGPoint(x: size.width / 2 + side / 2, y: size.height / 2 + side / 2)
      let points = shape == .line || shape == .arrow ? [CGPoint(x: a.x, y: b.y), CGPoint(x: b.x, y: a.y)] : [a, b]
      draw(Stroke(points: points, color: .white, widthPoints: 2, brushType: .pen, shape: shape), scale: 1, in: context.cgContext)
    }
  }

  /// Smoothed path through raw touch points ("quadratic-through-midpoints").
  /// Same technique as Android's DrawingCanvasView.buildSmoothedPath.
  static func buildSmoothedPath(points: [CGPoint], scale: CGFloat) -> CGPath {
    let path = CGMutablePath()
    guard !points.isEmpty else { return path }
    path.move(to: CGPoint(x: points[0].x * scale, y: points[0].y * scale))
    for i in 1..<points.count {
      let prev = points[i - 1]
      let curr = points[i]
      let mid = CGPoint(x: (prev.x + curr.x) / 2 * scale, y: (prev.y + curr.y) / 2 * scale)
      path.addQuadCurve(to: mid, control: CGPoint(x: prev.x * scale, y: prev.y * scale))
    }
    let last = points[points.count - 1]
    path.addLine(to: CGPoint(x: last.x * scale, y: last.y * scale))
    return path
  }
}
