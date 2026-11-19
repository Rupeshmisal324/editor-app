import CoreImage
import CoreText
import UIKit

// Text layers are drawn by ONE renderer — on-screen preview, photo export
// and video export all call `TextLayerRenderer.render`, so what you see is
// exactly what gets exported. Android's TextLayerRenderer.kt is a
// line-by-line port: same fonts (bundled, identical files), same font
// metrics table, same constants. Change both together.

enum TextBackgroundMode: Int {
  case none = 0
  case solid = 1
  case translucent = 2
}

/// Every look setting of a text layer. Ranges: size 0.5–2 (1 = normal),
/// outline/shadow 0–1, opacity 0–1, stretchX/Y 0.5–2, arch -1…1
/// (positive bends like ∩, negative like ∪).
struct TextLayerStyle: Equatable {
  var fontId: String = TextFontCatalog.defaultOption.id
  var color: UIColor = .white
  var isBold = false
  var isItalic = false
  var isUnderlined = false
  var alignment: NSTextAlignment = .center
  var background: TextBackgroundMode = .none
  var size: CGFloat = 1
  var outline: CGFloat = 0
  var shadow: CGFloat = 0
  var opacity: CGFloat = 1
  var stretchX: CGFloat = 1
  var stretchY: CGFloat = 1
  var arch: CGFloat = 0
}

struct TextFontOption {
  let id: String
  let label: String
  /// File in the TextFonts/ bundle folder; nil = DM Sans Bold, which the
  /// app already registers through Info.plist's UIAppFonts.
  let fileName: String?
  let sizeFactor: CGFloat
  /// hhea ascent/descent as a fraction of the em — used for line layout
  /// instead of each platform's own font metrics, so lines sit at exactly
  /// the same place on iOS and Android.
  let ascent: CGFloat
  let descent: CGFloat
}

enum TextFontCatalog {
  static let baseSize: CGFloat = 28

  // Ids are saved in re-edit projects — never rename one.
  static let options: [TextFontOption] = [
    TextFontOption(id: "classic", label: "Classic", fileName: nil, sizeFactor: 1.0, ascent: 0.992, descent: 0.310),
    TextFontOption(id: "serif", label: "Serif", fileName: "Playfair", sizeFactor: 1.0, ascent: 1.082, descent: 0.251),
    TextFontOption(id: "script", label: "Script", fileName: "Pacifico", sizeFactor: 0.9, ascent: 1.303, descent: 0.453),
    TextFontOption(id: "headline", label: "Headline", fileName: "BebasNeue", sizeFactor: 1.05, ascent: 0.900, descent: 0.300),
    TextFontOption(id: "marker", label: "Marker", fileName: "PermanentMarker", sizeFactor: 0.95, ascent: 1.109, descent: 0.317),
    TextFontOption(id: "lobster", label: "Lobster", fileName: "Lobster", sizeFactor: 1.0, ascent: 1.000, descent: 0.250),
    TextFontOption(id: "impact", label: "Impact", fileName: "Anton", sizeFactor: 0.9, ascent: 1.176, descent: 0.329),
    TextFontOption(id: "handwritten", label: "Handwritten", fileName: "Caveat", sizeFactor: 1.2, ascent: 0.960, descent: 0.300),
    TextFontOption(id: "rounded", label: "Rounded", fileName: "Nunito", sizeFactor: 1.0, ascent: 1.011, descent: 0.353),
    TextFontOption(id: "comic", label: "Comic", fileName: "Bangers", sizeFactor: 1.0, ascent: 0.883, descent: 0.181),
    TextFontOption(id: "fancy", label: "Fancy", fileName: "GreatVibes", sizeFactor: 1.3, ascent: 0.851, descent: 0.401),
    TextFontOption(id: "elegant", label: "Elegant", fileName: "Raleway", sizeFactor: 1.0, ascent: 0.940, descent: 0.234),
    TextFontOption(id: "fashion", label: "Fashion", fileName: "AbrilFatface", sizeFactor: 1.0, ascent: 1.058, descent: 0.291),
    TextFontOption(id: "typewriter", label: "Typewriter", fileName: "SpecialElite", sizeFactor: 1.25, ascent: 0.703, descent: 0.297),
    TextFontOption(id: "playful", label: "Playful", fileName: "Chewy", sizeFactor: 1.0, ascent: 0.979, descent: 0.303),
    TextFontOption(id: "retro", label: "Retro", fileName: "Righteous", sizeFactor: 1.0, ascent: 0.985, descent: 0.257),
    TextFontOption(id: "condensed", label: "Condensed", fileName: "Oswald", sizeFactor: 0.95, ascent: 1.193, descent: 0.289),
    TextFontOption(id: "royal", label: "Royal", fileName: "Cinzel", sizeFactor: 0.95, ascent: 0.976, descent: 0.372),
    TextFontOption(id: "future", label: "Future", fileName: "Orbitron", sizeFactor: 0.9, ascent: 1.011, descent: 0.243),
    TextFontOption(id: "block", label: "Block", fileName: "Bungee", sizeFactor: 0.85, ascent: 1.020, descent: 0.300),
    TextFontOption(id: "dancing", label: "Dancing", fileName: "DancingScript", sizeFactor: 1.15, ascent: 0.920, descent: 0.280),
    TextFontOption(id: "mono", label: "Mono", fileName: "SpaceMono", sizeFactor: 0.95, ascent: 1.120, descent: 0.361),
    TextFontOption(id: "spooky", label: "Spooky", fileName: "Creepster", sizeFactor: 1.0, ascent: 0.951, descent: 0.218),
  ]

