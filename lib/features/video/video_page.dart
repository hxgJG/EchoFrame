import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../core/models/media_item.dart';
import '../music/now_playing_page.dart';
import '../search/search_page.dart';
import '../../shared/widgets/media_tile.dart';
import '../../shared/widgets/section_header.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.state});

  final LumioAppState state;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final videoColor = LumioTheme.videoColor(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('视频库'),
        actions: <Widget>[
          IconButton(
            tooltip: '搜索',
            onPressed: () => _openSearch(context, state),
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: '随机播放视频',
            onPressed: () => state.shuffleAll(MediaKind.video),
            icon: Icon(Icons.shuffle_rounded, color: videoColor),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: videoColor,
          labelColor: videoColor,
          tabs: const <Widget>[
            Tab(text: '视频'),
            Tab(text: '文件夹'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: <Widget>[
          _VideoList(state: state),
          _FolderList(state: state),
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

class _VideoList extends StatelessWidget {
  const _VideoList({required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: <Widget>[
        const SectionHeader(title: '本地视频'),
        ...state.videoItems.map(
          (item) => MediaTile(
            item: item,
            onTap: () {
              state.play(item);
              _openNowPlaying(context, state);
            },
            trailing: _VideoMenu(
              state: state,
              item: item,
              onPlay: () {
                state.play(item);
                _openNowPlaying(context, state);
              },
            ),
          ),
        ),
        const SizedBox(height: 18),
        _PhaseNote(),
      ],
    );
  }
}

class _VideoMenu extends StatelessWidget {
  const _VideoMenu({
    required this.state,
    required this.item,
    required this.onPlay,
  });

  final LumioAppState state;
  final MediaItem item;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_vert_rounded),
      itemBuilder: (context) => const <PopupMenuEntry<String>>[
        PopupMenuItem(value: 'play', child: Text('播放')),
        PopupMenuItem(value: 'share', child: Text('分享')),
        PopupMenuItem(value: 'edit', child: Text('编辑信息')),
        PopupMenuItem(value: 'renameFile', child: Text('重命名文件')),
        PopupMenuItem(value: 'moveFile', child: Text('移动文件')),
        PopupMenuItem(value: 'deleteFile', child: Text('从媒体库移除')),
        PopupMenuItem(value: 'detail', child: Text('详情')),
      ],
      onSelected: (value) {
        switch (value) {
          case 'play':
            onPlay();
          case 'share':
            state.share(item);
          case 'edit':
            _showMetadataDialog(context, state, item);
          case 'renameFile':
            _renameVideoFile(context, state, item);
          case 'moveFile':
            _moveVideoFile(context, state, item);
          case 'deleteFile':
            _deleteVideoFile(context, state, item);
          case 'detail':
            _showMediaDetail(context, item);
        }
      },
    );
  }
}

Future<void> _renameVideoFile(
  BuildContext context,
  LumioAppState state,
  MediaItem item,
) async {
  final name = await _showVideoFileInput(
    context,
    title: '重命名文件',
    label: '完整文件名',
    initialValue: item.path.split('/').last,
    confirmLabel: '重命名',
  );
  if (name == null || !context.mounted) {
    return;
  }
  final result = await state.renameMediaFile(item.id, name);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  }
}

Future<void> _moveVideoFile(
  BuildContext context,
  LumioAppState state,
  MediaItem item,
) async {
  final path = await _showVideoFileInput(
    context,
    title: '移动文件',
    label: '目标目录',
    hintText: '例如：Movies/Lumio',
    confirmLabel: '移动',
  );
  if (path == null || !context.mounted) {
    return;
  }
  final result = await state.moveMediaFiles(<String>[item.id], path);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  }
}

Future<void> _deleteVideoFile(
  BuildContext context,
  LumioAppState state,
  MediaItem item,
) async {
  final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('从媒体库移除'),
          content: const Text('只会从忆光当前媒体库移除，设备中的视频源文件不会被删除。'),
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
  if (!confirmed || !context.mounted) {
    return;
  }
  final result = await state.deleteMediaFiles(<String>[item.id]);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  }
}

Future<String?> _showVideoFileInput(
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

Future<void> _showMediaDetail(BuildContext context, MediaItem item) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('视频详情'),
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

String _mediaDetailText(MediaItem item) {
  final rows = <String>[
    '标题：${item.title}',
    '来源/作者：${item.artist}',
    '合集/相册：${item.album}',
    '时长：${formatDuration(item.duration)}',
    if (item.resolution != null) '分辨率：${item.resolution}',
    if (item.formatLabel != null) '格式：${item.formatLabel}',
    if (item.fileSizeLabel != null) '大小：${item.fileSizeLabel}',
    if (item.lastPosition > Duration.zero)
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
      title: const Text('编辑视频信息'),
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
            decoration: const InputDecoration(labelText: '来源/作者'),
            textInputAction: TextInputAction.next,
          ),
          TextField(
            controller: albumController,
            decoration: const InputDecoration(labelText: '合集/相册'),
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
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('视频标签暂只修改忆光列表信息，源文件不会改变。')),
      );
    }
  }
}

class _FolderList extends StatelessWidget {
  const _FolderList({required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: state.videoFolders.map((folder) {
        final items = state.videoItems
            .where((item) => item.folder == folder)
            .toList(growable: false);
        final first = items.first;
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
            leading: MediaArtwork(item: first, size: 58),
            title: Text(folder.split('/').last, style: textTheme.titleMedium),
            subtitle: Text(
              '$folder • ${items.length} 个视频',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: items
                .map(
                  (item) => MediaTile(
                    item: item,
                    onTap: () {
                      state.play(item);
                      _openNowPlaying(context, state);
                    },
                    trailing: _VideoMenu(
                      state: state,
                      item: item,
                      onPlay: () {
                        state.play(item);
                        _openNowPlaying(context, state);
                      },
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        );
      }).toList(),
    );
  }
}

class _PhaseNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final videoColor = LumioTheme.videoColor(context);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: videoColor.withValues(
          alpha: scheme.brightness == Brightness.dark ? 0.18 : 0.1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.picture_in_picture_alt_rounded, color: videoColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '本地视频已支持全屏手势、续播、自动连播和 Android 小窗；复杂 ASS 特效及其他平台小窗仍待补齐。',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _openNowPlaying(BuildContext context, LumioAppState state) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AnimatedBuilder(
        animation: state,
        builder: (context, _) => NowPlayingPage(state: state),
      ),
    ),
  );
}
