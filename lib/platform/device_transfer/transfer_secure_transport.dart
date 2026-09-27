import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/device_transfer/transfer_authorization.dart';
import '../../core/device_transfer/transfer_host.dart';
import '../../core/device_transfer/transfer_invitation.dart';
import '../../core/device_transfer/transfer_protocol.dart';
import '../../core/device_transfer/transfer_pairing.dart';
import 'transfer_identity.dart';
import 'transfer_receiver.dart';

const _maximumFrame = 2 * 1024 * 1024;

Stream<Uint8List> _frames(Stream<Uint8List> input) async* {
  var buffer = BytesBuilder(copy: false);
  var header = <int>[];
  int? wanted;
  await for (final bytes in input) {
    var offset = 0;
    while (offset < bytes.length) {
      if (wanted == null) {
        final take = (4 - header.length).clamp(0, bytes.length - offset);
        header.addAll(bytes.sublist(offset, offset + take));
        offset += take;
        if (header.length != 4) continue;
        wanted = ByteData.sublistView(Uint8List.fromList(header)).getUint32(0);
        if (wanted < 2 || wanted > _maximumFrame) invalidTransferMessage();
        header = [];
      }
      final take = (wanted - buffer.length).clamp(0, bytes.length - offset);
      buffer.add(Uint8List.sublistView(bytes, offset, offset + take));
      offset += take;
      if (buffer.length == wanted) {
        yield buffer.takeBytes();
        buffer = BytesBuilder(copy: false);
        wanted = null;
      }
    }
  }
  if (header.isNotEmpty || wanted != null)
    throw const FormatException('连接在分块完成前断开。');
}

class _Wire {
  _Wire(this.socket) {
    _subscription = _frames(socket).listen((bytes) {
      if (_ending) return;
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map<String, Object?>) invalidTransferMessage();
        if (value['error'] is String) {
          _fail(TransferException(
              TransferFailure.values.firstWhere((e) => e.name == value['code'],
                  orElse: () => TransferFailure.unavailable),
              value['error'] as String));
          return;
        }
        final pending = _pending;
        if (pending != null) {
          _pending = null;
          pending.complete(value);
        } else {
          if (_queue.length >= 4) invalidTransferMessage();
          _queue.add(value);
        }
      } catch (e) {
        _fail(e);
      }
    },
        onError: (Object e) => _fail(e),
        onDone: () => _fail(const SocketException('对方已断开连接。')));
  }
  final SecureSocket socket;
  late final StreamSubscription<Uint8List> _subscription;
  final Queue<Map<String, Object?>> _queue = Queue();
  Completer<Map<String, Object?>>? _pending;
  Object? _failure;
  final Completer<void> _peerClosed = Completer<void>();
  bool _ending = false;
  Future<void>? termination;
  void Function()? onDisconnected;
  bool closed = false;
  Future<Map<String, Object?>> read(
      {Duration timeout = const Duration(minutes: 5)}) async {
    if (_queue.isNotEmpty) return _queue.removeFirst();
    if (_failure != null) throw _failure!;
    if (_pending != null) throw StateError('已有请求正在读取。');
    final pending = Completer<Map<String, Object?>>();
    _pending = pending;
    try {
      return await pending.future.timeout(timeout);
    } finally {
      if (_pending == pending) _pending = null;
    }
  }

  void _fail(Object error) {
    if (closed) return;
    _failure = error;
    closed = true;
    if (!_peerClosed.isCompleted) _peerClosed.complete();
    final pending = _pending;
    _pending = null;
    pending?.completeError(error);
    socket.destroy();
    unawaited(_subscription.cancel());
    if (error is TransferException &&
        error.code == TransferFailure.disconnected) {
      onDisconnected?.call();
    }
  }

  Future<void> send(Map<String, Object?> value) async {
    if (closed) throw _failure ?? const SocketException('连接已关闭。');
    if (_ending && !value.containsKey('error')) {
      throw const TransferException(TransferFailure.disconnected, '连接已结束。');
    }
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > _maximumFrame) invalidTransferMessage();
    final header = ByteData(4)..setUint32(0, bytes.length);
    socket.add(header.buffer.asUint8List());
    socket.add(bytes);
    await socket.flush().timeout(const Duration(seconds: 20));
  }

  void close() {
    _fail(const SocketException('连接已关闭。'));
  }

  void terminate({TransferException? error}) {
    if (closed || _ending) return;
    _ending = true;
    // Drain incoming requests until the peer consumes the terminal frame;
    // destroying a socket with unread data can reset and discard that frame.
    termination = () async {
      try {
        await send({
          'error': error?.message ?? '对方已断开连接，请重新申请。',
          'code': (error?.code ?? TransferFailure.disconnected).name
        });
        await _peerClosed.future.timeout(const Duration(seconds: 1));
      } catch (_) {
      } finally {
        close();
      }
    }();
  }
}

