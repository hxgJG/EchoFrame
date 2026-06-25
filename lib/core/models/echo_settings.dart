import 'package:flutter/material.dart';

import 'media_item.dart';

enum EqualizerPreset { off, bassBoost, vocal, rock, classical, custom }

enum SubtitleTextColor { white, yellow, cyan }

enum SubtitlePosition { low, middle, high }

enum VideoScaleMode { fit, stretch, crop }

class EchoSettings {
  const EchoSettings({
    this.themeMode = ThemeMode.system,
    this.allowOnlineEnhancement = false,
    this.defaultPlaybackView = PlaybackView.artwork,
    this.dynamicColor = false,
    this.minimumAudioDuration = const Duration(seconds: 45),
    this.includedFolders = const <String>[],
    this.excludedFolders = const <String>[],
    this.crossfadeSeconds = 0,
    this.lyricOffset = Duration.zero,
    this.equalizerPreset = EqualizerPreset.off,
    this.customEqualizerGains = const <double>[0, 0, 0, 0, 0],
    this.subtitleFontSize = 16,
    this.subtitleTextColor = SubtitleTextColor.white,
    this.subtitlePosition = SubtitlePosition.low,
    this.videoScaleMode = VideoScaleMode.fit,
  });

  factory EchoSettings.fromJson(Map<String, Object?> json) {
    return EchoSettings(
      themeMode: _themeModeFromName(json['themeMode']?.toString()),
      allowOnlineEnhancement: json['allowOnlineEnhancement'] == true,
      defaultPlaybackView: _playbackViewFromName(
        json['defaultPlaybackView']?.toString(),
      ),
      dynamicColor: json['dynamicColor'] == true,
      minimumAudioDuration: Duration(
        milliseconds: _asInt(json['minimumAudioDurationMs'], 45000),
      ),
      includedFolders: _asStringList(json['includedFolders']),
      excludedFolders: _asStringList(json['excludedFolders']),
      crossfadeSeconds: _asInt(json['crossfadeSeconds']),
      lyricOffset: Duration(milliseconds: _asInt(json['lyricOffsetMs'])),
      equalizerPreset: _equalizerPresetFromName(
        json['equalizerPreset']?.toString(),
      ),
      customEqualizerGains: _asDoubleList(
        json['customEqualizerGains'],
        fallbackLength: 5,
      ),
      subtitleFontSize: _asDouble(json['subtitleFontSize'], 16).clamp(12, 28),
      subtitleTextColor: _subtitleTextColorFromName(
        json['subtitleTextColor']?.toString(),
      ),
      subtitlePosition: _subtitlePositionFromName(
        json['subtitlePosition']?.toString(),
      ),
      videoScaleMode: _videoScaleModeFromName(
        json['videoScaleMode']?.toString(),
      ),
    );
  }

  final ThemeMode themeMode;
  final bool allowOnlineEnhancement;
  final PlaybackView defaultPlaybackView;
  final bool dynamicColor;
  final Duration minimumAudioDuration;
  final List<String> includedFolders;
  final List<String> excludedFolders;
  final int crossfadeSeconds;
  final Duration lyricOffset;
  final EqualizerPreset equalizerPreset;
  final List<double> customEqualizerGains;
  final double subtitleFontSize;
  final SubtitleTextColor subtitleTextColor;
  final SubtitlePosition subtitlePosition;
  final VideoScaleMode videoScaleMode;

