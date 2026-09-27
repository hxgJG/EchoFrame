import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/device_transfer/transfer_protocol.dart';
import 'package:lumio/platform/device_transfer/received_transfer_store.dart';

import '../../support/transfer_fixtures.dart';

void main() {
  late Directory root;
  late ReceivedTransferStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lumio-transfer-test-');
    store = ReceivedTransferStore(root);
    await store.initialize();
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<ReceivedTransferReceipt> prepare([TransferResource? resource]) =>
      store.prepare(
          peerDigest: transferPeerDigest,
          resource: resource ?? transferResource());
  Future<ReceivedTransferReceipt> complete([TransferResource? resource]) async {
    final job = await prepare(resource);
    await store.append(job.jobId, offset: 0, bytes: [1, 2, 3]);
    return store.finish(job.jobId);
  }

  File journal(ReceivedTransferReceipt job) =>
      File('${root.path}/jobs/${job.jobId}.json');
  File partial(ReceivedTransferReceipt job) =>
      File('${root.path}/partial/${job.jobId}.part');

  test('分块校验和接收记录独立于媒体入库，正常完成可重启恢复', () async {
    final ready = await complete();
    expect(ready.stage, ReceivedTransferStage.ready);
    expect(ready.indexed, false);
    final fresh = ReceivedTransferStore(root);
    await fresh.initialize();
    final file = await fresh.verifiedFile(ready.jobId);
    expect(await file.readAsBytes(), [1, 2, 3]);
    await fresh.markIndexed(ready.jobId);
    expect(fresh.receipts.single.indexed, true);
  });

  test('写入偏移必须连续，拒绝超长块和整文件越界', () async {
    final job = await prepare();
    await expectLater(store.append(job.jobId, offset: 1, bytes: [1]),
        throwsA(isA<TransferException>()));
    await expectLater(store.append(job.jobId, offset: 0, bytes: [1, 2, 3, 4]),
        throwsA(isA<TransferException>()));
    expect(
        () => store.append(job.jobId,
            offset: 0, bytes: List.filled(TransferLimits.blockBytes + 1, 0)),
        throwsA(isA<TransferException>()));
    await expectLater(
        store.finish(job.jobId), throwsA(isA<TransferException>()));
  });

  test('完整校验失败不发布也不标记成功', () async {
    final job = await prepare();
    await store.append(job.jobId, offset: 0, bytes: [1, 9, 3]);
    await expectLater(
        store.finish(job.jobId),
        throwsA(isA<TransferException>()
            .having((e) => e.code, 'code', TransferFailure.integrityMismatch)));
    expect(await Directory('${root.path}/received').list().length, 0);
    expect(store.receipts.single.stage, ReceivedTransferStage.downloading);
  });

  test('断点恢复保留覆盖策略和原本地版本，不静默重新选择', () async {
    final resource = transferResource();
    final job = await store.prepare(
        peerDigest: transferPeerDigest,
        resource: resource,
        policy: const TransferImportPolicy(overwriteLyrics: false),
        baseVersion: 'local-v1');
    await store.append(job.jobId, offset: 0, bytes: [1]);
    final fresh = ReceivedTransferStore(root);
    await fresh.initialize();
    final resumed = await fresh.prepare(
        peerDigest: transferPeerDigest,
        resource: resource,
        policy: const TransferImportPolicy(),
        baseVersion: 'local-v2');
    expect(resumed.offset, 1);
    expect(resumed.policy.overwriteLyrics, false);
    expect(resumed.baseVersion, 'local-v1');
    await fresh.append(job.jobId, offset: 1, bytes: [2, 3]);
    expect((await fresh.finish(job.jobId)).stage, ReceivedTransferStage.ready);
  });

  test('数据已写入但日志尚未确认时，只保留确认过的字节', () async {
    final job = await prepare();
    await store.append(job.jobId, offset: 0, bytes: [1]);
    await partial(job).writeAsBytes([9, 9], mode: FileMode.append, flush: true);
    final fresh = ReceivedTransferStore(root);
    await fresh.initialize();
    expect((await fresh.recover(job.jobId)).offset, 1);
    expect(await partial(job).readAsBytes(), [1]);
  });

  test('日志临时文件写失败不会显示成功，下次重试从检查点继续', () async {
    final job = await prepare();
    final temp = Directory('${journal(job).path}.tmp');
    await temp.create();
    await expectLater(store.append(job.jobId, offset: 0, bytes: [1]),
        throwsA(isA<TransferException>()));
    expect(store.receipts.single.offset, 0);
    await temp.delete();
    await store.append(job.jobId, offset: 0, bytes: [1, 2, 3]);
    expect((await store.finish(job.jobId)).stage, ReceivedTransferStage.ready);
  });

  for (final alreadyRenamed in [false, true]) {
    test('verified 日志在文件改名${alreadyRenamed ? '后' : '前'}退出可恢复', () async {
      final job = await prepare();
      await store.append(job.jobId, offset: 0, bytes: [1, 2, 3]);
      final json =
          jsonDecode(await journal(job).readAsString()) as Map<String, dynamic>;
      json['stage'] = 'verified';
      await journal(job).writeAsString(jsonEncode(json));
      if (alreadyRenamed) {
        await partial(job).rename('${root.path}/received/${job.localId}.mp3');
      }
      final fresh = ReceivedTransferStore(root);
      await fresh.initialize();
      expect(
          (await fresh.recover(job.jobId)).stage, ReceivedTransferStage.ready);
      expect(
          await (await fresh.verifiedFile(job.jobId)).readAsBytes(), [1, 2, 3]);
    });
  }

  test('内容相同复用正式文件，同名不同内容各自保留', () async {
    final first = await complete();
    final duplicate = await prepare(transferResource(title: '改名后的歌'));
    expect(duplicate.localId, first.localId);
    expect(duplicate.resource.metadata.title, '改名后的歌');
    final other = await prepare(
        transferResource(bytes: [4, 5], title: first.resource.metadata.title));
    await store.append(other.jobId, offset: 0, bytes: [4, 5]);
    final otherReady = await store.finish(other.jobId);
    expect(otherReady.localId, isNot(first.localId));
    expect(await Directory('${root.path}/received').list().length, 2);
  });

  test('显示标题即使含路径也不参与目标文件名', () async {
    final job = await complete(transferResource(title: '../../secret.txt'));
    final file = await store.verifiedFile(job.jobId);
    expect(file.uri.pathSegments.last, '${job.localId}.mp3');
    expect(await File('${root.path}/secret.txt').exists(), false);
  });

  test('未知日志版本不覆盖，不恢复或删除任何原数据', () async {
    final job = await prepare();
    final text = await journal(job).readAsString();
    await journal(job)
        .writeAsString(text.replaceFirst('"version":1', '"version":999'));
    final before = await journal(job).readAsString();
    await expectLater(ReceivedTransferStore(root).initialize(),
        throwsA(isA<TransferException>()));
    expect(await journal(job).readAsString(), before);
  });

  test('拒绝被替换的部分文件符号链接，不写入链接目标', () async {
    final job = await prepare();
    final unrelated = File('${root.path}/untouched.txt');
    await unrelated.writeAsString('preserve');
    await Link(partial(job).path).create(unrelated.path);
    await expectLater(store.append(job.jobId, offset: 0, bytes: [1]),
        throwsA(isA<TransferException>()));
    expect(await unrelated.readAsString(), 'preserve');
  });

  test('拒绝被替换的目录符号链接', () async {
    await Directory('${root.path}/partial').delete();
    final other = await Directory('${root.path}/other').create();
    await Link('${root.path}/partial').create(other.path);
    await expectLater(prepare(), throwsA(isA<TransferException>()));
  });

  test('空间不足中途暂停，不改变已确认进度', () async {
    var space = 20 * 1024 * 1024;
    final constrained =
        ReceivedTransferStore(root, availableBytes: () async => space);
    await constrained.initialize();
    final job = await constrained.prepare(
        peerDigest: transferPeerDigest, resource: transferResource());
    await constrained.append(job.jobId, offset: 0, bytes: [1]);
    space = 1;
    await expectLater(
        constrained.append(job.jobId, offset: 1, bytes: [2, 3]),
        throwsA(isA<TransferException>()
            .having((e) => e.code, 'code', TransferFailure.insufficientSpace)));
    expect(constrained.receipts.single.offset, 1);
  });

  test('零字节资源也必须经过摘要校验', () async {
    final job = await prepare(transferResource(bytes: []));
    expect((await store.finish(job.jobId)).stage, ReceivedTransferStage.ready);
  });

  test('清理过期任务和取消仅删除未完成文件，不删除正式文件', () async {
    var now = DateTime.utc(2026, 9, 26);
    store = ReceivedTransferStore(root, now: () => now);
    await store.initialize();
    final ready = await complete();
    final pending = await prepare(transferResource(bytes: [4]));
    await store.append(pending.jobId, offset: 0, bytes: [4]);
    now = now.add(const Duration(hours: 25));
    expect(await store.discardExpiredPartials(), 1);
    expect(await (await store.verifiedFile(ready.jobId)).exists(), true);
    await expectLater(
        store.cancelPartial(ready.jobId), throwsA(isA<TransferException>()));
    await expectLater(store.forgetIndexedReceipt(ready.jobId),
        throwsA(isA<TransferException>()));
    await store.markIndexed(ready.jobId);
    final file = await store.verifiedFile(ready.jobId);
    await store.forgetIndexedReceipt(ready.jobId);
    expect(await file.exists(), true);
  });

  test('超过 512 MiB 的完整文件仍计算摘要并校验末尾', () async {
    const length = 513 * 1024 * 1024;
    final sparse = File('${root.path}/synthetic-video');
    final handle = await sparse.open(mode: FileMode.write);
    await handle.truncate(length);
    await handle.close();
    final digest = (await sha256.bind(sparse.openRead()).first).toString();
    final resource = TransferResource(
        id: newTransferId(),
        kind: TransferResourceKind.video,
        byteLength: length,
        sha256Digest: digest,
        extension: 'mp4',
        metadata: TransferDisplayMetadata(title: '合成校验文件'));
    final job = await prepare(resource);
    await sparse.rename(partial(job).path);
    final json =
        jsonDecode(await journal(job).readAsString()) as Map<String, dynamic>;
    json['offset'] = length;
    await journal(job).writeAsString(jsonEncode(json));
    final lastByte = await partial(job).open(mode: FileMode.append);
    await lastByte.setPosition(length - 1);
    await lastByte.writeByte(1);
    await lastByte.close();
    final fresh = ReceivedTransferStore(root);
    await fresh.initialize();
    await expectLater(
        fresh.finish(job.jobId),
        throwsA(isA<TransferException>()
            .having((e) => e.code, 'code', TransferFailure.integrityMismatch)));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