class TransferSecureServer {
  TransferSecureServer(
      {required this.identity,
      required this.host,
      required this.name,
      required this.changed,
      this.onRead,
      this.onDisconnected,
      this.deviceInfo = const TransferDeviceInfo(),
      this.allowLoopback = false});
  final TransferIdentity identity;
  final TransferHost host;
  final String name;
  final void Function() changed;
  final void Function(String resourceId, int bytes)? onRead;
  final void Function(String identityDigest)? onDisconnected;
  final TransferDeviceInfo deviceInfo;
  final bool allowLoopback;
  final TransferPairingThrottle _throttle = TransferPairingThrottle();
  final Set<_Wire> _connections = {};
  SecureServerSocket? _server;
  TransferEndpoint? endpoint;
  final Map<_Wire, String> _peers = {};
  final Map<String, DateTime> _rejected = {};
  final List<DateTime> _attempts = [];
  final List<DateTime> _handshakes = [];
  int _epoch = 0;
  Timer? _expiryTimer;
  bool foreground = true;

  void suspend() {
    foreground = false;
    for (final connection in _connections.toList()) {
      connection.close();
    }
  }

  Future<void> pauseNetwork() async {
    suspend();
    _epoch++;
    endpoint = null;
    final listener = _server;
    _server = null;
    await listener?.close();
  }

  Future<void> rebind(InternetAddress address) async {
    await pauseNetwork();
    if (!host.authorization.isSharing) return;
    _expiryTimer?.cancel();
    foreground = true;
    await start(address);
  }

