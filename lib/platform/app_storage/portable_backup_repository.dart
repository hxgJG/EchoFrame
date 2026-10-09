import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/models/media_item.dart';
import '../../core/lyrics/lyric_library.dart';
import '../../core/models/playlist.dart';
import '../../core/models/lumio_settings.dart';
import '../../core/subtitles/subtitle_project.dart';

const portableBackupLimit = 2 * 1024 * 1024 * 1024;
const _metadataLimit = 128 * 1024 * 1024;
const _safeMediaName = r'^[a-f0-9]{32}\.[a-z0-9]{1,8}$';

class PortableBackupPreview {
  PortableBackupPreview(this.directory, this.value);
  final Directory directory;
  final Map<String, Object?> value;
  Map<String, Object?> get state =>
      Map<String, Object?>.from(value['state'] as Map);
  List get files => value['files'] as List;
  List get projects => state['subtitleProjects'] as List? ?? [];
  int get audioCount => (state['audioItems'] as List).length;
  int get videoCount => (state['videoItems'] as List).length;
  int get playlistCount => (state['playlists'] as List).length;
  int get byteLength => files.fold<int>(0, (n, e) => n + (e['size'] as int));
}

class PortableBackupRepository {
  static const channel = MethodChannel('lumio/portable_backup');
  static bool get supported => Platform.isAndroid || Platform.isMacOS;

  Future<Map<String, Object?>> environment() async => Map<String, Object?>.from(
      (await channel.invokeMapMethod('environment'))!);

