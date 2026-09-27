import 'dart:convert';
import 'dart:io';

import '../../core/device_transfer/transfer_pairing.dart';
import '../../core/device_transfer/transfer_protocol.dart';

/// Remember identity, never an access grant or a resume secret.
class TransferPeerStore {
  TransferPeerStore(this.root);
  final Directory root;
  final Map<String, String> _peers = {};
  String? lastIdentity;
  Future<void> _tail = Future.value();
  File get _file => File('${root.path}/known_peers.v2.json');

  Future<void> _check() async {
    if (await root.resolveSymbolicLinks() != root.absolute.path) {
      throw const FormatException('设备记录目录异常。');
    }
    final type = await FileSystemEntity.type(_file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FormatException('设备记录文件异常。');
    }
  }

  Future<void> load() async {
    await _check();
    if (!await _file.exists()) return;
    if (await _file.length() > 32768) throw const FormatException('设备记录过大。');
    final raw = jsonDecode(await _file.readAsString());
    if (raw is! Map ||
        raw['version'] != 2 ||
        raw['peers'] is! Map ||
        (raw['peers'] as Map).length > 100)
      throw const FormatException('设备记录损坏。');
    for (final entry in (raw['peers'] as Map).entries) {
      if (entry.key is! String ||
          !isTransferDigest(entry.key) ||
          entry.value is! String ||
          (entry.value as String).length > 80) {
        throw const FormatException('设备记录损坏。');
      }
      _peers[entry.key as String] = entry.value as String;
    }
    if (raw['last'] is String && _peers.containsKey(raw['last'])) {
      lastIdentity = raw['last'] as String;
    }
  }

  bool contains(String digest) => _peers.containsKey(digest);
  void checkIdentity(String digest) {
    if (_peers.keys.any((id) =>
        id != digest && displaySafetyCode(id) == displaySafetyCode(digest))) {
      throw const FormatException('安全码对应的完整身份发生冲突，已拒绝连接。');
    }
  }

  Future<void> remember(TransferRemoteDevice device, {bool receiving = false}) {
    final operation = _tail.then((_) async {
      checkIdentity(device.identityDigest);
      await _check();
      final peers = {..._peers, device.identityDigest: device.name};
      while (peers.length > 100) {
        peers.remove(peers.keys.first);
      }
      final last = receiving ? device.identityDigest : lastIdentity;
      final temp = File('${root.path}/peers-${newTransferId()}.tmp');
      try {
        await temp.writeAsString(
            jsonEncode({'version': 2, 'peers': peers, 'last': last}),
            flush: true);
        await _check();
        await temp.rename(_file.path);
        _peers
          ..clear()
          ..addAll(peers);
        lastIdentity = last;
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }
}
