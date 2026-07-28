import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../core/models/lumio_settings.dart';
import '../../core/models/media_item.dart';
import '../search/search_page.dart';
import '../../shared/widgets/media_tile.dart';
import '../../shared/widgets/section_header.dart';

class MusicLibraryPage extends StatefulWidget {
  const MusicLibraryPage({super.key, required this.state});

  final LumioAppState state;

  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final audioColor = LumioTheme.audioColor(scheme.brightness);
    return Scaffold(
      appBar: AppBar(
        title: const Text('音乐库'),
        actions: <Widget>[
          PopupMenuButton<MusicSort>(
            tooltip: '排序',
            icon: const Icon(Icons.sort_rounded),
            initialValue: state.musicSort,
            onSelected: state.setMusicSort,
            itemBuilder: (context) => const <PopupMenuEntry<MusicSort>>[
              PopupMenuItem(value: MusicSort.title, child: Text('按名称')),
              PopupMenuItem(value: MusicSort.addedAt, child: Text('按添加时间')),
              PopupMenuItem(value: MusicSort.duration, child: Text('按时长')),
              PopupMenuItem(value: MusicSort.playCount, child: Text('按播放次数')),
              PopupMenuItem(value: MusicSort.fileSize, child: Text('按文件大小')),
            ],
          ),
          IconButton(
            tooltip: state.settings.musicViewMode == MusicViewMode.list
                ? '切换为网格'
                : '切换为列表',
            onPressed: () => state.setMusicViewMode(
              state.settings.musicViewMode == MusicViewMode.list
                  ? MusicViewMode.grid
                  : MusicViewMode.list,
            ),
            icon: Icon(
              state.settings.musicViewMode == MusicViewMode.list
                  ? Icons.grid_view_rounded
                  : Icons.view_list_rounded,
            ),
          ),
          IconButton(
            tooltip: '搜索',
            onPressed: () => _openSearch(context, state),
            icon: const Icon(Icons.search_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: audioColor,
          labelColor: audioColor,
          tabs: const <Widget>[
            Tab(text: '歌曲'),
            Tab(text: '专辑'),
            Tab(text: '艺术家'),
            Tab(text: '文件夹'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: audioColor,
        foregroundColor: scheme.brightness == Brightness.dark
            ? LumioTheme.night
            : Colors.white,
        tooltip: '随机播放当前列表',
        onPressed: state.audioItems.isEmpty
            ? null
            : () => state.shuffleAll(MediaKind.audio),
        child: const Icon(Icons.shuffle_rounded),
      ),
      body: TabBarView(
        controller: _tabController,
        children: <Widget>[
          _SongsTab(state: state),
          _AlbumGrid(state: state),
          _ArtistGrid(state: state),
          _AudioFolderList(state: state),
        ],
      ),
    );
  }
}

void _openSearch(BuildContext context, LumioAppState state) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => SearchPage(state: state)),
  );
}

class _SongsTab extends StatefulWidget {
  const _SongsTab({required this.state});

  final LumioAppState state;

