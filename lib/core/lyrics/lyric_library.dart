import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/media_item.dart';
import 'lrc_parser.dart';
import 'lyrics_export.dart';

const lyricPackageLimit = 32 * 1024 * 1024;
const lyricLibraryLimit = 5000;
const _manifestName = 'lumio-lyrics.json';

String newLyricEntryId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
    '${Random.secure().nextInt(1 << 32).toRadixString(36)}';

String _normal(String text) =>
    text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
String _aliasText(Object? value) {
  if (value is! String || value.length > 1024)
    throw const FormatException('歌曲别名无效。');
  return value;
}

String lyricAudioName(String path) => path.split(RegExp(r'[/\\]')).last;
String lyricStateSignature(MediaItem item) => jsonEncode([
      LyricTiming.signatureFor(item.lyrics),
      item.lyricTiming.offsetMs,
      item.hasCustomLyrics,
      item.title,
      item.artist,
      item.album
    ]);

List<Map<String, String>> rememberLyricAlias(MediaItem item,
    {Map<String, String>? additional}) {
  final values = <Map<String, String>>[
    ...item.lyricMatchAliases,
    {'title': item.title, 'artist': item.artist, 'album': item.album},
    if (additional != null) additional,
  ];
  final unique = <String, Map<String, String>>{};
  for (final value in values) unique[jsonEncode(value)] = value;
  // 保留最早的原始信息，另保留最近 31 次名称变化。
  final list = unique.values.toList();
  return list.length <= 32
      ? list
      : [list.first, ...list.skip(list.length - 31)];
}

class LyricLibraryEntry {
  const LyricLibraryEntry(
      {required this.id,
      required this.title,
      required this.artist,
      required this.album,
      required this.fileName,
      required this.durationMs,
      required this.fileSize,
      required this.lyrics,
      required this.offsetMs,
      this.overwrite = true,
      this.active = true,
      this.source = '',
      this.fingerprint = '',
      this.aliases = const [],
      this.syncMetadata = true,
      this.handled = const {},
      this.excluded = const []});

  final String id, title, artist, album, fileName, source;
  final String fingerprint;
  final List<Map<String, String>> aliases;
  final bool syncMetadata;
  final int durationMs, fileSize, offsetMs;
  final List<LyricLine> lyrics;
  final bool overwrite, active;
  // 路径仅用于本机防止反复覆盖用户后续编辑，不进入可迁移歌词包。
  final Map<String, String> handled;
  final List<String> excluded;

  factory LyricLibraryEntry.fromMedia(MediaItem item,
          {String fingerprint = ''}) =>
      LyricLibraryEntry(
          id: newLyricEntryId(),
          title: item.title,
          artist: item.artist,
          album: item.album,
          fingerprint: fingerprint,
          aliases: item.lyricMatchAliases,
          fileName: lyricAudioName(item.path),
          durationMs: item.duration.inMilliseconds,
          fileSize: item.fileSizeBytes,
          lyrics: item.lyrics,
          offsetMs: item.lyricTiming.offsetMs);

