import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../core/models/media_item.dart';
import 'media_tile.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.state, required this.onExpand});

  final LumioAppState state;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final item = state.currentItem;
    if (item == null) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final mediaColor = LumioTheme.mediaColor(item.kind, context);
    final textTheme = Theme.of(context).textTheme;
    final fraction = item.duration.inMilliseconds == 0
        ? 0.0
        : state.position.inMilliseconds / item.duration.inMilliseconds;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: scheme.surface,
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onExpand,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              LinearProgressIndicator(
                minHeight: 3,
                value: fraction.clamp(0, 1),
                color: mediaColor,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: LayoutBuilder(builder: (context, constraints) {
                  final compact = constraints.maxWidth < 480;
                  final details = Row(children: <Widget>[
                    MediaArtwork(item: item, size: 44),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            item.kind == MediaKind.video
                                ? item.subtitle
                                : '${item.artist} • ${item.album}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ]);
                  final repeatLabel = switch (state.repeatMode) {
                    RepeatMode.off => '不循环',
                    RepeatMode.all => '列表循环',
                    RepeatMode.one => '单曲循环',
                  };
                  final controls = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        tooltip: state.shuffleEnabled ? '关闭随机播放' : '开启随机播放',
                        isSelected: state.shuffleEnabled,
                        onPressed: state.toggleShuffle,
                        style: IconButton.styleFrom(
                          backgroundColor: state.shuffleEnabled
                              ? scheme.primaryContainer
                              : null,
                          foregroundColor:
                              state.shuffleEnabled ? mediaColor : null,
                        ),
                        icon: const Icon(Icons.shuffle_rounded),
                      ),
                      IconButton(
                        tooltip: '$repeatLabel（点击切换）',
                        onPressed: state.cycleRepeatMode,
                        icon: Icon(
                          switch (state.repeatMode) {
                            RepeatMode.off => Icons.arrow_forward_rounded,
                            RepeatMode.all => Icons.repeat_rounded,
                            RepeatMode.one => Icons.repeat_one_rounded,
                          },
                          color: state.repeatMode == RepeatMode.off
                              ? scheme.onSurfaceVariant
                              : mediaColor,
                        ),
                      ),
                      IconButton(
                        tooltip: '上一首',
                        onPressed: state.previous,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      IconButton(
                        tooltip: state.isPlaying ? '暂停' : '播放',
                        onPressed: state.togglePlaying,
                        icon: Icon(
                          state.isPlaying
                              ? Icons.pause_circle_filled_rounded
                              : Icons.play_circle_fill_rounded,
                          color: mediaColor,
                          size: 34,
                        ),
                      ),
                      IconButton(
                        tooltip: '下一首',
                        onPressed: state.next,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    ],
                  );
                  if (compact) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [details, controls],
                    );
                  }
                  return Row(children: [
                    Expanded(child: details),
                    const SizedBox(width: 12),
                    controls,
                  ]);
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