  @override
  State<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends State<_SongsTab> {
  final Set<String> _selectedIds = <String>{};

  bool get _isSelecting => _selectedIds.isNotEmpty;

  void _toggleSelected(String mediaId) {
    setState(() {
      if (!_selectedIds.add(mediaId)) {
        _selectedIds.remove(mediaId);
      }
    });
  }

  void _clearSelection() {
    setState(_selectedIds.clear);
  }

  void _selectAll(List<MediaItem> items) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(items.map((item) => item.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final audioColor = LumioTheme.audioColor(scheme.brightness);
    final items = state.audioItems;
    if (items.isEmpty) {
      return const _MusicEmptyState(
        title: '没有找到音频',
        message: '可以到设置里扫描本机媒体，或检查读取权限。',
      );
    }
    if (state.settings.musicViewMode == MusicViewMode.grid) {
      return CustomScrollView(
        slivers: <Widget>[
          if (_isSelecting)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              sliver: SliverToBoxAdapter(
                child: _buildBatchActionBar(context, state, items),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 88),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.83,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = items[index];
                  final selected = _selectedIds.contains(item.id);
                  return _SongGridCard(
                    state: state,
                    item: item,
                    selected: selected,
                    isSelecting: _isSelecting,
                    onToggleSelected: () => _toggleSelected(item.id),
                  );
                },
                childCount: items.length,
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 88),
      itemCount: items.length + (_isSelecting ? 1 : 0),
      itemBuilder: (context, index) {
        if (_isSelecting && index == 0) {
          return _buildBatchActionBar(context, state, items);
        }
        final item = items[_isSelecting ? index - 1 : index];
        final selected = _selectedIds.contains(item.id);
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onLongPress: () => _toggleSelected(item.id),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected
                  ? audioColor.withValues(
                      alpha: scheme.brightness == Brightness.dark ? 0.2 : 0.12,
                    )
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: MediaTile(
              item: item,
              onTap: () =>
                  _isSelecting ? _toggleSelected(item.id) : state.play(item),
              trailing: _isSelecting
                  ? Checkbox(
                      value: selected,
                      activeColor: audioColor,
                      onChanged: (_) => _toggleSelected(item.id),
                    )
                  : _SongMenu(
                      state: state,
                      item: item,
                      onFavorite: () => state.toggleFavorite(item.id),
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBatchActionBar(
    BuildContext context,
    LumioAppState state,
    List<MediaItem> items,
  ) {
    return _BatchActionBar(
      selectedCount: _selectedIds.length,
      onCancel: _clearSelection,
      onSelectAll: () => _selectAll(items),
      onAddToQueue: () {
        state.addManyToQueue(_selectedIds);
        final count = _selectedIds.length;
        _clearSelection();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已将 $count 首加入队列')),
        );
      },
      onAddToPlaylist: () async {
        final count = _selectedIds.length;
        final playlistName = await _showPlaylistPicker(
          context,
          state,
          _selectedIds,
        );
        if (!context.mounted || playlistName == null) {
          return;
        }
        _clearSelection();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已将 $count 首加入 $playlistName')),
        );
      },
      onShare: () {
        final count = _selectedIds.length;
        state.shareMany(_selectedIds);
        _clearSelection();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已请求分享 $count 首媒体')),
        );
      },
      onDelete: () async {
        final ids = _selectedIds.toSet();
        final confirmed = await _confirmRemoveFromLibrary(context, ids.length);
        if (!confirmed || !context.mounted) {
          return;
        }
        final result = await state.deleteMediaFiles(ids);
        if (!context.mounted) {
          return;
        }
        if (result.didChangeFiles) {
          _clearSelection();
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message)),
        );
      },
      onMove: () async {
        final ids = _selectedIds.toSet();
        final relativePath = await _showFileValueDialog(
          context,
          title: '移动媒体',
          label: '目标目录',
          hintText: '例如：Music/Lumio',
          confirmLabel: '移动',
        );
        if (relativePath == null || !context.mounted) {
          return;
        }
        final result = await state.moveMediaFiles(ids, relativePath);
        if (!context.mounted) {
          return;
        }
        if (result.didChangeFiles) {
          _clearSelection();
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message)),
        );
      },
    );
  }
}

class _SongGridCard extends StatelessWidget {
  const _SongGridCard({
    required this.state,
    required this.item,
    required this.selected,
    required this.isSelecting,
    required this.onToggleSelected,
  });

  final LumioAppState state;
  final MediaItem item;
  final bool selected;
  final bool isSelecting;
  final VoidCallback onToggleSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audioColor = LumioTheme.audioColor(scheme.brightness);
    return Card(
      color: selected
          ? audioColor.withValues(
              alpha: scheme.brightness == Brightness.dark ? 0.2 : 0.12,
            )
          : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: onToggleSelected,
        onTap: isSelecting ? onToggleSelected : () => state.play(item),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                  child: Center(child: MediaArtwork(item: item, size: 120))),
              const SizedBox(height: 8),
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                item.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: isSelecting
                    ? Checkbox(
                        value: selected,
                        activeColor: audioColor,
                        onChanged: (_) => onToggleSelected(),
                      )
                    : _SongMenu(
                        state: state,
                        item: item,
                        onFavorite: () => state.toggleFavorite(item.id),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatchActionBar extends StatelessWidget {
  const _BatchActionBar({
    required this.selectedCount,
    required this.onCancel,
    required this.onSelectAll,
    required this.onAddToQueue,
    required this.onAddToPlaylist,
    required this.onShare,
    required this.onDelete,
    required this.onMove,
  });

  final int selectedCount;
  final VoidCallback onCancel;
  final VoidCallback onSelectAll;
  final VoidCallback onAddToQueue;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final VoidCallback onMove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '取消',
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
          Expanded(
            child: Text(
              '已选 $selectedCount 首',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            tooltip: '全选',
            onPressed: onSelectAll,
            icon: const Icon(Icons.select_all_rounded),
          ),
          IconButton(
            tooltip: '加入队列',
            onPressed: onAddToQueue,
            icon: const Icon(Icons.queue_music_rounded),
          ),
          IconButton(
            tooltip: '加入播放列表',
            onPressed: onAddToPlaylist,
            icon: const Icon(Icons.playlist_add_rounded),
          ),
          IconButton(
            tooltip: '分享',
            onPressed: onShare,
            icon: const Icon(Icons.share_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: '文件操作',
            icon: const Icon(Icons.drive_file_move_rounded),
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem(value: 'move', child: Text('移动文件')),
              PopupMenuItem(value: 'delete', child: Text('从媒体库移除')),
            ],
            onSelected: (value) {
              if (value == 'move') {
                onMove();
              } else if (value == 'delete') {
                onDelete();
              }
            },
          ),
        ],
      ),
    );
  }
}

