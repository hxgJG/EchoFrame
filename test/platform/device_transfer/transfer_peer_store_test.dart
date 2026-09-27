import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/device_transfer/transfer_pairing.dart';
import 'package:lumio/platform/device_transfer/transfer_peer_store.dart';

void main() {
  late Directory root;
  const first =
      '0123456789abcdef000000000000000000000000000000000000000000000000';
  const conflicting =
      '0123456789abcdef111111111111111111111111111111111111111111111111';
  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('lumio-pairing-test-');
    root = Directory(await temp.resolveSymbolicLinks());
  });
  tearDown(() => root.delete(recursive: true));

  test('安全码允许分组输入，不接受旧连接码或不完整输入', () {
    expect(normalizeSafetyCode('0123 4567 89ab cdef'), '0123456789ABCDEF');
    expect(() => normalizeSafetyCode('123456'), throwsFormatException);
    expect(() => normalizeSafetyCode('LUMIO1-code'), throwsFormatException);
  });
  test('设备资料可以完全缺省，只使用白名单且限制长度', () {
    expect(TransferDeviceInfo.fromJson(null).label, '');
    final info = TransferDeviceInfo.fromJson(
        {'type': '手机', 'model': '14', 'serial': 'ignored'});
    expect(info.label, '手机 · 14');
    expect(info.toJson().containsKey('serial'), false);
    expect(() => TransferDeviceInfo.fromJson({'model': 'x' * 81}),
        throwsA(anything));
    expect(() => TransferDeviceInfo.fromJson({'model': 'a\nb'}),
        throwsA(anything));
  });
  test('重启只恢复完整对端身份，不保存访问授权或恢复材料', () async {
    final store = TransferPeerStore(root);
    await store.load();
    await store.remember(
        const TransferRemoteDevice(first, '电脑', TransferDeviceInfo()),
        receiving: true);
    final next = TransferPeerStore(root);
    await next.load();
    expect(next.contains(first), true);
    expect(next.lastIdentity, first);
    final raw = await File('${root.path}/known_peers.v2.json').readAsString();
    expect(raw.contains('resume'), false);
    expect(raw.contains('grant'), false);
    expect(raw.contains('deviceInfo'), false);
  });
  test('相同显示码对应其他完整身份必须阻止连接', () async {
    final store = TransferPeerStore(root);
    await store.remember(
        const TransferRemoteDevice(first, '电脑', TransferDeviceInfo()));
    expect(() => store.checkIdentity(conflicting), throwsFormatException);
    await expectLater(
        store.remember(const TransferRemoteDevice(
            conflicting, '冒名', TransferDeviceInfo())),
        throwsFormatException);
  });
  test('记录损坏或符号链接不静默当作全新信任记录', () async {
    final file = File('${root.path}/known_peers.v2.json');
    await file.writeAsString('broken');
    await expectLater(TransferPeerStore(root).load(), throwsFormatException);
    await file.delete();
    final other = File('${root.path}/other.json');
    await other.writeAsString('{"version":2,"peers":{}}');
    await Link(file.path).create(other.path);
    await expectLater(TransferPeerStore(root).load(), throwsFormatException);
    expect(await other.readAsString(), '{"version":2,"peers":{}}');
  });
}
