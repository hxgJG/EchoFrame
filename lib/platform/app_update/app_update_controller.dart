import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/updates/release_config.dart';
import '../../core/updates/update_manifest.dart';
import 'update_transport.dart';
import 'update_diagnostics.dart';

enum UpdatePhase {
  idle,
  checking,
  available,
  downloading,
  ready,
  opening,
  failed
}

class AppUpdateController extends ChangeNotifier {
  static const _channel = MethodChannel('lumio/app_update');
  UpdatePhase phase = UpdatePhase.idle;
  Map<String, dynamic>? environment;
  UpdateManifest? manifest;
  UpdatePackage? package;
  File? downloaded;
  int received = 0;
  File? diagnosticReport;
  String? diagnosticWriteError;
  UpdateDiagnostics? _diagnostics;
  Timer? _diagnosticTimer;
  Future<void> _diagnosticWrites = Future<void>.value();
  Map<String, Object?> _report = {};
  String message = '点击检查更新。仅访问公开发布附件，不上传应用数据。';
  UpdateTransport? _transport;
  bool _disposed = false;
  bool _cancelRequested = false;
  static DateTime? _checkedAt;
  static UpdateManifest? _cachedManifest;
  static int _highestBuild = 0;
  bool get busy => [
        UpdatePhase.checking,
        UpdatePhase.downloading,
        UpdatePhase.opening
      ].contains(phase);
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadEnvironment() async {
    environment =
        (await _channel.invokeMapMethod<String, dynamic>('environment'))!;
    _emit();
  }

