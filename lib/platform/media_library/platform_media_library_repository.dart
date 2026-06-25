import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../../core/lyrics/lrc_parser.dart';
import '../../core/models/media_item.dart';
import '../../core/subtitles/ass_parser.dart';
import '../../core/subtitles/srt_parser.dart';
import 'media_library_repository.dart';

class PlatformMediaLibraryRepository implements MediaLibraryRepository {
  const PlatformMediaLibraryRepository({
    MethodChannel channel = const MethodChannel('echoframe/media_library'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<MediaLibraryScanResult> scan(MediaLibraryScanFilter filter) async {
    if (!Platform.isAndroid) {
      return MediaLibraryScanResult(
        status: MediaLibraryScanStatus.unsupported,
        message: Platform.isIOS ? 'iOS 将在导入流程阶段接入文件选择器。' : '当前平台暂未接入媒体库扫描。',
      );
    }

    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'scan',
        filter.toJson(),
      );
      if (raw == null) {
        return const MediaLibraryScanResult(
          status: MediaLibraryScanStatus.failed,
          message: '平台侧没有返回扫描结果。',
        );
      }
      final status = raw['status'] as String? ?? 'failed';
      final message = raw['message'] as String? ?? '';
      if (status == 'permissionDenied') {
        return MediaLibraryScanResult(
          status: MediaLibraryScanStatus.permissionDenied,
          message: message.isEmpty ? '需要授权读取本机音频/视频。' : message,
        );
      }
      if (status != 'completed') {
        return MediaLibraryScanResult(
          status: MediaLibraryScanStatus.failed,
          message: message.isEmpty ? '媒体库扫描失败。' : message,
        );
      }
      return MediaLibraryScanResult(
        status: MediaLibraryScanStatus.completed,
        audioItems: _parseItems(raw['audioItems'], MediaKind.audio),
        videoItems: _parseItems(raw['videoItems'], MediaKind.video),
        message: message,
      );
    } on PlatformException catch (error) {
      return MediaLibraryScanResult(
        status: error.code == 'permissionDenied'
            ? MediaLibraryScanStatus.permissionDenied
            : MediaLibraryScanStatus.failed,
        message: error.message ?? '媒体库扫描失败。',
      );
    } on MissingPluginException {
      return const MediaLibraryScanResult(
        status: MediaLibraryScanStatus.unsupported,
        message: '当前平台尚未注册媒体库扫描插件。',
      );
    }
  }

  Future<MediaLibraryScanResult> restoreLastScan() async {
    if (!Platform.isAndroid) {
      return const MediaLibraryScanResult(
        status: MediaLibraryScanStatus.unsupported,
        message: '当前平台暂未接入媒体库扫描快照。',
      );
    }

    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'restoreLastScan',
      );
      if (raw == null || raw['status'] != 'completed') {
        return const MediaLibraryScanResult(
          status: MediaLibraryScanStatus.unsupported,
          message: '暂无可恢复的媒体库快照。',
        );
      }
      return MediaLibraryScanResult(
        status: MediaLibraryScanStatus.completed,
        audioItems: _parseItems(raw['audioItems'], MediaKind.audio),
        videoItems: _parseItems(raw['videoItems'], MediaKind.video),
        message: raw['message'] as String? ?? '',
      );
    } on PlatformException catch (error) {
      return MediaLibraryScanResult(
        status: MediaLibraryScanStatus.failed,
        message: error.message ?? '恢复媒体库快照失败。',
      );
    } on MissingPluginException {
      return const MediaLibraryScanResult(
        status: MediaLibraryScanStatus.unsupported,
        message: '当前平台尚未注册媒体库扫描插件。',
      );
    }
  }

  List<MediaItem> _parseItems(Object? value, MediaKind fallbackKind) {
    if (value is! List<Object?>) {
      return const <MediaItem>[];
    }
    return value
        .whereType<Map<Object?, Object?>>()
        .map((item) => _parseItem(item, fallbackKind))
        .whereType<MediaItem>()
        .toList(growable: false);
  }

  MediaItem? _parseItem(Map<Object?, Object?> item, MediaKind fallbackKind) {
    final id = item['id']?.toString();
    final title = item['title']?.toString();
    final path = item['path']?.toString();
    if (id == null || title == null || path == null) {
      return null;
    }
    final kindText = item['kind']?.toString();
    final kind = kindText == 'video'
        ? MediaKind.video
        : kindText == 'audio'
            ? MediaKind.audio
            : fallbackKind;
    final durationMs = _asInt(item['durationMs']);
    final addedAtMs = _asInt(item['addedAtMs']);
    final sizeBytes = _asInt(item['sizeBytes']);
    final folder = item['folder']?.toString() ?? _folderOf(path);
    return MediaItem(
      id: id,
      kind: kind,
      title: title,
      artist: item['artist']?.toString() ?? 'Unknown artist',
      album: item['album']?.toString() ?? 'Unknown album',
      duration: Duration(milliseconds: durationMs),
      path: path,
      folder: folder,
      addedAt: addedAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(addedAtMs)
          : DateTime.now(),
      accentColor: _accentFor(id, kind),
      resolution: item['resolution']?.toString(),
      fileSizeBytes: sizeBytes,
      fileSizeLabel: sizeBytes > 0 ? _formatSize(sizeBytes) : null,
      formatLabel: item['format']?.toString(),
      lyrics: parseLrc(item['lyricsText']?.toString() ?? ''),
      subtitles: kind == MediaKind.video
          ? _parseSubtitles(
              srtText: item['subtitleText']?.toString() ?? '',
              assText: item['assSubtitleText']?.toString() ?? '',
            )
          : const <SubtitleCue>[],
    );
  }

  List<SubtitleCue> _parseSubtitles({
    required String srtText,
    required String assText,
  }) {
    final srtCues = parseSrt(srtText);
    if (srtCues.isNotEmpty) {
      return srtCues;
    }
    return parseAss(assText);
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

  String _folderOf(String path) {
    final index = path.lastIndexOf('/');
    return index <= 0 ? '/' : path.substring(0, index);
  }

  String _formatSize(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) {
      return '${(bytes / gb).toStringAsFixed(1)} GB';
    }
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(0)} MB';
    }
    return '${(bytes / kb).toStringAsFixed(0)} KB';
  }

  Color _accentFor(String id, MediaKind kind) {
    const audioPalette = <Color>[
      Color(0xFF2F6BFF),
      Color(0xFFFF6E68),
      Color(0xFF1FC7A6),
      Color(0xFFFFB020),
      Color(0xFF7C6FF6),
    ];
    const videoPalette = <Color>[
      Color(0xFF2563EB),
      Color(0xFF00A88F),
      Color(0xFFE85D75),
      Color(0xFF7C6FF6),
    ];
    final palette = kind == MediaKind.audio ? audioPalette : videoPalette;
    return palette[id.hashCode.abs() % palette.length];
  }
}
