import AVFoundation
import Foundation
import Darwin

struct SubtitleVideoProbe {
  let durationMs: Int64
  let width: Int
  let height: Int
  let audioTracks: Int
}

/// 仅负责已授权 URL 的原生处理；文件选择与 security-scoped 生命周期由调用层管理。
@MainActor
final class LumioSubtitleVideoExporter {
  private var session: AVAssetExportSession?
  private var active = false
  private var cancelled = false
  private var jobToken: UUID?
  private var publishing: Task<Void, Error>?
  var isExporting: Bool { active }

  func cancel() {
    guard active else { return }
    cancelled = true
    session?.cancelExport()
    publishing?.cancel()
  }

  static func probe(_ asset: AVAsset) async throws -> SubtitleVideoProbe {
    let duration = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(duration)
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    guard seconds.isFinite, seconds > 0, seconds <= 7 * 24 * 60 * 60,
          video.count == 1, audio.count <= 1, let track = video.first else {
      throw SubtitleVideoError.invalid("首版支持有效时长的单视频轨、至多一个音轨的视频。")
    }
    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let display = CGRect(origin: .zero, size: size).applying(transform).standardized.size
    guard display.width.isFinite, display.height.isFinite,
          display.width >= 16, display.height >= 16,
          display.width <= 4096, display.height <= 4096 else {
      throw SubtitleVideoError.invalid("首版支持边长 16～4096 像素的视频。")
    }
    let formats = try await track.load(.formatDescriptions)
    for format in formats {
      let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
      if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String ||
          transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String {
        throw SubtitleVideoError.invalid("暂不支持 HDR 字幕导出，请先使用 SDR 视频。")
      }
    }
    guard try await asset.load(.isExportable) else { throw SubtitleVideoError.invalid("该视频无法导出。") }
    return SubtitleVideoProbe(durationMs: Int64((seconds * 1000).rounded()),
      width: Int(display.width.rounded()), height: Int(display.height.rounded()), audioTracks: audio.count)
  }

  func export(source: URL, target: URL, document: SubtitleRenderDocument,
              allowOutOfRange: Bool = false,
              progress: @escaping (String, Double?) -> Void = { _, _ in }) async throws -> SubtitleVideoProbe {
    guard !active else { throw SubtitleVideoError.invalid("已有视频正在导出。") }
    guard source.isFileURL, target.isFileURL, target.pathExtension.lowercased() == "mp4",
          source.resolvingSymlinksInPath().standardizedFileURL != target.resolvingSymlinksInPath().standardizedFileURL else {
      throw SubtitleVideoError.invalid("请选择不同于原视频的 MP4 输出位置。")
    }
    let files = FileManager.default
    guard !files.fileExists(atPath: target.path) else { throw SubtitleVideoError.invalid("输出文件已存在，请使用新文件名；不会覆盖现有文件。") }
    active = true
    cancelled = false
    let token = UUID()
    jobToken = token
    defer { session = nil; publishing = nil; active = false; jobToken = nil }
    let asset = AVURLAsset(url: source)
    let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    progress("validating", nil)
    let probe = try await Self.probe(asset)
    try checkCancellation()
    guard document.cues.contains(where: { $0.startMs < probe.durationMs && $0.endMs > 0 }) else {
      throw SubtitleVideoError.invalid("视频范围内没有字幕，无法导出带字幕成片。")
    }
    guard allowOutOfRange || document.boundaryWarnings(durationMs: probe.durationMs) == 0 else {
      throw SubtitleVideoError.invalid("部分字幕超过视频范围，请确认范围裁切后再导出。")
    }
    let composition = try await LumioSubtitleVideoComposition.make(asset: asset, document: document)
    try checkCancellation()
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
          exporter.supportedFileTypes.contains(.mp4) else { throw SubtitleVideoError.invalid("该视频不支持当前 MP4 导出配置。") }
    session = exporter
    exporter.videoComposition = composition
    // 文件选择器只保证授权目标文件，不假定有权在其父目录创建临时文件。
    let scratch = files.temporaryDirectory.appendingPathComponent(".lumio-subtitle-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: scratch, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: scratch) }
    let temporary = scratch.appendingPathComponent("render.mp4")
    exporter.outputURL = temporary
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = true
    progress("encoding", 0)
    try checkCancellation()
    let monitor = Task { @MainActor in
      while !Task.isCancelled {
        progress("encoding", Double(exporter.progress))
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
    defer { monitor.cancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        exporter.exportAsynchronously {
          Task { @MainActor [weak self] in
            guard let self, self.jobToken == token, let finished = self.session else {
              continuation.resume(throwing: CancellationError())
              return
            }
            switch finished.status {
            case .completed: continuation.resume()
            case .cancelled: continuation.resume(throwing: CancellationError())
            default: continuation.resume(throwing: finished.error ?? SubtitleVideoError.invalid("视频导出失败。"))
            }
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.jobToken == token else { return }
        self?.cancel()
      }
    }
    monitor.cancel()
    try checkCancellation()
    progress("verifying", nil)
    let result = try await Self.probe(AVURLAsset(url: temporary))
    guard abs(result.durationMs - probe.durationMs) <= 150,
          result.audioTracks == probe.audioTracks,
          abs(result.width - probe.width) <= 2, abs(result.height - probe.height) <= 2 else {
      throw SubtitleVideoError.invalid("成片时长、方向、尺寸或音轨与原视频不符，未发布输出。")
    }
    let finalValues = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    guard sourceValues.fileSize == finalValues.fileSize,
          sourceValues.contentModificationDate == finalValues.contentModificationDate else {
      throw SubtitleVideoError.invalid("导出期间源视频发生变化，请重试。")
    }
    try checkCancellation()
    progress("publishing", nil)
    try checkCancellation()
    let publication = Task.detached(priority: .utility) {
      try SubtitleOutputPublisher.copy(temporary, to: target)
    }
    publishing = publication
    try await withTaskCancellationHandler { try await publication.value }
      onCancel: { publication.cancel() }
    progress("completed", 1)
    return result
  }

  private func checkCancellation() throws {
    if cancelled || Task.isCancelled { throw CancellationError() }
  }
}

private enum SubtitleOutputPublisher {
  static func copy(_ source: URL, to target: URL) throws {
    try Task.checkCancellation()
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    // O_EXCL 同时防止覆盖现有文件与目标路径被替换为符号链接的竞态。
    let descriptor = target.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) } ?? -1
    }
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? output.close() }
    do {
      while true {
        try Task.checkCancellation()
        guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
        try output.write(contentsOf: chunk)
      }
      try output.synchronize()
      try Task.checkCancellation()
    } catch {
      // 只移除我们创建的同一 inode；目标被外部替换后绝不能误删别人的文件。
      var own = stat(), current = stat()
      if fstat(descriptor, &own) == 0,
         lstat(target.path, &current) == 0,
         own.st_dev == current.st_dev, own.st_ino == current.st_ino {
        _ = unlink(target.path)
      }
      throw error
    }
  }
}
