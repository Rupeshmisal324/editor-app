import CoreImage
import UIKit

// Sticker library + sticker look (opacity / flip / outline / shadow).
// Android's StickerKit.kt is a line-by-line port — change both together.

/// The bundled sticker library: categories and search words from
/// Stickers/sticker_catalog.json (same file on Android). Sticker images
/// are "sticker_<hex>": the original 40 live in Images.xcassets, the rest
/// as PNGs in the Stickers folder.
enum StickerCatalog {
  struct Category {
    let title: String
    let stickers: [String]
  }

  private struct File: Decodable {
    struct Entry: Decodable {
      let title: String
      let stickers: [String]
    }
    let categories: [Entry]
    let keywords: [String: String]
  }

  static let categories: [Category] = file.categories.map { Category(title: $0.title, stickers: $0.stickers) }
  private static let keywords: [String: String] = file.keywords

  private static let file: File = {
    guard let url = Bundle.main.url(forResource: "sticker_catalog", withExtension: "json", subdirectory: "Stickers"),
          let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(File.self, from: data) else {
      return File(categories: [], keywords: [:])
    }
    return decoded
  }()

  /// Every sticker once, in category order.
  static var allStickers: [String] {
    var seen = Set<String>()
    return categories.flatMap(\.stickers).filter { seen.insert($0).inserted }
  }

  /// Stickers whose name contains every typed word ("red heart", "dog").
  static func search(_ query: String) -> [String] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return [] }
    return allStickers.filter { name in
      let keyword = keywords[name] ?? ""
      return words.allSatisfy { keyword.contains($0) }
    }
  }

  /// Full-size sticker artwork.
  static func image(named name: String) -> UIImage? {
    if let image = UIImage(named: name) { return image }
    guard let path = Bundle.main.path(forResource: name, ofType: "png", inDirectory: "Stickers") else { return nil }
    return UIImage(contentsOfFile: path)
  }

  private static let thumbnailCache = NSCache<NSString, UIImage>()

  /// Small decoded copy for the picker grid — hundreds of full 256px
  /// images would cost tens of MB.
  static func thumbnail(named name: String, side: CGFloat) -> UIImage? {
    let key = "\(name)@\(side)" as NSString
    if let cached = thumbnailCache.object(forKey: key) { return cached }
    guard let image = image(named: name) else { return nil }
    let thumb = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
      image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    thumbnailCache.setObject(thumb, forKey: key)
    return thumb
  }
}

/// Look settings of a sticker layer. outline/shadow 0–1, opacity 0–1.
struct StickerStyle: Equatable {
  var opacity: CGFloat = 1
  var flipX = false
  var flipY = false
  var outline: CGFloat = 0
  var shadow: CGFloat = 0

  var isDefault: Bool { self == StickerStyle() }
}

enum StickerStyleRenderer {
  // × the sticker's shorter side — keep in sync with Android.
  static let outlineMaxWidth: CGFloat = 0.08
  static let shadowMaxBlur: CGFloat = 0.06
  static let shadowMaxOffset: CGFloat = 0.04
  /// Pixels per point the styled image is rendered at.
  static let renderScale: CGFloat = 4

  /// Extra room (points) around the sticker for its outline and shadow —
  /// the layer grows by this on every side so nothing is clipped.
  static func padding(style: StickerStyle, size: CGSize) -> CGFloat {
    let side = min(size.width, size.height)
    var pad = outlineMaxWidth * side * style.outline
    if style.shadow > 0.001 {
      pad += shadowMaxBlur * side * style.shadow * 2.5 + shadowMaxOffset * side * style.shadow
    }
    return ceil(pad)
  }

  /// The styled sticker and its on-screen size (points), or the original
  /// image and size when the style is default.
  static func render(_ image: UIImage, size: CGSize, style: StickerStyle) -> (image: UIImage, size: CGSize) {
    guard !style.isDefault, size.width > 0, size.height > 0 else { return (image, size) }
    let side = min(size.width, size.height)
    let pad = padding(style: style, size: size)
    let outSize = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
    let scale = renderScale
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let pixelSize = CGSize(width: ceil(outSize.width * scale), height: ceil(outSize.height * scale))
    let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
    let artRect = CGRect(x: pad * scale, y: pad * scale, width: size.width * scale, height: size.height * scale)

    // Sticker (flipped) + white outline, no shadow, full opacity.
    let content = renderer.image { context in
      let ctx = context.cgContext
      ctx.translateBy(x: artRect.midX, y: artRect.midY)
      ctx.scaleBy(x: style.flipX ? -1 : 1, y: style.flipY ? -1 : 1)
      ctx.translateBy(x: -artRect.midX, y: -artRect.midY)
      if style.outline > 0.001, let silhouette = silhouette(of: image, size: artRect.size, color: .white) {
        // Dilate: the white silhouette stamped around a circle (two rings
        // so thick outlines stay solid).
        let radius = outlineMaxWidth * side * style.outline * scale
        for ring in [radius, radius * 0.5] {
          for step in 0..<24 {
            let angle = CGFloat(step) / 24 * 2 * .pi
            silhouette.draw(in: artRect.offsetBy(dx: ring * cos(angle), dy: ring * sin(angle)))
          }
        }
      }
      image.draw(in: artRect)
    }
    guard let contentImage = content.cgImage else { return (image, size) }
    let shadowImage = style.shadow > 0.001 ? makeShadow(contentImage, style: style, side: side * scale) : nil

    let final = renderer.image { context in
      let ctx = context.cgContext
      let rect = CGRect(origin: .zero, size: pixelSize)
      ctx.setAlpha(min(max(style.opacity, 0), 1))
      ctx.beginTransparencyLayer(auxiliaryInfo: nil)
      if let shadowImage { UIImage(cgImage: shadowImage).draw(in: rect) }
      UIImage(cgImage: contentImage).draw(in: rect)
      ctx.endTransparencyLayer()
    }
    guard let cgImage = final.cgImage else { return (image, size) }
    return (UIImage(cgImage: cgImage, scale: scale, orientation: .up), outSize)
  }

  /// The image's shape filled with one colour.
  private static func silhouette(of image: UIImage, size: CGSize, color: UIColor) -> UIImage? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      let rect = CGRect(origin: .zero, size: size)
      image.draw(in: rect)
      context.cgContext.setBlendMode(.sourceIn)
      color.setFill()
      context.cgContext.fill(rect)
    }
  }

  private static let ciContext = CIContext()

  /// Same recipe as TextLayerRenderer's shadow (black, blurred, offset down).
  private static func makeShadow(_ content: CGImage, style: StickerStyle, side: CGFloat) -> CGImage? {
    let blur = shadowMaxBlur * side * style.shadow
    let offset = shadowMaxOffset * side * style.shadow
    let alpha = 0.3 + 0.5 * min(max(style.shadow, 0), 1)
    let input = CIImage(cgImage: content)
    let extent = input.extent
    let tinted = input.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
      "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
    ])
    // Core Image is y-up: a negative y offset moves the shadow down.
    let shadow = (blur > 0.5 ? tinted.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) : tinted)
      .transformed(by: CGAffineTransform(translationX: 0, y: -offset))
    return ciContext.createCGImage(shadow.cropped(to: extent), from: extent)
  }
}
