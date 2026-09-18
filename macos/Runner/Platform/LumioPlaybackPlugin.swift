import AVFoundation
import Cocoa
import FlutterMacOS
import MediaPlayer

final class LumioPlaybackPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let bookmarkStore: SecurityScopedBookmarkStore
  private weak var window: NSWindow?
  private let player = AVPlayer()
  private let texture: LumioVideoTexture
  private var activeAccessRoot: URL?
  private var endObserver: NSObjectProtocol?
  private var itemStatusObservation: NSKeyValueObservation?
  private var playbackObservation: NSKeyValueObservation?
  private var preferredRate: Float = 1
  private var currentMetadata: [String: Any] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    // Registered by LumioMacOSPlugins so playback can reuse media authorization.
  }

  init(
    registrar: FlutterPluginRegistrar,
    bookmarkStore: SecurityScopedBookmarkStore,
    window: NSWindow
  ) {
    self.bookmarkStore = bookmarkStore
    self.window = window
    channel = FlutterMethodChannel(
      name: "lumio/playback",
      binaryMessenger: registrar.messenger
    )
    texture = LumioVideoTexture(registry: registrar.textures)
    super.init()
    registrar.addMethodCallDelegate(self, channel: channel)
    configureRemoteCommands()
    playbackObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] player, _ in
      guard let self else { return }
      self.updateNowPlayingPosition()
      self.channel.invokeMethod(
        "nativePlaybackStateChanged",
        arguments: ["isPlaying": player.timeControlStatus == .playing]
      )
    }
  }

  deinit {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    playbackObservation?.invalidate()
    itemStatusObservation?.invalidate()
    activeAccessRoot?.stopAccessingSecurityScopedResource()
    texture.dispose()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "play":
      play(arguments: call.arguments, result: result)
    case "pause":
      player.pause()
      updateNowPlayingPosition()
      result(nil)
    case "resume":
      // 重启后只恢复了 Dart 歌曲信息；返回错误让现有回退流程重新加载文件。
      guard let item = player.currentItem, item.status != .failed else {
        result(FlutterError(
          code: "resumeRequiresLoad",
          message: "当前媒体尚未加载，需要重新开始播放。",
          details: nil
        ))
        return
      }
      player.playImmediately(atRate: preferredRate)
      updateNowPlayingPosition()
      result(nil)
    case "seek":
      guard let arguments = call.arguments as? [String: Any] else {
        result(invalidArguments("缺少播放位置。"))
        return
      }
      let time = CMTime(
        milliseconds: int64(arguments["positionMs"]),
        preferredTimescale: 600
      )
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
        [weak self] _ in
        self?.texture.notifyFrameAvailable()
        self?.updateNowPlayingPosition()
      }
      result(nil)
    case "setSpeed":
      let arguments = call.arguments as? [String: Any]
      preferredRate = Float(double(arguments?["speed"], fallback: 1)).clamped(to: 0.5...2)
      if player.timeControlStatus == .playing {
        player.rate = preferredRate
      }
      result(nil)
    case "setVolumeScale":
      let arguments = call.arguments as? [String: Any]
      player.volume = Float(double(arguments?["scale"], fallback: 1)).clamped(to: 0...1)
      result(nil)
    case "setEqualizerPreset", "setCrossfadeDuration", "setShuffleEnabled", "setRepeatMode":
      result(nil)
    case "stop":
      stopPlayback()
      result(nil)
    case "position":
      result(currentPositionMs())
    case "enterPictureInPicture":
      result(unsupported("macOS 首版暂不支持视频画中画。"))
    case "adjustBrightness":
      result(unsupported("macOS 不修改系统屏幕亮度。"))
    case "adjustVolume":
      let arguments = call.arguments as? [String: Any]
      let delta = Float(double(arguments?["delta"], fallback: 0))
      player.volume = (player.volume + delta).clamped(to: 0...1)
      result(nil)
    case "share":
      share(arguments: call.arguments, result: result)
    case "shareMany":
      share(arguments: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func play(arguments: Any?, result: @escaping FlutterResult) {
    guard let values = arguments as? [String: Any],
          let path = values["path"] as? String,
          !path.isEmpty else {
      result(invalidArguments("播放路径无效。"))
      return
    }
    activeAccessRoot?.stopAccessingSecurityScopedResource()
    activeAccessRoot = bookmarkStore.startAccess(forFilePath: path)

    let item = AVPlayerItem(url: URL(fileURLWithPath: path))
    observe(item: item)
    let kind = values["kind"] as? String ?? "audio"
    if kind == "video" {
      texture.attach(to: item)
    } else {
      texture.detach()
    }
    player.replaceCurrentItem(with: item)
    currentMetadata = values
    let positionMs = int64(values["positionMs"])
    if positionMs > 0 {
      player.seek(
        to: CMTime(milliseconds: positionMs, preferredTimescale: 600),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
    }
    player.playImmediately(atRate: preferredRate)
    updateNowPlayingInfo()
    result(kind == "video" ? ["textureId": texture.textureID] : [:])
  }

  private func observe(item: AVPlayerItem) {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    itemStatusObservation?.invalidate()
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      self?.channel.invokeMethod(
        "completed",
        arguments: ["mediaId": self?.currentMetadata["mediaId"] as? String]
      )
    }
    itemStatusObservation = item.observe(\.status, options: [.new]) {
      [weak self] item, _ in
      guard item.status == .failed else { return }
      self?.channel.invokeMethod(
        "error",
        arguments: ["message": item.error?.localizedDescription ?? "媒体播放失败。"]
      )
    }
  }

  private func stopPlayback() {
    player.pause()
    player.replaceCurrentItem(with: nil)
    texture.detach()
    activeAccessRoot?.stopAccessingSecurityScopedResource()
    activeAccessRoot = nil
    currentMetadata = [:]
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private func configureRemoteCommands() {
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.isEnabled = true
    commands.pauseCommand.isEnabled = true
    commands.togglePlayPauseCommand.isEnabled = true
    commands.nextTrackCommand.isEnabled = true
    commands.previousTrackCommand.isEnabled = true
    commands.changePlaybackPositionCommand.isEnabled = true

    commands.playCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("play", arguments: nil)
      return .success
    }
    commands.pauseCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("pause", arguments: nil)
      return .success
    }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("toggle", arguments: nil)
      return .success
    }
    commands.nextTrackCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("next", arguments: nil)
      return .success
    }
    commands.previousTrackCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("previous", arguments: nil)
      return .success
    }
    commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self,
            let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      let time = CMTime(seconds: positionEvent.positionTime, preferredTimescale: 600)
      self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
      self.channel.invokeMethod(
        "nativePlaybackPositionChanged",
        arguments: ["positionMs": Int64(positionEvent.positionTime * 1000)]
      )
      return .success
    }
  }

  private func updateNowPlayingInfo() {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: currentMetadata["title"] as? String ?? "",
      MPMediaItemPropertyArtist: currentMetadata["artist"] as? String ?? "",
      MPMediaItemPropertyAlbumTitle: currentMetadata["album"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration:
        Double(int64(currentMetadata["durationMs"])) / 1000,
    ]
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentPositionMs()) / 1000
    info[MPNowPlayingInfoPropertyPlaybackRate] = player.timeControlStatus == .playing
      ? Double(preferredRate)
      : 0
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func updateNowPlayingPosition() {
    guard !currentMetadata.isEmpty else { return }
    updateNowPlayingInfo()
  }

  private func share(arguments: Any?, result: @escaping FlutterResult) {
    let values = arguments as? [String: Any]
    var paths: [String] = []
    if let path = values?["path"] as? String {
      paths = [path]
    } else if let items = values?["items"] as? [[String: Any]] {
      paths = items.compactMap { $0["path"] as? String }
    }
    let urls = paths.map { URL(fileURLWithPath: $0) }
    guard !urls.isEmpty,
          let view = window?.contentView else {
      result(invalidArguments("没有可分享的媒体文件。"))
      return
    }
    let picker = NSSharingServicePicker(items: urls)
    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    result(nil)
  }

  private func currentPositionMs() -> Int64 {
    let seconds = CMTimeGetSeconds(player.currentTime())
    return seconds.isFinite && seconds > 0 ? Int64(seconds * 1000) : 0
  }

  private func int64(_ value: Any?) -> Int64 {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    return 0
  }

  private func double(_ value: Any?, fallback: Double) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    return fallback
  }

  private func invalidArguments(_ message: String) -> FlutterError {
    FlutterError(code: "invalidArguments", message: message, details: nil)
  }

  private func unsupported(_ message: String) -> FlutterError {
    FlutterError(code: "unsupported", message: message, details: nil)
  }
}

private extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

private extension CMTime {
  init(milliseconds: Int64, preferredTimescale: CMTimeScale) {
    self.init(
      value: milliseconds * Int64(preferredTimescale),
      timescale: preferredTimescale * 1000
    )
  }
}
