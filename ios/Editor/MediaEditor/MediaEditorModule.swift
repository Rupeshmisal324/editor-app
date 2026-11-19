import Foundation
import UIKit
import AVFoundation
import React

/// RN bridge entry point for the native media editor. Presents a full-screen
/// UIViewController and resolves the Promise on Cancel/Done — never streams
/// editing state back over the bridge (see project architecture doc).
@objc(MediaEditorModule)
final class MediaEditorModule: NSObject, RCTBridgeModule {

  /// True from open() until the editor's result is sent — see open().
  private static var isEditorOpen = false

  /// Editor outputs (exports, story filter/collage/boomerang/effect files,
  /// downloaded music, voice temps) are handed to JS for upload and never
  /// deleted, so they piled up in tmp. Anything of ours older than 2 days
  /// (same window as re-edit projects) is long uploaded — removed on open.
  private static func pruneOldEditorFiles() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory
    guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
    let cutoff = Date().addingTimeInterval(-MediaEditorEditProject.maxAgeSeconds)
    let prefixes = ["story_collage_", "story_boomerang_", "story_filtered_", "story_effect_", "editor_music_", "voice-"]
    for entry in entries {
      let name = entry.lastPathComponent
      let base = (name as NSString).deletingPathExtension
      guard prefixes.contains(where: { name.hasPrefix($0) }) || UUID(uuidString: base) != nil else { continue }
      let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      guard values?.isRegularFile == true, let modified = values?.contentModificationDate, modified < cutoff else { continue }
      try? fm.removeItem(at: entry)
    }
  }

  static func moduleName() -> String! {
    "MediaEditorModule"
  }

  static func requiresMainQueueSetup() -> Bool {
    false
  }

  @objc(open:resolver:rejecter:)
  func open(
    _ input: NSDictionary,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    // A second open while the editor is already opening/open (e.g. a
    // double-tap) can't present (UIKit refuses), so its promise never
    // settled. Keep the first; the duplicate cancels.
    guard !Self.isEditorOpen else {
      resolve(["status": "cancelled"])
      return
    }
    guard
      let inputURIString = input["uri"] as? String,
      let type = input["type"] as? String,
      type == "image" || type == "video"
    else {
      resolve([
        "status": "error",
        "code": "invalid_media",
        "message": "Missing or invalid 'uri'/'type' in input.",
      ])
      return
    }

    // Re-edit: a project from a previous photo export reopens the untouched
    // source (not the flattened export in `uri`) with its layers rebuilt.
    // Falls back to a plain open of `uri` if the project is missing/stale.
    let editProject: MediaEditorEditProject? = type == "image"
      ? (input["editProject"] as? String).flatMap(MediaEditorEditProject.decode)
      : nil
    let uriString = editProject?.sourceURL.absoluteString ?? inputURIString
    DispatchQueue.global(qos: .utility).async {
      MediaEditorEditProject.pruneStaleProjects(keeping: editProject?.id)
      Self.pruneOldEditorFiles()
    }

    // Story camera flow only — swaps the primary button's label to "Share
    // your story"; export/result plumbing below is identical either way.
    let isStoryMode = (input["isStoryMode"] as? Bool) ?? false

    // Crosses the bridge once, here, at open time — never re-fetched or
    // streamed while the editor is up (see project architecture doc).
    let musicTracks: [MusicTrack] = (input["musicTracks"] as? [NSDictionary])?.compactMap { dict in
      guard
        let id = dict["id"] as? String,
        let title = dict["title"] as? String,
        let artist = dict["artist"] as? String,
        let albumArt = dict["albumArt"] as? String,
        let audioURLString = dict["audioUrl"] as? String,
        let audioURL = URL(string: audioURLString)
      else { return nil }
      return MusicTrack(id: id, title: title, artist: artist, albumArt: albumArt, audioURL: audioURL)
    } ?? []

    Self.isEditorOpen = true
    readMediaMetadata(uriString: uriString, type: type) { [weak self] metadata in
      guard let self else {
        DispatchQueue.main.async { Self.isEditorOpen = false }
        return
      }

      guard let metadata else {
        DispatchQueue.main.async { Self.isEditorOpen = false }
        resolve([
          "status": "error",
          "code": "invalid_media",
          "message": "Could not read media at \(uriString).",
        ])
        return
      }

      DispatchQueue.main.async {
        guard let presenter = RCTPresentedViewController() else {
          Self.isEditorOpen = false
          resolve([
            "status": "error",
            "code": "processing_error",
            "message": "No view controller available to present the editor.",
          ])
          return
        }

        var didResolve = false
        weak var weakEditor: MediaEditorViewController?
        let finish: (MediaEditorResultPayload) -> Void = { payload in
          guard !didResolve else { return }
          didResolve = true
          Self.isEditorOpen = false
          presenter.dismiss(animated: true) {
            resolve(payload.asDictionary)
          }
        }

        // Safe to force-unwrap: readMediaMetadata already succeeded above,
        // which required this same normalizedFileURL(from:) to resolve.
        let editor = MediaEditorViewController(
          sourceURL: MediaEditorModule.normalizedFileURL(from: uriString)!,
          mediaType: type,
          musicTracks: musicTracks,
          isStoryMode: isStoryMode,
          editProject: editProject,
          onCancel: { finish(.cancelled) },
          onDone: { outcome in
            switch outcome {
            case let .exported(uri, width, height, duration, resultType, stickers):
              finish(.success(
                type: resultType, uri: uri, width: width, height: height, duration: duration, stickers: stickers,
                editProject: weakEditor?.exportedEditProjectJSON
              ))
            case .passthrough:
              // No export pipeline for this media type yet (video —
              // Milestone 3) — report the untouched original, exactly the
              // Milestone 1/2 behavior.
              finish(.success(
                type: type,
                uri: uriString,
                width: metadata.width,
                height: metadata.height,
                duration: metadata.duration,
                stickers: [],
                editProject: nil
              ))
            case let .failed(message):
              finish(.error(code: "export_failed", message: message))
            }
          }
        )

        weakEditor = editor
        presenter.present(editor, animated: true)
      }
    }
  }

  // MARK: - Story camera helpers

  /// Layout mode: draws each captured photo into its cell of one canvas.
  /// Each cell's `x/y/w/h` is normalized (0-1) to the canvas. The camera
  /// preview is shown per cell, aspect-filled, so each photo is center-
  /// cropped to its cell's shape here to match. `previewAspect` (portrait
  /// width/height of the camera's preview stream) crops the photo to what
  /// the preview could see first — photos are usually 4:3 while the
  /// preview is 16:9. `mirror` flips a front-camera photo so it matches the
  /// mirrored preview.
  @objc(composeCollage:resolver:rejecter:)
  func composeCollage(
    _ input: NSDictionary,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let cells = (input["cells"] as? [NSDictionary]) ?? []
    let width = (input["width"] as? NSNumber)?.doubleValue ?? 1080
    let height = (input["height"] as? NSNumber)?.doubleValue ?? 1920
    guard !cells.isEmpty else {
      reject("invalid_input", "No cells to compose.", nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let size = CGSize(width: width, height: height)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let output = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
        UIColor.black.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        for cell in cells {
          guard
            let uri = cell["uri"] as? String,
            let url = MediaEditorModule.normalizedFileURL(from: uri),
            let data = try? Data(contentsOf: url),
            let loaded = UIImage(data: data)
          else { continue }
          let x = (cell["x"] as? NSNumber)?.doubleValue ?? 0
          let y = (cell["y"] as? NSNumber)?.doubleValue ?? 0
          let w = (cell["w"] as? NSNumber)?.doubleValue ?? 1
          let h = (cell["h"] as? NSNumber)?.doubleValue ?? 1
          let mirror = (cell["mirror"] as? Bool) ?? false
          let previewAspect = (cell["previewAspect"] as? NSNumber)?.doubleValue ?? 0
          let image = MediaEditorModule.uprightImage(loaded, mirrored: mirror)
          guard let cgImage = image.cgImage else { continue }

          // Center crop to the cell's aspect — what the aspect-fill
          // per-cell preview showed.
          let dest = CGRect(x: x * width, y: y * height, width: w * width, height: h * height)
          let cellAspect = dest.width / dest.height
          // What the preview stream could see (centered), then the part of
          // that the aspect-filled cell showed.
          var visibleW = Double(cgImage.width)
          var visibleH = Double(cgImage.height)
          if previewAspect > 0 {
            if visibleW / visibleH > previewAspect {
              visibleW = visibleH * previewAspect
            } else {
              visibleH = visibleW / previewAspect
            }
          }
          var cropW = visibleW
          var cropH = visibleW / cellAspect
          if cropH > visibleH {
            cropH = visibleH
            cropW = visibleH * cellAspect
          }
          let crop = CGRect(
            x: (Double(cgImage.width) - cropW) / 2,
            y: (Double(cgImage.height) - cropH) / 2,
            width: cropW,
            height: cropH
          ).integral
          guard let cropped = cgImage.cropping(to: crop) else { continue }
          UIImage(cgImage: cropped).draw(in: dest)
        }
      }
      guard let jpeg = output.jpegData(compressionQuality: 0.92) else {
        reject("export_failed", "Could not encode collage.", nil)
        return
      }
      let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("story_collage_\(UUID().uuidString).jpg")
      do {
        try jpeg.write(to: outURL)
        resolve(["uri": outURL.absoluteString, "width": Int(width), "height": Int(height)])
      } catch {
        reject("export_failed", error.localizedDescription, error)
      }
    }
  }

  /// Boomerang mode: samples `frameCount` frames evenly from the short
  /// recorded clip at `videoUri`, then encodes them forward then backward,
  /// repeated `loops` times, into an H.264 mp4 at `fps`.
  @objc(makeBoomerang:resolver:rejecter:)
  func makeBoomerang(
    _ input: NSDictionary,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    guard
      let videoUri = input["videoUri"] as? String,
      let videoURL = MediaEditorModule.normalizedFileURL(from: videoUri)
    else {
      reject("invalid_input", "Missing 'videoUri'.", nil)
      return
    }
    let frameCount = max(2, (input["frameCount"] as? NSNumber)?.intValue ?? 15)
    let fps = max(1, (input["fps"] as? NSNumber)?.int32Value ?? 24)
    let loops = max(1, (input["loops"] as? NSNumber)?.intValue ?? 3)
    DispatchQueue.global(qos: .userInitiated).async {
      let asset = AVURLAsset(url: videoURL)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      // 720p keeps up to ~40 decoded frames (a 5s hold) light on memory.
      generator.maximumSize = CGSize(width: 720, height: 1280)
      let tolerance = CMTime(value: 1, timescale: 60)
      generator.requestedTimeToleranceBefore = tolerance
      generator.requestedTimeToleranceAfter = tolerance
      let durationSeconds = CMTimeGetSeconds(asset.duration)
      var images: [CGImage] = []
      if durationSeconds > 0 {
        for index in 0..<frameCount {
          let seconds = durationSeconds * Double(index) / Double(frameCount)
          if let image = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) {
            images.append(image)
          }
        }
      }
      guard images.count >= 2, let first = images.first else {
        reject("invalid_input", "Not enough frames for a boomerang.", nil)
        return
      }
      // Forward, then backward without repeating either end frame.
      let pingPong = images + images.dropFirst().dropLast().reversed()
      var sequence: [CGImage] = []
      for _ in 0..<loops { sequence.append(contentsOf: pingPong) }

      // Even dimensions (H.264), capped at 720 wide.
      let scale = min(1, 720 / Double(first.width))
      let outW = Int(Double(first.width) * scale) / 2 * 2
      let outH = Int(Double(first.height) * scale) / 2 * 2
      let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("story_boomerang_\(UUID().uuidString).mp4")

      do {
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: outW,
          AVVideoHeightKey: outH,
        ])
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
          assetWriterInput: writerInput,
          sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
          ]
        )
        writer.add(writerInput)
        guard writer.startWriting() else {
          throw writer.error ?? NSError(domain: "MediaEditor", code: -1)
        }
        writer.startSession(atSourceTime: .zero)

        for (index, image) in sequence.enumerated() {
          while !writerInput.isReadyForMoreMediaData { usleep(2000) }
          guard let pool = adaptor.pixelBufferPool else { break }
          var bufferOut: CVPixelBuffer?
          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
          guard let buffer = bufferOut else { continue }
          CVPixelBufferLockBaseAddress(buffer, [])
          if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          ) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
          }
          CVPixelBufferUnlockBaseAddress(buffer, [])
          adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
        }
        writerInput.markAsFinished()
        let duration = Double(sequence.count) / Double(fps)
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(sequence.count), timescale: fps))
        writer.finishWriting {
          if writer.status == .completed {
            resolve(["uri": outURL.absoluteString, "duration": duration, "width": outW, "height": outH])
          } else {
            reject("export_failed", writer.error?.localizedDescription ?? "Boomerang export failed.", writer.error)
          }
        }
      } catch {
        reject("export_failed", error.localizedDescription, error)
      }
    }
  }

  /// Bakes a story-camera live filter into a captured photo or video.
  /// `matrix` is the same 20-value row-major color matrix (translation
  /// normalized 0-1) the Skia camera preview draws with, applied here to
  /// raw (non-color-managed) sRGB values so the result matches the preview.
  @objc(applyColorMatrix:resolver:rejecter:)
  func applyColorMatrix(
    _ input: NSDictionary,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    guard
      let uri = input["uri"] as? String,
      let url = MediaEditorModule.normalizedFileURL(from: uri),
      let type = input["type"] as? String,
      let values = (input["matrix"] as? [NSNumber])?.map({ CGFloat($0.doubleValue) }),
      values.count == 20
    else {
      reject("invalid_input", "Missing 'uri', 'type' or a 20-value 'matrix'.", nil)
      return
    }
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let applyMatrix: (CIImage) -> CIImage = { image in
      let filter = CIFilter(name: "CIColorMatrix")!
      filter.setValue(image, forKey: kCIInputImageKey)
      filter.setValue(CIVector(x: values[0], y: values[1], z: values[2], w: values[3]), forKey: "inputRVector")
      filter.setValue(CIVector(x: values[5], y: values[6], z: values[7], w: values[8]), forKey: "inputGVector")
      filter.setValue(CIVector(x: values[10], y: values[11], z: values[12], w: values[13]), forKey: "inputBVector")
      filter.setValue(CIVector(x: values[15], y: values[16], z: values[17], w: values[18]), forKey: "inputAVector")
      filter.setValue(CIVector(x: values[4], y: values[9], z: values[14], w: values[19]), forKey: "inputBiasVector")
      return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    if type == "image" {
      DispatchQueue.global(qos: .userInitiated).async {
        guard
          let data = try? Data(contentsOf: url),
          let loaded = UIImage(data: data),
          let cgImage = MediaEditorModule.uprightImage(loaded, mirrored: false).cgImage,
          let output = context.createCGImage(applyMatrix(CIImage(cgImage: cgImage)), from: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)),
          let jpeg = UIImage(cgImage: output).jpegData(compressionQuality: 0.92)
        else {
          reject("export_failed", "Could not filter photo.", nil)
          return
        }
        let outURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("story_filtered_\(UUID().uuidString).jpg")
        do {
          try jpeg.write(to: outURL)
          resolve(["uri": outURL.absoluteString])
        } catch {
          reject("export_failed", error.localizedDescription, error)
        }
      }
      return
    }

    let asset = AVURLAsset(url: url)
    let composition = AVMutableVideoComposition(asset: asset) { request in
      request.finish(with: applyMatrix(request.sourceImage.clampedToExtent()).cropped(to: request.sourceImage.extent), context: context)
    }
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
      reject("export_failed", "Could not create video export session.", nil)
      return
    }
    let outURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("story_filtered_\(UUID().uuidString).mp4")
    session.outputURL = outURL
    session.outputFileType = .mp4
    session.videoComposition = composition
    session.exportAsynchronously {
      if session.status == .completed {
        resolve(["uri": outURL.absoluteString])
      } else {
        reject("export_failed", session.error?.localizedDescription ?? "Could not filter video.", session.error)
      }
    }
  }

  /// Bakes a story-camera shader effect into a recorded video. `shader` is
  /// the effect's Core Image kernel, translated in JS from the same SkSL
  /// the live preview runs (utils/storyEffectShaders.ts):
  /// `kernel vec4 storyEffect(sampler image, vec2 res)`. Rendered without
  /// color management, like applyColorMatrix, to match the preview.
  @objc(applyShaderEffect:resolver:rejecter:)
  func applyShaderEffect(
    _ input: NSDictionary,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    guard
      let uri = input["uri"] as? String,
      let url = MediaEditorModule.normalizedFileURL(from: uri),
      let source = input["shader"] as? String
    else {
      reject("invalid_input", "Missing 'uri' or 'shader'.", nil)
      return
    }
    guard let kernel = CIKernel(source: source) else {
      reject("invalid_input", "Effect kernel failed to compile.", nil)
      return
    }
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let asset = AVURLAsset(url: url)
    let composition = AVMutableVideoComposition(asset: asset) { request in
      let image = request.sourceImage
      let extent = image.extent
      // Effects can sample anywhere in the frame (zoom, bulge, pixel
      // cells), so every output pixel may need the whole input.
      let output = kernel.apply(
        extent: extent,
        roiCallback: { _, _ in extent },
        arguments: [image.clampedToExtent(), CIVector(x: extent.width, y: extent.height)]
      )
      request.finish(with: (output ?? image).cropped(to: extent), context: context)
    }
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
      reject("export_failed", "Could not create video export session.", nil)
      return
    }
    let outURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("story_effect_\(UUID().uuidString).mp4")
    session.outputURL = outURL
    session.outputFileType = .mp4
    session.videoComposition = composition
    session.exportAsynchronously {
      if session.status == .completed {
        resolve(["uri": outURL.absoluteString])
      } else {
        reject("export_failed", session.error?.localizedDescription ?? "Could not apply effect to video.", session.error)
      }
    }
  }

  /// Redraws `image` with its EXIF orientation baked in (and optionally
  /// flipped horizontally) so `cgImage` pixels are upright.
  private static func uprightImage(_ image: UIImage, mirrored: Bool) -> UIImage {
    if image.imageOrientation == .up && !mirrored { return image }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
      if mirrored {
        ctx.cgContext.translateBy(x: image.size.width, y: 0)
        ctx.cgContext.scaleBy(x: -1, y: 1)
      }
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }

  // MARK: - Metadata

  /// Pickers on iOS (react-native-image-crop-picker, etc.) commonly hand back
  /// a plain absolute path with no scheme (e.g. "/private/var/..."). Passing
  /// that straight to `URL(string:)` "succeeds" but produces a schemeless
  /// relative-reference URL that `Data(contentsOf:)`/`AVURLAsset` can't read.
  /// Only treat a string as already-a-URL if it actually parsed a scheme;
  /// otherwise build a proper file:// URL from the raw path.
  private static func normalizedFileURL(from uriString: String) -> URL? {
    if let url = URL(string: uriString), url.scheme != nil {
      return url
    }
    return URL(fileURLWithPath: uriString)
  }

  private struct MediaMetadata {
    let width: Int
    let height: Int
    let duration: Double
  }

  private func readMediaMetadata(
    uriString: String,
    type: String,
    completion: @escaping (MediaMetadata?) -> Void
  ) {
    guard let url = MediaEditorModule.normalizedFileURL(from: uriString) else {
      completion(nil)
      return
    }

    if type == "image" {
      DispatchQueue.global(qos: .userInitiated).async {
        guard
          let data = try? Data(contentsOf: url),
          let image = UIImage(data: data)
        else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        let metadata = MediaMetadata(
          width: Int(image.size.width * image.scale),
          height: Int(image.size.height * image.scale),
          duration: 0
        )
        DispatchQueue.main.async { completion(metadata) }
      }
      return
    }

    // video
    let asset = AVURLAsset(url: url)
    Task {
      do {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
          await MainActor.run { completion(nil) }
          return
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let transformedSize = size.applying(transform)
        let metadata = MediaMetadata(
          width: Int(abs(transformedSize.width)),
          height: Int(abs(transformedSize.height)),
          duration: CMTimeGetSeconds(duration)
        )
        await MainActor.run { completion(metadata) }
      } catch {
        await MainActor.run { completion(nil) }
      }
    }
  }
}

