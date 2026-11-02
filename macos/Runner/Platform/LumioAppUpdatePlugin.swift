import Cocoa
import CryptoKit
import FlutterMacOS
import Network
import Sparkle
import Security

final class LumioAppUpdatePlugin: NSObject, FlutterPlugin, SPUUpdaterDelegate {
  private let channel: FlutterMethodChannel
  private let lifecycle: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.hxg.lumio.app-update")
  private var networkProbe: LumioUpdateNetworkProbe?
  private var updaterController: SPUStandardUpdaterController?
  private var localServer: LumioLocalUpdateServer?
  private var pendingInstall: (() -> Void)?
  private var pendingArguments: [String: Any]?
  private(set) var preparationFailed = false
  private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Lumio/updates", isDirectory: true)

  static func register(with registrar: FlutterPluginRegistrar) {}
  init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(name: "lumio/app_update", binaryMessenger: registrar.messenger)
    lifecycle = FlutterMethodChannel(name: "lumio/app_update_lifecycle", binaryMessenger: registrar.messenger)
    super.init()
    registrar.addMethodCallDelegate(self, channel: channel)
    registrar.addMethodCallDelegate(self, channel: lifecycle)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ["environment", "validate", "open", "probeNetwork", "cancelProbe", "launchSucceeded"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
    queue.async {
      do {
        if call.method == "cancelProbe" {
          self.networkProbe?.cancel()
          DispatchQueue.main.async { result(nil) }
          return
        }
        if call.method == "probeNetwork" {
          guard let args = call.arguments as? [String: Any], let raw = args["url"] as? String,
            let url = URL(string: raw), LumioUpdateNetworkProbe.trusted(url)
          else { throw self.failure("诊断地址不在可信 GitHub HTTPS 域名内。") }
          self.networkProbe?.cancel()
          let probe = LumioUpdateNetworkProbe()
          self.networkProbe = probe
          probe.start(url) { report in
            self.queue.async {
              if self.networkProbe === probe { self.networkProbe = nil }
            }
            DispatchQueue.main.async { result(report) }
          }
          return
        }
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        if call.method == "launchSucceeded" {
          try self.cleanupCompletedUpdate()
          DispatchQueue.main.async { result(nil) }
          return
        }
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
            if call.method == "open" { self.beginInstall(file, arguments: args, result: result) }
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
      resolved.lastPathComponent.range(of: #"^update-[0-9]+-(?:[0-9]+|[a-f0-9]{64})\.zip$"#, options: .regularExpression) != nil
    else { throw failure("更新包路径不在专用缓存目录。") }
    let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, size.int64Value > 0, size.int64Value <= 1073741824,
      Int64(values.fileSize ?? 0) == size.int64Value else { throw failure("更新包长度校验失败。") }
    let input = try FileHandle(forReadingFrom: resolved)
    defer { try? input.close() }
    var hash = SHA256()
    while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw failure("更新包哈希校验失败。") }
    if let signature = args["sparkleSignature"] as? String {
      guard let publicString = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
        let publicData = Data(base64Encoded: publicString),
        let signatureData = Data(base64Encoded: signature), signatureData.count == 64,
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData),
        key.isValidSignature(signatureData, for: try Data(contentsOf: resolved, options: .mappedIfSafe))
      else { throw failure("Mac 安装包独立签名不正确，已停止安装。") }
    }
    return resolved
  }

  private func beginInstall(_ file: URL, arguments: [String: Any], result: @escaping FlutterResult) {
    guard arguments["sparkleSignature"] is String else {
      result(FlutterError(code: "update_legacy_package", message: "此旧发布包没有 Sparkle 安装签名。请等待新的正式发布，或从发布页手动安装；不会覆盖当前程序。", details: nil))
      return
    }
    guard LumioMacOSPlugins.subtitleWorkbench?.hasExport != true else {
      result(FlutterError(code: "update_export_busy", message: "视频仍在导出，请完成或取消导出后再安装。", details: nil))
      return
    }
    if let handler = pendingInstall {
      prepareForRelaunch(handler)
      result("installing")
      return
    }
    if let updater = updaterController?.updater, updater.sessionInProgress {
      updater.checkForUpdates()
      result("installing")
      return
    }
    do {
      let server = try LumioLocalUpdateServer(archive: file, arguments: arguments)
      localServer?.stop()
      localServer = server
      pendingArguments = arguments
      server.start { error in
        DispatchQueue.main.async {
          if let error {
            server.stop()
            result(FlutterError(code: "update_local_transfer", message: error.localizedDescription, details: nil))
            return
          }
          do {
            if self.updaterController == nil {
              let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
              self.updaterController = controller
              try controller.updater.start()
            }
            self.updaterController?.checkForUpdates(nil)
            result("installing")
          } catch {
            server.stop()
            result(FlutterError(code: "update_sparkle", message: error.localizedDescription, details: nil))
          }
        }
      }
    } catch {
      result(FlutterError(code: "update_sparkle", message: error.localizedDescription, details: nil))
    }
  }

  func feedURLString(for updater: SPUUpdater) -> String? { localServer?.feedURL?.absoluteString }

  func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
    updateCheck: SPUUpdateCheck) throws {
    guard updateItem.versionString == (pendingArguments?["buildNumber"] as? NSNumber)?.stringValue,
      updateItem.fileURL == localServer?.archiveURL else {
      throw failure("安装目标与已校验的下载包不一致。")
    }
  }

