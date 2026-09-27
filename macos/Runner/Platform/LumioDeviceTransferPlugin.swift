import Cocoa
import CryptoKit
import FlutterMacOS
import Security

final class LumioDeviceTransferPlugin: NSObject, FlutterPlugin {
  private struct Lease {
    let handle: FileHandle
    let root: URL?
    let size: UInt64
    let chunks: [Data]
  }
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.hxg.lumio.transfer.files")
  private let bookmarks: SecurityScopedBookmarkStore
  private weak var window: NSWindow?
  private var leases: [String: Lease] = [:]
  private let blockSize = 256 * 1024
  private let identityService = "com.hxg.lumio.device-transfer.identity.v1"
  private var transferLock: Int32 = -1

  static func register(with registrar: FlutterPluginRegistrar) {}

  init(registrar: FlutterPluginRegistrar, bookmarks: SecurityScopedBookmarkStore, window: NSWindow) {
    self.bookmarks = bookmarks
    self.window = window
    channel = FlutterMethodChannel(name: "lumio/device_transfer", binaryMessenger: registrar.messenger)
    super.init()
    registrar.addMethodCallDelegate(self, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "exportReceived" {
      exportReceived(call.arguments, result: result)
      return
    }
    queue.async { [self] in
      do {
        let args = call.arguments as? [String: Any] ?? [:]
        let value: Any?
        switch call.method {
        case "deviceInfo": value = deviceInfo()
        case "acquireTransferLock":
          try acquireTransferLock()
          value = nil
        case "loadIdentity": value = try loadIdentity()
        case "saveIdentity":
          guard let text = args["value"] as? String, text.utf8.count <= 32768 else { throw CocoaError(.fileReadCorruptFile) }
          try saveIdentity(text)
          value = nil
        case "openMedia":
          guard let path = args["path"] as? String else { throw CocoaError(.fileReadNoSuchFile) }
          value = try openMedia(path)
        case "readMedia":
          guard let id = args["handle"] as? String,
                let offset = args["offset"] as? NSNumber,
                let length = args["length"] as? Int else { throw CocoaError(.fileReadCorruptFile) }
          value = FlutterStandardTypedData(bytes: try readMedia(id, offset: offset.int64Value, length: length))
        case "closeMedia":
          if let id = args["handle"] as? String { closeMedia(id) }
          value = nil
        case "closeAll":
          for id in Array(leases.keys) { closeMedia(id) }
          value = nil
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "transferPlatformError", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func identityQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: identityService,
     kSecAttrAccount as String: "device",
     kSecAttrSynchronizable as String: false]
  }

  private func deviceInfo() -> [String: String] {
    var size: size_t = 0
    var model = "Mac"
    if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size <= 256 {
      var buffer = [CChar](repeating: 0, count: size)
      if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 {
        model = String(cString: buffer)
      }
    }
    return ["type": "电脑", "brand": "Apple", "model": String(model.prefix(80))]
  }

  private func acquireTransferLock() throws {
    if transferLock >= 0 { return }
    let root = try receivedRoot().deletingLastPathComponent()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fd = open(root.appendingPathComponent(".owner").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw NSError(domain: "Lumio", code: 4, userInfo: [NSLocalizedDescriptionKey: "另一个忆光进程正在使用设备互传，请先关闭另一个窗口进程。"])
    }
    transferLock = fd
  }

  private func loadIdentity() throws -> String? {
    var query = identityQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
          let text = String(data: data, encoding: .utf8) else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return text
  }

  private func saveIdentity(_ text: String) throws {
    var query = identityQuery()
    query[kSecValueData as String] = Data(text.utf8)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }

  private func receivedRoot() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
      .appendingPathComponent("Lumio/device_transfer/received", isDirectory: true)
      .resolvingSymlinksInPath()
  }

  private func privateFile(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let root = try receivedRoot()
    guard url.resolvingSymlinksInPath().path == url.path,
          url.deletingLastPathComponent().path == root.path,
          (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
      throw CocoaError(.fileReadNoPermission)
    }
    return url
  }

  private func openMedia(_ path: String) throws -> [String: Any] {
    guard leases.count < 4 else { throw NSError(domain: "Lumio", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "同时打开的传输文件过多。请重试。"]) }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    var access: URL?
    if (try? privateFile(path)) == nil {
      access = bookmarks.startAccess(forFilePath: path)
      guard let root = access,
            url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
        access?.stopAccessingSecurityScopedResource()
        throw CocoaError(.fileReadNoPermission)
      }
    }
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
            values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current else {
        throw CocoaError(.fileReadNoPermission)
      }
      let handle = try FileHandle(forReadingFrom: url)
      do {
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        var chunks: [Data] = []
        while let bytes = try handle.read(upToCount: blockSize), !bytes.isEmpty {
          guard chunks.count < 262144 else { throw NSError(domain: "Lumio", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "单个传输文件暂限 64 GiB。"] ) }
          hash.update(data: bytes)
          chunks.append(Data(SHA256.hash(data: bytes)))
        }
        guard try handle.offset() == size else { throw CocoaError(.fileReadCorruptFile) }
        let id = UUID().uuidString
        leases[id] = Lease(handle: handle, root: access, size: size, chunks: chunks)
        return ["handle": id, "size": size, "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined(),
                "extension": url.pathExtension.lowercased()]
      } catch { try? handle.close(); throw error }
    } catch { access?.stopAccessingSecurityScopedResource(); throw error }
  }

  private func readMedia(_ id: String, offset: Int64, length: Int) throws -> Data {
    guard let lease = leases[id], offset >= 0, length > 0, length <= blockSize,
          UInt64(offset) <= lease.size, UInt64(length) <= lease.size - UInt64(offset) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var output = Data()
    let first = Int(offset) / blockSize
    let last = (Int(offset) + length - 1) / blockSize
    for index in first...last {
      guard index < lease.chunks.count else { throw CocoaError(.fileReadCorruptFile) }
      let start = UInt64(index * blockSize)
      let count = Int(min(UInt64(blockSize), lease.size - start))
      try lease.handle.seek(toOffset: start)
      guard let bytes = try lease.handle.read(upToCount: count), bytes.count == count,
            Data(SHA256.hash(data: bytes)) == lease.chunks[index] else {
        throw NSError(domain: "Lumio", code: 3, userInfo: [NSLocalizedDescriptionKey: "来源文件已改变，请重新开启共享。"])
      }
      let from = max(0, Int(offset) - Int(start))
      let to = min(count, Int(offset) + length - Int(start))
      output.append(bytes.subdata(in: from..<to))
    }
    return output
  }

  private func closeMedia(_ id: String) {
    guard let lease = leases.removeValue(forKey: id) else { return }
    try? lease.handle.close()
    lease.root?.stopAccessingSecurityScopedResource()
  }

  private func exportReceived(_ arguments: Any?, result: @escaping FlutterResult) {
    do {
      guard let args = arguments as? [String: Any], let path = args["path"] as? String else {
        throw CocoaError(.fileReadNoSuchFile)
      }
      let source = try privateFile(path)
      let panel = NSSavePanel()
      let title = (args["name"] as? String ?? "已接收文件")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
      panel.nameFieldStringValue = String(title.prefix(100)) + "." + source.pathExtension
      let completion: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let target = panel.url else { result(false); return }
        let access = target.startAccessingSecurityScopedResource()
        self.queue.async {
          defer { if access { target.stopAccessingSecurityScopedResource() } }
          do {
            guard source.standardizedFileURL != target.standardizedFileURL else { throw CocoaError(.fileWriteFileExists) }
            // The save panel owns overwrite confirmation. Atomic replacement does
            // not remove a user's existing export until the new copy is complete.
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".lumio-export-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            if FileManager.default.fileExists(atPath: target.path) {
              _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: target) }
            DispatchQueue.main.async { result(true) }
          } catch { DispatchQueue.main.async { result(FlutterError(code: "exportFailed", message: error.localizedDescription, details: nil)) } }
        }
      }
      if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
      else { completion(panel.runModal()) }
    } catch { result(FlutterError(code: "exportFailed", message: error.localizedDescription, details: nil)) }
  }
}
