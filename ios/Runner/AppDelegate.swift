import Flutter
import UIKit
import AVFoundation
import UserNotifications
import VideoToolbox

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let pcmQueue = DispatchQueue(label: "com.ksub.app.pcm")
  private var pcmSessions: [String: IosPcmStreamSession] = [:]
  private var livePcmPlayer: IosLivePcmPlayer?
  private var iosTtsPool: IosTtsAudioPool?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configurePlaybackAudioSession()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    configurePlaybackAudioSession()
    livePcmPlayer?.resumeIfNeeded()
  }

  private func configurePlaybackAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // .allowBluetooth không hợp lệ với .playback (gây lỗi OSStatus -50 khiến cả session không active).
      // Dùng .playback + .mixWithOthers để tự phát qua loa/Bluetooth và hòa trộn ổn định với video.
      try session.setCategory(
        .playback,
        mode: .default,
        options: [.mixWithOthers]
      )
      try session.setActive(true)
    } catch {
      print("Failed to configure AVAudioSession: \(error)")
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KsubMediaPlugin") else {
      return
    }
    let mediaChannel = FlutterMethodChannel(name: "com.ksub.app/media",
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

      case "openPcmStream":
        guard let args = call.arguments as? [String: Any],
              let mediaPath = args["mediaPath"] as? String,
              let mediaUrl = self.makeMediaUrl(mediaPath) else {
          result(FlutterError(code: "INVALID_ARGS", message: "Invalid media path", details: nil))
          return
        }
        let rawHeaders = args["headers"] as? [String: Any] ?? [:]
        var headers: [String: String] = [:]
        for (k, v) in rawHeaders {
          if let str = v as? String, !str.isEmpty {
            headers[k] = str
          }
        }
        let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
        self.openPcmStream(url: mediaUrl, headers: headers, startMs: startMs, result: result)

      case "readPcmChunk":
        guard let args = call.arguments as? [String: Any],
              let streamId = args["streamId"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing streamId", details: nil))
          return
        }
        let durationMs = max(40, min(5000, (args["durationMs"] as? NSNumber)?.intValue ?? 250))
        self.readPcmChunk(streamId: streamId, durationMs: durationMs, result: result)

      case "seekPcmStream":
        guard let args = call.arguments as? [String: Any],
              let streamId = args["streamId"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing streamId", details: nil))
          return
        }
        let posMs = (args["positionMs"] as? NSNumber)?.int64Value ?? 0
        self.seekPcmStream(streamId: streamId, positionMs: posMs, result: result)

      case "closePcmStream":
        let args = call.arguments as? [String: Any]
        let streamId = (args?["streamId"] as? String) ?? ""
        self.closePcmStream(streamId: streamId, result: result)

      case "checkVideoDecoderSupport":
        let hevcSupported: Bool
        if #available(iOS 11.0, *) {
          hevcSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        } else {
          hevcSupported = false
        }
        result([
          "avc": VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
          "hevc": hevcSupported,
        ])

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let serviceChannel = FlutterMethodChannel(name: "com.ksub.app/foreground_service",
                                              binaryMessenger: registrar.messenger())
    serviceChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "start", "update":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        let title = args["title"] as? String ?? "Ksub"
        let message = args["message"] as? String ?? ""
        self.showOrUpdateNotification(title: title, body: message)
        result(nil)
      case "stop":
        self.clearNotifications()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let liveAudioChannel = FlutterMethodChannel(
      name: "com.ksub.app/live_audio",
      binaryMessenger: registrar.messenger()
    )
    let player = IosLivePcmPlayer(channel: liveAudioChannel)
    self.livePcmPlayer = player
    liveAudioChannel.setMethodCallHandler { [weak player] call, result in
      guard let player = player else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "start":
        let sampleRate = (args?["sampleRate"] as? NSNumber)?.intValue ?? 24000
        let volume = (args?["volume"] as? NSNumber)?.floatValue ?? 1.0
        let rate = (args?["rate"] as? NSNumber)?.floatValue ?? 1.0
        player.configure(sampleRate: sampleRate, volume: volume, rate: rate)
        result(true)

      case "enqueuePcm":
        guard let typed = args?["pcm"] as? FlutterStandardTypedData else {
          result(false)
          return
        }
        let sampleRate = (args?["sampleRate"] as? NSNumber)?.intValue ?? 24000
        player.enqueuePcm(data: typed.data, sampleRate: sampleRate)
        result(true)

      case "setVolume":
        let volume = (args?["volume"] as? NSNumber)?.floatValue ?? 1.0
        player.setVolume(volume)
        result(true)

      case "setPlaybackRate":
        let rate = (args?["rate"] as? NSNumber)?.floatValue ?? 1.0
        player.setPlaybackRate(rate)
        result(true)

      case "setPaused":
        let paused = (args?["paused"] as? NSNumber)?.boolValue ?? false
        player.setPaused(paused)
        result(true)

      case "interrupt":
        player.interrupt()
        result(true)

      case "dispose":
        player.dispose()
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let iosTtsChannel = FlutterMethodChannel(
      name: "com.ksub.app/ios_tts_player",
      binaryMessenger: registrar.messenger()
    )
    let ttsPool = IosTtsAudioPool(channel: iosTtsChannel)
    self.iosTtsPool = ttsPool
    iosTtsChannel.setMethodCallHandler { [weak ttsPool] call, result in
      guard let ttsPool = ttsPool else {
        result(nil)
        return
      }
      ttsPool.handleMethodCall(call, result: result)
    }
  }

  private func showOrUpdateNotification(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = nil
      let request = UNNotificationRequest(identifier: "KsubForegroundTask", content: content, trigger: nil)
      center.add(request, withCompletionHandler: nil)
    }
  }

  private func clearNotifications() {
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: ["KsubForegroundTask"])
    center.removePendingNotificationRequests(withIdentifiers: ["KsubForegroundTask"])
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
          throw NSError(domain: "KsubMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "Media has no valid duration"])
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
          throw NSError(domain: "KsubMedia", code: 2, userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy track âm thanh"])
        }

        let safeStart = max(0, startMs)
        let startTime = CMTime(value: safeStart, timescale: 1000)
        let remaining = CMTimeSubtract(assetDuration, startTime)
        guard CMTimeCompare(remaining, .zero) > 0 else {
          throw NSError(domain: "KsubMedia", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mốc bắt đầu nằm ngoài thời lượng media"])
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
          throw NSError(domain: "KsubMedia", code: 4, userInfo: [NSLocalizedDescriptionKey: "Không thể tạo audio composition"])
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
          throw NSError(domain: "KsubMedia", code: 5, userInfo: [NSLocalizedDescriptionKey: "Không thể tạo export session"])
        }
        guard exportSession.supportedFileTypes.contains(.m4a) else {
          throw NSError(domain: "KsubMedia", code: 6, userInfo: [NSLocalizedDescriptionKey: "Codec âm thanh không hỗ trợ xuất M4A"])
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
            domain: "KsubMedia",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Xuất audio thất bại"]
          )
        }
        let exportedMs = Int64((CMTimeGetSeconds(clipDuration) * 1000).rounded())
        let resultMap: [String: Any] = [
          "actualStartMs": safeStart,
          "durationMs": exportedMs
        ]
        self.finish(result, value: resultMap)
      } catch {
        try? FileManager.default.removeItem(at: outputUrl)
        self.finish(result, value: FlutterError(code: "EXPORT_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func openPcmStream(
    url: URL,
    headers: [String: String],
    startMs: Int64,
    result: @escaping FlutterResult
  ) {
    Task {
      do {
        let session = try await IosPcmStreamSession.open(url: url, headers: headers, startMs: startMs)
        let streamId = UUID().uuidString
        self.pcmQueue.sync {
          self.pcmSessions[streamId] = session
        }
        self.finish(result, value: [
          "streamId": streamId,
          "durationMs": session.durationMs
        ])
      } catch {
        self.finish(result, value: FlutterError(
          code: "PCM_OPEN_ERROR",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }

  private func readPcmChunk(
    streamId: String,
    durationMs: Int,
    result: @escaping FlutterResult
  ) {
    let session = self.pcmQueue.sync { self.pcmSessions[streamId] }
    guard let session = session else {
      self.finish(result, value: FlutterError(code: "PCM_NOT_FOUND", message: "PCM stream not found", details: nil))
      return
    }
    Task {
      do {
        let chunk = try await session.readChunk(requestedMs: durationMs)
        self.finish(result, value: [
          "pcm": FlutterStandardTypedData(bytes: chunk.data),
          "startMs": chunk.startMs,
          "endMs": chunk.endMs,
          "eof": chunk.eof
        ])
      } catch {
        self.finish(result, value: FlutterError(
          code: "PCM_READ_ERROR",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }

  private func seekPcmStream(
    streamId: String,
    positionMs: Int64,
    result: @escaping FlutterResult
  ) {
    let session = self.pcmQueue.sync { self.pcmSessions[streamId] }
    guard let session = session else {
      self.finish(result, value: positionMs)
      return
    }
    Task {
      let actual = await session.seek(toMs: positionMs)
      self.finish(result, value: actual)
    }
  }

  private func closePcmStream(streamId: String, result: @escaping FlutterResult) {
    let session = self.pcmQueue.sync { self.pcmSessions.removeValue(forKey: streamId) }
    session?.close()
    self.finish(result, value: true)
  }
}

private final class IosPcmStreamSession: @unchecked Sendable {
  private static let pcmSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 16000,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsNonInterleaved: false
  ]

  private let url: URL
  private let asset: AVURLAsset
  private let audioTrack: AVAssetTrack
  private let didAccessSecurityScope: Bool
  let durationMs: Int64

  private let lock = NSLock()
  private var closed = false
  private var fileReader: AVAssetReader?
  private var fileOutput: AVAssetReaderTrackOutput?
  private var cursorMs: Int64 = 0
  private var emittedSamples: Int64 = 0
  private var bufferData = Data()
  private var remoteNextFetchMs: Int64 = 0
  private var reachEof = false

  private init(
    url: URL,
    asset: AVURLAsset,
    audioTrack: AVAssetTrack,
    durationMs: Int64,
    startMs: Int64,
    didAccessSecurityScope: Bool
  ) {
    self.url = url
    self.asset = asset
    self.audioTrack = audioTrack
    self.durationMs = durationMs
    self.cursorMs = max(0, startMs)
    self.remoteNextFetchMs = max(0, startMs)
    self.didAccessSecurityScope = didAccessSecurityScope
  }

  static func open(url: URL, headers: [String: String], startMs: Int64) async throws -> IosPcmStreamSession {
    let didAccess = url.isFileURL && url.startAccessingSecurityScopedResource()
    do {
      let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
      let asset = AVURLAsset(url: url, options: options)
      let duration = try await asset.load(.duration)
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      guard let track = tracks.first else {
        throw NSError(domain: "KsubMedia", code: 2, userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy track âm thanh"])
      }
      let secs = CMTimeGetSeconds(duration)
      let durMs = secs.isFinite && secs > 0 ? Int64((secs * 1000).rounded()) : 0
      return IosPcmStreamSession(
        url: url,
        asset: asset,
        audioTrack: track,
        durationMs: durMs,
        startMs: startMs,
        didAccessSecurityScope: didAccess
      )
    } catch {
      if didAccess {
        url.stopAccessingSecurityScopedResource()
      }
      throw error
    }
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  func seek(toMs posMs: Int64) async -> Int64 {
    let safePos = max(0, posMs)
    return withLock {
      fileReader?.cancelReading()
      fileReader = nil
      fileOutput = nil
      bufferData.removeAll(keepingCapacity: false)
      cursorMs = safePos
      remoteNextFetchMs = safePos
      emittedSamples = 0
      reachEof = false
      return safePos
    }
  }

  func readChunk(requestedMs: Int) async throws -> (data: Data, startMs: Int64, endMs: Int64, eof: Bool) {
    let targetBytes = max(160, requestedMs * 16000 / 1000) * 2
    let startMs = snapshotStartMs()

    if url.isFileURL {
      try fillBufferFromLocalReader(targetBytes: targetBytes)
    } else {
      while currentBufferedBytes() < targetBytes && !isReachEof() && !isClosed() {
        try await fillBufferFromRemoteWindow(windowMs: 4000)
      }
    }

    return drainChunk(targetBytes: targetBytes, chunkStartMs: startMs)
  }

  private func isClosed() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  private func isReachEof() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return reachEof
  }

  private func currentBufferedBytes() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return bufferData.count
  }

  private func snapshotStartMs() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return cursorMs + (emittedSamples * 1000 / 16000)
  }

  private func drainChunk(targetBytes: Int, chunkStartMs: Int64) -> (data: Data, startMs: Int64, endMs: Int64, eof: Bool) {
    lock.lock()
    defer { lock.unlock() }
    let take = min(targetBytes, bufferData.count)
    let out: Data
    if take > 0 {
      out = bufferData.prefix(take)
      bufferData.removeFirst(take)
      emittedSamples += Int64(take / 2)
    } else {
      out = Data()
    }
    let chunkEndMs = cursorMs + (emittedSamples * 1000 / 16000)
    let eof = reachEof && bufferData.isEmpty
    return (out, chunkStartMs, chunkEndMs, eof)
  }

  private func fillBufferFromLocalReader(targetBytes: Int) throws {
    let setup: (reader: AVAssetReader, output: AVAssetReaderTrackOutput)? = try withLock {
      if closed || reachEof {
        return nil
      }
      if fileReader == nil {
        let reader = try AVAssetReader(asset: asset)
        let startTime = CMTime(value: cursorMs, timescale: 1000)
        reader.timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: Self.pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
          throw NSError(domain: "KsubMedia", code: 8, userInfo: [NSLocalizedDescriptionKey: "Không thể đọc track âm thanh"])
        }
        reader.add(output)
        guard reader.startReading() else {
          throw reader.error ?? NSError(domain: "KsubMedia", code: 9, userInfo: [NSLocalizedDescriptionKey: "AVAssetReader startReading thất bại"])
        }
        fileReader = reader
        fileOutput = output
      }
      return (fileReader!, fileOutput!)
    }

    guard let pair = setup else { return }

    while currentBufferedBytes() < targetBytes && !isClosed() {
      guard let sample = pair.output.copyNextSampleBuffer() else {
        try withLock {
          if pair.reader.status == .failed, let err = pair.reader.error {
            throw err
          }
          reachEof = true
        }
        break
      }
      if let pcm = Self.extractPcmData(from: sample), !pcm.isEmpty {
        withLock {
          bufferData.append(pcm)
        }
      }
    }
  }

  private func nextRemoteWindow(windowMs: Int64) -> (startMs: Int64, sliceMs: Int64)? {
    return withLock {
      if closed || reachEof {
        return nil
      }
      let winStart = remoteNextFetchMs
      if durationMs > 0 && winStart >= durationMs {
        reachEof = true
        return nil
      }
      let remaining = durationMs > 0 ? max(0, durationMs - winStart) : windowMs
      let sliceMs = min(windowMs, remaining > 0 ? remaining : windowMs)
      if sliceMs <= 0 {
        reachEof = true
        return nil
      }
      return (winStart, sliceMs)
    }
  }

  private func markRemoteEof() {
    withLock { reachEof = true }
  }

  private func appendRemoteWindow(winStart: Int64, sliceMs: Int64, data: Data) {
    withLock {
      if !closed && remoteNextFetchMs == winStart {
        bufferData.append(data)
        remoteNextFetchMs = winStart + sliceMs
        if (durationMs > 0 && remoteNextFetchMs >= durationMs) || data.isEmpty {
          reachEof = true
        }
      }
    }
  }

  private func fillBufferFromRemoteWindow(windowMs: Int64) async throws {
    guard let window = nextRemoteWindow(windowMs: windowMs) else { return }
    let winStart = window.startMs
    let sliceMs = window.sliceMs

    let composition = AVMutableComposition()
    guard let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw NSError(domain: "KsubMedia", code: 4, userInfo: [NSLocalizedDescriptionKey: "Không thể tạo audio composition"])
    }
    let timeRange = CMTimeRange(
      start: CMTime(value: winStart, timescale: 1000),
      duration: CMTime(value: sliceMs, timescale: 1000)
    )
    try compTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)

    let tmpUrl = FileManager.default.temporaryDirectory
      .appendingPathComponent("ksub_pcm_\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: tmpUrl) }

    guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
      throw NSError(domain: "KsubMedia", code: 5, userInfo: [NSLocalizedDescriptionKey: "Không thể tạo export session"])
    }
    exportSession.outputURL = tmpUrl
    exportSession.outputFileType = .m4a
    exportSession.shouldOptimizeForNetworkUse = false

    await withCheckedContinuation { continuation in
      exportSession.exportAsynchronously {
        continuation.resume()
      }
    }
    guard exportSession.status == .completed else {
      throw exportSession.error ?? NSError(domain: "KsubMedia", code: 7, userInfo: [NSLocalizedDescriptionKey: "Xuất đoạn PCM thất bại"])
    }

    let localAsset = AVURLAsset(url: tmpUrl)
    let localTracks = try await localAsset.loadTracks(withMediaType: .audio)
    guard let localTrack = localTracks.first else {
      markRemoteEof()
      return
    }
    let reader = try AVAssetReader(asset: localAsset)
    let output = AVAssetReaderTrackOutput(track: localTrack, outputSettings: Self.pcmSettings)
    guard reader.canAdd(output) else {
      throw NSError(domain: "KsubMedia", code: 8, userInfo: [NSLocalizedDescriptionKey: "Không đọc được M4A tạm"])
    }
    reader.add(output)
    reader.startReading()

    var collected = Data()
    while let sample = output.copyNextSampleBuffer() {
      if let pcm = Self.extractPcmData(from: sample) {
        collected.append(pcm)
      }
    }

    let expectedBytes = Int(max(0, sliceMs) * 16000 / 1000) * 2
    if expectedBytes > 0 && collected.count > expectedBytes {
      collected = Data(collected.prefix(expectedBytes))
    }

    appendRemoteWindow(winStart: winStart, sliceMs: sliceMs, data: collected)
  }

  private static func extractPcmData(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    guard length > 0 else { return nil }
    var data = Data(count: length)
    let status = data.withUnsafeMutableBytes { rawBuf -> OSStatus in
      guard let base = rawBuf.baseAddress else { return -1 }
      return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
    }
    return status == kCMBlockBufferNoErr ? data : nil
  }

  func close() {
    lock.lock()
    closed = true
    fileReader?.cancelReading()
    fileReader = nil
    fileOutput = nil
    bufferData.removeAll(keepingCapacity: false)
    lock.unlock()
    if didAccessSecurityScope {
      url.stopAccessingSecurityScopedResource()
    }
  }
}

private final class IosLivePcmPlayer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.ksub.app.live_audio")
  private let channel: FlutterMethodChannel
  private var engine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var timePitch: AVAudioUnitTimePitch?
  private var pcmFormat: AVAudioFormat?
  private var configObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var routeObserver: NSObjectProtocol?
  private var mediaResetObserver: NSObjectProtocol?

  private var currentSampleRate: Double = 24000
  private var volume: Float = 1.0
  private var playbackRate: Float = 1.0
  private var isPaused: Bool = false
  private var isActive: Bool = false
  private var disposed: Bool = false
  private var generation: Int = 0
  private var queuedBuffers: Int = 0
  private var reportedPlaying: Bool = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    registerSessionObservers()
  }

  deinit {
    unregisterSessionObservers()
  }

  func configure(sampleRate: Int, volume: Float, rate: Float) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else { return }
      self.isActive = true
      self.isPaused = false
      self.volume = max(0.0, min(1.0, volume))
      self.playbackRate = max(0.5, min(2.5, rate))
      let safeRate = Double(max(8000, min(48000, sampleRate)))
      if let (eng, _, pitch, _) = self.setupEngineIfNeeded(sampleRate: safeRate) {
        eng.mainMixerNode.outputVolume = self.volume
        self.applyRateLocked(pitch)
        _ = self.ensureEngineRunningLocked()
      }
      self.updatePlayingStateLocked()
    }
  }

  func resumeIfNeeded() {
    queue.async { [weak self] in
      guard let self = self, !self.disposed, self.isActive else { return }
      self.configureSessionLocked()
      if !self.isPaused && self.ensureEngineRunningLocked() && self.queuedBuffers > 0 {
        if let node = self.playerNode, !node.isPlaying {
          node.play()
        }
      }
    }
  }

  func enqueuePcm(data: Data, sampleRate: Int) {
    guard !data.isEmpty else { return }
    queue.async { [weak self] in
      guard let self = self, !self.disposed else { return }
      self.isActive = true
      let safeRate = Double(max(8000, min(48000, sampleRate)))
      guard var graph = self.setupEngineIfNeeded(sampleRate: safeRate) else {
        return
      }

      if !self.ensureEngineRunningLocked() {
        // Thử dựng lại engine 1 lần nếu vừa gặp xung đột audio session/route từ video player.
        self.teardownEngineLocked()
        self.queuedBuffers = 0
        guard let rebuilt = self.setupEngineIfNeeded(sampleRate: safeRate),
              self.ensureEngineRunningLocked() else {
          return
        }
        graph = rebuilt
      }

      let eng = graph.0
      let node = graph.1
      let format = graph.3

      let sampleCount = data.count / 2
      guard sampleCount > 0,
            let pcmBuffer = AVAudioPCMBuffer(
              pcmFormat: format,
              frameCapacity: AVAudioFrameCount(sampleCount)
            ) else {
        return
      }
      pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

      guard let floatChannel = pcmBuffer.floatChannelData?[0] else { return }
      data.withUnsafeBytes { rawBuf in
        guard let bytes = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
        for i in 0..<sampleCount {
          let lo = Int16(bytes[i * 2])
          let hi = Int16(Int8(bitPattern: bytes[i * 2 + 1]))
          let sample = (hi << 8) | lo
          floatChannel[i] = Float(sample) / 32768.0
        }
      }

      let gen = self.generation
      self.queuedBuffers += 1
      self.updatePlayingStateLocked()

      node.scheduleBuffer(pcmBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
        self?.queue.async {
          guard let self = self, self.generation == gen else { return }
          if self.queuedBuffers > 0 {
            self.queuedBuffers -= 1
          }
          self.updatePlayingStateLocked()
        }
      }

      if eng.isRunning && !self.isPaused && !node.isPlaying {
        node.play()
      }
    }
  }

  func setVolume(_ volume: Float) {
    let clamped = max(0.0, min(1.0, volume))
    queue.async { [weak self] in
      guard let self = self, !self.disposed else { return }
      self.volume = clamped
      self.engine?.mainMixerNode.outputVolume = clamped
    }
  }

  func setPlaybackRate(_ rate: Float) {
    let clamped = max(0.5, min(2.5, rate))
    queue.async { [weak self] in
      guard let self = self, !self.disposed else { return }
      self.playbackRate = clamped
      if let pitch = self.timePitch {
        self.applyRateLocked(pitch)
      }
    }
  }

  func setPaused(_ paused: Bool) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else { return }
      self.isPaused = paused
      if paused {
        self.playerNode?.pause()
      } else if self.isActive {
        if self.ensureEngineRunningLocked(),
           self.queuedBuffers > 0,
           let node = self.playerNode,
           !node.isPlaying {
          node.play()
        }
      }
      self.updatePlayingStateLocked()
    }
  }

  func interrupt() {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else { return }
      self.generation &+= 1
      self.isPaused = false
      self.queuedBuffers = 0
      self.playerNode?.stop()
      self.timePitch?.reset()
      self.updatePlayingStateLocked()
    }
  }

  func dispose() {
    unregisterSessionObservers()
    queue.async { [weak self] in
      guard let self = self, !self.disposed else { return }
      self.disposed = true
      self.isActive = false
      self.isPaused = false
      self.generation &+= 1
      self.queuedBuffers = 0
      self.teardownEngineLocked()
      self.updatePlayingStateLocked()
    }
  }

  private func setupEngineIfNeeded(
    sampleRate: Double
  ) -> (AVAudioEngine, AVAudioPlayerNode, AVAudioUnitTimePitch, AVAudioFormat)? {
    if let eng = engine,
       let node = playerNode,
       let pitch = timePitch,
       let format = pcmFormat,
       abs(currentSampleRate - sampleRate) < 1.0 {
      return (eng, node, pitch, format)
    }

    teardownEngineLocked()
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    ) else {
      return nil
    }

    let eng = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let pitch = AVAudioUnitTimePitch()
    pitch.overlap = 8.0
    pitch.pitch = 0.0
    applyRateLocked(pitch)

    // Attach và kết nối node trước khi chỉnh mainMixerNode.outputVolume
    // để tránh khóa nhầm cấu trúc mixer mặc định trên iOS.
    eng.attach(node)
    eng.attach(pitch)
    eng.connect(node, to: pitch, format: format)
    eng.connect(pitch, to: eng.mainMixerNode, format: format)
    eng.mainMixerNode.outputVolume = volume

    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: eng,
      queue: nil
    ) { [weak self] _ in
      self?.queue.async {
        guard let self = self, !self.disposed else { return }
        self.configureSessionLocked()
        if !self.isActive || self.isPaused {
          return
        }
        if self.ensureEngineRunningLocked() {
          if let n = self.playerNode, self.queuedBuffers > 0, !n.isPlaying {
            n.play()
          }
        } else {
          self.teardownEngineLocked()
          self.queuedBuffers = 0
          self.updatePlayingStateLocked()
        }
      }
    }

    self.engine = eng
    self.playerNode = node
    self.timePitch = pitch
    self.pcmFormat = format
    self.currentSampleRate = sampleRate
    return (eng, node, pitch, format)
  }

  private func registerSessionObservers() {
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()

    interruptionObserver = center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: session,
      queue: nil
    ) { [weak self] notification in
      let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
      self?.queue.async {
        guard let self = self, !self.disposed else { return }
        guard let rawType = rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
          return
        }
        switch type {
        case .began:
          self.playerNode?.pause()
        case .ended:
          let shouldResume = rawOptions.map {
            AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
          } ?? true
          guard self.isActive, !self.isPaused, shouldResume else { return }
          self.configureSessionLocked()
          if self.ensureEngineRunningLocked(),
             self.queuedBuffers > 0,
             let n = self.playerNode,
             !n.isPlaying {
            n.play()
          }
        @unknown default:
          break
        }
      }
    }

    routeObserver = center.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: session,
      queue: nil
    ) { [weak self] _ in
      self?.queue.async {
        guard let self = self, !self.disposed, self.isActive, !self.isPaused else { return }
        self.configureSessionLocked()
        if self.ensureEngineRunningLocked(),
           self.queuedBuffers > 0,
           let n = self.playerNode,
           !n.isPlaying {
          n.play()
        }
      }
    }

    mediaResetObserver = center.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: session,
      queue: nil
    ) { [weak self] _ in
      self?.queue.async {
        guard let self = self, !self.disposed else { return }
        self.generation &+= 1
        self.queuedBuffers = 0
        self.teardownEngineLocked()
        self.updatePlayingStateLocked()
      }
    }
  }

  private func unregisterSessionObservers() {
    let center = NotificationCenter.default
    if let observer = interruptionObserver {
      center.removeObserver(observer)
      interruptionObserver = nil
    }
    if let observer = routeObserver {
      center.removeObserver(observer)
      routeObserver = nil
    }
    if let observer = mediaResetObserver {
      center.removeObserver(observer)
      mediaResetObserver = nil
    }
  }

  private func teardownEngineLocked() {
    if let observer = configObserver {
      NotificationCenter.default.removeObserver(observer)
      configObserver = nil
    }
    playerNode?.stop()
    engine?.stop()
    engine = nil
    playerNode = nil
    timePitch = nil
    pcmFormat = nil
  }

  private func applyRateLocked(_ pitch: AVAudioUnitTimePitch) {
    if abs(playbackRate - 1.0) < 0.01 {
      pitch.rate = 1.0
      pitch.bypass = true
    } else {
      pitch.bypass = false
      pitch.rate = playbackRate
    }
  }

  private func configureSessionLocked() {
    let session = AVAudioSession.sharedInstance()
    do {
      if session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) {
        try session.setCategory(
          .playback,
          mode: .default,
          options: [.mixWithOthers]
        )
      }
      try session.setActive(true)
    } catch {
      print("[IosLivePcmPlayer] AVAudioSession configure error: \(error)")
    }
  }

  @discardableResult
  private func ensureEngineRunningLocked() -> Bool {
    guard let eng = engine else { return false }
    configureSessionLocked()
    if !eng.isRunning {
      do {
        eng.prepare()
        try eng.start()
      } catch {
        print("[IosLivePcmPlayer] engine.start error: \(error)")
        return false
      }
    }
    return eng.isRunning
  }

  private func updatePlayingStateLocked() {
    let nowPlaying = !disposed && isActive && !isPaused && queuedBuffers > 0
    if nowPlaying != reportedPlaying {
      reportedPlaying = nowPlaying
      DispatchQueue.main.async { [weak self] in
        guard let self = self, !self.disposed else { return }
        self.channel.invokeMethod("onPlaybackStateChanged", arguments: nowPlaying)
      }
    }
  }
}