  func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
    pendingInstall = installHandler
    prepareForRelaunch(installHandler)
    return true
  }

  private func prepareForRelaunch(_ handler: @escaping () -> Void) {
    preparationFailed = true
    lifecycle.invokeMethod("prepareForInstall", arguments: nil) { response in
      if let error = response as? FlutterError {
        self.preparationFailed = true
        let alert = NSAlert()
        alert.messageText = "暂时无法安装更新"
        alert.informativeText = error.message ?? "保存应用数据失败，请稍后再次点击安装。"
        alert.runModal()
        return
      }
      if response as AnyObject? === FlutterMethodNotImplemented as AnyObject {
        self.preparationFailed = true
        return
      }
      guard let args = self.pendingArguments else { return }
      self.queue.async {
        do {
          guard let build = args["buildNumber"] as? NSNumber, let hash = args["sha256"] as? String else {
            throw self.failure("安装记录缺失。")
          }
          let rollbackName = "rollback-\(build)-\(hash)"
          let rollback = self.root.appendingPathComponent(rollbackName, isDirectory: true)
          guard rollback == rollback.resolvingSymlinksInPath() else { throw self.failure("回退目录异常。") }
          if !FileManager.default.fileExists(atPath: rollback.path) {
            try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: false)
          }
          let backup = rollback.appendingPathComponent("Lumio.app", isDirectory: true)
          if !FileManager.default.fileExists(atPath: backup.path) {
            let copying = rollback.appendingPathComponent("Lumio.copying.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: copying.path) {
              try FileManager.default.removeItem(at: copying)
            }
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: copying)
            try FileManager.default.moveItem(at: copying, to: backup)
          }
          var code: SecStaticCode?
          guard SecStaticCodeCreateWithPath(backup as CFURL, [], &code) == errSecSuccess,
            let code, SecStaticCodeCheckValidity(code,
              SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess
          else { throw self.failure("回退副本完整性验证失败，未开始替换当前应用。") }
          var receipt = args
          receipt["rollbackDirectory"] = rollbackName
          receipt["applicationPath"] = Bundle.main.bundleURL.standardizedFileURL.path
          try JSONSerialization.data(withJSONObject: receipt).write(
            to: self.root.appendingPathComponent("pending-install.json"), options: .atomic)
          DispatchQueue.main.async {
            self.preparationFailed = false
            self.pendingInstall = nil
            handler()
          }
        } catch {
          DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "无法保存更新记录，安装尚未开始"
            alert.informativeText = error.localizedDescription
            alert.runModal()
          }
        }
      }
    }
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    localServer?.stop()
    localServer = nil
    pendingInstall = nil
    preparationFailed = false
  }

  private func cleanupCompletedUpdate() throws {
    let receiptURL = root.appendingPathComponent("pending-install.json")
    guard FileManager.default.fileExists(atPath: receiptURL.path) else { return }
    let data = try Data(contentsOf: receiptURL)
    guard data.count < 8192, let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let target = receipt["buildNumber"] as? Int,
      let current = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"),
      current >= target,
      receipt["applicationPath"] as? String == Bundle.main.bundleURL.standardizedFileURL.path,
      let expected = receipt["sha256"] as? String,
      expected.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
      let path = receipt["path"] as? String else { return }
    let archive = root.appendingPathComponent("update-\(target)-\(expected).zip").standardizedFileURL
    guard archive.path == path, archive == archive.resolvingSymlinksInPath() else { return }
    // 仅新版完成 Flutter 首帧和资料恢复后清理这一份安装包；旧版或失败重试不清理。
    if FileManager.default.fileExists(atPath: archive.path) {
      let values = try archive.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { return }
      try FileManager.default.removeItem(at: archive)
    }
    if receipt["rollbackDirectory"] as? String == "rollback-\(target)-\(expected)" {
      let rollback = root.appendingPathComponent("rollback-\(target)-\(expected)", isDirectory: true)
      guard rollback == rollback.resolvingSymlinksInPath() else { return }
      if FileManager.default.fileExists(atPath: rollback.path) {
        try FileManager.default.removeItem(at: rollback)
      }
    }
    try FileManager.default.removeItem(at: receiptURL)
  }
}