  Future<void> start(InternetAddress address) async {
    if (!isLocalTransferAddress(address, allowLoopback: allowLoopback) ||
        !host.authorization.isSharing) {
      invalidTransferMessage();
    }
    final epoch = _epoch;
    final listener = await SecureServerSocket.bind(
        address, 0, identity.serverContext(),
        backlog: 4);
    if (epoch != _epoch || !host.authorization.isSharing) {
      await listener.close();
      return;
    }
    _server = listener;
    endpoint = TransferEndpoint(
        address: address.address,
        port: _server!.port,
        identityDigest: identity.digest,
        certificateDigest: identity.certificateDigest,
        allowLoopback: allowLoopback);
    _server!.listen((socket) {
      final now = DateTime.now();
      _handshakes
          .removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
      if (!foreground ||
          _handshakes.length >= 30 ||
          _connections.length >= 4 ||
          !_throttle.canAttempt ||
          !isLocalTransferAddress(socket.remoteAddress,
              allowLoopback: allowLoopback)) {
        socket.destroy();
        return;
      }
      _handshakes.add(now);
      final wire = _Wire(socket);
      _connections.add(wire);
      unawaited(_serve(wire));
    }, onError: (Object _) {
      // A failed TLS handshake belongs to that socket, not the sharing session.
    });
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Requests also check expiry; UI countdown never controls access.
      changed();
    });
  }

  void reject() {
    final pending = host.authorization.pending;
    if (pending == null) return;
    _rejected[pending.peer.identityDigest] = DateTime.now();
    while (_rejected.length > 100) {
      _rejected.remove(_rejected.keys.first);
    }
    host.authorization.reject(pending.id);
    changed();
  }

  void revoke() {
    _epoch++;
    host.authorization.revoke();
    for (final connection in _connections.toList()) {
      connection.terminate();
    }
    changed();
  }

  Future<void> stop() async {
    _expiryTimer?.cancel();
    endpoint = null;
    _epoch++;
    host.stop();
    for (final connection in _connections.toList()) {
      connection.close();
    }
    _connections.clear();
    final server = _server;
    _server = null;
    await server?.close();
    changed();
  }

  Future<void> _serve(_Wire wire) async {
    try {
      final session = host.authorization.sessionId!;
      final epoch = _epoch;
      final hello = await wire.read(timeout: const Duration(seconds: 10));
      if (hello['v'] != 2) {
        throw const TransferException(TransferFailure.unsupportedVersion,
            '互传协议版本不同，请将两端 App 更新到支持安全码连接的版本。');
      }
      if (hello['publicKey'] is! String ||
          (hello['publicKey'] as String).length > 4096 ||
          hello['name'] is! String ||
          hello['nonce'] is! String ||
          !isTransferId(hello['nonce'] as String) ||
          hello['resumeKey'] is! String ||
          !isTransferId(hello['resumeKey'] as String)) {
        invalidTransferMessage();
      }
      final public = hello['publicKey'] as String;
      final peerDigest = publicKeyDigest(public);
      final peerInfo = TransferDeviceInfo.fromJson(hello['deviceInfo']);
      final nonce = newTransferId() + newTransferId();
      final binding = TransferPeerBinding(
          identityDigest: peerDigest,
          channelDigest: sha256
              .convert(utf8.encode(
                  '$session:${identity.digest}:$peerDigest:${hello['resumeKey']}'))
              .toString(),
          displayName: hello['name'] as String,
          deviceInfo: peerInfo);
      final transcript = pairingChallenge(
          session: session,
          certificate: identity.certificateDigest,
          nonce: nonce,
          clientNonce: hello['nonce'] as String,
          serverKey: identity.publicKey,
          clientKey: public,
          serverName: name,
          clientName: binding.displayName,
          serverInfo: deviceInfo,
          clientInfo: peerInfo,
          resumeKey: hello['resumeKey'] as String);
      await wire.send({
        'v': 2,
        'session': session,
        'challenge': nonce,
        'certificate': identity.certificateDigest,
        'publicKey': identity.publicKey,
        'name': name,
        'deviceInfo': deviceInfo.toJson(),
        'signature': identity.sign(transcript)
      });
      final proof = await wire.read(timeout: const Duration(minutes: 2));
      if (proof['signature'] is! String ||
          !TransferIdentity.verify(
              public, [...transcript, 1], proof['signature'] as String)) {
        _throttle.recordFailure();
        throw const TransferException(
            TransferFailure.unauthorized, '设备身份校验失败。');
      }
      if (!foreground ||
          epoch != _epoch ||
          session != host.authorization.sessionId) {
        throw const TransferException(
            TransferFailure.disconnected, '共享状态已变化，请重新申请。');
      }
      _throttle.recordSuccess();
      final now = DateTime.now();
      _attempts
          .removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
      if (_rejected[peerDigest] case final rejected?) {
        if (now.difference(rejected) < const Duration(minutes: 1)) {
          throw const TransferException(
              TransferFailure.busy, '申请已被拒绝，请 1 分钟后再试。');
        }
      }
      var grant = host.authorization.grant;
      if (grant != null &&
          grant.peer.identityDigest == peerDigest &&
          !grant.peer.matches(binding)) {
        // A new process or deliberate disconnect rotates the resume secret.
        // Old sockets cannot retain access after this new pairing attempt.
        host.authorization.revoke();
        for (final entry in _peers.entries.toList()) {
          if (entry.value == peerDigest) entry.key.close();
        }
        grant = null;
      }
      final resuming = grant != null && grant.peer.matches(binding);
      if (!resuming) {
        if (_attempts.length >= 10) {
          throw const TransferException(
              TransferFailure.busy, '连接申请过于频繁，请稍后重试。');
        }
        _attempts.add(now);
      }
      final pending = host.authorization.pending;
      if (pending != null &&
          pending.peer.identityDigest == peerDigest &&
          !pending.peer.matches(binding)) {
        host.authorization.reject(pending.id);
      }
      _peers[wire] = peerDigest;
      String? requestId;
      if (!resuming)
        requestId = host.authorization
            .requestApproval(sessionId: session, peer: binding)
            .id;
      changed();
      Map<String, Object?> status() {
        if (epoch != _epoch || host.authorization.sessionId != session) {
          throw const TransferException(TransferFailure.notSharing, '共享已关闭。');
        }
        final current = host.authorization.grant;
        if (current != null && current.peer.matches(binding)) {
          return {
            'state': 'approved',
            'expiresAt': current.expiresAt.millisecondsSinceEpoch,
            'identity': identity.digest,
            'name': name
          };
        }
        final pending = host.authorization.pending;
        if (pending != null &&
            pending.id == requestId &&
            pending.peer.matches(binding)) {
          return {
            'state': 'pending',
            'identity': identity.digest,
            'name': name
          };
        }
        throw const TransferException(
            TransferFailure.unauthorized, '申请被拒绝、已撤销或授权已到期，请重新申请。');
      }

      await wire.send(status());
      var expectedSequence = 1;
      while (!wire.closed) {
        final request = await wire.read();
        if (!foreground)
          throw const TransferException(
              TransferFailure.unavailable, '对方已离开前台，请稍后重连。');
        if (request['sequence'] != expectedSequence++) invalidTransferMessage();
        final state = status();
        if (request['command'] == 'disconnect') {
          onDisconnected?.call(peerDigest);
          revoke();
          break;
        }
        if (request['command'] == 'status') {
          await wire.send(state);
          continue;
        }
        if (state['state'] != 'approved') {
          throw const TransferException(
              TransferFailure.unauthorized, '请等待对方批准连接。');
        }
        final current = host.authorization.grant!;
        final access = TransferAccess(
            sessionId: session, grantId: current.id, peer: binding);
        switch (request['command']) {
          case 'catalog':
            final offset = request['offset'];
            if (offset is! int || offset < 0 || offset > 1500)
              invalidTransferMessage();
            final catalog = await host.catalog(access);
            await wire.send({
              'resources': catalog.resources
                  .skip(offset)
                  .take(50)
                  .map((r) => r.toJson())
                  .toList(),
              'total': catalog.resources.length
            });
          case 'read':
            final id = request['id'], revision = request['revision'];
            final offset = request['offset'], length = request['length'];
            if (id is! String ||
                revision is! String ||
                offset is! int ||
                length is! int) invalidTransferMessage();
            final bytes = await host.readBlock(access,
                resourceId: id,
                revision: revision,
                offset: offset,
                length: length);
            await wire.send({'bytes': base64Encode(bytes)});
            onRead?.call(id, bytes.length);
          case 'receipt':
            final id = request['id'];
            if (id is! String) invalidTransferMessage();
            host.authorization.requireAccess(
                sessionId: access.sessionId,
                grantId: access.grantId,
                peer: binding,
                resourceId: id);
            await wire.send({'ok': true});
          default:
            invalidTransferMessage();
        }
      }
    } catch (error) {
      wire.terminate(
          error: error is TransferException
              ? error
              : const TransferException(
                  TransferFailure.unavailable, '连接校验或文件读取失败，请重新连接。'));
    } finally {
      await wire.termination;
      wire.close();
      _connections.remove(wire);
      _peers.remove(wire);
    }
  }
}

