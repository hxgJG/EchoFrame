import 'dart:typed_data';

import 'transfer_authorization.dart';
import 'transfer_protocol.dart';

/// Native implementations must resolve a selected local index ID to a leased
/// file handle, recheck visibility/OS access, and reject changed file identity.
/// Remote messages never provide a filesystem path to this interface.
abstract interface class TransferResourceReader {
  Future<bool> isAvailable(TransferResource expected);
  Future<Uint8List> readBlock(
      TransferResource expected, int offset, int length);
}

class TransferAccess {
  const TransferAccess(
      {required this.sessionId, required this.grantId, required this.peer});
  final String sessionId, grantId;
  final TransferPeerBinding peer;
}

/// Transport-independent host; no sockets and no insecure fallback adapter.
/// Revocation/expiry is checked both before and after every awaited read.
class TransferHost {
  TransferHost(
      {required this.authorization,
      required this.reader,
      this.parallelReads = TransferLimits.parallelFiles});
  final int parallelReads;
  final TransferAuthorization authorization;
  final TransferResourceReader reader;
  Map<String, TransferResource> _resources = {};
  Map<String, TransferResource> _published = {};
  final Set<String> _activeResources = {};

  void start(TransferManifest manifest, Set<String> selectedIds) {
    final resources = {
      for (final resource in manifest.resources) resource.id: resource
    };
    if (!selectedIds.every(resources.containsKey)) invalidTransferMessage();
    authorization.start(selectedIds);
    _published = {};
    _resources = {for (final id in selectedIds) id: resources[id]!};
  }

  void stop() {
    authorization.stop();
    _resources = {};
    _published = {};
  }

  Future<TransferManifest> catalog(TransferAccess access) async {
    _check(access);
    final result = <TransferResource>[];
    final snapshot = List<TransferResource>.of(_resources.values);
    for (final resource in snapshot) {
      _check(access);
      if (!authorization.scope.contains(resource.id)) continue;
      final available = await reader.isAvailable(resource);
      _check(access);
      if (available && authorization.scope.contains(resource.id))
        result.add(resource);
    }
    final ids = result.map((r) => r.id).toSet();
    // An attachment is not implicitly approved with its parent. If excluded or
    // unavailable, remove only the reference, not the parent media item.
    final manifest = TransferManifest(result.map((r) => TransferResource(
          id: r.id,
          kind: r.kind,
          byteLength: r.byteLength,
          sha256Digest: r.sha256Digest,
          extension: r.extension,
          metadata: r.metadata,
          attachmentIds: r.attachmentIds.where(ids.contains).toList(),
        )));
    _published = {
      for (final resource in manifest.resources) resource.id: resource
    };
    return manifest;
  }

  Future<Uint8List> readBlock(TransferAccess access,
      {required String resourceId,
      required String revision,
      required int offset,
      required int length}) async {
    _check(access, resourceId);
    final resource = _published[resourceId];
    if (resource == null) {
      throw const TransferException(TransferFailure.unavailable, '资源不可用。');
    }
    // Compare against the visible catalog revision (attachments may be omitted).
    // The catalog descriptor must therefore be explicitly selected for a task.
    if (revision != resource.revision) {
      throw const TransferException(
          TransferFailure.versionChanged, '资源版本已经改变，请重新选择。');
    }
    if (offset < 0 ||
        length <= 0 ||
        length > TransferLimits.blockBytes ||
        offset > resource.byteLength ||
        length > resource.byteLength - offset) {
      throw const TransferException(TransferFailure.invalidRange, '文件读取范围无效。');
    }
    if (_activeResources.length >= parallelReads ||
        !_activeResources.add(resourceId)) {
      throw const TransferException(TransferFailure.busy, '同时传输的文件数量已达上限。');
    }
    try {
      if (!await reader.isAvailable(resource)) {
        throw const TransferException(
            TransferFailure.unavailable, '资源已不可读或不再允许共享。');
      }
      _check(access, resourceId);
      final bytes = await reader.readBlock(resource, offset, length);
      _check(access, resourceId);
      if (!await reader.isAvailable(resource)) {
        throw const TransferException(
            TransferFailure.versionChanged, '读取过程中资源已改变。');
      }
      _check(access, resourceId);
      if (bytes.length != length) {
        throw const TransferException(
            TransferFailure.integrityMismatch, '文件分块长度不符。');
      }
      return bytes;
    } finally {
      _activeResources.remove(resourceId);
    }
  }

  void _check(TransferAccess access, [String? resourceId]) =>
      authorization.requireAccess(
        sessionId: access.sessionId,
        grantId: access.grantId,
        peer: access.peer,
        resourceId: resourceId,
      );
}