  factory LyricLibraryEntry.fromJson(Map<String, Object?> json,
      {bool local = false}) {
    String text(String key) {
      final value = json[key];
      if (value is! String || value.length > 1024)
        throw const FormatException('歌词包歌曲信息无效。');
      return value;
    }

    int number(String key, int min, int max) {
      final value = json[key];
      if (value is! int || value < min || value > max)
        throw const FormatException('歌词包时间或大小无效。');
      return value;
    }

    final raw = json['lyrics'];
    if (raw is! List || raw.isEmpty || raw.length > 20000)
      throw const FormatException('单首歌词行数无效。');
    final lines = <LyricLine>[];
    for (final line in raw) {
      if (line is! Map ||
          line['timeMs'] is! int ||
          line['text'] is! String ||
          (line['timeMs'] as int) < 0 ||
          (line['timeMs'] as int) > 604800000 ||
          (line['text'] as String).length > 4096)
        throw const FormatException('歌词行内容或时间无效。');
      lines.add(LyricLine(
          time: Duration(milliseconds: line['timeMs'] as int),
          text: line['text'] as String));
    }
    if (!lines.any((line) => line.text.trim().isNotEmpty))
      throw const FormatException('歌词内容为空。');
    lines.sort((a, b) => a.time.compareTo(b.time));
    final hash = json['fingerprint']?.toString() ?? '';
    if (hash.isNotEmpty && !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(hash))
      throw const FormatException('音频指纹无效。');
    final rawAliases = json['aliases'] ?? const [];
    if (rawAliases is! List || rawAliases.length > 32)
      throw const FormatException('歌曲别名无效。');
    final aliases = rawAliases.map((raw) {
      if (raw is! Map) throw const FormatException('歌曲别名无效。');
      return {
        for (final key in ['title', 'artist', 'album'])
          key: _aliasText(raw[key])
      };
    }).toList();
    return LyricLibraryEntry(
        id: local ? text('id') : newLyricEntryId(),
        title: text('title'),
        fingerprint: hash,
        aliases: aliases,
        syncMetadata: !local || json['syncMetadata'] != false,
        artist: text('artist'),
        album: text('album'),
        fileName: text('fileName'),
        durationMs: number('durationMs', 0, 604800000),
        fileSize: number('fileSize', 0, 1 << 53),
        lyrics: List.unmodifiable(lines),
        offsetMs: number('offsetMs', -LyricTiming.limitMs, LyricTiming.limitMs),
        overwrite: !local || json['overwrite'] != false,
        active: !local || json['active'] != false,
        source: local ? json['source']?.toString() ?? '' : '',
        handled: local && json['handled'] is Map
            ? Map<String, String>.from(json['handled'] as Map)
            : const {},
        excluded: local && json['excluded'] is List
            ? List<String>.from(json['excluded'] as List)
            : const []);
  }

  String get matchKey => fingerprint.isNotEmpty
      ? fingerprint
      : jsonEncode([
          _normal(title),
          _normal(artist),
          _normal(album),
          _normal(fileName),
          durationMs,
          fileSize
        ]);
  String get contentSignature => jsonEncode([
        LyricTiming.signatureFor(lyrics),
        offsetMs,
        title,
        artist,
        album,
        aliases
      ]);

  LyricLibraryEntry copyWith(
          {bool? active,
          bool? overwrite,
          bool? syncMetadata,
          List<LyricLine>? lyrics,
          int? offsetMs,
          String? source,
          Map<String, String>? handled,
          List<String>? excluded}) =>
      LyricLibraryEntry(
          id: id,
          title: title,
          artist: artist,
          album: album,
          fingerprint: fingerprint,
          aliases: aliases,
          syncMetadata: syncMetadata ?? this.syncMetadata,
          fileName: fileName,
          durationMs: durationMs,
          fileSize: fileSize,
          lyrics: lyrics ?? this.lyrics,
          offsetMs: offsetMs ?? this.offsetMs,
          active: active ?? this.active,
          overwrite: overwrite ?? this.overwrite,
          source: source ?? this.source,
          handled: handled ?? this.handled,
          excluded: excluded ?? this.excluded);

  Map<String, Object?> toJson({bool local = false}) => {
        'title': title,
        'artist': artist,
        'album': album,
        'fingerprint': fingerprint,
        'aliases': aliases,
        'fileName': fileName,
        'durationMs': durationMs,
        'fileSize': fileSize,
        'offsetMs': offsetMs,
        'lyrics': lyrics.map((line) => line.toJson()).toList(),
        if (local) ...{
          'id': id,
          'active': active,
          'overwrite': overwrite,
          'syncMetadata': syncMetadata,
          'source': source,
          'handled': handled,
          'excluded': excluded
        },
      };

  List<MediaItem> candidates(List<MediaItem> items,
      {Map<String, String> fingerprints = const {}}) {
    if (fingerprint.isNotEmpty) {
      final exact = items
          .where((item) =>
              item.kind == MediaKind.audio &&
              fingerprints[item.path] == fingerprint)
          .toList();
      if (exact.isNotEmpty) return exact;
    }
    if (durationMs <= 0) return const [];
    return items.where((item) {
      if (item.kind != MediaKind.audio ||
          item.duration.inMilliseconds <= 0 ||
          (durationMs - item.duration.inMilliseconds).abs() > 1000)
        return false;
      final names = [
        {'title': title, 'artist': artist, 'album': album},
        ...aliases
      ];
      final targetNames = [
        {'title': item.title, 'artist': item.artist, 'album': item.album},
        ...item.lyricMatchAliases
      ];
      final metadata = names.any((name) => targetNames.any((target) =>
          _useful(name['artist']!) &&
          _normal(name['title']!).isNotEmpty &&
          _normal(name['title']!) == _normal(target['title']!) &&
          _normal(name['artist']!) == _normal(target['artist']!) &&
          (!_useful(name['album']!) ||
              !_useful(target['album']!) ||
              _normal(name['album']!) == _normal(target['album']!))));
      final file = fileSize > 0 &&
          fileSize == item.fileSizeBytes &&
          fileName.isNotEmpty &&
          _normal(fileName) == _normal(lyricAudioName(item.path));
      return metadata || file;
    }).toList();
  }

