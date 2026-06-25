import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/models/media_item.dart';
import '../music/now_playing_page.dart';
import '../../shared/widgets/media_tile.dart';
import '../../shared/widgets/section_header.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.state});

  final EchoAppState state;

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('视频库'),
        actions: <Widget>[
          IconButton(
            tooltip: '随机播放视频',
            onPressed: () => state.shuffleAll(MediaKind.video),
            icon: const Icon(Icons.shuffle_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const <Widget>[
            Tab(text: 'Videos'),
            Tab(text: 'Folders'),
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

class _VideoList extends StatelessWidget {
  const _VideoList({required this.state});

  final EchoAppState state;

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

  final EchoAppState state;
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
          case 'detail':
            _showMediaDetail(context, item);
        }
      },
    );
  }
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
  EchoAppState state,
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
  }
}

class _FolderList extends StatelessWidget {
  const _FolderList({required this.state});

  final EchoAppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: state.videoFolders.map((folder) {
        final items = state.videoItems.where((item) => item.folder == folder);
        final first = items.first;
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: MediaArtwork(item: first, size: 58),
            title: Text(folder.split('/').last, style: textTheme.titleMedium),
            subtitle: Text(
              '$folder • ${items.length} 个视频',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              state.play(first);
              _openNowPlaying(context, state);
            },
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
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.picture_in_picture_alt_rounded, color: scheme.secondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Android 本地视频已接入 Texture 播放、小窗入口、续播进度和自动连播；全屏手势与亮度/音量滑动会继续补齐。',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _openNowPlaying(BuildContext context, EchoAppState state) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AnimatedBuilder(
        animation: state,
        builder: (context, _) => NowPlayingPage(state: state),
      ),
    ),
  );
}