  static var defaultOption: TextFontOption { options[0] }

  static func option(id: String?) -> TextFontOption {
    options.first { $0.id == id } ?? defaultOption
  }

  /// Maps the PostScript names of the Apple fonts older projects were
  /// saved with to the closest bundled font.
  static func optionId(legacyFontName name: String?) -> String {
    guard let name else { return defaultOption.id }
    let map: [String: String] = [
      "Georgia-Bold": "serif", "Courier-Bold": "mono", "SnellRoundhand-Bold": "script",
      "AvenirNext-Bold": "elegant", "AmericanTypewriter-Bold": "typewriter", "MarkerFelt-Wide": "playful",
      "ChalkboardSE-Bold": "marker", "Copperplate-Bold": "royal", "AvenirNextCondensed-Bold": "condensed",
      "BradleyHandITCTT-Bold": "handwritten", "BradleyHandITCTT": "handwritten", "Zapfino": "fancy",
      "HelveticaNeue-CondensedBlack": "impact", "Futura-Bold": "future", "Optima-ExtraBlack": "elegant",
      "Baskerville-Bold": "serif", "Noteworthy-Bold": "handwritten", "Didot": "fashion", "PartyLetPlain": "dancing",
    ]
    return map[name] ?? defaultOption.id
  }

  private static let lock = NSLock()
  private static var postScriptNames: [String: String] = [:]

  static func font(_ option: TextFontOption, size: CGFloat) -> UIFont {
    let fallback = UIFont.systemFont(ofSize: size, weight: .bold)
    guard let fileName = option.fileName else {
      return UIFont(name: "DMSans-Bold", size: size) ?? fallback
    }
    lock.lock()
    defer { lock.unlock() }
    if let name = postScriptNames[fileName] {
      return UIFont(name: name, size: size) ?? fallback
    }
    guard let url = Bundle.main.url(forResource: fileName, withExtension: "ttf", subdirectory: "TextFonts"),
          let provider = CGDataProvider(url: url as CFURL),
          let cgFont = CGFont(provider),
          let name = cgFont.postScriptName as String? else { return fallback }
    // Fails harmlessly if already registered (e.g. a second editor session).
    CTFontManagerRegisterGraphicsFont(cgFont, nil)
    postScriptNames[fileName] = name
    return UIFont(name: name, size: size) ?? fallback
  }
}

