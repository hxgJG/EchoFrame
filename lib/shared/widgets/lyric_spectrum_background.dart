import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../app/spectrum_palette.dart';
import '../../core/models/lumio_settings.dart';
import '../../platform/playback/audio_spectrum_controller.dart';

class LyricSpectrumBackground extends StatefulWidget {
  const LyricSpectrumBackground(
      {super.key,
      required this.controller,
      required this.enabled,
      this.colorStyle = SpectrumColorStyle.level});
  final AudioSpectrumController controller;
  final bool enabled;
  final SpectrumColorStyle colorStyle;

  @override
  State<LyricSpectrumBackground> createState() =>
      _LyricSpectrumBackgroundState();
}

class _LyricSpectrumBackgroundState extends State<LyricSpectrumBackground> {
  final _frame = ValueNotifier<List<double>>(List.filled(24, 0));
  List<double> _target = List.filled(24, 0);
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_receive);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visibility();
  }

  @override
  void didUpdateWidget(covariant LyricSpectrumBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visibility();
  }

  void _visibility() {
    _visible = widget.enabled &&
        TickerMode.of(context) &&
        !MediaQuery.disableAnimationsOf(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    widget.controller.setVisible(this, _visible);
    if (!_visible) {
      _timer?.cancel();
      _timer = null;
      _target = List.filled(24, 0);
      _frame.value = List.filled(24, 0);
    } else {
      _receive();
    }
  }

  void _receive() {
    if (!_visible) return;
    final bands = widget.controller.value;
    _target = bands.length == 24 ? bands : List.filled(24, 0);
    _timer ??= Timer.periodic(const Duration(milliseconds: 34), (_) {
      var moving = false;
      final next = List<double>.generate(24, (i) {
        final old = _frame.value[i];
        final delta = _target[i] - old;
        if (delta.abs() < 0.003) return _target[i];
        moving = true;
        return old + delta * (delta > 0 ? 0.55 : 0.24);
      });
      _frame.value = next;
      if (!moving) {
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_receive);
    widget.controller.setVisible(this, false);
    _timer?.cancel();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
            child: CustomPaint(
          painter: _SpectrumPainter(_frame, widget.colorStyle),
          child: const SizedBox.expand(),
        )),
      );
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(this.frame, this.colorStyle) : super(repaint: frame);
  final ValueNotifier<List<double>> frame;
  final SpectrumColorStyle colorStyle;
  Size? _shaderSize;
  Shader? _paletteShader;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || size.width <= 32) return;
    final step = (size.width - 24) / 24;
    final width = math.min(10.0, step * 0.52);
    final baseline = size.height - 12;
    final maximumHeight = math.min(size.height * 0.68, 220.0);
    final palette = SpectrumPalette.preset(colorStyle);
    if (_shaderSize != size) {
      // The classic scale stays fixed to the full height, not each moving bar.
      _paletteShader = palette.gradient.createShader(Rect.fromLTWH(
          12, baseline - maximumHeight, size.width - 24, maximumHeight));
      _shaderSize = size;
    }
    final paint = Paint();
    for (var i = 0; i < 24; i++) {
      final level = frame.value[i];
      if (level < 0.005) continue;
      final height = maximumHeight * level;
      final x = 12 + step * (i + 0.5);
      // Keep the middle calm, where lyrics carry the strongest contrast.
      final edge = ((i - 11.5).abs() / 11.5);
      paint.shader = _paletteShader;
      paint.color = Colors.white.withValues(alpha: 0.12 + edge * 0.06);
      canvas.drawRRect(
          RRect.fromRectAndCorners(
              Rect.fromLTWH(x - width / 2, baseline - height, width, height),
              topLeft: Radius.circular(math.min(width, height) / 2),
              topRight: Radius.circular(math.min(width, height) / 2)),
          paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) =>
      colorStyle != oldDelegate.colorStyle;
}
