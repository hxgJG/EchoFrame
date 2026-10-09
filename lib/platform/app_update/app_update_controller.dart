import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/updates/release_config.dart';
import '../../core/updates/update_manifest.dart';
import 'update_transport.dart';

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
  String message = '点击检查更新。仅访问公开发布附件，不上传应用数据。';
  UpdateTransport? _transport;
  bool _disposed = false;
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

  Future<void> check() async {
    if (busy) return;
    if (_checkedAt != null &&
        DateTime.now().difference(_checkedAt!) < const Duration(seconds: 60)) {
      phase = UpdatePhase.checking;
      _emit();
      try {
        await loadEnvironment();
        if (_cachedManifest != null)
          _applyManifest(_cachedManifest!);
        else {
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
    _checkedAt = DateTime.now();
    _cachedManifest = null;
    _emit();
    final transport = _transport = UpdateTransport();
    try {
      await loadEnvironment();
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
      _cachedManifest = verified;
    } on UpdateNotPublished {
      phase = UpdatePhase.idle;
      message = '尚无公开的更新版本，或发布附件暂不可用。当前应用可继续使用。';
    } on Object catch (e) {
      phase = UpdatePhase.failed;
      message = _error(e);
    } finally {
      transport.cancel();
      if (identical(_transport, transport)) _transport = null;
      _emit();
    }
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
    phase = UpdatePhase.downloading;
    received = 0;
    downloaded = null;
    message = '正在下载并校验…';
    _emit();
    final transport = _transport = UpdateTransport();
    File? file;
    try {
      await loadEnvironment();
      if ((environment!['availableBytes'] as num).toInt() <
          selected.size + 64 * 1024 * 1024)
        throw const FileSystemException('存储空间不足，请至少预留安装包大小与 64 MiB。');
      final suffix = Platform.isAndroid ? 'apk' : 'zip';
      file = File(
          '${environment!['cacheRoot']}/update-${manifest!.buildNumber}-${DateTime.now().microsecondsSinceEpoch}.$suffix');
      await transport.download(selected, file, (bytes) {
        received = bytes;
        _emit();
      });
      if (_disposed) {
        await file.delete();
        return;
      }
      await _channel.invokeMethod<void>('validate', _arguments(file));
      downloaded = file;
      phase = UpdatePhase.ready;
      message = '下载和校验完成。';
    } on UpdateCancelled {
      phase = UpdatePhase.available;
      message = '已取消下载。';
    } on Object catch (e) {
      if (file != null && await file.exists()) await file.delete();
      phase = UpdatePhase.failed;
      message = _error(e);
    } finally {
      transport.cancel();
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
    if (e is UpdateNotPublished) return '此版本附件暂不可用，请稍后重新检查更新。';
    if (e is FormatException) return e.message;
    if (e is TimeoutException) return '网络响应超时，请稍后重试。';
    if (e is FileSystemException && e.osError?.errorCode == 28)
      return '存储空间不足，下载已停止。';
    if (e is SocketException || e is HttpException || e is TlsException)
      return '无法连接发布服务，请检查网络后重试。';
    return e.toString();
  }

  void cancel() => _transport?.cancel();
  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