enum TextLayerRenderer {
  // Shared constants (× font size unless noted) — keep in sync with Android.
  static let lineSpacing: CGFloat = 1.08
  static let backgroundPadX: CGFloat = 0.32
  static let backgroundPadY: CGFloat = 0.14
  static let backgroundRadius: CGFloat = 0.28
  static let translucentAlpha: CGFloat = 0.55
  static let outlineMaxWidth: CGFloat = 0.22
  static let boldWidth: CGFloat = 0.045
  static let italicSkew: CGFloat = 0.22
  static let underlineOffset: CGFloat = 0.12
  static let underlineThickness: CGFloat = 0.07
  static let shadowMaxBlur: CGFloat = 0.18
  static let shadowMaxOffset: CGFloat = 0.08
  static let maxArchAngle: CGFloat = 1.6 * .pi

  /// One drawn run of text: a whole line, or a single character when
  /// arched. `anchor` is the baseline centre; the run is drawn from
  /// x = -width/2 in a frame rotated by `rotation`.
  private struct Piece {
    let text: String
    let anchor: CGPoint
    let rotation: CGFloat
    let width: CGFloat
  }

  private enum BackgroundPiece {
    case rect(CGRect, radius: CGFloat)
    case arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, thickness: CGFloat)
  }

  private struct Layout {
    var pieces: [Piece] = []
    var backgrounds: [BackgroundPiece] = []
    var bounds: CGRect = .zero
    let font: UIFont
    let fontSize: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
  }

  /// Size in points at scale 1 — the layer's on-screen size.
  static func measure(text: String, style: TextLayerStyle) -> CGSize {
    let layout = makeLayout(text: text, style: style, scale: 1)
    return outputSize(layout: layout, style: style)
  }

  /// Renders at `scale` (pixels per point). `size` is the exact, unrounded
  /// draw size in pixels — draw the image into a rect of this size centred
  /// on the layer's centre.
  static func render(text: String, style: TextLayerStyle, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
    let layout = makeLayout(text: text, style: style, scale: scale)
    let size = outputSize(layout: layout, style: style)
    let pixelWidth = Int(ceil(size.width)), pixelHeight = Int(ceil(size.height))
    guard pixelWidth > 0, pixelHeight > 0, pixelWidth * pixelHeight < 60_000_000 else { return nil }
    let canvasSize = CGSize(width: pixelWidth, height: pixelHeight)
    let contentSize = CGSize(width: layout.bounds.width * style.stretchX, height: layout.bounds.height * style.stretchY)

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)

    // Content first (no shadow, full opacity), then composited with its
    // shadow at the layer's opacity.
    let content = renderer.image { context in
      let ctx = context.cgContext
      ctx.translateBy(x: (canvasSize.width - contentSize.width) / 2, y: (canvasSize.height - contentSize.height) / 2)
      ctx.scaleBy(x: style.stretchX, y: style.stretchY)
      ctx.translateBy(x: -layout.bounds.minX, y: -layout.bounds.minY)
      drawContent(layout: layout, style: style, in: ctx)
    }
    guard let contentImage = content.cgImage else { return nil }
    let shadowImage = style.shadow > 0.001 ? makeShadow(from: contentImage, style: style, fontSize: layout.fontSize) : nil

    let final = renderer.image { context in
      let ctx = context.cgContext
      let rect = CGRect(origin: .zero, size: canvasSize)
      ctx.setAlpha(min(max(style.opacity, 0), 1))
      ctx.beginTransparencyLayer(auxiliaryInfo: nil)
      if let shadowImage {
        UIImage(cgImage: shadowImage).draw(in: rect)
      }
      UIImage(cgImage: contentImage).draw(in: rect)
      ctx.endTransparencyLayer()
    }
    guard let image = final.cgImage else { return nil }
    return (image, size)
  }

  // MARK: Layout

  private static func outputSize(layout: Layout, style: TextLayerStyle) -> CGSize {
    let pad = shadowPadding(style: style, fontSize: layout.fontSize)
    return CGSize(
      width: max(layout.bounds.width * style.stretchX + pad * 2, 1),
      height: max(layout.bounds.height * style.stretchY + pad * 2, 1)
    )
  }

  private static func shadowBlur(style: TextLayerStyle, fontSize: CGFloat) -> CGFloat {
    shadowMaxBlur * fontSize * style.shadow
  }

  private static func shadowOffset(style: TextLayerStyle, fontSize: CGFloat) -> CGFloat {
    shadowMaxOffset * fontSize * style.shadow
  }

  private static func shadowPadding(style: TextLayerStyle, fontSize: CGFloat) -> CGFloat {
    guard style.shadow > 0.001 else { return 0 }
    return ceil(shadowBlur(style: style, fontSize: fontSize) * 2.5 + shadowOffset(style: style, fontSize: fontSize))
  }

  private static func lineWidth(_ text: String, font: UIFont) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  /// Centre x and advance of every character, from the shaped line, so
  /// kerning is kept when the characters are placed one by one on an arc.
  private static func characterRuns(_ text: String, font: UIFont) -> [(text: String, center: CGFloat, width: CGFloat)] {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let total = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    var result: [(String, CGFloat, CGFloat)] = []
    var utf16Offset = 0
    let characters = Array(text)
    for (index, character) in characters.enumerated() {
      let length = String(character).utf16.count
      let start = CTLineGetOffsetForStringIndex(line, utf16Offset, nil)
      let end = index == characters.count - 1 ? total : CTLineGetOffsetForStringIndex(line, utf16Offset + length, nil)
      let width = max(end - start, 0)
      result.append((String(character), start + width / 2, width))
      utf16Offset += length
    }
    return result
  }

  private static func makeLayout(text: String, style: TextLayerStyle, scale: CGFloat) -> Layout {
    let option = TextFontCatalog.option(id: style.fontId)
    let fontSize = TextFontCatalog.baseSize * option.sizeFactor * min(max(style.size, 0.3), 3) * scale
    let font = TextFontCatalog.font(option, size: fontSize)
    let ascent = option.ascent * fontSize
    let descent = option.descent * fontSize
    let lineHeight = (ascent + descent) * lineSpacing
    var layout = Layout(font: font, fontSize: fontSize, ascent: ascent, descent: descent)

    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    let widths = lines.map { lineWidth($0, font: font) }
    let blockWidth = max(widths.max() ?? 0, 1)
    let hasBackground = style.background != .none
    let padX = hasBackground ? backgroundPadX * fontSize : 0
    let padY = hasBackground ? backgroundPadY * fontSize : 0

    func lineX(_ width: CGFloat) -> CGFloat {
      switch style.alignment {
      case .left: return 0
      case .right: return blockWidth - width
      default: return (blockWidth - width) / 2
      }
    }

    var points: [CGPoint] = []
    /// A box given in piece-local coordinates (origin = baseline centre),
    /// rotated and moved into place. `skew` applies the italic slant.
    func addBox(center: CGPoint, rotation: CGFloat, left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, skew: Bool = false) {
      let c = cos(rotation), s = sin(rotation)
      for (x0, y) in [(left, top), (right, top), (left, bottom), (right, bottom)] {
        let x = skew ? x0 - italicSkew * y : x0
        points.append(CGPoint(x: center.x + x * c - y * s, y: center.y + x * s + y * c))
      }
    }
    func addBox(center: CGPoint, rotation: CGFloat, halfWidth: CGFloat, top: CGFloat, bottom: CGFloat) {
      addBox(center: center, rotation: rotation, left: -halfWidth, right: halfWidth, top: top, bottom: bottom)
    }
    /// The visible letters of `text` (not the font's full line box), so the
    /// layer's box hugs the text and it can be moved right to the edges.
    /// Piece-local: origin at the baseline centre of a run `width` wide.
    func addInk(_ text: String, center: CGPoint, rotation: CGFloat, width: CGFloat) {
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
      let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
      if ink.isNull || ink.isEmpty {
        addBox(center: center, rotation: rotation, left: -width / 2, right: width / 2, top: -ascent, bottom: descent, skew: style.isItalic)
      } else {
        // Core Text is y-up from the baseline; pieces are y-down.
        addBox(center: center, rotation: rotation, left: -width / 2 + ink.minX, right: -width / 2 + ink.maxX,
               top: -ink.maxY, bottom: -ink.minY, skew: style.isItalic)
      }
      if style.isUnderlined {
        addBox(center: center, rotation: rotation, left: -width / 2, right: width / 2,
               top: (underlineOffset - underlineThickness / 2) * fontSize, bottom: (underlineOffset + underlineThickness / 2) * fontSize)
      }
    }

    let arch = min(max(style.arch, -1), 1)
    if abs(arch) < 0.01 {
      for (index, line) in lines.enumerated() where !line.isEmpty {
        let width = widths[index]
        let x = lineX(width)
        let baseline = ascent + CGFloat(index) * lineHeight
        layout.pieces.append(Piece(text: line, anchor: CGPoint(x: x + width / 2, y: baseline), rotation: 0, width: width))
        addInk(line, center: CGPoint(x: x + width / 2, y: baseline), rotation: 0, width: width)
        if hasBackground {
          let rect = CGRect(x: x - padX, y: baseline - ascent - padY, width: width + padX * 2, height: ascent + descent + padY * 2)
          layout.backgrounds.append(.rect(rect, radius: min(backgroundRadius * fontSize, rect.height / 2)))
          addBox(center: CGPoint(x: rect.midX, y: rect.midY), rotation: 0, halfWidth: rect.width / 2, top: -rect.height / 2, bottom: rect.height / 2)
        }
      }
    } else {
      let angle = arch * maxArchAngle
      let baseRadius = blockWidth / abs(angle)
      let bendsUp = arch > 0
      let center = CGPoint(x: blockWidth / 2, y: bendsUp ? ascent + baseRadius : ascent - baseRadius)
      for (index, line) in lines.enumerated() where !line.isEmpty {
        let offset = CGFloat(index) * lineHeight
        let radius = max(bendsUp ? baseRadius - offset : baseRadius + offset, lineHeight * 0.5)
        let x = lineX(widths[index])
        func position(_ arcLength: CGFloat, _ r: CGFloat) -> (CGPoint, CGFloat) {
          let phi = arcLength / radius
          return bendsUp
            ? (CGPoint(x: center.x + r * sin(phi), y: center.y - r * cos(phi)), phi)
            : (CGPoint(x: center.x + r * sin(phi), y: center.y + r * cos(phi)), -phi)
        }
        for run in characterRuns(line, font: font) {
          let (anchor, rotation) = position(x + run.center - blockWidth / 2, radius)
          layout.pieces.append(Piece(text: run.text, anchor: anchor, rotation: rotation, width: run.width))
          addInk(run.text, center: anchor, rotation: rotation, width: run.width)
        }
        if hasBackground {
          let thickness = ascent + descent + padY * 2
          let midRadius = bendsUp ? radius + (ascent - descent) / 2 : radius - (ascent - descent) / 2
          var startLength = x - padX - blockWidth / 2 + thickness / 2
          var endLength = x + widths[index] + padX - blockWidth / 2 - thickness / 2
          if endLength < startLength {
            let mid = (startLength + endLength) / 2
            startLength = mid
            endLength = mid
          }
          let startPhi = startLength / radius, endPhi = endLength / radius
          // Arc angles in the y-down frame: point = center + r·(cos α, sin α).
          let startAngle = bendsUp ? startPhi - .pi / 2 : .pi / 2 - startPhi
          let endAngle = bendsUp ? endPhi - .pi / 2 : .pi / 2 - endPhi
          layout.backgrounds.append(.arc(center: center, radius: max(midRadius, 1), start: startAngle, end: endAngle, thickness: thickness))
          for step in 0...24 {
            let t = CGFloat(step) / 24
            let arcLength = (startLength - thickness / 2) + (endLength - startLength + thickness) * t
            for r in [midRadius - thickness / 2, midRadius + thickness / 2] {
              points.append(position(arcLength, max(r, 0)).0)
            }
          }
        }
      }
    }

    guard !points.isEmpty else {
      layout.bounds = CGRect(x: 0, y: 0, width: 1, height: ascent + descent)
      return layout
    }
    var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
    for p in points {
      minX = min(minX, p.x); maxX = max(maxX, p.x)
      minY = min(minY, p.y); maxY = max(maxY, p.y)
    }
    let strokePad = (style.outline > 0.001 ? outlineMaxWidth * fontSize * style.outline / 2 : 0)
      + (style.isBold ? boldWidth * fontSize / 2 : 0)
    // Ink bounds already cover overhangs and the italic slant.
    let pad = strokePad + 1
    layout.bounds = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
    return layout
  }

  // MARK: Drawing

  private static func luminance(_ color: UIColor) -> CGFloat {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return 0.299 * r + 0.587 * g + 0.114 * b
  }

  /// Text colour actually drawn: on a background the chosen colour fills
  /// the background and the text turns black or white to stay readable.
  static func fillColor(for style: TextLayerStyle) -> UIColor {
    guard style.background != .none else { return style.color }
    return luminance(style.color) > 0.6 ? .black : .white
  }

  private static func drawContent(layout: Layout, style: TextLayerStyle, in ctx: CGContext) {
    let fontSize = layout.fontSize
    let fill = fillColor(for: style)

    if style.background != .none {
      let alpha: CGFloat = style.background == .translucent ? translucentAlpha : 1
      // One transparency layer so overlapping line pills don't double up
      // their alpha where they touch.
      ctx.saveGState()
      ctx.setAlpha(alpha)
      ctx.beginTransparencyLayer(auxiliaryInfo: nil)
      ctx.setFillColor(style.color.withAlphaComponent(1).cgColor)
      ctx.setStrokeColor(style.color.withAlphaComponent(1).cgColor)
      for piece in layout.backgrounds {
        switch piece {
        case let .rect(rect, radius):
          ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
          ctx.fillPath()
        case let .arc(center, radius, start, end, thickness):
          ctx.setLineWidth(thickness)
          ctx.setLineCap(.round)
          ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: end < start)
          ctx.strokePath()
        }
      }
      ctx.endTransparencyLayer()
      ctx.restoreGState()
    }

    let boldStroke = style.isBold ? boldWidth * fontSize : 0
    if style.outline > 0.001 {
      let outlineColor: UIColor = luminance(fill) > 0.5 ? .black : .white
      drawPieces(layout: layout, style: style, color: outlineColor, strokeWidth: outlineMaxWidth * fontSize * style.outline + boldStroke, strokeOnly: true, in: ctx)
    }
    drawPieces(layout: layout, style: style, color: fill, strokeWidth: boldStroke, strokeOnly: false, in: ctx)
  }

  private static func drawPieces(
    layout: Layout,
    style: TextLayerStyle,
    color: UIColor,
    strokeWidth: CGFloat,
    strokeOnly: Bool,
    in ctx: CGContext
  ) {
    let fontSize = layout.fontSize
    var attributes: [NSAttributedString.Key: Any] = [.font: layout.font, .foregroundColor: color]
    if strokeWidth > 0 {
      // Percent of the font size; positive = stroke only, negative = fill + stroke.
      let percent = strokeWidth / fontSize * 100
      attributes[.strokeWidth] = strokeOnly ? percent : -percent
      attributes[.strokeColor] = color
    }
    for piece in layout.pieces {
      ctx.saveGState()
      ctx.translateBy(x: piece.anchor.x, y: piece.anchor.y)
      ctx.rotate(by: piece.rotation)
      if style.isUnderlined {
        let grow = strokeOnly ? strokeWidth / 2 : 0
        let rect = CGRect(
          x: -piece.width / 2 - grow,
          y: underlineOffset * fontSize - underlineThickness * fontSize / 2 - grow,
          width: piece.width + grow * 2,
          height: underlineThickness * fontSize + grow * 2
        )
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
      }
      if style.isItalic {
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: -italicSkew, d: 1, tx: 0, ty: 0))
      }
      ctx.setLineJoin(.round)
      ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      ctx.textPosition = CGPoint(x: -piece.width / 2, y: 0)
      CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: piece.text, attributes: attributes)), ctx)
      ctx.restoreGState()
    }
  }

  // MARK: Shadow

  private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  private static func makeShadow(from content: CGImage, style: TextLayerStyle, fontSize: CGFloat) -> CGImage? {
    let blur = shadowBlur(style: style, fontSize: fontSize)
    let offset = shadowOffset(style: style, fontSize: fontSize)
    let alpha = 0.3 + 0.5 * min(max(style.shadow, 0), 1)
    let input = CIImage(cgImage: content)
    let extent = input.extent
    // Black, at `alpha`, keeping only the content's coverage.
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
