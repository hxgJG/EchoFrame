import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The native player owns sampling. Only compact bands cross this channel.
class AudioSpectrumController extends ValueNotifier<List<double>>
    with WidgetsBindingObserver {
  AudioSpectrumController() : super(const []) {
    if (supported) WidgetsBinding.instance.addObserver(this);
  }

  static const bandCount = 24;
  static bool get supported => Platform.isMacOS || Platform.isAndroid;
  final _channel = const MethodChannel('lumio/audio_spectrum');
  final Set<Object> _views = {};
  bool _playing = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _busy = false;
  bool _active = false;
  bool _configuring = false;
  bool? _configured;
  String? _mediaId;
  Timer? _timer;

  void updatePlayback({required bool playing, required String? mediaId}) {
    if (_mediaId != mediaId) value = const [];
    _mediaId = mediaId;
    _playing = playing;
    _reconcile();
  }

  void setVisible(Object owner, bool visible) {
    visible ? _views.add(owner) : _views.remove(owner);
    _reconcile();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A visible macOS window can lose keyboard focus without being hidden.
    _foreground = state == AppLifecycleState.resumed ||
        (Platform.isMacOS && state == AppLifecycleState.inactive);
    _reconcile();
  }

  void _reconcile() {
    final active = supported && _playing && _foreground && _views.isNotEmpty;
    if (_active == active || _disposed) return;
    _active = active;
    _timer?.cancel();
    _timer = null;
    value = const [];
    unawaited(_configure());
    if (active) {
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => _read());
    }
  }

  Future<void> _configure() async {
    if (_configuring) return;
    _configuring = true;
    try {
      while (_configured != _active) {
        final wanted = _active;
        await _channel.invokeMethod<void>('configure', {'enabled': wanted});
        _configured = wanted;
      }
    } catch (_) {
      // Unsupported audio analysis never interrupts playback.
      _timer?.cancel();
      _timer = null;
      if (!_disposed) value = const [];
    } finally {
      _configuring = false;
    }
  }

  Future<void> _read() async {
    if (_busy || !_active || _disposed) return;
    _busy = true;
    final mediaId = _mediaId;
    try {
      final bands = await _channel.invokeListMethod<num>('read');
      if (_disposed || !_active || mediaId != _mediaId) return;
      final next = bands != null && bands.length == bandCount
          ? bands
              .map((v) => v.isFinite ? v.toDouble().clamp(0.0, 1.0) : 0.0)
              .toList(growable: false)
          : const <double>[];
      if (!listEquals(value, next)) value = next;
    } catch (_) {
      if (!_disposed) value = const [];
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _timer?.cancel();
    if (supported) {
      WidgetsBinding.instance.removeObserver(this);
      unawaited(_configure());
    }
    super.dispose();
  }
}
