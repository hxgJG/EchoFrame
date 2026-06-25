import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/models/media_item.dart';
import 'media_tile.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.state, required this.onExpand});

  final EchoAppState state;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final item = state.currentItem;
    if (item == null) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
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
                backgroundColor: scheme.surfaceContainerHighest,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Row(
                  children: <Widget>[
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
                    IconButton(
                      tooltip: state.isPlaying ? '暂停' : '播放',
                      onPressed: state.togglePlaying,
                      icon: Icon(
                        state.isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                        color: scheme.primary,
                        size: 34,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
