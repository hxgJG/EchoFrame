import 'package:flutter/material.dart';

import '../../core/models/media_item.dart';

class MediaArtwork extends StatelessWidget {
  const MediaArtwork({
    super.key,
    required this.item,
    this.size = 56,
    this.icon,
  });

  final MediaItem item;
  final double size;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isVideo = item.kind == MediaKind.video;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: item.accentColor,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  item.accentColor.withValues(alpha: 0.95),
                  item.accentColor.withValues(alpha: 0.45),
                  scheme.surface.withValues(alpha: 0.2),
                ],
              ),
            ),
          ),
          Positioned(
            right: -size * 0.18,
            bottom: -size * 0.18,
            child: Icon(
              isVideo ? Icons.movie_rounded : Icons.graphic_eq_rounded,
              color: Colors.white.withValues(alpha: 0.28),
              size: size * 0.88,
            ),
          ),
          Center(
            child: Icon(
              icon ??
                  (isVideo ? Icons.play_arrow_rounded : Icons.album_rounded),
              color: Colors.white,
              size: size * 0.42,
            ),
          ),
        ],
      ),
    );
  }
}

class MediaTile extends StatelessWidget {
  const MediaTile({
    super.key,
    required this.item,
    required this.onTap,
    this.trailing,
    this.showMeta = true,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool showMeta;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: MediaArtwork(item: item),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.titleMedium,
      ),
      subtitle: Text(
        showMeta ? item.subtitle : formatDuration(item.duration),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: trailing ??
          IconButton(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () {},
          ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onTap: onTap,
    );
  }
}
