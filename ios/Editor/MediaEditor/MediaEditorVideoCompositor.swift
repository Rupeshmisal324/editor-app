import AVFoundation
import CoreImage
import Metal
import UIKit

/// Applies crop/pan/zoom/rotate/filter to each video frame during export —
/// the video counterpart to MediaEditorViewController.renderExport, using
/// the EXACT same composition (translate to crop origin, translate to
/// canvas center, translate by pan, rotate, scale, draw the source image
/// centered) rather than re-deriving it in Core Image's own bottom-left,
/// Y-up coordinate space. Doing the geometry via UIGraphicsImageRenderer/
/// CGContext (UIKit's top-left, Y-down convention — matching every other
/// pan/crop/translation value already computed in UIKit terms elsewhere in
/// this editor) avoids a second, error-prone axis-flip translation of that
/// same math into Core Image's convention; Core Image is used here only for
/// the filter step, which is purely tonal and has no coordinate convention
/// to get wrong.
final class MediaEditorVideoCompositor: NSObject, AVVideoCompositing {
  // kCVPixelBufferMetalCompatibilityKey (both dicts below) — without it,
  // AVFoundation is free to allocate plain, non-GPU-shareable pixel
  // buffers, which forces the Metal-backed CIContext below to do a hidden
  // CPU<->GPU copy just to read/write them on EVERY frame, on top of the
  // actual rendering work. Marking both the source (decoded) and render-
  // context (output) buffers Metal-compatible lets CoreImage read/write
  // them directly on the GPU — pure backing-memory/allocation change, same
  // BGRA pixel format and values either way, no visual difference.
  let sourcePixelBufferAttributes: [String: Any]? = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferMetalCompatibilityKey as String: true,
  ]
  let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferMetalCompatibilityKey as String: true,
  ]

  // AVAsynchronousVideoCompositionRequest is explicitly designed to let a
  // compositor return from startRequest immediately and call
  // request.finish(...) later from any thread once its real work is done —
  // that's the entire point of "Asynchronous" here vs the old synchronous
  // compositing protocol. The code below previously did all of a frame's
  // actual CI/CG work INLINE on the thread AVFoundation called startRequest
  // on, then called finish() before returning — which works, but means
  // AVFoundation has no reason to hand this compositor a second frame to
  // work on until the first one's entire CPU-heavy render finishes, so
  // every frame's decode + composite + encode serializes fully, one frame
  // at a time, using only one core. Dispatching the actual work onto a
  // concurrent queue instead lets multiple frames' CPU-side compositing
  // (the UIGraphicsImageRenderer/CGContext geometry+overlay pass, the
  // single biggest per-frame cost) run in parallel across cores, and lets
  // AVFoundation keep decoding/queuing ahead instead of stalling on this
  // one frame — same exact per-pixel math as before, purely a threading
  // change. CIContext itself is documented safe to use concurrently from
  // multiple threads.
  private let compositingQueue = DispatchQueue(
    label: "com.intoactive.mediaeditor.compositing", attributes: .concurrent
  )
  // Bounds how many frames can be composited at once (each holds a
  // decoded source buffer + a full-size rendered CGImage + an output
  // buffer in memory simultaneously) — without this, if AVFoundation ever
  // hands out startRequest calls faster than compositingQueue drains them,
  // in-flight memory could grow unbounded. wait() happens on the CALLING
  // thread (AVFoundation's own), not inside compositingQueue, so it
  // throttles how fast new work is accepted rather than parking GCD
  // worker threads in a blocked wait.
  private let compositingSemaphore = DispatchSemaphore(
    value: max(2, ProcessInfo.processInfo.activeProcessorCount)
  )

  private var renderContext: AVVideoCompositionRenderContext?
  // Explicit Metal device + no intermediate caching (each frame here is
  // fully independent, nothing benefits from CIContext's default caching)
  // — a bare `CIContext()` CAN silently fall back to the CPU renderer on
  // some code paths (this runs off-main-thread, on AVFoundation's own
  // compositing queue), which is dramatically slower per frame than a
  // GPU-backed context, especially at the 4096px export-resolution cap.
  // .workingFormat: RGBA8 — the actual output buffer this eventually blits
  // into (see blit() below) is already 8-bit BGRA (requiredPixelBuffer-
  // AttributesForRenderContext above), so CoreImage's own default higher-
  // precision (16-bit float) intermediate representation buys no visible
  // quality here, only extra GPU bandwidth/compute per frame that gets
  // truncated away at the final blit regardless.
  private let ciContext: CIContext = {
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBA8])
    }
    return CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBA8])
  }()

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    renderContext = newRenderContext
  }

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    guard
      let instruction = request.videoCompositionInstruction as? MediaEditorVideoInstruction,
      let sourceBuffer = request.sourceFrame(byTrackID: instruction.sourceTrackID),
      let outputBuffer = renderContext?.newPixelBuffer()
    else {
      request.finishCancelledRequest()
      return
    }

    // Everything below is the actual per-frame CPU/GPU work — dispatched
    // onto compositingQueue (see its own doc) so this frame's rendering
    // can overlap with the next frame's, instead of every frame serializing
    // on whatever single thread AVFoundation called startRequest on.
    compositingSemaphore.wait()
    compositingQueue.async {
      defer { self.compositingSemaphore.signal() }
      // Filter/adjustments run on the RAW (still un-rotated, as-decoded)
      // buffer — tonal/color-matrix operations don't care about geometry, so
      // there's no need to rotate before filtering.
      let sourceCIImage = CIImage(cvPixelBuffer: sourceBuffer)
      let filteredCIImage = instruction.filter.apply(
        to: sourceCIImage,
        strength: instruction.filterStrength,
        saturation: instruction.filterSaturation,
        sharpness: instruction.filterSharpness
      )
      let adjustedCIImage = instruction.adjustments.apply(to: filteredCIImage)
      // Only the layers whose time window covers this frame.
      let frameSeconds = CMTimeGetSeconds(request.compositionTime)
      let visibleOverlays = instruction.overlayLayers.filter { $0.isVisible(atSeconds: frameSeconds) }

      let renderedCGImage: CGImage?
      if Self.useGPUCompositing {
        let naturalSize = CGSize(width: CVPixelBufferGetWidth(sourceBuffer), height: CVPixelBufferGetHeight(sourceBuffer))
        let composited = Self.compositeFrameGPU(sourceCI: adjustedCIImage, naturalSize: naturalSize, instruction: instruction, overlays: visibleOverlays, frameSeconds: frameSeconds)
        renderedCGImage = self.ciContext.createCGImage(composited, from: CGRect(origin: .zero, size: instruction.cropRectInExport.size))
      } else {
        guard let filteredCGImage = self.ciContext.createCGImage(adjustedCIImage, from: adjustedCIImage.extent) else {
          request.finishCancelledRequest()
          return
        }
        // Reverted here per the user's explicit "previous change was closer
        // (only mirrored), this one is worse (now flipped top-to-bottom) —
        // revert" report: CIImage.oriented(_:) made things WORSE, not better,
        // so it's ruled out empirically, not just theoretically. Back to the
        // CGContext-based approach that produced CORRECT rotation with only a
        // left-right mirror remaining — closer to correct, and the next fix
        // should build from THIS state, not from .oriented(_:).
        let naturalSize = CGSize(width: CVPixelBufferGetWidth(sourceBuffer), height: CVPixelBufferGetHeight(sourceBuffer))
        let sourceImage = Self.orientationCorrectedImage(from: filteredCGImage, transform: instruction.sourceTransform.inverted(), naturalSize: naturalSize)

        let renderer = UIGraphicsImageRenderer(size: instruction.cropRectInExport.size)
        let rendered = renderer.image { rendererContext in
          let ctx = rendererContext.cgContext
          ctx.translateBy(x: -instruction.cropRectInExport.origin.x, y: -instruction.cropRectInExport.origin.y)

          ctx.saveGState()
          ctx.translateBy(x: instruction.canvasCenterInExport.x, y: instruction.canvasCenterInExport.y)
          ctx.translateBy(x: instruction.translationInExport.x, y: instruction.translationInExport.y)
          ctx.rotate(by: instruction.rotation)
          ctx.scaleBy(x: instruction.scale, y: instruction.scale)
          let imageRect = CGRect(
            x: -sourceImage.size.width / 2,
            y: -sourceImage.size.height / 2,
            width: sourceImage.size.width,
            height: sourceImage.size.height
          )
          sourceImage.draw(in: imageRect)
          ctx.restoreGState()

          // Text/sticker overlays (Day 26b) — drawn in the same crop-offset
          // canvas-export space as the image above, matching renderExport's
          // rule that layers are positioned relative to canvas center,
          // independent of the image/video's own pan/zoom/rotate.
          for overlay in visibleOverlays {
            Self.drawOverlayLayer(overlay, in: ctx)
          }
        }
        renderedCGImage = rendered.cgImage
      }

      guard let renderedCGImage else {
        request.finishCancelledRequest()
        return
      }
      // Was `ciContext.render(CIImage(cgImage: renderedCGImage), to: outputBuffer)`
      // — a SECOND full CoreImage render pass per frame (on top of the
      // createCGImage call above for the filter/adjustments step), which was
      // most of this export's per-frame cost. `renderedCGImage` is already
      // the final, fully-composited pixels (image + overlays) — it just
      // needs to land in outputBuffer, so draw it straight into the pixel
      // buffer's own backing memory instead of round-tripping through
      // CoreImage again. None of the crop/pan/rotate/overlay math above
      // changes — only how the already-finished frame reaches the buffer.
      guard Self.blit(renderedCGImage, into: outputBuffer) else {
        request.finishCancelledRequest()
        return
      }
      request.finish(withComposedVideoFrame: outputBuffer)
    }
  }

  /// Draws `image` directly into `pixelBuffer`'s own backing memory via a
  /// CGContext wrapping its bytes — `image` came from a
  /// UIGraphicsImageRenderer, whose CGContext is already set up in UIKit's
  /// top-left/Y-down convention, but a CGContext created directly from raw
  /// pixel bytes defaults to CoreGraphics' native bottom-left/Y-up
  /// convention — the one-time flip below accounts for exactly that
  /// mismatch for this single blit; it has nothing to do with (and must
  /// not be confused with) the source-orientation fix in startRequest
  /// above.
  private static func blit(_ image: CGImage, into pixelBuffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let ctx = CGContext(
      data: baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return false }
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }

  func cancelAllPendingVideoCompositionRequests() {}

  // ==========================================================================
  // GPU (Core Image) compositing path — replaces the CPU (UIGraphicsImage-
  // Renderer/CGContext) path above for the actual per-frame geometry work,
  // to fix real, user-reported slow exports at 4K (CPU software rasterizing
  // a full 4K frame with rotation/overlays is the dominant per-frame cost).
  // Verified OFF-DEVICE, before ever running on real hardware, by porting
  // both this function AND the CPU path above into a standalone macOS
  // Swift script and comparing their pixel output across every standard
  // AVAssetTrack.preferredTransform case (identity, 90 CW, 90 CCW, 180) and
  // multiple pan/zoom/rotate/crop-origin combinations, including overlays —
  // all matched exactly (a handful of sub-pixel anti-aliasing differences
  // at rotated diagonal edges only, the expected/harmless kind between two
  // different rasterizers, never a wrong position/color). Confirmed fast
  // AND correctly oriented on real device/Metal hardware (2026-09-08,
  // after removing compositeFrameGPU's own extraFlip step, see its git
  // history) — must stay true, do not revert to the CPU path for speed
  // reasons; if a future orientation bug surfaces, fix it in this path.
  private static let useGPUCompositing = true

  private static func flipConjugate(_ t: CGAffineTransform, height: CGFloat) -> CGAffineTransform {
    CGAffineTransform(a: t.a, b: -t.b, c: t.c, d: -t.d, tx: t.tx, ty: height - t.ty)
  }

  /// GPU equivalent of orientationCorrectedImage + the startRequest draw
  /// block + drawOverlayLayer, combined into one CIImage compositing chain.
  /// `sourceCI` is already filtered/adjusted (this only does geometry).
  private static func compositeFrameGPU(sourceCI: CIImage, naturalSize: CGSize, instruction: MediaEditorVideoInstruction, overlays: [MediaEditorVideoOverlayLayer], frameSeconds: Double) -> CIImage {
    // Same "orientation-correction" bbox math as orientationCorrectedImage,
    // in pure UIKit-space matrix terms (no flip yet) — .inverted() to match
    // exactly what the CPU path passes to that function.
    let sourceTransform = instruction.sourceTransform.inverted()
    let corners = [
      CGPoint(x: 0, y: 0), CGPoint(x: naturalSize.width, y: 0),
      CGPoint(x: 0, y: naturalSize.height), CGPoint(x: naturalSize.width, y: naturalSize.height),
    ].map { $0.applying(sourceTransform) }
    let minX = corners.map(\.x).min() ?? 0
    let minY = corners.map(\.y).min() ?? 0
    let maxX = corners.map(\.x).max() ?? naturalSize.width
    let maxY = corners.map(\.y).max() ?? naturalSize.height
    let correctedSize = CGSize(width: maxX - minX, height: maxY - minY)
    let orientT = CGAffineTransform(
      a: sourceTransform.a, b: sourceTransform.b, c: sourceTransform.c, d: sourceTransform.d,
      tx: sourceTransform.tx - minX, ty: sourceTransform.ty - minY
    )

    // REMOVED (mirroring regression, round 3) — this file previously
    // carried an `extraFlip` here, justified as compensating for the CPU
    // path's two UIGraphicsImageRenderer passes being "nested." They are
    // NOT nested: orientationCorrectedImage's renderer.image{} call runs
    // to completion and returns a finished UIImage BEFORE startRequest's
    // own renderer.image{} block even begins — two independent, sequential
    // render passes, not one pushed inside the other. There is no nested-
    // context artifact for this extra flip to be compensating for, and its
    // net effect (composed with a source clip whose own preferredTransform
    // already bakes in a ~90°/270° rotation) turns into exactly the
    // left-right mirror reported after export. Do not re-add it without a
    // concretely reproduced nested-context case to justify it. If a flip
    // is still wrong after this removal, the next suspect is
    // `flipConjugate` itself, not this line — see its own doc.
    // Recenter so the corrected image's own center becomes local origin,
    // matching the CPU path's `imageRect` (-w/2...w/2, -h/2...h/2).
    let recenter = CGAffineTransform(translationX: -correctedSize.width / 2, y: -correctedSize.height / 2)

    let placeTx = instruction.canvasCenterInExport.x + instruction.translationInExport.x - instruction.cropRectInExport.origin.x
    let placeTy = instruction.canvasCenterInExport.y + instruction.translationInExport.y - instruction.cropRectInExport.origin.y
    let placeT = CGAffineTransform(
      a: instruction.scale * cos(instruction.rotation), b: instruction.scale * sin(instruction.rotation),
      c: -instruction.scale * sin(instruction.rotation), d: instruction.scale * cos(instruction.rotation),
      tx: placeTx, ty: placeTy
    )

    // Compose ALL stages first in plain UIKit-space matrix terms, THEN
    // flip-conjugate ONCE at the very end using the FINAL canvas height —
    // flip-conjugating each stage separately and composing those does NOT
    // work (verified: introduces a spurious extra flip), since flips don't
    // commute/cancel across separately-conjugated stages the way you'd
    // expect — only a single conjugation of the fully-composed transform
    // is correct.
    let composedU = orientT.concatenating(recenter).concatenating(placeT)
    let finalHeight = instruction.cropRectInExport.height
    let ciTransform = Self.flipConjugate(composedU, height: finalHeight)

    var result = sourceCI.transformed(by: ciTransform)


    result = applyTransition(result, instruction: instruction, frameSeconds: frameSeconds)

    for overlay in overlays {
      let overlayNaturalSize = CGSize(width: overlay.image.width, height: overlay.image.height)
      guard overlayNaturalSize.width > 0, overlayNaturalSize.height > 0 else { continue }
      // overlay.image is rasterized at device screen scale (2x/3x) — see
      // MediaEditorVideoOverlayLayer.size's own doc — so it must be scaled
      // down to overlay.size (the intended draw size) first, same as the
      // CPU path's `rect` being defined directly in overlay.size units.
      // Text animations: same math as the preview (TextAnimation).
      let anim = overlay.anim.isNone
        ? .identity
        : TextAnimation.state(at: frameSeconds, segments: overlay.visibleRanges ?? [], config: overlay.anim)
      let overlayFit = CGAffineTransform(scaleX: overlay.size.width / overlayNaturalSize.width, y: overlay.size.height / overlayNaturalSize.height)
      let overlayRecenter = CGAffineTransform(translationX: -overlay.size.width / 2, y: -overlay.size.height / 2)
      let overlayTx = overlay.centerInExport.x - instruction.cropRectInExport.origin.x + anim.offsetX * instruction.cropRectInExport.width
      // centerInExport.y is already mirrored (see exportVideo), so "down
      // on screen" is a smaller value here.
      let overlayTy = overlay.centerInExport.y - instruction.cropRectInExport.origin.y - anim.offsetY * finalHeight
      let animatedScale = overlay.scale * anim.scale
      let animatedRotation = overlay.rotation + anim.rotation
      let overlayPlaceT = CGAffineTransform(
        a: animatedScale * cos(animatedRotation), b: animatedScale * sin(animatedRotation),
        c: -animatedScale * sin(animatedRotation), d: animatedScale * cos(animatedRotation),
        tx: overlayTx, ty: overlayTy
      )
      // No extraFlip here — overlays are drawn via a single, non-nested
      // raw ctx.draw on the CPU side (drawOverlayLayer), not a second
      // nested UIGraphicsImageRenderer pass, so they don't carry the same
      // artifact the main video's orientation-correction stage does.
      let overlayComposedU = overlayFit.concatenating(overlayRecenter).concatenating(overlayPlaceT)
      let overlayCITransform = Self.flipConjugate(overlayComposedU, height: finalHeight)
      var overlayImage = CIImage(cgImage: overlay.image)
      if anim.reveal < 1 {
        // Typewriter: only the left part of the text.
        overlayImage = overlayImage.cropped(to: CGRect(x: 0, y: 0, width: overlayNaturalSize.width * anim.reveal, height: overlayNaturalSize.height))
      }
      var positionedOverlay = overlayImage.transformed(by: overlayCITransform)
      if anim.alpha < 1 {
        let a = anim.alpha
        positionedOverlay = positionedOverlay.applyingFilter("CIColorMatrix", parameters: [
          "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
        ])
      }
      result = positionedOverlay.composited(over: result)
    }

    return result
  }

  /// Transitions (roadmap row 33): over the first / last
  /// `transitionDuration` of the instruction, fade / slide / zoom the video
  /// frame (stickers and text, drawn after this, are untouched). No
  /// overlap between clips, so the timeline length never changes.
  private static func applyTransition(_ image: CIImage, instruction: MediaEditorVideoInstruction, frameSeconds: Double) -> CIImage {
    let d = MediaEditorVideoInstruction.transitionDuration
    let start = CMTimeGetSeconds(instruction.timeRange.start)
    let end = start + CMTimeGetSeconds(instruction.timeRange.duration)
    var type = 0
    var amount: CGFloat = 0
    var incoming = false
    if instruction.transitionIn != 0, frameSeconds < start + d {
      type = instruction.transitionIn
      amount = CGFloat(1 - max(0, frameSeconds - start) / d)
      incoming = true
    } else if instruction.transitionOut != 0, frameSeconds > end - d {
      type = instruction.transitionOut
      amount = CGFloat(1 - max(0, end - frameSeconds) / d)
    }
    amount = min(max(amount, 0), 1)
    guard type != 0, amount > 0 else { return image }
    let size = instruction.cropRectInExport.size
    let outRect = CGRect(origin: .zero, size: size)
    var result = image
    var fade = 1 - amount
    switch type {
    case 2:
      // Slide: the outgoing clip leaves to the left, the next comes from the right.
      let dx = amount * size.width * (incoming ? 1 : -1)
      result = result.transformed(by: CGAffineTransform(translationX: dx, y: 0))
      fade = 1
    case 3:
      // Zoom: push in while fading.
      let s = 1 + 0.25 * amount
      let t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
        .scaledBy(x: s, y: s)
        .translatedBy(x: -size.width / 2, y: -size.height / 2)
      result = result.transformed(by: t)
    default:
      break
    }
    if fade < 1 {
      result = result.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: fade, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: fade, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: fade, w: 0),
      ])
    }
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: outRect)
    return result.cropped(to: outRect).composited(over: black)
  }

  /// Renders `cgImage` (still in its raw, un-rotated storage orientation,
  /// `naturalSize` in size) through `transform`, applied EXACTLY as given —
  /// no inversion, no coordinate-space conversion, no semantic re-encoding
  /// as an orientation enum — via a CGContext in UIKit's own Y-down
  /// convention, the SAME convention `transform` (AVAssetTrack.
  /// preferredTransform) was authored for. Re-normalizes the result to
  /// start at (0, 0) by transforming the four corners and translating by
  /// the minimum, so this works uniformly for any rotation (not just the
  /// 4 standard cases) with no per-case logic to get backwards.
  private static func orientationCorrectedImage(from cgImage: CGImage, transform: CGAffineTransform, naturalSize: CGSize) -> UIImage {
    // Deliberately NOT bailing out early for `transform.isIdentity` (a
    // prior version of this guard did) — an identity transform still
    // needs to go through the ctx.draw pipeline below, not straight
    // `UIImage(cgImage:).draw(in:)` back in startRequest, per gotcha 20:
    // that draw call composes incorrectly (produces a flipped result)
    // once it runs inside a context that already has other transforms
    // concatenated onto it (translate/rotate/scale for pan-zoom), which
    // is exactly what happens next in startRequest regardless of this
    // clip's own source transform. Every rotated-transform clip already
    // avoided that pitfall by being re-rendered here first; only the
    // identity case skipped it — reproduced as an identity-transform clip
    // (1080x1920, a=1 b=0 c=0 d=1) exporting with its video content
    // upside-down while overlays (drawn via their own already-corrected
    // raw ctx.draw, see drawOverlayLayer) stayed correct. For an identity
    // transform this is geometrically a no-op (corners map to themselves,
    // translate is (0,0), concatenate is a no-op) — it just forces the
    // same normalizing re-render every other transform value already gets.
    guard naturalSize.width > 0, naturalSize.height > 0 else {
      return UIImage(cgImage: cgImage)
    }
    let corners = [
      CGPoint(x: 0, y: 0), CGPoint(x: naturalSize.width, y: 0),
      CGPoint(x: 0, y: naturalSize.height), CGPoint(x: naturalSize.width, y: naturalSize.height),
    ].map { $0.applying(transform) }
    let minX = corners.map(\.x).min() ?? 0
    let minY = corners.map(\.y).min() ?? 0
    let maxX = corners.map(\.x).max() ?? naturalSize.width
    let maxY = corners.map(\.y).max() ?? naturalSize.height
    let outputSize = CGSize(width: maxX - minX, height: maxY - minY)
    guard outputSize.width > 0, outputSize.height > 0 else {
      return UIImage(cgImage: cgImage)
    }
    let renderer = UIGraphicsImageRenderer(size: outputSize)
    return renderer.image { rendererContext in
      let ctx = rendererContext.cgContext
      ctx.translateBy(x: -minX, y: -minY)
      ctx.concatenate(transform)
      // NO extra bottom-up flip here (a prior attempt added one, reasoning
      // that raw CGImage data is natively bottom-up) — that flip is what
      // caused the "correctly rotated but left-right mirrored" on-device
      // result: flipping an image THEN rotating it 90° is provably the
      // mirror image of just rotating it 90° directly (verified by
      // tracing where each corner ends up under both orderings), and the
      // rotation alone (via `transform` above) was already independently
      // confirmed correct on-device. UIGraphicsImageRenderer's own context
      // is ALREADY in the right convention for `ctx.draw` per this file's
      // own top-of-file doc — unlike blit() below, which flips because
      // ITS context is a raw pixel-buffer-backed one with no such built-in
      // handling. Adding a flip here was solving a problem that didn't
      // exist in this context, at the cost of introducing a real one.
      ctx.draw(cgImage, in: CGRect(origin: .zero, size: naturalSize))
    }
  }

  /// Draws one pre-rendered overlay image, matching
  /// MediaEditorViewController.drawLayerForExport's transform order exactly
  /// (translate to center, rotate, scale, draw centered) but against an
  /// already-rasterized CGImage instead of a live UILabel, since this runs
  /// on AVFoundation's background compositing queue.
  private static func drawOverlayLayer(_ overlay: MediaEditorVideoOverlayLayer, in ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: overlay.centerInExport.x, y: overlay.centerInExport.y)
    ctx.rotate(by: overlay.rotation)
    ctx.scaleBy(x: overlay.scale, y: overlay.scale)
    // overlay.size, NOT image.width/image.height — see
    // MediaEditorVideoOverlayLayer.size's own doc for why those pixel
    // dimensions (screen-scale-inflated) are the wrong unit here.
    let rect = CGRect(x: -overlay.size.width / 2, y: -overlay.size.height / 2, width: overlay.size.width, height: overlay.size.height)
    // Raw ctx.draw, NOT UIImage(cgImage:).draw(in:) — per this file's own
    // orientationCorrectedImage fix right above: UIImage's drawing applies
    // its own internal flip handling that doesn't compose correctly once
    // translate/rotate/scale are already on the context, producing an
    // upside-down result — text, stickers, and draw strokes ALL went
    // through this exact function and were ALL affected identically,
    // regardless of each layer's own `overlay.rotation` value (this bug
    // predates and is independent of the video-content orientation fix;
    // it was simply invisible while the whole frame was also upside-down).
    ctx.draw(overlay.image, in: rect)
    ctx.restoreGState()
  }
}
