import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../core/device_transfer/transfer_host.dart';
import '../../core/device_transfer/transfer_protocol.dart';
import '../../core/lyrics/lyric_library.dart';
import '../../core/models/media_item.dart';

class TransferShareChoice {
  const TransferShareChoice(
      {required this.key,
      required this.title,
      required this.subtitle,
      required this.kind,
      this.media,
      this.lyric});
  final String key, title, subtitle;
  final TransferResourceKind kind;
  final MediaItem? media;
  final LyricLibraryEntry? lyric;
}

class NativeTransferLease {
  NativeTransferLease(this.handle, this.size, this.digest, this.extension);
  final String handle, digest, extension;
  final int size;
  static const channel = MethodChannel('lumio/device_transfer');
  static Future<NativeTransferLease> open(MediaItem item) async {
    final raw = await channel.invokeMapMethod<String, Object?>('openMedia',
        {'id': item.id, 'kind': item.kind.name, 'path': item.path});
    if (raw == null ||
        raw['handle'] is! String ||
        raw['size'] is! int ||
        raw['sha256'] is! String ||
        raw['extension'] is! String) invalidTransferMessage();
    return NativeTransferLease(raw['handle'] as String, raw['size'] as int,
        raw['sha256'] as String, raw['extension'] as String);
  }

  Future<Uint8List> read(int offset, int length) async =>
      await channel.invokeMethod<Uint8List>('readMedia',
          {'handle': handle, 'offset': offset, 'length': length}) ??
      (throw const FormatException('来源文件未返回数据。'));
  Future<void> close() =>
      channel.invokeMethod<void>('closeMedia', {'handle': handle});
}

class _SharedEntry {
  _SharedEntry(this.resource, {this.mediaId, this.lyricId, this.bytes});
  final TransferResource resource;
  final String? mediaId, lyricId;
  final Uint8List? bytes;
  NativeTransferLease? lease;
  bool invalid = false;
}

class SharedResourceReader implements TransferResourceReader {
  SharedResourceReader(
      {required this.identityDigest,
      required this.mediaItems,
      required this.lyrics,
      required this.isVisible});
  final String identityDigest;
  final List<MediaItem> Function() mediaItems;
  final List<LyricLibraryEntry> Function() lyrics;
  final bool Function(MediaItem) isVisible;
  final Map<String, _SharedEntry> _entries = {};
  int _buffered = 0;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static const _artworkChannel = MethodChannel('lumio/media_library');

  List<TransferShareChoice> get choices => [
        for (final item in mediaItems().where(isVisible))
          TransferShareChoice(
              key: 'media:${item.id}',
              title: item.title,
              subtitle: item.subtitle,
              kind: item.kind == MediaKind.audio
                  ? TransferResourceKind.audio
                  : TransferResourceKind.video,
              media: item),
        for (final item in mediaItems().where((item) =>
            isVisible(item) &&
            item.kind == MediaKind.audio &&
            item.lyrics.isNotEmpty))
          TransferShareChoice(
              key: 'lyrics-media:${item.id}',
              title: item.title,
              subtitle: '${item.artist} · 当前正式歌词',
              kind: TransferResourceKind.lyrics,
              media: item),
        for (final lyric in lyrics().where((lyric) =>
            lyric.active &&
            !lyric.handled.keys
                .any((path) => mediaItems().any((item) => item.path == path))))
          TransferShareChoice(
              key: 'lyrics:${lyric.id}',
              title: lyric.title,
              subtitle: '${lyric.artist} · 独立歌词库',
              kind: TransferResourceKind.lyrics,
              lyric: lyric),
      ];

  String _id(String local) => sha256
      .convert(utf8.encode('$identityDigest:$local'))
      .toString()
      .substring(0, 32);
  TransferDisplayMetadata _metadata(MediaItem item) => TransferDisplayMetadata(
      title: item.title,
      artist: item.artist,
      album: item.album,
      durationMs: item.duration.inMilliseconds,
      aliases: rememberLyricAlias(item));

