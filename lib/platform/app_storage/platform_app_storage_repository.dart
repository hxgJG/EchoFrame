import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'app_storage_repository.dart';

class PlatformAppStorageRepository implements AppStorageRepository {
  const PlatformAppStorageRepository({
    MethodChannel channel = const MethodChannel('lumio/app_storage'),
  }) : _channel = channel;

  final MethodChannel _channel;

  bool get _isSupportedPlatform =>
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.operatingSystem == 'ohos';

  @override
  Future<Map<String, Object?>?> load() async {
    if (!_isSupportedPlatform) {
      return null;
    }
    try {
      final merged = <String, Object?>{};
      for (final partition in AppStoragePartition.values) {
        final value = await _channel.invokeMapMethod<String, Object?>(
          'loadPartition',
          <String, Object?>{'partition': partition.name},
        );
        if (value != null) {
          merged.addAll(value);
        }
      }
      return merged.isEmpty ? null : merged;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> save(
    Map<String, Object?> value, {
    required Set<AppStoragePartition> partitions,
  }) async {
    if (!_isSupportedPlatform) {
      return;
    }
    try {
      await Future.wait(
        partitions.map(
          (partition) => _channel.invokeMethod<void>(
            'savePartition',
            <String, Object?>{
              'partition': partition.name,
              'value': appStoragePartitionValue(value, partition),
            },
          ),
        ),
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<AppBackupInfo?> createBackup(Map<String, Object?> value) async {
    if (!_isSupportedPlatform) {
      return null;
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'createBackup',
        value,
      );
      return _parseBackupInfo(result);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<Map<String, Object?>?> restoreLatestBackup() async {
    if (!_isSupportedPlatform) {
      return null;
    }
    try {
      return _channel.invokeMapMethod<String, Object?>('restoreLatestBackup');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<AppBackupInfo?> latestBackup() async {
    if (!_isSupportedPlatform) {
      return null;
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'latestBackup',
      );
      return _parseBackupInfo(result);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  AppBackupInfo? _parseBackupInfo(Map<String, Object?>? value) {
    if (value == null) {
      return null;
    }
    final path = value['path']?.toString();
    final updatedAtMs = _asInt(value['updatedAtMs']);
    if (path == null || path.isEmpty || updatedAtMs <= 0) {
      return null;
    }
    return AppBackupInfo(
      path: path,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
    );
  }

  int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is double) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

Map<String, Object?> appStoragePartitionValue(
  Map<String, Object?> value,
  AppStoragePartition partition,
) {
  return switch (partition) {
    AppStoragePartition.library => <String, Object?>{
        'schemaVersion': value['schemaVersion'],
        'audioItems': value['audioItems'],
        'videoItems': value['videoItems'],
      },
    AppStoragePartition.playlists => <String, Object?>{
        'schemaVersion': value['schemaVersion'],
        'playlists': value['playlists'],
      },
    AppStoragePartition.session => <String, Object?>{
        for (final entry in value.entries)
          if (entry.key != 'audioItems' &&
              entry.key != 'videoItems' &&
              entry.key != 'playlists')
            entry.key: entry.value,
      },
  };
}
