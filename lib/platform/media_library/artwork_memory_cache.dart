import 'dart:typed_data';

typedef ArtworkLoader = Future<Uint8List?> Function(String cacheKey);

class ArtworkMemoryCache {
  ArtworkMemoryCache(this._loader);

  final ArtworkLoader _loader;
  final Map<String, Future<Uint8List?>> _entries =
      <String, Future<Uint8List?>>{};

  Future<Uint8List?> load(String cacheKey) {
    return _entries.putIfAbsent(cacheKey, () => _loader(cacheKey));
  }

  void clear() {
    _entries.clear();
  }
}
