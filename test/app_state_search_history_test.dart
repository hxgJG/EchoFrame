import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/app/app_state.dart';
import 'package:lumio/platform/app_storage/app_storage_repository.dart';
import 'package:lumio/platform/media_library/media_library_repository.dart';
import 'package:lumio/platform/media_library/platform_media_library_repository.dart';

class _Storage implements AppStorageRepository {
  Map<String, Object?> data = <String, Object?>{
    'schemaVersion': 2,
    'audioItems': <Object?>[],
    'videoItems': <Object?>[],
    'playlists': <Object?>[],
    'queueIds': <String>[],
    'recentSearches': <String>['旧关键词'],
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
  @override
  Future<MediaLibraryScanResult> scan(MediaLibraryScanFilter filter) async =>
      const MediaLibraryScanResult(status: MediaLibraryScanStatus.completed);
  @override
  Future<List<MediaSource>> listSources() async => const <MediaSource>[];
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late LumioAppState app;
  late _Storage storage;
  setUp(() async {
    for (final name in <String>[
      'lumio/playback',
      'lumio/desktop_lyrics',
      'lumio/media_library',
      'lumio/app_storage',
      'lumio/audio_spectrum',
    ]) {
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    storage = _Storage();
    app = LumioAppState(
        appStorageRepository: storage, mediaLibraryRepository: _Library());
    await app.startupReady;
  });

  test('恢复上次的搜索历史', () {
    expect(app.recentSearches, <String>['旧关键词']);
  });

  test('新搜索排最前，忽略大小写与空格去重', () {
    app.recordSearch('  Artist  ');
    app.recordSearch('ARTIST');
    // 已在首位且忽略大小写相同，保留首次的写法，不重复记录。
    expect(app.recentSearches, <String>['Artist', '旧关键词']);
  });

  test('空白或过长关键词不记录', () {
    app.recordSearch('   ');
    app.recordSearch('x' * 200);
    expect(app.recentSearches, <String>['旧关键词']);
  });

  test('最多保留 8 条，超出淘汰最旧', () {
    for (var i = 0; i < 12; i++) {
      app.recordSearch('词 $i');
    }
    expect(app.recentSearches.length, LumioAppState.maxRecentSearches);
    expect(app.recentSearches.first, '词 11');
    expect(app.recentSearches.contains('词 3'), isFalse);
  });

  test('删除单条与清空都会落盘', () {
    app.recordSearch('保留');
    app.removeRecentSearch('旧关键词');
    expect(app.recentSearches, <String>['保留']);
    expect(storage.data['recentSearches'], <String>['保留']);
    app.clearRecentSearches();
    expect(app.recentSearches, isEmpty);
    expect(storage.data['recentSearches'], isEmpty);
  });
}
