import 'dart:io';

import 'package:flutter/services.dart';

import 'artwork_cache.dart';

const _mediaLibraryChannel = MethodChannel('lumio/media_library');

/// 全局封面缓存。界面只通过它取图，扫描完成后由状态层统一失效。
final ArtworkCache artworkCache = ArtworkCache(loadArtworkBytes);

/// 读取一张封面：优先使用平台内嵌封面，其次回退到本地文件路径。
///
/// cacheKey 形如 `kind|mediaId|编码后的封面路径`，由 [artworkCacheKeyFor] 生成。
Future<Uint8List?> loadArtworkBytes(String cacheKey) async {
  final parts = cacheKey.split('|');
  if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) {
    return null;
  }
  try {
    final embedded = await _mediaLibraryChannel.invokeMethod<Uint8List>(
      'loadArtwork',
      <String, Object?>{'kind': parts[0], 'mediaId': parts[1]},
    );
    if (embedded != null && embedded.isNotEmpty) return embedded;
  } on MissingPluginException {
    // 平台未实现时回退到文件路径。
  } on PlatformException {
    // 内嵌封面读取失败时同样回退，不影响占位图显示。
  }
  if (parts.length < 3 || parts[2].isEmpty) return null;
  try {
    final file = File(Uri.decodeComponent(parts[2]));
    return await file.exists() ? file.readAsBytes() : null;
  } on FileSystemException {
    return null;
  }
}

/// 生成封面缓存键。封面路径变化会产生新键，从而读到新的图。
String artworkCacheKeyFor({
  required String kind,
  required String mediaId,
  String? artworkPath,
}) =>
    '$kind|$mediaId|${Uri.encodeComponent(artworkPath ?? '')}';

/// 扫描或标签改写后失效封面缓存：内存立即清空，磁盘仅在 [disk] 为真时删除。
Future<void> clearArtworkCache({bool disk = false}) async {
  await artworkCache.clear(disk: disk);
}