  MediaItem apply(MediaItem item, {bool replaceLyrics = true}) => item.copyWith(
      title: syncMetadata && _useful(title) ? title : item.title,
      artist: syncMetadata && _useful(artist) ? artist : item.artist,
      album: syncMetadata && _useful(album) ? album : item.album,
      lyricMatchAliases: syncMetadata
          ? rememberLyricAlias(item.copyWith(lyricMatchAliases: [
              ...item.lyricMatchAliases,
              ...aliases,
            ]))
          : item.lyricMatchAliases,
      lyrics: replaceLyrics ? lyrics : item.lyrics,
      hasCustomLyrics: replaceLyrics || item.hasCustomLyrics,
      lyricTiming: replaceLyrics
          ? LyricTiming(
              offsetMs: offsetMs,
              lyricsSignature: LyricTiming.signatureFor(lyrics))
          : item.lyricTiming);

  static bool _useful(String value) =>
      value.trim().isNotEmpty &&
      !value.startsWith('未知') &&
      !['unknown', '<unknown>'].contains(_normal(value));
}

class LyricPackagePreview {
  const LyricPackagePreview(this.entries, this.warnings, this.fileName);
  final List<LyricLibraryEntry> entries;
  final List<String> warnings;
  final String fileName;
}

// 解压采用有上限的流式输出，不信任 ZIP 中声称的解压后大小，也不写入包内路径。
class _BoundedBytes extends ByteConversionSink {
  _BoundedBytes(this.limit);
  final int limit;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit)
      throw const FormatException('歌词包解压内容超过限制。');
    bytes.add(chunk);
  }

  @override
  void close() {}
}

