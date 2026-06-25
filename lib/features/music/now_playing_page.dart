import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../core/models/echo_settings.dart';
import '../../core/models/media_item.dart';
import '../../shared/widgets/media_tile.dart';

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key, required this.state});

  final EchoAppState state;

  @override
  Widget build(BuildContext context) {
    final item = state.currentItem;
    final scheme = Theme.of(context).colorScheme;
    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('暂无播放内容')),
      );
    }

    final isVideo = item.kind == MediaKind.video;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '收起',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        title: Text(isVideo ? '视频播放' : 'Now Playing'),
        actions: <Widget>[
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
      body: ListView(
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
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
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

class _LyricsStage extends StatelessWidget {
  const _LyricsStage({required this.state, required this.item});

  final EchoAppState state;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final lines = item.lyrics;
    final currentIndex = state.currentLyricIndex;
    return Container(
      key: const ValueKey<String>('lyrics'),
      height: 320,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: lines.isEmpty
          ? Center(
              child: Text(
                '未找到本地歌词',
                style: textTheme.titleMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.builder(
              physics: const NeverScrollableScrollPhysics(),
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
                          ? scheme.primary
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

  final EchoAppState state;
  final MediaItem item;
  final int? textureId;
  final String subtitleText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                      item.accentColor.withValues(alpha: 0.8),
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
                  '${item.formatLabel ?? 'Video'} • ${item.resolution ?? 'Auto'}',
                  style: TextStyle(
                    color: scheme.onPrimary,
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

  final EchoAppState state;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  double _horizontalDrag = 0;
  double _verticalDrag = 0;
  bool _verticalDragStartedOnLeft = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final item = state.currentItem;
    final textureId = state.videoTextureId;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
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
          },
          onVerticalDragStart: (details) {
            _verticalDragStartedOnLeft =
                details.localPosition.dx < MediaQuery.sizeOf(context).width / 2;
            _verticalDrag = 0;
          },
          onVerticalDragUpdate: (details) {
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
          },
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
                  ),
                  child: _SubtitleOverlayText(
                    text: state.currentSubtitleText,
                    settings: state.settings,
                  ),
                ),
              Positioned(
                left: 8,
                top: 8,
                child: IconButton(
                  tooltip: '退出全屏',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(
                    Icons.fullscreen_exit_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 18,
                child: item == null
                    ? const SizedBox.shrink()
                    : _FullscreenControlBar(state: state, item: item),
              ),
            ],
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
  final EchoSettings settings;

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

  final EchoAppState state;
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

  final EchoAppState state;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = item.duration.inMilliseconds == 0
        ? 0.0
        : state.position.inMilliseconds / item.duration.inMilliseconds;
    return Column(
      children: <Widget>[
        Slider(value: fraction.clamp(0, 1), onChanged: state.seekToFraction),
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

  final EchoAppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
            color: state.repeatMode == RepeatMode.off ? null : scheme.primary,
          ),
        ),
        IconButton(
          tooltip: '上一首',
          onPressed: state.previous,
          icon: const Icon(Icons.skip_previous_rounded, size: 34),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
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
          tooltip: '随机',
          onPressed: state.toggleShuffle,
          icon: Icon(
            Icons.shuffle_rounded,
            color: state.shuffleEnabled ? scheme.primary : null,
          ),
        ),
      ],
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.state, required this.item});

  final EchoAppState state;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final isVideo = item.kind == MediaKind.video;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        IconButton(
          tooltip: '收起',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        IconButton(
          tooltip: isVideo ? '小窗播放' : '封面/歌词',
          onPressed:
              isVideo ? state.enterPictureInPicture : state.togglePlaybackView,
          icon: Icon(
            isVideo
                ? Icons.picture_in_picture_alt_rounded
                : Icons.lyrics_rounded,
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
          onPressed: () => state.selectSection(AppSection.playlists),
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

void _showMoreActions(BuildContext context, EchoAppState state) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
          ],
        ),
      ),
    ),
  );
}

Future<void> _showMetadataDialog(
  BuildContext context,
  EchoAppState state,
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
