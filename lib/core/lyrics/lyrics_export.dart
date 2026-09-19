import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/media_item.dart';

const maxLyricsExportBytes = 32 * 1024 * 1024;

class LyricsExportFile {
  const LyricsExportFile(
      this.fileName, this.bytes, this.count, this.clampedLines);
  final String fileName;
  final Uint8List bytes;
  final int count;
  final int clampedLines;
}

String _oneLine(String text) =>
    text.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();

String _metadata(String text) =>
    _oneLine(text).replaceAll('[', '［').replaceAll(']', '］');

String lyricsFileName(MediaItem item) {
  var name = _oneLine('${item.title} - ${item.artist}')
      .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
      .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (name.isEmpty) name = '未命名歌曲';
  final result = StringBuffer();
  var length = 0;
  for (final rune in name.runes) {
    final char = String.fromCharCode(rune);
    length += utf8.encode(char).length;
    if (length > 180) break;
    result.write(char);
  }
  return '$result.lrc';
}

/// 导出已保存的单曲校准，不把本机全局延迟或尚未保存的草稿带到其他播放器。
String encodeLrc(MediaItem item) {
  final output = StringBuffer()
    ..writeln('[ti:${_metadata(item.title)}]')
    ..writeln('[ar:${_metadata(item.artist)}]')
    ..writeln('[al:${_metadata(item.album)}]');
  final lines = List<LyricLine>.of(item.lyrics)
    ..sort((a, b) => a.time.compareTo(b.time));
  for (final line in lines) {
    final text = _oneLine(line.text);
    if (text.isEmpty) continue;
    final time = (line.time.inMilliseconds - item.lyricTiming.offsetMs)
        .clamp(0, 1 << 53);
    final minutes = (time ~/ 60000).toString().padLeft(2, '0');
    final seconds = (time ~/ 1000 % 60).toString().padLeft(2, '0');
    final milliseconds = (time % 1000).toString().padLeft(3, '0');
    output.writeln('[$minutes:$seconds.$milliseconds]$text');
  }
  return output.toString();
}

// 在后台 isolate 中编码/压缩，避免媒体库较大时阻塞播放界面。
LyricsExportFile buildLyricsExport((List<MediaItem>, bool) request) {
  final (items, bundle) = request;
  if (items.isEmpty || items.length > 65535 || (!bundle && items.length != 1)) {
    throw const FormatException('可导出歌词数量需在 1～65535 首之间。');
  }
  final archive = Archive();
  var size = 0;
  var clamped = 0;
  Uint8List? single;
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    final bytes = Uint8List.fromList(utf8.encode(encodeLrc(item)));
    size += bytes.length;
    if (size > maxLyricsExportBytes) {
      throw const FormatException('歌词总量超过 32 MB，请分首导出。');
    }
    clamped += item.lyrics
        .where((line) =>
            _oneLine(line.text).isNotEmpty &&
            line.time.inMilliseconds < item.lyricTiming.offsetMs)
        .length;
    if (bundle) {
      // 序号同时避免重名歌曲、大小写及跨平台 Unicode 规范化冲突。
      final prefix =
          (index + 1).toString().padLeft(items.length.toString().length, '0');
      final name = '$prefix - ${lyricsFileName(item)}';
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    } else {
      single = bytes;
    }
  }
  final bytes =
      bundle ? Uint8List.fromList(ZipEncoder().encode(archive)!) : single!;
  if (bytes.length > maxLyricsExportBytes) {
    throw const FormatException('导出文件超过 32 MB，请分首导出。');
  }
  return LyricsExportFile(
      bundle ? 'Lumio-全部歌词.zip' : lyricsFileName(items.single),
      bytes,
      items.length,
      clamped);
}
