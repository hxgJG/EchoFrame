import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../../core/models/media_item.dart';
import 'playback_repository.dart';

class PlatformPlaybackRepository implements PlaybackRepository {
  PlatformPlaybackRepository({
    MethodChannel channel = const MethodChannel('lumio/playback'),
  }) : _channel = channel {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler(_handleMethodCall);
    }
  }

  final MethodChannel _channel;
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();
  int? _videoTextureId;

  @override
  Stream<PlaybackEvent> get events => _events.stream;

  @override
  int? get videoTextureId => _videoTextureId;

  @override
  Future<void> play(MediaItem item, Duration position) async {
    if (!Platform.isAndroid) {
      return;
    }
    final result = await _channel.invokeMapMethod<String, Object?>(
      'play',
      <String, Object?>{
        'mediaId': item.id,
        'kind': item.kind.name,
        'title': item.title,
        'artist': item.artist,
        'album': item.album,
        'path': item.path,
        'durationMs': item.duration.inMilliseconds,
        'positionMs': position.inMilliseconds,
      },
    );
    _setVideoTextureId(_asInt(result?['textureId']));
  }

  @override
  Future<void> pause() => _invokeWithoutResult('pause');

  @override
  Future<void> resume() => _invokeWithoutResult('resume');

  @override
  Future<void> seek(Duration position) {
    if (!Platform.isAndroid) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>('seek', <String, Object?>{
      'positionMs': position.inMilliseconds,
    });
  }

  @override
  Future<void> setSpeed(double speed) {
    if (!Platform.isAndroid) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>('setSpeed', <String, Object?>{
      'speed': speed,
    });
  }

  @override
  Future<void> setEqualizerPreset(
    String presetName, {
    List<double> customGains = const <double>[],
  }) {
    if (!Platform.isAndroid) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>('setEqualizerPreset', <String, Object?>{
      'preset': presetName,
      'customGains': customGains,
    });
  }

  @override
  Future<void> setVolumeScale(double scale) {
    if (!Platform.isAndroid) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>('setVolumeScale', <String, Object?>{
      'scale': scale,
    });
  }

  @override
  Future<void> stop() => _invokeWithoutResult('stop');

  @override
  Future<Duration> position() async {
    if (!Platform.isAndroid) {
      return Duration.zero;
    }
    final value = await _channel.invokeMethod<int>('position');
    return Duration(milliseconds: value ?? 0);
  }

  @override
  Future<void> enterPictureInPicture() => _invokeWithoutResult(
        'enterPictureInPicture',
      );

  @override
  Future<void> adjustBrightness(double delta) {
    if (!Platform.isAndroid) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>('adjustBrightness', <String, Object?>{
      'delta': delta,
    });
  }

  @override
  Future<void> adjustVolume(double delta) {
    if (!Platform.isAndroid) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>('adjustVolume', <String, Object?>{
      'delta': delta,
    });
  }

  @override
  Future<void> share(MediaItem item) {
    if (!Platform.isAndroid) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>('share', <String, Object?>{
      'mediaId': item.id,
      'kind': item.kind.name,
      'title': item.title,
      'path': item.path,
    });
  }

  Future<void> _invokeWithoutResult(String method) async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>(method);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    final arguments = call.arguments;
    final values = arguments is Map<Object?, Object?>
        ? arguments.cast<String, Object?>()
        : const <String, Object?>{};
    switch (call.method) {
      case 'completed':
        _events.add(
          PlaybackEvent(
            type: PlaybackEventType.completed,
            mediaId: values['mediaId']?.toString(),
          ),
        );
      case 'error':
        _events.add(
          PlaybackEvent(
            type: PlaybackEventType.error,
            mediaId: values['mediaId']?.toString(),
            message: values['message']?.toString() ?? '播放失败。',
          ),
        );
      case 'videoTextureChanged':
        _setVideoTextureId(_asInt(values['textureId']));
      case 'play':
        _events.add(const PlaybackEvent(type: PlaybackEventType.play));
      case 'pause':
        _events.add(const PlaybackEvent(type: PlaybackEventType.pause));
      case 'toggle':
        _events.add(const PlaybackEvent(type: PlaybackEventType.toggle));
      case 'next':
        _events.add(const PlaybackEvent(type: PlaybackEventType.next));
      case 'previous':
        _events.add(const PlaybackEvent(type: PlaybackEventType.previous));
    }
  }

  void _setVideoTextureId(int? textureId) {
    if (_videoTextureId == textureId) {
      return;
    }
    _videoTextureId = textureId;
    _events.add(
      PlaybackEvent(
        type: PlaybackEventType.videoTextureChanged,
        videoTextureId: textureId,
      ),
    );
  }

  int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is double) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}
