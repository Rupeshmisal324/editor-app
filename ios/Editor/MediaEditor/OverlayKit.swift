import CoreImage
import UIKit

// Overlay (added photo) look: filter + adjust, opacity, blend, shape,
// border, flip and eraser. One renderer for preview, export and re-edit.
// Android's OverlayKit.kt is a line-by-line port — change both together.

enum OverlayBlendMode: String, CaseIterable {
  case normal, multiply, screen, overlay, darken, lighten, softLight

  var title: String {
    switch self {
    case .normal: return "Normal"
    case .multiply: return "Multiply"
    case .screen: return "Screen"
    case .overlay: return "Overlay"
    case .darken: return "Darken"
    case .lighten: return "Lighten"
    case .softLight: return "Soft light"
    }
  }

  var cgBlendMode: CGBlendMode {
    switch self {
    case .normal: return .normal
    case .multiply: return .multiply
    case .screen: return .screen
    case .overlay: return .overlay
    case .darken: return .darken
    case .lighten: return .lighten
    case .softLight: return .softLight
    }
  }

  /// Core Animation compositing filter for the on-screen preview.
  var compositingFilterName: String? {
    switch self {
    case .normal: return nil
    case .multiply: return "multiplyBlendMode"
    case .screen: return "screenBlendMode"
    case .overlay: return "overlayBlendMode"
    case .darken: return "darkenBlendMode"
    case .lighten: return "lightenBlendMode"
    case .softLight: return "softLightBlendMode"
    }
  }
}

enum OverlayShape: String, CaseIterable {
  case none, rounded, circle, heart, star, hexagon

  var title: String {
    switch self {
    case .none: return "None"
    case .rounded: return "Rounded"
    case .circle: return "Circle"
    case .heart: return "Heart"
    case .star: return "Star"
    case .hexagon: return "Hexagon"
    }
  }
}

/// Raw values/fields are saved in re-edit projects — never rename one.
struct OverlayStyle: Equatable {
  var filter: PhotoFilter = .original
  var filterStrength: CGFloat = 1
  /// -1…1 each.
  var brightness: CGFloat = 0
  var contrast: CGFloat = 0
  var saturation: CGFloat = 0
  var warmth: CGFloat = 0
  var opacity: CGFloat = 1
  var blend: OverlayBlendMode = .normal
  var shape: OverlayShape = .none
  /// 0…1 (× 8% of the shorter side).
  var border: CGFloat = 0
  var borderColor: UIColor = .white
  var flipX = false
  var flipY = false

  /// Everything that changes the colour pass (cached separately so eraser
  /// strokes don't re-run filters).
  var colorKey: String {
    "\(filter.rawValue)|\(filterStrength)|\(brightness)|\(contrast)|\(saturation)|\(warmth)"
  }
}

/// One eraser (or restore) stroke, in the overlay's own box: points are
/// 0…1 of its width/height, width is a fraction of its width.
struct OverlayEraseStroke: Equatable {
  var points: [CGPoint]
  var width: CGFloat
  var restore: Bool
}

enum OverlayRenderer {
  static let borderMaxWidth: CGFloat = 0.08
  static let roundedCornerRadius: CGFloat = 0.18
  /// Long side the on-screen preview is processed at.
  static let previewMaxSide: CGFloat = 1024

  // MARK: Colour pass

  private static let ciContext = CIContext()
  /// No colour management: the adjust matrix works on sRGB-encoded values,
  /// exactly like Android's ColorMatrix.
  private static let rawContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

  /// Brightness/contrast/saturation/warmth as one 4×5 matrix on 0…1
  /// sRGB values — rows (r, g, b, a), last column = offset. Shared with
  /// Android (there with offsets × 255).
  static func adjustMatrix(_ style: OverlayStyle) -> [[CGFloat]] {
    let s = 1 + style.saturation
    let lr: CGFloat = 0.2126, lg: CGFloat = 0.7152, lb: CGFloat = 0.0722
    var m: [[CGFloat]] = [
      [lr * (1 - s) + s, lg * (1 - s), lb * (1 - s), 0, 0],
      [lr * (1 - s), lg * (1 - s) + s, lb * (1 - s), 0, 0],
      [lr * (1 - s), lg * (1 - s), lb * (1 - s) + s, 0, 0],
      [0, 0, 0, 1, 0],
    ]
    let k = 1 + style.contrast * 0.6
    let contrastOffset = 0.5 * (1 - k) + style.brightness * 0.25
    let warmthOffsets: [CGFloat] = [style.warmth * 0.08, 0, -style.warmth * 0.08]
    for row in 0..<3 {
      for col in 0..<3 { m[row][col] *= k }
      m[row][4] = contrastOffset + warmthOffsets[row]
    }
    return m
  }