private enum MediaEditorResultPayload {
  case cancelled
  case success(type: String, uri: String, width: Int, height: Int, duration: Double, stickers: [[String: Any]], editProject: String?)
  case error(code: String, message: String)

  var asDictionary: [String: Any] {
    switch self {
    case .cancelled:
      return ["status": "cancelled"]
    case let .success(type, uri, width, height, duration, stickers, editProject):
      var dict: [String: Any] = [
        "status": "success",
        "type": type,
        "uri": uri,
        "width": width,
        "height": height,
        "duration": duration,
        "stickers": stickers,
      ]
      if let editProject { dict["editProject"] = editProject }
      return dict
    case let .error(code, message):
      return ["status": "error", "code": code, "message": message]
    }
  }
}

/// One entry from the app's music catalog (see staticMusicData.ts on the RN
/// side), handed to the editor once at open time.
struct MusicTrack {
  let id: String
  let title: String
  let artist: String
  let albumArt: String
  let audioURL: URL
  /// 0 for tracks handed in from the RN bridge (staticMusicData.ts never
  /// carried a duration) — only MusicAPI's live iTunes-backed fetch
  /// populates this, for the picker row's duration label.
  let durationSeconds: Double

  // Explicit init (not the synthesized memberwise one): a stored `let`
  // with an inline default is dropped from Swift's synthesized memberwise
  // initializer entirely, so callers couldn't pass durationSeconds at all
  // without this.
  init(id: String, title: String, artist: String, albumArt: String, audioURL: URL, durationSeconds: Double = 0) {
    self.id = id
    self.title = title
    self.artist = artist
    self.albumArt = albumArt
    self.audioURL = audioURL
    self.durationSeconds = durationSeconds
  }
}

/// What the editor screen reports back through `onDone`.
enum MediaEditorDoneOutcome {
  /// `resultType` is "image" or "video" — what was ACTUALLY produced, which
  /// can differ from the input `type` (a photo + music export mixes the
  /// still image into an exported video; see MediaEditorViewController's
  /// exportImageWithMusic). The bridge reports this, not the input type.
  /// `stickers` — one metadata entry per visible location sticker (see
  /// MediaEditorViewController.locationStickerMetadata); empty otherwise.
  case exported(uri: String, width: Int, height: Int, duration: Double, resultType: String, stickers: [[String: Any]])
  /// No export pipeline for this media type yet (video — Milestone 3).
  case passthrough
  case failed(message: String)
}
