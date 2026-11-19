import CoreImage
import CoreImage.CIFilterBuiltins

/// The Filters panel's looks, grouped into category tabs. Classic is the
/// original 10 (Chrome/Noir/Transfer/Process are Apple's own CIPhotoEffect
/// presets); Film/Cinema/Vibes are built from Core Image colour filters
/// only (no spatial effects), so each one is a pure per-pixel colour
/// transform. That's what lets Android reproduce them exactly from a lookup
/// table — see scripts/generate-filter-luts.swift, which compiles THIS file.
/// The raw values are labels AND the saved re-edit value, so never rename one.
enum PhotoFilter: String, CaseIterable {
  case original = "Original"
  // Classic
  case vivid = "Vivid"
  case warm = "Warm"
  case vintage = "Vintage"
  case blackAndWhite = "B&W"
  case cool = "Cool"
  case chrome = "Chrome"
  case noir = "Noir"
  case transfer = "Transfer"
  case process = "Process"
  // Film
  case fade = "Fade"
  case instant = "Instant"
  case tonal = "Tonal"
  case matte = "Matte"
  case golden = "Golden"
  case expired = "Expired"
  case retro = "Retro"
  case polar = "Polar"
  // Cinema
  case tealOrange = "Teal"
  case moody = "Moody"
  case midnight = "Midnight"
  case dusk = "Dusk"
  case bleach = "Bleach"
  case drama = "Drama"
  // Vibes
  case pastel = "Pastel"
  case sunset = "Sunset"
  case rose = "Rose"
  case mint = "Mint"
  case lavender = "Lavender"
  case sepia = "Sepia"
  case duo = "Duo"
  case pop = "Pop"
  // Artistic (photo only — spatial effects, see ArtisticEffects)
  case sketch = "Sketch"
  case comic = "Comic"
  case halftone = "Halftone"
  case pixel = "Pixel"
  case crystal = "Crystal"
  case poster = "Poster"
  case neon = "Neon"

  enum Category: String, CaseIterable {
    case classic = "Classic"
    case film = "Film"
    case cinema = "Cinema"
    case vibes = "Vibes"
    case artistic = "Artistic"
  }

  /// Artistic looks redraw the picture (not a per-pixel colour change), so
  /// they have no Android lookup table and are offered for photos only.
  var isArtistic: Bool { category == .artistic }

  /// Original shows first in every tab; its own category is Classic.
  var category: Category {
    switch self {
    case .original, .vivid, .warm, .vintage, .blackAndWhite, .cool, .chrome, .noir, .transfer, .process:
      return .classic
    case .fade, .instant, .tonal, .matte, .golden, .expired, .retro, .polar:
      return .film
    case .tealOrange, .moody, .midnight, .dusk, .bleach, .drama:
      return .cinema
    case .pastel, .sunset, .rose, .mint, .lavender, .sepia, .duo, .pop:
      return .vibes
    case .sketch, .comic, .halftone, .pixel, .crystal, .poster, .neon:
      return .artistic
    }
  }

  /// The whole Filters-panel stage: the filter at `strength`, then the
  /// panel's own Saturation (-1...1) and Sharpness (0...1). Used by the
  /// preview, photo export and the video compositor alike. Android bakes
  /// the same filter + Strength + Saturation into a lookup table rendered
  /// from these exact filters (scripts/generate-filter-luts.swift) — if a
  /// filter below changes, regenerate those tables too.
  func apply(to image: CIImage, strength: Float, saturation: Float, sharpness: Float) -> CIImage {
    var output = apply(to: image, strength: strength)
    if saturation != 0 {
      let f = CIFilter.colorControls()
      f.inputImage = output
      f.saturation = 1 + saturation
      output = f.outputImage ?? output
    }
    if sharpness > 0 {
      // Same mapping as the Edit panel's Sharpen.
      let f = CIFilter.sharpenLuminance()
      f.inputImage = output
      f.sharpness = sharpness * 0.8
      output = f.outputImage ?? output
    }
    return output
  }

  /// Applies the filter at `strength` (0 = untouched, 1 = full) by
  /// cross-fading the fully filtered result over the source — same
  /// result as Android's identity-blended ColorMatrix for a linear filter.
  func apply(to image: CIImage, strength: Float) -> CIImage {
    guard self != .original else { return image }
    if strength >= 0.999 { return apply(to: image) }
    if strength <= 0.001 { return image }
    let blend = CIFilter.dissolveTransition()
    blend.inputImage = image
    blend.targetImage = apply(to: image)
    blend.time = strength
    return blend.outputImage?.cropped(to: image.extent) ?? apply(to: image)
  }