  /// Filtered + adjusted copy of `base`, at most `maxSide` px long.
  static func colorPass(_ base: UIImage, style: OverlayStyle, maxSide: CGFloat) -> CGImage? {
    guard var current = downscaled(base, maxSide: maxSide) else { return nil }
    let extent = CGRect(x: 0, y: 0, width: current.width, height: current.height)
    if style.filter != .original {
      let filtered = style.filter.apply(to: CIImage(cgImage: current), strength: Float(style.filterStrength), saturation: 0, sharpness: 0).cropped(to: extent)
      guard let out = ciContext.createCGImage(filtered, from: extent) else { return nil }
      current = out
    }
    if style.brightness == 0 && style.contrast == 0 && style.saturation == 0 && style.warmth == 0 { return current }
    let m = adjustMatrix(style)
    let adjusted = CIImage(cgImage: current).applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: m[0][3]),
      "inputGVector": CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: m[1][3]),
      "inputBVector": CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: m[2][3]),
      "inputAVector": CIVector(x: m[3][0], y: m[3][1], z: m[3][2], w: m[3][3]),
      "inputBiasVector": CIVector(x: m[0][4], y: m[1][4], z: m[2][4], w: 0),
    ]).cropped(to: extent)
    return rawContext.createCGImage(adjusted, from: extent)
  }

  private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> CGImage? {
    guard let cg = image.cgImage else { return nil }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let scale = min(1, maxSide / max(w, h))
    if scale >= 1 { return cg }
    let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
    }.cgImage
  }

  // MARK: Shape

  /// The shape's outline inside `rect` (nil = the plain rectangle).
  /// Circle/heart/star/hexagon use the centred square.
  static func shapePath(_ shape: OverlayShape, in rect: CGRect) -> CGPath? {
    let side = min(rect.width, rect.height)
    let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    func polygon(_ points: [CGPoint]) -> CGPath {
      let path = CGMutablePath()
      path.addLines(between: points)
      path.closeSubpath()
      return path
    }
    switch shape {
    case .none:
      return nil
    case .rounded:
      return UIBezierPath(roundedRect: rect, cornerRadius: side * roundedCornerRadius).cgPath
    case .circle:
      return CGPath(ellipseIn: square, transform: nil)
    case .heart:
      return polygon(DrawingCanvasView.shapePolylines(.heart, from: square.origin, to: CGPoint(x: square.maxX, y: square.maxY), width: 0)[0])
    case .star:
      return polygon(DrawingCanvasView.shapePolylines(.star, from: square.origin, to: CGPoint(x: square.maxX, y: square.maxY), width: 0)[0])
    case .hexagon:
      return polygon((0..<6).map { i in
        let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 3
        return CGPoint(x: square.midX + side / 2 * cos(angle), y: square.midY + side / 2 * sin(angle))
      })
    }
  }

  // MARK: Composite

  /// The finished overlay at `pixelSize`: colour pass (precomputed),
  /// flipped, eraser applied, cut to its shape, bordered, at its opacity.
  /// Blend mode is NOT applied here — it's how the result is drawn onto
  /// the photo (export) or composited on screen (preview).
  static func composite(
    colored: CGImage,
    style: OverlayStyle,
    strokes: [OverlayEraseStroke],
    pixelSize: CGSize
  ) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let rect = CGRect(origin: .zero, size: pixelSize)
    let photo = UIImage(cgImage: colored)
    return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
      let ctx = context.cgContext
      ctx.setAlpha(min(max(style.opacity, 0), 1))
      ctx.beginTransparencyLayer(auxiliaryInfo: nil)
      let shape = shapePath(style.shape, in: rect)
      if let shape {
        ctx.addPath(shape)
        ctx.clip()
      }

      func drawPhoto() {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: style.flipX ? -1 : 1, y: style.flipY ? -1 : 1)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
        photo.draw(in: rect)
        ctx.restoreGState()
      }

      ctx.beginTransparencyLayer(auxiliaryInfo: nil)
      drawPhoto()
      for stroke in strokes where stroke.points.count > 0 {
        let path = CGMutablePath()
        let points = stroke.points.map { CGPoint(x: $0.x * pixelSize.width, y: $0.y * pixelSize.height) }
        path.addLines(between: points.count == 1 ? [points[0], points[0]] : points)
        let width = max(stroke.width * pixelSize.width, 1)
        ctx.saveGState()
        if stroke.restore {
          ctx.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
          ctx.clip()
          drawPhoto()
        } else {
          ctx.setBlendMode(.clear)
          ctx.addPath(path)
          ctx.setLineWidth(width)
          ctx.setLineCap(.round)
          ctx.setLineJoin(.round)
          ctx.strokePath()
        }
        ctx.restoreGState()
      }
      ctx.endTransparencyLayer()

      if style.border > 0.001 {
        // Stroked twice as wide and clipped by the shape: the inner half shows.
        let width = borderMaxWidth * min(pixelSize.width, pixelSize.height) * style.border
        ctx.addPath(shape ?? CGPath(rect: rect, transform: nil))
        ctx.setStrokeColor(style.borderColor.cgColor)
        ctx.setLineWidth(width * 2)
        ctx.setLineJoin(.round)
        ctx.strokePath()
      }
      ctx.endTransparencyLayer()
    }
  }

  /// Full render at `pixelSize` (export): colour pass at that size.
  static func render(base: UIImage, style: OverlayStyle, strokes: [OverlayEraseStroke], pixelSize: CGSize) -> UIImage? {
    let maxSide = max(pixelSize.width, pixelSize.height)
    guard let colored = colorPass(base, style: style, maxSide: max(maxSide, 1)) else { return nil }
    return composite(colored: colored, style: style, strokes: strokes, pixelSize: pixelSize)
  }
}
