import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../core/models/media_item.dart';
import '../../shared/widgets/media_tile.dart';
import '../music/audio_selection.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.state});

  final LumioAppState state;

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
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.state,
        builder: (context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final state = widget.state;
    final query = _controller.text;
    final results = state.search(query);
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          TextField(
            controller: _controller,
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
          if (query.trim().isEmpty) ...<Widget>[
            if (state.recentSearches.isNotEmpty)
              _RecentSearches(
                values: state.recentSearches,
                onSelected: (value) {
                  _controller.text = value;
                  _controller.selection =
                      TextSelection.collapsed(offset: _controller.text.length);
                  state.recordSearch(value);
                  setState(() {});
                },
                onRemove: state.removeRecentSearch,
                onClear: state.clearRecentSearches,
              ),
            if (state.recentSearches.isNotEmpty) const SizedBox(height: 16),
            const _SearchEmpty(
              icon: Icons.manage_search_rounded,
              title: '输入关键词开始本地搜索',
              message: '搜索只读取本机媒体索引，不需要网络。',
            ),
          ] else if (results.isEmpty)
            const _SearchEmpty(
              icon: Icons.search_off_rounded,
              title: '没有找到匹配内容',
              message: '可以尝试标题、艺术家、专辑或文件夹名。',
            )
          else
            ...results.map(
              (item) => MediaTile(
                item: item,
                onTap: () {
                  state.recordSearch(query);
                  selectAudioItem(context, state, item);
                },
                trailing: Icon(
                  item.kind == MediaKind.audio
                      ? Icons.music_note_rounded
                      : Icons.movie_rounded,
                  color: LumioTheme.mediaColor(
                    item.kind,
                    context,
                  ),
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

/// 搜索历史：点按直接复用，右侧可单条删除，也可整体清空。
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({
    required this.values,
    required this.onSelected,
    required this.onRemove,
    required this.onClear,
  });

  final List<String> values;
  final ValueChanged<String> onSelected;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child:
                  Text('最近搜索', style: Theme.of(context).textTheme.titleMedium),
            ),
            TextButton(onPressed: onClear, child: const Text('清空')),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: values
              .map((value) => InputChip(
                    label: Text(value),
                    avatar: Icon(Icons.history_rounded,
                        size: 18, color: scheme.onSurfaceVariant),
                    onPressed: () => onSelected(value),
                    onDeleted: () => onRemove(value),
                    deleteButtonTooltipMessage: '删除这条记录',
                  ))
              .toList(growable: false),
        ),
      ],
    );
  }
}
