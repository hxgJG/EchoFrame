import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/device_transfer/transfer_authorization.dart';
import 'package:lumio/core/device_transfer/transfer_host.dart';
import 'package:lumio/core/device_transfer/transfer_invitation.dart';
import 'package:lumio/core/device_transfer/transfer_pairing.dart';
import 'package:lumio/core/device_transfer/transfer_protocol.dart';
import 'package:lumio/platform/device_transfer/transfer_identity.dart';
import 'package:lumio/platform/device_transfer/transfer_secure_transport.dart';
import 'package:lumio/platform/device_transfer/received_transfer_store.dart';
import 'package:lumio/platform/device_transfer/transfer_receiver.dart';

import '../../support/transfer_fixtures.dart';

class _Reader implements TransferResourceReader {
  final bytes = Uint8List.fromList(List.generate(700000, (i) => i % 251));
  @override
  Future<bool> isAvailable(TransferResource resource) async => true;
  @override
  Future<Uint8List> readBlock(
          TransferResource resource, int offset, int length) async =>
      Uint8List.sublistView(bytes, offset, offset + length);
}

void main() {
  late TransferIdentity a, b, c;
  late TransferSecureServer server;
  late TransferAuthorization auth;
  late TransferResource resource;
  late _Reader reader;
  final clients = <TransferSecureClient>[];
  late String resumeKey;
  setUpAll(() async {
    a = await TransferIdentity.ephemeral();
    b = await TransferIdentity.ephemeral();
    c = await TransferIdentity.ephemeral();
  });
  setUp(() async {
    resumeKey = newTransferId();
    reader = _Reader();
    resource = transferResource(bytes: reader.bytes);
    auth = TransferAuthorization();
    final host = TransferHost(authorization: auth, reader: reader);
    host.start(TransferManifest([resource]), {resource.id});
    server = TransferSecureServer(
        identity: a,
        host: host,
        name: 'Mac QA',
        deviceInfo: const TransferDeviceInfo(
            type: '电脑', brand: 'Apple', model: 'MacBookPro18,3'),
        changed: () {},
        allowLoopback: true);
    await server.start(InternetAddress.loopbackIPv4);
  });
  tearDown(() async {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    await server.stop();
  });
  Future<TransferSecureClient> connect(
      [TransferIdentity? identity, TransferEndpoint? endpoint]) async {
    final client = await TransferSecureClient.connect(
        endpoint ?? server.endpoint!, identity ?? b, 'Android QA',
        resumeKey: resumeKey,
        confirm: (_) async => true,
        deviceInfo:
            const TransferDeviceInfo(type: '手机', brand: 'Xiaomi', model: '14'));
    clients.add(client);
    return client;
  }

  TransferEndpoint altered({String? pin, String? identity}) {
    final endpoint = server.endpoint!;
    return TransferEndpoint(
        address: endpoint.address,
        port: endpoint.port,
        certificateDigest: pin ?? endpoint.certificateDigest,
        identityDigest: identity ?? endpoint.identityDigest,
        allowLoopback: true);
  }

  test('真实 TLS：审批前不得获取目录，设备码绑定持钥身份', () async {
    final client = await connect();
    expect(client.status['state'], 'pending');
    expect(auth.pending!.peer.identityDigest, b.digest);
    expect(auth.pending!.peer.safetyCode, b.safetyCode);
    expect(auth.pending!.peer.deviceInfo.model, '14');
    expect(client.remoteInfo.model, 'MacBookPro18,3');
    await expectLater(client.catalog(), throwsA(isA<TransferException>()));
  });
  test('真实 TLS：批准、跨三个分块接收、校验和入库阶段分离', () async {
    final client = await connect();
    auth.approve(auth.pending!.id);
    expect((await client.refreshStatus())['state'], 'approved');
    final manifest = await client.catalog();
    expect(manifest.resources.single.sha256Digest, resource.sha256Digest);
    final root = await Directory.systemTemp.createTemp('lumio-tls-');
    try {
      final store = ReceivedTransferStore(root);
      await store.initialize();
      final receipt = await TransferReceiver(store).receive(
          source: client,
          peerDigest: a.digest,
          resource: resource,
          control: TransferReceiveControl());
      expect(await (await store.verifiedFile(receipt.jobId)).readAsBytes(),
          reader.bytes);
      expect(receipt.indexed, false);
      await client.receipt(resource.id);
      server.revoke();
      await expectLater(client.readBlock(resource, 0, 3), throwsA(anything));
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('错误证书与伪造广播身份被拒绝，不产生申请', () async {
    await expectLater(
        connect(b, altered(pin: transferPeerDigest)), throwsA(anything));
    expect(auth.pending, isNull);
    await expectLater(
        connect(b, altered(identity: c.digest)), throwsA(anything));
    expect(auth.pending, isNull);
    expect((await connect()).status['state'], 'pending');
  });
  test('意外掉线后持有相同恢复材料的身份可重连且不延期', () async {
    final first = await connect();
    auth.approve(auth.pending!.id);
    final deadline = auth.grant!.expiresAt;
    first.close();
    final resumed = await connect();
    expect(resumed.status['state'], 'approved');
    expect(auth.grant!.expiresAt, deadline);
    await expectLater(connect(c), throwsA(anything));
    expect(auth.grant!.peer.identityDigest, b.digest);
  });
  test('网络监听重建后身份和有效授权保持不变', () async {
    final first = await connect();
    auth.approve(auth.pending!.id);
    final deadline = auth.grant!.expiresAt;
    await server.pauseNetwork();
    expect(server.endpoint, isNull);
    await expectLater(first.catalog(), throwsA(anything));
    await server.rebind(InternetAddress.loopbackIPv4);
    expect(server.endpoint!.identityDigest, a.digest);
    expect((await connect()).status['state'], 'approved');
    expect(auth.grant!.expiresAt, deadline);
  });
  test('签名绑定会话、随机挑战与名称，无法跨挑战重放', () {
    final challenge = peerChallenge(
        session: newTransferId(),
        certificate: a.certificateDigest,
        nonce: newTransferId(),
        clientNonce: newTransferId(),
        publicKey: b.publicKey,
        name: 'B');
    final signature = b.sign(challenge);
    expect(TransferIdentity.verify(b.publicKey, challenge, signature), true);
    expect(TransferIdentity.verify(c.publicKey, challenge, signature), false);
    expect(TransferIdentity.verify(b.publicKey, [...challenge, 0], signature),
        false);
  });
  test('默认拒绝公网与回环地址，测试回环需显式授权', () {
    expect(
        () => TransferEndpoint(
            address: '127.0.0.1',
            port: 1234,
            identityDigest: a.digest,
            certificateDigest: a.certificateDigest),
        throwsA(anything));
    expect(isLocalTransferAddress(InternetAddress('8.8.8.8')), false);
    expect(isLocalTransferAddress(InternetAddress('192.168.1.2')), true);
  });
  test('取消首次安全码核对不会产生访问申请', () async {
    await expectLater(
        TransferSecureClient.connect(server.endpoint!, b, 'B',
            resumeKey: resumeKey, confirm: (device) async {
          expect(device.safetyCode, a.safetyCode);
          return false;
        }),
        throwsA(isA<TransferException>()));
    expect(auth.pending, isNull);
    expect(auth.grant, isNull);
  });
  test('接收方主动断开撤销授权，下次需要重新批准', () async {
    final client = await connect();
    auth.approve(auth.pending!.id);
    await client.disconnect();
    expect(auth.grant, isNull);
    expect((await connect()).status['state'], 'pending');
  });
  test('主动断开通知丢失或进程重启后，新恢复材料不可沿用旧授权', () async {
    final old = await connect();
    auth.approve(auth.pending!.id);
    resumeKey = newTransferId();
    final next = await connect();
    expect(next.status['state'], 'pending');
    expect(auth.grant, isNull);
    await expectLater(old.catalog(), throwsA(anything));
  });
  test('提供方主动断开通知接收方且不允许旧授权重连', () async {
    var notified = false;
    final client = await TransferSecureClient.connect(server.endpoint!, b, 'B',
        resumeKey: resumeKey,
        confirm: (_) async => true,
        onDisconnected: () => notified = true);
    clients.add(client);
    auth.approve(auth.pending!.id);
    server.revoke();
    await expectLater(
        client.refreshStatus(),
        throwsA(isA<TransferException>()
            .having((e) => e.code, 'code', TransferFailure.disconnected)));
    expect(notified, true);
    expect((await connect()).status['state'], 'pending');
  });
  test('拒绝后限制同一设备频繁重新申请', () async {
    final client = await connect();
    server.reject();
    client.close();
    await expectLater(connect(), throwsA(isA<TransferException>()));
    expect(auth.pending, isNull);
  });
  test('新版双向签名绑定设备资料与恢复材料', () {
    final data = pairingChallenge(
        session: newTransferId(),
        certificate: a.certificateDigest,
        nonce: newTransferId(),
        clientNonce: newTransferId(),
        serverKey: a.publicKey,
        clientKey: b.publicKey,
        serverName: 'A',
        clientName: 'B',
        serverInfo: const TransferDeviceInfo(model: 'Mac'),
        clientInfo: const TransferDeviceInfo(),
        resumeKey: resumeKey);
    expect(TransferIdentity.verify(a.publicKey, data, a.sign(data)), true);
    expect(TransferIdentity.verify(a.publicKey, [...data, 1], a.sign(data)),
        false);
  });
  test('旧版握手得到明确升级提示，不降级或生成申请', () async {
    final endpoint = server.endpoint!;
    final socket = await SecureSocket.connect(endpoint.address, endpoint.port,
        context: SecurityContext(withTrustedRoots: false),
        onBadCertificate: (cert) =>
            sha256.convert(cert.der).toString() == endpoint.certificateDigest);
    final response = Completer<Map<String, dynamic>>();
    final buffer = BytesBuilder();
    final subscription = socket.listen((data) {
      buffer.add(data);
      final bytes = buffer.toBytes();
      if (bytes.length < 4 || response.isCompleted) return;
      final length = ByteData.sublistView(bytes).getUint32(0);
      if (bytes.length >= 4 + length)
        response.complete(jsonDecode(utf8.decode(bytes.sublist(4, 4 + length)))
            as Map<String, dynamic>);
    }, onError: (Object e) {
      if (!response.isCompleted) response.completeError(e);
    });
    try {
      final bytes = utf8.encode(jsonEncode({'v': 1}));
      socket
          .add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List());
      socket.add(bytes);
      await socket.flush();
      expect(
          (await response.future.timeout(const Duration(seconds: 5)))['code'],
          'unsupportedVersion');
      expect(auth.pending, isNull);
    } finally {
      socket.destroy();
      await subscription.cancel();
    }
  });
  test('双向连接：一方主动断开后两边的访问授权都撤销', () async {
    final reverseAuth = TransferAuthorization();
    final reverseHost =
        TransferHost(authorization: reverseAuth, reader: reader);
    reverseHost.start(TransferManifest([resource]), {resource.id});
    final reverse = TransferSecureServer(
        identity: b,
        host: reverseHost,
        name: 'B',
        changed: () {},
        allowLoopback: true);
    await reverse.start(InternetAddress.loopbackIPv4);
    final ended = Completer<void>();
    try {
      final fromB = await TransferSecureClient.connect(server.endpoint!, b, 'B',
          resumeKey: resumeKey,
          confirm: (_) async => true,
          onDisconnected: reverse.revoke);
      clients.add(fromB);
      auth.approve(auth.pending!.id);
      final fromA =
          await TransferSecureClient.connect(reverse.endpoint!, a, 'A',
              resumeKey: newTransferId(),
              confirm: (_) async => true,
              onDisconnected: () {
                server.revoke();
                if (!ended.isCompleted) ended.complete();
              });
      clients.add(fromA);
      reverseAuth.approve(reverseAuth.pending!.id);
      server.revoke();
      await ended.future.timeout(const Duration(seconds: 3));
      expect(auth.grant, isNull);
      expect(reverseAuth.grant, isNull);
      await expectLater(fromA.catalog(), throwsA(anything));
      await expectLater(fromB.catalog(), throwsA(anything));
    } finally {
      await reverse.stop();
    }
  });
}