LyricPackagePreview decodeLyricPackage((Uint8List, String) request) {
  final (bytes, fileName) = request;
  if (bytes.isEmpty || bytes.length > lyricPackageLimit)
    throw const FormatException('歌词包不能超过 32 MiB。');
  final directory = ZipDirectory.read(InputStream(bytes));
  if (directory.fileHeaders.isEmpty ||
      directory.fileHeaders.length > lyricLibraryLimit + 1 ||
      directory.numberOfThisDisk != 0 ||
      directory.diskWithTheStartOfTheCentralDirectory != 0) {
    throw const FormatException('歌词包文件数量过多或不是单卷 ZIP。');
  }
  final files = <String, Uint8List>{};
  var total = 0;
  for (final header in directory.fileHeaders) {
    final file = header.file!;
    final name = header.filename;
    if (name.contains('\\') ||
        name.startsWith('/') ||
        name.contains(':') ||
        name.split('/').contains('..') ||
        name.contains('\u0000') ||
        ((header.externalFileAttributes! >> 16) & 0xF000) == 0xA000 ||
        file.flags & 1 != 0) throw const FormatException('歌词包含不安全路径、链接或加密文件。');
    if (name.endsWith('/')) continue;
    if (files.containsKey(name.toLowerCase()))
      throw const FormatException('歌词包包含重复文件名。');
    final limit = name == _manifestName ? lyricPackageLimit : 2 * 1024 * 1024;
    final claimed = header.uncompressedSize ?? -1;
    if (claimed < 0 || claimed > limit || total + claimed > lyricPackageLimit) {
      throw const FormatException('歌词包解压后超过 32 MiB 或单首超过 2 MiB。');
    }
    final sink = _BoundedBytes(min(limit, lyricPackageLimit - total));
    final raw = file.rawContent!.toUint8List();
    if (file.compressionMethod == 0) {
      sink.add(raw);
    } else if (file.compressionMethod == 8) {
      final decoder = io.ZLibDecoder(raw: true).startChunkedConversion(sink);
      for (var i = 0; i < raw.length; i += 1024) {
        decoder.add(Uint8List.sublistView(raw, i, min(i + 1024, raw.length)));
      }
      decoder.close();
    } else {
      throw const FormatException('歌词包只支持标准 ZIP 压缩。');
    }
    final content = sink.bytes.takeBytes();
    if (content.length != claimed || getCrc32(content) != header.crc32)
      throw const FormatException('歌词包损坏，校验失败。');
    total += content.length;
    files[name.toLowerCase()] = content;
  }
  final manifest = files[_manifestName];
  if (manifest != null) {
    final json = jsonDecode(utf8.decode(manifest));
    if (json is! Map ||
        json['format'] != 'lumio-lyrics' ||
        json['version'] != 1 ||
        json['entries'] is! List) {
      throw const FormatException('不支持此歌词包版本，请更新应用。');
    }
    final raw = json['entries'] as List;
    if (raw.isEmpty || raw.length > lyricLibraryLimit)
      throw const FormatException('歌词包需包含 1–5000 首歌词。');
    final entries = raw
        .map((e) =>
            LyricLibraryEntry.fromJson(Map<String, Object?>.from(e as Map)))
        .toList();
    if (entries.map((e) => e.matchKey).toSet().length != entries.length)
      throw const FormatException('歌词包中存在重复歌曲条目。');
    return LyricPackagePreview(entries, const [], fileName);
  }
  final entries = <LyricLibraryEntry>[];
  final warnings = <String>['旧版 ZIP 缺少音频时长等匹配信息，歌词将保留，可手动关联歌曲。'];
  for (final entry in files.entries.where((e) => e.key.endsWith('.lrc'))) {
    try {
      final text =
          utf8.decode(entry.value).replaceFirst(RegExp(r'^\uFEFF'), '');
      if (RegExp(r'\[offset:', caseSensitive: false).hasMatch(text))
        throw const FormatException('请先将 offset 折入时间戳');
      String tag(String name) =>
          RegExp('\\[$name:([^\\]\\r\\n]*)\\]', caseSensitive: false)
              .firstMatch(text)
              ?.group(1)
              ?.trim() ??
          '';
      final lines = parseLrc(text);
      final title = tag('ti');
      final item = LyricLibraryEntry.fromJson({
        'title': title.isEmpty
            ? lyricAudioName(entry.key).replaceFirst(RegExp(r'\.lrc$'), '')
            : title,
        'artist': tag('ar'),
        'album': tag('al'),
        'fileName': '',
        'durationMs': 0,
        'fileSize': 0,
        'offsetMs': 0,
        'lyrics': lines.map((e) => e.toJson()).toList()
      });
      entries.add(item);
    } catch (_) {
      if (warnings.length < 50) warnings.add('${entry.key}：格式或编码无效，未导入。');
    }
  }
  if (entries.isEmpty) throw const FormatException('ZIP 内没有有效的 UTF-8 LRC 歌词。');
  return LyricPackagePreview(entries, warnings, fileName);
}

LyricsExportFile buildLyricPackage(List<LyricLibraryEntry> entries) {
  if (entries.isEmpty || entries.length > lyricLibraryLimit)
    throw const FormatException('歌词包需包含 1–5000 首歌词。');
  for (final entry in entries) {
    LyricLibraryEntry.fromJson(entry.toJson());
  }
  if (entries.map((e) => e.matchKey).toSet().length != entries.length)
    throw const FormatException('歌词包存在重复歌曲，请先确认使用的版本。');
  final data = utf8.encode(jsonEncode({
    'format': 'lumio-lyrics',
    'version': 1,
    'entries': entries.map((entry) => entry.toJson()).toList()
  }));
  if (data.length > lyricPackageLimit)
    throw const FormatException('歌词包解压内容超过 32 MiB。');
  final archive = Archive()
    ..addFile(ArchiveFile(_manifestName, data.length, data));
  final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
  if (bytes.length > lyricPackageLimit)
    throw const FormatException('歌词包超过 32 MiB。');
  return LyricsExportFile('Lumio-跨设备歌词包.zip', bytes, entries.length, 0);
}
