import Foundation

@main
struct MetadataRepairChecks {
  static func main() {
    let original: [String: Any] = [
      "id": "test", "path": "/Music/黄凯芹 - 晚秋.mp3",
      "title": "ÍíÇï", "artist": "»Æ¿­ÇÛ", "album": "±¦Àö½ð", "playCount": 7
    ]
    let repaired = LumioMetadataRepair.record(original)
    precondition(repaired["title"] as? String == "晚秋")
    precondition(repaired["artist"] as? String == "黄凯芹")
    precondition(repaired["album"] as? String == "宝丽金")
    precondition(repaired["playCount"] as? Int == 7)
    precondition(NSDictionary(dictionary: repaired).isEqual(to: LumioMetadataRepair.record(repaired)))
    for title in ["Café", "Beyoncé", "Voilà déjà", "Mötley Crüe", "晚秋", "hello", "😀", "ÿÿÿÿ"] {
      let item: [String: Any] = ["path": "/Music/晚秋.mp3", "title": title]
      precondition(LumioMetadataRepair.record(item)["title"] as? String == title)
    }
    var unknown = original
    unknown["path"] = "/Music/track01.mp3"
    precondition(LumioMetadataRepair.record(unknown)["title"] as? String == "ÍíÇï")
    let restored = LumioMetadataRepair.library(["audioItems": [original], "themeMode": "dark"])
    precondition((restored["audioItems"] as? [[String: Any]])?.first?["title"] as? String == "晚秋")
    precondition(restored["themeMode"] as? String == "dark")
    print("Metadata repair checks passed")
  }
}