class TransferSecureClient implements TransferDownloadSource {
  TransferSecureClient._(this._wire, this.remoteIdentity, this.remoteName,
      this.remoteInfo, this.status, this.onDisconnected);
  final _Wire _wire;
  final String remoteIdentity, remoteName;
  final TransferDeviceInfo remoteInfo;
  final void Function()? onDisconnected;
  Map<String, Object?> status;
  Future<void> _tail = Future.value();
  int _sequence = 0;
  bool get closed => _wire.closed;

  static Future<TransferSecureClient> connect(
      TransferEndpoint endpoint, TransferIdentity identity, String name,
      {required String resumeKey,
      required Future<bool> Function(TransferRemoteDevice) confirm,
      TransferDeviceInfo deviceInfo = const TransferDeviceInfo(),
      void Function()? onDisconnected}) async {
    final socket = await SecureSocket.connect(endpoint.address, endpoint.port,
        context: SecurityContext(withTrustedRoots: false)
          ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2,
        timeout: const Duration(seconds: 10),
        onBadCertificate: (certificate) =>
            sha256.convert(certificate.der).toString() ==
                endpoint.certificateDigest &&
            DateTime.now().isBefore(certificate.endValidity) &&
            DateTime.now().isAfter(certificate.startValidity));
    final wire = _Wire(socket);
    try {
      if (socket.peerCertificate == null ||
          sha256.convert(socket.peerCertificate!.der).toString() !=
              endpoint.certificateDigest) {
        throw const TransferException(
            TransferFailure.unauthorized, '对方证书已变化，请刷新附近设备后重试。');
      }
      final nonce = newTransferId();
      await wire.send({
        'v': 2,
        'publicKey': identity.publicKey,
        'name': name,
        'nonce': nonce,
        'resumeKey': resumeKey,
        'deviceInfo': deviceInfo.toJson(),
      });
      final challenge = await wire.read(timeout: const Duration(seconds: 10));
      if (challenge['v'] != 2 ||
          challenge['session'] is! String ||
          !isTransferId(challenge['session'] as String) ||
          challenge['publicKey'] is! String ||
          (challenge['publicKey'] as String).length > 4096 ||
          challenge['name'] is! String ||
          (challenge['name'] as String).isEmpty ||
          (challenge['name'] as String).length > 80 ||
          (challenge['name'] as String).contains(RegExp(r'[\x00-\x1f\x7f]')) ||
          challenge['signature'] is! String ||
          challenge['certificate'] != endpoint.certificateDigest ||
          challenge['challenge'] is! String ||
          !isTransferDigest(challenge['challenge'] as String))
        invalidTransferMessage();
      final public = challenge['publicKey'] as String;
      final remoteName = challenge['name'] as String;
      final remoteInfo = TransferDeviceInfo.fromJson(challenge['deviceInfo']);
      final digest = publicKeyDigest(public);
      final transcript = pairingChallenge(
          session: challenge['session'] as String,
          certificate: endpoint.certificateDigest,
          nonce: challenge['challenge'] as String,
          clientNonce: nonce,
          serverKey: public,
          clientKey: identity.publicKey,
          serverName: remoteName,
          clientName: name,
          serverInfo: remoteInfo,
          clientInfo: deviceInfo,
          resumeKey: resumeKey);
      if (digest != endpoint.identityDigest ||
          !TransferIdentity.verify(
              public, transcript, challenge['signature'] as String)) {
        throw const TransferException(
            TransferFailure.unauthorized, '设备安全码与实际身份不符，已拒绝连接。');
      }
      if (!await confirm(
          TransferRemoteDevice(digest, remoteName, remoteInfo))) {
        throw const TransferException(TransferFailure.unauthorized, '已取消连接。');
      }
      await wire.send({
        'signature': identity.sign([...transcript, 1])
      });
      final status = await wire.read();
      if (status['identity'] != digest ||
          status['name'] != remoteName ||
          !['pending', 'approved'].contains(status['state']))
        invalidTransferMessage();
      wire.onDisconnected = onDisconnected;
      return TransferSecureClient._(
          wire, digest, remoteName, remoteInfo, status, onDisconnected);
    } catch (_) {
      wire.close();
      rethrow;
    }
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> request) {
    final operation = _tail.then((_) async {
      try {
        await _wire.send({...request, 'sequence': ++_sequence});
        return await _wire.read();
      } catch (e) {
        close();
        rethrow;
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<Map<String, Object?>> refreshStatus() async =>
      status = await _request({'command': 'status'});

  Future<TransferManifest> catalog() async {
    final resources = <TransferResource>[];
    var total = 0;
    do {
      final response =
          await _request({'command': 'catalog', 'offset': resources.length});
      final list = response['resources'];
      if (list is! List || list.length > 50 || response['total'] is! int)
        invalidTransferMessage();
      total = response['total'] as int;
      if (total < resources.length ||
          total > 1500 ||
          (resources.length < total && list.isEmpty)) invalidTransferMessage();
      for (final raw in list) {
        if (raw is! Map<String, Object?>) invalidTransferMessage();
        resources.add(TransferResource.fromJson(raw));
      }
      if (resources.length > total) invalidTransferMessage();
    } while (resources.length < total);
    return TransferManifest(resources);
  }

  @override
  Future<Uint8List> readBlock(
      TransferResource resource, int offset, int length) async {
    final response = await _request({
      'command': 'read',
      'id': resource.id,
      'revision': resource.revision,
      'offset': offset,
      'length': length
    });
    final bytes = response['bytes'];
    if (bytes is! String || bytes.length > TransferLimits.blockBytes * 2)
      invalidTransferMessage();
    final decoded = base64Decode(bytes);
    if (decoded.length != length) invalidTransferMessage();
    return decoded;
  }

  Future<void> receipt(String id) async {
    await _request({'command': 'receipt', 'id': id});
  }

  Future<void> disconnect() async {
    try {
      await _request({'command': 'disconnect'})
          .timeout(const Duration(seconds: 1));
    } catch (_) {
    } finally {
      close();
    }
  }

  void close() => _wire.close();
}
