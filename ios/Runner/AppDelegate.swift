import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CapSubMediaPlugin") else {
      return
    }
    let mediaChannel = FlutterMethodChannel(name: "com.capcut.capsub/media",
                                            binaryMessenger: registrar.messenger())
    mediaChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "probeMedia":
        guard let args = call.arguments as? [String: Any],
              let mediaPath = args["mediaPath"] as? String,
              let mediaUrl = self.makeMediaUrl(mediaPath) else {
          result(FlutterError(code: "INVALID_ARGS", message: "Invalid media path", details: nil))
          return
        }
        self.probeDuration(url: mediaUrl, result: result)

      case "extractAudio":
        guard let args = call.arguments as? [String: Any],
              let videoPath = args["videoPath"] as? String,
              let outputPath = args["outputPath"] as? String,
              let videoUrl = self.makeMediaUrl(videoPath) else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
          return
        }
        let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
        let durationMs = (args["durationMs"] as? NSNumber)?.int64Value ?? -1
        self.extractAudio(
          sourceUrl: videoUrl,
          outputUrl: URL(fileURLWithPath: outputPath),
          startMs: startMs,
          requestedDurationMs: durationMs,
          result: result
        )

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func makeMediaUrl(_ path: String) -> URL? {
    if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
      return URL(string: path)
    }
    return URL(fileURLWithPath: path)
  }

  private func finish(_ result: @escaping FlutterResult, value: Any?) {
    DispatchQueue.main.async {
      result(value)
    }
  }

  private func probeDuration(url: URL, result: @escaping FlutterResult) {
    Task {
      let didAccess = url.isFileURL && url.startAccessingSecurityScopedResource()
      defer {
        if didAccess { url.stopAccessingSecurityScopedResource() }
      }
      do {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationMs = Int64((CMTimeGetSeconds(duration) * 1000).rounded())
        guard durationMs > 0 else {
          throw NSError(domain: "CapSubMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "Media has no valid duration"])
        }
        self.finish(result, value: durationMs)
      } catch {
        self.finish(result, value: FlutterError(code: "PROBE_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func extractAudio(
    sourceUrl: URL,
    outputUrl: URL,
    startMs: Int64,
    requestedDurationMs: Int64,
    result: @escaping FlutterResult
  ) {
    Task {
      let didAccess = sourceUrl.isFileURL && sourceUrl.startAccessingSecurityScopedResource()
      defer {
        if didAccess { sourceUrl.stopAccessingSecurityScopedResource() }
      }

      do {
        let asset = AVURLAsset(url: sourceUrl)
        let assetDuration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceTrack = audioTracks.first else {
          throw NSError(domain: "CapSubMedia", code: 2, userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy track âm thanh"])
        }

        let safeStart = max(0, startMs)
        let startTime = CMTime(value: safeStart, timescale: 1000)
        let remaining = CMTimeSubtract(assetDuration, startTime)
        guard CMTimeCompare(remaining, .zero) > 0 else {
          throw NSError(domain: "CapSubMedia", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mốc bắt đầu nằm ngoài thời lượng media"])
        }

        let requested = requestedDurationMs > 0
          ? CMTime(value: requestedDurationMs, timescale: 1000)
          : remaining
        let clipDuration = CMTimeCompare(remaining, requested) <= 0 ? remaining : requested

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
          withMediaType: .audio,
          preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
          throw NSError(domain: "CapSubMedia", code: 4, userInfo: [NSLocalizedDescriptionKey: "Không thể tạo audio composition"])
        }
        try compositionTrack.insertTimeRange(
          CMTimeRange(start: startTime, duration: clipDuration),
          of: sourceTrack,
          at: .zero
        )

        try? FileManager.default.removeItem(at: outputUrl)
        try FileManager.default.createDirectory(
          at: outputUrl.deletingLastPathComponent(),
          withIntermediateDirectories: true,
          attributes: nil
        )

        let presets = AVAssetExportSession.exportPresets(compatibleWith: composition)
        let preset = presets.contains(AVAssetExportPresetPassthrough)
          ? AVAssetExportPresetPassthrough
          : AVAssetExportPresetAppleM4A
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
          throw NSError(domain: "CapSubMedia", code: 5, userInfo: [NSLocalizedDescriptionKey: "Không thể tạo export session"])
        }
        guard exportSession.supportedFileTypes.contains(.m4a) else {
          throw NSError(domain: "CapSubMedia", code: 6, userInfo: [NSLocalizedDescriptionKey: "Codec âm thanh không hỗ trợ xuất M4A"])
        }

        exportSession.outputURL = outputUrl
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { continuation in
          exportSession.exportAsynchronously {
            continuation.resume()
          }
        }

        guard exportSession.status == .completed else {
          throw exportSession.error ?? NSError(
            domain: "CapSubMedia",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Xuất audio thất bại"]
          )
        }
        let exportedMs = Int64((CMTimeGetSeconds(clipDuration) * 1000).rounded())
        self.finish(result, value: exportedMs)
      } catch {
        try? FileManager.default.removeItem(at: outputUrl)
        self.finish(result, value: FlutterError(code: "EXPORT_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }
}