Future<String?> _showPlaylistPicker(
  BuildContext context,
  LumioAppState state,
  Iterable<String> mediaIds,
) async {
  final ids = mediaIds.toSet();
  if (ids.isEmpty) {
    return null;
  }
  if (state.playlists.isEmpty) {
    final name = await _showPlaylistNameDialog(
      context,
      title: '新建播放列表',
      confirmLabel: '创建并加入',
    );
    if (name == null) {
      return null;
    }
    state.createPlaylist(name);
    final created = state.playlists.first;
    state.addManyToPlaylist(created.id, ids);
    return created.name;
  }

  final playlistId = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('加入播放列表'),
      children: state.playlists
          .map(
            (playlist) => SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(playlist.id),
              child: Text(playlist.name),
            ),
          )
          .toList(),
    ),
  );
  if (playlistId == null) {
    return null;
  }
  final playlist =
      state.playlists.firstWhere((value) => value.id == playlistId);
  state.addManyToPlaylist(playlist.id, ids);
  return playlist.name;
}

Future<String?> _showPlaylistNameDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
}) async {
  final controller = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '例如：通勤歌单'),
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

class _SongMenu extends StatelessWidget {
  const _SongMenu({
    required this.state,
    required this.item,
    required this.onFavorite,
  });

  final LumioAppState state;
  final MediaItem item;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_vert_rounded),
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        const PopupMenuItem(value: 'queue', child: Text('加入队列')),
        const PopupMenuItem(value: 'playlist', child: Text('加入播放列表')),
        const PopupMenuItem(value: 'share', child: Text('分享')),
        const PopupMenuItem(value: 'edit', child: Text('编辑信息')),
        const PopupMenuItem(value: 'renameFile', child: Text('重命名文件')),
        const PopupMenuItem(value: 'moveFile', child: Text('移动文件')),
        const PopupMenuItem(value: 'deleteFile', child: Text('从媒体库移除')),
        PopupMenuItem(
          value: 'favorite',
          child: Text(item.isFavorite ? '取消收藏' : '收藏'),
        ),
        const PopupMenuItem(value: 'detail', child: Text('详情')),
      ],
      onSelected: (value) {
        switch (value) {
          case 'playlist':
            _addToPlaylist(context);
          case 'favorite':
            onFavorite();
          case 'queue':
            state.addToQueue(item.id);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已加入队列：${item.title}')),
            );
          case 'share':
            state.share(item);
          case 'edit':
            _showMetadataDialog(context, state, item);
          case 'renameFile':
            _renameFile(context);
          case 'moveFile':
            _moveFile(context);
          case 'deleteFile':
            _deleteFile(context);
          case 'detail':
            _showMediaDetail(context);
        }
      },
    );
  }

  Future<void> _addToPlaylist(BuildContext context) async {
    final playlistName = await _showPlaylistPicker(
      context,
      state,
      <String>{item.id},
    );
    if (!context.mounted || playlistName == null) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已加入 $playlistName')),
    );
  }

  Future<void> _showMediaDetail(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('媒体详情'),
        content: SelectableText(_mediaDetailText(item)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _renameFile(BuildContext context) async {
    final currentName = item.path.split('/').last;
    final displayName = await _showFileValueDialog(
      context,
      title: '重命名文件',
      label: '完整文件名',
      initialValue: currentName,
      confirmLabel: '重命名',
    );
    if (displayName == null || !context.mounted) {
      return;
    }
    final result = await state.renameMediaFile(item.id, displayName);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  Future<void> _moveFile(BuildContext context) async {
    final relativePath = await _showFileValueDialog(
      context,
      title: '移动文件',
      label: '目标目录',
      hintText: '例如：Music/Lumio',
      confirmLabel: '移动',
    );
    if (relativePath == null || !context.mounted) {
      return;
    }
    final result = await state.moveMediaFiles(<String>[item.id], relativePath);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  Future<void> _deleteFile(BuildContext context) async {
    if (!await _confirmRemoveFromLibrary(context, 1) || !context.mounted) {
      return;
    }
    final result = await state.deleteMediaFiles(<String>[item.id]);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }
}

Future<bool> _confirmRemoveFromLibrary(BuildContext context, int count) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('从媒体库移除'),
          content: Text(
            '将从忆光当前媒体库移除 $count 个媒体，设备源文件不会被删除。之后可在设置中恢复。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认移除'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<String?> _showFileValueDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String confirmLabel,
  String initialValue = '',
  String? hintText,
}) async {
  final controller = TextEditingController(text: initialValue);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label, hintText: hintText),
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

String _mediaDetailText(MediaItem item) {
  final rows = <String>[
    '标题：${item.title}',
    if (item.kind == MediaKind.audio)
      '艺术家：${item.artist}'
    else
      '来源/作者：${item.artist}',
    if (item.kind == MediaKind.audio)
      '专辑：${item.album}'
    else
      '合集/相册：${item.album}',
    '时长：${formatDuration(item.duration)}',
    if (item.kind == MediaKind.video && item.resolution != null)
      '分辨率：${item.resolution}',
    if (item.formatLabel != null) '格式：${item.formatLabel}',
    if (item.fileSizeLabel != null) '大小：${item.fileSizeLabel}',
    if (item.kind == MediaKind.video && item.lastPosition > Duration.zero)
      '续播位置：${formatDuration(item.lastPosition)}',
    '文件夹：${item.folder}',
    '路径：${item.path}',
  ];
  return rows.where((row) => !row.endsWith('：')).join('\n');
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
    if (item.path.toLowerCase().endsWith('.mp3')) {
      final result = await state.writeMediaTags(
        item.id,
        title: title,
        artist: artist,
        album: album,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message)),
        );
      }
    } else {
      state.updateMediaMetadata(
        item.id,
        title: title,
        artist: artist,
        album: album,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前格式暂只修改忆光列表信息；源文件写回优先支持 MP3。')),
        );
      }
    }
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    if (state.albums.isEmpty) {
      return const _MusicEmptyState(
        title: '暂无专辑',
        message: '扫描到音频后会按本地标签自动汇总专辑。',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.86,
      ),
      itemCount: state.albums.length,
      itemBuilder: (context, index) {
        final album = state.albums[index];
        final items = state.itemsForAlbum(album);
        return _CollectionCard(
          title: album,
          subtitle: '${items.length} 首 • ${items.first.artist}',
          item: items.first,
          onTap: () => state.play(items.first),
        );
      },
    );
  }
}

