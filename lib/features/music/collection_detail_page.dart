import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/models/media_item.dart';
import '../../shared/widgets/media_tile.dart';
import '../../shared/widgets/section_header.dart';
import 'audio_selection.dart';
import 'playlist_picker.dart';

/// 专辑与艺术家详情：展示合集内全部歌曲，并提供整体播放与加入队列。
///
/// 只持有合集的标识（专辑名/艺术家名），内容通过状态层实时查询，
/// 因此重新扫描或修改元数据后列表会自动更新。
enum CollectionKind { album, artist }

class CollectionDetailPage extends StatelessWidget {
  const CollectionDetailPage({
    super.key,
    required this.state,
    required this.kind,
    required this.name,
  });

  final LumioAppState state;
  final CollectionKind kind;
  final String name;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final items = kind == CollectionKind.album
            ? state.itemsForAlbum(name)
            : state.itemsForArtist(name);
        return Scaffold(
          appBar: AppBar(
            title: Text(name.isEmpty ? '未知' : name),
          ),
          body: items.isEmpty
              ? const _CollectionEmptyState()
              : _CollectionBody(
                  state: state,
                  kind: kind,
                  name: name,
                  items: items,
                ),
        );
      },
    );
  }
}

class _CollectionBody extends StatelessWidget {
  const _CollectionBody({
    required this.state,
    required this.kind,
    required this.name,
    required this.items,
  });

  final LumioAppState state;
  final CollectionKind kind;
  final String name;
  final List<MediaItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total =
        items.fold<Duration>(Duration.zero, (sum, item) => sum + item.duration);
    final artists = items.map((item) => item.artist).toSet();
    final subtitle = <String>[
      '${items.length} 首歌曲',
      formatDuration(total),
      if (kind == CollectionKind.album && artists.length == 1) artists.first,
    ].join(' · ');

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: items.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                MediaArtwork(item: items.first, size: 108),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        name.isEmpty ? '未知' : name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          FilledButton.icon(
                            onPressed: () =>
                                state.playAll(items.map((item) => item.id)),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('播放全部'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              state
                                  .addManyToQueue(items.map((item) => item.id));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text('已加入队列：${items.length} 首')),
                              );
                            },
                            icon: const Icon(Icons.queue_music_rounded),
                            label: const Text('加入队列'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        if (index == 1) return const SectionHeader(title: '歌曲');
        final item = items[index - 2];
        return MediaTile(
          item: item,
          onTap: () => selectAudioItem(context, state, item),
          trailing: _CollectionSongMenu(state: state, item: item),
        );
      },
    );
  }
}

/// 合集页的歌曲菜单只保留与合集相关的操作；完整操作仍在音乐库列表中。
class _CollectionSongMenu extends StatelessWidget {
  const _CollectionSongMenu({required this.state, required this.item});

  final LumioAppState state;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_vert_rounded),
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        const PopupMenuItem(value: 'queue', child: Text('加入队列')),
        const PopupMenuItem(value: 'playlist', child: Text('加入播放列表')),
        const PopupMenuItem(value: 'play', child: Text('立即播放')),
        PopupMenuItem(
          value: 'favorite',
          child: Text(item.isFavorite ? '取消收藏' : '收藏'),
        ),
      ],
      onSelected: (value) async {
        switch (value) {
          case 'queue':
            state.addToQueue(item.id);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已加入队列：${item.title}')),
            );
          case 'playlist':
            final name =
                await showPlaylistPicker(context, state, <String>{item.id});
            if (!context.mounted || name == null) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已加入 $name')),
            );
          case 'play':
            state.play(item);
          case 'favorite':
            state.toggleFavorite(item.id);
        }
      },
    );
  }
}

class _CollectionEmptyState extends StatelessWidget {
  const _CollectionEmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.album_outlined,
                size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              '这个合集里已经没有歌曲',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '媒体重新扫描后，专辑或艺术家归类可能发生变化。',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
