import UIKit
import AVFoundation

/// Thin UIView whose backing layer IS an AVPlayerLayer, so AVFoundation
/// renders directly without an intermediate CALayer hop. Deliberately no
/// built-in transport controls (unlike AVPlayerViewController) — the editor
/// builds its own play/pause now and timeline/trim UI in later days, and a
/// system control overlay would only be in the way of that.
final class VideoPlayerContainerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }
}
