import Foundation

enum LumioPaths {
  static let fileManager = FileManager.default

  static var applicationSupportDirectory: URL {
    let base = try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = (base ?? fileManager.temporaryDirectory)
      .appendingPathComponent("Lumio", isDirectory: true)
    try? fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }
}

struct LumioMediaSourceRecord: Codable {
  let id: String
  var displayName: String
  var lastResolvedPath: String
  var bookmarkData: Data
  let createdAtMs: Int64
  var updatedAtMs: Int64
}

struct LumioResolvedMediaSource {
  let record: LumioMediaSourceRecord
  let url: URL?
  let isStale: Bool

  var summary: [String: Any] {
    [
      "id": record.id,
      "displayName": record.displayName,
      "resolvedPath": url?.path ?? record.lastResolvedPath,
      "status": url == nil ? "permissionRequired" : (isStale ? "stale" : "available"),
      "readOnly": false,
    ]
  }
}

final class SecurityScopedBookmarkStore {
  private let queue = DispatchQueue(label: "com.hxg.lumio.bookmarks")
  private let fileURL = LumioPaths.applicationSupportDirectory
    .appendingPathComponent("media_sources.json")

  func add(urls: [URL]) throws -> [[String: Any]] {
    try queue.sync {
      var records = loadRecords()
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      for url in urls {
        let normalized = url.standardizedFileURL
        let data = try normalized.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        if let index = records.firstIndex(where: {
          $0.lastResolvedPath == normalized.path
        }) {
          records[index].displayName = normalized.lastPathComponent
          records[index].bookmarkData = data
          records[index].updatedAtMs = now
        } else {
          records.append(
            LumioMediaSourceRecord(
              id: UUID().uuidString.lowercased(),
              displayName: normalized.lastPathComponent,
              lastResolvedPath: normalized.path,
              bookmarkData: data,
              createdAtMs: now,
              updatedAtMs: now
            )
          )
        }
      }
      try save(records)
      return resolve(records: records, refreshStaleBookmarks: true).map(\.summary)
    }
  }

  func list() -> [[String: Any]] {
    queue.sync {
      resolve(records: loadRecords(), refreshStaleBookmarks: false).map(\.summary)
    }
  }

  func remove(id: String) throws {
    try queue.sync {
      let records = loadRecords().filter { $0.id != id }
      try save(records)
    }
  }

  func resolvedSources() -> [LumioResolvedMediaSource] {
    queue.sync {
      resolve(records: loadRecords(), refreshStaleBookmarks: true)
    }
  }

  func startAccess(forFilePath path: String) -> URL? {
    let fileURL = URL(fileURLWithPath: path).standardizedFileURL
    let sources = resolvedSources()
      .compactMap { source -> (LumioResolvedMediaSource, URL)? in
        guard let root = source.url else { return nil }
        let rootPath = root.standardizedFileURL.path
        guard fileURL.path == rootPath || fileURL.path.hasPrefix(rootPath + "/") else {
          return nil
        }
        return (source, root)
      }
      .sorted { $0.1.path.count > $1.1.path.count }
    guard let root = sources.first?.1, root.startAccessingSecurityScopedResource() else {
      return nil
    }
    return root
  }

  private func loadRecords() -> [LumioMediaSourceRecord] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([LumioMediaSourceRecord].self, from: data)) ?? []
  }

  private func save(_ records: [LumioMediaSourceRecord]) throws {
    let data = try JSONEncoder().encode(records)
    try data.write(to: fileURL, options: .atomic)
  }

  private func resolve(
    records: [LumioMediaSourceRecord],
    refreshStaleBookmarks: Bool
  ) -> [LumioResolvedMediaSource] {
    var updated = records
    var didChange = false
    let resolved = updated.indices.map { index -> LumioResolvedMediaSource in
      var isStale = false
      let url = try? URL(
        resolvingBookmarkData: updated[index].bookmarkData,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      if let url, isStale, refreshStaleBookmarks,
         let refreshed = try? url.bookmarkData(
           options: [.withSecurityScope],
           includingResourceValuesForKeys: nil,
           relativeTo: nil
         ) {
        updated[index].bookmarkData = refreshed
        updated[index].lastResolvedPath = url.path
        updated[index].updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        isStale = false
        didChange = true
      }
      return LumioResolvedMediaSource(
        record: updated[index],
        url: url,
        isStale: isStale
      )
    }
    if didChange {
      try? save(updated)
    }
    return resolved
  }
}
