import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:nsd/nsd.dart' as nsd;

import '../../app/app_state.dart';
import '../../core/device_transfer/transfer_authorization.dart';
import '../../core/device_transfer/transfer_host.dart';
import '../../core/device_transfer/transfer_invitation.dart';
import '../../core/device_transfer/transfer_protocol.dart';
import '../../core/device_transfer/transfer_pairing.dart';
import 'platform_transfer_storage.dart';
import 'received_transfer_store.dart';
import 'shared_resource_reader.dart';
import 'transfer_identity.dart';
import 'transfer_receiver.dart';
import 'transfer_secure_transport.dart';
import 'transfer_peer_store.dart';

class DeviceTransferController extends ChangeNotifier
    with WidgetsBindingObserver {
  DeviceTransferController(this.app) {
    WidgetsBinding.instance.addObserver(this);
  }
  final LumioAppState app;
  static const serviceType = '_lumio-xfer._tcp';
  TransferIdentity? identity;
  ReceivedTransferStore? store;
  SharedResourceReader? reader;
  TransferSecureServer? server;
  TransferSecureClient? client;
  nsd.Discovery? _discovery;
  final Map<String, nsd.Service> _resolved = {};
  final Set<String> _resolutionAttempts = {};
  bool _resolving = false;
  int _discoveryEpoch = 0;
  nsd.Registration? _registration;
  bool _advertising = false, _foreground = true;
  bool _checkingNetwork = false;
  String? _networkSignature;
  String? _sharingInterface;
  Timer? _networkTimer;
  List<TransferResource> sharedResources = [];
  final Map<String, int> sentResources = {};
  final List<({String label, InternetAddress address})> addresses = [];
  List<nsd.Service> get nearby => (_discovery?.services ?? [])
      .take(40)
      .map((s) => _resolved[_serviceKey(s)] ?? s)
      .where((s) => serviceIdentity(s) != identity?.digest)
      .toList();
  TransferDeviceInfo deviceInfo = const TransferDeviceInfo();
  TransferPeerStore? peers;
  final Map<String, String> _resumeKeys = {};
  int _connectionEpoch = 0;
  bool get canReconnect => peers?.lastIdentity != null;
  String name = Platform.isMacOS ? 'Lumio · Mac' : 'Lumio · Android';
  String message = '仅局域网 · 无账号 · 无云端';
  String? error, discoveryWarning;
  bool initializing = false,
      preparing = false,
      receiving = false,
      connecting = false;
  bool _disposed = false, _cancelPrepare = false, _polling = false;
  int prepared = 0,
      prepareTotal = 0,
      receivedBytes = 0,
      totalBytes = 0,
      sentBytes = 0;
  int completed = 0, batchTotal = 0;
  double bytesPerSecond = 0;
  String currentTitle = '';
  List<TransferResource> remote = [];
  final Map<String, String> outcomes = {};
  TransferReceiveControl? _control;
  Timer? _poll;
  Future<void>? _initialization;
  bool get sharing => server?.host.authorization.isSharing == true;
  bool get approved =>
      client?.status['state'] == 'approved' && client?.closed == false;
  List<ReceivedTransferReceipt> get history => (store?.receipts.toList() ?? [])
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  List<TransferShareChoice> get choices => reader?.choices ?? [];
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() =>
      _initialization ??= _initialize().catchError((Object e) {
        _initialization = null;
        throw e;
      });

  Future<void> _initialize() async {
    initializing = true;
    error = null;
    _changed();
    try {
      await NativeTransferLease.channel
          .invokeMethod<void>('acquireTransferLock');
      store = await const PlatformTransferStorage().open();
      identity = await TransferIdentity.load();
      deviceInfo = await TransferIdentity.deviceInfo();
      peers = TransferPeerStore(store!.root);
      await peers!.load();
      reader = SharedResourceReader(
          identityDigest: identity!.digest,
          mediaItems: () => app.transferMedia,
          lyrics: () => app.lyricLibraryEntries,
          isVisible: app.transferVisible);
      await store!.discardExpiredPartials();
      await _pruneHistory();
      await refreshAddresses();
      _networkSignature = await _readNetworkSignature();
      _networkTimer ??=
          Timer.periodic(const Duration(seconds: 3), (_) => _checkNetwork());
      _poll ??= Timer.periodic(
          const Duration(seconds: 2), (_) => _refreshConnection());
    } catch (e) {
      identity = null;
      peers = null;
      error = describe(e);
      rethrow;
    } finally {
      initializing = false;
      _changed();
    }
  }

  Future<void> refreshAddresses() async {
    final interfaces = await NetworkInterface.list(includeLinkLocal: true);
    addresses.clear();
    for (final interface in interfaces) {
      // Tunnel interfaces should not accidentally advertise a VPN instead of Wi-Fi.
      if (RegExp(r'^(utun|tun|tap|ppp|ipsec)').hasMatch(interface.name))
        continue;
      for (final address in interface.addresses.where(isLocalTransferAddress)) {
        addresses.add((
          label: '${interface.name} · ${address.address}',
          address: address
        ));
      }
    }
    addresses.sort((a, b) => a.address.type == b.address.type
        ? 0
        : a.address.type == InternetAddressType.IPv4
            ? -1
            : 1);
    _changed();
  }

  Future<String> _readNetworkSignature() async {
    final interfaces = await NetworkInterface.list(includeLinkLocal: true);
    final values = [
      for (final interface in interfaces)
        if (!RegExp(r'^(utun|tun|tap|ppp|ipsec)').hasMatch(interface.name))
          for (final address
              in interface.addresses.where(isLocalTransferAddress))
            '${interface.name}:${address.address}'
    ]..sort();
    return values.join('|');
  }

  Future<void> _checkNetwork() async {
    if (_checkingNetwork ||
        _disposed ||
        !_foreground ||
        (!sharing && client == null)) return;
    _checkingNetwork = true;
    try {
      final current = await _readNetworkSignature();
      if (_networkSignature != null && current != _networkSignature) {
        pause();
        _connectionEpoch++;
        client?.close();
        remote = [];
        final sharingServer = server;
        await sharingServer?.pauseNetwork();
        await _unregister();
        await stopDiscovery();
        await refreshAddresses();
        final candidates = addresses
            .where((a) => a.label.split(' · ').first == _sharingInterface)
            .toList();
        if (sharingServer != null &&
            server == sharingServer &&
            !_disposed &&
            _foreground &&
            candidates.isNotEmpty) {
          await sharingServer.rebind(candidates.first.address);
          if (!_foreground) sharingServer.suspend();
          await _advertise(sharingServer);
        }
        message = '网络已变化，传输已暂停；恢复后可重新连接，有效授权不会延长。';
      }
      _networkSignature = current;
    } catch (_) {
      /* A later poll or socket failure will surface an unavailable interface. */
    } finally {
      _checkingNetwork = false;
      _changed();
    }
  }

  Future<void> discover() async {
    await stopDiscovery();
    if (_disposed || !_foreground) return;
    final epoch = _discoveryEpoch;
    discoveryWarning = null;
    try {
      final discovery =
          await nsd.startDiscovery(serviceType, autoResolve: false);
      if (_disposed || !_foreground || epoch != _discoveryEpoch) {
        await nsd.stopDiscovery(discovery);
        return;
      }
      _discovery = discovery;
      discovery.addListener(_discoveryChanged);
      _discoveryChanged();
    } catch (_) {
      discoveryWarning = '附近发现不可用，请检查局域网权限、Wi-Fi 和对方是否开启共享。';
    }
    _changed();
  }

  Future<void> stopDiscovery() async {
    _discoveryEpoch++;
    _resolved.clear();
    _resolutionAttempts.clear();
    final value = _discovery;
    _discovery = null;
    if (value != null) {
      value.removeListener(_discoveryChanged);
      try {
        await nsd.stopDiscovery(value);
      } catch (_) {}
    }
  }

  static String _serviceKey(nsd.Service service) =>
      '${service.name}|${service.type}';
  void _discoveryChanged() {
    _changed();
    unawaited(_resolveNearby());
  }

  Future<void> _resolveNearby() async {
    if (_resolving || _discovery == null) return;
    _resolving = true;
    final discovery = _discovery;
    try {
      while (!_disposed && _foreground && _discovery == discovery) {
        final unresolved = discovery!.services
            .take(40)
            .where((s) => !_resolutionAttempts.contains(_serviceKey(s)))
            .toList();
        if (unresolved.isEmpty) break;
        final service = unresolved.first;
        final key = _serviceKey(service);
        _resolutionAttempts.add(key);
        try {
          final resolved =
              await nsd.resolve(service).timeout(const Duration(seconds: 5));
          if (_discovery == discovery) _resolved[key] = resolved;
        } catch (_) {
          if (_discovery == discovery)
            discoveryWarning = '部分设备地址未能解析，可刷新附近设备后重试。';
        }
        _changed();
      }
    } finally {
      _resolving = false;
      if (_discovery != null && _discovery != discovery)
        unawaited(_resolveNearby());
    }
  }

  Future<void> startSharing(Set<String> selected, InternetAddress address,
      {required bool includeLyrics, required bool includeArtwork}) async {
    if (preparing || sharing) return;
    preparing = true;
    _cancelPrepare = false;
    error = null;
    sentBytes = 0;
    prepared = 0;
    prepareTotal = selected.length;
    _sharingInterface = addresses
        .where((a) => a.address.address == address.address)
        .map((a) => a.label.split(' · ').first)
        .firstOrNull;
    _changed();
    try {
      _networkSignature = await _readNetworkSignature();
      final manifest = await reader!.prepare(selected,
          includeLyrics: includeLyrics,
          includeArtwork: includeArtwork,
          progress: (done, total) {
            prepared = done;
            prepareTotal = total;
            _changed();
          },
          cancelled: () => _cancelPrepare || _disposed);
      if (_cancelPrepare || _disposed || !_foreground) {
        await reader!.close();
        return;
      }
      if (await _readNetworkSignature() != _networkSignature)
        throw StateError('准备期间网络发生变化，请刷新地址后重新开启。');
      sharedResources = manifest.resources;
      sentResources.clear();
      final host = TransferHost(
          authorization: TransferAuthorization(),
          reader: reader!,
          parallelReads: 1);
      host.start(manifest, manifest.resources.map((e) => e.id).toSet());
      final candidate = TransferSecureServer(
          identity: identity!,
          host: host,
          name: name,
          deviceInfo: deviceInfo,
          onDisconnected: _peerDisconnected,
          changed: _changed,
          onRead: (id, bytes) {
            sentBytes += bytes;
            sentResources[id] = (sentResources[id] ?? 0) + bytes;
            _changed();
          });
      server = candidate;
      await candidate.start(address);
      await _advertise(candidate);
      message = '共享已开启，只有核对设备码并批准后，对方才能浏览资源。';
    } catch (e) {
      await stopSharing();
      error = describe(e);
    } finally {
      preparing = false;
      _changed();
    }
  }

  void cancelPreparation() {
    _cancelPrepare = true;
    message = '将在当前文件校验完成后停止准备。';
    _changed();
  }

  Future<void> stopSharing() async {
    _cancelPrepare = true;
    await disconnect();
    final current = server;
    server = null;
    await current?.stop();
    await _unregister();
    await reader?.close();
    _changed();
  }

  Future<void> _unregister() async {
    final value = _registration;
    _registration = null;
    if (value != null) {
      try {
        await nsd.unregister(value);
      } catch (_) {}
    }
  }

  Future<void> _advertise(TransferSecureServer candidate) async {
    if (_advertising ||
        _registration != null ||
        server != candidate ||
        !_foreground ||
        _disposed ||
        candidate.endpoint == null) return;
    _advertising = true;
    try {
      final registration = await nsd.register(nsd.Service(
          name: name,
          type: serviceType,
          port: candidate.endpoint!.port,
          txt: {
            for (final e in {
              'v': '2',
              'id': identity!.digest,
              'cert': identity!.certificateDigest,
              'a': candidate.endpoint!.address
            }.entries)
              e.key: Uint8List.fromList(utf8.encode(e.value))
          }));
      if (_disposed || !_foreground || server != candidate) {
        await nsd.unregister(registration);
      } else {
        _registration = registration;
      }
    } catch (_) {
      discoveryWarning = '附近设备广播失败，请检查局域网权限后停止并重新开启共享。';
    } finally {
      _advertising = false;
      _changed();
    }
  }

  Future<void> approve(int minutes) async {
    final auth = server?.host.authorization,
        request = server?.host.authorization.pending;
    if (auth == null || request == null) return;
    if (client != null &&
        !client!.closed &&
        client!.remoteIdentity != request.peer.identityDigest) {
      error = '首版仅同时连接一台设备。请先断开当前接收连接。';
      _changed();
      return;
    }
    try {
      peers!.checkIdentity(request.peer.identityDigest);
      final epoch = _connectionEpoch;
      await peers!.remember(TransferRemoteDevice(request.peer.identityDigest,
          request.peer.displayName, request.peer.deviceInfo));
      if (!_foreground ||
          _disposed ||
          epoch != _connectionEpoch ||
          server?.host.authorization != auth) return;
      auth.approve(request.id, duration: Duration(minutes: minutes));
      error = null;
    } catch (e) {
      error = describe(e);
    }
    _changed();
  }

  void reject() {
    server?.reject();
    _changed();
  }

  static String? _txt(nsd.Service service, String key) {
    final bytes = service.txt?[key];
    if (bytes == null || bytes.length > 256) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  static String? serviceIdentity(nsd.Service service) {
    final id = _txt(service, 'id');
    return id != null && isTransferDigest(id) ? id : null;
  }

  static String serviceSubtitle(nsd.Service service) {
    final id = serviceIdentity(service);
    if (_txt(service, 'v') != '2') return '等待解析或旧版设备，请确认两端已更新';
    return id == null ? '正在解析设备…' : '安全码 ${displaySafetyCode(id)}';
  }

  Future<TransferEndpoint> _endpoint(nsd.Service service) async {
    final resolved = _resolved[_serviceKey(service)];
    if (resolved == null) throw StateError('正在解析设备地址，请稍候或刷新附近设备。');
    if (_txt(resolved, 'v') != '2') {
      throw StateError('对方尚不支持安全码连接，请将两端 App 更新到新版。');
    }
    final id = serviceIdentity(resolved), cert = _txt(resolved, 'cert');
    final address = _txt(resolved, 'a');
    if (id == null ||
        cert == null ||
        address == null ||
        resolved.port == null) {
      throw StateError('设备地址尚未准备好，请刷新附近设备。');
    }
    return TransferEndpoint(
        address: address,
        port: resolved.port!,
        identityDigest: id,
        certificateDigest: cert);
  }

  Future<nsd.Service> _find(String code, {String? fullIdentity}) async {
    if (_discovery == null) await discover();
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    do {
      final matches = nearby.where((s) {
        final id = serviceIdentity(s);
        return id != null && normalizeSafetyCode(displaySafetyCode(id)) == code;
      }).toList();
      final ids = matches.map(serviceIdentity).toSet();
      if (ids.length > 1 ||
          (fullIdentity != null &&
              ids.isNotEmpty &&
              !ids.contains(fullIdentity))) {
        throw StateError('安全码对应多个身份或原身份已变化，已停止连接。');
      }
      if (matches.isNotEmpty) return matches.first;
      if (!_foreground || _disposed) throw StateError('请返回前台后重新连接。');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } while (DateTime.now().isBefore(deadline));
    throw StateError('未找到该安全码。请确认对方开启共享、两端在同一局域网并允许本地网络访问。');
  }

  Future<void> connect(
      String code, Future<bool> Function(TransferRemoteDevice) confirm) async {
    try {
      final normalized = normalizeSafetyCode(code);
      if (normalized == normalizeSafetyCode(identity!.safetyCode))
        throw StateError('这是本机安全码，请选择另一台设备。');
      final service = await _find(normalized);
      await connectService(service, confirm, expectedCode: normalized);
    } catch (e) {
      error = describe(e);
      _changed();
    }
  }

  Future<void> connectService(
      nsd.Service service, Future<bool> Function(TransferRemoteDevice) confirm,
      {String? expectedCode, String? expectedIdentity}) async {
    if (connecting || receiving) return;
    connecting = true;
    error = null;
    final previous = client;
    final epoch = ++_connectionEpoch;
    _changed();
    try {
      final endpoint = await _endpoint(service);
      expectedIdentity ??= serviceIdentity(service);
      if (expectedCode != null &&
              normalizeSafetyCode(endpoint.safetyCode) != expectedCode ||
          expectedIdentity != null &&
              endpoint.identityDigest != expectedIdentity) {
        throw StateError('设备身份已变化，请刷新并重新核对。');
      }
      _networkSignature = await _readNetworkSignature();
      if (endpoint.identityDigest == identity!.digest)
        throw StateError('不能连接本机。');
      if (previous != null &&
          previous.remoteIdentity != endpoint.identityDigest) {
        throw StateError('请先断开当前设备，再连接另一台设备。');
      }
      if (nearby.any((s) {
        final id = serviceIdentity(s);
        return id != null &&
            id != endpoint.identityDigest &&
            displaySafetyCode(id) == endpoint.safetyCode;
      })) throw StateError('附近存在安全码相同但身份不同的设备，已停止连接。');
      final localPeer = server?.host.authorization.grant?.peer ??
          server?.host.authorization.pending?.peer;
      if (localPeer != null &&
          localPeer.identityDigest != endpoint.identityDigest) {
        throw StateError('本机正在与另一台设备连接，请先断开。');
      }
      previous?.close();
      client = null;
      remote = [];
      peers!.checkIdentity(endpoint.identityDigest);
      final resumeKey =
          _resumeKeys.putIfAbsent(endpoint.identityDigest, newTransferId);
      final value = await TransferSecureClient.connect(
          endpoint, identity!, name,
          resumeKey: resumeKey, deviceInfo: deviceInfo, onDisconnected: () {
        if (epoch == _connectionEpoch)
          _peerDisconnected(endpoint.identityDigest);
      }, confirm: (device) async {
        if (_disposed || !_foreground || epoch != _connectionEpoch)
          return false;
        if (!peers!.contains(device.identityDigest) && !await confirm(device))
          return false;
        if (_disposed || !_foreground || epoch != _connectionEpoch)
          return false;
        await peers!.remember(device, receiving: true);
        return !_disposed && _foreground && epoch == _connectionEpoch;
      });
      final grant = server?.host.authorization.grant;
      if (grant != null && grant.peer.identityDigest != value.remoteIdentity) {
        value.close();
        throw StateError('本机已授权另一台设备，请先撤销后再连接。');
      }
      if (_disposed || !_foreground || epoch != _connectionEpoch) {
        value.close();
        return;
      }
      client = value;
      message = '请在提供方核对本机设备安全码，并批准本次限时连接。';
      if (approved) await refreshCatalog();
    } catch (e) {
      error = describe(e);
    } finally {
      connecting = false;
      _changed();
    }
  }

  Future<void> reconnect(
      Future<bool> Function(TransferRemoteDevice) confirm) async {
    final id = peers?.lastIdentity;
    if (id == null) return;
    try {
      final service = await _find(normalizeSafetyCode(displaySafetyCode(id)),
          fullIdentity: id);
      await connectService(service, confirm, expectedIdentity: id);
    } catch (e) {
      error = describe(e);
      _changed();
    }
  }

  void _peerDisconnected(String id) {
    _resumeKeys.remove(id);
    final ownGrant = server?.host.authorization.grant;
    final ownPending = server?.host.authorization.pending;
    if (ownGrant?.peer.identityDigest == id ||
        ownPending?.peer.identityDigest == id) server?.revoke();
    if (client?.remoteIdentity == id) {
      _connectionEpoch++;
      _control?.pause();
      client?.close();
      client = null;
      remote = [];
    }
    message = '对方已断开连接，再次连接需要重新批准。';
    _changed();
  }

  Future<void> disconnect() async {
    _connectionEpoch++;
    _resumeKeys.clear();
    _control?.pause();
    final current = client;
    client = null;
    remote = [];
    server?.revoke();
    message = '已断开连接，再次连接需要重新批准。';
    _changed();
    await current?.disconnect();
  }

  Future<void> _refreshConnection() async {
    final current = client;
    if (_polling ||
        current == null ||
        current.closed ||
        receiving ||
        connecting) return;
    _polling = true;
    try {
      final wasApproved = approved;
      await current.refreshStatus();
      if (!wasApproved && approved) await refreshCatalog();
    } catch (e) {
      if (client == current) {
        error = describe(e);
        remote = [];
      }
    } finally {
      _polling = false;
      _changed();
    }
  }

  Future<void> refreshCatalog() async {
    if (!approved || receiving) return;
    try {
      remote = (await client!.catalog()).resources;
      error = null;
    } catch (e) {
      error = describe(e);
    }
    _changed();
  }

  Future<void> download(
      Set<String> selected, TransferImportPolicy policy) async {
    if (!approved || receiving || selected.isEmpty || selected.length > 500)
      return;
    final connection = client!;
    final map = {for (final resource in remote) resource.id: resource};
    final ordered = <String>{};
    for (final id in selected) {
      final r = map[id];
      if (r == null) continue;
      ordered.add(id);
      ordered.addAll(r.attachmentIds);
    }
    receiving = true;
    completed = 0;
    batchTotal = ordered.length;
    error = null;
    _control = TransferReceiveControl();
    final meter = Stopwatch()..start();
    var transferred = 0;
    final baselineById = {
      for (final id in ordered) id: app.transferImportContext
    };
    var ownContext = app.transferImportContext;
    final artworkFiles = <String, File>{};
    _changed();
    try {
      for (final id in ordered) {
        if (_control!.isPaused) break;
        final resource = map[id];
        if (resource == null) continue;
        currentTitle = resource.metadata.title;
        receivedBytes = 0;
        totalBytes = resource.byteLength;
        outcomes[id] = '正在校验本地内容';
        _changed();
        try {
          final duplicate = await app.findTransferDuplicate(resource);
          if (_control!.isPaused) break;
          if (duplicate != null) {
            await app.mergeTransferMetadata(
                duplicate, resource, policy, ownContext);
            ownContext = app.transferImportContext;
            outcomes[id] = '相同内容已存在，未重复下载';
            completed++;
            _changed();
            continue;
          }
          await _pruneHistory();
          var previousOffset = 0;
          final receipt = await TransferReceiver(store!).receive(
              source: connection,
              peerDigest: connection.remoteIdentity,
              resource: resource,
              control: _control!,
              policy: policy,
              baseVersion: baselineById[id]!,
              onProgress: (bytes, total) {
                if (previousOffset > 0) transferred += bytes - previousOffset;
                previousOffset = bytes;
                receivedBytes = bytes;
                totalBytes = total;
                bytesPerSecond = transferred /
                    (meter.elapsedMilliseconds.clamp(1, 1 << 53) / 1000);
                outcomes[id] = '接收中';
                _changed();
              });
          final file = await store!.verifiedFile(receipt.jobId);
          // A resumed job keeps its old conflict baseline. New jobs can account
          // for earlier imports from this same batch, never unrelated local edits.
          final expected = receipt.baseVersion == baselineById[id]
              ? ownContext
              : receipt.baseVersion;
          await app.importTransfer(receipt, file, expectedContext: expected);
          ownContext = app.transferImportContext;
          if (resource.kind == TransferResourceKind.artwork)
            artworkFiles[id] = file;
          await store!.markIndexed(receipt.jobId);
          outcomes[id] = '已接收并入库';
          completed++;
          try {
            await connection.receipt(resource.id);
          } catch (_) {
            /* Local durable success is not undone by a lost receipt. */
          }
        } on TransferReceivePaused {
          outcomes[id] = '已暂停，可在有效授权下继续';
          break;
        } catch (e) {
          outcomes[id] = describe(e);
          error = '部分任务未完成，可在“已接收”重试入库或重新连接后继续下载。';
        }
        _changed();
        if (connection.closed) break;
      }
      for (final resource in map.values.where((r) => selected.contains(r.id))) {
        for (final id in resource.attachmentIds) {
          if (artworkFiles[id] case final file?)
            await app.attachTransferArtwork(resource, file);
        }
      }
      message = _control!.isPaused
          ? '传输已暂停，已完成的文件仍可使用。'
          : '本批完成 $completed / $batchTotal 项（含附件）。';
    } catch (e) {
      error = describe(e);
    } finally {
      receiving = false;
      _control = null;
      _changed();
    }
  }

  void pause() {
    _control?.pause();
    message = '正在暂停，已保存分块将保留 24 小时。';
    _changed();
  }

  Future<void> retryImport(ReceivedTransferReceipt receipt) async {
    final file = await store!.verifiedFile(receipt.jobId);
    await app.importTransfer(receipt, file, reconfirm: true);
    await store!.markIndexed(receipt.jobId);
    _changed();
  }

  Future<void> cancelPartial(ReceivedTransferReceipt receipt) async {
    if (receiving) throw StateError('请先暂停传输，再取消未完成任务。');
    await store!.cancelPartial(receipt.jobId);
    _changed();
  }

  Future<void> export(ReceivedTransferReceipt receipt) async {
    final file = await store!.verifiedFile(receipt.jobId);
    if (receipt.resource.kind == TransferResourceKind.lyrics)
      throw StateError('歌词已保存到歌词库，请在歌词库导出标准 LRC 或歌词包。');
    await NativeTransferLease.channel.invokeMethod<bool>('exportReceived',
        {'path': file.path, 'name': receipt.resource.metadata.title});
  }

  Future<void> _pruneHistory() async {
    final list = history.reversed.where((e) => e.indexed).toList();
    for (final receipt in list) {
      if (store!.receipts.length < 180 &&
          DateTime.now().difference(receipt.updatedAt) <
              const Duration(days: 30)) break;
      await store!.forgetIndexedReceipt(receipt.jobId);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _connectionEpoch++;
      _cancelPrepare = true;
      pause();
      client?.close();
      server?.suspend();
      unawaited(stopDiscovery());
      unawaited(_unregister());
      message = '离开前台后已暂停。返回后请重连；授权期限不会延长。';
      _changed();
    } else if (state == AppLifecycleState.resumed) {
      _foreground = true;
      if (server case final current?) {
        unawaited(() async {
          await _checkNetwork();
          if (!_disposed &&
              _foreground &&
              server == current &&
              current.endpoint != null) {
            current.foreground = true;
            await _advertise(current);
          }
        }());
      }
      _changed();
    }
  }

  static String describe(Object e) => switch (e) {
        final TransferException e => e.message,
        final PlatformException e => e.message ?? '平台操作失败，请检查权限。',
        SocketException _ => '连接已断开或不可达。请确认同一局域网、对方在前台、防火墙允许，之后重连。',
        HandshakeException _ => '安全连接校验失败，请刷新附近设备并核对安全码，勿忽略证书错误。',
        TimeoutException _ => '连接超时，请确认对方仍在前台后重试。',
        final FormatException e => e.message,
        final StateError e => e.message,
        _ => '操作未完成，原文件已保留，请重试。',
      };

  @override
  void dispose() {
    _disposed = true;
    _cancelPrepare = true;
    _control?.pause();
    _poll?.cancel();
    _networkTimer?.cancel();
    client?.close();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(stopSharing());
    unawaited(stopDiscovery());
    super.dispose();
  }
}
