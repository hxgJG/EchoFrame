import 'dart:typed_data';

import '../../core/device_transfer/transfer_protocol.dart';
import 'received_transfer_store.dart';

/// Implemented only by a peer-authenticated transport. No URL/path download API.
abstract interface class TransferDownloadSource {
  Future<Uint8List> readBlock(
      TransferResource resource, int offset, int length);
}

class TransferReceiveControl {
  bool _paused = false;
  bool get isPaused => _paused;
  void pause() => _paused = true;
}

class TransferReceivePaused implements Exception {
  const TransferReceivePaused();
  @override
  String toString() => '传输已暂停，已保存的分块可在有效授权下继续接收。';
}

/// Foreground download orchestrator. Callers pause controls on lifecycle changes;
/// resuming requires a new control and a currently authenticated source.
class TransferReceiver {
  TransferReceiver(this.store);
  final ReceivedTransferStore store;
  final Set<String> _active = {};

  Future<ReceivedTransferReceipt> receive({
    required TransferDownloadSource source,
    required String peerDigest,
    required TransferResource resource,
    required TransferReceiveControl control,
    TransferImportPolicy policy = const TransferImportPolicy(),
    String baseVersion = '',
    void Function(int received, int total)? onProgress,
  }) async {
    final key = '$peerDigest:${resource.id}:${resource.revision}';
    if (_active.length >= TransferLimits.parallelFiles || !_active.add(key)) {
      throw const TransferException(TransferFailure.busy, '同时接收的文件数量已达上限。');
    }
    try {
      _check(control);
      var receipt = await store.prepare(
          peerDigest: peerDigest,
          resource: resource,
          policy: policy,
          baseVersion: baseVersion);
      _check(control);
      onProgress?.call(receipt.offset, resource.byteLength);
      while (receipt.offset < resource.byteLength) {
        _check(control);
        final remaining = resource.byteLength - receipt.offset;
        final length = remaining < TransferLimits.blockBytes
            ? remaining
            : TransferLimits.blockBytes;
        final bytes = await source.readBlock(resource, receipt.offset, length);
        _check(control);
        if (bytes.length != length) {
          throw const TransferException(
              TransferFailure.integrityMismatch, '对方返回的分块长度不符。');
        }
        receipt = await store.append(receipt.jobId,
            offset: receipt.offset, bytes: bytes);
        onProgress?.call(receipt.offset, resource.byteLength);
      }
      _check(control);
      return await store.finish(receipt.jobId);
    } finally {
      _active.remove(key);
    }
  }

  void _check(TransferReceiveControl control) {
    if (control.isPaused) throw const TransferReceivePaused();
  }
}
