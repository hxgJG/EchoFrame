import Foundation
import CoreFoundation

/// 仅修复有文件名佐证的旧中文标签，不猜测正常外文或改写媒体文件。
enum LumioMetadataRepair {
  static func record(_ original: [String: Any]) -> [String: Any] {
    guard let path = original["path"] as? String else { return original }
    let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let fields = ["title", "artist", "album"]
    var candidates: [String: String] = [:]
    for field in fields {
      if let value = original[field] as? String, let repaired = candidate(value) {
        candidates[field] = repaired
      }
    }
    let confirmed = ["title", "artist"].contains { field in
      guard let value = candidates[field] else { return false }
      return filename.contains(value)
    }
    guard confirmed else { return original }
    var result = original
    for (field, value) in candidates { result[field] = value }
    return result
  }

  static func library(_ original: [String: Any]) -> [String: Any] {
    var result = original
    for key in ["audioItems", "videoItems"] {
      if let items = original[key] as? [[String: Any]] {
        result[key] = items.map(record)
      }
    }
    return result
  }

  private static func candidate(_ value: String) -> String? {
    let scalars = Array(value.unicodeScalars)
    guard scalars.count >= 4,
          !scalars.contains(where: { isChinese($0.value) }),
          scalars.filter({ $0.value >= 0x80 }).count * 2 >= scalars.count else { return nil }
    let chinese = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))
    for encoding in [String.Encoding.isoLatin1, .windowsCP1252] {
      guard let bytes = value.data(using: encoding, allowLossyConversion: false),
            String(data: bytes, encoding: encoding) == value,
            let decoded = String(data: bytes, encoding: chinese),
            decoded.data(using: chinese, allowLossyConversion: false) == bytes else { continue }
      let output = Array(decoded.unicodeScalars)
      let count = output.filter { isChinese($0.value) }.count
      if count >= 2 && count * 2 >= output.count &&
          !output.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0xFFFD }) {
        return decoded
      }
    }
    return nil
  }

  private static func isChinese(_ value: UInt32) -> Bool {
    (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value)
  }
}
