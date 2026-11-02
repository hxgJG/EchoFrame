import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models/lumio_settings.dart';

extension SpectrumColorStyleLabel on SpectrumColorStyle {
  String get label => switch (this) {
        SpectrumColorStyle.level => '电平七彩（推荐）',
        SpectrumColorStyle.classic => '经典绿黄红',
        SpectrumColorStyle.rainbow => '彩虹分层',
        SpectrumColorStyle.ocean => '冰蓝分层',
        SpectrumColorStyle.neon => '紫粉分层',
        SpectrumColorStyle.fire => '烈焰分层',
        SpectrumColorStyle.aurora => '极光分层',
      };
}

class SpectrumPalette {
  SpectrumPalette._(this.swatches, this.colors, this.stops)
      : desktopColors =
            List<int>.unmodifiable(colors.map((color) => color.toARGB32()));

  // Analyzer values are linear PCM magnitudes, not logarithmic heights.
  // Duplicate stops make fixed dBFS thresholds into discrete color regions.
  factory SpectrumPalette._bands(
      List<Color> colors, List<double> thresholdsDb) {
    assert(colors.length == thresholdsDb.length + 1);
    final boundaries = [
      0.0,
      ...thresholdsDb.map((db) => math.pow(10, db / 20).toDouble()),
      1.0,
    ];
    return SpectrumPalette._(
      colors,
      List<Color>.unmodifiable([
        for (final color in colors) ...[color, color],
      ]),
      List<double>.unmodifiable([
        for (var i = 0; i < colors.length; i++) ...[
          boundaries[i],
          boundaries[i + 1]
        ],
      ]),
    );
  }

  final List<Color> swatches;
  final List<Color> colors;
  final List<double> stops;
  final List<int> desktopColors;

  LinearGradient get gradient => LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: colors,
        stops: stops,
      );

  // Reuse the native color arrays so unchanged appearance snapshots compare equal.
  static final _presets = <SpectrumColorStyle, SpectrumPalette>{
    SpectrumColorStyle.level: SpectrumPalette._bands(const [
      Color(0xFF587FE8),
      Color(0xFF3DC7DC),
      Color(0xFF39C78B),
      Color(0xFF9ACD4C),
      Color(0xFFF0CF4D),
      Color(0xFFF39445),
      Color(0xFFEF625C),
    ], const [
      -36,
      -24,
      -18,
      -12,
      -6,
      -3
    ]),
    SpectrumColorStyle.classic: SpectrumPalette._bands(const [
      Color(0xFF36C978),
      Color(0xFF9ACD4C),
      Color(0xFFF2CD45),
      Color(0xFFF39445),
      Color(0xFFF36B5C),
    ], const [
      -24,
      -12,
      -6,
      -3
    ]),
    SpectrumColorStyle.rainbow: SpectrumPalette._bands(const [
      Color(0xFF8275E8),
      Color(0xFF6287F5),
      Color(0xFF43C9DD),
      Color(0xFF4BCB8A),
      Color(0xFFF1D357),
      Color(0xFFF39A58),
      Color(0xFFE875AF),
    ], const [
      -36,
      -24,
      -18,
      -12,
      -6,
      -3
    ]),
    SpectrumColorStyle.ocean: SpectrumPalette._bands(const [
      Color(0xFF5268CC),
      Color(0xFF4C91E3),
      Color(0xFF48BDE8),
      Color(0xFF45D6C1),
      Color(0xFFA3EEE5),
    ], const [
      -30,
      -18,
      -9,
      -3
    ]),
    SpectrumColorStyle.neon: SpectrumPalette._bands(const [
      Color(0xFF7767CD),
      Color(0xFF9C71DC),
      Color(0xFFBF79DF),
      Color(0xFFDF7ABF),
      Color(0xFFFFA3B0),
    ], const [
      -30,
      -18,
      -9,
      -3
    ]),
    SpectrumColorStyle.fire: SpectrumPalette._bands(const [
      Color(0xFFC58839),
      Color(0xFFF0C450),
      Color(0xFFF5A449),
      Color(0xFFEF7952),
      Color(0xFFE85757),
    ], const [
      -30,
      -18,
      -9,
      -3
    ]),
    SpectrumColorStyle.aurora: SpectrumPalette._bands(const [
      Color(0xFF6476CE),
      Color(0xFF5DAABF),
      Color(0xFF49C7B4),
      Color(0xFF90D995),
      Color(0xFFE6DB80),
    ], const [
      -30,
      -18,
      -9,
      -3
    ]),
  };

  static SpectrumPalette preset(SpectrumColorStyle style) => _presets[style]!;
}