class _ArtistGrid extends StatelessWidget {
  const _ArtistGrid({required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    if (state.artists.isEmpty) {
      return const _MusicEmptyState(
        title: '暂无艺术家',
        message: '扫描到音频后会按本地标签自动汇总艺术家。',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
      children: <Widget>[
        const SectionHeader(title: '艺术家'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: state.artists.map((artist) {
            final items = state.itemsForArtist(artist);
            return SizedBox(
              width: 164,
              child: _CollectionCard(
                title: artist,
                subtitle: '${items.length} 首歌曲',
                item: items.first,
                onTap: () => state.play(items.first),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _AudioFolderList extends StatelessWidget {
  const _AudioFolderList({required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    final folders = state.audioFolders;
    if (folders.isEmpty) {
      return const _MusicEmptyState(
        title: '没有音频文件夹',
        message: '扫描本机媒体后，会按原始文件夹展示歌曲。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 88),
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        final items = state.itemsForAudioFolder(folder);
        return _AudioFolderTile(folder: folder, items: items, state: state);
      },
    );
  }
}

class _AudioFolderTile extends StatelessWidget {
  const _AudioFolderTile({
    required this.folder,
    required this.items,
    required this.state,
  });

  final String folder;
  final List<MediaItem> items;
  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final first = items.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        collapsedShape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        backgroundColor: scheme.surface,
        collapsedBackgroundColor: scheme.surface,
        leading: MediaArtwork(item: first),
        title: Text(folder.split('/').last, style: textTheme.titleMedium),
        subtitle: Text(
          '$folder • ${items.length} 首',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          tooltip: '播放文件夹',
          onPressed: () => state.play(first),
          icon: const Icon(Icons.play_circle_outline_rounded),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: items
            .map(
              (item) => MediaTile(
                item: item,
                onTap: () => state.play(item),
                trailing: _SongMenu(
                  state: state,
                  item: item,
                  onFavorite: () => state.toggleFavorite(item.id),
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _MusicEmptyState extends StatelessWidget {
  const _MusicEmptyState({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audioColor = LumioTheme.audioColor(scheme.brightness);
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.library_music_outlined, color: audioColor, size: 46),
            const SizedBox(height: 12),
            Text(title, style: textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.title,
    required this.subtitle,
    required this.item,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Center(child: MediaArtwork(item: item, size: 112)),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleMedium,
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
