import 'transfer_protocol.dart';
import 'transfer_pairing.dart';

abstract interface class TransferClock {
  DateTime get now;
  Duration get elapsed;
}

class SystemTransferClock implements TransferClock {
  final Stopwatch _stopwatch = Stopwatch()..start();
  @override
  DateTime get now => DateTime.now().toUtc();
  @override
  Duration get elapsed => _stopwatch.elapsed;
}

class _Deadline {
  _Deadline(TransferClock clock, Duration duration)
      : wall = clock.now.add(duration),
        monotonic = clock.elapsed + duration;
  final DateTime wall;
  final Duration monotonic;

  // Wall time also covers OS sleep on clocks that suspend their stopwatch.
  // A clock rollback cannot extend the monotonic deadline.
  bool expired(TransferClock clock) =>
      !clock.now.isBefore(wall) || clock.elapsed >= monotonic;
}

/// An in-process transport attestation, NOT a wire DTO or a bearer token.
/// The future secure adapter must construct this only after key confirmation,
/// and check possession on every connection. Untrusted JSON cannot create it.
class TransferPeerBinding {
  TransferPeerBinding(
      {required this.identityDigest,
      required this.channelDigest,
      required this.displayName,
      this.deviceInfo = const TransferDeviceInfo()}) {
    if (!isTransferDigest(identityDigest) ||
        !isTransferDigest(channelDigest) ||
        displayName.isEmpty ||
        displayName.length > 80 ||
        displayName.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      invalidTransferMessage();
    }
  }
  final String identityDigest, channelDigest, displayName;
  final TransferDeviceInfo deviceInfo;

  String get safetyCode => List.generate(
          4, (i) => identityDigest.substring(i * 4, i * 4 + 4).toUpperCase())
      .join(' ');

  bool matches(TransferPeerBinding other) =>
      identityDigest == other.identityDigest &&
      channelDigest == other.channelDigest;
}

class TransferApprovalRequest {
  TransferApprovalRequest._(this.id, this.peer, this._deadline);
  final String id;
  final TransferPeerBinding peer;
  final _Deadline _deadline;
  DateTime get expiresAt => _deadline.wall;
}

class TransferGrant {
  TransferGrant._(
      this.id, this.sessionId, this.peer, Set<String> resources, this._deadline)
      : resourceIds = Set.unmodifiable(resources);
  final String id, sessionId;
  final TransferPeerBinding peer;
  final Set<String> resourceIds;
  final _Deadline _deadline;
  DateTime get expiresAt => _deadline.wall;
}

/// Local authorization policy only. It does not perform pairing, authenticate
/// network packets, issue credentials or persist/restore active permissions.
class TransferAuthorization {
  TransferAuthorization({TransferClock? clock})
      : _clock = clock ?? SystemTransferClock();

  final TransferClock _clock;
  String? _sessionId;
  Set<String> _scope = {};
  TransferApprovalRequest? _pending;
  TransferGrant? _grant;

  bool get isSharing => _sessionId != null;
  String? get sessionId => _sessionId;
  Set<String> get scope => Set.unmodifiable(_scope);
  TransferApprovalRequest? get pending =>
      _pending?._deadline.expired(_clock) == true ? null : _pending;
  TransferGrant? get grant =>
      _grant?._deadline.expired(_clock) == true ? null : _grant;

  String start(Set<String> resources) {
    if (isSharing)
      throw const TransferException(TransferFailure.busy, '请先关闭当前共享。');
    if (resources.isEmpty || resources.any((id) => !isTransferId(id))) {
      invalidTransferMessage();
    }
    _scope = Set.of(resources);
    _sessionId = newTransferId();
    return _sessionId!;
  }

  TransferApprovalRequest requestApproval(
      {required String sessionId, required TransferPeerBinding peer}) {
    _requireSession(sessionId);
    if (grant != null)
      throw const TransferException(TransferFailure.busy, '已有设备获得访问授权。');
    final current = pending;
    if (current != null) {
      if (current.peer.matches(peer)) return current;
      throw const TransferException(TransferFailure.busy, '正在等待另一台设备的连接审批。');
    }
    return _pending = TransferApprovalRequest._(newTransferId(), peer,
        _Deadline(_clock, TransferLimits.approvalTimeout));
  }

  TransferGrant approve(String requestId,
      {Duration duration = TransferLimits.defaultAuthorization}) {
    if (!isSharing)
      throw const TransferException(TransferFailure.notSharing, '共享未开启。');
    if (duration < TransferLimits.minimumAuthorization ||
        duration > TransferLimits.maximumAuthorization)
      invalidTransferMessage();
    final request = _pending;
    if (request == null || request.id != requestId) {
      throw const TransferException(TransferFailure.unauthorized, '连接申请已经失效。');
    }
    if (request._deadline.expired(_clock)) {
      _pending = null;
      throw const TransferException(
          TransferFailure.approvalExpired, '连接申请已超时，请重新申请。');
    }
    _pending = null;
    return _grant = TransferGrant._(newTransferId(), _sessionId!, request.peer,
        _scope, _Deadline(_clock, duration));
  }

  void reject(String requestId) {
    if (_pending?.id == requestId) _pending = null;
  }

  TransferGrant requireAccess(
      {required String sessionId,
      required String grantId,
      required TransferPeerBinding peer,
      String? resourceId}) {
    _requireSession(sessionId);
    final value = _grant;
    if (value == null || value.id != grantId || !value.peer.matches(peer)) {
      throw const TransferException(TransferFailure.unauthorized, '设备未获访问授权。');
    }
    if (value._deadline.expired(_clock)) {
      throw const TransferException(
          TransferFailure.authorizationExpired, '访问授权已到期，请重新申请。');
    }
    if (resourceId != null &&
        (!_scope.contains(resourceId) ||
            !value.resourceIds.contains(resourceId))) {
      throw const TransferException(
          TransferFailure.outsideScope, '资源不在已批准的共享范围内。');
    }
    return value;
  }

  /// Shrinking is immediate. Expansion requires a new session and approval.
  void restrictTo(Set<String> resources) {
    if (!isSharing)
      throw const TransferException(TransferFailure.notSharing, '共享未开启。');
    if (!resources.every(_scope.contains)) {
      throw const TransferException(
          TransferFailure.outsideScope, '扩大共享范围需要重新开启并批准。');
    }
    _scope = Set.of(resources);
    if (_scope.isEmpty) stop();
  }

  void revoke() {
    _grant = null;
    _pending = null;
  }

  void stop() {
    revoke();
    _sessionId = null;
    _scope = {};
  }

  void _requireSession(String id) {
    if (_sessionId == null || _sessionId != id) {
      throw const TransferException(TransferFailure.notSharing, '共享已关闭或已重新开启。');
    }
  }
}

/// Apply globally, not just by source IP. Never log the entered code.
class TransferPairingThrottle {
  TransferPairingThrottle({TransferClock? clock})
      : _clock = clock ?? SystemTransferClock();
  final TransferClock _clock;
  int _failures = 0;
  _Deadline? _cooldown;

  bool get canAttempt {
    if (_cooldown == null) return true;
    if (!_cooldown!.expired(_clock)) return false;
    _cooldown = null;
    _failures = 0;
    return true;
  }

  void recordFailure() {
    if (!canAttempt) return;
    if (++_failures >= 5)
      _cooldown = _Deadline(_clock, const Duration(seconds: 60));
  }

  void recordSuccess() {
    if (canAttempt) _failures = 0;
  }
}
