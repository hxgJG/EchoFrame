import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../core/models/media_item.dart';
import '../../core/models/playlist.dart';
import '../search/search_page.dart';
import '../../shared/widgets/media_tile.dart';
import '../../shared/widgets/section_header.dart';

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key, required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final current = state.currentItem;
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放列表'),
        actions: <Widget>[
          IconButton(
            tooltip: '搜索',
            onPressed: () => _openSearch(context),
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: '新建播放列表',
            onPressed: () => _createPlaylist(context),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: <Widget>[
          const SectionHeader(title: '播放队列'),
          _QueueCard(state: state, current: current),
          const SectionHeader(title: '持久播放列表'),
          ...state.playlists.map((playlist) {
            final items = state.itemsForPlaylist(playlist);
            final playlistColor = items.isEmpty
                ? LumioTheme.audioColor(scheme.brightness)
                : items.every((item) => item.kind == MediaKind.video)
                    ? LumioTheme.videoColor(scheme.brightness)
                    : items.every((item) => item.kind == MediaKind.audio)
                        ? LumioTheme.audioColor(scheme.brightness)
                        : scheme.primary;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ExpansionTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                collapsedShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                backgroundColor: scheme.surface,
                collapsedBackgroundColor: scheme.surface,
                leading: Icon(
                  Icons.playlist_play_rounded,
                  color: playlistColor,
                ),
                title: Text(playlist.name, style: textTheme.titleMedium),
                subtitle: Text(
                  '${items.length} 项 • ${playlist.description}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _PlaylistMenu(
                  onRename: () => _renamePlaylist(context, playlist),
                  onClear: items.isEmpty
                      ? null
                      : () => _confirmClearPlaylistItems(
                            context,
                            playlist,
                            items,
                          ),
                  onDelete: () => _confirmDeletePlaylist(context, playlist),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: <Widget>[
                  if (items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '还没有添加媒体，可在歌曲菜单中加入。',
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )
                  else
                    _PlaylistReorderList(
                      playlist: playlist,
                      items: items,
                      state: state,
                    ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
          Text(
            '队列是当前播放的临时顺序，播放列表会保存在本机离线状态中。',
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  void _openSearch(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SearchPage(state: state)),
    );
  }

  Future<void> _createPlaylist(BuildContext context) async {
    final name = await _showPlaylistNameDialog(
      context,
      title: '新建播放列表',
      confirmLabel: '创建',
    );
    if (name != null) {
      state.createPlaylist(name);
    }
  }

  Future<void> _renamePlaylist(
    BuildContext context,
    Playlist playlist,
  ) async {
    final name = await _showPlaylistNameDialog(
      context,
      title: '重命名播放列表',
      confirmLabel: '保存',
      initialValue: playlist.name,
    );
    if (name != null) {
      state.renamePlaylist(playlist.id, name);
    }
  }

  Future<void> _confirmDeletePlaylist(
    BuildContext context,
    Playlist playlist,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除播放列表'),
        content: Text('确定删除「${playlist.name}」吗？媒体文件不会被删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      state.deletePlaylist(playlist.id);
    }
  }

  Future<void> _confirmClearPlaylistItems(
    BuildContext context,
    Playlist playlist,
    List<MediaItem> items,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空播放列表'),
        content:
            Text('确定从「${playlist.name}」移除全部 ${items.length} 项吗？媒体文件不会被删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      state.removeManyFromPlaylist(
        playlist.id,
        items.map((item) => item.id),
      );
    }
  }

  Future<String?> _showPlaylistNameDialog(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：夜跑节拍'),
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.state, required this.current});

  final LumioAppState state;
  final MediaItem? current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mediaColor = current == null
        ? scheme.primary
        : LumioTheme.mediaColor(current!.kind, scheme.brightness);
    final textTheme = Theme.of(context).textTheme;
    final queueItems = state.queueItems;
    final currentTitle = current?.title;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.queue_music_rounded, color: mediaColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  currentTitle == null
                      ? '暂无播放内容'
                      : '当前播放：$currentTitle • 队列 ${queueItems.length} 项',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleMedium,
                ),
              ),
              if (queueItems.isNotEmpty)
                IconButton(
                  tooltip: '清空队列',
                  onPressed: state.clearQueue,
                  icon: const Icon(Icons.clear_all_rounded),
                ),
              IconButton(
                tooltip: state.isPlaying ? '暂停' : '播放',
                onPressed: state.togglePlaying,
                icon: Icon(
                  state.isPlaying
                      ? Icons.pause_circle_rounded
                      : Icons.play_circle_rounded,
                  color: mediaColor,
                ),
              ),
            ],
          ),
          if (queueItems.isNotEmpty) ...<Widget>[
            const Divider(height: 20),
            _QueueReorderList(items: queueItems, state: state),
          ],
        ],
      ),
    );
  }
}

class _QueueReorderList extends StatelessWidget {
  const _QueueReorderList({required this.items, required this.state});

  final List<MediaItem> items;
  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorder: state.reorderQueue,
      itemBuilder: (context, index) {
        final item = items[index];
        return MediaTile(
          key: ValueKey('queue-$index-${item.id}'),
          item: item,
          onTap: () => state.play(item),
          showMeta: item.kind.name != 'video',
          trailing: _ReorderableMediaActions(
            index: index,
            removeTooltip: '从队列移除',
            onRemove: () => state.removeFromQueueAt(index),
          ),
        );
      },
    );
  }
}

class _PlaylistReorderList extends StatelessWidget {
  const _PlaylistReorderList({
    required this.playlist,
    required this.items,
    required this.state,
  });

  final Playlist playlist;
  final List<MediaItem> items;
  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorder: (oldIndex, newIndex) {
        state.reorderPlaylistItems(playlist.id, oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final item = items[index];
        return MediaTile(
          key: ValueKey('playlist-${playlist.id}-${item.id}'),
          item: item,
          onTap: () => state.play(item),
          showMeta: item.kind.name != 'video',
          trailing: _ReorderableMediaActions(
            index: index,
            removeTooltip: '从播放列表移除',
            onRemove: () => state.removeFromPlaylist(playlist.id, item.id),
          ),
        );
      },
    );
  }
}

class _ReorderableMediaActions extends StatelessWidget {
  const _ReorderableMediaActions({
    required this.index,
    required this.removeTooltip,
    required this.onRemove,
  });

  final int index;
  final String removeTooltip;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ReorderableDragStartListener(
          index: index,
          child: IconButton(
            tooltip: '拖拽排序',
            onPressed: () {},
            icon: Icon(Icons.drag_handle_rounded, color: scheme.outline),
          ),
        ),
        IconButton(
          tooltip: removeTooltip,
          onPressed: onRemove,
          icon: const Icon(Icons.remove_circle_outline),
        ),
      ],
    );
  }
}

class _PlaylistMenu extends StatelessWidget {
  const _PlaylistMenu({
    required this.onRename,
    required this.onClear,
    required this.onDelete,
  });

  final VoidCallback onRename;
  final VoidCallback? onClear;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '播放列表操作',
      icon: const Icon(Icons.more_vert_rounded),
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        const PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuItem(
          value: 'clear',
          enabled: onClear != null,
          child: const Text('清空条目'),
        ),
        const PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
      onSelected: (value) {
        switch (value) {
          case 'rename':
            onRename();
          case 'clear':
            onClear?.call();
          case 'delete':
            onDelete();
        }
      },
    );
  }
}
