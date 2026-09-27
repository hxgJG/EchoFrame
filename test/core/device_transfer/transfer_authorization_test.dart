import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/device_transfer/transfer_authorization.dart';
import 'package:lumio/core/device_transfer/transfer_protocol.dart';

import '../../support/transfer_fixtures.dart';

void main() {
  late FakeTransferClock clock;
  late TransferAuthorization auth;
  late String resourceId, sessionId;
  setUp(() {
    clock = FakeTransferClock();
    auth = TransferAuthorization(clock: clock);
    resourceId = newTransferId();
    sessionId = auth.start({resourceId});
  });
  TransferGrant approve([Duration duration = const Duration(hours: 1)]) {
    final request =
        auth.requestApproval(sessionId: sessionId, peer: transferPeer());
    return auth.approve(request.id, duration: duration);
  }

  void read(TransferGrant grant,
      {String? resource, TransferPeerBinding? peer}) {
    auth.requireAccess(
        sessionId: sessionId,
        grantId: grant.id,
        peer: peer ?? transferPeer(),
        resourceId: resource ?? resourceId);
  }

  test('默认关闭，未批准不能获取目录', () {
    expect(TransferAuthorization().isSharing, false);
    expect(
        () => auth.requireAccess(
            sessionId: sessionId,
            grantId: newTransferId(),
            peer: transferPeer()),
        throwsA(isA<TransferException>()));
    auth.requestApproval(sessionId: sessionId, peer: transferPeer());
    expect(auth.grant, isNull);
  });

  test('审批只限一个设备，同一申请重试幂等', () {
    final first =
        auth.requestApproval(sessionId: sessionId, peer: transferPeer());
    expect(auth.requestApproval(sessionId: sessionId, peer: transferPeer()).id,
        first.id);
    expect(
        () => auth.requestApproval(
            sessionId: sessionId,
            peer: transferPeer(identity: transferChannelDigest)),
        throwsA(isA<TransferException>()));
    approve();
    expect(
        () => auth.requestApproval(sessionId: sessionId, peer: transferPeer()),
        throwsA(isA<TransferException>()));
  });

  test('默认一小时，连续读取不会延长有效期', () {
    final grant = approve();
    read(grant);
    clock.advance(const Duration(minutes: 59));
    read(grant);
    clock.advance(const Duration(minutes: 1));
    expect(
        () => read(grant),
        throwsA(isA<TransferException>().having(
            (e) => e.code, 'code', TransferFailure.authorizationExpired)));
    expect(auth.grant, isNull);
  });

  test('拒绝小于五分钟或超过二十四小时的授权', () {
    for (final duration in [
      const Duration(minutes: 4),
      const Duration(hours: 25)
    ]) {
      expect(() => approve(duration), throwsA(isA<TransferException>()));
    }
    final grant = approve(const Duration(minutes: 5));
    clock.advance(const Duration(minutes: 5));
    expect(() => read(grant), throwsA(isA<TransferException>()));
  });

  test('审批两分钟超时，拒绝过期申请', () {
    final request =
        auth.requestApproval(sessionId: sessionId, peer: transferPeer());
    clock.advance(const Duration(minutes: 2));
    expect(auth.pending, isNull);
    expect(() => auth.approve(request.id), throwsA(isA<TransferException>()));
  });

  test('墙上时钟回退不延期，睡眠恢复也检查墙上时间', () {
    final grant = approve();
    clock.now = clock.now.subtract(const Duration(days: 1));
    clock.elapsed += const Duration(hours: 1);
    expect(() => read(grant), throwsA(isA<TransferException>()));
    final renewed = approve();
    clock.now = clock.now.add(const Duration(hours: 1));
    expect(() => read(renewed), throwsA(isA<TransferException>()));
  });

  test('设备和连接绑定不可转交，越界资源被拒绝', () {
    final grant = approve();
    expect(
        () => read(grant, peer: transferPeer(identity: transferChannelDigest)),
        throwsA(isA<TransferException>()));
    expect(() => read(grant, peer: transferPeer(channel: transferPeerDigest)),
        throwsA(isA<TransferException>()));
    expect(() => read(grant, resource: newTransferId()),
        throwsA(isA<TransferException>()));
  });

  test('范围只能缩小，移除不可恢复，关闭及重启不会恢复授权', () {
    final grant = approve();
    expect(() => auth.restrictTo({resourceId, newTransferId()}),
        throwsA(isA<TransferException>()));
    auth.restrictTo({});
    expect(() => read(grant), throwsA(isA<TransferException>()));
    sessionId = auth.start({resourceId});
    expect(() => read(grant), throwsA(isA<TransferException>()));
    final next = approve();
    auth.revoke();
    expect(() => read(next), throwsA(isA<TransferException>()));
  });

  test('连续猜错五次全局冷却，成功回调不能解除冷却', () {
    final throttle = TransferPairingThrottle(clock: clock);
    for (var i = 0; i < 5; i++) {
      expect(throttle.canAttempt, true);
      throttle.recordFailure();
    }
    expect(throttle.canAttempt, false);
    throttle.recordSuccess();
    expect(throttle.canAttempt, false);
    clock.advance(const Duration(seconds: 60));
    expect(throttle.canAttempt, true);
  });
}