// 只向本机 Sparkle 提供已校验的缓存包，不重新联网下载、不开放目录或任意文件路径。
private final class LumioLocalUpdateServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "com.hxg.lumio.update-local-transfer")
  private let archive: URL
  private let arguments: [String: Any]
  private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var readers: [ObjectIdentifier: FileHandle] = [:]
  private(set) var feedURL: URL?
  private(set) var archiveURL: URL?

  init(archive: URL, arguments: [String: Any]) throws {
    self.archive = archive
    self.arguments = arguments
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start(_ completion: @escaping (Error?) -> Void) {
    var reported = false
    listener.stateUpdateHandler = { state in
      guard !reported else { return }
      switch state {
      case .ready:
        guard let port = self.listener.port else { return }
        self.feedURL = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/appcast.xml")
        self.archiveURL = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/Lumio.zip")
        reported = true
        completion(nil)
      case .failed(let error): reported = true; completion(error)
      default: break
      }
    }
    listener.newConnectionHandler = { connection in
      guard self.connections.count < 4 else { connection.cancel(); return }
      let id = ObjectIdentifier(connection)
      self.connections[id] = connection
      connection.start(queue: self.queue)
      self.receive(connection, buffer: Data())
    }
    listener.start(queue: queue)
  }

  func stop() {
    queue.async {
      self.listener.cancel()
      self.listener.stateUpdateHandler = nil
      self.listener.newConnectionHandler = nil
      for connection in Array(self.connections.values) { self.close(connection) }
    }
  }

  private func close(_ connection: NWConnection) {
    let id = ObjectIdentifier(connection)
    try? readers.removeValue(forKey: id)?.close()
    connections.removeValue(forKey: id)
    connection.cancel()
  }

  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
      var input = buffer
      input.append(data ?? Data())
      guard input.count <= 8192, error == nil else { self.close(connection); return }
      if let request = String(data: input, encoding: .utf8), request.contains("\r\n\r\n") {
        self.respond(connection, request: request)
      } else if complete { self.close(connection) }
      else { self.receive(connection, buffer: input) }
    }
    queue.asyncAfter(deadline: .now() + 30) { [weak connection] in
      if let connection, self.connections[ObjectIdentifier(connection)] != nil { self.close(connection) }
    }
  }

  private func respond(_ connection: NWConnection, request: String) {
    let first = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
    guard first.count == 3, first[0] == "GET" || first[0] == "HEAD",
      let raw = URLComponents(string: String(first[1])), raw.scheme == nil,
      raw.host == nil, raw.query == nil,
      raw.path == feedURL?.path || raw.path == archiveURL?.path else { close(connection); return }
    do {
      let feed = raw.path == feedURL?.path
      let body = feed ? try appcast() : Data()
      let length = feed ? body.count : (arguments["size"] as? NSNumber)?.intValue ?? 0
      let header = Data("HTTP/1.1 200 OK\r\nContent-Type: \(feed ? "application/xml" : "application/zip")\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
      if first[0] == "HEAD" {
        connection.send(content: header, completion: .contentProcessed { _ in self.close(connection) })
      } else if feed {
        connection.send(content: header + body, completion: .contentProcessed { _ in self.close(connection) })
      } else {
        readers[ObjectIdentifier(connection)] = try FileHandle(forReadingFrom: archive)
        connection.send(content: header, completion: .contentProcessed { error in
          if error != nil { self.close(connection) } else { self.sendArchive(connection) }
        })
      }
    } catch { close(connection) }
  }

  private func sendArchive(_ connection: NWConnection) {
    do {
      guard let reader = readers[ObjectIdentifier(connection)],
        let bytes = try reader.read(upToCount: 65536), !bytes.isEmpty else { close(connection); return }
      connection.send(content: bytes, completion: .contentProcessed { error in
        if error != nil { self.close(connection) } else { self.sendArchive(connection) }
      })
    } catch { close(connection) }
  }

  private func appcast() throws -> Data {
    guard let url = archiveURL, let signature = arguments["sparkleSignature"] as? String,
      let version = arguments["version"] as? String,
      version.range(of: #"^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$"#, options: .regularExpression) != nil,
      let build = arguments["buildNumber"] as? NSNumber, let size = arguments["size"] as? NSNumber,
      Data(base64Encoded: signature)?.count == 64 else { throw CocoaError(.fileReadCorruptFile) }
    return Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <title>Lumio 更新</title><item><title>Lumio \(version)</title>
    <sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <enclosure url="\(url.absoluteString)" length="\(size)" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
    </item></channel></rss>
    """.utf8)
  }
}

// Independent HEAD measurements, never a replacement for the actual Dart GET.
private final class LumioUpdateNetworkProbe: NSObject, URLSessionTaskDelegate {
  private var session: URLSession?
  private var completion: (([String: Any]) -> Void)?
  private var transactions: [[String: Any]] = []
  private var redirects = 0

  static func trusted(_ url: URL) -> Bool {
    url.scheme == "https" && url.user == nil && url.password == nil &&
      (url.port == nil || url.port == 443) && url.fragment == nil &&
      ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
  }

  private func safeURL(_ url: URL?) -> String {
    guard let url = url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
    parts.query = nil
    parts.fragment = nil
    parts.user = nil
    parts.password = nil
    return parts.string ?? ""
  }

  private func milliseconds(_ start: Date?, _ end: Date?) -> Any {
    guard let start = start, let end = end else { return NSNull() }
    return max(0, end.timeIntervalSince(start) * 1000)
  }

  func start(_ url: URL, completion: @escaping ([String: Any]) -> Void) {
    self.completion = completion
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 45
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    self.session = session
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.setValue("Lumio-Updates/1", forHTTPHeaderField: "User-Agent")
    session.dataTask(with: request).resume()
  }

  func cancel() { session?.invalidateAndCancel() }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    redirects += 1
    guard redirects <= 5, let url = request.url, Self.trusted(url) else {
      completionHandler(nil)
      return
    }
    var head = request
    head.httpMethod = "HEAD"
    completionHandler(head)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    transactions = metrics.transactionMetrics.map { metric in
      ["url": safeURL(metric.request.url),
       "status": (metric.response as? HTTPURLResponse)?.statusCode ?? 0,
       "remoteAddress": metric.remoteAddress ?? "",
       "httpProtocol": metric.networkProtocolName ?? "",
       "isProxyConnection": metric.isProxyConnection,
       "isReusedConnection": metric.isReusedConnection,
       "dnsMs": milliseconds(metric.domainLookupStartDate, metric.domainLookupEndDate),
       "tcpMs": milliseconds(metric.connectStartDate, metric.secureConnectionStartDate ?? metric.connectEndDate),
       "tlsMs": milliseconds(metric.secureConnectionStartDate, metric.secureConnectionEndDate),
       "requestToFirstByteMs": milliseconds(metric.requestStartDate, metric.responseStartDate),
       "headersWaitMs": milliseconds(metric.requestEndDate, metric.responseStartDate)]
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    var report: [String: Any] = [
      "source": "独立 URLSession HEAD，发生于原 Dart 下载之后；DNS 缓存、系统代理和 HTTP 协议可能不同。null 表示阶段未观测到，不表示耗时为零。",
      "transactions": transactions,
      "status": (task.response as? HTTPURLResponse)?.statusCode ?? 0]
    if let error = error as NSError? { report["error"] = ["domain": error.domain, "code": error.code] }
    let callback = completion
    completion = nil
    callback?(report)
    session.finishTasksAndInvalidate()
    self.session = nil
  }
}
