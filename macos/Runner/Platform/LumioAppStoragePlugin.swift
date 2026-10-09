import FlutterMacOS
import Cocoa
import UniformTypeIdentifiers

final class LumioAppStoragePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let portableChannel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.hxg.lumio.storage")
  private let stateDirectory = LumioPaths.applicationSupportDirectory
    .appendingPathComponent("state", isDirectory: true)
  private let backupDirectory = LumioPaths.applicationSupportDirectory
    .appendingPathComponent("backups", isDirectory: true)

  static func register(with registrar: FlutterPluginRegistrar) {
    // Registered by LumioMacOSPlugins so the native services can share state.
  }

  init(registrar: FlutterPluginRegistrar) {
    portableChannel = FlutterMethodChannel(name: "lumio/portable_backup", binaryMessenger: registrar.messenger)
    channel = FlutterMethodChannel(
      name: "lumio/app_storage",
      binaryMessenger: registrar.messenger
    )
    super.init()
    try? recoverPortableCommit()
    try? FileManager.default.createDirectory(
      at: stateDirectory,
      withIntermediateDirectories: true
    )
    try? FileManager.default.createDirectory(
      at: backupDirectory,
      withIntermediateDirectories: true
    )
    registrar.addMethodCallDelegate(self, channel: channel)
    registrar.addMethodCallDelegate(self, channel: portableChannel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "loadWebDavConfiguration", "saveWebDavConfiguration":
      let args = call.arguments as? [String: Any] ?? [:]
      queue.async { [weak self] in
        guard let self else { return }
        do {
          let directory = LumioPaths.applicationSupportDirectory.appendingPathComponent("webdav_backup", isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
          try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
          let file = directory.appendingPathComponent("configuration.json")
          if call.method == "saveWebDavConfiguration" {
            if let config = args["configuration"] as? [String: Any] {
              let data = try JSONSerialization.data(withJSONObject: config)
              guard data.count <= 16384 else { throw CocoaError(.fileWriteInvalidFileName) }
              try data.write(to: file, options: .atomic)
              try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } else if FileManager.default.fileExists(atPath: file.path) {
              try FileManager.default.removeItem(at: file)
            }
            self.finish(result, value: nil)
          } else {
            if FileManager.default.fileExists(atPath: file.path) {
              let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
              guard bytes <= 16384 else { throw CocoaError(.fileReadCorruptFile) }
            }
            self.finish(result, value: FileManager.default.fileExists(atPath: file.path) ? try JSONSerialization.jsonObject(with: Data(contentsOf: file)) : nil)
          }
        } catch {
          self.finish(result, value: self.invalidArguments("无法读写本机云备份配置。"))
        }
      }
    case "environment":
      do {
        let root = try portableRoot()
        let support = LumioPaths.applicationSupportDirectory.standardizedFileURL
        let free = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
        result(["temporaryRoot": root.path, "managedRoots": [support.path],
                "receivedRoot": support.appendingPathComponent("device_transfer/received").path,
                "availableBytes": free?.int64Value ?? 0])
      } catch { result(storageError(error)) }
    case "export", "import":
      let args = call.arguments as? [String: Any] ?? [:]
      let exporting = call.method == "export"
      let panel: NSSavePanel = exporting ? NSSavePanel() : NSOpenPanel()
      panel.allowedContentTypes = [.zip]
      if let open = panel as? NSOpenPanel {
        open.canChooseDirectories = false; open.allowsMultipleSelection = false
        open.message = "选择 Lumio 数据备份；新版支持跨端恢复，旧版备份仅支持原平台。"
      } else {
        panel.nameFieldStringValue = args["name"] as? String ?? "Lumio-数据备份.zip"
        panel.message = "请保存到应用外部的目录。卸载前请确认备份文件已保存。"
      }
      guard panel.runModal() == .OK, let selected = panel.url else { result(nil); return }
      queue.async { [weak self] in
        guard let self else { return }
        var temporary: URL?
        let access = selected.startAccessingSecurityScopedResource()
        defer { if access { selected.stopAccessingSecurityScopedResource() } }
        do {
          if exporting {
            let root = try self.portableRoot().resolvingSymlinksInPath()
            guard let path = args["path"] as? String else { throw CocoaError(.fileReadInvalidFileName) }
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard source.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            // Never delete a selected existing file before a successful copy.
            guard !FileManager.default.fileExists(atPath: selected.path) else {
              throw NSError(domain: "LumioBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "请使用新的备份文件名，避免覆盖已有备份。"])
            }
            try FileManager.default.copyItem(at: source, to: selected)
            self.finish(result, value: selected.path)
          } else {
            let size = try selected.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= 2 * 1024 * 1024 * 1024 else {
              throw NSError(domain: "LumioBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: "备份不是普通文件或超过 2 GiB。"])
            }
            let root = try self.portableRoot()
            let free = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
            guard (free?.int64Value ?? 0) > Int64(bytes) + 16 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            let directory = root.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            temporary = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let destination = directory.appendingPathComponent("backup.zip")
            try FileManager.default.copyItem(at: selected, to: destination)
            self.finish(result, value: destination.path)
          }
        } catch {
          if let temporary { try? FileManager.default.removeItem(at: temporary) }
          self.finish(result, value: self.storageError(error))
        }
      }
    case "commit":
      guard let state = (call.arguments as? [String: Any])?["state"] as? [String: Any] else {
        result(invalidArguments("备份状态无效。")); return
      }
      guard MainActor.assumeIsolated({ LumioMacOSPlugins.subtitleWorkbench?.canRestoreBackup != false }) else {
        result(invalidArguments("请关闭字幕工作台并等待字幕导出结束，再导入备份。")); return
      }
      queue.async { [weak self] in
        guard let self else { return }
        do { try self.commitPortableState(state); self.finish(result, value: nil) }
        catch { self.finish(result, value: self.storageError(error)) }
      }
    case "transferStorage":
      queue.async { [weak self] in
        do {
          guard let self else { return }
          // Receiving media must never silently fall back to a cache/temp path.
          let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
          )
          let root = support.appendingPathComponent("Lumio/device_transfer", isDirectory: true)
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          for name in ["jobs", "partial"] {
            var directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
          }
          let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
          guard let available = attributes[.systemFreeSize] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
          }
          self.finish(result, value: ["path": root.path, "availableBytes": available.int64Value])
        } catch {
          self?.finish(result, value: self?.storageError(error))
        }
      }
    case "loadPartition":
      guard let partition = partition(from: call.arguments) else {
        result(invalidArguments("缺少存储分区。"))
        return
      }
      queue.async { [weak self] in
        self?.finish(result, value: self?.loadJSON(from: self?.partitionURL(partition)))
      }
    case "savePartition":
      guard let arguments = call.arguments as? [String: Any],
            let partition = arguments["partition"] as? String,
            let value = arguments["value"] as? [String: Any] else {
        result(invalidArguments("存储分区或内容无效。"))
        return
      }
      queue.async { [weak self] in
        do {
          guard let self else { return }
          try self.writeJSON(value, to: self.partitionURL(partition))
          self.finish(result, value: nil)
        } catch {
          self?.finish(result, value: self?.storageError(error))
        }
      }
    case "createBackup":
      guard let value = call.arguments as? [String: Any] else {
        result(invalidArguments("备份内容无效。"))
        return
      }
      queue.async { [weak self] in
        do {
          guard let self else { return }
          let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
          let url = self.backupDirectory
            .appendingPathComponent("lumio-backup-\(timestamp).json")
          try self.writeJSON(value, to: url)
          self.finish(result, value: ["path": url.path, "updatedAtMs": timestamp])
        } catch {
          self?.finish(result, value: self?.storageError(error))
        }
      }
    case "restoreLatestBackup":
      queue.async { [weak self] in
        guard let self else { return }
        self.finish(result, value: self.latestBackupURL().flatMap(self.loadJSON(from:)))
      }
    case "latestBackup":
      queue.async { [weak self] in
        guard let self, let url = self.latestBackupURL() else {
          self?.finish(result, value: nil)
          return
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let date = values?.contentModificationDate ?? Date.distantPast
        self.finish(
          result,
          value: [
            "path": url.path,
            "updatedAtMs": Int64(date.timeIntervalSince1970 * 1000),
          ]
        )
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func partition(from arguments: Any?) -> String? {
    (arguments as? [String: Any])?["partition"] as? String
  }

  private func portableRoot() throws -> URL {
    let root = LumioPaths.applicationSupportDirectory.appendingPathComponent("portable_backup", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private var commitRoot: URL {
    LumioPaths.applicationSupportDirectory.appendingPathComponent("portable_commit", isDirectory: true)
  }

  private func recoverPortableCommit() throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: commitRoot.path) else { return }
    if manager.fileExists(atPath: commitRoot.appendingPathComponent("completed").path) {
      try manager.removeItem(at: commitRoot)
      return
    }
    for name in ["state", "subtitle_projects"] {
      let target = LumioPaths.applicationSupportDirectory.appendingPathComponent(name)
      let old = commitRoot.appendingPathComponent("old-\(name)")
      let absent = commitRoot.appendingPathComponent("absent-\(name)")
      if manager.fileExists(atPath: old.path) {
        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        try manager.moveItem(at: old, to: target)
      } else if manager.fileExists(atPath: absent.path), manager.fileExists(atPath: target.path) {
        try manager.removeItem(at: target)
      }
    }
    try manager.removeItem(at: commitRoot)
  }

  private func commitPortableState(_ value: [String: Any]) throws {
    let manager = FileManager.default
    try recoverPortableCommit()
    try manager.createDirectory(at: commitRoot, withIntermediateDirectories: false)
    do {
      let libraryKeys: Set<String> = ["schemaVersion", "audioItems", "videoItems", "receivedMedia", "lyricLibrary", "lyricLibraryUndo"]
      let excluded = libraryKeys.union(["playlists", "subtitleProjects"])
      let stagedState = commitRoot.appendingPathComponent("new-state")
      let stagedProjects = commitRoot.appendingPathComponent("new-subtitle_projects")
      try manager.createDirectory(at: stagedState, withIntermediateDirectories: false)
      try manager.createDirectory(at: stagedProjects, withIntermediateDirectories: false)
      try writeJSON(value.filter { libraryKeys.contains($0.key) }, to: stagedState.appendingPathComponent("library.json"))
      try writeJSON(value.filter { $0.key == "schemaVersion" || $0.key == "playlists" }, to: stagedState.appendingPathComponent("playlists.json"))
      try writeJSON(value.filter { !excluded.contains($0.key) || $0.key == "schemaVersion" }, to: stagedState.appendingPathComponent("session.json"))
      let projects = value["subtitleProjects"] as? [[String: Any]] ?? []
      guard projects.count <= 200 else { throw CocoaError(.fileReadCorruptFile) }
      var ids: Set<String> = []
      for project in projects {
        guard let id = project["id"] as? String, UUID(uuidString: id) != nil, ids.insert(id).inserted,
              project["schemaVersion"] as? Int == 1 else { throw CocoaError(.fileReadCorruptFile) }
        try writeJSON(project, to: stagedProjects.appendingPathComponent("\(id).json"))
      }
      for name in ["state", "subtitle_projects"] {
        let target = LumioPaths.applicationSupportDirectory.appendingPathComponent(name)
        if manager.fileExists(atPath: target.path) {
          try manager.moveItem(at: target, to: commitRoot.appendingPathComponent("old-\(name)"))
        } else {
          try Data().write(to: commitRoot.appendingPathComponent("absent-\(name)"))
        }
        try manager.moveItem(at: commitRoot.appendingPathComponent("new-\(name)"), to: target)
      }
      // A completed marker distinguishes committed state from an interrupted swap.
      try Data().write(to: commitRoot.appendingPathComponent("completed"), options: .atomic)
    } catch { try recoverPortableCommit(); throw error }
    try? manager.removeItem(at: commitRoot)
  }

  private func partitionURL(_ partition: String) -> URL {
    stateDirectory.appendingPathComponent("\(partition).json")
  }

  private func loadJSON(from optionalURL: URL?) -> [String: Any]? {
    guard let url = optionalURL,
          let data = try? Data(contentsOf: url),
          let value = try? JSONSerialization.jsonObject(with: data),
          let dictionary = value as? [String: Any] else {
      return nil
    }
    return LumioMetadataRepair.library(dictionary)
  }

  private func writeJSON(_ value: [String: Any], to url: URL) throws {
    guard JSONSerialization.isValidJSONObject(value) else {
      throw CocoaError(.propertyListWriteInvalid)
    }
    let data = try JSONSerialization.data(
      withJSONObject: value,
      options: [.sortedKeys]
    )
    try data.write(to: url, options: .atomic)
  }

  private func latestBackupURL() -> URL? {
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: backupDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    return urls
      .filter { $0.pathExtension.lowercased() == "json" }
      .max { lhs, rhs in
        let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? Date.distantPast
        let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? Date.distantPast
        return left < right
      }
  }

  private func finish(_ result: @escaping FlutterResult, value: Any?) {
    DispatchQueue.main.async {
      result(value)
    }
  }

  private func invalidArguments(_ message: String) -> FlutterError {
    FlutterError(code: "invalidArguments", message: message, details: nil)
  }

  private func storageError(_ error: Error) -> FlutterError {
    FlutterError(code: "storageError", message: error.localizedDescription, details: nil)
  }
}