  func apply(to image: CIImage) -> CIImage {
    switch self {
    case .original:
      return image

    case .vivid:
      let f = CIFilter.colorControls()
      f.inputImage = image
      f.saturation = 1.4
      f.contrast = 1.1
      return f.outputImage ?? image

    case .warm:
      let f = CIFilter.temperatureAndTint()
      f.inputImage = image
      f.neutral = CIVector(x: 6500, y: 0)
      f.targetNeutral = CIVector(x: 4500, y: 0)
      return f.outputImage ?? image

    case .vintage:
      let sepia = CIFilter.sepiaTone()
      sepia.inputImage = image
      sepia.intensity = 0.45
      let desaturated = CIFilter.colorControls()
      desaturated.inputImage = sepia.outputImage ?? image
      desaturated.saturation = 0.85
      desaturated.contrast = 0.95
      return desaturated.outputImage ?? image

    case .blackAndWhite:
      let f = CIFilter.photoEffectMono()
      f.inputImage = image
      return f.outputImage ?? image

    case .cool:
      let f = CIFilter.temperatureAndTint()
      f.inputImage = image
      f.neutral = CIVector(x: 6500, y: 0)
      f.targetNeutral = CIVector(x: 8500, y: 0)
      return f.outputImage ?? image

    case .chrome:
      let f = CIFilter.photoEffectChrome()
      f.inputImage = image
      return f.outputImage ?? image

    case .noir:
      let f = CIFilter.photoEffectNoir()
      f.inputImage = image
      return f.outputImage ?? image

    case .transfer:
      let f = CIFilter.photoEffectTransfer()
      f.inputImage = image
      return f.outputImage ?? image

    case .process:
      let f = CIFilter.photoEffectProcess()
      f.inputImage = image
      return f.outputImage ?? image

    // MARK: Film
    case .fade:
      let f = CIFilter.photoEffectFade()
      f.inputImage = image
      return f.outputImage ?? image

    case .instant:
      let f = CIFilter.photoEffectInstant()
      f.inputImage = image
      return f.outputImage ?? image

    case .tonal:
      let f = CIFilter.photoEffectTonal()
      f.inputImage = image
      return f.outputImage ?? image

    case .matte:
      // Lifted blacks, softened whites, a little less colour.
      let lifted = FilterKit.curve(image, [0.10, 0.28, 0.50, 0.72, 0.92])
      return FilterKit.controls(lifted, saturation: 0.85)

    case .golden:
      let warmed = FilterKit.temperature(image, target: 4800, tint: 8)
      let toned = FilterKit.splitTone(warmed, shadow: (0.04, 0.02, -0.03), highlight: (0.06, 0.03, -0.04))
      return FilterKit.vibrance(toned, 0.25)

    case .expired:
      // Faded, green-yellow cast in the shadows, magenta-ish highlights.
      let faded = FilterKit.curve(image, [0.08, 0.30, 0.52, 0.74, 0.95])
      let toned = FilterKit.splitTone(faded, shadow: (-0.02, 0.05, 0.00), highlight: (0.05, 0.00, 0.04))
      return FilterKit.controls(toned, saturation: 0.8, contrast: 0.95)

    case .retro:
      let sepia = CIFilter.sepiaTone()
      sepia.inputImage = image
      sepia.intensity = 0.3
      let faded = FilterKit.curve(sepia.outputImage ?? image, [0.06, 0.27, 0.50, 0.74, 0.96])
      return FilterKit.temperature(faded, target: 5500, tint: 5)

    case .polar:
      let cooled = FilterKit.temperature(image, target: 9000, tint: 0)
      let bright = FilterKit.exposure(cooled, 0.15)
      return FilterKit.controls(bright, saturation: 0.75, contrast: 1.05)

    // MARK: Cinema
    case .tealOrange:
      let toned = FilterKit.splitTone(image, shadow: (-0.06, 0.02, 0.07), highlight: (0.08, 0.03, -0.06))
      return FilterKit.controls(toned, saturation: 1.1, contrast: 1.08)

    case .moody:
      let crushed = FilterKit.curve(image, [0.04, 0.20, 0.45, 0.70, 0.90])
      let toned = FilterKit.splitTone(crushed, shadow: (-0.02, 0.01, 0.04), highlight: (0.02, 0.01, -0.01))
      return FilterKit.controls(toned, saturation: 0.7, contrast: 1.1)

    case .midnight:
      let cooled = FilterKit.temperature(image, target: 10000, tint: -5)
      let dark = FilterKit.exposure(cooled, -0.35)
      return FilterKit.controls(dark, saturation: 0.7, contrast: 1.15)

    case .dusk:
      let toned = FilterKit.splitTone(image, shadow: (0.00, -0.02, 0.07), highlight: (0.08, 0.00, 0.05))
      return FilterKit.controls(toned, saturation: 1.05, contrast: 1.05)

    case .bleach:
      // Bleach bypass: low saturation, hard contrast, silvery highlights.
      return FilterKit.controls(image, saturation: 0.45, contrast: 1.2, brightness: 0.02)

    case .drama:
      let dark = FilterKit.exposure(image, -0.2)
      let curved = FilterKit.curve(dark, [0.0, 0.18, 0.50, 0.82, 1.0])
      return FilterKit.controls(curved, saturation: 0.9, contrast: 1.1)

    // MARK: Vibes
    case .pastel:
      let lifted = FilterKit.curve(image, [0.12, 0.35, 0.58, 0.80, 0.98])
      let toned = FilterKit.splitTone(lifted, shadow: (0.03, 0.00, 0.03), highlight: (0.02, 0.01, 0.02))
      return FilterKit.controls(toned, saturation: 0.65)

    case .sunset:
      let warmed = FilterKit.temperature(image, target: 4000, tint: 20)
      return FilterKit.vibrance(warmed, 0.35)

    case .rose:
      let toned = FilterKit.splitTone(image, shadow: (0.05, -0.01, 0.03), highlight: (0.06, 0.00, 0.03))
      return FilterKit.controls(toned, saturation: 0.95, brightness: 0.02)

    case .mint:
      let toned = FilterKit.splitTone(image, shadow: (-0.03, 0.04, 0.03), highlight: (-0.01, 0.04, 0.02))
      let bright = FilterKit.exposure(toned, 0.1)
      return FilterKit.controls(bright, saturation: 0.85)

    case .lavender:
      let toned = FilterKit.splitTone(image, shadow: (0.03, -0.01, 0.07), highlight: (0.03, 0.00, 0.05))
      return FilterKit.controls(toned, saturation: 0.8, brightness: 0.02)

    case .sepia:
      let f = CIFilter.sepiaTone()
      f.inputImage = image
      f.intensity = 0.9
      return f.outputImage ?? image

    case .duo:
      // Duotone: shadows deep indigo, highlights warm pink.
      let f = CIFilter.falseColor()
      f.inputImage = image
      f.color0 = CIColor(red: 0.12, green: 0.08, blue: 0.35)
      f.color1 = CIColor(red: 1.0, green: 0.86, blue: 0.80)
      return f.outputImage ?? image

    case .pop:
      let punchy = FilterKit.controls(image, saturation: 1.25, contrast: 1.15)
      return FilterKit.vibrance(punchy, 0.4)

    case .sketch, .comic, .halftone, .pixel, .crystal, .poster, .neon:
      return ArtisticEffects.apply(self, to: image)
    }
  }
}

/// Small helpers for building the colour-only looks above. Every helper is
/// a per-pixel colour operation (no blur/vignette/grain), which keeps each
/// look reproducible as a lookup table on Android.
enum FilterKit {
  static func controls(_ image: CIImage, saturation: Float = 1, contrast: Float = 1, brightness: Float = 0) -> CIImage {
    let f = CIFilter.colorControls()
    f.inputImage = image
    f.saturation = saturation
    f.contrast = contrast
    f.brightness = brightness
    return f.outputImage ?? image
  }

