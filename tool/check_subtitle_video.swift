import AVFoundation
import AppKit
import Foundation

// 独立原生集成检查：只生成测试视频，不读取媒体库或用户文件。
// 与 LumioSubtitleRenderDocument/VideoComposition/VideoExporter.swift 一起 swiftc 编译。
@main
struct SubtitleVideoCheck {
  static func require(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
    if try !condition() { throw SubtitleVideoError.invalid("检查失败：\(description)") }
  }

  @MainActor
  static func main() async throws {
    if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--verify-ui" {
      let source = URL(fileURLWithPath: CommandLine.arguments[2])
      let output = URL(fileURLWithPath: CommandLine.arguments[3])
      let info = try await LumioSubtitleVideoExporter.probe(AVURLAsset(url: output))
      try require(info.durationMs == 5000 && info.audioTracks == 1 && info.width == 640 && info.height == 360, "UI 导出的尺寸、时长和音轨")
      let before = try await whitePixels(output, at: 1.2)
      let during = try await whitePixels(output, at: 2, png: output.deletingPathExtension().appendingPathExtension("png"))
      let overlap = try await whitePixels(output, at: 3)
      let after = try await whitePixels(output, at: 4.8)
      let original = try await whitePixels(source, at: 2)
      try require(before < 10 && after < 10 && original < 10 && during > 30 && overlap > during, "UI 校准时间与成片一致")
      print("PASS：沙盒工作台导出，延后 0.5 秒、中文/重叠、方向和音轨检查通过。")
      return
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumio-subtitle-check-\(UUID().uuidString)")
    let scratchBefore = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix(".lumio-subtitle-") })
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    print("检查目录：\(root.path)")
    let document = try SubtitleRenderDocument(cues: [
      SubtitleVideoCue(id: "first", startMs: 1000, endMs: 3000, text: "你好，忆光\n中文字幕验证"),
      SubtitleVideoCue(id: "second", startMs: 2000, endMs: 4000, text: "Video subtitle · 同步"),
    ], style: SubtitleVideoStyle())
    try require(document.activeIndices(at: 999).isEmpty, "起点前无字幕")
    try require(document.activeIndices(at: 1000) == [0], "起点命中")
    try require(document.activeIndices(at: 2000) == [0, 1], "重叠字幕")
    try require(document.activeIndices(at: 3000) == [1], "半开区间终点")
    try require(document.activeIndices(at: 4000).isEmpty, "终点后无字幕")
    let source = root.appendingPathComponent("source.mp4")
    try await makeVideo(source, rotated: false, audio: true)
    let sourceBytes = try Data(contentsOf: source)
    let output = root.appendingPathComponent("subtitled.mp4")
    let exporter = LumioSubtitleVideoExporter()
    let info = try await exporter.export(source: source, target: output, document: document)
    try require(info.audioTracks == 1, "保留音轨")
    let originalWhite = try await whitePixels(source, at: 1.5)
    let before = try await whitePixels(output, at: 0.5)
    let during = try await whitePixels(output, at: 1.5, png: root.appendingPathComponent("landscape.png"))
    let overlap = try await whitePixels(output, at: 2.5, png: root.appendingPathComponent("overlap.png"))
    let after = try await whitePixels(output, at: 4.5)
    try require(originalWhite < 10 && before < 10 && after < 10, "字幕区间外不残留文字")
    print("画面白色像素：原片 \(originalWhite)，出现前 \(before)，单句 \(during)，重叠 \(overlap)，结束后 \(after)")
    try require(during > 30 && overlap > during, "中文字与重叠字幕烧录到画面")
    try require(try Data(contentsOf: source) == sourceBytes, "不修改原视频")

    let portrait = root.appendingPathComponent("rotated.mp4")
    let portraitOutput = root.appendingPathComponent("rotated-subtitled.mp4")
    try await makeVideo(portrait, rotated: true, audio: false)
    let portraitInfo = try await exporter.export(source: portrait, target: portraitOutput, document: document)
    try require(portraitInfo.width == 360 && portraitInfo.height == 640 && portraitInfo.audioTracks == 0, "旋转方向与无音轨")
    let portraitWhite = try await whitePixels(portraitOutput, at: 1.5, png: root.appendingPathComponent("portrait.png"))
    try require(portraitWhite > 50, "竖屏中文字")

    do {
      _ = try await exporter.export(source: source, target: source, document: document)
      throw SubtitleVideoError.invalid("同路径保护未生效")
    } catch SubtitleVideoError.invalid(let message) { try require(message.contains("不同于原视频"), "拒绝原地覆盖") }
    do {
      _ = try await exporter.export(source: source, target: output, document: document)
      throw SubtitleVideoError.invalid("现有目标保护未生效")
    } catch SubtitleVideoError.invalid(let message) { try require(message.contains("已存在"), "拒绝覆盖现有输出") }
    let cancelled = root.appendingPathComponent("cancelled.mp4")
    do {
      _ = try await exporter.export(source: source, target: cancelled, document: document) { phase, _ in
        if phase == "encoding" { exporter.cancel() }
      }
      throw SubtitleVideoError.invalid("取消未生效")
    } catch is CancellationError {}
    try require(!FileManager.default.fileExists(atPath: cancelled.path), "取消不发布成片")
    let longSource = root.appendingPathComponent("long-source.mp4")
    try await makeVideo(longSource, rotated: false, audio: false, frames: 1800)
    let midCancel = root.appendingPathComponent("mid-cancel.mp4")
    var cancelledDuringEncoding = false
    do {
      _ = try await exporter.export(source: longSource, target: midCancel, document: document) { phase, progress in
        if phase == "encoding", let progress, progress > 0, progress < 1 {
          cancelledDuringEncoding = true; exporter.cancel()
        }
      }
      throw SubtitleVideoError.invalid("编码中取消未触发")
    } catch is CancellationError {}
    try require(cancelledDuringEncoding && !FileManager.default.fileExists(atPath: midCancel.path), "编码中取消不产生输出")
    let publishCancel = root.appendingPathComponent("publish-cancel.mp4")
    do {
      _ = try await exporter.export(source: source, target: publishCancel, document: document) { phase, _ in
        if phase == "publishing" { exporter.cancel() }
      }
      throw SubtitleVideoError.invalid("发布前取消未生效")
    } catch is CancellationError {}
    try require(!FileManager.default.fileExists(atPath: publishCancel.path), "发布前取消不产生输出")
    let scratchAfter = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix(".lumio-subtitle-") })
    try require(scratchAfter.subtracting(scratchBefore).isEmpty, "本次任务临时文件已清理")
    print("PASS：区间查询、中文字幕/重叠、旋转、音轨、原文件保护、目标保护、取消与清理。")
  }

  static func makeVideo(_ url: URL, rotated: Bool, audio: Bool, frames: Int = 150) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
    ])
    if rotated { video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ])
    writer.add(video)
    let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
    ])
    if audio { writer.add(sound) }
    guard writer.startWriting() else { throw writer.error ?? SubtitleVideoError.invalid("测试视频初始化失败") }
    writer.startSession(atSourceTime: .zero)
    let audioTask = Task {
      if !audio { return }
      let deadline = Date().addingTimeInterval(20)
      for i in 0..<frames {
        while !sound.isReadyForMoreMediaData {
          if writer.status == .failed { throw writer.error! }
          if Date() > deadline { throw SubtitleVideoError.invalid("测试音频写入超时") }
          try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard sound.append(try audioSample(start: i * 1470, count: 1470)) else {
          throw writer.error ?? SubtitleVideoError.invalid("测试音频写入失败")
        }
      }
      sound.markAsFinished()
    }
    let deadline = Date().addingTimeInterval(20)
    for i in 0..<frames {
      while !video.isReadyForMoreMediaData {
        if writer.status == .failed { throw writer.error! }
        if Date() > deadline { throw SubtitleVideoError.invalid("测试视频写入超时") }
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      var buffer: CVPixelBuffer?
      guard let pool = adaptor.pixelBufferPool,
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
            let buffer else { throw SubtitleVideoError.invalid("测试帧创建失败") }
      CVPixelBufferLockBaseAddress(buffer, [])
      let bitmap = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
      bitmap.setFillColor(CGColor(gray: 0.12, alpha: 1))
      bitmap.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
      bitmap.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
      bitmap.fill(CGRect(x: 8, y: 310, width: 60, height: 40))
      CVPixelBufferUnlockBaseAddress(buffer, [])
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30)) else {
        throw writer.error ?? SubtitleVideoError.invalid("测试帧写入失败")
      }
    }
    video.markAsFinished()
    try await audioTask.value
    writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? SubtitleVideoError.invalid("测试视频写入失败") }
  }

  static func audioSample(start: Int, count: Int) throws -> CMSampleBuffer {
    var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var description: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr else {
      throw SubtitleVideoError.invalid("测试音频格式创建失败")
    }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 4,
      blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 4,
      flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else {
      throw SubtitleVideoError.invalid("测试音频缓冲失败")
    }
    let samples = (0..<count).map { Float(sin(Double(start + $0) * 2 * .pi * 440 / 44100) * 0.08) }
    let status = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 4) }
    guard status == noErr else { throw SubtitleVideoError.invalid("测试音频写入缓冲失败") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: CMTime(value: Int64(start), timescale: 44100), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var size = 4
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description,
      sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else {
      throw SubtitleVideoError.invalid("测试音频采样失败")
    }
    return sample
  }

  static func whitePixels(_ url: URL, at seconds: Double, png: URL? = nil) async throws -> Int {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
    if let png {
      let bitmap = NSBitmapImageRep(cgImage: image)
      try bitmap.representation(using: .png, properties: [:])!.write(to: png)
    }
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { pointer in
      let bitmap = CGContext(data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 200 && bytes[$0 + 1] > 200 && bytes[$0 + 2] > 200 }.count
  }
}
