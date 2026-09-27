import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/app/app_state.dart';
import 'package:lumio/core/device_transfer/transfer_protocol.dart';
import 'package:lumio/core/lyrics/lyric_library.dart';
import 'package:lumio/core/models/media_item.dart';
import 'package:lumio/platform/app_storage/app_storage_repository.dart';
import 'package:lumio/platform/device_transfer/received_transfer_store.dart';
import 'package:lumio/platform/media_library/platform_media_library_repository.dart';
import 'package:lumio/platform/media_library/media_library_repository.dart';

import '../../support/transfer_fixtures.dart';

class _Storage implements AppStorageRepository {
  Map<String, Object?> data = {
    'schemaVersion': 2,
    'audioItems': [],
    'videoItems': []
  };
  bool fail = false;
  @override
  Future<Map<String, Object?>?> load() async => data;
  @override
  Future<void> save(Map<String, Object?> value,
      {required Set<AppStoragePartition> partitions}) async {
    if (fail) throw const FileSystemException('test disk full');
    data = {
      ...data,
      ...Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map)
    };
  }

  @override
  Future<AppBackupInfo?> createBackup(Map<String, Object?> value) async => null;
  @override
  Future<AppBackupInfo?> latestBackup() async => null;
  @override
  Future<Map<String, Object?>?> restoreLatestBackup() async => null;
}

class _Library extends PlatformMediaLibraryRepository {
  @override
  Future<MediaLibraryScanResult> scan(MediaLibraryScanFilter filter) async =>
      const MediaLibraryScanResult(status: MediaLibraryScanStatus.completed);
  @override
  Future<List<MediaSource>> listSources() async => [];
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReceivedTransferStore store;
  late LumioAppState app;
  late _Storage storage;
  Future<LumioAppState> createApp() async {
    final state = LumioAppState(
        appStorageRepository: storage, mediaLibraryRepository: _Library());
    for (var i = 0; i < 200 && state.lyricLibraryBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(state.lyricLibraryBusy, false);
    return state;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lumio-import-');
    store = ReceivedTransferStore(root);
    await store.initialize();
    storage = _Storage();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('lumio/app_storage'), (call) async {
      if (call.method == 'transferStorage')
        return {'path': root.path, 'availableBytes': 1 << 40};
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('lumio/device_transfer'), (call) async {
      if (call.method == 'openMedia') {
        final file = File((call.arguments as Map)['path'] as String);
        final bytes = await file.readAsBytes();
        return {
          'handle': 'fixture',
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
          'extension': 'mp3'
        };
      }
      return null;
    });
    for (final name in [
      'lumio/playback',
      'lumio/desktop_lyrics',
      'lumio/media_library'
    ]) {
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    app = await createApp();
  });
  tearDown(() async {
    app.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await root.delete(recursive: true);
  });

  Future<ReceivedTransferReceipt> receive(List<int> bytes,
      {TransferResourceKind kind = TransferResourceKind.audio,
      String title = '新歌名',
      TransferImportPolicy policy = const TransferImportPolicy()}) async {
    final resource = transferResource(bytes: bytes, kind: kind, title: title);
    final receipt = await store.prepare(
        peerDigest: transferPeerDigest,
        resource: resource,
        policy: policy,
        baseVersion: app.transferImportContext);
    await store.append(receipt.jobId, offset: 0, bytes: bytes);
    return store.finish(receipt.jobId);
  }

  Future<void> apply(ReceivedTransferReceipt receipt) async =>
      app.importTransfer(receipt, await store.verifiedFile(receipt.jobId));

  test('接收媒体持久入库，空扫描与重启不会丢失私有文件索引', () async {
    final receipt = await receive([1, 2, 3]);
    await apply(receipt);
    expect(app.audioItems.single.title, '新歌名');
    final path = app.audioItems.single.path;
    await app.scanMediaLibrary();
    expect(app.audioItems.single.path, path);
    app.dispose();
    app = await createApp();
    expect(app.audioItems.single.path, path);
    expect(app.audioItems.single.availability, 'available');
    expect((await app.findTransferDuplicate(receipt.resource))?.path, path);
    await apply(receipt);
    expect(app.audioItems.length, 1);
  });
  test('歌词先到、歌曲后到，内容指纹跨改名匹配并应用展示信息', () async {
    final item = MediaItem(
        id: 'source',
        kind: MediaKind.audio,
        title: '原设备修改后的歌名',
        artist: '艺术家',
        album: '专辑',
        duration: const Duration(seconds: 120),
        path: '/unused/旧名.mp3',
        folder: '',
        addedAt: DateTime.now(),
        accentColor: Colors.teal,
        fileSizeBytes: 3,
        lyrics: const [LyricLine(time: Duration.zero, text: '测试歌词')]);
    final lyric = LyricLibraryEntry.fromMedia(item,
        fingerprint: 'sha256:${sha256.convert([1, 2, 3])}');
    final payload =
        utf8.encode(jsonEncode({'version': 1, 'lyric': lyric.toJson()}));
    await apply(await receive(payload, kind: TransferResourceKind.lyrics));
    expect(app.audioItems, isEmpty);
    expect(app.lyricLibraryEntries.length, 1);
    await apply(await receive([1, 2, 3], title: '另一台设备的文件名'));
    expect(app.audioItems.single.lyrics.single.text, '测试歌词');
    expect(app.audioItems.single.title, '原设备修改后的歌名');
  });
  test('同名不同内容保留两份，保存失败不显示已入库', () async {
    final first = await receive([1, 2, 3]);
    await apply(first);
    final second = await receive([4, 5, 6]);
    storage.fail = true;
    await expectLater(apply(second), throwsA(isA<FileSystemException>()));
    expect(app.audioItems.length, 1);
    storage.fail = false;
    await apply(second);
    expect(app.audioItems.length, 2);
    expect(app.audioItems.map((e) => e.path).toSet().length, 2);
  });
  test('旧下载基线不能覆盖接收期间变化，需明确重新确认', () async {
    final old = await receive([1, 2, 3]);
    await apply(await receive([4, 5, 6]));
    await expectLater(apply(old), throwsA(isA<StateError>()));
    expect(app.audioItems.length, 1);
    await app.importTransfer(old, await store.verifiedFile(old.jobId),
        reconfirm: true);
    expect(app.audioItems.length, 2);
  });
}
