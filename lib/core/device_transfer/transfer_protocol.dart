import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

abstract final class TransferLimits {
  static const protocolVersion = 1;
  static const manifestBytes = 1024 * 1024;
  static const batchResources = 500;
  static const parallelFiles = 2;
  static const blockBytes = 256 * 1024;
  static const maximumFileBytes = 9007199254740991;
  static const approvalTimeout = Duration(minutes: 2);
  static const defaultAuthorization = Duration(hours: 1);
  static const minimumAuthorization = Duration(minutes: 5);
  static const maximumAuthorization = Duration(hours: 24);
  static const partialRetention = Duration(hours: 24);
  static const retainedJobs = 200;
}

enum TransferResourceKind { audio, video, lyrics, artwork }

enum TransferFailure {
  invalidMessage,
  unsupportedVersion,
  notSharing,
  busy,
  unauthorized,
  approvalExpired,
  authorizationExpired,
  outsideScope,
  versionChanged,
  invalidRange,
  unavailable,
  integrityMismatch,
  storageCorrupt,
  storageLimit,
  insufficientSpace,
  disconnected,
}

class TransferException implements Exception {
  const TransferException(this.code, this.message);

  final TransferFailure code;
  final String message;

  @override
  String toString() => message;
}

String newTransferId() {
  final random = Random.secure();
  return List.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

bool isTransferId(String value) => RegExp(r'^[a-f0-9]{32}$').hasMatch(value);
bool isTransferDigest(String value) =>
    RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

Never invalidTransferMessage() => throw const TransferException(
    TransferFailure.invalidMessage, '设备传输数据格式无效。');

String _text(Object? value, {int limit = 1024}) {
  if (value is! String ||
      value.length > limit ||
      value.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'))) {
    invalidTransferMessage();
  }
  return value;
}

int _number(Object? value, int maximum) {
  if (value is! int || value < 0 || value > maximum) invalidTransferMessage();
  return value;
}

/// Only transferable display fields. Local paths, URIs, bookmarks and drafts
/// must never be serialized with MediaItem.toJson into a network response.
class TransferDisplayMetadata {
  TransferDisplayMetadata({
    required String title,
    String artist = '',
    String album = '',
    int durationMs = 0,
    List<Map<String, String>> aliases = const [],
  })  : title = _text(title),
        artist = _text(artist),
        album = _text(album),
        durationMs = _number(durationMs, 604800000),
        aliases = List.unmodifiable(
            aliases.map((alias) => Map<String, String>.unmodifiable({
                  for (final key in ['title', 'artist', 'album'])
                    key: _text(alias[key]),
                }))) {
    if (aliases.length > 32) invalidTransferMessage();
  }

  factory TransferDisplayMetadata.fromJson(Map<String, Object?> json) {
    final aliases = json['aliases'];
    if (aliases is! List || aliases.length > 32) invalidTransferMessage();
    return TransferDisplayMetadata(
      title: _text(json['title']),
      artist: _text(json['artist']),
      album: _text(json['album']),
      durationMs: _number(json['durationMs'], 604800000),
      aliases: aliases.map((alias) {
        if (alias is! Map) invalidTransferMessage();
        return {
          for (final key in ['title', 'artist', 'album']) key: _text(alias[key])
        };
      }).toList(),
    );
  }

  final String title, artist, album;
  final int durationMs;
  final List<Map<String, String>> aliases;

  Map<String, Object?> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'durationMs': durationMs,
        'aliases': aliases,
      };
}

class TransferResource {
  TransferResource({
    required this.id,
    required this.kind,
    required this.byteLength,
    required this.sha256Digest,
    required this.extension,
    required this.metadata,
    List<String> attachmentIds = const [],
  }) : attachmentIds = List.unmodifiable(attachmentIds) {
    if (!isTransferId(id) ||
        !isTransferDigest(sha256Digest) ||
        byteLength < 0 ||
        byteLength > TransferLimits.maximumFileBytes ||
        !_extensions[kind]!.contains(extension) ||
        attachmentIds.length > 2 ||
        attachmentIds.toSet().length != attachmentIds.length ||
        attachmentIds.any((value) => !isTransferId(value) || value == id) ||
        ((kind == TransferResourceKind.lyrics ||
                kind == TransferResourceKind.artwork) &&
            attachmentIds.isNotEmpty) ||
        (kind == TransferResourceKind.lyrics &&
            byteLength > 32 * 1024 * 1024) ||
        (kind == TransferResourceKind.artwork &&
            byteLength > 10 * 1024 * 1024)) {
      invalidTransferMessage();
    }
  }