  EchoSettings copyWith({
    ThemeMode? themeMode,
    bool? allowOnlineEnhancement,
    PlaybackView? defaultPlaybackView,
    bool? dynamicColor,
    Duration? minimumAudioDuration,
    List<String>? includedFolders,
    List<String>? excludedFolders,
    int? crossfadeSeconds,
    Duration? lyricOffset,
    EqualizerPreset? equalizerPreset,
    List<double>? customEqualizerGains,
    double? subtitleFontSize,
    SubtitleTextColor? subtitleTextColor,
    SubtitlePosition? subtitlePosition,
    VideoScaleMode? videoScaleMode,
  }) {
    return EchoSettings(
      themeMode: themeMode ?? this.themeMode,
      allowOnlineEnhancement:
          allowOnlineEnhancement ?? this.allowOnlineEnhancement,
      defaultPlaybackView: defaultPlaybackView ?? this.defaultPlaybackView,
      dynamicColor: dynamicColor ?? this.dynamicColor,
      minimumAudioDuration: minimumAudioDuration ?? this.minimumAudioDuration,
      includedFolders: includedFolders ?? this.includedFolders,
      excludedFolders: excludedFolders ?? this.excludedFolders,
      crossfadeSeconds: crossfadeSeconds ?? this.crossfadeSeconds,
      lyricOffset: lyricOffset ?? this.lyricOffset,
      equalizerPreset: equalizerPreset ?? this.equalizerPreset,
      customEqualizerGains: customEqualizerGains ?? this.customEqualizerGains,
      subtitleFontSize: subtitleFontSize ?? this.subtitleFontSize,
      subtitleTextColor: subtitleTextColor ?? this.subtitleTextColor,
      subtitlePosition: subtitlePosition ?? this.subtitlePosition,
      videoScaleMode: videoScaleMode ?? this.videoScaleMode,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'themeMode': themeMode.name,
      'allowOnlineEnhancement': allowOnlineEnhancement,
      'defaultPlaybackView': defaultPlaybackView.name,
      'dynamicColor': dynamicColor,
      'minimumAudioDurationMs': minimumAudioDuration.inMilliseconds,
      'includedFolders': includedFolders,
      'excludedFolders': excludedFolders,
      'crossfadeSeconds': crossfadeSeconds,
      'lyricOffsetMs': lyricOffset.inMilliseconds,
      'equalizerPreset': equalizerPreset.name,
      'customEqualizerGains': customEqualizerGains,
      'subtitleFontSize': subtitleFontSize,
      'subtitleTextColor': subtitleTextColor.name,
      'subtitlePosition': subtitlePosition.name,
      'videoScaleMode': videoScaleMode.name,
    };
  }
}

ThemeMode _themeModeFromName(String? name) {
  return ThemeMode.values.firstWhere(
    (value) => value.name == name,
    orElse: () => ThemeMode.system,
  );
}

PlaybackView _playbackViewFromName(String? name) {
  return PlaybackView.values.firstWhere(
    (value) => value.name == name && value != PlaybackView.video,
    orElse: () => PlaybackView.artwork,
  );
}

EqualizerPreset _equalizerPresetFromName(String? name) {
  return EqualizerPreset.values.firstWhere(
    (value) => value.name == name,
    orElse: () => EqualizerPreset.off,
  );
}

SubtitleTextColor _subtitleTextColorFromName(String? name) {
  return SubtitleTextColor.values.firstWhere(
    (value) => value.name == name,
    orElse: () => SubtitleTextColor.white,
  );
}

SubtitlePosition _subtitlePositionFromName(String? name) {
  return SubtitlePosition.values.firstWhere(
    (value) => value.name == name,
    orElse: () => SubtitlePosition.low,
  );
}

VideoScaleMode _videoScaleModeFromName(String? name) {
  return VideoScaleMode.values.firstWhere(
    (value) => value.name == name,
    orElse: () => VideoScaleMode.fit,
  );
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is double) {
    return value;
  }
  if (value is int) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

List<String> _asStringList(Object? value) {
  if (value is! List<Object?>) {
    return const <String>[];
  }
  return value.map((item) => item.toString()).toList(growable: false);
}

List<double> _asDoubleList(Object? value, {required int fallbackLength}) {
  if (value is! List<Object?>) {
    return List<double>.filled(fallbackLength, 0, growable: false);
  }
  final values = value
      .map((item) => _asDouble(item).clamp(-10, 10).toDouble())
      .toList(growable: false);
  if (values.length >= fallbackLength) {
    return values.take(fallbackLength).toList(growable: false);
  }
  return <double>[
    ...values,
    ...List<double>.filled(fallbackLength - values.length, 0),
  ];
}
