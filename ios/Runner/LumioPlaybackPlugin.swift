import AVFoundation
import Flutter
import UIKit

/// iOS 播放：AVPlayer 负责音频与视频解码，视频帧经 FlutterTexture 交给 Flutter 渲染。
///
/// 首版覆盖播放/暂停/跳转/倍速/音量与结束、状态、画面尺寸、错误事件；
/// 均衡器、淡入淡出、系统媒体控制与画中画在 iOS 上尚未接入，
/// Dart 侧已通过平台能力模型隐藏对应入口，这里对相关方法返回空实现。
final class LumioPlaybackPlugin: NSObject, FlutterPlugin, FlutterTexture {
  private let channel: FlutterMethodChannel
  private let textures: FlutterTextureRegistry
  private let player = AVPlayer()
  private var textureId: Int64 = -1
  private var videoOutput: AVPlayerItemVideoOutput?
  private var displayLink: CADisplayLink?
  private var currentMetadata: [String: Any] = [:]
  private var endObserver: NSObjectProtocol?
  private var statusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var latestPixelBuffer: CVPixelBuffer?
  private var preferredRate: Float = 1
  private var lastReportedSize: CGSize = .zero

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LumioPlaybackPlugin(
      messenger: registrar.messenger(),
      textures: registrar.textures()
    )
    registrar.addMethodCallDelegate(instance, channel: instance.channel)
  }

  init(messenger: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {
    self.textures = textures
    channel = FlutterMethodChannel(name: "lumio/playback", binaryMessenger: messenger)
    super.init()
    configureAudioSession()
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      guard let self else { return }
      let playing = player.timeControlStatus == .playing
      self.channel.invokeMethod("nativePlaybackStateChanged", arguments: ["isPlaying": playing])
      playing ? self.startDisplayLink() : self.stopDisplayLink()
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
  }

  deinit {
    stopDisplayLink()
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    statusObservation?.invalidate()
    timeControlObservation?.invalidate()
    NotificationCenter.default.removeObserver(self)
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "play":
      guard let values = call.arguments as? [String: Any],
            let path = values["path"] as? String else {
        result(FlutterError(code: "invalidArguments", message: "缺少媒体路径。", details: nil))
        return
      }
      startPlayback(path: path, values: values, result: result)
    case "pause":
      player.pause()
      result(nil)
    case "resume":
      player.rate = preferredRate
      result(nil)
    case "stop":
      player.pause()
      player.replaceCurrentItem(with: nil)
      currentMetadata = [:]
      stopDisplayLink()
      releaseVideoOutput()
      result(nil)
    case "seek":
      let positionMs = (call.arguments as? [String: Any])?["positionMs"] as? NSNumber
      let target = CMTime(
        seconds: max(0, (positionMs?.doubleValue ?? 0) / 1000),
        preferredTimescale: 600
      )
      player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
      result(nil)
    case "position":
      let seconds = CMTimeGetSeconds(player.currentTime())
      result(seconds.isFinite ? Int(seconds * 1000) : 0)
    case "setSpeed":
      let speed = (call.arguments as? [String: Any])?["speed"] as? NSNumber
      preferredRate = Float(max(0.5, min(2.0, speed?.doubleValue ?? 1)))
      if player.timeControlStatus == .playing {
        player.rate = preferredRate
      }
      result(nil)
    case "setVolumeScale":
      let scale = (call.arguments as? [String: Any])?["scale"] as? NSNumber
      player.volume = Float(max(0, min(1, scale?.doubleValue ?? 1)))
      result(nil)
    case "setEqualizerPreset", "setCrossfadeDuration", "setShuffleEnabled",
         "setRepeatMode", "setShuffleWeights", "setVideoFullscreen",
         "adjustBrightness", "adjustVolume", "share":
      // iOS 尚未接入均衡器、淡入淡出、系统分享与亮度调节。
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 播放

  private func startPlayback(path: String, values: [String: Any], result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      result(FlutterError(code: "missingFile", message: "媒体文件不存在或已被移动。", details: nil))
      return
    }
    currentMetadata = values
    let item = AVPlayerItem(url: url)
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.channel.invokeMethod(
        "completed",
        arguments: ["mediaId": self.currentMetadata["mediaId"] as? String ?? ""]
      )
    }
    statusObservation?.invalidate()
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard let self, item.status == .failed else { return }
      self.channel.invokeMethod("error", arguments: [
        "mediaId": self.currentMetadata["mediaId"] as? String ?? "",
        "message": item.error?.localizedDescription ?? "播放失败。",
      ])
    }
    player.replaceCurrentItem(with: item)
    let positionMs = (values["positionMs"] as? NSNumber)?.doubleValue ?? 0
    if positionMs > 0 {
      player.seek(to: CMTime(seconds: positionMs / 1000, preferredTimescale: 600))
    }
    let isVideo = (values["kind"] as? String) == "video"
    var payload: [String: Any] = [:]
    if isVideo {
      attachVideoOutput(to: item)
      payload["textureId"] = textureId
    } else {
      releaseVideoOutput()
    }
    player.rate = preferredRate
    result(payload)
  }

  // MARK: - 视频纹理

  private func attachVideoOutput(to item: AVPlayerItem) {
    if textureId < 0 {
      textureId = textures.register(self)
    }
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
    item.add(output)
    videoOutput = output
    latestPixelBuffer = nil
    lastReportedSize = .zero
    channel.invokeMethod("videoTextureChanged", arguments: ["textureId": textureId])
    reportVideoSize(item)
  }

  private func reportVideoSize(_ item: AVPlayerItem) {
    let size = item.presentationSize
    guard size.width > 0, size.height > 0, size != lastReportedSize else { return }
    lastReportedSize = size
    channel.invokeMethod("videoSizeChanged", arguments: [
      "mediaId": currentMetadata["mediaId"] as? String ?? "",
      "aspectRatio": Double(size.width / size.height),
    ])
  }

  private func releaseVideoOutput() {
    if let videoOutput, let item = player.currentItem {
      item.remove(videoOutput)
    }
    videoOutput = nil
    latestPixelBuffer = nil
  }

  private func startDisplayLink() {
    guard videoOutput != nil, displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(step))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc private func step() {
    guard let output = videoOutput else { return }
    let time = player.currentTime()
    if output.hasNewPixelBuffer(forItemTime: time),
       let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
      latestPixelBuffer = buffer
      textures.textureFrameAvailable(textureId)
      if let item = player.currentItem {
        reportVideoSize(item)
      }
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let buffer = latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  // MARK: - 音频会话

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    try? session.setActive(true)
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    switch type {
    case .began:
      channel.invokeMethod("interruptionBegan", arguments: ["mayResume": true])
    case .ended:
      channel.invokeMethod("interruptionEnded", arguments: nil)
    @unknown default:
      break
    }
  }
}
