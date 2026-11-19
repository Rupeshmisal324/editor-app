import Foundation
import UIKit

/// Everything needed to reopen an exported PHOTO with its layers still
/// editable (Instagram/Canva-style re-edit). Returned to JS as an opaque
/// JSON string next to the exported file and passed back on the next
/// `open()`. Only ever read back on the same device/platform, so this is
/// iOS's own format (Android has its own); nothing in JS parses it.
///
/// Files (the untouched source photo + overlay-photo PNGs) live in
/// `Caches/MediaEditorProjects/<id>/`; projects untouched for
/// `maxAgeSeconds` are deleted on the next editor open.
struct MediaEditorEditProject: Codable {
  static let currentVersion = 1

  var version: Int = currentVersion
  var id: String
  /// File name of the untouched source photo inside the project folder.
  var sourceFileName: String
  /// Canvas (imageView bounds) width when saved — positions below are in
  /// these points, rescaled on restore if the canvas comes out different.
  var canvasWidth: Double

  var imageTranslationX: Double = 0
  var imageTranslationY: Double = 0
  var imageScale: Double = 1
  var imageRotation: Double = 0

  var filter: String = PhotoFilter.original.rawValue
  var filterStrength: Float = 1
  /// Optional so projects saved before these sliders existed still decode.
  var filterSaturation: Float?
  var filterSharpness: Float?
  var adjustments: PhotoAdjustments = PhotoAdjustments()
  /// Optional so projects saved before Blur existed still decode.
  var blur: PhotoBlur?

  var strokes: [Stroke] = []
  /// Bottom-to-top, matching on-screen stacking.
  var layers: [Layer] = []

  struct RGBA: Codable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ color: UIColor) {
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
        var white: CGFloat = 0
        color.getWhite(&white, alpha: &a)
        r = white; g = white; b = white
      }
      self.r = Double(r); self.g = Double(g); self.b = Double(b); self.a = Double(a)
    }

    var uiColor: UIColor {
      UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
  }

  struct Stroke: Codable {
    /// Flat [x0, y0, x1, y1, ...] in canvas points.
    var points: [Double]
    var color: RGBA
    var width: Double
    /// DrawingCanvasView.BrushType raw value ("pen", "spray", "eraser"…).
    var brush: String
    /// Texture seed (spray/chalk/squares); absent in older projects.
    var seed: UInt32?
    /// DrawingCanvasView.ShapeType raw value; nil = freehand.
    var shape: String?
  }

  /// An overlay's OverlayStyle + eraser strokes.
  struct OverlayLook: Codable {
    struct EraseStroke: Codable {
      /// Flat [x0, y0, x1, y1, ...], 0…1 of the overlay's box.
      var points: [Double]
      var width: Double
      var restore: Bool
    }
    var filter: String
    var filterStrength: Double
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var warmth: Double
    var opacity: Double
    var blend: String
    var shape: String
    var border: Double
    var borderColor: RGBA
    var flipX: Bool
    var flipY: Bool
    var eraseStrokes: [EraseStroke]

    init(_ style: OverlayStyle, strokes: [OverlayEraseStroke]) {
      filter = style.filter.rawValue
      filterStrength = Double(style.filterStrength)
      brightness = Double(style.brightness)
      contrast = Double(style.contrast)
      saturation = Double(style.saturation)
      warmth = Double(style.warmth)
      opacity = Double(style.opacity)
      blend = style.blend.rawValue
      shape = style.shape.rawValue
      border = Double(style.border)
      borderColor = RGBA(style.borderColor)
      flipX = style.flipX
      flipY = style.flipY
      eraseStrokes = strokes.map { stroke in
        EraseStroke(points: stroke.points.flatMap { [Double($0.x), Double($0.y)] }, width: Double(stroke.width), restore: stroke.restore)
      }
    }

    func restored() -> (OverlayStyle, [OverlayEraseStroke]) {
      var style = OverlayStyle()
      style.filter = PhotoFilter(rawValue: filter) ?? .original
      style.filterStrength = CGFloat(filterStrength)
      style.brightness = CGFloat(brightness)
      style.contrast = CGFloat(contrast)
      style.saturation = CGFloat(saturation)
      style.warmth = CGFloat(warmth)
      style.opacity = CGFloat(opacity)
      style.blend = OverlayBlendMode(rawValue: blend) ?? .normal
      style.shape = OverlayShape(rawValue: shape) ?? .none
      style.border = CGFloat(border)
      style.borderColor = borderColor.uiColor
      style.flipX = flipX
      style.flipY = flipY
      let strokes = eraseStrokes.map { saved -> OverlayEraseStroke in
        var points: [CGPoint] = []
        var i = 0
        while i + 1 < saved.points.count {
          points.append(CGPoint(x: saved.points[i], y: saved.points[i + 1]))
          i += 2
        }
        return OverlayEraseStroke(points: points, width: CGFloat(saved.width), restore: saved.restore)
      }
      return (style, strokes)
    }
  }

  enum Kind: String, Codable {
    case text, sticker, location, image
  }

  struct Layer: Codable {
    var kind: Kind
    var translationX: Double
    var translationY: Double
    var scale: Double
    var rotation: Double

    // text
    var text: String?
    var fontName: String?
    var fontSize: Double?
    var color: RGBA?
    var alignment: Int?
    var isBold: Bool?
    var isItalic: Bool?
    var isUnderlined: Bool?
    /// TextFontCatalog id. Older projects only have `fontName` (an Apple
    /// font's PostScript name) — mapped via TextFontCatalog.optionId(legacyFontName:).
    var fontId: String?
    /// TextBackgroundMode raw value.
    var textBackground: Int?
    var textSize: Double?
    var outline: Double?
    var shadow: Double?
    var opacity: Double?
    var stretchX: Double?
    var stretchY: Double?
    var arch: Double?

    // sticker (also uses opacity/outline/shadow above)
    var assetName: String?
    var flipX: Bool?
    var flipY: Bool?

    // location
    var locationName: String?
    var locationStyle: Int?
    /// Story info pills (see EditableTextLayerView.infoKind); nil = location.
    var infoKind: String?
    var infoValue: String?
    var latitude: Double?
    var longitude: Double?

    // image overlay (the file is the unstyled photo; `overlay` its look)
    var imageFileName: String?
    var overlay: OverlayLook?
    var width: Double?
    var height: Double?
  }

  // MARK: - Storage

  static let maxAgeSeconds: TimeInterval = 2 * 24 * 60 * 60

  static var rootDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MediaEditorProjects", isDirectory: true)
  }

  static func directory(for id: String) -> URL {
    rootDirectory.appendingPathComponent(id, isDirectory: true)
  }

  var directory: URL { Self.directory(for: id) }
  var sourceURL: URL { directory.appendingPathComponent(sourceFileName) }

  static func decode(_ json: String) -> MediaEditorEditProject? {
    guard let data = json.data(using: .utf8),
          let project = try? JSONDecoder().decode(MediaEditorEditProject.self, from: data),
          project.version == currentVersion,
          FileManager.default.fileExists(atPath: project.sourceURL.path)
    else { return nil }
    return project
  }

  func encodedJSON() -> String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Deletes project folders not modified within `maxAgeSeconds`.
  static func pruneStaleProjects(keeping keepID: String?) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
      at: rootDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
    for entry in entries where entry.lastPathComponent != keepID {
      let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, modified < cutoff {
        try? fm.removeItem(at: entry)
      }
    }
  }
}