  /// White-balance shift from daylight (6500K) to `target`.
  static func temperature(_ image: CIImage, target: CGFloat, tint: CGFloat) -> CIImage {
    let f = CIFilter.temperatureAndTint()
    f.inputImage = image
    f.neutral = CIVector(x: 6500, y: 0)
    f.targetNeutral = CIVector(x: target, y: tint)
    return f.outputImage ?? image
  }

  /// Runs `body` on display-encoded (sRGB gamma) values instead of Core
  /// Image's linear working space, so curve points and tint amounts mean
  /// what they look like (a +0.05 tint is ~13/255 on screen, not a huge
  /// jump in the shadows).
  static func perceptual(_ image: CIImage, _ body: (CIImage) -> CIImage) -> CIImage {
    let encode = CIFilter.linearToSRGBToneCurve()
    encode.inputImage = image
    let decode = CIFilter.sRGBToneCurveToLinear()
    decode.inputImage = body(encode.outputImage ?? image)
    return decode.outputImage ?? image
  }

  /// Tone curve through 5 evenly spaced points (x = 0, 0.25, 0.5, 0.75, 1),
  /// in display (sRGB) values.
  static func curve(_ image: CIImage, _ y: [CGFloat]) -> CIImage {
    perceptual(image) { curveLinear($0, y) }
  }

  private static func curveLinear(_ image: CIImage, _ y: [CGFloat]) -> CIImage {
    let f = CIFilter.toneCurve()
    f.inputImage = image
    f.point0 = CGPoint(x: 0, y: y[0])
    f.point1 = CGPoint(x: 0.25, y: y[1])
    f.point2 = CGPoint(x: 0.5, y: y[2])
    f.point3 = CGPoint(x: 0.75, y: y[3])
    f.point4 = CGPoint(x: 1, y: y[4])
    return f.outputImage ?? image
  }

  static func vibrance(_ image: CIImage, _ amount: Float) -> CIImage {
    let f = CIFilter.vibrance()
    f.inputImage = image
    f.amount = amount
    return f.outputImage ?? image
  }

  static func exposure(_ image: CIImage, _ ev: Float) -> CIImage {
    let f = CIFilter.exposureAdjust()
    f.inputImage = image
    f.ev = ev
    return f.outputImage ?? image
  }

  /// Split toning: adds `shadow` RGB to the dark areas and `highlight` RGB
  /// to the bright areas (display values), blended by the pixel's own
  /// luminance.
  static func splitTone(
    _ image: CIImage,
    shadow: (CGFloat, CGFloat, CGFloat),
    highlight: (CGFloat, CGFloat, CGFloat)
  ) -> CIImage {
    perceptual(image) { splitToneEncoded($0, shadow: shadow, highlight: highlight) }
  }

  private static func splitToneEncoded(
    _ image: CIImage,
    shadow: (CGFloat, CGFloat, CGFloat),
    highlight: (CGFloat, CGFloat, CGFloat)
  ) -> CIImage {
    func tinted(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CIImage {
      let f = CIFilter.colorMatrix()
      f.inputImage = image
      f.biasVector = CIVector(x: rgb.0, y: rgb.1, z: rgb.2, w: 0)
      return f.outputImage ?? image
    }
    let mask = controls(image, saturation: 0)
    let blend = CIFilter.blendWithMask()
    blend.inputImage = tinted(highlight)
    blend.backgroundImage = tinted(shadow)
    blend.maskImage = mask
    // A colour-matrix bias tints the empty space outside the image too
    // (infinite extent) — crop back so thumbnails/exports keep their size.
    return (blend.outputImage ?? image).cropped(to: image.extent)
  }
}

/// Brightness/contrast/saturation/... adjustment slider values, applied
/// after the named PhotoFilter — the exact CIFilter chain the adjustment
/// sliders drive, extracted into a plain value type (rather than a method
/// reading live `self.brightness` etc. fields) so it can be captured once
/// and handed to the video export compositor (MediaEditorVideoCompositor),
/// which runs on an AVFoundation-internal background queue with no access
/// to a live MediaEditorViewController instance.
struct PhotoAdjustments: Codable {
  var brightness: Float = 0
  var contrast: Float = 0
  var saturation: Float = 0
  var fade: Float = 0
  var shadow: Float = 0
  var highlights: Float = 0
  var warmth: Float = 0
  var tint: Float = 0
  var sharpen: Float = 0
  var vignette: Float = 0

