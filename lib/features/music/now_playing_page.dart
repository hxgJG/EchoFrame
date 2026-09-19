import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../core/models/lumio_settings.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/playback_page_gesture.dart';
import '../../platform/media_library/lyrics_import.dart';
import '../../shared/widgets/media_tile.dart';
import '../../shared/widgets/lyrics_export_action.dart';
import 'lyric_calibration_dialog.dart';

class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key, required this.state});

  final LumioAppState state;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  Offset _dragDelta = Offset.zero;
  double _dismissOverscroll = 0;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final item = state.currentItem;
    final scheme = Theme.of(context).colorScheme;
    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('暂无播放内容')),
      );
    }

    final isVideo = item.kind == MediaKind.video;
    if (isVideo && state.isInPictureInPicture) {
      final textureId = state.videoTextureId;
      return Scaffold(
        backgroundColor: Colors.black,
        body: textureId == null
            ? const Center(
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.white70,
                  size: 64,
                ),
              )
            : _VideoTextureView(
                textureId: textureId,
                scaleMode: VideoScaleMode.fit,
                aspectRatio: _videoAspectRatio(item),
              ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '收起',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        title: Text(isVideo ? '视频播放' : '正在播放'),
        actions: <Widget>[
          if (defaultTargetPlatform == TargetPlatform.macOS &&
              !isVideo &&
              item.lyrics.isNotEmpty)
            TextButton.icon(
              onPressed: () => showLyricCalibration(context, state),
              icon: const Icon(Icons.sync_alt_rounded),
              label: const Text('校准歌词'),
            ),
          IconButton(
            tooltip: item.isFavorite ? '取消收藏' : '收藏',
            onPressed: () => state.toggleFavorite(item.id),
            icon: Icon(
              item.isFavorite ? Icons.favorite_rounded : Icons.favorite_border,
              color: item.isFavorite ? scheme.secondary : null,
            ),
          ),
          IconButton(
            tooltip: '更多',
            onPressed: () => _showMoreActions(context, state),
            icon: const Icon(Icons.more_vert_rounded),
          ),
        ],
      ),
      body: defaultTargetPlatform == TargetPlatform.macOS && !isVideo
          ? _MacMusicDetails(state: state, item: item)
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: isVideo
                  ? null
                  : (details) {
                      _dragDelta += details.delta;
                    },
              onPanEnd: isVideo
                  ? null
                  : (_) {
                      final action = resolvePlaybackPageGesture(
                        deltaX: _dragDelta.dx,
                        deltaY: _dragDelta.dy,
                      );
                      _dragDelta = Offset.zero;
                      switch (action) {
                        case PlaybackPageGestureAction.none:
                          break;
                        case PlaybackPageGestureAction.toggleView:
                          state.togglePlaybackView();
                        case PlaybackPageGestureAction.dismiss:
                          Navigator.of(context).maybePop();
                      }
                    },
              onPanCancel: () {
                _dragDelta = Offset.zero;
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is OverscrollNotification &&
                      notification.overscroll < 0) {
                    _dismissOverscroll -= notification.overscroll;
                    if (_dismissOverscroll >= 72) {
                      _dismissOverscroll = 0;
                      Navigator.of(context).maybePop();
                    }
                  } else if (notification is ScrollEndNotification) {
                    _dismissOverscroll = 0;
                  }
                  return false;
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
                  children: <Widget>[
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: isVideo || state.playbackView == PlaybackView.video
                          ? _VideoStage(
                              state: state,
                              item: item,
                              textureId: state.videoTextureId,
                              subtitleText: state.currentSubtitleText,
                            )
                          : state.playbackView == PlaybackView.lyrics
                              ? _LyricsStage(state: state, item: item)
                              : _ArtworkStage(item: item),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      )
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isVideo ? item.subtitle : item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 24),
                    _ProgressControl(state: state, item: item),
                    const SizedBox(height: 16),
                    _PrimaryControls(state: state),
                    const SizedBox(height: 18),
                    _ToolRow(state: state, item: item),
                  ],
                ),
              ),
            ),
    );
  }
}

