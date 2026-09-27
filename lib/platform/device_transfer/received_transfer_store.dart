import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/device_transfer/transfer_protocol.dart';

enum ReceivedTransferStage { downloading, verified, ready }

/// A ready receipt means the bytes are durable and verified, NOT that they have
/// already been merged into the media/lyric library. That commit is separate.
class ReceivedTransferReceipt {
  ReceivedTransferReceipt._(
      {required this.jobId,
      required this.localId,
      required this.peerDigest,
      required this.resource,
      required this.policy,
      required this.baseVersion,
      required this.offset,
      required this.updatedAt,
      required this.stage,
      this.indexed = false});

  final String jobId, localId, peerDigest, baseVersion;
  final TransferResource resource;
  final TransferImportPolicy policy;
  final int offset;
  final DateTime updatedAt;
  final ReceivedTransferStage stage;
  final bool indexed;

  ReceivedTransferReceipt _copy(
          {int? offset,
          ReceivedTransferStage? stage,
          bool? indexed,
          DateTime? updatedAt,
          String? localId}) =>
      ReceivedTransferReceipt._(
          jobId: jobId,
          localId: localId ?? this.localId,
          peerDigest: peerDigest,
          resource: resource,
          policy: policy,
          baseVersion: baseVersion,
          offset: offset ?? this.offset,
          updatedAt: updatedAt ?? this.updatedAt,
          stage: stage ?? this.stage,
          indexed: indexed ?? this.indexed);

  Map<String, Object?> _toJson() => {
        'version': 1,
        'jobId': jobId,
        'localId': localId,
        'peerDigest': peerDigest,
        'resource': resource.toJson(),
        'policy': policy.toJson(),
        'baseVersion': baseVersion,
        'offset': offset,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'stage': stage.name,
        'indexed': indexed,
      };

  static ReceivedTransferReceipt _fromJson(Object? value) {
    if (value is! Map<String, Object?> || value['version'] != 1) {
      throw const TransferException(
          TransferFailure.storageCorrupt, '接收记录版本无法读取，原文件已保留。');
    }
    final resourceJson = value['resource'];
    if (resourceJson is! Map<String, Object?>) invalidTransferMessage();
    final resource = TransferResource.fromJson(resourceJson);
    final jobId = value['jobId'],
        localId = value['localId'],
        peer = value['peerDigest'];
    final policy = value['policy'], base = value['baseVersion'];
    final offset = value['offset'], time = value['updatedAt'];
    final stages =
        ReceivedTransferStage.values.where((s) => s.name == value['stage']);
    if (jobId is! String ||
        !isTransferDigest(jobId) ||
        localId is! String ||
        !isTransferId(localId) ||
        peer is! String ||
        !isTransferDigest(peer) ||
        jobId != _jobId(peer, resource) ||
        policy is! Map ||
        policy['overwriteLyrics'] is! bool ||
        policy['syncMetadata'] is! bool ||
        base is! String ||
        base.length > 4096 ||
        offset is! int ||
        offset < 0 ||
        offset > resource.byteLength ||
        time is! int ||
        time < 0 ||
        time > 8640000000000000 ||
        stages.isEmpty ||
        value['indexed'] is! bool) invalidTransferMessage();
    final stage = stages.single;
    if ((stage != ReceivedTransferStage.downloading &&
            offset != resource.byteLength) ||
        (value['indexed'] == true && stage != ReceivedTransferStage.ready)) {
      invalidTransferMessage();
    }
    return ReceivedTransferReceipt._(
        jobId: jobId,
        localId: localId,
        peerDigest: peer,
        resource: resource,
        policy: TransferImportPolicy(
            overwriteLyrics: policy['overwriteLyrics'] as bool,
            syncMetadata: policy['syncMetadata'] as bool),
        baseVersion: base,
        offset: offset,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(time, isUtc: true),
        stage: stage,
        indexed: value['indexed'] as bool);
  }
}

String _jobId(String peer, TransferResource resource) => sha256
    .convert(utf8.encode('$peer:${resource.id}:${resource.revision}'))
    .toString();

