import Cocoa
import CryptoKit
import FlutterMacOS

final class LumioAppUpdatePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.hxg.lumio.app-update")
  private var networkProbe: LumioUpdateNetworkProbe?
  private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Lumio/updates", isDirectory: true)

  static func register(with registrar: FlutterPluginRegistrar) {}
  init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(name: "lumio/app_update", binaryMessenger: registrar.messenger)
    super.init()
    registrar.addMethodCallDelegate(self, channel: channel)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ["environment", "validate", "open", "probeNetwork", "cancelProbe"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
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
