import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DesktopLyricsController extends ChangeNotifier {
  static const double maximumTransparency = 0.6;
  static const double defaultTransparency = 0;
  final MethodChannel _channel = const MethodChannel('lumio/desktop_lyrics');
  bool get supported => Platform.isMacOS;
  bool enabled = false;
  bool locked = false;
  double transparency = defaultTransparency;
  ValueChanged<String>? onOpenCalibration;
  String? error;
  bool _disposed = false;
  bool _sending = false;
  Map<String, Object> _latest = const {};
  Map<String, Object> _appearance = const {};
  Map<String, Object>? _sent;
  Future<void>? _ready;

  void initialize({
    required VoidCallback onPrevious,
    required VoidCallback onTogglePlaying,
    required VoidCallback onNext,
  }) {
    if (!supported || _ready != null) return;
    _channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      if (call.method == 'openLyricCalibration' &&
          enabled &&
          !locked &&
          call.arguments is String &&
          call.arguments == _latest['mediaId'] &&
          _latest['canCalibrate'] == true) {
        onOpenCalibration?.call(call.arguments as String);
      }
      if (call.method == 'playbackAction' && enabled && !locked) {
        switch (call.arguments) {
          case 'previous':
            onPrevious();
          case 'togglePlaying':
            onTogglePlaying();
          case 'next':
            onNext();
        }
      }
      if (call.method == 'settingsChanged' && !_disposed) {
        _applySettings(Map<Object?, Object?>.from(call.arguments as Map));
      }
    });
    _ready = _configure('getSettings');
  }

  Future<void> setEnabled(bool value) async {
    await _ready;
    await _configure('configure', {'enabled': value});
  }

  Future<void> setLocked(bool value) async {
    await _ready;
    await _configure('configure', {'locked': value});
  }

  Future<void> resetPosition() => _configure('resetPosition');

  Future<void> setTransparency(double value) async {
    if (!value.isFinite) return;
    await _ready;
    await _configure('configure', {
      'transparency': value.clamp(0.0, maximumTransparency).toDouble(),
    });
  }

  Future<void> _configure(String method, [Map<String, Object>? args]) async {
    if (!supported || _disposed) return;
    try {
      final settings =
          await _channel.invokeMapMethod<Object?, Object?>(method, args);
      if (!_disposed && settings != null) {
        error = null;
        _applySettings(settings);
      }
    } catch (_) {
      if (!_disposed) {
        error = '桌面歌词暂不可用，请重启应用后重试。';
        notifyListeners();
      }
    }
  }

  void _applySettings(Map<Object?, Object?> settings) {
    enabled = settings['enabled'] == true;
    locked = settings['locked'] == true;
    final value = settings['transparency'];
    transparency = value is num && value.isFinite
        ? value.toDouble().clamp(0.0, maximumTransparency).toDouble()
        : defaultTransparency;
    _sent = null;
    notifyListeners();
    unawaited(_flush());
  }

  void publish(Map<String, Object> snapshot) {
    _latest = {...snapshot, ..._appearance};
    if (supported && enabled && error == null) unawaited(_flush());
  }

  void setAppearance(Map<String, Object> appearance) {
    if (!supported || mapEquals(_appearance, appearance)) return;
    _appearance = appearance;
    if (_latest.isEmpty) return;
    _latest = {..._latest, ...appearance};
    if (enabled && error == null) unawaited(_flush());
  }

  Future<void> _flush() async {
    if (_sending || _disposed || !enabled || _latest.isEmpty) return;
    _sending = true;
    try {
      // 只跨通道发送变化后的句子，不逐播放进度刷新原生窗口。
      while (!_disposed && enabled && !mapEquals(_sent, _latest)) {
        final snapshot = _latest;
        await _channel.invokeMethod<void>('update', snapshot);
        _sent = snapshot;
      }
    } catch (_) {
      if (!_disposed) {
        error = '桌面歌词同步失败，请关闭后重新开启。';
        notifyListeners();
      }
    } finally {
      _sending = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (supported) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
