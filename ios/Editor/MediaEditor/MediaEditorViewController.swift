import UIKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import CoreLocation
import MapKit

/// Milestone 1 proved the open/cancel/done round trip with a blank screen.
/// Milestone 2 replaced that with a real image editor (canvas, crop,
/// transform, text/stickers, filters/adjustments, export). Milestone 3
/// (this file's video branch) is starting with playback.
final class MediaEditorViewController: UIViewController {
  /// Story mode: gap between the status bar and the floating X / Undo /
  /// Redo / Share row (was 8 — sat too close to the status bar).
  static let storyTopGap: CGFloat = 24

  private let sourceURL: URL
  private let mediaType: String
  /// True when opened from the Story camera flow — swaps in the full
  /// Instagram-style story chrome (see setUpStoryModeChrome), including
  /// the primary button's label ("Share") and top-right position.
  private let isStoryMode: Bool
  private let onCancel: () -> Void
  private let onDone: (MediaEditorDoneOutcome) -> Void

  private let imageView = UIImageView()
  /// Never-TRANSFORMED (`.transform` always stays `.identity`) parent of
  /// imageView/playerView — `clipsToBounds = true` hard-clips a zoomed/
  /// panned/rotated photo or video to the canvas box's own screen rect,
  /// per the user's explicit "zoomed image should not display outside of
  /// that cropper box" report. See its setup in viewDidLoad for why this
  /// must be a SEPARATE ancestor rather than clipsToBounds directly on
  /// imageView/playerView. Its own SIZE, unlike its transform, is no
  /// longer fixed — see [updateCanvasSizeForLayers]. Deliberately resized
  /// via REAL Auto Layout constraint swaps, not a CGAffineTransform scale
  /// — `.frame` is documented as undefined once `.transform` isn't
  /// `.identity`, and this view's own `.frame` is read directly elsewhere
  /// (e.g. a layer's `boundsProvider`, export math) and must stay
  /// meaningful at all times.
  private let canvasClipContainerView = UIView()
  // Defines the dedicated content area (image editor only) that
  // imageContentAreaGuide's own children — the video-controls band
  // (filmstripScrollView/videoControlsBackdropView) — sit within; the
  // CANVAS itself no longer sizes against this guide directly, see
  // canvasContentAreaGuide below.
  private let imageContentAreaGuide = UILayoutGuide()
  /// What the canvas ACTUALLY sizes/centers against — narrower than
  /// [imageContentAreaGuide] by the video-controls band's own height
  /// (video only; image reuses imageContentAreaGuide's exact bottom).
  /// Per the user's explicit "video editor and layers portion to be
  /// completely separate... video should be always above that section,
  /// not below these editor tools" request — the video-controls band
  /// (filmstripScrollView, playPauseButton, Split/Delete, the layer-
  /// tracks panel) used to float as an overlay directly on
  /// canvasClipContainerView's own bottom edge (see git history), which
  /// both let the video visually extend UNDER those controls AND made
  /// the whole band move around whenever the canvas resized (see
  /// updateCanvasSizeForLayers). Now the band is pinned to a FIXED point
  /// (imageContentAreaGuide.bottomAnchor — see filmstripScrollView's own
  /// constraint in viewDidLoad) and the canvas is sized to fit entirely
  /// ABOVE it instead.
  private let canvasContentAreaGuide = UILayoutGuide()
  private var imageAspectConstraint: NSLayoutConstraint?
  /// The 2 "fit as large as possible" constraints (see viewDidLoad) —
  /// always active now. Used to be swapped out for a SEPARATE, extra-
  /// shrunk pair (canvasShrinkFactorForLayers, a fixed 0.72 multiplier)
  /// whenever any layer existed, back when canvasContentAreaGuide's own
  /// bottom reservation was a fixed constant that didn't know about the
  /// layer-tracks panel's real height — that multiplier was an
  /// approximation standing in for real dynamic reservation (see its own
  /// removed doc: "a fixed proportional shrink is a much lower-risk way
  /// to approximate the same visual effect here [than Android's exact
  /// pixel reservation]"). Now that canvasContentAreaGuide.bottomAnchor is
  /// pinned to layersAreaCollapseButton's own dynamic top (see that
  /// constraint's doc), the guide itself already shrinks by exactly the
  /// tracks panel's real height — keeping the OLD extra 0.72 multiplier
  /// on top of that was double-shrinking the canvas, per the user's
  /// explicit "still above and below there is more space available"
  /// report. Removed entirely; matches Android, which never had an
  /// equivalent extra-shrink constant in the first place.
  private var canvasFullSizeConstraints: [NSLayoutConstraint] = []

  /// Static center crosshair over the canvas (1 vertical + 1 horizontal
  /// line) — purely a visual aid so the user can see the image's own
  /// center while placing text/stickers, per the user's explicit request.
  /// Non-interactive; sized/positioned once to match the canvas box
  /// exactly and never touched again, consistent with this file's
  /// "canvas box sized once, geometrically stable" rule elsewhere.
  private let gridOverlayView = UIView()

  /// Opaque bars covering the status-bar area (above the top bar) and the
  /// home-indicator area (below the bottom tray) — added LAST (and re-
  /// fronted after every later layer addition, see keepSafeAreaCoversOnTop)
  /// so nothing (a dragged text/sticker layer, or the image itself) can
  /// ever visually show through those two edge strips, per the user's
  /// explicit request.
  private let topSafeAreaCoverView = UIView()
  private let bottomSafeAreaCoverView = UIView()

  /// Opaque bars filling the 4 "gutter" strips between imageContentAreaGuide
  /// and the canvas box (imageView/playerView) itself — i.e. the letterbox
  /// margin left over when the media's own aspect ratio doesn't exactly
  /// match the guide's. Re-fronted alongside the safe-area covers (same
  /// keepSafeAreaCoversOnTop call) so a dragged/pinched overlay image can
  /// never visually spill outside the crop box, per the user's explicit
  /// "overlay image should render into the cropping box, not outside of
  /// it" request. Purely visual (not referenced by export, same as the
  /// grid/border) — sized entirely via Auto Layout relative to imageView
  /// vs. the guide, deliberately avoiding a manual CAShapeLayer mask +
  /// frame-conversion, the same category of coordinate-space mixup already
  /// found and fixed elsewhere in this file (canvasCenter's `.center`-vs-
  /// local-bounds bug).
  private let canvasGutterViews = (top: UIView(), bottom: UIView(), left: UIView(), right: UIView())
  private let loadingIndicator = UIActivityIndicatorView(style: .large)
  private let doneButton = UIButton(type: .system)
  // Guards against tapping Done again while an export is already running —
  // without this, repeated taps (e.g. while waiting on a slow export with
  // no visible progress) stack up multiple concurrent exports competing
  // for the same CPU, each taking even longer.
  private var isExporting = false
  // Export progress overlay (per the user's explicit "show progress UI,
  // don't let the user close/lock during export" request) — the session
  // reference exists solely so the overlay's cancel button can actually
  // call `.cancelExport()` on it (it's created deep inside exportVideo's
  // own async Task, well after the overlay is already shown), and the
  // timer polls `.progress` since AVAssetExportSession predates any
  // documented KVO/async-stream API for it at this project's iOS 15.1
  // deployment target.
  private var exportProgressView: ExportProgressView?
  private weak var currentExportSession: AVAssetExportSession?
  private var exportProgressTimer: Timer?
  private var exportWasCancelled = false

  // Video (Milestone 3). A fresh, dedicated AVPlayer per editor session —
  // deliberately not routed through the app's IAVideoPlayerStore singleton,
  // which solves keeping ONE player alive across mount/unmount for the
  // feed's inline↔fullscreen↔PiP handoffs. The editor is a single
  // full-screen session with its own trim/seek controls; there's no handoff
  // to design for, so a dedicated player is simpler and has no shared state
  // with feed playback.
  private let playerView = VideoPlayerContainerView()
  private var player: AVPlayer?
  private let playPauseButton = UIButton(type: .system)
  private let videoTrimView = VideoTrimView()
  /// Translucent scrim behind the play/pause + trim scrubber (+ Split/
  /// Delete) row — per the user's explicit "display these layer above
  /// video layer" request, the video canvas is now full-size (see
  /// reservedBottomChromeHeight in viewDidLoad, which no longer reserves
  /// a separate row for these controls) and this whole control cluster
  /// floats as an overlay on top of the video's own bottom edge instead
  /// of sitting in dedicated space below it. Sibling of the buttons, added
  /// just beneath them in z-order, so it darkens the video behind the
  /// controls without intercepting their touches.
  private let videoControlsBackdropView = UIView()
  /// Per-layer (text/sticker/overlay) time-range + z-order rows — per the
  /// user's explicit "as we are getting these both layers in a separate
  /// Layers tab... display these both layers on screen" correction, these
  /// no longer live behind their own tab (there is no more `.layers` tab
  /// or SlideUpPanelView for it): they're stacked directly above the
  /// Split/Delete + trim scrubber row, always visible on the Tools tab,
  /// matching the reference multi-track timeline where every layer's own
  /// track sits above the base video track in the same view. Rebuilt from
  /// scratch on every add/delete/reorder/timing change — see
  /// refreshLayersPanel's own doc for why that's simpler than incremental
  /// row diffing here.
  private let layerTracksStack = UIStackView()
  /// Layer row → its canvas layer view (rebuilt in refreshLayersPanel).
  private var layerTrackRowOwners: [ObjectIdentifier: UIView] = [:]
  /// Order before the current track-reorder drag (see commitLayerReorderUndo).
  private var pendingLayerReorderUndo: LayerOrderSnapshot?
  /// "+ Layer" — opens the Add layer sheet (video, non-story).
  private let addLayerButton = UIButton(type: .system)
  // Hide / lock for the selected text/sticker/photo layer — shown in the
  // play/split/delete row (in place of the selection label) while a
  // layer is selected.
  private let layerHideButton = UIButton(type: .system)
  private let layerLockButton = UIButton(type: .system)
  // Clip management (roadmap row 29): shown in the same slot while a clip
  // (a segment of the main video or of a merged clip) is selected.
  private let clipVolumeButton = UIButton(type: .system)
  /// Per-clip volume (0…1, default 1), multiplied with the original-audio
  /// slider — preview and export. Key = the clip's URL (sourceURL = main).
  private var clipVolumes: [URL: Float] = [:]
  /// Speed control (roadmap row 28): per PART of a clip, like CapCut /
  /// Edits — split a clip and each part gets its own speed. Stored per clip
  /// as source-time spans; a part plays at the newest span covering its
  /// middle (default 1x), so both halves of a split keep the part's speed
  /// and split / delete / trim / undo need no bookkeeping here.
  private struct SpeedSpan {
    let range: ClosedRange<Double>
    let speed: Double
  }
  private var speedSpans: [URL: [SpeedSpan]] = [:]
  /// Fade in/out audio (video editor): 1s ramps on the music (where it
  /// starts / ends) and the clip's own sound (video start / end).
  private var audioFadeIn = false
  // Voice-over (one narration track, recorded from the playhead).
  private var voiceOverURL: URL?
  /// Editor-made temp files (voice recordings, downloaded music) — deleted
  /// when the editor closes; the exported file itself is never listed.
  private var tempFilesToDelete: [URL] = []
  // Beat sync: beats of the chosen song (song time, seconds) and the
  // "Snap cuts to beat" switch.
  private var musicBeats: [Double] = []
  private var beatSnapEnabled = false
  private weak var beatSyncNoteLabel: UILabel?
  private var skipNextBeatSnap = false
  /// Where it starts on the combined timeline, and its length (seconds).
  private var voiceOverStart: Double = 0
  private var voiceOverDuration: Double = 0
  private var voicePlayer: AVAudioPlayer?
  private let voiceProxyToken = NSObject()
  private var isVoiceRowSelected = false {
    didSet { if !isVoiceRowSelected { voiceRangeBar?.setSelection(id: nil, segmentIndex: nil) } }
  }
  /// The voice-over track's bar — its body drags only while selected.
  private weak var voiceRangeBar: LayerRangeBarView?
  /// Original sound / music level while the voice-over plays (ducking).
  private static let voiceDuckLevel: Float = 0.3
  private var voiceRecorder: AVAudioRecorder?
  private var voiceRecorderPanel: UIView?
  private weak var voiceRecorderTimeLabel: UILabel?
  private weak var voiceRecordButton: UIButton?
  private var voiceRecordingStart: Double = 0
  private var voiceRecordingURL: URL?
  private var voiceRecordingTimer: Timer?
  private var audioSessionBeforeRecording: (AVAudioSession.Category, AVAudioSession.Mode)?
  private var audioFadeOut = false
  private static let audioFadeSeconds: Double = 1
  private let clipSpeedButton = UIButton(type: .system)
  /// Transitions (roadmap row 33): the transition INTO a merged clip from
  /// the clip before it (1 fade, 2 slide, 3 zoom). Keyed by the clip, so
  /// it moves with it when clips are reordered.
  private var transitionsIn: [URL: Int] = [:]
  private let clipTransitionButton = UIButton(type: .system)
  /// Text animations: shown in compare's spot while a text layer is selected.
  private let textAnimationButton = UIButton(type: .system)
  private var speedSheet: UIView?
  private weak var speedValueLabel: UILabel?
  private weak var speedDurationLabel: UILabel?
  private var clipVolumePanel: UIView?
  private weak var clipVolumeSlider: UISlider?
  private weak var clipVolumeValueLabel: UILabel?
  private var clipVolumeEditURL: URL?
  private var clipVolumeBeforeDrag: Float = 1
  private var addLayerSheetView: UIView?
  /// Caps how tall the stack can grow before scrolling (a handful of
  /// layers) — same "as large as possible up to a hard cap" priority
  /// trick as canvasClipContainerView's own sizing, so 0 layers collapses
  /// to 0 height (no empty gap) and many layers scroll instead of pushing
  /// the video controls off-screen.
  private let layerTracksScrollView = UIScrollView()
  /// Forces layerTracksScrollView to 0 height regardless of row count —
  /// activated while collapsed, deactivated (letting the fit/cap
  /// constraints in viewDidLoad take over) while expanded. See
  /// updateLayersAreaExpansion's own doc for the full collapse/expand
  /// design.
  private var layerTracksCollapsedConstraint: NSLayoutConstraint?
  /// 20 while any layer exists (whether expanded or collapsed — the
  /// chevron itself must stay tappable to re-expand), 0 when there are
  /// none at all, so an all-video session with no text/sticker/overlay
  /// layers costs zero extra scrim height for a control that would never
  /// be shown. Mutated directly (not swapped between two constraints)
  /// since it's a plain constant, not a competing priority.
  private var layersAreaCollapseButtonHeightConstraint: NSLayoutConstraint?
  /// Per the user's explicit "if layers are active these video preview
  /// goes smaller... and if we minimise with a drop-down icon then video
  /// displays full screen" request. Deliberately does NOT resize the
  /// canvas itself (canvasClipContainerView stays exactly where it is,
  /// full-size, at a fixed center — see its own doc for why moving it
  /// would desync text/sticker layer positions from the export math).
  /// Instead this toggles videoControlsBackdropView between a small
  /// translucent scrim (collapsed — today's floating-over-video look) and
  /// a tall OPAQUE panel that visually reads as a dedicated area below
  /// the video, even though it's still the same overlay z-order
  /// mechanism. Defaults to expanded (false) so the very first layer
  /// added auto-expands; see registerLayerTiming for the "first layer"
  /// reset.
  private var isLayersAreaCollapsed = false
  private let layersAreaCollapseButton = UIButton(type: .system)
  // Split cuts the segment under the current playhead into two; Delete
  // removes whichever segment the playhead currently sits in (guarded
  // against deleting the last remaining one) — per the user's explicit
  // "split video into multiple parts and delete any of them" request.
  private let splitSegmentButton = UIButton(type: .system)
  private let deleteSegmentButton = UIButton(type: .system)
  // Ordered, non-overlapping, ascending KEPT ranges of the original video
  // — replaces a single trimStart/trimEnd pair per the user's explicit
  // "split into parts, delete any of them" request. Always at least one
  // element once duration is known (see setUpVideoPlayer).
  private var videoSegments: [ClosedRange<Double>] = []
  // Extra videos the user picked to APPEND after the primary clip, in the
  // order added, per the user's explicit "doesn't matter how many video,
  // all video clips will be added to same video layer and will be played
  // in queue, same like Instagram" request. Each plays in FULL (no split/
  // trim/pan/zoom/filter/adjustments/text overlays of its own — those stay
  // primary-clip-only) — see setUpVideoPlayer's own doc for how the queued
  // live preview works, and exportVideo's for how they're joined into one
  // output file. Empty means no merge is pending.
  private var additionalVideoClipURLs: [URL] = []
  private var queuePlayer: AVQueuePlayer? { player as? AVQueuePlayer }
  // Tracks WHICH AVPlayerItem is the primary clip, distinct from whatever
  // AVQueuePlayer.currentItem happens to be — used to gate the trim
  // scrubber/gap-skip/Split/Delete logic (all primary-clip-only) and to
  // detect when playback has advanced into a merged clip.
  private weak var primaryPlayerItem: AVPlayerItem?
  // Evenly time-sampled frames across each clip's OWN full real duration
  // (same tileCount/sampling formula as VideoTrimView.loadThumbnails) —
  // replaces a single frame-at-0 that used to get stretched/cropped
  // across a merged clip's entire (often much wider, and after a split,
  // per-segment) bar, per the user's explicit "video thumbnail should
  // not look zoomed... only show thumbnail up to exact same real timing
  // of video clip" report: a single far-off-aspect frame center-cropped
  // to fill a wide/narrow bar reads as an extreme, meaningless zoom, and
  // never actually reflected which real moment of the clip a given part
  // of the bar represents.
  private var additionalClipThumbnailTiles: [URL: [Int: UIImage]] = [:]
  private let mergedClipThumbnailTileCount = 8
  // Each clip's own real (untrimmed) duration, loaded async once per clip
  // — needed synchronously by refreshMergedClipsStrip's anchor math, so
  // it's cached here rather than re-derived on demand.
  private var additionalClipDurations: [URL: Double] = [:]
  // Per-merged-clip KEPT segments (each start...end in that clip's OWN
  // local time, ordered/non-overlapping/ascending) — missing entry means
  // "not yet trimmed/split, use the full clip", per the user's explicit
  // "I want to adjust, trim... like Instagram" follow-up, later extended
  // to full multi-segment split/delete parity with the primary clip (per
  // the user's explicit "split/delete should work on merged clips too"
  // request) — mirrors `videoSegments`'s own model exactly, just keyed
  // per clip instead of there being only one. Set via mergedStripView's
  // onRangeChanged (dragging directly on the seamless filmstrip row —
  // see refreshMergedClipsStrip's own doc) and by
  // splitMergedClipSegment/deleteMergedClipSegment; read by
  // makeAdditionalPlayerItem (live preview) and exportVideo (final
  // output), both of which insert every kept segment consecutively into
  // one composition track — same "multiple insertTimeRange calls"
  // technique the primary clip's own segments already use, which is
  // exactly why a merged clip needs NO runtime gap-skip logic of its own:
  // its gaps are physically excised from the composition before playback
  // ever starts.
  private var additionalClipSegments: [URL: [ClosedRange<Double>]] = [:]
  // One stable, never-displayed UIView per clip — see proxyView(for:)'s
  // own doc for why this exists.
  private var additionalClipProxyViews: [URL: UIView] = [:]
  // Per-clip anchor (sum of KEPT — not full — durations of clips before
  // it) as of the last refreshMergedClipsStrip() call — recomputed there,
  // read by mergedStripView's onRangeChanged closure (set up once in
  // viewDidLoad, so unlike the old makeAdditionalClipsRow it can't just
  // capture a local var at creation time). Using kept (not full) duration
  // is what makes clips pack back-to-back with zero gap — an earlier
  // version anchored on full duration, which left a permanent gap sized
  // to whatever had been trimmed off the PRECEDING clip, straight
  // contradicting the "single continuous filmstrip" goal.
  // One anchor per KEPT SEGMENT now (was one per clip, back when a clip
  // only ever had a single kept span) — segmentAnchors[url]![i] is
  // segment i's own fixed slot start as of the last refresh.
  private var mergedClipSegmentAnchors: [URL: [Double]] = [:]
  // The exact segments array each clip's anchors/items were built from —
  // captured once per refreshMergedClipsStrip() call so onRangeChanged's
  // repeated per-tick delta math (see its own doc) has a STABLE reference
  // to add deltas to, rather than the live, already-mutating
  // additionalClipSegments dict (which would double-count/drift across
  // ticks within the same drag). Also doubles as the clamp bound that
  // keeps one segment's edge-drag from crossing into an adjacent
  // segment's own space within the same clip.
  private var mergedClipReferenceSegments: [URL: [ClosedRange<Double>]] = [:]
  // Which merged-clip segment (if any) the user last TAPPED — the Delete
  // button's target when the active clip (not a layer) is what's
  // selected, mirroring videoTrimView.selectedSegmentIndex/
  // selectedLayerSegmentIndex's identical role for the other two "what
  // should Delete act on" contexts.
  private var selectedMergedClipURL: URL?
  private var selectedMergedClipSegmentIndex: Int?
  // Merged clips render as a direct, zero-gap continuation of
  // videoTrimView's own filmstrip (one seamless strip, per the user's
  // explicit "true single continuous filmstrip" choice) rather than a
  // separate row in the Layers panel — see refreshMergedClipsStrip's own
  // doc. A single persistent instance, unlike the old makeAdditionalClipsRow
  // (which rebuilt a brand-new LayerRangeBarView every call) — reusing one
  // instance means an in-progress drag's own gesture is never at risk from
  // a mid-gesture rebuild.
  private let mergedStripView = LayerRangeBarView()
  // Recreated (not just mutated) each time relevant durations change,
  // since a constraint's constant needs the width in POINTS, computed
  // fresh from timelinePointsPerSecond — see updateFilmstripLayout.
  private var videoTrimViewWidthConstraint: NSLayoutConstraint?
  private var mergedStripViewWidthConstraint: NSLayoutConstraint?
  // Matches the SAME total combined width as videoTrimView+mergedStripView
  // together (not just whatever the widest individual row happens to
  // need) — this is what lets layerTracksScrollView's own contentOffset.x
  // range exactly match filmstripScrollView's, so the horizontal-scroll
  // mirror between them (see the scroll delegate) never clamps early.
  private var layerTracksStackWidthConstraint: NSLayoutConstraint?
  // Reentrancy guard for the two-way scroll mirror between
  // filmstripScrollView and layerTracksScrollView (see scrollViewDidScroll).
  private var isSyncingFilmstripAndLayerTracksScroll = false
  // Guards the ONE-TIME contentOffset correction in
  // updateFilmstripContentInsetIfNeeded — a UIScrollView does NOT
  // automatically reposition its existing contentOffset when a NEW
  // contentInset is applied, so without this the view can settle
  // "scrolled past" a short video's own (narrow) content into blank
  // space the very first time a real inset is computed.
  private var hasAppliedInitialFilmstripContentInset = false

  // MARK: - Instagram-style scrollable combined timeline
  //
  // Per the user's explicit reference screenshot + "full Instagram-style
  // scrolling timeline" choice: the WHOLE combined filmstrip (primary
  // clip's own kept segments + every merged clip's own kept range, still
  // packed back-to-back with zero gap exactly as before) now lives inside
  // a horizontally scrollable container at a FIXED pixels-per-second
  // scale, with a playhead line fixed at the visible viewport's own
  // center — scrolling the strip IS scrubbing, rather than the strip
  // resizing to fit a fixed viewport with an internal moving playhead
  // (the prior design). videoTrimView/mergedStripView's own internal
  // coordinate math (x(for:)/xCompacted(for:)) needed NO changes for
  // this — both already derive positions purely from their own bounds.width
  // and duration, which now just happens to be set from a fixed pixel
  // scale instead of "fit available space."
  /// Pinch the timeline to zoom (Edits / CapCut style): 10–240 pt/s,
  /// default 40.
  private var timelinePointsPerSecond: CGFloat = 40
  private static let timelineZoomRange: ClosedRange<CGFloat> = 10...240
  private var timelinePinchStartScale: CGFloat = 40
  private let filmstripScrollView = UIScrollView()
  private let filmstripPlayheadView = UIView()
  /// Video redesign: "0:04 / 0:18" beside play/pause.
  private let videoTimeLabel = UILabel()
  private var lastVideoTimeLabelText = ""
  // Identity-matched (not index-matched, since AVQueuePlayer removes
  // played items from its own live queue) against queuePlayer.currentItem
  // to determine which merged clip is currently playing — populated
  // fresh every rebuildVideoQueue call.
  private var additionalPlayerItemsByURL: [(url: URL, item: AVPlayerItem)] = []
  // True only while the user's own finger is actively dragging/
  // decelerating the filmstrip — distinguishes a user-driven scrub (which
  // should both update the highlight AND, once released, actually seek
  // the player) from our OWN programmatic contentOffset updates that
  // follow hands-off playback (which should only update the highlight,
  // never re-trigger a seek — that would fight the player driving
  // itself). Per the user's explicit "make it auto scroll with video
  // timing... once user touch editor then stop scrolling" request, the
  // filmstrip auto-follows playback continuously (including across the
  // queue's own existing loop-back-to-start behavior) until this becomes
  // true.
  private var isUserScrubbingFilmstrip = false
  // nil = the primary clip is the one currently highlighted/active.
  private var activeClipURL: URL? {
    didSet {
      updateVideoSelectionLabel()
      // Per-clip volume / speed follow whichever clip is playing.
      if activeClipURL != oldValue {
        player?.volume = effectivePlayerVolume()
        applyPreviewSpeed()
      }
    }
  }
  // Observes the LAST queued item's own natural end (distinct from the
  // periodic time-observer's gap-skip logic, which only ever watches the
  // FIRST item's own kept segments) — firing means the whole queue played
  // through, and per the existing single-clip "loop forever" behavior,
  // the entire multi-clip queue should loop back to the start too. Torn
  // down and re-added every time the queue is rebuilt (new clip added/
  // removed) since it targets a specific AVPlayerItem instance.
  private var lastQueueItemEndObserver: NSObjectProtocol?
  // Backstop for the single-clip loop case. The periodic time-observer's
  // own gap-skip logic (below) is SUPPOSED to catch "reached the last kept
  // segment's own end" via a numeric `seconds >= upperBound` comparison and
  // seek back to the start — but on a real device that comparison can miss
  // the exact boundary tick (AVPlayer auto-pauses the instant the item
  // reaches its true end, and the periodic observer isn't guaranteed to
  // fire again once rate drops to 0), so playback silently stops instead
  // of looping — the user's exact "plays once then stops" report.
  // `.AVPlayerItemDidPlayToEndTime` is the reliable, purpose-built
  // notification for this and doesn't depend on polling precision. Only
  // acts when the queue is a single item (no merged clips) — the
  // multi-clip case already loops the whole queue via
  // `lastQueueItemEndObserver` above.
  //
  // IMPORTANT: once this notification actually fires, AVQueuePlayer has
  // already evicted the finished item from its internal queue (this
  // happens even with a single item and no next item to advance to —
  // a well-known AVQueuePlayer gotcha), so `currentItem`/`items()` are
  // empty by the time the handler runs. Seeking/playing the now-empty
  // `queuePlayer` is a silent no-op, so — exactly like
  // `lastQueueItemEndObserver` above — this rebuilds the queue from
  // scratch via `rebuildVideoQueue` rather than trying to reuse it.
  // Torn down/re-added every rebuild, same as `lastQueueItemEndObserver`.
  private var primaryItemEndObserver: NSObjectProtocol?
  // Per-layer active time range + manual-hide state, per the user's
  // explicit "extend and reduce each layer's duration, just like
  // Instagram" request. Keyed by ObjectIdentifier rather than adding a
  // stored property to EditableTextLayerView/EditableImageLayerView —
  // those two share no common base class with room for one, and a
  // side-table works uniformly for both without touching either class.
  // Deliberately SEPARATE from the existing isHidden-based soft-delete
  // (see deleteLayer) — combining both into one flag would make "deleted"
  // and "currently outside its time range" indistinguishable, breaking
  // undo/redo.
  // Multiple, non-overlapping segments per layer — per the user's
  // explicit "i want a functionality that i can split all layer" request,
  // mirroring how the primary video's own `videoSegments` supports
  // split/delete. Always non-empty; splitting divides one entry into two
  // adjacent ones (splitLayerSegment), deleting removes just one entry
  // (deleteLayerSegment) unless it's the last, which deletes the whole
  // layer instead (a layer with 0 segments is meaningless).
  private struct LayerTiming {
    var segments: [ClosedRange<Double>]
    /// Per-layer hide (eye button): invisible in the preview AND left out
    /// of the export, but still on its track so it can be shown again.
    var isManuallyHidden = false
    /// Per-layer lock: no move/resize/rotate on the canvas, no trim/move
    /// on its track, no split/delete/edit. Reordering still works.
    var isLocked = false
    /// Text animation (text layers): see TextAnimation for the types.
    var anim = TextAnimConfig.none
  }
  private var layerTimings: [ObjectIdentifier: LayerTiming] = [:]
  /// Which of `selectedLayer`'s own segments (if split) was last tapped
  /// in the layer-tracks row — Delete targets THIS one specifically when
  /// set (see deleteLayerSegment); nil falls back to whichever segment
  /// contains the current playhead. Reset to nil whenever selection
  /// changes via any OTHER path (canvas tap, duplicate, etc.) so a stale
  /// segment from a previously-selected layer never leaks into a new
  /// selection.
  private var selectedLayerSegmentIndex: Int? { didSet { syncLayerTrackSelection() } }
  private var timeObserverToken: Any?
  // Tracks the user's INTENDED play state, not the engine's transient
  // one — AVPlayer auto-pauses itself once an item plays to its natural
  // end (the common un-trimmed case, where trimEnd == the clip's true
  // end), so gating trim-loop-resume on `player.rate`/`timeControlStatus`
  // at that exact moment would wrongly read as "user paused" and never
  // loop. This flag instead reflects only explicit play/pause taps.
  private var isVideoPlaying = true

  // Music (Milestone 4, Day 23) — selection + preview only for now; baking
  // into the export (Day 25/26) lands later. A second, independent AVPlayer
  // mixes with the main player's audio via the system audio session
  // automatically — no manual mixing code needed for preview.
  private let musicTracks: [MusicTrack]
  private var selectedMusicTrack: MusicTrack?
  private var musicPlayer: AVPlayer?
  // play()/pause() don't flip timeControlStatus synchronously (a freshly
  // created player especially can sit at .waitingToPlayAtSpecifiedRate for
  // a moment while it buffers) — this KVO observation keeps the story
  // badge's play/pause icon (updateStoryMusicBadge) reactively correct
  // instead of relying on a one-shot check right after calling play/pause,
  // which is what caused the icon to occasionally show the wrong state
  // right after autoplay-on-select.
  private var musicPlayerTimeControlObservation: NSKeyValueObservation?
  // AVPlayer has no built-in loop mode — reaching the end just stops it.
  // This observer seeks back to zero and replays on end-of-item, so the
  // preview loops continuously instead of playing through once and
  // stopping, per the user's explicit "play in loop" request.
  private var musicPlayerLoopObserver: NSObjectProtocol?
  /// Empty-state "+ Choose music track" (dashed outline, video redesign).
  private let musicButton = DashedOutlineButton()

  // Day 24 — music volume. Trim UI removed per the user's explicit "remove
  // this music trimmer" request — musicTrimStart/End now just always span
  // the full track (set once the track's real duration resolves, see
  // selectMusicTrack), so export (which still reads them) always uses the
  // whole song rather than a user-picked portion.
  private let musicVolumeSlider = UISlider()
  private let musicVolumeValueLabel = UILabel()
  private let musicVolumeRow = UIStackView()
  private var musicTrimStart: Double = 0
  private var musicTrimEnd: Double = 0

  // Music-as-a-layer (per the user's explicit "add one dedicated layer of
  // music... user can scroll and drag to change position" request) — WHEN
  // in the combined video timeline the (already-trimmed, musicTrimStart/
  // End) song begins playing. The kept song duration itself stays
  // whatever the Music panel's own trim view says; this offset only
  // shifts its position, via the layer row's body-drag (see
  // LayerRangeBarView.allowBodyDrag). Distinct from musicTrimStart (which
  // portion of the SONG FILE plays) — this is where on the VIDEO that
  // portion starts.
  private var musicOffset: Double = 0
  // Per the user's explicit "same split music layer also" request — the
  // music row can now be split/have portions deleted exactly like a text/
  // sticker layer's own `LayerTiming.segments`. These are combined-
  // timeline windows during which the music is actually audible; a gap
  // between two segments (from deleting the one between them) mutes the
  // song during that window without skipping ahead in it — see
  // updateMusicPlaybackWindow/exportVideo's own music-loop doc for the
  // "anchor at segments[0]" continuity math. `musicOffset` above still
  // tracks segments[0]'s own start (kept in sync on every edit) since
  // several existing call sites read it directly.
  private var musicSegments: [ClosedRange<Double>] = []
  // Non-nil ONLY while the music row (not a canvas layer, video segment,
  // or merged clip) is the current Split/Delete target — mutually
  // exclusive with selectedLayer/selectedMergedClipURL/videoTrimView's own
  // selectedSegmentIndex, each of which clears this when THEY become the
  // target (see selectLayer, mergedStripView.onItemSelected, and
  // videoTrimView.onSegmentSelected).
  private var selectedMusicSegmentIndex: Int? {
    didSet {
      if selectedMusicSegmentIndex != nil { isVoiceRowSelected = false }
      updateVideoSelectionLabel()
    }
  }
  // Stable identity token for the music row's Item.id — mirrors how every
  // other row uses ObjectIdentifier(realLayerView); music has no real
  // on-canvas view of its own to take an identifier from.
  private let musicProxyToken = NSObject()

  // Chosen-track card (replaces the plain "SoundHelix Song 8"-style text
  // button once a track is picked) — per the user's explicit "update
  // choosen songs UI... provide music play pause button also remove
  // selected song icon" request. musicButton itself becomes the EMPTY-
  // STATE "+ Choose Music Track" trigger only; once a track is selected,
  // it hides and this card takes over (tapping the card body still opens
  // the same picker to change track).
  private let musicTrackCard = UIView()
  private let musicTrackSubtitleLabel = UILabel()
  private let musicArtView = UIView()
  private let musicChangeTrackButton = UIButton(type: .system)
  private let musicTrackTitleLabel = UILabel()
  private let musicPlayPauseButton = UIButton(type: .system)
  private let removeMusicButton = UIButton(type: .system)

  // Day 25 — mixing the original video audio against the music, completing
  // AudioState's originalAudioVolume (declared since Milestone 1, unused
  // until now). Independent of whether music is even selected — you may
  // just want to mute/duck the original clip's audio. The separate
  // muteOriginalAudioButton/originalAudioMuted toggle was removed per the
  // user's explicit "remove Mute Audio button" request — dragging this
  // slider to 0% already IS mute, a dedicated button was redundant.
  private let originalAudioVolumeSlider = UISlider()
  private let originalAudioVolumeValueLabel = UILabel()
  // Story mode's rail skips the half-sheet music panel entirely (see
  // presentStoryMusicPicker), so originalAudioVolumeSlider above is never
  // reachable there — this is a SEPARATE, story-mode-only quick toggle for
  // the same underlying state (originalAudioVolumeSlider.value), not a
  // revival of the old muteOriginalAudioButton removed above; per the
  // user's explicit "mute/unmute original video audio inside the story
  // editor" request. See toggleStoryOriginalAudioMute.
  private let storyMuteButton = MediaEditorViewController.makeStoryRailButton(systemImageName: "speaker.wave.2.fill")

  // Story mode's own top-center "now playing" pill — separate, additive UI
  // from musicTrackCard/musicPanel above (those stay untouched; this is
  // purely for the isStoryMode chrome, which skips the half-sheet panel
  // entirely and needs its own compact "what's selected, is it playing,
  // remove it" affordance directly over the canvas). See
  // setUpStoryMusicBadge/updateStoryMusicBadge/didTapStoryMusicBadge.
  private let storyMusicBadge = UIView()
  /// Story-mode chrome that lives directly on `view` (X, Undo/Redo, Share,
  /// the tool rail) — re-fronted by keepSafeAreaCoversOnTop so the opaque
  /// canvas gutter covers never paint over it. Those gutters are real
  /// black bars whenever a story photo is aspect-fit (not full-screen).
  private var storyChromeViews: [UIView] = []
  private let storyMusicBadgePlayPauseButton = UIButton(type: .system)
  private let storyMusicBadgeLabel = UILabel()
  private let storyMusicBadgeRemoveButton = UIButton(type: .system)

  // Pan/pinch/rotate accumulate here and recompose into imageView.transform.
  // Order matters: translate happens in the untransformed parent frame,
  // rotate/scale happen around the image's own center.
  private var currentTranslation: CGPoint = .zero
  private var currentScale: CGFloat = 1
  private var currentRotation: CGFloat = 0

  // 1.0 (not the old 0.5) — the canvas box already matches the photo's own
  // aspect ratio exactly (see imageContentAreaGuide), so scale 1.0 is
  // already "image exactly fills the box"; anything smaller would reveal
  // empty space around it, per the user's explicit "image should never go
  // out of bounds" request.
  private static let minScale: CGFloat = 1.0
  private static let maxScale: CGFloat = 6

  /// Pan/pinch/rotate and crop apply to whichever canvas view is actually
  /// showing this session's media — the exact same gesture/state code drives
  /// both, it's just retargeted here rather than duplicated per media type.
  private var activeMediaView: UIView {
    mediaType == "image" ? imageView : playerView
  }

  // Text layers are independent of the image's own pan/zoom/rotate — added
  // as siblings in `view`, not subviews of imageView.
  private var textLayerViews: [EditableTextLayerView] = []

  // Stickers reuse the exact same transformable-layer view as text
  // (EditableTextLayerView), displaying a bundled sticker image — so every
  // gesture/undo/export/per-layer-timing code path keeps working. Kept in
  // a separate array so layer-management code can tell stickers from text.
  // The library itself is StickerCatalog (StickerKit.swift).
  private var stickerLayerViews: [EditableTextLayerView] = []

  /// A second photo placed on top of the first — the "overlay" feature,
  /// per the user's explicit request. Image-only for now (not baked into
  /// video export) — same scope limit already accepted for Vignette/
  /// Sharpen on Android, for the same reason: video export would need a
  /// custom Media3-equivalent (here, AVVideoCompositing) integration, a
  /// materially bigger scope than adding another CIFilter/layer term.
  private var imageOverlayLayerViews: [EditableImageLayerView] = []
  /// Initial on-screen size for a newly-added overlay image — long side
  /// capped at this many points, aspect-preserved, so a full-resolution
  /// photo doesn't appear at some enormous native size before the user
  /// pinches it down.
  private static let overlayInitialMaxDimension: CGFloat = 160

  /// New text/sticker layers (and duplicates) are anchored `imageView.
  /// centerYAnchor` PLUS this constant, not dead-center — see addTextLayer.
  /// **Used in exactly 2 places on purpose: the anchor constraint itself
  /// (addTextLayer/addStickerLayer/didTapDuplicateSelectedLayer) and the
  /// export math (drawLayerForExport/exportVideo's overlay positioning)**
  /// — the two MUST agree, since export recomputes each layer's position
  /// from `canvasCenter + layer.currentTranslation` without reading the
  /// live constraint. A prior version hardcoded this offset only in the
  /// constraint and not in export, so exported text/stickers landed
  /// `newLayerVerticalOffset` points away from where they appeared live
  /// (user-reported bug) — a shared constant instead of 2 magic numbers
  /// makes that drift impossible to reintroduce silently.
  private static let newLayerVerticalOffset: CGFloat = -60

  // On-canvas layer action toolbar (Delete/Duplicate/Edit) — appears above
  // whichever layer (text/sticker/image overlay) was last tapped, tracks
  // its position live during drag/pinch/rotate (via
  // EditableLayerView.onTransformChanged), and disappears when the canvas
  // itself is tapped (didTapCanvasBackground). Typed as the shared
  // `EditableLayerView` protocol (not a specific concrete class) so the
  // same selection/toolbar machinery works for every layer type —
  // `didTapDuplicateSelectedLayer`/`didTapEditSelectedLayer` are the only
  // 2 places that need to know which concrete type it actually is.
  private var selectedLayer: EditableLayerView? {
    didSet {
      if selectedLayer != nil { isVoiceRowSelected = false }
      updateVideoSelectionLabel()
      syncLayerTrackSelection()
    }
  }
  private var layerActionToolbar: UIStackView?
  // Stored so setCanvasTransformGesturesEnabled can toggle just these 3 —
  // see its doc comment.
  private var canvasPanGesture: UIPanGestureRecognizer?
  private var canvasPinchGesture: UIPinchGestureRecognizer?
  private var canvasRotationGesture: UIRotationGestureRecognizer?
  // View-wide pan/pinch/rotate, enabled ONLY while a layer is selected —
  // forwards to `selectedLayer` regardless of where on screen the touch
  // lands, so pinching/dragging keeps working even if fingers miss a
  // shrunk-down layer's own small bounds. Instagram-style, per the user's
  // explicit request ("i want same like instagram"). See
  // setUpSharedLayerGestures/selectLayer/deselectLayer.
  private let sharedLayerPanGesture = UIPanGestureRecognizer()
  private let sharedLayerPinchGesture = UIPinchGestureRecognizer()
  private let sharedLayerRotationGesture = UIRotationGestureRecognizer()
  /// Non-nil only while the text-entry overlay is open FOR AN EXISTING
  /// layer (via the toolbar's Edit action) — didConfirmTextEntry updates
  /// this layer in place instead of adding a new one. Reset to nil by
  /// dismissTextEntryOverlay so a later "Add Text" tap never reuses a
  /// stale target.
  private var editingLayer: EditableTextLayerView?

  // Filters apply to the base (already-downsampled) preview image only —
  // full-res filter application happens at export time. `baseImage` is the
  // untouched source every filter re-renders from, so switching filters
  // never compounds on top of a previous one.
  private var baseImage: UIImage?
  private let ciContext = CIContext()
  private var selectedFilter: PhotoFilter = .original
  /// 0...1 intensity of `selectedFilter` (Filters panel Strength slider).
  private var filterStrength: Float = 1
  /// Filters panel Saturation (-1...1) and Sharpness (0...1), applied right
  /// after the filter. Reset to 0 whenever a different filter is picked.
  private var filterSaturation: Float = 0
  private var filterSharpness: Float = 0

  // Adjustments compose on top of whichever filter is selected: preview =
  // filter -> brightness -> contrast -> saturation, always rebuilt from
  // baseImage so repeated slider drags never compound rounding error. Not
  // part of undo/redo — same reasoning as the continuous transform gestures.
  private var brightness: Float = 0 // -1...1
  private var contrast: Float = 0 // -1...1 (0 = unchanged)
  private var saturation: Float = 0 // -1...1 (0 = unchanged)
  // 5 additional adjustments, per the user's explicit request — same
  // -1...1 range and "always rebuilt from baseImage" rule as B/C/S above.
  // Positive fade/shadow/warmth = fade out / lift shadows / warmer;
  // negative = the opposite (more vivid / deepen shadows / cooler).
  // Vignette/sharpen only have a meaningful positive direction (there's no
  // natural "negative vignette"), so negative values are treated as 0.
  private var fade: Float = 0
  private var shadow: Float = 0
  private var vignette: Float = 0
  private var sharpen: Float = 0
  private var warmth: Float = 0
  // 2 more adjustments, per the user's follow-up request — same -1...1
  // range/rebuild rule. Highlights is CIHighlightShadowAdjust's OTHER
  // parameter (inputHighlightAmount) — shadow already uses
  // inputShadowAmount on the same filter instance. Tint is a green-magenta
  // shift via colorMatrix's G channel, the counterpart to Warmth's
  // blue-orange shift via R/B.
  private var highlights: Float = 0
  private var tint: Float = 0

  /// Per the user's explicit "any clip including the first should be
  /// reorderable, and edits should stay with their own clip" request —
  /// until now `selectedFilter`/the 10 adjustment vars above were
  /// effectively single-instance globals implicitly meaning "the primary
  /// clip's settings" (only the primary clip could ever have them; a
  /// merged/additional clip structurally couldn't — see
  /// makeAdditionalPlayerItem's own doc). `clipFilterState` below is the
  /// per-clip store, keyed by URL (sourceURL's current value counts as a
  /// key here too, same as additionalClipSegments/additionalClipDurations/
  /// additionalClipThumbnailTiles are keyed by URL regardless of primary-
  /// vs-additional role); `selectedFilter`/the 10 adjustment vars stay a
  /// "working copy" that always mirrors whichever clip is currently
  /// active — see syncActiveClipFilterState.
  private struct ClipFilterState {
    var filter: PhotoFilter = .original
    var filterStrength: Float = 1
    var filterSaturation: Float = 0
    var filterSharpness: Float = 0
    var adjustments = PhotoAdjustments()
  }
  private var clipFilterState: [URL: ClipFilterState] = [:]

  private func currentFilterStateSnapshot() -> ClipFilterState {
    ClipFilterState(
      filter: selectedFilter,
      filterStrength: filterStrength,
      filterSaturation: filterSaturation,
      filterSharpness: filterSharpness,
      adjustments: currentAdjustments
    )
  }

  /// Loads `state` into the working-copy vars AND re-syncs the Edit/
  /// Effect panels' own UI (sliders + filter-picker highlight) to match —
  /// a "reload" path that never existed before this session, since
  /// previously there was only ever one possible editing target (the
  /// primary clip) and the sliders/filter picker were simply never
  /// reloaded once built.
  private func applyFilterStateSnapshot(_ state: ClipFilterState) {
    selectedFilter = state.filter
    filterStrength = state.filterStrength
    filterSaturation = state.filterSaturation
    filterSharpness = state.filterSharpness
    brightness = state.adjustments.brightness
    contrast = state.adjustments.contrast
    saturation = state.adjustments.saturation
    fade = state.adjustments.fade
    shadow = state.adjustments.shadow
    highlights = state.adjustments.highlights
    warmth = state.adjustments.warmth
    tint = state.adjustments.tint
    sharpen = state.adjustments.sharpen
    vignette = state.adjustments.vignette
    syncAdjustSlidersToCurrentValues()
    updateFilterButtonHighlight()
  }

  /// Pushes the working-copy vars' current values into each of their own
  /// UISliders — setting `.value` does NOT fire `.valueChanged` on its
  /// own (see makeAdjustmentRow's own undo/redo doc), so this re-drives
  /// it manually via `sendActions(for: .valueChanged)`, exactly like that
  /// same undo/redo restore path already does. Each row is the
  /// UIStackView(label, slider, valueLabel) makeAdjustmentRow itself
  /// builds — arrangedSubviews[1] reaches the UISlider without needing
  /// makeAdjustmentRow to expose one directly.
  private func syncAdjustSlidersToCurrentValues() {
    let currentValues: [AdjustProperty: Float] = [
      .brightness: brightness, .contrast: contrast, .saturation: saturation,
      .fade: fade, .shadow: shadow, .warmth: warmth, .highlights: highlights, .tint: tint,
      .sharpen: sharpen, .vignette: vignette,
    ]
    for (property, value) in currentValues {
      guard let row = adjustSliderRows[property] as? UIStackView,
            row.arrangedSubviews.count > 1,
            let slider = row.arrangedSubviews[1] as? UISlider
      else { continue }
      slider.value = value
      slider.sendActions(for: .valueChanged)
    }
  }

  /// Called whenever activeClipURL changes (see updateActiveClipHighlight)
  /// — flushes the OUTGOING clip's current working-copy values into
  /// `clipFilterState`, then loads the INCOMING clip's own stored values
  /// (or defaults, if it's never been individually edited) into the
  /// working copy. previousURL/newURL use the same "nil = primary"
  /// convention activeClipURL itself already does.
  private func syncActiveClipFilterState(previousURL: URL?, newURL: URL?) {
    clipFilterState[previousURL ?? sourceURL] = currentFilterStateSnapshot()
    applyFilterStateSnapshot(clipFilterState[newURL ?? sourceURL] ?? ClipFilterState())
  }

  // Basic undo/redo — covers adding/deleting text and sticker layers only.
  // Continuous gestures (image pan/zoom/rotate, crop resize) are
  // deliberately not part of this: they're trivially reversible by hand
  // (drag back), and capturing coarse-grained undo steps for a continuous
  // multi-touch gesture is a materially bigger feature than "basic".
  private struct UndoableAction {
    let undo: () -> Void
    let redo: () -> Void
  }
  private var undoStack: [UndoableAction] = [] {
    // Any committed change (layer added/moved/styled/deleted) may change
    // what the blur has to cover.
    didSet { DispatchQueue.main.async { [weak self] in self?.updateBlurCover(force: true) } }
  }
  /// Redesign Phase 5: while a tool panel is open, the undo-stack depth when
  /// it opened. ✕ undoes back to it; leaving any other way (Done, drag
  /// down, another tool) merges everything since into one undo step.
  private var toolSession: (tab: ImageEditorTab, depth: Int)?
  private static let sessionTabs: [ImageEditorTab] = [.effect, .edit, .stickers, .draw, .textStyle]
  private var redoStack: [UndoableAction] = []

  private func pushUndo(undo: @escaping () -> Void, redo: @escaping () -> Void) {
    undoStack.append(UndoableAction(undo: undo, redo: redo))
    redoStack.removeAll()
  }

  // MARK: - Top/bottom bar (Milestone 5 UI polish) — shared by image AND
  // video since the user's explicit "same UI as the image editor" request;
  // originally image-only, with video kept on its own separate layout.
  //
  // Cancel/Undo/Redo/Done live in one icon row at the top; the rest
  // collapses into a bottom tab bar (Tools/Text/Draw/Sticker/Overlay, plus
  // a video-only Music tab). Filters + Adjust live in their own always-
  // visible strip under the canvas, not a tab. Tools has no panel of its
  // own — pan/zoom/rotate work continuously on the canvas, so it's the
  // default/no-op selection. Stickers/Draw/Music are stateful tabs (each
  // reveals its own persistent panel); Text/Overlay are momentary actions,
  // wired straight to their own picker/overlay with no tab state of their
  // own.
  //
  // Name kept as `ImageEditorTab`/`selectedImageEditorTab` even though it
  // now also drives video — renaming every reference site was judged not
  // worth the risk for a purely cosmetic improvement.
  private enum ImageEditorTab {
    case tools
    /// Filters — was an always-visible strip, moved back behind its own
    /// tab per the user's explicit "major change" request.
    case effect
    case stickers
    case draw
    /// Adjustments (Brightness/Contrast/etc.) — same "was always-visible,
    /// now gated behind a tab" change as `effect`.
    case edit
    /// Video only — never selectable for an image session (no music tab
    /// button exists in that case, see setUpEditingControls).
    case music
    /// Text Style panel for the selected text layer (opened from its
    /// toolbar's Style button, no tray tab of its own).
    case textStyle
    /// Redesign: the Tools grid sheet (TOOLS in the bottom bar).
    case toolsGrid
  }
  private var selectedImageEditorTab: ImageEditorTab = .tools
  // SF Symbol "arrow.up.and.down.and.arrow.left.and.right" — a standard
  // move/pan glyph. Previously "crop", left over from before crop was
  // removed from this editor; cosmetically implied a feature that no
  // longer exists.
  private let toolsTabButton = MediaEditorViewController.makeTabButton(imageName: "tool_move", title: "Tools")
  // Filters — left of Text, per the user's explicit tab-order request.
  // Was the always-visible filter row; now gated behind this tab.
  // "sparkles" — matches Android's EditorIcon.SPARKLE glyph exactly (a
  // sparkle/stars shape), per the user's explicit "make all icons...
  // same for ios and android" request. Was "camera.filters", a
  // different concept from Android's own icon for this tab.
  private let effectTabButton = MediaEditorViewController.makeTabButton(imageName: "tool_filters", title: "Filters")
  // Height is set post-init via setCollapsedHeight (see setUpEditingControls)
  // since it depends on `isImage`, not known at property-initializer time.
  private let effectPanel = SlideUpPanelView(title: "Filters")
  private let textTabButton = MediaEditorViewController.makeTabButton(imageName: "tool_text", title: "Text")
  // Adjustments (Brightness/Contrast/etc.) — right of Text, per the user's
  // explicit tab-order request. Was the always-visible adjust icon row/
  // single-slider swap; now gated behind this tab.
  // "pencil" — matches Android's EditorIcon.EDIT glyph exactly (a
  // standard pencil shape), per the user's explicit "make all icons...
  // same for ios and android" request. Was "slider.horizontal.3", a
  // different concept from Android's own icon for this tab.
  private let editTabButton = MediaEditorViewController.makeTabButton(imageName: "tool_adjust", title: "Adjust")
  private let editPanel = SlideUpPanelView(title: "Adjust")
  private let stickerTabButton = MediaEditorViewController.makeTabButton(imageName: "tool_sticker", title: "Sticker")
  // Freehand draw/brush — per the user's explicit request. 3rd stateful
  // tab, same SlideUpPanelView shell as Stickers (color row + brush-width
  // slider instead of a sticker grid). "scribble" is a real SF Symbol, not
  // a custom asset.
  private let drawTabButton = MediaEditorViewController.makeTabButton(imageName: "tool_draw", title: "Draw")
  // Momentary action, like Text/Sticker — opens the system photo picker
  // (PHPickerViewController) and adds the chosen photo as a new draggable/
  // pinchable/rotatable overlay layer, per the user's explicit request.
  private let overlayTabButton = MediaEditorViewController.makeTabButton(imageName: "tool_overlay", title: "Overlay")
  // Video-only 6th tab, consolidating what used to be several separate
  // floating controls (music picker, its volume/trim, original-clip mute/
  // volume) into one SlideUpPanelView, matching the Stickers/Draw pattern.
  private let musicTabButton = MediaEditorViewController.makeTabButton(imageName: "tool_music", title: "Music")
  private let musicPanel = SlideUpPanelView(title: "Music")
  // Video-only, momentary action like Text/Overlay — opens a video picker
  // and appends the chosen clip after the current one (see exportVideo's
  // own doc for what "merge" means in this first version). Replaces
  // Overlay's old slot in the tray now that Overlay is video-excluded.
  // "plus" — matches Android's EditorIcon.ADD_VIDEO glyph exactly (a
  // plain "+" cross), per the user's explicit "make all icons... same
  // for ios and android" request. Was "film.stack", a different concept
  // from Android's own (deliberately minimal) icon for this tab.
  private let mergeTabButton = MediaEditorViewController.makeTabButton(imageName: "tool_add_video", title: "Clips")
  // Small pill under each STATEFUL tab's label (Tools/Sticker/Draw/Music —
  // the same 4 tabs the color-crossfade in updateImageEditorUI already
  // tracks; Text/Overlay stay momentary actions with no selected state,
  // so they get no indicator), per UI-modernization item 4: a real
  // selection indicator instead of relying on icon/label color alone.
  private let toolsTabIndicator = MediaEditorViewController.makeTabIndicatorDot()
  private let effectTabIndicator = MediaEditorViewController.makeTabIndicatorDot()
  private let editTabIndicator = MediaEditorViewController.makeTabIndicatorDot()
  private let stickerTabIndicator = MediaEditorViewController.makeTabIndicatorDot()
  private let drawTabIndicator = MediaEditorViewController.makeTabIndicatorDot()
  private let musicTabIndicator = MediaEditorViewController.makeTabIndicatorDot()
  private let topBar = UIView()
  // Wraps bottomTrayScrollView so the tray can have rounded top corners +
  // a real elevation shadow (UI-modernization item 3) without fighting
  // UIScrollView's own `clipsToBounds = true` default, which would
  // otherwise clip the shadow away — the scroll view stays a transparent,
  // fully-clipped overlay on top of this opaque, shadowed card.
  private let bottomTrayCardView = UIView()
  private let bottomTrayScrollView = UIScrollView()
  private let bottomTabBar = UIStackView()
  /// Video editor (not photo, not story): compact tool rail — only for the
  /// hand-built rail (before iOS 26). On iOS 26 the rail is the system
  /// Liquid Glass UITabBar (setUpSystemToolTabBar), which already uses
  /// small 10pt labels and needs its own full height: squeezed to the
  /// compact height it drew every icon on top of its label.
  /// iOS 26 keeps the native bar at its ORIGINAL settings (76pt, no title
  /// offset) — at those it shows every name in full; making it taller or
  /// shifting the titles is what made it cut names to "Fil…".
  private var isCompactToolRail: Bool {
    if #available(iOS 26.0, *) { return false }
    return !isStoryMode && mediaType != "image"
  }
  // Icon 20 + gap 6 + label ~15 + insets, inside the glass capsule's 6pt
  // top/bottom insets — 62 was too tight and the label rode up into the icon.
  private static let compactTrayHeight: CGFloat = 78
  private static let compactTrayIconSize: CGFloat = 20
  /// iOS 26 system bar (video editor): icons sit this much higher, and
  /// the bar is a bit taller, so the pills feel less cramped.
  private static let systemTabBarIconLift: CGFloat = 3
  private static let systemTabBarExtraHeight: CGFloat = 8
  /// Tool rail height — compact in the video editor.
  private var trayHeight: CGFloat {
    if isCompactToolRail { return Self.compactTrayHeight }
    if #available(iOS 26.0, *), !isStoryMode, mediaType != "image" {
      return EditorDesignTokens.Spacing.bottomTrayHeight + Self.systemTabBarExtraHeight
    }
    return EditorDesignTokens.Spacing.bottomTrayHeight
  }

  private static func resizedRailIcon(_ image: UIImage, side: CGFloat) -> UIImage {
    let scale = side / max(image.size.width, image.size.height, 1)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
      .withRenderingMode(.alwaysTemplate)
  }
  /// Instagram-style floating glass capsule behind the tool row, and the
  /// lighter "lens" pill that slides to the selected tool (regular editor).
  /// iOS 26: real Liquid Glass (UIGlassEffect, same as the top-bar
  /// controls). Earlier iOS: the frosted capsule.
  private let toolGlassView: UIView = {
    if #available(iOS 26.0, *) { return GlassSurfaceView(shape: .capsule) }
    return GlassCapsuleView()
  }()
  private let toolLensView = GlassLensView()
  /// Gap between the capsule and the screen edge / its own content.
  /// Video editor: a wider capsule (closer to the screen edges) so every
  /// tool name has room to show in full.
  private var toolGlassInsetH: CGFloat { isCompactToolRail ? 4 : 12 }
  private static let toolGlassInsetV: CGFloat = 6
  // Filters + Adjust used to be an "Effects" tab/panel, then moved to an
  // always-visible strip under the canvas (Instagram-style); per the
  // user's later "major change" request they're back to being tab-gated
  // panels again — see effectPanel/editPanel above.
  private enum AdjustProperty {
    case brightness, contrast, saturation, fade, shadow, vignette, sharpen, warmth, highlights, tint, blur
    /// Not a slider — a one-tap action (see didTapAutoEnhance).
    case auto
  }
  /// Auto-enhance toggle state: values it applied, and what they replaced.
  /// "On" whenever the sliders still exactly match `autoEnhanceApplied`.
  private var autoEnhanceApplied: PhotoAutoEnhance?
  private var autoEnhanceBackup: PhotoAutoEnhance?
  private var autoEnhanceButton: UIButton?
  /// Tilt-shift / background blur (photo only) — see PhotoBlur.
  private var blur = PhotoBlur()
  /// Blur over text/stickers/overlays/drawing (see updateBlurCover).
  private let blurCoverView = UIImageView()
  private var unblurredPreviewImage: UIImage?
  private var blurCoverSignature: [CGFloat] = []
  private var blurCoverLink: CADisplayLink?
  private let blurOverlayView = BlurFocusOverlayView()
  private var blurModeButtons: [PhotoBlur.Mode: UIButton] = [:]
  private var blurStrengthSlider: UISlider?
  private var selectedAdjustProperty: AdjustProperty?

  // Redesign Phase 4 — Snapseed-style Tune: while Adjust is open, a
  // transparent surface over the photo takes swipes. Up/down picks the
  // setting (list shown while choosing), left/right changes its value.
  // It drives the SAME Adjust sliders (value, preview, undo all unchanged).
  private static let tuneOrder: [(AdjustProperty, String)] = [
    (.brightness, "Brightness"), (.contrast, "Contrast"), (.saturation, "Saturation"),
    (.warmth, "Warmth"), (.highlights, "Highlights"), (.shadow, "Shadows"),
    (.fade, "Fade"), (.tint, "Tint"), (.sharpen, "Sharpen"), (.vignette, "Vignette"),
  ]
  private var tuneProperty: AdjustProperty = .brightness
  private let tuneSurfaceView = UIView()
  private let tunePillView = UIView()
  private let tunePillNameLabel = UILabel()
  private let tunePillValueLabel = UILabel()
  private let tunePillBarFill = UIView()
  private let tuneListView = UIStackView()
  /// One row per setting: (row background, name, value).
  private var tuneListRows: [(row: UIView, name: UILabel, value: UILabel)] = []
  /// Finger travel per setting while choosing — small enough that every
  /// setting is reachable within a fitted (shrunk) picture.
  private static let tuneChooseStep: CGFloat = 17
  private enum TuneSwipeMode { case undecided, choose, adjust }
  private var tuneSwipeMode: TuneSwipeMode = .undecided
  private var tuneSwipeStartIndex = 0
  private var tuneSwipeStartValue: Float = 0
  /// Mockup Tune screen chrome: bottom bar (✕ · compare · Tune · list · ✓)
  /// and the hint above it. While Tune is open the top bar, the Adjust
  /// panel, the tool rail and LOOKS · TOOLS · EXPORT are all hidden.
  private let tuneBottomBar = UIView()
  private let tuneHintLabel = UILabel()
  /// Mockup Filters screen: the selected filter's name above the photo.
  private let filterNameLabel = UILabel()
  private let filterNameGlass = GlassSurfaceView(shape: .capsule)
  /// Filters and Text/Style open full screen like Tune (mockup): the
  /// sheet carries its own ✕ · title · ✓ bar and the top bar, tool rail
  /// and LOOKS · TOOLS · EXPORT are hidden. Story mode keeps its own chrome.
  private var isFullScreenPanelTool: Bool {
    !isStoryMode && (selectedImageEditorTab == .effect || selectedImageEditorTab == .textStyle
      || (selectedImageEditorTab == .music && mediaType != "image"))
  }
  /// The settings list opened from the bottom bar's list button: stays up
  /// and its rows can be tapped (a swipe's list is touch-through).
  private var isTuneListPinned = false

  /// Adjust shows as the full-screen Tune mode except for Blur, which keeps
  /// the Adjust panel (it needs its mode buttons).
  private var isTuneActive: Bool {
    selectedImageEditorTab == .edit && selectedAdjustProperty != .blur
  }
  private let adjustIconRow = UIStackView()
  private let adjustIconScrollView = UIScrollView()
  private let adjustDetailRow = UIStackView()
  private var adjustSliderRows: [AdjustProperty: UIView] = [:]
  /// Base collapsed heights for the Effect/Edit panels — the same "must be
  /// a constant, not measured from a live view" reasoning as every other
  /// chrome height here (see SlideUpPanelView's own doc), sized to just
  /// barely fit that panel's actual content (a filter row / the adjust
  /// icon row's fixed 44pt height) rather than the much taller standard
  /// collapsed height Sticker/Draw/Music's content needs.
  // 176 = header + category tabs + thumbnails. 200 = adjust mode: back
  // row + Strength/Saturation/Sharpness (opened from the pencil on the
  // selected thumbnail). Same values as Android.
  private let effectPanelHeight: CGFloat = 200
  private let effectPanelHeightWithoutSliders: CGFloat = 176
  private static let filterCategoryRowHeight: CGFloat = 30
  // Header + one 44pt row (icons, or one slider) — reduced from 140 per the
  // user's "too tall" report. Same as Android.
  private let editPanelHeight: CGFloat = 104
  /// Reverted back to the SF Symbol default (~17pt, unconfigured — same as
  /// splitSegmentButton/deleteSegmentButton's own "scissors"/"trash" icons,
  /// which never took a custom configuration) per the user's later,
  /// explicit "play/pause icons should be the same size as the delete
  /// icon" correction to the earlier "increase size" request this
  /// constant originally implemented.
  // Per the reference spec's explicit "grid (4 columns) of sticker
  // thumbnails in the panel" — Stickers becomes a 3rd stateful tab reusing
  // the same SlideUpPanelView shell as Effects, rather than the momentary
  // action-sheet picker it was before (Text stays momentary — its own spec
  // text explicitly wants an immediate keyboard, not a panel).
  // Taller than the default to fit the search box + category tabs.
  private let stickersPanel = SlideUpPanelView(title: "Stickers", collapsedHeight: 280)
  private weak var stickerSearchField: UISearchTextField?
  private var stickerCategoryTabs: [UIButton] = []
  private weak var stickerCategoryScrollRef: UIScrollView?
  private weak var stickerGridStack: UIStackView?
  private weak var stickerGridScrollRef: UIScrollView?
  private var selectedStickerCategory = 0
  /// Active only while typing a search, so the panel rides above the keyboard.
  private var stickersPanelKeyboardConstraint: NSLayoutConstraint?
  // Reduced from the shared default per the user's explicit "make these
  // height small of vertical container" request — this panel's actual
  // content (color row + brush-type row + brush-size row) is much
  // shorter than the default, leaving a large dead empty area below it
  // otherwise. Mirrors Android's identical override.
  private let drawPanel = SlideUpPanelView(title: "Draw", collapsedHeight: 200)
  /// Redesign: every tool as a grid of tiles (TOOLS in the bottom bar).
  private let toolsGridPanel = SlideUpPanelView(title: "Tools", collapsedHeight: 280)
  /// Rows of tiles in the Tools sheet (sizes it to show them all).
  private var toolsGridRowCount = 0
  /// LOOKS · TOOLS · EXPORT buttons and their underlines.
  private var lookToolsButtons: [(button: UIButton, underline: UIView)] = []
  // Sized/positioned to exactly match imageView's own box (see
  // setUpDrawingCanvas, same technique as gridOverlayView) so a recorded
  // touch point is already in imageView's own local coordinate space —
  // needs only a straight `* exportScale` at export time, no translation.
  private let drawingCanvasView = DrawingCanvasView()
  private var selectedDrawColor: UIColor = .white
  private var selectedDrawWidthPoints: CGFloat = 6
  private var drawColorButtons: [UIButton] = []
  // Per the user's explicit "add multiple brush option" request.
  private var selectedBrushType: DrawingCanvasView.BrushType = .pen
  private var drawBrushTypeButtons: [(DrawingCanvasView.BrushType, UIButton)] = []
  /// The eraser keeps its own size, separate from the brushes'.
  private var drawEraserWidthPoints: CGFloat = 20
  /// Draw panel tool: freehand brush, eraser, or drag-to-size shape (drawn
  /// with the selected brush). Same on Android.
  private enum DrawTool: CaseIterable {
    case brush, eraser, shape
    var symbol: String {
      switch self {
      case .brush: return "paintbrush.pointed.fill"
      case .eraser: return "eraser.fill"
      case .shape: return "square.on.circle"
      }
    }
    var title: String {
      switch self {
      case .brush: return "Brush"
      case .eraser: return "Eraser"
      case .shape: return "Shape"
      }
    }
  }
  private var selectedDrawTool: DrawTool = .brush
  private var selectedDrawShape: DrawingCanvasView.ShapeType = .rectangle
  private var drawToolButtons: [(DrawTool, UIButton)] = []
  private var drawShapeButtons: [(DrawingCanvasView.ShapeType, UIButton)] = []
  private var drawBrushTilesRef: UIView?
  private var drawShapeTilesRef: UIView?
  private var drawWidthSliderRef: UISlider?
  private var drawColorScrollRef: UIView?
  /// Maps each filter to its rendered circular thumbnail image view — used
  /// both to fill in the live-rendered preview once baseImage loads
  /// (renderFilterThumbnails) and to draw the selected-state ring border
  /// (updateFilterButtonHighlight).
  private var filterThumbnailImageViews: [PhotoFilter: UIImageView] = [:]
  // Filters panel slider rows (see makeFilterSliderRow).
  /// Filters-panel slider rows (Strength / Saturation / Sharpness).
  private struct FilterSliderRow {
    let view: UIView
    let slider: UISlider
    let valueLabel: UILabel
    let read: () -> Float
  }
  private var filterSliderRows: [FilterSliderRow] = []

  // MARK: - Text entry overlay — an on-canvas text input with a font/
  // colour/style toolbar above the keyboard. Fonts are the bundled set in
  // TextFontCatalog (same files as Android), drawn by TextLayerRenderer.
  // Expanded from 6 to 12 (per the user's explicit "add more than 10
  // colors" request), then 12 to 18 (per their "add more colors"
  // follow-up) — all real UIColor system colors or their exact hex
  // equivalents (kept identical to Android's textColorSwatches for
  // visual parity, same convention as the original 12).
  private static let textColorSwatches: [UIColor] = [
    .white, .black, UIColor(red: 0x7C / 255, green: 0x4D / 255, blue: 0xFF / 255, alpha: 1), .systemRed, .systemYellow, .systemBlue,
    .systemGreen, .systemOrange, .systemPink, .systemTeal, .systemPurple, .systemGray,
    .systemIndigo, .systemMint, .systemCyan, .systemBrown,
    UIColor(red: 0xB8 / 255, green: 0x86 / 255, blue: 0x0B / 255, alpha: 1), // gold
    UIColor(red: 1, green: 0, blue: 1, alpha: 1), // magenta
  ]
  private var textEntryOverlay: UIView?
  private let textEntryTextView = UITextView()
  /// The look being chosen in the text-entry sheet. When editing an
  /// existing layer it starts from that layer's style, so the Style
  /// panel's settings (outline, arch…) are kept.
  private var textEntryStyle = TextLayerStyle()
  private var textFontButtons: [UIButton] = []
  private var textColorButtons: [UIButton] = []
  private var textBoldButton: UIButton?
  private var textItalicButton: UIButton?
  private var textUnderlineButton: UIButton?
  private var textAlignButton: UIButton?
  private var textBackgroundButton: UIButton?

  // Text Style panel (Size / Outline / Shadow / Opacity / Stretch / Arch),
  // opened from the selected text layer's toolbar. Changes apply live to
  // the layer; one undo step is recorded when the panel closes.
  private enum TextStyleTool: CaseIterable {
    case filters, light, color, size, outline, shadow, opacity, stretch, arch, blend, shape, border, flip, eraser, crop
    var title: String {
      switch self {
      case .filters: return "Filters"
      case .light: return "Light"
      case .color: return "Color"
      case .size: return "Size"
      case .outline: return "Outline"
      case .shadow: return "Shadow"
      case .opacity: return "Opacity"
      case .stretch: return "Stretch"
      case .arch: return "Arch"
      case .blend: return "Blend"
      case .shape: return "Shape"
      case .border: return "Border"
      case .flip: return "Flip"
      case .eraser: return "Eraser"
      case .crop: return "Crop"
      }
    }
    static let textTools: [TextStyleTool] = [.size, .outline, .shadow, .opacity, .stretch, .arch]
    static let stickerTools: [TextStyleTool] = [.opacity, .outline, .shadow, .flip]
    static let overlayTools: [TextStyleTool] = [.filters, .light, .color, .opacity, .blend, .shape, .border, .flip, .eraser, .crop]
  }
  /// The look being edited — a text layer's, a sticker's or an overlay's
  /// (the same panel serves all three; one undo step per panel session).
  private enum LayerStyleSnapshot: Equatable {
    case text(TextLayerStyle)
    case sticker(StickerStyle)
    case overlay(OverlayStyle, [OverlayEraseStroke])
  }
  private let textStylePanelHeight: CGFloat = 160
  /// Overlays need room for the filter thumbnails / chips above a slider.
  private let overlayStylePanelHeight: CGFloat = 200
  private lazy var textStylePanel = SlideUpPanelView(title: "Style", collapsedHeight: textStylePanelHeight)
  private var textStyleTarget: UIView?
  private var textStyleAtOpen: LayerStyleSnapshot?
  private var textStyleFlipRow: UIView?
  /// Chips above the sliders (filter thumbnails, blend modes, shapes,
  /// border colours, eraser modes) — rebuilt per tool.
  private var textStyleChipStack: UIStackView?
  private var textStyleChipScroll: UIScrollView?
  private var overlayFilterThumbnails: (base: ObjectIdentifier, images: [PhotoFilter: UIImage])?
  private var overlayEraseRestoreMode = false
  private var overlayEraserWidthPoints: CGFloat = 28
  private let overlayEraseCaptureView = OverlayEraseCaptureView()
  private var selectedTextStyleTool: TextStyleTool = .size
  private var textStyleToolButtons: [TextStyleTool: UIButton] = [:]
  private struct TextStyleSliderRow {
    let view: UIView
    let titleLabel: UILabel
    let slider: UISlider
    let valueLabel: UILabel
  }
  private var textStyleSliderRows: [TextStyleSliderRow] = []

  /// Icon/title are a CONSTANT white regardless of selection — per the
  /// user's explicit "make these icons color white and just make that
  /// which icons is active then show red dot below these icon" request
  /// (see updateImageEditorUI, which now only toggles the dot).
  /// `imageName` is one of the redesign's line icons in Images.xcassets
  /// (tool_*, same drawings as Android's ic_tool_*).
  private static func makeTabButton(imageName: String, title: String) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(named: imageName)?.withRenderingMode(.alwaysTemplate)
    config.title = title
    config.imagePlacement = .top
    config.imagePadding = 4
    // UIButton.Configuration.plain()'s own default contentInsets are
    // ~14pt on the leading/trailing sides — that (not bottomTabBar's own
    // .spacing) is what actually dominates the visible gap between two
    // adjacent tab icons, since it's added on BOTH buttons flanking each
    // gap. Shrinking it here is what actually tightens the tray, not
    // further reductions to the stack's own spacing value.
    // Room for the selected-tool tile around icon + label.
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
    config.titleLineBreakMode = .byClipping
    config.background.cornerRadius = 14
    config.background.backgroundColor = .clear
    config.baseForegroundColor = EditorDesignTokens.Colors.textPrimary
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = EditorDesignTokens.Typography.trayLabel
      return outgoing
    }
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    // The title label's default horizontal compression-resistance
    // priority (250, low) let bottomTabBar's UIStackView squeeze a
    // two-word title like "Add Video" below its own intrinsic width and
    // truncate it — every other tray label is a single word and happened
    // to never hit this. .required forces the stack/scroll view to give
    // it its full natural width instead (the tray already scrolls, so
    // there's no downside to it needing a little more horizontal room).
    // Equal-width slots: a long label ("Add Video") shrinks a little to fit.
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.titleLabel?.minimumScaleFactor = 0.8
    return button
  }

  private static func styleTabButton(_ button: UIButton, selected: Bool) {
    guard var config = button.configuration else { return }
    // The sliding glass lens marks the selected tool (no tile); selected
    // is full white + semibold, the rest slightly dimmed — like Instagram.
    config.background.backgroundColor = .clear
    config.baseForegroundColor = selected ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.textPrimary.withAlphaComponent(0.78)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = selected
        ? .systemFont(ofSize: EditorDesignTokens.Typography.trayLabel.pointSize, weight: .semibold)
        : EditorDesignTokens.Typography.trayLabel
      return outgoing
    }
    button.configuration = config
    fitTabTitle(button)
  }

  /// Full tool name on one line — shrinks a little instead of "Fil…".
  /// Re-applied after every configuration change, which resets the
  /// title label's own fitting settings.
  private static func fitTabTitle(_ button: UIButton) {
    button.titleLabel?.numberOfLines = 1
    button.titleLabel?.lineBreakMode = .byClipping
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    // Slots are sized for the full name, so this only kicks in for an
    // unusually large Dynamic Type / bold-text setting.
    button.titleLabel?.minimumScaleFactor = 0.85
  }

  /// A small accent-colored pill, hidden (`alpha = 0`) until its tab is
  /// selected — see the 4 `...TabIndicator` properties. Pill (not a bare
  /// dot) so it echoes the app's other pill-shaped selected-state chrome
  /// (see CLAUDE.md's `pillSelected` token) while staying small enough to
  /// sit under a tray label without crowding it.
  private static func makeTabIndicatorDot() -> UIView {
    let dot = UIView()
    dot.backgroundColor = EditorDesignTokens.Colors.danger
    dot.layer.cornerRadius = 2
    dot.alpha = 0
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.widthAnchor.constraint(equalToConstant: 4).isActive = true
    dot.heightAnchor.constraint(equalToConstant: 4).isActive = true
    return dot
  }

  /// Pins `dot` centered under `button`'s own bottom edge (i.e. below its
  /// label) — safe to render outside the button's own bounds since
  /// `UIButton.clipsToBounds` defaults to false, and the tray has
  /// headroom below the button's content (see `bottomTrayHeight` vs. the
  /// button's own intrinsic content height).
  private static func attachTabIndicator(_ dot: UIView, to button: UIButton) {
    button.addSubview(dot)
    NSLayoutConstraint.activate([
      dot.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      dot.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 4),
    ])
  }

  /// Sized to the HIG/accessibility minimum tap target
  /// (`EditorDesignTokens.Spacing.minTapTarget`) even though the glyph
  /// itself renders at its natural, smaller size, centered — no per-icon
  /// background needed now that these sit directly on the solid `topBar`
  /// chrome strip.
  private static func makeTopBarIconButton(systemImageName: String) -> UIButton {
    let button = UIButton(type: .system)
    // The redesign's line icons (Images.xcassets ui_*, same drawings as
    // Android) replace these SF Symbols everywhere they're used.
    let redesigned: [String: String] = [
      "xmark": "ui_close", "checkmark": "ui_check",
      "arrow.uturn.backward": "ui_undo", "arrow.uturn.forward": "ui_redo",
      "square.split.2x1": "ui_compare",
    ]
    let image = redesigned[systemImageName].flatMap { UIImage(named: $0)?.withRenderingMode(.alwaysTemplate) }
      ?? UIImage(systemName: systemImageName)
    button.setImage(image, for: .normal)
    button.tintColor = EditorDesignTokens.Colors.textPrimary
    button.translatesAutoresizingMaskIntoConstraints = false
    let size = EditorDesignTokens.Spacing.minTapTarget
    button.widthAnchor.constraint(equalToConstant: size).isActive = true
    button.heightAnchor.constraint(equalToConstant: size).isActive = true
    return button
  }

  /// Plain text top-bar button (Cancel) — sized to its own content
  /// (with a comfortable minimum height for tap-ability) rather than a
  /// fixed square, unlike `makeTopBarIconButton`.
  private static func makeTopBarTextButton(title: String) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
    button.tintColor = EditorDesignTokens.Colors.textPrimary
    button.translatesAutoresizingMaskIntoConstraints = false
    button.heightAnchor.constraint(equalToConstant: EditorDesignTokens.Spacing.minTapTarget).isActive = true
    return button
  }

  init(
    sourceURL: URL,
    mediaType: String,
    musicTracks: [MusicTrack] = [],
    isStoryMode: Bool = false,
    editProject: MediaEditorEditProject? = nil,
    onCancel: @escaping () -> Void,
    onDone: @escaping (MediaEditorDoneOutcome) -> Void
  ) {
    self.pendingEditProject = editProject
    self.editProjectID = editProject?.id
    self.sourceURL = sourceURL
    self.mediaType = mediaType
    self.musicTracks = musicTracks
    self.isStoryMode = isStoryMode
    self.onCancel = onCancel
    self.onDone = onDone
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = EditorDesignTokens.Colors.canvasBackground
    // Music picker shows songs the moment it opens (video, photo, story).
    MusicAPI.prefetchTrending()

    // The app declares background audio (for the track player), so an
    // AVPlayer keeps playing after the app is minimised unless paused.
    NotificationCenter.default.addObserver(
      self, selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil
    )

    let isImage = mediaType == "image"

    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.isHidden = !isImage

    // Set the canvas's aspect ratio from the file's header (fast, no full
    // decode) BEFORE any layout pass can happen — text/sticker layer
    // positioning and export math both anchor to the canvas's own center,
    // so the box must already be at its final aspect-fit size before that
    // first layout, not resized into place later once the full
    // downsampled image finishes loading async.
    if isImage, let pixelSize = MediaEditorViewController.imagePixelSize(at: sourceURL), pixelSize.height > 0 {
      let constraint = canvasClipContainerView.widthAnchor.constraint(equalTo: canvasClipContainerView.heightAnchor, multiplier: pixelSize.width / pixelSize.height)
      constraint.isActive = true
      imageAspectConstraint = constraint
    }

    playerView.translatesAutoresizingMaskIntoConstraints = false
    playerView.isHidden = isImage
    playerView.backgroundColor = .black
    // Story mode fills/crops edge-to-edge (matches the aspect-fill canvas
    // sizing above); every other mode letterboxes within its box as before.
    playerView.playerLayer.videoGravity = isStoryMode ? .resizeAspectFill : .resizeAspect

    // Icon, not text — a plain SF Symbol swap (no separate asset needed)
    // is also far more compact than "Pause"/"Play" text, freeing width
    // back to the scrubber, per the user's explicit "make these into an
    // icon and increase the scrubber's width" request.
    playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
    playPauseButton.tintColor = .white
    playPauseButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold), forImageIn: .normal)
    playPauseButton.translatesAutoresizingMaskIntoConstraints = false
    playPauseButton.isHidden = isImage
    playPauseButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)
    playPauseButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)
    // Video redesign: play/pause sits on the same glass circle as the
    // top-bar controls, with "0:04 / 0:18" beside it.
    if !isImage && !isStoryMode {
      let glass = GlassSurfaceView.install(behind: playPauseButton, shape: .capsule)
      // The glass is a subview of the button itself — keep it under the
      // play/pause icon (it was drawing over it, leaving an empty circle).
      glass.layer.zPosition = -1
      glass.isUserInteractionEnabled = false
    }
    videoTimeLabel.translatesAutoresizingMaskIntoConstraints = false
    videoTimeLabel.isHidden = true
    videoTimeLabel.isUserInteractionEnabled = false

    videoTrimView.translatesAutoresizingMaskIntoConstraints = false
    videoTrimView.isHidden = isImage
    // Scrubbing is now driven by filmstripScrollView's own native
    // panning (see the scrollable-timeline doc above videoTrimView's
    // width constraint below) — onScrub never fires for filmstrip style
    // any more (see VideoTrimView's own doc), so no closure is wired here.
    videoTrimView.onSegmentsChanged = { [weak self] segments in
      self?.videoSegments = segments
      self?.updateFilmstripLayout()
    }
    videoTrimView.onHandleDragStateChanged = { [weak self] isDragging in
      self?.filmstripScrollView.isScrollEnabled = !isDragging
    }
    // Tapping a video segment and tapping a layer's own timeline row are
    // two different "what should Delete act on" contexts — deselecting
    // any layer here means a stale prior layer selection can never
    // silently steal a delete meant for the video segment the user just
    // tapped (see didTapDeleteSegment's own routing).
    videoTrimView.onSegmentSelected = { [weak self] _ in
      self?.isVoiceRowSelected = false
      self?.deselectLayer()
      self?.selectedMergedClipURL = nil
      self?.selectedMergedClipSegmentIndex = nil
      self?.selectedMusicSegmentIndex = nil
      self?.updateLayerStateButtons()
    }

    // See mergedStripView's own property doc — this is set up ONCE here
    // (closures included) and persists across every add/remove/trim, unlike
    // the old makeAdditionalClipsRow which rebuilt a fresh instance (and
    // fresh closures) every time.
    mergedStripView.translatesAutoresizingMaskIntoConstraints = false
    mergedStripView.isHidden = true
    mergedStripView.isMergedClipsContinuation = true
    // newStart/newEnd arrive in the bar's own COMPACTED coordinate space
    // (see refreshMergedClipsStrip's doc) — the matching entry in
    // mergedClipSegmentAnchors[url] is THIS segment's own fixed slot
    // start as of the last refresh, so (newStart - anchor) is a DELTA
    // from that slot's original edges, not an absolute real time. Adding
    // that delta to the STABLE reference segment (captured at the same
    // refresh, not the live-mutating additionalClipSegments dict)
    // correctly handles both drag types this row allows (edge-drag only —
    // allowBodyDrag is never set for mergedStripView): a START/END edge
    // drag moves only that one delta. Clamped against this clip's OWN
    // immediately adjacent segment (if any) so dragging one segment's
    // edge can never cross into a neighboring segment's own space and
    // corrupt the resulting composition's time-range insertion order —
    // mirrors VideoTrimView's own single-item "first segment's start /
    // last segment's end only" scope cut, just enforced via clamping
    // here instead since LayerRangeBarView already lets every segment's
    // own edges drag independently (the same capability layer segments
    // already rely on).
    mergedStripView.onRangeChanged = { [weak self] id, segmentIndex, newStart, newEnd in
      guard let self, let url = self.additionalVideoClipURLs.first(where: { ObjectIdentifier(self.proxyView(for: $0)) == id }),
            let referenceSegments = self.mergedClipReferenceSegments[url], referenceSegments.indices.contains(segmentIndex),
            let anchors = self.mergedClipSegmentAnchors[url], anchors.indices.contains(segmentIndex)
      else { return }
      let fullDuration = self.additionalClipDurations[url] ?? 5
      let anchor = anchors[segmentIndex]
      let referenceSegment = referenceSegments[segmentIndex]
      let referenceLength = referenceSegment.upperBound - referenceSegment.lowerBound
      let floor = segmentIndex > 0 ? referenceSegments[segmentIndex - 1].upperBound : 0
      let ceiling = segmentIndex < referenceSegments.count - 1 ? referenceSegments[segmentIndex + 1].lowerBound : fullDuration
      var newLocalStart = max(floor, min(referenceSegment.lowerBound + (newStart - anchor), fullDuration))
      var newLocalEnd = max(newLocalStart, min(referenceSegment.upperBound + (newEnd - (anchor + referenceLength)), fullDuration))
      newLocalStart = min(newLocalStart, ceiling)
      newLocalEnd = min(newLocalEnd, ceiling)
      guard var segments = self.additionalClipSegments[url], segments.indices.contains(segmentIndex) else { return }
      segments[segmentIndex] = newLocalStart...newLocalEnd
      self.additionalClipSegments[url] = segments
      self.updateFilmstripLayout()
    }
    // Tracks which SEGMENT of the active merged clip was last tapped —
    // the Delete button's target, mirroring videoTrimView's own
    // onSegmentSelected wiring. Which CLIP is "active" (yellow border,
    // trimmable, deletable-as-a-whole) is still driven entirely by
    // scroll position (see updateActiveClipHighlight) — this is only
    // about WHICH of that clip's own segments Split/Delete should target.
    mergedStripView.onItemSelected = { [weak self] id, segmentIndex in
      guard let self, let url = self.additionalVideoClipURLs.first(where: { ObjectIdentifier(self.proxyView(for: $0)) == id }) else { return }
      self.deselectLayer()
      self.videoTrimView.clearSegmentSelection()
      self.selectedMergedClipURL = url
      self.selectedMergedClipSegmentIndex = segmentIndex
      self.selectedMusicSegmentIndex = nil
      self.isVoiceRowSelected = false
      self.updateLayerStateButtons()
    }
    // Deferred to drag-END (not every onRangeChanged tick) so the
    // AVQueuePlayer isn't torn down and rebuilt dozens of times per second
    // while the user is still actively dragging. Also re-packs every
    // item's anchor from the now-settled trims, immediately closing any
    // gap the drag just opened rather than leaving it until some other,
    // unrelated refresh happens to fire.
    mergedStripView.onDragEnded = { [weak self] in
      self?.rebuildVideoQueue(startPlaying: false)
      self?.refreshMergedClipsStrip()
    }
    mergedStripView.onHandleDragStateChanged = { [weak self] isDragging in
      guard let self else { return }
      // Explicitly disabling the pan gesture recognizer itself (not just
      // isScrollEnabled, which only prevents FUTURE recognition attempts)
      // forces it to immediately cancel even if it already started
      // evaluating this exact touch — per the user's "long press then
      // drag does nothing" report: with a 0.45s long-press hold before
      // reorder mode engages, there's ample time for the scroll view's
      // own pan gesture to have already begun tracking the touch, and
      // toggling isScrollEnabled alone can lose that race.
      self.filmstripScrollView.panGestureRecognizer.isEnabled = !isDragging
      self.filmstripScrollView.isScrollEnabled = !isDragging
    }
    // Long-press + vertical drag reorders merged video clips relative to
    // each other — per the user's explicit "if i want to reorder video
    // clips in layers... i can by long press on these element and drag
    // it" request.
    mergedStripView.onReorderSwap = { [weak self] a, b in
      guard let self,
            let urlA = self.additionalVideoClipURLs.first(where: { ObjectIdentifier(self.proxyView(for: $0)) == a }),
            let urlB = self.additionalVideoClipURLs.first(where: { ObjectIdentifier(self.proxyView(for: $0)) == b }),
            let idxA = self.additionalVideoClipURLs.firstIndex(of: urlA),
            let idxB = self.additionalVideoClipURLs.firstIndex(of: urlB)
      else { return }
      self.additionalVideoClipURLs.swapAt(idxA, idxB)
    }
    mergedStripView.onReorderEnded = { [weak self] in
      self?.rebuildVideoQueue(startPlaying: false)
      self?.refreshMergedClipsStrip()
    }

    // MARK: Instagram-style scrollable combined timeline — see
    // timelinePointsPerSecond's own doc for the overall design.
    filmstripScrollView.translatesAutoresizingMaskIntoConstraints = false
    filmstripScrollView.isHidden = isImage
    filmstripScrollView.delegate = self
    filmstripScrollView.showsHorizontalScrollIndicator = false
    filmstripScrollView.decelerationRate = .fast

    filmstripPlayheadView.translatesAutoresizingMaskIntoConstraints = false
    filmstripPlayheadView.isHidden = isImage
    filmstripPlayheadView.backgroundColor = .white
    filmstripPlayheadView.isUserInteractionEnabled = false

    splitSegmentButton.setImage(UIImage(systemName: "scissors"), for: .normal)
    splitSegmentButton.tintColor = .white
    splitSegmentButton.translatesAutoresizingMaskIntoConstraints = false
    splitSegmentButton.isHidden = isImage
    splitSegmentButton.addTarget(self, action: #selector(didTapSplitSegment), for: .touchUpInside)
    splitSegmentButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)

    deleteSegmentButton.setImage(UIImage(systemName: "trash"), for: .normal)
    deleteSegmentButton.tintColor = .white
    deleteSegmentButton.translatesAutoresizingMaskIntoConstraints = false
    deleteSegmentButton.isHidden = isImage
    deleteSegmentButton.addTarget(self, action: #selector(didTapDeleteSegment), for: .touchUpInside)
    deleteSegmentButton.addTarget(self, action: #selector(hapticMedium), for: .touchUpInside)

    videoControlsBackdropView.translatesAutoresizingMaskIntoConstraints = false
    videoControlsBackdropView.backgroundColor = .clear
    videoControlsBackdropView.isUserInteractionEnabled = false
    videoControlsBackdropView.isHidden = isImage
    layerTracksScrollView.isHidden = isImage
    layerTracksScrollView.showsVerticalScrollIndicator = false
    // Only ever scrolls vertically by the user's own touch (many stacked
    // rows overflowing the height cap) — its HORIZONTAL position is
    // mirrored to/from filmstripScrollView instead (see scrollViewDidScroll),
    // so a drag on either one keeps both in sync.
    layerTracksScrollView.showsHorizontalScrollIndicator = false
    // No rubber-band bounce, and a swipe scrolls one axis at a time — the
    // rows felt "bouncy" (drifting up/down during a sideways scroll).
    layerTracksScrollView.bounces = false
    // Deliver touches to the layer bars immediately — with the default
    // delay, a quick drag on a layer's edge was taken as a timeline scroll
    // and only a press-and-hold actually trimmed. A body swipe still
    // scrolls (the pan cancels the bar's touch once it moves).
    layerTracksScrollView.delaysContentTouches = false
    layerTracksScrollView.isDirectionalLockEnabled = true
    layerTracksScrollView.delegate = self
    if mediaType != "image" && !isStoryMode {
      for scrollView in [filmstripScrollView, layerTracksScrollView] {
        scrollView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handleTimelinePinch(_:))))
        // Two fingers pinch (zoom) rather than scroll.
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
      }
    }

    layersAreaCollapseButton.translatesAutoresizingMaskIntoConstraints = false
    layersAreaCollapseButton.tintColor = EditorDesignTokens.Colors.textSecondary
    // Video redesign: "Layers · N ⌃" pill (title set in
    // updateLayersAreaExpansion), chevron on the right.
    layersAreaCollapseButton.setTitleColor(EditorDesignTokens.Colors.textSecondary, for: .normal)
    layersAreaCollapseButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    layersAreaCollapseButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold), forImageIn: .normal)
    layersAreaCollapseButton.semanticContentAttribute = .forceRightToLeft
    layersAreaCollapseButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
    layersAreaCollapseButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 14)
    layersAreaCollapseButton.isHidden = true
    layersAreaCollapseButton.addTarget(self, action: #selector(didTapToggleLayersArea), for: .touchUpInside)

    // "+" add-layer icon — plain white glyph, same style as the scissors
    // and trash beside it (user asked to drop the blue "+ Layer" capsule).
    addLayerButton.setImage(UIImage(systemName: "plus"), for: .normal)
    addLayerButton.tintColor = .white
    addLayerButton.translatesAutoresizingMaskIntoConstraints = false
    addLayerButton.accessibilityLabel = "Add a new layer"
    addLayerButton.isHidden = true
    addLayerButton.addTarget(self, action: #selector(didTapAddLayer), for: .touchUpInside)
    for (button, action) in [(layerHideButton, #selector(didTapToggleLayerHidden)), (layerLockButton, #selector(didTapToggleLayerLocked)),
                             (clipVolumeButton, #selector(didTapClipVolume)),
                             (clipSpeedButton, #selector(didTapClipSpeed)), (clipTransitionButton, #selector(didTapClipTransition)),
                             (textAnimationButton, #selector(didTapTextAnimation))] {
      button.tintColor = .white
      button.translatesAutoresizingMaskIntoConstraints = false
      button.isHidden = true
      button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .medium), forImageIn: .normal)
      button.addTarget(self, action: action, for: .touchUpInside)
    }

    loadingIndicator.color = .white
    loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

    // Fixed-frame, never-transformed wrapper around imageView/playerView —
    // clipsToBounds=true hard-clips their content to the canvas box's own
    // screen rect, per the user's explicit "zoomed image should not
    // display outside of that cropper box" report. This MUST be a separate
    // ancestor, not clipsToBounds on imageView/playerView themselves:
    // CALayer clipping is computed in the layer's own (untransformed)
    // bounds space and is carried along BY the same transform as its
    // content, so a scaled-up imageView clipping to its own bounds would
    // clip proportionally with the zoom and never actually stop the
    // overflow. A plain, never-transformed parent clips in real screen
    // space regardless of how much its child is zoomed/rotated/panned.
    canvasClipContainerView.translatesAutoresizingMaskIntoConstraints = false
    canvasClipContainerView.clipsToBounds = true
    // Per the user's explicit CapCut-reference "container with border
    // radius" request — a fixed point value applies correctly regardless
    // of the container's own current size, so this needs setting once,
    // not re-applied on every updateCanvasSizeForLayers resize.
    // Story mode is edge-to-edge full-bleed (per the user's explicit
    // "fully covered by camera preview, remove yellow border and black
    // background" request) — no rounded corners, no yellow selection
    // border there at all; see also updateCanvasSelectionBorder's own doc.
    canvasClipContainerView.layer.cornerRadius = isStoryMode ? 0 : 16
    view.addSubview(canvasClipContainerView)
    canvasClipContainerView.addSubview(imageView)
    canvasClipContainerView.addSubview(playerView)
    view.addSubview(videoControlsBackdropView)
    view.addSubview(layerTracksScrollView)
    view.addSubview(layersAreaCollapseButton)
    view.addSubview(addLayerButton)
    view.addSubview(layerHideButton)
    view.addSubview(layerLockButton)
    clipVolumeButton.setImage(UIImage(systemName: "speaker.wave.2"), for: .normal)
    clipVolumeButton.accessibilityLabel = "Clip volume"
    view.addSubview(clipVolumeButton)
    clipSpeedButton.setImage(UIImage(systemName: "gauge.with.dots.needle.67percent") ?? UIImage(systemName: "speedometer"), for: .normal)
    clipSpeedButton.accessibilityLabel = "Clip speed"
    view.addSubview(clipSpeedButton)
    clipTransitionButton.setImage(UIImage(systemName: "square.on.square.intersection.dashed") ?? UIImage(systemName: "square.on.square"), for: .normal)
    clipTransitionButton.accessibilityLabel = "Transition into this clip"
    view.addSubview(clipTransitionButton)
    textAnimationButton.setImage(UIImage(systemName: "wand.and.stars"), for: .normal)
    textAnimationButton.accessibilityLabel = "Text animation"
    view.addSubview(textAnimationButton)
    view.addSubview(loadingIndicator)
    view.addSubview(playPauseButton)
    view.addSubview(videoTimeLabel)
    // Video redesign: what Split/Delete will act on ("Clip 2", "Text"…).
    videoSelectionLabel.translatesAutoresizingMaskIntoConstraints = false
    videoSelectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
    videoSelectionLabel.textColor = EditorDesignTokens.Colors.selectedToolTint
    videoSelectionLabel.isHidden = true
    view.addSubview(videoSelectionLabel)
    view.addSubview(filmstripScrollView)
    filmstripScrollView.addSubview(videoTrimView)
    filmstripScrollView.addSubview(mergedStripView)
    // Above filmstripScrollView (added right after it, before split/delete)
    // so it's never accidentally covered, but still gets re-fronted
    // defensively in keepSafeAreaCoversOnTop like every other video control.
    view.addSubview(filmstripPlayheadView)
    view.addSubview(splitSegmentButton)
    view.addSubview(deleteSegmentButton)

    // Built before the canvas constraints below so the canvas's own bottom
    // edge can anchor above bottomTrayScrollView (giving the canvas a
    // dedicated, non-overlapping area above the bottom controls, per the
    // user's explicit reference-screenshot request, now shared by video
    // too per their explicit "same UI as the image editor" request) —
    // bottomTrayScrollView must already be in the view hierarchy for that
    // anchor reference to resolve.
    setUpEditingControls()

    let safe = view.safeAreaLayoutGuide

    // Both media types get the same dedicated content area — margin on all
    // sides, stopping above the bottom tray only. This is imageContentAreaGuide's
    // OWN bottom, used to position the video-controls band itself
    // (filmstripScrollView/videoControlsBackdropView, both anchored to it
    // directly, NOT to the canvas — see their own constraints below); the
    // CANVAS instead sizes against the separate, narrower
    // canvasContentAreaGuide (see its own doc) so it can never extend
    // into the space this band occupies. Previously the video-controls
    // band floated as an overlay directly on the canvas's own bottom edge
    // (per an earlier "display these layer above video layer" request);
    // per the user's LATER, explicit "video editor and layers portion to
    // be completely separate... video should be always above that
    // section, not below these editor tools" request, that's no longer
    // the case.
    //
    // effectPanel/editPanel/stickersPanel/drawPanel/musicPanel are ALL
    // toggleable panels (Filters/Adjust used to be an always-visible
    // strip; per the user's explicit "major change" request they're now
    // gated behind their own tabs) — each is a SlideUpPanelView that can
    // expand well past its collapsed height via its drag handle, and that
    // expansion is deliberately an OVERLAY on top of the canvas, not a
    // resize of it: unlike the video-controls band (which now DOES
    // reserve real space, and DOES trigger a real canvas resize — see
    // updateCanvasSizeForLayers), these panels stay pure overlays.
    view.addLayoutGuide(imageContentAreaGuide)
    view.addLayoutGuide(canvasContentAreaGuide)
    // Photo: the picture runs down behind the floating glass tool row
    // (only the LOOKS · TOOLS · EXPORT bar is reserved), like Instagram's
    // bar over the feed. Video keeps its controls band, so it still stops
    // above the row.
    let reservedBottomChromeHeight = (isImage && !isStoryMode)
      ? EditorDesignTokens.Spacing.lookToolsBarHeight
      : trayHeight + lookToolsBarHeight
    // Margin kept intentionally small — user's explicit "make the cropper
    // very close to left/right of screen" request (was 20, still non-zero
    // so the border/handles never touch the physical screen edge).
    let contentAreaHorizontalMargin: CGFloat = 4
    // Story mode is edge-to-edge full-bleed — imageContentAreaGuide spans
    // the whole view instead of the safe-area-inset "content area" used by
    // the normal chrome (topBar/bottom tray are hidden in story mode, see
    // setUpEditingControls, but their layout footprint would otherwise
    // still be reserved here).
    var contentAreaConstraints: [NSLayoutConstraint] = [
      imageContentAreaGuide.topAnchor.constraint(equalTo: isStoryMode ? view.topAnchor : topBar.bottomAnchor),
      imageContentAreaGuide.leadingAnchor.constraint(
        equalTo: isStoryMode ? view.leadingAnchor : safe.leadingAnchor,
        constant: isStoryMode ? 0 : contentAreaHorizontalMargin
      ),
      imageContentAreaGuide.trailingAnchor.constraint(
        equalTo: isStoryMode ? view.trailingAnchor : safe.trailingAnchor,
        constant: isStoryMode ? 0 : -contentAreaHorizontalMargin
      ),
      imageContentAreaGuide.bottomAnchor.constraint(
        equalTo: isStoryMode ? view.bottomAnchor : safe.bottomAnchor,
        constant: isStoryMode ? 0 : -reservedBottomChromeHeight
      ),

      // canvasContentAreaGuide shares imageContentAreaGuide's top/
      // leading/trailing exactly, but reserves EXTRA space at the bottom
      // (video only) for the video-controls band — see its own doc for
      // why the canvas sizes against THIS guide, not imageContentAreaGuide
      // directly, now.
      canvasContentAreaGuide.topAnchor.constraint(equalTo: imageContentAreaGuide.topAnchor),
      canvasContentAreaGuide.leadingAnchor.constraint(equalTo: imageContentAreaGuide.leadingAnchor),
      canvasContentAreaGuide.trailingAnchor.constraint(equalTo: imageContentAreaGuide.trailingAnchor),
      // Pinned to layersAreaCollapseButton's own DYNAMIC top (not a fixed
      // constant) — per the user's explicit "video preview is half cut in
      // the bottom" report with 3+ layer-type rows (text+sticker+music)
      // stacked: the old fixed-height reservation only ever accounted for
      // the filmstrip/Split-Delete row, never the layer-tracks panel's
      // own (variable, 0 to N rows) height, so a tall enough stack simply
      // overlapped the canvas. layersAreaCollapseButton already sits
      // directly above layerTracksScrollView and its OWN height already
      // tracks hasLayers (0 when empty), so its topAnchor is exactly "the
      // real top edge of everything below the canvas" regardless of how
      // many rows are currently stacked — mirrors Android's
      // updateCanvasSizeForLayers(tracksHeightPx:), which already
      // reserves the ACTUAL current tracks height rather than a guess.
      // Story mode always reserves ZERO here too (full-bleed); for VIDEO
      // specifically this is unverified on-device (the reference
      // screenshot that drove this fix was a photo) — the filmstrip/
      // layer-tracks band isn't hidden in story mode and may overlap the
      // now-full-screen canvas, needs a real device check.
      canvasContentAreaGuide.bottomAnchor.constraint(
        equalTo: (isImage || isStoryMode) ? imageContentAreaGuide.bottomAnchor : deleteSegmentButton.topAnchor,
        constant: (isImage || isStoryMode) ? 0 : -10
      ),

      // canvasClipContainerView (not imageView directly) sizes to
      // canvasContentAreaGuide — imageView/playerView are its children
      // and simply fill it exactly (below), so they inherit this sizing
      // while still being clipped by the container's own clipsToBounds.
      // Vertically CENTERED (not top-aligned) per the user's explicit
      // "landscape video displays at the top with empty space below,
      // ideally it should be centered" report. A prior fix had made this
      // top-aligned instead, per an earlier "empty space above, shift the
      // video container up" complaint — but that was for a portrait video
      // only marginally shorter than the guide (a small, evenly-split gap
      // was barely visible above and comparatively felt worse below); a
      // landscape video is dramatically shorter than a portrait guide, so
      // top-aligning it collects ALL of that much larger slack below the
      // box, pinning the video to the top exactly as reported. Centering
      // is the standard, orientation-agnostic behavior (matches CapCut/
      // Instagram-style editors) and keeps both cases reasonable: a small
      // top-align-vs-center difference is barely noticeable for the
      // portrait case, while landscape now sits correctly centered.
      canvasClipContainerView.centerXAnchor.constraint(equalTo: canvasContentAreaGuide.centerXAnchor),
      // -10 per the user's explicit "shift up by 20px" report, then
      // corrected down to 10px — the original 20 overshot. Story mode has
      // no bottom tray to offset away from, so it stays exactly centered.
      // Story: the X / Undo / Share row and the rail are overlays, so the
      // photo is centred on the whole screen (the guide spans the view).
      canvasClipContainerView.centerYAnchor.constraint(equalTo: canvasContentAreaGuide.centerYAnchor, constant: isStoryMode ? 0 : -10),
    ]
    // Story-mode VIDEO fills/crops the guide edge-to-edge (aspect-FILL,
    // cropping any overflow via clipsToBounds — per the user's explicit
    // "fully covered by camera preview" request). Story-mode IMAGES are
    // aspect-FIT like every other mode, so a photo is exported as-is
    // (never auto-cropped to the screen's shape) and a gallery pick and a
    // camera shot both reach the story viewer whole (see the
    // widthAsLargeAsPossible/heightAsLargeAsPossible doc just below for how
    // this combines with the required aspect-ratio constraint).
    if isStoryMode && !isImage {
      contentAreaConstraints.append(contentsOf: [
        canvasClipContainerView.widthAnchor.constraint(greaterThanOrEqualTo: canvasContentAreaGuide.widthAnchor),
        canvasClipContainerView.heightAnchor.constraint(greaterThanOrEqualTo: canvasContentAreaGuide.heightAnchor),
      ])
    } else {
      contentAreaConstraints.append(contentsOf: [
        canvasClipContainerView.widthAnchor.constraint(lessThanOrEqualTo: canvasContentAreaGuide.widthAnchor),
        canvasClipContainerView.heightAnchor.constraint(lessThanOrEqualTo: canvasContentAreaGuide.heightAnchor),
      ])
    }
    NSLayoutConstraint.activate(contentAreaConstraints)
    // Auto Layout's standard "fit as large as possible within maxW/maxH
    // while respecting an aspect ratio" recipe: both `==` constraints
    // below are individually satisfiable, but never both at once unless
    // the guide's own aspect ratio happens to match the media's — the
    // solver keeps whichever one the required aspect-ratio constraint
    // (image: added once the file loads, below; video: playerView simply
    // has no aspect constraint of its own and relies on its
    // .resizeAspect video gravity instead) allows, which is exactly
    // aspect-fit sizing of the box itself, not just the content within it.
    // (For story-mode video the box instead aspect-FILLS, per the >= constraints
    // just above — this same defaultHigh pair still drives it to grow as
    // large as possible, which combined with >= produces fill-and-crop.)
    let widthAsLargeAsPossible = canvasClipContainerView.widthAnchor.constraint(equalTo: canvasContentAreaGuide.widthAnchor)
    widthAsLargeAsPossible.priority = .defaultHigh
    let heightAsLargeAsPossible = canvasClipContainerView.heightAnchor.constraint(equalTo: canvasContentAreaGuide.heightAnchor)
    heightAsLargeAsPossible.priority = .defaultHigh
    canvasFullSizeConstraints = [widthAsLargeAsPossible, heightAsLargeAsPossible]
    NSLayoutConstraint.activate(canvasFullSizeConstraints)
    // Video has no file-header aspect ratio read up front the way images do
    // (imageAspectConstraint) — without a required aspect constraint of its
    // own, the 2 defaultHigh constraints above would just both win (filling
    // the guide exactly, a non-aspect-correct stretch) until
    // setUpVideoPlayer asserts the asset's real aspect ratio once its
    // natural size loads.

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: canvasClipContainerView.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: canvasClipContainerView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: canvasClipContainerView.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: canvasClipContainerView.bottomAnchor),

      playerView.topAnchor.constraint(equalTo: imageView.topAnchor),
      playerView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
      playerView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
      playerView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),

      // Anchored to imageContentAreaGuide's OWN fixed bottom edge (NOT
      // canvasClipContainerView's) — this whole row used to float as an
      // overlay directly on the canvas's own bottom edge (per an earlier
      // "display these layer above video layer" request), which both let
      // the video visually extend UNDER these controls AND made the
      // whole row move whenever the canvas resized (see
      // updateCanvasSizeForLayers). Per the user's later, explicit "video
      // editor and layers portion to be completely separate... video
      // should be always above that section, not below these editor
      // tools" request, this band now sits at a FIXED position instead —
      // canvasContentAreaGuide's own bottom reservation (see its doc) is
      // Play/pause used to flank this row (reserving left/right space
      // from it) but per the user's explicit
      // "keep play pause icon on left top same line we have keep trim and
      // delete in right top, ... utilise these left and right space from
      // layers, all layers should cover full width" request they moved up
      // to the top band instead (see their own constraints below), so the
      // scrubber now spans the full safe-area width, matching the fixed
      // "very close to the screen edge" margin already established for the
      // crop box (EditorDesignTokens' 4pt cropper margin).
      filmstripScrollView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 4),
      filmstripScrollView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -4),
      filmstripScrollView.bottomAnchor.constraint(equalTo: imageContentAreaGuide.bottomAnchor, constant: -12),
      filmstripScrollView.heightAnchor.constraint(equalToConstant: 48),

      videoTrimView.leadingAnchor.constraint(equalTo: filmstripScrollView.contentLayoutGuide.leadingAnchor),
      videoTrimView.topAnchor.constraint(equalTo: filmstripScrollView.contentLayoutGuide.topAnchor),
      videoTrimView.bottomAnchor.constraint(equalTo: filmstripScrollView.contentLayoutGuide.bottomAnchor),
      videoTrimView.heightAnchor.constraint(equalTo: filmstripScrollView.frameLayoutGuide.heightAnchor),

      mergedStripView.leadingAnchor.constraint(equalTo: videoTrimView.trailingAnchor),
      mergedStripView.topAnchor.constraint(equalTo: filmstripScrollView.contentLayoutGuide.topAnchor),
      mergedStripView.bottomAnchor.constraint(equalTo: filmstripScrollView.contentLayoutGuide.bottomAnchor),
      mergedStripView.trailingAnchor.constraint(equalTo: filmstripScrollView.contentLayoutGuide.trailingAnchor),

      // Extends UP through layerTracksScrollView too (not just
      // filmstripScrollView) — per the user's explicit "same [playhead]
      // line should display on all layers also" report: layerTracksScrollView
      // shares filmstripScrollView's exact leading/trailing edges and
      // scrolls in perfect lockstep with it (see scrollViewDidScroll), so
      // one continuous line at this shared centerX stays correctly
      // aligned to the same point in time across every row, text/sticker/
      // music included, not just the video filmstrip.
      filmstripPlayheadView.centerXAnchor.constraint(equalTo: filmstripScrollView.centerXAnchor),
      filmstripPlayheadView.topAnchor.constraint(equalTo: layerTracksScrollView.topAnchor),
      filmstripPlayheadView.bottomAnchor.constraint(equalTo: filmstripScrollView.bottomAnchor),
      filmstripPlayheadView.widthAnchor.constraint(equalToConstant: 2),

      // Per-layer track rows sit directly above the play/pause + scrubber
      // row — per the user's explicit reference screenshot (a real
      // Instagram/CapCut-style multi-track timeline), pinned to EXACTLY
      // the same leading/trailing edges as filmstripScrollView (not the
      // safe area independently) so their shared horizontal scroll
      // mirror (see scrollViewDidScroll) lines up with zero manual
      // margin arithmetic.
      layerTracksScrollView.leadingAnchor.constraint(equalTo: filmstripScrollView.leadingAnchor),
      layerTracksScrollView.trailingAnchor.constraint(equalTo: filmstripScrollView.trailingAnchor),
      layerTracksScrollView.bottomAnchor.constraint(equalTo: filmstripScrollView.topAnchor, constant: -8),

      // Split/Delete now sit at the TOP of the whole cluster (top-right),
      // not sandwiched between the layer tracks and the trim scrubber —
      // per the user's explicit "keep split and delete icon on top right
      // side of all layer, not in the middle" correction.
      deleteSegmentButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -4),
      // Video redesign: the "Layers · N" pill has its own row between
      // this play/split/delete row and the layer tracks.
      deleteSegmentButton.bottomAnchor.constraint(equalTo: layersAreaCollapseButton.topAnchor, constant: -2),
      deleteSegmentButton.widthAnchor.constraint(equalToConstant: 36),
      deleteSegmentButton.heightAnchor.constraint(equalToConstant: 36),

      splitSegmentButton.trailingAnchor.constraint(equalTo: deleteSegmentButton.leadingAnchor, constant: -12),
      splitSegmentButton.centerYAnchor.constraint(equalTo: deleteSegmentButton.centerYAnchor),
      splitSegmentButton.widthAnchor.constraint(equalToConstant: 36),
      splitSegmentButton.heightAnchor.constraint(equalToConstant: 36),

      // playPauseButton moved up to the same top band (left side, mirroring
      // Split/Delete on the right) per the user's
      // explicit "keep play pause icon on left top same line" request — it
      // used to sit beside the scrubber, reserving left space from every
      // layer track row below.
      playPauseButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
      playPauseButton.centerYAnchor.constraint(equalTo: deleteSegmentButton.centerYAnchor),
      playPauseButton.widthAnchor.constraint(equalToConstant: 40),
      playPauseButton.heightAnchor.constraint(equalToConstant: 40),

      videoTimeLabel.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10),
      // Left of compare (before/after), which sits just left of "+".
      videoSelectionLabel.trailingAnchor.constraint(equalTo: (isImage || isStoryMode || compareButton == nil) ? addLayerButton.leadingAnchor : compareButton!.leadingAnchor, constant: -8),
      videoSelectionLabel.centerYAnchor.constraint(equalTo: splitSegmentButton.centerYAnchor),
      videoSelectionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: videoTimeLabel.trailingAnchor, constant: 8),
      videoTimeLabel.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),

      // Collapse chevron sits in the same top band as Split/Delete,
      // centered — toggling between chevron.down (expanded — tap to
      // collapse) and chevron.up (collapsed — tap to re-expand) in
      // updateLayersAreaExpansion.
      layersAreaCollapseButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 4),
      // "+ Layer" sits in the play/split/delete row, left of the scissors
      // (user's request — it overlapped the filmstrip in its own row).
      addLayerButton.trailingAnchor.constraint(equalTo: splitSegmentButton.leadingAnchor, constant: -12),
      addLayerButton.centerYAnchor.constraint(equalTo: splitSegmentButton.centerYAnchor),
      addLayerButton.widthAnchor.constraint(equalToConstant: 36),
      addLayerButton.heightAnchor.constraint(equalToConstant: 36),
      layerLockButton.trailingAnchor.constraint(equalTo: (isImage || isStoryMode || compareButton == nil) ? addLayerButton.leadingAnchor : compareButton!.leadingAnchor, constant: -4),
      layerLockButton.centerYAnchor.constraint(equalTo: splitSegmentButton.centerYAnchor),
      layerLockButton.widthAnchor.constraint(equalToConstant: 34),
      layerLockButton.heightAnchor.constraint(equalToConstant: 36),
      layerHideButton.trailingAnchor.constraint(equalTo: layerLockButton.leadingAnchor, constant: -2),
      layerHideButton.centerYAnchor.constraint(equalTo: splitSegmentButton.centerYAnchor),
      layerHideButton.widthAnchor.constraint(equalToConstant: 34),
      layerHideButton.heightAnchor.constraint(equalToConstant: 36),
      // Same slots as lock / eye.
      clipVolumeButton.trailingAnchor.constraint(equalTo: layerLockButton.trailingAnchor),
      clipVolumeButton.centerYAnchor.constraint(equalTo: splitSegmentButton.centerYAnchor),
      clipVolumeButton.widthAnchor.constraint(equalToConstant: 34),
      clipVolumeButton.heightAnchor.constraint(equalToConstant: 36),
      // Speed sits in the eye button's slot (Duplicate was removed).
      clipSpeedButton.trailingAnchor.constraint(equalTo: layerLockButton.trailingAnchor),
      clipSpeedButton.centerYAnchor.constraint(equalTo: splitSegmentButton.centerYAnchor),
      clipSpeedButton.widthAnchor.constraint(equalToConstant: 34),
      clipSpeedButton.heightAnchor.constraint(equalToConstant: 36),
      layersAreaCollapseButton.bottomAnchor.constraint(equalTo: layerTracksScrollView.topAnchor, constant: -4),
      layersAreaCollapseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

      loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    let layersAreaCollapseButtonHeight = layersAreaCollapseButton.heightAnchor.constraint(equalToConstant: 0)
    layersAreaCollapseButtonHeight.isActive = true
    layersAreaCollapseButtonHeightConstraint = layersAreaCollapseButtonHeight

    // Fixed-pixel widths (constants mutated in place by
    // updateFilmstripLayout, not recreated — no ratio/multiplier involved
    // any more now that the scroll view, not a proportional split, is
    // what fits arbitrary total durations into the available screen
    // space).
    let videoTrimViewWidth = videoTrimView.widthAnchor.constraint(equalToConstant: 100)
    let mergedStripViewWidth = mergedStripView.widthAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([videoTrimViewWidth, mergedStripViewWidth])
    videoTrimViewWidthConstraint = videoTrimViewWidth
    mergedStripViewWidthConstraint = mergedStripViewWidth
    updateFilmstripLayout()

    // "As large as possible up to a hard cap" while expanded — same
    // priority trick as canvasClipContainerView's own aspect-fit sizing:
    // 0 layers (or collapsed — see layerTracksCollapsedConstraint) forces
    // 0 height (no empty gap above the trim scrubber), and there are at
    // most 3 rows now (Text/Stickers/Overlay — see refreshLayersPanel),
    // so the cap only needs to comfortably fit exactly 3 of them; it
    // exists purely as a backstop, not an expected everyday ceiling.
    // layerTracksStack is only ever added into layerTracksScrollView's
    // hierarchy for video (see the `if !isImage` block further down that
    // builds it) — for a still image it has no superview at all, so a
    // constraint tying its height to layerTracksScrollView's would fail
    // to activate ("no common ancestor") and crash. Image mode never
    // shows this scroll view (isHidden = isImage above), so it doesn't
    // need sizing against layerTracksStack there.
    if !isImage {
      let layerTracksHeightFit = layerTracksScrollView.heightAnchor.constraint(equalTo: layerTracksStack.heightAnchor)
      layerTracksHeightFit.priority = .defaultHigh
      // Raised from 110 per the user's explicit "increase height of that
      // view where we are displaying all layers" request — fits more
      // simultaneous rows before scrolling internally. Mirrors Android's
      // identical capPx increase.
      // At most 3 rows (36 + 6 spacing each) — more rows scroll inside
      // this area instead of shrinking the video preview further.
      let layerTracksHeightCap = layerTracksScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 3 * 36 + 2 * 6)
      NSLayoutConstraint.activate([layerTracksHeightFit, layerTracksHeightCap])
    }
    layerTracksCollapsedConstraint = layerTracksScrollView.heightAnchor.constraint(equalToConstant: 0)

    // Scrim spans from just above Split/Delete (the tallest element in
    // the top band, so it's always the one that determines how far up
    // the scrim needs to reach) down to imageContentAreaGuide's own FIXED
    // bottom edge (not the canvas's, which can now be smaller than this —
    // see canvasContentAreaGuide's own doc), so the whole floating
    // control cluster sits on a darkened/opaque band rather than directly
    // on raw video pixels — see updateLayersAreaExpansion for the
    // collapsed-vs-expanded look.
    NSLayoutConstraint.activate([
      videoControlsBackdropView.topAnchor.constraint(equalTo: deleteSegmentButton.topAnchor, constant: -6),
      videoControlsBackdropView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
      videoControlsBackdropView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
      videoControlsBackdropView.bottomAnchor.constraint(equalTo: imageContentAreaGuide.bottomAnchor),
    ])

    if isImage {
      loadingIndicator.startAnimating()
      let maxPixelSize = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
      MediaEditorViewController.loadDownsampledImage(from: sourceURL, maxPixelSize: maxPixelSize) { [weak self] image in
        self?.loadingIndicator.stopAnimating()
        self?.imageView.image = image
        self?.baseImage = image
        self?.applyImageAspectRatio(image)
        if let image { self?.renderFilterThumbnails(from: image) }
        if image != nil { self?.restoreEditProjectIfNeeded() }
      }
    } else {
      setUpVideoPlayer()
    }
    setUpTransformGestures()
    setUpGridOverlay()
    setUpDrawingCanvas()
    setUpBlurOverlay()
    setUpSafeAreaCovers()
    setUpCanvasGutterCovers()
    setUpSharedLayerGestures()
    // Establishes the correct initial z-order (gutters/safe-area covers
    // behind everything, then the video-controls band, then the tray,
    // then the 5 slide-up panels, then topBar frontmost — see this
    // function's own doc). Previously this was ONLY ever called
    // reactively, from later actions (add layer, split/delete segment,
    // reorder, entering Draw) — never once during initial setup. Since
    // `setUpEditingControls()` (adds the panels) runs BEFORE
    // `setUpCanvasGutterCovers()` above, the gutter covers' plain
    // insertion order left them sitting IN FRONT of the panels by
    // default — any slide-up panel (e.g. Stickers) opened before one of
    // those later actions happened to run would visibly get its
    // left/right edges painted over by the opaque gutter bars, exactly
    // matching the user's "bottom sheet is blocked by a black layer"
    // report.
    keepSafeAreaCoversOnTop()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    hasAppeared = true
    restoreEditProjectIfNeeded()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // filmstripScrollView's own visible width is only known once layout
    // has actually run — recomputing this defensively on every layout
    // pass is cheap (it early-exits once the inset already matches) and
    // correctly catches rotation/size-class changes.
    updateFilmstripContentInsetIfNeeded()
    rescaleLayersIfCanvasResized()
  }

  /// Disabled by default — enabled only while a layer is selected (see
  /// selectLayer/deselectLayer). `cancelsTouchesInView = false` on all 3:
  /// these sit on `view`, above every button in the editor (layer toolbar
  /// included, which is visible exactly when these are enabled), and pan/
  /// pinch/rotate recognizing alongside a button's own tap tracking is a
  /// real risk if not explicitly prevented — same category of concern
  /// already reasoned through for the canvas background-tap gesture.
  private func setUpSharedLayerGestures() {
    sharedLayerPanGesture.addTarget(self, action: #selector(handleSharedLayerPan(_:)))
    sharedLayerPinchGesture.addTarget(self, action: #selector(handleSharedLayerPinch(_:)))
    sharedLayerRotationGesture.addTarget(self, action: #selector(handleSharedLayerRotation(_:)))
    [sharedLayerPanGesture, sharedLayerPinchGesture, sharedLayerRotationGesture].forEach {
      $0.delegate = self
      $0.cancelsTouchesInView = false
      $0.isEnabled = false
      view.addGestureRecognizer($0)
    }
  }

  @objc private func handleSharedLayerPan(_ gesture: UIPanGestureRecognizer) {
    trackTransformGesture(gesture, for: selectedLayer)
    selectedLayer?.applyExternalPan(gesture, in: view)
  }

  @objc private func handleSharedLayerPinch(_ gesture: UIPinchGestureRecognizer) {
    trackTransformGesture(gesture, for: selectedLayer)
    selectedLayer?.applyExternalPinch(gesture)
  }

  @objc private func handleSharedLayerRotation(_ gesture: UIRotationGestureRecognizer) {
    trackTransformGesture(gesture, for: selectedLayer)
    selectedLayer?.applyExternalRotation(gesture)
  }

  // MARK: - Layer transform undo/redo
  //
  // A layer can be dragged/pinched/rotated via TWO independent gesture
  // paths (its own, while unselected; the VC's shared one, while
  // selected — see setOwnTransformGesturesEnabled's doc), and a single
  // physical two-finger gesture drives up to 3 recognizers (pan/pinch/
  // rotation) concurrently, each with its own begin/end timing. Tracking
  // membership in `activeTransformGestureIDs` (rather than a naive
  // "first .began / first .ended" counter) means the undo entry is
  // pushed exactly once per physical gesture, however many recognizers
  // and calls were involved, and the "before" snapshot is captured
  // before ANY of them has mutated the layer.
  private var transformGestureSnapshot: (layer: EditableLayerView, translation: CGPoint, scale: CGFloat, rotation: CGFloat)?
  private var activeTransformGestureIDs: Set<ObjectIdentifier> = []

  private func trackTransformGesture(_ gesture: UIGestureRecognizer, for layer: EditableLayerView?) {
    guard let layer else { return }
    let id = ObjectIdentifier(gesture)
    switch gesture.state {
    case .began:
      activeTransformGestureIDs.insert(id)
      if transformGestureSnapshot == nil {
        transformGestureSnapshot = (layer, layer.currentTranslation, layer.currentScale, layer.currentRotation)
      }
    case .ended, .cancelled, .failed:
      activeTransformGestureIDs.remove(id)
      if activeTransformGestureIDs.isEmpty {
        commitTransformGestureUndo()
      }
    default:
      break
    }
  }

  private func commitTransformGestureUndo() {
    guard let snapshot = transformGestureSnapshot else { return }
    transformGestureSnapshot = nil
    let layer = snapshot.layer
    let oldTranslation = snapshot.translation
    let oldScale = snapshot.scale
    let oldRotation = snapshot.rotation
    let newTranslation = layer.currentTranslation
    let newScale = layer.currentScale
    let newRotation = layer.currentRotation
    guard oldTranslation != newTranslation || oldScale != newScale || oldRotation != newRotation else { return }
    pushUndo(
      undo: { [weak layer] in
        layer?.applyInitialTransform(translation: oldTranslation, scale: oldScale, rotation: oldRotation)
      },
      redo: { [weak layer] in
        layer?.applyInitialTransform(translation: newTranslation, scale: newScale, rotation: newRotation)
      }
    )
  }

  /// `playerView` is always pinned to match `imageView`'s frame exactly
  /// (see the constraints above), so `imageView` alone is a sufficient
  /// reference for both media types — no isImage branching needed here.
  /// Rule-of-thirds grid — 2 vertical + 2 horizontal lines dividing the
  /// canvas into thirds — per the user's explicit request (was a single
  /// center crosshair). `v1`/`v2` sit at 1/3 and 2/3 of the canvas width,
  /// `h1`/`h2` at 1/3 and 2/3 of its height; the old-style
  /// `NSLayoutConstraint(item:attribute:...)` initializer is used (rather
  /// than the type-safe anchor API) specifically because it's the only way
  /// to relate a position attribute (`.centerX`/`.centerY`) to a dimension
  /// attribute (`.width`/`.height`) with a fractional multiplier — the
  /// standard Auto Layout technique for "place a view at X% across its
  /// parent."
  /// **Fixed a real crash**: the first version of this method positioned
  /// the grid lines at 1/3 and 2/3 across the canvas using
  /// `NSLayoutConstraint(item:attribute:...)` to relate a POSITION
  /// attribute (`.centerX`/`.centerY`) directly to a SIZE attribute
  /// (`.width`/`.height`) with a fractional multiplier. That combination
  /// is rejected at RUNTIME by Auto Layout's `ResolveConstraintArguments`
  /// (an uncaught `NSInvalidArgumentException` → abort) — Swift's
  /// type-safe anchor API doesn't even expose a way to write this, which
  /// in hindsight was the signal this wasn't actually valid, not just an
  /// API inconvenience to route around. This crashed on EVERY app launch,
  /// in `viewDidLoad`, not anything specific to a later user action.
  ///
  /// Fixed by using 2 invisible `UILayoutGuide`s that each claim exactly
  /// 1/3 of the width (via `widthAnchor.constraint(equalTo:multiplier:)` —
  /// both sides are DIMENSION anchors, a legitimate combination, this is
  /// the standard aspect-ratio-constraint pattern) and positioning each
  /// line at a guide boundary (`centerXAnchor.constraint(equalTo:
  /// someGuide.trailingAnchor)` — both sides are POSITION anchors on the
  /// same axis, also legitimate). Same trick for the 2 horizontal lines,
  /// with height instead of width.
  private func setUpGridOverlay() {
    // Story mode has no grid/border guide at all — the story fills the
    // screen edge to edge, like Instagram. The view itself is still
    // inserted below (drawingCanvasView is layered relative to it).
    let showsGuide = mediaType == "image" && !isStoryMode
    gridOverlayView.isUserInteractionEnabled = false
    gridOverlayView.backgroundColor = .clear
    gridOverlayView.translatesAutoresizingMaskIntoConstraints = false
    // Border + rule-of-thirds lines are IMAGE ONLY now — per the user's
    // explicit "remove grid from video player of editor" request
    // (matches Android, which only ever created its own GridOverlayView
    // for the image branch). gridOverlayView itself still gets inserted
    // and pinned to the canvas box's edges unconditionally below —
    // setUpDrawingCanvas() inserts drawingCanvasView
    // `aboveSubview: gridOverlayView`, which silently does nothing if
    // gridOverlayView were never added to the hierarchy at all, so this
    // view must stay present (just visually empty) for a video session.
    if showsGuide {
      // Border tracing the canvas box's own edge — purely a visual crop-
      // boundary aid, per the user's explicit request ("add border layer...
      // so user should understand which is cropper border so where image
      // get cropped"). gridOverlayView is already pinned exactly to
      // imageView's/playerView's bounds (see constraints below), which IS
      // the crop rect export already crops to — a CALayer border on this
      // same view traces that boundary with no separate crop-frame state
      // needed.
      // Same alpha as the grid lines below — user's explicit "make these
      // lines faded (ALL)" follow-up, then lightened further (0.5 -> 0.3)
      // per their next round of feedback.
      gridOverlayView.layer.borderWidth = 2
      gridOverlayView.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
    }
    view.insertSubview(gridOverlayView, aboveSubview: canvasClipContainerView)

    NSLayoutConstraint.activate([
      gridOverlayView.topAnchor.constraint(equalTo: imageView.topAnchor),
      gridOverlayView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
      gridOverlayView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
      gridOverlayView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
    ])

    guard showsGuide else { return }

    let v1 = UIView()
    let v2 = UIView()
    let h1 = UIView()
    let h2 = UIView()
    [v1, v2, h1, h2].forEach {
      $0.backgroundColor = UIColor.white.withAlphaComponent(0.3)
      $0.translatesAutoresizingMaskIntoConstraints = false
      gridOverlayView.addSubview($0)
    }

    let leftThird = UILayoutGuide()
    let middleThird = UILayoutGuide()
    let topThird = UILayoutGuide()
    let middleThirdV = UILayoutGuide()
    [leftThird, middleThird, topThird, middleThirdV].forEach { gridOverlayView.addLayoutGuide($0) }

    NSLayoutConstraint.activate([
      // Two 1/3-width guides, chained left to right — v1/v2 sit exactly
      // at their trailing edges (1/3 and 2/3 across).
      leftThird.leadingAnchor.constraint(equalTo: gridOverlayView.leadingAnchor),
      leftThird.widthAnchor.constraint(equalTo: gridOverlayView.widthAnchor, multiplier: 1.0 / 3.0),
      middleThird.leadingAnchor.constraint(equalTo: leftThird.trailingAnchor),
      middleThird.widthAnchor.constraint(equalTo: gridOverlayView.widthAnchor, multiplier: 1.0 / 3.0),

      // Same idea for the 2 horizontal lines, using height instead.
      topThird.topAnchor.constraint(equalTo: gridOverlayView.topAnchor),
      topThird.heightAnchor.constraint(equalTo: gridOverlayView.heightAnchor, multiplier: 1.0 / 3.0),
      middleThirdV.topAnchor.constraint(equalTo: topThird.bottomAnchor),
      middleThirdV.heightAnchor.constraint(equalTo: gridOverlayView.heightAnchor, multiplier: 1.0 / 3.0),

      v1.centerXAnchor.constraint(equalTo: leftThird.trailingAnchor),
      v1.topAnchor.constraint(equalTo: gridOverlayView.topAnchor),
      v1.bottomAnchor.constraint(equalTo: gridOverlayView.bottomAnchor),
      v1.widthAnchor.constraint(equalToConstant: 1),

      v2.centerXAnchor.constraint(equalTo: middleThird.trailingAnchor),
      v2.topAnchor.constraint(equalTo: gridOverlayView.topAnchor),
      v2.bottomAnchor.constraint(equalTo: gridOverlayView.bottomAnchor),
      v2.widthAnchor.constraint(equalToConstant: 1),

      h1.centerYAnchor.constraint(equalTo: topThird.bottomAnchor),
      h1.leadingAnchor.constraint(equalTo: gridOverlayView.leadingAnchor),
      h1.trailingAnchor.constraint(equalTo: gridOverlayView.trailingAnchor),
      h1.heightAnchor.constraint(equalToConstant: 1),

      h2.centerYAnchor.constraint(equalTo: middleThirdV.bottomAnchor),
      h2.leadingAnchor.constraint(equalTo: gridOverlayView.leadingAnchor),
      h2.trailingAnchor.constraint(equalTo: gridOverlayView.trailingAnchor),
      h2.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  /// Pinned to imageView's own edges — same technique as gridOverlayView
  /// (which is why a stroke's on-screen point already matches imageView's
  /// own local space with no extra offset needed at export time, unlike
  /// text/sticker/overlay layers). Image only — video (mediaType != image)
  /// never activates the Draw tab, matching the precedent already accepted
  /// for Vignette/Sharpen/Overlay.
  ///
  /// `isUserInteractionEnabled` starts false — toggled true only while the
  /// Draw tab is active (see updateImageEditorUI), so it doesn't intercept
  /// any touches otherwise. While active, updateImageEditorUI also brings
  /// it to the front of `view`'s subviews — it's added here early (right
  /// after the grid), so without that it would sit BEHIND any text/sticker/
  /// overlay layer added later at runtime, and lose hit-testing priority to
  /// them.
  private func setUpDrawingCanvas() {
    drawingCanvasView.isUserInteractionEnabled = false
    drawingCanvasView.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(drawingCanvasView, aboveSubview: gridOverlayView)
    NSLayoutConstraint.activate([
      drawingCanvasView.topAnchor.constraint(equalTo: imageView.topAnchor),
      drawingCanvasView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
      drawingCanvasView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
      drawingCanvasView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
    ])
    drawingCanvasView.onStrokeFinished = { [weak self] stroke in
      self?.pushUndo(
        undo: { [weak self] in self?.drawingCanvasView.removeStroke(stroke) },
        redo: { [weak self] in self?.drawingCanvasView.addStroke(stroke) }
      )
    }
  }

  /// Toggles every EXISTING text/sticker/overlay layer's OWN pan/pinch/
  /// rotate (tap/long-press always stay active) — needed only while the
  /// Draw tab is active: unlike Android (where every touch funnels through
  /// one shared LayerGestureCoordinator that drawingCanvasRef simply
  /// intercepts before it), each iOS layer owns independent gesture
  /// recognizers that keep working regardless of which view is topmost, so
  /// without this an existing layer sitting under a drawn stroke would
  /// still drag/resize/rotate out from under the user's finger while they
  /// try to draw over it.
  private func setLayersOwnGesturesEnabled(_ enabled: Bool) {
    for layer in textLayerViews + stickerLayerViews { setOwnGestures(layer, enabled: enabled) }
    for layer in imageOverlayLayerViews { setOwnGestures(layer, enabled: enabled) }
  }

  private func setUpSafeAreaCovers() {
    let safe = view.safeAreaLayoutGuide
    [topSafeAreaCoverView, bottomSafeAreaCoverView].forEach {
      $0.backgroundColor = EditorDesignTokens.Colors.chromeBackground
      $0.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview($0)
    }
    NSLayoutConstraint.activate([
      topSafeAreaCoverView.topAnchor.constraint(equalTo: view.topAnchor),
      topSafeAreaCoverView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topSafeAreaCoverView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topSafeAreaCoverView.bottomAnchor.constraint(equalTo: safe.topAnchor),

      bottomSafeAreaCoverView.topAnchor.constraint(equalTo: safe.bottomAnchor),
      bottomSafeAreaCoverView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomSafeAreaCoverView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomSafeAreaCoverView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  /// Text/sticker/overlay layers (and their duplicates) are added to `view`
  /// at runtime, AFTER the safe-area covers and canvas gutter covers above
  /// — since `addSubview` appends to the top of the z-order, a newly-added
  /// layer would otherwise render ON TOP of the covers instead of being
  /// hidden behind them if dragged/pinched into those edge strips. Called
  /// once after every new layer is added to keep every cover pinned at the
  /// very top. Safe to call unconditionally for both media types — the
  /// gutter views' constraints already collapse to zero width/height
  /// whenever the canvas box exactly fills imageContentAreaGuide on that
  /// axis, so fronting them is a no-op in that case, not a visual bug.
  private func keepSafeAreaCoversOnTop() {
    view.bringSubviewToFront(topSafeAreaCoverView)
    view.bringSubviewToFront(bottomSafeAreaCoverView)
    view.bringSubviewToFront(canvasGutterViews.top)
    view.bringSubviewToFront(canvasGutterViews.bottom)
    view.bringSubviewToFront(canvasGutterViews.left)
    view.bringSubviewToFront(canvasGutterViews.right)
    if isFilterStageActive {
      // The fitted picture (and the views moving with it) sit above the
      // gutters, below the tray and panels.
      view.bringSubviewToFront(filterStageView)
      for v in filterStageTrackingViews where !v.isHidden { view.bringSubviewToFront(v) }
      scheduleFilterStageRefresh()
    }
    if !filterNameLabel.isHidden {
      view.bringSubviewToFront(filterNameGlass)
      view.bringSubviewToFront(filterNameLabel)
    }
    // The Tune value pill / setting list float over the picture's top area.
    if !tunePillView.isHidden {
      view.bringSubviewToFront(tunePillView)
      view.bringSubviewToFront(tuneListView)
      view.bringSubviewToFront(tuneBottomBar)
      view.bringSubviewToFront(tuneHintLabel)
    }
    // bringSubviewToFront calls are cumulative — the LAST call in this
    // function is the FRONTMOST view. Order below (back to front): canvas
    // gutters/safe-area covers, then the video-controls band (backdrop/
    // scrubber/buttons), then the bottom tray, then every slide-up panel
    // (so an OPEN panel always visually covers the video-controls band
    // and tray beneath it — user-reported bug, screenshot: musicPanel
    // used to sit BEHIND videoControlsBackdropView since that block used
    // to run AFTER this one), then topBar LAST so Cancel/Undo/Redo/Done
    // stay on top and tappable even while a panel is open.
    if mediaType != "image" {
      // Now that this row floats directly over the video's own bottom
      // edge (see viewDidLoad's videoControlsBackdropView constraints)
      // rather than in dedicated space below the canvas, a large enough
      // text/sticker/overlay layer can geometrically reach into the same
      // area — keep the scrim + controls above any of those. Backdrop
      // first so the buttons/scrubber/layer tracks stay in front of it,
      // not the other way around.
      view.bringSubviewToFront(videoControlsBackdropView)
      view.bringSubviewToFront(layerTracksScrollView)
      view.bringSubviewToFront(layersAreaCollapseButton)
      view.bringSubviewToFront(addLayerButton)
      if let compareButton, mediaType != "image" { view.bringSubviewToFront(compareButton) }
      view.bringSubviewToFront(layerHideButton)
      view.bringSubviewToFront(clipVolumeButton)
      view.bringSubviewToFront(clipSpeedButton)
      view.bringSubviewToFront(clipTransitionButton)
      view.bringSubviewToFront(textAnimationButton)
      view.bringSubviewToFront(layerLockButton)
      view.bringSubviewToFront(playPauseButton)
      view.bringSubviewToFront(videoTimeLabel)
      view.bringSubviewToFront(videoSelectionLabel)
      // videoTrimView/mergedStripView are children of filmstripScrollView
      // now (see the scrollable-timeline doc), not direct children of
      // `view` — fronting the scroll view itself moves them together;
      // the playhead line must stay above the scroll view's own content.
      view.bringSubviewToFront(filmstripScrollView)
      view.bringSubviewToFront(filmstripPlayheadView)
      view.bringSubviewToFront(splitSegmentButton)
      view.bringSubviewToFront(deleteSegmentButton)
    }
    view.bringSubviewToFront(bottomTrayCardView)
    view.bringSubviewToFront(effectPanel)
    view.bringSubviewToFront(editPanel)
    view.bringSubviewToFront(stickersPanel)
    view.bringSubviewToFront(drawPanel)
    view.bringSubviewToFront(textStylePanel)
    view.bringSubviewToFront(toolsGridPanel)
    view.bringSubviewToFront(musicPanel)
    // The layer action bar sits in the gap above the tray/panels, over the
    // black canvas gutters — it must be above those to be visible.
    if let layerActionToolbar { view.bringSubviewToFront(layerActionToolbar) }
    // Story-mode chrome floats on `view` itself (topBar is hidden there),
    // so it needs its own re-front — otherwise the canvas gutter covers
    // fronted above hide it wherever the photo doesn't reach (user-
    // reported: icons missing above/below an aspect-fit story photo).
    // Same slot as Android's storyRailRef/storyMusicBadgeRef re-front.
    storyChromeViews.forEach { view.bringSubviewToFront($0) }
    if isStoryMode, storyMusicBadge.superview === view {
      view.bringSubviewToFront(storyMusicBadge)
    }
    // Fixes a user-reported bug: a big enough overlay/text/sticker layer
    // (added to `view` at runtime, AFTER these chrome pieces) rendered ON
    // TOP of them, hiding Cancel/Undo/Redo/Done entirely — topBar must be
    // the LAST call so it's frontmost no matter what else this function
    // just re-ordered above it.
    if let textAnimationSheet { view.bringSubviewToFront(textAnimationSheet) }
    view.bringSubviewToFront(topBar)
  }

  /// The 4 gutter covers described at their declaration — each pinned
  /// entirely via Auto Layout between imageContentAreaGuide's own edge and
  /// imageView's corresponding edge, so they're correct regardless of the
  /// media's aspect ratio with zero manual frame math. `.black` matches
  /// `view.backgroundColor` exactly, so painting over a stray layer here
  /// is visually seamless with the margin that was already there.
  private func setUpCanvasGutterCovers() {
    let (top, bottom, left, right) = canvasGutterViews
    [top, bottom, left, right].forEach {
      $0.backgroundColor = EditorDesignTokens.Colors.canvasBackground
      $0.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview($0)
    }
    NSLayoutConstraint.activate([
      top.topAnchor.constraint(equalTo: imageContentAreaGuide.topAnchor),
      top.leadingAnchor.constraint(equalTo: imageContentAreaGuide.leadingAnchor),
      top.trailingAnchor.constraint(equalTo: imageContentAreaGuide.trailingAnchor),
      top.bottomAnchor.constraint(equalTo: imageView.topAnchor),

      bottom.topAnchor.constraint(equalTo: imageView.bottomAnchor),
      bottom.leadingAnchor.constraint(equalTo: imageContentAreaGuide.leadingAnchor),
      bottom.trailingAnchor.constraint(equalTo: imageContentAreaGuide.trailingAnchor),
      bottom.bottomAnchor.constraint(equalTo: imageContentAreaGuide.bottomAnchor),

      left.topAnchor.constraint(equalTo: imageView.topAnchor),
      left.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
      left.leadingAnchor.constraint(equalTo: imageContentAreaGuide.leadingAnchor),
      left.trailingAnchor.constraint(equalTo: imageView.leadingAnchor),

      right.topAnchor.constraint(equalTo: imageView.topAnchor),
      right.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
      right.leadingAnchor.constraint(equalTo: imageView.trailingAnchor),
      right.trailingAnchor.constraint(equalTo: imageContentAreaGuide.trailingAnchor),
    ])
  }

  /// Fallback only — the common path sets this synchronously in
  /// viewDidLoad from the file header before the first layout pass (see the
  /// comment there for why timing matters). This covers the rare case
  /// where that header read fails but the full decode still succeeds; it
  /// no-ops if the synchronous path already set the constraint.
  private func applyImageAspectRatio(_ image: UIImage?) {
    guard imageAspectConstraint == nil, let image, image.size.height > 0 else { return }
    let ratio = image.size.width / image.size.height
    let constraint = canvasClipContainerView.widthAnchor.constraint(equalTo: canvasClipContainerView.heightAnchor, multiplier: ratio)
    constraint.isActive = true
    imageAspectConstraint = constraint
  }

  /// Reads only the image header (no full decode) to get the aspect ratio
  /// as fast and as early as possible. Raw EXIF pixel dimensions don't
  /// account for orientation, so a rotated (5/6/7/8) orientation needs its
  /// width/height swapped to match what the transform-applied thumbnail
  /// decode (loadDownsampledImage, which bakes EXIF orientation in) will
  /// actually display.
  private static func imagePixelSize(at url: URL) -> CGSize? {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
    else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return [5, 6, 7, 8].contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
  }

  // MARK: - Editing controls (shared by image AND video) — top icon row
  // (cancel/undo/redo/done) + bottom tab bar (Tools/Effect/Text/Edit/Draw/
  // Sticker/Overlay, plus a video-only Music tab), Effect/Edit each
  // opening their own SlideUpPanelView (filters / adjustments). Originally
  // image-only; unified onto video too per the user's explicit "same UI
  // as the image editor" request — video's own
  // former standalone layout (plain text buttons, a vertical stack of
  // Text/Sticker/Filter/Music buttons under the top bar) is gone. Tools has
  // no panel of its own — pan/zoom/rotate work continuously on the canvas.
  // Text is a momentary action wired to the on-canvas text-entry overlay.
  // Sticker/Draw/Music are stateful tabs, each revealing their own
  // SlideUpPanelView.
  private func setUpEditingControls() {
    let isImage = mediaType == "image"
    // Cancel/Done are plain text labels (not icons) — per the user's
    // explicit request to simplify these away from the hand-drawn-style
    // icon set. Undo/Redo stay as SF Symbol icons — not part of that
    // request, and there's no short standard word for either that reads as
    // cleanly as an arrow glyph.
    // Redesign: ✕ icon (was the text "Cancel") and a blue "Done" pill.
    let cancelButton = MediaEditorViewController.makeTopBarIconButton(systemImageName: "xmark")
    cancelButton.accessibilityLabel = "Cancel"
    cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)

    let undoButton = MediaEditorViewController.makeTopBarIconButton(systemImageName: "arrow.uturn.backward")
    undoButton.addTarget(self, action: #selector(didTapUndo), for: .touchUpInside)
    undoButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)

    let redoButton = MediaEditorViewController.makeTopBarIconButton(systemImageName: "arrow.uturn.forward")
    redoButton.addTarget(self, action: #selector(didTapRedo), for: .touchUpInside)
    redoButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)

    // Hold-to-compare with the original (regular editor, photo or video).
    if !isStoryMode {
      let button = MediaEditorViewController.makeTopBarIconButton(systemImageName: "square.split.2x1")
      button.accessibilityLabel = "Hold to compare with original"
      button.addTarget(self, action: #selector(didPressCompare), for: .touchDown)
      button.addTarget(self, action: #selector(didReleaseCompare), for: [.touchUpInside, .touchUpOutside, .touchCancel])
      if !isImage {
        // Video: a plain white icon in the play/split/delete row, same
        // style as "+", scissors and trash.
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .clear
        button.tintColor = .white
      }
      compareButton = button
    }

    var doneConfig = UIButton.Configuration.filled()
    // Video editor: Export top right as an icon in an accent circle (the
    // LOOKS · TOOLS · EXPORT bar is gone for video, see lookToolsBarHeight).
    doneConfig.title = isStoryMode ? "Share" : "Done"
    if !isImage && !isStoryMode {
      doneConfig.title = nil
      doneConfig.image = UIImage(systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
      doneConfig.cornerStyle = .capsule
      doneConfig.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 10, bottom: 11, trailing: 10)
    }
    doneConfig.baseBackgroundColor = EditorDesignTokens.Colors.accent
    doneConfig.baseForegroundColor = .white
    doneConfig.cornerStyle = .capsule
    doneConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    doneConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = .systemFont(ofSize: 15, weight: .semibold)
      return outgoing
    }
    doneButton.configuration = doneConfig
    if !isImage && !isStoryMode { doneButton.accessibilityLabel = "Export" }
    doneButton.translatesAutoresizingMaskIntoConstraints = false
    doneButton.addTarget(self, action: #selector(didTapDone), for: .touchUpInside)
    doneButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)

    // Liquid Glass controls float on the editor; the bar itself is clear.
    topBar.backgroundColor = .clear
    topBar.translatesAutoresizingMaskIntoConstraints = false

    toolsTabButton.addTarget(self, action: #selector(didTapToolsTab), for: .touchUpInside)
    effectTabButton.addTarget(self, action: #selector(didTapEffectTab), for: .touchUpInside)
    // Same rich on-canvas text-entry overlay (font/color/alignment toolbar
    // above the keyboard) for both media types — video previously had its
    // own simpler alert (didTapAddText), now removed.
    textTabButton.addTarget(self, action: #selector(presentTextEntryOverlay), for: .touchUpInside)
    editTabButton.addTarget(self, action: #selector(didTapEditTab), for: .touchUpInside)
    // Same 40-emoji grid panel for both media types — video previously had
    // its own momentary action-sheet picker (didTapAddSticker), now removed.
    stickerTabButton.addTarget(self, action: #selector(didTapStickersTab), for: .touchUpInside)
    drawTabButton.addTarget(self, action: #selector(didTapDrawTab), for: .touchUpInside)
    overlayTabButton.addTarget(self, action: #selector(presentImageOverlayPicker), for: .touchUpInside)
    musicTabButton.addTarget(self, action: #selector(didTapMusicTab), for: .touchUpInside)
    mergeTabButton.addTarget(self, action: #selector(presentVideoClipPicker), for: .touchUpInside)
    // "Add Video" is the only two-word tray label — the shared factory's
    // 2pt leading/trailing insets leave it sitting flush against its
    // neighbors with no breathing room, per the user's explicit "increase
    // little more padding so it will display nicely" follow-up (after
    // the required-compression-resistance fix above stopped it from
    // being truncated outright). Widened only for this one button so the
    // already-tuned tight spacing on every other (single-word) tab is
    // unaffected.
    // (Every tab now gets 8pt side insets from makeTabButton, so "Add
    // Video" needs no override.)

    // Free-scrolling tray: items size to their own content (not stretched
    // to fill the width) with a fixed gap between them, inside a
    // UIScrollView so the tray can scroll if more tools are ever added.
    // Video gets a 6th item (Music) with no image equivalent.
    bottomTabBar.axis = .horizontal
    bottomTabBar.distribution = .fillEqually
    bottomTabBar.alignment = .center
    bottomTabBar.spacing = 2
    bottomTrayScrollView.isScrollEnabled = false
    bottomTabBar.translatesAutoresizingMaskIntoConstraints = false
    // Effect sits immediately left of Text, Edit immediately right of it —
    // per the user's explicit "major change" tab-order request.
    // "Tools" (pan/zoom/rotate) tab removed from the visible tray per the
    // user's explicit request — it was a no-op placeholder since pan/zoom/
    // rotate already work continuously on the canvas regardless of the
    // selected tab. `toolsTabButton`/`.tools` stay in code as the internal
    // "no other panel active" default/reset state (see
    // selectedImageEditorTab) — only its visible tab button is removed.
    var tabButtons: [UIButton] = [
      effectTabButton, textTabButton, editTabButton, drawTabButton, stickerTabButton,
    ]
    // Overlay (image-over-image layer tool) is image-only, per the user's
    // explicit "remove overlay from video" request — it never baked into
    // exported video anyway (see Phase A notes: overlay's drag/pinch/
    // rotate worked live on video as a side effect of the shared chrome,
    // but export-baking was never built for it).
    if isImage {
      tabButtons.append(overlayTabButton)
    } else {
      tabButtons.append(musicTabButton)
      tabButtons.append(mergeTabButton)
    }
    tabButtons.forEach { bottomTabBar.addArrangedSubview($0) }
    // Every slot is at least as wide as its full name (semibold = the
    // selected look, the widest), so names always show completely on any
    // iPhone — the rail scrolls on very narrow screens instead.
    let titleFont = UIFont.systemFont(ofSize: EditorDesignTokens.Typography.trayLabel.pointSize, weight: .semibold)
    for button in tabButtons {
      let title = button.configuration?.title ?? ""
      let needed = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width) + 6
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: needed).isActive = true
    }
    if isCompactToolRail {
      // Video editor: smaller rail icons (the full-size rail looked heavy
      // under the timeline). styleTabButton keeps config.image as is.
      for button in tabButtons {
        guard var config = button.configuration, let image = config.image else { continue }
        config.image = Self.resizedRailIcon(image, side: Self.compactTrayIconSize)
        config.imagePadding = 9
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        config.titleLineBreakMode = .byClipping
        button.configuration = config
        Self.fitTabTitle(button)
      }
      bottomTabBar.spacing = 0
    }

    MediaEditorViewController.attachTabIndicator(toolsTabIndicator, to: toolsTabButton)
    MediaEditorViewController.attachTabIndicator(effectTabIndicator, to: effectTabButton)
    MediaEditorViewController.attachTabIndicator(editTabIndicator, to: editTabButton)
    MediaEditorViewController.attachTabIndicator(stickerTabIndicator, to: stickerTabButton)
    MediaEditorViewController.attachTabIndicator(drawTabIndicator, to: drawTabButton)
    if !isImage {
      MediaEditorViewController.attachTabIndicator(musicTabIndicator, to: musicTabButton)
    }

    // Rounded top corners + a real elevation shadow, per UI-modernization
    // item 3 — reads as a floating panel over the canvas instead of a
    // flat strip flush with the screen edge. `masksToBounds` is
    // deliberately left false: cornerRadius alone already shapes the
    // opaque background fill, and leaving clipping off is what lets the
    // shadow render outside the layer's own bounds.
    bottomTrayCardView.backgroundColor = EditorDesignTokens.Colors.chromeBackground
    bottomTrayCardView.translatesAutoresizingMaskIntoConstraints = false
    bottomTrayCardView.layer.cornerRadius = EditorDesignTokens.Spacing.panelCornerRadius
    bottomTrayCardView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    bottomTrayCardView.layer.shadowColor = UIColor.black.cgColor
    bottomTrayCardView.layer.shadowOpacity = 0.35
    bottomTrayCardView.layer.shadowRadius = 10
    bottomTrayCardView.layer.shadowOffset = CGSize(width: 0, height: -3)

    // The scroll view itself stays transparent and keeps its own default
    // `clipsToBounds = true` (needed so scrolled-past tab content clips
    // correctly) — the card underneath supplies the shape and shadow.
    bottomTrayScrollView.showsHorizontalScrollIndicator = false
    bottomTrayScrollView.backgroundColor = .clear
    bottomTrayScrollView.translatesAutoresizingMaskIntoConstraints = false
    bottomTrayScrollView.addSubview(bottomTabBar)
    bottomTrayCardView.addSubview(bottomTrayScrollView)
    if !isStoryMode {
      // Video: no LOOKS · TOOLS · EXPORT bar (Export is top right, Filters
      // and Tune are on the tool rail) — it took too much height.
      if isImage { setUpLookToolsBar() }
      setUpToolGlass()
    }
    setUpToolsGridPanel(isImage: isImage)
    setUpTune()

    // Circular thumbnails showing a live-rendered preview of the current
    // photo with each filter baked in (renderFilterThumbnails, called once
    // the photo finishes loading) rather than a generic icon — horizontally
    // scrollable via the same "self-sizing, centered if short, scrollable
    // if long" pattern already used for the bottom tray.
    let filterRow = UIStackView()
    filterRow.axis = .horizontal
    filterRow.distribution = .fill
    filterRow.spacing = EditorDesignTokens.Spacing.thumbnailGutter
    filterRow.translatesAutoresizingMaskIntoConstraints = false
    // Artistic looks are photo only.
    for filter in PhotoFilter.allCases where isImage || !filter.isArtistic {
      let thumbnail = MediaEditorViewController.makeFilterThumbnailButton(filter: filter)
      thumbnail.container.tag = PhotoFilter.allCases.firstIndex(of: filter) ?? 0
      let tap = UITapGestureRecognizer(target: self, action: #selector(didTapFilterThumbnail(_:)))
      thumbnail.container.addGestureRecognizer(tap)
      filterThumbnailImageViews[filter] = thumbnail.imageView
      filterThumbnailContainers[filter] = thumbnail.container
      filterEditOverlays[filter] = thumbnail.editOverlay
      filterRow.addArrangedSubview(thumbnail.container)
    }
    let filterScrollView = UIScrollView()
    filterScrollViewRef = filterScrollView
    filterScrollView.showsHorizontalScrollIndicator = false
    filterScrollView.translatesAutoresizingMaskIntoConstraints = false
    filterScrollView.addSubview(filterRow)
    let filterScrollHeight = EditorDesignTokens.Spacing.thumbnailSize + 4 + 16 // thumbnail + gap + label
    NSLayoutConstraint.activate([
      filterScrollView.heightAnchor.constraint(equalToConstant: filterScrollHeight),
      filterRow.topAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.topAnchor),
      filterRow.bottomAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.bottomAnchor),
      filterRow.heightAnchor.constraint(equalTo: filterScrollView.frameLayoutGuide.heightAnchor),
      filterRow.centerXAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.centerXAnchor),
      filterRow.leadingAnchor.constraint(greaterThanOrEqualTo: filterScrollView.contentLayoutGuide.leadingAnchor),
      filterRow.trailingAnchor.constraint(lessThanOrEqualTo: filterScrollView.contentLayoutGuide.trailingAnchor),
    ])

    // Adjust — Instagram's actual "Edit" model: an icon row, tap one to
    // swap in a single centered slider with a back arrow, rather than
    // showing all sliders stacked at once. 8 properties now (was 3), so
    // the icon row is horizontally scrollable, matching the filter row.
    let brightnessRow = MediaEditorViewController.makeAdjustmentRow(title: "B", onChange: { [weak self] value in
      self?.brightness = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let contrastRow = MediaEditorViewController.makeAdjustmentRow(title: "C", onChange: { [weak self] value in
      self?.contrast = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let saturationRow = MediaEditorViewController.makeAdjustmentRow(title: "S", onChange: { [weak self] value in
      self?.saturation = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let fadeRow = MediaEditorViewController.makeAdjustmentRow(title: "Fade", onChange: { [weak self] value in
      self?.fade = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let shadowRow = MediaEditorViewController.makeAdjustmentRow(title: "Shadow", onChange: { [weak self] value in
      self?.shadow = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let vignetteRow = MediaEditorViewController.makeAdjustmentRow(title: "Vignette", onChange: { [weak self] value in
      self?.vignette = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let sharpenRow = MediaEditorViewController.makeAdjustmentRow(title: "Sharpen", onChange: { [weak self] value in
      self?.sharpen = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let warmthRow = MediaEditorViewController.makeAdjustmentRow(title: "Warm", onChange: { [weak self] value in
      self?.warmth = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let highlightsRow = MediaEditorViewController.makeAdjustmentRow(title: "Highlights", onChange: { [weak self] value in
      self?.highlights = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let tintRow = MediaEditorViewController.makeAdjustmentRow(title: "Tint", onChange: { [weak self] value in
      self?.tint = value
      self?.refreshPreview()
    }, pushUndo: { [weak self] undo, redo in self?.pushUndo(undo: undo, redo: redo) })
    let blurRow = makeBlurRow()
    let allAdjustRows = [brightnessRow, contrastRow, saturationRow, fadeRow, shadowRow, vignetteRow, sharpenRow, warmthRow, highlightsRow, tintRow, blurRow]
    adjustSliderRows = [
      .brightness: brightnessRow, .contrast: contrastRow, .saturation: saturationRow,
      .fade: fadeRow, .shadow: shadowRow, .vignette: vignetteRow, .sharpen: sharpenRow, .warmth: warmthRow,
      .highlights: highlightsRow, .tint: tintRow, .blur: blurRow,
    ]
    allAdjustRows.forEach { $0.isHidden = true }
    // All rows share one UIStackView so hiding all-but-one auto-collapses
    // their space (standard UIStackView behavior) — only the currently-
    // selected row's height is ever occupied.
    let adjustSlidersStack = UIStackView(arrangedSubviews: allAdjustRows)
    adjustSlidersStack.axis = .vertical
    adjustSlidersStack.translatesAutoresizingMaskIntoConstraints = false

    // Icon + label per adjustment (was plain text labels only) — the
    // single biggest "looks dated" cue in the whole editor, per the
    // user's explicit "modernize the UI" request. Real SF Symbols, same
    // convention as every other icon on this platform.
    var adjustIconOptions: [(AdjustProperty, String, String)] = [
      (.brightness, "Brightness", "sun.max.fill"), (.contrast, "Contrast", "circle.lefthalf.filled"),
      (.saturation, "Saturation", "drop.fill"), (.fade, "Fade", "circle.dashed"),
      (.shadow, "Shadow", "moon.fill"), (.vignette, "Vignette", "aperture"),
      (.sharpen, "Sharpen", "target"), (.warmth, "Warm", "thermometer.sun.fill"),
      (.highlights, "Highlights", "highlighter"), (.tint, "Tint", "paintbrush.fill"),
    ]
    // Photo only, like the rest of the canvas-geometry tools.
    if mediaType == "image" {
      adjustIconOptions.insert((.auto, "Auto", "wand.and.stars"), at: 0)
      adjustIconOptions.append((.blur, "Blur", "circle.circle"))
    }
    adjustIconRow.axis = .horizontal
    adjustIconRow.distribution = .fill
    adjustIconRow.spacing = 6
    adjustIconRow.translatesAutoresizingMaskIntoConstraints = false
    for (property, label, systemImageName) in adjustIconOptions {
      let icon = MediaEditorViewController.makeAdjustIconButton(label: label, systemImageName: systemImageName)
      icon.addAction(UIAction { [weak self] _ in self?.didTapAdjustIcon(property) }, for: .touchUpInside)
      if property == .auto { autoEnhanceButton = icon }
      adjustIconRow.addArrangedSubview(icon)
    }
    adjustIconScrollView.showsHorizontalScrollIndicator = false
    adjustIconScrollView.translatesAutoresizingMaskIntoConstraints = false
    adjustIconScrollView.addSubview(adjustIconRow)
    NSLayoutConstraint.activate([
      adjustIconRow.topAnchor.constraint(equalTo: adjustIconScrollView.contentLayoutGuide.topAnchor),
      adjustIconRow.bottomAnchor.constraint(equalTo: adjustIconScrollView.contentLayoutGuide.bottomAnchor),
      adjustIconRow.leadingAnchor.constraint(equalTo: adjustIconScrollView.contentLayoutGuide.leadingAnchor),
      adjustIconRow.trailingAnchor.constraint(equalTo: adjustIconScrollView.contentLayoutGuide.trailingAnchor),
      adjustIconRow.heightAnchor.constraint(equalTo: adjustIconScrollView.frameLayoutGuide.heightAnchor),
    ])

    let adjustBackButton = UIButton(type: .system)
    adjustBackButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    adjustBackButton.tintColor = EditorDesignTokens.Colors.textSecondary
    adjustBackButton.addAction(UIAction { [weak self] _ in self?.didTapAdjustBack() }, for: .touchUpInside)
    adjustBackButton.translatesAutoresizingMaskIntoConstraints = false
    adjustBackButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

    adjustDetailRow.axis = .horizontal
    adjustDetailRow.spacing = 8
    adjustDetailRow.alignment = .center
    adjustDetailRow.translatesAutoresizingMaskIntoConstraints = false
    adjustDetailRow.isHidden = true
    adjustDetailRow.addArrangedSubview(adjustBackButton)
    adjustDetailRow.addArrangedSubview(adjustSlidersStack)

    // Both states share ONE fixed-height container — icon row and single-
    // slider-with-back-button never differ in height, so toggling between
    // them never resizes anything above/below it.
    let adjustRowHeight: CGFloat = 44
    let adjustContainer = UIView()
    adjustContainer.translatesAutoresizingMaskIntoConstraints = false
    adjustContainer.addSubview(adjustIconScrollView)
    adjustContainer.addSubview(adjustDetailRow)
    NSLayoutConstraint.activate([
      adjustContainer.heightAnchor.constraint(equalToConstant: adjustRowHeight),
      adjustIconScrollView.topAnchor.constraint(equalTo: adjustContainer.topAnchor),
      adjustIconScrollView.bottomAnchor.constraint(equalTo: adjustContainer.bottomAnchor),
      adjustIconScrollView.leadingAnchor.constraint(equalTo: adjustContainer.leadingAnchor),
      adjustIconScrollView.trailingAnchor.constraint(equalTo: adjustContainer.trailingAnchor),
      adjustDetailRow.topAnchor.constraint(equalTo: adjustContainer.topAnchor),
      adjustDetailRow.bottomAnchor.constraint(equalTo: adjustContainer.bottomAnchor),
      adjustDetailRow.leadingAnchor.constraint(equalTo: adjustContainer.leadingAnchor),
      adjustDetailRow.trailingAnchor.constraint(equalTo: adjustContainer.trailingAnchor),
    ])

    // Filter row lives in effectPanel's content — was an always-visible
    // strip; gated behind its own Effect tab per the user's explicit
    // "major change" request. No manual background/corner/shadow styling
    // needed here (unlike the old filtersAdjustContainer) — SlideUpPanelView
    // already supplies that chrome itself, same as Sticker/Draw/Music.
    // Category tabs (Classic / Film / Cinema / Vibes) above the thumbnails.
    let filterCategoryRow = makeFilterCategoryRow()
    filterCategoryRow.translatesAutoresizingMaskIntoConstraints = false
    effectPanel.contentContainer.addSubview(filterCategoryRow)
    effectPanel.contentContainer.addSubview(filterScrollView)
    // Strength, then the filter's own Saturation (-100...100) and
    // Sharpness (0...100) — all three reset when a new filter is picked.
    let filterSliderStack = UIStackView(arrangedSubviews: [
      makeFilterSliderRow(title: "Strength", minValue: 0, defaultValue: 1,
                          read: { [weak self] in self?.filterStrength ?? 1 },
                          write: { [weak self] in self?.filterStrength = $0 }),
      makeFilterSliderRow(title: "Saturation", minValue: -1, defaultValue: 0,
                          read: { [weak self] in self?.filterSaturation ?? 0 },
                          write: { [weak self] in self?.filterSaturation = $0 }),
      makeFilterSliderRow(title: "Sharpness", minValue: 0, defaultValue: 0,
                          read: { [weak self] in self?.filterSharpness ?? 0 },
                          write: { [weak self] in self?.filterSharpness = $0 }),
    ])
    filterSliderStack.axis = .vertical
    filterSliderStack.spacing = 4
    filterSliderStack.translatesAutoresizingMaskIntoConstraints = false
    effectPanel.contentContainer.addSubview(filterSliderStack)
    // Adjust mode (pencil on the selected thumbnail): a "‹ Vivid" back row
    // replaces the tabs and the sliders replace the thumbnails.
    let filterEditHeader = makeFilterEditHeader()
    filterEditHeader.translatesAutoresizingMaskIntoConstraints = false
    effectPanel.contentContainer.addSubview(filterEditHeader)
    filterCategoryRowRef = filterCategoryRow
    filterSliderStackRef = filterSliderStack
    NSLayoutConstraint.activate([
      filterCategoryRow.topAnchor.constraint(equalTo: effectPanel.contentContainer.topAnchor),
      filterCategoryRow.centerXAnchor.constraint(equalTo: effectPanel.contentContainer.centerXAnchor),
      filterCategoryRow.heightAnchor.constraint(equalToConstant: Self.filterCategoryRowHeight),
      filterEditHeader.topAnchor.constraint(equalTo: effectPanel.contentContainer.topAnchor),
      filterEditHeader.leadingAnchor.constraint(equalTo: effectPanel.contentContainer.leadingAnchor, constant: 12),
      filterEditHeader.heightAnchor.constraint(equalToConstant: Self.filterCategoryRowHeight),
      filterScrollView.topAnchor.constraint(equalTo: filterCategoryRow.bottomAnchor),
      filterScrollView.leadingAnchor.constraint(equalTo: effectPanel.contentContainer.leadingAnchor),
      filterScrollView.trailingAnchor.constraint(equalTo: effectPanel.contentContainer.trailingAnchor),
      filterSliderStack.topAnchor.constraint(equalTo: filterCategoryRow.bottomAnchor, constant: 6),
      filterSliderStack.leadingAnchor.constraint(equalTo: effectPanel.contentContainer.leadingAnchor, constant: 20),
      filterSliderStack.trailingAnchor.constraint(equalTo: effectPanel.contentContainer.trailingAnchor, constant: -20),
    ])
    filterSliderStack.arrangedSubviews.forEach { $0.heightAnchor.constraint(equalToConstant: 32).isActive = true }
    selectFilterCategory(selectedFilter.category)
    syncFilterStrengthControl()
    effectPanel.setCollapsedHeight(effectPanelHeightWithoutSliders)
    effectPanel.onConfirm = { [weak self] in
      // Next time the panel opens it starts on the thumbnails again.
      self?.setFilterEditing(false)
      self?.didTapToolsTab()
    }
    // ✕ on every editing panel (not Tools grid / Music).
    for panel in [effectPanel, editPanel, stickersPanel, drawPanel] {
      panel.onCancel = { [weak self] in self?.cancelToolSession() }
    }

    // Adjust icon-row/single-slider swap lives in editPanel's content —
    // same "was always-visible, now gated behind a tab" change.
    editPanel.contentContainer.addSubview(adjustContainer)
    NSLayoutConstraint.activate([
      adjustContainer.topAnchor.constraint(equalTo: editPanel.contentContainer.topAnchor),
      adjustContainer.leadingAnchor.constraint(equalTo: editPanel.contentContainer.leadingAnchor, constant: 16),
      adjustContainer.trailingAnchor.constraint(equalTo: editPanel.contentContainer.trailingAnchor, constant: -16),
    ])
    editPanel.setCollapsedHeight(editPanelHeight)
    editPanel.onConfirm = { [weak self] in
      self?.didTapToolsTab()
    }

    // Per-layer track rows (video only — no time axis to show for a still
    // image): a scrollable stack rebuilt from scratch by
    // refreshLayersPanel() whenever the set of layers/their order/timing
    // changes, always visible on the Tools tab directly above the trim
    // scrubber — see layerTracksStack's own doc for why there's no
    // separate tab/panel for this anymore. Positioned (and constrained
    // against the other video controls) alongside them in viewDidLoad,
    // since those views don't exist as properties readable here at
    // this point in some configurations — only configured here.
    if !isImage {
      layerTracksStack.axis = .vertical
      layerTracksStack.spacing = 6
      // Per-row LEADING alignment (not the default .fill) so each row's
      // own explicit width constraint (see makeLayerTypeRow) actually
      // takes effect instead of being stretched to the stack's width —
      // needed now that rows are narrower than the full combined
      // timeline whenever merged clips exist. layerTracksScrollView's own
      // leading/trailing are now pinned DIRECTLY to filmstripScrollView's
      // (see its own constraints below) — an exact match with zero manual
      // margin arithmetic — so a row left-aligned at x=0 here lines up
      // with videoTrimView's own x=0 with no extra margin needed.
      layerTracksStack.alignment = .leading
      layerTracksStack.translatesAutoresizingMaskIntoConstraints = false
      layerTracksScrollView.translatesAutoresizingMaskIntoConstraints = false
      layerTracksScrollView.addSubview(layerTracksStack)
      let layerTracksStackWidth = layerTracksStack.widthAnchor.constraint(equalToConstant: 100)
      NSLayoutConstraint.activate([
        layerTracksStack.topAnchor.constraint(equalTo: layerTracksScrollView.contentLayoutGuide.topAnchor),
        layerTracksStack.bottomAnchor.constraint(equalTo: layerTracksScrollView.contentLayoutGuide.bottomAnchor),
        layerTracksStack.leadingAnchor.constraint(equalTo: layerTracksScrollView.contentLayoutGuide.leadingAnchor),
        layerTracksStack.trailingAnchor.constraint(lessThanOrEqualTo: layerTracksScrollView.contentLayoutGuide.trailingAnchor),
        layerTracksStackWidth,
      ])
      layerTracksStackWidthConstraint = layerTracksStackWidth
    }

    // Sticker library: search box, category tabs, and a grid of the
    // current category (or search results). The grid is rebuilt on each
    // change so only the visible set is decoded (see StickerCatalog.thumbnail).
    let searchField = UISearchTextField()
    searchField.placeholder = "Search stickers"
    searchField.font = .systemFont(ofSize: 14)
    searchField.textColor = EditorDesignTokens.Colors.textPrimary
    searchField.backgroundColor = EditorDesignTokens.Colors.elevatedSurface
    searchField.returnKeyType = .search
    searchField.autocorrectionType = .no
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.addAction(UIAction { [weak self, weak searchField] _ in
      self?.didChangeStickerSearch(searchField?.text ?? "")
    }, for: .editingChanged)
    // Having this action is what makes Return close the keyboard.
    searchField.addAction(UIAction { _ in }, for: .editingDidEndOnExit)
    searchField.addAction(UIAction { [weak self] _ in self?.stickersPanelKeyboardConstraint?.isActive = true }, for: .editingDidBegin)
    searchField.addAction(UIAction { [weak self] _ in self?.stickersPanelKeyboardConstraint?.isActive = false }, for: .editingDidEnd)
    stickerSearchField = searchField

    let tabRow = UIStackView()
    tabRow.axis = .horizontal
    tabRow.alignment = .fill
    tabRow.translatesAutoresizingMaskIntoConstraints = false
    stickerCategoryTabs = StickerCatalog.categories.enumerated().map { index, category in
      let button = UIButton(type: .system)
      button.setTitle(category.title, for: .normal)
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 9, bottom: 4, right: 9)
      button.addAction(UIAction { [weak self] _ in
        UISelectionFeedbackGenerator().selectionChanged()
        self?.selectStickerCategory(index)
      }, for: .touchUpInside)
      let underline = UIView()
      underline.backgroundColor = EditorDesignTokens.Colors.textPrimary
      underline.layer.cornerRadius = 1
      underline.tag = 1
      underline.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(underline)
      NSLayoutConstraint.activate([
        underline.widthAnchor.constraint(equalToConstant: 16),
        underline.heightAnchor.constraint(equalToConstant: 2),
        underline.centerXAnchor.constraint(equalTo: button.centerXAnchor),
        underline.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4),
      ])
      tabRow.addArrangedSubview(button)
      return button
    }
    let tabScroll = UIScrollView()
    tabScroll.showsHorizontalScrollIndicator = false
    tabScroll.translatesAutoresizingMaskIntoConstraints = false
    tabScroll.addSubview(tabRow)
    stickerCategoryScrollRef = tabScroll

    let stickerGrid = UIStackView()
    stickerGrid.axis = .vertical
    stickerGrid.spacing = EditorDesignTokens.Spacing.thumbnailGutter
    stickerGrid.translatesAutoresizingMaskIntoConstraints = false
    stickerGridStack = stickerGrid
    let stickerGridScrollView = UIScrollView()
    stickerGridScrollView.translatesAutoresizingMaskIntoConstraints = false
    stickerGridScrollView.showsVerticalScrollIndicator = false
    stickerGridScrollView.keyboardDismissMode = .onDrag
    stickerGridScrollView.addSubview(stickerGrid)
    stickerGridScrollRef = stickerGridScrollView

    let container = stickersPanel.contentContainer
    container.addSubview(searchField)
    container.addSubview(tabScroll)
    container.addSubview(stickerGridScrollView)
    NSLayoutConstraint.activate([
      searchField.topAnchor.constraint(equalTo: container.topAnchor),
      searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      searchField.heightAnchor.constraint(equalToConstant: 34),

      tabScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
      tabScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
      tabScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
      tabScroll.heightAnchor.constraint(equalToConstant: Self.filterCategoryRowHeight),
      tabRow.topAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.topAnchor),
      tabRow.bottomAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.bottomAnchor),
      tabRow.leadingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.leadingAnchor),
      tabRow.trailingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.trailingAnchor),
      tabRow.heightAnchor.constraint(equalTo: tabScroll.frameLayoutGuide.heightAnchor),

      stickerGridScrollView.topAnchor.constraint(equalTo: tabScroll.bottomAnchor, constant: 4),
      stickerGridScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      stickerGridScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      stickerGridScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

      stickerGrid.topAnchor.constraint(equalTo: stickerGridScrollView.contentLayoutGuide.topAnchor),
      stickerGrid.bottomAnchor.constraint(equalTo: stickerGridScrollView.contentLayoutGuide.bottomAnchor),
      stickerGrid.leadingAnchor.constraint(equalTo: stickerGridScrollView.contentLayoutGuide.leadingAnchor),
      stickerGrid.trailingAnchor.constraint(equalTo: stickerGridScrollView.contentLayoutGuide.trailingAnchor),
      stickerGrid.widthAnchor.constraint(equalTo: stickerGridScrollView.frameLayoutGuide.widthAnchor),
    ])
    selectStickerCategory(0)
    stickersPanel.configureExpandedHeight(screenHeight: UIScreen.main.bounds.height)
    stickersPanel.onConfirm = { [weak self] in
      self?.didTapToolsTab()
    }

    // Draw panel: same 12 color swatches as the text-entry toolbar (reused
    // directly, not a second palette) plus a brush-width slider — no font/
    // alignment concept applies here, so a much smaller content area than
    // Stickers' grid.
    drawColorButtons = MediaEditorViewController.textColorSwatches.map { color in
      let swatch = UIButton(type: .system)
      swatch.backgroundColor = color
      swatch.layer.cornerRadius = 14
      swatch.layer.borderColor = EditorDesignTokens.Colors.divider.cgColor
      swatch.translatesAutoresizingMaskIntoConstraints = false
      swatch.widthAnchor.constraint(equalToConstant: 28).isActive = true
      swatch.heightAnchor.constraint(equalToConstant: 28).isActive = true
      swatch.addAction(UIAction { [weak self] _ in self?.didSelectDrawColor(color) }, for: .touchUpInside)
      return swatch
    }
    let drawColorRow = UIStackView(arrangedSubviews: drawColorButtons)
    drawColorRow.axis = .horizontal
    drawColorRow.spacing = 10
    drawColorRow.alignment = .center
    let drawColorScroll = makeHorizontalScrollRow(content: drawColorRow)

    // PicsArt-style row: Brush / Eraser / Shape tools, then the selected
    // tool's tiles — brushes show their real stroke and shapes their
    // outline, both drawn by the same code as the canvas.
    let tileSize = CGSize(width: 60, height: 44)
    func makeTile(image: UIImage?, title: String, action: @escaping () -> Void) -> UIButton {
      let button = UIButton(type: .custom)
      button.backgroundColor = EditorDesignTokens.Colors.elevatedSurface
      button.layer.cornerRadius = 10
      button.layer.borderColor = EditorDesignTokens.Colors.accent.cgColor
      button.clipsToBounds = true
      button.setImage(image, for: .normal)
      button.imageView?.contentMode = .scaleAspectFit
      button.accessibilityLabel = title
      button.translatesAutoresizingMaskIntoConstraints = false
      button.widthAnchor.constraint(equalToConstant: tileSize.width).isActive = true
      button.heightAnchor.constraint(equalToConstant: tileSize.height).isActive = true
      button.addAction(UIAction { _ in action() }, for: .touchUpInside)
      return button
    }
    drawToolButtons = DrawTool.allCases.map { tool in
      var config = UIButton.Configuration.plain()
      config.image = UIImage(systemName: tool.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
      config.title = tool.title
      config.imagePlacement = .top
      config.imagePadding = 3
      config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = .systemFont(ofSize: 11, weight: .medium)
        return outgoing
      }
      let button = UIButton(configuration: config)
      button.layer.cornerRadius = 10
      button.clipsToBounds = true
      button.translatesAutoresizingMaskIntoConstraints = false
      button.widthAnchor.constraint(equalToConstant: 56).isActive = true
      button.heightAnchor.constraint(equalToConstant: tileSize.height).isActive = true
      button.addAction(UIAction { [weak self] _ in self?.didSelectDrawTool(tool) }, for: .touchUpInside)
      return (tool, button)
    }
    drawBrushTypeButtons = DrawingCanvasView.BrushType.allCases.filter { $0 != .eraser }.map { brushType in
      (brushType, makeTile(image: DrawingCanvasView.previewImage(brush: brushType, size: tileSize), title: brushType.title) { [weak self] in
        self?.didSelectBrushType(brushType)
      })
    }
    drawShapeButtons = DrawingCanvasView.ShapeType.allCases.map { shape in
      (shape, makeTile(image: DrawingCanvasView.shapePreviewImage(shape, size: tileSize), title: shape.title) { [weak self] in
        self?.didSelectDrawShape(shape)
      })
    }
    let toolStack = UIStackView(arrangedSubviews: drawToolButtons.map(\.1))
    toolStack.spacing = 4
    let toolDivider = UIView()
    toolDivider.backgroundColor = EditorDesignTokens.Colors.divider
    toolDivider.translatesAutoresizingMaskIntoConstraints = false
    toolDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
    toolDivider.heightAnchor.constraint(equalToConstant: 28).isActive = true
    let brushTiles = UIStackView(arrangedSubviews: drawBrushTypeButtons.map(\.1))
    brushTiles.spacing = 8
    let shapeTiles = UIStackView(arrangedSubviews: drawShapeButtons.map(\.1))
    shapeTiles.spacing = 8
    drawBrushTilesRef = brushTiles
    drawShapeTilesRef = shapeTiles
    let drawBrushTileRow = UIStackView(arrangedSubviews: [toolStack, toolDivider, brushTiles, shapeTiles])
    drawBrushTileRow.axis = .horizontal
    drawBrushTileRow.spacing = 10
    drawBrushTileRow.alignment = .center
    var drawBrushTypeRow: UIView = makeHorizontalScrollRow(content: drawBrushTileRow, height: tileSize.height)
    if !isStoryMode {
      // Regular editor: tools on their own row, then the brushes (or
      // shapes) on a scrolling row below.
      let tileRow = UIStackView(arrangedSubviews: [brushTiles, shapeTiles])
      tileRow.axis = .horizontal
      tileRow.spacing = 8
      tileRow.alignment = .center
      let toolRow = UIStackView(arrangedSubviews: [toolStack, UIView()])
      toolRow.axis = .horizontal
      let column = UIStackView(arrangedSubviews: [toolRow, makeHorizontalScrollRow(content: tileRow, height: tileSize.height)])
      column.axis = .vertical
      column.spacing = 12
      drawBrushTypeRow = column
    }
    drawColorScrollRef = drawColorScroll
    drawColorScrollRef = drawColorScroll

    let drawWidthLabel = UILabel()
    drawWidthLabel.text = "Size"
    drawWidthLabel.textColor = EditorDesignTokens.Colors.textPrimary
    drawWidthLabel.font = .systemFont(ofSize: 12)
    drawWidthLabel.setContentHuggingPriority(.required, for: .horizontal)

    let drawWidthMinPoints: CGFloat = 2
    let drawWidthMaxPoints: CGFloat = 28
    let drawWidthSlider = UISlider()
    drawWidthSlider.minimumValue = Float(drawWidthMinPoints)
    drawWidthSlider.maximumValue = Float(drawWidthMaxPoints)
    drawWidthSlider.value = Float(selectedDrawWidthPoints)
    drawWidthSlider.setMinimumTrackImage(MediaEditorViewController.makeSliderTrackImage(color: EditorDesignTokens.Colors.accent), for: .normal)
    drawWidthSlider.setMaximumTrackImage(MediaEditorViewController.makeSliderTrackImage(color: EditorDesignTokens.Colors.divider), for: .normal)
    drawWidthSlider.setThumbImage(MediaEditorViewController.makeSliderThumbImage(), for: .normal)
    drawWidthSlider.addAction(UIAction { [weak self, weak drawWidthSlider] _ in
      guard let self, let value = drawWidthSlider?.value else { return }
      if self.selectedDrawTool == .eraser {
        self.drawEraserWidthPoints = CGFloat(value)
      } else {
        self.selectedDrawWidthPoints = CGFloat(value)
      }
      self.drawingCanvasView.currentWidthPoints = CGFloat(value)
    }, for: .valueChanged)
    drawWidthSliderRef = drawWidthSlider
    drawingCanvasView.currentWidthPoints = selectedDrawWidthPoints

    let drawWidthRow = UIStackView(arrangedSubviews: [drawWidthLabel, drawWidthSlider])
    drawWidthRow.axis = .horizontal
    drawWidthRow.spacing = 12
    drawWidthRow.alignment = .center

    let drawPanelContent = UIStackView(arrangedSubviews: [drawBrushTypeRow, drawColorScroll, drawWidthRow])
    drawPanelContent.axis = .vertical
    drawPanelContent.spacing = 12
    drawPanelContent.translatesAutoresizingMaskIntoConstraints = false
    drawPanel.contentContainer.addSubview(drawPanelContent)
    NSLayoutConstraint.activate([
      drawPanelContent.topAnchor.constraint(equalTo: drawPanel.contentContainer.topAnchor),
      drawPanelContent.leadingAnchor.constraint(equalTo: drawPanel.contentContainer.leadingAnchor, constant: 16),
      drawPanelContent.trailingAnchor.constraint(equalTo: drawPanel.contentContainer.trailingAnchor, constant: -16),
    ])
    drawPanel.configureExpandedHeight(screenHeight: UIScreen.main.bounds.height)
    drawPanel.onConfirm = { [weak self] in
      self?.didTapToolsTab()
    }
    updateDrawPickerHighlights()
    setUpTextStylePanel()

    // Music panel (video only) — consolidates what used to be several
    // separate floating controls (track picker, its volume/trim, the
    // original clip's mute/volume) into one SlideUpPanelView, matching
    // Stickers/Draw. Reworked per the user's explicit "update UI of the
    // music trimmer + chosen song, provide a play/pause button, add a
    // remove-selected-song icon, both music controllers (added track +
    // original clip) should be here" request. While rebuilding this,
    // found musicButton/musicVolumeSlider/muteOriginalAudioButton/
    // originalAudioVolumeSlider/musicTrimView had NEVER had their
    // action/target wired up on iOS (Android's equivalent panel already
    // had all of this correctly wired) — every one of those controls was
    // purely decorative. Fixed alongside the redesign below.
    // Built for video always, and for a still image ONLY in story mode —
    // per the user's explicit "add music option on the photo story screen
    // too" request. The regular (non-story) image editor stays music-free:
    // musicTabButton is never added to its own bottom tray for isImage
    // (see the tabButtons array below in this same function), so this
    // panel's content simply never becomes reachable there even though it
    // now technically gets built for image+story too.
    if !isImage || isStoryMode {
      // Empty-state trigger — shown only when no track is selected yet;
      // once one is, musicTrackCard (below) takes over and this hides.
      // Video redesign (mockup "Music & audio"): dashed "+ Choose music
      // track" empty state; 64pt track card (green art tile, title,
      // "artist · plays 0:00–0:18", round play/pause, ✕); "Change track";
      // UPPERCASE volume headers with the % on the right and a full-width
      // slider underneath.
      var chooseConfig = UIButton.Configuration.plain()
      chooseConfig.title = "Choose music track"
      chooseConfig.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
      chooseConfig.imagePadding = 8
      chooseConfig.baseForegroundColor = EditorDesignTokens.Colors.textPrimary
      chooseConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
        var attrs = attrs
        attrs.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        return attrs
      }
      musicButton.configuration = chooseConfig
      musicButton.translatesAutoresizingMaskIntoConstraints = false
      musicButton.heightAnchor.constraint(equalToConstant: 64).isActive = true
      musicButton.addTarget(self, action: #selector(didTapMusic), for: .touchUpInside)
      musicButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)

      musicTrackCard.backgroundColor = EditorDesignTokens.Colors.elevatedSurface
      musicTrackCard.layer.cornerRadius = 14
      musicTrackCard.layer.cornerCurve = .continuous
      musicTrackCard.translatesAutoresizingMaskIntoConstraints = false
      musicTrackCard.heightAnchor.constraint(equalToConstant: 64).isActive = true
      musicTrackCard.isUserInteractionEnabled = true

      musicArtView.backgroundColor = EditorDesignTokens.Colors.musicLayer
      musicArtView.layer.cornerRadius = 10
      musicArtView.layer.cornerCurve = .continuous
      musicArtView.translatesAutoresizingMaskIntoConstraints = false
      let artIcon = UIImageView(image: UIImage(systemName: "music.note", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)))
      artIcon.tintColor = .white
      artIcon.translatesAutoresizingMaskIntoConstraints = false
      musicArtView.addSubview(artIcon)

      musicPlayPauseButton.setImage(Self.musicCardPlayImage(playing: true), for: .normal)
      musicPlayPauseButton.tintColor = .white
      musicPlayPauseButton.backgroundColor = EditorDesignTokens.Colors.divider
      musicPlayPauseButton.layer.cornerRadius = 20
      musicPlayPauseButton.accessibilityLabel = "Preview track"
      musicPlayPauseButton.translatesAutoresizingMaskIntoConstraints = false
      musicPlayPauseButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)
      musicPlayPauseButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)

      musicTrackTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
      musicTrackTitleLabel.textColor = EditorDesignTokens.Colors.textPrimary
      musicTrackTitleLabel.numberOfLines = 1
      musicTrackTitleLabel.lineBreakMode = .byTruncatingTail
      musicTrackSubtitleLabel.font = .systemFont(ofSize: 12)
      musicTrackSubtitleLabel.textColor = EditorDesignTokens.Colors.textSecondary
      musicTrackSubtitleLabel.numberOfLines = 1
      musicTrackSubtitleLabel.lineBreakMode = .byTruncatingTail
      let titleStack = UIStackView(arrangedSubviews: [musicTrackTitleLabel, musicTrackSubtitleLabel])
      titleStack.axis = .vertical
      titleStack.spacing = 2
      titleStack.translatesAutoresizingMaskIntoConstraints = false

      removeMusicButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
      removeMusicButton.tintColor = EditorDesignTokens.Colors.textSecondary
      removeMusicButton.accessibilityLabel = "Remove track"
      removeMusicButton.translatesAutoresizingMaskIntoConstraints = false
      removeMusicButton.addTarget(self, action: #selector(didTapRemoveMusic), for: .touchUpInside)
      removeMusicButton.addTarget(self, action: #selector(hapticMedium), for: .touchUpInside)

      musicTrackCard.addSubview(musicArtView)
      musicTrackCard.addSubview(titleStack)
      musicTrackCard.addSubview(musicPlayPauseButton)
      musicTrackCard.addSubview(removeMusicButton)
      NSLayoutConstraint.activate([
        musicArtView.leadingAnchor.constraint(equalTo: musicTrackCard.leadingAnchor, constant: 10),
        musicArtView.centerYAnchor.constraint(equalTo: musicTrackCard.centerYAnchor),
        musicArtView.widthAnchor.constraint(equalToConstant: 44),
        musicArtView.heightAnchor.constraint(equalToConstant: 44),
        artIcon.centerXAnchor.constraint(equalTo: musicArtView.centerXAnchor),
        artIcon.centerYAnchor.constraint(equalTo: musicArtView.centerYAnchor),

        removeMusicButton.trailingAnchor.constraint(equalTo: musicTrackCard.trailingAnchor, constant: -8),
        removeMusicButton.centerYAnchor.constraint(equalTo: musicTrackCard.centerYAnchor),
        removeMusicButton.widthAnchor.constraint(equalToConstant: 40),
        removeMusicButton.heightAnchor.constraint(equalToConstant: 40),

        musicPlayPauseButton.trailingAnchor.constraint(equalTo: removeMusicButton.leadingAnchor),
        musicPlayPauseButton.centerYAnchor.constraint(equalTo: musicTrackCard.centerYAnchor),
        musicPlayPauseButton.widthAnchor.constraint(equalToConstant: 40),
        musicPlayPauseButton.heightAnchor.constraint(equalToConstant: 40),

        titleStack.leadingAnchor.constraint(equalTo: musicArtView.trailingAnchor, constant: 12),
        titleStack.trailingAnchor.constraint(equalTo: musicPlayPauseButton.leadingAnchor, constant: -8),
        titleStack.centerYAnchor.constraint(equalTo: musicTrackCard.centerYAnchor),
      ])

      var changeConfig = UIButton.Configuration.plain()
      changeConfig.title = "Change track"
      changeConfig.baseForegroundColor = EditorDesignTokens.Colors.selectedToolTint
      changeConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
      changeConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
        var attrs = attrs
        attrs.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        return attrs
      }
      musicChangeTrackButton.configuration = changeConfig
      musicChangeTrackButton.contentHorizontalAlignment = .leading
      musicChangeTrackButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
      musicChangeTrackButton.addTarget(self, action: #selector(didTapMusic), for: .touchUpInside)
      musicChangeTrackButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)

      func sectionHeader(_ text: String) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(string: text, attributes: [
          .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
          .foregroundColor: EditorDesignTokens.Colors.textSecondary,
          .kern: 0.7,
        ])
        return label
      }
      func volumeBlock(header: String, slider: UISlider, valueLabel: UILabel, footnote: String?) -> UIStackView {
        valueLabel.text = "100%"
        valueLabel.textColor = EditorDesignTokens.Colors.textPrimary
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.textAlignment = .right
        let headerRow = UIStackView(arrangedSubviews: [sectionHeader(header), valueLabel])
        headerRow.axis = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.distribution = .equalSpacing
        styleVolumeSlider(slider)
        slider.value = 1
        slider.heightAnchor.constraint(equalToConstant: 32).isActive = true
        var views: [UIView] = [headerRow, slider]
        if let footnote {
          let note = UILabel()
          note.text = footnote
          note.font = .systemFont(ofSize: 12)
          note.textColor = EditorDesignTokens.Colors.textSecondary
          views.append(note)
        }
        let block = UIStackView(arrangedSubviews: views)
        block.axis = .vertical
        block.spacing = 4
        return block
      }

      let addedMusicHeaderLabel = sectionHeader("ADDED MUSIC")
      musicVolumeSlider.addTarget(self, action: #selector(musicVolumeChanged(_:)), for: .valueChanged)
      let musicVolumeBlock = volumeBlock(header: "MUSIC VOLUME", slider: musicVolumeSlider, valueLabel: musicVolumeValueLabel, footnote: nil)
      musicVolumeRow.axis = .vertical
      musicVolumeRow.addArrangedSubview(musicVolumeBlock)

      var musicPanelContentViews: [UIView] = [
        addedMusicHeaderLabel, musicButton, musicTrackCard, musicChangeTrackButton, musicVolumeRow,
      ]
      var originalAudioVolumeRowForSpacing: UIStackView?
      if !isImage {
        originalAudioVolumeSlider.addTarget(self, action: #selector(originalAudioVolumeChanged(_:)), for: .valueChanged)
        let originalAudioVolumeRow = volumeBlock(header: "ORIGINAL AUDIO", slider: originalAudioVolumeSlider,
                                                 valueLabel: originalAudioVolumeValueLabel, footnote: "0% mutes the clip's own sound")
        musicPanelContentViews.append(originalAudioVolumeRow)
        originalAudioVolumeRowForSpacing = originalAudioVolumeRow
        if !isStoryMode {
          // Fade in/out audio: music + the clip's own sound.
          musicPanelContentViews.append(sectionHeader("FADE"))
          for (title, isIn) in [("Fade in", true), ("Fade out", false)] {
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 15)
            label.textColor = EditorDesignTokens.Colors.textPrimary
            let toggle = UISwitch()
            toggle.onTintColor = EditorDesignTokens.Colors.accent
            toggle.isOn = isIn ? audioFadeIn : audioFadeOut
            toggle.addAction(UIAction { [weak self] action in
              guard let self, let sw = action.sender as? UISwitch else { return }
              if isIn { self.audioFadeIn = sw.isOn } else { self.audioFadeOut = sw.isOn }
              self.player?.volume = self.effectivePlayerVolume()
            }, for: .valueChanged)
            let row = UIStackView(arrangedSubviews: [label, toggle])
            row.axis = .horizontal
            row.alignment = .center
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            musicPanelContentViews.append(row)
          }
          let fadeNote = UILabel()
          fadeNote.text = "1-second fade on the music and the video's own sound"
          fadeNote.font = .systemFont(ofSize: 12)
          fadeNote.textColor = EditorDesignTokens.Colors.textSecondary
          fadeNote.numberOfLines = 0
          musicPanelContentViews.append(fadeNote)
          // Beat sync.
          musicPanelContentViews.append(sectionHeader("BEAT SYNC"))
          let beatLabel = UILabel()
          beatLabel.text = "Snap cuts to beat"
          beatLabel.font = .systemFont(ofSize: 15)
          beatLabel.textColor = EditorDesignTokens.Colors.textPrimary
          let beatToggle = UISwitch()
          beatToggle.onTintColor = EditorDesignTokens.Colors.accent
          beatToggle.isOn = beatSnapEnabled
          beatToggle.addAction(UIAction { [weak self] action in
            guard let self, let sw = action.sender as? UISwitch else { return }
            self.beatSnapEnabled = sw.isOn
          }, for: .valueChanged)
          let beatRow = UIStackView(arrangedSubviews: [beatLabel, beatToggle])
          beatRow.axis = .horizontal
          beatRow.alignment = .center
          beatRow.heightAnchor.constraint(equalToConstant: 40).isActive = true
          musicPanelContentViews.append(beatRow)
          let beatNote = UILabel()
          beatNote.font = .systemFont(ofSize: 12)
          beatNote.textColor = EditorDesignTokens.Colors.textSecondary
          beatNote.numberOfLines = 0
          musicPanelContentViews.append(beatNote)
          beatSyncNoteLabel = beatNote
          updateBeatSyncNote()
        }
      }

      let musicPanelContent = UIStackView(arrangedSubviews: musicPanelContentViews)
      musicPanelContent.axis = .vertical
      musicPanelContent.spacing = 8
      musicPanelContent.setCustomSpacing(4, after: musicTrackCard)
      musicPanelContent.setCustomSpacing(12, after: musicButton)
      musicPanelContent.setCustomSpacing(12, after: musicChangeTrackButton)
      musicPanelContent.setCustomSpacing(16, after: musicVolumeRow)
      if let originalAudioVolumeRowForSpacing {
        musicPanelContent.setCustomSpacing(8, after: originalAudioVolumeRowForSpacing)
      }
      musicPanelContent.translatesAutoresizingMaskIntoConstraints = false

      let musicPanelScrollView = UIScrollView()
      musicPanelScrollView.translatesAutoresizingMaskIntoConstraints = false
      musicPanelScrollView.showsVerticalScrollIndicator = false
      musicPanel.contentContainer.addSubview(musicPanelScrollView)
      musicPanelScrollView.addSubview(musicPanelContent)
      NSLayoutConstraint.activate([
        musicPanelScrollView.topAnchor.constraint(equalTo: musicPanel.contentContainer.topAnchor),
        musicPanelScrollView.leadingAnchor.constraint(equalTo: musicPanel.contentContainer.leadingAnchor),
        musicPanelScrollView.trailingAnchor.constraint(equalTo: musicPanel.contentContainer.trailingAnchor),
        musicPanelScrollView.bottomAnchor.constraint(equalTo: musicPanel.contentContainer.bottomAnchor),

        musicPanelContent.topAnchor.constraint(equalTo: musicPanelScrollView.contentLayoutGuide.topAnchor),
        musicPanelContent.bottomAnchor.constraint(equalTo: musicPanelScrollView.contentLayoutGuide.bottomAnchor, constant: -8),
        musicPanelContent.leadingAnchor.constraint(equalTo: musicPanelScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
        musicPanelContent.trailingAnchor.constraint(equalTo: musicPanelScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
        musicPanelContent.widthAnchor.constraint(equalTo: musicPanelScrollView.frameLayoutGuide.widthAnchor, constant: -32),
      ])

      // Taller default than the standard panel token so the added-music
      // controls fit without needing a drag-to-expand first; the
      // original-audio section is still reachable via the scroll view
      // above even at this height.
      // Video's full-screen sheet fits the restyled card + both volumes.
      musicPanel.setCollapsedHeight(isImage || isStoryMode ? 300 : 330)
      musicPanel.configureExpandedHeight(screenHeight: UIScreen.main.bounds.height)
      musicPanel.onConfirm = { [weak self] in
        self?.didTapToolsTab()
      }

      updateMusicTrackUI()
    }

    view.addSubview(topBar)
    topBar.addSubview(cancelButton)
    topBar.addSubview(undoButton)
    topBar.addSubview(redoButton)
    if let compareButton {
      if isImage {
        topBar.addSubview(compareButton)
      } else {
        // Video: compare lives in the play/split/delete row, left of "+";
        // Export takes its top-right spot.
        view.addSubview(compareButton)
        compareButton.isHidden = true
        topBar.addSubview(doneButton)
      }
    }
    // Story mode builds its own top-right Share button reusing
    // `doneButton` directly (see setUpStoryModeChrome) — kept out of
    // topBar so it isn't hidden along with the rest of the old chrome.
    // Regular editor: no Done here any more — EXPORT (bottom bar) saves.
    view.addSubview(effectPanel)
    view.addSubview(editPanel)
    view.addSubview(stickersPanel)
    view.addSubview(drawPanel)
    view.addSubview(textStylePanel)
    view.addSubview(toolsGridPanel)
    stickersPanelKeyboardConstraint = stickersPanel.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor)
    if !isImage || isStoryMode {
      view.addSubview(musicPanel)
    }
    view.addSubview(bottomTrayCardView)

    let safe = view.safeAreaLayoutGuide
    let topBarPadding = EditorDesignTokens.Spacing.topBarHorizontalPadding
    var chromeConstraints: [NSLayoutConstraint] = [
      topBar.topAnchor.constraint(equalTo: safe.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.heightAnchor.constraint(equalToConstant: EditorDesignTokens.Spacing.topBarHeight),

      cancelButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
      cancelButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: topBarPadding),

      undoButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
      undoButton.trailingAnchor.constraint(equalTo: topBar.centerXAnchor, constant: -4),

      redoButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
      redoButton.leadingAnchor.constraint(equalTo: topBar.centerXAnchor, constant: 4),

      bottomTrayCardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomTrayCardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomTrayCardView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
      bottomTrayCardView.heightAnchor.constraint(equalToConstant: trayHeight
        + lookToolsBarHeight),

      bottomTrayScrollView.leadingAnchor.constraint(equalTo: bottomTrayCardView.leadingAnchor),
      bottomTrayScrollView.trailingAnchor.constraint(equalTo: bottomTrayCardView.trailingAnchor),
      bottomTrayScrollView.topAnchor.constraint(equalTo: bottomTrayCardView.topAnchor),
      // The tool rail is the top part of the card; the LOOKS · TOOLS ·
      // EXPORT bar (setUpLookToolsBar) fills the rest.
      bottomTrayScrollView.heightAnchor.constraint(equalToConstant: trayHeight),

      // Standard "self-sizing content, centered if smaller than the
      // viewport, scrollable if larger" pattern: pin to the content guide
      // on all 4 edges plus center X, with inequality leading/trailing so
      // the stack is free to be narrower than the scroll view without
      // creating a conflicting exact-width constraint.
      bottomTabBar.topAnchor.constraint(equalTo: bottomTrayScrollView.contentLayoutGuide.topAnchor),
      bottomTabBar.bottomAnchor.constraint(equalTo: bottomTrayScrollView.contentLayoutGuide.bottomAnchor),
      bottomTabBar.heightAnchor.constraint(equalTo: bottomTrayScrollView.frameLayoutGuide.heightAnchor),
      // Every tool fits across the screen in equal slots — no scrolling.
      // Pinned on both sides so the content is exactly one screen wide
      // (centring alone left the content width undefined: tools went off
      // the left edge).
      // Inside the glass capsule (inset from the screen edges).
      bottomTabBar.leadingAnchor.constraint(equalTo: bottomTrayScrollView.contentLayoutGuide.leadingAnchor, constant: toolGlassInsetH + 4),
      bottomTabBar.trailingAnchor.constraint(equalTo: bottomTrayScrollView.contentLayoutGuide.trailingAnchor, constant: -(toolGlassInsetH + 4)),
      // At least one screen wide (equal slots across the capsule). On a
      // narrow iPhone where the full tool names don't fit, it grows wider
      // (each slot has a minimum width, see fitTabTitle's caller) and the
      // rail scrolls instead of cutting names to "Fil…".
      bottomTabBar.widthAnchor.constraint(greaterThanOrEqualTo: bottomTrayScrollView.frameLayoutGuide.widthAnchor, constant: -2 * (toolGlassInsetH + 4)),
      {
        let fit = bottomTabBar.widthAnchor.constraint(equalTo: bottomTrayScrollView.frameLayoutGuide.widthAnchor, constant: -2 * (toolGlassInsetH + 4))
        fit.priority = .defaultLow
        return fit
      }(),

      // Story mode's bottom tray is hidden (see below) but still fully
      // laid out/reserving its own height underneath — pinning to its
      // topAnchor there would leave that whole reserved strip as dead
      // space below the panel. Per the user's explicit "no vertical
      // distance should be between bottom of device and bottom sheet"
      // request, story mode pins straight to view.bottomAnchor instead —
      // truly flush with the screen edge, under the home indicator too.
      effectPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      effectPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // Mockup: Filters and Text sheets reach the screen edge (bar inside).
      effectPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      editPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      editPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      editPanel.bottomAnchor.constraint(equalTo: isStoryMode ? view.bottomAnchor : bottomTrayScrollView.topAnchor),

      stickersPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stickersPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      {
        // Breakable, so the keyboard constraint below can lift the panel.
        // To the screen bottom: the sheet covers the tool rail and
        // LOOKS · TOOLS · EXPORT while it's open (it grows by their height,
        // see didTapStickersTab).
        let constraint = stickersPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        constraint.priority = .defaultHigh
        return constraint
      }(),

      drawPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      drawPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // To the screen bottom: covers the tool rail and LOOKS · TOOLS ·
      // EXPORT while open (taller by their height, see didTapDrawTab).
      drawPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      textStylePanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textStylePanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textStylePanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      toolsGridPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      toolsGridPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // Mockup: the Tools sheet covers the tool rail and the LOOKS · TOOLS ·
      // EXPORT bar, down to the screen edge.
      toolsGridPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ]
    if let compareButton, isImage {
      // Top right, where Done used to be.
      chromeConstraints.append(contentsOf: [
        compareButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        compareButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -topBarPadding),
      ])
    } else if let compareButton, !isStoryMode {
      chromeConstraints.append(contentsOf: [
        doneButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        doneButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -topBarPadding),
        doneButton.widthAnchor.constraint(equalToConstant: 40),
        doneButton.heightAnchor.constraint(equalToConstant: 40),

        compareButton.trailingAnchor.constraint(equalTo: addLayerButton.leadingAnchor, constant: -4),
        // Shown in compare's spot while a merged clip is selected.
        clipTransitionButton.centerXAnchor.constraint(equalTo: compareButton.centerXAnchor),
        clipTransitionButton.centerYAnchor.constraint(equalTo: compareButton.centerYAnchor),
        clipTransitionButton.widthAnchor.constraint(equalToConstant: 36),
        clipTransitionButton.heightAnchor.constraint(equalToConstant: 36),
        textAnimationButton.centerXAnchor.constraint(equalTo: compareButton.centerXAnchor),
        textAnimationButton.centerYAnchor.constraint(equalTo: compareButton.centerYAnchor),
        textAnimationButton.widthAnchor.constraint(equalToConstant: 36),
        textAnimationButton.heightAnchor.constraint(equalToConstant: 36),
        compareButton.centerYAnchor.constraint(equalTo: splitSegmentButton.centerYAnchor),
        compareButton.widthAnchor.constraint(equalToConstant: 36),
        compareButton.heightAnchor.constraint(equalToConstant: 36),
      ])
    }
    NSLayoutConstraint.activate(chromeConstraints)
    if !isStoryMode {
      // Each top control sits on its own glass: ✕ and compare as circles,
      // undo + redo sharing one capsule.
      GlassSurfaceView.install(around: [cancelButton], in: topBar, shape: .capsule, pad: 0)
      GlassSurfaceView.install(around: [undoButton, redoButton], in: topBar, shape: .capsule, pad: 0)
      if let compareButton, isImage {
        GlassSurfaceView.install(around: [compareButton], in: topBar, shape: .capsule, pad: 0)
      }

    }
    if !isImage || isStoryMode {
      NSLayoutConstraint.activate([
        musicPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        musicPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        // Story: flush with the screen edge. Video: full-screen Music
        // sheet with its own ✕ · Music · ✓ bar (video redesign).
        musicPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }

    // Story mode: hide the old Cancel/Undo/Redo/Done top bar and the
    // horizontal tab tray (still fully laid out underneath, just
    // invisible — the tool panels above still anchor to
    // bottomTrayScrollView.topAnchor unchanged) and build the
    // Instagram-style chrome instead. Every new button calls the exact
    // same engine methods the old tab tray already used.
    if isStoryMode {
      topBar.isHidden = true
      bottomTrayCardView.isHidden = true
      setUpStoryModeChrome(safe: safe, isImage: isImage)
    }

    updateImageEditorUI()
    updateFilterButtonHighlight()
  }

  // MARK: - Story mode chrome

  /// Instagram-style story chrome: X close top-left, a top-right "Share"
  /// button (the existing `doneButton`, just repositioned/relabeled) on
  /// the same row, and a right-edge vertical icon rail below that
  /// (Text/Stickers/Filters/Overlay-or-Audio/Draw/Download). Every icon
  /// calls the SAME private engine methods
  /// the old Cancel/Undo/Redo/Done top bar + tab tray already used —
  /// nothing about canvas/gesture/filter/export/music logic changes here.
  private func setUpStoryModeChrome(safe: UILayoutGuide, isImage: Bool) {
    let closeButton = MediaEditorViewController.makeTopBarIconButton(systemImageName: "xmark")
    closeButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
    view.addSubview(closeButton)

    // Undo/Redo centered in the top row between X and Share — the regular
    // topBar's own pair is hidden along with it in story mode. Same
    // didTapUndo/didTapRedo targets; mirrors Android's storyUndoRedoRow.
    let storyUndoButton = MediaEditorViewController.makeTopBarIconButton(systemImageName: "arrow.uturn.backward")
    storyUndoButton.addTarget(self, action: #selector(didTapUndo), for: .touchUpInside)
    storyUndoButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)
    view.addSubview(storyUndoButton)
    let storyRedoButton = MediaEditorViewController.makeTopBarIconButton(systemImageName: "arrow.uturn.forward")
    storyRedoButton.addTarget(self, action: #selector(didTapRedo), for: .touchUpInside)
    storyRedoButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)
    view.addSubview(storyRedoButton)

    var rows: [UIView] = [
      makeStoryToolRow(systemImageName: "textformat", label: "Text", action: #selector(presentTextEntryOverlay)),
      makeStoryToolRow(systemImageName: "face.smiling", label: "Stickers", action: #selector(didTapStickersTab)),
      makeStoryToolRow(systemImageName: "camera.filters", label: "Filters", action: #selector(didTapEffectTab)),
      // Adjust (brightness, contrast, …) — the same Tune tool as the editor.
      makeStoryToolRow(systemImageName: "slider.horizontal.3", label: "Adjust", action: #selector(didTapEditTab)),
    ]
    // Overlay (image-over-image) is still image-only, mirroring the
    // existing tab tray (see isImage branching above). Music, unlike the
    // regular tray, is available for BOTH media types in story mode — per
    // the user's explicit "add music option on the photo story screen too"
    // request, picking a track for a photo mixes it into an exported video
    // on Share (see exportImageWithMusic).
    if isImage {
      rows.append(makeStoryToolRow(systemImageName: "square.on.square", label: "Overlay", action: #selector(presentImageOverlayPicker)))
    }
    rows.append(makeStoryToolRow(systemImageName: "scribble", label: "Draw", action: #selector(didTapDrawTab)))
    // Video only — a still image has no original audio track to mute. See
    // storyMuteButton's own doc for why this isn't just the old (removed)
    // muteOriginalAudioButton coming back.
    if !isImage {
      rows.append(makeStoryMuteRow())
    }
    // presentStoryMusicPicker (not didTapMusicTab) — the story rail skips
    // the regular editor's half-height "Choose Music Track" panel entirely
    // and opens the full picker directly on first tap. didTapMusicTab
    // (half-sheet) stays exactly as-is for the regular non-story editor.
    rows.append(makeStoryToolRow(systemImageName: "music.note", label: "Audio", action: #selector(presentStoryMusicPicker)))
    rows.append(makeStoryToolRow(systemImageName: "square.and.arrow.down", label: "Download", action: #selector(didTapDownloadToGallery)))
    rows.append(makeStoryToolRow(systemImageName: "mappin.and.ellipse", label: "Location", action: #selector(didTapStoryLocation)))
    // "Tags" (link / hashtag / time / date stickers) removed from the
    // story rail (user request).

    let rail = UIStackView(arrangedSubviews: rows)
    rail.axis = .vertical
    // 10 tools now (Adjust + Tags added) — tighter so the rail clears the
    // top bar's Share button on shorter iPhones.
    rail.spacing = 8
    rail.alignment = .trailing
    rail.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(rail)

    view.addSubview(doneButton)
    // Plain text, no filled pill — per the user's explicit "remove the
    // purple background off the Share button" request. Matches the
    // regular top bar's own Cancel/Done/Undo/Redo (all textPrimary/white,
    // see doneButton's shared init styling) and SlideUpPanelView's
    // confirmButton, which dropped this exact same accent-purple pill
    // for the same reason previously.
    doneButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 0)

    // X / Undo / Redo / Share float over the story with no backing, so give
    // them the same soft shadow as the rail labels — keeps white glyphs
    // readable over bright or white photos (now that story images are
    // aspect-fit, a light photo can sit right under them).
    [closeButton, storyUndoButton, storyRedoButton, doneButton].forEach(MediaEditorViewController.applyStoryLegibilityShadow)
    storyChromeViews = [closeButton, storyUndoButton, storyRedoButton, doneButton, rail]

    NSLayoutConstraint.activate([
      closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: MediaEditorViewController.storyTopGap),
      closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: EditorDesignTokens.Spacing.topBarHorizontalPadding),

      // Shifted up from dead-center per the user's explicit "move the
      // right-hand icon rail a little more upside" request.
      rail.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
      rail.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -EditorDesignTokens.Spacing.topBarHorizontalPadding),

      // Top-right, opposite the close button — per the user's explicit
      // "keep Share button on right top, opposite to cross sign" request.
      doneButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      doneButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -EditorDesignTokens.Spacing.topBarHorizontalPadding),

      storyUndoButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      storyUndoButton.trailingAnchor.constraint(equalTo: view.centerXAnchor, constant: -4),
      storyRedoButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      storyRedoButton.leadingAnchor.constraint(equalTo: view.centerXAnchor, constant: 4),
    ])

    setUpStoryMusicBadge(safe: safe, closeButton: closeButton, doneButton: doneButton)
  }

  /// Top-center "now playing" pill, shown only while isStoryMode &&
  /// selectedMusicTrack != nil (see updateStoryMusicBadge). Reuses the
  /// SAME dark-translucent-circle visual language as makeStoryRailButton
  /// (UIColor.black.withAlphaComponent(0.35), textPrimary tint) rather than
  /// inventing a new style. Sits just below the X / Undo / Redo / Share
  /// row, horizontally centered — the icon rail sits further down (see the
  /// rail constraints just above), so there's no collision to worry about here.
  private func setUpStoryMusicBadge(safe: UILayoutGuide, closeButton: UIButton, doneButton: UIButton) {
    storyMusicBadge.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    storyMusicBadge.layer.cornerRadius = 16
    storyMusicBadge.clipsToBounds = true
    storyMusicBadge.translatesAutoresizingMaskIntoConstraints = false
    storyMusicBadge.isHidden = true
    storyMusicBadge.isUserInteractionEnabled = true
    // Mirrors musicTrackCard's own "tap the card body to act on it, tap
    // the nested remove button to remove it" pattern (see didTapMusic's
    // musicTrackCard.addGestureRecognizer usage above) — same established
    // shape elsewhere in this file for a container + nested button.
    storyMusicBadge.addGestureRecognizer(
      UITapGestureRecognizer(target: self, action: #selector(didTapStoryMusicBadge))
    )

    // Status icon only — isUserInteractionEnabled = false so a tap here
    // still falls through to the badge's own tap gesture above rather than
    // needing a second identical target-action.
    storyMusicBadgePlayPauseButton.tintColor = EditorDesignTokens.Colors.textPrimary
    storyMusicBadgePlayPauseButton.isUserInteractionEnabled = false
    storyMusicBadgePlayPauseButton.translatesAutoresizingMaskIntoConstraints = false

    storyMusicBadgeLabel.font = EditorDesignTokens.Typography.trayLabel
    storyMusicBadgeLabel.textColor = EditorDesignTokens.Colors.textPrimary
    storyMusicBadgeLabel.numberOfLines = 1
    storyMusicBadgeLabel.lineBreakMode = .byTruncatingTail
    storyMusicBadgeLabel.translatesAutoresizingMaskIntoConstraints = false

    storyMusicBadgeRemoveButton.setImage(
      UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)),
      for: .normal
    )
    storyMusicBadgeRemoveButton.tintColor = EditorDesignTokens.Colors.textPrimary
    storyMusicBadgeRemoveButton.translatesAutoresizingMaskIntoConstraints = false
    storyMusicBadgeRemoveButton.addTarget(self, action: #selector(didTapRemoveMusic), for: .touchUpInside)
    storyMusicBadgeRemoveButton.addTarget(self, action: #selector(hapticMedium), for: .touchUpInside)

    storyMusicBadge.addSubview(storyMusicBadgePlayPauseButton)
    storyMusicBadge.addSubview(storyMusicBadgeLabel)
    storyMusicBadge.addSubview(storyMusicBadgeRemoveButton)
    view.addSubview(storyMusicBadge)

    NSLayoutConstraint.activate([
      storyMusicBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      // Just below the X / Undo / Redo / Share row (Undo/Redo now occupy
      // its center) — same placement as Android's story music badge.
      storyMusicBadge.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 12),
      storyMusicBadge.heightAnchor.constraint(equalToConstant: 32),
      storyMusicBadge.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
      storyMusicBadge.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

      storyMusicBadgePlayPauseButton.leadingAnchor.constraint(equalTo: storyMusicBadge.leadingAnchor, constant: 6),
      storyMusicBadgePlayPauseButton.centerYAnchor.constraint(equalTo: storyMusicBadge.centerYAnchor),
      storyMusicBadgePlayPauseButton.widthAnchor.constraint(equalToConstant: 20),
      storyMusicBadgePlayPauseButton.heightAnchor.constraint(equalToConstant: 20),

      storyMusicBadgeLabel.leadingAnchor.constraint(equalTo: storyMusicBadgePlayPauseButton.trailingAnchor, constant: 6),
      storyMusicBadgeLabel.centerYAnchor.constraint(equalTo: storyMusicBadge.centerYAnchor),
      storyMusicBadgeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160),

      storyMusicBadgeRemoveButton.leadingAnchor.constraint(equalTo: storyMusicBadgeLabel.trailingAnchor, constant: 6),
      storyMusicBadgeRemoveButton.trailingAnchor.constraint(equalTo: storyMusicBadge.trailingAnchor, constant: -8),
      storyMusicBadgeRemoveButton.centerYAnchor.constraint(equalTo: storyMusicBadge.centerYAnchor),
      storyMusicBadgeRemoveButton.widthAnchor.constraint(equalToConstant: 20),
      storyMusicBadgeRemoveButton.heightAnchor.constraint(equalToConstant: 20),
    ])
  }

  /// Story rail's Audio button — skips didTapMusicTab's half-height panel
  /// (the regular non-story editor's own flow, left untouched) and opens
  /// the full MusicPickerViewController directly, matching the "tapping
  /// any creating tool pauses the live preview" convention every other
  /// story-rail action already follows (pauseVideoForToolInteraction).
  /// didTapMusic() itself is fully standalone (just presents the picker
  /// and wires onSelect to selectMusicTrack) — no half-sheet/tab-state
  /// dependency to work around.
  @objc private func presentStoryMusicPicker() {
    // Pause while the picker is up (its own track previews would overlap
    // the video's audio), then resume the loop once it's dismissed —
    // story mode has no play button to resume with.
    let wasPlaying = player?.timeControlStatus == .playing
    if wasPlaying { didTapPlayPause() }
    // A photo story has no video player: pause its song directly.
    let songWasPlaying = mediaType == "image" && (musicPlayer?.rate ?? 0) != 0
    if songWasPlaying { musicPlayer?.pause() }
    let trackBefore = selectedMusicTrack?.audioURL
    presentMusicPicker { [weak self] in
      guard let self else { return }
      if songWasPlaying, self.selectedMusicTrack?.audioURL == trackBefore, !self.isStoryMusicPausedByUser {
        self.musicPlayer?.play()
        self.updateStoryMusicBadge()
      }
      guard wasPlaying, let player = self.player, player.timeControlStatus != .playing else { return }
      self.didTapPlayPause()
    }
  }

  /// Story badge tap target. For a still image there is no main `player`
  /// (didTapPlayPause no-ops there via its own `guard let player else
  /// {return}`), so this toggles musicPlayer directly; for video it defers
  /// to the existing didTapPlayPause(), which already keeps player and
  /// musicPlayer in lockstep (and now also refreshes this badge's icon —
  /// see the updateStoryMusicBadge() call added at the end of
  /// didTapPlayPause).
  @objc private func didTapStoryMusicBadge() {
    guard let musicPlayer else { return }
    // Only the song (the video story keeps looping) — same as Android.
    if musicPlayer.rate != 0 {
      isStoryMusicPausedByUser = true
      musicPlayer.pause()
    } else {
      isStoryMusicPausedByUser = false
      if mediaType == "image" { musicPlayer.play() } else { updateMusicPlaybackWindow() }
    }
    updateStoryMusicBadge()
  }

  /// Story badge pause must stick: the playback window would otherwise
  /// restart the song on the next tick.
  private var isStoryMusicPausedByUser = false

  /// Refreshes the story-mode badge's visibility/title/play-pause icon.
  /// Safe to call unconditionally (no-ops outside story mode, since the
  /// badge is never added to the view hierarchy there) — called from
  /// selectMusicTrack (both picking and clearing a track) and from
  /// didTapPlayPause/didTapStoryMusicBadge whenever playback state flips.
  private func updateStoryMusicBadge() {
    guard isStoryMode else { return }
    guard let track = selectedMusicTrack else {
      storyMusicBadge.isHidden = true
      return
    }
    storyMusicBadge.isHidden = false
    storyMusicBadgeLabel.text = track.title
    let isPlaying = mediaType == "image" ? (musicPlayer?.timeControlStatus == .playing) : isVideoPlaying
    storyMusicBadgePlayPauseButton.setImage(
      UIImage(
        systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)
      ),
      for: .normal
    )
  }

  /// One story-toolbar row: a small right-aligned label next to a circular
  /// dark icon button, matching the Instagram-style rail from the user's
  /// reference screenshot.
  private func makeStoryToolRow(systemImageName: String, label: String, action: Selector) -> UIView {
    let button = MediaEditorViewController.makeStoryRailButton(systemImageName: systemImageName)
    button.addTarget(self, action: action, for: .touchUpInside)

    let labelView = UILabel()
    labelView.text = label
    labelView.font = MediaEditorViewController.storyRailLabelFont
    labelView.textColor = EditorDesignTokens.Colors.textPrimary
    labelView.translatesAutoresizingMaskIntoConstraints = false
    MediaEditorViewController.applyStoryLegibilityShadow(labelView)

    let row = UIStackView(arrangedSubviews: [labelView, button])
    row.axis = .horizontal
    row.spacing = 8
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    return row
  }

  /// Same shape as makeStoryToolRow, but uses the STORED storyMuteButton
  /// (not a throwaway one) so toggleStoryOriginalAudioMute can update its
  /// icon later to reflect mute state — makeStoryToolRow's own button
  /// isn't kept around since none of its other rows need to change their
  /// icon after the fact.
  private func makeStoryMuteRow() -> UIView {
    storyMuteButton.addTarget(self, action: #selector(toggleStoryOriginalAudioMute), for: .touchUpInside)

    let labelView = UILabel()
    labelView.text = "Mute"
    labelView.font = MediaEditorViewController.storyRailLabelFont
    labelView.textColor = EditorDesignTokens.Colors.textPrimary
    labelView.translatesAutoresizingMaskIntoConstraints = false
    MediaEditorViewController.applyStoryLegibilityShadow(labelView)

    let row = UIStackView(arrangedSubviews: [labelView, storyMuteButton])
    row.axis = .horizontal
    row.spacing = 8
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    return row
  }

  /// Toggles the ORIGINAL video clip's own audio on/off by driving
  /// originalAudioVolumeSlider (0%/100%) through its existing
  /// originalAudioVolumeChanged handler — the exact same state exportVideo
  /// already reads (originalAudioEffectiveVolume), so this stays correct
  /// on export with no export-side changes needed. Label stays "Mute"
  /// (an action, like the rest of the rail's labels — Text/Stickers/etc.
  /// describe what tapping DOES, not the current state); only the icon
  /// flips between speaker/speaker-muted to show current state.
  @objc private func toggleStoryOriginalAudioMute() {
    let newValue: Float = originalAudioVolumeSlider.value > 0 ? 0 : 1
    originalAudioVolumeSlider.value = newValue
    originalAudioVolumeChanged(originalAudioVolumeSlider)
    storyMuteButton.setImage(
      UIImage(systemName: newValue > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill"),
      for: .normal
    )
  }

  /// Solid dark circular icon button for the story-mode rail — distinct
  /// from `makeTopBarIconButton` (which sits directly on the opaque topBar
  /// strip and needs no background of its own), since these sit directly
  /// over the live canvas/video.
  /// Soft dark drop shadow for white story chrome (labels, top-row icons)
  /// that floats straight over the media — matches Android's rail-label
  /// setShadowLayer(4, 0, 1, ~60% black).
  private static func applyStoryLegibilityShadow(_ view: UIView) {
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOpacity = 0.6
    view.layer.shadowRadius = 3
    view.layer.shadowOffset = CGSize(width: 0, height: 1)
    view.layer.masksToBounds = false
  }

  /// Story-mode rail label font — a step below EditorDesignTokens'
  /// trayLabel (11pt), per the user's "keep text on the left, but a little
  /// smaller" request. Matches Android's STORY_RAIL_LABEL_SP.
  private static let storyRailLabelFont = UIFont.systemFont(ofSize: 10, weight: .medium)

  private static func makeStoryRailButton(systemImageName: String) -> UIButton {
    let button = UIButton(type: .system)
    // The redesign's line icons (same drawings as the tool bar and Android),
    // drawn at 22pt inside the 40pt circle.
    let redesigned: [String: String] = [
      "textformat": "tool_text", "face.smiling": "tool_sticker", "camera.filters": "tool_filters",
      "square.on.square": "tool_overlay", "scribble": "tool_draw", "music.note": "tool_music",
    ]
    if let name = redesigned[systemImageName], let icon = UIImage(named: name) {
      let side: CGFloat = 22
      let resized = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
        icon.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
      }
      button.setImage(resized.withRenderingMode(.alwaysTemplate), for: .normal)
    } else {
      button.setImage(UIImage(systemName: systemImageName), for: .normal)
    }
    button.tintColor = EditorDesignTokens.Colors.textPrimary
    button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    button.translatesAutoresizingMaskIntoConstraints = false
    let size: CGFloat = 40
    button.widthAnchor.constraint(equalToConstant: size).isActive = true
    button.heightAnchor.constraint(equalToConstant: size).isActive = true
    button.layer.cornerRadius = size / 2
    return button
  }

  /// Download-to-gallery: exports the current edit exactly like Share does,
  /// but saves it to the device's Photos library and stays in the editor
  /// instead of calling `onDone`/dismissing. Guarded by the same
  /// `isExporting` flag Share uses so the two can't race.
  @objc private func didTapDownloadToGallery() {
    guard !isExporting else { return }
    isExporting = true
    loadingIndicator.startAnimating()

    let finish: () -> Void = { [weak self] in
      self?.isExporting = false
      self?.loadingIndicator.stopAnimating()
    }

    if mediaType == "image" {
      exportImage { [weak self] result in
        guard let self else { return finish() }
        switch result {
        case let .success(url, _):
          self.saveExportedFileToCameraRoll(fileURL: url, isVideo: false) { _ in finish() }
        case .failure:
          finish()
        }
      }
      return
    }

    exportVideo { [weak self] result in
      guard let self else { return finish() }
      switch result {
      case let .success(url, _, _):
        self.saveExportedFileToCameraRoll(fileURL: url, isVideo: true) { _ in finish() }
      case .failure:
        finish()
      }
    }
  }

  /// Saves an already-exported photo/video file to the device's Photos
  /// library without ending the editing session — adapted from
  /// modules/native-gallery/ios/NativeGallery.m's saveToCameraRoll (same
  /// PHPhotoLibrary API, called directly here instead of over the RN
  /// bridge; album placement is intentionally omitted — this always saves
  /// to the default camera roll).
  private func saveExportedFileToCameraRoll(fileURL: URL, isVideo: Bool, completion: @escaping (Bool) -> Void) {
    PHPhotoLibrary.shared().performChanges({
      if isVideo {
        _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
      } else {
        _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
      }
    }, completionHandler: { success, _ in
      DispatchQueue.main.async {
        completion(success)
      }
    })
  }

  @objc private func didTapToolsTab() {
    pauseVideoForToolInteraction()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    selectedImageEditorTab = .tools
    updateImageEditorUI(animated: true)
  }

  @objc private func didTapEffectTab() {
    pauseVideoForToolInteraction()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    selectedImageEditorTab = .effect
    updateImageEditorUI(animated: true)
  }

  @objc private func didTapEditTab() {
    pauseVideoForToolInteraction()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    selectedImageEditorTab = .edit
    updateImageEditorUI(animated: true)
  }

  /// Same top edge as before, now reaching down over the tool rail and
  /// LOOKS · TOOLS · EXPORT (regular editor).
  private func sizeStickersPanelOverToolRail() {
    guard !isStoryMode else { return }
    let covered = trayHeight + lookToolsBarHeight
      + view.safeAreaInsets.bottom
    stickersPanel.setCollapsedHeight(280 + covered)
  }

  @objc private func didTapStickersTab() {
    // Editing an existing sticker doesn't add a layer.
    if editingStickerLayer == nil, !canAddLayer() { return }
    sizeStickersPanelOverToolRail()
    pauseVideoForToolInteraction()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    selectedImageEditorTab = .stickers
    updateImageEditorUI(animated: true)
  }

  @objc private func didTapDrawTab() {
    if !isStoryMode {
      // Covers the tool rail, but only as tall as its rows (header, tools,
      // brushes, colours, size) above the home indicator — no empty space.
      drawPanel.setCollapsedHeight(248 + view.safeAreaInsets.bottom)
    }
    pauseVideoForToolInteraction()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    selectedImageEditorTab = .draw
    updateImageEditorUI(animated: true)
  }

  @objc private func didTapMusicTab() {
    pauseVideoForToolInteraction()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    selectedImageEditorTab = .music
    updateImageEditorUI(animated: true)
  }

  @objc private func didSelectDrawColor(_ color: UIColor) {
    UISelectionFeedbackGenerator().selectionChanged()
    selectedDrawColor = color
    drawingCanvasView.currentColor = color
    updateDrawPickerHighlights()
  }

  private func didSelectBrushType(_ brushType: DrawingCanvasView.BrushType) {
    UISelectionFeedbackGenerator().selectionChanged()
    selectedBrushType = brushType
    applyDrawTool(.brush)
  }

  private func didSelectDrawShape(_ shape: DrawingCanvasView.ShapeType) {
    UISelectionFeedbackGenerator().selectionChanged()
    selectedDrawShape = shape
    applyDrawTool(.shape)
  }

  private func didSelectDrawTool(_ tool: DrawTool) {
    UISelectionFeedbackGenerator().selectionChanged()
    applyDrawTool(tool)
  }

  /// Points the canvas at the tool: the eraser draws eraser strokes with
  /// its own size; a shape uses the selected brush's look.
  private func applyDrawTool(_ tool: DrawTool) {
    selectedDrawTool = tool
    drawingCanvasView.currentBrushType = tool == .eraser ? .eraser : selectedBrushType
    drawingCanvasView.currentShape = tool == .shape ? selectedDrawShape : nil
    let width = tool == .eraser ? drawEraserWidthPoints : selectedDrawWidthPoints
    drawingCanvasView.currentWidthPoints = width
    drawWidthSliderRef?.setValue(Float(width), animated: true)
    updateDrawPickerHighlights()
  }

  /// Same highlight recipe as updateTextEntryPickerHighlights's color
  /// swatches — a stroked circle, accent-colored + thicker when selected.
  private func updateDrawPickerHighlights() {
    for (index, swatch) in drawColorButtons.enumerated() {
      let isSelected = MediaEditorViewController.textColorSwatches[index] == selectedDrawColor
      swatch.layer.borderWidth = isSelected ? 2 : 1
      swatch.layer.borderColor = isSelected ? EditorDesignTokens.Colors.accent.cgColor : EditorDesignTokens.Colors.divider.cgColor
    }
    for (brushType, button) in drawBrushTypeButtons {
      button.layer.borderWidth = brushType == selectedBrushType ? 2 : 0
    }
    for (shape, button) in drawShapeButtons {
      button.layer.borderWidth = shape == selectedDrawShape ? 2 : 0
    }
    for (tool, button) in drawToolButtons {
      let selected = tool == selectedDrawTool
      button.backgroundColor = selected ? EditorDesignTokens.Colors.elevatedSurface : .clear
      button.configuration?.baseForegroundColor = selected ? EditorDesignTokens.Colors.accent : EditorDesignTokens.Colors.textPrimary
    }
    drawBrushTilesRef?.isHidden = selectedDrawTool != .brush
    drawShapeTilesRef?.isHidden = selectedDrawTool != .shape
    // Colour doesn't apply to the eraser.
    drawColorScrollRef?.alpha = selectedDrawTool == .eraser ? 0.35 : 1
    drawColorScrollRef?.isUserInteractionEnabled = selectedDrawTool != .eraser
  }

  /// `animated` is false only for the initial setup call (viewDidLoad) —
  /// no bounce/crossfade on first appearance, only on an actual tab switch.
  private func updateImageEditorUI(animated: Bool = false) {
    if selectedImageEditorTab != .stickers { stickerSearchField?.resignFirstResponder() }
    defer {
      // Panels and video controls change what the layer bar must sit above.
      DispatchQueue.main.async { [weak self] in self?.repositionLayerToolbar() }
    }
    if selectedImageEditorTab != .textStyle { commitTextStyleEdit() }
    if let session = toolSession, session.tab != selectedImageEditorTab {
      mergeUndoSteps(since: session.depth)
      toolSession = nil
    }
    if toolSession == nil, Self.sessionTabs.contains(selectedImageEditorTab) {
      toolSession = (selectedImageEditorTab, undoStack.count)
    }
    // Music isn't on the undo stack: snapshot it so ✕ can put it back.
    if selectedImageEditorTab == .music {
      if musicSessionSnapshot == nil {
        musicSessionSnapshot = MusicSessionSnapshot(
          track: selectedMusicTrack, offset: musicOffset, segments: musicSegments,
          selectedSegment: selectedMusicSegmentIndex, trimStart: musicTrimStart, trimEnd: musicTrimEnd,
          musicVolume: musicVolumeSlider.value, originalVolume: originalAudioVolumeSlider.value)
      }
    } else {
      musicSessionSnapshot = nil
    }
    defer {
      updateOverlayEraseCapture()
      updateBlurCover()
      updateTuneUI()
    }
    textStylePanel.setPanelVisible(selectedImageEditorTab == .textStyle, animated: animated)
    toolsGridPanel.setPanelVisible(selectedImageEditorTab == .toolsGrid, animated: animated)
    // Mockup: the photo is dimmed behind the Tools sheet.
    UIView.animate(withDuration: animated ? EditorDesignTokens.Motion.panelToggleDuration : 0) {
      self.filterStageView.alpha = self.selectedImageEditorTab == .toolsGrid ? 0.45 : 1
      // Video redesign: the video dims behind the Tools sheet too.
      if self.mediaType != "image" {
        self.canvasClipContainerView.alpha = self.selectedImageEditorTab == .toolsGrid ? 0.45 : 1
      }
    }
    updateLookToolsBar()
    effectPanel.setPanelVisible(selectedImageEditorTab == .effect, animated: animated)
    updateFilterStage(animated: animated)
    updateVideoStage(animated: animated)
    editPanel.setPanelVisible(selectedImageEditorTab == .edit && !isTuneActive, animated: animated)
    stickersPanel.setPanelVisible(selectedImageEditorTab == .stickers, animated: animated)
    drawPanel.setPanelVisible(selectedImageEditorTab == .draw, animated: animated)
    updateBlurOverlay()
    // Music panel visibility also applies to image+story mode (see the
    // isStoryMode-gated panel-content build in setUpEditingControls) —
    // pulled out of the video-only block below, which covers genuinely
    // video-specific chrome (trim scrubber/play-pause/filmstrip/layer
    // tracks) that doesn't apply to a still image even in story mode.
    if mediaType != "image" || isStoryMode {
      musicPanel.setPanelVisible(selectedImageEditorTab == .music, animated: animated)
    }
    if mediaType != "image" {
      // Trim scrubber + play/pause + per-layer track rows only make sense
      // on the Tools tab — any open panel (Effect/Edit/Sticker/Draw/Music)
      // floats in the exact same fixed position just above the tray and
      // visually collides with the panel's own content otherwise (user-
      // reported UI bug, screenshot), no matter how tall that panel is.
      // Hiding the row entirely here is simpler and more robust than the
      // per-panel extra-height workaround this replaces.
      let showVideoControls = selectedImageEditorTab == .tools
      // Story mode has no play/pause or main-video filmstrip at all —
      // the clip just loops continuously (Instagram-style).
      playPauseButton.isHidden = !showVideoControls || isStoryMode
      videoTimeLabel.isHidden = !showVideoControls || isStoryMode
      // filmstripScrollView/filmstripPlayheadView carry videoTrimView/
      // mergedStripView as their content now — hiding the scroll view
      // itself hides both together.
      filmstripScrollView.isHidden = !showVideoControls || isStoryMode
      filmstripPlayheadView.isHidden = !showVideoControls || isStoryMode
      // Split/Delete (multi-segment editing) and the layer-tracks row are
      // regular-editor-only in story mode — per the user's explicit
      // "delete, split and layer should not display" request, a story
      // video is already trimmed to its final length before the editor
      // even opens (see processVideo in StoryCameraScreen/
      // SimpleGalleryScreen), so segment splitting has no story-mode
      // affordance to justify it. playPauseButton/filmstrip stay governed
      // by showVideoControls alone — not part of this request.
      splitSegmentButton.isHidden = !showVideoControls || isStoryMode
      videoSelectionLabel.isHidden = !showVideoControls || isStoryMode
      deleteSegmentButton.isHidden = !showVideoControls || isStoryMode
      compareButton?.isHidden = !showVideoControls || isStoryMode
      updateLayerStateButtons()
      videoControlsBackdropView.isHidden = !showVideoControls || isStoryMode
      layerTracksScrollView.isHidden = !showVideoControls || isStoryMode
      layersAreaCollapseButton.isHidden = !showVideoControls || isStoryMode || allLayerViews().isEmpty
      updateLayersAreaExpansion(animated: animated)
    }

    // Draw intercepts every canvas touch while active (see
    // DrawingCanvasView's own doc) — deselect any active layer first so its
    // toolbar doesn't linger uninteractive over the canvas while drawing,
    // and disable every OTHER layer's own gestures too (unlike Android's
    // single shared coordinator, each iOS layer's gestures keep working
    // regardless of z-order unless explicitly disabled — see
    // setLayersOwnGesturesEnabled's doc).
    let isDrawActive = selectedImageEditorTab == .draw
    if isDrawActive {
      deselectLayer()
      setLayersOwnGesturesEnabled(false)
      setCanvasTransformGesturesEnabled(false)
      view.bringSubviewToFront(drawingCanvasView)
      keepSafeAreaCoversOnTop()
    } else {
      setLayersOwnGesturesEnabled(true)
      setCanvasTransformGesturesEnabled(true)
    }
    drawingCanvasView.isUserInteractionEnabled = isDrawActive

    // Icon/label color is now a CONSTANT white regardless of selection —
    // per the user's explicit "make these icons color white and just
    // make that which icons is active then show red dot below these
    // icon" request. The active tab is now signaled ONLY by the red dot
    // (...TabIndicator.alpha) below it — no more color cross-fade.
    // Redesign: the selected tool gets a soft tile behind it and a blue
    // icon + label (the old red dots stay hidden). Same on Android.
    let applyDots = {
      for dot in [self.toolsTabIndicator, self.effectTabIndicator, self.editTabIndicator,
                  self.stickerTabIndicator, self.drawTabIndicator, self.musicTabIndicator] {
        dot.alpha = 0
      }
      let tabs: [(UIButton, Bool)] = [
        (self.toolsTabButton, self.selectedImageEditorTab == .tools),
        (self.effectTabButton, self.selectedImageEditorTab == .effect),
        (self.editTabButton, self.selectedImageEditorTab == .edit),
        (self.stickerTabButton, self.selectedImageEditorTab == .stickers),
        (self.drawTabButton, isDrawActive),
        (self.musicTabButton, self.selectedImageEditorTab == .music),
      ]
      for (button, selected) in tabs { Self.styleTabButton(button, selected: selected) }
    }
    updateToolLens(animated: animated)

    guard animated else {
      applyDots()
      return
    }

    UIView.transition(
      with: bottomTabBar,
      duration: EditorDesignTokens.Motion.trayIconActiveDuration,
      options: .transitionCrossDissolve,
      animations: applyDots
    )

    let activeButton: UIButton
    switch selectedImageEditorTab {
    case .tools: activeButton = toolsTabButton
    case .effect: activeButton = effectTabButton
    case .edit: activeButton = editTabButton
    case .stickers: activeButton = stickerTabButton
    case .draw: activeButton = drawTabButton
    case .music: activeButton = musicTabButton
    case .textStyle: return // opened from the layer toolbar, no tray tab
    case .toolsGrid: return // opened from the bottom bar
    }
    let bounceHalfDuration = EditorDesignTokens.Motion.trayIconActiveDuration / 2
    UIView.animate(withDuration: bounceHalfDuration, animations: {
      activeButton.transform = CGAffineTransform(
        scaleX: EditorDesignTokens.Motion.trayIconActiveScale,
        y: EditorDesignTokens.Motion.trayIconActiveScale
      )
    }, completion: { _ in
      UIView.animate(withDuration: bounceHalfDuration) {
        activeButton.transform = .identity
      }
    })
  }

  private func updateFilterButtonHighlight() {
    filterNameLabel.text = selectedFilter.rawValue
    for (filter, imageView) in filterThumbnailImageViews {
      imageView.layer.borderWidth = filter == selectedFilter ? 3 : 0
    }
    // Undo/redo/re-edit can land on a filter from another tab — show it.
    if selectedFilter != .original && selectedFilter.category != selectedFilterCategory {
      selectFilterCategory(selectedFilter.category)
    }
    syncFilterStrengthControl()
  }

  // MARK: - Filter category tabs

  private var filterThumbnailContainers: [PhotoFilter: UIView] = [:]
  private var filterCategoryTabs: [PhotoFilter.Category: (button: UIButton, underline: UIView)] = [:]
  private weak var filterScrollViewRef: UIScrollView?
  private var selectedFilterCategory: PhotoFilter.Category = .classic

  /// Text tabs, each with a small underline shown when selected.
  private func makeFilterCategoryRow() -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.alignment = .fill
    row.spacing = 0
    for category in PhotoFilter.Category.allCases where mediaType == "image" || category != .artistic {
      let button = UIButton(type: .system)
      button.setTitle(category.rawValue, for: .normal)
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 9, bottom: 4, right: 9)
      button.addAction(UIAction { [weak self] _ in
        guard let self, category != self.selectedFilterCategory else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        self.selectFilterCategory(category)
      }, for: .touchUpInside)
      let underline = UIView()
      underline.backgroundColor = EditorDesignTokens.Colors.textPrimary
      underline.layer.cornerRadius = 1
      underline.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(underline)
      NSLayoutConstraint.activate([
        underline.widthAnchor.constraint(equalToConstant: 16),
        underline.heightAnchor.constraint(equalToConstant: 2),
        underline.centerXAnchor.constraint(equalTo: button.centerXAnchor),
        underline.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4),
      ])
      filterCategoryTabs[category] = (button, underline)
      row.addArrangedSubview(button)
    }
    return row
  }

  /// Shows only `category`'s thumbnails (Original always stays first).
  private func selectFilterCategory(_ category: PhotoFilter.Category) {
    selectedFilterCategory = category
    for (filter, container) in filterThumbnailContainers {
      container.isHidden = !(filter == .original || filter.category == category)
    }
    for (tabCategory, tab) in filterCategoryTabs {
      let selected = tabCategory == category
      tab.button.setTitleColor(selected ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.textSecondary, for: .normal)
      tab.button.titleLabel?.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
      tab.underline.isHidden = !selected
    }
    filterScrollViewRef?.setContentOffset(.zero, animated: false)
  }

  /// The rows are only meaningful for a real filter: for Original they're
  /// hidden and the panel shrinks to just the thumbnails (same on Android).
  private func syncFilterStrengthControl() {
    // Original has nothing to adjust (e.g. undo landed on it).
    if selectedFilter == .original { isEditingFilter = false }
    scheduleFilterStageRefresh() // panel height may change
    let editing = isEditingFilter
    effectPanel.setCollapsedHeight(editing ? effectPanelHeight : effectPanelHeightWithoutSliders, animated: true)
    updateVideoStage(animated: true)
    filterCategoryRowRef?.isHidden = editing
    filterScrollViewRef?.isHidden = editing
    filterEditHeaderRef?.isHidden = !editing
    filterSliderStackRef?.isHidden = !editing
    filterEditHeaderRef?.setTitle(" \(selectedFilter.rawValue)", for: .normal)
    for (filter, overlay) in filterEditOverlays {
      overlay.isHidden = filter != selectedFilter || filter == .original
    }
    for row in filterSliderRows {
      let value = row.read()
      row.slider.value = value
      row.valueLabel.text = "\(Int((value * 100).rounded()))"
    }
  }

  // MARK: - Filter stage (whole picture visible above the Filters panel)
  //
  // The Filters panel would otherwise cover the lower part of the photo.
  // The canvas and its layers can't simply be shrunk (layers are direct
  // subviews of `view`, and their positions feed export maths), so while
  // the panel is open they're made transparent and a snapshot of the
  // finished picture — rendered from those same views, so it's exactly
  // what you'll get — is shown fitted into the free space above the panel
  // instead. Same behaviour on Android.

  private let filterStageView = UIImageView()
  private var isFilterStageActive = false
  private var filterStageRefreshScheduled = false
  /// Views made transparent while the stage is shown, with their alpha.
  private var filterStageHiddenViews: [(view: UIView, alpha: CGFloat)] = []

  /// The views that make up the picture, drawn into the snapshot.
  private var filterStageContentViews: [UIView] {
    var views: [UIView] = [canvasClipContainerView]
    views += textLayerViews as [UIView]
    views += stickerLayerViews as [UIView]
    views += imageOverlayLayerViews as [UIView]
    // Outside Draw the drawing is part of the picture, in its own place in
    // the stacking order (not lifted above later stickers/text).
    if selectedImageEditorTab != .draw { views.append(drawingCanvasView) }
    // Blur over the layers (on top of them); hidden when not in use.
    if blurCoverView.superview === view { views.append(blurCoverView) }
    return views
  }

  /// Views you interact with while their panel is open (draw on the
  /// canvas, drag the blur focus). They can't be a snapshot, so instead of
  /// being hidden they get the stage's own move/scale — their touch
  /// coordinates are local, so drawing/dragging still lands correctly.
  private var filterStageTrackingViews: [UIView] {
    var views: [UIView] = []
    if selectedImageEditorTab == .draw { views.append(drawingCanvasView) }
    if selectedImageEditorTab == .edit {
      views.append(blurOverlayView)
      views.append(tuneSurfaceView)
    }
    views.append(overlayEraseCaptureView)
    // The rule-of-thirds grid + its frame move/shrink with the picture.
    views.append(gridOverlayView)
    return views.filter { $0.superview === view }
  }

  /// The open panel the picture has to fit above (photo only), or nil.
  private var filterStagePanel: SlideUpPanelView? {
    switch selectedImageEditorTab {
    case .tools: return nil
    case .effect: return effectPanel
    case .edit: return editPanel
    case .stickers: return stickersPanel
    case .draw: return drawPanel
    case .music: return musicPanel.superview == nil ? nil : musicPanel
    case .textStyle: return textStylePanel
    case .toolsGrid: return toolsGridPanel
    }
  }

  private func updateFilterStage(animated: Bool) {
    let shouldShow = filterStagePanel != nil && mediaType == "image" && baseImage != nil
    if shouldShow && !isFilterStageActive {
      enterFilterStage(animated: animated)
    } else if !shouldShow && isFilterStageActive {
      exitFilterStage(animated: animated)
    } else if shouldShow {
      // Switched straight from one panel to another: what's snapshotted vs
      // moved live depends on the panel, so rebuild the stage.
      exitFilterStage(animated: false)
      enterFilterStage(animated: animated)
    }
  }

  private func enterFilterStage(animated: Bool) {
    view.layoutIfNeeded()
    let canvasFrame = canvasClipContainerView.frame
    guard canvasFrame.width > 0, canvasFrame.height > 0, let panel = filterStagePanel,
          let snapshot = renderFilterStageSnapshot() else { return }
    isFilterStageActive = true
    stickerDeleteBadge?.isHidden = true
    filterStageView.contentMode = .scaleToFill
    filterStageView.clipsToBounds = true
    // Just under the open panel, above the canvas and every layer.
    view.insertSubview(filterStageView, belowSubview: panel)
    filterStageView.layer.cornerRadius = isStoryMode ? 0 : 16
    filterStageView.image = snapshot
    filterStageView.transform = .identity
    filterStageView.frame = canvasFrame
    filterStageView.isHidden = false

    filterStageHiddenViews = []
    var toHide = filterStageContentViews
    if let layerActionToolbar { toHide.append(layerActionToolbar) }
    for v in toHide {
      filterStageHiddenViews.append((v, v.alpha))
      v.alpha = 0
    }
    keepSafeAreaCoversOnTop()
    applyFilterStageFit(animated: animated)
  }

  private func exitFilterStage(animated: Bool) {
    guard isFilterStageActive else { return }
    isFilterStageActive = false
    DispatchQueue.main.async { [weak self] in self?.updateStickerDeleteBadge() }
    // Every view that may have been moved with the stage (the tab may have
    // changed since).
    let tracking: [UIView] = [drawingCanvasView, blurOverlayView, overlayEraseCaptureView, tuneSurfaceView, gridOverlayView]
    let restore = { [weak self] in
      guard let self else { return }
      for entry in self.filterStageHiddenViews { entry.view.alpha = entry.alpha }
      self.filterStageHiddenViews = []
      self.filterStageView.isHidden = true
      self.filterStageView.image = nil
      self.filterStageView.transform = .identity
      for v in tracking { v.transform = .identity }
    }
    guard animated else {
      filterStageView.layer.removeAllAnimations()
      restore()
      return
    }
    UIView.animate(
      withDuration: EditorDesignTokens.Motion.panelToggleDuration,
      delay: 0,
      options: [.curveEaseOut, .beginFromCurrentState],
      animations: {
        self.filterStageView.transform = .identity
        for v in tracking { v.transform = .identity }
      },
      completion: { [weak self] _ in
        guard let self, !self.isFilterStageActive else { return }
        restore()
      }
    )
  }

  /// Scales the stage (about the canvas centre) to fit between the top bar
  /// and the open panel's top, centred in that gap. Never enlarges. The
  /// tracking views get the same mapping around their own centres.
  private func applyFilterStageFit(animated: Bool) {
    let canvasFrame = canvasClipContainerView.frame
    guard canvasFrame.height > 0, let panel = filterStagePanel else { return }
    let gap: CGFloat = 8
    var top = topBar.convert(topBar.bounds, to: view).maxY + gap
    // Resting position (frame would include the panel's slide-in transform).
    let panelBottom = panel.center.y + panel.bounds.height / 2
    var bottom = panelBottom - panel.restingHeight - gap
    if isTuneActive {
      // Tune screen: between the value pill and the hint above its bar.
      view.layoutIfNeeded()
      top = view.safeAreaInsets.top + 8 + tunePillView.bounds.height + 16
      bottom = tuneHintLabel.frame.minY - 12
    }
    let available = bottom - top
    guard available > 0 else { return }
    let scale = min(1, available / canvasFrame.height)
    let translation = (top + available / 2) - canvasFrame.midY
    let target = CGAffineTransform(translationX: 0, y: translation).scaledBy(x: scale, y: scale)
    let center = CGPoint(x: canvasFrame.midX, y: canvasFrame.midY)
    let tracking = filterStageTrackingViews.map { v -> (UIView, CGAffineTransform) in
      let mapped = CGPoint(
        x: center.x + (v.center.x - center.x) * scale,
        y: center.y + (v.center.y - center.y) * scale + translation
      )
      return (v, CGAffineTransform(translationX: mapped.x - v.center.x, y: mapped.y - v.center.y).scaledBy(x: scale, y: scale))
    }
    let apply = {
      self.filterStageView.transform = target
      for (v, t) in tracking { v.transform = t }
    }
    guard animated else {
      apply()
      return
    }
    UIView.animate(
      withDuration: EditorDesignTokens.Motion.panelToggleDuration,
      delay: 0,
      options: [.curveEaseOut, .beginFromCurrentState],
      animations: apply
    )
  }

  /// Coalesces the many refreshes a slider drag triggers into one per run loop.
  private func scheduleFilterStageRefresh() {
    guard isFilterStageActive, !filterStageRefreshScheduled else { return }
    filterStageRefreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.filterStageRefreshScheduled = false
      guard self.isFilterStageActive else { return }
      // Layers added while the stage is up (e.g. a sticker from the
      // Stickers panel) belong in the snapshot, not on top of it.
      let hidden = Set(self.filterStageHiddenViews.map { ObjectIdentifier($0.view) })
      for v in self.filterStageContentViews where !hidden.contains(ObjectIdentifier(v)) {
        self.filterStageHiddenViews.append((v, v.alpha))
        v.alpha = 0
      }
      if let snapshot = self.renderFilterStageSnapshot() { self.filterStageView.image = snapshot }
      self.applyFilterStageFit(animated: true)
    }
  }

  /// Renders the canvas box's content (photo + layers, as on screen) — each
  /// direct subview with its own centre/transform, in z-order. Their alpha
  /// is briefly set back to 1 for the render (no screen update happens in
  /// between, so nothing flickers).
  private func renderFilterStageSnapshot() -> UIImage? {
    renderCanvasComposite(of: filterStageContentViews)
  }

  /// Draws `views` (direct subviews of `view`, in their stacking order)
  /// into an image of the canvas box, as on screen.
  private func renderCanvasComposite(of views: [UIView], scale: CGFloat? = nil) -> UIImage? {
    let canvasFrame = canvasClipContainerView.frame
    guard canvasFrame.width > 0, canvasFrame.height > 0 else { return nil }
    let content = Set(views.map(ObjectIdentifier.init))
    let saved = filterStageHiddenViews
    for entry in saved { entry.view.alpha = entry.alpha }
    defer { for entry in saved { entry.view.alpha = 0 } }
    let format = UIGraphicsImageRendererFormat.preferred()
    if let scale { format.scale = scale }
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(bounds: canvasFrame, format: format)
    return renderer.image { context in
      let cg = context.cgContext
      for subview in view.subviews where content.contains(ObjectIdentifier(subview)) && !subview.isHidden {
        cg.saveGState()
        cg.translateBy(x: subview.center.x, y: subview.center.y)
        cg.concatenate(subview.transform)
        cg.translateBy(
          x: -subview.bounds.width * subview.layer.anchorPoint.x,
          y: -subview.bounds.height * subview.layer.anchorPoint.y
        )
        if let overlay = subview as? EditableImageLayerView, overlay.overlayStyle.blend != .normal, let image = overlay.image {
          // layer.render ignores the on-screen compositing filter.
          image.draw(in: overlay.bounds, blendMode: overlay.overlayStyle.blend.cgBlendMode, alpha: 1)
        } else {
          subview.layer.render(in: cg)
        }
        cg.restoreGState()
      }
    }
  }

  // MARK: - Filter adjust mode

  /// Sliders shown instead of the thumbnails (pencil on the selected filter).
  private var isEditingFilter = false
  private var filterEditOverlays: [PhotoFilter: UIView] = [:]
  private weak var filterCategoryRowRef: UIView?
  private weak var filterSliderStackRef: UIView?
  private weak var filterEditHeaderRef: UIButton?

  private func setFilterEditing(_ editing: Bool) {
    guard isEditingFilter != editing else { return }
    isEditingFilter = editing && selectedFilter != .original
    syncFilterStrengthControl()
  }

  /// "‹ Vivid" — back to the thumbnails.
  private func makeFilterEditHeader() -> UIView {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
    button.tintColor = EditorDesignTokens.Colors.textPrimary
    button.setTitleColor(EditorDesignTokens.Colors.textPrimary, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
    button.addAction(UIAction { [weak self] _ in
      UISelectionFeedbackGenerator().selectionChanged()
      self?.setFilterEditing(false)
    }, for: .touchUpInside)
    button.isHidden = true
    filterEditHeaderRef = button
    return button
  }

  // MARK: - Video playback

  private func setUpVideoPlayer() {
    let asset = AVURLAsset(url: sourceURL)
    videoTrimView.loadThumbnails(from: asset)

    rebuildVideoQueue(startPlaying: true)
    playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)

    Task { [weak self] in
      guard let duration = try? await asset.load(.duration) else { return }
      let seconds = CMTimeGetSeconds(duration)
      guard seconds.isFinite, seconds > 0 else { return }
      await MainActor.run {
        self?.videoTrimView.configureFullRange(duration: seconds)
        self?.videoSegments = [0...seconds]
        self?.correctFallbackLayerTimings(toDuration: seconds)
        self?.updateFilmstripLayout()
      }
    }

    attachTimelinePeriodicObserver()

    // A single extracted still frame does double duty: it gives the canvas
    // its real (orientation-corrected) aspect ratio — exactly like
    // applyImageAspectRatio's fallback path for images — AND becomes the
    // source for the filter thumbnail row, so video's filter picker shows
    // real live-rendered previews too, not a generic icon, per the user's
    // "same UI as the image editor" request.
    // `AVAssetImageGenerator.image(at:)` (the async/await variant) is iOS
    // 16+ only — this project's actual deployment target is 15.1 (Podfile's
    // `platform :ios, '16.0'` only governs pods, not the app target itself,
    // per project.pbxproj's IPHONEOS_DEPLOYMENT_TARGET). Use the
    // completion-handler API instead, which has been available since iOS 4.
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    // Only the shape + small filter previews need it: no full 4K frame.
    generator.maximumSize = CGSize(width: 1280, height: 1280)
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { [weak self] _, cgImage, _, _, _ in
      guard let self, let cgImage else { return }
      let frameImage = UIImage(cgImage: cgImage)
      DispatchQueue.main.async {
        self.applyImageAspectRatio(frameImage)
        self.renderFilterThumbnails(from: frameImage)
      }
    }
  }

  /// Attaches the 60fps periodic time observer that drives the filmstrip
  /// auto-scroll/highlight, per-layer time-based visibility, the music
  /// playback window, and the primary clip's own segment gap-skip/loop
  /// logic. MUST be re-called (after tearing down any existing token)
  /// every time `player` is reassigned to a new `AVQueuePlayer` instance
  /// — `addPeriodicTimeObserver` is registered against one specific
  /// player, so a stale token silently stops firing forever once its
  /// player is replaced (was previously only ever called once, from
  /// `setUpVideoPlayer`, which quietly broke this whole observer — no
  /// more filmstrip sync, no more layer show/hide — the first time
  /// `rebuildVideoQueue` ran after initial setup; became far more visible
  /// once `primaryItemEndObserver` started calling `rebuildVideoQueue` on
  /// every single-clip loop).
  private func attachTimelinePeriodicObserver() {
    if let timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
      self.timeObserverToken = nil
    }
    // Dropped from 0.25s per the user's explicit "playing like stuck
    // stuck stuck... i want to display smooth" request — at 250ms the
    // filmstrip's auto-scroll-follow-playback (setContentOffset below)
    // only updated 4x/second, visibly stepping instead of scrolling
    // smoothly. 1/60s matches a 60fps frame cadence; every other piece
    // of work this closure does (highlight/layer-visibility checks)
    // already early-returns or is cheap when nothing changed, so running
    // it this often adds negligible cost. Mirrors the identical Android
    // fix (TIMELINE_POLL_INTERVAL_MS).
    let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
    timeObserverToken = queuePlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      guard let self, let queuePlayer = self.queuePlayer else { return }
      // Per-part speed: follow whichever part is playing now.
      self.applyPreviewSpeed()

      // Instagram-style scrollable timeline: keep the active-clip
      // highlight (and, unless the user's own finger is actively
      // dragging it, the scroll position itself) in sync with ACTUAL
      // playback — regardless of whether the primary or a merged clip is
      // currently playing, and continuing seamlessly across the queue's
      // own existing loop-back-to-start behavior. Programmatic
      // (animated: false) so it never fights/echoes a user-driven scroll
      // — scrollViewDidScroll only triggers an actual SEEK from
      // scrollViewDidEndDragging/DidEndDecelerating, neither of which
      // fire for a programmatic contentOffset change.
      self.updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer: false)
      if !self.isUserScrubbingFilmstrip {
        let combined = self.combinedTimeForCurrentPlayback()
        self.filmstripScrollView.setContentOffset(CGPoint(x: self.scrollOffsetX(forCombinedTime: combined), y: 0), animated: false)
        self.updateVideoTimeLabel(current: combined)
        if !self.videoMiniScrubRow.isHidden && !self.isDraggingVideoMiniSlider {
          self.syncVideoMiniScrubber(current: combined)
        }
      }
      self.updateMusicPlaybackWindow()
      // Runs regardless of which item is currently playing — layers now
      // extend across merged clips too (see combinedLayerDuration's own
      // doc), so their visibility must keep updating during merged-clip
      // playback, not just while the primary clip is active.
      self.updateLayerTimeVisibility()
      self.updateTransitionPreview()
      if self.audioFadeIn || self.audioFadeOut || self.voiceOverURL != nil {
        let now = self.combinedTimeForCurrentPlayback()
        self.player?.volume = self.voiceRecorder != nil ? 0 : self.effectivePlayerVolume()
        self.musicPlayer?.volume = self.musicVolumeSlider.value * self.musicFadeFactor(now) * self.voiceDuckFactor(now)
      }
      self.updateVoicePlaybackWindow()

      // Only the PRIMARY clip's own timeline drives the gap-skip logic
      // below — merged clips (additionalVideoClipURLs) always play in
      // full, in order, once reached; AVQueuePlayer itself advances
      // between them with no help needed here.
      guard queuePlayer.currentItem === self.primaryPlayerItem else { return }
      let seconds = CMTimeGetSeconds(time)
      // Skip past any deleted gap (before the first segment, between two
      // kept segments, or after the last) — preview should play back
      // exactly what will be exported, not run through content that's
      // been cut. Gated on `isVideoPlaying` (the user's INTENDED state),
      // not the engine's transient one — see that property's own doc for
      // why. An empty `videoSegments` means "not yet configured" (before
      // configureFullRange runs), so this stays inert until a real range
      // is known.
      guard self.isVideoPlaying, !self.videoSegments.isEmpty else { return }
      if let currentIndex = self.videoSegments.lastIndex(where: { $0.lowerBound <= seconds }),
         seconds >= self.videoSegments[currentIndex].upperBound {
        let nextIndex = currentIndex + 1
        if nextIndex < self.videoSegments.count {
          queuePlayer.seek(to: CMTime(seconds: self.videoSegments[nextIndex].lowerBound, preferredTimescale: 600))
          startPlayback(queuePlayer)
        } else if queuePlayer.items().count > 1 {
          // More clips queued after this one — hand off to the next one
          // instead of looping back to THIS clip's own start, per the
          // user's explicit "played in queue, same like Instagram"
          // request. The queue as a whole still loops once the LAST item
          // finishes — see rebuildVideoQueue's own doc.
          queuePlayer.advanceToNextItem()
        } else {
          // Single-clip loop-back-to-start — per the user's explicit
          // "as video start playing in loop again then the music should
          // be reset and start again" request, the music must restart
          // here too, not keep running toward its own natural end.
          queuePlayer.seek(to: CMTime(seconds: self.videoSegments[0].lowerBound, preferredTimescale: 600))
          startPlayback(queuePlayer)
          self.resetMusicToLoopStart()
        }
      } else if self.videoSegments.lastIndex(where: { $0.lowerBound <= seconds }) == nil {
        // Before the very first kept segment's start (e.g. right after
        // deleting the segment that used to occupy this position).
        queuePlayer.seek(to: CMTime(seconds: self.videoSegments[0].lowerBound, preferredTimescale: 600))
        startPlayback(queuePlayer)
      }
    }
  }

  /// A fresh AVPlayerItem for the primary clip, with the same live filter/
  /// adjustment preview `videoComposition` closure it's always had — split
  /// out so rebuildVideoQueue can recreate it on demand (e.g. to loop the
  /// whole queue) without duplicating this setup.
  private func makePrimaryPlayerItem() -> AVPlayerItem {
    let asset = AVURLAsset(url: sourceURL)
    let item = AVPlayerItem(asset: asset)
    item.videoComposition = AVVideoComposition(asset: asset) { [weak self] request in
      guard let self else {
        request.finish(with: request.sourceImage, context: nil)
        return
      }
      // Hold-to-compare shows the untouched frame.
      request.finish(with: self.isShowingOriginal ? request.sourceImage : self.adjustedCIImage(from: request.sourceImage), context: nil)
    }
    // Speed control: keep voices at their normal pitch at any rate.
    item.audioTimePitchAlgorithm = .timeDomain
    return item
  }

  /// A merged clip plays UNTRIMMED (its own AVURLAsset directly) unless
  /// the user trimmed/split it via mergedStripView's inline drag handles
  /// or its own Split/Delete, in which case a composition carrying just
  /// its kept segments — inserted back-to-back, exactly the SAME
  /// "multiple insertTimeRange calls into one track" technique used for
  /// the primary clip's own kept segments (both in live preview and
  /// export) — is used instead. This is also why a merged clip needs NO
  /// gap-skip logic of its own in the periodic time observer: its gaps
  /// are already physically excised from the composition before the
  /// AVPlayerItem is ever handed to the queue, unlike the primary clip
  /// (which keeps its own custom per-frame AVVideoComposition live for
  /// filter/adjustment preview, so it can't be pre-baked the same way).
  /// Uses the synchronous, deprecated-but-still-supported
  /// `tracks(withMediaType:)` rather than the async loader, so
  /// rebuildVideoQueue (called from many synchronous call sites already)
  /// doesn't need to become async itself.
  private func makeAdditionalPlayerItem(url: URL) -> AVPlayerItem {
    let asset = AVURLAsset(url: url)
    let item: AVPlayerItem
    if let segments = additionalClipSegments[url], !segments.isEmpty {
      let composition = AVMutableComposition()
      if
        let sourceVideoTrack = asset.tracks(withMediaType: .video).first,
        let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      {
        compositionVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform
        let sourceAudioTrack = asset.tracks(withMediaType: .audio).first
        let compositionAudioTrack = sourceAudioTrack != nil
          ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
          : nil
        var insertionPoint = CMTime.zero
        for segment in segments {
          let range = CMTimeRange(
            start: CMTime(seconds: segment.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: segment.upperBound, preferredTimescale: 600)
          )
          try? compositionVideoTrack.insertTimeRange(range, of: sourceVideoTrack, at: insertionPoint)
          if let sourceAudioTrack, let compositionAudioTrack {
            try? compositionAudioTrack.insertTimeRange(range, of: sourceAudioTrack, at: insertionPoint)
          }
          insertionPoint = insertionPoint + range.duration
        }
        item = AVPlayerItem(asset: composition)
      } else {
        item = AVPlayerItem(asset: asset)
      }
    } else {
      item = AVPlayerItem(asset: asset)
    }

    // Same live filter/adjustment preview videoComposition as
    // makePrimaryPlayerItem's own — merged clips never had ANY filter
    // preview before (per the user's "edits should stay with their own
    // clip" request; see clipFilterState's own doc). `adjustedCIImage`
    // reads the shared working-copy vars, which syncActiveClipFilterState
    // keeps pointed at whichever clip is CURRENTLY playing, so this one
    // closure is correct for every clip without needing this specific
    // clip's URL baked in. Assigning `.videoComposition` on top of an
    // already-composition-backed item (the trimmed/split branch above)
    // is independent of that composition's own job (assembling which
    // source time ranges play, i.e. the gap-skip-by-composition this
    // function's own doc describes) — this only affects PER-FRAME
    // rendering on top of whatever the composition already assembled.
    item.videoComposition = AVVideoComposition(asset: item.asset) { [weak self] request in
      guard let self else {
        request.finish(with: request.sourceImage, context: nil)
        return
      }
      // Hold-to-compare shows the untouched frame.
      request.finish(with: self.isShowingOriginal ? request.sourceImage : self.adjustedCIImage(from: request.sourceImage), context: nil)
    }

    // Speed control: keep voices at their normal pitch at any rate.
    item.audioTimePitchAlgorithm = .timeDomain
    return item
  }

  /// (Re)builds the whole playback queue from scratch — the primary clip
  /// followed by every merged clip in `additionalVideoClipURLs`, in order —
  /// per the user's explicit "doesn't matter how many video, all video
  /// clips will be added to same video layer and will be played in queue,
  /// same like Instagram" request. Called at initial setup, whenever a
  /// clip is added/removed, whenever the user scrubs/splits/deletes while
  /// a merged clip is playing (jumping back to the primary clip first —
  /// see videoTrimView.onScrub's own doc), and — only when more than one
  /// clip is queued — to loop the ENTIRE queue back to the start once the
  /// last item finishes. AVQueuePlayer removes each item from its queue as
  /// playback advances past it, and reusing an already-played AVPlayerItem
  /// in a new queue isn't reliable, so looping rebuilds fresh AVPlayerItem
  /// instances rather than re-inserting the old ones. The single-clip case
  /// primarily loops via the periodic time observer's own gap-skip logic
  /// above (no rebuild needed — it seeks the still-live item before it
  /// ever reaches its true end); `primaryItemEndObserver` is only a
  /// backstop for when that per-tick check misses the exact boundary, and
  /// — for the same "already-played item isn't reusable" reason as
  /// above — it also rebuilds rather than trying to seek the (by then
  /// queue-evicted) item.
  private func rebuildVideoQueue(startPlaying: Bool) {
    if let lastQueueItemEndObserver {
      NotificationCenter.default.removeObserver(lastQueueItemEndObserver)
      self.lastQueueItemEndObserver = nil
    }
    if let primaryItemEndObserver {
      NotificationCenter.default.removeObserver(primaryItemEndObserver)
      self.primaryItemEndObserver = nil
    }
    // Must remove from the OLD `player` before it's reassigned below —
    // `attachTimelinePeriodicObserver()` (called after reassignment) only
    // knows how to remove a token from whatever `player` is CURRENT at
    // that point, which would already be the new one.
    if let timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
      self.timeObserverToken = nil
    }
    let primaryItem = makePrimaryPlayerItem()
    primaryPlayerItem = primaryItem
    let additionalItems = additionalVideoClipURLs.map { makeAdditionalPlayerItem(url: $0) }
    // Identity-matched (not index-matched — AVQueuePlayer removes played
    // items from its own live queue) against queuePlayer.currentItem by
    // combinedTimeForCurrentPlayback, to determine which merged clip is
    // currently playing for the Instagram-style scrollable timeline.
    additionalPlayerItemsByURL = Array(zip(additionalVideoClipURLs, additionalItems))
    let allItems = [primaryItem] + additionalItems

    let wasPlaying = isVideoPlaying
    let newPlayer = AVQueuePlayer(items: allItems)
    // A freshly-constructed AVQueuePlayer always starts at full volume —
    // without this, muting/lowering the original audio got silently
    // undone every time this function re-created the player (every
    // single-clip loop restart, every merged-clip add/split/delete),
    // per the user's explicit "if original music sound is lowered
    // manually... it should not play until increase music, currently
    // its playing when video start from 0 and/or in loop" report.
    newPlayer.volume = effectivePlayerVolume()
    player = newPlayer
    playerView.playerLayer.player = newPlayer
    attachTimelinePeriodicObserver()

    if allItems.count == 1 {
      primaryItemEndObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: primaryItem, queue: .main
      ) { [weak self] _ in
        guard let self, self.isVideoPlaying else { return }
        self.rebuildVideoQueue(startPlaying: true)
        self.resetMusicToLoopStart()
      }
    }

    if allItems.count > 1, let lastItem = allItems.last {
      lastQueueItemEndObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: lastItem, queue: .main
      ) { [weak self] _ in
        self?.rebuildVideoQueue(startPlaying: true)
        self?.resetMusicToLoopStart()
      }
    }
    if startPlaying || wasPlaying {
      startPlayback(newPlayer)
    }
  }

  /// Pauses playback when the user taps any bottom tool-tray icon while
  /// the video is playing, per the user's explicit "tapping any creating
  /// tool should pause playing video" request. Reuses the exact same
  /// toggle as `didTapPlayPause` (rather than calling `player`/
  /// `musicPlayer` directly) so `isVideoPlaying` and every button that
  /// mirrors it (`playPauseButton`, `musicPlayPauseButton`) stay in sync.
  /// Guarded on `timeControlStatus` so it never resumes an already-paused
  /// video, and is a no-op in image mode (`player` is nil there).
  private func pauseVideoForToolInteraction() {
    // Story mode has no play/pause button to resume with, so the video
    // keeps looping while tools are used (Instagram-style).
    guard !isStoryMode else { return }
    guard let player, player.timeControlStatus == .playing else { return }
    didTapPlayPause()
  }

  // MARK: Timeline scrubbing

  private var wasPlayingBeforeScrub = false
  private var isLiveScrubSeekInFlight = false

  /// Pause / resume for a timeline drag (not a user play/pause tap). On
  /// resume the music is re-placed by updateMusicPlaybackWindow rather than
  /// just un-paused, so it lines up with the new spot.
  private func setScrubPlayback(playing: Bool) {
    guard let player else { return }
    if playing {
      startPlayback(player)
      isVideoPlaying = true
      musicPlayer?.pause()
      updateMusicPlaybackWindow()
    } else {
      player.pause()
      musicPlayer?.pause()
      voicePlayer?.pause()
      isVideoPlaying = false
    }
    let symbol = playing ? "pause.fill" : "play.fill"
    playPauseButton.setImage(UIImage(systemName: symbol), for: .normal)
    videoMiniPlayButton.setImage(UIImage(systemName: symbol), for: .normal)
    musicPlayPauseButton.setImage(Self.musicCardPlayImage(playing: playing), for: .normal)
    updateStoryMusicBadge()
  }

  /// While dragging, the preview shows the frame under the playhead (main
  /// clip only — a merged clip needs a queue rebuild, done on release).
  /// One seek at a time so a fast drag doesn't pile them up.
  private func liveScrubSeek(to combined: Double) {
    guard !isLiveScrubSeekInFlight, let player, queuePlayer?.currentItem === primaryPlayerItem else { return }
    let target = realSeekTarget(forCombinedTime: combined)
    guard target.isPrimary else { return }
    isLiveScrubSeekInFlight = true
    let tolerance = CMTime(seconds: 0.04, preferredTimescale: 600)
    player.seek(to: CMTime(seconds: target.localSeconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
      DispatchQueue.main.async { self?.isLiveScrubSeekInFlight = false }
    }
  }

  private func finishTimelineScrub() {
    isUserScrubbingFilmstrip = false
    seekCombinedTimeline(to: combinedTime(forScrollOffsetX: filmstripScrollView.contentOffset.x))
    if wasPlayingBeforeScrub {
      wasPlayingBeforeScrub = false
      setScrubPlayback(playing: true)
    }
  }

  @objc private func didTapPlayPause() {
    guard let player else { return }
    if player.timeControlStatus == .playing {
      player.pause()
      musicPlayer?.pause()
      isVideoPlaying = false
      playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
      videoMiniPlayButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
      musicPlayPauseButton.setImage(Self.musicCardPlayImage(playing: false), for: .normal)
    } else {
      startPlayback(player)
      musicPlayer?.play()
      isVideoPlaying = true
      playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
      videoMiniPlayButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
      musicPlayPauseButton.setImage(Self.musicCardPlayImage(playing: true), for: .normal)
    }
    // Keeps the story-mode badge's own play/pause icon in sync with this
    // same toggle (video+story path only — image+story uses
    // didTapStoryMusicBadge's own dedicated musicPlayer-only toggle, since
    // `guard let player` above already no-ops this whole function for a
    // still image). No-ops outside story mode.
    updateStoryMusicBadge()
  }

  @objc private func didTapSplitSegment() {
    if blockIfSelectedLayerLocked() { return }
    // Beat sync: move the cut to the nearest beat first.
    if beatSnapEnabled, !skipNextBeatSnap {
      let now = combinedTimeForCurrentPlayback()
      if let beat = nearestBeat(to: now, within: 0.3), abs(beat - now) > 0.02 {
        seekCombinedTimeline(to: beat)
        filmstripScrollView.setContentOffset(CGPoint(x: scrollOffsetX(forCombinedTime: beat), y: 0), animated: false)
        updateVideoTimeLabel(current: beat)
        skipNextBeatSnap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
          self?.didTapSplitSegment()
          self?.skipNextBeatSnap = false
        }
        return
      }
    }
    // Per the user's explicit "same split music layer also" request —
    // Split/Delete target the music row whenever IT was the last thing
    // tapped in the layer tracks (selectedMusicSegmentIndex), same
    // priority as a selected canvas layer below.
    if selectedMusicSegmentIndex != nil, let index = musicSegments.firstIndex(where: {
      $0.contains(combinedTimeForCurrentPlayback())
    }) {
      splitMusicSegment(at: index)
      return
    }
    // Per the user's explicit "i want a functionality that i can split
    // all layer" request — Split/Delete now operate on the SELECTED
    // LAYER's own segments (at whichever one contains the current
    // playhead) instead of the video's own, whenever a layer is
    // selected. Falls through to the existing video-segment behavior
    // below when no layer is selected, completely unchanged.
    if let selectedLayer, let index = layerTimings[ObjectIdentifier(selectedLayer)]?.segments.firstIndex(where: {
      $0.contains(combinedTimeForCurrentPlayback())
    }) {
      splitLayerSegment(selectedLayer, at: index)
      return
    }
    // Split/Delete now ALSO work on whichever MERGED clip is currently
    // active (yellow border, same clip the red delete-whole-clip button
    // targets) — per the user's explicit "why on every click of scissors
    // icon layer should cut in split portion" report: this used to just
    // silently rebuild the queue back to the primary clip and do nothing,
    // which is exactly what looked like "scissors isn't cutting."
    if let activeURL = activeClipURL {
      splitActiveMergedClip(activeURL)
      return
    }
    // Split/Delete only ever apply to the PRIMARY clip's own segments —
    // if playback has advanced into a merged clip, jump back first (see
    // videoTrimView.onScrub's identical guard).
    if queuePlayer?.currentItem !== primaryPlayerItem {
      rebuildVideoQueue(startPlaying: false)
    }
    guard let player else { return }
    let seconds = CMTimeGetSeconds(player.currentTime())
    guard seconds.isFinite else { return }
    let oldSegments = videoTrimView.segments
    if videoTrimView.splitAtCurrentTime(seconds) {
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      let newSegments = videoTrimView.segments
      pushUndo(
        undo: { [weak self] in
          self?.videoTrimView.restoreSegments(oldSegments)
          self?.videoSegments = oldSegments
        },
        redo: { [weak self] in
          self?.videoTrimView.restoreSegments(newSegments)
          self?.videoSegments = newSegments
        }
      )
    } else {
      // Already at a split point, right at a segment's own edge, or too
      // close to one end to leave both halves >= the minimum trim
      // duration.
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
  }

  @objc private func didTapDeleteSegment() {
    if blockIfSelectedLayerLocked() { return }
    if isVoiceRowSelected {
      deleteVoiceOver()
      return
    }
    // Same music-row priority as didTapSplitSegment above — targets
    // whichever segment was last TAPPED, falling back to "whichever
    // contains the playhead".
    if selectedMusicSegmentIndex != nil {
      let tappedIndex = selectedMusicSegmentIndex.flatMap { musicSegments.indices.contains($0) ? $0 : nil }
      let targetIndex = tappedIndex ?? musicSegments.firstIndex(where: { $0.contains(combinedTimeForCurrentPlayback()) })
      if let targetIndex {
        deleteMusicSegment(at: targetIndex)
        return
      }
    }
    // Same routing as didTapSplitSegment above, but targets whichever
    // segment the user last TAPPED in the layer-tracks row
    // (selectedLayerSegmentIndex — see its own doc), not necessarily the
    // one under the current playhead — per the user's explicit "select a
    // dedicated splitted portion of layer so that on click of that these
    // portion should be delete by clicking on delete icon" request. Falls
    // back to "whichever segment contains the playhead" if selection came
    // from somewhere else (e.g. a canvas tap) rather than the row itself.
    if let selectedLayer {
      let timing = layerTimings[ObjectIdentifier(selectedLayer)]
      let tappedIndex = selectedLayerSegmentIndex.flatMap { timing?.segments.indices.contains($0) == true ? $0 : nil }
      let targetIndex = tappedIndex ?? timing?.segments.firstIndex(where: { $0.contains(combinedTimeForCurrentPlayback()) })
      if let targetIndex {
        deleteLayerSegment(selectedLayer, at: targetIndex)
        return
      }
    }
    // Same extension as didTapSplitSegment above — Delete now ALSO works
    // on whichever MERGED clip is currently active, targeting whichever
    // of ITS OWN segments was last tapped (selectedMergedClipSegmentIndex),
    // falling back to "whichever segment contains the playhead" exactly
    // like the layer path above.
    if let activeURL = activeClipURL {
      deleteActiveMergedClipSegment(activeURL)
      return
    }
    if queuePlayer?.currentItem !== primaryPlayerItem {
      rebuildVideoQueue(startPlaying: false)
    }
    guard let player else { return }
    // Same "tapped portion wins over playhead position" preference as
    // the layer path above — per the user's explicit "select a
    // dedicated splitted portion... white border means selected
    // portion... delete on click on delete icon" request, now extended
    // to the video's own segments too, not just layers.
    let oldSegments = videoTrimView.segments
    let didDelete: Bool
    if let selectedSegmentIndex = videoTrimView.selectedSegmentIndex {
      didDelete = videoTrimView.deleteSegment(at: selectedSegmentIndex)
    } else {
      let seconds = CMTimeGetSeconds(player.currentTime())
      guard seconds.isFinite else { return }
      didDelete = videoTrimView.deleteSegment(containing: seconds)
    }
    if didDelete {
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      let newSegments = videoTrimView.segments
      pushUndo(
        undo: { [weak self] in
          self?.videoTrimView.restoreSegments(oldSegments)
          self?.videoSegments = oldSegments
        },
        redo: { [weak self] in
          self?.videoTrimView.restoreSegments(newSegments)
          self?.videoSegments = newSegments
        }
      )
      // Jump playback to whatever segment now occupies this position —
      // matches the periodic observer's own gap-skip logic, avoiding a
      // visible freeze on the just-deleted frame until the next 0.25s
      // tick would otherwise catch up. When the playhead was inside (or
      // past) the segment that just got deleted AND it was the trailing-
      // most one, there IS no later segment to jump forward to — per the
      // user's explicit "it should stay at the same time where I deleted,
      // not reset to the start" report, that case now lands near the END
      // of whatever remains instead of falling all the way back to the
      // very first segment's start (which looked like the whole video had
      // reset to 0).
      //
      // "Near" the end, not exactly AT it: VideoTrimView.minTrimDuration
      // (2.0s, private — kept here as a literal with this note, matching
      // this file's existing cross-file-constant convention) requires
      // BOTH halves of any split to be >= that long, so landing precisely
      // on the trailing edge dropped the playhead into a permanently
      // unsplittable dead zone — every next scissors tap silently failed
      // (segment too short on the right) until the user manually scrubbed
      // away first, per the user's explicit "once I delete, I can't split
      // this same video again" report. Backing off by minTrimDuration
      // keeps the playhead at the closest position that's still always
      // immediately re-splittable, when the remaining segment is long
      // enough to have one; otherwise (a remaining segment under 2x that,
      // 4s) there's no valid split point anywhere in it regardless of
      // where the playhead lands, so it simply clamps to the segment start.
      let matchingMinTrimDuration = 2.0
      let seconds = CMTimeGetSeconds(player.currentTime())
      let target: Double
      if let nextSegment = videoSegments.first(where: { $0.lowerBound >= seconds }) {
        target = nextSegment.lowerBound
      } else if let lastSegment = videoSegments.last {
        target = max(lastSegment.lowerBound, lastSegment.upperBound - matchingMinTrimDuration)
      } else {
        target = 0
      }
      player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    } else {
      // Refused because this is the only remaining segment — nothing
      // left to preview/export if it were removed too.
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
  }

  /// Splits `layer`'s segment at `index` into two, at the current
  /// combined-timeline playhead — mirrors the primary video's own Split
  /// button (`videoTrimView.splitAtCurrentTime`), scoped to one layer's
  /// own segment list instead of `videoSegments`. Refuses (matching
  /// warning haptic) if the playhead is too close to either edge of that
  /// segment to leave both halves >= the same 0.5s minimum used
  /// throughout this file (LayerRangeBarView.minRangeDuration,
  /// videoTrimView's own split/trim minimum).
  private func splitLayerSegment(_ layer: UIView, at index: Int) {
    guard var timing = layerTimings[ObjectIdentifier(layer)], timing.segments.indices.contains(index) else { return }
    let segment = timing.segments[index]
    let splitPoint = combinedTimeForCurrentPlayback()
    let minSegmentDuration = 0.5
    guard splitPoint - segment.lowerBound >= minSegmentDuration, segment.upperBound - splitPoint >= minSegmentDuration else {
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
      return
    }
    let oldSegments = timing.segments
    timing.segments[index] = segment.lowerBound...splitPoint
    timing.segments.insert(splitPoint...segment.upperBound, at: index + 1)
    let newSegments = timing.segments
    layerTimings[ObjectIdentifier(layer)] = timing
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    updateLayerTimeVisibility()
    refreshLayersPanel()
    let layerID = ObjectIdentifier(layer)
    pushUndo(
      undo: { [weak self] in
        guard var t = self?.layerTimings[layerID] else { return }
        t.segments = oldSegments
        self?.layerTimings[layerID] = t
        self?.updateLayerTimeVisibility()
        self?.refreshLayersPanel()
      },
      redo: { [weak self] in
        guard var t = self?.layerTimings[layerID] else { return }
        t.segments = newSegments
        self?.layerTimings[layerID] = t
        self?.updateLayerTimeVisibility()
        self?.refreshLayersPanel()
      }
    )
  }

  /// Deletes JUST segment `index` of `layer` (see splitLayerSegment's own
  /// doc) — per the user's explicit "on click of that these portion
  /// should be delete by clicking on delete icon and gap should be
  /// removed" request. The segment is simply removed from the array (no
  /// absolute-time shifting of any remaining segments — a layer's
  /// segments are a VISIBILITY schedule, not video footage being spliced,
  /// so there's no gap to physically close, only the just-removed
  /// segment's own colored block, which naturally stops being drawn).
  /// If this was the layer's LAST remaining segment, deletes the whole
  /// layer instead (a layer with 0 segments is meaningless) via the SAME
  /// confirm/undo path a full layer deletion already uses.
  private func deleteLayerSegment(_ layer: UIView, at index: Int) {
    guard var timing = layerTimings[ObjectIdentifier(layer)], timing.segments.indices.contains(index) else { return }
    if timing.segments.count <= 1 {
      guard let editableLayer = layer as? EditableLayerView else { return }
      confirmDeleteLayer(editableLayer)
      return
    }
    let oldSegments = timing.segments
    timing.segments.remove(at: index)
    let newSegments = timing.segments
    layerTimings[ObjectIdentifier(layer)] = timing
    selectedLayerSegmentIndex = nil
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    updateLayerTimeVisibility()
    refreshLayersPanel()
    let layerID = ObjectIdentifier(layer)
    pushUndo(
      undo: { [weak self] in
        guard var t = self?.layerTimings[layerID] else { return }
        t.segments = oldSegments
        self?.layerTimings[layerID] = t
        self?.updateLayerTimeVisibility()
        self?.refreshLayersPanel()
      },
      redo: { [weak self] in
        guard var t = self?.layerTimings[layerID] else { return }
        t.segments = newSegments
        self?.layerTimings[layerID] = t
        self?.updateLayerTimeVisibility()
        self?.refreshLayersPanel()
      }
    )
  }

  /// Maps a COMPACTED (gap-free) local time within a merged clip's own
  /// composition-based AVPlayerItem (see makeAdditionalPlayerItem) back
  /// to which of its real kept segments that position falls in, and the
  /// REAL local time within that segment — mirrors VideoTrimView's own
  /// `realTimeForCompacted`, minus the pixel-mapping half (here the
  /// "compacted" space is the player's own composition timeline, not
  /// screen coordinates).
  private func mergedClipSegment(forCompactedLocalTime compactedTime: Double, in url: URL) -> (index: Int, realTime: Double)? {
    guard let segments = additionalClipSegments[url], !segments.isEmpty else { return nil }
    var remaining = max(0, compactedTime)
    for (index, segment) in segments.enumerated() {
      let length = segment.upperBound - segment.lowerBound
      if remaining <= length || index == segments.count - 1 {
        return (index, segment.lowerBound + max(0, min(remaining, length)))
      }
      remaining -= length
    }
    return nil
  }

  /// Splits the currently-ACTIVE merged clip's own segment at the
  /// playhead — the merged-clip counterpart to `videoTrimView.
  /// splitAtCurrentTime`/`splitLayerSegment`, per the user's explicit
  /// "why on every click of scissors icon layer should cut in split
  /// portion" report (Split used to just silently jump back to the
  /// primary clip and do nothing whenever a merged clip was active).
  private func splitActiveMergedClip(_ url: URL) {
    guard let player else { return }
    // Lazy-init BEFORE mergedClipSegment(forCompactedLocalTime:in:) reads
    // it — that helper (and this function's own guard below) both require
    // additionalClipSegments[url] to already exist, but a freshly-added,
    // never-split-or-trimmed clip has no entry yet (additionalClipKeptDuration
    // only ever READS a fallback, never writes one back). Without this,
    // every scissors tap on a brand-new merged clip silently failed, no
    // matter where the playhead was — per the user's explicit "newly added
    // video is not splitting" report. deleteActiveMergedClipSegment already
    // does this same lazy-init (that's why deleting worked but splitting
    // didn't) — mirrored here.
    if additionalClipSegments[url] == nil {
      additionalClipSegments[url] = [0...additionalClipKeptDuration(for: url)]
    }
    let compactedLocal = CMTimeGetSeconds(player.currentTime())
    guard compactedLocal.isFinite, let (index, splitPoint) = mergedClipSegment(forCompactedLocalTime: compactedLocal, in: url),
          var segments = additionalClipSegments[url], segments.indices.contains(index)
    else { return }
    let segment = segments[index]
    let minSegmentDuration = 0.5
    guard splitPoint - segment.lowerBound >= minSegmentDuration, segment.upperBound - splitPoint >= minSegmentDuration else {
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
      return
    }
    let oldSegments = segments
    segments.replaceSubrange(index...index, with: [segment.lowerBound...splitPoint, splitPoint...segment.upperBound])
    let newSegments = segments
    additionalClipSegments[url] = segments
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    refreshMergedClipsStrip()
    rebuildVideoQueue(startPlaying: false)
    // rebuildVideoQueue always restarts the queue from the PRIMARY clip's
    // beginning (see its own doc) with no memory of where playback was —
    // per the user's explicit "I split it once, now I can't split again,
    // scissors isn't cutting" report: without this, the very next scissors
    // tap saw the playhead sitting back at the primary clip's start (not
    // this merged clip at all), silently tried to split THAT instead, and
    // failed there too (too close to time 0). Land back in this same clip,
    // right at the new split point, matching CapCut-style "the playhead
    // sits at your last edit" behavior.
    seekToMergedClip(url: url, localSeconds: splitPoint)
    pushUndo(
      undo: { [weak self] in
        self?.additionalClipSegments[url] = oldSegments
        self?.refreshMergedClipsStrip()
        self?.rebuildVideoQueue(startPlaying: false)
      },
      redo: { [weak self] in
        self?.additionalClipSegments[url] = newSegments
        self?.refreshMergedClipsStrip()
        self?.rebuildVideoQueue(startPlaying: false)
      }
    )
  }

  /// Deletes one segment of the currently-ACTIVE merged clip — targets
  /// whichever segment was last TAPPED (selectedMergedClipSegmentIndex,
  /// mirroring selectedLayerSegmentIndex/videoTrimView.
  /// selectedSegmentIndex's identical role), falling back to "whichever
  /// segment contains the playhead" otherwise. Refuses (matching warning
  /// haptic) to delete a clip's only remaining segment — same "nothing
  /// left to preview/export" guard the primary clip's own segments use.
  /// Whole-clip removal (mergedStripDeleteButton) was removed per the
  /// user's explicit "remove these red delete icons" request — a merged
  /// clip can now only ever be trimmed down to a single segment, not
  /// removed entirely.
  private func deleteActiveMergedClipSegment(_ url: URL) {
    var segments = additionalClipSegments[url] ?? [0...additionalClipKeptDuration(for: url)]
    if additionalClipSegments[url] == nil {
      additionalClipSegments[url] = segments
    }
    let tappedIndex = (selectedMergedClipURL == url ? selectedMergedClipSegmentIndex : nil).flatMap { segments.indices.contains($0) ? $0 : nil }
    let targetIndex: Int?
    var referenceRealTime: Double?
    if let tappedIndex {
      targetIndex = tappedIndex
      referenceRealTime = segments[tappedIndex].lowerBound
    } else if let player {
      let compactedLocal = CMTimeGetSeconds(player.currentTime())
      let match = compactedLocal.isFinite ? mergedClipSegment(forCompactedLocalTime: compactedLocal, in: url) : nil
      targetIndex = match?.index
      referenceRealTime = match?.realTime
    } else {
      targetIndex = nil
    }
    guard let targetIndex, segments.indices.contains(targetIndex) else { return }
    guard segments.count > 1 else {
      // Only piece left: offer to remove the whole clip (roadmap row 29).
      confirmRemoveMergedClip(url)
      return
    }
    let oldSegments = segments
    segments.remove(at: targetIndex)
    let newSegments = segments
    additionalClipSegments[url] = segments
    if selectedMergedClipURL == url {
      selectedMergedClipURL = nil
      selectedMergedClipSegmentIndex = nil
    }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    refreshMergedClipsStrip()
    rebuildVideoQueue(startPlaying: false)
    // Same fix as splitActiveMergedClip and the primary clip's own delete
    // path — rebuildVideoQueue always restarts from the PRIMARY clip's
    // beginning with no memory of where playback was, which silently
    // kicked the user out of the merged clip they were just editing and
    // broke every following scissors/delete tap on it. Land on whatever
    // segment now occupies the old position, or near (not exactly at) the
    // end of what remains if the trailing-most segment was the one
    // deleted — 2.0 matches VideoTrimView.minTrimDuration, kept as a
    // literal per this file's existing cross-file-constant convention —
    // so an immediate next split on this same clip doesn't land in an
    // unsplittable dead zone right on the edge.
    let matchingMinTrimDuration = 2.0
    let seekTarget: Double
    if let referenceRealTime, let nextSegment = newSegments.first(where: { $0.lowerBound >= referenceRealTime }) {
      seekTarget = nextSegment.lowerBound
    } else if let lastSegment = newSegments.last {
      seekTarget = max(lastSegment.lowerBound, lastSegment.upperBound - matchingMinTrimDuration)
    } else {
      seekTarget = 0
    }
    seekToMergedClip(url: url, localSeconds: seekTarget)
    pushUndo(
      undo: { [weak self] in
        self?.additionalClipSegments[url] = oldSegments
        self?.refreshMergedClipsStrip()
        self?.rebuildVideoQueue(startPlaying: false)
      },
      redo: { [weak self] in
        self?.additionalClipSegments[url] = newSegments
        self?.refreshMergedClipsStrip()
        self?.rebuildVideoQueue(startPlaying: false)
      }
    )
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Leaving the editor (Cancel, Share, or any other dismissal) stops the
    // chosen music and the video preview.
    if isBeingDismissed || isMovingFromParent {
      stopPlaybackForExit()
      voicePlayer?.stop()
      voiceRecorder?.stop()
      // The export is finished (or abandoned) by now — drop our temp inputs.
      let files = tempFilesToDelete
      tempFilesToDelete = []
      DispatchQueue.global(qos: .utility).async {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
      }
    }
  }

  /// Story mode has no play button to resume with, so whatever was
  /// playing when the app was minimised starts again on return.
  private var resumeVideoOnActive = false
  private var resumeMusicOnActive = false

  @objc private func appWillResignActive() {
    resumeVideoOnActive = isStoryMode && player?.timeControlStatus == .playing
    resumeMusicOnActive = isStoryMode && musicPlayer?.timeControlStatus == .playing
    // Outside story mode, go through the normal toggle so the play/pause
    // buttons show "paused" and the user resumes by hand.
    if !isStoryMode, let player, player.timeControlStatus == .playing {
      didTapPlayPause()
    }
    player?.pause()
    musicPlayer?.pause()
    updateStoryMusicBadge()
  }

  @objc private func appDidBecomeActive() {
    // Not while leaving — the editor may be mid-dismissal.
    guard !isBeingDismissed else { return }
    if resumeVideoOnActive, let player { startPlayback(player) }
    if resumeMusicOnActive { musicPlayer?.play() }
    resumeVideoOnActive = false
    resumeMusicOnActive = false
    updateStoryMusicBadge()
  }

  private func stopPlaybackForExit() {
    resumeVideoOnActive = false
    resumeMusicOnActive = false
    player?.pause()
    musicPlayer?.pause()
  }

  deinit {
    blurCoverLink?.invalidate()
    if let token = timeObserverToken {
      player?.removeTimeObserver(token)
    }
    if let lastQueueItemEndObserver {
      NotificationCenter.default.removeObserver(lastQueueItemEndObserver)
    }
    if let primaryItemEndObserver {
      NotificationCenter.default.removeObserver(primaryItemEndObserver)
    }
    if let musicPlayerLoopObserver {
      NotificationCenter.default.removeObserver(musicPlayerLoopObserver)
    }
  }

  // MARK: - Music (Day 23 — selection + preview only)

  /// Splits the music row's segment currently under the playhead — the
  /// music counterpart to splitLayerSegment/splitActiveMergedClip. Per
  /// the user's explicit "same split music layer also" request.
  private func splitMusicSegment(at index: Int) {
    guard musicSegments.indices.contains(index) else { return }
    let segment = musicSegments[index]
    let splitPoint = combinedTimeForCurrentPlayback()
    let minSegmentDuration = 0.5
    guard splitPoint - segment.lowerBound >= minSegmentDuration, segment.upperBound - splitPoint >= minSegmentDuration else {
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
      return
    }
    let oldSegments = musicSegments
    musicSegments.replaceSubrange(index...index, with: [segment.lowerBound...splitPoint, splitPoint...segment.upperBound])
    let newSegments = musicSegments
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    updateMusicPlaybackWindow()
    refreshLayersPanel()
    pushUndo(
      undo: { [weak self] in
        self?.musicSegments = oldSegments
        self?.updateMusicPlaybackWindow()
        self?.refreshLayersPanel()
      },
      redo: { [weak self] in
        self?.musicSegments = newSegments
        self?.updateMusicPlaybackWindow()
        self?.refreshLayersPanel()
      }
    )
  }

  /// Deletes one segment of the music row — targets whichever segment was
  /// last TAPPED (selectedMusicSegmentIndex), falling back to "whichever
  /// segment contains the playhead" otherwise, mirroring
  /// deleteLayerSegment/deleteActiveMergedClipSegment. Refuses (matching
  /// warning haptic) to delete the music's only remaining segment — same
  /// "nothing left to preview/export" guard every other segment-delete in
  /// this file uses.
  private func deleteMusicSegment(at index: Int) {
    guard musicSegments.indices.contains(index) else { return }
    // Same "last remaining segment" handoff as deleteLayerSegment: with
    // only one segment left there's nothing to split it FROM, so this is
    // really a request to remove the whole track — go through the
    // confirm dialog instead of silently no-oping.
    guard musicSegments.count > 1 else {
      confirmDeleteMusicLayer()
      return
    }
    let oldSegments = musicSegments
    musicSegments.remove(at: index)
    let newSegments = musicSegments
    if selectedMusicSegmentIndex == index { selectedMusicSegmentIndex = nil }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    updateMusicPlaybackWindow()
    refreshLayersPanel()
    pushUndo(
      undo: { [weak self] in
        self?.musicSegments = oldSegments
        self?.updateMusicPlaybackWindow()
        self?.refreshLayersPanel()
      },
      redo: { [weak self] in
        self?.musicSegments = newSegments
        self?.updateMusicPlaybackWindow()
        self?.refreshLayersPanel()
      }
    )
  }

  @objc private func didTapMusic() {
    presentMusicPicker(onDismiss: nil)
  }

  private func presentMusicPicker(onDismiss: (() -> Void)?) {
    // Rich picker (live trending/search via MusicAPI, per-row preview) —
    // replaces the old plain UIAlertController list over the static
    // bridge-provided `musicTracks`, per the user's explicit "same as add
    // post screen selection process" request.
    let picker = MusicPickerViewController()
    picker.onSelect = { [weak self] track in
      self?.selectMusicTrack(track)
    }
    picker.onDismiss = onDismiss
    present(picker, animated: true)
  }

  private func selectMusicTrack(_ track: MusicTrack?) {
    // A new song starts playing; an old badge pause doesn't carry over.
    isStoryMusicPausedByUser = false
    musicPlayerTimeControlObservation?.invalidate()
    musicPlayerTimeControlObservation = nil
    if let musicPlayerLoopObserver {
      NotificationCenter.default.removeObserver(musicPlayerLoopObserver)
      self.musicPlayerLoopObserver = nil
    }
    musicPlayer?.pause()
    musicPlayer = nil
    selectedMusicTrack = track
    musicOffset = 0
    musicSegments = []
    selectedMusicSegmentIndex = nil
    musicTrimStart = 0
    updateMusicTrackUI()
    updateStoryMusicBadge()
    refreshLayersPanel()

    musicBeats = []
    updateBeatSyncNote()
    guard let track else { return }
    prefetchMusicFile(for: track)
    if !isStoryMode, mediaType != "image" { detectBeats(for: track) }
    let musicPlayer = AVPlayer(url: track.audioURL)
    // Carries over whatever volume the user already dialed in for a
    // previous track rather than resetting to full volume every pick.
    musicPlayer.volume = musicVolumeSlider.value
    self.musicPlayer = musicPlayer
    musicPlayerTimeControlObservation = musicPlayer.observe(\.timeControlStatus) { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.updateStoryMusicBadge()
      }
    }
    if let currentItem = musicPlayer.currentItem {
      musicPlayerLoopObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: currentItem, queue: .main
      ) { [weak musicPlayer] _ in
        musicPlayer?.seek(to: .zero)
        musicPlayer?.play()
      }
    }
    // A still image has no main player to match — picking a track there
    // should autoplay immediately (per the user's explicit "make song on
    // auto play" request), since there's no other transport state to
    // sync with. For video, keep matching whatever the main player is
    // doing right now rather than always autoplaying — picking a track
    // while paused shouldn't start audio.
    if mediaType == "image" || player?.timeControlStatus == .playing {
      musicPlayer.play()
    }
    // Reflects whatever play/pause state the block just above actually
    // landed on (the call right after updateMusicTrackUI() above already
    // covered the "cleared to nil" case, but ran before this musicPlayer
    // existed, so it couldn't yet know whether playback would auto-start).
    updateStoryMusicBadge()

    musicTrimEnd = 0
    Task { [weak self] in
      guard let asset = musicPlayer.currentItem?.asset,
            let duration = try? await asset.load(.duration)
      else { return }
      let seconds = CMTimeGetSeconds(duration)
      guard seconds.isFinite, seconds > 0 else { return }
      await MainActor.run {
        guard let self else { return }
        self.musicTrimEnd = seconds
        // Single starting segment spanning the full (kept) duration —
        // exactly the old single-window default before split existed.
        if self.musicSegments.isEmpty {
          self.musicSegments = [self.musicOffset...(self.musicOffset + seconds)]
        }
        self.refreshLayersPanel()
      }
    }
  }

  @objc private func musicVolumeChanged(_ sender: UISlider) {
    musicPlayer?.volume = sender.value
    musicVolumeValueLabel.text = "\(Int(sender.value * 100))%"
  }

  /// Swaps between the empty-state "+ Choose Music Track" button and the
  /// chosen-track card (title + play/pause + remove), and syncs the
  /// play/pause icon to the current playback state — called on selection
  /// change and once at initial setup.
  private func updateMusicTrackUI() {
    let hasTrack = selectedMusicTrack != nil
    musicButton.isHidden = hasTrack
    musicTrackCard.isHidden = !hasTrack
    musicTrackTitleLabel.text = selectedMusicTrack?.title
    musicChangeTrackButton.isHidden = !hasTrack
    if let track = selectedMusicTrack {
      // As the video will play (speed changes included), like the time label.
      let secs = max(0, Int(playedOutTime(forCombined: combinedLayerDuration())))
      let plays = String(format: "plays 0:00–%d:%02d", secs / 60, secs % 60)
      if mediaType == "image" {
        musicTrackSubtitleLabel.text = track.artist
      } else {
        musicTrackSubtitleLabel.text = track.artist.isEmpty ? plays : "\(track.artist) · \(plays)"
      }
    } else {
      musicTrackSubtitleLabel.text = nil
    }
    musicVolumeRow.isHidden = !hasTrack
    musicPlayPauseButton.setImage(Self.musicCardPlayImage(playing: isVideoPlaying), for: .normal)
  }

  /// Track card's round play/pause glyph (video redesign).
  private static func musicCardPlayImage(playing: Bool) -> UIImage? {
    UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
  }

  /// Clears the chosen track entirely, per the user's explicit "remove
  /// selected song icon" request — reuses selectMusicTrack(nil), the same
  /// path the picker's own "None" option already takes.
  @objc private func didTapRemoveMusic() {
    selectMusicTrack(nil)
  }

  /// Removes the whole music track — reached once deleteMusicSegment hits
  /// its last remaining segment (same confirm-then-delete shape as
  /// confirmDeleteLayer), per the user's explicit "provide functionality
  /// to remove full music layer" request. Long-press alone no longer
  /// triggers this directly — it just selects the tapped segment now,
  /// per the user's later "on long press these splitted portion should
  /// select only" correction.
  private func confirmDeleteMusicLayer() {
    guard selectedMusicTrack != nil else { return }
    let alert = UIAlertController(title: "Delete music?", message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      self?.selectMusicTrack(nil)
    })
    present(alert, animated: true)
  }

  // MARK: - Original audio (Day 25)

  @objc private func originalAudioVolumeChanged(_ sender: UISlider) {
    originalAudioVolumeValueLabel.text = "\(Int(sender.value * 100))%"
    player?.volume = effectivePlayerVolume()
  }

  @objc private func didTapCancel() {
    onCancel()
  }

  // MARK: - Redesign: LOOKS · TOOLS · EXPORT bar + Tools grid

  /// Height of the LOOKS · TOOLS · EXPORT bar under the tool rail — only
  /// the photo editor has it (not story mode, not the video editor).
  private var lookToolsBarHeight: CGFloat {
    (isStoryMode || mediaType != "image") ? 0 : EditorDesignTokens.Spacing.lookToolsBarHeight
  }

  private func setUpLookToolsBar() {
    let hairline = UIView()
    hairline.backgroundColor = EditorDesignTokens.Colors.divider
    hairline.translatesAutoresizingMaskIntoConstraints = false
    let row = UIStackView()
    row.axis = .horizontal
    row.distribution = .fillEqually
    row.translatesAutoresizingMaskIntoConstraints = false
    let items: [(String, () -> Void)] = [
      ("LOOKS", { [weak self] in self?.didTapEffectTab() }),
      ("TOOLS", { [weak self] in self?.didTapToolsGrid() }),
      ("EXPORT", { [weak self] in self?.didTapDone() }),
    ]
    lookToolsButtons = items.map { title, action in
      let button = UIButton(type: .custom)
      button.setAttributedTitle(NSAttributedString(string: title, attributes: [
        .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
        .kern: 1.0,
        .foregroundColor: EditorDesignTokens.Colors.textSecondary,
      ]), for: .normal)
      button.addAction(UIAction { _ in
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
      }, for: .touchUpInside)
      let underline = UIView()
      underline.backgroundColor = EditorDesignTokens.Colors.accent
      underline.layer.cornerRadius = 1.5
      underline.isHidden = true
      underline.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(underline)
      NSLayoutConstraint.activate([
        underline.widthAnchor.constraint(equalToConstant: 18),
        underline.heightAnchor.constraint(equalToConstant: 3),
        underline.centerXAnchor.constraint(equalTo: button.centerXAnchor),
        underline.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -8),
      ])
      row.addArrangedSubview(button)
      return (button, underline)
    }
    bottomTrayCardView.addSubview(hairline)
    bottomTrayCardView.addSubview(row)

    NSLayoutConstraint.activate([
      hairline.topAnchor.constraint(equalTo: bottomTrayScrollView.bottomAnchor),
      hairline.leadingAnchor.constraint(equalTo: bottomTrayCardView.leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: bottomTrayCardView.trailingAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1),
      row.topAnchor.constraint(equalTo: hairline.bottomAnchor),
      row.leadingAnchor.constraint(equalTo: bottomTrayCardView.leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: bottomTrayCardView.trailingAnchor, constant: -12),
      row.bottomAnchor.constraint(equalTo: bottomTrayCardView.bottomAnchor),
    ])
  }

  // MARK: - Glass tool row (Instagram-style)

  private func setUpToolGlass() {
    // The card itself goes clear: the bar floats over the photo and only
    // the LOOKS · TOOLS · EXPORT bar keeps a solid background.
    bottomTrayCardView.backgroundColor = .clear
    bottomTrayCardView.layer.shadowOpacity = 0
    let lookBackground = UIView()
    lookBackground.backgroundColor = EditorDesignTokens.Colors.chromeBackground
    lookBackground.translatesAutoresizingMaskIntoConstraints = false
    bottomTrayCardView.insertSubview(lookBackground, at: 0)
    NSLayoutConstraint.activate([
      lookBackground.topAnchor.constraint(equalTo: bottomTrayScrollView.bottomAnchor),
      lookBackground.leadingAnchor.constraint(equalTo: bottomTrayCardView.leadingAnchor),
      lookBackground.trailingAnchor.constraint(equalTo: bottomTrayCardView.trailingAnchor),
      lookBackground.bottomAnchor.constraint(equalTo: bottomTrayCardView.bottomAnchor),
    ])
    // iOS 26: the system tab bar IS the design — it draws the Liquid Glass
    // capsule, the selection lens and the morphing itself (same approach
    // as the reference EDTabBarController).
    // Not for the video editor — see isCompactToolRail.
    if #available(iOS 26.0, *), !isCompactToolRail {
      setUpSystemToolTabBar()
      return
    }
    // Our own floating capsule with a sliding lozenge — Liquid Glass on
    // iOS 26 (video editor), frosted before that.
    toolGlassView.translatesAutoresizingMaskIntoConstraints = false
    bottomTrayCardView.insertSubview(toolGlassView, belowSubview: bottomTrayScrollView)
    let inset = toolGlassInsetH
    NSLayoutConstraint.activate([
      toolGlassView.leadingAnchor.constraint(equalTo: bottomTrayCardView.leadingAnchor, constant: inset),
      toolGlassView.trailingAnchor.constraint(equalTo: bottomTrayCardView.trailingAnchor, constant: -inset),
      toolGlassView.topAnchor.constraint(equalTo: bottomTrayScrollView.topAnchor, constant: Self.toolGlassInsetV),
      toolGlassView.bottomAnchor.constraint(equalTo: bottomTrayScrollView.bottomAnchor, constant: -Self.toolGlassInsetV),
    ])
    toolLensView.isUserInteractionEnabled = false
    toolLensView.isHidden = true
    bottomTrayScrollView.insertSubview(toolLensView, belowSubview: bottomTabBar)
  }

  // MARK: iOS 26 — system tab bar

  /// The rail's buttons, by tab-bar item tag (the bar forwards taps to them,
  /// so every tool keeps its existing action).
  private var toolTabBarButtons: [UIButton] = []
  private var toolTabBar: UITabBar?

  @available(iOS 26.0, *)
  private func setUpSystemToolTabBar() {
    let buttons = bottomTabBar.arrangedSubviews.compactMap { $0 as? UIButton }
    toolTabBarButtons = buttons
    let bar = UITabBar()
    bar.items = buttons.enumerated().map { index, button in
      let title = button.configuration?.title ?? ""
      let item = UITabBarItem(title: title, image: button.configuration?.image, tag: index)
      item.accessibilityLabel = title
      // More room between icon and name: the ICON moves up (the title is
      // left alone — shifting titles is what cut names to "Fil…").
      item.imageInsets = UIEdgeInsets(top: -Self.systemTabBarIconLift, left: 0, bottom: Self.systemTabBarIconLift, right: 0)
      return item
    }
    // Default background = the system Liquid Glass (a transparent
    // configuration would remove it).
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    let items = appearance.stackedLayoutAppearance
    let normal = EditorDesignTokens.Colors.textPrimary.withAlphaComponent(0.78)
    let selected = EditorDesignTokens.Colors.textPrimary
    let font = UIFont.systemFont(ofSize: 10, weight: .medium)
    items.normal.iconColor = normal
    items.selected.iconColor = selected
    items.normal.titleTextAttributes = [.foregroundColor: normal, .font: font]
    items.selected.titleTextAttributes = [.foregroundColor: selected, .font: font]
    appearance.stackedLayoutAppearance = items
    appearance.inlineLayoutAppearance = items
    appearance.compactInlineLayoutAppearance = items
    bar.standardAppearance = appearance
    bar.scrollEdgeAppearance = appearance
    bar.tintColor = selected
    // The editor is dark; pin the bar so the glass and icons match it.
    bar.overrideUserInterfaceStyle = .dark
    bar.delegate = self
    bar.translatesAutoresizingMaskIntoConstraints = false
    // The system bar replaces the hand-built row (its buttons stay, unseen,
    // as the actions the bar forwards to).
    bottomTrayScrollView.isHidden = true
    bottomTrayCardView.addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: bottomTrayCardView.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: bottomTrayCardView.trailingAnchor),
      bar.topAnchor.constraint(equalTo: bottomTrayScrollView.topAnchor),
      bar.bottomAnchor.constraint(equalTo: bottomTrayScrollView.bottomAnchor),
    ])
    toolTabBar = bar
    syncToolTabBarSelection()
  }

  /// Puts the system bar's selection on the open tool (none for tools that
  /// don't stay open: Text / Overlay / Add Video, or the plain editor).
  private func syncToolTabBarSelection() {
    guard let bar = toolTabBar else { return }
    let index = selectedToolRailButton.flatMap { button in toolTabBarButtons.firstIndex { $0 === button } }
    let item = index.flatMap { i in bar.items?.first { $0.tag == i } }
    if bar.selectedItem !== item { bar.selectedItem = item }
  }

  /// The rail button for the open tool, if it has one.
  private var selectedToolRailButton: UIButton? {
    switch selectedImageEditorTab {
    case .effect: return effectTabButton
    case .edit: return editTabButton
    case .stickers: return stickerTabButton
    case .draw: return drawTabButton
    case .music: return musicTabButton
    default: return nil
    }
  }

  // MARK: Pre-iOS 26 — lozenge

  private var lozengeAnimator: UIViewPropertyAnimator?

  /// Lozenge rect for a rail button, in the row's content coordinates:
  /// the slot, inset 4pt from the capsule's top and bottom.
  private func toolLensRect(for button: UIButton) -> CGRect {
    bottomTabBar.layoutIfNeeded()
    let slot = bottomTabBar.convert(button.frame, to: bottomTrayScrollView)
    let height = bottomTrayScrollView.bounds.height - 2 * Self.toolGlassInsetV - 8
    return CGRect(x: slot.minX + 1, y: bottomTrayScrollView.bounds.midY - height / 2, width: slot.width - 2, height: height)
  }

  private func updateToolLens(animated: Bool) {
    guard !isStoryMode else { return }
    if toolTabBar != nil {
      syncToolTabBarSelection()
      return
    }
    guard toolLensView.superview != nil else { return }
    guard let button = selectedToolRailButton, !button.isHidden else {
      lozengeAnimator?.stopAnimation(true)
      lozengeAnimator = nil
      toolLensView.isHidden = true
      return
    }
    view.layoutIfNeeded()
    let target = toolLensRect(for: button)
    // Snap when not animating, or on the very first placement.
    guard animated, !toolLensView.isHidden, toolLensView.frame.width > 0 else {
      lozengeAnimator?.stopAnimation(true)
      lozengeAnimator = nil
      toolLensView.frame = target
      toolLensView.isHidden = false
      return
    }
    // A light spring, close to the system bar's; a quick second tap
    // redirects the slide from where the lozenge visibly is.
    lozengeAnimator?.stopAnimation(true)
    let animator = UIViewPropertyAnimator(duration: 0.35, dampingRatio: 0.8) {
      self.toolLensView.frame = target
    }
    animator.addCompletion { [weak self] _ in self?.lozengeAnimator = nil }
    lozengeAnimator = animator
    animator.startAnimation()
  }

  /// LOOKS is lit while Filters is open, TOOLS while the grid is open.
  private func updateLookToolsBar() {
    let active: [Bool] = [selectedImageEditorTab == .effect, selectedImageEditorTab == .toolsGrid, false]
    for (index, item) in lookToolsButtons.enumerated() {
      let on = index < active.count && active[index]
      let title = item.button.attributedTitle(for: .normal)?.string ?? ""
      item.button.setAttributedTitle(NSAttributedString(string: title, attributes: [
        .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
        .kern: 1.0,
        .foregroundColor: on ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.textSecondary,
      ]), for: .normal)
      item.underline.isHidden = !on
    }
  }

  @objc private func didTapToolsGrid() {
    pauseVideoForToolInteraction()
    // Tall enough for every tile row, plus the home-indicator area.
    let rows = CGFloat(max(toolsGridRowCount, 1))
    toolsGridPanel.setCollapsedHeight(53 + rows * 84 + (rows - 1) * 10 + 16 + view.safeAreaInsets.bottom)
    selectedImageEditorTab = selectedImageEditorTab == .toolsGrid ? .tools : .toolsGrid
    updateImageEditorUI(animated: true)
  }

  /// Every tool as a tile; a tap closes the grid and opens that tool.
  private func setUpToolsGridPanel(isImage: Bool) {
    var tools: [(String, String, () -> Void)] = [
      ("tool_adjust", "Tune", { [weak self] in self?.didTapEditTab() }),
      ("tool_filters", "Filters", { [weak self] in self?.didTapEffectTab() }),
    ]
    if isImage {
      tools.append(("tool_auto", "Auto", { [weak self] in
        self?.didTapEditTab()
        self?.didTapAdjustIcon(.auto)
      }))
      tools.append(("tool_blur", "Blur", { [weak self] in
        self?.didTapEditTab()
        self?.didTapAdjustIcon(.blur)
      }))
    }
    tools.append(("tool_vignette", "Vignette", { [weak self] in
      self?.didTapEditTab()
      self?.didTapAdjustIcon(.vignette)
    }))
    tools.append(("tool_text", "Text", { [weak self] in self?.presentTextEntryOverlay() }))
    tools.append(("tool_draw", "Draw", { [weak self] in self?.didTapDrawTab() }))
    tools.append(("tool_sticker", "Sticker", { [weak self] in self?.didTapStickersTab() }))
    if isImage {
      tools.append(("tool_overlay", "Overlay", { [weak self] in self?.presentImageOverlayPicker() }))
    } else {
      tools.append(("tool_music", "Music", { [weak self] in self?.didTapMusicTab() }))
      tools.append(("tool_add_video", "Add clip", { [weak self] in self?.presentVideoClipPicker() }))
    }

    let grid = UIStackView()
    grid.axis = .vertical
    grid.spacing = 10
    grid.translatesAutoresizingMaskIntoConstraints = false
    let columns = 4
    toolsGridRowCount = (tools.count + columns - 1) / columns
    for start in stride(from: 0, to: tools.count, by: columns) {
      let row = UIStackView()
      row.axis = .horizontal
      row.spacing = 10
      row.distribution = .fillEqually
      for (imageName, title, action) in tools[start..<min(start + columns, tools.count)] {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(named: imageName)?.withRenderingMode(.alwaysTemplate)
        config.title = title
        config.imagePlacement = .top
        config.imagePadding = 8
        config.baseForegroundColor = EditorDesignTokens.Colors.textPrimary
        config.background.backgroundColor = EditorDesignTokens.Colors.elevatedSurface
        config.background.cornerRadius = 16
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
          var outgoing = incoming
          outgoing.font = .systemFont(ofSize: 12, weight: .medium)
          return outgoing
        }
        let tile = UIButton(configuration: config)
        tile.titleLabel?.adjustsFontSizeToFitWidth = true
        tile.heightAnchor.constraint(equalToConstant: 84).isActive = true
        tile.addAction(UIAction { [weak self] _ in
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          // Close the grid first; the tool then opens its own panel/picker.
          self?.selectedImageEditorTab = .tools
          self?.updateImageEditorUI(animated: false)
          action()
        }, for: .touchUpInside)
        row.addArrangedSubview(tile)
      }
      for _ in 0..<(columns - min(columns, tools.count - start)) { row.addArrangedSubview(UIView()) }
      grid.addArrangedSubview(row)
    }
    let scroll = UIScrollView()
    scroll.showsVerticalScrollIndicator = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(grid)
    let container = toolsGridPanel.contentContainer
    container.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: container.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      grid.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      grid.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      grid.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      grid.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      grid.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
    ])
    toolsGridPanel.configureExpandedHeight(screenHeight: UIScreen.main.bounds.height)
    toolsGridPanel.useCloseIconForConfirm()
    toolsGridPanel.onConfirm = { [weak self] in self?.didTapToolsTab() }
  }

  @objc private func didTapDone() {
    NSLog("[MediaEditor] didTapDone: tapped, mediaType=%@", mediaType)
    guard !isExporting else { return }
    // Export reads the real canvas/layer views — bring them back first.
    exitFilterStage(animated: false)
    isExporting = true
    doneButton.isEnabled = false
    loadingIndicator.startAnimating()
    // Stop live preview playback immediately on Done — per the user's
    // explicit "video and music should stop while exporting" request.
    // Mirrors Android's finishSuccess(), which releases its preview
    // players at this same point rather than leaving them running
    // underneath the export progress overlay.
    let wasPlayingBeforeExport = player?.timeControlStatus == .playing
    if wasPlayingBeforeExport { didTapPlayPause() }
    // The line above is a no-op for a still image (it
    // guards on `player`, which is nil there) — a photo's music preview
    // has no video player to piggyback on, so it needs its own explicit
    // stop here or it would otherwise keep playing silently underneath
    // the export progress overlay/after Share is tapped.
    musicPlayer?.pause()
    updateStoryMusicBadge()

    // Snapshotted at tap time, same moment the exports read layer state.
    let stickers = locationStickerMetadata()

    let finishExporting: () -> Void = { [weak self] in
      guard let self else { return }
      self.isExporting = false
      self.doneButton.isEnabled = true
      self.loadingIndicator.stopAnimating()
    }

    if mediaType == "image" {
      // Story mode + a selected music track: mux the still photo + audio
      // into an exported VIDEO instead of a plain image export — per the
      // user's explicit "add music option on the photo story screen too"
      // request. Every other photo path (including story mode without
      // music) is unchanged below.
      if isStoryMode, selectedMusicTrack != nil {
        exportImageWithMusic { [weak self] result in
          guard let self else { return }
          switch result {
          case let .success(url, size, duration):
            finishExporting()
            self.onDone(.exported(uri: url.absoluteString, width: Int(size.width), height: Int(size.height), duration: duration, resultType: "video", stickers: stickers))
          case let .failure(message):
            finishExporting()
            self.onDone(.failed(message: message))
          }
        }
        return
      }
      exportImage { [weak self] result in
        guard let self else { return }
        switch result {
        case let .success(url, size):
          finishExporting()
          // Re-edit: saved only for a plain photo export (not photo+music,
          // which comes back as a video).
          self.exportedEditProjectJSON = self.saveEditProject()
          self.onDone(.exported(uri: url.absoluteString, width: Int(size.width), height: Int(size.height), duration: 0, resultType: "image", stickers: stickers))
        case let .failure(message):
          finishExporting()
          self.onDone(.failed(message: message))
        }
      }
      return
    }

    exportWasCancelled = false
    presentExportProgress()
    startExportProgressPolling()

    exportVideo { [weak self] result in
      guard let self else { return }
      // Snap the smoothed display straight to 100% BEFORE tearing the
      // overlay down — per the user's own "don't make it fast" request
      // the ring intentionally climbs at a capped rate, which means it
      // can still be short of 100% at the exact moment the real export
      // finishes; without this it would otherwise just vanish mid-climb.
      self.exportProgressView?.finishProgress()
      self.dismissExportProgress()
      if self.exportWasCancelled {
        // The user tapped the overlay's X — cancelExport() makes the
        // AVAssetExportSession finish with .cancelled, which would
        // otherwise surface here as an ordinary .failure and pop an error
        // alert the user never asked to see; swallow it silently instead,
        // matching "cancel just returns you to editing."
        finishExporting()
        // Back to how it was (story mode has no play button to resume).
        if wasPlayingBeforeExport, !self.isVideoPlaying { self.didTapPlayPause() }
        return
      }
      switch result {
      case let .success(url, size, duration):
        NSLog("[MediaEditor] didTapDone: video export succeeded, calling onDone(.exported)")
        finishExporting()
        self.onDone(.exported(uri: url.absoluteString, width: Int(size.width), height: Int(size.height), duration: duration, resultType: "video", stickers: stickers))
      case let .failure(message):
        NSLog("[MediaEditor] didTapDone: video export failed, calling onDone(.failed): %@", message)
        finishExporting()
        self.onDone(.failed(message: message))
      }
    }
  }

  /// One-time thumbnail of the video at the moment export starts — the
  /// progress overlay only shows this once, not a live playhead.
  /// `AVPlayerLayer`'s actual video pixels are composited by the system
  /// directly, outside the normal CALayer render tree — a `UIView`-level
  /// snapshot (`drawHierarchy`/`UIGraphicsImageRenderer`) reliably comes
  /// back black for it, per the user's explicit "the colorful progress box
  /// should show the video thumbnail, currently it's empty" report. Grab a
  /// real DECODED frame from the source asset instead via
  /// `AVAssetImageGenerator`, at the exact time the player is currently
  /// showing, so the preview actually matches what's on screen.
  /// Kept alive until its frame arrives — as a local, the generator was
  /// freed as soon as this returned, which cancelled the request and left
  /// the export box empty.
  private var exportThumbnailGenerator: AVAssetImageGenerator?

  private func exportPreviewThumbnail(completion: @escaping (UIImage?) -> Void) {
    // The frame under the playhead (from whichever clip is playing), or
    // the main clip's first kept frame.
    let isPrimary = queuePlayer?.currentItem == nil || queuePlayer?.currentItem === primaryPlayerItem
    let asset = isPrimary ? AVURLAsset(url: sourceURL) : (player?.currentItem?.asset ?? AVURLAsset(url: sourceURL))
    let time = player?.currentTime() ?? CMTime(seconds: videoSegments.first?.lowerBound ?? 0, preferredTimescale: 600)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1080, height: 1080)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    exportThumbnailGenerator = generator
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time.isValid ? time : .zero)]) { [weak self] _, cgImage, _, _, _ in
      let image = cgImage.map { UIImage(cgImage: $0) }
      DispatchQueue.main.async {
        self?.exportThumbnailGenerator = nil
        completion(image)
      }
    }
  }

  private func presentExportProgress() {
    let overlay = ExportProgressView(frame: view.bounds)
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.onCancel = { [weak self] in
      self?.didTapCancelExport()
    }
    view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.topAnchor.constraint(equalTo: view.topAnchor),
      overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    exportProgressView = overlay
    // Generated asynchronously (a real frame decode, unlike the old
    // instant-but-blank view snapshot) — the overlay shows immediately
    // with its plain black placeholder, then gets the actual frame a
    // moment later via this same `configure` it already exposes.
    exportPreviewThumbnail { [weak overlay] image in
      overlay?.configure(previewImage: image)
    }
  }

  private func dismissExportProgress() {
    exportProgressTimer?.invalidate()
    exportProgressTimer = nil
    exportProgressView?.removeFromSuperview()
    exportProgressView = nil
    currentExportSession = nil
  }

  /// AVAssetExportSession.progress predates any documented KVO/async-
  /// stream API — polling is the standard, portable way to read it at
  /// this project's iOS 15.1 deployment target (see gotcha 5/8 in the
  /// project memory re: this deployment target's API ceiling).
  private func startExportProgressPolling() {
    exportProgressTimer?.invalidate()
    exportProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, let session = self.currentExportSession else { return }
      self.exportProgressView?.updateProgress(session.progress)
    }
  }

  private func didTapCancelExport() {
    exportWasCancelled = true
    currentExportSession?.cancelExport()
    // dismissExportProgress()/finishExporting() happen once exportVideo's
    // own completion fires (cancelExport still calls it, with status
    // .cancelled) — not here, so there's only ever one place that tears
    // down the overlay/re-enables Done, regardless of whether export
    // finished, failed, or was cancelled.
  }

  @objc private func didTapUndo() {
    guard let action = undoStack.popLast() else { return }
    action.undo()
    redoStack.append(action)
    // Undoing past where the open tool started: ✕ mustn't redo those.
    if let session = toolSession, undoStack.count < session.depth {
      toolSession = (session.tab, undoStack.count)
    }
  }

  /// Folds every undo step since `depth` into one (a tool's whole session).
  private func mergeUndoSteps(since depth: Int) {
    guard depth >= 0, undoStack.count - depth > 1 else { return }
    let actions = Array(undoStack[depth...])
    undoStack.removeSubrange(depth...)
    undoStack.append(UndoableAction(
      undo: { actions.reversed().forEach { $0.undo() } },
      redo: { actions.forEach { $0.redo() } }
    ))
  }

  private struct MusicSessionSnapshot {
    let track: MusicTrack?
    let offset: Double
    let segments: [ClosedRange<Double>]
    let selectedSegment: Int?
    let trimStart: Double
    let trimEnd: Double
    let musicVolume: Float
    let originalVolume: Float
  }
  /// Music as it was when the Music sheet opened (video redesign ✕).
  private var musicSessionSnapshot: MusicSessionSnapshot?

  /// ✕ on the full-screen Music sheet: put back the track, its timing and
  /// both volumes as they were when the sheet opened.
  private func cancelMusicSession() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if let snap = musicSessionSnapshot {
      if snap.track?.audioURL != selectedMusicTrack?.audioURL {
        selectMusicTrack(snap.track)
      }
      musicOffset = snap.offset
      musicSegments = snap.segments
      selectedMusicSegmentIndex = snap.selectedSegment
      musicTrimStart = snap.trimStart
      musicTrimEnd = snap.trimEnd
      musicVolumeSlider.value = snap.musicVolume
      musicVolumeChanged(musicVolumeSlider)
      originalAudioVolumeSlider.value = snap.originalVolume
      originalAudioVolumeChanged(originalAudioVolumeSlider)
      refreshLayersPanel()
    }
    musicSessionSnapshot = nil
    selectedImageEditorTab = .tools
    updateImageEditorUI(animated: true)
  }

  /// Video redesign: while full-screen Filters or Music is open the video
  /// shrinks to sit between the top and the sheet (photos use the filter
  /// stage). A transform only, so the canvas layout itself is untouched.
  private func updateVideoStage(animated: Bool) {
    guard mediaType != "image", !isStoryMode else { return }
    var target = CGAffineTransform.identity
    if selectedImageEditorTab == .effect || selectedImageEditorTab == .music, let panel = filterStagePanel {
      view.layoutIfNeeded()
      let size = canvasClipContainerView.bounds.size
      let center = canvasClipContainerView.superview?.convert(canvasClipContainerView.center, to: view) ?? canvasClipContainerView.center
      let top = view.safeAreaLayoutGuide.layoutFrame.minY + 56
      // Filters also has the play + scrub row above its sheet.
      let bottom = view.bounds.height - panel.bounds.height - 12 - (selectedImageEditorTab == .effect ? 52 : 0)
      let available = bottom - top
      if size.width > 0, size.height > 0, available > 80 {
        let scale = min(1, available / size.height, (view.bounds.width - 32) / size.width)
        target = CGAffineTransform(translationX: 0, y: (top + available / 2) - center.y).scaledBy(x: scale, y: scale)
      }
    }
    guard canvasClipContainerView.transform != target else { return }
    UIView.animate(withDuration: animated ? EditorDesignTokens.Motion.panelToggleDuration : 0, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      self.canvasClipContainerView.transform = target
    }
  }

  /// ✕ on a tool panel: put back everything changed since it opened.
  private func cancelToolSession() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if selectedImageEditorTab == .textStyle, let target = textStyleTarget, let snapshot = textStyleAtOpen {
      // Not committed to the undo stack yet — restore it directly.
      textStyleTarget = nil
      textStyleAtOpen = nil
      applyStyleSnapshot(snapshot, to: target)
    }
    if let session = toolSession {
      while undoStack.count > session.depth, let action = undoStack.popLast() {
        action.undo()
      }
      toolSession = nil
    }
    if selectedImageEditorTab == .effect { setFilterEditing(false) }
    selectedImageEditorTab = .tools
    updateImageEditorUI(animated: true)
  }

  @objc private func didTapRedo() {
    guard let action = redoStack.popLast() else { return }
    action.redo()
    undoStack.append(action)
  }

  // MARK: - Layer deletion (long-press)

  private func confirmDeleteLayer(_ label: EditableLayerView) {
    if isLayerLocked(label) {
      showEditorToast("Layer is locked. Unlock it to delete.")
      return
    }
    let alert = UIAlertController(title: "Delete this layer?", message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      self?.deleteLayer(label)
    })
    present(alert, animated: true)
  }

  private func deleteLayer(_ label: EditableLayerView) {
    // Long-press → confirm (confirmDeleteLayer) can delete a layer that
    // was never explicitly tapped-selected first — if it WAS the current
    // selection, clear it now so its white border and the canvas's own
    // yellow one (see updateCanvasSelectionBorder) don't stay stuck on a
    // hidden layer.
    if selectedLayer === label { deselectLayer() }
    label.isHidden = true
    label.isUserInteractionEnabled = false
    refreshLayersPanel()
    pushUndo(
      undo: { [weak self] in
        label.isHidden = false
        label.isUserInteractionEnabled = true
        self?.refreshLayersPanel()
      },
      redo: { [weak self] in
        label.isHidden = true
        label.isUserInteractionEnabled = false
        self?.refreshLayersPanel()
      }
    )
  }

  // MARK: - Per-layer-type track rows (time range editor)
  //
  // Per the user's explicit "each text/sticker/overlay element should have
  // its own layer, draggable to extend/reduce" request (reference image:
  // a stacked multi-track timeline), followed by two corrections: (1)
  // these rows should NOT live behind their own tab ("as we are getting
  // these both layers in a separate Layers tab... display these both
  // layers on screen") — they're stacked directly above the trim
  // scrubber (layerTracksStack/layerTracksScrollView, set up in
  // viewDidLoad), always visible on the Tools tab; (2) multiple layers of
  // the SAME type should NOT each get their own row ("for multiple
  // emojis multiple layer will not be created, all images will be in
  // single layer one by one... same for text") — there are always at
  // most 3 rows (Text/Stickers/Overlay), each a single LayerRangeBarView
  // showing every layer of that type as its own independently draggable
  // colored range within the SAME bar. Z-order reordering (previously
  // up/down buttons per layer) was dropped in that same correction — a
  // layer's render order is now just its insertion order, not user-
  // adjustable from this panel. Export-time enforcement of these ranges
  // is a separate, not-yet-built follow-up (see LayerRangeBarView.swift's
  // own doc) — this pass covers live-preview + the editing UI only.

  /// Total KEPT duration across the PRIMARY clip AND every merged clip —
  /// the same combined, gap-compacted coordinate space
  /// `combinedTimeForCurrentPlayback()` reports during playback (clips
  /// packed back-to-back, deleted segments/trims removed). Layer timing
  /// (`registerLayerTiming`/`refreshLayersPanel`/`updateLayerTimeVisibility`)
  /// is expressed in THIS space, not the primary clip's own raw local
  /// time — per the user's explicit "if I add new video then existing
  /// text/icon/music should be auto added on that layer too" request,
  /// reversing an earlier "layers stay primary-clip-only, merged clips
  /// have none of their own" scoping decision (see
  /// `didPickSecondVideoClip`'s own doc) specifically for this.
  private func combinedLayerDuration() -> Double {
    let primaryKeptDuration = videoSegments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
    let mergedKeptDuration = additionalVideoClipURLs.reduce(0.0) { $0 + additionalClipKeptDuration(for: $1) }
    return primaryKeptDuration + mergedKeptDuration
  }

  /// Sum of a merged clip's own KEPT segment durations — the "how much of
  /// this clip actually contributes to combined playback time" figure
  /// used everywhere a merged clip's span is needed (anchoring, filmstrip
  /// width, combined-timeline duration, the duration label). Falls back
  /// to the full clip when it hasn't been split/trimmed at all yet.
  private func additionalClipKeptDuration(for url: URL) -> Double {
    let fullDuration = additionalClipDurations[url] ?? 5
    guard let segments = additionalClipSegments[url], !segments.isEmpty else { return fullDuration }
    return segments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
  }

  /// Registers a fresh [currentPlayhead, duration] time range for a
  /// newly-added layer — starts wherever playback currently is, runs to
  /// the end of the COMBINED (primary + every merged clip) timeline — a
  /// no-op for image sessions, which have no time axis. Call right after
  /// appending to textLayerViews/stickerLayerViews/imageOverlayLayerViews.
  private static let newLayerDefaultSeconds: Double = 3
  /// Max text/sticker/photo layers in a video (see canAddLayer).
  static let maxVideoLayers = 10

  private func registerLayerTiming(_ layer: UIView) {
    guard mediaType != "image" else { return }
    // The FIRST layer in a fresh session should always auto-expand the
    // dedicated area (per the user's explicit "if layers are active
    // these video preview goes smaller" request) even if the user
    // collapsed it earlier this session and then deleted every layer —
    // once truly empty, a re-collapse from a past session shouldn't
    // linger. A later add while layers already exist respects whatever
    // the user last chose.
    if layerTimings.isEmpty {
      isLayersAreaCollapsed = false
    }
    let duration = combinedLayerDuration()
    let clampedDuration = duration > 0 ? duration : 1
    // Per the user's explicit "layers should start from the white center
    // line" request — a newly-added text/sticker/overlay now starts
    // wherever playback currently is (the fixed white playhead line,
    // filmstripPlayheadView) instead of always from the very beginning
    // of the clip. Uses combinedTimeForCurrentPlayback() — the SAME
    // combined-timeline coordinate space `duration` above and
    // updateLayerTimeVisibility now both use — not the primary player's
    // own raw local time, which resets to 0 once playback advances into
    // a merged clip. Clamped so scrubbing to the very last instant
    // before adding still leaves a usable, visible slice (matches the
    // 0.5s minimum segment length used elsewhere) rather than a
    // zero-length range.
    let playheadSeconds = combinedTimeForCurrentPlayback()
    // Story mode: every layer shows for the WHOLE video (Instagram-style)
    // — there's no layer timeline there to adjust it with anyway.
    let start = isStoryMode ? 0 : min(max(0, playheadSeconds), max(0, clampedDuration - 0.5))
    // Edits-style default length: 3 seconds from the playhead (or to the
    // end, if that's sooner) so new layers don't all pile up full-length.
    // Story mode keeps the whole video.
    let end = isStoryMode ? clampedDuration : min(clampedDuration, start + Self.newLayerDefaultSeconds)
    layerTimings[ObjectIdentifier(layer)] = LayerTiming(segments: [start...end])
    // Per the user's explicit, repeated "ALL layers should start from
    // the white [playhead] line" request, every newly-added layer keeps
    // its own playhead-anchored start untouched — no longer redistributed
    // into an equal, 0-anchored slice alongside its same-type siblings
    // (that was reflowAutoTimedLayers, from an earlier "text and icon
    // both default to the whole clip and end up fully overlapping"
    // round; removed since it directly fought this new request — it
    // unconditionally overwrote every same-type layer's start, including
    // this one, the moment a 2nd same-type layer was added). Trade-off,
    // told to the user: layers added at the same/overlapping playhead
    // position can visually overlap again, same as before that reflow
    // existed — drag a layer's own range-bar segment to adjust it
    // manually if that happens.
    refreshLayersPanel()
  }

  /// `setUpVideoPlayer`'s real-duration load (`asset.load(.duration)`) is
  /// async — a layer added in the brief window before it resolves gets
  /// stamped with `registerLayerTiming`'s 0...1 sentinel fallback above.
  /// Once the real duration is known, stretch any timing still exactly at
  /// that sentinel out to the real full clip, otherwise it stays a barely-
  /// visible sliver in its LayerRangeBarView track forever (its range bar
  /// renders at 1/duration of the row's width) — easy to mistake for "this
  /// layer's row never showed up" when a second layer registered AFTER the
  /// duration resolved fills its own row edge-to-edge right next to it.
  private func correctFallbackLayerTimings(toDuration duration: Double) {
    guard duration > 1 else { return }
    var didChange = false
    // Sentinel is always this layer's SOLE segment at this point — a
    // layer can't have been split yet in the brief window before the
    // real duration resolves. Matched by its upperBound alone (the
    // fallback's fixed `1` duration), NOT the full `[0...1]` segment —
    // registerLayerTiming's playhead-anchored start means the sentinel's
    // lowerBound can be any value up to 0.5, not just 0, so a `== [0...1]`
    // equality check silently failed to correct any layer added after
    // playback had already advanced even slightly, leaving it stuck as a
    // ~1-second sliver forever (looks like "only visible at one position").
    for (id, timing) in layerTimings where timing.segments.count == 1 && timing.segments[0].upperBound == 1 {
      let start = timing.segments[0].lowerBound
      layerTimings[id] = LayerTiming(segments: [start...duration], isManuallyHidden: timing.isManuallyHidden, isLocked: timing.isLocked, anim: timing.anim)
      didChange = true
    }
    if didChange {
      refreshLayersPanel()
    }
  }

  /// The current z-order (bottom to top) of every NON-deleted text/
  /// sticker/overlay layer, read straight from the real view hierarchy —
  /// no parallel tracking array to keep in sync, since `view.subviews`
  /// already IS the actual render order.
  private func allLayerViews() -> [UIView] {
    let layerIdentifiers = Set((textLayerViews + stickerLayerViews).map(ObjectIdentifier.init))
      .union(imageOverlayLayerViews.map(ObjectIdentifier.init))
    return view.subviews.filter { layerIdentifiers.contains(ObjectIdentifier($0)) && !$0.isHidden }
  }

  /// Track badge by layer type — the sticker/photo itself, or a "T" symbol.
  private func layerTrackBadge(for layer: UIView) -> (image: UIImage?, fills: Bool) {
    if let imageLayer = layer as? EditableImageLayerView, let image = imageLayer.image {
      return (Self.layerTrackThumbnail(image), true)
    }
    if let textLayer = layer as? EditableTextLayerView, textLayer.isStickerImageLayer, let sticker = textLayer.stickerImage {
      return (Self.layerTrackThumbnail(sticker), false)
    }
    return (Self.layerTrackSymbol("textformat"), false)
  }

  private static func layerTrackSymbol(_ name: String) -> UIImage? {
    UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
      .withTintColor(.white, renderingMode: .alwaysOriginal)
  }

  /// Small copy so redrawing a track during a drag stays cheap.
  private static func layerTrackThumbnail(_ image: UIImage) -> UIImage {
    let maxSide: CGFloat = 44
    let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
    let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
    return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
  }

  /// Highlights the selected layer's track (white border + white trim
  /// handles), whether it was picked on the track or on the canvas, and
  /// after rows are rebuilt. Its body then drags to move it in time.
  private func syncLayerTrackSelection() {
    for case let row as LayerRangeBarView in layerTracksStack.arrangedSubviews {
      guard let owner = layerTrackRowOwners[ObjectIdentifier(row)] else { continue }
      if let selectedLayer, owner === selectedLayer {
        row.setSelection(id: ObjectIdentifier(owner), segmentIndex: selectedLayerSegmentIndex ?? 0)
      } else {
        row.setSelection(id: nil, segmentIndex: nil)
      }
    }
  }

  /// Track colour by layer type — text purple, sticker amber, photo blue.
  private func layerTrackColor(for layer: UIView) -> UIColor {
    if stickerLayerViews.contains(where: { $0 === layer }) { return EditorDesignTokens.Colors.stickerLayer }
    if textLayerViews.contains(where: { $0 === layer }) { return EditorDesignTokens.Colors.textLayer }
    return EditorDesignTokens.Colors.accent
  }

  /// Moves `row` one slot up (-1) or down (+1) among the layer rows and
  /// swaps the matching canvas stacking. Returns how far the row moved
  /// (positive = down), or nil at the ends / next to the music row.
  private func moveLayerTrackRow(_ row: UIView, direction: Int) -> CGFloat? {
    let rows = layerTracksStack.arrangedSubviews
    guard let index = rows.firstIndex(of: row), let layer = layerTrackRowOwners[ObjectIdentifier(row)] else { return nil }
    let target = index + direction
    guard rows.indices.contains(target), let neighborLayer = layerTrackRowOwners[ObjectIdentifier(rows[target])] else { return nil }
    let neighbor = rows[target]
    if pendingLayerReorderUndo == nil { pendingLayerReorderUndo = captureLayerOrder() }
    // Move the NEIGHBOR, never the row under the finger — taking the
    // touched view out of the stack would cancel its touch.
    layerTracksStack.removeArrangedSubview(neighbor)
    layerTracksStack.insertArrangedSubview(neighbor, at: index)
    layerTracksStack.layoutIfNeeded()
    swapInLayerBackingArray(layer, neighborLayer)
    swapLayerZOrder(layer, neighborLayer)
    UISelectionFeedbackGenerator().selectionChanged()
    // Keep the dragged row in view when there are more rows than fit —
    // the list scrolls along with it.
    let offsetBefore = layerTracksScrollView.contentOffset.y
    let rowFrame = row.convert(row.bounds, to: layerTracksScrollView).insetBy(dx: 0, dy: -4)
    let visibleTop = offsetBefore
    let visibleBottom = offsetBefore + layerTracksScrollView.bounds.height
    let maxOffset = max(0, layerTracksScrollView.contentSize.height - layerTracksScrollView.bounds.height)
    var newOffset = offsetBefore
    if rowFrame.minY < visibleTop { newOffset = rowFrame.minY }
    if rowFrame.maxY > visibleBottom { newOffset = rowFrame.maxY - layerTracksScrollView.bounds.height }
    newOffset = min(max(0, newOffset), maxOffset)
    if newOffset != offsetBefore {
      layerTracksScrollView.contentOffset.y = newOffset
    }
    // On-screen movement = movement in the stack minus the scroll.
    return CGFloat(direction) * (row.bounds.height + layerTracksStack.spacing) - (newOffset - offsetBefore)
  }

  /// Layer stacking + backing arrays, so a track reorder can be undone.
  private struct LayerOrderSnapshot {
    let zOrder: [UIView]
    let text: [EditableTextLayerView]
    let sticker: [EditableTextLayerView]
    let image: [EditableImageLayerView]
  }

  private func captureLayerOrder() -> LayerOrderSnapshot {
    LayerOrderSnapshot(zOrder: allLayerViews(), text: textLayerViews, sticker: stickerLayerViews, image: imageOverlayLayerViews)
  }

  private func applyLayerOrder(_ snapshot: LayerOrderSnapshot) {
    // Only views that still exist on the canvas — a later delete may
    // have removed some since.
    let live = Set(allLayerViews().map(ObjectIdentifier.init))
    snapshot.zOrder.filter { live.contains(ObjectIdentifier($0)) }.forEach { view.bringSubviewToFront($0) }
    keepSafeAreaCoversOnTop()
    textLayerViews = snapshot.text.filter { t in textLayerViews.contains { $0 === t } }
    stickerLayerViews = snapshot.sticker.filter { t in stickerLayerViews.contains { $0 === t } }
    imageOverlayLayerViews = snapshot.image.filter { t in imageOverlayLayerViews.contains { $0 === t } }
    refreshLayersPanel()
  }

  /// Called when a track reorder gesture ends — one undo step per drag.
  private func commitLayerReorderUndo() {
    guard let before = pendingLayerReorderUndo else { return }
    pendingLayerReorderUndo = nil
    let after = captureLayerOrder()
    guard before.zOrder.map(ObjectIdentifier.init) != after.zOrder.map(ObjectIdentifier.init) else { return }
    pushUndo(
      undo: { [weak self] in self?.applyLayerOrder(before) },
      redo: { [weak self] in self?.applyLayerOrder(after) }
    )
  }

  /// A short label for a layer's track row — its own text for a text
  /// layer, "Sticker" for a sticker (both are EditableTextLayerView,
  /// distinguished by `isStickerImageLayer` since a sticker's `.text` is
  /// cleared in favor of its image subview — see applyStickerImage), or a
  /// generic name for an image overlay (which has no text to show).
  private func layerDisplayLabel(_ layer: UIView) -> String {
    if let textLayer = layer as? EditableTextLayerView {
      if textLayer.isLocationLayer { return Self.infoStickerTitle(textLayer.infoKind) }
      if textLayer.isStickerImageLayer { return "Sticker" }
      return textLayer.text?.isEmpty == false ? textLayer.text! : "Text"
    }
    return "Overlay"
  }

  /// Called every time the set of layers, their timing, or their manual-
  /// hide state changes — clears and rebuilds layerTracksStack with at
  /// most 3 rows (Text, Stickers, Overlay — only the non-empty ones), so
  /// it's never possible for the displayed rows to drift out of sync with
  /// what's actually on the canvas. Merged video clips are NOT part of
  /// this panel — see refreshMergedClipsStrip's own doc for why they
  /// instead live directly attached to videoTrimView's own filmstrip.
  private func refreshLayersPanel() {
    layerTracksStack.arrangedSubviews.forEach {
      layerTracksStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    // KEPT duration (matches videoTrimView's own compacted total exactly
    // when merged clips exist) rather than the last segment's raw
    // upperBound — identical in the common (no split) case, but keeps
    // each row's own fixed-pixel width (see makeLayerTypeRow) at the
    // SAME pixels-per-second scale as the video row below it, per the
    // user's explicit "show layers above current video, same timeline"
    // reference. A residual, narrow-edge-case limitation: a layer timed
    // to start exactly at an internal split/delete gap (primary clip
    // only) can be a few pixels off from videoTrimView's own per-segment
    // compacted mapping — LayerRangeBarView itself still maps linearly
    // over this one combined duration, not per-segment.
    //
    // Includes merged-clip duration too (not just the primary clip's own
    // kept duration) even though layer items themselves are still timed
    // within the primary clip only — this makes each row's own width
    // (and therefore rangeBar.configure's `duration` denominator) scale
    // in lockstep with layerTracksStackWidthConstraint's full combined
    // width. Since rangeBar's own xFor/timeFor map time -> pixel as a
    // plain (time/duration)*width ratio, and BOTH duration and width now
    // grow by the exact same primaryWidth+mergedWidth factor, every
    // existing item's rendered pixel position is mathematically
    // unchanged — only the row's own trailing (empty) background now
    // extends the full way to the timeline's real end instead of
    // stopping dead at the primary clip's boundary, which is what the
    // user's "text and sticker layer is cutting when scrolling" report
    // was seeing (the row's own view — and its background paint — used
    // to physically end there, so scrolling past it revealed bare
    // background instead of a continuous, just-empty track).
    let duration = combinedLayerDuration()
    // Edits-style layers: every text/sticker/photo gets its OWN row,
    // ordered like the canvas stacking — the top row is the item drawn
    // on top. Long-press a row and drag up/down to change that order
    // (see makeLayerTypeRow's onCrossRowReorderStep wiring).
    layerTrackRowOwners.removeAll()
    for layer in allLayerViews().reversed() {
      let row = makeLayerTypeRow(for: [layer], color: layerTrackColor(for: layer), duration: duration)
      layerTrackRowOwners[ObjectIdentifier(row)] = layer
      layerTracksStack.addArrangedSubview(row)
    }
    syncLayerTrackSelection()
    // Dedicated music row — per the user's explicit "add one dedicated
    // layer of music... user can scroll and drag to change position"
    // request. Only ever 0 or 1 item, so it's built separately rather
    // than forced into the groups loop above (which assumes a
    // layerTimings-backed view list — music's timing model is
    // musicOffset/musicTrimStart/End instead).
    if selectedMusicTrack != nil {
      layerTracksStack.addArrangedSubview(makeMusicRow(duration: duration))
    }
    if voiceOverURL != nil {
      layerTracksStack.addArrangedSubview(makeVoiceRow(duration: duration))
    }
    // Every row above is a BRAND NEW LayerRangeBarView instance (the
    // teardown/rebuild at the top of this function), never yet laid out —
    // updateLayersAreaExpansion below wraps its own layoutIfNeeded() in an
    // ANIMATED block, which (since this would be that first layout pass)
    // made UIKit interpolate each new row's appearance FROM an implicit
    // zero/default starting frame, a visible pop/jump/shake on every
    // split/delete-segment/add — per the user's explicit "when I click on
    // scissor then layer is jumping and looks like shaking" report.
    // Resolving their real frames here, non-animated, BEFORE that later
    // animated pass runs means there's nothing left for it to animate.
    UIView.performWithoutAnimation {
      self.view.layoutIfNeeded()
    }
    // More rows than fit: show the scroll bar briefly so it's clear the
    // track list scrolls.
    if layerTracksStack.arrangedSubviews.count > 3 {
      layerTracksScrollView.flashScrollIndicators()
    }
    updateLayersAreaExpansion(animated: true)
  }

  @objc private func didTapToggleLayersArea() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    isLayersAreaCollapsed.toggle()
    updateLayersAreaExpansion(animated: true)
  }

  /// Drives the collapse/expand look described at isLayersAreaCollapsed's
  /// own doc. Called after every layer add/delete/reorder (refreshLayersPanel)
  /// and every tab switch (updateImageEditorUI), so it's always in sync
  /// with the current layer count and tab regardless of which changed.
  private func updateLayersAreaExpansion(animated: Bool) {
    guard mediaType != "image" else { return }
    // allLayerViews() only covers on-canvas text/sticker/overlay views —
    // music has no canvas view of its own, so a music-only selection left
    // this false and the whole layers area (including the already-built
    // music row) stayed collapsed/hidden until some OTHER layer type
    // happened to get added too. Per the user's explicit "music layer
    // should display immediately" report.
    let hasLayers = !allLayerViews().isEmpty || selectedMusicTrack != nil || voiceOverURL != nil
    // Tune / Adjust / Vignette (the .edit panel) hide the timeline — fold
    // the layer tracks (and the "Layers · N" row) away too so they don't
    // leave an empty band under the video. The user's own collapse
    // choice (isLayersAreaCollapsed) is untouched and returns afterwards.
    let toolHidesLayers = selectedImageEditorTab == .edit
    let expanded = hasLayers && !isLayersAreaCollapsed && !toolHidesLayers
    // Called after every layer add/delete/reorder (see this function's own
    // doc) — would otherwise re-show this button in story mode the moment
    // a text/sticker layer gets added, undoing updateImageEditorUI's own
    // isStoryMode hide (see showVideoControls above).
    // Hidden with the video controls (e.g. while the Music panel is open),
    // like "+ Layer" below.
    layersAreaCollapseButton.isHidden = !hasLayers || isStoryMode || filmstripScrollView.isHidden
    layersAreaCollapseButton.setImage(UIImage(systemName: expanded ? "chevron.down" : "chevron.up"), for: .normal)
    // Video redesign: a "Layers · N" pill instead of a bare chevron.
    let layerCount = allLayerViews().count + (selectedMusicTrack != nil ? 1 : 0) + (voiceOverURL != nil ? 1 : 0)
    // Collapsed: one coloured dot per layer type before the label (mockup).
    let pillTitle = NSMutableAttributedString()
    if !expanded {
      var dotColors: [UIColor] = []
      if textLayerViews.contains(where: { !$0.isHidden }) { dotColors.append(EditorDesignTokens.Colors.textLayer) }
      if stickerLayerViews.contains(where: { !$0.isHidden }) { dotColors.append(EditorDesignTokens.Colors.stickerLayer) }
      // Photos: blue, matching their tracks.
      if imageOverlayLayerViews.contains(where: { !$0.isHidden }) { dotColors.append(EditorDesignTokens.Colors.accent) }
      if selectedMusicTrack != nil { dotColors.append(EditorDesignTokens.Colors.musicLayer) }
      for color in dotColors {
        pillTitle.append(NSAttributedString(string: "●", attributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: color, .baselineOffset: 1.5]))
      }
      if !dotColors.isEmpty { pillTitle.append(NSAttributedString(string: "  ")) }
    }
    pillTitle.append(NSAttributedString(string: "Layers · \(layerCount)", attributes: [
      .font: UIFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: EditorDesignTokens.Colors.textSecondary,
    ]))
    layersAreaCollapseButton.setAttributedTitle(pillTitle, for: .normal)
    addLayerButton.isHidden = isStoryMode || filmstripScrollView.isHidden
    layersAreaCollapseButtonHeightConstraint?.constant = (hasLayers && !toolHidesLayers) ? 28 : 0
    layerTracksCollapsedConstraint?.isActive = !expanded
    let backdropChange = {
      self.videoControlsBackdropView.backgroundColor = expanded
        ? EditorDesignTokens.Colors.chromeBackground
        : .clear
    }
    if animated {
      UIView.animate(withDuration: 0.25, animations: backdropChange)
    } else {
      backdropChange()
    }
    // Per the user's explicit "if all layers are displaying then show
    // video preview in small container but if i close all layers by
    // clicking on dropdown arrow then video container should display in
    // big preview" request — the canvas shrink/grow now depends on
    // whether the layers area is actually VISIBLE (`expanded`), not just
    // whether any layers exist. canvasContentAreaGuide's own dynamic
    // bottom anchor (pinned to layersAreaCollapseButton's top) already
    // reacts to the height-constraint changes just above; this call must
    // come AFTER them (not before, as an earlier pass at this had it) so
    // the layout it resolves reflects the REAL new state, not the one
    // about to become stale. Always animates internally (see its own
    // doc), independent of this function's own `animated` flag — matches
    // this function's pre-existing behavior for the canvas resize.
    updateCanvasSizeForLayers()
    // Picking a track inside full-screen Music changes the canvas size.
    updateVideoStage(animated: animated)
  }

  /// Shrinks/grows the canvas box (video/image, already rounded via
  /// canvasClipContainerView.layer.cornerRadius) whenever the layer-
  /// tracks panel's own `hasLayers` state changes — per the user's
  /// explicit CapCut-reference "video displays in a smaller bordered
  /// container when layers exist, bigger when they don't" request. Called
  /// on every refreshLayersPanel() pass. The full/shrunk constraint SWAP
  /// itself no longer exists (there's only one constraint set now, see
  /// canvasFullSizeConstraints's own doc) — but the canvas's real size can
  /// still change purely from canvasContentAreaGuide's own dynamic bottom
  /// edge moving as the layer-tracks panel grows/shrinks (1 row vs. 3
  /// rows, or collapsing it entirely), so this still runs on every
  /// refreshLayersPanel() pass to keep every on-canvas layer's position
  /// in sync with wherever the canvas box actually ends up.
  /// rescaleForCanvasResize(by:) already no-ops internally when the ratio
  /// is exactly 1, so calling this even when nothing actually changed
  /// size is cheap.
  ///
  /// The tricky part isn't resizing the box itself — Auto Layout does
  /// that on its own once canvasContentAreaGuide's own size changes —
  /// it's that every EXISTING text/sticker/overlay layer has its own
  /// `currentTranslation`/`currentScale` (an offset + size on top of its
  /// Auto Layout anchor, which is imageView's own center — see
  /// EditableTextLayerView/EditableImageLayerView). Resizing the box
  /// alone would leave that offset/size at its OLD absolute point value,
  /// visually detached from the now-smaller (or bigger) video underneath
  /// it. Unlike Android (where layers anchor to ROOT's center, a
  /// DIFFERENT point from the canvas's own center, requiring an old-
  /// center/new-center conversion), here the anchor IS already the
  /// canvas's own center and never moves on its own (imageView fills
  /// canvasClipContainerView exactly, and canvasClipContainerView is
  /// ALWAYS centered on canvasContentAreaGuide regardless of its own
  /// size) — so fixing this is just a uniform rescale of each layer's
  /// existing translation + own scale by (newWidth / oldWidth), via
  /// rescaleForCanvasResize(by:). Deliberately includes every layer
  /// regardless of visibility (unlike allLayerViews(), which filters to
  /// visible ones) — a soft-deleted or eye-toggled-off layer that gets
  /// re-shown later must not reveal a stale, wrong-scale position from
  /// before the last resize.
  private func updateCanvasSizeForLayers() {
    // The rescale itself runs from viewDidLayoutSubviews
    // (rescaleLayersIfCanvasResized), so it happens inside this animation
    // and every layer moves/resizes in step with the canvas.
    UIView.animate(withDuration: 0.25) {
      self.view.layoutIfNeeded()
    }
  }

  /// Canvas width the layers' positions/sizes currently correspond to.
  private var lastLayerCanvasWidth: CGFloat = 0

  /// Keeps every text/sticker/photo layer (and the drawing) at the SAME
  /// spot on the video, scaled with it, whenever the canvas box changes
  /// size — e.g. it shrinks as layer tracks are added.
  ///
  /// Runs on every layout pass and compares against the width the layers
  /// were last fitted to. It used to measure the "old" width just before
  /// its own layout pass, but refreshLayersPanel had already laid the
  /// canvas out at the new size by then, so the factor was always 1 and
  /// layers kept their old point offsets on a smaller video.
  ///
  /// Uses bounds (not frame) so the Filters/Music stage transform on
  /// canvasClipContainerView is never mistaken for a resize.
  private func rescaleLayersIfCanvasResized() {
    let newWidth = canvasClipContainerView.bounds.width
    guard newWidth > 0 else { return }
    let oldWidth = lastLayerCanvasWidth
    lastLayerCanvasWidth = newWidth
    guard oldWidth > 0, abs(newWidth - oldWidth) > 0.5 else { return }
    let factor = newWidth / oldWidth
    // Every layer regardless of visibility — a soft-deleted or hidden layer
    // that comes back later must not show a stale position.
    let layers: [EditableLayerView] =
      textLayerViews.map { $0 as EditableLayerView }
      + stickerLayerViews.map { $0 as EditableLayerView }
      + imageOverlayLayerViews.map { $0 as EditableLayerView }
    // Layers are anchored at the canvas center PLUS a fixed
    // newLayerVerticalOffset. The whole offset from the center has to
    // scale, not just the translation part — scaling only the translation
    // left the fixed part unscaled, so layers drifted on every resize.
    let anchorY = Self.newLayerVerticalOffset
    for layer in layers {
      let t = layer.currentTranslation
      layer.applyInitialTransform(
        translation: CGPoint(x: t.x * factor, y: (t.y + anchorY) * factor - anchorY),
        scale: layer.currentScale * factor,
        rotation: layer.currentRotation
      )
    }
    // Draw strokes are baked point geometry inside the canvas box.
    drawingCanvasView.rescaleForCanvasResize(by: factor)
    if selectedLayer != nil { repositionLayerToolbar() }
  }

  /// One row for an entire layer TYPE (all texts, all stickers, or all
  /// overlays) — a single LayerRangeBarView drawing each layer's own
  /// segment(s) as separate colored, independently-draggable ranges
  /// within the shared bar — a layer that's been split (see
  /// splitLayerSegment) contributes MULTIPLE items, all sharing its own
  /// `id` but distinguished by `segmentIndex`. Tapping/dragging an item
  /// selects its underlying layer (see onItemSelected below) — that
  /// reuses the existing on-canvas Delete/Duplicate/Edit toolbar for
  /// delete, and this bar's own edge-drag for trim, rather than
  /// inventing separate controls for either.
  private func makeLayerTypeRow(for layers: [UIView], color: UIColor, duration: Double) -> UIView {
    let rangeBar = LayerRangeBarView()
    rangeBar.snapTargets = { [weak self] id, segment in self?.trackSnapTargets(excluding: id, segment: segment) ?? [] }
    let items: [LayerRangeBarView.Item] = layers.flatMap { layer -> [LayerRangeBarView.Item] in
      let segments = layerTimings[ObjectIdentifier(layer)]?.segments ?? [0...duration]
      let baseLabel = layerDisplayLabel(layer)
      let badge = layerTrackBadge(for: layer)
      return segments.enumerated().map { index, segment in
        LayerRangeBarView.Item(
          id: ObjectIdentifier(layer),
          rangeStart: segment.lowerBound,
          rangeEnd: segment.upperBound,
          color: color,
          // Numbered only once split — an unsplit layer's single segment
          // keeps the plain label, exactly as before.
          label: segments.count > 1 ? "\(baseLabel) \(index + 1)" : baseLabel,
          segmentIndex: index,
          badge: badge.image,
          badgeFillsTile: badge.fills,
          isDimmed: isLayerUserHidden(layer),
          statusIcons: [
            isLayerUserHidden(layer) ? Self.layerTrackSymbol("eye.slash") : nil,
            isLayerLocked(layer) ? Self.layerTrackSymbol("lock.fill") : nil,
          ].compactMap { $0 }
        )
      }
    }
    rangeBar.configure(duration: duration, items: items)
    // Locked: no trim handles and no drag-to-move on its track.
    let rowLocked = layers.count == 1 && isLayerLocked(layers[0])
    if rowLocked { rangeBar.edgeDragEnabled = false }
    rangeBar.translatesAutoresizingMaskIntoConstraints = false
    // A plain UIView with no intrinsic content size needs an explicit
    // height when it's not the sole arranged subview of a .fill-aligned
    // stack — matches Android's explicit MATCH_PARENT height for its own
    // rangeBar LayoutParams. Raised from 30 alongside layerTracksHeightCap's
    // own increase, per the user's "increase height of that view" request.
    rangeBar.heightAnchor.constraint(equalToConstant: 36).isActive = true
    // Fixed pixel width at the SAME timelinePointsPerSecond scale as
    // videoTrimView — left-aligned (layerTracksStack.alignment = .leading)
    // at the SAME x=0 as videoTrimView within the shared scrollable
    // timeline, so a layer's own timing lines up with the matching real
    // time on the video row below it. `duration` now already includes
    // merged-clip time (see refreshLayersPanel), so this row's own width
    // matches layerTracksStackWidthConstraint's full combined width
    // exactly — no separate empty-background gap to leave past its own
    // right edge any more; existing (primary-clip-only) items still land
    // at the same pixel positions since duration and width scale together.
    rangeBar.widthAnchor.constraint(equalToConstant: max(1, CGFloat(duration) * timelinePointsPerSecond)).isActive = true
    rangeBar.onRangeChanged = { [weak self] id, segmentIndex, start, end in
      guard let self, var current = self.layerTimings[id], current.segments.indices.contains(segmentIndex) else { return }
      current.segments[segmentIndex] = start...end
      self.layerTimings[id] = current
      self.updateLayerTimeVisibility()
    }
    rangeBar.onItemSelected = { [weak self] id, segmentIndex in
      guard let self, let match = layers.first(where: { ObjectIdentifier($0) == id }) as? EditableLayerView else { return }
      self.selectLayer(match, showToolbar: false)
      // Set AFTER selectLayer — selectLayer itself resets this to nil as
      // its own default (see its own doc), this overrides it with the
      // ACTUAL segment the user tapped, which is what Delete should
      // target (see deleteLayerSegment).
      self.selectedLayerSegmentIndex = segmentIndex
    }
    // Long-press + vertical drag reorders same-type layers relative to
    // each other (both their canvas z-order and this row's own overlap-
    // painting order) — per the user's explicit "provide functionality to
    // all layer to reorder... select and reorder by long press" request,
    // reintroducing reordering via a different gesture than the up/down
    // arrow buttons removed earlier this session.
    rangeBar.onReorderSwap = { [weak self] a, b in
      guard let self,
            let viewA = layers.first(where: { ObjectIdentifier($0) == a }),
            let viewB = layers.first(where: { ObjectIdentifier($0) == b })
      else { return }
      self.swapInLayerBackingArray(viewA, viewB)
      self.swapLayerZOrder(viewA, viewB)
    }
    rangeBar.onReorderEnded = { [weak self] in
      self?.commitLayerReorderUndo()
      self?.refreshLayersPanel()
    }
    // Beat sync: trimmed / moved edges land on the nearest beat.
    rangeBar.onDragEnded = { [weak self] in
      guard let self, self.beatSnapEnabled else { return }
      for layer in layers { self.snapLayerTimingToBeats(layer) }
      self.refreshLayersPanel()
    }
    // Drag a SELECTED layer's body to move it in time (length unchanged).
    // Only while unsplit — same rule as the music row.
    if layers.count == 1, !rowLocked, (layerTimings[ObjectIdentifier(layers[0])]?.segments.count ?? 1) <= 1 {
      rangeBar.allowBodyDrag = true
      rangeBar.bodyDragRequiresSelection = true
    }
    // Tap a track: if the playhead is outside that segment, jump to its
    // start so the item is actually visible on the video.
    rangeBar.onItemTapped = { [weak self] id, segmentIndex in
      guard let self, let segments = self.layerTimings[id]?.segments, segments.indices.contains(segmentIndex) else { return }
      let segment = segments[segmentIndex]
      let now = self.combinedTimeForCurrentPlayback()
      guard now < segment.lowerBound || now > segment.upperBound else { return }
      self.pauseVideoForToolInteraction()
      self.seekCombinedTimeline(to: segment.lowerBound)
      self.filmstripScrollView.setContentOffset(CGPoint(x: self.scrollOffsetX(forCombinedTime: segment.lowerBound), y: 0), animated: false)
      self.updateVideoTimeLabel(current: segment.lowerBound)
    }
    // One item per row now — reorder moves the whole row among its siblings.
    if layers.count == 1 {
      rangeBar.onCrossRowReorderStep = { [weak self, weak rangeBar] direction in
        guard let self, let rangeBar else { return nil }
        return self.moveLayerTrackRow(rangeBar, direction: direction)
      }
    }
    // Per the user's explicit "if I am touching on layers the all layers
    // should not move" report — this row's own edge-drag touches happen
    // INSIDE layerTracksScrollView, but only videoTrimView/mergedStripView
    // (see their own identical wiring) ever disabled the ancestor scroll
    // views during a handle drag; Text/Sticker/Overlay rows never did.
    // With layerTracksScrollView left scroll-enabled, its own native pan
    // gesture recognizer could activate AT THE SAME TIME as this row's raw
    // touch handling, scrolling the whole shared timeline (every row,
    // mirrored into filmstripScrollView too) out from under the user while
    // they were only trying to drag one layer's own edge handle. Disabling
    // BOTH mirrored scroll views for the drag's duration — not just
    // layerTracksScrollView — keeps them from drifting apart in the
    // process.
    rangeBar.onHandleDragStateChanged = { [weak self] isDragging in
      self?.layerTracksScrollView.isScrollEnabled = !isDragging
      self?.filmstripScrollView.isScrollEnabled = !isDragging
    }
    return rangeBar
  }

  /// Reorder support (see makeLayerTypeRow's own doc) — the two views
  /// that just swapped positions during a long-press drag are always from
  /// the SAME type array (a row only ever contains one type), so trying
  /// each in turn and returning as soon as both are found is enough.
  private func swapInLayerBackingArray(_ a: UIView, _ b: UIView) {
    func trySwap<T: UIView>(_ list: inout [T]) -> Bool {
      guard let idxA = list.firstIndex(where: { $0 === a }), let idxB = list.firstIndex(where: { $0 === b }) else { return false }
      list.swapAt(idxA, idxB)
      return true
    }
    if trySwap(&textLayerViews) { return }
    if trySwap(&stickerLayerViews) { return }
    _ = trySwap(&imageOverlayLayerViews)
  }

  /// Swaps ONLY these two layers' relative canvas z-order, leaving every
  /// other layer's relative order exactly as it was — derives the CURRENT
  /// true combined order from allLayerViews() (view's own actual subview
  /// order, spanning all types) rather than assuming a fixed type-
  /// priority stacking, then re-applies it via the same
  /// bringSubviewToFront()-in-sequence + keepSafeAreaCoversOnTop() pattern
  /// already used elsewhere in this file for reasserting z-order safely.
  private func swapLayerZOrder(_ a: UIView, _ b: UIView) {
    var order = allLayerViews()
    guard let idxA = order.firstIndex(where: { $0 === a }), let idxB = order.firstIndex(where: { $0 === b }) else { return }
    order[idxA] = b
    order[idxB] = a
    order.forEach { view.bringSubviewToFront($0) }
    keepSafeAreaCoversOnTop()
  }

  /// The music row — see musicOffset's own doc. No reorder wiring
  /// (nothing to reorder against with only one id). Supports BOTH body-
  /// drag (reposition where the track starts on the timeline, only while
  /// unsplit — see allowBodyDrag below) and edge-drag (trim each
  /// segment's own start/end), same as every other layer row — per the
  /// user's explicit "same leading/trailing drag handles on music too"
  /// request. The two never conflict: LayerRangeBarView's own hit-testing
  /// already checks the edge zones before falling through to body-drag
  /// for the middle region.
  /// Segment-based, mirroring makeLayerTypeRow's own per-segment Item
  /// list — per the user's explicit "same split music layer also"
  /// request. Only ever ONE underlying id (musicProxyToken, music has no
  /// per-instance views like text/sticker do), but that id can now
  /// contribute MULTIPLE items once split, exactly like a layer's own
  /// segments.
  private func makeMusicRow(duration: Double) -> UIView {
    let rangeBar = LayerRangeBarView()
    rangeBar.snapTargets = { [weak self] id, segment in self?.trackSnapTargets(excluding: id, segment: segment) ?? [] }
    let minKeptDuration = 0.5
    let fallback = [musicOffset...(musicOffset + max(musicTrimEnd - musicTrimStart, minKeptDuration))]
    let segments = musicSegments.isEmpty ? fallback : musicSegments
    // Body-drag (reposition the WHOLE track) only stays meaningful before
    // any split exists — once there are multiple pieces, dragging one
    // segment's body is ambiguous with scrolling the shared timeline,
    // same reasoning that already removed body-drag from text/sticker/
    // overlay rows entirely.
    rangeBar.allowBodyDrag = segments.count <= 1
    rangeBar.edgeDragEnabled = true
    let baseLabel = selectedMusicTrack?.title ?? "Music"
    let items: [LayerRangeBarView.Item] = segments.enumerated().map { index, segment in
      LayerRangeBarView.Item(
        id: ObjectIdentifier(musicProxyToken),
        rangeStart: segment.lowerBound,
        rangeEnd: segment.upperBound,
        color: EditorDesignTokens.Colors.musicLayer,
        // Numbered only once split — an unsplit track keeps the plain
        // label, exactly as before.
        label: segments.count > 1 ? "\(baseLabel) \(index + 1)" : baseLabel,
        segmentIndex: index,
        badge: Self.layerTrackSymbol("music.note"),
        markers: combinedBeatTimes()
      )
    }
    rangeBar.configure(duration: duration, items: items)
    rangeBar.translatesAutoresizingMaskIntoConstraints = false
    rangeBar.heightAnchor.constraint(equalToConstant: 36).isActive = true
    rangeBar.widthAnchor.constraint(equalToConstant: max(1, CGFloat(duration) * timelinePointsPerSecond)).isActive = true
    rangeBar.onRangeChanged = { [weak self] _, segmentIndex, newStart, newEnd in
      guard let self, self.musicSegments.indices.contains(segmentIndex) else { return }
      self.musicSegments[segmentIndex] = newStart...newEnd
      // segments[0]'s own start IS musicOffset — several other call sites
      // (export, updateMusicPlaybackWindow) still read it directly.
      if segmentIndex == 0 { self.musicOffset = newStart }
      self.updateMusicPlaybackWindow()
    }
    rangeBar.onItemSelected = { [weak self] _, segmentIndex in
      guard let self else { return }
      // Music becomes the Split/Delete target — clear every other
      // selection so they can't both claim the next scissors/trash tap,
      // mirroring mergedStripView.onItemSelected's identical clearing.
      self.deselectLayer()
      self.selectedMergedClipURL = nil
      self.selectedMergedClipSegmentIndex = nil
      self.videoTrimView.clearSegmentSelection()
      self.selectedMusicSegmentIndex = segmentIndex
    }
    // Same fix as makeLayerTypeRow's identical wiring — this row's own
    // body-drag (allowBodyDrag) must not let the ancestor scroll views
    // scroll out from under it mid-drag either.
    rangeBar.onHandleDragStateChanged = { [weak self] isDragging in
      self?.layerTracksScrollView.isScrollEnabled = !isDragging
      self?.filmstripScrollView.isScrollEnabled = !isDragging
    }
    // Music never sets onReorderSwap (every segment shares the SAME id —
    // there's nothing to reorder against), so reordering is disabled;
    // long-press still selects the tapped segment (see
    // LayerRangeBarView.beginReorder's own doc) exactly like every other
    // row. Removing the whole track happens via deleteMusicSegment once
    // only one segment is left, not directly from long-press.
    rangeBar.reorderEnabled = false
    return rangeBar
  }

  /// Hides/shows every layer based on whether the current playhead falls
  /// within its own time range (combined with its manual eye-toggle
  /// state) — called from the video preview's periodic time observer, and
  /// immediately after any range/order/visibility change so there's never
  /// a stale frame waiting for the next 0.25s tick. Uses `.alpha`, not
  /// `.isHidden` — that flag already means "deleted" (see deleteLayer),
  /// and reusing it here would make the two states indistinguishable.
  private func updateLayerTimeVisibility() {
    // combinedTimeForCurrentPlayback(), not the primary player's own raw
    // local time — see combinedLayerDuration's own doc for why: layers
    // now extend across merged clips too, and the primary player's local
    // time resets to 0 once the queue advances past it, which would make
    // every layer's range comparison meaningless during merged-clip
    // playback.
    let currentTime = combinedTimeForCurrentPlayback()
    for layer in allLayerViews() {
      guard let timing = layerTimings[ObjectIdentifier(layer)] else { continue }
      let inRange = timing.segments.contains { $0.contains(currentTime) }
      var targetAlpha: CGFloat = (inRange && !timing.isManuallyHidden) ? 1 : 0
      // Text animations: fade / pop / typewriter / slide at each piece's
      // start and end (same math as the export).
      if let textLayer = layer as? EditableTextLayerView, !textLayer.isStickerImageLayer {
        let anim = TextAnimation.state(at: currentTime, segments: timing.segments, config: timing.anim)
        targetAlpha *= anim.alpha
        textLayer.setAnimationState(anim, canvasSize: canvasClipContainerView.bounds.size)
      }
      // Skip the redundant layout/redraw when nothing actually changed —
      // now called every ~1/60s (was 0.25s, see the time observer's own
      // interval doc), so avoiding needless per-frame work here matters
      // more than it used to.
      if layer.alpha != targetAlpha { layer.alpha = targetAlpha }
    }
  }

  /// Starts/pauses the music player as playback crosses any of the music
  /// row's own `musicSegments` windows on the combined timeline — per the
  /// user's explicit music-as-a-layer request, the track no longer just
  /// always starts at time 0, and (per the later "same split music layer
  /// also" request) can now have multiple such windows with gaps between
  /// them. Only manages the TRANSITION edges (start on entry, pause on
  /// exit) rather than continuously re-syncing every tick — matches the
  /// existing lightweight preview-only rigor already used for music
  /// elsewhere in this file (no frame-accurate re-seek loop). The SOURCE
  /// file position is always anchored to segments[0]'s own start (NOT
  /// whichever segment is currently active), so the song's own internal
  /// pacing stays continuous straight through a gap — entering a LATER
  /// segment resumes wherever the song would already be, rather than
  /// restarting from that segment's own beginning.
  private func updateMusicPlaybackWindow() {
    guard let musicPlayer, selectedMusicTrack != nil else { return }
    if isStoryMusicPausedByUser {
      if musicPlayer.rate != 0 { musicPlayer.pause() }
      return
    }
    guard musicTrimEnd > musicTrimStart, let anchor = musicSegments.first?.lowerBound else { return }
    let combined = combinedTimeForCurrentPlayback()
    let inWindow = musicSegments.contains { $0.contains(combined) }
    // `rate`, not timeControlStatus: right after a seek the player is
    // still loading (.waitingToPlayAtSpecifiedRate), and treating that as
    // "not playing" re-seeked it every tick, so a later piece of split
    // music never started.
    if isVideoPlaying && inWindow {
      if musicPlayer.rate == 0 {
        musicPlayer.seek(to: CMTime(seconds: musicTrimStart + (combined - anchor), preferredTimescale: 600))
        musicPlayer.play()
      }
    } else if musicPlayer.rate != 0 {
      musicPlayer.pause()
    }
  }

  /// Called every time video playback loops back to its own start (single-
  /// clip gap-skip restart, multi-clip queue rebuild-and-replay) — per the
  /// user's explicit "as video start playing in loop again then the music
  /// should be reset and start again, should not be play continuously"
  /// request. Without this, the music player just runs on its own
  /// continuous clock once started (updateMusicPlaybackWindow above only
  /// manages START/STOP transitions, never re-syncs mid-flight), so across
  /// a video loop it would keep advancing toward ITS OWN natural end
  /// instead of restarting alongside the video.
  private func resetMusicToLoopStart() {
    guard let musicPlayer, selectedMusicTrack != nil else { return }
    musicPlayer.pause()
    musicPlayer.seek(to: CMTime(seconds: musicTrimStart, preferredTimescale: 600))
    // Reuses the normal entry/exit decision (is time-0 actually inside a
    // music segment?) rather than assuming it should always resume — same
    // call the per-tick observer already makes.
    updateMusicPlaybackWindow()
  }

  // MARK: - Layer selection + on-canvas action toolbar (Delete/Duplicate/Edit)

  /// Wires the 3 callbacks every text/sticker layer needs, regardless of
  /// how it was created (addTextLayer, addStickerLayer, or duplicated) —
  /// kept in one place so all 3 call sites can't drift out of sync.
  private func wireLayerCallbacks(_ label: EditableLayerView) {
    // Weak `label` everywhere: these closures are stored ON the label, so a
    // strong capture made each layer retain itself (leaked after closing).
    label.onLongPress = { [weak self, weak label] in
      guard let label else { return }
      self?.confirmDeleteLayer(label)
    }
    label.onTap = { [weak self, weak label] in
      guard let label else { return }
      // Location stickers cycle their style on every tap (Instagram-style),
      // in addition to the normal select.
      if let locationLayer = label as? EditableTextLayerView, locationLayer.isLocationLayer {
        self?.cycleLocationStyle(locationLayer)
      }
      if self?.selectedLayer !== label { UISelectionFeedbackGenerator().selectionChanged() }
      self?.selectLayer(label)
    }
    // No toolbar work while dragging: the Delete / Duplicate / Edit bar sits
    // at a fixed spot above the tools, so re-fitting it on every transform
    // frame (a full Auto Layout pass) only cost smoothness.
    // Story: the selected sticker's ✕ follows it (a cheap frame move).
    label.onTransformChanged = isStoryMode ? { [weak self, weak label] in
      guard let self, let label, (label as UIView) === (self.selectedLayer as UIView?) else { return }
      self.updateStickerDeleteBadge()
    } : nil
    // Tracks this layer's OWN pan/pinch/rotate (active only while it's
    // NOT selected — see setOwnTransformGesturesEnabled) for undo/redo,
    // same as handleSharedLayerPan/Pinch/Rotation does for the selected-
    // layer path below.
    label.onOwnGestureStateChanged = { [weak self, weak label] gesture in
      guard let label else { return }
      self?.trackTransformGesture(gesture, for: label)
    }
    // canvasClipContainerView's frame is fixed once laid out (this
    // codebase's own "canvas box sized once, never resizes" rule) — a
    // closure rather than a captured value purely for consistency/no extra
    // cost, not because it's expected to change. Per the user's explicit
    // request: nothing added on top of the photo should be
    // draggable/resizable past its edges.
    //
    // MUST be canvasClipContainerView's frame, NOT imageView's: this text/
    // sticker/overlay layer is a direct child of `view` (same as before),
    // so its own `.center` is expressed in `view`'s coordinate space —
    // but imageView is now nested INSIDE canvasClipContainerView, so
    // `imageView.frame` is expressed in the CONTAINER's space instead,
    // which would silently mismatch here (the exact same category of
    // coordinate-space bug already found once in this file — see
    // renderExport's canvasCenter comment). canvasClipContainerView is
    // still a direct child of `view`, so its `.frame` stays in the right
    // space and is numerically identical to what imageView.frame used to
    // return before it was nested.
    label.boundsProvider = { [weak self] in self?.canvasClipContainerView.frame ?? .zero }
    label.onSnapChanged = { [weak self] state in self?.showSnapGuides(state) }
  }

  /// Replaces a UISlider's own flat, default thin track + plain round
  /// thumb with a thicker pill-shaped track and a bigger white thumb with
  /// an accent-colored ring + soft drop shadow — per the user's explicit
  /// "these slider is looking very simple, improve UI of these" report.
  /// Shared by musicVolumeSlider/originalAudioVolumeSlider so both read as
  /// one consistent, more premium control instead of the system default.
  private func styleVolumeSlider(_ slider: UISlider) {
    slider.minimumTrackTintColor = EditorDesignTokens.Colors.accent
    slider.maximumTrackTintColor = EditorDesignTokens.Colors.divider

    let trackHeight: CGFloat = 8
    let trackImage = UIGraphicsImageRenderer(size: CGSize(width: trackHeight, height: trackHeight)).image { _ in
      UIColor.white.setFill()
      UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: trackHeight, height: trackHeight), cornerRadius: trackHeight / 2).fill()
    }.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: trackHeight / 2, bottom: 0, right: trackHeight / 2))
    slider.setMinimumTrackImage(trackImage, for: .normal)
    slider.setMaximumTrackImage(trackImage, for: .normal)

    let thumbDiameter: CGFloat = 26
    let ringWidth: CGFloat = 2
    let shadowPadding: CGFloat = 3
    let canvasSize = CGSize(width: thumbDiameter + shadowPadding * 2, height: thumbDiameter + shadowPadding * 2)
    let thumbImage = UIGraphicsImageRenderer(size: canvasSize).image { context in
      let circleRect = CGRect(x: shadowPadding, y: shadowPadding, width: thumbDiameter, height: thumbDiameter)
      let path = UIBezierPath(ovalIn: circleRect)
      context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.35).cgColor)
      UIColor.white.setFill()
      path.fill()
      // Reset the shadow before stroking the ring — otherwise the stroke
      // casts its own (doubled, blurrier-looking) shadow on top.
      context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
      EditorDesignTokens.Colors.accent.setStroke()
      path.lineWidth = ringWidth
      path.stroke()
    }
    slider.setThumbImage(thumbImage, for: .normal)
    slider.setThumbImage(thumbImage, for: .highlighted)
  }

  /// The canvas no longer gets a yellow border (removed per the user's
  /// request); only a tapped layer shows its white selection border.
  private func updateCanvasSelectionBorder() {
    canvasClipContainerView.layer.borderWidth = 0
  }

  /// `showToolbar: false` — selected from its timeline track: highlight it
  /// (canvas border, track, split/delete target) without the floating
  /// Delete/Duplicate/Edit/Style toolbar, which only appears when the
  /// element itself is tapped on the video (user's request).
  private func selectLayer(_ layer: EditableLayerView, showToolbar: Bool = true) {
    // Another layer picked while the Animation sheet is open: finish
    // (keep) that edit first — the sheet belongs to the previous layer.
    if let sheet = textAnimationSheet, (layer as UIView) !== (selectedLayer as UIView?) { sheet.onClose?(true) }
    // Re-enable the PREVIOUS selection's own gestures first, in case
    // selection switches directly from one layer to another without going
    // through deselectLayer in between (e.g. tapping a different layer
    // while one is already selected).
    if let previous = selectedLayer { setOwnGestures(previous, enabled: true) }
    // Per the user's explicit "show white color border to each layer when
    // touch... user should get to know on which layer we tapped" request
    // — clear the PREVIOUS selection's white border (if switching directly
    // from one layer to another) before giving the new one its own.
    selectedLayer?.layer.borderWidth = 0
    selectedLayer = layer
    // Thin (was 2) — the selected layer's border read too heavy.
    layer.layer.borderWidth = 1
    layer.layer.borderColor = UIColor.white.cgColor
    // The main video/image canvas keeps its own yellow border ONLY while
    // no overlay layer is selected — so exactly one thing on screen ever
    // reads as "the current tap target" at a time.
    updateCanvasSelectionBorder()
    // Reset here, not just in deselectLayer — this function is ALSO the
    // direct-switch path ("tapping a different layer while one is
    // already selected", per the comment above), which never calls
    // deselectLayer at all. makeLayerTypeRow's onItemSelected sets this
    // to the ACTUAL tapped segment right after calling selectLayer, so
    // this default only sticks when selection came from somewhere else
    // (a canvas tap, duplicate, etc.).
    selectedLayerSegmentIndex = nil
    // A layer is now the delete target — clear any stale white
    // selected-segment border still showing on the video's own row or a
    // merged clip's own row.
    videoTrimView.clearSegmentSelection()
    selectedMergedClipURL = nil
    selectedMergedClipSegmentIndex = nil
    selectedMusicSegmentIndex = nil
    layer.setOwnTransformGesturesEnabled(false)
    setCanvasTransformGesturesEnabled(false)
    sharedLayerPanGesture.isEnabled = true
    sharedLayerPinchGesture.isEnabled = true
    sharedLayerRotationGesture.isEnabled = true
    // Locked (or hidden) layer: selectable so it can be unlocked, but it
    // can't be moved and gets no Delete/Duplicate/Edit toolbar.
    let interactionBlocked = isLayerLocked(layer) || isLayerUserHidden(layer)
    if interactionBlocked {
      sharedLayerPanGesture.isEnabled = false
      sharedLayerPinchGesture.isEnabled = false
      sharedLayerRotationGesture.isEnabled = false
    }
    if showToolbar && isLayerLocked(layer) {
      layerActionToolbar?.removeFromSuperview()
      layerActionToolbar = nil
      showEditorToast("Layer is locked")
    } else if showToolbar && !interactionBlocked {
      showLayerActionToolbar(for: layer)
    } else {
      layerActionToolbar?.removeFromSuperview()
      layerActionToolbar = nil
    }
    updateStickerDeleteBadge()
  }

  private func deselectLayer() {
    textAnimationSheet?.onClose?(true)
    if selectedImageEditorTab == .textStyle {
      selectedImageEditorTab = .tools
      updateImageEditorUI(animated: true)
    }
    if let previous = selectedLayer { setOwnGestures(previous, enabled: true) }
    selectedLayer?.layer.borderWidth = 0
    selectedLayer = nil
    selectedLayerSegmentIndex = nil
    updateCanvasSelectionBorder()
    setCanvasTransformGesturesEnabled(true)
    sharedLayerPanGesture.isEnabled = false
    sharedLayerPinchGesture.isEnabled = false
    sharedLayerRotationGesture.isEnabled = false
    layerActionToolbar?.removeFromSuperview()
    layerActionToolbar = nil
    updateStickerDeleteBadge()
  }

  // MARK: Story sticker ✕

  private var stickerDeleteBadge: UIButton?

  /// Story mode: a small ✕ on the selected sticker's top-left corner that
  /// removes it (undoable). Follows the sticker while it's dragged,
  /// pinched or rotated; hidden while a tool panel shows the picture as a
  /// snapshot, and for locked/hidden layers. Same as Android.
  private func updateStickerDeleteBadge() {
    guard
      isStoryMode,
      !isFilterStageActive,
      let layer = selectedLayer as? EditableTextLayerView,
      stickerLayerViews.contains(where: { $0 === layer }),
      !layer.isHidden,
      !isLayerLocked(layer),
      !isLayerUserHidden(layer),
      layer.bounds.width > 0
    else {
      stickerDeleteBadge?.isHidden = true
      return
    }
    let size: CGFloat = 26
    let badge: UIButton
    if let existing = stickerDeleteBadge {
      badge = existing
    } else {
      badge = UIButton(type: .custom)
      badge.frame = CGRect(x: 0, y: 0, width: size, height: size)
      badge.backgroundColor = UIColor.black.withAlphaComponent(0.78)
      badge.layer.cornerRadius = size / 2
      badge.layer.borderWidth = 1.5
      badge.layer.borderColor = UIColor.white.cgColor
      badge.setImage(
        UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)),
        for: .normal
      )
      badge.tintColor = .white
      badge.accessibilityLabel = "Remove sticker"
      badge.addTarget(self, action: #selector(didTapStickerDeleteBadge), for: .touchUpInside)
      view.addSubview(badge)
      stickerDeleteBadge = badge
    }
    // The sticker's own top-left corner, through its move/scale/rotate.
    badge.center = layer.convert(CGPoint.zero, to: view)
    if badge.isHidden || badge.superview?.subviews.last !== badge {
      badge.isHidden = false
      view.bringSubviewToFront(badge)
      // Chrome (rail, top buttons, music badge) stays above the badge.
      storyChromeViews.forEach { view.bringSubviewToFront($0) }
    }
  }

  @objc private func didTapStickerDeleteBadge() {
    didTapDeleteSelectedLayer()
  }

  /// Plain text labels, not icons — per the user's explicit request (the
  /// hand-drawn-style icon set read as too custom/odd for a 3-item action
  /// row). "Delete" is tinted systemRed, matching the destructive-style
  /// tint `confirmDeleteLayer`'s own alert action already uses.
  private static func makeLayerToolbarTextButton(title: String, isDestructive: Bool = false) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 14, weight: .regular)
    button.tintColor = isDestructive ? .systemRed : EditorDesignTokens.Colors.textPrimary
    button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    return button
  }

  private static func makeLayerToolbarDivider() -> UIView {
    let divider = UIView()
    divider.backgroundColor = EditorDesignTokens.Colors.divider
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
    return divider
  }

  private func showLayerActionToolbar(for layer: EditableLayerView) {
    layerActionToolbar?.removeFromSuperview()

    let deleteButton = MediaEditorViewController.makeLayerToolbarTextButton(title: "Delete", isDestructive: true)
    deleteButton.addAction(UIAction { [weak self] _ in self?.didTapDeleteSelectedLayer() }, for: .touchUpInside)
    let duplicateButton = MediaEditorViewController.makeLayerToolbarTextButton(title: "Duplicate")
    duplicateButton.addAction(UIAction { [weak self] _ in self?.didTapDuplicateSelectedLayer() }, for: .touchUpInside)
    let editButton = MediaEditorViewController.makeLayerToolbarTextButton(title: "Edit")
    editButton.addAction(UIAction { [weak self] _ in self?.didTapEditSelectedLayer() }, for: .touchUpInside)

    var buttons: [UIView] = [
      deleteButton,
      MediaEditorViewController.makeLayerToolbarDivider(),
      duplicateButton,
      MediaEditorViewController.makeLayerToolbarDivider(),
      editButton,
    ]
    if styleSnapshot(of: layer as UIView) != nil {
      let styleButton = MediaEditorViewController.makeLayerToolbarTextButton(title: "Style")
      styleButton.addAction(UIAction { [weak self] _ in self?.didTapStyleSelectedLayer() }, for: .touchUpInside)
      buttons += [MediaEditorViewController.makeLayerToolbarDivider(), styleButton]
    }
    // Story videos have no layer tracks — text animations are picked here
    // (In plays as the story starts, Out as it ends, every loop). Not for
    // photo stories: they export as a single still image.
    if isStoryMode, mediaType != "image", let text = layer as? EditableTextLayerView, !text.isStickerImageLayer {
      let animateButton = MediaEditorViewController.makeLayerToolbarTextButton(title: "Animate")
      animateButton.addAction(UIAction { [weak self] _ in self?.didTapTextAnimation() }, for: .touchUpInside)
      buttons += [MediaEditorViewController.makeLayerToolbarDivider(), animateButton]
    }
    let stack = UIStackView(arrangedSubviews: buttons)
    stack.axis = .horizontal
    stack.alignment = .fill
    stack.backgroundColor = EditorDesignTokens.Colors.panelBackground
    stack.layer.cornerRadius = 20
    stack.clipsToBounds = true
    view.addSubview(stack)
    layerActionToolbar = stack
    repositionLayerToolbar()
    keepSafeAreaCoversOnTop()
  }

  /// The layer action bar always sits in one fixed place — centred just
  /// above the bottom editing tools — never over the layer or anywhere
  /// else, per the user's request. While a panel is open it's hidden
  /// rather than moved. Same on Android.
  private func repositionLayerToolbar() {
    guard selectedLayer != nil, let toolbar = layerActionToolbar else { return }
    // A UIStackView positioned by frame — systemLayoutSizeFitting (not
    // sizeToFit) gives its real arranged-content size.
    let fittingSize = toolbar.systemLayoutSizeFitting(
      UIView.layoutFittingCompressedSize,
      withHorizontalFittingPriority: .fittingSizeLevel,
      verticalFittingPriority: .fittingSizeLevel
    )
    toolbar.bounds = CGRect(origin: .zero, size: fittingSize)
    let gap: CGFloat = 10
    toolbar.center = CGPoint(x: view.bounds.midX, y: layerToolbarBottomY() - fittingSize.height / 2 - gap)
    toolbar.isHidden = selectedImageEditorTab != .tools
  }

  /// Top edge of the bottom editing tools (story mode has none: the
  /// screen's safe bottom).
  private func layerToolbarBottomY() -> CGFloat {
    if isStoryMode || bottomTrayCardView.isHidden || bottomTrayCardView.superview == nil {
      return view.bounds.height - view.safeAreaInsets.bottom - 8
    }
    return bottomTrayCardView.convert(bottomTrayCardView.bounds, to: view).minY
  }

  private func didTapDeleteSelectedLayer() {
    guard let layer = selectedLayer else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    deselectLayer()
    deleteLayer(layer)
  }

  private func didTapDuplicateSelectedLayer() {
    guard let source = selectedLayer, canAddLayer() else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if let textSource = source as? EditableTextLayerView {
      duplicateTextOrStickerLayer(textSource)
    } else if let imageSource = source as? EditableImageLayerView {
      duplicateImageOverlayLayer(imageSource)
    }
  }

  private func duplicateTextOrStickerLayer(_ source: EditableTextLayerView) {
    let isSticker = stickerLayerViews.contains(where: { $0 === source })
    let clone = EditableTextLayerView()
    if let locationName = source.locationName {
      clone.infoKind = source.infoKind
      clone.infoValue = source.infoValue
      applyLocationSticker(to: clone, name: locationName, style: source.locationStyle)
      clone.locationLatitude = source.locationLatitude
      clone.locationLongitude = source.locationLongitude
    } else if let assetName = source.stickerAssetName, let image = StickerCatalog.image(named: assetName) {
      clone.applyStickerImage(image, assetName: assetName)
      clone.applyStickerStyle(source.stickerStyle)
    } else {
      clone.applyText(source.text ?? "", style: source.layerStyle ?? TextLayerStyle())
    }
    clone.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(clone)
    NSLayoutConstraint.activate([
      clone.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      // Must match addTextLayer/addStickerLayer's base anchor exactly
      // (same -60 constant) — `currentTranslation` below is an offset
      // relative to THIS anchor, so a mismatched base would visually
      // shift the clone away from the source by the difference.
      clone.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: Self.newLayerVerticalOffset),
    ])
    clone.enableGestures(in: view)
    wireLayerCallbacks(clone)
    clone.applyInitialTransform(
      translation: CGPoint(x: source.currentTranslation.x + 20, y: source.currentTranslation.y + 20),
      scale: source.currentScale,
      rotation: source.currentRotation
    )
    if isSticker {
      stickerLayerViews.append(clone)
    } else {
      textLayerViews.append(clone)
    }
    // A clone starts with the SAME time range as its source, not a fresh
    // full-duration default — reads as "a copy of that element," not a
    // brand-new one.
    if var sourceTiming = layerTimings[ObjectIdentifier(source)] {
      // A copy starts visible and unlocked.
      sourceTiming.isManuallyHidden = false
      sourceTiming.isLocked = false
      layerTimings[ObjectIdentifier(clone)] = sourceTiming
      refreshLayersPanel()
    } else {
      registerLayerTiming(clone)
    }
    selectLayer(clone)
    keepSafeAreaCoversOnTop()
    pushUndo(
      undo: { [weak self] in
        clone.isHidden = true
        clone.isUserInteractionEnabled = false
        if self?.selectedLayer === clone { self?.deselectLayer() }
      },
      redo: { clone.isHidden = false; clone.isUserInteractionEnabled = true }
    )
  }

  private func duplicateImageOverlayLayer(_ source: EditableImageLayerView) {
    let clone = EditableImageLayerView()
    if let base = source.baseImage {
      clone.applyOverlay(base: base, style: source.overlayStyle, strokes: source.eraseStrokes)
    } else {
      clone.image = source.image
    }
    clone.sourceImage = source.sourceImage
    clone.contentMode = .scaleAspectFit
    clone.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(clone)
    NSLayoutConstraint.activate([
      clone.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      clone.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: Self.newLayerVerticalOffset),
      clone.widthAnchor.constraint(equalTo: source.widthAnchor),
      clone.heightAnchor.constraint(equalTo: source.heightAnchor),
    ])
    clone.enableGestures(in: view)
    wireLayerCallbacks(clone)
    clone.applyInitialTransform(
      translation: CGPoint(x: source.currentTranslation.x + 20, y: source.currentTranslation.y + 20),
      scale: source.currentScale,
      rotation: source.currentRotation
    )
    imageOverlayLayerViews.append(clone)
    // Same "clone starts with the source's own time range" rule as
    // duplicateTextOrStickerLayer.
    if var sourceTiming = layerTimings[ObjectIdentifier(source)] {
      // A copy starts visible and unlocked.
      sourceTiming.isManuallyHidden = false
      sourceTiming.isLocked = false
      layerTimings[ObjectIdentifier(clone)] = sourceTiming
      refreshLayersPanel()
    } else {
      registerLayerTiming(clone)
    }
    selectLayer(clone)
    keepSafeAreaCoversOnTop()
    pushUndo(
      undo: { [weak self] in
        clone.isHidden = true
        clone.isUserInteractionEnabled = false
        if self?.selectedLayer === clone { self?.deselectLayer() }
      },
      redo: { clone.isHidden = false; clone.isUserInteractionEnabled = true }
    )
  }

  private func didTapEditSelectedLayer() {
    guard let layer = selectedLayer else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if let textLayer = layer as? EditableTextLayerView {
      if textLayer.isLocationLayer, textLayer.infoKind != "location" {
        presentInfoStickerEditor(kind: textLayer.infoKind, editing: textLayer)
      } else if textLayer.isLocationLayer {
        presentLocationPicker(editing: textLayer)
      } else if stickerLayerViews.contains(where: { $0 === textLayer }) {
        presentStickerPickerForEdit(textLayer)
      } else {
        presentTextEntryOverlayInternal(editing: textLayer)
      }
    } else if let imageLayer = layer as? EditableImageLayerView {
      presentImageOverlayPickerForEdit(imageLayer)
    }
  }

  /// Reopens the same image-grid Stickers panel used for adding one,
  /// rather than a standalone picker — `editingStickerLayer` (checked by
  /// `didTapStickerGridItem`) makes the next tap replace this layer's
  /// image instead of adding a new layer. Replaces the old action-sheet
  /// (which listed emoji glyphs as text) now that stickers are images.
  private func presentStickerPickerForEdit(_ label: EditableTextLayerView) {
    editingStickerLayer = label
    sizeStickersPanelOverToolRail()
    selectedImageEditorTab = .stickers
    updateImageEditorUI(animated: true)
  }

  private func updateStickerLayer(_ label: EditableTextLayerView, assetName: String) {
    guard let image = StickerCatalog.image(named: assetName) else { return }
    let oldAssetName = label.stickerAssetName
    let oldImage = oldAssetName.flatMap { StickerCatalog.image(named: $0) }
    label.applyStickerImage(image, assetName: assetName)
    if selectedLayer === label { repositionLayerToolbar() }
    pushUndo(
      undo: {
        guard let oldImage, let oldAssetName else { return }
        label.applyStickerImage(oldImage, assetName: oldAssetName)
      },
      redo: { label.applyStickerImage(image, assetName: assetName) }
    )
  }

  private func updateTextLayer(_ label: EditableTextLayerView, text: String, style: TextLayerStyle) {
    let oldText = label.text ?? ""
    let oldStyle = label.layerStyle ?? TextLayerStyle()
    label.applyText(text, style: style)
    refreshAfterTextLayerChange(label)
    pushUndo(
      undo: { [weak self] in
        label.applyText(oldText, style: oldStyle)
        self?.refreshAfterTextLayerChange(label)
      },
      redo: { [weak self] in
        label.applyText(text, style: style)
        self?.refreshAfterTextLayerChange(label)
      }
    )
  }

  /// A style change resizes the layer — lay it out now so its toolbar and
  /// the filter/style stage snapshot use the new size.
  private func refreshAfterTextLayerChange(_ label: UIView) {
    view.layoutIfNeeded()
    // Draw the new look now, so the stage snapshot below doesn't capture
    // the previous one.
    label.layer.displayIfNeeded()
    if selectedLayer === label { repositionLayerToolbar() }
    scheduleFilterStageRefresh()
  }

  // MARK: - Style panel (text layers, stickers and overlays)

  private struct TextStyleSliderSpec {
    let title: String
    let range: ClosedRange<Float>
    let defaultValue: Float
    let get: () -> Float
    let set: (Float) -> Void
  }

  private func styleSnapshot(of view: UIView) -> LayerStyleSnapshot? {
    if let overlay = view as? EditableImageLayerView, overlay.baseImage != nil {
      return .overlay(overlay.overlayStyle, overlay.eraseStrokes)
    }
    guard let label = view as? EditableTextLayerView else { return nil }
    if let style = label.layerStyle { return .text(style) }
    if label.canStyleSticker { return .sticker(label.stickerStyle) }
    return nil
  }

  private func applyStyleSnapshot(_ snapshot: LayerStyleSnapshot, to view: UIView) {
    switch snapshot {
    case let .text(style): (view as? EditableTextLayerView).map { $0.applyText($0.text ?? "", style: style) }
    case let .sticker(style): (view as? EditableTextLayerView)?.applyStickerStyle(style)
    case let .overlay(style, strokes):
      if let overlay = view as? EditableImageLayerView, let base = overlay.baseImage {
        overlay.applyOverlay(base: base, style: style, strokes: strokes)
      }
    }
    refreshAfterTextLayerChange(view)
    if textStyleTarget === view { syncTextStyleControls() }
  }

  private func styleTools(for view: UIView?) -> [TextStyleTool] {
    if view is EditableImageLayerView { return TextStyleTool.overlayTools }
    if let label = view as? EditableTextLayerView, label.layerStyle == nil { return TextStyleTool.stickerTools }
    return TextStyleTool.textTools
  }

  /// Slider rows for `tool` on the current target, in display units (percent).
  private func textStyleSliderSpecs(for tool: TextStyleTool) -> [TextStyleSliderSpec] {
    if let overlay = textStyleTarget as? EditableImageLayerView {
      func spec(_ title: String, _ range: ClosedRange<Float>, _ defaultValue: Float, _ key: WritableKeyPath<OverlayStyle, CGFloat>) -> TextStyleSliderSpec {
        TextStyleSliderSpec(
          title: title, range: range, defaultValue: defaultValue,
          get: { [weak overlay] in Float((overlay?.overlayStyle[keyPath: key] ?? 0) * 100) },
          set: { [weak overlay] value in
            guard let overlay else { return }
            var style = overlay.overlayStyle
            style[keyPath: key] = CGFloat(value) / 100
            overlay.applyOverlayStyle(style)
          }
        )
      }
      switch tool {
      case .filters: return overlay.overlayStyle.filter == .original ? [] : [spec("Strength", 0...100, 100, \.filterStrength)]
      case .light: return [spec("Brightness", -100...100, 0, \.brightness), spec("Contrast", -100...100, 0, \.contrast)]
      case .color: return [spec("Saturation", -100...100, 0, \.saturation), spec("Warmth", -100...100, 0, \.warmth)]
      case .opacity: return [spec("Opacity", 10...100, 100, \.opacity)]
      case .border: return [spec("Width", 0...100, 0, \.border)]
      case .eraser:
        return [TextStyleSliderSpec(
          title: "Size", range: 8...80, defaultValue: 28,
          get: { [weak self] in Float(self?.overlayEraserWidthPoints ?? 28) },
          set: { [weak self] value in self?.overlayEraserWidthPoints = CGFloat(value) }
        )]
      default: return []
      }
    }
    guard let label = textStyleTarget as? EditableTextLayerView else { return [] }
    if label.layerStyle != nil {
      func spec(_ title: String, _ range: ClosedRange<Float>, _ defaultValue: Float, _ key: WritableKeyPath<TextLayerStyle, CGFloat>) -> TextStyleSliderSpec {
        TextStyleSliderSpec(
          title: title, range: range, defaultValue: defaultValue,
          get: { [weak label] in Float((label?.layerStyle?[keyPath: key] ?? 0) * 100) },
          set: { [weak label] value in
            guard let label, var style = label.layerStyle else { return }
            style[keyPath: key] = CGFloat(value) / 100
            label.applyText(label.text ?? "", style: style)
          }
        )
      }
      switch tool {
      case .size: return [spec("Size", 50...200, 100, \.size)]
      case .outline: return [spec("Outline", 0...100, 0, \.outline)]
      case .shadow: return [spec("Shadow", 0...100, 0, \.shadow)]
      case .opacity: return [spec("Opacity", 10...100, 100, \.opacity)]
      case .stretch: return [spec("Width", 50...200, 100, \.stretchX), spec("Height", 50...200, 100, \.stretchY)]
      case .arch: return [spec("Arch", -100...100, 0, \.arch)]
      default: return []
      }
    }
    func spec(_ title: String, _ range: ClosedRange<Float>, _ defaultValue: Float, _ key: WritableKeyPath<StickerStyle, CGFloat>) -> TextStyleSliderSpec {
      TextStyleSliderSpec(
        title: title, range: range, defaultValue: defaultValue,
        get: { [weak label] in Float((label?.stickerStyle[keyPath: key] ?? 0) * 100) },
        set: { [weak label] value in
          guard let label else { return }
          var style = label.stickerStyle
          style[keyPath: key] = CGFloat(value) / 100
          label.applyStickerStyle(style)
        }
      )
    }
    switch tool {
    case .opacity: return [spec("Opacity", 10...100, 100, \.opacity)]
    case .outline: return [spec("Outline", 0...100, 0, \.outline)]
    case .shadow: return [spec("Shadow", 0...100, 0, \.shadow)]
    default: return []
    }
  }

  /// Chips shown above the sliders for `tool` (overlays only).
  private func rebuildStyleChips() {
    guard let stack = textStyleChipStack else { return }
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard let overlay = textStyleTarget as? EditableImageLayerView else {
      textStyleChipScroll?.isHidden = true
      return
    }
    let style = overlay.overlayStyle
    func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> UIButton {
      var config = UIButton.Configuration.filled()
      config.title = title
      config.baseBackgroundColor = selected ? EditorDesignTokens.Colors.accent : EditorDesignTokens.Colors.elevatedSurface
      config.baseForegroundColor = EditorDesignTokens.Colors.textPrimary
      config.cornerStyle = .capsule
      config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = .systemFont(ofSize: 13)
        return outgoing
      }
      let button = UIButton(configuration: config)
      button.addAction(UIAction { _ in
        UISelectionFeedbackGenerator().selectionChanged()
        action()
      }, for: .touchUpInside)
      return button
    }
    func update(_ change: (inout OverlayStyle) -> Void) {
      var next = overlay.overlayStyle
      change(&next)
      overlay.applyOverlayStyle(next)
      refreshAfterTextLayerChange(overlay)
      syncTextStyleControls()
    }
    var chips: [UIView] = []
    switch selectedTextStyleTool {
    case .filters:
      let thumbnails = overlayFilterThumbnailImages(for: overlay)
      chips = PhotoFilter.allCases.map { filter in
        let tile = UIButton(type: .custom)
        tile.setImage(thumbnails[filter], for: .normal)
        tile.imageView?.contentMode = .scaleAspectFill
        tile.layer.cornerRadius = 8
        tile.clipsToBounds = true
        tile.layer.borderWidth = filter == style.filter ? 2 : 0
        tile.layer.borderColor = EditorDesignTokens.Colors.accent.cgColor
        let label = UILabel()
        label.text = filter.rawValue
        label.font = .systemFont(ofSize: 10)
        label.textColor = filter == style.filter ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.textSecondary
        label.textAlignment = .center
        let column = UIStackView(arrangedSubviews: [tile, label])
        column.axis = .vertical
        column.spacing = 2
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.widthAnchor.constraint(equalToConstant: 50).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 50).isActive = true
        tile.addAction(UIAction { _ in
          UISelectionFeedbackGenerator().selectionChanged()
          update { $0.filter = filter; $0.filterStrength = 1 }
        }, for: .touchUpInside)
        return column
      }
    case .blend:
      chips = OverlayBlendMode.allCases.map { mode in pill(mode.title, selected: mode == style.blend) { update { $0.blend = mode } } }
    case .shape:
      chips = OverlayShape.allCases.map { shape in pill(shape.title, selected: shape == style.shape) { update { $0.shape = shape } } }
    case .border:
      chips = MediaEditorViewController.textColorSwatches.map { color in
        let swatch = UIButton(type: .system)
        swatch.backgroundColor = color
        swatch.layer.cornerRadius = 13
        let selected = color == style.borderColor
        swatch.layer.borderWidth = selected ? 2 : 1
        swatch.layer.borderColor = selected ? EditorDesignTokens.Colors.accent.cgColor : EditorDesignTokens.Colors.divider.cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 26).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 26).isActive = true
        swatch.addAction(UIAction { _ in
          UISelectionFeedbackGenerator().selectionChanged()
          update {
            $0.borderColor = color
            if $0.border < 0.01 { $0.border = 0.35 }
          }
        }, for: .touchUpInside)
        return swatch
      }
    case .eraser:
      chips = [
        pill("Erase", selected: !overlayEraseRestoreMode) { [weak self] in
          self?.overlayEraseRestoreMode = false
          self?.rebuildStyleChips()
        },
        pill("Restore", selected: overlayEraseRestoreMode) { [weak self] in
          self?.overlayEraseRestoreMode = true
          self?.rebuildStyleChips()
        },
        pill("Reset", selected: false) { [weak self, weak overlay] in
          guard let self, let overlay, !overlay.eraseStrokes.isEmpty else { return }
          overlay.setEraseStrokes([])
          self.refreshAfterTextLayerChange(overlay)
        },
      ]
    default:
      break
    }
    chips.forEach { stack.addArrangedSubview($0) }
    textStyleChipScroll?.isHidden = chips.isEmpty
    stack.alignment = selectedTextStyleTool == .filters ? .top : .center
  }

  /// Every filter applied to a small copy of the overlay (cached per photo).
  private func overlayFilterThumbnailImages(for overlay: EditableImageLayerView) -> [PhotoFilter: UIImage] {
    guard let base = overlay.baseImage else { return [:] }
    if let cache = overlayFilterThumbnails, cache.base == ObjectIdentifier(base) { return cache.images }
    var images: [PhotoFilter: UIImage] = [:]
    for filter in PhotoFilter.allCases {
      var style = OverlayStyle()
      style.filter = filter
      if let cg = OverlayRenderer.colorPass(base, style: style, maxSide: 120) {
        images[filter] = UIImage(cgImage: cg)
      }
    }
    overlayFilterThumbnails = (ObjectIdentifier(base), images)
    return images
  }

  /// While the overlay Eraser tool is open, a transparent view over the
  /// canvas takes the touches and turns them into erase/restore strokes on
  /// the target overlay. It moves with the fitted picture (a stage
  /// "tracking view"), so its local points are canvas points.
  private func updateOverlayEraseCapture() {
    let active = selectedImageEditorTab == .textStyle && selectedTextStyleTool == .eraser
      && textStyleTarget is EditableImageLayerView
    guard active else {
      overlayEraseCaptureView.transform = .identity
      overlayEraseCaptureView.removeFromSuperview()
      return
    }
    if overlayEraseCaptureView.superview == nil {
      overlayEraseCaptureView.backgroundColor = .clear
      overlayEraseCaptureView.onTouch = { [weak self] point, isStart in self?.handleOverlayErase(at: point, isStart: isStart) }
      view.addSubview(overlayEraseCaptureView)
    }
    overlayEraseCaptureView.transform = .identity
    overlayEraseCaptureView.frame = canvasClipContainerView.frame
    keepSafeAreaCoversOnTop()
    if isFilterStageActive { applyFilterStageFit(animated: false) } else { view.bringSubviewToFront(overlayEraseCaptureView) }
  }

  private func handleOverlayErase(at localPoint: CGPoint, isStart: Bool) {
    guard let overlay = textStyleTarget as? EditableImageLayerView, overlay.bounds.width > 0, overlay.bounds.height > 0 else { return }
    let capture = overlayEraseCaptureView
    // Local point → where it is on the unscaled canvas → the overlay's own box.
    let canvasPoint = CGPoint(
      x: capture.center.x - capture.bounds.width / 2 + localPoint.x,
      y: capture.center.y - capture.bounds.height / 2 + localPoint.y
    )
    let p = overlay.convert(canvasPoint, from: view)
    let normalized = CGPoint(x: p.x / overlay.bounds.width, y: p.y / overlay.bounds.height)
    var strokes = overlay.eraseStrokes
    if isStart || strokes.isEmpty {
      let width = overlayEraserWidthPoints / max(overlay.bounds.width * overlay.currentScale, 1)
      strokes.append(OverlayEraseStroke(points: [normalized], width: width, restore: overlayEraseRestoreMode))
    } else {
      strokes[strokes.count - 1].points.append(normalized)
    }
    overlay.setEraseStrokes(strokes)
    scheduleFilterStageRefresh()
  }

  private func didTapStyleTool(_ tool: TextStyleTool) {
    if tool == .crop {
      // Not a mode: opens the crop screen for this overlay.
      guard let overlay = textStyleTarget as? EditableImageLayerView, let image = overlay.sourceImage ?? overlay.baseImage else { return }
      presentOverlayCropScreen(image: image, editing: overlay)
      return
    }
    guard tool != selectedTextStyleTool else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    selectedTextStyleTool = tool
    syncTextStyleControls()
  }

  private func setUpTextStylePanel() {
    let toolRow = UIStackView()
    toolRow.axis = .horizontal
    toolRow.alignment = .fill
    for tool in TextStyleTool.allCases {
      let button = UIButton(type: .system)
      button.setTitle(tool.title, for: .normal)
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 4, right: 10)
      button.addAction(UIAction { [weak self] _ in self?.didTapStyleTool(tool) }, for: .touchUpInside)
      let underline = UIView()
      underline.backgroundColor = EditorDesignTokens.Colors.textPrimary
      underline.layer.cornerRadius = 1
      underline.tag = 1
      underline.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(underline)
      NSLayoutConstraint.activate([
        underline.widthAnchor.constraint(equalToConstant: 16),
        underline.heightAnchor.constraint(equalToConstant: 2),
        underline.centerXAnchor.constraint(equalTo: button.centerXAnchor),
        underline.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4),
      ])
      textStyleToolButtons[tool] = button
      toolRow.addArrangedSubview(button)
    }
    let toolScroll = UIScrollView()
    toolScroll.showsHorizontalScrollIndicator = false
    toolScroll.translatesAutoresizingMaskIntoConstraints = false
    toolRow.translatesAutoresizingMaskIntoConstraints = false
    toolScroll.addSubview(toolRow)

    let sliderStack = UIStackView()
    sliderStack.axis = .vertical
    sliderStack.spacing = 4
    sliderStack.translatesAutoresizingMaskIntoConstraints = false
    let chipStack = UIStackView()
    chipStack.axis = .horizontal
    chipStack.spacing = 8
    chipStack.alignment = .center
    chipStack.translatesAutoresizingMaskIntoConstraints = false
    let chipScroll = UIScrollView()
    chipScroll.showsHorizontalScrollIndicator = false
    chipScroll.translatesAutoresizingMaskIntoConstraints = false
    chipScroll.addSubview(chipStack)
    NSLayoutConstraint.activate([
      chipScroll.heightAnchor.constraint(equalToConstant: 66),
      chipStack.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
      chipStack.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
      chipStack.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
      chipStack.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
      chipStack.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
    ])
    chipScroll.isHidden = true
    sliderStack.addArrangedSubview(chipScroll)
    textStyleChipStack = chipStack
    textStyleChipScroll = chipScroll
    textStyleSliderRows = (0..<2).map { index in
      let titleLabel = UILabel()
      titleLabel.textColor = EditorDesignTokens.Colors.textPrimary
      titleLabel.font = .systemFont(ofSize: 12)
      titleLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
      let valueLabel = UILabel()
      valueLabel.textColor = EditorDesignTokens.Colors.textSecondary
      valueLabel.font = EditorDesignTokens.Typography.sliderValue
      valueLabel.textAlignment = .right
      valueLabel.setContentHuggingPriority(.required, for: .horizontal)
      valueLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
      let slider = UISlider()
      slider.setMinimumTrackImage(MediaEditorViewController.makeSliderTrackImage(color: EditorDesignTokens.Colors.accent), for: .normal)
      slider.setMaximumTrackImage(MediaEditorViewController.makeSliderTrackImage(color: EditorDesignTokens.Colors.divider), for: .normal)
      slider.setThumbImage(MediaEditorViewController.makeSliderThumbImage(), for: .normal)
      slider.addAction(UIAction { [weak self, weak slider] _ in
        guard let self, let slider else { return }
        self.didChangeTextStyleSlider(index: index, value: slider.value)
      }, for: .valueChanged)
      let row = UIStackView(arrangedSubviews: [titleLabel, slider, valueLabel])
      row.axis = .horizontal
      row.spacing = 8
      row.alignment = .center
      row.heightAnchor.constraint(equalToConstant: 32).isActive = true
      sliderStack.addArrangedSubview(row)
      return TextStyleSliderRow(view: row, titleLabel: titleLabel, slider: slider, valueLabel: valueLabel)
    }

    // Flip (stickers): two pill buttons instead of sliders.
    func flipButton(_ title: String, symbol: String, action: @escaping () -> Void) -> UIButton {
      var config = UIButton.Configuration.filled()
      config.title = title
      config.image = UIImage(systemName: symbol)
      config.imagePadding = 6
      config.baseBackgroundColor = EditorDesignTokens.Colors.elevatedSurface
      config.baseForegroundColor = EditorDesignTokens.Colors.textPrimary
      config.cornerStyle = .capsule
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = .systemFont(ofSize: 13)
        return outgoing
      }
      let button = UIButton(configuration: config)
      button.addAction(UIAction { _ in action() }, for: .touchUpInside)
      return button
    }
    let flipRow = UIStackView(arrangedSubviews: [
      flipButton("Horizontal", symbol: "arrow.left.and.right") { [weak self] in self?.didTapStickerFlip(horizontal: true) },
      flipButton("Vertical", symbol: "arrow.up.and.down") { [weak self] in self?.didTapStickerFlip(horizontal: false) },
    ])
    flipRow.axis = .horizontal
    flipRow.spacing = 12
    flipRow.distribution = .fillEqually
    flipRow.isHidden = true
    sliderStack.addArrangedSubview(flipRow)
    textStyleFlipRow = flipRow

    let container = textStylePanel.contentContainer
    container.addSubview(toolScroll)
    container.addSubview(sliderStack)
    NSLayoutConstraint.activate([
      toolScroll.topAnchor.constraint(equalTo: container.topAnchor),
      toolScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
      toolScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
      toolScroll.heightAnchor.constraint(equalToConstant: Self.filterCategoryRowHeight),
      toolRow.topAnchor.constraint(equalTo: toolScroll.contentLayoutGuide.topAnchor),
      toolRow.bottomAnchor.constraint(equalTo: toolScroll.contentLayoutGuide.bottomAnchor),
      toolRow.leadingAnchor.constraint(equalTo: toolScroll.contentLayoutGuide.leadingAnchor),
      toolRow.trailingAnchor.constraint(equalTo: toolScroll.contentLayoutGuide.trailingAnchor),
      toolRow.heightAnchor.constraint(equalTo: toolScroll.frameLayoutGuide.heightAnchor),

      sliderStack.topAnchor.constraint(equalTo: toolScroll.bottomAnchor, constant: 6),
      sliderStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      sliderStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
    ])
    textStylePanel.configureExpandedHeight(screenHeight: UIScreen.main.bounds.height)
    textStylePanel.onConfirm = { [weak self] in
      self?.didTapToolsTab()
    }
    textStylePanel.onCancel = { [weak self] in self?.cancelToolSession() }
    syncTextStyleControls()
  }

  private func didTapStyleSelectedLayer() {
    guard let layer = selectedLayer, let snapshot = styleSnapshot(of: layer) else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    pauseVideoForToolInteraction()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    commitTextStyleEdit()
    textStyleTarget = layer
    textStyleAtOpen = snapshot
    let tools = styleTools(for: layer)
    if !tools.contains(selectedTextStyleTool) || selectedTextStyleTool == .crop { selectedTextStyleTool = tools[0] }
    textStylePanel.setCollapsedHeight(layer is EditableImageLayerView ? overlayStylePanelHeight : textStylePanelHeight)
    let isSticker = (layer as? EditableTextLayerView).map { $0.layerStyle == nil } ?? false
    textStylePanel.setBarTitle(layer is EditableImageLayerView ? "Overlay" : isSticker ? "Sticker" : "Text")
    syncTextStyleControls()
    selectedImageEditorTab = .textStyle
    updateImageEditorUI(animated: true)
  }

  /// Puts the target's tools and the selected tool's values on screen.
  private func syncTextStyleControls() {
    let tools = styleTools(for: textStyleTarget)
    for (tool, button) in textStyleToolButtons {
      let selected = tool == selectedTextStyleTool
      button.isHidden = !tools.contains(tool)
      button.setTitleColor(selected ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.textSecondary, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
      button.viewWithTag(1)?.isHidden = !selected
    }
    textStyleFlipRow?.isHidden = selectedTextStyleTool != .flip
    rebuildStyleChips()
    updateOverlayEraseCapture()
    let specs = textStyleSliderSpecs(for: selectedTextStyleTool)
    for (index, row) in textStyleSliderRows.enumerated() {
      guard index < specs.count else {
        row.view.isHidden = true
        continue
      }
      let spec = specs[index]
      row.view.isHidden = false
      row.titleLabel.text = spec.title
      row.slider.minimumValue = spec.range.lowerBound
      row.slider.maximumValue = spec.range.upperBound
      let value = spec.get()
      row.slider.value = value
      row.valueLabel.text = "\(Int(value.rounded()))"
    }
  }

  private func didChangeTextStyleSlider(index: Int, value: Float) {
    guard let label = textStyleTarget else { return }
    let specs = textStyleSliderSpecs(for: selectedTextStyleTool)
    guard index < specs.count else { return }
    let spec = specs[index]
    // Snap to the default near it, with a tick, so it's easy to get back.
    var snapped = value.rounded()
    if abs(snapped - spec.defaultValue) <= 2 {
      if abs(spec.get() - spec.defaultValue) > 0.5 { UISelectionFeedbackGenerator().selectionChanged() }
      snapped = spec.defaultValue
    }
    spec.set(snapped)
    textStyleSliderRows[index].valueLabel.text = "\(Int(snapped))"
    refreshAfterTextLayerChange(label)
  }

  private func didTapStickerFlip(horizontal: Bool) {
    UISelectionFeedbackGenerator().selectionChanged()
    if let overlay = textStyleTarget as? EditableImageLayerView {
      var style = overlay.overlayStyle
      if horizontal { style.flipX.toggle() } else { style.flipY.toggle() }
      overlay.applyOverlayStyle(style)
      refreshAfterTextLayerChange(overlay)
      return
    }
    guard let label = textStyleTarget as? EditableTextLayerView, label.canStyleSticker else { return }
    var style = label.stickerStyle
    if horizontal { style.flipX.toggle() } else { style.flipY.toggle() }
    label.applyStickerStyle(style)
    refreshAfterTextLayerChange(label)
  }

  /// Records the whole panel session as one undo step.
  private func commitTextStyleEdit() {
    guard let label = textStyleTarget else { return }
    let oldSnapshot = textStyleAtOpen
    textStyleTarget = nil
    textStyleAtOpen = nil
    updateOverlayEraseCapture()
    guard let oldSnapshot, let newSnapshot = styleSnapshot(of: label), oldSnapshot != newSnapshot else { return }
    pushUndo(
      undo: { [weak self] in self?.applyStyleSnapshot(oldSnapshot, to: label) },
      redo: { [weak self] in self?.applyStyleSnapshot(newSnapshot, to: label) }
    )
  }

  // MARK: - Text entry overlay (image only)

  @objc private func presentTextEntryOverlay() {
    guard canAddLayer() else { return }
    pauseVideoForToolInteraction()
    // Close whatever stateful panel (Effect/Edit/Sticker/Draw/Music) is
    // currently open first — only one tool should ever be active at a
    // time, per the user's explicit request. A no-op if nothing was open.
    selectedImageEditorTab = .tools
    updateImageEditorUI(animated: true)
    presentTextEntryOverlayInternal(editing: nil)
  }

  /// `existing` is non-nil only when opened via the layer toolbar's Edit
  /// action — prefills the overlay with that layer's current text/font/
  /// color/alignment and, on confirm, updates it in place instead of
  /// adding a new layer (see didConfirmTextEntry).
  private func presentTextEntryOverlayInternal(editing existing: EditableTextLayerView?) {
    editingLayer = existing
    textEntryStyle = existing?.layerStyle ?? TextLayerStyle()

    let overlay = UIView(frame: view.bounds)
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    let dismissTap = UITapGestureRecognizer(target: self, action: #selector(didTapTextEntryBackground(_:)))
    overlay.addGestureRecognizer(dismissTap)

    textEntryTextView.text = existing?.text ?? ""
    textEntryTextView.backgroundColor = .clear
    textEntryTextView.tintColor = EditorDesignTokens.Colors.accent
    textEntryTextView.translatesAutoresizingMaskIntoConstraints = false
    textEntryTextView.inputAccessoryView = makeTextEntryAccessoryToolbar()
    applyCurrentTextEntryStyle()

    overlay.addSubview(textEntryTextView)
    view.addSubview(overlay)

    // Center the text view within the space ABOVE the keyboard (which
    // includes the font/color accessory toolbar docked to it) rather than
    // the whole screen — previously it centered in the FULL screen, so as
    // you typed and the view grew taller, it increasingly overlapped/hid
    // behind the keyboard + toolbar (user report). `keyboardLayoutGuide`
    // (iOS 15+, within this app's 16.0 deployment target) tracks the live
    // keyboard height automatically, accessory view included.
    let availableAreaGuide = UILayoutGuide()
    overlay.addLayoutGuide(availableAreaGuide)
    NSLayoutConstraint.activate([
      availableAreaGuide.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor),
      availableAreaGuide.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
      availableAreaGuide.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
      availableAreaGuide.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

      // A little below dead-center of the available area (not exactly
      // centered) — per the user's explicit follow-up ("keep it little
      // lower") after the first pass moved it up.
      textEntryTextView.centerYAnchor.constraint(equalTo: availableAreaGuide.centerYAnchor, constant: 60),
      textEntryTextView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
      textEntryTextView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24),
      textEntryTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
      textEntryTextView.heightAnchor.constraint(lessThanOrEqualTo: availableAreaGuide.heightAnchor, constant: -16),
    ])
    textEntryOverlay = overlay
    updateTextEntryPickerHighlights()
    textEntryTextView.becomeFirstResponder()
  }

  /// Fonts and colors are separate, independently-scrollable rows stacked
  /// vertically (fonts on top, colors+alignment below) — not one row with
  /// everything side by side — per the user's explicit request.
  private func makeTextEntryAccessoryToolbar() -> UIView {
    let screenWidth = UIScreen.main.bounds.width
    let toolbar = UIView(frame: CGRect(x: 0, y: 0, width: screenWidth, height: 136))
    toolbar.autoresizingMask = [.flexibleWidth]
    toolbar.backgroundColor = EditorDesignTokens.Colors.panelBackground

    let cancelButton = MediaEditorViewController.makeTopBarIconButton(systemImageName: "xmark")
    cancelButton.addTarget(self, action: #selector(didCancelTextEntry), for: .touchUpInside)
    let confirmButton = MediaEditorViewController.makeTopBarIconButton(systemImageName: "checkmark")
    confirmButton.tintColor = EditorDesignTokens.Colors.accent
    confirmButton.addTarget(self, action: #selector(didConfirmTextEntry), for: .touchUpInside)

    textFontButtons = TextFontCatalog.options.map { option in
      let button = UIButton(type: .system)
      button.setTitle(option.label, for: .normal)
      button.setTitleColor(EditorDesignTokens.Colors.textSecondary, for: .normal)
      // Each label previews its own font.
      button.titleLabel?.font = TextFontCatalog.font(option, size: 16 * option.sizeFactor)
      // Big invisible padding so a near-miss doesn't fall through and
      // close the sheet.
      button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
      button.addAction(UIAction { [weak self] _ in self?.didSelectTextFont(option.id) }, for: .touchUpInside)
      return button
    }
    let fontRow = UIStackView(arrangedSubviews: textFontButtons)
    fontRow.axis = .horizontal
    fontRow.spacing = 4
    fontRow.alignment = .center

    textColorButtons = MediaEditorViewController.textColorSwatches.map { color in
      let swatch = UIButton(type: .system)
      swatch.backgroundColor = color
      swatch.layer.cornerRadius = 12
      swatch.layer.borderColor = EditorDesignTokens.Colors.divider.cgColor
      swatch.translatesAutoresizingMaskIntoConstraints = false
      swatch.widthAnchor.constraint(equalToConstant: 24).isActive = true
      swatch.heightAnchor.constraint(equalToConstant: 24).isActive = true
      swatch.addAction(UIAction { [weak self] _ in self?.didSelectTextColor(color) }, for: .touchUpInside)
      return swatch
    }
    let colorRow = UIStackView(arrangedSubviews: textColorButtons)
    colorRow.axis = .horizontal
    colorRow.spacing = 10
    colorRow.alignment = .center

    let boldButton = UIButton(type: .system)
    boldButton.setTitle("B", for: .normal)
    boldButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .heavy)
    boldButton.addAction(UIAction { [weak self] _ in self?.didToggleTextBold() }, for: .touchUpInside)
    textBoldButton = boldButton

    let italicButton = UIButton(type: .system)
    italicButton.setTitle("I", for: .normal)
    italicButton.titleLabel?.font = .italicSystemFont(ofSize: 15)
    italicButton.addAction(UIAction { [weak self] _ in self?.didToggleTextItalic() }, for: .touchUpInside)
    textItalicButton = italicButton

    let underlineButton = UIButton(type: .system)
    let underlineTitle = NSAttributedString(string: "U", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
    underlineButton.setAttributedTitle(underlineTitle, for: .normal)
    underlineButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
    underlineButton.addAction(UIAction { [weak self] _ in self?.didToggleTextUnderline() }, for: .touchUpInside)
    textUnderlineButton = underlineButton

    // Cycles left → centre → right.
    let alignButton = UIButton(type: .system)
    alignButton.addAction(UIAction { [weak self] _ in self?.didCycleTextAlignment() }, for: .touchUpInside)
    textAlignButton = alignButton

    // Cycles none → solid → see-through background behind the text.
    let backgroundButton = UIButton(type: .system)
    backgroundButton.addAction(UIAction { [weak self] _ in self?.didCycleTextBackground() }, for: .touchUpInside)
    textBackgroundButton = backgroundButton

    let styleRow = UIStackView(arrangedSubviews: [boldButton, italicButton, underlineButton, alignButton, backgroundButton])
    styleRow.axis = .horizontal
    styleRow.spacing = 14
    styleRow.alignment = .center

    let colorAndStyleRow = UIStackView(arrangedSubviews: [styleRow, colorRow])
    colorAndStyleRow.axis = .horizontal
    colorAndStyleRow.spacing = 16
    colorAndStyleRow.alignment = .center

    let fontScroll = makeHorizontalScrollRow(content: fontRow)
    let colorScroll = makeHorizontalScrollRow(content: colorAndStyleRow)

    let stack = UIStackView(arrangedSubviews: [fontScroll, colorScroll])
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false

    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    confirmButton.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(cancelButton)
    toolbar.addSubview(confirmButton)
    toolbar.addSubview(stack)

    NSLayoutConstraint.activate([
      cancelButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 4),
      cancelButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),

      confirmButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 4),
      confirmButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),

      stack.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 6),
      stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -8),
    ])

    return toolbar
  }

  /// Wraps `content` in a UIScrollView pinned to a fixed row height, using
  /// content's own intrinsic height — the same "self-sizing, scrollable if
  /// it overflows" pattern already used elsewhere in this file.
  private func makeHorizontalScrollRow(content: UIStackView, height: CGFloat = 34) -> UIView {
    content.translatesAutoresizingMaskIntoConstraints = false
    let scrollView = UIScrollView()
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(content)
    NSLayoutConstraint.activate([
      scrollView.heightAnchor.constraint(equalToConstant: height),
      content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      content.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])
    return scrollView
  }

  private func didSelectTextFont(_ fontId: String) {
    UISelectionFeedbackGenerator().selectionChanged()
    textEntryStyle.fontId = fontId
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  @objc private func didSelectTextColor(_ color: UIColor) {
    UISelectionFeedbackGenerator().selectionChanged()
    textEntryStyle.color = color
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  @objc private func didToggleTextBold() {
    UISelectionFeedbackGenerator().selectionChanged()
    textEntryStyle.isBold.toggle()
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  @objc private func didToggleTextItalic() {
    UISelectionFeedbackGenerator().selectionChanged()
    textEntryStyle.isItalic.toggle()
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  @objc private func didToggleTextUnderline() {
    UISelectionFeedbackGenerator().selectionChanged()
    textEntryStyle.isUnderlined.toggle()
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  private func didCycleTextAlignment() {
    UISelectionFeedbackGenerator().selectionChanged()
    switch textEntryStyle.alignment {
    case .left: textEntryStyle.alignment = .center
    case .center: textEntryStyle.alignment = .right
    default: textEntryStyle.alignment = .left
    }
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  private func didCycleTextBackground() {
    UISelectionFeedbackGenerator().selectionChanged()
    textEntryStyle.background = TextBackgroundMode(rawValue: (textEntryStyle.background.rawValue + 1) % 3) ?? .none
    applyCurrentTextEntryStyle()
    updateTextEntryPickerHighlights()
  }

  /// Shows the chosen font/colour/bold/italic/underline/alignment/
  /// background on the text being typed (outline, arch etc. only show on
  /// the layer itself). Bold and italic use the same synthetic stroke and
  /// slant TextLayerRenderer draws, since the bundled fonts have one weight.
  private func applyCurrentTextEntryStyle() {
    let style = textEntryStyle
    let option = TextFontCatalog.option(id: style.fontId)
    let fontSize = TextFontCatalog.baseSize * option.sizeFactor * min(max(style.size, 0.5), 1.5)
    let font = TextFontCatalog.font(option, size: fontSize)
    let fill = TextLayerRenderer.fillColor(for: style)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = style.alignment
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: fill,
      .paragraphStyle: paragraphStyle,
    ]
    if style.isBold {
      attributes[.strokeWidth] = -TextLayerRenderer.boldWidth * 100
      attributes[.strokeColor] = fill
    }
    if style.isItalic { attributes[.obliqueness] = TextLayerRenderer.italicSkew }
    if style.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    textEntryTextView.typingAttributes = attributes
    textEntryTextView.textAlignment = style.alignment
    if style.background == .none {
      textEntryTextView.backgroundColor = .clear
    } else {
      textEntryTextView.backgroundColor = style.color.withAlphaComponent(style.background == .translucent ? TextLayerRenderer.translucentAlpha : 1)
    }
    textEntryTextView.layer.cornerRadius = 12
    textEntryTextView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
    guard !textEntryTextView.text.isEmpty else { return }
    let selectedRange = textEntryTextView.selectedRange
    textEntryTextView.attributedText = NSAttributedString(string: textEntryTextView.text, attributes: attributes)
    textEntryTextView.selectedRange = selectedRange
  }

  private func updateTextEntryPickerHighlights() {
    let accent = EditorDesignTokens.Colors.accent
    let idle = EditorDesignTokens.Colors.textSecondary
    for (index, button) in textFontButtons.enumerated() {
      let isSelected = TextFontCatalog.options[index].id == textEntryStyle.fontId
      button.setTitleColor(isSelected ? accent : idle, for: .normal)
    }
    for (index, swatch) in textColorButtons.enumerated() {
      let isSelected = MediaEditorViewController.textColorSwatches[index] == textEntryStyle.color
      swatch.layer.borderWidth = isSelected ? 2 : 1
      swatch.layer.borderColor = isSelected ? accent.cgColor : EditorDesignTokens.Colors.divider.cgColor
    }
    textBoldButton?.setTitleColor(textEntryStyle.isBold ? accent : idle, for: .normal)
    textItalicButton?.setTitleColor(textEntryStyle.isItalic ? accent : idle, for: .normal)
    textUnderlineButton?.setTitleColor(textEntryStyle.isUnderlined ? accent : idle, for: .normal)
    let alignSymbol: String
    switch textEntryStyle.alignment {
    case .left: alignSymbol = "text.alignleft"
    case .right: alignSymbol = "text.alignright"
    default: alignSymbol = "text.aligncenter"
    }
    textAlignButton?.setImage(UIImage(systemName: alignSymbol), for: .normal)
    textAlignButton?.tintColor = idle
    let backgroundSymbol = textEntryStyle.background == .none ? "a.square" : "a.square.fill"
    textBackgroundButton?.setImage(UIImage(systemName: backgroundSymbol), for: .normal)
    textBackgroundButton?.tintColor = textEntryStyle.background == .none ? idle : accent
    textBackgroundButton?.alpha = textEntryStyle.background == .translucent ? 0.55 : 1
  }

  @objc private func didConfirmTextEntry() {
    let text = textEntryTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let style = textEntryStyle
    let editing = editingLayer
    dismissTextEntryOverlay()
    guard !text.isEmpty else { return }
    if let editing {
      updateTextLayer(editing, text: text, style: style)
    } else {
      addTextLayer(text: text, style: style)
    }
  }

  @objc private func didCancelTextEntry() {
    dismissTextEntryOverlay()
  }

  /// Only dismisses for a tap that lands OUTSIDE the text view itself —
  /// otherwise tapping inside it to place the cursor would also dismiss
  /// the whole overlay, since the gesture is attached to the full-screen
  /// background view underneath.
  @objc private func didTapTextEntryBackground(_ gesture: UITapGestureRecognizer) {
    let location = gesture.location(in: textEntryTextView)
    if !textEntryTextView.bounds.contains(location) {
      dismissTextEntryOverlay()
    }
  }

  private func dismissTextEntryOverlay() {
    textEntryTextView.resignFirstResponder()
    textEntryOverlay?.removeFromSuperview()
    textEntryOverlay = nil
    editingLayer = nil
  }

  // MARK: - Text layers

  private func addTextLayer(text: String, style: TextLayerStyle = TextLayerStyle()) {
    let label = EditableTextLayerView()
    label.applyText(text, style: style)
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      // Above dead-center (not at it) — a freshly-added layer starting at
      // the exact vertical middle of the canvas sat too close to/behind
      // the bottom chrome (filters/adjust strip + tab bar) on shorter
      // canvases, per the user's report. A fixed upward offset (rather
      // than an exact proportion of the canvas height) keeps this simple
      // and applies uniformly to both image and video, whose canvas
      // views/heights differ.
      label.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: Self.newLayerVerticalOffset),
    ])
    // `view` (the screen's root) is the stable reference — never itself
    // transformed — exactly like the image's own gestures in handlePan/etc.
    label.enableGestures(in: view)
    wireLayerCallbacks(label)
    textLayerViews.append(label)
    registerLayerTiming(label)
    // Auto-selected immediately — matches didTapDuplicateSelectedLayer's
    // clones and locks the canvas out of pan/pinch/rotate right away
    // rather than only once the user separately taps the new layer.
    selectLayer(label)
    keepSafeAreaCoversOnTop()
    // registerLayerTiming never sets this layer's own alpha — that's the
    // periodic time observer's job, which only runs during playback — and
    // the freshly-activated centerX/centerY constraints above need an
    // explicit layout pass to actually take effect, which UIKit otherwise
    // only guarantees before the NEXT event (e.g. a touch), not
    // immediately. Per the user's explicit "adding a second text/sticker
    // doesn't show until I touch the screen" report: force both right
    // here instead of relying on some other, incidental trigger.
    updateLayerTimeVisibility()
    view.layoutIfNeeded()
    // wireLayerCallbacks set boundsProvider (which computes this layer's
    // clip mask via `convert(_:from:)`, see updateClipMask's own doc)
    // BEFORE the layoutIfNeeded above ran — so that first mask was built
    // from this brand-new label's stale pre-layout frame and clipped its
    // actual rendered content away entirely. Per the user's explicit "add
    // a second text and it doesn't display until I touch it" report: the
    // on-canvas Delete/Duplicate/Edit toolbar appeared fine (it doesn't
    // depend on this mask), only the rendered text was invisible, until a
    // touch's own pan/pinch/rotate recomputed the mask with now-correct
    // geometry. Re-assigning the same closure re-fires boundsProvider's
    // didSet, recomputing the mask right now instead of waiting for that
    // first touch. Routed through a local var — `label.boundsProvider =
    // label.boundsProvider` compiles as an error ("assigning a property
    // to itself"), even though semantically this is a re-trigger, not a
    // no-op (didSet always fires on assignment; there's no equality check
    // to skip since closures aren't Equatable).
    let currentBoundsProvider = label.boundsProvider
    label.boundsProvider = currentBoundsProvider

    pushUndo(
      undo: { [weak self] in
        label.isHidden = true
        label.isUserInteractionEnabled = false
        if self?.selectedLayer === label { self?.deselectLayer() }
      },
      redo: { label.isHidden = false; label.isUserInteractionEnabled = true }
    )
  }

  // MARK: - Sticker layers

  /// Non-nil only while the Stickers panel is open FOR AN EXISTING sticker
  /// layer (via the toolbar's Edit action) — mirrors
  /// `editingImageOverlayLayer` below. `didTapStickerGridItem` swaps that
  /// layer's image in place instead of adding a new layer when this is
  /// set.
  private var editingStickerLayer: EditableTextLayerView?

  private func selectStickerCategory(_ index: Int) {
    selectedStickerCategory = index
    for (i, button) in stickerCategoryTabs.enumerated() {
      let selected = i == index && (stickerSearchField?.text ?? "").isEmpty
      button.setTitleColor(selected ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.textSecondary, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
      button.viewWithTag(1)?.isHidden = !selected
    }
    if !(stickerSearchField?.text ?? "").isEmpty {
      stickerSearchField?.text = ""
      stickerSearchField?.resignFirstResponder()
      selectStickerCategory(index)
      return
    }
    guard StickerCatalog.categories.indices.contains(index) else {
      showStickerGrid([])
      return
    }
    showStickerGrid(StickerCatalog.categories[index].stickers)
  }

  private func didChangeStickerSearch(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      selectStickerCategory(selectedStickerCategory)
      return
    }
    for button in stickerCategoryTabs {
      button.setTitleColor(EditorDesignTokens.Colors.textSecondary, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
      button.viewWithTag(1)?.isHidden = true
    }
    showStickerGrid(StickerCatalog.search(trimmed))
  }

  /// Rebuilds the grid (6 columns) for `names`.
  private func showStickerGrid(_ names: [String]) {
    guard let grid = stickerGridStack else { return }
    grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let columns = 6
    if names.isEmpty {
      let label = UILabel()
      label.text = "No stickers found"
      label.textColor = EditorDesignTokens.Colors.textSecondary
      label.font = .systemFont(ofSize: 13)
      label.textAlignment = .center
      label.heightAnchor.constraint(equalToConstant: 60).isActive = true
      grid.addArrangedSubview(label)
    }
    for start in stride(from: 0, to: names.count, by: columns) {
      let rowStack = UIStackView()
      rowStack.axis = .horizontal
      rowStack.spacing = EditorDesignTokens.Spacing.thumbnailGutter
      rowStack.distribution = .fillEqually
      for assetName in names[start..<min(start + columns, names.count)] {
        let button = UIButton(type: .custom)
        button.setImage(StickerCatalog.thumbnail(named: assetName, side: 56), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.imageEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        button.backgroundColor = EditorDesignTokens.Colors.elevatedSurface
        button.layer.cornerRadius = EditorDesignTokens.Spacing.thumbnailCornerRadius
        button.heightAnchor.constraint(equalTo: button.widthAnchor).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.didTapStickerGridItem(assetName) }, for: .touchUpInside)
        rowStack.addArrangedSubview(button)
      }
      for _ in 0..<(columns - min(columns, names.count - start)) {
        rowStack.addArrangedSubview(UIView())
      }
      grid.addArrangedSubview(rowStack)
    }
    stickerGridScrollRef?.setContentOffset(.zero, animated: false)
  }

  private func didTapStickerGridItem(_ assetName: String) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if let editingLayer = editingStickerLayer {
      editingStickerLayer = nil
      updateStickerLayer(editingLayer, assetName: assetName)
      // Close the panel after replacing — matches the previous action-
      // sheet's dismiss-on-select behavior, unlike the "stays open" ADD
      // flow below (which lets the user drop several stickers in a row).
      selectedImageEditorTab = .tools
      updateImageEditorUI(animated: true)
    } else {
      addStickerLayer(assetName: assetName)
      // Story (Instagram-style): the tray closes on pick so the new
      // sticker sits on the full-size story, selected — drag it right away
      // (with the tray open the picture is a shrunk snapshot).
      if isStoryMode {
        selectedImageEditorTab = .tools
        updateImageEditorUI(animated: true)
        DispatchQueue.main.async { [weak self] in self?.updateStickerDeleteBadge() }
      }
    }
  }

  private func addStickerLayer(assetName: String) {
    // The Stickers panel stays open between picks — re-check per sticker.
    guard canAddLayer() else { return }
    guard let image = StickerCatalog.image(named: assetName) else { return }
    let label = EditableTextLayerView()
    label.applyStickerImage(image, assetName: assetName)
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      // Same upward offset as addTextLayer, for consistency — see its
      // comment.
      label.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: Self.newLayerVerticalOffset),
    ])
    label.enableGestures(in: view)
    wireLayerCallbacks(label)
    stickerLayerViews.append(label)
    registerLayerTiming(label)
    selectLayer(label)
    keepSafeAreaCoversOnTop()
    // Same fix as addTextLayer's identical two calls — see its comment.
    updateLayerTimeVisibility()
    view.layoutIfNeeded()
    // Same stale-mask fix as addTextLayer's identical line — see its comment.
    let currentBoundsProvider = label.boundsProvider
    label.boundsProvider = currentBoundsProvider

    pushUndo(
      undo: { [weak self] in
        label.isHidden = true
        label.isUserInteractionEnabled = false
        if self?.selectedLayer === label { self?.deselectLayer() }
      },
      redo: { label.isHidden = false; label.isUserInteractionEnabled = true }
    )
  }

  // MARK: - Location stickers (story mode)

  /// Story rail's Location button — opens the nearby/search place picker
  /// and adds the chosen place as a movable pill sticker.
  // MARK: Story info stickers (link, hashtag, time, date)

  private static func infoStickerTitle(_ kind: String) -> String {
    switch kind {
    case "link": return "Link"
    case "hashtag": return "Hashtag"
    case "time": return "Time"
    case "date": return "Date"
    default: return "Location"
    }
  }

  @objc private func didTapStoryInfoStickers() {
    pauseVideoForToolInteraction()
    selectedImageEditorTab = .tools
    updateImageEditorUI(animated: true)
    let sheet = UIAlertController(title: "Add a sticker", message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: "Link or program", style: .default) { [weak self] _ in self?.presentInfoStickerEditor(kind: "link", editing: nil) })
    sheet.addAction(UIAlertAction(title: "Hashtag", style: .default) { [weak self] _ in self?.presentInfoStickerEditor(kind: "hashtag", editing: nil) })
    sheet.addAction(UIAlertAction(title: "Time", style: .default) { [weak self] _ in self?.addInfoSticker(kind: "time", value: nil, name: Self.infoNowText("time")) })
    sheet.addAction(UIAlertAction(title: "Date", style: .default) { [weak self] _ in self?.addInfoSticker(kind: "date", value: nil, name: Self.infoNowText("date")) })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    sheet.popoverPresentationController?.sourceView = view
    sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.maxX - 40, y: view.bounds.midY, width: 1, height: 1)
    present(sheet, animated: true)
  }

  private static func infoNowText(_ kind: String) -> String {
    let f = DateFormatter()
    if kind == "time" { f.timeStyle = .short; f.dateStyle = .none } else { f.setLocalizedDateFormatFromTemplate("EEE d MMM") }
    return f.string(from: Date())
  }

  /// Link: URL (+ optional label; a program's share link opens the program).
  /// Hashtag: the tag. Time / date: refreshed to now.
  private func presentInfoStickerEditor(kind: String, editing: EditableTextLayerView?) {
    if kind == "time" || kind == "date" {
      if let editing { updateInfoSticker(editing, value: nil, name: Self.infoNowText(kind)) }
      return
    }
    let isLink = kind == "link"
    let alert = UIAlertController(
      title: isLink ? "Link sticker" : "Hashtag sticker",
      message: isLink ? "Paste a link — a program's Share link opens that program." : "Viewers tap it to search the tag.",
      preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = isLink ? "https://…" : "#fitness"
      field.keyboardType = isLink ? .URL : .default
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.text = editing?.infoValue.map { isLink ? $0 : "#" + $0 }
    }
    if isLink {
      alert.addTextField { field in
        field.placeholder = "Label (optional)"
        field.text = editing?.locationName
      }
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: editing == nil ? "Add" : "Save", style: .default) { [weak self, weak alert] _ in
      guard let self, let fields = alert?.textFields else { return }
      let raw = (fields.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if isLink {
        var url = raw
        if !url.isEmpty, !url.contains("://") { url = "https://" + url }
        guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
          self.showEditorToast("Enter a valid link")
          return
        }
        let typedLabel = (fields.count > 1 ? fields[1].text ?? "" : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typedLabel.isEmpty ? (parsed.host ?? url).replacingOccurrences(of: "www.", with: "") : typedLabel
        if let editing { self.updateInfoSticker(editing, value: url, name: name) } else { self.addInfoSticker(kind: "link", value: url, name: name) }
      } else {
        let tag = raw.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "")
        guard !tag.isEmpty else { return }
        if let editing { self.updateInfoSticker(editing, value: tag, name: "#" + tag) } else { self.addInfoSticker(kind: "hashtag", value: tag, name: "#" + tag) }
      }
    })
    present(alert, animated: true)
  }

  private func addInfoSticker(kind: String, value: String?, name: String) {
    guard canAddLayer() else { return }
    let label = EditableTextLayerView()
    label.infoKind = kind
    label.infoValue = value
    applyLocationSticker(to: label, name: name, style: 0)
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: Self.newLayerVerticalOffset),
    ])
    label.enableGestures(in: view)
    wireLayerCallbacks(label)
    stickerLayerViews.append(label)
    registerLayerTiming(label)
    selectLayer(label)
    keepSafeAreaCoversOnTop()
    updateLayerTimeVisibility()
    view.layoutIfNeeded()
    let currentBoundsProvider = label.boundsProvider
    label.boundsProvider = currentBoundsProvider
    pushUndo(
      undo: { [weak self] in
        label.isHidden = true
        label.isUserInteractionEnabled = false
        if self?.selectedLayer === label { self?.deselectLayer() }
      },
      redo: { label.isHidden = false; label.isUserInteractionEnabled = true }
    )
  }

  private func updateInfoSticker(_ label: EditableTextLayerView, value: String?, name: String) {
    let oldValue = label.infoValue
    let oldName = label.locationName ?? name
    let style = label.locationStyle
    let apply: (String?, String) -> Void = { [weak self, weak label] value, name in
      guard let self, let label else { return }
      label.infoValue = value
      self.setLocationSticker(label, name: name, style: style)
    }
    apply(value, name)
    pushUndo(undo: { apply(oldValue, oldName) }, redo: { apply(value, name) })
  }

  @objc private func didTapStoryLocation() {
    pauseVideoForToolInteraction()
    selectedImageEditorTab = .tools
    updateImageEditorUI(animated: true)
    presentLocationPicker(editing: nil)
  }

  /// `editing` non-nil (toolbar Edit) replaces that layer's place name,
  /// keeping its style + transform, instead of adding a new layer.
  private func presentLocationPicker(editing: EditableTextLayerView?) {
    let picker = LocationPickerViewController()
    picker.onSelect = { [weak self, weak editing] place in
      guard let self else { return }
      if let editing {
        self.updateLocationLayer(editing, name: place.name, latitude: place.latitude, longitude: place.longitude)
      } else {
        self.addLocationLayer(name: place.name, latitude: place.latitude, longitude: place.longitude)
      }
    }
    present(picker, animated: true)
  }

  private func addLocationLayer(name: String, latitude: Double?, longitude: Double?) {
    let label = EditableTextLayerView()
    applyLocationSticker(to: label, name: name, style: 0)
    label.locationLatitude = latitude
    label.locationLongitude = longitude
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      // Same base anchor as addStickerLayer — duplicate/export rely on it.
      label.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: Self.newLayerVerticalOffset),
    ])
    label.enableGestures(in: view)
    wireLayerCallbacks(label)
    stickerLayerViews.append(label)
    registerLayerTiming(label)
    selectLayer(label)
    keepSafeAreaCoversOnTop()
    updateLayerTimeVisibility()
    view.layoutIfNeeded()
    // Same stale-mask fix as addStickerLayer — see addTextLayer's comment.
    let currentBoundsProvider = label.boundsProvider
    label.boundsProvider = currentBoundsProvider

    pushUndo(
      undo: { [weak self] in
        label.isHidden = true
        label.isUserInteractionEnabled = false
        if self?.selectedLayer === label { self?.deselectLayer() }
      },
      redo: { label.isHidden = false; label.isUserInteractionEnabled = true }
    )
  }

  private func updateLocationLayer(_ label: EditableTextLayerView, name: String, latitude: Double?, longitude: Double?) {
    guard let oldName = label.locationName else { return }
    let oldLatitude = label.locationLatitude
    let oldLongitude = label.locationLongitude
    guard oldName != name || oldLatitude != latitude || oldLongitude != longitude else { return }
    let style = label.locationStyle
    let apply: (String, Double?, Double?) -> Void = { [weak self] name, latitude, longitude in
      label.locationLatitude = latitude
      label.locationLongitude = longitude
      self?.setLocationSticker(label, name: name, style: style)
    }
    apply(name, latitude, longitude)
    pushUndo(
      undo: { apply(oldName, oldLatitude, oldLongitude) },
      redo: { apply(name, latitude, longitude) }
    )
  }

  private func cycleLocationStyle(_ label: EditableTextLayerView) {
    guard let name = label.locationName else { return }
    let oldStyle = label.locationStyle
    let newStyle = (oldStyle + 1) % LocationStickerRenderer.styleCount
    setLocationSticker(label, name: name, style: newStyle)
    pushUndo(
      undo: { [weak self] in self?.setLocationSticker(label, name: name, style: oldStyle) },
      redo: { [weak self] in self?.setLocationSticker(label, name: name, style: newStyle) }
    )
  }

  /// Re-renders an EXISTING location layer in place (name/style change) —
  /// the pill's width changes with the name, so the clip mask and toolbar
  /// are refreshed after layout.
  private func setLocationSticker(_ label: EditableTextLayerView, name: String, style: Int) {
    applyLocationSticker(to: label, name: name, style: style)
    view.layoutIfNeeded()
    let currentBoundsProvider = label.boundsProvider
    label.boundsProvider = currentBoundsProvider
    if selectedLayer === label { repositionLayerToolbar() }
    refreshLayersPanel()
  }

  private func applyLocationSticker(to label: EditableTextLayerView, name: String, style: Int) {
    let symbol: String?
    switch label.infoKind {
    case "link": symbol = "link"
    case "hashtag": symbol = nil
    case "time": symbol = "clock"
    case "date": symbol = "calendar"
    default: symbol = "mappin"
    }
    let image = LocationStickerRenderer.render(name: name, style: style, symbol: symbol)
    label.locationName = name
    label.locationStyle = style
    label.applyStickerImage(image, assetName: "location", size: image.size)
  }

  // MARK: - Image overlay layers (one photo placed on top of another)

  /// Non-nil only while the photo picker is open FOR AN EXISTING overlay
  /// layer (via the toolbar's Edit action) — `picker(_:didFinishPicking:)`
  /// swaps that layer's image in place instead of adding a new layer.
  private var editingImageOverlayLayer: EditableImageLayerView?

  @objc private func presentImageOverlayPicker() {
    guard canAddLayer() else { return }
    pauseVideoForToolInteraction()
    // Close whatever stateful panel (Effect/Edit/Sticker/Draw/Music) is
    // currently open first — only one tool should ever be active at a
    // time, per the user's explicit request. A no-op if nothing was open.
    selectedImageEditorTab = .tools
    updateImageEditorUI(animated: true)
    editingImageOverlayLayer = nil
    presentPhotoPicker()
  }

  private func presentImageOverlayPickerForEdit(_ layer: EditableImageLayerView) {
    editingImageOverlayLayer = layer
    presentPhotoPicker()
  }

  /// `PHPickerViewController` (not `UIImagePickerController`) deliberately —
  /// it doesn't require photo-library usage-description permission
  /// prompting, the modern/Apple-recommended choice for "let the user pick
  /// one photo" with no need to browse/manage the library otherwise.
  private func presentPhotoPicker() {
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  // MARK: - Merge extra videos (queued playback, same video layer)
  //
  // Per the user's explicit "doesn't matter how many video, all video
  // clips will be added to same video layer and will be played in queue,
  // same like Instagram" request — genuinely queues in the live in-app
  // preview (see rebuildVideoQueue) as well as the exported file (see
  // exportVideo). Trim is inline, directly in the primary clip's own
  // filmstrip row (see refreshMergedClipsStrip below), per the user's
  // explicit "true single continuous filmstrip" choice. Pan/zoom of the
  // clip itself stay primary-clip-only, but per the user's LATER, explicit
  // "if I add new video then existing text/icon/music should be auto
  // added on that layer too" request, text/sticker/overlay/music layers
  // now DO extend across merged clips too (see combinedLayerDuration's
  // own doc) — every existing layer's end time is pushed out to the new
  // combined duration whenever a clip is added (didPickSecondVideoClip /
  // loadAdditionalClipDuration), unconditionally; drag a layer's own
  // end handle back in if it shouldn't cover the new clip.

  @objc private func presentVideoClipPicker() {
    pauseVideoForToolInteraction()
    selectedImageEditorTab = .tools
    updateImageEditorUI(animated: true)
    var config = PHPickerConfiguration()
    config.filter = .videos
    config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  private func didPickSecondVideoClip(url: URL) {
    // Captured BEFORE any state changes below — rebuildVideoQueue always
    // restarts playback from the PRIMARY clip's very beginning (see its
    // own doc), which silently reset the playhead to 0 every time a video
    // was added, per the user's explicit "after adding new video, don't
    // reset video layer start, stay where we added it" report. Same fix
    // shape as the merged-clip split/delete position-loss fix earlier
    // this session — seekCombinedTimeline already knows how to land back
    // on the exact same spot regardless of whether that's the primary
    // clip or an existing merged clip.
    let previousCombinedTime = combinedTimeForCurrentPlayback()
    additionalVideoClipURLs.append(url)
    // Extends every layer to the new (fallback-estimated, since the real
    // duration hasn't loaded yet — see loadAdditionalClipDuration) total
    // right away for immediate feedback; corrected/grown further once
    // the real duration resolves below.
    extendLayerTimingsToCombinedDuration()
    refreshMergedClipsStrip()
    rebuildVideoQueue(startPlaying: false)
    seekCombinedTimeline(to: previousCombinedTime)
    loadAdditionalClipDuration(url)
  }

  /// Per the user's explicit "if i add new video then it should be auto
  /// added on that layer" request, confirmed as UNCONDITIONAL (every
  /// layer, including ones already manually shortened) via
  /// AskUserQuestion — pushes every existing layer's end out to the
  /// current combined duration. A no-op once nothing's actually shorter
  /// than the new duration (e.g. re-called after the real clip duration
  /// resolves but it happened to match the 5s fallback estimate exactly).
  private func extendLayerTimingsToCombinedDuration() {
    guard mediaType != "image", !layerTimings.isEmpty else { return }
    let duration = combinedLayerDuration()
    guard duration > 0 else { return }
    var didChange = false
    // Only the LAST segment ever extends — earlier segments (before a
    // split, or an internal gap left by a deleted split portion) keep
    // their own end exactly as the user set it.
    for (id, var timing) in layerTimings {
      guard let lastIndex = timing.segments.indices.last, timing.segments[lastIndex].upperBound < duration else { continue }
      timing.segments[lastIndex] = timing.segments[lastIndex].lowerBound...duration
      layerTimings[id] = timing
      didChange = true
    }
    if didChange {
      updateLayerTimeVisibility()
      refreshLayersPanel()
    }
  }

  /// A stable, never-displayed UIView per merged clip, existing SOLELY so
  /// LayerRangeBarView.Item can use its ObjectIdentifier — that API (also
  /// used by real on-canvas Text/Sticker/Overlay layers) needs a genuine
  /// reference-type identity, and a clip has no on-canvas view of its own
  /// to borrow one from. Created once per URL and reused, so the identity
  /// (and therefore which row item is "selected") stays stable across
  /// refreshMergedClipsStrip rebuilds.
  private func proxyView(for url: URL) -> UIView {
    if let existing = additionalClipProxyViews[url] { return existing }
    let proxy = UIView()
    additionalClipProxyViews[url] = proxy
    return proxy
  }

  private func loadAdditionalClipDuration(_ url: URL) {
    Task { [weak self] in
      guard let self, let duration = try? await AVURLAsset(url: url).load(.duration) else { return }
      let seconds = CMTimeGetSeconds(duration)
      guard seconds.isFinite, seconds > 0 else { return }
      await MainActor.run {
        self.additionalClipDurations[url] = seconds
        // Corrects/grows the estimate-based extension didPickSecondVideoClip
        // already applied, now that the real duration is known.
        self.extendLayerTimingsToCombinedDuration()
        self.refreshMergedClipsStrip()
      }
    }
  }

  /// Repopulates the persistent `mergedStripView` with current merged-clip
  /// state and recomputes its share of the seamless filmstrip row's width
  /// — called whenever any merged-clip-affecting state changes (add,
  /// remove, a clip's duration/thumbnail finishing its async load). Per
  /// the user's explicit "true single continuous filmstrip" choice, this
  /// clip's own frames render as a direct, zero-gap continuation of
  /// videoTrimView's own filmstrip rather than a separate row in the
  /// Layers panel (see VideoTrimView.squareTrailingCorners and
  /// LayerRangeBarView.isMergedClipsContinuation for how the seam itself
  /// is drawn seamlessly).
  ///
  /// Each kept SEGMENT gets a FIXED anchor — the sum of KEPT (not full)
  /// durations of everything before it, across every clip's own segments
  /// — that never moves until the NEXT call to this function, so the bar
  /// doesn't rescale itself out from under an in-progress drag. Its
  /// item's rangeStart/rangeEnd = anchor...anchor+keptLength (packed
  /// back-to-back with zero gap, not offset by the segment's own real
  /// position) — edge-drag semantics are recovered in onRangeChanged via
  /// a DELTA against the reference segment captured here
  /// (mergedClipReferenceSegments), rather than by baking the segment's
  /// own offset into the item's bar position — which makes
  /// LayerRangeBarView's existing edge-drag gesture land on a genuinely
  /// meaningful video-editing action with NO changes needed to that
  /// shared component's own drag logic: drag an edge → trims that side of
  /// THIS segment's own footage, clamped against its immediate neighbor
  /// segment (if any) within the same clip.
  /// An EARLIER version anchored on FULL duration instead — that left a
  /// PERMANENT gap (not just a cosmetic in-drag one) sized to whatever had
  /// been trimmed off the preceding clip, since the item's own rendered
  /// span stopped short of its anchor-to-anchor slot's full width. Fixed
  /// per the user's explicit "these clips are not displaying same...
  /// remove trimmed portion... keep all container UI same" report.
  /// A real limitation, still accepted per the user's own earlier explicit
  /// choice: since neighboring items don't reflow to stay adjacent MID-DRAG
  /// (only once refreshMergedClipsStrip runs again, e.g. onDragEnded),
  /// shrinking one item can leave a brief visual gap next to it until that
  /// happens — purely cosmetic and now self-corrects immediately on
  /// release rather than waiting for some unrelated event; the actual
  /// export/preview always concatenates clips using their real saved trim
  /// values regardless of any visual gap.
  private func refreshMergedClipsStrip() {
    var anchor: Double = 0
    var allAnchors: [URL: [Double]] = [:]
    var allReferenceSegments: [URL: [ClosedRange<Double>]] = [:]
    var items: [LayerRangeBarView.Item] = []
    for url in additionalVideoClipURLs {
      let fullDuration = additionalClipDurations[url] ?? 5
      let segments = additionalClipSegments[url] ?? [0...fullDuration]
      let isActive = url == activeClipURL
      var segmentAnchors: [Double] = []
      for (index, segment) in segments.enumerated() {
        let keptLength = segment.upperBound - segment.lowerBound
        segmentAnchors.append(anchor)
        items.append(LayerRangeBarView.Item(
          id: ObjectIdentifier(proxyView(for: url)),
          rangeStart: anchor,
          rangeEnd: anchor + keptLength,
          color: EditorDesignTokens.Colors.accent,
          // Numbered only once split — an unsplit clip's single segment
          // keeps the plain "Clip" label, matching layer segments' own
          // "only number once split" convention.
          label: segments.count > 1 ? "Clip \(index + 1)" : "Clip",
          segmentIndex: index,
          thumbnailTiles: tilesForMergedClipSegment(url: url, segment: segment, fullDuration: fullDuration),
          isActive: isActive,
          // Only the FIRST segment shows the duration label, matching
          // VideoTrimView's own "one label for the whole clip, not one
          // per segment" convention.
          durationLabel: (isActive && index == 0) ? durationLabelText(for: url) : nil
        ))
        anchor += keptLength
      }
      allAnchors[url] = segmentAnchors
      allReferenceSegments[url] = segments
    }
    mergedClipSegmentAnchors = allAnchors
    mergedClipReferenceSegments = allReferenceSegments
    mergedStripView.configure(duration: max(anchor, 1), items: items)
    mergedStripView.isHidden = additionalVideoClipURLs.isEmpty
    videoTrimView.squareTrailingCorners = !additionalVideoClipURLs.isEmpty
    for url in additionalVideoClipURLs where additionalClipThumbnailTiles[url] == nil {
      loadAdditionalClipThumbnail(url)
    }
    updateFilmstripLayout()
  }

  /// Picks WHICH of a clip's pre-sampled (evenly across its FULL real
  /// duration, from `loadAdditionalClipThumbnail`) frames fall within one
  /// KEPT segment's own real `segment` range, for that segment's own item
  /// to tile across just its own bar width — mirrors
  /// VideoTrimView.drawCompactedThumbnails' identical per-segment
  /// filter/fallback exactly, so a merged clip that's been split reads the
  /// same way the primary clip's own split segments already do: each
  /// piece shows real frames from its own real time range, and a segment
  /// too short to contain any sample point falls back to its single
  /// nearest neighboring frame instead of a solid color gap.
  private func tilesForMergedClipSegment(url: URL, segment: ClosedRange<Double>, fullDuration: Double) -> [UIImage] {
    guard let allTiles = additionalClipThumbnailTiles[url], !allTiles.isEmpty, fullDuration > 0 else { return [] }
    let tileCount = mergedClipThumbnailTileCount
    let matching = (0..<tileCount).filter { index in
      let sampleTime = fullDuration * (Double(index) + 0.5) / Double(tileCount)
      return sampleTime >= segment.lowerBound && sampleTime <= segment.upperBound
    }
    if !matching.isEmpty { return matching.compactMap { allTiles[$0] } }
    let midpoint = (segment.lowerBound + segment.upperBound) / 2
    let nearestIndex = (0..<tileCount).min(by: { a, b in
      let sampleA = fullDuration * (Double(a) + 0.5) / Double(tileCount)
      let sampleB = fullDuration * (Double(b) + 0.5) / Double(tileCount)
      return abs(sampleA - midpoint) < abs(sampleB - midpoint)
    })
    guard let nearestIndex, let image = allTiles[nearestIndex] else { return [] }
    return [image]
  }

  /// Sizes videoTrimView/mergedStripView at a FIXED pixels-per-second
  /// scale (timelinePointsPerSecond) rather than proportionally fitting
  /// the screen — per the user's explicit "full Instagram-style scrolling
  /// timeline" choice, a longer combined video produces a WIDER
  /// scrollable strip instead of a squeezed one. Called on every initial-
  /// duration load, primary split/delete change, and merged-clip trim/
  /// add/remove.
  /// Video redesign: refreshes "current / total" (m:ss), only touching the
  /// label when the text actually changes (called at 60fps).
  /// Tap haptics for buttons whose actions are also called from code
  /// (e.g. play/pause), so only a real tap buzzes.
  @objc private func hapticLight() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
  @objc private func hapticMedium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }

  private let videoSelectionLabel = UILabel()

  private func updateVideoSelectionLabel() {
    guard mediaType != "image" else { return }
    let text: String
    if selectedMusicSegmentIndex != nil {
      text = "Music"
    } else if let layer = selectedLayer {
      text = layer is EditableTextLayerView ? "Text" : "Sticker"
    } else if let url = activeClipURL, let index = additionalVideoClipURLs.firstIndex(of: url) {
      text = "Clip \(index + 2)"
    } else {
      text = ""
    }
    if videoSelectionLabel.text != text { videoSelectionLabel.text = text }
    updateLayerStateButtons()
  }

  // MARK: - Speed control (roadmap row 28)

  /// A clip's kept parts in source time (main clip = sourceURL / nil).
  private func clipParts(_ url: URL?) -> [ClosedRange<Double>] {
    guard let url, url != sourceURL else { return videoSegments }
    return additionalClipSegments[url] ?? [0...(additionalClipDurations[url] ?? 5)]
  }

  /// Speed of one part (its source range) given a clip's spans.
  private static func partSpeed(_ spans: [SpeedSpan]?, _ part: ClosedRange<Double>) -> Double {
    let mid = (part.lowerBound + part.upperBound) / 2
    return spans?.last(where: { $0.range.contains(mid) })?.speed ?? 1
  }

  private func partSpeed(_ url: URL?, _ part: ClosedRange<Double>) -> Double {
    Self.partSpeed(speedSpans[url ?? sourceURL], part)
  }

  /// Sets one part's speed; a never-split merged clip covers its whole
  /// source so a late-loading duration can't move it.
  private func setPartSpeedSpan(_ url: URL, _ part: ClosedRange<Double>, _ speed: Double) {
    var spans = speedSpans[url] ?? []
    let range = url != sourceURL && additionalClipSegments[url] == nil ? 0...Double(Int32.max) : part
    spans.removeAll { $0.range.lowerBound >= range.lowerBound && $0.range.upperBound <= range.upperBound }
    spans.append(SpeedSpan(range: range, speed: speed))
    speedSpans[url] = spans
  }

  /// Every part on the combined timeline in order (combined start, kept
  /// length, speed).
  private func timelineSpeedParts() -> [(start: Double, kept: Double, speed: Double)] {
    var parts: [(start: Double, kept: Double, speed: Double)] = []
    for block in timelineBlocks() {
      var cursor = block.combinedStart
      for part in clipParts(block.url) {
        let kept = part.upperBound - part.lowerBound
        parts.append((cursor, kept, partSpeed(block.url, part)))
        cursor += kept
      }
    }
    return parts
  }

  /// Speed of the part the player is in right now.
  private func currentPlayingPartSpeed() -> Double {
    guard let player else { return 1 }
    let local = CMTimeGetSeconds(player.currentTime())
    guard local.isFinite else { return 1 }
    if queuePlayer?.currentItem === primaryPlayerItem || queuePlayer?.currentItem == nil {
      guard let part = videoSegments.last(where: { $0.lowerBound <= local }) ?? videoSegments.first else { return 1 }
      return partSpeed(sourceURL, part)
    }
    guard let currentItem = queuePlayer?.currentItem,
          let url = additionalPlayerItemsByURL.first(where: { $0.item === currentItem })?.url else { return 1 }
    // A merged clip's item plays its kept parts back-to-back.
    let parts = clipParts(url)
    var remaining = local
    for part in parts {
      let length = part.upperBound - part.lowerBound
      if remaining <= length { return partSpeed(url, part) }
      remaining -= length
    }
    return parts.last.map { partSpeed(url, $0) } ?? 1
  }

  /// While playing, keeps the rate at the current part's speed — called
  /// from the periodic time observer so it switches as playback crosses
  /// parts.
  private func applyPreviewSpeed() {
    guard let player, player.rate > 0 else { return }
    let speed = Float(currentPlayingPartSpeed())
    if player.rate != speed { player.rate = speed }
  }

  /// The part the Speed sheet edits: the tapped part of the selected clip,
  /// else the one under the playhead, else its first.
  private func selectedSpeedPart(_ url: URL) -> (index: Int, part: ClosedRange<Double>)? {
    let parts = clipParts(url)
    let tapped = url == sourceURL ? videoTrimView.selectedSegmentIndex : selectedMergedClipSegmentIndex
    if let i = tapped, parts.indices.contains(i) { return (i, parts[i]) }
    if let player {
      let local = CMTimeGetSeconds(player.currentTime())
      if local.isFinite {
        if url == sourceURL, queuePlayer?.currentItem === primaryPlayerItem || queuePlayer?.currentItem == nil {
          if let i = videoSegments.lastIndex(where: { $0.lowerBound <= local }) { return (i, parts[i]) }
        } else if let currentItem = queuePlayer?.currentItem,
                  additionalPlayerItemsByURL.first(where: { $0.item === currentItem })?.url == url {
          var remaining = local
          for (i, part) in parts.enumerated() {
            let length = part.upperBound - part.lowerBound
            if remaining <= length { return (i, part) }
            remaining -= length
          }
        }
      }
    }
    return parts.first.map { (0, $0) }
  }

  /// Starts playback at the playing part's own speed (play() alone resets
  /// the rate to 1).
  private func startPlayback(_ player: AVPlayer) {
    player.play()
    let speed = Float(currentPlayingPartSpeed())
    if speed != 1 { player.rate = speed }
  }

  /// Edits-style Speed sheet: ✕ · Speed · ✓, the big value, the clip's
  /// length before → after, and a ruler (0.25x–4x, doubling per step,
  /// 1x in the middle). The clip plays at the new speed while dragging.
  @objc private func didTapClipSpeed() {
    guard let url = selectedClipURLForActions(), speedSheet == nil else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    guard let (partIndex, part) = selectedSpeedPart(url) else { return }
    let original = partSpeed(url, part)
    let originalSpans = speedSpans[url]
    let sourceLength = part.upperBound - part.lowerBound

    let sheet = UIView()
    sheet.translatesAutoresizingMaskIntoConstraints = false
    sheet.backgroundColor = EditorDesignTokens.Colors.panelBackground
    sheet.layer.cornerRadius = 22
    sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

    func barButton(_ symbol: String, tint: UIColor, label: String, action: @escaping () -> Void) -> UIButton {
      let b = UIButton(type: .system)
      b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
      b.tintColor = tint
      b.accessibilityLabel = label
      b.addAction(UIAction { _ in
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
      }, for: .touchUpInside)
      b.widthAnchor.constraint(equalToConstant: 44).isActive = true
      b.heightAnchor.constraint(equalToConstant: 44).isActive = true
      return b
    }
    let cancel = barButton("xmark", tint: EditorDesignTokens.Colors.textPrimary, label: "Cancel") { [weak self] in
      self?.closeSpeedSheet(url: url, part: part, originalSpans: originalSpans, apply: false)
    }
    let done = barButton("checkmark", tint: EditorDesignTokens.Colors.accent, label: "Apply speed") { [weak self] in
      self?.closeSpeedSheet(url: url, part: part, originalSpans: originalSpans, apply: true)
    }
    let title = UILabel()
    title.text = "Speed"
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    title.textColor = EditorDesignTokens.Colors.textPrimary
    title.textAlignment = .center
    let header = UIStackView(arrangedSubviews: [cancel, title, done])
    header.alignment = .center

    let value = UILabel()
    value.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
    value.textColor = EditorDesignTokens.Colors.textPrimary
    value.textAlignment = .center
    let durations = UILabel()
    durations.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    durations.textColor = EditorDesignTokens.Colors.textSecondary
    durations.textAlignment = .center

    let ruler = SpeedRulerView()
    ruler.value = original
    ruler.onChange = { [weak self] speed in
      guard let self else { return }
      self.setPartSpeedSpan(url, part, speed)
      self.applyPreviewSpeed()
      self.updateSpeedSheetLabels(speed: speed, sourceLength: sourceLength)
      self.refreshVideoTimeLabel()
    }
    ruler.heightAnchor.constraint(equalToConstant: 72).isActive = true

    let note = UILabel()
    note.text = "Voices keep their normal pitch"
    note.font = .systemFont(ofSize: 12)
    note.textColor = EditorDesignTokens.Colors.textSecondary
    note.textAlignment = .center

    let stack = UIStackView(arrangedSubviews: [header, value, durations, ruler, note])
    stack.axis = .vertical
    stack.spacing = 6
    stack.setCustomSpacing(14, after: durations)
    stack.translatesAutoresizingMaskIntoConstraints = false
    sheet.addSubview(stack)
    view.addSubview(sheet)
    NSLayoutConstraint.activate([
      sheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      sheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      sheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 8),
      stack.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
    ])
    speedSheet = sheet
    speedValueLabel = value
    speedDurationLabel = durations
    updateSpeedSheetLabels(speed: original, sourceLength: sourceLength)

    // Play the part from its start so the new speed can be seen.
    if let block = timelineBlocks().first(where: { ($0.url ?? sourceURL) == url && (selectedMergedClipURL != nil || $0.url == nil) }) {
      let partStart = block.combinedStart + clipParts(url).prefix(partIndex).reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
      seekCombinedTimeline(to: partStart)
      filmstripScrollView.setContentOffset(CGPoint(x: scrollOffsetX(forCombinedTime: partStart), y: 0), animated: false)
    }
    if !isVideoPlaying { didTapPlayPause() }

    sheet.transform = CGAffineTransform(translationX: 0, y: 320)
    UIView.animate(withDuration: 0.25) { sheet.transform = .identity }
  }

  private func updateSpeedSheetLabels(speed: Double, sourceLength: Double) {
    speedValueLabel?.text = Self.speedTitle(speed)
    func fmt(_ t: Double) -> String {
      let tenths = Int((t * 10).rounded())
      return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
    speedDurationLabel?.text = "Part \(fmt(sourceLength)) → \(fmt(sourceLength / speed))"
  }

  private func closeSpeedSheet(url: URL, part: ClosedRange<Double>, originalSpans: [SpeedSpan]?, apply: Bool) {
    guard let sheet = speedSheet else { return }
    let chosenSpans = speedSpans[url]
    speedSheet = nil
    if isVideoPlaying { didTapPlayPause() }
    UIView.animate(withDuration: 0.2, animations: { sheet.transform = CGAffineTransform(translationX: 0, y: sheet.bounds.height) }) { _ in
      sheet.removeFromSuperview()
    }
    let changed = Self.partSpeed(originalSpans, part) != Self.partSpeed(chosenSpans, part)
    if !apply || !changed {
      setSpeedSpans(originalSpans, for: url)
      return
    }
    setSpeedSpans(chosenSpans, for: url)
    pushUndo(
      undo: { [weak self] in self?.setSpeedSpans(originalSpans, for: url) },
      redo: { [weak self] in self?.setSpeedSpans(chosenSpans, for: url) }
    )
  }

  private static func speedTitle(_ speed: Double) -> String {
    let rounded = (speed * 100).rounded() / 100
    if rounded == rounded.rounded() { return "\(Int(rounded))x" }
    return String(format: rounded * 10 == (rounded * 10).rounded() ? "%.1fx" : "%.2fx", rounded)
  }

  private func setSpeedSpans(_ spans: [SpeedSpan]?, for url: URL) {
    speedSpans[url] = (spans?.isEmpty ?? true) ? nil : spans
    refreshVideoTimeLabel()
    applyPreviewSpeed()
    updateLayerStateButtons()
  }

  // MARK: - Beat sync

  private func updateBeatSyncNote() {
    if selectedMusicTrack == nil {
      beatSyncNoteLabel?.text = "Add a music track to find its beats"
    } else if musicBeats.isEmpty {
      beatSyncNoteLabel?.text = "Finding the beats…"
    } else {
      beatSyncNoteLabel?.text = "\(musicBeats.count) beats found · shown as dots on the music track. Cuts and layer edges snap to them."
    }
  }

  /// Finds the song's beats on the downloaded copy (off the main thread).
  private func detectBeats(for track: MusicTrack) {
    withLocalMusicURL(for: track) { [weak self] url in
      guard url.isFileURL else { return }
      DispatchQueue.global(qos: .utility).async {
        let beats = BeatDetector.beats(in: url)
        DispatchQueue.main.async {
          guard let self, self.selectedMusicTrack?.id == track.id else { return }
          self.musicBeats = beats
          self.updateBeatSyncNote()
          self.refreshLayersPanel()
        }
      }
    }
  }

  /// Beats on the combined timeline: the chosen song section, placed where
  /// the music starts (same anchor as playback / export).
  private func combinedBeatTimes() -> [Double] {
    guard !musicBeats.isEmpty else { return [] }
    let anchor = musicSegments.first?.lowerBound ?? musicOffset
    let times = musicBeats.filter { $0 >= musicTrimStart && $0 <= musicTrimEnd }.map { anchor + ($0 - musicTrimStart) }
    guard !musicSegments.isEmpty else { return times }
    return times.filter { t in musicSegments.contains { $0.contains(t) } }
  }

  private func nearestBeat(to t: Double, within: Double) -> Double? {
    guard let beat = combinedBeatTimes().min(by: { abs($0 - t) < abs($1 - t) }), abs(beat - t) <= within else { return nil }
    return beat
  }

  /// Snaps each edge of a layer's time pieces to a beat within 0.15s.
  private func snapLayerTimingToBeats(_ layer: UIView) {
    guard var timing = layerTimings[ObjectIdentifier(layer)] else { return }
    timing.segments = timing.segments.map { seg in
      let lo = nearestBeat(to: seg.lowerBound, within: 0.15) ?? seg.lowerBound
      let hi = nearestBeat(to: seg.upperBound, within: 0.15) ?? seg.upperBound
      return hi - lo >= 0.5 ? lo...hi : seg
    }
    layerTimings[ObjectIdentifier(layer)] = timing
    updateLayerTimeVisibility()
  }

  // MARK: - Voice-over

  /// Ducking (0.3 while the voice-over plays, 0.15s ramps) at combined time t.
  private func voiceDuckFactor(_ t: Double) -> Float {
    guard voiceOverURL != nil, voiceOverDuration > 0 else { return 1 }
    let start = voiceOverStart
    let end = voiceOverStart + voiceOverDuration
    let ramp = 0.15
    if t <= start - ramp || t >= end + ramp { return 1 }
    if t >= start, t <= end { return Self.voiceDuckLevel }
    let edge = t < start ? (start - t) / ramp : (t - end) / ramp
    return Self.voiceDuckLevel + (1 - Self.voiceDuckLevel) * Float(min(max(edge, 0), 1))
  }

  /// Volume ramps down to `level * duck` over [start, end] (0.15s ramps).
  private static func addDuckRamps(_ params: AVMutableAudioMixInputParameters, level: Float, duck: Float, start: Double, end: Double) {
    guard end > start else { return }
    let ramp = 0.15
    let rampStart = max(0, start - ramp)
    params.setVolumeRamp(fromStartVolume: level, toEndVolume: level * duck, timeRange: CMTimeRange(
      start: CMTime(seconds: rampStart, preferredTimescale: 600), duration: CMTime(seconds: max(0.01, start - rampStart), preferredTimescale: 600)))
    params.setVolumeRamp(fromStartVolume: level * duck, toEndVolume: level, timeRange: CMTimeRange(
      start: CMTime(seconds: end, preferredTimescale: 600), duration: CMTime(seconds: ramp, preferredTimescale: 600)))
  }

  private nonisolated func voiceOverDurationSnapshot(_ asset: AVURLAsset) -> Double {
    let seconds = CMTimeGetSeconds(asset.duration)
    return seconds.isFinite ? seconds : 0
  }

  /// Plays the voice-over in the preview while playback is inside its span.
  private func updateVoicePlaybackWindow() {
    guard let voicePlayer, voiceRecorder == nil else { return }
    let t = combinedTimeForCurrentPlayback()
    let inside = t >= voiceOverStart && t < voiceOverStart + voiceOverDuration
    if isVideoPlaying && inside {
      if !voicePlayer.isPlaying {
        voicePlayer.currentTime = max(0, t - voiceOverStart)
        voicePlayer.play()
      }
    } else if voicePlayer.isPlaying {
      voicePlayer.pause()
    }
  }

  private func makeVoiceRow(duration: Double) -> UIView {
    let rangeBar = LayerRangeBarView()
    rangeBar.snapTargets = { [weak self] id, segment in self?.trackSnapTargets(excluding: id, segment: segment) ?? [] }
    rangeBar.allowBodyDrag = true
    // Moves only once selected (tap first), like the layer tracks.
    rangeBar.bodyDragRequiresSelection = true
    rangeBar.edgeDragEnabled = false
    rangeBar.reorderEnabled = false
    let end = min(voiceOverStart + voiceOverDuration, duration)
    rangeBar.configure(duration: duration, items: [LayerRangeBarView.Item(
      id: ObjectIdentifier(voiceProxyToken),
      rangeStart: min(voiceOverStart, max(0, end - 0.1)),
      rangeEnd: end,
      color: EditorDesignTokens.Colors.voiceLayer,
      label: "Voice-over",
      badge: Self.layerTrackSymbol("mic.fill")
    )])
    rangeBar.translatesAutoresizingMaskIntoConstraints = false
    rangeBar.heightAnchor.constraint(equalToConstant: 36).isActive = true
    rangeBar.widthAnchor.constraint(equalToConstant: max(1, CGFloat(duration) * timelinePointsPerSecond)).isActive = true
    rangeBar.onRangeChanged = { [weak self] _, _, newStart, _ in
      self?.voiceOverStart = newStart
      self?.voicePlayer?.pause()
    }
    voiceRangeBar = rangeBar
    if isVoiceRowSelected { rangeBar.setSelection(id: ObjectIdentifier(voiceProxyToken), segmentIndex: 0) }
    rangeBar.onItemSelected = { [weak self] _, _ in
      guard let self else { return }
      self.deselectLayer()
      self.selectedMergedClipURL = nil
      self.selectedMergedClipSegmentIndex = nil
      self.videoTrimView.clearSegmentSelection()
      self.selectedMusicSegmentIndex = nil
      self.isVoiceRowSelected = true
      self.updateLayerStateButtons()
    }
    rangeBar.onHandleDragStateChanged = { [weak self] isDragging in
      self?.layerTracksScrollView.isScrollEnabled = !isDragging
      self?.filmstripScrollView.isScrollEnabled = !isDragging
    }
    return rangeBar
  }

  private struct VoiceOverSnapshot {
    let url: URL?
    let start: Double
    let duration: Double
  }

  private func applyVoiceOver(_ snap: VoiceOverSnapshot) {
    voicePlayer?.stop()
    voiceOverURL = snap.url
    voiceOverStart = snap.start
    voiceOverDuration = snap.duration
    voicePlayer = snap.url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
    voicePlayer?.prepareToPlay()
    isVoiceRowSelected = false
    refreshLayersPanel()
    player?.volume = effectivePlayerVolume()
  }

  private func deleteVoiceOver() {
    let before = VoiceOverSnapshot(url: voiceOverURL, start: voiceOverStart, duration: voiceOverDuration)
    applyVoiceOver(VoiceOverSnapshot(url: nil, start: 0, duration: 0))
    pushUndo(
      undo: { [weak self] in self?.applyVoiceOver(before) },
      redo: { [weak self] in self?.applyVoiceOver(VoiceOverSnapshot(url: nil, start: 0, duration: 0)) }
    )
  }

  /// Records narration from the playhead while the video plays muted.
  private func presentVoiceRecorder() {
    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        guard let self else { return }
        guard granted else {
          self.showEditorToast("Allow microphone access in Settings to record a voice-over")
          return
        }
        self.showVoiceRecorderPanel()
      }
    }
  }

  private func showVoiceRecorderPanel() {
    guard voiceRecorderPanel == nil else { return }
    pauseVideoForToolInteraction()
    let panel = UIView()
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.backgroundColor = EditorDesignTokens.Colors.panelBackground
    panel.layer.cornerRadius = 22
    panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    let title = UILabel()
    title.text = "Voice-over"
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    title.textColor = EditorDesignTokens.Colors.textPrimary
    let hint = UILabel()
    hint.text = "Records from the playhead. Tap again to stop."
    hint.font = .systemFont(ofSize: 12)
    hint.textColor = EditorDesignTokens.Colors.textSecondary
    hint.numberOfLines = 0
    let time = UILabel()
    time.text = "0:00"
    time.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
    time.textColor = EditorDesignTokens.Colors.textPrimary
    time.textAlignment = .center
    let record = UIButton(type: .custom)
    record.backgroundColor = EditorDesignTokens.Colors.danger
    record.layer.cornerRadius = 32
    record.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)), for: .normal)
    record.tintColor = .white
    record.accessibilityLabel = "Start recording"
    record.addAction(UIAction { [weak self] _ in self?.toggleVoiceRecording() }, for: .touchUpInside)
    record.widthAnchor.constraint(equalToConstant: 64).isActive = true
    record.heightAnchor.constraint(equalToConstant: 64).isActive = true
    let cancel = UIButton(type: .system)
    cancel.setTitle("Cancel", for: .normal)
    cancel.tintColor = EditorDesignTokens.Colors.textPrimary
    cancel.addAction(UIAction { [weak self] _ in self?.finishVoiceRecording(keep: false) }, for: .touchUpInside)
    let recordRow = UIStackView(arrangedSubviews: [record])
    recordRow.axis = .vertical
    recordRow.alignment = .center
    let stack = UIStackView(arrangedSubviews: [title, hint, time, recordRow, cancel])
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(stack)
    view.addSubview(panel)
    NSLayoutConstraint.activate([
      panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
      stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
    ])
    voiceRecorderPanel = panel
    voiceRecorderTimeLabel = time
    voiceRecordButton = record
  }

  private func toggleVoiceRecording() {
    if voiceRecorder != nil {
      finishVoiceRecording(keep: true)
      return
    }
    let session = AVAudioSession.sharedInstance()
    audioSessionBeforeRecording = (session.category, session.mode)
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)
    } catch {
      showEditorToast("Couldn't start the microphone")
      return
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
    guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else {
      showEditorToast("Couldn't start recording")
      return
    }
    voiceRecorder = recorder
    voiceRecordingURL = url
    tempFilesToDelete.append(url)
    voiceRecordingStart = combinedTimeForCurrentPlayback()
    voicePlayer?.pause()
    // The video stays paused while recording (user request) — the mic only
    // hears the voice, and the take is placed at the playhead.
    if isVideoPlaying { didTapPlayPause() }
    player?.volume = 0
    musicPlayer?.pause()
    let maxLength = max(0.3, combinedLayerDuration() - voiceRecordingStart)
    voiceRecordButton?.setImage(UIImage(systemName: "stop.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)), for: .normal)
    voiceRecordButton?.accessibilityLabel = "Stop recording"
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    voiceRecordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, let recorder = self.voiceRecorder else { return }
      let secs = Int(recorder.currentTime)
      self.voiceRecorderTimeLabel?.text = String(format: "%d:%02d", secs / 60, secs % 60)
      self.musicPlayer?.pause()
      // Stop where the video ends (the take can't run past it).
      if recorder.currentTime >= maxLength - 0.05 {
        self.finishVoiceRecording(keep: true)
      }
    }
  }

  private func finishVoiceRecording(keep: Bool) {
    voiceRecordingTimer?.invalidate()
    voiceRecordingTimer = nil
    let recorder = voiceRecorder
    let duration = recorder?.currentTime ?? 0
    recorder?.stop()
    voiceRecorder = nil
    if let previous = audioSessionBeforeRecording {
      try? AVAudioSession.sharedInstance().setCategory(previous.0, mode: previous.1)
      audioSessionBeforeRecording = nil
    }
    if isVideoPlaying { didTapPlayPause() }
    player?.volume = effectivePlayerVolume()
    voiceRecorderPanel?.removeFromSuperview()
    voiceRecorderPanel = nil
    guard keep, recorder != nil, let url = voiceRecordingURL, duration > 0.3 else {
      if keep, recorder != nil { showEditorToast("Too short — hold the recording a little longer") }
      return
    }
    let before = VoiceOverSnapshot(url: voiceOverURL, start: voiceOverStart, duration: voiceOverDuration)
    let after = VoiceOverSnapshot(url: url, start: voiceRecordingStart, duration: duration)
    applyVoiceOver(after)
    pushUndo(
      undo: { [weak self] in self?.applyVoiceOver(before) },
      redo: { [weak self] in self?.applyVoiceOver(after) }
    )
  }

  // MARK: - Text animations

  private var textAnimationSheet: TextAnimationSheetView?

  /// Opens the Animation sheet (In / Out / Loop tiles + duration) for the
  /// selected text layer. Each pick plays on the video right away; ✕
  /// reverts, ✓ keeps it as one undo step.
  @objc private func didTapTextAnimation() {
    guard textAnimationSheet == nil, let layer = selectedLayer as? EditableTextLayerView, !layer.isStickerImageLayer,
          let timing = layerTimings[ObjectIdentifier(layer)] else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let original = timing.anim
    let sheet = TextAnimationSheetView(config: original)
    sheet.translatesAutoresizingMaskIntoConstraints = false
    sheet.onChange = { [weak self, weak layer] config, tab in
      guard let self, let layer else { return }
      self.setTextAnimation(config, for: layer)
      self.previewTextAnimation(for: layer, tab: tab)
    }
    sheet.onClose = { [weak self, weak layer] apply in
      guard let self else { return }
      self.closeTextAnimationSheet()
      guard let layer else { return }
      let chosen = self.layerTimings[ObjectIdentifier(layer)]?.anim ?? original
      guard apply else {
        self.setTextAnimation(original, for: layer)
        return
      }
      guard chosen != original else { return }
      self.pushUndo(
        undo: { [weak self, weak layer] in if let self, let layer { self.setTextAnimation(original, for: layer) } },
        redo: { [weak self, weak layer] in if let self, let layer { self.setTextAnimation(chosen, for: layer) } }
      )
    }
    view.addSubview(sheet)
    NSLayoutConstraint.activate([
      sheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      sheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      sheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    textAnimationSheet = sheet
    sheet.transform = CGAffineTransform(translationX: 0, y: 420)
    UIView.animate(withDuration: 0.25) { sheet.transform = .identity }
  }

  private func closeTextAnimationSheet() {
    guard let sheet = textAnimationSheet else { return }
    textAnimationSheet = nil
    // Story mode has no play button: the story keeps looping.
    if !isStoryMode, isVideoPlaying { didTapPlayPause() }
    UIView.animate(withDuration: 0.2, animations: { sheet.transform = CGAffineTransform(translationX: 0, y: sheet.bounds.height) }) { _ in
      sheet.removeFromSuperview()
    }
  }

  /// Plays the part of the piece under the playhead where the open tab's
  /// animation shows: its start (In / Loop) or just before its end (Out).
  private func previewTextAnimation(for layer: EditableTextLayerView, tab: Int) {
    guard let timing = layerTimings[ObjectIdentifier(layer)] else { return }
    let now = combinedTimeForCurrentPlayback()
    guard let seg = timing.segments.first(where: { $0.contains(now) }) ?? timing.segments.first else { return }
    var target = seg.lowerBound
    if tab == 1 {
      let d = min(timing.anim.outDuration, (seg.upperBound - seg.lowerBound) / 2)
      target = max(seg.lowerBound, seg.upperBound - d - 0.4)
    }
    seekCombinedTimeline(to: target)
    if !isStoryMode {
      filmstripScrollView.setContentOffset(CGPoint(x: scrollOffsetX(forCombinedTime: target), y: 0), animated: false)
    }
    if !isVideoPlaying { didTapPlayPause() }
    // Music jumps with the video (re-placed by the playback window).
    if !isStoryMusicPausedByUser {
      musicPlayer?.pause()
      updateMusicPlaybackWindow()
    }
    updateLayerTimeVisibility()
  }

  private func setTextAnimation(_ config: TextAnimConfig, for layer: EditableTextLayerView) {
    guard var timing = layerTimings[ObjectIdentifier(layer)] else { return }
    timing.anim = config
    layerTimings[ObjectIdentifier(layer)] = timing
    updateLayerTimeVisibility()
    updateLayerStateButtons()
  }

  // MARK: - Transitions (roadmap row 33)

  private static let transitionTitles = ["None", "Fade", "Slide", "Zoom"]

  @objc private func didTapClipTransition() {
    guard let url = selectedMergedClipURL else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let current = transitionsIn[url] ?? 0
    let alert = UIAlertController(title: "Transition into this clip", message: "Plays where the previous clip ends.", preferredStyle: .actionSheet)
    for (type, title) in Self.transitionTitles.enumerated() {
      alert.addAction(UIAlertAction(title: title + (type == current ? "  ✓" : ""), style: .default) { [weak self] _ in
        guard let self, type != current else { return }
        self.setTransition(type, into: url)
        self.pushUndo(
          undo: { [weak self] in self?.setTransition(current, into: url) },
          redo: { [weak self] in self?.setTransition(type, into: url) }
        )
      })
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.popoverPresentationController?.sourceView = clipTransitionButton
    alert.popoverPresentationController?.sourceRect = clipTransitionButton.bounds
    present(alert, animated: true)
  }

  private func setTransition(_ type: Int, into url: URL) {
    transitionsIn[url] = type == 0 ? nil : type
    updateLayerStateButtons()
  }

  /// Live preview of transitions at clip boundaries (same look as the
  /// export's MediaEditorVideoCompositor.applyTransition), on the video
  /// layer only — stickers / text stay put.
  private func updateTransitionPreview() {
    guard mediaType != "image", !transitionsIn.isEmpty else {
      resetTransitionPreview()
      return
    }
    let t = combinedTimeForCurrentPlayback()
    let d = MediaEditorVideoInstruction.transitionDuration
    let blocks = timelineBlocks()
    var type = 0
    var amount: CGFloat = 0
    var incoming = false
    for i in blocks.indices where i > 0 {
      guard let url = blocks[i].url, let kind = transitionsIn[url], kind != 0 else { continue }
      let boundary = blocks[i].combinedStart
      if t >= boundary - d, t < boundary {
        type = kind; amount = CGFloat(1 - (boundary - t) / d); incoming = false
      } else if t >= boundary, t < boundary + d {
        type = kind; amount = CGFloat(1 - (t - boundary) / d); incoming = true
      }
    }
    guard type != 0, amount > 0 else {
      resetTransitionPreview()
      return
    }
    let layer = playerView.playerLayer
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    switch type {
    case 2:
      layer.opacity = 1
      layer.setAffineTransform(CGAffineTransform(translationX: amount * playerView.bounds.width * (incoming ? 1 : -1), y: 0))
    case 3:
      layer.opacity = Float(1 - amount)
      layer.setAffineTransform(CGAffineTransform(scaleX: 1 + 0.25 * amount, y: 1 + 0.25 * amount))
    default:
      layer.opacity = Float(1 - amount)
      layer.setAffineTransform(.identity)
    }
    CATransaction.commit()
  }

  private func resetTransitionPreview() {
    let layer = playerView.playerLayer
    guard layer.opacity != 1 || !layer.affineTransform().isIdentity else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 1
    layer.setAffineTransform(.identity)
    CATransaction.commit()
  }

  // MARK: - Clip management (duplicate, per-clip volume, remove)

  private func clipVolume(_ url: URL?) -> Float { clipVolumes[url ?? sourceURL] ?? 1 }

  /// Original-audio slider × the playing clip's own volume.
  private func effectivePlayerVolume() -> Float {
    originalAudioVolumeSlider.value * clipVolume(activeClipURL) * originalFadeFactor(combinedTimeForCurrentPlayback()) * voiceDuckFactor(combinedTimeForCurrentPlayback())
  }

  /// Fade in/out audio: gain (0…1) of the clip's own sound at combined time t.
  private func originalFadeFactor(_ t: Double) -> Float {
    guard audioFadeIn || audioFadeOut else { return 1 }
    let total = combinedLayerDuration()
    var g = 1.0
    if audioFadeIn { g = min(g, t / Self.audioFadeSeconds) }
    if audioFadeOut, total > 0 { g = min(g, (total - t) / Self.audioFadeSeconds) }
    return Float(min(max(g, 0), 1))
  }

  /// Fade in/out audio: gain of the music at combined time t (its own first
  /// start / last end).
  private func musicFadeFactor(_ t: Double) -> Float {
    guard audioFadeIn || audioFadeOut, let first = musicSegments.first, let last = musicSegments.last else { return 1 }
    var g = 1.0
    if audioFadeIn { g = min(g, (t - first.lowerBound) / Self.audioFadeSeconds) }
    if audioFadeOut { g = min(g, (last.upperBound - t) / Self.audioFadeSeconds) }
    return Float(min(max(g, 0), 1))
  }

  /// The clip whose segment is selected on the video row (main clip =
  /// sourceURL), when no layer / music is the selection.
  private func selectedClipURLForActions() -> URL? {
    guard mediaType != "image", !isStoryMode, selectedLayer == nil, selectedMusicSegmentIndex == nil else { return nil }
    if let selectedMergedClipURL { return selectedMergedClipURL }
    if videoTrimView.selectedSegmentIndex != nil { return sourceURL }
    return nil
  }

  private struct MergedClipSnapshot {
    let url: URL
    let index: Int
    let segments: [ClosedRange<Double>]?
    let duration: Double?
    let filter: ClipFilterState?
    let volume: Float?
    var speedSpans: [SpeedSpan]? = nil
    var transition: Int? = nil
  }

  private func insertMergedClip(_ snap: MergedClipSnapshot) {
    let previousTime = combinedTimeForCurrentPlayback()
    additionalVideoClipURLs.insert(snap.url, at: min(snap.index, additionalVideoClipURLs.count))
    if let segments = snap.segments { additionalClipSegments[snap.url] = segments }
    if let duration = snap.duration { additionalClipDurations[snap.url] = duration }
    if let filter = snap.filter { clipFilterState[snap.url] = filter }
    if let volume = snap.volume { clipVolumes[snap.url] = volume }
    if let spans = snap.speedSpans { speedSpans[snap.url] = spans }
    if let transition = snap.transition { transitionsIn[snap.url] = transition }
    extendLayerTimingsToCombinedDuration()
    refreshMergedClipsStrip()
    rebuildVideoQueue(startPlaying: false)
    seekCombinedTimeline(to: previousTime)
    if snap.duration == nil { loadAdditionalClipDuration(snap.url) }
    updateLayerStateButtons()
  }

  @discardableResult
  private func removeMergedClip(_ url: URL) -> MergedClipSnapshot? {
    guard let index = additionalVideoClipURLs.firstIndex(of: url) else { return nil }
    // The playing clip's live filter edits live in the working copy.
    clipFilterState[activeClipURL ?? sourceURL] = currentFilterStateSnapshot()
    let snap = MergedClipSnapshot(url: url, index: index, segments: additionalClipSegments[url],
                                  duration: additionalClipDurations[url], filter: clipFilterState[url], volume: clipVolumes[url],
                                  speedSpans: speedSpans[url], transition: transitionsIn[url])
    let previousTime = combinedTimeForCurrentPlayback()
    additionalVideoClipURLs.remove(at: index)
    if selectedMergedClipURL == url {
      selectedMergedClipURL = nil
      selectedMergedClipSegmentIndex = nil
    }
    clampLayerTimingsToCombinedDuration()
    refreshMergedClipsStrip()
    rebuildVideoQueue(startPlaying: false)
    seekCombinedTimeline(to: min(previousTime, max(0, combinedLayerDuration() - 0.1)))
    updateLayerStateButtons()
    return snap
  }

  /// After the timeline got shorter: cut every layer's segments to the new
  /// end, keeping at least a short last piece so no layer is lost.
  private func clampLayerTimingsToCombinedDuration() {
    let duration = combinedLayerDuration()
    guard duration > 0 else { return }
    for (id, var timing) in layerTimings {
      let clipped = timing.segments.compactMap { seg -> ClosedRange<Double>? in
        let lo = min(seg.lowerBound, duration)
        let hi = min(seg.upperBound, duration)
        return hi - lo >= 0.1 ? lo...hi : nil
      }
      timing.segments = clipped.isEmpty ? [max(0, duration - 1)...duration] : clipped
      layerTimings[id] = timing
    }
    updateLayerTimeVisibility()
    refreshLayersPanel()
  }

  /// Removes a whole merged clip (asked when its only piece is deleted).
  private func confirmRemoveMergedClip(_ url: URL) {
    let alert = UIAlertController(title: "Remove this clip?", message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
      guard let self, let snap = self.removeMergedClip(url) else { return }
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      self.pushUndo(
        undo: { [weak self] in self?.insertMergedClip(snap) },
        redo: { [weak self] in self?.removeMergedClip(url) }
      )
    })
    present(alert, animated: true)
  }

  @objc private func didTapClipVolume() {
    guard let url = selectedClipURLForActions() else { return }
    if clipVolumePanel != nil, clipVolumeEditURL == url {
      hideClipVolumePanel()
      return
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    showClipVolumePanel(for: url)
  }

  /// Small floating card above the play row: "Clip volume" + slider + %.
  private func showClipVolumePanel(for url: URL) {
    hideClipVolumePanel()
    clipVolumeEditURL = url
    let panel = UIView()
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.backgroundColor = EditorDesignTokens.Colors.elevatedSurface.withAlphaComponent(0.96)
    panel.layer.cornerRadius = 14
    panel.layer.cornerCurve = .continuous
    let title = UILabel()
    title.text = "Clip volume"
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.textColor = EditorDesignTokens.Colors.textPrimary
    let value = UILabel()
    value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    value.textColor = EditorDesignTokens.Colors.textSecondary
    value.textAlignment = .right
    let slider = UISlider()
    slider.minimumValue = 0
    slider.maximumValue = 1
    slider.value = clipVolume(url)
    slider.minimumTrackTintColor = EditorDesignTokens.Colors.accent
    slider.addTarget(self, action: #selector(clipVolumeSliderChanged(_:)), for: .valueChanged)
    slider.addTarget(self, action: #selector(clipVolumeSliderBegan(_:)), for: .touchDown)
    slider.addTarget(self, action: #selector(clipVolumeSliderEnded(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    value.text = "\(Int((slider.value * 100).rounded()))%"
    for v in [title, value, slider] {
      v.translatesAutoresizingMaskIntoConstraints = false
      panel.addSubview(v)
    }
    view.addSubview(panel)
    NSLayoutConstraint.activate([
      panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      panel.bottomAnchor.constraint(equalTo: splitSegmentButton.topAnchor, constant: -8),
      title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
      title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
      value.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      value.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
      slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
      slider.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
      slider.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
      slider.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
    ])
    clipVolumePanel = panel
    clipVolumeSlider = slider
    clipVolumeValueLabel = value
  }

  private func hideClipVolumePanel() {
    clipVolumePanel?.removeFromSuperview()
    clipVolumePanel = nil
    clipVolumeEditURL = nil
  }

  @objc private func clipVolumeSliderBegan(_ sender: UISlider) {
    clipVolumeBeforeDrag = clipVolume(clipVolumeEditURL)
  }

  @objc private func clipVolumeSliderChanged(_ sender: UISlider) {
    guard let url = clipVolumeEditURL else { return }
    setClipVolume(sender.value, for: url)
  }

  @objc private func clipVolumeSliderEnded(_ sender: UISlider) {
    guard let url = clipVolumeEditURL else { return }
    let before = clipVolumeBeforeDrag
    let after = sender.value
    guard before != after else { return }
    pushUndo(
      undo: { [weak self] in self?.setClipVolume(before, for: url) },
      redo: { [weak self] in self?.setClipVolume(after, for: url) }
    )
  }

  private func setClipVolume(_ value: Float, for url: URL) {
    clipVolumes[url] = value
    player?.volume = effectivePlayerVolume()
    if clipVolumeEditURL == url {
      clipVolumeSlider?.value = value
      clipVolumeValueLabel?.text = "\(Int((value * 100).rounded()))%"
    }
    updateLayerStateButtons()
  }

  // MARK: - Snap guides

  private let snapGuidesView = SnapGuidesView()
  private var lastSnapState = LayerSnapState.none

  /// Draws the guide lines a dragged layer is snapped to (over the canvas)
  /// and plays a light tap each time a new guide engages.
  private func showSnapGuides(_ state: LayerSnapState) {
    if snapGuidesView.superview == nil {
      snapGuidesView.isUserInteractionEnabled = false
      view.addSubview(snapGuidesView)
    }
    let gained = (state.centerX && !lastSnapState.centerX) || (state.centerY && !lastSnapState.centerY)
      || (state.left && !lastSnapState.left) || (state.right && !lastSnapState.right)
      || (state.top && !lastSnapState.top) || (state.bottom && !lastSnapState.bottom)
    if gained { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    // Nothing to redraw / re-front unless the snapped guides changed.
    guard state != lastSnapState || snapGuidesView.frame != canvasClipContainerView.frame else { return }
    lastSnapState = state
    snapGuidesView.frame = canvasClipContainerView.frame
    view.bringSubviewToFront(snapGuidesView)
    snapGuidesView.state = state
  }

  // MARK: - Per-layer hide / lock

  private func isLayerUserHidden(_ layer: UIView) -> Bool {
    layerTimings[ObjectIdentifier(layer)]?.isManuallyHidden ?? false
  }

  private func isLayerLocked(_ layer: UIView) -> Bool {
    layerTimings[ObjectIdentifier(layer)]?.isLocked ?? false
  }

  /// A layer's own pan/pinch/rotate — always off while it's locked or
  /// hidden, whatever the caller asked for.
  private func setOwnGestures(_ layer: EditableLayerView, enabled: Bool) {
    layer.setOwnTransformGesturesEnabled(enabled && !isLayerLocked(layer) && !isLayerUserHidden(layer))
  }

  /// Eye + lock buttons: shown (in place of the selection label) only while
  /// a text/sticker/photo layer is selected in a video session.
  private func updateLayerStateButtons() {
    let show = mediaType != "image" && !isStoryMode && selectedLayer != nil
      && selectedMusicSegmentIndex == nil && !splitSegmentButton.isHidden
    layerHideButton.isHidden = !show
    layerLockButton.isHidden = !show
    let clipURL = show ? nil : selectedClipURLForActions()
    let showClip = clipURL != nil && mediaType != "image" && !isStoryMode && !splitSegmentButton.isHidden
    // Clip volume button removed (user request) — Speed sits in its slot.
    clipVolumeButton.isHidden = true
    clipSpeedButton.isHidden = !showClip
    let showTransition = showClip && selectedMergedClipURL != nil
    clipTransitionButton.isHidden = !showTransition
    let selectedText = (selectedLayer as? EditableTextLayerView).flatMap { $0.isStickerImageLayer ? nil : $0 }
    let showTextAnim = show && selectedText != nil
    textAnimationButton.isHidden = !showTextAnim
    if showTextAnim, let selectedText, let timing = layerTimings[ObjectIdentifier(selectedText)] {
      textAnimationButton.tintColor = timing.anim.isNone ? .white : EditorDesignTokens.Colors.selectedToolTint
    }
    if mediaType != "image", !isStoryMode, !splitSegmentButton.isHidden {
      compareButton?.isHidden = showClip || showTextAnim
    }
    if showTransition, let url = selectedMergedClipURL {
      clipTransitionButton.tintColor = (transitionsIn[url] ?? 0) == 0 ? .white : EditorDesignTokens.Colors.selectedToolTint
    }
    if let clipURL, showClip {
      let speed = selectedSpeedPart(clipURL).map { partSpeed(clipURL, $0.part) } ?? 1
      clipSpeedButton.tintColor = speed == 1 ? .white : EditorDesignTokens.Colors.selectedToolTint
    }
    if let clipURL, showClip {
      let v = clipVolume(clipURL)
      clipVolumeButton.setImage(UIImage(systemName: v <= 0 ? "speaker.slash" : (v < 1 ? "speaker.wave.1" : "speaker.wave.2")), for: .normal)
    }
    if !showClip || clipURL != clipVolumeEditURL { hideClipVolumePanel() }
    if show || showClip { videoSelectionLabel.isHidden = true } else if !splitSegmentButton.isHidden { videoSelectionLabel.isHidden = false }
    guard show, let layer = selectedLayer else { return }
    let hidden = isLayerUserHidden(layer)
    let locked = isLayerLocked(layer)
    layerHideButton.setImage(UIImage(systemName: hidden ? "eye.slash" : "eye"), for: .normal)
    layerHideButton.tintColor = hidden ? EditorDesignTokens.Colors.selectedToolTint : .white
    layerHideButton.accessibilityLabel = hidden ? "Show layer" : "Hide layer"
    layerLockButton.setImage(UIImage(systemName: locked ? "lock.fill" : "lock.open"), for: .normal)
    layerLockButton.tintColor = locked ? EditorDesignTokens.Colors.selectedToolTint : .white
    layerLockButton.accessibilityLabel = locked ? "Unlock layer" : "Lock layer"
  }

  @objc private func didTapToggleLayerHidden() {
    guard let layer = selectedLayer, layerTimings[ObjectIdentifier(layer)] != nil else { return }
    let newValue = !isLayerUserHidden(layer)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    setLayerUserHidden(layer, newValue)
    pushUndo(
      undo: { [weak self, weak layer] in if let self, let layer { self.setLayerUserHidden(layer, !newValue) } },
      redo: { [weak self, weak layer] in if let self, let layer { self.setLayerUserHidden(layer, newValue) } }
    )
  }

  @objc private func didTapToggleLayerLocked() {
    guard let layer = selectedLayer, layerTimings[ObjectIdentifier(layer)] != nil else { return }
    let newValue = !isLayerLocked(layer)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    setLayerLocked(layer, newValue)
    pushUndo(
      undo: { [weak self, weak layer] in if let self, let layer { self.setLayerLocked(layer, !newValue) } },
      redo: { [weak self, weak layer] in if let self, let layer { self.setLayerLocked(layer, newValue) } }
    )
  }

  private func setLayerUserHidden(_ layer: EditableLayerView, _ hidden: Bool) {
    guard var timing = layerTimings[ObjectIdentifier(layer)] else { return }
    timing.isManuallyHidden = hidden
    layerTimings[ObjectIdentifier(layer)] = timing
    applyLayerInteractionState(layer)
    updateLayerTimeVisibility()
    refreshLayersPanel()
    updateLayerStateButtons()
  }

  private func setLayerLocked(_ layer: EditableLayerView, _ locked: Bool) {
    guard var timing = layerTimings[ObjectIdentifier(layer)] else { return }
    timing.isLocked = locked
    layerTimings[ObjectIdentifier(layer)] = timing
    applyLayerInteractionState(layer)
    refreshLayersPanel()
    updateLayerStateButtons()
  }

  /// Re-applies which gestures may move `layer` after its hide/lock state
  /// changed — the selected layer is driven by the shared view-wide
  /// gestures, any other one by its own.
  private func applyLayerInteractionState(_ layer: EditableLayerView) {
    let blocked = isLayerLocked(layer) || isLayerUserHidden(layer)
    if selectedLayer === layer {
      layer.setOwnTransformGesturesEnabled(false)
      sharedLayerPanGesture.isEnabled = !blocked
      sharedLayerPinchGesture.isEnabled = !blocked
      sharedLayerRotationGesture.isEnabled = !blocked
      if blocked {
        layerActionToolbar?.removeFromSuperview()
        layerActionToolbar = nil
      }
    } else {
      setOwnGestures(layer, enabled: selectedImageEditorTab != .draw)
    }
  }

  /// True (and tells the user) when the selected layer is locked — used to
  /// stop split/delete/trim on it.
  private func blockIfSelectedLayerLocked() -> Bool {
    guard selectedMusicSegmentIndex == nil, let layer = selectedLayer, isLayerLocked(layer) else { return false }
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
    showEditorToast("Layer is locked. Unlock it to edit.")
    return true
  }

  /// A combined-timeline time as it plays out: each clip's part divided
  /// by that clip's speed (2x halves it, 0.5x doubles it).
  private func playedOutTime(forCombined t: Double) -> Double {
    var output = 0.0
    for part in timelineSpeedParts() {
      let played = min(max(0, t - part.start), part.kept)
      output += played / max(0.01, part.speed)
      if t <= part.start + part.kept { break }
    }
    return output
  }

  /// Re-shows "0:04 / 0:18" right away (e.g. after a speed change).
  private func refreshVideoTimeLabel() {
    // The music card's "plays 0:00–m:ss" follows speed changes too.
    updateMusicTrackUI()
    lastVideoTimeLabelText = ""
    updateVideoTimeLabel(current: isUserScrubbingFilmstrip
      ? combinedTime(forScrollOffsetX: filmstripScrollView.contentOffset.x)
      : combinedTimeForCurrentPlayback())
  }

  /// `current` is a combined-timeline time; both numbers are shown as the
  /// video will actually play (speed changes included).
  private func updateVideoTimeLabel(current combinedCurrent: Double) {
    let combinedTotal = combinedLayerDuration()
    let total = playedOutTime(forCombined: combinedTotal)
    let current = playedOutTime(forCombined: min(combinedCurrent, combinedTotal))
    func fmt(_ t: Double) -> String {
      let secs = max(0, Int(t.isFinite ? t.rounded(.down) : 0))
      return String(format: "%d:%02d", secs / 60, secs % 60)
    }
    let text = "\(fmt(min(current, total))) / \(fmt(total))"
    guard text != lastVideoTimeLabelText else { return }
    lastVideoTimeLabelText = text
    let attributed = NSMutableAttributedString(
      string: fmt(min(current, total)),
      attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor.white])
    attributed.append(NSAttributedString(
      string: " / \(fmt(total))",
      attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: EditorDesignTokens.Colors.textSecondary]))
    videoTimeLabel.attributedText = attributed
  }

  /// Pinch on the clips / layer tracks zooms the timeline around the
  /// playhead: the time under the playhead stays put while the strip and
  /// every track row stretch or shrink. A tick at the zoom limits.
  @objc private func handleTimelinePinch(_ gesture: UIPinchGestureRecognizer) {
    switch gesture.state {
    case .began:
      timelinePinchStartScale = timelinePointsPerSecond
      if isVideoPlaying { didTapPlayPause() }
    case .changed:
      let range = Self.timelineZoomRange
      let proposed = timelinePinchStartScale * gesture.scale
      let clamped = min(max(proposed, range.lowerBound), range.upperBound)
      guard abs(clamped - timelinePointsPerSecond) > 0.01 else { return }
      let hitLimit = (clamped == range.lowerBound || clamped == range.upperBound) && clamped != timelinePointsPerSecond
      let anchor = combinedTime(forScrollOffsetX: filmstripScrollView.contentOffset.x)
      timelinePointsPerSecond = clamped
      applyTimelineScale()
      filmstripScrollView.contentOffset.x = scrollOffsetX(forCombinedTime: anchor)
      if hitLimit { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    default:
      break
    }
  }

  /// Re-sizes the clips strip and every track row for the current
  /// timelinePointsPerSecond (rows keep their own durations).
  private func applyTimelineScale() {
    updateFilmstripLayout()
    func visit(_ view: UIView) {
      if let bar = view as? LayerRangeBarView, bar !== mergedStripView {
        for constraint in bar.constraints where constraint.firstAttribute == .width && constraint.secondItem == nil {
          constraint.constant = max(1, CGFloat(bar.duration) * timelinePointsPerSecond)
        }
        bar.setNeedsDisplay()
        return
      }
      view.subviews.forEach(visit)
    }
    visit(layerTracksScrollView)
    videoTrimView.setNeedsDisplay()
    mergedStripView.setNeedsDisplay()
    view.layoutIfNeeded()
  }

  private func updateFilmstripLayout() {
    let primaryKeptDuration = videoSegments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
    let mergedKeptDuration = additionalVideoClipURLs.reduce(0.0) { $0 + additionalClipKeptDuration(for: $1) }
    let primaryWidth = max(1, CGFloat(primaryKeptDuration) * timelinePointsPerSecond)
    let mergedWidth = CGFloat(mergedKeptDuration) * timelinePointsPerSecond
    videoTrimViewWidthConstraint?.constant = primaryWidth
    mergedStripViewWidthConstraint?.constant = mergedWidth
    // Matches the SAME total width as videoTrimView+mergedStripView
    // combined — see layerTracksStackWidthConstraint's own doc for why
    // this must be the FULL combined width, not just whichever row is
    // individually widest.
    layerTracksStackWidthConstraint?.constant = primaryWidth + mergedWidth
    view.layoutIfNeeded()
    updateFilmstripContentInsetIfNeeded()
    updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer: isUserScrubbingFilmstrip)
    lastVideoTimeLabelText = ""
    updateVideoTimeLabel(current: isUserScrubbingFilmstrip
      ? combinedTime(forScrollOffsetX: filmstripScrollView.contentOffset.x)
      : combinedTimeForCurrentPlayback())
  }

  /// Centers combined time 0 and the very end under the fixed playhead by
  /// insetting the scroll view's content by half its OWN visible width on
  /// each side — the standard "centered scrubber" padding trick. Applied
  /// identically to layerTracksScrollView (same leading/trailing edges as
  /// filmstripScrollView, see their shared constraints) so their raw
  /// contentOffset.x values stay directly comparable for the two-way
  /// scroll mirror. Recomputed defensively whenever layout runs; only
  /// really changes with device rotation/size class.
  private func updateFilmstripContentInsetIfNeeded() {
    let halfWidth = filmstripScrollView.bounds.width / 2
    guard halfWidth > 0 else { return }
    let newInset = UIEdgeInsets(top: 0, left: halfWidth, bottom: 0, right: halfWidth)
    if filmstripScrollView.contentInset != newInset {
      filmstripScrollView.contentInset = newInset
    }
    // Right inset ALSO matches (not 0) — mirrored contentOffset.x values
    // must never clamp differently between the two scroll views, or
    // scrolling filmstripScrollView all the way to its own true end would
    // silently desync from layerTracksScrollView's smaller valid range.
    if layerTracksScrollView.contentInset != newInset {
      layerTracksScrollView.contentInset = newInset
    }
    // UIScrollView does NOT automatically reposition an already-settled
    // contentOffset (0 by default) when a NEW contentInset is applied —
    // without this explicit one-time correction, the view can end up
    // "scrolled past" a short video's own narrow content into blank
    // space (exactly matching a user report of "video layer not
    // displaying" once this ran for the first time on a short clip).
    // Combined time 0 belongs centered under the fixed playhead, which
    // is exactly -halfWidth once this inset exists.
    if !hasAppliedInitialFilmstripContentInset {
      hasAppliedInitialFilmstripContentInset = true
      filmstripScrollView.contentOffset.x = -halfWidth
      layerTracksScrollView.contentOffset.x = -halfWidth
    }
  }

  // MARK: - Combined-timeline time mapping (primary segments + merged
  // clips, all packed back-to-back with zero gap, per timelinePointsPerSecond's
  // own doc)

  /// Where a dragged track edge snaps (with a haptic): every other track
  /// piece's start / end (text, sticker, photo, music, voice-over), the
  /// playhead and the cuts between clips.
  private func trackSnapTargets(excluding id: ObjectIdentifier, segment: Int) -> [Double] {
    var targets: [Double] = [combinedTimeForCurrentPlayback()]
    for block in timelineBlocks() {
      targets.append(block.combinedStart)
      targets.append(block.combinedStart + block.keptDuration)
    }
    for (layerID, timing) in layerTimings {
      for (index, piece) in timing.segments.enumerated() where !(layerID == id && index == segment) {
        targets.append(piece.lowerBound)
        targets.append(piece.upperBound)
      }
    }
    if selectedMusicTrack != nil {
      for (index, piece) in musicSegments.enumerated() where !(ObjectIdentifier(musicProxyToken) == id && index == segment) {
        targets.append(piece.lowerBound)
        targets.append(piece.upperBound)
      }
    }
    if voiceOverURL != nil, ObjectIdentifier(voiceProxyToken) != id {
      targets.append(voiceOverStart)
      targets.append(voiceOverStart + voiceOverDuration)
    }
    return targets
  }

  private struct TimelineBlock {
    let url: URL?  // nil = primary clip
    let keptDuration: Double
    let combinedStart: Double
  }

  private func timelineBlocks() -> [TimelineBlock] {
    var blocks: [TimelineBlock] = []
    var cursor: Double = 0
    let primaryKept = videoSegments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
    blocks.append(TimelineBlock(url: nil, keptDuration: primaryKept, combinedStart: cursor))
    cursor += primaryKept
    for url in additionalVideoClipURLs {
      let kept = additionalClipKeptDuration(for: url)
      blocks.append(TimelineBlock(url: url, keptDuration: kept, combinedStart: cursor))
      cursor += kept
    }
    return blocks
  }

  /// Both conversions below must agree with updateFilmstripContentInsetIfNeeded's
  /// own `contentInset.left = halfWidth` / initial `contentOffset.x =
  /// -halfWidth` setup — combined time 0 needs to land exactly under the
  /// FIXED playhead (filmstripScrollView's own horizontal center), and
  /// `contentOffset.x` is a "how far past the inset-padded content origin"
  /// value, not the same coordinate space as a raw `time * pointsPerSecond`
  /// content-x. Previously neither of these subtracted/added `halfWidth`
  /// at all — self-consistent between the two (a scrub-then-read-back
  /// round-trip cancelled out), but wrong in an ABSOLUTE sense any time an
  /// offset computed here got compared against/driven by something that
  /// wasn't itself computed the same wrong way — e.g. the periodic time
  /// observer's `setContentOffset(scrollOffsetX(forCombinedTime:))`, which
  /// visibly left the filmstrip permanently offset from the playhead by a
  /// full `halfWidth` (several real seconds, given
  /// timelinePointsPerSecond's low value) the moment playback started —
  /// exactly the user's reported "video is out of the white line" bug,
  /// confirmed via a screenshot showing the gap.
  private func combinedTime(forScrollOffsetX x: CGFloat) -> Double {
    let halfWidth = filmstripScrollView.bounds.width / 2
    return Double(max(0, x + halfWidth) / timelinePointsPerSecond)
  }

  private func scrollOffsetX(forCombinedTime t: Double) -> CGFloat {
    let halfWidth = filmstripScrollView.bounds.width / 2
    return CGFloat(max(0, t)) * timelinePointsPerSecond - halfWidth
  }

  /// Which block (primary or a specific merged clip) a COMBINED time
  /// falls in, defaulting to the last block for anything at/past the end.
  private func timelineBlock(containingCombinedTime t: Double, in blocks: [TimelineBlock]) -> TimelineBlock? {
    blocks.first(where: { t >= $0.combinedStart && t <= $0.combinedStart + $0.keptDuration }) ?? blocks.last
  }

  /// The REVERSE of realSeekTarget — derives the current combined-timeline
  /// position from the PLAYER's own actual state (which item + its local
  /// time), used to drive the highlight/auto-scroll during hands-off
  /// playback (see the periodic time observer).
  private func combinedTimeForCurrentPlayback() -> Double {
    guard let player else { return 0 }
    let localSeconds = CMTimeGetSeconds(player.currentTime())
    guard localSeconds.isFinite else { return 0 }
    let blocks = timelineBlocks()
    if queuePlayer?.currentItem === primaryPlayerItem || queuePlayer?.currentItem == nil {
      guard let primaryBlock = blocks.first(where: { $0.url == nil }) else { return 0 }
      guard let segmentIndex = videoSegments.firstIndex(where: { $0.lowerBound <= localSeconds && localSeconds <= $0.upperBound }) else {
        return primaryBlock.combinedStart
      }
      let keptBeforeThisSegment = videoSegments[0..<segmentIndex].reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
      return primaryBlock.combinedStart + keptBeforeThisSegment + max(0, localSeconds - videoSegments[segmentIndex].lowerBound)
    } else if
      let currentItem = queuePlayer?.currentItem,
      let url = additionalPlayerItemsByURL.first(where: { $0.item === currentItem })?.url,
      let block = blocks.first(where: { $0.url == url })
    {
      return block.combinedStart + max(0, localSeconds)
    }
    return 0
  }

  /// Given a COMBINED time (from a user scrub), returns which real item
  /// to seek and the LOCAL time within it — the inverse of
  /// combinedTimeForCurrentPlayback.
  private func realSeekTarget(forCombinedTime combined: Double) -> (isPrimary: Bool, url: URL?, localSeconds: Double) {
    let blocks = timelineBlocks()
    guard let block = timelineBlock(containingCombinedTime: combined, in: blocks) else { return (true, nil, 0) }
    let offsetWithinBlock = max(0, combined - block.combinedStart)
    guard block.url == nil else { return (false, block.url, offsetWithinBlock) }
    var remaining = offsetWithinBlock
    for segment in videoSegments {
      let segLength = segment.upperBound - segment.lowerBound
      if remaining <= segLength { return (true, nil, segment.lowerBound + remaining) }
      remaining -= segLength
    }
    return (true, nil, videoSegments.last?.upperBound ?? 0)
  }

  /// Actually moves playback to a combined-timeline position — deferred
  /// until a user's scrub gesture SETTLES (scrollViewDidEndDragging/
  /// DidEndDecelerating), not called on every scroll delta, so an
  /// AVQueuePlayer rebuild/advance dance never runs dozens of times a
  /// second mid-drag.
  private func seekCombinedTimeline(to combined: Double) {
    let target = realSeekTarget(forCombinedTime: combined)
    if target.isPrimary {
      if queuePlayer?.currentItem !== primaryPlayerItem {
        rebuildVideoQueue(startPlaying: false)
      }
      player?.seek(to: CMTime(seconds: target.localSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    } else if let url = target.url {
      seekToMergedClip(url: url, localSeconds: target.localSeconds)
    }
  }

  /// Jumps playback directly to a specific merged clip at a specific
  /// local offset within it — AVQueuePlayer has no "seek to an arbitrary
  /// queued item" API, so this rebuilds the queue fresh (matching how
  /// looping/split/delete already jump back to the primary) then
  /// advances past every item before the target one.
  private func seekToMergedClip(url: URL, localSeconds: Double) {
    guard let index = additionalVideoClipURLs.firstIndex(of: url) else { return }
    rebuildVideoQueue(startPlaying: false)
    guard let queuePlayer else { return }
    for _ in 0..<(index + 1) {
      queuePlayer.advanceToNextItem()
    }
    queuePlayer.seek(to: CMTime(seconds: localSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  /// Live, cheap update of which clip is highlighted (yellow border +
  /// duration label) — called on EVERY scroll delta during a user drag
  /// (usingScrollOffsetInsteadOfPlayer: true) and from the periodic time
  /// observer during hands-off playback (false, reads the player's own
  /// actual position instead via combinedTimeForCurrentPlayback). Never
  /// touches the player itself — see seekCombinedTimeline for the actual
  /// (deferred-to-drag-end) seek.
  private func updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer: Bool) {
    let blocks = timelineBlocks()
    let combined = usingScrollOffsetInsteadOfPlayer
      ? combinedTime(forScrollOffsetX: filmstripScrollView.contentOffset.x)
      : combinedTimeForCurrentPlayback()
    let newActiveURL = timelineBlock(containingCombinedTime: combined, in: blocks)?.url
    let newIsPrimaryActive = newActiveURL == nil
    guard newActiveURL != activeClipURL || videoTrimView.isActiveClip != newIsPrimaryActive else { return }
    let previousActiveURL = activeClipURL
    activeClipURL = newActiveURL
    videoTrimView.isActiveClip = newIsPrimaryActive
    updateMergedStripActiveState()
    // Per the user's explicit "edits should stay with their own clip"
    // request — also fixes a pre-existing preview gap: makeAdditionalPlayerItem
    // never attached ANY filter/adjustment compositor to merged clips at
    // all (only makePrimaryPlayerItem did), so they always played back
    // with the primary's own filter frozen at whatever it was, or with
    // none. Only fires on an ACTUAL clip-boundary crossing (see the
    // guard above), not on every poll tick.
    if newActiveURL != previousActiveURL { syncActiveClipFilterState(previousURL: previousActiveURL, newURL: newActiveURL) }
  }

  /// Updates ONLY the isActive/durationLabel flags on the merged-clip
  /// items already computed by the last refreshMergedClipsStrip() call —
  /// deliberately NOT a full refreshMergedClipsStrip() (which also
  /// recomputes anchors/widths and calls back into updateFilmstripLayout,
  /// which itself calls updateActiveClipHighlight — that would recurse).
  /// Cheap: just remaps the existing items array and re-configures.
  private func updateMergedStripActiveState() {
    let updatedItems = mergedStripView.items.map { item -> LayerRangeBarView.Item in
      var item = item
      let url = additionalVideoClipURLs.first(where: { ObjectIdentifier(proxyView(for: $0)) == item.id })
      let isActive = url != nil && url == activeClipURL
      item.isActive = isActive
      item.durationLabel = isActive ? url.map(durationLabelText) : nil
      return item
    }
    mergedStripView.configure(duration: mergedStripView.duration, items: updatedItems)
  }

  private func durationLabelText(for url: URL) -> String {
    String(format: "%.1fs", additionalClipKeptDuration(for: url))
  }

  /// Samples `mergedClipThumbnailTileCount` frames evenly across this
  /// clip's OWN full real duration (same center-of-slice sampling formula
  /// as VideoTrimView.loadThumbnails) instead of a single frame at time
  /// zero — see `additionalClipThumbnailTiles`'s own doc for why. All
  /// frames are gathered (into a fixed-size, index-addressed array, since
  /// generateCGImagesAsynchronously callbacks can arrive out of order)
  /// before refreshing the strip once, rather than progressively like
  /// VideoTrimView does, since a merged clip's item (and therefore its
  /// thumbnailTiles) gets fully rebuilt on every refreshMergedClipsStrip()
  /// call anyway — refreshing per-frame here would just repeat that full
  /// rebuild N times for no visible benefit.
  private func loadAdditionalClipThumbnail(_ url: URL) {
    let asset = AVURLAsset(url: url)
    let tileCount = mergedClipThumbnailTileCount
    Task { [weak self] in
      guard let self, let loadedDuration = try? await asset.load(.duration) else { return }
      let seconds = CMTimeGetSeconds(loadedDuration)
      guard seconds.isFinite, seconds > 0 else { return }
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 240, height: 240)
      var frames: [Int: UIImage] = [:]
      var remaining = tileCount
      for index in 0..<tileCount {
        let time = CMTime(seconds: seconds * (Double(index) + 0.5) / Double(tileCount), preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, cgImage, _, _, _ in
          guard let self else { return }
          DispatchQueue.main.async {
            if let cgImage { frames[index] = UIImage(cgImage: cgImage) }
            remaining -= 1
            if remaining == 0 {
              guard !frames.isEmpty else { return }
              self.additionalClipThumbnailTiles[url] = frames
              self.refreshMergedClipsStrip()
            }
          }
        }
      }
    }
  }

  // MARK: - Overlay image crop (pan/zoom to fit a fixed box before adding)
  //
  // A full-screen modal step between picking a photo for the Overlay
  // feature and actually adding/updating the layer — per the user's
  // explicit "overlay image should be cropped to a chosen size, don't
  // display the full image" request. Deliberately reuses the SAME pan/
  // pinch + "never reveal empty space" clamp pattern already proven for
  // the main photo canvas, rather than a new draggable/resizable crop-
  // FRAME component: that class (CropOverlayView) was fully DELETED from
  // this codebase already (confirmed by its absence, not just unwired —
  // only comments in other files still reference it as historical
  // context), so "reuse the existing crop tool" wasn't actually available
  // — this lower-risk alternative was the user's explicit choice once
  // that was surfaced.
  private let overlayCropOverlayView = UIView()
  private let overlayCropBoxView = UIView()
  private let overlayCropImageView = UIImageView()
  private var overlayCropSourceImage: UIImage?
  private var overlayCropEditingLayer: EditableImageLayerView?
  private var overlayCropTranslation: CGPoint = .zero
  private var overlayCropScale: CGFloat = 1
  private static let overlayCropBoxSize: CGFloat = 260
  private static let overlayCropMinScale: CGFloat = 1
  private static let overlayCropMaxScale: CGFloat = 4

  private func presentOverlayCropScreen(image: UIImage, editing: EditableImageLayerView?) {
    // Bakes any EXIF orientation into the pixel buffer itself so the crop
    // math below (which reads `cgImage.width/height` — the RAW, pre-
    // orientation pixel grid) matches what's actually displayed. Skipping
    // this for a sideways/upside-down photo would crop the wrong region
    // entirely — the same class of orientation pitfall already documented
    // elsewhere in this file (imagePixelSize's orientation-aware swap).
    let normalized = MediaEditorViewController.normalizedUpOrientation(image)
    overlayCropSourceImage = normalized
    overlayCropEditingLayer = editing
    overlayCropTranslation = .zero
    overlayCropScale = 1

    // Rebuilt fresh each time rather than assumed already configured —
    // these 3 views are persistent instances (reused across repeated
    // Overlay picks in one session), so any stale subviews/gesture
    // recognizers from a PRIOR presentation must be cleared first or
    // they'd silently accumulate (duplicate buttons, duplicate pan/pinch
    // handlers double-applying the same touch).
    overlayCropOverlayView.subviews.forEach { $0.removeFromSuperview() }
    overlayCropImageView.gestureRecognizers?.forEach { overlayCropImageView.removeGestureRecognizer($0) }

    overlayCropOverlayView.backgroundColor = .black
    overlayCropOverlayView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(overlayCropOverlayView)
    NSLayoutConstraint.activate([
      overlayCropOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
      overlayCropOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      overlayCropOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      overlayCropOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    let cancelButton = MediaEditorViewController.makeTopBarTextButton(title: "Cancel")
    cancelButton.addTarget(self, action: #selector(didTapOverlayCropCancel), for: .touchUpInside)
    let confirmButton = UIButton(type: .system)
    confirmButton.setTitle("Use Photo", for: .normal)
    confirmButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    // White, matching doneButton — per the user's "make all Done button
    // in white" request, applied for consistency to this equivalent
    // primary confirm button too.
    confirmButton.tintColor = EditorDesignTokens.Colors.textPrimary
    confirmButton.translatesAutoresizingMaskIntoConstraints = false
    confirmButton.heightAnchor.constraint(equalToConstant: EditorDesignTokens.Spacing.minTapTarget).isActive = true
    confirmButton.addTarget(self, action: #selector(didTapOverlayCropConfirm), for: .touchUpInside)
    overlayCropOverlayView.addSubview(cancelButton)
    overlayCropOverlayView.addSubview(confirmButton)

    let hint = UILabel()
    hint.text = "Pinch and drag to choose what's used"
    hint.textColor = EditorDesignTokens.Colors.textSecondary
    hint.font = .systemFont(ofSize: 13)
    hint.translatesAutoresizingMaskIntoConstraints = false

    overlayCropBoxView.backgroundColor = .clear
    overlayCropBoxView.clipsToBounds = true
    overlayCropBoxView.layer.borderWidth = 2
    overlayCropBoxView.layer.borderColor = UIColor.white.cgColor
    overlayCropBoxView.translatesAutoresizingMaskIntoConstraints = false
    overlayCropOverlayView.addSubview(hint)
    overlayCropOverlayView.addSubview(overlayCropBoxView)

    overlayCropImageView.image = normalized
    overlayCropImageView.contentMode = .scaleAspectFill
    overlayCropImageView.transform = .identity
    overlayCropImageView.translatesAutoresizingMaskIntoConstraints = false
    overlayCropImageView.isUserInteractionEnabled = true
    overlayCropBoxView.addSubview(overlayCropImageView)

    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      cancelButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
      cancelButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
      confirmButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
      confirmButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),

      overlayCropBoxView.centerXAnchor.constraint(equalTo: overlayCropOverlayView.centerXAnchor),
      overlayCropBoxView.centerYAnchor.constraint(equalTo: overlayCropOverlayView.centerYAnchor),
      overlayCropBoxView.widthAnchor.constraint(equalToConstant: Self.overlayCropBoxSize),
      overlayCropBoxView.heightAnchor.constraint(equalToConstant: Self.overlayCropBoxSize),

      overlayCropImageView.centerXAnchor.constraint(equalTo: overlayCropBoxView.centerXAnchor),
      overlayCropImageView.centerYAnchor.constraint(equalTo: overlayCropBoxView.centerYAnchor),
      overlayCropImageView.widthAnchor.constraint(equalTo: overlayCropBoxView.widthAnchor),
      overlayCropImageView.heightAnchor.constraint(equalTo: overlayCropBoxView.heightAnchor),

      hint.bottomAnchor.constraint(equalTo: overlayCropBoxView.topAnchor, constant: -16),
      hint.centerXAnchor.constraint(equalTo: overlayCropOverlayView.centerXAnchor),
    ])

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverlayCropPan(_:)))
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleOverlayCropPinch(_:)))
    overlayCropImageView.addGestureRecognizer(pan)
    overlayCropImageView.addGestureRecognizer(pinch)
  }

  @objc private func handleOverlayCropPan(_ gesture: UIPanGestureRecognizer) {
    let translation = gesture.translation(in: overlayCropBoxView)
    overlayCropTranslation.x += translation.x
    overlayCropTranslation.y += translation.y
    gesture.setTranslation(.zero, in: overlayCropBoxView)
    clampOverlayCropTranslation()
    updateOverlayCropTransform()
  }

  @objc private func handleOverlayCropPinch(_ gesture: UIPinchGestureRecognizer) {
    let proposed = overlayCropScale * gesture.scale
    overlayCropScale = min(max(proposed, Self.overlayCropMinScale), Self.overlayCropMaxScale)
    gesture.scale = 1
    clampOverlayCropTranslation()
    updateOverlayCropTransform()
  }

  /// Same shape as the main canvas's own clampBoundedTranslation: at the
  /// current scale, the max offset before an edge would recede past the
  /// box (revealing empty space) is `boxSize * (scale - 1) / 2` — valid
  /// here because overlayCropImageView's OWN (untransformed) size is
  /// fixed at exactly overlayCropBoxSize (aspect-FILL within that fixed
  /// frame already covers the box before any user zoom is applied).
  private func clampOverlayCropTranslation() {
    let maxOffset = Self.overlayCropBoxSize * (overlayCropScale - 1) / 2
    overlayCropTranslation.x = min(max(overlayCropTranslation.x, -maxOffset), maxOffset)
    overlayCropTranslation.y = min(max(overlayCropTranslation.y, -maxOffset), maxOffset)
  }

  private func updateOverlayCropTransform() {
    var t = CGAffineTransform.identity
    t = t.translatedBy(x: overlayCropTranslation.x, y: overlayCropTranslation.y)
    t = t.scaledBy(x: overlayCropScale, y: overlayCropScale)
    overlayCropImageView.transform = t
  }

  @objc private func didTapOverlayCropCancel() {
    dismissOverlayCropScreen()
  }

  @objc private func didTapOverlayCropConfirm() {
    let editing = overlayCropEditingLayer
    let source = overlayCropSourceImage
    guard let cropped = cropOverlayImageForConfirm() else {
      dismissOverlayCropScreen()
      return
    }
    dismissOverlayCropScreen()
    if let editing {
      updateImageOverlayLayer(editing, image: cropped, source: source)
    } else {
      addImageOverlayLayer(image: cropped, source: source)
    }
  }

  private func dismissOverlayCropScreen() {
    overlayCropOverlayView.removeFromSuperview()
    overlayCropSourceImage = nil
    overlayCropEditingLayer = nil
  }

  /// Crops `overlayCropSourceImage` to exactly what's visible within the
  /// box, given the user's current pan/pinch state — the same "map a
  /// fixed on-screen box back into the source's own pixel grid" idea as
  /// `renderExport`'s crop math, just aspect-FILL instead of aspect-FIT
  /// and with no filters/layers/rotation to also account for.
  private func cropOverlayImageForConfirm() -> UIImage? {
    guard let sourceImage = overlayCropSourceImage, let cgImage = sourceImage.cgImage else { return nil }
    let srcWidth = CGFloat(cgImage.width)
    let srcHeight = CGFloat(cgImage.height)
    guard srcWidth > 0, srcHeight > 0 else { return nil }

    // The scale that makes the shorter source dimension exactly fill the
    // box — i.e. contentMode = .scaleAspectFill's own implicit scale —
    // before the user's own overlayCropScale zoom is layered on top.
    let coverScale = Self.overlayCropBoxSize / min(srcWidth, srcHeight)
    let renderScale = coverScale * overlayCropScale
    guard renderScale > 0 else { return nil }

    let cropSizeInSourcePixels = Self.overlayCropBoxSize / renderScale
    let cropCenterInSourcePixels = CGPoint(
      x: srcWidth / 2 - overlayCropTranslation.x / renderScale,
      y: srcHeight / 2 - overlayCropTranslation.y / renderScale
    )
    let cropRect = CGRect(
      x: cropCenterInSourcePixels.x - cropSizeInSourcePixels / 2,
      y: cropCenterInSourcePixels.y - cropSizeInSourcePixels / 2,
      width: cropSizeInSourcePixels,
      height: cropSizeInSourcePixels
    ).intersection(CGRect(x: 0, y: 0, width: srcWidth, height: srcHeight))
    guard cropRect.width > 0, cropRect.height > 0, let croppedCG = cgImage.cropping(to: cropRect) else { return nil }
    return UIImage(cgImage: croppedCG, scale: 1, orientation: .up)
  }

  /// Redraws `image` so its pixel buffer matches `.up` orientation exactly
  /// — a no-op (returns the same image) if it's already `.up`. Needed
  /// because `cropOverlayImageForConfirm` reads `cgImage.width/height`
  /// directly (the RAW, pre-orientation pixel grid), which only matches
  /// what's visually displayed once orientation is baked in.
  private static func normalizedUpOrientation(_ image: UIImage) -> UIImage {
    guard image.imageOrientation != .up else { return image }
    let renderer = UIGraphicsImageRenderer(size: image.size)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
  }

  /// Upright (EXIF baked in) and at most 2048px long — a full-resolution
  /// photo would cost a lot of memory for every filter/eraser re-render.
  private static func overlayPhoto(from image: UIImage) -> UIImage {
    let upright = normalizedUpOrientation(image)
    let longSide = max(upright.size.width * upright.scale, upright.size.height * upright.scale)
    let maxSide: CGFloat = 2048
    guard longSide > maxSide else { return upright }
    let factor = maxSide / longSide
    let size = CGSize(width: (upright.size.width * upright.scale * factor).rounded(), height: (upright.size.height * upright.scale * factor).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in upright.draw(in: CGRect(origin: .zero, size: size)) }
  }

  /// Re-fits an overlay's box to a new picture's proportions (after Edit or
  /// re-crop), keeping its longer side.
  private func resizeOverlayBox(_ layer: EditableImageLayerView, for image: UIImage) {
    let newAspect = max(image.size.width, 0.01) / max(image.size.height, 0.01)
    let oldSize = layer.bounds.size
    guard oldSize.width > 0, oldSize.height > 0, abs(newAspect - oldSize.width / oldSize.height) > 0.01 else { return }
    let longSide = max(oldSize.width, oldSize.height)
    // Own aspect/size constraints, plus a duplicate's "same size as the
    // source" ones (those live on the superview).
    NSLayoutConstraint.deactivate((layer.constraints + (layer.superview?.constraints ?? [])).filter {
      ($0.firstItem as? UIView) === layer && ($0.firstAttribute == .width || $0.firstAttribute == .height)
    })
    NSLayoutConstraint.activate([
      layer.widthAnchor.constraint(equalToConstant: newAspect >= 1 ? longSide : longSide * newAspect),
      layer.heightAnchor.constraint(equalToConstant: newAspect >= 1 ? longSide / newAspect : longSide),
    ])
    view.layoutIfNeeded()
  }

  private func addImageOverlayLayer(image: UIImage, source: UIImage? = nil) {
    let layer = EditableImageLayerView()
    layer.applyOverlay(base: image, style: OverlayStyle(), strokes: [])
    layer.sourceImage = source
    layer.contentMode = .scaleAspectFit
    layer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(layer)

    // Sized to a fixed initial on-screen box (long side capped, aspect
    // preserved) — a full-resolution photo would otherwise appear at some
    // enormous native size before the user pinches it down.
    let aspect = max(image.size.width, 0.01) / max(image.size.height, 0.01)
    NSLayoutConstraint.activate([
      layer.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      // Same base anchor as text/sticker layers — see addTextLayer's
      // comment on why this constant must match the export math exactly.
      layer.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: Self.newLayerVerticalOffset),
      layer.widthAnchor.constraint(equalTo: layer.heightAnchor, multiplier: aspect),
    ])
    if aspect >= 1 {
      layer.widthAnchor.constraint(equalToConstant: Self.overlayInitialMaxDimension).isActive = true
    } else {
      layer.heightAnchor.constraint(equalToConstant: Self.overlayInitialMaxDimension).isActive = true
    }

    layer.enableGestures(in: view)
    wireLayerCallbacks(layer)
    imageOverlayLayerViews.append(layer)
    registerLayerTiming(layer)
    selectLayer(layer)
    keepSafeAreaCoversOnTop()
    // Same fix as addTextLayer's identical two calls — see its comment.
    updateLayerTimeVisibility()
    view.layoutIfNeeded()
    // Same stale-mask fix as addTextLayer's identical line — see its comment.
    let currentBoundsProvider = layer.boundsProvider
    layer.boundsProvider = currentBoundsProvider
    pushUndo(
      undo: { layer.isHidden = true; layer.isUserInteractionEnabled = false },
      redo: { layer.isHidden = false; layer.isUserInteractionEnabled = true }
    )
  }

  /// New photo (Edit) or new crop (re-crop): keeps the look, but drops
  /// eraser strokes — they were drawn on the old picture.
  private func updateImageOverlayLayer(_ layer: EditableImageLayerView, image: UIImage, source: UIImage?) {
    guard let oldBase = layer.baseImage else { return }
    let oldSource = layer.sourceImage
    let oldStrokes = layer.eraseStrokes
    let style = layer.overlayStyle
    layer.applyOverlay(base: image, style: style, strokes: [])
    layer.sourceImage = source
    resizeOverlayBox(layer, for: image)
    scheduleFilterStageRefresh()
    pushUndo(
      undo: { [weak self] in
        layer.applyOverlay(base: oldBase, style: layer.overlayStyle, strokes: oldStrokes)
        layer.sourceImage = oldSource
        self?.resizeOverlayBox(layer, for: oldBase)
        self?.scheduleFilterStageRefresh()
      },
      redo: { [weak self] in
        layer.applyOverlay(base: image, style: layer.overlayStyle, strokes: [])
        layer.sourceImage = source
        self?.resizeOverlayBox(layer, for: image)
        self?.scheduleFilterStageRefresh()
      }
    )
  }

  // MARK: - Filters

  private func applyFilter(_ filter: PhotoFilter) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let old = (filter: selectedFilter, strength: filterStrength, saturation: filterSaturation, sharpness: filterSharpness)
    guard old.filter != filter else { return }
    // A newly picked filter always starts at full strength, with its own
    // Saturation/Sharpness back at 0.
    setFilter(filter, strength: 1, saturation: 0, sharpness: 0)
    pushUndo(
      undo: { [weak self] in
        self?.setFilter(old.filter, strength: old.strength, saturation: old.saturation, sharpness: old.sharpness)
      },
      redo: { [weak self] in
        self?.setFilter(filter, strength: 1, saturation: 0, sharpness: 0)
      }
    )
  }

  private func setFilter(_ filter: PhotoFilter, strength: Float, saturation: Float, sharpness: Float) {
    selectedFilter = filter
    filterStrength = strength
    filterSaturation = saturation
    filterSharpness = sharpness
    refreshPreview()
    updateFilterButtonHighlight()
  }

  @objc private func didTapFilterThumbnail(_ gesture: UITapGestureRecognizer) {
    guard let tag = gesture.view?.tag, PhotoFilter.allCases.indices.contains(tag) else { return }
    let filter = PhotoFilter.allCases[tag]
    // Tapping the already-selected filter (it shows a pencil) opens its sliders.
    if filter == selectedFilter && filter != .original {
      UISelectionFeedbackGenerator().selectionChanged()
      setFilterEditing(true)
      return
    }
    applyFilter(filter)
  }

  private struct FilterThumbnailViews {
    let container: UIView
    let imageView: UIImageView
    /// Dark circle + pencil, shown on the selected filter only.
    let editOverlay: UIView
  }

  private static func makeFilterThumbnailButton(filter: PhotoFilter) -> FilterThumbnailViews {
    let size = EditorDesignTokens.Spacing.thumbnailSize
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.backgroundColor = EditorDesignTokens.Colors.elevatedSurface
    imageView.layer.cornerRadius = size / 2
    imageView.layer.borderColor = EditorDesignTokens.Colors.accent.cgColor
    imageView.translatesAutoresizingMaskIntoConstraints = false

    let label = UILabel()
    label.text = filter.rawValue
    label.textColor = EditorDesignTokens.Colors.textSecondary
    label.font = EditorDesignTokens.Typography.trayLabel
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.isUserInteractionEnabled = true
    container.addSubview(imageView)
    container.addSubview(label)
    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: container.topAnchor),
      imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      imageView.widthAnchor.constraint(equalToConstant: size),
      imageView.heightAnchor.constraint(equalToConstant: size),

      label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      label.widthAnchor.constraint(greaterThanOrEqualToConstant: size),
    ])

    let editOverlay = UIView()
    editOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    editOverlay.layer.cornerRadius = size / 2
    editOverlay.isUserInteractionEnabled = false
    editOverlay.isHidden = true
    editOverlay.translatesAutoresizingMaskIntoConstraints = false
    let pencil = UIImageView(image: UIImage(systemName: "pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
    pencil.tintColor = .white
    pencil.translatesAutoresizingMaskIntoConstraints = false
    editOverlay.addSubview(pencil)
    container.addSubview(editOverlay)
    NSLayoutConstraint.activate([
      editOverlay.topAnchor.constraint(equalTo: imageView.topAnchor),
      editOverlay.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
      editOverlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
      editOverlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
      pencil.centerXAnchor.constraint(equalTo: editOverlay.centerXAnchor),
      pencil.centerYAnchor.constraint(equalTo: editOverlay.centerYAnchor),
    ])

    return FilterThumbnailViews(container: container, imageView: imageView, editOverlay: editOverlay)
  }

  /// Renders each filter's live thumbnail from the just-loaded photo —
  /// called once, right after `baseImage` is set (see viewDidLoad's
  /// download completion closure). Reuses `PhotoFilter.apply(to:)`, the
  /// exact same per-filter CIFilter chain the main preview/export already
  /// use, applied to a small square crop instead of the full image — no
  /// duplicated filter math.
  /// `sourceImage` is `baseImage` for a photo session, or a single
  /// extracted video frame for a video session (see setUpVideoPlayer) —
  /// parameterized rather than reading `baseImage` directly so the exact
  /// same thumbnail-rendering code serves both media types.
  private func renderFilterThumbnails(from sourceImage: UIImage) {
    guard let sourceCIImage = CIImage(image: sourceImage) else { return }
    let size = EditorDesignTokens.Spacing.thumbnailSize * UIScreen.main.scale
    // Center-crop to a square in the source's own pixel space before
    // filtering/downscaling, so the thumbnail isn't a squashed aspect-fit
    // of the whole photo.
    let extent = sourceCIImage.extent
    let squareSide = min(extent.width, extent.height)
    let cropRect = CGRect(
      x: extent.midX - squareSide / 2,
      y: extent.midY - squareSide / 2,
      width: squareSide,
      height: squareSide
    )
    let squareCIImage = sourceCIImage.cropped(to: cropRect)
    let scale = size / squareSide
    let thumbnailBase = squareCIImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    // Only the filters this session shows (no Artistic for video).
    for filter in PhotoFilter.allCases where filterThumbnailImageViews[filter] != nil {
      let filtered = filter.apply(to: thumbnailBase)
      guard
        let cgImage = ciContext.createCGImage(filtered, from: filtered.extent)
      else { continue }
      filterThumbnailImageViews[filter]?.image = UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
    }
  }

  // MARK: - Adjustments (brightness / contrast / saturation)

  /// Track/thumb sized to EditorDesignTokens.Spacing, a trailing numeric
  /// value readout (spec's "slider value labels: 13pt regular, tabular
  /// numerals"), and a light selection-changed haptic when the value
  private static func makeAdjustIconButton(label: String, systemImageName: String) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.title = label
    config.image = UIImage(systemName: systemImageName)
    // Leading (icon beside label), not top (icon above label) — the icon
    // row shares a fixed 44pt height with the single-slider detail view
    // it swaps with, and stacking the icon above the label would make
    // the button's own intrinsic height taller than that budget.
    config.imagePlacement = .leading
    config.imagePadding = 4
    // Plain buttons default to ~14pt side insets, which (on top of the
    // row spacing) left wide gaps between the items.
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    config.baseForegroundColor = EditorDesignTokens.Colors.textSecondary
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = .systemFont(ofSize: 12, weight: .medium)
      return outgoing
    }
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }

  private func didTapAdjustIcon(_ property: AdjustProperty) {
    if property == .auto {
      didTapAutoEnhance()
      return
    }
    UISelectionFeedbackGenerator().selectionChanged()
    selectedAdjustProperty = property
    adjustSliderRows.forEach { key, row in row.isHidden = key != property }
    adjustIconScrollView.isHidden = true
    adjustDetailRow.isHidden = false
    if Self.tuneOrder.contains(where: { $0.0 == property }) { tuneProperty = property }
    updateBlurOverlay()
    updateTuneUI()
  }

  private func didTapAdjustBack() {
    selectedAdjustProperty = nil
    adjustIconScrollView.isHidden = false
    adjustDetailRow.isHidden = true
    updateBlurOverlay()
    updateTuneUI()
  }

  // MARK: - Tune (swipe to adjust)

  private func tuneSlider(for property: AdjustProperty) -> (slider: UISlider, valueLabel: UILabel?)? {
    guard let row = adjustSliderRows[property] as? UIStackView, row.arrangedSubviews.count > 1,
          let slider = row.arrangedSubviews[1] as? UISlider else { return nil }
    return (slider, row.arrangedSubviews.count > 2 ? row.arrangedSubviews[2] as? UILabel : nil)
  }

  private func setUpTune() {
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTunePan(_:)))
    pan.maximumNumberOfTouches = 1
    tuneSurfaceView.addGestureRecognizer(pan)
    tuneSurfaceView.backgroundColor = .clear
    tuneSurfaceView.isHidden = true

    // Value pill on Liquid Glass.
    GlassSurfaceView.install(behind: tunePillView, shape: .rounded(21))
    tunePillView.isUserInteractionEnabled = false
    tunePillView.isHidden = true
    tunePillNameLabel.font = .systemFont(ofSize: 14, weight: .medium)
    tunePillNameLabel.textColor = EditorDesignTokens.Colors.textPrimary
    tunePillValueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    tunePillValueLabel.textColor = EditorDesignTokens.Colors.selectedToolTint
    let labels = UIStackView(arrangedSubviews: [tunePillNameLabel, tunePillValueLabel])
    labels.spacing = 10
    labels.alignment = .center
    labels.translatesAutoresizingMaskIntoConstraints = false
    let track = UIView()
    track.backgroundColor = EditorDesignTokens.Colors.divider
    track.layer.cornerRadius = 1.5
    track.clipsToBounds = true
    track.translatesAutoresizingMaskIntoConstraints = false
    tunePillBarFill.backgroundColor = EditorDesignTokens.Colors.accent
    track.addSubview(tunePillBarFill)
    tunePillView.addSubview(labels)
    tunePillView.addSubview(track)
    NSLayoutConstraint.activate([
      labels.topAnchor.constraint(equalTo: tunePillView.topAnchor, constant: 8),
      labels.leadingAnchor.constraint(equalTo: tunePillView.leadingAnchor, constant: 14),
      labels.trailingAnchor.constraint(equalTo: tunePillView.trailingAnchor, constant: -14),
      track.topAnchor.constraint(equalTo: labels.bottomAnchor, constant: 6),
      track.leadingAnchor.constraint(equalTo: tunePillView.leadingAnchor, constant: 14),
      track.trailingAnchor.constraint(equalTo: tunePillView.trailingAnchor, constant: -14),
      track.heightAnchor.constraint(equalToConstant: 3),
      track.bottomAnchor.constraint(equalTo: tunePillView.bottomAnchor, constant: -9),
    ])

    // Mockup look: a dark see-through card in the middle of the screen,
    // each row "Name ……… value", the current one filled blue.
    tuneListView.axis = .vertical
    tuneListView.spacing = 2
    tuneListView.isLayoutMarginsRelativeArrangement = true
    tuneListView.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    // Brightness / Contrast / Saturation … in one Liquid Glass container.
    GlassSurfaceView.install(behind: tuneListView, shape: .rounded(22))
    tuneListView.isUserInteractionEnabled = false
    tuneListView.alpha = 0
    tuneListRows = Self.tuneOrder.enumerated().map { index, entry in
      let title = entry.1
      let row = UIView()
      row.layer.cornerRadius = 12
      row.tag = index
      row.isUserInteractionEnabled = true
      row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapTuneRow(_:))))
      let name = UILabel()
      name.text = title
      name.font = .systemFont(ofSize: 15)
      name.textColor = EditorDesignTokens.Colors.textPrimary
      let value = UILabel()
      value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
      value.textColor = EditorDesignTokens.Colors.textSecondary
      value.textAlignment = .right
      for label in [name, value] {
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
      }
      NSLayoutConstraint.activate([
        row.widthAnchor.constraint(equalToConstant: 220),
        row.heightAnchor.constraint(equalToConstant: 38),
        name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
        name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        value.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
        value.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      ])
      tuneListView.addArrangedSubview(row)
      return (row, name, value)
    }
    view.addSubview(tuneSurfaceView)
    view.addSubview(tunePillView)
    view.addSubview(tuneListView)
    setUpTuneBottomBar()
    setUpVideoMiniScrubber()
    setUpFullScreenToolPanels()
  }

  private func setUpFullScreenToolPanels() {
    guard !isStoryMode else { return }
    effectPanel.useBottomActionBar(title: "Filters", accessoryImageName: "tool_adjust", accessoryLabel: "Strength and saturation") { [weak self] in
      guard let self, self.selectedFilter != .original else { return }
      UISelectionFeedbackGenerator().selectionChanged()
      self.setFilterEditing(!self.isEditingFilter)
    }
    textStylePanel.useBottomActionBar(title: "Text")
    if mediaType != "image" {
      // Video redesign: Music is full screen too; ✕ puts back the track
      // and volumes it had when opened.
      musicPanel.useBottomActionBar(title: "Music")
      musicPanel.onCancel = { [weak self] in self?.cancelMusicSession() }
    }
    filterNameLabel.font = .systemFont(ofSize: 14, weight: .medium)
    filterNameLabel.textColor = EditorDesignTokens.Colors.textSecondary
    filterNameLabel.textAlignment = .center
    filterNameLabel.text = selectedFilter.rawValue
    filterNameLabel.isHidden = true
    filterNameLabel.translatesAutoresizingMaskIntoConstraints = false
    filterNameLabel.textColor = EditorDesignTokens.Colors.textPrimary
    view.addSubview(filterNameLabel)
    // On a small glass pill.
    filterNameGlass.translatesAutoresizingMaskIntoConstraints = false
    filterNameGlass.isHidden = true
    view.insertSubview(filterNameGlass, belowSubview: filterNameLabel)
    NSLayoutConstraint.activate([
      filterNameGlass.leadingAnchor.constraint(equalTo: filterNameLabel.leadingAnchor, constant: -16),
      filterNameGlass.trailingAnchor.constraint(equalTo: filterNameLabel.trailingAnchor, constant: 16),
      filterNameGlass.topAnchor.constraint(equalTo: filterNameLabel.topAnchor, constant: -8),
      filterNameGlass.bottomAnchor.constraint(equalTo: filterNameLabel.bottomAnchor, constant: 8),
    ])
    NSLayoutConstraint.activate([
      filterNameLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      filterNameLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
    ])
  }

  private func setUpTuneBottomBar() {
    tuneBottomBar.backgroundColor = .clear
    tuneBottomBar.isHidden = true
    tuneBottomBar.translatesAutoresizingMaskIntoConstraints = false
    // ✕ · compare · Tune · list · ✓ on a floating glass capsule.
    let barGlass = GlassSurfaceView(shape: .capsule)
    barGlass.translatesAutoresizingMaskIntoConstraints = false
    tuneBottomBar.addSubview(barGlass)
    NSLayoutConstraint.activate([
      barGlass.leadingAnchor.constraint(equalTo: tuneBottomBar.leadingAnchor, constant: 8),
      barGlass.trailingAnchor.constraint(equalTo: tuneBottomBar.trailingAnchor, constant: -8),
      barGlass.topAnchor.constraint(equalTo: tuneBottomBar.topAnchor, constant: 2),
      barGlass.heightAnchor.constraint(equalToConstant: 56),
    ])
    let hairline = UIView()
    hairline.isHidden = true
    hairline.backgroundColor = EditorDesignTokens.Colors.divider
    hairline.translatesAutoresizingMaskIntoConstraints = false
    func iconButton(_ name: String, label: String, tint: UIColor = EditorDesignTokens.Colors.textPrimary) -> UIButton {
      let button = UIButton(type: .system)
      button.setImage(UIImage(named: name)?.withRenderingMode(.alwaysTemplate), for: .normal)
      button.tintColor = tint
      button.accessibilityLabel = label
      button.translatesAutoresizingMaskIntoConstraints = false
      button.widthAnchor.constraint(equalToConstant: 48).isActive = true
      button.heightAnchor.constraint(equalToConstant: 48).isActive = true
      return button
    }
    let cancel = iconButton("ui_close", label: "Cancel Tune")
    cancel.addAction(UIAction { [weak self] _ in self?.cancelToolSession() }, for: .touchUpInside)
    let apply = iconButton("ui_check", label: "Apply Tune", tint: EditorDesignTokens.Colors.selectedToolTint)
    apply.addAction(UIAction { [weak self] _ in self?.didTapToolsTab() }, for: .touchUpInside)
    let compare = iconButton("ui_compare", label: "Hold to compare with original")
    compare.addTarget(self, action: #selector(didPressCompare), for: .touchDown)
    compare.addTarget(self, action: #selector(didReleaseCompare), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    compare.isHidden = isStoryMode
    let title = UILabel()
    title.text = "Tune"
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.textColor = EditorDesignTokens.Colors.textPrimary
    let list = iconButton("tool_adjust", label: "Show settings list")
    list.addAction(UIAction { [weak self] _ in self?.toggleTuneListPinned() }, for: .touchUpInside)
    let center = UIStackView(arrangedSubviews: [compare, title, list])
    center.spacing = 14
    center.alignment = .center
    center.translatesAutoresizingMaskIntoConstraints = false
    for v in [hairline, cancel, apply, center] as [UIView] { tuneBottomBar.addSubview(v) }

    tuneHintLabel.text = "Swipe up / down to choose · left / right to adjust"
    tuneHintLabel.font = .systemFont(ofSize: 12)
    tuneHintLabel.textColor = EditorDesignTokens.Colors.textSecondary
    tuneHintLabel.textAlignment = .center
    tuneHintLabel.isHidden = true
    tuneHintLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tuneBottomBar)
    view.addSubview(tuneHintLabel)
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      tuneBottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tuneBottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tuneBottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      tuneBottomBar.topAnchor.constraint(equalTo: safe.bottomAnchor, constant: -64),
      hairline.topAnchor.constraint(equalTo: tuneBottomBar.topAnchor),
      hairline.leadingAnchor.constraint(equalTo: tuneBottomBar.leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: tuneBottomBar.trailingAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1),
      cancel.leadingAnchor.constraint(equalTo: tuneBottomBar.leadingAnchor, constant: 8),
      cancel.centerYAnchor.constraint(equalTo: tuneBottomBar.topAnchor, constant: 30),
      apply.trailingAnchor.constraint(equalTo: tuneBottomBar.trailingAnchor, constant: -8),
      apply.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
      center.centerXAnchor.constraint(equalTo: tuneBottomBar.centerXAnchor),
      center.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
      tuneHintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      tuneHintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      tuneHintLabel.bottomAnchor.constraint(equalTo: tuneBottomBar.topAnchor, constant: -10),
    ])
  }

  private func showTuneList(_ show: Bool) {
    if show {
      refreshTunePill()
      // Size it first (it isn't Auto Layout-placed), then centre it on the screen.
      let size = tuneListView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
      tuneListView.bounds = CGRect(origin: .zero, size: size)
      tuneListView.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
      tuneListView.layoutIfNeeded()
      view.bringSubviewToFront(tuneListView)
    }
    tuneListView.isUserInteractionEnabled = show && isTuneListPinned
    UIView.animate(withDuration: show ? 0.15 : 0.2) { self.tuneListView.alpha = show ? 1 : 0 }
  }

  private func toggleTuneListPinned() {
    UISelectionFeedbackGenerator().selectionChanged()
    isTuneListPinned.toggle()
    showTuneList(isTuneListPinned)
  }

  @objc private func didTapTuneRow(_ gesture: UITapGestureRecognizer) {
    guard isTuneListPinned, let index = gesture.view?.tag, Self.tuneOrder.indices.contains(index) else { return }
    tuneProperty = Self.tuneOrder[index].0
    isTuneListPinned = false
    showTuneList(false)
    didTapAdjustIcon(tuneProperty)
  }

  /// Shown while Adjust is open (not for Blur, which has its own on-photo
  /// controls). Re-placed every time — the canvas/stage may have moved.
  private func updateTuneUI() {
    defer { updateVideoMiniScrubber() }
    let active = isTuneActive
    tuneSurfaceView.isHidden = !active
    tunePillView.isHidden = !active
    tuneBottomBar.isHidden = !active
    tuneHintLabel.isHidden = !active
    // Story mode: the story's own close / undo / share / tool rail fade out
    // while Tune is open (its pill, sliders and ✕ / ✓ bar take their place).
    if isStoryMode {
      // The tool rail also steps aside while a bottom panel (stickers,
      // draw, filters, music…) is open — it drew over the panel and took
      // its ✓ taps on shorter phones.
      let panelOpen = selectedImageEditorTab != .tools
      for chrome in storyChromeViews {
        let hide = active || (chrome === storyChromeViews.last && panelOpen)
        chrome.alpha = hide ? 0 : 1
        chrome.isUserInteractionEnabled = !hide
      }
    }
    // Mockup Tune / Filters / Text screens: nothing else on top or bottom.
    if !isStoryMode {
      let fullScreen = active || isFullScreenPanelTool
      topBar.isHidden = fullScreen
      bottomTrayCardView.isHidden = fullScreen
      filterNameLabel.isHidden = selectedImageEditorTab != .effect
      filterNameGlass.isHidden = filterNameLabel.isHidden
      if !filterNameLabel.isHidden {
        view.bringSubviewToFront(filterNameGlass)
        view.bringSubviewToFront(filterNameLabel)
      }
    }
    // Blur selected from inside Adjust brings the panel back (and vice versa).
    editPanel.setPanelVisible(selectedImageEditorTab == .edit && !active, animated: true)
    guard active else {
      isTuneListPinned = false
      tuneListView.alpha = 0
      tuneListView.isUserInteractionEnabled = false
      return
    }
    refreshTunePill()
    let pillSize = tunePillView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    let width = max(pillSize.width, 170)
    tunePillView.bounds = CGRect(x: 0, y: 0, width: width, height: pillSize.height)
    tunePillView.center = CGPoint(x: view.bounds.midX, y: view.safeAreaInsets.top + 8 + pillSize.height / 2)
    tuneSurfaceView.transform = .identity
    tuneSurfaceView.frame = canvasClipContainerView.frame
    keepSafeAreaCoversOnTop()
    if isFilterStageActive { applyFilterStageFit(animated: false) } else { view.bringSubviewToFront(tuneSurfaceView) }
    for v in [tuneBottomBar, tuneHintLabel, tunePillView, tuneListView] as [UIView] { view.bringSubviewToFront(v) }
  }

  // MARK: - Video redesign: play + scrub row inside Tune and Filters

  private let videoMiniScrubRow = UIView()
  private let videoMiniPlayButton = UIButton(type: .system)
  private let videoMiniSlider = UISlider()
  private let videoMiniTimeLabel = UILabel()
  private var videoMiniAboveTuneConstraint: NSLayoutConstraint?
  private var videoMiniAbovePanelConstraint: NSLayoutConstraint?
  private var isDraggingVideoMiniSlider = false

  /// Lets the user play / scrub the video while Tune or Filters is open,
  /// to check the look on other frames.
  private func setUpVideoMiniScrubber() {
    guard mediaType != "image", !isStoryMode else { return }
    let row = videoMiniScrubRow
    row.translatesAutoresizingMaskIntoConstraints = false
    row.isHidden = true
    GlassSurfaceView.install(behind: row, shape: .capsule)

    videoMiniPlayButton.tintColor = .white
    videoMiniPlayButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold), forImageIn: .normal)
    videoMiniPlayButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
    videoMiniPlayButton.accessibilityLabel = "Play"
    videoMiniPlayButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)
    videoMiniPlayButton.addTarget(self, action: #selector(hapticLight), for: .touchUpInside)

    videoMiniSlider.minimumTrackTintColor = .white
    videoMiniSlider.maximumTrackTintColor = EditorDesignTokens.Colors.divider
    let thumbSize: CGFloat = 16
    let thumb = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize)).image { _ in
      UIColor.white.setFill()
      UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize)).fill()
    }
    videoMiniSlider.setThumbImage(thumb, for: .normal)
    videoMiniSlider.addTarget(self, action: #selector(videoMiniSliderBegan), for: .touchDown)
    videoMiniSlider.addTarget(self, action: #selector(videoMiniSliderChanged), for: .valueChanged)
    videoMiniSlider.addTarget(self, action: #selector(videoMiniSliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

    videoMiniTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    videoMiniTimeLabel.textColor = EditorDesignTokens.Colors.textSecondary
    videoMiniTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
    videoMiniTimeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    let stack = UIStackView(arrangedSubviews: [videoMiniPlayButton, videoMiniSlider, videoMiniTimeLabel])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(stack)
    view.addSubview(row)
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
      row.heightAnchor.constraint(equalToConstant: 40),
      stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
      stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: row.topAnchor),
      stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
      videoMiniPlayButton.widthAnchor.constraint(equalToConstant: 36),
      videoMiniPlayButton.heightAnchor.constraint(equalToConstant: 36),
    ])
    videoMiniAboveTuneConstraint = row.bottomAnchor.constraint(equalTo: tuneHintLabel.topAnchor, constant: -8)
    videoMiniAbovePanelConstraint = row.bottomAnchor.constraint(equalTo: effectPanel.topAnchor, constant: -8)
  }

  private func updateVideoMiniScrubber() {
    guard videoMiniScrubRow.superview != nil else { return }
    let inTune = isTuneActive
    let inFilters = selectedImageEditorTab == .effect
    videoMiniAboveTuneConstraint?.isActive = false
    videoMiniAbovePanelConstraint?.isActive = false
    videoMiniScrubRow.isHidden = !(inTune || inFilters)
    guard !videoMiniScrubRow.isHidden else { return }
    (inTune ? videoMiniAboveTuneConstraint : videoMiniAbovePanelConstraint)?.isActive = true
    videoMiniPlayButton.setImage(UIImage(systemName: isVideoPlaying ? "pause.fill" : "play.fill"), for: .normal)
    syncVideoMiniScrubber(current: combinedTimeForCurrentPlayback())
    view.bringSubviewToFront(videoMiniScrubRow)
  }

  private func syncVideoMiniScrubber(current: Double) {
    let total = combinedLayerDuration()
    videoMiniSlider.maximumValue = Float(max(total, 0.01))
    videoMiniSlider.value = Float(min(max(current, 0), total))
    let secs = max(0, Int(min(current, total)))
    videoMiniTimeLabel.text = String(format: "%d:%02d", secs / 60, secs % 60)
  }

  @objc private func videoMiniSliderBegan() {
    isDraggingVideoMiniSlider = true
  }

  @objc private func videoMiniSliderChanged() {
    let t = Double(videoMiniSlider.value)
    let secs = max(0, Int(t))
    videoMiniTimeLabel.text = String(format: "%d:%02d", secs / 60, secs % 60)
    seekCombinedTimeline(to: t)
  }

  @objc private func videoMiniSliderEnded() {
    isDraggingVideoMiniSlider = false
  }

  private func refreshTunePill() {
    let title = Self.tuneOrder.first { $0.0 == tuneProperty }?.1 ?? ""
    tunePillNameLabel.text = title
    guard let control = tuneSlider(for: tuneProperty) else { return }
    tunePillValueLabel.text = control.valueLabel?.text ?? "\(Int(control.slider.value * 100))"
    // Bar fills from the centre (0) toward the value's side.
    tunePillView.layoutIfNeeded()
    let trackWidth = tunePillBarFill.superview?.bounds.width ?? 0
    let v = CGFloat(control.slider.value)
    let fillWidth = abs(v) * trackWidth / 2
    tunePillBarFill.frame = CGRect(x: v >= 0 ? trackWidth / 2 : trackWidth / 2 - fillWidth, y: 0, width: fillWidth, height: 3)
    for (index, item) in tuneListRows.enumerated() {
      let property = Self.tuneOrder[index].0
      let on = property == tuneProperty
      // Selected row: the same soft light lozenge as the tool bar.
      item.row.backgroundColor = on ? UIColor.white.withAlphaComponent(0.16) : .clear
      item.name.font = .systemFont(ofSize: 15, weight: on ? .semibold : .regular)
      item.value.textColor = on ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.textSecondary
      item.value.text = tuneSlider(for: property)?.valueLabel?.text ?? "0"
    }
  }

  @objc private func handleTunePan(_ gesture: UIPanGestureRecognizer) {
    let t = gesture.translation(in: view)
    switch gesture.state {
    case .began:
      tuneSwipeMode = .undecided
      tuneSwipeStartIndex = Self.tuneOrder.firstIndex { $0.0 == tuneProperty } ?? 0
    case .changed:
      if tuneSwipeMode == .undecided {
        guard hypot(t.x, t.y) > 10 else { return }
        if abs(t.y) > abs(t.x) {
          tuneSwipeMode = .choose
          isTuneListPinned = false
          showTuneList(true)
        } else {
          tuneSwipeMode = .adjust
          guard let control = tuneSlider(for: tuneProperty) else { return }
          tuneSwipeStartValue = control.slider.value
          control.slider.sendActions(for: .touchDown) // starts the slider's undo step
        }
      }
      switch tuneSwipeMode {
      case .choose:
        let index = min(max(tuneSwipeStartIndex + Int((t.y / Self.tuneChooseStep).rounded()), 0), Self.tuneOrder.count - 1)
        if Self.tuneOrder[index].0 != tuneProperty {
          tuneProperty = Self.tuneOrder[index].0
          UISelectionFeedbackGenerator().selectionChanged()
          refreshTunePill()
        }
      case .adjust:
        guard let control = tuneSlider(for: tuneProperty) else { return }
        // A full-width swipe moves the value by about 1.6 (of -1…1).
        let width = max(tuneSurfaceView.bounds.width, 1)
        let value = min(max(tuneSwipeStartValue + Float(t.x / width) * 1.6, -1), 1)
        control.slider.value = value
        control.slider.sendActions(for: .valueChanged)
        refreshTunePill()
      case .undecided:
        break
      }
    case .ended, .cancelled, .failed:
      if tuneSwipeMode == .adjust {
        tuneSlider(for: tuneProperty)?.slider.sendActions(for: .touchUpInside) // records one undo step
      } else if tuneSwipeMode == .choose {
        showTuneList(false)
        didTapAdjustIcon(tuneProperty) // also selects its slider (kept in sync)
      }
      tuneSwipeMode = .undecided
      refreshTunePill()
    default:
      break
    }
  }

  /// arrives at one of the 3 snap points (min/center/max) — matching the
  /// spec's "selection-changed haptic on slider snap points (0, 50, 100)"
  /// applied to this slider's own -1...1 range.
  private static func makeAdjustmentRow(
    title: String,
    onChange: @escaping (Float) -> Void,
    pushUndo: @escaping (_ undo: @escaping () -> Void, _ redo: @escaping () -> Void) -> Void
  ) -> UIStackView {
    let label = UILabel()
    label.text = title
    label.textColor = EditorDesignTokens.Colors.textPrimary
    label.font = .systemFont(ofSize: 12)
    label.setContentHuggingPriority(.required, for: .horizontal)

    let valueLabel = UILabel()
    valueLabel.text = "0"
    valueLabel.textColor = EditorDesignTokens.Colors.textSecondary
    valueLabel.font = EditorDesignTokens.Typography.sliderValue
    valueLabel.textAlignment = .right
    valueLabel.setContentHuggingPriority(.required, for: .horizontal)
    valueLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true

    let slider = UISlider()
    slider.minimumValue = -1
    slider.maximumValue = 1
    slider.value = 0
    slider.setMinimumTrackImage(makeSliderTrackImage(color: EditorDesignTokens.Colors.accent), for: .normal)
    slider.setMaximumTrackImage(makeSliderTrackImage(color: EditorDesignTokens.Colors.divider), for: .normal)
    slider.setThumbImage(makeSliderThumbImage(), for: .normal)

    var previousValue: Float = 0
    slider.addAction(UIAction { [weak slider] _ in
      guard let value = slider?.value else { return }
      onChange(value)

      let intValue = Int(value * 100)
      valueLabel.text = intValue > 0 ? "+\(intValue)" : "\(intValue)"

      let snapPoints: [Float] = [-1, 0, 1]
      let snapThreshold: Float = 0.04
      for snap in snapPoints {
        let wasNear = abs(previousValue - snap) <= snapThreshold
        let isNear = abs(value - snap) <= snapThreshold
        if isNear && !wasNear {
          UISelectionFeedbackGenerator().selectionChanged()
          break
        }
      }
      previousValue = value
    }, for: .valueChanged)

    // Undo/redo for this slider: snapshot the value once when the drag
    // starts (not on every .valueChanged tick, which would push one undo
    // entry per pixel of movement), then push a single entry comparing
    // that snapshot to wherever the drag ended up. Restoring re-drives
    // the slider through `.valueChanged` (rather than duplicating the
    // property-set/label/haptic logic above) since setting `.value`
    // programmatically does not fire UIControl actions on its own.
    var dragStartValue: Float = 0
    slider.addAction(UIAction { [weak slider] _ in dragStartValue = slider?.value ?? 0 }, for: .touchDown)
    let commitDrag = UIAction { [weak slider] _ in
      guard let slider, dragStartValue != slider.value else { return }
      let oldValue = dragStartValue
      let newValue = slider.value
      pushUndo(
        { [weak slider] in slider?.value = oldValue; slider?.sendActions(for: .valueChanged) },
        { [weak slider] in slider?.value = newValue; slider?.sendActions(for: .valueChanged) }
      )
    }
    slider.addAction(commitDrag, for: .touchUpInside)
    slider.addAction(commitDrag, for: .touchUpOutside)

    let stack = UIStackView(arrangedSubviews: [label, slider, valueLabel])
    stack.axis = .horizontal
    stack.spacing = 8
    return stack
  }

  /// Label + slider + value readout for one Filters-panel setting in
  /// `minValue...1` (shown x100). Haptic tick on reaching `defaultValue`;
  /// one undo entry per drag, same as the Adjust sliders.
  private func makeFilterSliderRow(
    title: String,
    minValue: Float,
    defaultValue: Float,
    read: @escaping () -> Float,
    write: @escaping (Float) -> Void
  ) -> UIView {
    let label = UILabel()
    label.text = title
    label.textColor = EditorDesignTokens.Colors.textPrimary
    label.font = .systemFont(ofSize: 12)
    // Fixed width so the three sliders line up.
    label.widthAnchor.constraint(equalToConstant: 64).isActive = true

    let valueLabel = UILabel()
    valueLabel.textColor = EditorDesignTokens.Colors.textSecondary
    valueLabel.font = EditorDesignTokens.Typography.sliderValue
    valueLabel.textAlignment = .right
    valueLabel.setContentHuggingPriority(.required, for: .horizontal)
    valueLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true

    let slider = UISlider()
    slider.minimumValue = minValue
    slider.maximumValue = 1
    slider.value = read()
    slider.setMinimumTrackImage(MediaEditorViewController.makeSliderTrackImage(color: EditorDesignTokens.Colors.accent), for: .normal)
    slider.setMaximumTrackImage(MediaEditorViewController.makeSliderTrackImage(color: EditorDesignTokens.Colors.divider), for: .normal)
    slider.setThumbImage(MediaEditorViewController.makeSliderThumbImage(), for: .normal)

    slider.addAction(UIAction { [weak self, weak slider] _ in
      guard let self, let slider else { return }
      let wasDefault = abs(read() - defaultValue) < 0.005
      write(slider.value)
      valueLabel.text = "\(Int((slider.value * 100).rounded()))"
      if abs(slider.value - defaultValue) < 0.005 && !wasDefault { UISelectionFeedbackGenerator().selectionChanged() }
      self.refreshPreview()
    }, for: .valueChanged)

    var dragStartValue = defaultValue
    slider.addAction(UIAction { _ in dragStartValue = read() }, for: .touchDown)
    let commitDrag = UIAction { [weak self] _ in
      let oldValue = dragStartValue
      let newValue = read()
      guard let self, oldValue != newValue else { return }
      self.pushUndo(
        undo: { [weak self] in
          write(oldValue)
          self?.refreshPreview()
          self?.syncFilterStrengthControl()
        },
        redo: { [weak self] in
          write(newValue)
          self?.refreshPreview()
          self?.syncFilterStrengthControl()
        }
      )
    }
    slider.addAction(commitDrag, for: .touchUpInside)
    slider.addAction(commitDrag, for: .touchUpOutside)

    let stack = UIStackView(arrangedSubviews: [label, slider, valueLabel])
    stack.axis = .horizontal
    stack.spacing = 8
    stack.alignment = .center
    filterSliderRows.append(FilterSliderRow(view: stack, slider: slider, valueLabel: valueLabel, read: read))
    return stack
  }

  private static func makeSliderTrackImage(color: UIColor) -> UIImage {
    let height = EditorDesignTokens.Spacing.sliderTrackHeight
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: height, height: height))
    let image = renderer.image { _ in
      color.setFill()
      UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: height, height: height), cornerRadius: height / 2).fill()
    }
    return image.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: height / 2, bottom: 0, right: height / 2))
  }

  private static func makeSliderThumbImage() -> UIImage {
    let diameter = EditorDesignTokens.Spacing.sliderThumbDiameter
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter))
    return renderer.image { _ in
      EditorDesignTokens.Colors.textPrimary.setFill()
      UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
    }
  }

  // MARK: - Re-edit project (reopen an exported photo with layers editable)

  /// Set at init when reopening a previous edit; consumed (once) as soon as
  /// the photo has loaded and the canvas has its final size.
  private var pendingEditProject: MediaEditorEditProject?
  /// Reused across re-edits so the same project folder is updated in place.
  private var editProjectID: String?
  /// Set in viewDidAppear — see restoreEditProjectIfNeeded.
  private var hasAppeared = false
  /// JSON for the bridge result — set right before onDone for a photo export.
  private(set) var exportedEditProjectJSON: String?

  /// Snapshots the editor into a project folder + JSON. Nil on any failure
  /// (the export still succeeds; the photo just won't be re-editable).
  private func saveEditProject() -> String? {
    let canvasWidth = imageView.bounds.width
    guard mediaType == "image", canvasWidth > 0 else { return nil }
    let fm = FileManager.default
    let id = editProjectID ?? UUID().uuidString
    let directory = MediaEditorEditProject.directory(for: id)
    do {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      // Source: copied in once; on a re-edit it already lives here.
      let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
      let sourceFileName = "source.\(ext)"
      let projectSource = directory.appendingPathComponent(sourceFileName)
      if sourceURL.standardizedFileURL.path != projectSource.standardizedFileURL.path {
        if fm.fileExists(atPath: projectSource.path) { try fm.removeItem(at: projectSource) }
        try fm.copyItem(at: sourceURL, to: projectSource)
      }
      // Overlay PNGs are rewritten every save.
      for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasPrefix("overlay_") {
        try? fm.removeItem(at: directory.appendingPathComponent(file))
      }

      var project = MediaEditorEditProject(id: id, sourceFileName: sourceFileName, canvasWidth: Double(canvasWidth))
      project.imageTranslationX = Double(currentTranslation.x)
      project.imageTranslationY = Double(currentTranslation.y)
      project.imageScale = Double(currentScale)
      project.imageRotation = Double(currentRotation)
      project.filter = selectedFilter.rawValue
      project.filterStrength = filterStrength
      project.filterSaturation = filterSaturation
      project.filterSharpness = filterSharpness
      project.adjustments = currentAdjustments
      project.blur = blur

      project.strokes = drawingCanvasView.strokes.map { stroke in
        MediaEditorEditProject.Stroke(
          points: stroke.points.flatMap { [Double($0.x), Double($0.y)] },
          color: .init(stroke.color),
          width: Double(stroke.widthPoints),
          brush: stroke.brushType.rawValue,
          seed: stroke.seed,
          shape: stroke.shape?.rawValue
        )
      }

      // Deleted layers are only hidden (so undo can bring them back).
      let allLayers: [UIView] = (textLayerViews as [UIView]) + (stickerLayerViews as [UIView]) + (imageOverlayLayerViews as [UIView])
      let visible = allLayers
        .filter { !$0.isHidden && $0.superview === view }
        .sorted { (view.subviews.firstIndex(of: $0) ?? 0) < (view.subviews.firstIndex(of: $1) ?? 0) }
      NSLog("[MediaEditor] save: imageView.frame=%@ clip.frame=%@ imgT=%@ imgS=%.3f",
            "\(imageView.frame)", "\(canvasClipContainerView.frame)", "\(currentTranslation)", Double(currentScale))
      for (index, layerView) in visible.enumerated() {
        if let l = layerView as? EditableLayerView {
          NSLog("[MediaEditor] save layer %d: t=%@ s=%.3f r=%.3f center=%@ bounds=%@",
                index, "\(l.currentTranslation)", Double(l.currentScale), Double(l.currentRotation),
                "\(layerView.center)", "\(layerView.bounds.size)")
        }
        if let label = layerView as? EditableTextLayerView {
          var layer = MediaEditorEditProject.Layer(
            kind: .text,
            translationX: Double(label.currentTranslation.x),
            translationY: Double(label.currentTranslation.y),
            scale: Double(label.currentScale),
            rotation: Double(label.currentRotation)
          )
          if let locationName = label.locationName {
            layer.kind = .location
            layer.locationName = locationName
            layer.locationStyle = label.locationStyle
            layer.infoKind = label.infoKind == "location" ? nil : label.infoKind
            layer.infoValue = label.infoValue
            layer.latitude = label.locationLatitude
            layer.longitude = label.locationLongitude
          } else if let assetName = label.stickerAssetName {
            layer.kind = .sticker
            layer.assetName = assetName
            let stickerStyle = label.stickerStyle
            layer.opacity = Double(stickerStyle.opacity)
            layer.outline = Double(stickerStyle.outline)
            layer.shadow = Double(stickerStyle.shadow)
            layer.flipX = stickerStyle.flipX
            layer.flipY = stickerStyle.flipY
          } else {
            let style = label.layerStyle ?? TextLayerStyle()
            layer.text = label.text ?? ""
            layer.fontId = style.fontId
            layer.color = .init(style.color)
            layer.alignment = style.alignment.rawValue
            layer.isBold = style.isBold
            layer.isItalic = style.isItalic
            layer.isUnderlined = style.isUnderlined
            layer.textBackground = style.background.rawValue
            layer.textSize = Double(style.size)
            layer.outline = Double(style.outline)
            layer.shadow = Double(style.shadow)
            layer.opacity = Double(style.opacity)
            layer.stretchX = Double(style.stretchX)
            layer.stretchY = Double(style.stretchY)
            layer.arch = Double(style.arch)
          }
          project.layers.append(layer)
        } else if let overlay = layerView as? EditableImageLayerView, let image = overlay.baseImage ?? overlay.image,
                  let data = image.pngData() {
          let fileName = "overlay_\(index).png"
          try data.write(to: directory.appendingPathComponent(fileName))
          var layer = MediaEditorEditProject.Layer(
            kind: .image,
            translationX: Double(overlay.currentTranslation.x),
            translationY: Double(overlay.currentTranslation.y),
            scale: Double(overlay.currentScale),
            rotation: Double(overlay.currentRotation)
          )
          layer.imageFileName = fileName
          layer.width = Double(overlay.bounds.width)
          layer.height = Double(overlay.bounds.height)
          layer.overlay = .init(overlay.overlayStyle, strokes: overlay.eraseStrokes)
          project.layers.append(layer)
        }
      }
      editProjectID = id
      NSLog("[MediaEditor] saveEditProject: canvasW=%.1f layers=%d strokes=%d", Double(canvasWidth), project.layers.count, project.strokes.count)
      return project.encodedJSON()
    } catch {
      NSLog("[MediaEditor] saveEditProject failed: %@", "\(error)")
      return nil
    }
  }

  /// Rebuilds the saved edit: image pan/zoom, filter + adjustments, drawing
  /// and every layer, all still editable. Not undoable — it's the
  /// starting state, so the undo stack stays empty.
  private func restoreEditProjectIfNeeded() {
    // Both the photo AND the final layout are needed: before viewDidAppear
    // the safe-area insets aren't applied yet, so the canvas is still
    // taller than its final size and layers restored then end up shifted
    // once it shrinks. Called from both places; whichever comes last wins.
    guard hasAppeared, baseImage != nil, let project = pendingEditProject else { return }
    pendingEditProject = nil
    view.layoutIfNeeded()
    let canvasWidth = imageView.bounds.width
    guard canvasWidth > 0 else { return }
    // Positions were saved in canvas points; rescale if the canvas differs.
    let k = project.canvasWidth > 0 ? canvasWidth / CGFloat(project.canvasWidth) : 1
    NSLog("[MediaEditor] restoreEditProject: savedCanvasW=%.1f canvasW=%.1f k=%.3f layers=%d strokes=%d",
          project.canvasWidth, Double(canvasWidth), Double(k), project.layers.count, project.strokes.count)
    NSLog("[MediaEditor] restore: imageView.frame=%@ clip.frame=%@", "\(imageView.frame)", "\(canvasClipContainerView.frame)")

    currentTranslation = CGPoint(x: CGFloat(project.imageTranslationX) * k, y: CGFloat(project.imageTranslationY) * k)
    currentScale = CGFloat(project.imageScale)
    currentRotation = CGFloat(project.imageRotation)
    updateImageTransform()

    applyFilterStateSnapshot(ClipFilterState(
      filter: PhotoFilter(rawValue: project.filter) ?? .original,
      filterStrength: project.filterStrength,
      filterSaturation: project.filterSaturation ?? 0,
      filterSharpness: project.filterSharpness ?? 0,
      adjustments: project.adjustments
    ))
    blur = project.blur ?? PhotoBlur()
    syncBlurControls()
    refreshPreview()

    for saved in project.strokes {
      var points: [CGPoint] = []
      var i = 0
      while i + 1 < saved.points.count {
        points.append(CGPoint(x: CGFloat(saved.points[i]) * k, y: CGFloat(saved.points[i + 1]) * k))
        i += 2
      }
      let brush = DrawingCanvasView.BrushType(rawValue: saved.brush) ?? .pen
      drawingCanvasView.addStroke(DrawingCanvasView.Stroke(
        points: points, color: saved.color.uiColor, widthPoints: CGFloat(saved.width) * k,
        brushType: brush, seed: saved.seed ?? 0,
        shape: saved.shape.flatMap(DrawingCanvasView.ShapeType.init(rawValue:))
      ))
    }

    for saved in project.layers {
      restoreLayer(saved, scaleFactor: k, directory: project.directory)
    }
    keepSafeAreaCoversOnTop()
  }

  private func restoreLayer(_ saved: MediaEditorEditProject.Layer, scaleFactor k: CGFloat, directory: URL) {
    let layerView: EditableLayerView
    switch saved.kind {
    case .text, .sticker, .location:
      let label = EditableTextLayerView()
      switch saved.kind {
      case .location:
        label.infoKind = saved.infoKind ?? "location"
        label.infoValue = saved.infoValue
        applyLocationSticker(to: label, name: saved.locationName ?? "", style: saved.locationStyle ?? 0)
        label.locationLatitude = saved.latitude
        label.locationLongitude = saved.longitude
      case .sticker:
        guard let assetName = saved.assetName, let image = StickerCatalog.image(named: assetName) else { return }
        label.applyStickerImage(image, assetName: assetName)
        var stickerStyle = StickerStyle()
        stickerStyle.opacity = CGFloat(saved.opacity ?? 1)
        stickerStyle.outline = CGFloat(saved.outline ?? 0)
        stickerStyle.shadow = CGFloat(saved.shadow ?? 0)
        stickerStyle.flipX = saved.flipX ?? false
        stickerStyle.flipY = saved.flipY ?? false
        label.applyStickerStyle(stickerStyle)
      default:
        var style = TextLayerStyle()
        style.fontId = saved.fontId ?? TextFontCatalog.optionId(legacyFontName: saved.fontName)
        style.color = saved.color?.uiColor ?? .white
        style.alignment = NSTextAlignment(rawValue: saved.alignment ?? NSTextAlignment.center.rawValue) ?? .center
        style.isBold = saved.isBold ?? false
        style.isItalic = saved.isItalic ?? false
        style.isUnderlined = saved.isUnderlined ?? false
        style.background = TextBackgroundMode(rawValue: saved.textBackground ?? 0) ?? .none
        style.size = CGFloat(saved.textSize ?? 1)
        style.outline = CGFloat(saved.outline ?? 0)
        style.shadow = CGFloat(saved.shadow ?? 0)
        style.opacity = CGFloat(saved.opacity ?? 1)
        style.stretchX = CGFloat(saved.stretchX ?? 1)
        style.stretchY = CGFloat(saved.stretchY ?? 1)
        style.arch = CGFloat(saved.arch ?? 0)
        label.applyText(saved.text ?? "", style: style)
      }
      label.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(label)
      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: Self.newLayerVerticalOffset),
      ])
      label.enableGestures(in: view)
      if saved.kind == .text {
        textLayerViews.append(label)
      } else {
        stickerLayerViews.append(label)
      }
      layerView = label
    case .image:
      guard let fileName = saved.imageFileName,
            let image = UIImage(contentsOfFile: directory.appendingPathComponent(fileName).path)
      else { return }
      let overlay = EditableImageLayerView()
      let restored = saved.overlay?.restored() ?? (OverlayStyle(), [])
      overlay.applyOverlay(base: image, style: restored.0, strokes: restored.1)
      overlay.contentMode = .scaleAspectFit
      overlay.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(overlay)
      NSLayoutConstraint.activate([
        overlay.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
        overlay.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: Self.newLayerVerticalOffset),
        overlay.widthAnchor.constraint(equalToConstant: CGFloat(saved.width ?? Double(Self.overlayInitialMaxDimension))),
        overlay.heightAnchor.constraint(equalToConstant: CGFloat(saved.height ?? Double(Self.overlayInitialMaxDimension))),
      ])
      overlay.enableGestures(in: view)
      imageOverlayLayerViews.append(overlay)
      layerView = overlay
    }
    wireLayerCallbacks(layerView)
    registerLayerTiming(layerView)
    // Lay the new layer out FIRST: applyInitialTransform clamps the
    // translation against the layer's own `center`/`bounds`, which are
    // still zero before layout — clamping then moved restored layers.
    view.layoutIfNeeded()
    // Sizes above are the saved (unscaled) ones, so canvas rescale goes
    // into translation + scale only, like rescaleForCanvasResize does.
    layerView.applyInitialTransform(
      translation: CGPoint(x: CGFloat(saved.translationX) * k, y: CGFloat(saved.translationY) * k),
      scale: CGFloat(saved.scale) * k,
      rotation: CGFloat(saved.rotation)
    )
    NSLog("[MediaEditor] restore layer %@: wanted t=(%.1f,%.1f) got t=%@ s=%.3f center=%@ bounds=%@%@",
          saved.kind.rawValue, saved.translationX * Double(k), saved.translationY * Double(k),
          "\(layerView.currentTranslation)", Double(layerView.currentScale), "\(layerView.center)", "\(layerView.bounds.size)",
          abs(Double(layerView.currentTranslation.x) - saved.translationX * Double(k)) > 0.5
            || abs(Double(layerView.currentTranslation.y) - saved.translationY * Double(k)) > 0.5 ? "  <-- CLAMPED" : "")
    // Same as addTextLayer: re-set after layout so the clip mask updates.
    let currentBoundsProvider = layerView.boundsProvider
    layerView.boundsProvider = currentBoundsProvider
  }

  // MARK: - Auto-enhance (photo only)

  private var currentAutoEnhanceValues: PhotoAutoEnhance {
    PhotoAutoEnhance(brightness: brightness, contrast: contrast, saturation: saturation, warmth: warmth)
  }

  private func applyAutoEnhanceValues(_ values: PhotoAutoEnhance) {
    brightness = values.brightness
    contrast = values.contrast
    saturation = values.saturation
    warmth = values.warmth
    // Re-drives each slider (and its value label) from the vars above.
    syncAdjustSlidersToCurrentValues()
    refreshPreview()
  }

  /// One tap: balanced Brightness/Contrast/Saturation/Warm from the photo's
  /// own statistics. Tapping again (with those values untouched) restores
  /// what was there before. Undoable either way.
  private func didTapAutoEnhance() {
    let current = currentAutoEnhanceValues
    let target: PhotoAutoEnhance
    if let applied = autoEnhanceApplied, let backup = autoEnhanceBackup, applied == current {
      target = backup
    } else {
      guard let baseImage else { return }
      let cgImage = baseImage.cgImage ?? CIImage(image: baseImage).flatMap { ciContext.createCGImage($0, from: $0.extent) }
      guard let cgImage, let computed = PhotoAutoEnhance.compute(from: cgImage) else { return }
      autoEnhanceBackup = current
      autoEnhanceApplied = computed
      target = computed
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    guard target != current else {
      updateAutoEnhanceButton()
      return
    }
    applyAutoEnhanceValues(target)
    pushUndo(
      undo: { [weak self] in self?.applyAutoEnhanceValues(current) },
      redo: { [weak self] in self?.applyAutoEnhanceValues(target) }
    )
  }

  private func updateAutoEnhanceButton() {
    guard let button = autoEnhanceButton else { return }
    let isOn = autoEnhanceApplied != nil && autoEnhanceApplied == currentAutoEnhanceValues
    button.configuration?.baseForegroundColor = isOn ? EditorDesignTokens.Colors.accent : EditorDesignTokens.Colors.textSecondary
    button.accessibilityTraits = isOn ? [.button, .selected] : .button
  }

  // MARK: - Blur / tilt-shift (photo only)

  private func setUpBlurOverlay() {
    guard mediaType == "image" else { return }
    blurOverlayView.isHidden = true
    blurOverlayView.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(blurOverlayView, aboveSubview: drawingCanvasView)
    // Same untransformed canvas box as drawingCanvasView; photo geometry
    // goes through imageView.convert, which accounts for pan/zoom/rotate.
    NSLayoutConstraint.activate([
      blurOverlayView.topAnchor.constraint(equalTo: imageView.topAnchor),
      blurOverlayView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
      blurOverlayView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
      blurOverlayView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
    ])
    blurOverlayView.photoSize = { [weak self] in self?.imageView.bounds.size ?? .zero }
    blurOverlayView.toOverlay = { [weak self] point in
      guard let self else { return point }
      return self.imageView.convert(point, to: self.blurOverlayView)
    }
    blurOverlayView.toPhoto = { [weak self] point in
      guard let self else { return point }
      return self.imageView.convert(point, from: self.blurOverlayView)
    }
    blurOverlayView.photoRotation = { [weak self] in self?.currentRotation ?? 0 }
    blurOverlayView.photoScale = { [weak self] in self?.currentScale ?? 1 }
    blurOverlayView.onChange = { [weak self] newBlur in
      self?.blur = newBlur
      self?.refreshPreview()
    }
    blurOverlayView.onGestureEnded = { [weak self] before, after in
      self?.pushBlurUndo(from: before, to: after)
    }
  }

  /// Guide + gestures only while the Blur tool is open with a mode on.
  private func updateBlurOverlay() {
    guard mediaType == "image" else { return }
    let visible = selectedImageEditorTab == .edit && selectedAdjustProperty == .blur && blur.mode != .off
    blurOverlayView.isHidden = !visible
    blurOverlayView.isUserInteractionEnabled = visible
    guard visible else { return }
    blurOverlayView.blur = blur
    // Above any text/sticker layers so it wins the touches, but still
    // below the panel chrome.
    view.bringSubviewToFront(blurOverlayView)
    view.bringSubviewToFront(editPanel)
    keepSafeAreaCoversOnTop()
    blurOverlayView.setNeedsLayout()
  }

  private func syncBlurControls() {
    for (mode, button) in blurModeButtons {
      button.isSelected = mode == blur.mode
      button.configuration?.baseBackgroundColor = mode == blur.mode ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.elevatedSurface
      button.configuration?.baseForegroundColor = mode == blur.mode ? EditorDesignTokens.Colors.canvasBackground : EditorDesignTokens.Colors.textPrimary
    }
    blurStrengthSlider?.value = Float(blur.strength)
    blurStrengthSlider?.isEnabled = blur.mode != .off
    blurStrengthSlider?.alpha = blur.mode != .off ? 1 : 0.4
    updateBlurOverlay()
  }

  private func applyBlur(_ newBlur: PhotoBlur) {
    blur = newBlur
    syncBlurControls()
    refreshPreview()
  }

  private func pushBlurUndo(from old: PhotoBlur, to new: PhotoBlur) {
    guard old != new else { return }
    pushUndo(
      undo: { [weak self] in self?.applyBlur(old) },
      redo: { [weak self] in self?.applyBlur(new) }
    )
  }

  /// Off / Radial / Linear pills + strength slider, in the Adjust panel's
  /// single-row detail slot.
  private func makeBlurRow() -> UIStackView {
    var pills: [UIView] = []
    for (mode, title) in [(PhotoBlur.Mode.off, "Off"), (.radial, "Radial"), (.linear, "Linear")] {
      var config = UIButton.Configuration.filled()
      config.title = title
      config.cornerStyle = .capsule
      config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = .systemFont(ofSize: 12, weight: .semibold)
        return outgoing
      }
      let button = UIButton(configuration: config)
      button.setContentHuggingPriority(.required, for: .horizontal)
      button.setContentCompressionResistancePriority(.required, for: .horizontal)
      button.addAction(UIAction { [weak self] _ in
        guard let self, self.blur.mode != mode else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        let old = self.blur
        var new = self.blur
        new.mode = mode
        self.applyBlur(new)
        self.pushBlurUndo(from: old, to: new)
      }, for: .touchUpInside)
      blurModeButtons[mode] = button
      pills.append(button)
    }

    let slider = UISlider()
    slider.minimumValue = 0
    slider.maximumValue = 1
    slider.value = Float(blur.strength)
    slider.setMinimumTrackImage(MediaEditorViewController.makeSliderTrackImage(color: EditorDesignTokens.Colors.accent), for: .normal)
    slider.setMaximumTrackImage(MediaEditorViewController.makeSliderTrackImage(color: EditorDesignTokens.Colors.divider), for: .normal)
    slider.setThumbImage(MediaEditorViewController.makeSliderThumbImage(), for: .normal)
    slider.addAction(UIAction { [weak self, weak slider] _ in
      guard let self, let slider else { return }
      self.blur.strength = Double(slider.value)
      self.refreshPreview()
    }, for: .valueChanged)
    var dragStart = blur
    slider.addAction(UIAction { [weak self] _ in dragStart = self?.blur ?? PhotoBlur() }, for: .touchDown)
    let commit = UIAction { [weak self] _ in
      guard let self else { return }
      self.pushBlurUndo(from: dragStart, to: self.blur)
    }
    slider.addAction(commit, for: .touchUpInside)
    slider.addAction(commit, for: .touchUpOutside)
    blurStrengthSlider = slider

    let stack = UIStackView(arrangedSubviews: pills + [slider])
    stack.axis = .horizontal
    stack.spacing = 6
    stack.alignment = .center
    stack.setCustomSpacing(12, after: pills[pills.count - 1])
    syncBlurControls()
    return stack
  }

  // MARK: - Before/after compare (image editor, hold to see original)

  /// Top-bar compare button; nil outside the regular image editor.
  private var compareButton: UIButton?
  /// Edited preview stashed while the original is shown, restored on release.
  private var compareStashedImage: UIImage?
  /// Views hidden while the original is shown — only those that were visible.
  private var compareHiddenViews: [UIView] = []
  private var isShowingOriginal = false

  /// Shows the untouched photo: no filter/adjustments (vignette and sharpen
  /// are baked into the edited preview, so they go too), and no text,
  /// stickers, overlay photos or drawing. Crop is kept, since the canvas
  /// box itself is the crop.
  @objc private func didPressCompare() {
    guard !isShowingOriginal else { return }
    defer { scheduleFilterStageRefresh() }
    isShowingOriginal = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if let baseImage {
      compareStashedImage = imageView.image
      imageView.image = baseImage
    }
    var toHide: [UIView] = []
    toHide += textLayerViews as [UIView]
    toHide += stickerLayerViews as [UIView]
    toHide += imageOverlayLayerViews as [UIView]
    toHide.append(drawingCanvasView)
    if let layerActionToolbar { toHide.append(layerActionToolbar) }
    for v in toHide where !v.isHidden {
      v.isHidden = true
      compareHiddenViews.append(v)
    }
    updateBlurCover()
    // Video: the per-frame composition reads isShowingOriginal; re-render.
    if mediaType != "image" { refreshPreview() }
  }

  @objc private func didReleaseCompare() {
    guard isShowingOriginal else { return }
    defer { scheduleFilterStageRefresh() }
    isShowingOriginal = false
    if let compareStashedImage {
      imageView.image = compareStashedImage
    }
    compareStashedImage = nil
    compareHiddenViews.forEach { $0.isHidden = false }
    compareHiddenViews.removeAll()
    updateBlurCover(force: true)
    if mediaType != "image" { refreshPreview() }
  }

  private func refreshPreview() {
    guard mediaType != "image" else {
      // An edit (e.g. a second finger on a slider) ends a hold-to-compare,
      // otherwise release would restore a stale stashed preview.
      didReleaseCompare()
      guard let baseImage, let cgImage = filteredCGImage(from: baseImage) else { return }
      imageView.image = UIImage(cgImage: cgImage, scale: baseImage.scale, orientation: .up)
      // The blur also covers text/stickers/overlays/drawing: the cover is
      // rendered from the picture WITHOUT blur plus the layers, then blurred.
      if blur.isActive, let sharp = filteredCGImage(from: baseImage, applyBlur: false) {
        unblurredPreviewImage = UIImage(cgImage: sharp, scale: baseImage.scale, orientation: .up)
      } else {
        unblurredPreviewImage = nil
      }
      updateBlurCover(force: true)
      updateAutoEnhanceButton()
      scheduleFilterStageRefresh()
      return
    }
    // Video's filter/adjustment preview is a live, per-frame
    // AVVideoComposition closure (see makePrimaryPlayerItem) that reads
    // selectedFilter/currentAdjustments fresh on every frame it actually
    // renders. A plain `seek(to: player.currentTime())` (this function's
    // prior fix, gated to only run while paused) was NOT reliable — per
    // the user's explicit "still not applying immediately as I'm
    // selecting" follow-up report, for BOTH filters and adjustments.
    // AVFoundation can treat a seek to the exact time it's already
    // sitting at as a no-op and skip re-rendering, and apparently the
    // per-frame closure isn't always picked up promptly while genuinely
    // playing either. Nudging forward by a tiny amount then back forces
    // two REAL seeks, guaranteeing the composition closure actually
    // re-runs with the latest values — unconditionally, whether paused or
    // playing, since gating this on play state was itself part of what
    // wasn't working.
    guard let player else { return }
    let currentTime = player.currentTime()
    let nudgedTime = CMTimeAdd(currentTime, CMTime(value: 1, timescale: 600))
    player.seek(to: nudgedTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
      player?.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
  }

  /// Applies the selected filter + brightness/contrast/saturation to `image`
  /// — shared by the live preview (on `baseImage`, the downsampled preview
  /// source) and export (on a separately-decoded higher-res source), so the
  /// two can never drift apart into different-looking pixel math. A thin
  /// wrapper around `adjustedCIImage`, which does the actual work and is
  /// also reused by the live video preview (see `setUpVideoPlayer`).
  private func filteredCGImage(from image: UIImage, applyBlur: Bool = true) -> CGImage? {
    guard let source = CIImage(image: image) else { return nil }
    var output = adjustedCIImage(from: source)
    // Photo-only, after color: preview + export both come through here.
    if mediaType == "image" && applyBlur { output = blur.apply(to: output) }
    return ciContext.createCGImage(output, from: source.extent)
  }

  /// The pure CIImage-in/CIImage-out core of the filter+adjustment
  /// pipeline — reads `selectedFilter` and all adjustment slider fields
  /// fresh on every call, with no dependency on `baseImage` (image-only),
  /// so it's equally usable from the image preview/export (via
  /// `filteredCGImage`) and from video's per-frame `AVVideoComposition`
  /// handler (`setUpVideoPlayer`). The adjustment math itself lives in
  /// `PhotoAdjustments.apply` (PhotoFilter.swift) — a plain value type
  /// rather than a method on `self` — so the video EXPORT compositor
  /// (which runs on an AVFoundation-internal background queue with no
  /// live view controller to read `self.brightness` etc. from) can apply
  /// the exact same math from a captured snapshot; see `exportVideo`.
  private func adjustedCIImage(from source: CIImage) -> CIImage {
    currentAdjustments.apply(to: selectedFilter.apply(
      to: source,
      strength: filterStrength,
      saturation: filterSaturation,
      sharpness: filterSharpness
    ))
  }

  private var currentAdjustments: PhotoAdjustments {
    PhotoAdjustments(
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
      fade: fade,
      shadow: shadow,
      highlights: highlights,
      warmth: warmth,
      tint: tint,
      sharpen: sharpen,
      vignette: vignette
    )
  }

  // MARK: - Export

  private enum ExportResult {
    case success(url: URL, size: CGSize)
    case failure(message: String)
  }

  /// Export re-composites the exact same scene shown in the live preview —
  /// image (filtered/adjusted) + its pan/zoom/rotate + every visible text/
  /// sticker layer — at a higher resolution than the screen, then crops to
  /// the crop frame. Everything scales up by one consistent factor derived
  /// from how much higher-res the original file is than the on-screen
  /// canvas, so the result is geometrically identical to what's on screen,
  /// just at real quality — rather than trying to reverse-map crop
  /// coordinates against the original file's pixel grid by hand.
  private static let maxExportPixelSize: CGFloat = 4096
  // Video's own, LOWER cap — per-frame cost scales with pixel count, and
  // every one of a video's frames pays that cost (unlike a still image,
  // rendered once). 1920 is still a full 1080p-class export, which is the
  // ceiling most social platforms target anyway; 4096 was needlessly high
  // for video and is most of why export was slow. Kept separate from
  // maxExportPixelSize so image export's own quality ceiling is untouched.
  private static let maxVideoExportPixelSize: CGFloat = 1920
  // Story mode exports at most this many pixels WIDE (full-screen canvas, so
  // ~1080x2340 on a modern phone) — the resolution stories are displayed at.
  // Anything more is only extra encode + upload time.
  private static let storyExportPixelWidth: CGFloat = 1080
  private static let storyJPEGQuality: CGFloat = 0.85

  private func exportImage(completion: @escaping (ExportResult) -> Void) {
    MediaEditorViewController.loadDownsampledImage(
      from: sourceURL,
      maxPixelSize: Self.maxExportPixelSize
    ) { [weak self] highResImage in
      guard let self else { return }
      guard let highResImage else {
        completion(.failure(message: "Could not read the original image for export."))
        return
      }
      guard let rendered = self.renderExport(highResImage: highResImage) else {
        completion(.failure(message: "Could not render the edited image."))
        return
      }
      guard let data = rendered.jpegData(
        compressionQuality: self.isStoryMode ? Self.storyJPEGQuality : 0.92
      ) else {
        completion(.failure(message: "Could not encode the edited image."))
        return
      }
      let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jpg")
      do {
        try data.write(to: outputURL)
        completion(.success(url: outputURL, size: rendered.size))
      } catch {
        completion(.failure(message: "Could not write the edited image to disk."))
      }
    }
  }

  private func renderExport(highResImage: UIImage) -> UIImage? {
    let canvasSize = imageView.bounds.size
    guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
    // With layers on the picture the blur goes over them too: blur the
    // finished composite instead of only the photo (same as the preview).
    let blurComposite = mediaType == "image" && blur.isActive && !blurCoverLayerViews.isEmpty
    guard let filteredCG = filteredCGImage(from: highResImage, applyBlur: !blurComposite) else { return nil }
    let filteredHighRes = UIImage(cgImage: filteredCG)

    // How wide the image renders within the canvas under aspect-fit — from
    // that, the scale factor that maps one on-screen canvas point to one
    // pixel of the (higher-res) source image.
    let imageAspect = filteredHighRes.size.width / filteredHighRes.size.height
    let canvasAspect = canvasSize.width / canvasSize.height
    let renderedImageWidthInCanvasPoints = imageAspect > canvasAspect
      ? canvasSize.width
      : canvasSize.height * imageAspect
    guard renderedImageWidthInCanvasPoints > 0 else { return nil }
    // At `nativeExportScale` the source is drawn at its own pixel size.
    let nativeExportScale = filteredHighRes.size.width / renderedImageWidthInCanvasPoints
    var exportScale = nativeExportScale
    if isStoryMode {
      exportScale = min(exportScale, Self.storyExportPixelWidth / canvasSize.width)
    }
    // When the story cap shrinks the output, the source must shrink by the
    // same factor — drawing it at full pixel size into the smaller canvas
    // exported a zoomed-in center crop (user-reported: uploaded story photo
    // "zoomed" vs. the editor).
    let imageDrawScale = exportScale / nativeExportScale

    // Crop feature removed — always export the full canvas (equivalent to
    // a crop rect that exactly matches the canvas bounds). Kept as an
    // explicit rect (rather than deleting the crop-offset math below)
    // since the offset it drives is otherwise 0 anyway, and this keeps
    // the pan/zoom/rotate compositing block that follows completely
    // unchanged.
    let cropRect = CGRect(origin: .zero, size: canvasSize)
    let cropRectInExport = CGRect(
      x: cropRect.origin.x * exportScale,
      y: cropRect.origin.y * exportScale,
      width: cropRect.width * exportScale,
      height: cropRect.height * exportScale
    )
    guard cropRectInExport.width > 0, cropRectInExport.height > 0 else { return nil }

    // Canvas-space center, constant regardless of the image's own
    // pan/zoom/rotate — text/sticker layers are positioned relative to
    // this, not to the image's transform (see addTextLayer/addStickerLayer).
    //
    // MUST be imageView's own LOCAL center (canvasSize/2), NOT
    // `imageView.center` — that property is expressed in the SUPERVIEW's
    // (screen's) coordinate space, whereas this export bitmap's coordinate
    // space matches imageView's own bounds (its size is `canvasSize`
    // scaled up, starting at (0,0) = imageView's own top-left). Ever since
    // the canvas box gained margins/an offset (no longer pinned at literal
    // screen (0,0)), `imageView.center` != `imageView.bounds.center` — using
    // the screen-space value shifted the whole exported composite (image
    // AND every text/sticker layer, which all key off this same point) by
    // imageView's on-screen origin. This was the real, longstanding root
    // cause of exported content not matching the live editor — a bug that
    // predates this session's other position fixes.
    let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

    // scale 1: the math above maps canvas points to SOURCE pixels, so one
    // renderer point must be one output pixel. The default format renders at
    // the screen scale (3x), which silently exported 9x the pixels.
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: cropRectInExport.size, format: format)
    let rendered = renderer.image { rendererContext in
      let ctx = rendererContext.cgContext
      ctx.translateBy(x: -cropRectInExport.origin.x, y: -cropRectInExport.origin.y)

      ctx.saveGState()
      let imageCenterInExport = CGPoint(x: canvasCenter.x * exportScale, y: canvasCenter.y * exportScale)
      ctx.translateBy(x: imageCenterInExport.x, y: imageCenterInExport.y)
      ctx.translateBy(x: currentTranslation.x * exportScale, y: currentTranslation.y * exportScale)
      ctx.rotate(by: currentRotation)
      ctx.scaleBy(x: currentScale, y: currentScale)
      let drawWidth = filteredHighRes.size.width * imageDrawScale
      let drawHeight = filteredHighRes.size.height * imageDrawScale
      let imageRect = CGRect(
        x: -drawWidth / 2,
        y: -drawHeight / 2,
        width: drawWidth,
        height: drawHeight
      )
      filteredHighRes.draw(in: imageRect)
      ctx.restoreGState()

      // Draw/brush strokes — drawingCanvasView is pinned to exactly match
      // imageView's own box (see setUpDrawingCanvas), so a recorded point is
      // ALREADY in this export bitmap's own local coordinate space and
      // needs only a straight `* exportScale`, unlike text/sticker/overlay
      // layers below (which are centered on `view` with a fixed offset —
      // see drawLayerForExport). Drawn right after the base image, matching
      // the on-screen stacking (added right after the grid, before any
      // runtime-added text/sticker/overlay layer).
      // Own transparency layer, so the eraser can't erase the photo.

      // Drawn in add order, matching the on-screen stacking (each was added
      // as a later, higher-z-order sibling than the one before it). Overlay
      // images are always drawn last here — an approximation already
      // accepted for text-vs-sticker ordering (both arrays are always
      // concatenated in this same fixed order regardless of true add-
      // order), extended to the 3rd layer type rather than tracking one
      // single ordered list, which would be a bigger structural change.
      // Drawing, text, stickers and overlays in their on-screen stacking
      // order (subview order), so whatever was added last is on top —
      // same as the preview. Strokes get their own transparency layer
      // inside DrawingCanvasView.draw so the eraser can't erase the photo.
      for subview in view.subviews where !subview.isHidden {
        if subview === drawingCanvasView {
          if !drawingCanvasView.strokes.isEmpty {
            DrawingCanvasView.draw(drawingCanvasView.strokes, scale: exportScale, in: ctx)
          }
        } else if let layer = subview as? EditableTextLayerView,
                  textLayerViews.contains(where: { $0 === layer }) || stickerLayerViews.contains(where: { $0 === layer }) {
          drawLayerForExport(layer, canvasCenter: canvasCenter, exportScale: exportScale, in: ctx)
        } else if let layer = subview as? EditableImageLayerView, imageOverlayLayerViews.contains(where: { $0 === layer }) {
          drawImageOverlayForExport(layer, canvasCenter: canvasCenter, exportScale: exportScale, in: ctx)
        }
      }
    }
    guard blurComposite, let composite = CIImage(image: rendered),
          let blurred = ciContext.createCGImage(blur.apply(to: composite), from: composite.extent) else { return rendered }
    return UIImage(cgImage: blurred, scale: 1, orientation: .up)
  }

  // MARK: - Blur over layers

  /// Text, stickers, overlays and drawing currently on the picture.
  private var blurCoverLayerViews: [UIView] {
    var views: [UIView] = textLayerViews as [UIView]
    views += stickerLayerViews as [UIView]
    views += imageOverlayLayerViews as [UIView]
    if !drawingCanvasView.strokes.isEmpty { views.append(drawingCanvasView) }
    return views.filter { !$0.isHidden && $0.superview === view }
  }

  /// The blurred picture-plus-layers, shown on top of the layers (touches
  /// pass through to them). Not while drawing or styling a layer — those
  /// show the layer sharp so you can see what you're doing.
  private var shouldShowBlurCover: Bool {
    mediaType == "image" && blur.isActive && !isShowingOriginal && unblurredPreviewImage != nil
      && selectedImageEditorTab != .draw && selectedImageEditorTab != .textStyle
      && !blurCoverLayerViews.isEmpty
  }

  /// Where every covered view is (position, size, transform, z-order):
  /// the cover is re-rendered whenever this changes (e.g. a layer drag).
  private func blurCoverSignatureNow(_ views: [UIView]) -> [CGFloat] {
    var sig: [CGFloat] = [CGFloat(views.count)]
    let frame = canvasClipContainerView.frame
    sig += [frame.minX, frame.minY, frame.width, frame.height]
    for v in views {
      let t = v.transform
      sig += [CGFloat(view.subviews.firstIndex(of: v) ?? -1), v.center.x, v.center.y, v.bounds.width, v.bounds.height, t.a, t.b, t.c, t.d, t.tx, t.ty]
    }
    return sig
  }

  private func updateBlurCover(force: Bool = false) {
    guard shouldShowBlurCover else {
      blurCoverView.isHidden = true
      blurCoverView.image = nil
      blurCoverLink?.invalidate()
      blurCoverLink = nil
      blurCoverSignature = []
      return
    }
    if blurCoverLink == nil {
      let link = CADisplayLink(target: WeakDisplayLinkTarget { [weak self] in self?.updateBlurCover() }, selector: #selector(WeakDisplayLinkTarget.tick))
      link.preferredFramesPerSecond = 30
      link.add(to: .main, forMode: .common)
      blurCoverLink = link
    }
    let layers = blurCoverLayerViews
    let signature = blurCoverSignatureNow(layers)
    guard force || signature != blurCoverSignature || blurCoverView.isHidden else { return }
    blurCoverSignature = signature
    renderBlurCover(layers: layers)
  }

  private func renderBlurCover(layers: [UIView]) {
    guard let sharp = unblurredPreviewImage else { return }
    if blurCoverView.superview !== view {
      blurCoverView.isUserInteractionEnabled = false
      blurCoverView.contentMode = .scaleToFill
      blurCoverView.clipsToBounds = true
      view.addSubview(blurCoverView)
    }
    blurCoverView.layer.cornerRadius = canvasClipContainerView.layer.cornerRadius
    // Picture without blur + the layers, as on screen (no selection border).
    let shownImage = imageView.image
    let selectionBorder = selectedLayer?.layer.borderWidth ?? 0
    imageView.image = sharp
    selectedLayer?.layer.borderWidth = 0
    let composite = renderCanvasComposite(of: [canvasClipContainerView] + layers, scale: min(UIScreen.main.scale, 2))
    imageView.image = shownImage
    selectedLayer?.layer.borderWidth = selectionBorder
    guard let composite, let input = CIImage(image: composite),
          let blurred = ciContext.createCGImage(blur.apply(to: input), from: input.extent) else { return }
    blurCoverView.image = UIImage(cgImage: blurred, scale: composite.scale, orientation: .up)
    blurCoverView.transform = .identity
    blurCoverView.frame = canvasClipContainerView.frame
    blurCoverView.isHidden = false
    // Just above the top-most layer (below the layer bar and other chrome).
    if let top = layers.compactMap({ view.subviews.firstIndex(of: $0) }).max() {
      view.insertSubview(blurCoverView, aboveSubview: view.subviews[top])
    }
    if isFilterStageActive { scheduleFilterStageRefresh() }
  }

  /// A text/sticker layer's center in canvas points at export — its base
  /// anchor (canvas center + newLayerVerticalOffset, see addTextLayer) plus
  /// its own translation. Shared by image export, video export and
  /// locationStickerMetadata so all three agree on where a layer lands.
  private static func exportCenterInCanvas(translation: CGPoint, canvasCenter: CGPoint) -> CGPoint {
    CGPoint(
      x: canvasCenter.x + translation.x,
      y: canvasCenter.y + newLayerVerticalOffset + translation.y
    )
  }

  /// One entry per visible location sticker, returned with the export
  /// result so story viewers can tap it to open Maps. Both exports render
  /// the full canvas (renderExport / exportVideo: output = canvas ×
  /// exportScale) and draw a sticker at exportCenterInCanvas × exportScale
  /// with size bounds × currentScale × exportScale — so dividing canvas-
  /// point values by the canvas size gives the same fractions of the
  /// output file, independent of exportScale. w/h are the unrotated box.
  private func locationStickerMetadata() -> [[String: Any]] {
    let canvasSize = mediaType == "image" ? imageView.bounds.size : playerView.bounds.size
    guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
    let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    return stickerLayerViews
      .filter { !$0.isHidden && $0.isLocationLayer && ["location", "link", "hashtag"].contains($0.infoKind) }
      .map { layer in
        let center = Self.exportCenterInCanvas(translation: layer.currentTranslation, canvasCenter: canvasCenter)
        return [
          "type": layer.infoKind,
          "name": layer.locationName ?? "",
          "url": layer.infoKind == "link" ? (layer.infoValue ?? "") : "",
          "tag": layer.infoKind == "hashtag" ? (layer.infoValue ?? "") : "",
          "lat": layer.locationLatitude.map { $0 as Any } ?? NSNull(),
          "lng": layer.locationLongitude.map { $0 as Any } ?? NSNull(),
          "x": center.x / canvasSize.width,
          "y": center.y / canvasSize.height,
          "w": layer.bounds.width * layer.currentScale / canvasSize.width,
          "h": layer.bounds.height * layer.currentScale / canvasSize.height,
          // UIKit's y-down space: a positive angle turns clockwise on screen.
          "rotation": layer.currentRotation * 180 / .pi,
          "aspect": canvasSize.width / canvasSize.height,
        ] as [String: Any]
      }
  }

  private func drawLayerForExport(
    _ layer: EditableTextLayerView,
    canvasCenter: CGPoint,
    exportScale: CGFloat,
    in ctx: CGContext
  ) {
    // The layer's actual on-screen base anchor is canvasCenter PLUS
    // newLayerVerticalOffset (see addTextLayer) — must match exactly, or
    // exported layers land newLayerVerticalOffset points away from where
    // they appear live (this was a real, user-reported bug).
    let centerInCanvas = Self.exportCenterInCanvas(translation: layer.currentTranslation, canvasCenter: canvasCenter)
    let centerInExport = CGPoint(x: centerInCanvas.x * exportScale, y: centerInCanvas.y * exportScale)

    // Sticker layers (bundled image, not rendered text) draw straight from
    // their own asset — same approach as drawImageOverlayForExport — so a
    // sticker's real artwork lands in the export instead of an empty
    // label (this layer's `.text`/`.attributedText` are nil once it holds
    // a sticker image, see EditableTextLayerView.applyStickerImage).
    if layer.isStickerImageLayer, let image = layer.stickerImage {
      let size = CGSize(width: layer.bounds.width * exportScale, height: layer.bounds.height * exportScale)
      ctx.saveGState()
      ctx.translateBy(x: centerInExport.x, y: centerInExport.y)
      ctx.rotate(by: layer.currentRotation)
      ctx.scaleBy(x: layer.currentScale, y: layer.currentScale)
      image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
      ctx.restoreGState()
      return
    }

    // Re-rendered at export resolution by the same renderer the on-screen
    // layer uses, so the export matches the preview exactly and stays crisp.
    guard let style = layer.layerStyle,
          let rendered = TextLayerRenderer.render(text: layer.text ?? "", style: style, scale: exportScale) else { return }
    ctx.saveGState()
    ctx.translateBy(x: centerInExport.x, y: centerInExport.y)
    ctx.rotate(by: layer.currentRotation)
    ctx.scaleBy(x: layer.currentScale, y: layer.currentScale)
    let pixelSize = CGSize(width: rendered.image.width, height: rendered.image.height)
    UIImage(cgImage: rendered.image).draw(in: CGRect(
      x: -rendered.size.width / 2, y: -rendered.size.height / 2,
      width: pixelSize.width, height: pixelSize.height
    ))
    ctx.restoreGState()
  }

  /// Image-overlay counterpart to `drawLayerForExport` — draws the
  /// overlay's own `UIImage` (already loaded at whatever resolution the
  /// system picker returned it) instead of rendering text, scaled from its
  /// on-screen size by the same `exportScale` factor everything else uses.
  private func drawImageOverlayForExport(
    _ layer: EditableImageLayerView,
    canvasCenter: CGPoint,
    exportScale: CGFloat,
    in ctx: CGContext
  ) {
    // Re-rendered at export size from the unstyled photo (sharper than the
    // on-screen preview), then drawn with its blend mode.
    let pixelSize = CGSize(width: max(layer.bounds.width * exportScale, 1), height: max(layer.bounds.height * exportScale, 1))
    guard let image = layer.baseImage.flatMap({
      OverlayRenderer.render(base: $0, style: layer.overlayStyle, strokes: layer.eraseStrokes, pixelSize: pixelSize)
    }) ?? layer.image else { return }
    // Same base anchor as drawLayerForExport — must match addImageOverlayLayer's
    // constraint exactly (see its comment).
    let centerInCanvas = CGPoint(
      x: canvasCenter.x + layer.currentTranslation.x,
      y: canvasCenter.y + Self.newLayerVerticalOffset + layer.currentTranslation.y
    )
    let centerInExport = CGPoint(x: centerInCanvas.x * exportScale, y: centerInCanvas.y * exportScale)
    let size = CGSize(width: layer.bounds.width * exportScale, height: layer.bounds.height * exportScale)

    ctx.saveGState()
    ctx.translateBy(x: centerInExport.x, y: centerInExport.y)
    ctx.rotate(by: layer.currentRotation)
    ctx.scaleBy(x: layer.currentScale, y: layer.currentScale)
    ctx.setBlendMode(layer.overlayStyle.blend.cgBlendMode)
    image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), blendMode: layer.overlayStyle.blend.cgBlendMode, alpha: 1)
    ctx.restoreGState()
  }

  /// Renders one text/sticker layer to a standalone CGImage — the video
  /// counterpart to drawLayerForExport, which instead draws straight into
  /// an already-open CGContext (fine for image export, which runs
  /// synchronously on the main thread; video's per-frame compositor runs on
  /// a background queue, so it needs a plain, pre-rendered image handed to
  /// it rather than a live UILabel to render itself, see exportVideo).
  private func renderOverlayImage(text: String, style: TextLayerStyle, exportScale: CGFloat) -> (image: CGImage, size: CGSize)? {
    // `size` is the intended draw size at export scale — see
    // MediaEditorVideoOverlayLayer.size's doc. The bitmap is that size
    // rounded up, so use its own pixel size to avoid a sub-pixel stretch.
    guard let rendered = TextLayerRenderer.render(text: text, style: style, scale: exportScale) else { return nil }
    return (rendered.image, CGSize(width: rendered.image.width, height: rendered.image.height))
  }

  /// Image-overlay counterpart to renderOverlayImage — the video-export
  /// analog of drawImageOverlayForExport, which draws straight into an
  /// already-open CGContext instead (fine for image export's synchronous
  /// main-thread render; video's per-frame compositor runs on a background
  /// queue, so it needs a pre-rendered image rather than a live
  /// UIImageView to draw). `size` is the layer's own on-screen bounds, per
  /// VideoImageOverlaySnapshot's doc.
  private func renderImageOverlayImage(image: UIImage, size: CGSize, exportScale: CGFloat) -> CGImage? {
    let scaledSize = CGSize(width: size.width * exportScale, height: size.height * exportScale)
    guard scaledSize.width > 0, scaledSize.height > 0 else { return nil }
    // scale 1: scaledSize is already in export PIXELS. The screen's default
    // 3x made every overlay bitmap 9x bigger than the video needs.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: scaledSize, format: format)
    let rendered = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: scaledSize))
    }
    return rendered.cgImage
  }

  /// Draw/brush-stroke counterpart to renderOverlayImage — rasterizes
  /// every stroke onto a single full-frame-sized CGImage (rather than one
  /// image per stroke) since strokes have no per-layer anchor/rotation/
  /// scale of their own, just absolute points already in the canvas's own
  /// local space (see renderExport's identical stroke-drawing comment for
  /// why no base-anchor offset is needed here, unlike text/sticker/
  /// overlay). Returns nil when there are no strokes, so the caller can
  /// skip adding an empty overlay layer.
  private func renderStrokesOverlayImage(
    strokes: [DrawingCanvasView.Stroke],
    size: CGSize,
    exportScale: CGFloat
  ) -> CGImage? {
    guard !strokes.isEmpty, size.width > 0, size.height > 0 else { return nil }
    // scale 1: `size` is the export frame in pixels (at 3x a 1080x1920
    // drawing was a ~75 MB bitmap).
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let rendered = renderer.image { rendererContext in
      DrawingCanvasView.draw(strokes, scale: exportScale, in: rendererContext.cgContext)
    }
    return rendered.cgImage
  }

  // MARK: - Video export (Day 26a + 26b + 26c)
  //
  // Bakes trim + crop/pan/zoom/rotate + filter into a real output file via
  // AVMutableComposition (trim) + a custom AVVideoCompositing compositor
  // (MediaEditorVideoCompositor — crop/transform/filter per frame, reusing
  // the SAME math as renderExport above) + AVAssetExportSession. Day 26b
  // adds text/sticker overlays: each visible layer's text/font/color/
  // translation/rotation/scale is snapshotted on the main thread (UILabel
  // properties are safe to read here, before the export Task starts), then
  // once exportScale is known, rendered to a CGImage on the main thread
  // (hopping via MainActor.run, since building/rendering a UILabel must
  // happen on main) and handed to the compositor as plain, already-
  // rasterized data — the compositor itself runs on a background
  // AVFoundation queue where touching a live UILabel would be unsafe.
  //
  // Day 26c bakes in original-audio volume/mute and music mixing. Both the
  // original clip's audio and an optional selected music track become
  // their own AVMutableCompositionTrack (music inserted as its own
  // .zero-based segment, clamped to the video's trimmed duration since
  // it's independently timed, not muxed onto the video's audio track),
  // each with an AVMutableAudioMixInputParameters controlling its volume —
  // AVFoundation mixes every composition audio track together
  // automatically once assigned to AVAssetExportSession.audioMix, no
  // manual sample mixing needed.

  private struct VideoOverlaySnapshot {
    /// Position in the on-screen stacking order (export keeps it).
    let zIndex: Int
    let text: String
    /// nil for sticker layers.
    let style: TextLayerStyle?
    let translation: CGPoint
    let rotation: CGFloat
    let scale: CGFloat
    // Non-nil only for a sticker layer (bundled image, not rendered text)
    // — when set, export draws this image directly instead of re-
    // rendering `text` as a glyph, mirroring drawLayerForExport's same
    // branch for the synchronous image-export path. `stickerSize` is the
    // layer's own on-screen bounds, matching VideoImageOverlaySnapshot's
    // identical `size` semantics.
    let stickerImage: UIImage?
    let stickerSize: CGSize
    /// The layer's time windows on the combined timeline (nil = always).
    let visibleRanges: [ClosedRange<Double>]?
    var anim = TextAnimConfig.none
  }

  /// Image-overlay counterpart to VideoOverlaySnapshot — `size` is the
  /// layer's own on-screen bounds (not the source image's native pixel
  /// size), matching drawImageOverlayForExport's identical distinction.
  private struct VideoImageOverlaySnapshot {
    let zIndex: Int
    let image: UIImage
    let size: CGSize
    let translation: CGPoint
    let rotation: CGFloat
    let scale: CGFloat
    let visibleRanges: [ClosedRange<Double>]?
  }

  private enum VideoExportResult {
    case success(url: URL, size: CGSize, duration: Double)
    case failure(message: String)
  }

  // MARK: - Photo + Music export (story mode only)

  /// Mixes a still image + a selected music track into an exported VIDEO —
  /// a static image has no audio timeline of its own, so "music on a
  /// photo" (per the user's explicit "add music option on the photo story
  /// screen too" request) means synthesizing a silent video from the one
  /// rendered frame, then reusing the exact same AVMutableComposition /
  /// AVMutableAudioMixInputParameters muxing pattern exportVideo's own
  /// music-track handling already uses (see its `if let musicTrack,
  /// musicClipEnd > musicClipStart` block below) — just against a fresh
  /// composition, with no "original audio" track (a photo has none) and no
  /// per-frame video compositor (the frame is already fully baked via
  /// renderExport, nothing left to composite).
  /// Local copies of picked music (keyed by track id), downloaded as soon
  /// as a track is selected so Share doesn't wait on the network.
  private var localMusicFiles: [String: URL] = [:]
  /// Callers waiting on an in-flight download, keyed by track id.
  private var musicDownloadWaiters: [String: [(URL?) -> Void]] = [:]

  private func prefetchMusicFile(for track: MusicTrack) {
    guard track.audioURL.isFileURL == false,
          localMusicFiles[track.id] == nil,
          musicDownloadWaiters[track.id] == nil
    else { return }
    musicDownloadWaiters[track.id] = []
    let ext = track.audioURL.pathExtension.isEmpty ? "m4a" : track.audioURL.pathExtension
    URLSession.shared.downloadTask(with: track.audioURL) { [weak self] tempURL, response, _ in
      var local: URL?
      if let tempURL, (response as? HTTPURLResponse)?.statusCode == 200 {
        // Keeps the extension so AVFoundation recognises the file type.
        let destination = FileManager.default.temporaryDirectory
          .appendingPathComponent("editor_music_\(UUID().uuidString).\(ext)")
        if (try? FileManager.default.moveItem(at: tempURL, to: destination)) != nil {
          local = destination
          DispatchQueue.main.async { self?.tempFilesToDelete.append(destination) }
        }
      }
      DispatchQueue.main.async {
        guard let self else { return }
        if let local { self.localMusicFiles[track.id] = local }
        let waiters = self.musicDownloadWaiters.removeValue(forKey: track.id) ?? []
        waiters.forEach { $0(local) }
      }
    }.resume()
  }

  /// The downloaded copy when ready (waiting for an in-flight download),
  /// else the remote URL — export still works, just streams the audio.
  private func withLocalMusicURL(for track: MusicTrack, completion: @escaping (URL) -> Void) {
    if let local = localMusicFiles[track.id] {
      completion(local)
    } else if musicDownloadWaiters[track.id] != nil {
      musicDownloadWaiters[track.id]?.append { completion($0 ?? track.audioURL) }
    } else {
      completion(track.audioURL)
    }
  }

  private func exportImageWithMusic(completion: @escaping (VideoExportResult) -> Void) {
    guard let musicTrack = selectedMusicTrack else {
      completion(.failure(message: "No music track selected."))
      return
    }
    let musicVolume = musicVolumeSlider.value
    let musicClipStart = musicTrimStart
    // 60s cap matches the app's story video length limit (see
    // StoryCameraScreen's MAX_RECORDING_MS); 15s is a safe fallback for the
    // (possible, since there's no trim UI forcing the user to wait) case
    // where selectMusicTrack's async duration resolution hasn't completed
    // yet by the time Share is tapped, leaving musicTrimEnd at its initial 0.
    let rawDuration = musicTrimEnd - musicTrimStart
    let targetDuration = rawDuration > 0 ? min(rawDuration, 60.0) : 15.0

    // The result is a VIDEO, so it uses the video resolution cap: the
    // photo's own 4096 cap made every frame of the still-image video a
    // needlessly huge encode (most of why Share was slow).
    MediaEditorViewController.loadDownsampledImage(
      from: sourceURL,
      maxPixelSize: Self.maxVideoExportPixelSize
    ) { [weak self] highResImage in
      guard let self else { return }
      guard let highResImage, let rendered = self.renderExport(highResImage: highResImage) else {
        completion(.failure(message: "Could not render the edited image."))
        return
      }
      guard let renderedCGImage = rendered.cgImage else {
        completion(.failure(message: "Could not read the rendered image."))
        return
      }
      self.writeSilentVideo(from: renderedCGImage, size: rendered.size, duration: targetDuration) { silentResult in
        switch silentResult {
        case let .failure(message):
          completion(.failure(message: message))
        case let .success(silentURL):
          // Downloaded when the track was picked, so usually instant.
          self.withLocalMusicURL(for: musicTrack) { musicURL in
          self.muxMusic(
            intoSilentVideoAt: silentURL,
            musicURL: musicURL,
            musicVolume: musicVolume,
            musicClipStart: musicClipStart,
            targetDuration: targetDuration,
            renderedSize: rendered.size
          ) { result in
            // The silent intermediate is temporary either way — clean it up
            // once the final export (success OR failure) has consumed it,
            // mirroring exportVideo/exportImage's own temp-file handling.
            try? FileManager.default.removeItem(at: silentURL)
            completion(result)
          }
          }
        }
      }
    }
  }

  private enum SilentVideoResult {
    case success(URL)
    case failure(message: String)
  }

  /// Writes a short, silent .mp4 that just holds ONE static frame repeated
  /// across `duration` — the visual side is already fully baked (filters/
  /// adjustments/draw-strokes/text/sticker/overlay layers, via
  /// renderExport), so this needs no per-frame compositor, just a steady
  /// stream of duplicate pixel buffers. 30fps matches standard video
  /// expectations for broad player/codec compatibility (a sparser rate
  /// risks some players/muxers treating gaps between keyframes as a stall).
  private func writeSilentVideo(
    from image: CGImage,
    size: CGSize,
    duration: Double,
    completion: @escaping (SilentVideoResult) -> Void
  ) {
    // H.264 wants even dimensions.
    let width = Int(size.width.rounded()) / 2 * 2
    let height = Int(size.height.rounded()) / 2 * 2
    guard width > 0, height > 0 else {
      completion(.failure(message: "Invalid image size for video export."))
      return
    }
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")

    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
    } catch {
      completion(.failure(message: "Could not create video writer: \(error.localizedDescription)"))
      return
    }

    let outputSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
    ]
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    writerInput.expectsMediaDataInRealTime = false

    let pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: writerInput,
      sourcePixelBufferAttributes: pixelBufferAttributes
    )

    guard writer.canAdd(writerInput) else {
      completion(.failure(message: "Could not configure video writer input."))
      return
    }
    writer.add(writerInput)

    guard writer.startWriting() else {
      completion(.failure(message: writer.error?.localizedDescription ?? "Could not start video writer."))
      return
    }
    writer.startSession(atSourceTime: .zero)

    // One shared pixel buffer, blitted once and appended repeatedly — the
    // frame never changes, so there's no reason to re-render or re-allocate
    // it per frame.
    guard let pixelBufferPool = adaptor.pixelBufferPool else {
      completion(.failure(message: "Could not create pixel buffer pool."))
      return
    }
    var pixelBufferOut: CVPixelBuffer?
    let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBufferOut)
    guard poolStatus == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
      completion(.failure(message: "Could not allocate pixel buffer."))
      return
    }
    guard MediaEditorViewController.blitStillImage(image, into: pixelBuffer) else {
      completion(.failure(message: "Could not render the frame into a pixel buffer."))
      return
    }

    // The frame never changes, so a low frame rate loses nothing visible
    // and cuts the encode work 6x versus 30fps (5fps is a normal, fully
    // valid rate for players and muxers).
    let frameRate: Int32 = 5
    let totalFrames = max(1, Int((duration * Double(frameRate)).rounded()))
    let frameDuration = CMTime(value: 1, timescale: frameRate)
    var frameIndex = 0
    let queue = DispatchQueue(label: "com.intoactive.mediaeditor.imagevideo")

    writerInput.requestMediaDataWhenReady(on: queue) {
      while writerInput.isReadyForMoreMediaData {
        if frameIndex >= totalFrames {
          writerInput.markAsFinished()
          writer.finishWriting {
            DispatchQueue.main.async {
              if writer.status == .completed {
                completion(.success(outputURL))
              } else {
                completion(.failure(message: writer.error?.localizedDescription ?? "Video writer failed to finish."))
              }
            }
          }
          return
        }
        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
        if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
          writerInput.markAsFinished()
          DispatchQueue.main.async {
            completion(.failure(message: writer.error?.localizedDescription ?? "Could not append video frame."))
          }
          return
        }
        frameIndex += 1
      }
    }
  }

  /// Draws `image` into `pixelBuffer`'s own backing memory. No Y-flip:
  /// `ctx.draw` of a CGImage into a raw bitmap context already lands
  /// upright in memory (row 0 = image top) — flipping first, as
  /// MediaEditorVideoCompositor's `blit(_:into:)` does for its own frames,
  /// turned music-on-photo stories upside down (mirrored top-to-bottom).
  private static func blitStillImage(_ image: CGImage, into pixelBuffer: CVPixelBuffer) -> Bool {
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
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }

  /// Loads the silent single-frame video's own track into a fresh
  /// composition, adds the trimmed music track alongside it (same pattern
  /// as exportVideo's music-mixing block, minus any "original audio" —
  /// there is none for a still image), and exports via a plain
  /// AVAssetExportSession (no custom AVMutableVideoComposition/compositor —
  /// the visual frame is already fully baked into the silent video itself,
  /// there's nothing per-frame left to composite).
  private func muxMusic(
    intoSilentVideoAt silentURL: URL,
    musicURL: URL,
    musicVolume: Float,
    musicClipStart: Double,
    targetDuration: Double,
    renderedSize: CGSize,
    completion: @escaping (VideoExportResult) -> Void
  ) {
    Task {
      do {
        let silentAsset = AVURLAsset(url: silentURL)
        guard let silentVideoTrack = try await silentAsset.loadTracks(withMediaType: .video).first else {
          await MainActor.run { completion(.failure(message: "Could not read the generated video track.")) }
          return
        }
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
          await MainActor.run { completion(.failure(message: "Could not create the video track.")) }
          return
        }
        let fullRange = CMTimeRange(start: .zero, duration: CMTime(seconds: targetDuration, preferredTimescale: 600))
        try compositionVideoTrack.insertTimeRange(fullRange, of: silentVideoTrack, at: .zero)

        var audioMixParameters: [AVMutableAudioMixInputParameters] = []
        let musicAsset = AVURLAsset(url: musicURL)
        if let sourceMusicTrack = try? await musicAsset.loadTracks(withMediaType: .audio).first {
          var musicSourceDurationSeconds = musicClipStart + targetDuration
          if let musicTimeRangeLoaded = try? await sourceMusicTrack.load(.timeRange) {
            let loadedDuration = CMTimeGetSeconds(musicTimeRangeLoaded.duration)
            if loadedDuration.isFinite, loadedDuration > 0 {
              musicSourceDurationSeconds = min(musicSourceDurationSeconds, loadedDuration)
            }
          }
          let sourceStart = max(0, min(musicClipStart, musicSourceDurationSeconds))
          let sourceEnd = max(sourceStart, min(musicClipStart + targetDuration, musicSourceDurationSeconds))
          if sourceEnd > sourceStart,
             let compositionMusicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let musicTimeRange = CMTimeRange(
              start: CMTime(seconds: sourceStart, preferredTimescale: 600),
              duration: CMTime(seconds: sourceEnd - sourceStart, preferredTimescale: 600)
            )
            try? compositionMusicTrack.insertTimeRange(musicTimeRange, of: sourceMusicTrack, at: .zero)
            let musicParams = AVMutableAudioMixInputParameters(track: compositionMusicTrack)
            musicParams.setVolume(musicVolume, at: .zero)
            audioMixParameters.append(musicParams)
          }
        }

        // The video track is already final and the music is AAC, so at
        // full volume both are copied as-is (no re-encode — this used to
        // encode the whole video a second time). Passthrough can't apply
        // a volume change, so any other volume still re-encodes.
        let canPassThrough = abs(musicVolume - 1) < 0.001
        guard let exportSession = AVAssetExportSession(
          asset: composition,
          presetName: canPassThrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        ) else {
          await MainActor.run { completion(.failure(message: "Could not create the export session.")) }
          return
        }
        if !canPassThrough, !audioMixParameters.isEmpty {
          let audioMix = AVMutableAudioMix()
          audioMix.inputParameters = audioMixParameters
          exportSession.audioMix = audioMix
        }
        let outputURL = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension("mp4")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        // Matches exportVideo's own completion-handler style (not the
        // newer `export() async throws`, which needs a higher deployment
        // target than this project's — see ios/Podfile).
        exportSession.exportAsynchronously {
          DispatchQueue.main.async {
            switch exportSession.status {
            case .completed:
              completion(.success(url: outputURL, size: renderedSize, duration: targetDuration))
            default:
              completion(.failure(message: exportSession.error?.localizedDescription ?? "Video export failed."))
            }
          }
        }
      } catch {
        await MainActor.run { completion(.failure(message: error.localizedDescription)) }
      }
    }
  }

  private func exportVideo(musicFileURL: URL? = nil, completion: @escaping (VideoExportResult) -> Void) {
    // Use the downloaded copy of the music (waits for an in-flight
    // download) instead of streaming it — on a weak connection the
    // streamed track was silently dropped from the export.
    if musicFileURL == nil, let track = selectedMusicTrack {
      withLocalMusicURL(for: track) { [weak self] url in
        self?.exportVideo(musicFileURL: url, completion: completion)
      }
      return
    }
    let musicSourceURL = musicFileURL
    let canvasSize = playerView.bounds.size
    guard canvasSize.width > 0, canvasSize.height > 0 else {
      completion(.failure(message: "Could not read the video canvas size."))
      return
    }
    // Crop feature removed — always export the full canvas (equivalent to
    // a crop rect that exactly matches the canvas bounds). Kept as an
    // explicit rect (rather than deleting the crop-offset math below)
    // since the offset it drives is otherwise 0 anyway, and this keeps
    // the pan/zoom/rotate compositing math (computed independently, from
    // currentTranslation/currentRotation/currentScale) completely
    // unchanged.
    let cropRect = CGRect(origin: .zero, size: canvasSize)
    // Same fix as renderExport's identical variable — must be playerView's
    // own LOCAL center (canvasSize/2), not the screen-space `.center`
    // property, since this export's coordinate space matches playerView's
    // own bounds. See renderExport's comment for the full explanation.
    let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    let translation = currentTranslation
    let rotation = currentRotation
    let scale = currentScale
    // Flushes whichever clip is CURRENTLY being edited (per
    // syncActiveClipFilterState's own "nil = primary" convention) into
    // clipFilterState before export reads it — otherwise a just-changed
    // slider value wouldn't be reflected if the user tapped Done before
    // the playhead ever crossed back off that clip (the only OTHER time
    // this dictionary gets updated).
    clipFilterState[activeClipURL ?? sourceURL] = currentFilterStateSnapshot()
    let primaryFilterState = clipFilterState[sourceURL] ?? ClipFilterState()
    let filter = primaryFilterState.filter
    let filterStrength = primaryFilterState.filterStrength
    let filterSaturation = primaryFilterState.filterSaturation
    let filterSharpness = primaryFilterState.filterSharpness
    let adjustments = primaryFilterState.adjustments
    let clipFilterStateSnapshot = self.clipFilterState
    let videoSegments = self.videoSegments
    let additionalClipURLs = self.additionalVideoClipURLs
    let clipVolumesSnapshot = self.clipVolumes
    let primaryClipVolume = self.clipVolume(self.sourceURL)
    // Speed control: the editor's timeline is in each clip's own time; the
    // export plays each clip at its speed, so every time on that timeline
    // (layers, music) is mapped to the output timeline with this.
    let speedSpansSnapshot = self.speedSpans
    let primarySpeedSpans = self.speedSpans[self.sourceURL]
    let transitionsSnapshot = self.transitionsIn
    let fadeIn = self.audioFadeIn
    let fadeOut = self.audioFadeOut
    let fadeSeconds = Self.audioFadeSeconds
    let lastClipVolume = self.additionalVideoClipURLs.last.map { self.clipVolume($0) } ?? primaryClipVolume
    let speedBlocks = self.timelineSpeedParts()
    let toOutputTime: (Double) -> Double = { t in
      var out = 0.0
      for block in speedBlocks {
        if t <= block.start + block.kept { return out + max(0, t - block.start) / block.speed }
        out += block.kept / block.speed
      }
      return out + max(0, t - (speedBlocks.last.map { $0.start + $0.kept } ?? 0))
    }
    // Voice-over: its span on the OUTPUT timeline, and the original-sound
    // level there (the clip under its start) to duck from.
    let voiceURL = self.voiceOverURL
    let voiceOutStart = toOutputTime(self.voiceOverStart)
    let voiceOutEnd = voiceOutStart + self.voiceOverDuration
    let voiceClipVolume: Float = {
      let block = self.timelineBlocks().last { $0.combinedStart <= self.voiceOverStart }
      return self.clipVolume(block?.url)
    }()
    let duckLevel = Self.voiceDuckLevel
    let additionalClipSegments = self.additionalClipSegments

    let musicTrack = selectedMusicTrack
    let musicVolume = musicVolumeSlider.value
    let musicClipStart = musicTrimStart
    let musicClipEnd = musicTrimEnd
    let musicOffsetValue = toOutputTime(musicOffset)
    // Snapshot for the same reason every other mutable-state capture on
    // this page is snapshotted before the async export Task below — the
    // live `musicSegments` could change (or the layer could be torn down)
    // while export is still running. Falls back to the single
    // [offset, offset+keptDuration) window when still empty (duration not
    // resolved yet) so a very-fast Done tap can't lose the music track
    // entirely.
    let musicSegmentsSnapshot = musicSegments.isEmpty
      ? [musicOffsetValue...(musicOffsetValue + max(musicClipEnd - musicClipStart, 0))]
      : musicSegments.map { toOutputTime($0.lowerBound)...max(toOutputTime($0.lowerBound), toOutputTime($0.upperBound)) }
    let originalAudioEffectiveVolume: Float = originalAudioVolumeSlider.value

    // On-screen stacking order of every layer (and the drawing), so the
    // export keeps "last added on top".
    let zOrder = Dictionary(uniqueKeysWithValues: view.subviews.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
    let strokesZIndex = zOrder[ObjectIdentifier(drawingCanvasView)] ?? -1
    let overlaySnapshots = (textLayerViews + stickerLayerViews)
      .filter { !$0.isHidden && !isLayerUserHidden($0) }
      .map { layer in
        VideoOverlaySnapshot(
          zIndex: zOrder[ObjectIdentifier(layer)] ?? 0,
          text: layer.text ?? "",
          style: layer.layerStyle,
          translation: layer.currentTranslation,
          rotation: layer.currentRotation,
          scale: layer.currentScale,
          stickerImage: layer.isStickerImageLayer ? layer.stickerImage : nil,
          stickerSize: layer.bounds.size,
          visibleRanges: layerTimings[ObjectIdentifier(layer)]?.segments.map { toOutputTime($0.lowerBound)...max(toOutputTime($0.lowerBound), toOutputTime($0.upperBound)) },
          anim: layer.isStickerImageLayer ? .none : (layerTimings[ObjectIdentifier(layer)]?.anim ?? .none)
        )
      }
    // Overlay (image-over-image) layers — same base-anchor convention as
    // text/sticker above (see drawImageOverlayForExport's identical
    // convention for image export).
    let imageOverlaySnapshots = imageOverlayLayerViews
      .filter { !$0.isHidden && !isLayerUserHidden($0) }
      .compactMap { layer -> VideoImageOverlaySnapshot? in
        guard let image = layer.image else { return nil }
        return VideoImageOverlaySnapshot(
          zIndex: zOrder[ObjectIdentifier(layer)] ?? 0,
          image: image,
          size: layer.bounds.size,
          translation: layer.currentTranslation,
          rotation: layer.currentRotation,
          scale: layer.currentScale,
          visibleRanges: layerTimings[ObjectIdentifier(layer)]?.segments.map { toOutputTime($0.lowerBound)...max(toOutputTime($0.lowerBound), toOutputTime($0.upperBound)) }
        )
      }
    // Draw/brush strokes — snapshotted up front alongside the layer
    // snapshots above, even though Stroke is already an immutable class,
    // so every export input is captured at the same moment.
    let strokeSnapshots = drawingCanvasView.strokes

    let asset = AVURLAsset(url: sourceURL)
    NSLog(
      "[MediaEditor] exportVideo: starting, overlaySnapshots=%d imageOverlaySnapshots=%d strokeSnapshots=%d",
      overlaySnapshots.count, imageOverlaySnapshots.count, strokeSnapshots.count
    )
    Task { [weak self] in
      guard let self else {
        NSLog("[MediaEditor] exportVideo: self was deallocated before export could run")
        return
      }
      do {
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
          await MainActor.run { completion(.failure(message: "Could not read the video track.")) }
          return
        }
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let assetDuration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(assetDuration)
        guard totalSeconds.isFinite, totalSeconds > 0 else {
          await MainActor.run { completion(.failure(message: "Could not read the video duration.")) }
          return
        }

        // Orientation-corrected native size — matches how MediaEditorModule
        // already reports width/height for this same asset.
        let transformedSize = naturalSize.applying(preferredTransform)
        let nativeWidth = abs(transformedSize.width)
        let nativeHeight = abs(transformedSize.height)
        guard nativeWidth > 0, nativeHeight > 0 else {
          await MainActor.run { completion(.failure(message: "Invalid video dimensions.")) }
          return
        }

        let videoAspect = nativeWidth / nativeHeight
        let canvasAspect = canvasSize.width / canvasSize.height
        let renderedWidthInCanvasPoints = videoAspect > canvasAspect
          ? canvasSize.width
          : canvasSize.height * videoAspect
        guard renderedWidthInCanvasPoints > 0 else {
          await MainActor.run { completion(.failure(message: "Could not compute export scale.")) }
          return
        }
        let rawExportScale = nativeWidth / renderedWidthInCanvasPoints

        // Clamp so the compositor's CPU-side per-frame render never exceeds
        // maxVideoExportPixelSize on its longest side. Uncapped (or capped
        // only at image export's much higher 4096 ceiling), a high-res
        // source video can push the crop's render size into the tens of
        // megapixels PER FRAME — the CPU-bound custom compositor
        // (MediaEditorVideoCompositor, Core Graphics not GPU) pays that
        // cost on every single frame of the clip, which is most of why
        // export was slow; from the UI this looks exactly like tapping
        // Done did nothing.
        let uncappedCropSize = CGSize(
          width: cropRect.width * rawExportScale,
          height: cropRect.height * rawExportScale
        )
        let largestUncappedDimension = max(uncappedCropSize.width, uncappedCropSize.height)
        let exportScale = largestUncappedDimension > Self.maxVideoExportPixelSize
          ? rawExportScale * (Self.maxVideoExportPixelSize / largestUncappedDimension)
          : rawExportScale

        let cropRectInExport = CGRect(
          x: cropRect.origin.x * exportScale,
          y: cropRect.origin.y * exportScale,
          width: cropRect.width * exportScale,
          height: cropRect.height * exportScale
        )
        guard cropRectInExport.width > 1, cropRectInExport.height > 1 else {
          await MainActor.run { completion(.failure(message: "Invalid crop selection.")) }
          return
        }
        let canvasCenterInExport = CGPoint(x: canvasCenter.x * exportScale, y: canvasCenter.y * exportScale)
        let translationInExport = CGPoint(x: translation.x * exportScale, y: translation.y * exportScale)
        // Fix for "video appears zoomed in whenever maxVideoExportPixelSize
        // actually caps the resolution" (2026-09-08) — the compositor draws
        // the decoded source frame at its own FULL NATIVE pixel size (see
        // MediaEditorVideoCompositor's `sourceImage`/`naturalSize`, entirely
        // independent of exportScale), scaled only by `instruction.scale`
        // (the user's own pinch-zoom gesture, `currentScale`). When the cap
        // doesn't engage, `cropRectInExport` was DERIVED from the native
        // resolution in the first place (rawExportScale), so native-size
        // content naturally fills it correctly. Once the cap shrinks
        // `exportScale` below `rawExportScale`, `cropRectInExport` shrinks
        // too but the native-size source image doesn't — drawing full-res
        // content into a now-smaller canvas at the same `instruction.scale`
        // makes the video appear zoomed in by exactly the inverse of the
        // cap ratio. Folding that ratio into the scale passed to the
        // instruction (1.0 whenever the cap doesn't engage) corrects this
        // without touching either compositing path — both read the same
        // `instruction.scale`.
        let videoContentScale = scale * (exportScale / rawExportScale)

        NSLog("[MediaEditor] exportVideo: about to render %d overlay image(s)", overlaySnapshots.count)
        // Rendering a UILabel and calling layer.render(in:) must happen on
        // the main thread — this Task otherwise runs on a background
        // executor once it hits the first `await` above.
        let overlayLayers: [MediaEditorVideoOverlayLayer] = await MainActor.run {
          // (zIndex, layer) — sorted into on-screen stacking order at the end.
          var layers: [(Int, MediaEditorVideoOverlayLayer)] = []

          // Draw strokes, added FIRST so they sit under text/sticker/
          // overlay layers, matching renderExport's on-screen/image-export
          // stacking order (strokes drawn right after the base image,
          // before any layer). One full-frame image anchored at the
          // canvas's own center with no rotation/scale — see
          // renderStrokesOverlayImage's doc for why no base-anchor offset
          // is needed here, unlike the layer types below.
          let strokesImage = self.renderStrokesOverlayImage(
            strokes: strokeSnapshots, size: cropRectInExport.size, exportScale: exportScale
          )
          NSLog("[MediaEditor] exportVideo: strokesImage=%@ size=%@", strokesImage != nil ? "yes" : "nil", "\(cropRectInExport.size)")
          if let strokesImage {
            layers.append((strokesZIndex, MediaEditorVideoOverlayLayer(
              image: strokesImage, size: cropRectInExport.size, centerInExport: canvasCenterInExport, rotation: 0, scale: 1
            )))
          }

          layers.append(contentsOf: overlaySnapshots.compactMap { snapshot -> (Int, MediaEditorVideoOverlayLayer)? in
            // Sticker layers draw their bundled image directly (same
            // renderer image overlays use) instead of re-rendering `text`
            // as a glyph — see VideoOverlaySnapshot.stickerImage's doc.
            // Each branch's own intended export-scaled draw size travels
            // alongside its image — see MediaEditorVideoOverlayLayer.size's
            // own doc for why this can't be reconstructed from the
            // rendered image's own pixel dimensions later.
            let imageAndSize: (image: CGImage, size: CGSize)?
            if let stickerImage = snapshot.stickerImage {
              let scaledStickerSize = CGSize(width: snapshot.stickerSize.width * exportScale, height: snapshot.stickerSize.height * exportScale)
              imageAndSize = self.renderImageOverlayImage(image: stickerImage, size: snapshot.stickerSize, exportScale: exportScale)
                .map { (image: $0, size: scaledStickerSize) }
            } else if let style = snapshot.style {
              imageAndSize = self.renderOverlayImage(text: snapshot.text, style: style, exportScale: exportScale)
            } else {
              imageAndSize = nil
            }
            guard let imageAndSize else { return nil }
            // Must match addTextLayer's actual base anchor exactly — see
            // the comment on drawLayerForExport's identical computation.
            let centerInCanvas = Self.exportCenterInCanvas(translation: snapshot.translation, canvasCenter: canvasCenter)
            // Y is mirrored around the frame's own vertical center
            // (cropRectInExport.height - y) — per the user's explicit
            // "sticker was above text, both near the top; after export
            // they're both near the bottom AND swapped order" report,
            // confirmed by screenshot: exactly the signature of every
            // overlay's Y position being reflected top-to-bottom (which
            // also explains the reversed relative order — whichever was
            // higher lands lower). Video content itself and image export's
            // own identical positioning math are both independently
            // confirmed correct, so this reflection is specific to the
            // video overlay-compositing path.
            let centerInExport = CGPoint(x: centerInCanvas.x * exportScale, y: cropRectInExport.height - (centerInCanvas.y * exportScale))
            return (snapshot.zIndex, MediaEditorVideoOverlayLayer(
              image: imageAndSize.image,
              size: imageAndSize.size,
              centerInExport: centerInExport,
              rotation: snapshot.rotation,
              scale: snapshot.scale,
              visibleRanges: snapshot.visibleRanges,
              anim: snapshot.anim
            ))
          })

          // Overlay (image-over-image) layers — drawn last, matching
          // renderExport's identical ordering.
          let imageOverlayLayers = imageOverlaySnapshots.compactMap { snapshot -> (Int, MediaEditorVideoOverlayLayer)? in
            guard let cgImage = self.renderImageOverlayImage(
              image: snapshot.image, size: snapshot.size, exportScale: exportScale
            ) else { return nil }
            // Same base anchor as text/sticker above — must match
            // addImageOverlayLayer's constraint exactly.
            let centerInCanvas = CGPoint(
              x: canvasCenter.x + snapshot.translation.x,
              y: canvasCenter.y + Self.newLayerVerticalOffset + snapshot.translation.y
            )
            // Same Y-mirror as the text/sticker case above — see its
            // comment for why.
            let centerInExport = CGPoint(x: centerInCanvas.x * exportScale, y: cropRectInExport.height - (centerInCanvas.y * exportScale))
            return (snapshot.zIndex, MediaEditorVideoOverlayLayer(
              image: cgImage,
              size: CGSize(width: snapshot.size.width * exportScale, height: snapshot.size.height * exportScale),
              centerInExport: centerInExport,
              rotation: snapshot.rotation,
              scale: snapshot.scale,
              visibleRanges: snapshot.visibleRanges
            ))
          }
          layers.append(contentsOf: imageOverlayLayers)

          NSLog(
            "[MediaEditor] exportVideo: imageOverlayLayers rendered=%d of %d snapshots",
            imageOverlayLayers.count, imageOverlaySnapshots.count
          )
          // Stable sort: equal indexes keep their insertion order.
          return layers.enumerated()
            .sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
            .map { $0.element.1 }
        }
        NSLog("[MediaEditor] exportVideo: total overlayLayers=%d", overlayLayers.count)

        // Clamp each kept segment to the asset's real duration (in case it
        // was configured against a slightly different duration reading)
        // and drop any that collapse to nothing once clamped.
        let clampedSegments = videoSegments.compactMap { segment -> ClosedRange<Double>? in
          let start = max(0, min(segment.lowerBound, totalSeconds))
          let end = max(start, min(segment.upperBound, totalSeconds))
          return end > start ? start...end : nil
        }
        guard !clampedSegments.isEmpty else {
          await MainActor.run { completion(.failure(message: "Invalid trim range.")) }
          return
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
          await MainActor.run { completion(.failure(message: "Could not build the export composition.")) }
          return
        }
        compositionVideoTrack.preferredTransform = preferredTransform

        // Original audio + optional music mixing (Day 26c). Volume/mute is
        // applied via AVMutableAudioMixInputParameters per composition
        // audio track rather than by scaling samples ourselves — muting is
        // just a volume of 0, matching the live preview's own mute-via-
        // volume behavior (originalAudioVolumeSlider dragged to 0%).
        var audioMixParameters: [AVMutableAudioMixInputParameters] = []
        var originalAudioParamsRef: AVMutableAudioMixInputParameters?
        let sourceAudioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let compositionAudioTrack = sourceAudioTrack != nil
          ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
          : nil
        // The audio track's OWN real duration can be a little shorter than
        // the video track's / the asset's overall duration (common in
        // real-world files, especially re-encoded or forwarded videos) —
        // clampedSegments above is clamped against the VIDEO-driven
        // `totalSeconds` only. insertTimeRange THROWS (not a partial
        // insert) if asked for a range past a track's own real content, so
        // without this, a single segment reaching even slightly past the
        // audio track's real end silently dropped ALL audio for that
        // segment via the `try?` below. Clamping per-track here means
        // audio still gets inserted for whatever portion actually exists.
        var audioTrackDurationSeconds = totalSeconds
        if let sourceAudioTrack, let audioTimeRange = try? await sourceAudioTrack.load(.timeRange) {
          let loadedDuration = CMTimeGetSeconds(audioTimeRange.duration)
          if loadedDuration.isFinite, loadedDuration > 0 {
            audioTrackDurationSeconds = loadedDuration
          }
        }

        // Each kept segment is inserted BACK-TO-BACK (advancing `insertionPoint`
        // by each segment's own duration) — this is what actually concatenates
        // the kept parts and drops the deleted ones from the exported file,
        // the same "multiple insertTimeRange calls into one track" technique
        // used for trim before, just repeated once per segment instead of once
        // total. The custom compositor (MediaEditorVideoCompositor) applies the
        // SAME per-frame filter/crop/overlay regardless of which original
        // segment a given composition-frame came from, so nothing else about
        // the instruction/compositor needs to know segments exist at all.
        var insertionPoint = CMTime.zero
        for segment in clampedSegments {
          let segmentRange = CMTimeRange(
            start: CMTime(seconds: segment.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: segment.upperBound, preferredTimescale: 600)
          )
          try compositionVideoTrack.insertTimeRange(segmentRange, of: sourceTrack, at: insertionPoint)
          if let sourceAudioTrack, let compositionAudioTrack {
            let audioSegmentEnd = min(segment.upperBound, audioTrackDurationSeconds)
            if audioSegmentEnd > segment.lowerBound {
              let audioSegmentRange = CMTimeRange(
                start: CMTime(seconds: segment.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: audioSegmentEnd, preferredTimescale: 600)
              )
              do {
                try compositionAudioTrack.insertTimeRange(audioSegmentRange, of: sourceAudioTrack, at: insertionPoint)
              } catch {
                NSLog("[MediaEditor] exportVideo: original-audio insertTimeRange failed for segment %@: %@", "\(segment)", error.localizedDescription)
              }
            }
          }
          var placedDuration = segmentRange.duration
          // Each part exports at its own speed.
          let primarySpeed = Self.partSpeed(primarySpeedSpans, segment)
          if primarySpeed != 1 {
            // Speed control: stretch / squeeze this piece in place.
            placedDuration = CMTimeMultiplyByFloat64(segmentRange.duration, multiplier: 1 / primarySpeed)
            let placed = CMTimeRange(start: insertionPoint, duration: segmentRange.duration)
            compositionVideoTrack.scaleTimeRange(placed, toDuration: placedDuration)
            compositionAudioTrack?.scaleTimeRange(placed, toDuration: placedDuration)
          }
          insertionPoint = insertionPoint + placedDuration
        }
        let totalKeptDuration = insertionPoint

        if let compositionAudioTrack {
          let originalAudioParams = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
          // Per-clip volume: the main clip's from 0, each merged clip's from
          // its own start (set in the merged-clip loop below).
          originalAudioParams.setVolume(originalAudioEffectiveVolume * primaryClipVolume, at: .zero)
          audioMixParameters.append(originalAudioParams)
          originalAudioParamsRef = originalAudioParams
        }

        if let musicTrack, musicClipEnd > musicClipStart, !musicSegmentsSnapshot.isEmpty {
          let musicAsset = AVURLAsset(url: musicSourceURL ?? musicTrack.audioURL)
          if let sourceMusicTrack = try? await musicAsset.loadTracks(withMediaType: .audio).first {
            // Clamp so no music segment ever outlasts the (already-
            // trimmed/split) main video, and each is inserted as its own
            // independent segment at its own combined-timeline position —
            // not muxed onto the video's own audio track — so an
            // unclamped range would otherwise extend the whole
            // composition's duration past the video itself. ALSO clamped
            // against the music track's own real duration (same
            // "insertTimeRange throws, not truncates, past a track's real
            // content" reasoning as the original-audio and merged-clip
            // insertions above) in case musicClipEnd was ever computed
            // against a slightly-stale duration reading.
            let totalKeptSeconds = CMTimeGetSeconds(totalKeptDuration)
            var musicSourceDurationSeconds = musicClipEnd
            if let musicTimeRangeLoaded = try? await sourceMusicTrack.load(.timeRange) {
              let loadedDuration = CMTimeGetSeconds(musicTimeRangeLoaded.duration)
              if loadedDuration.isFinite, loadedDuration > 0 {
                musicSourceDurationSeconds = min(musicSourceDurationSeconds, loadedDuration)
              }
            }
            // Per the user's explicit "same split music layer also"
            // request — music can now have multiple segments (visibility
            // windows on the combined timeline, exactly like a text/
            // sticker layer's own segments), each inserted independently
            // into ONE shared composition track so any gap between them
            // (a deleted middle portion) plays as silence rather than
            // muxing everything into one contiguous block. The SOURCE
            // file position for each segment is computed relative to the
            // FIRST segment's own start (anchor) so the song's own
            // internal pacing stays continuous straight through a gap —
            // deleting a portion mutes the video during that window
            // without skipping ahead in the song, matching how playback
            // preview (updateMusicPlaybackWindow) already behaves.
            let anchor = musicSegmentsSnapshot.first?.lowerBound ?? musicOffsetValue
            var compositionMusicTrack: AVMutableCompositionTrack?
            for segment in musicSegmentsSnapshot {
              let clampedStart = max(0, min(segment.lowerBound, totalKeptSeconds))
              let clampedEnd = max(clampedStart, min(segment.upperBound, totalKeptSeconds))
              guard clampedEnd > clampedStart else { continue }
              let sourceStart = max(musicClipStart, min(musicClipStart + (clampedStart - anchor), musicSourceDurationSeconds))
              let sourceEnd = max(sourceStart, min(musicClipStart + (clampedEnd - anchor), musicSourceDurationSeconds))
              let segmentDuration = sourceEnd - sourceStart
              guard segmentDuration > 0 else { continue }
              if compositionMusicTrack == nil {
                compositionMusicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
              }
              guard let track = compositionMusicTrack else { continue }
              let musicTimeRange = CMTimeRange(
                start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: segmentDuration, preferredTimescale: 600)
              )
              do {
                try track.insertTimeRange(musicTimeRange, of: sourceMusicTrack, at: CMTime(seconds: clampedStart, preferredTimescale: 600))
              } catch {
                NSLog("[MediaEditor] exportVideo: music insertTimeRange failed for segment %@: %@", "\(segment)", error.localizedDescription)
              }
            }
            if let compositionMusicTrack {
              let musicParams = AVMutableAudioMixInputParameters(track: compositionMusicTrack)
              musicParams.setVolume(musicVolume, at: .zero)
              // Fade in/out audio: ramps where the music starts / ends.
              let musicStart = max(0, min(musicSegmentsSnapshot.first?.lowerBound ?? 0, totalKeptSeconds))
              let musicEnd = max(musicStart, min(musicSegmentsSnapshot.last?.upperBound ?? 0, totalKeptSeconds))
              let rampLength = min(fadeSeconds, (musicEnd - musicStart) / 2)
              if rampLength > 0.05 {
                if fadeIn {
                  musicParams.setVolumeRamp(fromStartVolume: 0, toEndVolume: musicVolume, timeRange: CMTimeRange(
                    start: CMTime(seconds: musicStart, preferredTimescale: 600), duration: CMTime(seconds: rampLength, preferredTimescale: 600)))
                }
                if fadeOut {
                  musicParams.setVolumeRamp(fromStartVolume: musicVolume, toEndVolume: 0, timeRange: CMTimeRange(
                    start: CMTime(seconds: musicEnd - rampLength, preferredTimescale: 600), duration: CMTime(seconds: rampLength, preferredTimescale: 600)))
                }
              }
              if voiceURL != nil {
                Self.addDuckRamps(musicParams, level: musicVolume, duck: duckLevel, start: voiceOutStart, end: min(voiceOutEnd, totalKeptSeconds))
              }
              audioMixParameters.append(musicParams)
            }
          }
        }
        // Voice-over: its own track at its place on the output timeline.
        if let voiceURL {
          let voiceAsset = AVURLAsset(url: voiceURL)
          if let voiceSource = try? await voiceAsset.loadTracks(withMediaType: .audio).first,
             let voiceTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let totalSeconds = CMTimeGetSeconds(totalKeptDuration)
            let length = min(self.voiceOverDurationSnapshot(voiceAsset), max(0, totalSeconds - voiceOutStart))
            if length > 0.05 {
              try? voiceTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600)),
                of: voiceSource, at: CMTime(seconds: voiceOutStart, preferredTimescale: 600))
            }
          }
        }

        let instruction = MediaEditorVideoInstruction(
          timeRange: CMTimeRange(start: .zero, duration: totalKeptDuration),
          sourceTrackID: compositionVideoTrack.trackID,
          sourceTransform: preferredTransform,
          cropRectInExport: cropRectInExport,
          canvasCenterInExport: canvasCenterInExport,
          translationInExport: translationInExport,
          rotation: rotation,
          scale: videoContentScale,
          filter: filter,
          filterStrength: filterStrength,
          filterSaturation: filterSaturation,
          filterSharpness: filterSharpness,
          adjustments: adjustments,
          overlayLayers: overlayLayers
        )

        // Merged clips (see rebuildVideoQueue's own doc): each is appended
        // in full, in order, into the SAME composition tracks — right
        // after the primary clip's own kept segments, then each other.
        // Each now carries its OWN filter/adjustments (clipFilterStateSnapshot,
        // below) — pan/zoom/text-overlays stay primary-clip-only — plus
        // each one's own orientation correction and an aspect-FIT (never
        // crop) into the fixed render size the primary instruction above
        // already established.
        var additionalInstructions: [MediaEditorVideoInstruction] = []
        var additionalInstructionURLs: [URL] = []
        for additionalClipURL in additionalClipURLs {
          let additionalAsset = AVURLAsset(url: additionalClipURL)
          guard
            let additionalSourceTrack = try? await additionalAsset.loadTracks(withMediaType: .video).first,
            let additionalNaturalSize = try? await additionalSourceTrack.load(.naturalSize),
            let additionalPreferredTransform = try? await additionalSourceTrack.load(.preferredTransform),
            let additionalAssetDuration = try? await additionalAsset.load(.duration)
          else { continue }
          let additionalSeconds = CMTimeGetSeconds(additionalAssetDuration)
          let additionalTransformedSize = additionalNaturalSize.applying(additionalPreferredTransform)
          let additionalNativeWidth = abs(additionalTransformedSize.width)
          let additionalNativeHeight = abs(additionalTransformedSize.height)
          guard additionalSeconds.isFinite, additionalSeconds > 0, additionalNativeWidth > 0, additionalNativeHeight > 0
          else { continue }
          // Use the user's saved KEPT SEGMENTS (see refreshMergedClipsStrip
          // / splitMergedClipSegment / deleteMergedClipSegment) if this
          // clip has any, clamped to the asset's real duration same as the
          // primary clip's own segments are — otherwise the full clip as
          // one segment. Each is inserted BACK-TO-BACK (advancing
          // `insertionPoint` by each segment's own duration) — the exact
          // same "multiple insertTimeRange calls into one track" technique
          // the primary clip's own segments use just above, repeated once
          // per segment instead of once total, with one
          // MediaEditorVideoInstruction per segment sharing this clip's
          // SAME transform/scale (only the timeRange differs).
          let rawSegments = additionalClipSegments[additionalClipURL] ?? [0...additionalSeconds]
          let clampedAdditionalSegments = rawSegments.compactMap { segment -> ClosedRange<Double>? in
            let start = max(0, min(segment.lowerBound, additionalSeconds))
            let end = max(start, min(segment.upperBound, additionalSeconds))
            return end > start ? start...end : nil
          }
          guard !clampedAdditionalSegments.isEmpty else { continue }
          // Loaded ONCE per clip (was re-loaded inside the per-segment loop
          // below, redundant work for a clip split into multiple kept
          // segments) — same duration-clamp reasoning as the primary
          // clip's own audio insertion above: this clip's audio track can
          // be a little shorter than its video track, and insertTimeRange
          // throws (not a partial insert) rather than silently truncating.
          let additionalSourceAudioTrack = compositionAudioTrack != nil
            ? try? await additionalAsset.loadTracks(withMediaType: .audio).first
            : nil
          var additionalAudioDurationSeconds = additionalSeconds
          if let additionalSourceAudioTrack, let audioTimeRange = try? await additionalSourceAudioTrack.load(.timeRange) {
            let loadedDuration = CMTimeGetSeconds(audioTimeRange.duration)
            if loadedDuration.isFinite, loadedDuration > 0 {
              additionalAudioDurationSeconds = loadedDuration
            }
          }
          // renderSize is fixed for the whole composition (set once,
          // below, from the PRIMARY clip's own cropRectInExport) — every
          // additional clip must be scaled/centered to exactly fill that
          // SAME buffer, not re-derive its own exportScale/cropRect the
          // way the primary clip does (that formula ties the crop rect's
          // SIZE to the primary clip's own resolution, which would
          // produce a mismatched buffer size here).
          let fitScale = min(
            cropRectInExport.width / additionalNativeWidth,
            cropRectInExport.height / additionalNativeHeight
          )
          // Each merged clip now carries its OWN filter/adjustments (see
          // clipFilterState's own doc) — per the user's explicit "edits
          // should stay with their own clip" request. Pan/zoom/text-
          // overlays remain primary-clip-only (text/sticker/overlay layers
          // are positioned by TIME across the whole combined timeline, not
          // per-clip, so they're unaffected by reordering).
          let additionalFilterState = clipFilterStateSnapshot[additionalClipURL] ?? ClipFilterState()
          for segment in clampedAdditionalSegments {
            let additionalTimeRange = CMTimeRange(
              start: CMTime(seconds: segment.lowerBound, preferredTimescale: 600),
              end: CMTime(seconds: segment.upperBound, preferredTimescale: 600)
            )
            let additionalClipStart = insertionPoint
            try? compositionVideoTrack.insertTimeRange(additionalTimeRange, of: additionalSourceTrack, at: additionalClipStart)
            originalAudioParamsRef?.setVolume(originalAudioEffectiveVolume * (clipVolumesSnapshot[additionalClipURL] ?? 1), at: additionalClipStart)
            if let compositionAudioTrack, let additionalSourceAudioTrack {
              let audioSegmentEnd = min(segment.upperBound, additionalAudioDurationSeconds)
              if audioSegmentEnd > segment.lowerBound {
                let additionalAudioRange = CMTimeRange(
                  start: CMTime(seconds: segment.lowerBound, preferredTimescale: 600),
                  end: CMTime(seconds: audioSegmentEnd, preferredTimescale: 600)
                )
                do {
                  try compositionAudioTrack.insertTimeRange(additionalAudioRange, of: additionalSourceAudioTrack, at: additionalClipStart)
                } catch {
                  NSLog("[MediaEditor] exportVideo: merged-clip audio insertTimeRange failed for segment %@: %@", "\(segment)", error.localizedDescription)
                }
              }
            }
            let additionalSpeed = Self.partSpeed(speedSpansSnapshot[additionalClipURL], segment)
            var additionalPlacedDuration = additionalTimeRange.duration
            if additionalSpeed != 1 {
              additionalPlacedDuration = CMTimeMultiplyByFloat64(additionalTimeRange.duration, multiplier: 1 / additionalSpeed)
              let placed = CMTimeRange(start: additionalClipStart, duration: additionalTimeRange.duration)
              compositionVideoTrack.scaleTimeRange(placed, toDuration: additionalPlacedDuration)
              compositionAudioTrack?.scaleTimeRange(placed, toDuration: additionalPlacedDuration)
            }
            insertionPoint = insertionPoint + additionalPlacedDuration
            additionalInstructionURLs.append(additionalClipURL)
            additionalInstructions.append(MediaEditorVideoInstruction(
              timeRange: CMTimeRange(start: additionalClipStart, duration: additionalPlacedDuration),
              sourceTrackID: compositionVideoTrack.trackID,
              sourceTransform: additionalPreferredTransform,
              cropRectInExport: cropRectInExport,
              canvasCenterInExport: CGPoint(x: cropRectInExport.width / 2, y: cropRectInExport.height / 2),
              translationInExport: .zero,
              rotation: 0,
              scale: fitScale,
              filter: additionalFilterState.filter,
              filterStrength: additionalFilterState.filterStrength,
              filterSaturation: additionalFilterState.filterSaturation,
              filterSharpness: additionalFilterState.filterSharpness,
              adjustments: additionalFilterState.adjustments,
              // Layers span the whole combined timeline in the editor, so
              // they're drawn over merged clips too (each one only inside
              // its own time windows — see visibleRanges).
              overlayLayers: overlayLayers
            ))
          }
        }
        let finalDuration = insertionPoint
        // Voice-over ducking of the clips' own sound.
        if voiceURL != nil, let originalAudioParamsRef {
          Self.addDuckRamps(originalAudioParamsRef, level: originalAudioEffectiveVolume * voiceClipVolume, duck: duckLevel,
                            start: voiceOutStart, end: min(voiceOutEnd, CMTimeGetSeconds(finalDuration)))
        }
        // Fade in/out audio: the clip's own sound at the video's start / end.
        if let originalAudioParamsRef, fadeIn || fadeOut {
          let total = CMTimeGetSeconds(finalDuration)
          let rampLength = min(fadeSeconds, total / 2)
          if rampLength > 0.05 {
            if fadeIn {
              originalAudioParamsRef.setVolumeRamp(fromStartVolume: 0, toEndVolume: originalAudioEffectiveVolume * primaryClipVolume,
                                                   timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: rampLength, preferredTimescale: 600)))
            }
            if fadeOut {
              let v = originalAudioEffectiveVolume * lastClipVolume
              originalAudioParamsRef.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(
                start: CMTime(seconds: total - rampLength, preferredTimescale: 600), duration: CMTime(seconds: rampLength, preferredTimescale: 600)))
            }
          }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = cropRectInExport.size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.customVideoCompositorClass = MediaEditorVideoCompositor.self
        // Transitions: into each merged clip's first piece, and out of the
        // last piece of whatever plays before it.
        var previousLast: MediaEditorVideoInstruction = instruction
        var index = 0
        while index < additionalInstructions.count {
          let url = additionalInstructionURLs[index]
          var lastIndex = index
          while lastIndex + 1 < additionalInstructions.count, additionalInstructionURLs[lastIndex + 1] == url { lastIndex += 1 }
          let type = transitionsSnapshot[url] ?? 0
          if type != 0 {
            additionalInstructions[index].transitionIn = type
            previousLast.transitionOut = type
          }
          previousLast = additionalInstructions[lastIndex]
          index = lastIndex + 1
        }
        videoComposition.instructions = [instruction] + additionalInstructions

        guard let exportSession = AVAssetExportSession(
          asset: composition, presetName: AVAssetExportPresetHighestQuality
        ) else {
          await MainActor.run { completion(.failure(message: "Could not create the export session.")) }
          return
        }
        exportSession.videoComposition = videoComposition
        if !audioMixParameters.isEmpty {
          let audioMix = AVMutableAudioMix()
          audioMix.inputParameters = audioMixParameters
          exportSession.audioMix = audioMix
        }
        let outputURL = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension("mp4")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        // Speed control: sped-up / slowed clips keep their voice pitch.
        exportSession.audioTimePitchAlgorithm = .spectral
        // Exposed so the progress overlay's cancel button and polling
        // timer (both main-thread/UI-driven) have something to act on —
        // this Task's own body doesn't run on the main actor (see the
        // `await MainActor.run` wraps throughout this function), so this
        // assignment needs the same hop.
        let alreadyCancelled = await MainActor.run { () -> Bool in
          self.currentExportSession = exportSession
          return self.exportWasCancelled
        }
        // Covers the brief window between tapping Done (which can be
        // immediately followed by tapping the overlay's X) and this point
        // — everything above is just track-loading/composition-building,
        // no encoding has started yet, so bailing here avoids kicking off
        // real encode work for an export the user already cancelled.
        guard !alreadyCancelled else {
          await MainActor.run { completion(.failure(message: "Cancelled.")) }
          return
        }

        NSLog("[MediaEditor] exportVideo: starting AVAssetExportSession, renderSize=%@", "\(videoComposition.renderSize)")
        exportSession.exportAsynchronously {
          DispatchQueue.main.async {
            NSLog("[MediaEditor] exportVideo: AVAssetExportSession finished with status=%d error=%@",
                  exportSession.status.rawValue, exportSession.error?.localizedDescription ?? "nil")
            switch exportSession.status {
            case .completed:
              completion(.success(
                url: outputURL,
                size: cropRectInExport.size,
                duration: CMTimeGetSeconds(finalDuration)
              ))
            default:
              completion(.failure(message: exportSession.error?.localizedDescription ?? "Video export failed."))
            }
          }
        }
      } catch {
        NSLog("[MediaEditor] exportVideo: threw error=%@", error.localizedDescription)
        await MainActor.run { completion(.failure(message: error.localizedDescription)) }
      }
    }
  }

  // MARK: - Pan / pinch / rotate

  private func setUpTransformGestures() {
    let target = activeMediaView
    target.isUserInteractionEnabled = true

    let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
    // Deselects any active layer + hides its action toolbar when the
    // canvas itself (not a text/sticker layer) is tapped. Deliberately
    // scoped to `activeMediaView` only, NOT the full-screen `view` — a
    // view-wide tap gesture would sit above every button in the editor
    // (top bar, tab bar, the layer toolbar itself) and risks cancelling
    // their own touch handling, an interaction bug that can't be verified
    // without a device. Accepted minor gap: tapping the empty margin
    // around the canvas box doesn't deselect (Android's touch-dispatch
    // model doesn't share this risk, so it covers that case — see
    // LayerGestureCoordinator.onLayerTapped).
    let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(didTapCanvasBackground))
    panGesture.delegate = self
    pinchGesture.delegate = self
    rotationGesture.delegate = self
    backgroundTap.delegate = self

    target.addGestureRecognizer(panGesture)
    target.addGestureRecognizer(pinchGesture)
    target.addGestureRecognizer(rotationGesture)
    target.addGestureRecognizer(backgroundTap)

    // Stored so selectLayer/deselectLayer can toggle JUST these 3 (not
    // backgroundTap, which must stay enabled so tapping the canvas can
    // still deselect) — see canvasTransformGesturesEnabled's doc.
    canvasPanGesture = panGesture
    canvasPinchGesture = pinchGesture
    canvasRotationGesture = rotationGesture
  }

  /// Locks the base canvas out of pan/pinch/rotate while a text/sticker/
  /// overlay layer is selected, per the user's explicit request:
  /// manipulating a newly-added element should never also move/zoom/
  /// rotate the photo underneath. Deliberately leaves the canvas's OWN tap
  /// gesture (didTapCanvasBackground) untouched — disabling
  /// `isUserInteractionEnabled` on the whole view would have blocked that
  /// too, permanently trapping the user with no way to tap-to-deselect.
  private func setCanvasTransformGesturesEnabled(_ enabled: Bool) {
    canvasPanGesture?.isEnabled = enabled
    canvasPinchGesture?.isEnabled = enabled
    canvasRotationGesture?.isEnabled = enabled
  }

  @objc private func didTapCanvasBackground() {
    deselectLayer()
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    trackCanvasTransformGesture(gesture)
    // Reported in `view`'s frame (never itself transformed), not imageView's
    // own — otherwise the pan direction would follow the image's current
    // rotation/scale instead of the finger's actual on-screen movement.
    let translation = gesture.translation(in: view)
    currentTranslation.x += translation.x
    currentTranslation.y += translation.y
    gesture.setTranslation(.zero, in: view)
    clampTranslationToBounds()
    updateImageTransform()
  }

  @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    trackCanvasTransformGesture(gesture)
    let proposed = currentScale * gesture.scale
    currentScale = min(max(proposed, Self.minScale), Self.maxScale)
    gesture.scale = 1
    clampTranslationToBounds()
    updateImageTransform()
  }

  /// Keeps the image/video covering its own canvas box at all times — at
  /// `currentScale`, the maximum offset in either axis before an edge
  /// would recede past the box's edge (revealing empty space) is
  /// `size * (scale - 1) / 2`. Ignores `currentRotation` deliberately —
  /// bounding a rotated rectangle's coverage is a materially bigger
  /// geometry problem, and rotation wasn't part of what was asked for.
  private func clampTranslationToBounds() {
    let bounds = activeMediaView.bounds
    let maxOffsetX = bounds.width * (currentScale - 1) / 2
    let maxOffsetY = bounds.height * (currentScale - 1) / 2
    currentTranslation.x = min(max(currentTranslation.x, -maxOffsetX), maxOffsetX)
    currentTranslation.y = min(max(currentTranslation.y, -maxOffsetY), maxOffsetY)
  }

  @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
    trackCanvasTransformGesture(gesture)
    currentRotation += gesture.rotation
    gesture.rotation = 0
    updateImageTransform()
  }

  // Same ID-set tracking as trackTransformGesture, for the base canvas
  // (photo/video itself) rather than a text/sticker/overlay layer — kept
  // as a separate snapshot since it restores `currentTranslation`/
  // `currentScale`/`currentRotation` + `updateImageTransform()` directly
  // instead of going through EditableLayerView's applyInitialTransform.
  private var canvasTransformSnapshot: (translation: CGPoint, scale: CGFloat, rotation: CGFloat)?
  private var activeCanvasTransformGestureIDs: Set<ObjectIdentifier> = []

  private func trackCanvasTransformGesture(_ gesture: UIGestureRecognizer) {
    let id = ObjectIdentifier(gesture)
    switch gesture.state {
    case .began:
      activeCanvasTransformGestureIDs.insert(id)
      if canvasTransformSnapshot == nil {
        canvasTransformSnapshot = (currentTranslation, currentScale, currentRotation)
      }
    case .ended, .cancelled, .failed:
      activeCanvasTransformGestureIDs.remove(id)
      if activeCanvasTransformGestureIDs.isEmpty {
        commitCanvasTransformUndo()
      }
    default:
      break
    }
  }

  private func commitCanvasTransformUndo() {
    guard let snapshot = canvasTransformSnapshot else { return }
    canvasTransformSnapshot = nil
    let oldTranslation = snapshot.translation
    let oldScale = snapshot.scale
    let oldRotation = snapshot.rotation
    let newTranslation = currentTranslation
    let newScale = currentScale
    let newRotation = currentRotation
    guard oldTranslation != newTranslation || oldScale != newScale || oldRotation != newRotation else { return }
    pushUndo(
      undo: { [weak self] in
        guard let self else { return }
        self.currentTranslation = oldTranslation
        self.currentScale = oldScale
        self.currentRotation = oldRotation
        self.updateImageTransform()
      },
      redo: { [weak self] in
        guard let self else { return }
        self.currentTranslation = newTranslation
        self.currentScale = newScale
        self.currentRotation = newRotation
        self.updateImageTransform()
      }
    )
  }

  private func updateImageTransform() {
    var transform = CGAffineTransform.identity
    transform = transform.translatedBy(x: currentTranslation.x, y: currentTranslation.y)
    transform = transform.rotated(by: currentRotation)
    transform = transform.scaledBy(x: currentScale, y: currentScale)
    activeMediaView.transform = transform
  }

  /// Decodes at display resolution instead of full pixel dimensions — a
  /// full-res decode of a 12MP+ photo risks OOM for no visual benefit at
  /// preview scale. kCGImageSourceCreateThumbnailWithTransform bakes in EXIF
  /// orientation, so the result is already upright.
  private static func loadDownsampledImage(
    from url: URL,
    maxPixelSize: CGFloat,
    completion: @escaping (UIImage?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
      guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ]
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        .map(UIImage.init(cgImage:))
      DispatchQueue.main.async { completion(image) }
    }
  }
}

extension MediaEditorViewController: UIGestureRecognizerDelegate {
  // Lets pan/pinch/rotate all recognize at once, matching the combined
  // gesture feel users expect from a photo editor.
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }

  // Per the user's explicit "when I am touching any specific layer then
  // selected layer's icon/text is also moving on video canvas... these
  // should not be disturbed while touching layers" report. `selectLayer`
  // (fired from LayerRangeBarView.onItemSelected, itself fired from
  // touchesBegan — i.e. mid-touch, while the SAME finger that's dragging
  // a layer's timeline bar is still down) enables
  // sharedLayerPan/Pinch/RotationGesture. Since those 3 are attached
  // directly to `view` (an ancestor of the whole layer-tracks panel) with
  // no delegate check on WHICH touches they're allowed to consider, a
  // gesture recognizer enabled mid-touch can still pick up that
  // already-in-progress touch stream on its next movement — so the exact
  // same drag meant to trim a layer's time range in the timeline was
  // ALSO being read as a pan on that just-selected layer's on-canvas
  // position. Scoped narrowly to only these 3 shared gestures (every
  // other gesture — filmstrip/layerTracks scrolling, LayerRangeBarView's
  // own raw touch handling, etc. — is unaffected) and only refuses
  // touches that originate inside layerTracksScrollView; a touch that
  // starts directly on the canvas continues to work exactly as before.
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard
      gestureRecognizer === sharedLayerPanGesture
        || gestureRecognizer === sharedLayerPinchGesture
        || gestureRecognizer === sharedLayerRotationGesture
    else { return true }
    guard let touchedView = touch.view else { return true }
    if touchedView.isDescendant(of: layerTracksScrollView) { return false }
    // Same class of bug as the layerTracksScrollView guard above, a
    // different culprit — per the user's explicit "long press activates a
    // layer but single tap doesn't" report. These 3 shared gestures are
    // attached to `view` (an ancestor of every on-canvas layer) with no
    // touch restriction otherwise, so tapping a DIFFERENT, not-yet-
    // selected layer while one is already selected let them pick up that
    // same touch too — moving/pinching the WRONG (still-selected) layer
    // via fallbackTarget, and (per UIGestureRecognizer's default
    // cancelsTouchesInView) sometimes cancelling the new layer's own tap
    // gesture outright before it could recognize. A long-press held
    // perfectly still for its own ~0.4s timeout gave the shared pan
    // gesture plenty of time to cleanly FAIL first instead of racing the
    // tap, which is why only long-press reliably worked. Refusing a touch
    // that starts on any OTHER layer (empty canvas and the selected
    // layer's own bounds are both still allowed — that's the whole point
    // of "drag anywhere on screen to keep manipulating the selection")
    // fixes tap-to-switch-selection without touching the Instagram-style
    // drag-anywhere behavior at all.
    if let touchedLayer = allLayerViews().first(where: { $0 === touchedView }), touchedLayer !== selectedLayer {
      return false
    }
    // One-finger drags move the selected layer only when they start on it
    // (with a little slack for small layers) — per the user's report that
    // dragging/scrolling anywhere on screen kept moving the text. Two-
    // finger pinch/rotate still work anywhere.
    if gestureRecognizer === sharedLayerPanGesture, let selected = selectedLayer {
      let hitArea = selected.frame.insetBy(dx: -24, dy: -24)
      if !hitArea.contains(touch.location(in: view)) { return false }
    }
    return true
  }
}

extension MediaEditorViewController: UITabBarDelegate {
  /// iOS 26 system tool bar: forward the tap to the tool's own button, then
  /// put the selection back on whatever is actually open.
  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard toolTabBarButtons.indices.contains(item.tag) else { return }
    toolTabBarButtons[item.tag].sendActions(for: .touchUpInside)
    DispatchQueue.main.async { [weak self] in self?.syncToolTabBarSelection() }
  }
}

extension MediaEditorViewController: UIScrollViewDelegate {
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guard scrollView === filmstripScrollView || scrollView === layerTracksScrollView else { return }
    isUserScrubbingFilmstrip = true
    // Like Android: playback pauses while the timeline is dragged (the
    // preview follows the finger) and carries on from the new spot on
    // release. Playing on underneath made the release seek fight the
    // still-running playback / loop-back.
    if isVideoPlaying {
      wasPlayingBeforeScrub = true
      setScrubPlayback(playing: false)
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard !isSyncingFilmstripAndLayerTracksScroll else { return }
    // Two-way horizontal mirror between filmstripScrollView and
    // layerTracksScrollView — per the user's reference multi-track
    // timeline, the layer rows must scroll in perfect lockstep with the
    // video row below them regardless of which one the user's own touch
    // actually landed on (layerTracksScrollView's vertical position is
    // left untouched, only .x is mirrored). Guarded by
    // isSyncingFilmstripAndLayerTracksScroll so setting the OTHER view's
    // contentOffset here doesn't re-enter this same method.
    if scrollView === filmstripScrollView {
      isSyncingFilmstripAndLayerTracksScroll = true
      layerTracksScrollView.contentOffset.x = scrollView.contentOffset.x
      isSyncingFilmstripAndLayerTracksScroll = false
      // Live, on every scroll delta regardless of source (user drag OR
      // our own programmatic playback-follow) — cheap (just flag toggles
      // + setNeedsDisplay), so updating it continuously is fine; the
      // actual player SEEK only happens once the user's drag settles,
      // below.
      updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer: isUserScrubbingFilmstrip)
      if isUserScrubbingFilmstrip {
        let combined = combinedTime(forScrollOffsetX: scrollView.contentOffset.x)
        updateVideoTimeLabel(current: combined)
        liveScrubSeek(to: combined)
      }
    } else if scrollView === layerTracksScrollView {
      isSyncingFilmstripAndLayerTracksScroll = true
      filmstripScrollView.contentOffset.x = scrollView.contentOffset.x
      isSyncingFilmstripAndLayerTracksScroll = false
      updateActiveClipHighlight(usingScrollOffsetInsteadOfPlayer: isUserScrubbingFilmstrip)
    }
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    guard scrollView === filmstripScrollView || scrollView === layerTracksScrollView, !decelerate else { return }
    finishTimelineScrub()
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    guard scrollView === filmstripScrollView || scrollView === layerTracksScrollView else { return }
    finishTimelineScrub()
  }
}

extension MediaEditorViewController: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider else { return }
    if provider.canLoadObject(ofClass: UIImage.self) {
      let editing = editingImageOverlayLayer
      provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
        guard let image = object as? UIImage else { return }
        DispatchQueue.main.async {
          guard let self else { return }
          // Added straight away at its own shape — cropping is optional,
          // later, from the overlay's Style → Crop (per the user's request).
          let photo = Self.overlayPhoto(from: image)
          if let editing {
            self.updateImageOverlayLayer(editing, image: photo, source: photo)
          } else {
            self.addImageOverlayLayer(image: photo, source: photo)
          }
        }
      }
    } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      // loadFileRepresentation can take a real, visible moment for a large
      // video (it's copying the file out of the Photos library, not just
      // handing back a reference) — per the user's explicit "show an
      // activity indicator until it loads" request, using this file's own
      // existing loadingIndicator start/stop pattern rather than a new one.
      loadingIndicator.startAnimating()
      provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
        guard let url else {
          DispatchQueue.main.async { self?.loadingIndicator.stopAnimating() }
          return
        }
        // The handed-back URL is a TEMPORARY file deleted the instant this
        // completion handler returns — must copy it somewhere persistent
        // synchronously, before returning, or export later finds nothing
        // there (same class of gotcha as the schemeless-path pickers
        // elsewhere in this file, just a different failure mode: here the
        // path is fine, it just stops existing).
        let destination = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        try? FileManager.default.copyItem(at: url, to: destination)
        DispatchQueue.main.async {
          self?.didPickSecondVideoClip(url: destination)
          self?.loadingIndicator.stopAnimating()
        }
      }
    }
  }
}

// MARK: - Location sticker rendering

/// Draws the Instagram-style location pill (pin + UPPERCASED place name).
/// Rendered at screen scale for a crisp on-screen layer; export draws the
/// same image scaled into the output (see the sticker branch of the image
/// export and VideoOverlaySnapshot.stickerImage).
enum LocationStickerRenderer {
  static let styleCount = 3
  private static let height: CGFloat = 40
  private static let horizontalPadding: CGFloat = 14
  private static let pinTextGap: CGFloat = 6
  private static let maxTextWidth: CGFloat = 260

  /// 0 = white pill/dark text, 1 = dark pill/white text, 2 = no pill,
  /// white text with a soft shadow.
  static func render(name: String, style: Int, symbol: String? = "mappin") -> UIImage {
    let ink = UIColor(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255, alpha: 1)
    let pillColor: UIColor? = style == 0 ? .white : (style == 1 ? ink : nil)
    let contentColor: UIColor = style == 0 ? ink : .white
    let font = UIFont(name: "DMSans-SemiBold", size: 16) ?? .systemFont(ofSize: 16, weight: .bold)

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: contentColor,
      .paragraphStyle: paragraph,
    ]
    let text = name.uppercased() as NSString
    let textWidth = min(ceil(text.size(withAttributes: attributes).width), maxTextWidth)

    let pin = symbol.flatMap { UIImage(
      systemName: $0,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    ) }?.withTintColor(contentColor, renderingMode: .alwaysOriginal)
    let pinSize = pin?.size ?? .zero
    let iconGap = pin == nil ? 0 : pinTextGap

    // Style 2 has no pill — extra margin keeps the shadow from clipping.
    let shadowInset: CGFloat = style == 2 ? 4 : 0
    let size = CGSize(
      width: ceil(horizontalPadding * 2 + pinSize.width + iconGap + textWidth + shadowInset * 2),
      height: height + shadowInset * 2
    )

    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
      let ctx = rendererContext.cgContext
      let pillRect = CGRect(x: shadowInset, y: shadowInset, width: size.width - shadowInset * 2, height: height)
      if let pillColor {
        pillColor.setFill()
        UIBezierPath(roundedRect: pillRect, cornerRadius: height / 2).fill()
      } else {
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: UIColor.black.withAlphaComponent(0.55).cgColor)
      }
      var x = pillRect.minX + horizontalPadding
      if let pin {
        pin.draw(in: CGRect(x: x, y: pillRect.midY - pinSize.height / 2, width: pinSize.width, height: pinSize.height))
        x += pinSize.width + pinTextGap
      }
      let lineHeight = font.lineHeight
      text.draw(
        with: CGRect(x: x, y: pillRect.midY - lineHeight / 2, width: textWidth, height: lineHeight),
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
        attributes: attributes,
        context: nil
      )
    }
  }
}

// MARK: - Location picker

/// Nearby (current location, MapKit points of interest) + search place
/// picker for the story Location sticker. Same dark sheet look as
/// MusicPickerViewController.
final class LocationPickerViewController: UIViewController {
  struct Place {
    let name: String
    let subtitle: String
    var latitude: Double? = nil
    var longitude: Double? = nil
    /// Set only for autocomplete suggestions, which carry no coordinate —
    /// resolved via MKLocalSearch when the row is tapped (see resolve).
    var completion: MKLocalSearchCompletion? = nil
  }

  /// Fires once, when the user taps a row (the sheet dismisses itself).
  var onSelect: ((Place) -> Void)?

  private let searchBar = UISearchBar()
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let statusLabel = UILabel()
  private let spinner = LocationSearchingView()
  private let settingsButton = UIButton(type: .system)
  private let locationManager = CLLocationManager()

  private var userLocation: CLLocation?
  private var nearbyPlaces: [Place] = []
  /// Location off / not allowed: popular places in the user's country
  /// fill the list instead of leaving it empty (with a tap to turn
  /// location on above them).
  private var showingSuggestions = false
  private var searchResults: [Place] = []
  private var isSearching = false
  private var searchWorkItem: DispatchWorkItem?
  private var activeSearch: MKLocalSearch?
  private var activeAreaSearch: MKLocalSearch?
  private var currentQuery = ""
  /// Search merges three sources (see runSearch) — kept apart so each can
  /// arrive in any order and the list is rebuilt from all three.
  private let completer = MKLocalSearchCompleter()
  private var completerPlaces: [Place] = []
  private var exactPlaces: [Place] = []
  private var areaPlaces: [Place] = []
  private var pendingSearchParts = 0
  /// The completer can update several times per query — only its first
  /// answer counts towards pendingSearchParts.
  private var completerAnswered = false

  private static let nearbyLimit = 10
  private static let nearbyRadius: CLLocationDistance = 1000
  private static let searchRegionRadius: CLLocationDistance = 50_000

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = EditorDesignTokens.Colors.chromeBackground
    overrideUserInterfaceStyle = .dark
    setUpSearchBar()
    setUpTableView()
    setUpStatusViews()
    completer.delegate = self
    completer.resultTypes = [.address, .pointOfInterest]
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    handleAuthorization(locationManager.authorizationStatus)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    searchWorkItem?.cancel()
    cancelSearch()
  }

  private func cancelSearch() {
    activeSearch?.cancel()
    activeAreaSearch?.cancel()
    completer.cancel()
  }

  private func setUpSearchBar() {
    searchBar.delegate = self
    searchBar.placeholder = "Search locations"
    searchBar.searchBarStyle = .minimal
    searchBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(searchBar)
    NSLayoutConstraint.activate([
      searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
    ])
  }

  private func setUpTableView() {
    tableView.backgroundColor = .clear
    tableView.separatorColor = EditorDesignTokens.Colors.divider
    tableView.dataSource = self
    tableView.delegate = self
    tableView.keyboardDismissMode = .onDrag
    tableView.rowHeight = 60
    tableView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tableView)
    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func setUpStatusViews() {
    statusLabel.textColor = EditorDesignTokens.Colors.textSecondary
    statusLabel.font = .systemFont(ofSize: 14)
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    statusLabel.isHidden = true

    settingsButton.setTitle("Open Settings", for: .normal)
    settingsButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    settingsButton.tintColor = EditorDesignTokens.Colors.textPrimary
    settingsButton.isHidden = true
    settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)

    [statusLabel, settingsButton, spinner].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview($0)
    }
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 48),
      statusLabel.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 40),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
      settingsButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
      settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
    ])
  }

  private var visiblePlaces: [Place] { isSearching ? searchResults : nearbyPlaces }

  private func showStatus(_ message: String?, showSettings: Bool = false) {
    statusLabel.text = message
    statusLabel.isHidden = message == nil
    settingsButton.isHidden = !showSettings
  }

  @objc private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  // MARK: Nearby

  private func handleAuthorization(_ status: CLAuthorizationStatus) {
    guard !isSearching else { return }
    switch status {
    case .notDetermined:
      spinner.message = "Finding places near you…"
      spinner.startAnimating()
      locationManager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      if userLocation == nil {
        spinner.message = "Finding places near you…"
        spinner.startAnimating()
        showStatus(nil)
        locationManager.requestLocation()
      }
    default:
      loadSuggestions()
    }
  }

  /// Popular places in the user's country (from the phone's region) when
  /// there's no location to search around — the sheet is never empty.
  private func loadSuggestions() {
    guard nearbyPlaces.isEmpty || showingSuggestions else { return }
    spinner.message = "Finding popular places…"
    spinner.startAnimating()
    showStatus(nil)
    let regionCode = (Locale.current as NSLocale).object(forKey: .countryCode) as? String ?? "IN"
    let country = Locale(identifier: "en_US").localizedString(forRegionCode: regionCode) ?? "India"
    CLGeocoder().geocodeAddressString(country) { [weak self] placemarks, _ in
      guard let self else { return }
      let request = MKLocalSearch.Request()
      request.naturalLanguageQuery = "popular places"
      if let circle = placemarks?.first?.region as? CLCircularRegion {
        request.region = MKCoordinateRegion(center: circle.center, latitudinalMeters: circle.radius * 2, longitudinalMeters: circle.radius * 2)
      }
      MKLocalSearch(request: request).start { [weak self] response, _ in
        guard let self, self.userLocation == nil else { return }
        let items = (response?.mapItems ?? []).filter { $0.name?.isEmpty == false }
        self.spinner.stopAnimating()
        guard !items.isEmpty else {
          self.showStatus("Turn on location access to see nearby places", showSettings: true)
          return
        }
        self.showingSuggestions = true
        self.nearbyPlaces = items.prefix(Self.nearbyLimit).map(Self.place(from:))
        self.tableView.tableHeaderView = self.locationOffBanner()
        guard !self.isSearching else { return }
        self.tableView.reloadData()
      }
    }
  }

  /// "Turn on location for places near you" bar above the suggestions.
  private func locationOffBanner() -> UIView {
    let button = UIButton(type: .system)
    button.setTitle("Turn on location for places near you  ›", for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
    button.tintColor = EditorDesignTokens.Colors.selectedToolTint
    button.contentHorizontalAlignment = .left
    button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    button.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
    button.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 40)
    return button
  }

  private func loadNearby(around location: CLLocation) {
    let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: Self.nearbyRadius)
    MKLocalSearch(request: request).start { [weak self] response, _ in
      guard let self else { return }
      let items = (response?.mapItems ?? [])
        .filter { $0.name?.isEmpty == false }
        .sorted {
          ($0.placemark.location?.distance(from: location) ?? .greatestFiniteMagnitude)
            < ($1.placemark.location?.distance(from: location) ?? .greatestFiniteMagnitude)
        }
      self.nearbyPlaces = items.prefix(Self.nearbyLimit).map(Self.place(from:))
      self.showingSuggestions = false
      self.tableView.tableHeaderView = nil
      guard !self.isSearching else { return }
      self.spinner.stopAnimating()
      self.showStatus(self.nearbyPlaces.isEmpty ? "No nearby places found" : nil)
      self.tableView.reloadData()
    }
  }

  // MARK: Search

  /// Google-Maps-style search. A plain MKLocalSearch resolves an area name
  /// ("andheri") to that ONE area, so three sources are merged in this
  /// order, de-duplicated by name + subtitle: autocomplete suggestions
  /// (MKLocalSearchCompleter — Andheri East, Andheri Station, ...), exact
  /// search matches, then points of interest around the top exact match
  /// (spots inside that area).
  private func runSearch(_ query: String) {
    cancelSearch()
    completerPlaces = []
    exactPlaces = []
    areaPlaces = []
    completerAnswered = false
    pendingSearchParts = 2 // completer + exact search (area search chains off the latter)
    let region = userLocation.map {
      MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: Self.searchRegionRadius, longitudinalMeters: Self.searchRegionRadius)
    }
    if let region { completer.region = region }
    completer.queryFragment = query

    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    if let region { request.region = region }
    let search = MKLocalSearch(request: request)
    activeSearch = search
    search.start { [weak self] response, _ in
      // Stale-response guard: the user kept typing after this started.
      guard let self, self.isSearching, self.currentQuery == query else { return }
      let items = (response?.mapItems ?? []).filter { $0.name?.isEmpty == false }
      self.exactPlaces = items.map(Self.place(from:))
      if let anchor = items.first?.placemark.coordinate {
        self.pendingSearchParts += 1
        self.loadArea(around: anchor, query: query)
      }
      self.finishSearchPart()
    }
  }

  private func loadArea(around coordinate: CLLocationCoordinate2D, query: String) {
    let search = MKLocalSearch(request: MKLocalPointsOfInterestRequest(center: coordinate, radius: 2000))
    activeAreaSearch = search
    search.start { [weak self] response, _ in
      guard let self, self.isSearching, self.currentQuery == query else { return }
      self.areaPlaces = (response?.mapItems ?? [])
        .filter { $0.name?.isEmpty == false }
        .prefix(20)
        .map(Self.place(from:))
      self.finishSearchPart()
    }
  }

  /// Rebuilds the merged list after any source arrives; the empty-state
  /// message only shows once every source has answered.
  private func finishSearchPart(countsAsDone: Bool = true) {
    if countsAsDone { pendingSearchParts = max(pendingSearchParts - 1, 0) }
    var seen = Set<String>()
    searchResults = (completerPlaces + exactPlaces + areaPlaces).filter {
      seen.insert(($0.name + "|" + $0.subtitle).lowercased()).inserted
    }
    if !searchResults.isEmpty || pendingSearchParts == 0 { spinner.stopAnimating() }
    showStatus(searchResults.isEmpty && pendingSearchParts == 0 ? "No places found" : nil)
    tableView.reloadData()
  }

  private static func place(from item: MKMapItem) -> Place {
    let placemark = item.placemark
    let parts = [placemark.thoroughfare, placemark.locality, placemark.administrativeArea]
      .compactMap { $0 }
      .filter { !$0.isEmpty && $0 != item.name }
    let coordinate = placemark.coordinate
    let hasCoordinate = CLLocationCoordinate2DIsValid(coordinate)
    return Place(
      name: item.name ?? "",
      subtitle: parts.joined(separator: ", "),
      latitude: hasCoordinate ? coordinate.latitude : nil,
      longitude: hasCoordinate ? coordinate.longitude : nil
    )
  }

  /// Fills in a completer suggestion's coordinate before handing it back.
  /// Always calls `completion` exactly once — with nil coords on failure or
  /// after a ~5s timeout, so a slow lookup never blocks picking the place.
  private func resolve(_ place: Place, completion: @escaping (Place) -> Void) {
    guard let suggestion = place.completion, place.latitude == nil else {
      completion(place)
      return
    }
    var finished = false
    let finish: (Place) -> Void = { result in
      guard !finished else { return }
      finished = true
      completion(result)
    }
    let search = MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion))
    search.start { response, _ in
      var resolved = place
      if let coordinate = response?.mapItems.first?.placemark.coordinate, CLLocationCoordinate2DIsValid(coordinate) {
        resolved.latitude = coordinate.latitude
        resolved.longitude = coordinate.longitude
      }
      finish(resolved)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      search.cancel()
      finish(place)
    }
  }
}

extension LocationPickerViewController: CLLocationManagerDelegate {
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    handleAuthorization(manager.authorizationStatus)
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard userLocation == nil, let location = locations.last else { return }
    userLocation = location
    loadNearby(around: location)
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard userLocation == nil, !isSearching else { return }
    // No fix (location off / no signal): suggestions instead of an empty list.
    loadSuggestions()
  }
}

extension LocationPickerViewController: MKLocalSearchCompleterDelegate {
  func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
    guard isSearching, completer.queryFragment == currentQuery else { return }
    completerPlaces = completer.results
      .filter { !$0.title.isEmpty }
      .map { Place(name: $0.title, subtitle: $0.subtitle, completion: $0) }
    finishSearchPart(countsAsDone: !completerAnswered)
    completerAnswered = true
  }

  func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
    guard isSearching, completer.queryFragment == currentQuery else { return }
    finishSearchPart(countsAsDone: !completerAnswered)
    completerAnswered = true
  }
}

extension LocationPickerViewController: UISearchBarDelegate {
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    searchWorkItem?.cancel()
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    currentQuery = trimmed
    guard trimmed.count >= 2 else {
      cancelSearch()
      isSearching = false
      searchResults = []
      spinner.stopAnimating()
      showStatus(nil)
      tableView.reloadData()
      // Back to Nearby — re-derive its status (spinner/permission message).
      if nearbyPlaces.isEmpty { handleAuthorization(locationManager.authorizationStatus) }
      return
    }
    isSearching = true
    searchResults = []
    tableView.reloadData()
    showStatus(nil)
    spinner.message = "Searching “\(trimmed)”…"
    spinner.startAnimating()
    let work = DispatchWorkItem { [weak self] in self?.runSearch(trimmed) }
    searchWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }
}

extension LocationPickerViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    visiblePlaces.count
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    !isSearching && !nearbyPlaces.isEmpty ? (showingSuggestions ? "Popular places" : "Nearby") : nil
  }

  func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
    guard let header = view as? UITableViewHeaderFooterView else { return }
    header.textLabel?.textColor = EditorDesignTokens.Colors.textSecondary
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "place")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "place")
    let place = visiblePlaces[indexPath.row]
    cell.backgroundColor = .clear
    cell.imageView?.image = UIImage(systemName: "mappin.circle.fill")
    cell.imageView?.tintColor = EditorDesignTokens.Colors.textSecondary
    cell.textLabel?.text = place.name
    cell.textLabel?.textColor = EditorDesignTokens.Colors.textPrimary
    cell.textLabel?.font = .systemFont(ofSize: 15, weight: .medium)
    cell.detailTextLabel?.text = place.subtitle
    cell.detailTextLabel?.textColor = EditorDesignTokens.Colors.textSecondary
    cell.detailTextLabel?.font = .systemFont(ofSize: 12)
    cell.detailTextLabel?.numberOfLines = 1
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let place = visiblePlaces[indexPath.row]
    // Block further taps/typing while a suggestion's coordinate resolves.
    tableView.isUserInteractionEnabled = false
    searchBar.isUserInteractionEnabled = false
    showStatus(nil)
    spinner.stopAnimating()
    spinner.message = "Getting location…"
    spinner.startAnimating()
    resolve(place) { [weak self] resolved in
      guard let self else { return }
      self.spinner.stopAnimating()
      self.onSelect?(resolved)
      self.dismiss(animated: true)
    }
  }
}

/// On-canvas guide + gestures for the Blur tool: drag moves the sharp area,
/// pinch resizes it, two-finger rotate turns a linear band. Geometry is
/// edited in the photo's own (imageView-local) space via `toPhoto`/
/// `toOverlay`, so it stays correct when the photo is panned/zoomed.
final class BlurFocusOverlayView: UIView, UIGestureRecognizerDelegate {
  var blur = PhotoBlur() { didSet { setNeedsLayout() } }
  var photoSize: (() -> CGSize)?
  var toOverlay: ((CGPoint) -> CGPoint)?
  var toPhoto: ((CGPoint) -> CGPoint)?
  var photoRotation: (() -> CGFloat)?
  var photoScale: (() -> CGFloat)?
  var onChange: ((PhotoBlur) -> Void)?
  var onGestureEnded: ((_ before: PhotoBlur, _ after: PhotoBlur) -> Void)?

  private let guideLayer = CAShapeLayer()
  private let featherLayer = CAShapeLayer()
  private let fadeLayer = CAShapeLayer()
  private var gestureStartBlur: PhotoBlur?
  private var activeGestures = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    clipsToBounds = true
    fadeLayer.fillColor = UIColor.white.withAlphaComponent(0.28).cgColor
    fadeLayer.fillRule = .evenOdd
    fadeLayer.opacity = 0
    layer.addSublayer(fadeLayer)
    for shape in [guideLayer, featherLayer] {
      shape.fillColor = UIColor.clear.cgColor
      shape.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
      shape.lineWidth = 1.5
      shape.shadowColor = UIColor.black.cgColor
      shape.shadowOpacity = 0.5
      shape.shadowRadius = 1.5
      shape.shadowOffset = .zero
      layer.addSublayer(shape)
    }
    featherLayer.lineDashPattern = [6, 5]
    featherLayer.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.maximumNumberOfTouches = 1
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
    for g in [pan, pinch, rotate] as [UIGestureRecognizer] {
      g.delegate = self
      addGestureRecognizer(g)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    true
  }

  // MARK: Geometry (photo-local points)

  private var size: CGSize { photoSize?() ?? bounds.size }
  private var minSide: CGFloat { max(min(size.width, size.height), 1) }
  private var focusCenter: CGPoint {
    CGPoint(x: CGFloat(blur.centerX) * size.width, y: CGFloat(blur.centerY) * size.height)
  }

  /// photo-local → overlay affine transform (pan/zoom/rotate of the photo).
  private func photoToOverlayTransform() -> CGAffineTransform {
    guard let toOverlay else { return .identity }
    let o = toOverlay(.zero)
    let x = toOverlay(CGPoint(x: 1, y: 0))
    let y = toOverlay(CGPoint(x: 0, y: 1))
    return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    for l in [guideLayer, featherLayer, fadeLayer] { l.frame = bounds }
    let inner = CGFloat(blur.size) * minSide
    let outer = inner + CGFloat(max(blur.size * PhotoBlur.featherFactor, 0.05)) * minSide
    let c = focusCenter
    let guide = UIBezierPath()
    let feather = UIBezierPath()
    let sharp = UIBezierPath()
    switch blur.mode {
    case .off:
      break
    case .radial:
      guide.append(UIBezierPath(arcCenter: c, radius: inner, startAngle: 0, endAngle: .pi * 2, clockwise: true))
      feather.append(UIBezierPath(arcCenter: c, radius: outer, startAngle: 0, endAngle: .pi * 2, clockwise: true))
      sharp.append(UIBezierPath(arcCenter: c, radius: inner, startAngle: 0, endAngle: .pi * 2, clockwise: true))
    case .linear:
      let a = CGFloat(blur.angle)
      let d = CGPoint(x: cos(a), y: sin(a))
      let n = CGPoint(x: -sin(a), y: cos(a))
      let length = (size.width + size.height) * 2
      func line(_ offset: CGFloat, into path: UIBezierPath) {
        let p = CGPoint(x: c.x + n.x * offset, y: c.y + n.y * offset)
        path.move(to: CGPoint(x: p.x - d.x * length, y: p.y - d.y * length))
        path.addLine(to: CGPoint(x: p.x + d.x * length, y: p.y + d.y * length))
      }
      line(inner, into: guide); line(-inner, into: guide)
      line(outer, into: feather); line(-outer, into: feather)
      let band = UIBezierPath()
      let p1 = CGPoint(x: c.x + n.x * inner, y: c.y + n.y * inner)
      let p2 = CGPoint(x: c.x - n.x * inner, y: c.y - n.y * inner)
      band.move(to: CGPoint(x: p1.x - d.x * length, y: p1.y - d.y * length))
      band.addLine(to: CGPoint(x: p1.x + d.x * length, y: p1.y + d.y * length))
      band.addLine(to: CGPoint(x: p2.x + d.x * length, y: p2.y + d.y * length))
      band.addLine(to: CGPoint(x: p2.x - d.x * length, y: p2.y - d.y * length))
      band.close()
      sharp.append(band)
    }
    let t = photoToOverlayTransform()
    guide.apply(t)
    feather.apply(t)
    sharp.apply(t)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    guideLayer.path = guide.cgPath
    featherLayer.path = feather.cgPath
    // Whole overlay minus the sharp area (even-odd) = "this gets blurred".
    let fade = UIBezierPath(rect: bounds)
    fade.append(sharp)
    fadeLayer.path = fade.cgPath
    CATransaction.commit()
  }

  // MARK: Gestures

  private func gestureBegan() {
    if activeGestures == 0 {
      gestureStartBlur = blur
      fadeLayer.opacity = 1
    }
    activeGestures += 1
  }

  private func gestureEnded() {
    activeGestures = max(activeGestures - 1, 0)
    guard activeGestures == 0 else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = fadeLayer.opacity
    fade.toValue = 0
    fade.duration = 0.25
    fadeLayer.opacity = 0
    fadeLayer.add(fade, forKey: "fade")
    if let start = gestureStartBlur { onGestureEnded?(start, blur) }
    gestureStartBlur = nil
  }

  private func track(_ g: UIGestureRecognizer) -> Bool {
    switch g.state {
    case .began: gestureBegan(); return true
    case .changed: return true
    case .ended, .cancelled, .failed: gestureEnded(); return false
    default: return false
    }
  }

  private func commit(_ newBlur: PhotoBlur) {
    blur = newBlur
    onChange?(newBlur)
  }

  @objc private func handlePan(_ g: UIPanGestureRecognizer) {
    guard track(g), let toPhoto, let toOverlay else { return }
    let translation = g.translation(in: self)
    g.setTranslation(.zero, in: self)
    let current = toOverlay(focusCenter)
    let moved = toPhoto(CGPoint(x: current.x + translation.x, y: current.y + translation.y))
    var new = blur
    new.centerX = Double(min(max(moved.x / max(size.width, 1), 0), 1))
    new.centerY = Double(min(max(moved.y / max(size.height, 1), 0), 1))
    commit(new)
  }

  @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
    guard track(g) else { return }
    var new = blur
    new.size = min(max(blur.size * Double(g.scale), PhotoBlur.minSize), PhotoBlur.maxSize)
    g.scale = 1
    commit(new)
  }

  @objc private func handleRotate(_ g: UIRotationGestureRecognizer) {
    guard track(g), blur.mode == .linear else { return }
    var new = blur
    new.angle = blur.angle + Double(g.rotation)
    g.rotation = 0
    commit(new)
  }
}


/// Transparent touch catcher for the overlay eraser (see
/// MediaEditorViewController.updateOverlayEraseCapture).
final class OverlayEraseCaptureView: UIView {
  /// (point in this view's own coordinates, is the first touch of a stroke)
  var onTouch: ((CGPoint, Bool) -> Void)?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    onTouch?(touch.location(in: self), true)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    onTouch?(touch.location(in: self), false)
  }
}

/// CADisplayLink retains its target; this breaks the cycle with the editor.
private final class WeakDisplayLinkTarget: NSObject {
  private let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @objc func tick() { action() }
}

/// Pre-iOS 26 floating capsule behind the tool row (iOS 26 uses the
/// system tab bar instead). Same recipe as the reference NavBarCapsuleView:
/// a thin system blur, a light wash, a hairline rim and a soft drop shadow.
/// Reads as frosted rather than refractive — there's no Liquid Glass here.
final class GlassCapsuleView: UIView {
  private let clipView = UIView()
  private let materialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let washView = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.12
    layer.shadowRadius = 10
    layer.shadowOffset = CGSize(width: 0, height: 4)
    clipView.clipsToBounds = true
    clipView.layer.cornerCurve = .continuous
    clipView.layer.borderWidth = 0.5
    clipView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    addSubview(clipView)
    clipView.addSubview(materialView)
    washView.backgroundColor = UIColor.black.withAlphaComponent(0.15)
    clipView.addSubview(washView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let radius = bounds.height / 2
    clipView.frame = bounds
    clipView.layer.cornerRadius = radius
    materialView.frame = clipView.bounds
    washView.frame = clipView.bounds
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
  }
}

/// Selected-tool lozenge that slides along the rail. iOS 26: a small
/// Liquid Glass lens (UIGlassEffect, lightly white-tinted so it reads
/// brighter than the capsule under it). Earlier iOS: a soft light fill
/// (reference look).
final class GlassLensView: UIView {
  private var glassView: UIVisualEffectView?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    layer.cornerCurve = .continuous
    if #available(iOS 26.0, *) {
      overrideUserInterfaceStyle = .dark
      backgroundColor = .clear
      let effect = UIGlassEffect(style: .regular)
      effect.tintColor = UIColor.white.withAlphaComponent(0.14)
      let glass = UIVisualEffectView(effect: effect)
      glass.cornerConfiguration = .capsule()
      glass.frame = bounds
      glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(glass)
      glassView = glass
    } else {
      backgroundColor = UIColor.white.withAlphaComponent(0.12)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    if glassView == nil { layer.cornerRadius = bounds.height / 2 }
  }
}

/// One Liquid Glass surface for every editor control (bars, buttons, pills,
/// sheets). iOS 26+: the system glass (UIGlassEffect, regular) with the
/// matching corner configuration. Earlier iOS: the reference frosted recipe
/// — thin dark blur, black 15% wash, 0.5pt white 12% rim, soft shadow.
/// Decorative only: never takes touches.
final class GlassSurfaceView: UIView {
  enum Shape {
    case capsule
    case rounded(CGFloat)
    case topRounded(CGFloat)
  }

  private let shape: Shape
  private let clipView = UIView()
  private var effectView: UIVisualEffectView!
  private let washView = UIView()
  private let usesNativeGlass: Bool

  init(shape: Shape) {
    self.shape = shape
    if #available(iOS 26.0, *) { usesNativeGlass = true } else { usesNativeGlass = false }
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    // Dark glass, like the tool bar: the editor is dark, and in light mode
    // the system glass would otherwise resolve to a white frost.
    overrideUserInterfaceStyle = .dark
    if #available(iOS 26.0, *) {
      let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
      switch shape {
      case .capsule:
        glass.cornerConfiguration = .capsule()
      case .rounded(let r):
        glass.cornerConfiguration = .corners(radius: .fixed(r))
      case .topRounded(let r):
        glass.cornerConfiguration = .uniformEdges(topRadius: .fixed(r), bottomRadius: .fixed(0))
      }
      glass.frame = bounds
      glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(glass)
      effectView = glass
      return
    }
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.12
    layer.shadowRadius = 10
    layer.shadowOffset = CGSize(width: 0, height: 4)
    clipView.clipsToBounds = true
    clipView.layer.cornerCurve = .continuous
    clipView.layer.borderWidth = 0.5
    clipView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    addSubview(clipView)
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    clipView.addSubview(effectView)
    washView.backgroundColor = UIColor.black.withAlphaComponent(0.15)
    clipView.addSubview(washView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard !usesNativeGlass else { return }
    let radius: CGFloat
    switch shape {
    case .capsule:
      radius = bounds.height / 2
      clipView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    case .rounded(let r):
      radius = r
      clipView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    case .topRounded(let r):
      radius = r
      clipView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }
    clipView.frame = bounds
    clipView.layer.cornerRadius = radius
    effectView.frame = clipView.bounds
    washView.frame = clipView.bounds
    if case .topRounded = shape {
      layer.shadowPath = UIBezierPath(roundedRect: bounds, byRoundingCorners: [.topLeft, .topRight],
                                      cornerRadii: CGSize(width: radius, height: radius)).cgPath
    } else {
      layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }
  }

  /// Fills `host` (inset by `inset`) behind its content; `host` goes clear.
  @discardableResult
  static func install(behind host: UIView, shape: Shape, inset: UIEdgeInsets = .zero) -> GlassSurfaceView {
    let glass = GlassSurfaceView(shape: shape)
    glass.frame = host.bounds.inset(by: inset)
    glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.insertSubview(glass, at: 0)
    host.backgroundColor = .clear
    return glass
  }

  /// A glass shape wrapped around `views` (inside `container`, behind them),
  /// padded by `pad`, via Auto Layout.
  @discardableResult
  static func install(around views: [UIView], in container: UIView, shape: Shape, pad: CGFloat) -> GlassSurfaceView {
    let glass = GlassSurfaceView(shape: shape)
    glass.translatesAutoresizingMaskIntoConstraints = false
    if let firstIndex = views.compactMap({ container.subviews.firstIndex(of: $0) }).min() {
      container.insertSubview(glass, at: firstIndex)
    } else {
      container.insertSubview(glass, at: 0)
    }
    guard let first = views.first, let last = views.last else { return glass }
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: first.leadingAnchor, constant: -pad),
      glass.trailingAnchor.constraint(equalTo: last.trailingAnchor, constant: pad),
      glass.topAnchor.constraint(equalTo: first.topAnchor, constant: -pad),
      glass.bottomAnchor.constraint(equalTo: first.bottomAnchor, constant: pad),
    ])
    return glass
  }
}


/// A button with a dashed rounded outline that follows its bounds (Music
/// sheet's empty "+ Choose music track", video redesign).
final class DashedOutlineButton: UIButton {
  private let dashLayer = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    dashLayer.strokeColor = UIColor(red: 0x3A / 255, green: 0x3D / 255, blue: 0x43 / 255, alpha: 1).cgColor
    dashLayer.fillColor = UIColor.clear.cgColor
    dashLayer.lineWidth = 1.5
    dashLayer.lineDashPattern = [6, 4]
    layer.addSublayer(dashLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    dashLayer.frame = bounds
    dashLayer.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 14).cgPath
  }
}

// MARK: - Add layer sheet (Edits-style layers, board V8)

extension MediaEditorViewController {
  @objc fileprivate func didTapAddLayer() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    presentAddLayerSheet()
  }

  /// Bottom sheet listing what can be added as a new layer. Each tile just
  /// opens the tool that already exists; the new item then gets its own
  /// track starting at the playhead (registerLayerTiming).
  private func presentAddLayerSheet() {
    guard addLayerSheetView == nil else { return }
    pauseVideoForToolInteraction()
    // Close any open tool first, same as every other tool entry point.
    selectedImageEditorTab = .tools
    updateImageEditorUI(animated: false)

    let overlay = UIControl()
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    overlay.alpha = 0
    overlay.addAction(UIAction { [weak self] _ in self?.dismissAddLayerSheet() }, for: .touchUpInside)
    view.addSubview(overlay)

    let sheet = UIView()
    sheet.translatesAutoresizingMaskIntoConstraints = false
    sheet.backgroundColor = EditorDesignTokens.Colors.panelBackground
    sheet.layer.cornerRadius = 22
    sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    overlay.addSubview(sheet)

    let handle = UIView()
    handle.translatesAutoresizingMaskIntoConstraints = false
    handle.backgroundColor = UIColor(red: 0x3A / 255, green: 0x3D / 255, blue: 0x43 / 255, alpha: 1)
    handle.layer.cornerRadius = 2

    let title = UILabel()
    title.text = "Add layer"
    title.font = .systemFont(ofSize: 18, weight: .semibold)
    title.textColor = EditorDesignTokens.Colors.textPrimary
    let subtitle = UILabel()
    subtitle.text = "Starts at \(Self.addLayerTimeString(combinedTimeForCurrentPlayback())) (playhead) · \(allLayerViews().count) of \(Self.maxVideoLayers) layers used"
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = EditorDesignTokens.Colors.textSecondary
    subtitle.numberOfLines = 2
    let titles = UIStackView(arrangedSubviews: [title, subtitle])
    titles.axis = .vertical
    titles.spacing = 2

    let close = UIButton(type: .system)
    close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
    close.tintColor = EditorDesignTokens.Colors.textPrimary
    close.accessibilityLabel = "Close add layer"
    close.addAction(UIAction { [weak self] _ in self?.dismissAddLayerSheet() }, for: .touchUpInside)
    close.widthAnchor.constraint(equalToConstant: 44).isActive = true
    close.heightAnchor.constraint(equalToConstant: 44).isActive = true
    let header = UIStackView(arrangedSubviews: [titles, close])
    header.alignment = .center

    let tiles: [(String, UIColor, String, String, () -> Void)] = [
      ("tool_text", EditorDesignTokens.Colors.textLayer, "Text", "Words, titles", { [weak self] in self?.presentTextEntryOverlay() }),
      ("tool_sticker", EditorDesignTokens.Colors.stickerLayer, "Sticker", "Library", { [weak self] in self?.didTapStickersTab() }),
      ("tool_overlay", EditorDesignTokens.Colors.accent, "Photo", "From gallery", { [weak self] in self?.presentImageOverlayPicker() }),
      ("tool_music", EditorDesignTokens.Colors.musicLayer, "Music", selectedMusicTrack == nil ? "Add a track" : "Replace track", { [weak self] in self?.didTapMusicTab() }),
      ("tool_add_video", UIColor(red: 0x3A / 255, green: 0x3D / 255, blue: 0x43 / 255, alpha: 1), "Clip", "Adds to the end", { [weak self] in self?.presentVideoClipPicker() }),
      ("mic.fill", EditorDesignTokens.Colors.voiceLayer, "Voice", voiceOverURL == nil ? "Record narration" : "Record again", { [weak self] in self?.presentVoiceRecorder() }),
    ]
    let grid = UIStackView()
    grid.axis = .vertical
    grid.spacing = 10
    let columns = 3
    for start in stride(from: 0, to: tiles.count, by: columns) {
      let row = UIStackView()
      row.axis = .horizontal
      row.spacing = 10
      row.distribution = .fillEqually
      for (icon, color, name, sub, action) in tiles[start..<min(start + columns, tiles.count)] {
        row.addArrangedSubview(makeAddLayerTile(icon: icon, color: color, name: name, subtitle: sub) { [weak self] in
          self?.dismissAddLayerSheet(animated: false)
          action()
        })
      }
      for _ in 0..<(columns - min(columns, tiles.count - start)) { row.addArrangedSubview(UIView()) }
      grid.addArrangedSubview(row)
    }

    let footnote = UILabel()
    footnote.text = "Each new item gets its own track. Hold a track and drag up or down to change what sits on top."
    footnote.font = .systemFont(ofSize: 12)
    footnote.textColor = EditorDesignTokens.Colors.textSecondary
    footnote.numberOfLines = 0

    let content = UIStackView(arrangedSubviews: [header, grid, footnote])
    content.axis = .vertical
    content.spacing = 14
    content.translatesAutoresizingMaskIntoConstraints = false
    sheet.addSubview(handle)
    sheet.addSubview(content)

    NSLayoutConstraint.activate([
      overlay.topAnchor.constraint(equalTo: view.topAnchor),
      overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      sheet.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
      sheet.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
      sheet.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
      handle.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 10),
      handle.centerXAnchor.constraint(equalTo: sheet.centerXAnchor),
      handle.widthAnchor.constraint(equalToConstant: 36),
      handle.heightAnchor.constraint(equalToConstant: 4),
      content.topAnchor.constraint(equalTo: handle.bottomAnchor, constant: 10),
      content.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -16),
      content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
    ])
    addLayerSheetView = overlay
    view.layoutIfNeeded()
    sheet.transform = CGAffineTransform(translationX: 0, y: sheet.bounds.height)
    UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
      overlay.alpha = 1
      sheet.transform = .identity
    }
  }

  private func dismissAddLayerSheet(animated: Bool = true) {
    guard let overlay = addLayerSheetView else { return }
    addLayerSheetView = nil
    guard animated, let sheet = overlay.subviews.first else {
      overlay.removeFromSuperview()
      return
    }
    UIView.animate(withDuration: 0.2, animations: {
      overlay.alpha = 0
      sheet.transform = CGAffineTransform(translationX: 0, y: sheet.bounds.height)
    }, completion: { _ in overlay.removeFromSuperview() })
  }

  private func makeAddLayerTile(icon: String, color: UIColor, name: String, subtitle: String, action: @escaping () -> Void) -> UIView {
    let tile = UIControl()
    tile.backgroundColor = EditorDesignTokens.Colors.elevatedSurface
    tile.layer.cornerRadius = 16
    tile.accessibilityLabel = "\(name), \(subtitle)"
    tile.isAccessibilityElement = true
    tile.accessibilityTraits = .button
    tile.heightAnchor.constraint(equalToConstant: 96).isActive = true

    let badge = UIView()
    badge.backgroundColor = color
    badge.layer.cornerRadius = 12
    badge.isUserInteractionEnabled = false
    badge.translatesAutoresizingMaskIntoConstraints = false
    let image = UIImageView(image: (UIImage(named: icon) ?? UIImage(systemName: icon))?.withRenderingMode(.alwaysTemplate))
    image.tintColor = .white
    image.contentMode = .scaleAspectFit
    image.translatesAutoresizingMaskIntoConstraints = false
    badge.addSubview(image)

    let nameLabel = UILabel()
    nameLabel.text = name
    nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
    nameLabel.textColor = EditorDesignTokens.Colors.textPrimary
    let subLabel = UILabel()
    subLabel.text = subtitle
    subLabel.font = .systemFont(ofSize: 12)
    subLabel.textColor = EditorDesignTokens.Colors.textSecondary
    subLabel.adjustsFontSizeToFitWidth = true
    subLabel.minimumScaleFactor = 0.85
    let stack = UIStackView(arrangedSubviews: [badge, nameLabel, subLabel])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 4
    stack.setCustomSpacing(6, after: badge)
    stack.isUserInteractionEnabled = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(stack)
    NSLayoutConstraint.activate([
      badge.widthAnchor.constraint(equalToConstant: 40),
      badge.heightAnchor.constraint(equalToConstant: 40),
      image.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: 22),
      image.heightAnchor.constraint(equalToConstant: 22),
      stack.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: tile.leadingAnchor, constant: 4),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: tile.trailingAnchor, constant: -4),
    ])
    tile.addAction(UIAction { _ in
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      action()
    }, for: .touchUpInside)
    return tile
  }

  /// Video sessions allow at most `maxVideoLayers` text/sticker/photo
  /// layers (music isn't counted — there's only ever one track). Shows a
  /// short message and returns false when full. Image sessions: no limit.
  func canAddLayer() -> Bool {
    guard mediaType != "image", allLayerViews().count >= Self.maxVideoLayers else { return true }
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
    showEditorToast("Maximum \(Self.maxVideoLayers) layers. Delete one to add another.")
    return false
  }

  /// A small pill message under the top bar that fades out on its own.
  private func showEditorToast(_ message: String) {
    view.subviews.filter { $0.accessibilityIdentifier == "editorToast" }.forEach { $0.removeFromSuperview() }
    let label = PaddedToastLabel()
    label.accessibilityIdentifier = "editorToast"
    label.text = message
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = EditorDesignTokens.Colors.textPrimary
    label.backgroundColor = EditorDesignTokens.Colors.elevatedSurface.withAlphaComponent(0.95)
    label.textAlignment = .center
    label.numberOfLines = 1
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.8
    label.layer.cornerRadius = 16
    label.layer.masksToBounds = true
    label.alpha = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
    ])
    UIAccessibility.post(notification: .announcement, argument: message)
    UIView.animate(withDuration: 0.2) { label.alpha = 1 }
    UIView.animate(withDuration: 0.3, delay: 2.2, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
  }

  private static func addLayerTimeString(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

/// UILabel with inner padding, for the editor's toast message.
private final class PaddedToastLabel: UILabel {
  private let insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
  }
}

/// Thin guide lines over the canvas while a dragged layer is snapped:
/// center lines run the full canvas, edge guides sit at the safe margin.
final class SnapGuidesView: UIView {
  var state = LayerSnapState.none { didSet { if state != oldValue { setNeedsDisplay() } } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func draw(_ rect: CGRect) {
    guard !state.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
    let m = LayerSnapper.edgeMargin
    ctx.setLineWidth(1)
    ctx.setStrokeColor(EditorDesignTokens.Colors.accent.cgColor)
    var lines: [(CGPoint, CGPoint)] = []
    if state.centerX { lines.append((CGPoint(x: bounds.midX, y: 0), CGPoint(x: bounds.midX, y: bounds.height))) }
    if state.centerY { lines.append((CGPoint(x: 0, y: bounds.midY), CGPoint(x: bounds.width, y: bounds.midY))) }
    if state.left { lines.append((CGPoint(x: m, y: 0), CGPoint(x: m, y: bounds.height))) }
    if state.right { lines.append((CGPoint(x: bounds.width - m, y: 0), CGPoint(x: bounds.width - m, y: bounds.height))) }
    if state.top { lines.append((CGPoint(x: 0, y: m), CGPoint(x: bounds.width, y: m))) }
    if state.bottom { lines.append((CGPoint(x: 0, y: bounds.height - m), CGPoint(x: bounds.width, y: bounds.height - m))) }
    for (a, b) in lines {
      ctx.move(to: a)
      ctx.addLine(to: b)
    }
    ctx.strokePath()
  }
}

/// Beat sync: a simple on-device beat finder. Decodes the song to mono
/// 16-bit PCM, measures loudness in ~23 ms steps, and keeps the sudden
/// rises (onsets) that stand out from their surroundings, at least 0.28s
/// apart. Good enough to snap cuts to; not a full tempo tracker.
enum BeatDetector {
  static func beats(in url: URL, maxSeconds: Double = 300) -> [Double] {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first,
          let reader = try? AVAssetReader(asset: asset) else { return [] }
    let sampleRate = 22_050.0
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVNumberOfChannelsKey: 1,
      AVSampleRateKey: sampleRate,
    ])
    guard reader.canAdd(output) else { return [] }
    reader.add(output)
    guard reader.startReading() else { return [] }
    let hop = 512
    var energies: [Double] = []
    var acc = 0.0
    var count = 0
    let maxSamples = Int(maxSeconds * sampleRate)
    var total = 0
    while total < maxSamples, let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
      let length = CMBlockBufferGetDataLength(block)
      var data = [Int16](repeating: 0, count: length / 2)
      CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
      for sample in data {
        let v = Double(sample) / 32768
        acc += v * v
        count += 1
        if count == hop {
          energies.append(acc / Double(hop))
          acc = 0
          count = 0
        }
      }
      total += data.count
    }
    reader.cancelReading()
    guard energies.count > 4 else { return [] }
    // Onset strength: rise in log loudness.
    var onset = [Double](repeating: 0, count: energies.count)
    for i in 1..<energies.count {
      onset[i] = max(0, log(energies[i] + 1e-7) - log(energies[i - 1] + 1e-7))
    }
    let hopSeconds = Double(hop) / sampleRate
    let window = 16
    var beats: [Double] = []
    var lastBeat = -1.0
    for i in 1..<(onset.count - 1) {
      guard onset[i] > 0, onset[i] >= onset[i - 1], onset[i] >= onset[i + 1] else { continue }
      let lo = max(0, i - window)
      let hi = min(onset.count - 1, i + window)
      var mean = 0.0
      for j in lo...hi { mean += onset[j] }
      mean /= Double(hi - lo + 1)
      let t = Double(i) * hopSeconds
      if onset[i] > mean * 1.8 + 0.05, t - lastBeat >= 0.28 {
        beats.append(t)
        lastBeat = t
      }
    }
    return beats
  }
}

/// Edits-style speed ruler: 0.25x–4x on a doubling scale (1x centred),
/// small ticks every quarter step, labelled major ticks at 0.25 / 0.5 / 1 /
/// 2 / 4x, and a round thumb on a filled track. Drag or tap anywhere.
/// Snaps to round values, with a haptic tick on each major value.
final class SpeedRulerView: UIView {
  static let minLog: Double = -2 // log2(0.25)
  static let maxLog: Double = 2  // log2(4)

  var value: Double = 1 { didSet { setNeedsDisplay() } }
  var onChange: ((Double) -> Void)?
  private let haptic = UISelectionFeedbackGenerator()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw
    isAccessibilityElement = true
    accessibilityTraits = .adjustable
    accessibilityLabel = "Speed"
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var inset: CGFloat { 24 }
  private func x(forLog l: Double) -> CGFloat {
    inset + CGFloat((l - Self.minLog) / (Self.maxLog - Self.minLog)) * (bounds.width - inset * 2)
  }
  private func log(forX x: CGFloat) -> Double {
    let f = Double((x - inset) / max(1, bounds.width - inset * 2))
    return Self.minLog + min(max(f, 0), 1) * (Self.maxLog - Self.minLog)
  }

  /// Rounded so the readout stays tidy: 0.05 steps below 2x, 0.1 above.
  static func snapped(_ speed: Double) -> Double {
    for major in [0.25, 0.5, 1.0, 2.0, 4.0] where abs(speed - major) / major < 0.04 { return major }
    let step = speed < 2 ? 0.05 : 0.1
    return min(max((speed / step).rounded() * step, 0.25), 4)
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    let trackY: CGFloat = 26
    // Ticks.
    var l = Self.minLog
    while l <= Self.maxLog + 0.001 {
      let major = abs(l - l.rounded()) < 0.001
      let tx = x(forLog: l)
      ctx.setFillColor(UIColor.white.withAlphaComponent(major ? 0.7 : 0.3).cgColor)
      let h: CGFloat = major ? 14 : 8
      ctx.fill(CGRect(x: tx - 0.75, y: trackY - h / 2, width: 1.5, height: h))
      if major {
        let speed = pow(2, l)
        let text = (speed < 1 ? (speed == 0.25 ? "0.25x" : "0.5x") : "\(Int(speed))x") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: 11, weight: .medium),
          .foregroundColor: UIColor.white.withAlphaComponent(0.7),
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: tx - size.width / 2, y: trackY + 14), withAttributes: attrs)
      }
      l += 0.25
    }
    // Track from 1x to the value, then the thumb.
    let vx = x(forLog: log2(value))
    let cx = x(forLog: 0)
    ctx.setFillColor(EditorDesignTokens.Colors.accent.cgColor)
    ctx.fill(CGRect(x: min(vx, cx), y: trackY - 1.5, width: abs(vx - cx), height: 3))
    ctx.setFillColor(UIColor.white.cgColor)
    ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: UIColor.black.withAlphaComponent(0.4).cgColor)
    ctx.fillEllipse(in: CGRect(x: vx - 11, y: trackY - 11, width: 22, height: 22))
  }

  private func update(with x: CGFloat) {
    let new = Self.snapped(pow(2, log(forX: x)))
    guard new != value else { return }
    let crossedMajor = [0.25, 0.5, 1.0, 2.0, 4.0].contains(new)
    value = new
    if crossedMajor { haptic.selectionChanged() }
    accessibilityValue = "\(new)x"
    onChange?(new)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    haptic.prepare()
    if let t = touches.first { update(with: t.location(in: self).x) }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    if let t = touches.first { update(with: t.location(in: self).x) }
  }

  override func accessibilityIncrement() { update(with: x(forLog: log2(value) + 0.25)) }
  override func accessibilityDecrement() { update(with: x(forLog: log2(value) - 0.25)) }
}

/// CapCut-style text animation sheet: ✕ · Animation · ✓, In / Out / Loop
/// tabs, a grid of named tiles (each with a small "Aa" playing its own
/// animation) and a duration slider for the open tab. Every change is
/// reported through `onChange` so the video can preview it live; the
/// caller applies / reverts on close. Same design as Android
/// TextAnimationSheetView.
final class TextAnimationSheetView: UIView {
  var onChange: ((TextAnimConfig, Int) -> Void)?
  var onClose: ((Bool) -> Void)?
  private(set) var config: TextAnimConfig
  private var tab = 0
  private var tabButtons: [UIButton] = []
  private var tabDots: [UIView] = []
  private let tabUnderline = UIView()
  private let gridScroll = UIScrollView()
  private var tiles: [Tile] = []
  private let slider = UISlider()
  private let sliderTitle = UILabel()
  private let sliderValue = UILabel()
  private var displayLink: CADisplayLink?
  private let startTime = CACurrentMediaTime()

  private final class Tile: UIControl {
    let type: Int
    let glyphBox = UIView()
    let glyph = UILabel()
    let name = UILabel()
    let glyphMask = CALayer()
    init(type: Int, title: String) {
      self.type = type
      super.init(frame: .zero)
      layer.cornerRadius = 12
      layer.borderWidth = 2
      backgroundColor = EditorDesignTokens.Colors.elevatedSurface
      glyphBox.isUserInteractionEnabled = false
      glyphBox.clipsToBounds = true
      addSubview(glyphBox)
      if type == 0 {
        let icon = UIImageView(image: UIImage(systemName: "nosign", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)))
        icon.tintColor = EditorDesignTokens.Colors.textSecondary
        icon.contentMode = .center
        icon.frame = .zero
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glyphBox.addSubview(icon)
      } else {
        glyph.text = "Aa"
        glyph.font = .systemFont(ofSize: 18, weight: .bold)
        glyph.textColor = EditorDesignTokens.Colors.textPrimary
        glyph.textAlignment = .center
        glyph.layer.mask = glyphMask
        glyphMask.backgroundColor = UIColor.black.cgColor
        glyphBox.addSubview(glyph)
      }
      name.text = title
      name.font = .systemFont(ofSize: 12, weight: .medium)
      name.textColor = EditorDesignTokens.Colors.textSecondary
      name.textAlignment = .center
      name.adjustsFontSizeToFitWidth = true
      name.minimumScaleFactor = 0.8
      name.isUserInteractionEnabled = false
      addSubview(name)
      accessibilityLabel = title
      accessibilityTraits = .button
      isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
      super.layoutSubviews()
      glyphBox.frame = CGRect(x: 4, y: 4, width: bounds.width - 8, height: bounds.height - 26)
      glyphBox.subviews.first(where: { $0 is UIImageView })?.frame = glyphBox.bounds
      name.frame = CGRect(x: 4, y: bounds.height - 22, width: bounds.width - 8, height: 16)
    }
    func setSelected(_ on: Bool) {
      layer.borderColor = on ? EditorDesignTokens.Colors.selectedToolTint.cgColor : UIColor.clear.cgColor
      name.textColor = on ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.textSecondary
    }
    /// Shows the tile's own animation for state `s`.
    func show(_ s: TextAnimation.State) {
      guard type != 0 else { return }
      let size = CGSize(width: 44, height: 26)
      glyph.bounds = CGRect(origin: .zero, size: size)
      glyph.center = CGPoint(x: glyphBox.bounds.midX, y: glyphBox.bounds.midY)
      // Offsets are canvas fractions — exaggerated so they read in a tile.
      var t = CGAffineTransform(translationX: s.offsetX * glyphBox.bounds.width * 2.5, y: s.offsetY * glyphBox.bounds.height * 4)
      t = t.rotated(by: s.rotation).scaledBy(x: s.scale, y: s.scale)
      glyph.transform = t
      glyph.alpha = s.alpha
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      glyphMask.frame = CGRect(x: 0, y: 0, width: size.width * s.reveal, height: size.height)
      CATransaction.commit()
    }
  }

  init(config: TextAnimConfig) {
    self.config = config
    super.init(frame: .zero)
    backgroundColor = EditorDesignTokens.Colors.panelBackground
    layer.cornerRadius = 22
    layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    tab = config.inType != 0 || (config.outType == 0 && config.loopType == 0) ? 0 : (config.outType != 0 ? 1 : 2)
    build()
  }
  required init?(coder: NSCoder) { fatalError() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    displayLink?.invalidate()
    displayLink = nil
    if window != nil {
      let link = CADisplayLink(target: WeakProxy(self), selector: #selector(WeakProxy.tick))
      link.preferredFramesPerSecond = 30
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
  }

  private final class WeakProxy: NSObject {
    weak var owner: TextAnimationSheetView?
    init(_ owner: TextAnimationSheetView) { self.owner = owner }
    @objc func tick() { owner?.animateTiles() }
  }

  private func build() {
    func barButton(_ symbol: String, tint: UIColor, label: String, action: @escaping () -> Void) -> UIButton {
      let b = UIButton(type: .system)
      b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
      b.tintColor = tint
      b.accessibilityLabel = label
      b.addAction(UIAction { _ in
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
      }, for: .touchUpInside)
      b.widthAnchor.constraint(equalToConstant: 44).isActive = true
      b.heightAnchor.constraint(equalToConstant: 44).isActive = true
      return b
    }
    let cancel = barButton("xmark", tint: EditorDesignTokens.Colors.textPrimary, label: "Cancel") { [weak self] in self?.onClose?(false) }
    let done = barButton("checkmark", tint: EditorDesignTokens.Colors.accent, label: "Apply animation") { [weak self] in self?.onClose?(true) }
    let title = UILabel()
    title.text = "Animation"
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    title.textColor = EditorDesignTokens.Colors.textPrimary
    title.textAlignment = .center
    let header = UIStackView(arrangedSubviews: [cancel, title, done])
    header.alignment = .center

    let tabsRow = UIStackView()
    tabsRow.distribution = .fillEqually
    for (i, name) in ["In", "Out", "Loop"].enumerated() {
      let b = UIButton(type: .system)
      b.setTitle(name, for: .normal)
      b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
      b.addAction(UIAction { [weak self] _ in
        UISelectionFeedbackGenerator().selectionChanged()
        self?.selectTab(i)
      }, for: .touchUpInside)
      let dot = UIView()
      dot.backgroundColor = EditorDesignTokens.Colors.selectedToolTint
      dot.layer.cornerRadius = 2.5
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.isUserInteractionEnabled = false
      b.addSubview(dot)
      NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: 5), dot.heightAnchor.constraint(equalToConstant: 5),
        dot.leadingAnchor.constraint(equalTo: b.titleLabel!.trailingAnchor, constant: 4),
        dot.topAnchor.constraint(equalTo: b.titleLabel!.topAnchor),
      ])
      tabButtons.append(b)
      tabDots.append(dot)
      tabsRow.addArrangedSubview(b)
    }
    tabsRow.heightAnchor.constraint(equalToConstant: 40).isActive = true
    tabUnderline.backgroundColor = EditorDesignTokens.Colors.textPrimary
    tabUnderline.layer.cornerRadius = 1
    tabsRow.addSubview(tabUnderline)
    let divider = UIView()
    divider.backgroundColor = EditorDesignTokens.Colors.divider
    divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

    gridScroll.showsVerticalScrollIndicator = false
    gridScroll.alwaysBounceVertical = true
    // Two rows, plus a peek of the third so it's clear the grid scrolls.
    gridScroll.heightAnchor.constraint(equalToConstant: 196).isActive = true

    sliderTitle.text = "Duration"
    sliderTitle.font = .systemFont(ofSize: 13, weight: .medium)
    sliderTitle.textColor = EditorDesignTokens.Colors.textSecondary
    sliderTitle.setContentHuggingPriority(.required, for: .horizontal)
    sliderValue.font = EditorDesignTokens.Typography.sliderValue
    sliderValue.textColor = EditorDesignTokens.Colors.textPrimary
    sliderValue.textAlignment = .right
    sliderValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
    slider.minimumTrackTintColor = EditorDesignTokens.Colors.textPrimary
    slider.addAction(UIAction { [weak self] _ in self?.sliderChanged(final: false) }, for: .valueChanged)
    slider.addAction(UIAction { [weak self] _ in self?.sliderChanged(final: true) }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    let sliderRow = UIStackView(arrangedSubviews: [sliderTitle, slider, sliderValue])
    sliderRow.spacing = 12
    sliderRow.alignment = .center
    let sliderWrap = UIView()
    sliderRow.translatesAutoresizingMaskIntoConstraints = false
    sliderWrap.addSubview(sliderRow)
    NSLayoutConstraint.activate([
      sliderRow.topAnchor.constraint(equalTo: sliderWrap.topAnchor),
      sliderRow.bottomAnchor.constraint(equalTo: sliderWrap.bottomAnchor),
      sliderRow.leadingAnchor.constraint(equalTo: sliderWrap.leadingAnchor, constant: 6),
      sliderRow.trailingAnchor.constraint(equalTo: sliderWrap.trailingAnchor, constant: -6),
      sliderWrap.heightAnchor.constraint(equalToConstant: 44),
    ])

    let stack = UIStackView(arrangedSubviews: [header, tabsRow, divider, gridScroll, sliderWrap])
    stack.axis = .vertical
    stack.spacing = 0
    stack.setCustomSpacing(10, after: divider)
    stack.setCustomSpacing(8, after: gridScroll)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
    ])
    selectTab(tab, notify: false)
  }

  private var titles: [String] {
    switch tab {
    case 0: return TextAnimation.inTitles
    case 1: return TextAnimation.outTitles
    default: return TextAnimation.loopTitles
    }
  }

  private var currentType: Int {
    switch tab {
    case 0: return config.inType
    case 1: return config.outType
    default: return config.loopType
    }
  }

  private func selectTab(_ index: Int, notify: Bool = true) {
    tab = index
    for (i, b) in tabButtons.enumerated() {
      b.setTitleColor(i == index ? EditorDesignTokens.Colors.textPrimary : EditorDesignTokens.Colors.textSecondary, for: .normal)
    }
    tiles.forEach { $0.removeFromSuperview() }
    tiles = titles.enumerated().map { type, title in
      let tile = Tile(type: type, title: title)
      tile.addAction(UIAction { [weak self] _ in self?.pick(type) }, for: .touchUpInside)
      gridScroll.addSubview(tile)
      return tile
    }
    gridScroll.contentOffset = .zero
    refreshSelection()
    setNeedsLayout()
    if notify, currentType != 0 { onChange?(config, tab) }
  }

  private func pick(_ type: Int) {
    UISelectionFeedbackGenerator().selectionChanged()
    switch tab {
    case 0: config.inType = type
    case 1: config.outType = type
    default: config.loopType = type
    }
    refreshSelection()
    onChange?(config, tab)
  }

  private func refreshSelection() {
    let type = currentType
    for tile in tiles { tile.setSelected(tile.type == type) }
    for (i, dot) in tabDots.enumerated() {
      dot.isHidden = [config.inType, config.outType, config.loopType][i] == 0
    }
    let isLoop = tab == 2
    let range = isLoop ? TextAnimation.loopPeriodRange : TextAnimation.durationRange
    slider.minimumValue = Float(range.lowerBound)
    slider.maximumValue = Float(range.upperBound)
    slider.value = Float(tab == 0 ? config.inDuration : tab == 1 ? config.outDuration : config.loopPeriod)
    sliderTitle.text = isLoop ? "Cycle" : "Duration"
    let enabled = type != 0
    slider.isEnabled = enabled
    slider.superview?.alpha = enabled ? 1 : 0.4
    updateSliderLabel()
  }

  private func updateSliderLabel() {
    sliderValue.text = String(format: "%.1fs", (Double(slider.value) * 10).rounded() / 10)
  }

  private func sliderChanged(final: Bool) {
    let v = (Double(slider.value) * 10).rounded() / 10
    switch tab {
    case 0: config.inDuration = v
    case 1: config.outDuration = v
    default: config.loopPeriod = v
    }
    updateSliderLabel()
    if final { onChange?(config, tab) }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if let row = tabUnderline.superview, tab < tabButtons.count {
      let b = tabButtons[tab]
      tabUnderline.frame = CGRect(x: b.frame.midX - 14, y: row.bounds.height - 3, width: 28, height: 2)
    }
    let columns = 4
    let gap: CGFloat = 8
    let width = gridScroll.bounds.width
    guard width > 0 else { return }
    let tileW = floor((width - gap * CGFloat(columns - 1)) / CGFloat(columns))
    let tileH: CGFloat = 86
    for (i, tile) in tiles.enumerated() {
      let col = i % columns, row = i / columns
      tile.frame = CGRect(x: CGFloat(col) * (tileW + gap), y: CGFloat(row) * (tileH + gap), width: tileW, height: tileH)
    }
    let rows = (tiles.count + columns - 1) / columns
    gridScroll.contentSize = CGSize(width: width, height: CGFloat(rows) * (tileH + gap))
    animateTiles()
  }

  /// Each tile plays its own animation on a 2 s cycle (In: comes in and
  /// holds; Out: holds and leaves; Loop: keeps going).
  private func animateTiles() {
    let cycle = 2.0
    let t = (CACurrentMediaTime() - startTime).truncatingRemainder(dividingBy: cycle)
    for tile in tiles where tile.type != 0 {
      var c = TextAnimConfig()
      c.inDuration = 0.6
      c.outDuration = 0.6
      c.loopPeriod = 1.0
      let segment: ClosedRange<Double>
      switch tab {
      case 0: c.inType = tile.type; segment = 0.2...100
      case 1: c.outType = tile.type; segment = -100...1.6
      default: c.loopType = tile.type; segment = 0...100
      }
      var s = TextAnimation.state(at: t, segments: [segment], config: c)
      if !segment.contains(t) { s.alpha = 0 }
      tile.show(s)
    }
  }

  deinit { displayLink?.invalidate() }
}

/// Location picker's waiting state: radar rings pulsing out from a bobbing
/// map pin, with a line saying what is being looked up ("Finding places
/// near you…", "Searching “cafe”…"). Drop-in for the old spinner
/// (startAnimating / stopAnimating; hidden while stopped). Same design and
/// timings as Android's LocationSearchingView.
final class LocationSearchingView: UIView {
  var message = "Finding places near you…" {
    didSet { label.text = message }
  }
  private(set) var isAnimating = false

  private static let ringPeriod: CFTimeInterval = 1.8
  private static let bobHalfPeriod: CFTimeInterval = 0.45
  private static let graphicSize = CGSize(width: 120, height: 128)
  private static let baseY: CGFloat = 76

  private let graphic = UIView()
  private let label = UILabel()
  private var rings: [CAShapeLayer] = []
  private let pinLayer = CALayer()
  private let shadowLayer = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isHidden = true
    isUserInteractionEnabled = false
    backgroundColor = EditorDesignTokens.Colors.chromeBackground.withAlphaComponent(0.92)
    layer.cornerRadius = 20

    graphic.translatesAutoresizingMaskIntoConstraints = false
    addSubview(graphic)
    label.text = message
    label.textColor = EditorDesignTokens.Colors.textSecondary
    label.font = .systemFont(ofSize: 14)
    label.textAlignment = .center
    label.numberOfLines = 2
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      graphic.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      graphic.centerXAnchor.constraint(equalTo: centerXAnchor),
      graphic.widthAnchor.constraint(equalToConstant: Self.graphicSize.width),
      graphic.heightAnchor.constraint(equalToConstant: Self.graphicSize.height),
      label.topAnchor.constraint(equalTo: graphic.bottomAnchor, constant: 4),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
      widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
    ])
    buildLayers()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func buildLayers() {
    let accent = EditorDesignTokens.Colors.accent
    let cx = Self.graphicSize.width / 2
    let base = Self.baseY

    // Radar rings, scaled/faded by animations (see startAnimating).
    for _ in 0..<3 {
      let ring = CAShapeLayer()
      ring.frame = CGRect(x: cx - 52, y: base - 52, width: 104, height: 104)
      ring.path = UIBezierPath(ovalIn: ring.bounds).cgPath
      ring.strokeColor = accent.cgColor
      ring.fillColor = accent.withAlphaComponent(0.18).cgColor
      ring.lineWidth = 2
      ring.opacity = 0
      graphic.layer.addSublayer(ring)
      rings.append(ring)
    }

    shadowLayer.frame = CGRect(x: cx - 12, y: base - 4, width: 24, height: 8)
    shadowLayer.path = UIBezierPath(ovalIn: shadowLayer.bounds).cgPath
    shadowLayer.fillColor = UIColor.black.cgColor
    shadowLayer.opacity = 0.35
    graphic.layer.addSublayer(shadowLayer)

    // Teardrop: circle (r 13) whose two tangents meet at the tip (base).
    pinLayer.frame = graphic.bounds.isEmpty
      ? CGRect(origin: .zero, size: Self.graphicSize)
      : graphic.bounds
    let r: CGFloat = 13
    let center = CGPoint(x: cx, y: base - 21)
    let alpha = asin(r / 21)
    let pinPath = UIBezierPath()
    pinPath.move(to: CGPoint(x: cx, y: base))
    pinPath.addArc(withCenter: center, radius: r, startAngle: .pi - alpha, endAngle: 2 * .pi + alpha, clockwise: true)
    pinPath.close()
    let pin = CAShapeLayer()
    pin.path = pinPath.cgPath
    pin.fillColor = accent.cgColor
    let dot = CAShapeLayer()
    dot.path = UIBezierPath(arcCenter: center, radius: 5, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
    dot.fillColor = UIColor.white.cgColor
    pinLayer.addSublayer(pin)
    pinLayer.addSublayer(dot)
    graphic.layer.addSublayer(pinLayer)
  }

  func startAnimating() {
    guard !isAnimating else { return }
    isAnimating = true
    isHidden = false
    let now = CACurrentMediaTime()
    for (i, ring) in rings.enumerated() {
      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 0.15
      scale.toValue = 1
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0.55
      fade.toValue = 0
      let group = CAAnimationGroup()
      group.animations = [scale, fade]
      group.duration = Self.ringPeriod
      group.repeatCount = .infinity
      group.beginTime = now + Self.ringPeriod * Double(i) / 3
      group.fillMode = .backwards
      ring.add(group, forKey: "pulse")
    }
    let bob = CABasicAnimation(keyPath: "transform.translation.y")
    bob.fromValue = 0
    bob.toValue = -10
    bob.duration = Self.bobHalfPeriod
    bob.autoreverses = true
    bob.repeatCount = .infinity
    bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    pinLayer.add(bob, forKey: "bob")

    let shrink = CABasicAnimation(keyPath: "transform.scale")
    shrink.fromValue = 1
    shrink.toValue = 0.65
    let dim = CABasicAnimation(keyPath: "opacity")
    dim.fromValue = 0.35
    dim.toValue = 0.18
    let shadowGroup = CAAnimationGroup()
    shadowGroup.animations = [shrink, dim]
    shadowGroup.duration = Self.bobHalfPeriod
    shadowGroup.autoreverses = true
    shadowGroup.repeatCount = .infinity
    shadowGroup.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    shadowLayer.add(shadowGroup, forKey: "bob")
  }

  func stopAnimating() {
    guard isAnimating else { return }
    isAnimating = false
    isHidden = true
    rings.forEach { $0.removeAllAnimations() }
    pinLayer.removeAllAnimations()
    shadowLayer.removeAllAnimations()
  }

  /// Animations are dropped when the view leaves the window (sheet
  /// re-presented, app backgrounded) — restart them on return.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil, isAnimating else { return }
    isAnimating = false
    startAnimating()
  }
}