class _MacMusicDetails extends StatelessWidget {
  const _MacMusicDetails({required this.state, required this.item});

  final LumioAppState state;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 桌面窗口同时限制舞台的宽高，避免正方形封面把播放控制挤出视口。
        final stageHeight = (constraints.maxHeight - 64).clamp(180.0, 420.0);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: SizedBox(
                      height: stageHeight,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: state.playbackView == PlaybackView.lyrics
                              ? _LyricsStage(
                                  state: state,
                                  item: item,
                                  height: stageHeight,
                                )
                              : _ArtworkStage(item: item),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 32),
                        _ProgressControl(state: state, item: item),
                        const SizedBox(height: 16),
                        _PrimaryControls(state: state),
                        const SizedBox(height: 18),
                        _ToolRow(state: state, item: item),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ArtworkStage extends StatelessWidget {
  const _ArtworkStage({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Center(
        child: SizedBox.expand(child: MediaArtwork(item: item, size: 260)),
      ),
    );
  }
}

class _LyricsStage extends StatefulWidget {
  const _LyricsStage(
      {required this.state, required this.item, this.height = 320});

  final LumioAppState state;
  final MediaItem item;
  final double height;

  @override
  State<_LyricsStage> createState() => _LyricsStageState();
}

class _LyricsStageState extends State<_LyricsStage> {
  static const double _lineExtent = 52;
  final ScrollController _scrollController = ScrollController();
  late int _lastLyricIndex;

  @override
  void initState() {
    super.initState();
    _lastLyricIndex = widget.state.currentLyricIndex;
    widget.state.attachLyricView();
    widget.state.lyricChanges.addListener(_lyricTick);
    _scheduleCurrentLine();
  }

  void _lyricTick() {
    if (!mounted) return;
    final index = widget.state.currentLyricIndex;
    if (index != _lastLyricIndex) {
      setState(() => _lastLyricIndex = index);
      _scheduleCurrentLine();
    }
  }

  @override
  void didUpdateWidget(covariant _LyricsStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 两个 widget 共享可变的 AppState，必须保存行号快照才能检测进度变化。
    final currentIndex = widget.state.currentLyricIndex;
    if (_lastLyricIndex != currentIndex ||
        oldWidget.item.id != widget.item.id ||
        oldWidget.item.lyrics != widget.item.lyrics ||
        oldWidget.height != widget.height) {
      _lastLyricIndex = currentIndex;
      _scheduleCurrentLine();
    }
  }