private final class IosTtsAudioPool {
  private let channel: FlutterMethodChannel
  private let lock = NSLock()
  private var players: [Int: IosTtsAudioPlayer] = [:]

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    guard let playerId = (args?["playerId"] as? NSNumber)?.intValue else {
      result(FlutterError(code: "INVALID_ARGS", message: "Missing playerId", details: nil))
      return
    }

    switch call.method {
    case "setFilePath":
      guard let path = args?["path"] as? String, !path.isEmpty else {
        result(nil)
        return
      }
      let player = getOrCreatePlayer(playerId)
      player.setFilePath(path, completion: result)

    case "play":
      getPlayer(playerId)?.play(completion: result) ?? result(false)

    case "pause":
      getPlayer(playerId)?.pause(completion: result) ?? result(false)

    case "stop":
      getPlayer(playerId)?.stop(completion: result) ?? result(true)

    case "seek":
      let posMs = (args?["positionMs"] as? NSNumber)?.intValue ?? 0
      getPlayer(playerId)?.seek(positionMs: posMs, completion: result) ?? result(false)

    case "setSpeed":
      let speed = (args?["speed"] as? NSNumber)?.doubleValue ?? 1.0
      getPlayer(playerId)?.setSpeed(speed, completion: result) ?? result(false)

    case "setVolume":
      let volume = (args?["volume"] as? NSNumber)?.doubleValue ?? 1.0
      getPlayer(playerId)?.setVolume(volume, completion: result) ?? result(false)

    case "setVoiceTone":
      let pitch = (args?["pitch"] as? NSNumber)?.doubleValue ?? 1.0
      let eqEnabled = (args?["eqEnabled"] as? NSNumber)?.boolValue ?? false
      let bandGains = (args?["bandGainsDb"] as? [NSNumber])?.map { $0.doubleValue } ?? [0, 0, 0, 0, 0]
      getOrCreatePlayer(playerId).setVoiceTone(
        pitch: pitch,
        bandGainsDb: bandGains,
        eqEnabled: eqEnabled,
        completion: result
      )

    case "getPositionMs":
      getPlayer(playerId)?.getPositionMs(completion: result) ?? result(0)

    case "dispose":
      if let removed = removePlayer(playerId) {
        removed.dispose()
      }
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func getPlayer(_ id: Int) -> IosTtsAudioPlayer? {
    lock.lock()
    defer { lock.unlock() }
    return players[id]
  }

  private func getOrCreatePlayer(_ id: Int) -> IosTtsAudioPlayer {
    lock.lock()
    defer { lock.unlock() }
    if let existing = players[id] {
      return existing
    }
    let created = IosTtsAudioPlayer(playerId: id) { [weak self] completedId in
      DispatchQueue.main.async {
        self?.channel.invokeMethod("onCompleted", arguments: ["playerId": completedId])
      }
    }
    players[id] = created
    return created
  }

  private func removePlayer(_ id: Int) -> IosTtsAudioPlayer? {
    lock.lock()
    defer { lock.unlock() }
    return players.removeValue(forKey: id)
  }
}

private final class IosTtsAudioPlayer {
  private static let eqFrequencies: [Float] = [60.0, 230.0, 910.0, 3600.0, 14000.0]