  func apply(to image: CIImage) -> CIImage {
    var output = image

    // Skipped entirely (was unconditional) when brightness/contrast/
    // saturation/fade are all at their untouched default (0) — those
    // defaults make CIColorControls a mathematical no-op anyway
    // (brightness 0, contrast 1x, saturation 1x), but running the actual
    // GPU filter for every single exported frame regardless was real,
    // avoidable per-frame cost on the export path, which every other
    // block in this function already avoids via its own `if x != 0`
    // guard — this was the one exception.
    if brightness != 0 || contrast != 0 || saturation != 0 || fade != 0 {
      // Fade folds into the same brightness/contrast node as B/C/S, rather
      // than adding a separate CIFilter stage — positive fade = lower
      // contrast + lifted brightness (washed out); negative = the opposite
      // (punchier/more vivid).
      let fadeContrastDelta: Float = fade >= 0 ? -0.35 * fade : 0.3 * -fade
      let fadeBrightnessDelta: Float = fade >= 0 ? 0.12 * fade : 0

      let adjust = CIFilter.colorControls()
      adjust.inputImage = output
      adjust.brightness = brightness + fadeBrightnessDelta
      adjust.contrast = 1 + contrast + fadeContrastDelta
      adjust.saturation = 1 + saturation
      output = adjust.outputImage ?? output
    }

    // Warmth — a plain RGB channel scale (same math as Android's tint
    // matrix), not CITemperatureAndTint, so both platforms match.
    if warmth != 0 {
      let warmthMatrix = CIFilter.colorMatrix()
      warmthMatrix.inputImage = output
      let redMul = CGFloat(1 + 0.25 * warmth)
      let blueMul = CGFloat(1 - 0.25 * warmth)
      warmthMatrix.rVector = CIVector(x: redMul, y: 0, z: 0, w: 0)
      warmthMatrix.bVector = CIVector(x: 0, y: 0, z: blueMul, w: 0)
      output = warmthMatrix.outputImage ?? output
    }

    // Shadow/Highlights share CIHighlightShadowAdjust — one filter
    // invocation combining both parameters, since the API only exposes one
    // shadowAmount (0...1, lift-only) and one highlightAmount (0...1,
    // attenuate-only toward 1) per call. Neither has a built-in "opposite
    // direction" (deepen shadows / boost highlights), so those still fall
    // back to the same contrast/brightness approximation as before.
    if shadow > 0 || highlights > 0 {
      let shadowHighlightFilter = CIFilter.highlightShadowAdjust()
      shadowHighlightFilter.inputImage = output
      shadowHighlightFilter.shadowAmount = max(shadow, 0)
      shadowHighlightFilter.highlightAmount = 1 - max(highlights, 0)
      output = shadowHighlightFilter.outputImage ?? output
    }
    if shadow < 0 {
      let deepen = CIFilter.colorControls()
      deepen.inputImage = output
      deepen.contrast = 1 - shadow * 0.3
      output = deepen.outputImage ?? output
    }
    if highlights < 0 {
      let boostHighlights = CIFilter.colorControls()
      boostHighlights.inputImage = output
      boostHighlights.brightness = -highlights * 0.2
      output = boostHighlights.outputImage ?? output
    }

    // Tint — green-magenta shift via colorMatrix's G channel, the
    // counterpart to Warmth's blue-orange shift via R/B above. Same
    // coefficients as Android's tintMatrix call for cross-platform
    // consistency.
    if tint != 0 {
      let tintFilter = CIFilter.colorMatrix()
      tintFilter.inputImage = output
      let gMul = CGFloat(1 + 0.2 * tint)
      let rMul = CGFloat(1 - 0.15 * tint)
      let bMul = CGFloat(1 - 0.15 * tint)
      tintFilter.rVector = CIVector(x: rMul, y: 0, z: 0, w: 0)
      tintFilter.gVector = CIVector(x: 0, y: gMul, z: 0, w: 0)
      tintFilter.bVector = CIVector(x: 0, y: 0, z: bMul, w: 0)
      output = tintFilter.outputImage ?? output
    }

    // Sharpen — no natural "negative" direction, so only apply above 0.
    if sharpen > 0 {
      let sharpenFilter = CIFilter.sharpenLuminance()
      sharpenFilter.inputImage = output
      sharpenFilter.sharpness = sharpen * 0.8
      output = sharpenFilter.outputImage ?? output
    }

    // Vignette — no natural "negative" direction, so only apply above 0.
    if vignette > 0 {
      let vignetteFilter = CIFilter.vignette()
      vignetteFilter.inputImage = output
      vignetteFilter.intensity = vignette
      vignetteFilter.radius = 1.5
      output = vignetteFilter.outputImage ?? output
    }

    return output
  }
}

/// Tilt-shift / background blur (photo only, like Vignette/Sharpen): the
/// photo stays sharp inside a circle (radial) or a band (linear) and blurs
/// progressively outside it. All geometry is normalized to the photo itself
/// (not the screen), so the same value renders identically on the
/// downsampled preview and the full-res export.
struct PhotoBlur: Codable, Equatable {
  enum Mode: String, Codable { case off, radial, linear }

  var mode: Mode = .off
  /// Sharp-area center, 0...1 of the photo's width/height (top-left origin).
  var centerX: Double = 0.5
  var centerY: Double = 0.5
  /// Radial: sharp radius. Linear: half the sharp band's height. Fraction
  /// of the photo's shorter side.
  var size: Double = 0.22
  /// Linear only: band angle in radians (0 = horizontal band).
  var angle: Double = 0
  /// 0...1 → max blur radius (see `maxBlurFraction`).
  var strength: Double = 0.6

  static let minSize: Double = 0.04
  static let maxSize: Double = 0.9
  /// Max blur radius as a fraction of the shorter side.
  static let maxBlurFraction: Double = 0.03
  /// Blur ramps in over this many `size`s beyond the sharp edge.
  static let featherFactor: Double = 0.7

  var isActive: Bool { mode != .off && strength > 0.001 }

  func apply(to image: CIImage) -> CIImage {
    guard isActive else { return image }
    let extent = image.extent
    guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return image }
    let minSide = Double(min(extent.width, extent.height))
    let inner = size * minSide
    let outer = inner + max(size * Self.featherFactor, 0.05) * minSide
    // Core Image is bottom-left origin; centerY is top-left.
    let cx = Double(extent.minX) + centerX * Double(extent.width)
    let cy = Double(extent.minY) + (1 - centerY) * Double(extent.height)

    // Mask: black = sharp, white = fully blurred.
    let mask: CIImage?
    switch mode {
    case .off:
      return image
    case .radial:
      let g = CIFilter.radialGradient()
      g.center = CGPoint(x: cx, y: cy)
      g.radius0 = Float(inner)
      g.radius1 = Float(outer)
      g.color0 = CIColor.black
      g.color1 = CIColor.white
      mask = g.outputImage
    case .linear:
      // Unit normal to the band, in CI (y-up) space. A band at `angle`
      // (screen space, y-down, clockwise) has normal (-sin, cos) on screen
      // → (-sin, -cos) after flipping y.
      let nx = -sin(angle), ny = -cos(angle)
      func side(_ sign: Double) -> CIImage? {
        let g = CIFilter.smoothLinearGradient()
        g.point0 = CGPoint(x: cx + sign * nx * inner, y: cy + sign * ny * inner)
        g.point1 = CGPoint(x: cx + sign * nx * outer, y: cy + sign * ny * outer)
        g.color0 = CIColor.black
        g.color1 = CIColor.white
        return g.outputImage
      }
      if let a = side(1), let b = side(-1) {
        let combine = CIFilter.maximumCompositing()
        combine.inputImage = a
        combine.backgroundImage = b
        mask = combine.outputImage
      } else {
        mask = nil
      }
    }
    guard let mask else { return image }
    let blur = CIFilter.maskedVariableBlur()
    blur.inputImage = image.clampedToExtent()
    blur.mask = mask.cropped(to: extent)
    blur.radius = Float(strength * Self.maxBlurFraction * minSide)
    return blur.outputImage?.cropped(to: extent) ?? image
  }
}