/// Receives bounded blocks; never interprets a remote title as a filesystem path.
/// root must be supplied by the trusted platform adapter (noBackupFilesDir on
/// Android / Application Support on macOS), never by the remote peer.
class ReceivedTransferStore {
  ReceivedTransferStore(this.root,
      {DateTime Function()? now, Future<int> Function()? availableBytes})
      : _now = now ?? (() => DateTime.now().toUtc()),
        _availableBytes = availableBytes;
  final Directory root;
  final DateTime Function() _now;
  final Future<int> Function()? _availableBytes;
  final Map<String, ReceivedTransferReceipt> _receipts = {};
  Future<void> _tail = Future.value();
  bool _initialized = false;
  String? _canonicalRoot;

  Directory get _jobs => Directory('${root.path}/jobs');
  Directory get _partials => Directory('${root.path}/partial');
  Directory get _received => Directory('${root.path}/received');

  List<ReceivedTransferReceipt> get receipts =>
      List.unmodifiable(_receipts.values);

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> initialize() => _serial(() async {
        if (_initialized) return;
        for (final directory in [root, _jobs, _partials, _received]) {
          await _ensureDirectory(directory);
        }
        _canonicalRoot = await root.resolveSymbolicLinks();
        final loaded = <String, ReceivedTransferReceipt>{};
        await for (final entity in _jobs.list(followLinks: false)) {
          final name = entity.uri.pathSegments.last;
          // Only our exact journal filenames are considered. Unrelated files stay.
          if (!RegExp(r'^[a-f0-9]{64}\.json$').hasMatch(name)) continue;
          if (loaded.length >= TransferLimits.retainedJobs) {
            throw const TransferException(
                TransferFailure.storageLimit, '接收记录数量超出限制。');
          }
          await _requireFile(entity.path);
          final file = File(entity.path);
          if (await file.length() > 256 * 1024) _corrupt();
          ReceivedTransferReceipt receipt;
          try {
            receipt = ReceivedTransferReceipt._fromJson(
                jsonDecode(await file.readAsString()));
          } on FormatException {
            _corrupt();
          }
          if (name != '${receipt.jobId}.json') _corrupt();
          loaded[receipt.jobId] = receipt;
        }
        _receipts.addAll(loaded);
        _initialized = true;
      });

  Future<ReceivedTransferReceipt> prepare({
    required String peerDigest,
    required TransferResource resource,
    TransferImportPolicy policy = const TransferImportPolicy(),
    String baseVersion = '',
  }) =>
      _serial(() async {
        await _checkRoot();
        if (!isTransferDigest(peerDigest) || baseVersion.length > 4096)
          invalidTransferMessage();
        final job = _jobId(peerDigest, resource);
        final existing = _receipts[job];
        if (existing != null) {
          // Resume preserves the original conflict baseline and user choices.
          return _recover(existing);
        }
        if (_receipts.length >= TransferLimits.retainedJobs) {
          throw const TransferException(
              TransferFailure.storageLimit, '接收记录已达上限，请先清理过期的未完成任务。');
        }
        var receipt = ReceivedTransferReceipt._(
            jobId: job,
            localId: newTransferId(),
            peerDigest: peerDigest,
            resource: resource,
            policy: policy,
            baseVersion: baseVersion,
            offset: 0,
            updatedAt: _now(),
            stage: ReceivedTransferStage.downloading);
        // Reuse only verified same-content media of the same format. Metadata is
        // kept on this receipt so a later import can independently resolve conflicts.
        for (final previous in _receipts.values) {
          if (previous.stage != ReceivedTransferStage.ready ||
              previous.resource.kind != resource.kind ||
              previous.resource.extension != resource.extension ||
              previous.resource.byteLength != resource.byteLength ||
              previous.resource.sha256Digest != resource.sha256Digest) continue;
          await _verify(_final(previous), resource);
          receipt = receipt._copy(
              localId: previous.localId,
              offset: resource.byteLength,
              stage: ReceivedTransferStage.ready);
          break;
        }
        await _ensureSpace(
            additional: receipt.stage == ReceivedTransferStage.downloading
                ? receipt.resource.byteLength
                : 0);
        await _save(receipt);
        return receipt;
      });

