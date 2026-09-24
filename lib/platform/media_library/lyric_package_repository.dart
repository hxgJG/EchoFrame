import 'dart:io';
import 'package:flutter/services.dart';
import '../../core/models/media_item.dart';

class LyricPackageRepository {
  static bool get supported => Platform.isMacOS || Platform.isAndroid;
  static const _channel = MethodChannel('lumio/media_library');

  Future<Map<String, String>> fingerprints(List<MediaItem> items) async {
    if (!supported || items.isEmpty) return {};
    try {
      final result = await _channel
          .invokeMapMethod<String, Object?>('lyricAudioFingerprints', {
        'items': items
            .map((item) =>
                {'id': item.id, 'path': item.path, 'size': item.fileSizeBytes})
            .toList(),
      });
      return {
        for (final entry in (result ?? {}).entries)
          if (entry.value is String &&
              RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(entry.value as String))
            entry.key: entry.value as String
      };
    } on MissingPluginException {
      return {};
    } on PlatformException {
      return {};
    }
  }

  Future<(Uint8List, String)?> pick() async {
    if (!supported) throw UnsupportedError('当前平台暂不支持歌词包。');
    final result =
        await _channel.invokeMapMethod<Object?, Object?>('importLyricsPackage');
    if (result == null || result['status'] == 'cancelled') return null;
    if (result['status'] != 'completed' || result['bytes'] is! Uint8List) {
      throw FormatException(result['message']?.toString() ?? '读取歌词包失败。');
    }
    return (
      result['bytes'] as Uint8List,
      result['fileName']?.toString() ?? '歌词包.zip'
    );
  }
}
