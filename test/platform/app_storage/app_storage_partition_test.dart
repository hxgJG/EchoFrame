import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/platform/app_storage/app_storage_repository.dart';
import 'package:lumio/platform/app_storage/platform_app_storage_repository.dart';

void main() {
  const snapshot = <String, Object?>{
    'schemaVersion': 1,
    'audioItems': <Object?>['audio'],
    'videoItems': <Object?>['video'],
    'playlists': <Object?>['playlist'],
    'settings': <String, Object?>{'theme': 'dark'},
    'positionMs': 1200,
  };

  test('session partition excludes large and low-frequency collections', () {
    final value = appStoragePartitionValue(
      snapshot,
      AppStoragePartition.session,
    );

    expect(value['settings'], isNotNull);
    expect(value['positionMs'], 1200);
    expect(value, isNot(contains('audioItems')));
    expect(value, isNot(contains('videoItems')));
    expect(value, isNot(contains('playlists')));
  });

  test('library and playlists partitions contain only their own payload', () {
    final library = appStoragePartitionValue(
      snapshot,
      AppStoragePartition.library,
    );
    final playlists = appStoragePartitionValue(
      snapshot,
      AppStoragePartition.playlists,
    );

    expect(library.keys, <String>{
      'schemaVersion',
      'audioItems',
      'videoItems',
    });
    expect(playlists.keys, <String>{'schemaVersion', 'playlists'});
  });
}
