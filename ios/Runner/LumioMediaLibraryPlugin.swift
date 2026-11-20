import AVFoundation
import Flutter
import UIKit
import UniformTypeIdentifiers

/// iOS 媒体库：按 PRD D4 采用「用户主动导入」，不做全盘扫描。
///
/// 选中的音视频会被复制进应用沙盒的 `Media` 目录，之后由本插件负责
/// 元数据读取、封面抽取与视频首帧。来源列表固定为该目录一项。
final class LumioMediaLibraryPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.hxg.lumio.media")
  private var pendingPicker: FlutterResult?
  private var pickerIsVideo = false

  private var mediaDirectory: URL {
    let directory = LumioAppPaths.applicationSupport.appendingPathComponent("Media", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static let sourceID = "ios-imported"
  private static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf", "alac", "ogg", "opus"
  ]
  private static let videoExtensions: Set<String> = [
    "mp4", "mov", "m4v", "avi", "mkv"
  ]

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LumioMediaLibraryPlugin(messenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.channel)
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "lumio/media_library", binaryMessenger: messenger)
    super.init()
    _ = mediaDirectory
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listSources":
      queue.async { [weak self] in
        guard let self else { return }
        self.finish(result, value: self.hasImportedMedia() ? [self.sourcePayload()] : [Any]())
      }
    case "addSources", "addVideoSources":
      presentPicker(videos: call.method == "addVideoSources", result: result)
    case "scan":
      queue.async { [weak self] in
        guard let self else { return }
        self.scan(arguments: call.arguments, result: result)
      }
    case "loadArtwork":
      queue.async { [weak self] in
        guard let self else { return }
        self.loadArtwork(arguments: call.arguments, result: result)
      }
    case "loadVideoFrame":
      queue.async { [weak self] in
        guard let self else { return }
        self.loadVideoFrame(arguments: call.arguments, result: result)
      }
    case "cancelScan":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 导入

  private func presentPicker(videos: Bool, result: @escaping FlutterResult) {
    guard pendingPicker == nil else {
      result(FlutterError(code: "busy", message: "已有文件选择器正在打开。", details: nil))
      return
    }
    pendingPicker = result
    pickerIsVideo = videos
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        let types: [UTType] = videos ? [.movie, .video] : [.audio]
        picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
      } else {
        let types = videos ? ["public.movie"] : ["public.audio"]
        picker = UIDocumentPickerViewController(documentTypes: types, in: .import)
      }
      picker.delegate = self
      picker.allowsMultipleSelection = true
      self.topViewController()?.present(picker, animated: true)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingPicker else { return }
    pendingPicker = nil
    guard !urls.isEmpty else {
      result([Any]())
      return
    }
    queue.async { [weak self] in
      guard let self else { return }
      do {
        for url in urls {
          try self.importFile(at: url)
        }
        self.finish(result, value: [self.sourcePayload()])
      } catch {
        self.finish(result, value: FlutterError(
          code: "importFailed",
          message: "导入失败：\(error.localizedDescription)",
          details: nil
        ))
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPicker?(nil)
    pendingPicker = nil
  }

  /// 把选中文件复制进沙盒；同名文件自动追加序号，不覆盖已导入内容。
  private func importFile(at url: URL) throws {
    let manager = FileManager.default
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let destination = uniqueDestination(for: url.lastPathComponent)
    // 使用协调读取，兼容 iCloud Drive 等尚未下载到本地的文件。
    var coordinationError: NSError?
    var copyError: Error?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
      do {
        try manager.copyItem(at: readable, to: destination)
      } catch {
        copyError = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let copyError { throw copyError }
  }

  private func uniqueDestination(for fileName: String) -> URL {
    let manager = FileManager.default
    let directory = mediaDirectory
    let base = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    var candidate = directory.appendingPathComponent(fileName)
    var index = 1
    while manager.fileExists(atPath: candidate.path) {
      let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
      candidate = directory.appendingPathComponent(name)
      index += 1
    }
    return candidate
  }

  private func hasImportedMedia() -> Bool {
    let contents = try? FileManager.default.contentsOfDirectory(
      at: mediaDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    return !(contents ?? []).isEmpty
  }

  private func sourcePayload() -> [String: Any] {
    [
      "id": Self.sourceID,
      "displayName": "本机导入",
      "resolvedPath": mediaDirectory.path,
      "status": "available",
      "readOnly": false,
    ]
  }

  // MARK: - 扫描

  private func scan(arguments: Any?, result: @escaping FlutterResult) {
    let values = arguments as? [String: Any] ?? [:]
    let minimumDurationMs = (values["minimumAudioDurationMs"] as? NSNumber)?.int64Value ?? 0
    let excluded = Set((values["excludedFolders"] as? [String] ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    let files = (try? FileManager.default.contentsOfDirectory(
      at: mediaDirectory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    var audioItems: [[String: Any]] = []
    var videoItems: [[String: Any]] = []
    for url in files {
      let ext = url.pathExtension.lowercased()
      let kind: String
      if Self.audioExtensions.contains(ext) {
        kind = "audio"
      } else if Self.videoExtensions.contains(ext) {
        kind = "video"
      } else {
        continue
      }
      if excluded.contains(url.deletingLastPathComponent().standardizedFileURL.path) { continue }
      guard let item = makeItem(url: url, kind: kind) else { continue }
      if kind == "audio", (item["durationMs"] as? Int64 ?? 0) < minimumDurationMs { continue }
      if kind == "audio" { audioItems.append(item) } else { videoItems.append(item) }
    }
    audioItems.sort { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }
    videoItems.sort { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }
    let payload: [String: Any] = [
      "status": "completed",
      "message": audioItems.isEmpty && videoItems.isEmpty
        ? "还没有导入媒体。点击「添加媒体」从「文件」中选择音视频。"
        : "已导入 \(audioItems.count) 首音频、\(videoItems.count) 个视频。",
      "audioItems": audioItems,
      "videoItems": videoItems,
    ]
    finish(result, value: payload)
  }

  private func makeItem(url: URL, kind: String) -> [String: Any]? {
    let asset = AVURLAsset(url: url)
    let values = try? url.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ])
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    let durationMs = durationSeconds.isFinite && durationSeconds > 0
      ? Int64(durationSeconds * 1000) : 0
    let date = values?.creationDate ?? values?.contentModificationDate ?? Date()
    var item: [String: Any] = [
      "id": "ios-\(kind)-\(stableKey(url.lastPathComponent))",
      "kind": kind,
      "title": metadataString(asset, key: .commonKeyTitle)
        ?? url.deletingPathExtension().lastPathComponent,
      "artist": metadataString(asset, key: .commonKeyArtist) ?? "未知艺术家",
      "album": metadataString(asset, key: .commonKeyAlbumName) ?? "未知专辑",
      "durationMs": durationMs,
      "path": url.path,
      "folder": url.deletingLastPathComponent().path,
      "addedAtMs": Int64(date.timeIntervalSince1970 * 1000),
      "sizeBytes": Int64(values?.fileSize ?? 0),
      "format": url.pathExtension.uppercased(),
      "sourceId": Self.sourceID,
      "relativePath": url.lastPathComponent,
      "availability": "available",
    ]
    if kind == "video", let resolution = videoResolution(asset) {
      item["resolution"] = resolution
    }
    let base = url.deletingPathExtension()
    item["lyricsText"] = readTextSidecar(base: base, extensions: ["lrc"])
    item["subtitleText"] = readTextSidecar(base: base, extensions: ["srt"])
    item["assSubtitleText"] = readTextSidecar(base: base, extensions: ["ass", "ssa"])
    return item
  }

  private func metadataString(_ asset: AVAsset, key: AVMetadataKey) -> String? {
    AVMetadataItem.metadataItems(
      from: asset.commonMetadata,
      withKey: key,
      keySpace: .common
    ).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func videoResolution(_ asset: AVAsset) -> String? {
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }
    let transformed = track.naturalSize.applying(track.preferredTransform)
    let width = Int(abs(transformed.width).rounded())
    let height = Int(abs(transformed.height).rounded())
    guard width > 0, height > 0 else { return nil }
    return "\(width)x\(height)"
  }

  private func readTextSidecar(base: URL, extensions: [String]) -> String {
    for fileExtension in extensions {
      let url = base.appendingPathExtension(fileExtension)
      if let text = try? String(contentsOf: url, encoding: .utf8) {
        return text
      }
    }
    return ""
  }

  private func stableKey(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in Data(value.utf8) {
      hash ^= UInt64(byte)
      hash = hash &* 0x100000001b3
    }
    return String(hash, radix: 16)
  }

  // MARK: - 封面与首帧

  private func loadArtwork(arguments: Any?, result: @escaping FlutterResult) {
    let values = arguments as? [String: Any] ?? [:]
    let mediaId = values["mediaId"] as? String ?? ""
    guard let url = url(forMediaId: mediaId) else {
      finish(result, value: nil)
      return
    }
    let asset = AVURLAsset(url: url)
    let artworkKey: AVMetadataKey = .commonKeyArtwork
    for item in AVMetadataItem.metadataItems(
      from: asset.commonMetadata,
      withKey: artworkKey,
      keySpace: .common
    ) {
      if let data = item.dataValue {
        finish(result, value: FlutterStandardTypedData(bytes: data))
        return
      }
    }
    finish(result, value: nil)
  }

  private func loadVideoFrame(arguments: Any?, result: @escaping FlutterResult) {
    let values = arguments as? [String: Any] ?? [:]
    let mediaId = values["mediaId"] as? String ?? ""
    guard let url = url(forMediaId: mediaId) else {
      finish(result, value: nil)
      return
    }
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 480)
    guard let image = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil),
          let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else {
      finish(result, value: nil)
      return
    }
    finish(result, value: FlutterStandardTypedData(bytes: data))
  }

  /// 由媒体 ID 反查文件：ID 后缀是文件名的稳定摘要，避免路径随沙盒迁移失效。
  private func url(forMediaId mediaId: String) -> URL? {
    guard mediaId.hasPrefix("ios-") else { return nil }
    let key = String(mediaId.split(separator: "-").last ?? "")
    let files = (try? FileManager.default.contentsOfDirectory(
      at: mediaDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []
    return files.first { stableKey($0.lastPathComponent) == key }
  }

  // MARK: - 辅助

  private func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }

  private func finish(_ result: @escaping FlutterResult, value: Any?) {
    DispatchQueue.main.async {
      result(value)
    }
  }
}
