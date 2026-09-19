import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'media_tile.dart';
import 'mini_player.dart';

/// 手机端播放条空闲后收起，悬浮球只在应用内显示，不申请系统悬浮权限。
class MobilePlayerShell extends StatefulWidget {
  const MobilePlayerShell(
      {super.key,
      required this.state,
      required this.body,
      required this.navigationBar,
      required this.onOpenNowPlaying});

  final LumioAppState state;
  final Widget body;
  final Widget navigationBar;
  final VoidCallback onOpenNowPlaying;

  @override
  State<MobilePlayerShell> createState() => _MobilePlayerShellState();
}

class _MobilePlayerShellState extends State<MobilePlayerShell>
    with WidgetsBindingObserver {
  static const _diameter = 80.0;
  static const _margin = 8.0;
  Timer? _timer;
  bool _collapsed = false;
  bool _right = true;
  bool _foreground = true;
  double _verticalFraction = 0.85;
  Offset? _dragPosition;
  String? _mediaId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mediaId = widget.state.currentItem?.id;
    widget.state.addListener(_mediaChanged);
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant MobilePlayerShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_mediaChanged);
      widget.state.addListener(_mediaChanged);
      _mediaChanged();
    }
  }

  void _mediaChanged() {
    final id = widget.state.currentItem?.id;
    if (id == _mediaId) return;
    final wasEmpty = _mediaId == null;
    _mediaId = id;
    if (wasEmpty || id == null) setState(() => _collapsed = false);
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    if (_collapsed || !_foreground || widget.state.currentItem == null) return;
    _timer = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        _restartTimer();
        return;
      }
      setState(() => _collapsed = true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _restartTimer();
  }

  void _expand() {
    setState(() => _collapsed = false);
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.state.removeListener(_mediaChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: Listener(
        onPointerDown: (_) => _timer?.cancel(),
        onPointerUp: (_) => _restartTimer(),
        onPointerCancel: (_) => _restartTimer(),
        child: widget.navigationBar,
      ),
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(builder: (context, constraints) {
          final size = math.min(
              _diameter, math.min(constraints.maxWidth, constraints.maxHeight));
          final maxX = math.max(0.0, constraints.maxWidth - size - _margin);
          final maxY = math.max(0.0, constraints.maxHeight - size - _margin);
          final minX = math.min(_margin, maxX);
          final minY = math.min(_margin, maxY);
          Offset clamp(Offset p) =>
              Offset(p.dx.clamp(minX, maxX), p.dy.clamp(minY, maxY));
          final position = clamp(_dragPosition ??
              Offset(_right ? maxX : minX,
                  minY + (maxY - minY) * _verticalFraction));
          void finishDrag() {
            setState(() {
              _right = position.dx + size / 2 >= constraints.maxWidth / 2;
              _verticalFraction =
                  maxY > minY ? (position.dy - minY) / (maxY - minY) : 0;
              _dragPosition = null;
            });
          }

          return Listener(
            onPointerDown: (_) => _timer?.cancel(),
            onPointerUp: (_) => _restartTimer(),
            onPointerCancel: (_) => _restartTimer(),
            child: Stack(children: [
              Column(children: [
                Expanded(child: widget.body),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  alignment: Alignment.bottomCenter,
                  child: _collapsed
                      ? const SizedBox.shrink()
                      : MiniPlayer(
                          state: widget.state,
                          onExpand: widget.onOpenNowPlaying),
                ),
              ]),
              if (_collapsed && widget.state.currentItem != null && size > 0)
                AnimatedPositioned(
                  duration: _dragPosition == null
                      ? const Duration(milliseconds: 180)
                      : Duration.zero,
                  left: position.dx,
                  top: position.dy,
                  width: size,
                  height: size,
                  child: GestureDetector(
                    onPanStart: (_) => setState(() => _dragPosition = position),
                    onPanUpdate: (event) => setState(() {
                      _dragPosition =
                          clamp((_dragPosition ?? position) + event.delta);
                    }),
                    onPanEnd: (_) => finishDrag(),
                    onPanCancel: finishDrag,
                    onLongPress: _expand,
                    child: _FloatingDisc(
                        state: widget.state,
                        onOpen: widget.onOpenNowPlaying,
                        onExpand: _expand),
                  ),
                ),
            ]),
          );
        }),
      ),
    );
  }
}

class _FloatingDisc extends StatefulWidget {
  const _FloatingDisc(
      {required this.state, required this.onOpen, required this.onExpand});
  final LumioAppState state;
  final VoidCallback onOpen;
  final VoidCallback onExpand;

  @override
  State<_FloatingDisc> createState() => _FloatingDiscState();
}

class _FloatingDiscState extends State<_FloatingDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation =
      AnimationController(vsync: this, duration: const Duration(seconds: 16));

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.state.currentItem!;
    final scheme = Theme.of(context).colorScheme;
    final animate =
        widget.state.isPlaying && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_rotation.isAnimating) _rotation.repeat();
    if (!animate && _rotation.isAnimating) _rotation.stop();
    final duration = item.duration.inMilliseconds;
    final progress = duration > 0
        ? (widget.state.position.inMilliseconds / duration).clamp(0.0, 1.0)
        : 0.0;
    return Semantics(
      label: '悬浮播放器，${item.title}，长按展开播放条',
      customSemanticsActions: {
        const CustomSemanticsAction(label: '展开播放条'): widget.onExpand
      },
      child: Material(
        elevation: 6,
        shape: const CircleBorder(),
        color: scheme.surface,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onOpen,
          child: Stack(alignment: Alignment.center, children: [
            Positioned.fill(
                child: Padding(
              padding: const EdgeInsets.all(5),
              child: ClipOval(
                  child: RotationTransition(
                      turns: _rotation,
                      child: MediaArtwork(item: item, size: 70))),
            )),
            Positioned.fill(
                child: IgnorePointer(
                    child: Padding(
              padding: const EdgeInsets.all(2),
              child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 3,
                  backgroundColor: scheme.outlineVariant,
                  color: LumioTheme.mediaColor(item.kind, context)),
            ))),
            IconButton.filled(
              tooltip: widget.state.isPlaying ? '暂停' : '播放',
              onPressed: widget.state.togglePlaying,
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.6),
                foregroundColor: Colors.white,
                minimumSize: const Size(40, 40),
                padding: const EdgeInsets.all(8),
              ),
              iconSize: 22,
              icon: Icon(widget.state.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded),
            ),
          ]),
        ),
      ),
    );
  }
}
