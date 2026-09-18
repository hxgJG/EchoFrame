import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../core/models/media_item.dart';
import '../../platform/media_library/artwork_memory_cache.dart';

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

  static const MethodChannel _mediaLibraryChannel = MethodChannel(
    'lumio/media_library',
  );
  static final ArtworkMemoryCache _artworkCache = ArtworkMemoryCache(
    _loadArtwork,
  );

  static Future<Uint8List?> _loadArtwork(String cacheKey) async {
    final parts = cacheKey.split('|');
    if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) {
      return null;
    }
    try {
      final embedded = await _mediaLibraryChannel.invokeMethod<Uint8List>(
        'loadArtwork',
        <String, Object?>{
          'kind': parts[0],
          'mediaId': parts[1],
        },
      );
      if (embedded != null && embedded.isNotEmpty) {
        return embedded;
      }
    } on MissingPluginException {
    } on PlatformException {}
    if (parts.length < 3 || parts[2].isEmpty) {
      return null;
    }
    try {
      final file = File(Uri.decodeComponent(parts[2]));
      return await file.exists() ? file.readAsBytes() : null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mediaColor = LumioTheme.mediaColor(item.kind, context);
    final placeholder = _ArtworkPlaceholder(
      item: item,
      icon: icon,
      scheme: scheme,
      size: size,
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: mediaColor,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<Uint8List?>(
        future: _artworkCache.load(
          '${item.kind.name}|${item.id}|'
          '${Uri.encodeComponent(item.artworkPath ?? '')}',
        ),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return placeholder;
          }
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => placeholder,
          );
        },
      ),
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder({
    required this.item,
    required this.icon,
    required this.scheme,
    required this.size,
  });

  final MediaItem item;
  final IconData? icon;
  final ColorScheme scheme;
  final double size;

  @override
  Widget build(BuildContext context) {
    final isVideo = item.kind == MediaKind.video;
    final mediaColor = LumioTheme.mediaColor(item.kind, context);
    final background = scheme.brightness == Brightness.dark
        ? Color.alphaBlend(
            mediaColor.withValues(alpha: 0.16), scheme.surfaceContainerLow)
        : LumioTheme.mediaContainerColor(item.kind, context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                background,
                Color.alphaBlend(
                  mediaColor.withValues(alpha: 0.12),
                  background,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: -size * 0.18,
          bottom: -size * 0.18,
          child: Icon(
            isVideo ? Icons.movie_rounded : Icons.graphic_eq_rounded,
            color: mediaColor.withValues(alpha: 0.16),
            size: size * 0.88,
          ),
        ),
        Center(
          child: Icon(
            icon ?? (isVideo ? Icons.play_arrow_rounded : Icons.album_rounded),
            color: mediaColor,
            size: size * 0.42,
          ),
        ),
      ],
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