  static const _extensions = {
    TransferResourceKind.audio: {
      'mp3',
      'm4a',
      'aac',
      'flac',
      'wav',
      'ogg',
      'opus',
      'aiff',
      'alac',
      'wma'
    },
    TransferResourceKind.video: {
      'mp4',
      'm4v',
      'mov',
      'mkv',
      'webm',
      'avi',
      '3gp',
      'ts',
      'wmv'
    },
    TransferResourceKind.lyrics: {'json'},
    TransferResourceKind.artwork: {'jpg', 'jpeg', 'png', 'webp'},
  };

  factory TransferResource.fromJson(Map<String, Object?> json) {
    final kinds =
        TransferResourceKind.values.where((kind) => kind.name == json['kind']);
    final metadata = json['metadata'];
    final attachments = json['attachmentIds'];
    if (kinds.isEmpty ||
        metadata is! Map<String, Object?> ||
        attachments is! List ||
        attachments.length > 2) invalidTransferMessage();
    return TransferResource(
      id: _text(json['id']),
      kind: kinds.single,
      byteLength: _number(json['byteLength'], TransferLimits.maximumFileBytes),
      sha256Digest: _text(json['sha256']),
      extension: _text(json['extension']),
      metadata: TransferDisplayMetadata.fromJson(metadata),
      attachmentIds: attachments.map((value) => _text(value)).toList(),
    );
  }

  final String id, sha256Digest, extension;
  final TransferResourceKind kind;
  final int byteLength;
  final TransferDisplayMetadata metadata;
  final List<String> attachmentIds;

  // Freeze metadata and attachment changes as well as the file contents.
  String get revision =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'byteLength': byteLength,
        'sha256': sha256Digest,
        'extension': extension,
        'metadata': metadata.toJson(),
        'attachmentIds': attachmentIds,
      };
}

class TransferManifest {
  TransferManifest(Iterable<TransferResource> resources)
      : resources = List.unmodifiable(resources) {
    if (this.resources.length > TransferLimits.batchResources * 3) {
      invalidTransferMessage();
    }
    final byId = {for (final resource in this.resources) resource.id: resource};
    if (byId.length != this.resources.length) invalidTransferMessage();
    final attachments = this.resources.expand((r) => r.attachmentIds).toSet();
    if (this.resources.where((r) => !attachments.contains(r.id)).length >
        TransferLimits.batchResources) invalidTransferMessage();
    for (final resource in this.resources) {
      final kinds = <TransferResourceKind>{};
      for (final id in resource.attachmentIds) {
        final attachment = byId[id];
        if (attachment == null ||
            (attachment.kind != TransferResourceKind.lyrics &&
                attachment.kind != TransferResourceKind.artwork) ||
            !kinds.add(attachment.kind)) invalidTransferMessage();
      }
    }
    if (encode().length > TransferLimits.manifestBytes)
      invalidTransferMessage();
  }

  factory TransferManifest.decode(List<int> bytes) {
    if (bytes.length > TransferLimits.manifestBytes) invalidTransferMessage();
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map || json['version'] is! int) invalidTransferMessage();
      if (json['version'] != TransferLimits.protocolVersion) {
        throw const TransferException(
            TransferFailure.unsupportedVersion, '对方的传输协议版本不受支持，请更新应用。');
      }
      final resources = json['resources'];
      if (resources is! List ||
          resources.length > TransferLimits.batchResources * 3) {
        invalidTransferMessage();
      }
      return TransferManifest(resources.map((resource) {
        if (resource is! Map<String, Object?>) invalidTransferMessage();
        return TransferResource.fromJson(resource);
      }));
    } on FormatException {
      invalidTransferMessage();
    }
  }

  final List<TransferResource> resources;
  List<int> encode() => utf8.encode(jsonEncode({
        'version': TransferLimits.protocolVersion,
        'resources': resources.map((resource) => resource.toJson()).toList(),
      }));
}

class TransferImportPolicy {
  const TransferImportPolicy(
      {this.overwriteLyrics = true, this.syncMetadata = true});
  final bool overwriteLyrics, syncMetadata;
  Map<String, Object?> toJson() => {
        'overwriteLyrics': overwriteLyrics,
        'syncMetadata': syncMetadata,
      };
}