  Future<TransferManifest> prepare(Set<String> selected,
      {required bool includeLyrics,
      required bool includeArtwork,
      required void Function(int, int) progress,
      required bool Function() cancelled}) async {
    await close();
    if (selected.isEmpty || selected.length > TransferLimits.batchResources) {
      throw const FormatException('请选择 1–500 项资源。');
    }
    final byKey = {for (final choice in choices) choice.key: choice};
    try {
      var done = 0;
      for (final key in selected) {
        if (cancelled()) throw StateError('共享准备已取消。');
        final choice = byKey[key];
        if (choice == null) throw StateError('所选资源已移除或不再允许共享，请重新选择。');
        final item = choice.media;
        if (choice.kind == TransferResourceKind.lyrics) {
          if (item != null) {
            String fingerprint = '';
            try {
              final lease = await NativeTransferLease.open(item);
              try {
                fingerprint = 'sha256:${lease.digest}';
              } finally {
                await lease.close();
              }
            } on PlatformException {
              /* Formal lyrics can be transferred alone. */
            }
            _addLyrics('lyrics-media:${item.id}',
                LyricLibraryEntry.fromMedia(item, fingerprint: fingerprint),
                mediaId: item.id);
          } else {
            _addLyrics(key, choice.lyric!, lyricId: choice.lyric!.id);
          }
        } else {
          final lease = await NativeTransferLease.open(item!);
          try {
            final attachments = <String>[];
            if (includeLyrics &&
                item.kind == MediaKind.audio &&
                item.lyrics.isNotEmpty) {
              attachments.add(_addLyrics(
                  'lyrics-media:${item.id}',
                  LyricLibraryEntry.fromMedia(
                      item.copyWith(fileSizeBytes: lease.size),
                      fingerprint: 'sha256:${lease.digest}'),
                  mediaId: item.id));
            }
            if (includeArtwork) {
              var bytes = await _artworkChannel.invokeMethod<Uint8List>(
                  'loadArtwork', {'mediaId': item.id, 'kind': item.kind.name});
              if (bytes == null && item.artworkPath != null) {
                final file = File(item.artworkPath!);
                if (await file.exists() &&
                    await file.length() <= 10 * 1024 * 1024)
                  bytes = await file.readAsBytes();
              }
              if (bytes != null &&
                  bytes.isNotEmpty &&
                  bytes.length <= 10 * 1024 * 1024) {
                final id = _id('artwork:${item.id}');
                final resource = TransferResource(
                    id: id,
                    kind: TransferResourceKind.artwork,
                    byteLength: bytes.length,
                    sha256Digest: sha256.convert(bytes).toString(),
                    extension:
                        bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50
                            ? 'png'
                            : 'jpg',
                    metadata: _metadata(item));
                _buffer(
                    id, _SharedEntry(resource, mediaId: item.id, bytes: bytes));
                attachments.add(id);
              }
            }
            final resource = TransferResource(
                id: _id(key),
                kind: choice.kind,
                byteLength: lease.size,
                sha256Digest: lease.digest,
                extension: lease.extension,
                metadata: _metadata(item),
                attachmentIds: attachments);
            _entries[resource.id] = _SharedEntry(resource, mediaId: item.id);
          } finally {
            await lease.close();
          }
        }
        if (cancelled()) throw StateError('共享准备已取消。');
        progress(++done, selected.length);
      }
      return TransferManifest(_entries.values.map((entry) => entry.resource));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  String _addLyrics(String key, LyricLibraryEntry lyric,
      {String? mediaId, String? lyricId}) {
    final id = _id(key);
    final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({'version': 1, 'lyric': lyric.toJson()})));
    final resource = TransferResource(
        id: id,
        kind: TransferResourceKind.lyrics,
        byteLength: bytes.length,
        sha256Digest: sha256.convert(bytes).toString(),
        extension: 'json',
        metadata: TransferDisplayMetadata(
            title: lyric.title,
            artist: lyric.artist,
            album: lyric.album,
            durationMs: lyric.durationMs,
            aliases: lyric.aliases));
    _buffer(
        id,
        _SharedEntry(resource,
            mediaId: mediaId, lyricId: lyricId, bytes: bytes));
    return id;
  }

  void _buffer(String id, _SharedEntry entry) {
    _buffered +=
        (entry.bytes?.length ?? 0) - (_entries[id]?.bytes?.length ?? 0);
    if (_buffered > 128 * 1024 * 1024)
      throw StateError('所选歌词和封面超过 128 MiB，请减少附件或分批共享。');
    _entries[id] = entry;
  }

  @override
  Future<bool> isAvailable(TransferResource expected) async {
    final entry = _entries[expected.id];
    if (entry == null ||
        entry.invalid ||
        entry.resource.sha256Digest != expected.sha256Digest) return false;
    if (entry.mediaId != null)
      return mediaItems()
          .any((item) => item.id == entry.mediaId && isVisible(item));
    return lyrics().any((lyric) => lyric.active && lyric.id == entry.lyricId);
  }

  @override
  Future<Uint8List> readBlock(
          TransferResource expected, int offset, int length) =>
      _serial(() async {
        final entry = _entries[expected.id];
        if (entry == null || !await isAvailable(expected))
          throw StateError('资源已移除。');
        if (entry.bytes != null)
          return Uint8List.sublistView(entry.bytes!, offset, offset + length);
        try {
          if (entry.lease == null) {
            // Native reads share one serialized lease lane, independent of receiving.
            for (final other in _entries.values
                .where((e) => e != entry && e.lease != null)) {
              await other.lease!.close();
              other.lease = null;
            }
            final item = mediaItems().firstWhere(
                (item) => item.id == entry.mediaId && isVisible(item));
            final lease = await NativeTransferLease.open(item);
            if (lease.digest != expected.sha256Digest ||
                lease.size != expected.byteLength) {
              await lease.close();
              throw StateError('来源内容已改变，请刷新共享后重新选择。');
            }
            entry.lease = lease;
          }
          return await entry.lease!.read(offset, length);
        } catch (_) {
          entry.invalid = true;
          rethrow;
        }
      });

  Future<void> close() => _serial(() async {
        for (final entry in _entries.values) {
          await entry.lease?.close();
        }
        _entries.clear();
        _buffered = 0;
      });
}