/// One-tap "Auto" enhance: analyses the photo and picks balanced values for
/// the EXISTING Brightness/Contrast/Saturation/Warm sliders, so the result
/// stays fully editable/undoable and goes through the normal preview/export
/// pipeline. Same approach as Android's PhotoAutoEnhance, but each platform
/// fits its OWN slider math (see compute(samples:)).
struct PhotoAutoEnhance: Equatable {
  var brightness: Float
  var contrast: Float
  var saturation: Float
  var warmth: Float

  /// Sampled at this long side — plenty for global statistics.
  private static let sampleLongSide = 96

  static func compute(from image: CGImage) -> PhotoAutoEnhance? {
    let longSide = max(image.width, image.height)
    guard longSide > 0 else { return nil }
    let scale = min(1, Double(sampleLongSide) / Double(longSide))
    let w = max(1, Int(Double(image.width) * scale))
    let h = max(1, Int(Double(image.height) * scale))
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(
        data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else { return false }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }
    var samples: [(r: Double, g: Double, b: Double)] = []
    samples.reserveCapacity(w * h)
    for i in stride(from: 0, to: pixels.count, by: 4) {
      samples.append((Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255))
    }
    return compute(samples: samples)
  }

  /// Pure math on RGB samples (0...1, sRGB).
  ///
  /// 1. Decide the IDEAL tone curve in sRGB: an auto-levels stretch
  ///    (0.5%–99.5% luminance → 0–1) at 75% strength, plus a gentle gamma
  ///    pulling the mean toward mid-grey for under/over-exposed photos.
  /// 2. Search the Brightness/Contrast pair whose ACTUAL slider math on this
  ///    platform best reproduces that curve, weighted by the photo's own
  ///    histogram. iOS's sliders are CIColorControls, which works in LINEAR
  ///    light, contrast first (pivot linear 0.5), then additive brightness —
  ///    measured, not assumed. Android's sliders are sRGB, brightness first.
  ///    So the same "ideal" gives different slider numbers per platform.
  static func compute(samples: [(r: Double, g: Double, b: Double)]) -> PhotoAutoEnhance? {
    guard !samples.isEmpty else { return nil }
    var histogram = [Double](repeating: 0, count: 256)
    var satSum = 0.0
    var midR = 0.0, midB = 0.0, midCount = 0.0
    for s in samples {
      let lum = 0.299 * s.r + 0.587 * s.g + 0.114 * s.b
      histogram[min(255, max(0, Int(lum * 255)))] += 1
      let maxC = max(s.r, s.g, s.b), minC = min(s.r, s.g, s.b)
      satSum += maxC > 0 ? (maxC - minC) / maxC : 0
      if lum > 0.15 && lum < 0.85 {
        midR += srgbToLinear(s.r); midB += srgbToLinear(s.b); midCount += 1
      }
    }
    let n = Double(samples.count)
    func percentile(_ p: Double) -> Double {
      let target = n * p
      var running = 0.0
      for (bin, count) in histogram.enumerated() {
        running += count
        if running > target { return Double(bin) / 255 }
      }
      return 1
    }
    let lo = percentile(0.005), hi = max(percentile(0.995), lo + 0.05)

    // 1. Ideal tone curve.
    func levels(_ x: Double) -> Double { x + 0.75 * ((x - lo) / (hi - lo) - x) }
    var meanAfterLevels = 0.0
    for bin in 0..<256 where histogram[bin] > 0 {
      meanAfterLevels += min(max(levels(Double(bin) / 255), 0), 1) * histogram[bin]
    }
    meanAfterLevels /= n
    // Exposure only for genuinely dark/bright photos (a white-on-white or
    // night shot is allowed to stay high-/low-key): pull the mean 60% of
    // the way back into 0.38...0.62 with a gamma.
    let targetMean = min(max(meanAfterLevels, 0.38), 0.62)
    let fullGamma = log(targetMean) / log(min(max(meanAfterLevels, 0.03), 0.97))
    let gamma = min(max(1 + 0.6 * (fullGamma - 1), 0.6), 1.4)
    var idealCurve = [Double](repeating: 0, count: 256)
    for bin in 0..<256 { idealCurve[bin] = pow(min(max(levels((Double(bin) + 0.5) / 255), 0), 1), gamma) }

    // Every tone inside the photo's own range counts (not just the common
    // ones), so a few dark pixels can't be sacrificed to fit the bulk.
    let floorWeight = n / 256 * 0.6
    var weights = [Double](repeating: 0, count: 256)
    for bin in 0..<256 {
      let x = Double(bin) / 255
      weights[bin] = histogram[bin] + (x >= lo && x <= hi ? floorWeight : 0)
    }
    let linearIn = (0..<256).map { srgbToLinear((Double($0) + 0.5) / 255) }

    // 2. Best-fit slider pair for this platform's real slider math
    //    (iOS: linear light, contrast about 0.5, then additive brightness —
    //    which together can also express a pure exposure gain).
    func error(b: Double, c: Double) -> Double {
      var total = 0.0
      for bin in 0..<256 where weights[bin] > 0 {
        let raw = (linearIn[bin] - 0.5) * c + 0.5 + b
        let out = linearToSrgb(min(max(raw, 0), 1))
        let target = idealCurve[bin]
        let d = out - target
        var e = d * d
        // Clipping that the ideal curve doesn't ask for is much worse than
        // a slightly-off tone: crushed blacks / blown highlights.
        // On iOS any negative offset (brightness below what contrast
        // implies) clips the darkest tones outright, so even a small
        // unrequested clip carries a flat cost.
        if raw <= 0 && target > 0.004 { e += 0.05 + 10 * target * target }
        if raw >= 1 && target < 0.99 { e += 0.05 + 10 * (1 - target) * (1 - target) }
        total += e * weights[bin]
      }
      // Small pull toward "no change" so near-perfect photos stay put.
      return total + n * 0.0003 * ((c - 1) * (c - 1) + b * b)
    }
    // Coarse grid, then a fine pass around the winner.
    var best = (b: 0.0, c: 1.0, error: error(b: 0, c: 1))
    for c in stride(from: 0.7, through: 1.8, by: 0.05) {
      for b in stride(from: -0.3, through: 0.4, by: 0.05) {
        let e = error(b: b, c: c)
        if e < best.error { best = (b, c, e) }
      }
    }
    let coarse = best
    for c in stride(from: coarse.c - 0.05, through: coarse.c + 0.05, by: 0.01) {
      for b in stride(from: coarse.b - 0.05, through: coarse.b + 0.05, by: 0.01) {
        let e = error(b: b, c: c)
        if e < best.error { best = (b, c, e) }
      }
    }

    // Saturation: half-way toward a natural ~0.30 mean (HSV saturation).
    // Near-B&W photos are left alone and mostly-neutral ones (white
    // subject) only get a small lift; contrast already adds some punch.
    let meanSat = satSum / n
    var saturation = 0.0
    if meanSat > 0.06 {
      saturation = 0.5 * (0.30 / meanSat - 1) - 0.15 * (best.c - 1)
      saturation = min(max(saturation, -0.1), meanSat < 0.12 ? 0.1 : 0.25)
    }

    // Warmth: correct a colour cast (grey-world on mid-tones) in the space
    // the Warm slider multiplies in (linear on iOS). Blue casts are
    // corrected firmly; warm ones only lightly, since many photos (food,
    // sunsets, indoor light) are SUPPOSED to be warm.
    var warmth = 0.0
    if midCount > n * 0.05 {
      let r = midR / midCount, b = midB / midCount
      if r + b > 0 {
        let full = (b - r) / (0.25 * (r + b)) // makes mid-tone R == B
        if abs(full) >= 0.1 {
          warmth = full > 0 ? min(full * 0.7, 0.6) : max(full * 0.25, -0.15)
        }
      }
    }

    func rounded(_ v: Double) -> Float { Float((v * 100).rounded() / 100) }
    return PhotoAutoEnhance(
      brightness: rounded(best.b),
      contrast: rounded(best.c - 1),
      saturation: rounded(saturation),
      warmth: rounded(warmth)
    )
  }

