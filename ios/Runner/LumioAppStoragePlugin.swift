import Flutter
import UIKit

/// iOS 端应用状态存储：与 Android/macOS 相同的分区 JSON 协议。
///
/// 分区文件位于应用沙盒的 Application Support 下，备份文件另存一份，
/// 供“创建备份 / 恢复最近备份”使用。iOS 的平台能力模型暂不开放
/// 跨端迁移备份（portable backup）与 WebDAV，相关通道不在此注册。
final class LumioAppStoragePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.hxg.lumio.storage")
  private let root = LumioAppPaths.applicationSupport
  private var stateDirectory: URL { root.appendingPathComponent("state", isDirectory: true) }
  private var backupDirectory: URL { root.appendingPathComponent("backups", isDirectory: true) }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LumioAppStoragePlugin(
      messenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: instance.channel)
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "lumio/app_storage",
      binaryMessenger: messenger
    )
    super.init()
    try? FileManager.default.createDirectory(
      at: stateDirectory,
      withIntermediateDirectories: true
    )
    try? FileManager.default.createDirectory(
      at: backupDirectory,
      withIntermediateDirectories: true
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "loadPartition":
      guard let partition = partition(from: call.arguments) else {
        result(invalidArguments("缺少存储分区。"))
        return
      }
      queue.async { [weak self] in
        guard let self else { return }
        self.finish(result, value: self.loadJSON(from: self.partitionURL(partition)))
      }
    case "savePartition":
      guard let arguments = call.arguments as? [String: Any],
            let partition = arguments["partition"] as? String,
            let value = arguments["value"] as? [String: Any] else {
        result(invalidArguments("存储分区或内容无效。"))
        return
      }
      queue.async { [weak self] in
        guard let self else { return }
        do {
          try self.writeJSON(value, to: self.partitionURL(partition))
          self.finish(result, value: nil)
        } catch {
          self.finish(result, value: self.storageError(error))
        }
      }
    case "createBackup":
      guard let value = call.arguments as? [String: Any] else {
        result(invalidArguments("备份内容无效。"))
        return
      }
      queue.async { [weak self] in
        guard let self else { return }
        do {
          let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
          let url = self.backupDirectory
            .appendingPathComponent("lumio-backup-\(timestamp).json")
          try self.writeJSON(value, to: url)
          self.pruneBackups(keeping: 5)
          self.finish(result, value: ["path": url.path, "updatedAtMs": timestamp])
        } catch {
          self.finish(result, value: self.storageError(error))
        }
      }
    case "restoreLatestBackup":
      queue.async { [weak self] in
        guard let self else { return }
        self.finish(result, value: self.latestBackupURL().flatMap { self.loadJSON(from: $0) })
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
    return dictionary
  }

  private func writeJSON(_ value: [String: Any], to url: URL) throws {
    guard JSONSerialization.isValidJSONObject(value) else {
      throw CocoaError(.propertyListWriteInvalid)
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try? mutableURL.setResourceValues(values)
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

  /// 只保留最近若干份备份；iOS 上用户无法手动清理沙盒文件。
  private func pruneBackups(keeping limit: Int) {
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: backupDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    let sorted = urls
      .filter { $0.pathExtension.lowercased() == "json" }
      .sorted { lhs, rhs in
        let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? Date.distantPast
        let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? Date.distantPast
        return left > right
      }
    for url in sorted.dropFirst(limit) {
      try? FileManager.default.removeItem(at: url)
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

/// iOS 沙盒内的固定目录。与 macOS 使用同样的 `Lumio` 子目录约定，
/// 便于两端共用备份与迁移文档。
enum LumioAppPaths {
  static let fileManager = FileManager.default

  static var applicationSupport: URL {
    let base = try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = (base ?? fileManager.temporaryDirectory)
      .appendingPathComponent("Lumio", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
