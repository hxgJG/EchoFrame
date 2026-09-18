import 'package:flutter/material.dart';

/// 品牌语义色与 Material 组件色分离，页面通过 ThemeExtension 取色。
@immutable
class LumioMediaColors extends ThemeExtension<LumioMediaColors> {
  const LumioMediaColors({
    required this.audio,
    required this.video,
    required this.audioContainer,
    required this.videoContainer,
    required this.onContainer,
  });

  final Color audio;
  final Color video;
  final Color audioContainer;
  final Color videoContainer;
  final Color onContainer;

  @override
  LumioMediaColors copyWith(
          {Color? audio,
          Color? video,
          Color? audioContainer,
          Color? videoContainer,
          Color? onContainer}) =>
      LumioMediaColors(
        audio: audio ?? this.audio,
        video: video ?? this.video,
        audioContainer: audioContainer ?? this.audioContainer,
        videoContainer: videoContainer ?? this.videoContainer,
        onContainer: onContainer ?? this.onContainer,
      );

  @override
  LumioMediaColors lerp(covariant LumioMediaColors? other, double t) {
    if (other == null) return this;
    return LumioMediaColors(
      audio: Color.lerp(audio, other.audio, t)!,
      video: Color.lerp(video, other.video, t)!,
      audioContainer: Color.lerp(audioContainer, other.audioContainer, t)!,
      videoContainer: Color.lerp(videoContainer, other.videoContainer, t)!,
      onContainer: Color.lerp(onContainer, other.onContainer, t)!,
    );
  }
}

@immutable
class LumioThemeDefinition {
  const LumioThemeDefinition(
      {required this.id,
      required this.label,
      required this.light,
      required this.dark,
      required this.lightMedia,
      required this.darkMedia});

  final String id;
  final String label;
  final ColorScheme light;
  final ColorScheme dark;
  final LumioMediaColors lightMedia;
  final LumioMediaColors darkMedia;
}

/// 新方案只需注册明暗色板；稳定 id 用于存储，未知 id 回退默认方案。
class LumioThemeCatalog {
  static const defaultId = 'mint';
  static final List<LumioThemeDefinition> themes = List.unmodifiable([
    LumioThemeDefinition(
      id: defaultId,
      label: '薄荷 · 日与夜',
      light: ColorScheme.fromSeed(
        seedColor: const Color(0xFF276B5B),
        brightness: Brightness.light,
        secondary: const Color(0xFF9B5141),
        onSecondary: Colors.white,
        secondaryContainer: const Color(0xFFFBE3DA),
        onSecondaryContainer: const Color(0xFF522D25),
        tertiary: const Color(0xFF326C66),
        surface: const Color(0xFFFCFAF5),
        onSurface: const Color(0xFF1D302A),
        onSurfaceVariant: const Color(0xFF50645B),
        surfaceContainerLowest: const Color(0xFFFFFEFA),
        surfaceContainerLow: const Color(0xFFF2F6EF),
        surfaceContainer: const Color(0xFFEBF1E9),
        surfaceContainerHigh: const Color(0xFFE4ECE3),
        surfaceContainerHighest: const Color(0xFFDDE6DC),
        outline: const Color(0xFF71877C),
        outlineVariant: const Color(0xFFC9D8CD),
      ),
      dark: ColorScheme.fromSeed(
        seedColor: const Color(0xFF9ADAC6),
        brightness: Brightness.dark,
        secondary: const Color(0xFFF3BCAD),
        onSecondary: const Color(0xFF42271F),
        secondaryContainer: const Color(0xFF443532),
        onSecondaryContainer: const Color(0xFFFBE3DA),
        tertiary: const Color(0xFF91CEC2),
        surface: const Color(0xFF16191C),
        onSurface: const Color(0xFFE7ECE9),
        onSurfaceVariant: const Color(0xFFADB9B3),
        surfaceContainerLowest: const Color(0xFF101214),
        surfaceContainerLow: const Color(0xFF1D2125),
        surfaceContainer: const Color(0xFF23282C),
        surfaceContainerHigh: const Color(0xFF2B3136),
        surfaceContainerHighest: const Color(0xFF353D42),
        outline: const Color(0xFF81908A),
        outlineVariant: const Color(0xFF3D4845),
      ),
      lightMedia: const LumioMediaColors(
        audio: Color(0xFF276B5B),
        video: Color(0xFF9B5141),
        audioContainer: Color(0xFFC5F3E4),
        videoContainer: Color(0xFFFBE3DA),
        onContainer: Color(0xFF1D302A),
      ),
      darkMedia: const LumioMediaColors(
        audio: Color(0xFF9ADAC6),
        video: Color(0xFFF3BCAD),
        audioContainer: Color(0xFF9ADAC6),
        videoContainer: Color(0xFFF3BCAD),
        onContainer: Color(0xFF16191C),
      ),
    ),
  ]);

  static LumioThemeDefinition resolve(String? id) => themes.firstWhere(
        (theme) => theme.id == id,
        orElse: () => themes.first,
      );
}
