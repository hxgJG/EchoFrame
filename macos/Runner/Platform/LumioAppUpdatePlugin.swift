import Cocoa
import CryptoKit
import FlutterMacOS

final class LumioAppUpdatePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.hxg.lumio.app-update")
  private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Lumio/updates", isDirectory: true)

  static func register(with registrar: FlutterPluginRegistrar) {}
  init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(name: "lumio/app_update", binaryMessenger: registrar.messenger)
    super.init()
    registrar.addMethodCallDelegate(self, channel: channel)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ["environment", "validate", "open"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
    queue.async {
      do {
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        if call.method == "environment" {
          let os = ProcessInfo.processInfo.operatingSystemVersion
          #if arch(arm64)
          let architecture = "arm64"
          #else
          let architecture = "x86_64"
          #endif
          let free = try FileManager.default.attributesOfFileSystem(forPath: self.root.path)[.systemFreeSize] as? NSNumber
          let environment: [String: Any] = ["platform": "macos", "architecture": architecture,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            "buildNumber": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            "osVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "cacheRoot": self.root.resolvingSymlinksInPath().path, "availableBytes": free?.int64Value ?? 0]
          DispatchQueue.main.async { result(environment) }
        } else {
          guard let args = call.arguments as? [String: Any] else { throw self.failure("更新参数缺失。") }
          let file = try self.validate(args)
          DispatchQueue.main.async {
            if call.method == "open" { NSWorkspace.shared.activateFileViewerSelecting([file]); result("opened") }
            else { result(nil) }
          }
        }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "update_validation", message: error.localizedDescription, details: nil)) }
      }
    }
  }
  private func failure(_ message: String) -> NSError {
    NSError(domain: "LumioUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  private func validate(_ args: [String: Any]) throws -> URL {
    guard let path = args["path"] as? String, let expected = args["sha256"] as? String,
      let size = args["size"] as? NSNumber, let build = args["buildNumber"] as? NSNumber,
      build.intValue > (Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0)
    else { throw failure("更新包参数或版本不正确。") }
    let file = URL(fileURLWithPath: path).standardizedFileURL
    let resolved = file.resolvingSymlinksInPath()
    guard file.path == resolved.path,
      resolved.deletingLastPathComponent() == root.resolvingSymlinksInPath(),
      resolved.lastPathComponent.range(of: #"^update-[0-9]+-[0-9]+\.zip$"#, options: .regularExpression) != nil
    else { throw failure("更新包路径不在专用缓存目录。") }
    let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, size.int64Value > 0, size.int64Value <= 1073741824,
      Int64(values.fileSize ?? 0) == size.int64Value else { throw failure("更新包长度校验失败。") }
    let input = try FileHandle(forReadingFrom: resolved)
    defer { try? input.close() }
    var hash = SHA256()
    while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw failure("更新包哈希校验失败。") }
    return resolved
  }
}
