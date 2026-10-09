import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/app/app_state.dart';
import 'package:lumio/core/models/media_item.dart';
import 'package:lumio/core/models/lumio_settings.dart';
import 'package:lumio/core/backup/portable_backup_format.dart';
import 'package:lumio/platform/app_storage/app_storage_repository.dart';
import 'package:lumio/platform/media_library/media_library_repository.dart';
import 'package:lumio/platform/media_library/platform_media_library_repository.dart';

class _Storage implements AppStorageRepository {
  Map<String, Object?> data = {
    'schemaVersion': 2,
    'portableRestorePending': true,
    'audioItems': [
      {
        'id': 'old-id',
        'kind': 'audio',
        'path': '/external/song.mp3',
        'title': '自定义名字',
        'artist': '自定义歌手',
        'album': '自定义专辑',
        'isFavorite': true,
        'shuffleWeight': 6,
        'hasCustomLyrics': true,
        'lyrics': [
          {'timeMs': 1000, 'text': '自定义歌词'}
        ],
        'lastPositionMs': 12000,
        'availability': 'permissionRequired',
      }
    ],
    'videoItems': [],
    'playlists': [
      {
        'id': 'p1',
        'name': '歌单',
        'mediaIds': ['old-id']
      }
    ],
    'queueIds': ['old-id'],
    'currentItemId': 'old-id',
    'positionMs': 12000,
  };
  @override
  Future<Map<String, Object?>?> load() async => data;
  @override
  Future<void> save(Map<String, Object?> value,
      {required Set<AppStoragePartition> partitions}) async {
    data = value;
  }

  @override
  Future<AppBackupInfo?> createBackup(Map<String, Object?> value) async => null;
  @override
  Future<AppBackupInfo?> latestBackup() async => null;
  @override
  Future<Map<String, Object?>?> restoreLatestBackup() async => null;
}

class _Library extends PlatformMediaLibraryRepository {
  MediaLibraryScanResult result =
      const MediaLibraryScanResult(status: MediaLibraryScanStatus.completed);
  @override
  Future<MediaLibraryScanResult> scan(MediaLibraryScanFilter filter) async =>
      result;
  @override
  Future<List<MediaSource>> listSources() async => [];
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late LumioAppState app;
  late _Library library;
  late _Storage storage;
  setUp(() async {
    for (final name in [
      'lumio/playback',
      'lumio/desktop_lyrics',
      'lumio/media_library',
      'lumio/app_storage'
    ]) {
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    library = _Library();
    storage = _Storage();
    app = LumioAppState(
        appStorageRepository: storage, mediaLibraryRepository: library);
    for (var i = 0; i < 200 && app.lyricLibraryBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(app.lyricLibraryBusy, false);
  });
  tearDown(() {
    app.dispose();
  });

  test('迁移后空扫描保留尚未授权的媒体和歌单', () async {
    await app.scanMediaLibrary();
    expect(app.audioItems.single.id, 'old-id');
    expect(app.audioItems.single.lyrics.single.text, '自定义歌词');
    expect(app.playlists.single.mediaIds, ['old-id']);
    expect(app.position.inMilliseconds, 12000);
  });

  test('重新授权后以新原生标识关联旧歌词、歌单及进度', () async {
    library.result = MediaLibraryScanResult(
        status: MediaLibraryScanStatus.completed,
        audioItems: [
          MediaItem.fromJson({
            'id': 'new-id',
            'kind': 'audio',
            'path': '/external/song.mp3',
            'title': '原文件名字',
            'artist': '原标签',
            'availability': 'available',
          })
        ]);
    await app.scanMediaLibrary();
    final item = app.audioItems.single;
    expect(item.id, 'new-id');
    expect(item.title, '自定义名字');
    expect(item.artist, '自定义歌手');
    expect(item.album, '自定义专辑');
    expect(item.lyrics.single.text, '自定义歌词');
    expect(item.isFavorite, true);
    expect(item.shuffleWeight, 6);
    expect(item.lastPosition.inMilliseconds, 12000);
    expect(app.playlists.single.mediaIds, ['new-id']);
    expect(app.currentItem?.id, 'new-id');
    expect(app.position.inMilliseconds, 12000);
    expect(app.isPlaying, false);
  });

  test('先恢复跨端数据、后添加原文件，恢复歌曲信息与全部引用', () async {
    app.dispose();
    final old = (storage.data['audioItems'] as List).single as Map;
    old['durationMs'] = 240000;
    old['fileSizeBytes'] = 1234;
    old['backupIdentity'] = {
      'key': 'a' * 32,
      'fileName': 'song.mp3',
      'fingerprint': 'sha256:${'b' * 64}'
    };
    storage.data['settings'] = const LumioSettings().toJson();
    storage.data['receivedMedia'] = {'version': 1, 'items': []};
    storage.data['lyricLibrary'] = {'version': 1, 'entries': []};
    storage.data = portableState(storage.data)
      ..['portableRestorePending'] = true;
    app = LumioAppState(
        appStorageRepository: storage, mediaLibraryRepository: library);
    for (var i = 0; i < 200 && app.lyricLibraryBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await app.scanMediaLibrary();
    expect(app.audioItems.single.sourceId, portableMediaSource);
    app.togglePlaying();
    expect(app.isPlaying, false);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('lumio/media_library'), (call) async {
      if (call.method == 'backupMediaFingerprints')
        return {'/new-device/renamed.mp3': 'sha256:${'b' * 64}'};
      return null;
    });
    library.result = MediaLibraryScanResult(
        status: MediaLibraryScanStatus.completed,
        audioItems: [
          MediaItem.fromJson({
            'id': 'android-local-id',
            'kind': 'audio',
            'path': '/new-device/renamed.mp3',
            'title': '原文件曲名',
            'artist': '原标签',
            'durationMs': 240005,
            'fileSizeBytes': 1234,
          })
        ]);
    await app.scanMediaLibrary();
    final item = app.audioItems.single;
    expect(item.id, 'android-local-id');
    expect(item.sourceId, isNot(portableMediaSource));
    expect(item.title, '自定义名字');
    expect(item.artist, '自定义歌手');
    expect(item.lyrics.single.text, '自定义歌词');
    expect(item.isFavorite, true);
    expect(item.shuffleWeight, 6);
    expect(app.playlists.single.mediaIds, [item.id]);
    expect(app.queueItems.single.id, item.id);
    expect(app.currentItem?.id, item.id);
    expect(app.position.inMilliseconds, 12000);
    expect(app.isPlaying, false);
  });
}