  Future<ReceivedTransferReceipt> append(String jobId,
      {required int offset, required List<int> bytes}) {
    if (bytes.isEmpty ||
        bytes.length > TransferLimits.blockBytes ||
        bytes.any((byte) => byte < 0 || byte > 255)) invalidTransferMessage();
    // Copy before enqueueing so the caller cannot mutate an in-flight chunk.
    final block = List<int>.of(bytes);
    return _serial(() async {
      await _checkRoot();
      var receipt = await _recover(_requireReceipt(jobId));
      if (receipt.stage != ReceivedTransferStage.downloading ||
          offset != receipt.offset ||
          block.length > receipt.resource.byteLength - offset) {
        throw const TransferException(
            TransferFailure.invalidRange, '下载分块偏移或长度不符。');
      }
      final file = _partial(receipt);
      await _ensureSpace();
      await _requireFile(file.path, allowMissing: true);
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.writeFrom(block);
        await handle.flush();
      } finally {
        await handle.close();
      }
      receipt = receipt._copy(offset: offset + block.length, updatedAt: _now());
      await _save(receipt);
      return receipt;
    });
  }

  Future<ReceivedTransferReceipt> finish(String jobId) => _serial(() async {
        await _checkRoot();
        var receipt = await _recover(_requireReceipt(jobId));
        if (receipt.stage == ReceivedTransferStage.ready) return receipt;
        if (receipt.offset != receipt.resource.byteLength) {
          throw const TransferException(
              TransferFailure.invalidRange, '文件尚未接收完整。');
        }
        final partial = _partial(receipt);
        if (receipt.resource.byteLength == 0 && !await partial.exists()) {
          await _requireFile(partial.path, allowMissing: true);
          await partial.writeAsBytes([], flush: true);
        }
        await _verify(partial, receipt.resource);
        receipt = receipt._copy(
            stage: ReceivedTransferStage.verified, updatedAt: _now());
        // Persist verified before rename. Either side of a crash can be recovered.
        await _save(receipt);
        return _publish(receipt);
      });

  Future<ReceivedTransferReceipt> recover(String jobId) => _serial(() async {
        await _checkRoot();
        return _recover(_requireReceipt(jobId));
      });

  Future<File> verifiedFile(String jobId) => _serial(() async {
        await _checkRoot();
        final receipt = await _recover(_requireReceipt(jobId));
        if (receipt.stage != ReceivedTransferStage.ready) {
          throw const TransferException(
              TransferFailure.unavailable, '文件尚未校验完成。');
        }
        return _final(receipt);
      });

  /// Called only after the media/lyric repository durably commits its index.
  Future<void> markIndexed(String jobId) => _serial(() async {
        await _checkRoot();
        final receipt = await _recover(_requireReceipt(jobId));
        if (receipt.stage != ReceivedTransferStage.ready) _corrupt();
        await _save(receipt._copy(indexed: true, updatedAt: _now()));
      });

  /// After durable indexing, history can be pruned without removing the media.
  /// The independent media index must retain localId, extension and checksum.
  Future<void> forgetIndexedReceipt(String jobId) => _serial(() async {
        await _checkRoot();
        final receipt = _requireReceipt(jobId);
        if (!receipt.indexed || receipt.stage != ReceivedTransferStage.ready) {
          throw const TransferException(
              TransferFailure.unavailable, '尚未入库，不能清理接收记录。');
        }
        await _requireFile(_journal(receipt).path);
        await _journal(receipt).delete();
        _receipts.remove(jobId);
      });

  Future<void> cancelPartial(String jobId) => _serial(() async {
        await _checkRoot();
        final receipt = _requireReceipt(jobId);
        if (receipt.stage != ReceivedTransferStage.downloading) {
          throw const TransferException(
              TransferFailure.unavailable, '文件已经完成校验，取消不会删除已接收文件。');
        }
        final partial = _partial(receipt);
        await _requireFile(partial.path, allowMissing: true);
        if (await partial.exists()) await partial.delete();
        await _requireFile(_journal(receipt).path);
        await _journal(receipt).delete();
        _receipts.remove(jobId);
      });

  /// Deletes only this store's known unfinished files. Never received media.
  Future<int> discardExpiredPartials() => _serial(() async {
        await _checkRoot();
        var removed = 0;
        for (final receipt
            in List<ReceivedTransferReceipt>.of(_receipts.values)) {
          if (receipt.stage != ReceivedTransferStage.downloading ||
              _now().difference(receipt.updatedAt) <
                  TransferLimits.partialRetention) continue;
          final partial = _partial(receipt);
          await _requireFile(partial.path, allowMissing: true);
          if (await partial.exists()) await partial.delete();
          final journal = _journal(receipt);
          await _requireFile(journal.path);
          await journal.delete();
          _receipts.remove(receipt.jobId);
          removed++;
        }
        return removed;
      });

  Future<ReceivedTransferReceipt> _recover(
      ReceivedTransferReceipt receipt) async {
    if (receipt.stage == ReceivedTransferStage.ready) {
      await _verify(_final(receipt), receipt.resource);
      return receipt;
    }
    if (receipt.stage == ReceivedTransferStage.verified)
      return _publish(receipt);
    final partial = _partial(receipt);
    await _requireFile(partial.path, allowMissing: receipt.offset == 0);
    if (await partial.exists()) {
      final length = await partial.length();
      if (length < receipt.offset) _corrupt();
      if (length > receipt.offset) {
        // Bytes may have flushed before a failed journal write; only the durable
        // checkpoint is acknowledged. Never append after unacknowledged bytes.
        final handle = await partial.open(mode: FileMode.append);
        try {
          await handle.truncate(receipt.offset);
          await handle.flush();
        } finally {
          await handle.close();
        }
      }
    }
    return receipt;
  }

  Future<ReceivedTransferReceipt> _publish(
      ReceivedTransferReceipt receipt) async {
    final target = _final(receipt);
    await _requireFile(target.path, allowMissing: true);
    if (await target.exists()) {
      await _verify(target, receipt.resource);
    } else {
      final partial = _partial(receipt);
      await _verify(partial, receipt.resource);
      await partial.rename(target.path);
    }
    final ready =
        receipt._copy(stage: ReceivedTransferStage.ready, updatedAt: _now());
    await _save(ready);
    return ready;
  }

  Future<void> _verify(File file, TransferResource resource) async {
    await _requireFile(file.path);
    if (await file.length() != resource.byteLength ||
        (await sha256.bind(file.openRead()).first).toString() !=
            resource.sha256Digest) {
      throw const TransferException(
          TransferFailure.integrityMismatch, '文件完整性校验失败，未导入媒体库。');
    }
  }

  Future<void> _ensureSpace({int additional = 0}) async {
    final query = _availableBytes;
    if (query == null) return;
    final outstanding = _receipts.values
        .where((r) => r.stage == ReceivedTransferStage.downloading)
        .fold<int>(
            additional, (sum, r) => sum + r.resource.byteLength - r.offset);
    if (await query() < outstanding + 16 * 1024 * 1024) {
      throw const TransferException(
          TransferFailure.insufficientSpace, '接收目录空间不足，已暂停写入并保留已接收分块。');
    }
  }

  Future<void> _save(ReceivedTransferReceipt receipt) async {
    final journal = _journal(receipt);
    final temporary = File('${journal.path}.tmp');
    await _requireFile(journal.path, allowMissing: true);
    await _requireFile(temporary.path, allowMissing: true);
    await temporary.writeAsString(jsonEncode(receipt._toJson()), flush: true);
    await temporary.rename(journal.path);
    _receipts[receipt.jobId] = receipt;
  }

  ReceivedTransferReceipt _requireReceipt(String jobId) {
    final receipt = _receipts[jobId];
    if (receipt == null)
      throw const TransferException(TransferFailure.unavailable, '未找到接收任务。');
    return receipt;
  }

  File _journal(ReceivedTransferReceipt receipt) =>
      File('${_jobs.path}/${receipt.jobId}.json');
  File _partial(ReceivedTransferReceipt receipt) =>
      File('${_partials.path}/${receipt.jobId}.part');
  File _final(ReceivedTransferReceipt receipt) => File(
      '${_received.path}/${receipt.localId}.${receipt.resource.extension}');

  Future<void> _checkRoot() async {
    if (!_initialized)
      throw StateError('ReceivedTransferStore.initialize must complete first.');
    if (await root.resolveSymbolicLinks() != _canonicalRoot) _corrupt();
    for (final directory in [root, _jobs, _partials, _received]) {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) _corrupt();
    }
  }

  Future<void> _ensureDirectory(Directory directory) async {
    final type =
        await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound)
      await directory.create(recursive: true);
    else if (type != FileSystemEntityType.directory) _corrupt();
  }

  Future<void> _requireFile(String path, {bool allowMissing = false}) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file ||
        (allowMissing && type == FileSystemEntityType.notFound)) return;
    _corrupt();
  }

  Never _corrupt() => throw const TransferException(
      TransferFailure.storageCorrupt, '接收目录或记录异常，已停止写入并保留原文件。');
}