  private static func srgbToLinear(_ v: Double) -> Double {
    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
  }

  private static func linearToSrgb(_ v: Double) -> Double {
    v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
  }
}

// MARK: - Artistic effects

/// CPU implementations of the Artistic looks. Android's ArtisticEffects.kt
/// is a line-by-line port (same integer maths, same hash, same order), so
/// both platforms draw the same picture. All sizes scale with the image's
/// short side, so a thumbnail, the preview and the full-size export look
/// alike. Pixel rows run top to bottom, matching an Android Bitmap.
enum ArtisticEffects {
  private static let context = CIContext(options: [.cacheIntermediates: false])
  private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let lock = NSLock()
  /// One cached result: Edit-panel slider ticks re-run the whole filter
  /// chain on the same source, and redrawing the effect each time is slow.
  private static var cache: (key: String, output: CIImage)?

  /// Effects are drawn at most this big (long side) and scaled up after —
  /// full-size exports would otherwise need hundreds of MB. Same on Android.
  static let maxProcessingSide = 1600

  static func apply(_ filter: PhotoFilter, to image: CIImage) -> CIImage {
    let extent = image.extent.integral
    guard !extent.isInfinite, extent.width >= 2, extent.height >= 2 else { return image }
    let fullW = Int(extent.width), fullH = Int(extent.height)
    let longSide = max(fullW, fullH)
    var w = fullW, h = fullH
    if longSide > maxProcessingSide {
      w = max(2, Int((Float(fullW) * Float(maxProcessingSide) / Float(longSide)).rounded()))
      h = max(2, Int((Float(fullH) * Float(maxProcessingSide) / Float(longSide)).rounded()))
    }
    let source = image
      .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
      .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(fullW), y: CGFloat(h) / CGFloat(fullH)))
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    context.render(source, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: colorSpace)

    // Back to the input's own size and position.
    func placed(_ output: CIImage) -> CIImage {
      output
        .transformed(by: CGAffineTransform(scaleX: CGFloat(fullW) / CGFloat(w), y: CGFloat(fullH) / CGFloat(h)))
        .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        .cropped(to: image.extent)
    }

    let key = "\(filter.rawValue)|\(w)x\(h)|\(fingerprint(rgba))"
    lock.lock()
    if let cached = cache, cached.key == key {
      lock.unlock()
      return placed(cached.output)
    }
    lock.unlock()

    var r = [Int](repeating: 0, count: w * h), g = r, b = r
    for i in 0..<(w * h) {
      r[i] = Int(rgba[i * 4]); g[i] = Int(rgba[i * 4 + 1]); b[i] = Int(rgba[i * 4 + 2])
    }
    let out = process(filter, r, g, b, w, h)
    for i in 0..<(w * h) {
      rgba[i * 4] = UInt8(out.r[i]); rgba[i * 4 + 1] = UInt8(out.g[i]); rgba[i * 4 + 2] = UInt8(out.b[i]); rgba[i * 4 + 3] = 255
    }
    let output = CIImage(
      bitmapData: Data(rgba), bytesPerRow: w * 4, size: CGSize(width: w, height: h),
      format: .RGBA8, colorSpace: colorSpace
    )
    lock.lock()
    cache = (key, output)
    lock.unlock()
    return placed(output)
  }

  /// Cheap content hash over ~4k evenly spaced bytes.
  private static func fingerprint(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 14695981039346656037
    let step = max(1, bytes.count / 4096)
    var i = 0
    while i < bytes.count {
      hash = (hash ^ UInt64(bytes[i])) &* 1099511628211
      i += step
    }
    return hash
  }

  typealias Planes = (r: [Int], g: [Int], b: [Int])

  @_optimize(speed)
  static func process(_ filter: PhotoFilter, _ r: [Int], _ g: [Int], _ b: [Int], _ w: Int, _ h: Int) -> Planes {
    switch filter {
    case .sketch: return sketch(r, g, b, w, h)
    case .comic: return comic(r, g, b, w, h)
    case .halftone: return halftone(r, g, b, w, h)
    case .pixel: return pixelate(r, g, b, w, h)
    case .crystal: return crystal(r, g, b, w, h)
    case .poster: return (posterize(r, 5), posterize(g, 5), posterize(b, 5))
    case .neon: return neon(r, g, b, w, h)
    default: return (r, g, b)
    }
  }

  // MARK: Shared helpers (mirrored exactly in ArtisticEffects.kt)

  @inline(__always) static func luma(_ r: Int, _ g: Int, _ b: Int) -> Int { (r * 77 + g * 150 + b * 29) >> 8 }

  @_optimize(speed)
  static func lumaPlane(_ r: [Int], _ g: [Int], _ b: [Int]) -> [Int] {
    var out = [Int](repeating: 0, count: r.count)
    for i in 0..<r.count { out[i] = luma(r[i], g[i], b[i]) }
    return out
  }

  /// Separable box blur, edges clamped, integer average.
  @_optimize(speed)
  static func boxBlur(_ src: [Int], _ w: Int, _ h: Int, _ radius: Int) -> [Int] {
    if radius <= 0 { return src }
    let div = 2 * radius + 1
    var tmp = [Int](repeating: 0, count: w * h)
    var out = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
      let row = y * w
      var sum = 0
      for k in -radius...radius { sum += src[row + min(max(k, 0), w - 1)] }
      for x in 0..<w {
        tmp[row + x] = sum / div
        sum += src[row + min(x + radius + 1, w - 1)] - src[row + max(x - radius, 0)]
      }
    }
    for x in 0..<w {
      var sum = 0
      for k in -radius...radius { sum += tmp[min(max(k, 0), h - 1) * w + x] }
      for y in 0..<h {
        out[y * w + x] = sum / div
        sum += tmp[min(y + radius + 1, h - 1) * w + x] - tmp[max(y - radius, 0) * w + x]
      }
    }
    return out
  }

  /// Sobel edge strength 0...255. `scale` compensates for a pre-blur of
  /// that width, so edge strength doesn't depend on image size.
  @_optimize(speed)
  static func edges(_ l: [Int], _ w: Int, _ h: Int, _ scale: Int) -> [Int] {
    var out = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
      let ym = max(y - 1, 0) * w, yc = y * w, yp = min(y + 1, h - 1) * w
      for x in 0..<w {
        let xm = max(x - 1, 0), xp = min(x + 1, w - 1)
        let gx = (l[ym + xp] + 2 * l[yc + xp] + l[yp + xp]) - (l[ym + xm] + 2 * l[yc + xm] + l[yp + xm])
        let gy = (l[yp + xm] + 2 * l[yp + x] + l[yp + xp]) - (l[ym + xm] + 2 * l[ym + x] + l[ym + xp])
        out[yc + x] = min(255, (abs(gx) + abs(gy)) * scale / 8)
      }
    }
    return out
  }

  @_optimize(speed)
  static func posterize(_ p: [Int], _ levels: Int) -> [Int] {
    let n = levels - 1
    var out = [Int](repeating: 0, count: p.count)
    for i in 0..<p.count { out[i] = ((p[i] * n + 127) / 255) * 255 / n }
    return out
  }

  /// Deterministic 0..<1 value per grid cell (same bits as Kotlin's Int maths).
  static func hashFraction(_ i: Int, _ j: Int, _ seed: Int) -> Float {
    var h = UInt32(truncatingIfNeeded: i) &* 374761393
      &+ UInt32(truncatingIfNeeded: j) &* 668265263
      &+ UInt32(truncatingIfNeeded: seed) &* 144665
    h = (h ^ (h >> 13)) &* 1274126177
    h = h ^ (h >> 16)
    return Float(h >> 8) / 16777216
  }

  // MARK: Effects

  /// Pencil sketch: colour-dodge of the grey image with its blurred inverse.
  @_optimize(speed)
  static func sketch(_ r: [Int], _ g: [Int], _ b: [Int], _ w: Int, _ h: Int) -> Planes {
    let side = min(w, h)
    let gray = lumaPlane(r, g, b)
    var inverted = [Int](repeating: 0, count: w * h)
    for i in 0..<(w * h) { inverted[i] = 255 - gray[i] }
    let radius = max(1, side / 120)
    let blurred = boxBlur(boxBlur(inverted, w, h, radius), w, h, radius)
    var out = [Int](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
      let dodge = blurred[i] >= 255 ? 255 : min(255, gray[i] * 255 / (255 - blurred[i]))
      out[i] = 255 - min(255, (255 - dodge) * 2) // deepen the pencil lines
    }
    return (out, out, out)
  }

  /// Comic: flat posterized colours with bold dark outlines.
  @_optimize(speed)
  static func comic(_ r: [Int], _ g: [Int], _ b: [Int], _ w: Int, _ h: Int) -> Planes {
    let side = min(w, h)
    let radius = max(1, side / 400)
    let br = boxBlur(r, w, h, radius), bg = boxBlur(g, w, h, radius), bb = boxBlur(b, w, h, radius)
    let edge = edges(lumaPlane(br, bg, bb), w, h, 2 * radius + 1)
    var mask = [Int](repeating: 0, count: w * h)
    for i in 0..<(w * h) { mask[i] = edge[i] > 50 ? 255 : 0 }
    mask = boxBlur(mask, w, h, side / 500)
    // Punchier colours before flattening, so the result isn't greyish.
    var sr = br, sg = bg, sb = bb
    for i in 0..<(w * h) {
      let l = luma(br[i], bg[i], bb[i])
      sr[i] = min(255, max(0, l + (br[i] - l) * 3 / 2))
      sg[i] = min(255, max(0, l + (bg[i] - l) * 3 / 2))
      sb[i] = min(255, max(0, l + (bb[i] - l) * 3 / 2))
    }
    var outR = posterize(sr, 4), outG = posterize(sg, 4), outB = posterize(sb, 4)
    for i in 0..<(w * h) where mask[i] > 60 {
      outR[i] = 25; outG[i] = 22; outB[i] = 30
    }
    return (outR, outG, outB)
  }

  /// Colour halftone: one dot per cell on paper, bigger where darker.
  @_optimize(speed)
  static func halftone(_ r: [Int], _ g: [Int], _ b: [Int], _ w: Int, _ h: Int) -> Planes {
    let side = min(w, h)
    let cell = max(4, side / 40)
    var outR = [Int](repeating: 0, count: w * h), outG = outR, outB = outR
    var cy = 0
    while cy < h {
      let y1 = min(cy + cell, h)
      var cx = 0
      while cx < w {
        let x1 = min(cx + cell, w)
        var sr = 0, sg = 0, sb = 0
        for y in cy..<y1 { for x in cx..<x1 { let i = y * w + x; sr += r[i]; sg += g[i]; sb += b[i] } }
        let count = (y1 - cy) * (x1 - cx)
        let ar = sr / count, ag = sg / count, ab = sb / count
        // Dot = the cell's own colour, saturated a little so it reads on paper.
        let l = luma(ar, ag, ab)
        let dotR = min(255, max(0, l + (ar - l) * 3 / 2))
        let dotG = min(255, max(0, l + (ag - l) * 3 / 2))
        let dotB = min(255, max(0, l + (ab - l) * 3 / 2))
        let radius = Float(cell) * 0.6 * (1 - Float(l) / 255 * 0.85).squareRoot()
        let centerX = Float(cx) + Float(cell) * 0.5, centerY = Float(cy) + Float(cell) * 0.5
        for y in cy..<y1 {
          let dy = Float(y) + 0.5 - centerY
          for x in cx..<x1 {
            let dx = Float(x) + 0.5 - centerX
            let coverage = min(max(radius - (dx * dx + dy * dy).squareRoot() + 0.5, 0), 1)
            let i = y * w + x
            outR[i] = Int(Float(250) * (1 - coverage) + Float(dotR) * coverage + 0.5)
            outG[i] = Int(Float(246) * (1 - coverage) + Float(dotG) * coverage + 0.5)
            outB[i] = Int(Float(238) * (1 - coverage) + Float(dotB) * coverage + 0.5)
          }
        }
        cx += cell
      }
      cy += cell
    }
    return (outR, outG, outB)
  }

  /// Big square pixels (block average).
  @_optimize(speed)
  static func pixelate(_ r: [Int], _ g: [Int], _ b: [Int], _ w: Int, _ h: Int) -> Planes {
    let block = max(2, min(w, h) / 64)
    var outR = [Int](repeating: 0, count: w * h), outG = outR, outB = outR
    var by = 0
    while by < h {
      let y1 = min(by + block, h)
      var bx = 0
      while bx < w {
        let x1 = min(bx + block, w)
        var sr = 0, sg = 0, sb = 0
        for y in by..<y1 { for x in bx..<x1 { let i = y * w + x; sr += r[i]; sg += g[i]; sb += b[i] } }
        let count = (y1 - by) * (x1 - bx)
        let ar = sr / count, ag = sg / count, ab = sb / count
        for y in by..<y1 { for x in bx..<x1 { let i = y * w + x; outR[i] = ar; outG[i] = ag; outB[i] = ab } }
        bx += block
      }
      by += block
    }
    return (outR, outG, outB)
  }

  /// Crystal / stained glass: each pixel takes the colour of its nearest
  /// jittered seed point (Voronoi cells).
  @_optimize(speed)
  static func crystal(_ r: [Int], _ g: [Int], _ b: [Int], _ w: Int, _ h: Int) -> Planes {
    let cell = max(4, min(w, h) / 36)
    let gridW = (w + cell - 1) / cell, gridH = (h + cell - 1) / cell
    var seedX = [Float](repeating: 0, count: gridW * gridH), seedY = seedX
    var seedColor = [Int](repeating: 0, count: gridW * gridH)
    for j in 0..<gridH {
      for i in 0..<gridW {
        let sx = (Float(i) + 0.15 + 0.7 * hashFraction(i, j, 1)) * Float(cell)
        let sy = (Float(j) + 0.15 + 0.7 * hashFraction(i, j, 2)) * Float(cell)
        seedX[j * gridW + i] = sx
        seedY[j * gridW + i] = sy
        seedColor[j * gridW + i] = min(Int(sy), h - 1) * w + min(Int(sx), w - 1)
      }
    }
    var outR = [Int](repeating: 0, count: w * h), outG = outR, outB = outR
    for y in 0..<h {
      let cj = y / cell
      let py = Float(y) + 0.5
      for x in 0..<w {
        let ci = x / cell
        let px = Float(x) + 0.5
        var best = Float.greatestFiniteMagnitude
        var bestSource = 0
        for j in max(cj - 1, 0)...min(cj + 1, gridH - 1) {
          for i in max(ci - 1, 0)...min(ci + 1, gridW - 1) {
            let s = j * gridW + i
            let dx = px - seedX[s], dy = py - seedY[s]
            let d = dx * dx + dy * dy
            if d < best { best = d; bestSource = seedColor[s] }
          }
        }
        let o = y * w + x
        outR[o] = r[bestSource]; outG[o] = g[bestSource]; outB[o] = b[bestSource]
      }
    }
    return (outR, outG, outB)
  }

  /// Neon: glowing coloured edges on black.
  @_optimize(speed)
  static func neon(_ r: [Int], _ g: [Int], _ b: [Int], _ w: Int, _ h: Int) -> Planes {
    let side = min(w, h)
    let radius = max(1, side / 500)
    let edge = edges(boxBlur(lumaPlane(r, g, b), w, h, radius), w, h, 2 * radius + 1)
    var line = [Int](repeating: 0, count: w * h)
    for i in 0..<(w * h) { line[i] = min(255, edge[i] * 3) }
    let glow = boxBlur(line, w, h, max(1, side / 300))
    var outR = [Int](repeating: 0, count: w * h), outG = outR, outB = outR
    for i in 0..<(w * h) {
      let intensity = min(255, line[i] + glow[i])
      let l = luma(r[i], g[i], b[i])
      // Saturate the source colour so the glow reads as neon, not grey.
      let cr = min(255, max(0, l + (r[i] - l) * 2 + 40))
      let cg = min(255, max(0, l + (g[i] - l) * 2 + 40))
      let cb = min(255, max(0, l + (b[i] - l) * 2 + 40))
      outR[i] = min(255, cr * intensity / 255 + intensity / 6)
      outG[i] = min(255, cg * intensity / 255 + intensity / 6)
      outB[i] = min(255, cb * intensity / 255 + intensity / 6)
    }
    return (outR, outG, outB)
  }
}
