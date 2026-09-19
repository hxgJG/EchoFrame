import AVFoundation
import Cocoa
import CryptoKit
import FlutterMacOS
import UniformTypeIdentifiers

final class LumioMediaLibraryPlugin: NSObject, FlutterPlugin {
  private struct IndexedMedia {
    let path: String
    let kind: String
    let sourceID: String
    let relativePath: String
  }

  private let channel: FlutterMethodChannel
  private let bookmarkStore: SecurityScopedBookmarkStore
  private weak var window: NSWindow?
  private let queue = DispatchQueue(label: "com.hxg.lumio.media-library", qos: .userInitiated)
  private let scanStateLock = NSLock()
  private var scanCancelled = false
  private var exportingLyrics = false
  private var mediaIndex: [String: IndexedMedia] = [:]
  private let snapshotURL = LumioPaths.applicationSupportDirectory
    .appendingPathComponent("scan_snapshot.json")

  private let audioExtensions: Set<String> = [
    "aac", "flac", "m4a", "mp3", "wav",
  ]
  private let videoExtensions: Set<String> = [
    "m4v", "mov", "mp4",
  ]

  static func register(with registrar: FlutterPluginRegistrar) {
    // Registered by LumioMacOSPlugins so the bookmark store can be shared.
  }

  init(
    registrar: FlutterPluginRegistrar,
    bookmarkStore: SecurityScopedBookmarkStore,
    window: NSWindow
  ) {
    self.bookmarkStore = bookmarkStore
    self.window = window
    channel = FlutterMethodChannel(
      name: "lumio/media_library",
      binaryMessenger: registrar.messenger
    )
    super.init()
    registrar.addMethodCallDelegate(self, channel: channel)
    queue.async { [weak self] in
      guard let self, let snapshot = self.loadSnapshot() else { return }
      self.rebuildIndex(from: snapshot)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "addSources":
      presentSourcePicker(result: result)
    case "listSources":
      result(bookmarkStore.list())
    case "removeSource":
      guard let id = (call.arguments as? [String: Any])?["sourceId"] as? String else {
        result(invalidArguments("缺少媒体来源 ID。"))
        return
      }
      do {
        try bookmarkStore.remove(id: id)
        result(nil)
      } catch {
        result(mediaError(error))
      }
    case "scan":
      let arguments = call.arguments as? [String: Any] ?? [:]
      if bookmarkStore.resolvedSources().compactMap(\.url).isEmpty {
        presentSourcePicker { [weak self] pickerResult in
          guard let self else { return }
          if pickerResult is FlutterError {
            result(pickerResult)
          } else if (pickerResult as? [[String: Any]])?.isEmpty != false {
            result([
              "status": "cancelled",
              "message": "未选择媒体文件夹，媒体库保持不变。",
            ])
          } else {
            self.startScan(arguments: arguments, result: result)
          }
        }
      } else {
        startScan(arguments: arguments, result: result)
      }
    case "cancelScan":
      setScanCancelled(true)
      result(nil)
    case "restoreLastScan":
      queue.async { [weak self] in
        guard let self else { return }
        let snapshot = self.loadSnapshot()
        if let snapshot {
          self.rebuildIndex(from: snapshot)
        }
        self.finish(result, value: snapshot)
      }
    case "loadArtwork":
      guard let arguments = call.arguments as? [String: Any],
            let mediaID = arguments["mediaId"] as? String else {
        result(invalidArguments("缺少媒体 ID。"))
        return
      }
      queue.async { [weak self] in
        guard let self else { return }
        let data = self.loadArtwork(mediaID: mediaID)
        self.finish(
          result,
          value: data.map { FlutterStandardTypedData(bytes: $0) }
        )
      }
    case "performFileOperation":
      guard let arguments = call.arguments as? [String: Any] else {
        result(invalidArguments("文件操作参数无效。"))
        return
      }
      queue.async { [weak self] in
        guard let self else { return }
        self.finish(result, value: self.performFileOperation(arguments))
      }
    case "importLyrics":
      presentLyricsPicker(result: result)
    case "exportLyrics":
      exportLyrics(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func exportLyrics(_ arguments: Any?, result: @escaping FlutterResult) {
    guard !exportingLyrics else {
      result(["status": "failed", "message": "已有歌词正在导出。"])
      return
    }
    guard let args = arguments as? [String: Any],
          let name = args["fileName"] as? String,
          !name.contains("/"), !name.contains("\\"),
          name.hasSuffix(".lrc") || name.hasSuffix(".zip"),
          let payload = args["bytes"] as? FlutterStandardTypedData,
          !payload.data.isEmpty, payload.data.count <= 32 * 1024 * 1024 else {
      result(["status": "failed", "message": "歌词导出内容无效或超过 32 MB。"])
      return
    }
    exportingLyrics = true
    let panel = NSSavePanel()
    panel.title = name.hasSuffix(".zip") ? "导出全部歌词" : "导出歌词"
    panel.nameFieldStringValue = name
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [name.hasSuffix(".zip") ? .zip : (UTType(filenameExtension: "lrc", conformingTo: .plainText) ?? .plainText)]
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      guard response == .OK, let url = panel.url else {
        self.exportingLyrics = false
        result(["status": "cancelled", "message": "已取消导出。"])
        return
      }
      let scoped = url.startAccessingSecurityScopedResource()
      self.queue.async {
        let response: [String: String]
        do {
          try payload.data.write(to: url, options: .atomic)
          response = ["status": "completed", "message": "歌词已保存。"]
        } catch {
          response = ["status": "failed", "message": "保存失败：\(error.localizedDescription)"]
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        DispatchQueue.main.async {
          self.exportingLyrics = false
          result(response)
        }
      }
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(panel.runModal())
    }
  }

  private func presentSourcePicker(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "添加媒体文件夹"
    panel.message = "忆光只会读取你明确选择的文件夹。"
    panel.prompt = "添加"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.resolvesAliases = true

    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      guard response == .OK else {
        result([])
        return
      }
      do {
        result(try self.bookmarkStore.add(urls: panel.urls))
      } catch {
        result(self.mediaError(error))
      }
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(panel.runModal())
    }
  }

  private func presentLyricsPicker(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "选择 LRC 歌词文件"
    panel.message = "所选歌词会绑定到当前歌曲，并保存在忆光媒体库中。"
    panel.prompt = "导入"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.allowedContentTypes = [
      UTType(filenameExtension: "lrc") ?? .plainText,
      .plainText,
    ]

    let completion: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else {
        result(self.lyricsImportResult(status: "cancelled", message: "已取消选择歌词文件。"))
        return
      }
      guard url.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame else {
        result(self.lyricsImportResult(status: "failed", message: "请选择 .lrc 格式的歌词文件。"))
        return
      }
      let isAccessing = url.startAccessingSecurityScopedResource()
      defer {
        if isAccessing {
          url.stopAccessingSecurityScopedResource()
        }
      }
      do {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 2 * 1024 * 1024 else {
          result(self.lyricsImportResult(status: "failed", message: "歌词文件不能超过 2 MB。"))
          return
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 2 * 1024 * 1024 else {
          result(self.lyricsImportResult(status: "failed", message: "歌词文件不能超过 2 MB。"))
          return
        }
        guard let decoded = String(data: data, encoding: .utf8)
          ?? String(data: data, encoding: .utf16)
          ?? String(data: data, encoding: .utf16LittleEndian)
          ?? String(data: data, encoding: .utf16BigEndian) else {
          result(self.lyricsImportResult(status: "failed", message: "歌词文件编码无法识别，请使用 UTF-8 或 UTF-16。"))
          return
        }
        let text = decoded.replacingOccurrences(
          of: "\u{FEFF}",
          with: "",
          options: .anchored
        )
        result(self.lyricsImportResult(
          status: "completed",
          message: "歌词文件已读取。",
          fileName: url.lastPathComponent,
          lyricsText: text
        ))
      } catch {
        result(self.lyricsImportResult(
          status: "failed",
          message: error.localizedDescription
        ))
      }
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(panel.runModal())
    }
  }

  private func lyricsImportResult(
    status: String,
    message: String,
    fileName: String = "",
    lyricsText: String = ""
  ) -> [String: Any] {
    [
      "status": status,
      "message": message,
      "fileName": fileName,
      "lyricsText": lyricsText,
    ]
  }

  private func startScan(
    arguments: [String: Any],
    result: @escaping FlutterResult
  ) {
    setScanCancelled(false)
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let response = try self.scan(arguments: arguments)
        if response["status"] as? String == "completed" {
          try self.writeSnapshot(response)
          self.rebuildIndex(from: response)
        }
        self.finish(result, value: response)
      } catch {
        self.finish(result, value: self.mediaError(error))
      }
    }
  }