  private let playerId: Int
  private let onCompleted: (Int) -> Void
  private let queue = DispatchQueue(label: "com.ksub.app.ios_tts")

  private var engine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var timePitch: AVAudioUnitTimePitch?
  private var equalizer: AVAudioUnitEQ?
  private var engineFormat: AVAudioFormat?
  private var configObserver: NSObjectProtocol?

  private var audioFile: AVAudioFile?
  private var totalFrames: AVAudioFramePosition = 0
  private var seekFrame: AVAudioFramePosition = 0
  private var hasScheduledSegment = false
  private var scheduleToken: UInt64 = 0

  private var isPlaying = false
  private var isPaused = false
  private var isCompleted = false
  private var pausedFrame: AVAudioFramePosition?
  private var disposed = false

  private var playbackRate: Float = 1.0
  private var pitchFactor: Float = 1.0
  private var volume: Float = 1.0
  private var eqEnabled = false
  private var bandGainsDb: [Float] = [0, 0, 0, 0, 0]

  init(playerId: Int, onCompleted: @escaping (Int) -> Void) {
    self.playerId = playerId
    self.onCompleted = onCompleted
  }

  func setFilePath(_ path: String, completion: @escaping (Int?) -> Void) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      do {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = file.length
        guard format.sampleRate > 0, frames > 0 else {
          DispatchQueue.main.async { completion(nil) }
          return
        }

        self.scheduleToken &+= 1
        self.playerNode?.stop()
        self.hasScheduledSegment = false
        self.isPlaying = false
        self.isPaused = false
        self.isCompleted = false
        self.pausedFrame = nil
        self.seekFrame = 0
        self.audioFile = file
        self.totalFrames = frames

        _ = self.setupEngineIfNeeded(format: format)
        let durationMs = Int((Double(frames) / format.sampleRate) * 1000.0)
        DispatchQueue.main.async { completion(durationMs) }
      } catch {
        print("[IosTtsAudioPlayer] setFilePath error: \(error)")
        DispatchQueue.main.async { completion(nil) }
      }
    }
  }

  func play(completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed, let file = self.audioFile else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      guard self.setupEngineIfNeeded(format: file.processingFormat),
            self.ensureEngineRunningLocked(),
            let node = self.playerNode else {
        DispatchQueue.main.async { completion(false) }
        return
      }

      if self.isCompleted {
        self.seekFrame = 0
        self.isCompleted = false
        self.hasScheduledSegment = false
      }

      if !self.hasScheduledSegment {
        self.scheduleFromCurrentFrameLocked()
      }

      self.applyEffectsLocked()
      node.volume = self.volume
      node.play()
      self.isPlaying = true
      self.isPaused = false
      self.pausedFrame = nil
      DispatchQueue.main.async { completion(true) }
    }
  }

  func pause(completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      if self.isPlaying {
        self.pausedFrame = self.currentFrameLocked()
        self.playerNode?.pause()
      }
      self.isPlaying = false
      self.isPaused = true
      DispatchQueue.main.async { completion(true) }
    }
  }

  func stop(completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else {
        DispatchQueue.main.async { completion(true) }
        return
      }
      self.scheduleToken &+= 1
      self.playerNode?.stop()
      self.hasScheduledSegment = false
      self.seekFrame = 0
      self.pausedFrame = nil
      self.isPlaying = false
      self.isPaused = false
      self.isCompleted = false
      DispatchQueue.main.async { completion(true) }
    }
  }

  func seek(positionMs: Int, completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed, let file = self.audioFile else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      let sampleRate = file.processingFormat.sampleRate
      let targetFrame = AVAudioFramePosition((Double(max(0, positionMs)) / 1000.0) * sampleRate)
      self.seekFrame = min(max(0, targetFrame), max(0, self.totalFrames - 1))
      self.pausedFrame = self.isPaused ? self.seekFrame : nil
      self.isCompleted = false

      let wasPlaying = self.isPlaying
      self.scheduleToken &+= 1
      self.playerNode?.stop()
      self.hasScheduledSegment = false
      self.scheduleFromCurrentFrameLocked()

      if wasPlaying, self.ensureEngineRunningLocked() {
        self.playerNode?.play()
        self.isPlaying = true
        self.isPaused = false
      }
      DispatchQueue.main.async { completion(true) }
    }
  }

  func setSpeed(_ speed: Double, completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      self.playbackRate = Float(max(0.25, min(4.5, speed)))
      self.applyEffectsLocked()
      DispatchQueue.main.async { completion(true) }
    }
  }

  func setVolume(_ volume: Double, completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      self.volume = Float(max(0.0, min(1.0, volume)))
      self.playerNode?.volume = self.volume
      DispatchQueue.main.async { completion(true) }
    }
  }

  func setVoiceTone(
    pitch: Double,
    bandGainsDb: [Double],
    eqEnabled: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      self.pitchFactor = Float(max(0.5, min(2.0, pitch)))
      self.eqEnabled = eqEnabled
      var nextGains: [Float] = []
      for i in 0..<Self.eqFrequencies.count {
        let g = i < bandGainsDb.count ? bandGainsDb[i] : 0.0
        nextGains.append(Float(max(-15.0, min(15.0, g))))
      }
      self.bandGainsDb = nextGains
      self.applyEffectsLocked()
      DispatchQueue.main.async { completion(true) }
    }
  }

  func getPositionMs(completion: @escaping (Int) -> Void) {
    queue.async { [weak self] in
      guard let self = self, !self.disposed, let file = self.audioFile else {
        DispatchQueue.main.async { completion(0) }
        return
      }
      let ms = self.currentPositionMsLocked(sampleRate: file.processingFormat.sampleRate)
      DispatchQueue.main.async { completion(ms) }
    }
  }

  func dispose() {
    queue.async { [weak self] in
      guard let self = self, !self.disposed else { return }
      self.disposed = true
      self.scheduleToken &+= 1
      self.teardownEngineLocked()
      self.audioFile = nil
    }
  }

  private func currentFrameLocked() -> AVAudioFramePosition {
    if isCompleted {
      return totalFrames
    }
    if isPaused, let pf = pausedFrame {
      return pf
    }
    var currentFrame = seekFrame
    if let node = playerNode,
       hasScheduledSegment,
       let renderTime = node.lastRenderTime,
       let playerTime = node.playerTime(forNodeTime: renderTime) {
      currentFrame = min(totalFrames, seekFrame + max(0, playerTime.sampleTime))
    }
    return currentFrame
  }

  private func currentPositionMsLocked(sampleRate: Double) -> Int {
    guard sampleRate > 0 else { return 0 }
    return Int((Double(currentFrameLocked()) / sampleRate) * 1000.0)
  }

  private func scheduleFromCurrentFrameLocked() {
    guard let file = audioFile, let node = playerNode else { return }
    guard seekFrame < totalFrames else {
      hasScheduledSegment = false
      isCompleted = true
      isPlaying = false
      return
    }

    let remaining = AVAudioFrameCount(totalFrames - seekFrame)
    let token = scheduleToken &+ 1
    scheduleToken = token
    hasScheduledSegment = true
    isCompleted = false

    node.scheduleSegment(
      file,
      startingFrame: seekFrame,
      frameCount: remaining,
      at: nil,
      completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      self?.queue.async { [weak self] in
        guard let self = self, !self.disposed, self.scheduleToken == token else { return }
        self.isPlaying = false
        self.isPaused = false
        self.isCompleted = true
        self.hasScheduledSegment = false
        self.seekFrame = self.totalFrames
        self.onCompleted(self.playerId)
      }
    }
  }

  @discardableResult
  private func setupEngineIfNeeded(format: AVAudioFormat) -> Bool {
    if let existingFormat = engineFormat,
       engine != nil,
       playerNode != nil,
       timePitch != nil,
       equalizer != nil,
       abs(existingFormat.sampleRate - format.sampleRate) < 1.0,
       existingFormat.channelCount == format.channelCount {
      return true
    }

    teardownEngineLocked()

    let eng = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let tp = AVAudioUnitTimePitch()
    tp.overlap = 8.0

    let eq = AVAudioUnitEQ(numberOfBands: Self.eqFrequencies.count)
    for (idx, freq) in Self.eqFrequencies.enumerated() {
      let band = eq.bands[idx]
      band.filterType = .parametric
      band.frequency = freq
      band.bandwidth = 1.0
      band.gain = idx < bandGainsDb.count ? bandGainsDb[idx] : 0.0
      band.bypass = false
    }

    eng.attach(node)
    eng.attach(tp)
    eng.attach(eq)
    eng.connect(node, to: tp, format: format)
    eng.connect(tp, to: eq, format: format)
    eng.connect(eq, to: eng.mainMixerNode, format: format)

    node.volume = volume

    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: eng,
      queue: nil
    ) { [weak self] _ in
      self?.queue.async {
        guard let self = self, !self.disposed else { return }
        if self.isPlaying, self.ensureEngineRunningLocked() {
          self.playerNode?.play()
        }
      }
    }

    self.engine = eng
    self.playerNode = node
    self.timePitch = tp
    self.equalizer = eq
    self.engineFormat = format
    self.applyEffectsLocked()
    return true
  }

  private func applyEffectsLocked() {
    if let tp = timePitch {
      let needsRate = abs(playbackRate - 1.0) >= 0.005
      let needsPitch = abs(pitchFactor - 1.0) >= 0.005
      if !needsRate && !needsPitch {
        tp.rate = 1.0
        tp.pitch = 0.0
        tp.bypass = true
      } else {
        tp.bypass = false
        tp.rate = playbackRate
        tp.pitch = Float(1200.0 * log2(Double(pitchFactor)))
      }
    }
    if let eq = equalizer {
      eq.bypass = !eqEnabled
      for idx in 0..<min(eq.bands.count, bandGainsDb.count) {
        eq.bands[idx].gain = bandGainsDb[idx]
      }
    }
  }

  @discardableResult
  private func ensureEngineRunningLocked() -> Bool {
    guard let eng = engine else { return false }
    let session = AVAudioSession.sharedInstance()
    do {
      if session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) {
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      }
      try session.setActive(true)
    } catch {
      print("[IosTtsAudioPlayer] AVAudioSession error: \(error)")
    }

    if !eng.isRunning {
      do {
        eng.prepare()
        try eng.start()
      } catch {
        print("[IosTtsAudioPlayer] engine.start error: \(error)")
        return false
      }
    }
    return eng.isRunning
  }

  private func teardownEngineLocked() {
    if let observer = configObserver {
      NotificationCenter.default.removeObserver(observer)
      configObserver = nil
    }
    playerNode?.stop()
    engine?.stop()
    engine = nil
    playerNode = nil
    timePitch = nil
    equalizer = nil
    engineFormat = nil
    hasScheduledSegment = false
  }
}