  Future<void> _startDiagnostics(String operation) async {
    await _saveDiagnostics();
    _diagnosticTimer?.cancel();
    final root = Directory('${environment!['cacheRoot']}/diagnostics');
    await root.create(recursive: true);
    diagnosticReport = File(
        '${root.path}/network-${DateTime.now().microsecondsSinceEpoch}.json');
    diagnosticWriteError = null;
    _diagnostics = UpdateDiagnostics();
    _report = {
      'schemaVersion': 1,
      'operation': operation,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': environment!['version'],
      'appBuild': environment!['buildNumber'],
      'platform': environment!['platform'],
      'architecture': environment!['architecture'],
      'status': 'running',
      'networkMode': '原有 Dart HttpClient 直连；不能证明系统 VPN 或透明代理已关闭',
      'timingBoundary':
          'Dart getUrl / 响应头为综合等待；原生 HEAD 是下载后的独立探测，不等同原 GET。支持字节续传，没有更改 DNS、IP 或代理。',
      if (operation == 'download' && package != null)
        'package': {
          'version': manifest!.version,
          'buildNumber': manifest!.buildNumber,
          'fileName': package!.fileName,
          'expectedBytes': package!.size,
          'sha256': package!.sha256,
          'url': diagnosticUrl(package!.url),
        },
    };
    await _saveDiagnostics();
    if (_disposed) return;
    _diagnosticTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_saveDiagnostics());
    });
    _emit();
  }

  Future<void> _saveDiagnostics() {
    final file = diagnosticReport;
    final diagnostics = _diagnostics;
    if (file == null || diagnostics == null) return _diagnosticWrites;
    final contents = const JsonEncoder.withIndent('  ').convert({
      ..._report,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'receivedBytes': received,
      'transport': diagnostics.snapshot(),
    });
    return _diagnosticWrites = _diagnosticWrites.then((_) async {
      try {
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(contents, flush: true);
        await temporary.rename(file.path);
      } on Object {
        diagnosticWriteError = '诊断日志保存失败，请检查磁盘空间。';
        _emit();
      }
    });
  }

  Future<void> _finishDiagnostics(String status, {Object? error}) async {
    _diagnosticTimer?.cancel();
    _report['status'] = status;
    _report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    if (error != null) _report['error'] = diagnosticError(error);
    await _saveDiagnostics();
  }

  Future<void> _probeDiagnostics(Uri uri) async {
    if (!Platform.isMacOS || _disposed) return;
    try {
      _report['independentHeadProbe'] = await _channel
          .invokeMethod<Object>('probeNetwork', {'url': uri.toString()});
      await _saveDiagnostics();
    } on Object catch (error) {
      _report['probeError'] = diagnosticError(error);
    }
  }

  Future<String> readDiagnosticReport() async {
    await _saveDiagnostics();
    if (diagnosticReport == null) return '尚无诊断记录，请手动检查更新或下载。';
    return diagnosticReport!.readAsString();
  }

  Future<void> check() async {
    if (busy) return;
    if (_checkedAt != null &&
        DateTime.now().difference(_checkedAt!) < const Duration(seconds: 60)) {
      phase = UpdatePhase.checking;
      _emit();
      try {
        await loadEnvironment();
        if (_cachedManifest != null) {
          _applyManifest(_cachedManifest!);
          await _refreshRetained();
        } else {
          phase = UpdatePhase.idle;
          message = '刚刚已检查，请在一分钟后重试。';
        }
      } on Object catch (e) {
        phase = UpdatePhase.failed;
        message = _error(e);
      }
      _emit();
      return;
    }
    phase = UpdatePhase.checking;
    manifest = null;
    package = null;
    downloaded = null;
    received = 0;
    _checkedAt = DateTime.now();
    _cachedManifest = null;
    _emit();
    UpdateTransport? transport;
    try {
      await loadEnvironment();
      await _startDiagnostics('check');
      if (_disposed) return;
      transport = _transport = UpdateTransport(diagnostics: _diagnostics);
      final raw = await transport.smallFile(
          Uri.parse(
              'https://github.com/$releaseRepository/releases/latest/download/update-manifest.json'),
          65536);
      final signature = await transport.smallFile(
          Uri.parse(
              'https://github.com/$releaseRepository/releases/latest/download/update-manifest.sig'),
          256);
      final verified = await UpdateManifest.verify(
          raw, utf8.decode(signature), updatePublicKey);
      if (_disposed) return;
      _applyManifest(verified);
      await _refreshRetained();
      _cachedManifest = verified;
      await _finishDiagnostics('manifestSignatureVerified');
    } on UpdateNotPublished {
      phase = UpdatePhase.idle;
      message = '尚无公开的更新版本，或发布附件暂不可用。当前应用可继续使用。';
      await _finishDiagnostics('notPublished');
    } on Object catch (e) {
      phase = UpdatePhase.failed;
      message = _error(e);
      await _finishDiagnostics('failed', error: e);
    } finally {
      transport?.cancel();
      if (identical(_transport, transport)) _transport = null;
      _emit();
    }
  }

  File _cacheFile(UpdatePackage selected) => File(
      '${environment!['cacheRoot']}/update-${manifest!.buildNumber}-${selected.sha256}.${selected.platform == 'android' ? 'apk' : 'zip'}');

  Future<void> _refreshRetained() async {
    if (package == null) return;
    try {
      received =
          await UpdateTransport.retainedBytes(package!, _cacheFile(package!));
    } on FileSystemException {
      received = 0;
    }
    if (received > 0) message = '发现已保存的下载进度，可继续下载并校验。';
  }

  void _applyManifest(UpdateManifest verified) {
    final current = int.parse(environment!['buildNumber'].toString());
    if (verified.buildNumber < _highestBuild)
      throw const FormatException('服务器返回了更早的清单，已拒绝回退。');
    _highestBuild = verified.buildNumber;
    if (verified.buildNumber <= current) {
      phase = UpdatePhase.idle;
      message = '当前已是最新版本。';
    } else {
      if (UpdateManifest.compareOS(
              verified.version, environment!['version'] as String) <
          0) throw const FormatException('已拒绝版本降级。');
      package = verified.select(
          environment!['platform'] as String,
          environment!['architecture'] as String,
          environment!['osVersion'] as String);
      manifest = verified;
      phase = UpdatePhase.available;
      message = '发现新版本，请查看说明后下载。';
    }
  }

  Future<void> download() async {
    if (busy || package == null) return;
    final selected = package!;
    _cancelRequested = false;
    phase = UpdatePhase.downloading;
    downloaded = null;
    message = '正在下载并校验，网络中断将自动尝试续传…';
    _emit();
    UpdateTransport? transport;
    File? file;
    var transportCompleted = false;
    try {
      await loadEnvironment();
      await _startDiagnostics('download');
      if (_disposed) return;
      if (_cancelRequested) throw UpdateCancelled();
      transport = _transport = UpdateTransport(diagnostics: _diagnostics);
      file = _cacheFile(selected);
      received = await UpdateTransport.retainedBytes(selected, file);
      if ((environment!['availableBytes'] as num).toInt() <
          selected.size - received + 64 * 1024 * 1024)
        throw const FileSystemException('存储空间不足，请至少预留安装包大小与 64 MiB。');
      await transport.download(selected, file, (bytes) {
        received = bytes;
        _emit();
      });
      transportCompleted = true;
      if (_disposed) return;
      await _channel.invokeMethod<void>('validate', _arguments(file));
      downloaded = file;
      await _probeDiagnostics(selected.url);
      await _finishDiagnostics('downloadAndNativeValidationPassed');
      phase = UpdatePhase.ready;
      message = '下载和校验完成，诊断已保存。';
    } on UpdateCancelled {
      phase = UpdatePhase.available;
      message = '已暂停下载，已下载部分保留，可稍后继续。';
      await _finishDiagnostics('cancelled');
    } on Object catch (e) {
      try {
        if (transportCompleted && file != null && await file.exists())
          await file.delete();
        if (file != null && e is! UpdateDownloadBusy) {
          received = await UpdateTransport.retainedBytes(selected, file);
        }
      } on FileSystemException {
        // A cache read/cleanup failure must not leave the page stuck downloading.
        received = 0;
      }
      message = _error(e);
      await _probeDiagnostics(selected.url);
      await _finishDiagnostics('failed', error: e);
      phase = UpdatePhase.failed;
    } finally {
      transport?.cancel();
      if (identical(_transport, transport)) _transport = null;
      _emit();
    }
  }

  Map<String, Object?> _arguments(File file) => {
        'path': file.path,
        'size': package!.size,
        'sha256': package!.sha256,
        'buildNumber': manifest!.buildNumber,
        'version': manifest!.version,
        'certificateSha256': package!.certificateSha256
      };

  Future<void> open(Future<void> Function() saveSession) async {
    if (busy || downloaded == null) return;
    phase = UpdatePhase.opening;
    _emit();
    try {
      await saveSession();
      if (_disposed) return;
      final result =
          await _channel.invokeMethod<String>('open', _arguments(downloaded!));
      message = result == 'permissionRequired'
          ? '请在系统设置允许本应用安装更新，返回后再次点击“安装更新”。不会自动开始安装。'
          : Platform.isAndroid
              ? '已交给系统安装器，请完成系统确认；取消不会清空数据。'
              : '已在 Finder 定位。解压后先退出 Lumio，再手动替换应用。';
      phase = UpdatePhase.ready;
    } on Object catch (e) {
      phase = UpdatePhase.ready;
      message = _error(e);
    }
    _emit();
  }

  static String _error(Object e) {
    if (e is PlatformException) return e.message ?? '系统操作失败，请重试。';
    if (e is UpdateDownloadBusy) return '上一次下载正在停止，请稍后继续。';
    if (e is UpdateNotPublished) return '此版本附件暂不可用，请稍后重新检查更新。';
    if (e is FormatException) return e.message;
    if (e is TimeoutException) return '网络响应超时，请稍后重试。';
    if (e is FileSystemException && e.osError?.errorCode == 28)
      return '存储空间不足，下载已停止。';
    if (e is SocketException || e is HttpException || e is TlsException)
      return '无法连接发布服务，请检查网络后重试。';
    return e.toString();
  }

  void cancel() {
    _cancelRequested = true;
    _transport?.cancel();
    if (Platform.isMacOS) {
      unawaited(
          _channel.invokeMethod<void>('cancelProbe').catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    _diagnosticTimer?.cancel();
    if (_report['status'] == 'running') _report['status'] = 'pageClosed';
    unawaited(_saveDiagnostics());
    super.dispose();
  }
}
