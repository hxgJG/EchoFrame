import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/models/media_item.dart';
import '../../shared/widgets/media_tile.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.state});

  final EchoAppState state;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = _controller.text;
    final results = widget.state.search(query);
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          TextField(
            controller: _controller,
            autofocus: false,
            decoration: InputDecoration(
              hintText: '搜索歌曲、艺术家、专辑、视频或文件夹',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
                      onPressed: () {
                        _controller.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          if (query.trim().isEmpty)
            const _SearchEmpty(
              icon: Icons.manage_search_rounded,
              title: '输入关键词开始本地搜索',
              message: '搜索只读取本机媒体索引，不需要网络。',
            )
          else if (results.isEmpty)
            const _SearchEmpty(
              icon: Icons.search_off_rounded,
              title: '没有找到匹配内容',
              message: '可以尝试标题、艺术家、专辑或文件夹名。',
            )
          else
            ...results.map(
              (item) => MediaTile(
                item: item,
                onTap: () => widget.state.play(item),
                trailing: Icon(
                  item.kind == MediaKind.audio
                      ? Icons.music_note_rounded
                      : Icons.movie_rounded,
                  color: scheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SearchEmpty extends StatelessWidget {
  const _SearchEmpty({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: <Widget>[
          Icon(icon, color: scheme.primary, size: 42),
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
    );
  }
}
