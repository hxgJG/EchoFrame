import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'app_storage_repository.dart';

class PlatformAppStorageRepository implements AppStorageRepository {
  const PlatformAppStorageRepository({
    MethodChannel channel = const MethodChannel('echoframe/app_storage'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<Map<String, Object?>?> load() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final value = await _channel.invokeMapMethod<String, Object?>('load');
      return value;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> save(Map<String, Object?> value) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('save', value);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<AppBackupInfo?> createBackup(Map<String, Object?> value) async {
    if (!Platform.isAndroid) {
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
    if (!Platform.isAndroid) {
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
    if (!Platform.isAndroid) {
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
