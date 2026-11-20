import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

typedef ArtworkLoader = Future<Uint8List?> Function(String cacheKey);

/// 封面两级缓存：内存 LRU + 缓存目录文件。
///
/// 内存层按字节限量，避免长时间浏览大媒体库时把所有封面常驻内存；
/// 磁盘层让冷启动不必为每首歌重新走平台通道。取不到缓存目录时自动降级为
/// 仅内存缓存，不影响图片显示。
class ArtworkCache {
  ArtworkCache(
    this._loader, {
    this.memoryBudget = 32 << 20,
    this.diskBudget = 128 << 20,
    this.maxEntryBytes = 4 << 20,
    this.maxEntries = 20000,
    Future<Directory?> Function()? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory;

  /// 常驻内存的封面字节上限，超出后按最近最少使用淘汰。
  final int memoryBudget;

  /// 磁盘缓存上限，写入后超过该值时淘汰最旧文件。
  final int diskBudget;

  /// 单张封面上限，超过则不落盘，避免个别超大图占满预算。
  final int maxEntryBytes;

  /// 缓存条数上限；未命中结果也占位，避免滚动时反复请求平台通道。
  final int maxEntries;

  final ArtworkLoader _loader;
  final Future<Directory?> Function() _directoryProvider;

  final LinkedHashMap<String, _ArtworkEntry> _entries =
      LinkedHashMap<String, _ArtworkEntry>();
  int _memoryBytes = 0;
  Future<Directory?>? _directoryFuture;
  bool _pruned = false;

  static Future<Directory?> _defaultDirectory() async {
    try {
      final base = await getTemporaryDirectory();
      return Directory('${base.path}/lumio_artwork');
    } on Object {
      // 平台未实现或不可用时退化为纯内存缓存。
      return null;
    }
  }

  Future<Uint8List?> load(String cacheKey) {
    final existing = _entries.remove(cacheKey);
    if (existing != null) {
      _entries[cacheKey] = existing;
      return existing.future;
    }
    final entry = _ArtworkEntry(_read(cacheKey));
    _entries[cacheKey] = entry;
    unawaited(entry.future.then((bytes) {
      // 解析期间可能已被淘汰，只有仍在表中时才计入内存占用。
      if (!identical(_entries[cacheKey], entry)) return;
      entry.size = bytes?.length ?? 0;
      _memoryBytes += entry.size;
      _evictMemory();
    }, onError: (Object _) {}));
    _evictOverflow();
    return entry.future;
  }

  /// 清空内存层；[disk] 为真时同时删除磁盘缓存文件。
  /// 媒体库重新扫描后需要调用，否则改过的封面会继续显示旧图。
  Future<void> clear({bool disk = false}) async {
    _entries.clear();
    _memoryBytes = 0;
    if (!disk) return;
    final directory = await _directory();
    if (directory == null) return;
    try {
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith('.img')) {
          await entity.delete();
        }
      }
    } on Object {
      // 删除失败时保留文件，只影响缓存命中率。
    }
  }

  Future<Uint8List?> _read(String cacheKey) async {
    final cached = await _readDisk(cacheKey);
    if (cached != null && cached.isNotEmpty) return cached;
    final loaded = await _loader(cacheKey);
    if (loaded != null && loaded.isNotEmpty) {
      await _writeDisk(cacheKey, loaded);
    }
    return loaded;
  }

  Future<Directory?> _directory() {
    return _directoryFuture ??= _prepareDirectory();
  }

  Future<Directory?> _prepareDirectory() async {
    try {
      final directory = await _directoryProvider();
      if (directory == null) return null;
      await directory.create(recursive: true);
      if (!_pruned) {
        _pruned = true;
        await _prune(directory);
      }
      return directory;
    } on Object {
      return null;
    }
  }

  String _fileName(String cacheKey) =>
      '${sha256.convert(utf8.encode(cacheKey))}.img';

  Future<Uint8List?> _readDisk(String cacheKey) async {
    final directory = await _directory();
    if (directory == null) return null;
    final file = File('${directory.path}/${_fileName(cacheKey)}');
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size <= 0 ||
          stat.size > maxEntryBytes) {
        return null;
      }
      final bytes = await file.readAsBytes();
      // 刷新访问时间，供容量淘汰时判断新旧；失败不影响读取结果。
      try {
        await file.setLastModified(DateTime.now());
      } on Object {
        // 忽略：只影响淘汰顺序。
      }
      return bytes;
    } on Object {
      return null;
    }
  }

  Future<void> _writeDisk(String cacheKey, Uint8List bytes) async {
    if (bytes.length > maxEntryBytes) return;
    final directory = await _directory();
    if (directory == null) return;
    try {
      await File('${directory.path}/${_fileName(cacheKey)}')
          .writeAsBytes(bytes);
      await _prune(directory);
    } on Object {
      // 缓存写入失败不影响本次显示。
    }
  }

  Future<void> _prune(Directory directory) async {
    try {
      final files = await directory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.img'))
          .cast<File>()
          .toList();
      if (files.isEmpty) return;
      final stats = <({File file, int size, DateTime modified})>[];
      var total = 0;
      for (final file in files) {
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        total += stat.size;
        stats.add((file: file, size: stat.size, modified: stat.modified));
      }
      if (total <= diskBudget) return;
      stats.sort((a, b) => a.modified.compareTo(b.modified));
      final target = diskBudget * 3 ~/ 4;
      for (final item in stats) {
        if (total <= target) break;
        try {
          await item.file.delete();
          total -= item.size;
        } on Object {
          // 已被其他清理删除。
        }
      }
    } on Object {
      // 目录不可读时跳过清理。
    }
  }

  void _evictOverflow() {
    while (_entries.length > maxEntries) {
      final removed = _entries.remove(_entries.keys.first);
      if (removed != null) _memoryBytes -= removed.size;
    }
  }

  void _evictMemory() {
    while (_memoryBytes > memoryBudget && _entries.isNotEmpty) {
      final removed = _entries.remove(_entries.keys.first);
      if (removed == null) continue;
      _memoryBytes -= removed.size;
      if (_memoryBytes < 0) _memoryBytes = 0;
    }
  }
}

class _ArtworkEntry {
  _ArtworkEntry(this.future);
  final Future<Uint8List?> future;
  int size = 0;
}
