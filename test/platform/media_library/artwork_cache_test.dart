import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/platform/media_library/artwork_cache.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lumio-artwork-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  ArtworkCache buildCache(
    ArtworkLoader loader, {
    int memoryBudget = 32 << 20,
    int diskBudget = 128 << 20,
  }) =>
      ArtworkCache(
        loader,
        memoryBudget: memoryBudget,
        diskBudget: diskBudget,
        directoryProvider: () async => directory,
      );

  test('同一封面只加载一次', () async {
    var loadCount = 0;
    final cache = buildCache((key) async {
      loadCount += 1;
      return Uint8List.fromList(<int>[1, 2, 3]);
    });

    expect(await cache.load('song-1'), <int>[1, 2, 3]);
    expect(await cache.load('song-1'), <int>[1, 2, 3]);
    expect(loadCount, 1);
  });

  test('未命中结果也会占位，不重复请求平台通道', () async {
    var loadCount = 0;
    final cache = buildCache((key) async {
      loadCount += 1;
      return null;
    });

    expect(await cache.load('song-without-cover'), isNull);
    expect(await cache.load('song-without-cover'), isNull);
    expect(loadCount, 1);
  });

  test('命中磁盘缓存时不再回调加载器', () async {
    var loadCount = 0;
    final first = buildCache((key) async {
      loadCount += 1;
      return Uint8List.fromList(<int>[7, 8, 9]);
    });
    expect(await first.load('song-2'), <int>[7, 8, 9]);

    // 新建实例模拟重启：内存已清空，磁盘仍在。
    final second = buildCache((key) async {
      loadCount += 1;
      return null;
    });
    expect(await second.load('song-2'), <int>[7, 8, 9]);
    expect(loadCount, 1);
  });

  test('超过内存预算时淘汰最久未使用的一张', () async {
    var loadCount = 0;
    // 关闭磁盘层，单独验证内存淘汰。
    final cache = ArtworkCache(
      (key) async {
        loadCount += 1;
        return Uint8List.fromList(List<int>.filled(1024, 1));
      },
      memoryBudget: 2048,
      directoryProvider: () async => null,
    );

    await cache.load('a');
    await cache.load('b');
    await cache.load('c');
    expect(loadCount, 3);

    // a 已被淘汰，重新加载会再次回调；c 仍在内存中不会。
    await cache.load('a');
    expect(loadCount, 4);
    await cache.load('c');
    expect(loadCount, 4);
  });

  test('缺少缓存目录时退化为纯内存缓存', () async {
    var loadCount = 0;
    final cache = ArtworkCache(
      (key) async {
        loadCount += 1;
        return Uint8List.fromList(<int>[4, 5]);
      },
      directoryProvider: () async => null,
    );

    expect(await cache.load('song-3'), <int>[4, 5]);
    expect(await cache.load('song-3'), <int>[4, 5]);
    expect(loadCount, 1);
  });

  test('超过单张上限的封面不落盘', () async {
    final large = Uint8List.fromList(List<int>.filled(64, 2));
    final cache = ArtworkCache(
      (key) async => large,
      maxEntryBytes: 32,
      directoryProvider: () async => directory,
    );
    expect(await cache.load('song-4'), large);
    final files =
        await directory.list().where((entity) => entity is File).toList();
    expect(files, isEmpty);
  });
}
