import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/device_transfer/transfer_authorization.dart';
import 'package:lumio/core/device_transfer/transfer_host.dart';
import 'package:lumio/core/device_transfer/transfer_protocol.dart';
import 'package:lumio/platform/device_transfer/platform_transfer_storage.dart';
import 'package:lumio/platform/device_transfer/received_transfer_store.dart';
import 'package:lumio/platform/device_transfer/transfer_receiver.dart';

import '../../support/transfer_fixtures.dart';

class _SyntheticReader implements TransferResourceReader {
  _SyntheticReader(this.bytes);
  final Uint8List bytes;
  @override
  Future<bool> isAvailable(TransferResource expected) async => true;
  @override
  Future<Uint8List> readBlock(
          TransferResource expected, int offset, int length) async =>
      Uint8List.sublistView(bytes, offset, offset + length);
}

class _InProcessSource implements TransferDownloadSource {
  _InProcessSource(this.host, this.access);
  final TransferHost host;
  final TransferAccess access;
  final List<int> offsets = [];
  @override
  Future<Uint8List> readBlock(
      TransferResource resource, int offset, int length) {
    offsets.add(offset);
    return host.readBlock(access,
        resourceId: resource.id,
        revision: resource.revision,
        offset: offset,
        length: length);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReceivedTransferStore store;
  late TransferReceiver receiver;
  late TransferHost host;
  late TransferResource resource;
  late _InProcessSource source;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lumio-transfer-flow-');
    store = ReceivedTransferStore(root);
    await store.initialize();
    receiver = TransferReceiver(store);
    final bytes = Uint8List(TransferLimits.blockBytes * 2 + 7);
    bytes[bytes.length - 1] = 42;
    resource = transferResource(bytes: bytes);
    final auth = TransferAuthorization();
    host = TransferHost(authorization: auth, reader: _SyntheticReader(bytes));
    host.start(TransferManifest([resource]), {resource.id});
    final request =
        auth.requestApproval(sessionId: auth.sessionId!, peer: transferPeer());
    final grant = auth.approve(request.id);
    final access = TransferAccess(
        sessionId: grant.sessionId, grantId: grant.id, peer: grant.peer);
    await host.catalog(access);
    source = _InProcessSource(host, access);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('合成数据完成审批、目录、分块、摘要验证及持久保存', () async {
    final result = await receiver.receive(
        source: source,
        peerDigest: transferPeerDigest,
        resource: resource,
        control: TransferReceiveControl());
    expect(result.stage, ReceivedTransferStage.ready);
    expect(result.indexed, false);
    expect(source.offsets,
        [0, TransferLimits.blockBytes, TransferLimits.blockBytes * 2]);
    expect(await (await store.verifiedFile(result.jobId)).length(),
        resource.byteLength);
  });

  test('前台流程暂停后保留检查点，再次接收只请求剩余分块', () async {
    final control = TransferReceiveControl();
    await expectLater(
        receiver.receive(
            source: source,
            peerDigest: transferPeerDigest,
            resource: resource,
            control: control,
            onProgress: (received, _) {
              if (received > 0) control.pause();
            }),
        throwsA(isA<TransferReceivePaused>()));
    expect(store.receipts.single.offset, TransferLimits.blockBytes);
    source.offsets.clear();
    final ready = await receiver.receive(
        source: source,
        peerDigest: transferPeerDigest,
        resource: resource,
        control: TransferReceiveControl());
    expect(ready.stage, ReceivedTransferStage.ready);
    expect(source.offsets,
        [TransferLimits.blockBytes, TransferLimits.blockBytes * 2]);
  });

  test('中途撤销不伪装成功，再次批准后续传不重复创建文件', () async {
    await expectLater(
        receiver.receive(
            source: source,
            peerDigest: transferPeerDigest,
            resource: resource,
            control: TransferReceiveControl(),
            onProgress: (received, _) {
              if (received > 0) host.authorization.revoke();
            }),
        throwsA(isA<TransferException>()));
    expect(store.receipts.single.stage, ReceivedTransferStage.downloading);
    final auth = host.authorization;
    final request =
        auth.requestApproval(sessionId: auth.sessionId!, peer: transferPeer());
    final grant = auth.approve(request.id);
    source = _InProcessSource(
        host,
        TransferAccess(
            sessionId: grant.sessionId, grantId: grant.id, peer: grant.peer));
    final ready = await receiver.receive(
        source: source,
        peerDigest: transferPeerDigest,
        resource: resource,
        control: TransferReceiveControl());
    expect(ready.stage, ReceivedTransferStage.ready);
    expect(store.receipts.length, 1);
    expect(source.offsets.first, TransferLimits.blockBytes);
  });

  test('原生目录通过私有通道获取，不接受网络指定路径', () async {
    const channel = MethodChannel('lumio/app_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'transferStorage');
      return {'path': root.path, 'availableBytes': 1024 * 1024 * 1024};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final native = await const PlatformTransferStorage().open();
    final receipt = await native.prepare(
        peerDigest: transferPeerDigest, resource: resource);
    expect(receipt.offset, 0);
    expect(native.root.path, root.path);
  });
}