  private func scan(arguments: [String: Any]) throws -> [String: Any] {
    let minimumDurationMs = int64(arguments["minimumAudioDurationMs"])
    let includedFolders = stringList(arguments["includedFolders"])
    let excludedFolders = stringList(arguments["excludedFolders"])
    var audioItems: [[String: Any]] = []
    var videoItems: [[String: Any]] = []
    var inaccessibleSources = 0

    for source in bookmarkStore.resolvedSources() {
      guard !isScanCancelled() else {
        return ["status": "cancelled", "message": "已取消扫描，媒体库保持不变。"]
      }
      guard let root = source.url,
            root.startAccessingSecurityScopedResource() else {
        inaccessibleSources += 1
        continue
      }
      defer { root.stopAccessingSecurityScopedResource() }

      let keys: [URLResourceKey] = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .fileResourceIdentifierKey,
      ]
      guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) else { continue }

      for case let fileURL as URL in enumerator {
        guard !isScanCancelled() else {
          return ["status": "cancelled", "message": "已取消扫描，媒体库保持不变。"]
        }
        let values = try? fileURL.resourceValues(forKeys: Set(keys))
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
        let normalizedPath = fileURL.standardizedFileURL.path
        if !includedFolders.isEmpty,
           !includedFolders.contains(where: { path(normalizedPath, isInside: $0) }) {
          continue
        }
        if excludedFolders.contains(where: { path(normalizedPath, isInside: $0) }) {
          continue
        }
        let fileExtension = fileURL.pathExtension.lowercased()
        let kind: String
        if audioExtensions.contains(fileExtension) {
          kind = "audio"
        } else if videoExtensions.contains(fileExtension) {
          kind = "video"
        } else {
          continue
        }
        let item = mediaItem(
          url: fileURL,
          root: root,
          sourceID: source.record.id,
          kind: kind,
          resourceValues: values
        )
        if kind == "audio" {
          if int64(item["durationMs"]) >= minimumDurationMs {
            audioItems.append(item)
          }
        } else {
          videoItems.append(item)
        }
      }
    }

    audioItems.sort { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }
    videoItems.sort { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }
    var message = "已从授权文件夹扫描媒体。"
    if inaccessibleSources > 0 {
      message += " \(inaccessibleSources) 个来源需要重新授权。"
    }
    return [
      "schemaVersion": 2,
      "status": "completed",
      "message": message,
      "audioItems": audioItems,
      "videoItems": videoItems,
    ]
  }

  private func mediaItem(
    url: URL,
    root: URL,
    sourceID: String,
    kind: String,
    resourceValues: URLResourceValues?
  ) -> [String: Any] {
    let asset = AVURLAsset(url: url)
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    let durationMs = durationSeconds.isFinite && durationSeconds > 0
      ? Int64(durationSeconds * 1000)
      : 0
    let relativePath = url.path.replacingOccurrences(
      of: root.path.hasSuffix("/") ? root.path : root.path + "/",
      with: "",
      options: [.anchored]
    )
    let id = stableID(sourceID: sourceID, relativePath: relativePath)
    let title = metadataString(asset, key: .commonKeyTitle)
      ?? url.deletingPathExtension().lastPathComponent
    let artist = metadataString(asset, key: .commonKeyArtist) ?? "未知艺术家"
    let album = metadataString(asset, key: .commonKeyAlbumName) ?? "未知专辑"
    let date = resourceValues?.creationDate
      ?? resourceValues?.contentModificationDate
      ?? Date()
    var item: [String: Any] = [
      "id": id,
      "kind": kind,
      "title": title,
      "artist": artist,
      "album": album,
      "durationMs": durationMs,
      "path": url.path,
      "folder": url.deletingLastPathComponent().path,
      "addedAtMs": Int64(date.timeIntervalSince1970 * 1000),
      "sizeBytes": Int64(resourceValues?.fileSize ?? 0),
      "format": url.pathExtension.uppercased(),
      "sourceId": sourceID,
      "relativePath": relativePath,
      "availability": "available",
    ]
    if kind == "video", let resolution = videoResolution(asset) {
      item["resolution"] = resolution
    }
    let base = url.deletingPathExtension()
    item["lyricsText"] = readTextSidecar(base: base, extensions: ["lrc"])
    item["subtitleText"] = readTextSidecar(base: base, extensions: ["srt"])
    item["assSubtitleText"] = readTextSidecar(base: base, extensions: ["ass", "ssa"])
    return LumioMetadataRepair.record(item)
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

  private func stableID(sourceID: String, relativePath: String) -> String {
    let digest = SHA256.hash(data: Data("\(sourceID)|\(relativePath)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func loadArtwork(mediaID: String) -> Data? {
    guard let indexed = mediaIndex[mediaID] else { return nil }
    let accessRoot = bookmarkStore.startAccess(forFilePath: indexed.path)
    defer { accessRoot?.stopAccessingSecurityScopedResource() }
    let asset = AVURLAsset(url: URL(fileURLWithPath: indexed.path))
    if indexed.kind == "audio" {
      let artwork = AVMetadataItem.metadataItems(
        from: asset.commonMetadata,
        withKey: AVMetadataKey.commonKeyArtwork,
        keySpace: .common
      ).first
      if let data = artwork?.dataValue { return data }
    } else {
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = NSSize(width: 960, height: 540)
      if let image = try? generator.copyCGImage(
        at: CMTime(seconds: 1, preferredTimescale: 600),
        actualTime: nil
      ) {
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(
          using: .jpeg,
          properties: [.compressionFactor: 0.82]
        )
      }
    }
    return nil
  }

  private func performFileOperation(_ arguments: [String: Any]) -> [String: Any] {
    guard let type = arguments["type"] as? String,
          let mediaIDs = arguments["mediaIds"] as? [String],
          !mediaIDs.isEmpty else {
      return ["status": "failed", "message": "文件操作参数无效。"]
    }
    if type == "writeTags" {
      return ["status": "unsupported", "message": "macOS 首版暂不写回媒体标签。"]
    }
    var affected: [String] = []
    do {
      for mediaID in mediaIDs {
        guard let indexed = mediaIndex[mediaID] else { continue }
        let source = URL(fileURLWithPath: indexed.path)
        let accessRoot = bookmarkStore.startAccess(forFilePath: indexed.path)
        defer { accessRoot?.stopAccessingSecurityScopedResource() }
        let destination: URL
        switch type {
        case "rename":
          guard let rawName = arguments["displayName"] as? String else { continue }
          let requested = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
          let name = URL(fileURLWithPath: requested).pathExtension.isEmpty
            ? requested + "." + source.pathExtension
            : requested
          destination = source.deletingLastPathComponent().appendingPathComponent(name)
        case "move":
          guard let relativePath = arguments["relativePath"] as? String,
                let root = accessRoot else { continue }
          let directory = root.appendingPathComponent(relativePath, isDirectory: true)
          try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
          )
          destination = directory.appendingPathComponent(source.lastPathComponent)
        default:
          return ["status": "unsupported", "message": "当前文件操作不受支持。"]
        }
        try FileManager.default.moveItem(at: source, to: destination)
        affected.append(mediaID)
      }
      return [
        "status": "completed",
        "message": affected.isEmpty ? "没有可操作的媒体文件。" : "已完成文件操作。",
        "affectedMediaIds": affected,
      ]
    } catch {
      return ["status": "failed", "message": error.localizedDescription]
    }
  }

  private func rebuildIndex(from snapshot: [String: Any]) {
    var next: [String: IndexedMedia] = [:]
    for key in ["audioItems", "videoItems"] {
      guard let items = snapshot[key] as? [[String: Any]] else { continue }
      for item in items {
        guard let id = item["id"] as? String,
              let path = item["path"] as? String,
              let kind = item["kind"] as? String else { continue }
        next[id] = IndexedMedia(
          path: path,
          kind: kind,
          sourceID: item["sourceId"] as? String ?? "",
          relativePath: item["relativePath"] as? String ?? ""
        )
      }
    }
    mediaIndex = next
  }

  private func writeSnapshot(_ snapshot: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
    try data.write(to: snapshotURL, options: .atomic)
  }

  private func loadSnapshot() -> [String: Any]? {
    guard let data = try? Data(contentsOf: snapshotURL),
          let object = try? JSONSerialization.jsonObject(with: data),
          let snapshot = object as? [String: Any] else { return nil }
    return LumioMetadataRepair.library(snapshot)
  }

  private func setScanCancelled(_ value: Bool) {
    scanStateLock.lock()
    scanCancelled = value
    scanStateLock.unlock()
  }

  private func isScanCancelled() -> Bool {
    scanStateLock.lock()
    defer { scanStateLock.unlock() }
    return scanCancelled
  }

  private func stringList(_ value: Any?) -> [String] {
    (value as? [Any])?.map { String(describing: $0) } ?? []
  }

  private func int64(_ value: Any?) -> Int64 {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    return Int64(String(describing: value ?? "")) ?? 0
  }

  private func path(_ candidate: String, isInside folder: String) -> Bool {
    let root = URL(fileURLWithPath: folder).standardizedFileURL.path
    return candidate == root || candidate.hasPrefix(root + "/")
  }

  private func finish(_ result: @escaping FlutterResult, value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func invalidArguments(_ message: String) -> FlutterError {
    FlutterError(code: "invalidArguments", message: message, details: nil)
  }

  private func mediaError(_ error: Error) -> FlutterError {
    FlutterError(code: "mediaLibraryError", message: error.localizedDescription, details: nil)
  }
}
