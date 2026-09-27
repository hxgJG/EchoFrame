import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/device_transfer/transfer_authorization.dart';
import 'package:lumio/core/device_transfer/transfer_host.dart';
import 'package:lumio/core/device_transfer/transfer_protocol.dart';

import '../../support/transfer_fixtures.dart';

class _Reader implements TransferResourceReader {
  bool available = true;
  int reads = 0;
  Completer<void>? barrier;
  @override
  Future<bool> isAvailable(TransferResource expected) async => available;
  @override
  Future<Uint8List> readBlock(
      TransferResource expected, int offset, int length) async {
    reads++;
    await barrier?.future;
    return Uint8List.fromList([1, 2, 3].sublist(offset, offset + length));
  }
}

void main() {
  late FakeTransferClock clock;
  late TransferAuthorization auth;
  late TransferHost host;
  late _Reader reader;
  late TransferResource resource;
  late TransferAccess access;
  setUp(() async {
    clock = FakeTransferClock();
    auth = TransferAuthorization(clock: clock);
    reader = _Reader();
    host = TransferHost(authorization: auth, reader: reader);
    resource = transferResource();
    host.start(TransferManifest([resource]), {resource.id});
    final request =
        auth.requestApproval(sessionId: auth.sessionId!, peer: transferPeer());
    final grant = auth.approve(request.id);
    access = TransferAccess(
        sessionId: grant.sessionId, grantId: grant.id, peer: grant.peer);
    await host.catalog(access);
  });
  Future<Uint8List> read() => host.readBlock(access,
      resourceId: resource.id,
      revision: resource.revision,
      offset: 0,
      length: 3);

  test('最多同时读取两个文件，第三个请求被拒绝', () async {
    host.stop();
    final resources = List.generate(3, (_) => transferResource());
    host.start(TransferManifest(resources), resources.map((r) => r.id).toSet());
    final request =
        auth.requestApproval(sessionId: auth.sessionId!, peer: transferPeer());
    final grant = auth.approve(request.id);
    final approved = TransferAccess(
        sessionId: grant.sessionId, grantId: grant.id, peer: grant.peer);
    await host.catalog(approved);
    reader.barrier = Completer<void>();
    Future<Uint8List> block(int index) => host.readBlock(approved,
        resourceId: resources[index].id,
        revision: resources[index].revision,
        offset: 0,
        length: 3);
    final first = block(0), second = block(1);
    await expectLater(
        block(2),
        throwsA(isA<TransferException>()
            .having((e) => e.code, 'code', TransferFailure.busy)));
    reader.barrier!.complete();
    await Future.wait([first, second]);
    expect(await block(2), [1, 2, 3]);
  });

  test('合法目录和有界读取，范围错误不触发读取', () async {
    expect(await read(), [1, 2, 3]);
    await expectLater(
        host.readBlock(access,
            resourceId: resource.id,
            revision: resource.revision,
            offset: 2,
            length: 2),
        throwsA(isA<TransferException>()));
    await expectLater(
        host.readBlock(access,
            resourceId: resource.id,
            revision: resource.revision,
            offset: -1,
            length: 1),
        throwsA(isA<TransferException>()));
    await expectLater(
        host.readBlock(access,
            resourceId: newTransferId(),
            revision: resource.revision,
            offset: 0,
            length: 1),
        throwsA(isA<TransferException>()));
    expect(reader.reads, 1);
  });

  for (final action in ['revoke', 'expire', 'hide', 'stop']) {
    test('读取中 $action，完成的分块也不再交给传输层', () async {
      reader.barrier = Completer<void>();
      final future = read();
      final check = expectLater(future, throwsA(isA<TransferException>()));
      await Future<void>.delayed(Duration.zero);
      switch (action) {
        case 'revoke':
          auth.revoke();
        case 'expire':
          clock.advance(const Duration(hours: 1));
        case 'hide':
          reader.available = false;
        case 'stop':
          host.stop();
      }
      reader.barrier!.complete();
      await check;
    });
  }

  test('同资源并发重入被拒绝，完成后释放占用', () async {
    reader.barrier = Completer<void>();
    final first = read();
    await Future<void>.delayed(Duration.zero);
    await expectLater(read(), throwsA(isA<TransferException>()));
    reader.barrier!.complete();
    await first;
    expect(await read(), [1, 2, 3]);
  });

  test('未选择的附件不会随父资源自动放行，目录版本可用于下载', () async {
    host.stop();
    final lyric = transferResource(kind: TransferResourceKind.lyrics);
    final audio = transferResource(attachments: [lyric.id]);
    host.start(TransferManifest([audio, lyric]), {audio.id});
    final request =
        auth.requestApproval(sessionId: auth.sessionId!, peer: transferPeer());
    final grant = auth.approve(request.id);
    final selected = TransferAccess(
        sessionId: grant.sessionId, grantId: grant.id, peer: grant.peer);
    final catalog = await host.catalog(selected);
    expect(catalog.resources.single.attachmentIds, isEmpty);
    expect(
        await host.readBlock(selected,
            resourceId: audio.id,
            revision: catalog.resources.single.revision,
            offset: 0,
            length: 3),
        [1, 2, 3]);
    await expectLater(
        host.readBlock(selected,
            resourceId: lyric.id,
            revision: lyric.revision,
            offset: 0,
            length: 3),
        throwsA(isA<TransferException>()));
  });

  test('旧版本拒绝读取，撤销后连目录也不可见', () async {
    await expectLater(
        host.readBlock(access,
            resourceId: resource.id,
            revision: transferPeerDigest,
            offset: 0,
            length: 3),
        throwsA(isA<TransferException>()));
    auth.revoke();
    await expectLater(host.catalog(access), throwsA(isA<TransferException>()));
    expect(reader.reads, 0);
  });
}
