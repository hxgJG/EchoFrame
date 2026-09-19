import AVFoundation
import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// 文件授权、独立预览及应用级导出任务；不触碰媒体库播放器。
@MainActor
final class LumioSubtitleWorkbenchPlugin: NSObject, @preconcurrency FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let texture: LumioVideoTexture
  private let window: NSWindow
  private let bookmarks: SecurityScopedBookmarkStore
  private var player: AVPlayer?
  private var sourceURL: URL?
  private var accessURL: URL?
  private var sessionID: String?
  private var busy = false
  private var exportTask: Task<Void, Never>?
  private let exporter = LumioSubtitleVideoExporter()
  private var job: [String: Any] = [:]
  private var probe: SubtitleVideoProbe?
  private let directory = LumioPaths.applicationSupportDirectory.appendingPathComponent("subtitle_projects", isDirectory: true)
  private let jobURL = LumioPaths.applicationSupportDirectory.appendingPathComponent("subtitle_export_job.json")

  static func register(with registrar: FlutterPluginRegistrar) {}

  init(registrar: FlutterPluginRegistrar, window: NSWindow, bookmarks: SecurityScopedBookmarkStore) {
    channel = FlutterMethodChannel(name: "lumio/subtitle_workbench", binaryMessenger: registrar.messenger)
    texture = LumioVideoTexture(registry: registrar.textures)
    self.window = window
    self.bookmarks = bookmarks
    super.init()
    if let data = try? Data(contentsOf: jobURL), var previous = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      if !["completed", "failed", "cancelled"].contains(previous["phase"] as? String ?? "") {
        previous["phase"] = "failed"
        previous["error"] = "上次导出被应用退出或系统中断。项目已保留，请使用新文件名重新导出；若存在未完成输出，请核对后手动删除。"
      }
      job = previous
    }
    registrar.addMethodCallDelegate(self, channel: channel)
  }

  var hasExport: Bool { exportTask != nil }

  func requestTermination(_ sender: NSApplication) -> NSApplication.TerminateReply? {
    guard hasExport else { return nil }
    let alert = NSAlert()
    alert.messageText = "视频仍在导出"
    alert.informativeText = "可以继续等待，或取消导出并退出。已保存的字幕项目不会丢失。"
    alert.addButton(withTitle: "继续等待")
    alert.addButton(withTitle: "取消导出并退出")
    guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
    exporter.cancel()
    exportTask?.cancel()
    Task { [weak self] in
      await self?.exportTask?.value
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    if call.method == "status" {
      let time = player?.currentTime().seconds ?? 0
      result(["sessionId": sessionID ?? "", "positionMs": time.isFinite ? Int64(time * 1000) : 0,
              "playing": player?.rate != 0 && player != nil, "job": job,
              "error": player?.currentItem?.error?.localizedDescription ?? ""])
      return
    }
    if call.method == "cancelExport" {
      exporter.cancel(); exportTask?.cancel(); result(nil); return
    }
    guard !busy else { result(FlutterError(code: "busy", message: "上一个操作尚未完成。", details: nil)); return }
    busy = true
    Task {
      defer { busy = false }
      do { result(try await perform(call.method, arguments)) }
      catch { result(FlutterError(code: "subtitleWorkbench", message: error.localizedDescription, details: nil)) }
    }
  }

  private func perform(_ method: String, _ args: [String: Any]) async throws -> Any? {
    switch method {
    case "list":
      return try projectFiles().map { url -> [String: Any] in
        do {
          let value = try readProject(url)
          return ["id": value["id"] ?? "", "name": value["name"] ?? "未命名项目",
                  "updatedAtMs": value["updatedAtMs"] ?? 0, "schemaVersion": value["schemaVersion"] ?? 0]
        } catch { return ["id": url.deletingPathExtension().lastPathComponent, "name": "损坏的项目（可删除）", "error": error.localizedDescription] }
      }
    case "load": return try readProject(projectURL(args["id"]))
    case "save":
      guard var project = args["project"] as? [String: Any], project["schemaVersion"] as? Int == 1 else {
        throw SubtitleVideoError.invalid("不支持的项目版本。")
      }
      let url = try projectURL(project["id"])
      guard let revision = project["revision"] as? Int, revision > 0,
            let expected = args["expectedRevision"] as? Int, revision >= expected else {
        throw SubtitleVideoError.invalid("项目版本无效。")
      }
      if !FileManager.default.fileExists(atPath: url.path), expected != 0 {
        throw SubtitleVideoError.invalid("项目已被删除，不能自动重新创建，请先备份草稿。")
      }
      if !FileManager.default.fileExists(atPath: url.path), try projectFiles().count >= 200 {
        throw SubtitleVideoError.invalid("最多保存 200 个字幕项目，请先备份并清理不再需要的项目。")
      }
      if FileManager.default.fileExists(atPath: url.path) {
        let old = try readProject(url)
        guard old["schemaVersion"] as? Int == 1,
              old["revision"] as? Int == args["expectedRevision"] as? Int else {
          throw SubtitleVideoError.invalid("项目已被更新，请重新打开，避免覆盖其他版本。")
        }
      }
      project["updatedAtMs"] = Int64(Date().timeIntervalSince1970 * 1000)
      try write(project, url)
      return project
    case "delete":
      let id = args["id"] as? String
      guard job["projectId"] as? String != id || !hasExport else { throw SubtitleVideoError.invalid("请先完成或取消该项目的导出。") }
      let url = try projectURL(id)
      // 仅删除应用自建项目文件，不读取项目内的源路径作为删除目标。
      try FileManager.default.removeItem(at: url)
      return nil
    case "snapshot":
      var projects: [[String: Any]] = []
      var bytes = 0
      for file in try projectFiles() {
        bytes += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 8 * 1024 * 1024
        guard bytes <= 64 * 1024 * 1024 else { throw SubtitleVideoError.invalid("字幕项目备份超过 64 MiB，请清理不再需要的项目。") }
        projects.append(try readProject(file))
      }
      return projects
    case "restore":
      guard sessionID == nil, !hasExport else { throw SubtitleVideoError.invalid("请关闭字幕工作台并等待导出结束，再恢复备份。") }
      guard let projects = args["projects"] as? [[String: Any]], projects.count <= 200 else { throw SubtitleVideoError.invalid("字幕项目备份无效。") }
      guard try projectFiles().count + projects.count <= 200,
            try JSONSerialization.data(withJSONObject: projects).count <= 64 * 1024 * 1024 else { throw SubtitleVideoError.invalid("恢复后项目超过 200 个或备份超过 64 MiB。") }
      var prepared: [(URL, Data)] = []
      // 恢复为新项目；先校验整批，再写入，失败只回滚本次创建的 UUID 文件。
      for var project in projects {
        guard project["schemaVersion"] as? Int == 1 else { throw SubtitleVideoError.invalid("备份含不支持的字幕项目版本。") }
        project["id"] = UUID().uuidString.lowercased()
        project["revision"] = 1
        project["name"] = "恢复 · \(project["name"] as? String ?? "字幕项目")"
        project.removeValue(forKey: "libraryBinding")
        let data = try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys])
        guard data.count <= 8 * 1024 * 1024 else { throw SubtitleVideoError.invalid("备份中单项目超过 8 MiB。") }
        prepared.append((try projectURL(project["id"]), data))
      }
      var created: [URL] = []
      let staging = directory.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: staging) }
      do {
        for (url, data) in prepared {
          let temporary = staging.appendingPathComponent(url.lastPathComponent)
          try data.write(to: temporary, options: .atomic)
          try FileManager.default.moveItem(at: temporary, to: url)
          created.append(url)
        }
      } catch { for url in created { try? FileManager.default.removeItem(at: url) }; throw error }
      return nil
    case "selectVideo":
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false
      panel.message = "选择已下载到本机的 SDR MP4/MOV 视频。仅本地读取，不复制或上传。"
      guard await show(panel) == .OK, let url = panel.url else { return nil }
      return try await sourceReference(url)
    case "libraryVideo":
      guard let path = args["path"] as? String else { throw SubtitleVideoError.invalid("缺少视频路径。") }
      let root = bookmarks.startAccess(forFilePath: path)
      defer { root?.stopAccessingSecurityScopedResource() }
      return try await sourceReference(URL(fileURLWithPath: path))
    case "open":
      closePreview()
      guard let source = args["source"] as? [String: Any],
            let encoded = source["bookmark"] as? String, let data = Data(base64Encoded: encoded) else {
        throw SubtitleVideoError.invalid("视频授权不可用，请重新选择文件。")
      }
      var stale = false
      let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
      let access = url.startAccessingSecurityScopedResource()
      do {
        let identity = try fingerprint(url)
        guard identity["size"] as? Int64 == (source["size"] as? NSNumber)?.int64Value,
              identity["modifiedMs"] as? Int64 == (source["modifiedMs"] as? NSNumber)?.int64Value else {
          throw SubtitleVideoError.invalid("视频已改变，可能不是原视频。请重新选择并确认，字幕草稿会保留。")
        }
        let asset = AVURLAsset(url: url)
        let info = try await LumioSubtitleVideoExporter.probe(asset)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in request.finish(with: request.sourceImage, context: nil) })
        let preview = AVPlayer(playerItem: item)
        preview.actionAtItemEnd = .pause
        player = preview; sourceURL = url; accessURL = access ? url : nil; probe = info
        sessionID = UUID().uuidString
        texture.attach(to: item)
        return ["sessionId": sessionID!, "textureId": texture.textureID, "durationMs": info.durationMs, "width": info.width, "height": info.height]
      } catch { if access { url.stopAccessingSecurityScopedResource() }; throw error }
    case "close": closePreview(); return nil
    case "document":
      try requireSession(args)
      guard let item = player?.currentItem, let player else { throw SubtitleVideoError.invalid("预览尚未打开。") }
      let playing = player.rate != 0
      let time = player.currentTime()
      player.pause()
      let replacement = AVPlayerItem(asset: item.asset)
      if let cues = args["cues"] as? [Any], cues.isEmpty {
        replacement.videoComposition = AVVideoComposition(asset: item.asset, applyingCIFiltersWithHandler: { request in
          request.finish(with: request.sourceImage, context: nil)
        })
      } else {
        let document = try decodeDocument(args)
        replacement.videoComposition = try await LumioSubtitleVideoComposition.make(asset: item.asset, document: document)
      }
      texture.detach()
      player.replaceCurrentItem(with: replacement)
      texture.attach(to: replacement)
      guard await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) else { throw SubtitleVideoError.invalid("预览定位失败，请重新打开视频。") }
      texture.notifyFrameAvailable()
      if playing { player.play() }
      return nil
    case "play":
      try requireSession(args)
      if args["playing"] as? Bool == true {
        if let player, let probe, player.currentTime().seconds * 1000 >= Double(probe.durationMs - 30) {
          await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player?.play()
      } else { player?.pause() }
      return nil
    case "seek":
      try requireSession(args)
      let ms = (args["positionMs"] as? NSNumber)?.int64Value ?? 0
      guard await player?.seek(to: CMTime(value: max(0, min(ms, probe?.durationMs ?? 0)), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) == true else {
        throw SubtitleVideoError.invalid("定位未完成，请重试。")
      }
      texture.notifyFrameAvailable()
      return nil
    case "sidecar":
      try requireSession(args)
      guard let sourceURL, let root = bookmarks.startAccess(forFilePath: sourceURL.path) else {
        throw SubtitleVideoError.invalid("同名字幕所在文件夹未授权，请使用“导入字幕”手动选择同名文件。")
      }
      defer { root.stopAccessingSecurityScopedResource() }
      for ext in ["srt", "ass", "ssa"] {
        let url = sourceURL.deletingPathExtension().appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: url.path) { return try subtitleFile(url) }
      }
      throw SubtitleVideoError.invalid("没有找到同名 SRT / ASS / SSA 文件，当前草稿未改变。")
    case "import":
      let panel = NSOpenPanel()
      panel.allowedContentTypes = ["srt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
      panel.allowsMultipleSelection = false
      guard await show(panel) == .OK, let url = panel.url else { return nil }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      return try subtitleFile(url)
    case "export":
      try requireSession(args)
      guard !hasExport, let sourceURL else { throw SubtitleVideoError.invalid("已有导出任务或视频不可用。") }
      let document = try decodeDocument(args)
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.mpeg4Movie]
      panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "_字幕版.mp4"
      panel.message = "另存带硬字幕的新视频，不覆盖原视频或现有文件。"
      guard await show(panel) == .OK, let target = panel.url else { return nil }
      let targetAccess = target.startAccessingSecurityScopedResource()
      let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
      let token = UUID().uuidString
      job = ["id": token, "projectId": args["projectId"] ?? "", "revision": args["revision"] ?? 0, "phase": "preparing"]
      persistJob()
      exportTask = Task {
        defer {
          if targetAccess { target.stopAccessingSecurityScopedResource() }
          if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
          exportTask = nil
          persistJob()
        }
        do {
          let size = Int64(try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
          let available = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
          let estimate = max(size * 3, 128 * 1024 * 1024)
          if let available, available < estimate { throw SubtitleVideoError.invalid("临时磁盘空间不足，建议至少预留原文件三倍空间。实际编码大小仍可能不同。") }
          // 文件授权不一定允许读取父目录容量；能取得时额外预检，写入失败仍由导出器清理。
          let targetValues = try? target.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
          if let capacity = targetValues?.volumeAvailableCapacityForImportantUsage, capacity < estimate {
            throw SubtitleVideoError.invalid("目标磁盘可用空间不足，请选择其他位置。")
          }
          _ = try await exporter.export(source: sourceURL, target: target, document: document,
            allowOutOfRange: args["allowOutOfRange"] as? Bool == true) { [weak self] phase, progress in
              self?.job["phase"] = phase
              self?.job["progress"] = progress ?? NSNull()
            }
          job["phase"] = "completed"; job["path"] = target.path
        } catch {
          job["phase"] = error is CancellationError || Task.isCancelled ? "cancelled" : "failed"
          job["error"] = error.localizedDescription
        }
      }
      return job
    default: return FlutterMethodNotImplemented
    }
  }

  private func requireSession(_ args: [String: Any]) throws {
    guard let sessionID, args["sessionId"] as? String == sessionID else { throw SubtitleVideoError.invalid("预览会话已过期，请重新打开项目。") }
  }

  private func persistJob() {
    if let data = try? JSONSerialization.data(withJSONObject: job) { try? data.write(to: jobURL, options: .atomic) }
  }

  private func subtitleFile(_ url: URL) throws -> [String: Any] {
    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2 * 1024 * 1024 else { throw SubtitleVideoError.invalid("字幕文件不能超过 2 MiB。") }
    let data = try Data(contentsOf: url)
    guard data.count <= 2 * 1024 * 1024 else { throw SubtitleVideoError.invalid("字幕文件过大。") }
    return ["name": url.lastPathComponent, "bytes": FlutterStandardTypedData(bytes: data)]
  }

  private func sourceReference(_ url: URL) async throws -> [String: Any] {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    var source = try fingerprint(url)
    let cloud = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
    if cloud?.isUbiquitousItem == true && cloud?.ubiquitousItemDownloadingStatus == .notDownloaded {
      throw SubtitleVideoError.invalid("请先在 Finder 中下载此视频，再添加到字幕工作台。")
    }
    do { _ = try await LumioSubtitleVideoExporter.probe(AVURLAsset(url: url)) }
    catch { source["probeWarning"] = error.localizedDescription }
    source["name"] = url.lastPathComponent
    source["path"] = url.path
    source["bookmark"] = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
    return source
  }

  private func fingerprint(_ url: URL) throws -> [String: Any] {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { throw SubtitleVideoError.invalid("请选择可读取的本地文件。") }
    return ["size": Int64(size), "modifiedMs": Int64(modified.timeIntervalSince1970 * 1000)]
  }

  private func decodeDocument(_ args: [String: Any]) throws -> SubtitleRenderDocument {
    let data = try JSONSerialization.data(withJSONObject: args["cues"] ?? [])
    guard data.count <= 8 * 1024 * 1024 else { throw SubtitleVideoError.invalid("字幕数据超过 8 MiB。") }
    let cues = try JSONDecoder().decode([SubtitleVideoCue].self, from: data)
    let styleData = try JSONSerialization.data(withJSONObject: args["style"] ?? [:])
    let style = try JSONDecoder().decode(SubtitleVideoStyle.self, from: styleData)
    return try SubtitleRenderDocument(cues: cues, style: style)
  }

  private func closePreview() {
    player?.pause(); texture.detach(); player?.replaceCurrentItem(with: nil)
    player = nil; sourceURL = nil; probe = nil; sessionID = nil
    accessURL?.stopAccessingSecurityScopedResource(); accessURL = nil
  }

  private func show(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
    await withCheckedContinuation { continuation in
      panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
    }
  }

  private func projectURL(_ value: Any?) throws -> URL {
    guard let id = value as? String, UUID(uuidString: id) != nil else { throw SubtitleVideoError.invalid("项目 ID 无效。") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(id.lowercased() + ".json")
  }

  private func projectFiles() throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
  }

  private func readProject(_ url: URL) throws -> [String: Any] {
    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1024 * 1024,
          let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw SubtitleVideoError.invalid("项目文件损坏或过大。") }
    return value
  }

  private func write(_ value: [String: Any], _ url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard data.count <= 8 * 1024 * 1024 else { throw SubtitleVideoError.invalid("单个项目不能超过 8 MiB。") }
    try data.write(to: url, options: .atomic)
  }
}
