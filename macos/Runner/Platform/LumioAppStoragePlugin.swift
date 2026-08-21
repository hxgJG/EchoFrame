import FlutterMacOS
import Foundation

final class LumioAppStoragePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.hxg.lumio.storage")
  private let stateDirectory = LumioPaths.applicationSupportDirectory
    .appendingPathComponent("state", isDirectory: true)
  private let backupDirectory = LumioPaths.applicationSupportDirectory
    .appendingPathComponent("backups", isDirectory: true)

  static func register(with registrar: FlutterPluginRegistrar) {
    // Registered by LumioMacOSPlugins so the native services can share state.
  }

  init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(
      name: "lumio/app_storage",
      binaryMessenger: registrar.messenger
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
    registrar.addMethodCallDelegate(self, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
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
