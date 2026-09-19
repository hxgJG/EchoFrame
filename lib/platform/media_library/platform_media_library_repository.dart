import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../../core/lyrics/lrc_parser.dart';
import '../../core/lyrics/lyrics_export.dart';
import '../../core/models/media_item.dart';
import '../../core/subtitles/ass_parser.dart';
import '../../core/subtitles/srt_parser.dart';
import 'lyrics_import.dart';
import 'lyrics_export_result.dart';
import 'media_file_operation.dart';
import 'media_library_repository.dart';

class PlatformMediaLibraryRepository implements MediaLibraryRepository {
  const PlatformMediaLibraryRepository({
    MethodChannel channel = const MethodChannel('lumio/media_library'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<LyricsExportResult> exportLyrics(LyricsExportFile file) async {
    if (!Platform.isMacOS && !Platform.isAndroid) {
      return const LyricsExportResult(
          status: LyricsExportStatus.unsupported, message: '当前平台暂不支持歌词导出。');
    }
    try {
      final raw =
          await _channel.invokeMapMethod<Object?, Object?>('exportLyrics', {
        'fileName': file.fileName,
        'bytes': file.bytes,
      });
      return raw == null
          ? const LyricsExportResult(
              status: LyricsExportStatus.failed, message: '未收到导出结果。')
          : LyricsExportResult.fromJson(raw);
    } on MissingPluginException {
      return const LyricsExportResult(
          status: LyricsExportStatus.unsupported,
          message: '当前版本未注册歌词导出，请更新应用。');
    } on PlatformException catch (error) {
      return LyricsExportResult(
          status: LyricsExportStatus.failed,
          message: error.message ?? '歌词导出失败。');
    }
  }

  bool get _isSupportedPlatform =>
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.operatingSystem == 'ohos';

  @override
  Future<List<MediaSource>> addSources() async {
    if (!Platform.isMacOS) {
      return const <MediaSource>[];
    }
    try {
      final raw = await _channel.invokeListMethod<Object?>('addSources');
      return _parseSources(raw);
    } on PlatformException {
      return const <MediaSource>[];
    } on MissingPluginException {
      return const <MediaSource>[];
    }
  }

  @override
  Future<List<MediaSource>> listSources() async {
    if (!Platform.isMacOS) {
      return const <MediaSource>[];
    }
    try {
      final raw = await _channel.invokeListMethod<Object?>('listSources');
      return _parseSources(raw);
    } on PlatformException {
      return const <MediaSource>[];
    } on MissingPluginException {
      return const <MediaSource>[];
    }
  }

  @override
  Future<void> removeSource(String sourceId) async {
    if (!Platform.isMacOS) {
      return;
    }
    await _channel.invokeMethod<void>(
      'removeSource',
      <String, Object?>{'sourceId': sourceId},
    );
  }

  @override
  Future<void> cancelScan() async {
    if (!_isSupportedPlatform) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('cancelScan');
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<LyricsImportResult> importLyrics() => _importLyrics('importLyrics');

  @override
  Future<LyricsImportResult> importLyricsText() =>
      _importLyrics('importLyricsText');

  Future<LyricsImportResult> _importLyrics(String method) async {
    if (!_isSupportedPlatform) {
      return const LyricsImportResult(
        status: LyricsImportStatus.unsupported,
        message: '当前平台暂不支持导入歌词文件。',
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        method,
      );
      if (raw == null) {
        return const LyricsImportResult(
          status: LyricsImportStatus.failed,
          message: '平台侧没有返回歌词文件。',
        );
      }
      return LyricsImportResult.fromJson(raw);
    } on PlatformException catch (error) {
      return LyricsImportResult(
        status: LyricsImportStatus.failed,
        message: error.message ?? '歌词文件导入失败。',
      );
    } on MissingPluginException {
      return const LyricsImportResult(
        status: LyricsImportStatus.unsupported,
        message: '当前平台尚未注册歌词文件选择器。',
      );
    }
  }

  @override
  Future<MediaLibraryScanResult> scan(MediaLibraryScanFilter filter) async {
    if (!_isSupportedPlatform) {
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
      if (status == 'cancelled') {
        return MediaLibraryScanResult(
          status: MediaLibraryScanStatus.cancelled,
          message: message.isEmpty ? '已取消，媒体库保持不变。' : message,
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
    if (!_isSupportedPlatform) {
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

  @override
  Future<MediaFileOperationResult> performFileOperation(
    MediaFileOperationRequest request,
  ) async {
    if (!Platform.isAndroid && !Platform.isMacOS) {
      return const MediaFileOperationResult(
        status: MediaFileOperationStatus.unsupported,
        message: '当前平台暂未接入真实媒体文件操作。',
      );
    }
    if (!request.isValid) {
      return const MediaFileOperationResult(
        status: MediaFileOperationStatus.failed,
        message: '文件操作参数无效。',
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'performFileOperation',
        request.toJson(),
      );
      return MediaFileOperationResult.fromJson(
        raw ?? const <String, Object?>{'status': 'failed'},
      );
    } on PlatformException catch (error) {
      return MediaFileOperationResult(
        status: MediaFileOperationStatus.failed,
        message: error.message ?? '文件操作失败。',
      );
    } on MissingPluginException {
      return const MediaFileOperationResult(
        status: MediaFileOperationStatus.unsupported,
        message: '当前平台尚未注册真实媒体文件操作。',
      );
    }
  }

  List<MediaSource> _parseSources(List<Object?>? value) {
    return (value ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(MediaSource.fromJson)
        .where((source) => source.id.isNotEmpty)
        .toList(growable: false);
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
      artist: item['artist']?.toString() ?? '未知艺术家',
      album: item['album']?.toString() ?? '未知专辑',
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
      sourceId: item['sourceId']?.toString(),
      relativePath: item['relativePath']?.toString(),
      availability: item['availability']?.toString() ?? 'available',
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
      Color(0xFF276B5B),
      Color(0xFF326C66),
      Color(0xFF566C61),
      Color(0xFF387565),
      Color(0xFF426D59),
    ];
    const videoPalette = <Color>[
      Color(0xFF9B5141),
      Color(0xFFA15749),
      Color(0xFF945347),
      Color(0xFF905A4C),
      Color(0xFF995745),
    ];
    final palette = kind == MediaKind.audio ? audioPalette : videoPalette;
    return palette[id.hashCode.abs() % palette.length];
  }
}