  Future<String?> export(Map<String, Object?> snapshot) async {
    final environment = await this.environment();
    final directory = await Directory(environment['temporaryRoot'] as String)
        .createTemp('export-');
    try {
      final path = '${directory.path}/Lumio-数据备份.zip';
      await compute(_encodeBackup, {
        'snapshot': snapshot,
        'environment': environment,
        'platform': Platform.operatingSystem,
        'path': path,
      });
      return await channel.invokeMethod<String>('export', {
        'path': path,
        'name': 'Lumio-数据备份-${DateTime.now().millisecondsSinceEpoch}.zip',
      });
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<PortableBackupPreview?> select() async {
    final environment = await this.environment();
    final path = await channel.invokeMethod<String>('import');
    if (path == null) return null;
    final directory = File(path).parent;
    try {
      final value = await compute(_decodeBackup, {
        'path': path,
        'platform': Platform.operatingSystem,
        'availableBytes': environment['availableBytes'],
        'directory': directory.path,
      });
      return PortableBackupPreview(directory, value);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> commit(Map<String, Object?> state) =>
      channel.invokeMethod<void>('commit', {'state': state});
}

String _token() => List.generate(16, (_) => Random.secure().nextInt(256))
    .map((e) => e.toRadixString(16).padLeft(2, '0'))
    .join();

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _encodeBackup(Map<String, Object?> args) async {
  final state = Map<String, Object?>.from(args['snapshot'] as Map);
  final environment = args['environment'] as Map;
  final roots = (environment['managedRoots'] as List).cast<String>();
  final receivedRoot = environment['receivedRoot'] as String;
  final files = <Map<String, Object?>>[];
  final paths = <String>{};
  var total = 0;
  Future<void> add(String? path, {bool required = false}) async {
    if (path == null || path.isEmpty || paths.contains(path)) return;
    final name = path.split('/').last;
    final managed = roots.any((root) => path.startsWith('$root/'));
    if (!managed) {
      if (required) throw const FormatException('应用内媒体路径异常，未生成不完整备份。');
      return;
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      if (required) throw FormatException('应用内媒体文件缺失：$name。请先处理后再备份。');
      return;
    }
    final file = File(path);
    final canonical = await file.resolveSymbolicLinks();
    if (!roots.any((root) => canonical.startsWith('$root/'))) {
      throw const FormatException('备份文件越过应用目录边界。');
    }
    if (required && !path.startsWith('$receivedRoot/')) {
      throw const FormatException('接收媒体路径异常。');
    }
    final size = await file.length();
    total += size;
    if (total > portableBackupLimit - _metadataLimit || files.length >= 9999) {
      throw const FormatException('备份超过 2 GiB 或文件数超过 9999，请先精简应用内媒体。');
    }
    final extension =
        name.contains('.') ? name.split('.').last.toLowerCase() : 'bin';
    final storedName =
        '${_token()}.${RegExp(r'^[a-z0-9]{1,8}$').hasMatch(extension) ? extension : 'bin'}';
    files.add({
      'name': storedName,
      'originalPath': path,
      'size': size,
      'sha256': await _digest(file),
    });
    paths.add(path);
  }

  final received = state['receivedMedia'] as Map;
  for (final raw in received['items'] as List) {
    final item = raw as Map;
    await add(item['path'] as String?, required: true);
    await add(item['artworkPath'] as String?);
  }
  for (final raw in [
    ...state['audioItems'] as List,
    ...state['videoItems'] as List
  ]) {
    await add((raw as Map)['artworkPath'] as String?);
  }
  // Authorization bookmarks and transfer identities are deliberately excluded.
  for (final raw in state['subtitleProjects'] as List? ?? []) {
    ((raw as Map)['source'] as Map?)?.remove('bookmark');
    raw.remove('libraryBinding');
  }
  final metadata = utf8.encode(jsonEncode({
    'format': 'lumio-data-backup',
    'version': 1,
    'platform': args['platform'],
    'createdAtMs': DateTime.now().millisecondsSinceEpoch,
    'state': state,
    'files': files,
  }));
  if (metadata.length > _metadataLimit ||
      total + metadata.length + 4 * 1024 * 1024 > portableBackupLimit ||
      total + metadata.length + 64 * 1024 * 1024 >
          (environment['availableBytes'] as int)) {
    throw const FormatException('备份数据超过限制或应用临时目录空间不足。');
  }
  final encoder = ZipFileEncoder();
  encoder.create(args['path'] as String, level: ZipFileEncoder.STORE);
  try {
    encoder.addArchiveFile(
        ArchiveFile.noCompress('lumio-backup.json', metadata.length, metadata));
    for (final entry in files) {
      final file = File(entry['originalPath'] as String);
      if (await file.length() != entry['size']) {
        throw const FormatException('打包期间文件已改变，请重新导出。');
      }
      await encoder.addFile(
          file, 'media/${entry['name']}', ZipFileEncoder.STORE);
    }
  } finally {
    encoder.closeSync();
  }
  // Verify the bytes actually packaged, not just the pre-copy source hashes.
  await _readBackup(args['path'] as String, args['platform'] as String);
}

Future<Map<String, Object?>> _decodeBackup(Map<String, Object?> args) async {
  final value = await _readBackup(
      args['path'] as String, args['platform'] as String,
      extractTo: args['directory'] as String,
      availableBytes: args['availableBytes'] as int);
  return value;
}

Future<Map<String, Object?>> _readBackup(String path, String platform,
    {String? extractTo, int? availableBytes}) async {
  final input = InputFileStream(path);
  try {
    final length = input.length;
    // Own-format archives have no comment or ZIP64 footer. Bound the central
    // directory before the archive library allocates it.
    if (length < 22 || length > portableBackupLimit) {
      throw const FormatException('备份为空、损坏或超过 2 GiB。');
    }
    input.position = length - 22;
    if (input.readUint32() != 0x06054b50 ||
        input.readUint16() != 0 ||
        input.readUint16() != 0) {
      throw const FormatException('只支持本应用导出的单卷备份 ZIP。');
    }
    final count = input.readUint16(), count2 = input.readUint16();
    final size = input.readUint32(), offset = input.readUint32();
    if (count != count2 ||
        count < 1 ||
        count > 10000 ||
        size > 2 * 1024 * 1024 ||
        offset + size != length - 22 ||
        input.readUint16() != 0) {
      throw const FormatException('备份目录无效或超过限制。');
    }
    input.reset();
    final zip = ZipDirectory.read(input);
    final entries = <String, ZipFileHeader>{};
    for (final entry in zip.fileHeaders) {
      final name = entry.filename;
      final mode = (entry.externalFileAttributes ?? 0) >> 16 & 0xf000;
      if (entries.containsKey(name) ||
          (name != 'lumio-backup.json' &&
              !RegExp('^media/${_safeMediaName.substring(1, _safeMediaName.length - 1)}\$')
                  .hasMatch(name)) ||
          (mode != 0 && mode != 0x8000) ||
          entry.generalPurposeBitFlag & 1 != 0 ||
          entry.compressionMethod != 0 ||
          entry.file!.compressionMethod != 0 ||
          entry.file!.flags & 1 != 0 ||
          entry.compressedSize != entry.uncompressedSize ||
          entry.file!.rawContent!.length != entry.uncompressedSize) {
        throw const FormatException('备份含重复文件、不安全路径、链接或不支持的压缩。');
      }
      entries[name] = entry;
    }
    if (entries.length != count) throw const FormatException('备份目录不完整。');
    final header = entries.remove('lumio-backup.json');
    if (header == null || header.uncompressedSize! > _metadataLimit) {
      throw const FormatException('缺少备份清单或清单过大。');
    }
    final bytes = header.file!.rawContent!.toUint8List();
    if (getCrc32(bytes) != header.crc32)
      throw const FormatException('备份清单校验失败。');
    final value =
        Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map);
    if (value['format'] != 'lumio-data-backup' ||
        value['version'] != 1 ||
        value['platform'] != platform) {
      throw const FormatException('不支持此备份版本或平台。请在与导出端相同的平台导入。');
    }
    final state = Map<String, Object?>.from(value['state'] as Map);
    _validateState(state);
    final files = value['files'] as List;
    if (files.length != entries.length)
      throw const FormatException('备份文件清单不完整。');
    var total = 0;
    final paths = <String>{}, names = <String>{};
    for (final raw in files) {
      final e = raw as Map;
      final name = e['name'],
          original = e['originalPath'],
          digest = e['sha256'],
          size = e['size'];
      if (name is! String ||
          !RegExp(_safeMediaName).hasMatch(name) ||
          !names.add(name) ||
          original is! String ||
          !original.startsWith('/') ||
          original.contains('\x00') ||
          !paths.add(original) ||
          size is! int ||
          size < 0 ||
          digest is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
          entries['media/$name']?.uncompressedSize != size) {
        throw const FormatException('备份媒体清单无效。');
      }
      total += size;
    }
    if (total + bytes.length > portableBackupLimit ||
        (availableBytes != null && total + 64 * 1024 * 1024 > availableBytes)) {
      throw const FormatException('备份超过限制或恢复空间不足。');
    }
    for (final raw in (state['receivedMedia'] as Map)['items'] as List) {
      if (!paths.contains((raw as Map)['path']))
        throw const FormatException('备份缺少应用内媒体，不可用于卸载迁移。');
    }
    for (final raw in files) {
      final e = raw as Map;
      final stream = entries['media/${e['name']}']!.file!.rawContent!;
      final output = extractTo == null
          ? null
          : File('$extractTo/${e['name']}').openSync(mode: FileMode.write);
      final digest = <Digest>[];
      final sink = sha256.startChunkedConversion(_DigestSink(digest));
      var crc = 0, written = 0;
      try {
        while (!stream.isEOS) {
          final chunk =
              stream.readBytes(min(65536, stream.length)).toUint8List();
          if (chunk.isEmpty) throw const FormatException('媒体文件已截断。');
          output?.writeFromSync(chunk);
          written += chunk.length;
          sink.add(chunk);
          crc = getCrc32(chunk, crc);
        }
        sink.close();
        if (written != e['size'] ||
            digest.single.toString() != e['sha256'] ||
            crc != entries['media/${e['name']}']!.crc32) {
          throw const FormatException('媒体文件校验失败，未导入。');
        }
      } finally {
        output?.closeSync();
      }
    }
    return value;
  } finally {
    input.closeSync();
  }
}

void _validateState(Map<String, Object?> state) {
  if (state['schemaVersion'] != 2) throw const FormatException('不支持此应用数据版本。');
  final ids = <String>{};
  for (final key in ['audioItems', 'videoItems']) {
    final items = state[key] as List;
    if (items.length > 50000) throw const FormatException('媒体条目过多。');
    for (final raw in items) {
      final item = MediaItem.fromJson(Map<String, Object?>.from(raw as Map));
      if (item.id.isEmpty ||
          !ids.add(item.id) ||
          item.path.isEmpty ||
          item.path.contains('\x00') ||
          item.kind.name != (key == 'audioItems' ? 'audio' : 'video')) {
        throw const FormatException('媒体索引无效。');
      }
    }
  }
  final playlists = state['playlists'] as List;
  if (playlists.length > 10000) throw const FormatException('歌单数量过多。');
  final playlistIds = <String>{};
  for (final raw in playlists) {
    final playlist = Playlist.fromJson(Map<String, Object?>.from(raw as Map));
    if (playlist.id.isEmpty || !playlistIds.add(playlist.id))
      throw const FormatException('歌单标识无效或重复。');
  }
  final lyrics = state['lyricLibrary'];
  if (lyrics != null) {
    if (lyrics is! Map ||
        lyrics['version'] != 1 ||
        lyrics['entries'] is! List ||
        (lyrics['entries'] as List).length > lyricLibraryLimit)
      throw const FormatException('歌词库无效或超过限制。');
    final lyricIds = <String>{};
    for (final raw in lyrics['entries'] as List) {
      final entry = LyricLibraryEntry.fromJson(
          Map<String, Object?>.from(raw as Map),
          local: true);
      if (!lyricIds.add(entry.id)) throw const FormatException('歌词库标识重复。');
    }
  }
  LumioSettings.fromJson(Map<String, Object?>.from(state['settings'] as Map));
  final received = state['receivedMedia'] as Map;
  if (received['version'] != 1 || received['items'] is! List)
    throw const FormatException('接收媒体索引无效。');
  final receivedIds = <String>{};
  for (final raw in received['items'] as List) {
    final item = MediaItem.fromJson(Map<String, Object?>.from(raw as Map));
    if (!RegExp(r'^transfer-[a-f0-9]{32}$').hasMatch(item.id) ||
        !receivedIds.add(item.id) ||
        item.sourceId != 'lumio-received' ||
        !RegExp(_safeMediaName).hasMatch(item.relativePath ?? '')) {
      throw const FormatException('接收媒体条目无效。');
    }
  }
  final projects = state['subtitleProjects'] as List? ?? [];
  if (projects.length > 200) throw const FormatException('字幕项目过多。');
  final projectIds = <String>{};
  for (final raw in projects) {
    final project =
        SubtitleProject.fromJson(Map<String, dynamic>.from(raw as Map));
    if (!RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
                caseSensitive: false)
            .hasMatch(project.id) ||
        !projectIds.add(project.id)) throw const FormatException('字幕项目标识无效。');
  }
}

class _DigestSink implements Sink<Digest> {
  _DigestSink(this.values);
  final List<Digest> values;
  @override
  void add(Digest data) => values.add(data);
  @override
  void close() {}
}