  @override
  void dispose() {
    widget.state.lyricChanges.removeListener(_lyricTick);
    widget.state.detachLyricView();
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleCurrentLine() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final currentIndex = widget.state.currentLyricIndex;
      final index = currentIndex < 0 ? 0 : currentIndex;
      if (index >= widget.item.lyrics.length || !_scrollController.hasClients) {
        return;
      }
      final target = (index * _lineExtent -
              _scrollController.position.viewportDimension / 2 +
              _lineExtent / 2)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audioColor = LumioTheme.audioColor(context);
    final textTheme = Theme.of(context).textTheme;
    final lines = widget.item.lyrics;
    final currentIndex = widget.state.currentLyricIndex;
    return Container(
      key: const ValueKey<String>('lyrics'),
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: lines.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '未找到本地歌词',
                    style: textTheme.titleMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () => _importLyrics(
                      context,
                      widget.state,
                      widget.item,
                    ),
                    icon: const Icon(Icons.upload_file_rounded),
                    label: const Text('导入 LRC 歌词'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              controller: _scrollController,
              itemExtent: _lineExtent,
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final isCurrent = index == currentIndex;
                final distance = (index - currentIndex).abs();
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Text(
                    lines[index].text,
                    textAlign: TextAlign.center,
                    style: (isCurrent
                            ? textTheme.titleLarge
                            : textTheme.titleMedium)
                        ?.copyWith(
                      color: isCurrent
                          ? audioColor
                          : scheme.onSurface.withValues(
                              alpha: distance <= 1 ? 0.58 : 0.32,
                            ),
                      fontWeight: isCurrent ? FontWeight.w900 : FontWeight.w700,
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _VideoStage extends StatelessWidget {
  const _VideoStage({
    required this.state,
    required this.item,
    required this.textureId,
    required this.subtitleText,
  });

  final LumioAppState state;
  final MediaItem item;
  final int? textureId;
  final String subtitleText;

  @override
  Widget build(BuildContext context) {
    final videoColor = LumioTheme.videoColor(context);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        key: const ValueKey<String>('video'),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (textureId == null) ...<Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      videoColor.withValues(alpha: 0.8),
                      Colors.black,
                    ],
                  ),
                ),
              ),
              Center(
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.white.withValues(alpha: 0.9),
                  size: 70,
                ),
              ),
            ] else
              _VideoTextureView(
                textureId: textureId!,
                scaleMode: state.settings.videoScaleMode,
                aspectRatio: _videoAspectRatio(item),
              ),
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.48),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${item.formatLabel ?? '视频'} • ${item.resolution ?? '自动'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton.filledTonal(
                tooltip: '全屏',
                onPressed: textureId == null
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => AnimatedBuilder(
                              animation: state,
                              builder: (context, _) =>
                                  _FullscreenVideoPage(state: state),
                            ),
                          ),
                        ),
                icon: const Icon(Icons.fullscreen_rounded),
              ),
            ),
            if (subtitleText.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: _subtitleBottom(state.settings.subtitlePosition, false),
                child: _SubtitleOverlayText(
                  text: subtitleText,
                  settings: state.settings,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenVideoPage extends StatefulWidget {
  const _FullscreenVideoPage({required this.state});

  final LumioAppState state;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  static const Duration _controlsHideDelay = Duration(seconds: 3);

  double _horizontalDrag = 0;
  double _verticalDrag = 0;
  bool _verticalDragStartedOnLeft = true;
  bool _controlsVisible = true;
  late bool _lastIsPlaying;
  Timer? _controlsHideTimer;

  @override
  void initState() {
    super.initState();
    _lastIsPlaying = widget.state.isPlaying;
    widget.state.addListener(_handlePlaybackStateChanged);
    if (_lastIsPlaying) {
      _scheduleControlsHide();
    }
    if (widget.state.platformCapabilities.supportsBrightnessAdjustment) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    widget.state.removeListener(_handlePlaybackStateChanged);
    if (widget.state.platformCapabilities.supportsBrightnessAdjustment) {
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _handlePlaybackStateChanged() {
    final isPlaying = widget.state.isPlaying;
    if (_lastIsPlaying == isPlaying) {
      return;
    }
    _lastIsPlaying = isPlaying;
    if (isPlaying) {
      _showControls();
    } else {
      _showControls(scheduleHide: false);
    }
  }

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    if (!widget.state.isPlaying) {
      return;
    }
    _controlsHideTimer = Timer(_controlsHideDelay, () {
      if (!mounted || !widget.state.isPlaying) {
        return;
      }
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls({bool scheduleHide = true}) {
    _controlsHideTimer?.cancel();
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    if (scheduleHide) {
      _scheduleControlsHide();
    }
  }

  void _toggleControls() {
    _controlsHideTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _scheduleControlsHide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final item = state.currentItem;
    final textureId = state.videoTextureId;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: MouseRegion(
          onHover: (_) => _showControls(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onHorizontalDragStart: (_) => _showControls(scheduleHide: false),
            onHorizontalDragUpdate: (details) {
              _horizontalDrag += details.primaryDelta ?? 0;
            },
            onHorizontalDragEnd: (_) {
              final media = state.currentItem;
              if (media != null && _horizontalDrag.abs() >= 24) {
                final deltaMs = _horizontalDrag * 45;
                final nextPosition =
                    state.position + Duration(milliseconds: deltaMs.round());
                state.seekToFraction(
                  media.duration.inMilliseconds == 0
                      ? 0
                      : nextPosition.inMilliseconds /
                          media.duration.inMilliseconds,
                );
              }
              _horizontalDrag = 0;
              _scheduleControlsHide();
            },
            onVerticalDragStart:
                state.platformCapabilities.supportsBrightnessAdjustment
                    ? (details) {
                        _verticalDragStartedOnLeft = details.localPosition.dx <
                            MediaQuery.sizeOf(context).width / 2;
                        _verticalDrag = 0;
                      }
                    : null,
            onVerticalDragUpdate:
                state.platformCapabilities.supportsBrightnessAdjustment
                    ? (details) {
                        _verticalDrag += details.primaryDelta ?? 0;
                        if (_verticalDrag.abs() < 20) {
                          return;
                        }
                        final delta = -_verticalDrag / 600;
                        if (_verticalDragStartedOnLeft) {
                          state.adjustBrightness(delta);
                        } else {
                          state.adjustVolume(delta);
                        }
                        _verticalDrag = 0;
                      }
                    : null,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (textureId == null)
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill_rounded,
                      color: Colors.white70,
                      size: 80,
                    ),
                  )
                else
                  _VideoTextureView(
                    textureId: textureId,
                    scaleMode: state.settings.videoScaleMode,
                    aspectRatio: _videoAspectRatio(item),
                  ),
                if (state.currentSubtitleText.isNotEmpty)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: _subtitleBottom(
                          state.settings.subtitlePosition,
                          true,
                        ) -
                        (_controlsVisible ? 0 : 72),
                    child: _SubtitleOverlayText(
                      text: state.currentSubtitleText,
                      settings: state.settings,
                    ),
                  ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: IconButton(
                        tooltip: '退出全屏',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(
                          Icons.fullscreen_exit_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 18,
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: MouseRegion(
                        onEnter: (_) => _showControls(scheduleHide: false),
                        onExit: (_) => _showControls(),
                        child: Listener(
                          onPointerDown: (_) =>
                              _showControls(scheduleHide: false),
                          onPointerUp: (_) => _scheduleControlsHide(),
                          child: item == null
                              ? const SizedBox.shrink()
                              : _FullscreenControlBar(state: state, item: item),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoTextureView extends StatelessWidget {
  const _VideoTextureView({
    required this.textureId,
    required this.scaleMode,
    required this.aspectRatio,
  });

  final int textureId;
  final VideoScaleMode scaleMode;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return FittedBox(
            fit: _videoBoxFit(scaleMode),
            child: SizedBox(
              width: width,
              height: width / aspectRatio,
              child: Texture(textureId: textureId),
            ),
          );
        },
      ),
    );
  }
}

class _SubtitleOverlayText extends StatelessWidget {
  const _SubtitleOverlayText({required this.text, required this.settings});

  final String text;
  final LumioSettings settings;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: _subtitleColor(settings.subtitleTextColor),
        fontSize: settings.subtitleFontSize,
        fontWeight: FontWeight.w800,
        shadows: const <Shadow>[
          Shadow(
            color: Colors.black,
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
    );
  }
}

Color _subtitleColor(SubtitleTextColor color) {
  return switch (color) {
    SubtitleTextColor.white => Colors.white,
    SubtitleTextColor.yellow => const Color(0xFFFFF176),
    SubtitleTextColor.cyan => const Color(0xFF80DEEA),
  };
}

BoxFit _videoBoxFit(VideoScaleMode mode) {
  return switch (mode) {
    VideoScaleMode.fit => BoxFit.contain,
    VideoScaleMode.stretch => BoxFit.fill,
    VideoScaleMode.crop => BoxFit.cover,
  };
}

double _videoAspectRatio(MediaItem? item) {
  final resolution = item?.resolution;
  if (resolution == null || !resolution.contains('x')) {
    return 16 / 9;
  }
  final parts = resolution.split('x');
  if (parts.length != 2) {
    return 16 / 9;
  }
  final width = double.tryParse(parts[0]);
  final height = double.tryParse(parts[1]);
  if (width == null || height == null || width <= 0 || height <= 0) {
    return 16 / 9;
  }
  return width / height;
}

double _subtitleBottom(SubtitlePosition position, bool fullscreen) {
  return switch (position) {
    SubtitlePosition.low => fullscreen ? 116 : 52,
    SubtitlePosition.middle => fullscreen ? 180 : 104,
    SubtitlePosition.high => fullscreen ? 260 : 164,
  };
}

class _FullscreenControlBar extends StatelessWidget {
  const _FullscreenControlBar({required this.state, required this.item});

  final LumioAppState state;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final fraction = item.duration.inMilliseconds == 0
        ? 0.0
        : (state.position.inMilliseconds / item.duration.inMilliseconds)
            .clamp(0, 1)
            .toDouble();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            Row(
              children: <Widget>[
                Text(
                  formatDuration(state.position),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: fraction,
                    onChanged: state.seekToFraction,
                  ),
                ),
                Text(
                  formatDuration(item.duration),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                IconButton(
                  tooltip: '上一个',
                  onPressed: state.previous,
                  icon: const Icon(
                    Icons.skip_previous_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(12),
                  ),
                  onPressed: state.togglePlaying,
                  child: Icon(
                    state.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  tooltip: '下一个',
                  onPressed: state.next,
                  icon: const Icon(
                    Icons.skip_next_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressControl extends StatelessWidget {
  const _ProgressControl({required this.state, required this.item});

  final LumioAppState state;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mediaColor = LumioTheme.mediaColor(item.kind, context);
    final fraction = item.duration.inMilliseconds == 0
        ? 0.0
        : state.position.inMilliseconds / item.duration.inMilliseconds;
    return Column(
      children: <Widget>[
        Slider(
          value: fraction.clamp(0, 1),
          activeColor: mediaColor,
          onChanged: state.seekToFraction,
        ),
        Row(
          children: <Widget>[
            Text(
              formatDuration(state.position),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            Text(
              formatDuration(item.duration),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

class _PrimaryControls extends StatelessWidget {
  const _PrimaryControls({required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = state.currentItem;
    final mediaColor = current == null
        ? scheme.primary
        : LumioTheme.mediaColor(current.kind, context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        IconButton(
          tooltip: '循环模式',
          onPressed: state.cycleRepeatMode,
          icon: Icon(
            state.repeatMode == RepeatMode.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            color: state.repeatMode == RepeatMode.off ? null : mediaColor,
          ),
        ),
        IconButton(
          tooltip: '上一首',
          onPressed: state.previous,
          icon: const Icon(Icons.skip_previous_rounded, size: 34),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: current == null
                ? scheme.brightness == Brightness.light
                    ? scheme.primaryContainer
                    : scheme.primary
                : LumioTheme.mediaContainerColor(current.kind, context),
            foregroundColor: LumioTheme.onMediaColor(context),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            padding: const EdgeInsets.all(18),
          ),
          onPressed: state.togglePlaying,
          child: Icon(
            state.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 36,
          ),
        ),
        IconButton(
          tooltip: '下一首',
          onPressed: state.next,
          icon: const Icon(Icons.skip_next_rounded, size: 34),
        ),
        IconButton(
          tooltip: state.shuffleEnabled ? '关闭随机播放' : '开启随机播放',
          isSelected: state.shuffleEnabled,
          style: IconButton.styleFrom(
            backgroundColor:
                state.shuffleEnabled ? scheme.primaryContainer : null,
            foregroundColor: state.shuffleEnabled ? mediaColor : null,
          ),
          onPressed: state.toggleShuffle,
          icon: Icon(
            Icons.shuffle_rounded,
            color: state.shuffleEnabled ? mediaColor : null,
          ),
        ),
      ],
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.state, required this.item});

  final LumioAppState state;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final isVideo = item.kind == MediaKind.video;
    final mediaColor = LumioTheme.mediaColor(item.kind, context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        IconButton(
          tooltip: '收起',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        if (!isVideo || state.platformCapabilities.supportsPictureInPicture)
          IconButton(
            tooltip: isVideo ? '小窗播放' : '封面/歌词',
            onPressed: isVideo
                ? state.enterPictureInPicture
                : state.togglePlaybackView,
            icon: Icon(
              isVideo
                  ? Icons.picture_in_picture_alt_rounded
                  : Icons.lyrics_rounded,
              color: mediaColor,
            ),
          ),
        IconButton(
          tooltip: item.isFavorite ? '取消收藏' : '收藏',
          onPressed: () => state.toggleFavorite(item.id),
          icon: Icon(
            item.isFavorite ? Icons.favorite_rounded : Icons.favorite_border,
          ),
        ),
        IconButton(
          tooltip: '查看队列',
          onPressed: () {
            Navigator.of(context).maybePop();
            state.selectSection(AppSection.playlists);
          },
          icon: const Icon(Icons.queue_music_rounded),
        ),
        IconButton(
          tooltip: '更多',
          onPressed: () => _showMoreActions(context, state),
          icon: const Icon(Icons.more_horiz_rounded),
        ),
      ],
    );
  }
}

void _showMoreActions(BuildContext context, LumioAppState state) {
  final pageContext = context;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.looks_one_rounded),
              title: const Text('设置 A 点'),
              subtitle: Text('当前位置 ${formatDuration(state.position)}'),
              onTap: () {
                state.setAbLoopStart();
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.looks_two_rounded),
              title: const Text('设置 B 点'),
              subtitle: Text(state.abLoopLabel),
              onTap: () {
                state.setAbLoopEnd();
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.clear_rounded),
              title: const Text('清除 AB 循环'),
              subtitle: Text(state.abLoopLabel),
              onTap: () {
                state.clearAbLoop();
                Navigator.of(context).pop();
              },
            ),
            if (state.currentItem != null)
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('编辑媒体信息'),
                subtitle: Text(state.currentItem!.title),
                onTap: () {
                  final item = state.currentItem!;
                  Navigator.of(context).pop();
                  _showMetadataDialog(context, state, item);
                },
              ),
            if (state.currentItem case final item?
                when item.kind == MediaKind.audio)
              ListTile(
                leading: const Icon(Icons.upload_file_rounded),
                title: Text(item.lyrics.isEmpty ? '导入歌词' : '替换歌词'),
                subtitle: const Text('选择单独的 LRC 歌词文件'),
                onTap: () {
                  Navigator.of(context).pop();
                  _importLyrics(pageContext, state, item);
                },
              ),
            if (state.currentItem case final item?
                when item.kind == MediaKind.audio && item.lyrics.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('导出当前歌词'),
                subtitle: const Text('LRC 文件，包含已保存的单曲校准'),
                enabled: !state.isExportingLyrics,
                onTap: () {
                  Navigator.of(context).pop();
                  runLyricsExport(pageContext, state, mediaId: item.id);
                },
              ),
            if (state.currentItem case final item?
                when item.kind == MediaKind.audio && item.lyrics.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.lyrics_outlined),
                title: const Text('移除歌词'),
                onTap: () {
                  state.removeLyrics(item.id);
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(pageContext).showSnackBar(
                    const SnackBar(content: Text('已移除当前歌曲的歌词。')),
                  );
                },
              ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _importLyrics(
  BuildContext context,
  LumioAppState state,
  MediaItem item,
) async {
  final result = await state.importLyrics(item.id);
  if (!context.mounted || result.status == LyricsImportStatus.cancelled) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        result.message.isEmpty
            ? result.didImport
                ? '歌词已导入。'
                : '歌词导入失败。'
            : result.message,
      ),
    ),
  );
}

Future<void> _showMetadataDialog(
  BuildContext context,
  LumioAppState state,
  MediaItem item,
) async {
  final titleController = TextEditingController(text: item.title);
  final artistController = TextEditingController(text: item.artist);
  final albumController = TextEditingController(text: item.album);
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('编辑媒体信息'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: titleController,
            autofocus: true,
            decoration: const InputDecoration(labelText: '标题'),
            textInputAction: TextInputAction.next,
          ),
          TextField(
            controller: artistController,
            decoration: const InputDecoration(labelText: '艺术家'),
            textInputAction: TextInputAction.next,
          ),
          TextField(
            controller: albumController,
            decoration: const InputDecoration(labelText: '专辑'),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => Navigator.of(context).pop(true),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  final title = titleController.text;
  final artist = artistController.text;
  final album = albumController.text;
  titleController.dispose();
  artistController.dispose();
  albumController.dispose();
  if (saved == true) {
    state.updateMediaMetadata(
      item.id,
      title: title,
      artist: artist,
      album: album,
    );
  }
}
