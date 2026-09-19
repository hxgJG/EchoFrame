import AVFoundation
import AppKit
import CoreImage
import CoreText

/// Core Image 视频合成让预览、抽帧与导出使用相同的呈现时间和渲染器。
/// 不修改该系统生成的 composition 指令，以保留素材的帧时序和 preferredTransform。
enum LumioSubtitleVideoComposition {
  static func make(asset: AVAsset, document: SubtitleRenderDocument) async throws -> AVVideoComposition {
    let renderer = SubtitleFrameRenderer(document: document)
    _ = try await asset.load(.duration, .tracks)
    // 新的 async applier 仅在 macOS 26 可用；保留 macOS 13 的合成入口。
    return AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
      autoreleasepool {
        do {
          let time = CMTimeGetSeconds(request.compositionTime)
          guard time.isFinite else { throw SubtitleVideoError.invalid("视频帧时间无效。") }
          let output = try renderer.render(request.sourceImage, milliseconds: Int64((time * 1000).rounded(.down)))
          request.finish(with: output, context: renderer.context)
        } catch { request.finish(with: error) }
      }
    })
  }
}

// 文档不可变，NSCache/CIContext 支持并发访问；所有排版上下文均按请求创建。
private final class SubtitleFrameRenderer: @unchecked Sendable {
  let context = CIContext(options: [.cacheIntermediates: false])
  private let document: SubtitleRenderDocument
  private let cache = NSCache<NSString, CIImage>()

  init(document: SubtitleRenderDocument) {
    self.document = document
    cache.countLimit = 8
    cache.totalCostLimit = 32 * 1024 * 1024
  }

  func render(_ source: CIImage, milliseconds: Int64) throws -> CIImage {
    let indices = document.activeIndices(at: milliseconds)
    if indices.isEmpty { return source }
    let size = source.extent.size
    guard size.width.isFinite, size.height.isFinite,
          size.width >= 16, size.height >= 16,
          size.width <= 4096, size.height <= 4096 else {
      throw SubtitleVideoError.invalid("首版字幕导出支持边长不超过 4096 像素的视频。")
    }
    let key = "\(Int(size.width))x\(Int(size.height)):\(indices.map(String.init).joined(separator: ","))" as NSString
    let overlay: CIImage
    if let cached = cache.object(forKey: key) { overlay = cached }
    else {
      let text = indices.map { document.cues[$0].text }.joined(separator: "\n")
      overlay = try makeOverlay(text: text, size: size)
      cache.setObject(overlay, forKey: key, cost: Int(overlay.extent.width * overlay.extent.height * 4))
    }
    let x = source.extent.minX + (size.width - overlay.extent.width) / 2
    let y = source.extent.minY + size.height * document.style.bottomFraction
    return overlay.transformed(by: CGAffineTransform(translationX: x, y: y))
      .composited(over: source).cropped(to: source.extent)
  }

  private func makeOverlay(text: String, size: CGSize) throws -> CIImage {
    let fontSize = max(10, min(size.width, size.height) * document.style.fontFraction)
    let padding = max(4, fontSize * 0.25)
    let width = floor(size.width * 0.9)
    let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, fontSize, nil)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    let color: NSColor
    switch document.style.color {
    case "yellow": color = NSColor(srgbRed: 1, green: 0.95, blue: 0.46, alpha: 1)
    case "cyan": color = NSColor(srgbRed: 0.5, green: 1, blue: 1, alpha: 1)
    default: color = .white
    }
    let attributed = NSAttributedString(string: text, attributes: [
      .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
      .strokeColor: NSColor.black, .strokeWidth: -3.0,
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
      CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude), nil)
    let height = ceil(measured.height + padding * 2)
    guard height <= size.height * 0.4 else {
      throw SubtitleVideoError.invalid("字幕超过画面高度的 40%，请缩小字号或拆分长句，不能静默截断。")
    }
    guard let bitmap = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw SubtitleVideoError.invalid("无法创建字幕绘制缓冲区。")
    }
    if document.style.background {
      bitmap.setFillColor(CGColor(gray: 0, alpha: 0.55))
      bitmap.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: padding, cornerHeight: padding, transform: nil))
      bitmap.fillPath()
    }
    bitmap.textMatrix = .identity
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
      CGPath(rect: CGRect(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2), transform: nil), nil)
    guard CTFrameGetVisibleStringRange(frame).length == attributed.length else {
      throw SubtitleVideoError.invalid("字幕排版不完整，请调整文字或字号。")
    }
    CTFrameDraw(frame, bitmap)
    guard let image = bitmap.makeImage() else { throw SubtitleVideoError.invalid("字幕图像生成失败。") }
    return CIImage(cgImage: image)
  }
}
