import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/lyrics/lyric_library.dart';
import '../../core/models/media_item.dart';
import '../../platform/media_library/lyrics_export_result.dart';

class LyricLibraryPage extends StatefulWidget {
  const LyricLibraryPage({super.key, required this.state});
  final LumioAppState state;
  @override
  State<LyricLibraryPage> createState() => _LyricLibraryPageState();
}

class _LyricLibraryPageState extends State<LyricLibraryPage> {
  String _query = '';
  bool _pendingOnly = false;
  bool _working = false;
  LumioAppState get state => widget.state;

  Future<void> _run(Future<String?> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final message = await action();
      if (mounted && message != null)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作未完成：$error')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String?> _import() async {
    final preview = await state.readLyricPackage();
    if (preview == null || !mounted) return null;
    final expected = state.lyricImportContext;
    var overwrite = true;
    var syncMetadata = true;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('导入歌词包'),
                  content: SizedBox(
                      width: 540,
                      child: SingleChildScrollView(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(preview.fileName),
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('覆盖已有歌词，优先使用本次导入'),
                                subtitle: const Text('关闭后仅补充缺失歌词；也适用于后续添加的歌曲。'),
                                value: overwrite,
                                onChanged: (value) =>
                                    setDialogState(() => overwrite = value)),
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('同步歌曲展示信息'),
                                subtitle: const Text(
                                    '同步歌名、艺术家、专辑；保留原名称为匹配别名，不改文件名或音频标签。空字段不覆盖。'),
                                value: syncMetadata,
                                onChanged: (value) =>
                                    setDialogState(() => syncMetadata = value)),
                            Text(state.lyricImportSummary(preview, overwrite)),
                            if (preview.warnings.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(preview.warnings.join('\n')),
                            ],
                            const SizedBox(height: 12),
                            Text(preview.entries
                                .take(6)
                                .map((e) => '${e.title} · ${e.artist}')
                                .join('\n')),
                            if (preview.entries.length > 6) const Text('……'),
                          ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('确认导入'))
                  ],
                )));
    if (confirmed != true) return null;
    return state.importLyricPackage(preview,
        overwrite: overwrite,
        syncMetadata: syncMetadata,
        expectedContext: expected);
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: Text(title), content: Text(text), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确认')),
              ])) ==
      true;

  Future<String?> _associate(LyricLibraryEntry entry,
      {bool detach = false}) async {
    var query = '';
    final selected = await showDialog<MediaItem>(
        context: context,
        builder: (context) =>
            StatefulBuilder(builder: (context, setDialogState) {
              final items = state.audioItems
                  .where((item) =>
                      (!detach || entry.handled.containsKey(item.path)) &&
                      '${item.title} ${item.artist}'
                          .toLowerCase()
                          .contains(query))
                  .toList();
              return AlertDialog(
                  title: Text(detach ? '解除关联' : '选择歌曲 · ${entry.title}'),
                  content: SizedBox(
                      width: 540,
                      height: 360,
                      child: Column(children: [
                        TextField(
                            decoration:
                                const InputDecoration(labelText: '搜索歌曲或歌手'),
                            onChanged: (value) => setDialogState(
                                () => query = value.trim().toLowerCase())),
                        Expanded(
                            child: items.isEmpty
                                ? const Center(
                                    child: Text('没有可选择的歌曲，请先扫描本机音频。'))
                                : ListView.builder(
                                    itemCount: items.length,
                                    itemBuilder: (context, index) {
                                      final item = items[index];
                                      return ListTile(
                                          title: Text(item.title),
                                          subtitle: Text(
                                              '${item.artist} · ${item.duration.inSeconds} 秒\n${lyricAudioName(item.path)}'),
                                          onTap: () =>
                                              Navigator.pop(context, item));
                                    })),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'))
                  ]);
            }));
    if (selected == null || !mounted) return null;
    if (detach) {
      if (!await _confirm('解除关联', '保留《${selected.title}》当前歌词，但不再自动关联此路径。'))
        return null;
      return state.detachLyricEntry(entry.id, selected.path);
    }
    if (!await _confirm('应用歌词',
        '将此歌词关联到《${selected.title}》。${entry.syncMetadata ? '同时同步歌名、艺术家和专辑。' : ''}${selected.lyrics.isNotEmpty ? '已有歌词及单曲校准将被替换，可通过歌词库撤销。' : ''}'))
      return null;
    return state.associateLyricEntry(entry.id, selected.id, overwrite: true);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final busy = _working || state.lyricLibraryBusy;
        final entries = state.lyricLibraryEntries.reversed
            .where((entry) =>
                (!_pendingOnly ||
                    state.lyricEntryStatus(entry).startsWith('待')) &&
                '${entry.title} ${entry.artist}'.toLowerCase().contains(_query))
            .toList();
        return Scaffold(
            appBar: AppBar(title: const Text('歌词库与跨设备迁移')),
            body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                                '歌词包独立保存，不包含音频。未找到歌曲的歌词会等待以后扫描匹配；多个版本或旧包可手动关联。'),
                            if (state.lyricLibraryError != null)
                              Text(state.lyricLibraryError!,
                                  style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error)),
                            const SizedBox(height: 12),
                            Wrap(spacing: 8, runSpacing: 8, children: [
                              FilledButton.icon(
                                  onPressed:
                                      busy || state.lyricLibraryError != null
                                          ? null
                                          : () => _run(_import),
                                  icon: const Icon(Icons.upload_file),
                                  label: const Text('导入歌词包')),
                              OutlinedButton.icon(
                                  onPressed: busy ||
                                          state.lyricLibraryError != null
                                      ? null
                                      : () => _run(() async {
                                            final result = await state
                                                .exportLyricPackage();
                                            return result.status ==
                                                    LyricsExportStatus.cancelled
                                                ? null
                                                : result.message;
                                          }),
                                  icon: const Icon(Icons.folder_zip_outlined),
                                  label: const Text('导出跨设备歌词包')),
                              TextButton.icon(
                                  onPressed: busy || !state.canUndoLyricLibrary
                                      ? null
                                      : () => _run(() async {
                                            if (!await _confirm('撤销最近一次歌词库操作',
                                                '恢复之前的歌词库和被覆盖的歌词；之后另行编辑过的歌曲不会被回退。'))
                                              return null;
                                            return state.undoLyricLibrary();
                                          }),
                                  icon: const Icon(Icons.undo),
                                  label: const Text('撤销最近操作')),
                            ]),
                            const SizedBox(height: 8),
                            Text(
                                '当前歌曲歌词 ${state.exportableLyricsCount} 首 · 歌词库 ${state.lyricLibraryEntries.length} 条（含历史版本）'),
                            TextField(
                                decoration: const InputDecoration(
                                    prefixIcon: Icon(Icons.search),
                                    hintText: '搜索歌词库歌名或歌手'),
                                onChanged: (value) => setState(
                                    () => _query = value.trim().toLowerCase())),
                            FilterChip(
                                label: const Text('仅看待匹配'),
                                selected: _pendingOnly,
                                onSelected: (value) =>
                                    setState(() => _pendingOnly = value)),
                          ])),
                  if (busy) const LinearProgressIndicator(),
                  Expanded(
                      child: entries.isEmpty
                          ? const Center(child: Text('暂无记录。可先导入歌词包，再添加歌曲。'))
                          : ListView.builder(
                              itemCount: entries.length,
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                return ListTile(
                                    leading: Icon(entry.active
                                        ? Icons.lyrics_outlined
                                        : Icons.history),
                                    title: Text(entry.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    subtitle: Text(
                                        '${entry.artist} · ${state.lyricEntryStatus(entry)}\n${entry.overwrite ? '优先导入歌词' : '仅补充缺失'} · ${entry.lyrics.length} 行'),
                                    onTap: () => showDialog<void>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                                title: Text(entry.title),
                                                content: SizedBox(
                                                    width: 480,
                                                    child: SingleChildScrollView(
                                                        child: Text(
                                                            '来源：${entry.source}\n单曲校准：${entry.offsetMs} ms\n\n${entry.lyrics.take(30).map((e) => e.text).join('\n')}'))),
                                                actions: [
                                                  TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                              context),
                                                      child: const Text('关闭'))
                                                ])),
                                    trailing: PopupMenuButton<String>(
                                        enabled: !busy,
                                        onSelected: (action) => _run(() async {
                                              if (action == 'associate')
                                                return _associate(entry);
                                              if (action == 'detach')
                                                return _associate(entry,
                                                    detach: true);
                                              if (!await _confirm('删除歌词库记录',
                                                  '仅删除此记录，已应用到歌曲的歌词保留。可撤销本次操作。'))
                                                return null;
                                              return state
                                                  .deleteLyricEntry(entry.id);
                                            }),
                                        itemBuilder: (_) => [
                                              const PopupMenuItem(
                                                  value: 'associate',
                                                  child: Text('手动关联 / 应用此版本')),
                                              if (entry.handled.isNotEmpty)
                                                const PopupMenuItem(
                                                    value: 'detach',
                                                    child: Text('解除歌曲关联')),
                                              const PopupMenuItem(
                                                  value: 'delete',
                                                  child: Text('删除记录')),
                                            ]));
                              })),
                ]));
      });
}
