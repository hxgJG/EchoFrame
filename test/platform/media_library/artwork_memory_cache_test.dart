import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/platform/media_library/artwork_memory_cache.dart';

void main() {
  test('loads each media artwork only once', () async {
    var loadCount = 0;
    final cache = ArtworkMemoryCache((mediaId) async {
      loadCount += 1;
      return Uint8List.fromList(<int>[1, 2, 3]);
    });

    final first = await cache.load('song-1');
    final second = await cache.load('song-1');

    expect(first, <int>[1, 2, 3]);
    expect(second, <int>[1, 2, 3]);
    expect(loadCount, 1);
  });

  test('caches missing artwork to avoid repeated platform calls', () async {
    var loadCount = 0;
    final cache = ArtworkMemoryCache((mediaId) async {
      loadCount += 1;
      return null;
    });

    expect(await cache.load('song-without-cover'), isNull);
    expect(await cache.load('song-without-cover'), isNull);
    expect(loadCount, 1);
  });
}
