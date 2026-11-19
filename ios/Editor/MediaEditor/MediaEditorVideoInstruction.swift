import AVFoundation
import CoreGraphics

/// One pre-rendered text/sticker layer, positioned in the same canvas-
/// export space as cropRectInExport (i.e. relative to the frame BEFORE the
/// crop-origin offset is subtracted, matching drawLayerForExport's
/// centerInExport for images). `image` is rendered ONCE on the main thread
/// before export starts (Day 26b) — MediaEditorVideoCompositor.startRequest
/// runs on an AVFoundation-internal background queue, where touching a live
/// UILabel/CALayer would be unsafe, so there is nothing UIKit-live left for
/// the compositor to touch per frame, only this already-rasterized image.
struct MediaEditorVideoOverlayLayer {
  let image: CGImage
  // The layer's intended draw size in export-scaled points — NOT the same
  // as image.width/image.height. `image` was rasterized via
  // UIGraphicsImageRenderer, which renders at the device's screen scale
  // (2x/3x) by default, so its CGImage's raw pixel dimensions are 2-3x
  // LARGER than this. Reconstructing draw size from image.width/height
  // (as this used to) drew every overlay 2-3x too big — per the user's
  // explicit "exported video looks completely different, text/stickers
  // look inverted" report: text especially, being small and dense
  // (particularly complex scripts), rendered oversized and overlapping
  // into an illegible mess; a simple round sticker just looked a bit big,
  // easy to mistake for "fine." This field carries the correct intended
  // size explicitly instead of ever re-deriving it from pixel data.
  let size: CGSize
  let centerInExport: CGPoint
  let rotation: CGFloat
  let scale: CGFloat
  /// When this layer is on screen, in composition seconds (the editor's
  /// combined timeline: kept primary segments back-to-back, then merged
  /// clips). nil = the whole video (drawing strokes).
  var visibleRanges: [ClosedRange<Double>]? = nil
  /// Text animation (see TextAnimation).
  var anim = TextAnimConfig.none

  func isVisible(atSeconds t: Double) -> Bool {
    guard let visibleRanges else { return true }
    // Small tolerance so a frame landing exactly on an edge still counts.
    return visibleRanges.contains { t >= $0.lowerBound - 0.001 && t <= $0.upperBound + 0.001 }
  }
}

/// Carries this export's crop/transform/filter parameters through to
/// MediaEditorVideoCompositor.startRequest. AVFoundation instantiates the
/// compositor itself (customVideoCompositorClass) with no init arguments,
/// so a custom AVVideoCompositionInstructionProtocol is the only way to
/// hand it per-export parameters — the compositor reads them back via
/// `request.videoCompositionInstruction as? MediaEditorVideoInstruction`.
final class MediaEditorVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol {
  let timeRange: CMTimeRange
  let enablePostProcessing = false
  let containsTweening = false
  let requiredSourceTrackIDs: [NSValue]?
  let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

  let sourceTrackID: CMPersistentTrackID

  // The source track's own rotation/mirroring metadata (e.g. a portrait
  // clip stored as landscape sensor data + a 90° flag). A custom
  // AVVideoCompositing class — unlike the default one AVPlayer/normal
  // AVAssetExportSession use — receives RAW, un-rotated pixel buffers;
  // nothing applies this automatically, so MediaEditorVideoCompositor
  // must apply it itself before compositing, or the exported frame comes
  // out sideways with the wrong aspect (looks like "rotated + half black"
  // — the un-rotated source doesn't fill the orientation-corrected
  // renderSize/cropRectInExport this instruction was computed against).
  let sourceTransform: CGAffineTransform

  // Already expressed in "export-scaled" units — the same units
  // MediaEditorViewController.renderExport computes via exportScale — so
  // the compositor's per-frame math is a direct port of renderExport's,
  // just applied per video frame instead of once for a still image.
  let cropRectInExport: CGRect
  let canvasCenterInExport: CGPoint
  let translationInExport: CGPoint
  let rotation: CGFloat
  let scale: CGFloat
  let filter: PhotoFilter
  /// 0...1 — see PhotoFilter.apply(to:strength:).
  let filterStrength: Float
  /// Filters-panel Saturation (-1...1) / Sharpness (0...1).
  let filterSaturation: Float
  let filterSharpness: Float
  let adjustments: PhotoAdjustments
  let overlayLayers: [MediaEditorVideoOverlayLayer]
  /// Transitions (roadmap row 33): 0 none, 1 fade, 2 slide, 3 zoom — at
  /// this instruction's start (into the clip) and end (out of it).
  var transitionIn = 0
  var transitionOut = 0
  static let transitionDuration: Double = 0.4

  init(
    timeRange: CMTimeRange,
    sourceTrackID: CMPersistentTrackID,
    sourceTransform: CGAffineTransform,
    cropRectInExport: CGRect,
    canvasCenterInExport: CGPoint,
    translationInExport: CGPoint,
    rotation: CGFloat,
    scale: CGFloat,
    filter: PhotoFilter,
    filterStrength: Float = 1,
    filterSaturation: Float = 0,
    filterSharpness: Float = 0,
    adjustments: PhotoAdjustments,
    overlayLayers: [MediaEditorVideoOverlayLayer]
  ) {
    self.timeRange = timeRange
    self.sourceTrackID = sourceTrackID
    self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
    self.sourceTransform = sourceTransform
    self.cropRectInExport = cropRectInExport
    self.canvasCenterInExport = canvasCenterInExport
    self.translationInExport = translationInExport
    self.rotation = rotation
    self.scale = scale
    self.filter = filter
    self.filterStrength = filterStrength
    self.filterSaturation = filterSaturation
    self.filterSharpness = filterSharpness
    self.adjustments = adjustments
    self.overlayLayers = overlayLayers
  }
}
