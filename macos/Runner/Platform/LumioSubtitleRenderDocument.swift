import Foundation
import CoreGraphics

enum SubtitleVideoError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self { case .invalid(let message): return message }
  }
}

/// 时间已经折入用户确认的校准；原生渲染与导出不再添加任何播放器偏移。
struct SubtitleVideoCue: Codable, Equatable, Sendable {
  let id: String
  let startMs: Int64
  let endMs: Int64
  let text: String
}

struct SubtitleVideoStyle: Codable, Equatable, Sendable {
  var fontFraction: Double = 0.045
  var bottomFraction: Double = 0.08
  var color: String = "white"
  var background: Bool = true

  func validate() throws {
    guard fontFraction.isFinite, (0.018...0.09).contains(fontFraction),
          bottomFraction.isFinite, (0.02...0.55).contains(bottomFraction),
          ["white", "yellow", "cyan"].contains(color) else {
      throw SubtitleVideoError.invalid("字幕样式参数无效。")
    }
  }
}

/// 使用起止事件构建有界的区间索引，支持重叠、同起点和随机定位。
final class SubtitleRenderDocument: Sendable {
  static let maximumCues = 20_000
  static let maximumBytes = 2 * 1024 * 1024
  static let maximumConcurrentCues = 8
  let cues: [SubtitleVideoCue]
  let style: SubtitleVideoStyle
  private let boundaries: [Int64]
  private let intervals: [[Int]]

  init(cues: [SubtitleVideoCue], style: SubtitleVideoStyle) throws {
    try style.validate()
    guard !cues.isEmpty, cues.count <= Self.maximumCues else {
      throw SubtitleVideoError.invalid("请提供 1～20000 句字幕。")
    }
    var identities = Set<String>()
    var total = 0
    var events: [(time: Int64, index: Int, begins: Bool)] = []
    for (index, cue) in cues.enumerated() {
      let size = cue.text.utf8.count
      total += size
      guard !cue.id.isEmpty, cue.id.utf8.count <= 128,
            identities.insert(cue.id).inserted,
            cue.startMs >= 0, cue.endMs > cue.startMs,
            cue.endMs <= 7 * 24 * 60 * 60 * 1000,
            !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !cue.text.contains("\0"), size <= 16 * 1024,
            total <= Self.maximumBytes else {
        throw SubtitleVideoError.invalid("第 \(index + 1) 句内容、标识或时间无效，请先修正。")
      }
      events.append((cue.startMs, index, true))
      events.append((cue.endMs, index, false))
    }
    events.sort { $0.time < $1.time }
    var times: [Int64] = []
    var groups: [[Int]] = []
    var active = Set<Int>()
    var cursor = 0
    while cursor < events.count {
      let time = events[cursor].time
      while cursor < events.count, events[cursor].time == time {
        let event = events[cursor]
        if event.begins { active.insert(event.index) } else { active.remove(event.index) }
        cursor += 1
      }
      guard active.count <= Self.maximumConcurrentCues else {
        throw SubtitleVideoError.invalid("同一时刻超过 8 句字幕重叠，请先整理后导出；原字幕不会被删除。")
      }
      times.append(time)
      groups.append(active.sorted())
    }
    self.cues = cues
    self.style = style
    boundaries = times
    intervals = groups
  }

  func activeIndices(at milliseconds: Int64) -> [Int] {
    var low = 0, high = boundaries.count
    while low < high {
      let mid = (low + high) / 2
      if boundaries[mid] <= milliseconds { low = mid + 1 } else { high = mid }
    }
    return low == 0 ? [] : intervals[low - 1]
  }

  func text(at milliseconds: Int64) -> String {
    activeIndices(at: milliseconds).map { cues[$0].text }.joined(separator: "\n")
  }

  func boundaryWarnings(durationMs: Int64) -> Int {
    cues.filter { $0.startMs >= durationMs || $0.endMs > durationMs }.count
  }
}
