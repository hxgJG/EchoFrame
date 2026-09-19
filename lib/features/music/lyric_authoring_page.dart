import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../core/lyrics/lyric_authoring.dart';
import '../../core/lyrics/lyric_draft.dart';
import '../../core/models/media_item.dart';

class LyricAuthoringPage extends StatefulWidget {
  const LyricAuthoringPage(
      {super.key, required this.state, required this.item});
  final LumioAppState state;
  final MediaItem item;
  @override
  State<LyricAuthoringPage> createState() => _LyricAuthoringPageState();
}

class _LyricAuthoringPageState extends State<LyricAuthoringPage> {
  late final LyricAuthoring editor;
  late final TextEditingController source;
  final rows = ScrollController();
  final focus = FocusNode();
  Timer? debounce;
  Future<void>? pendingSave;
  int savedRevision = 0;
  bool busy = false, marking = false, preview = false, allowClose = false;
  int activeLine = -1;
  String saveStatus = '草稿自动保存';
  LumioAppState get app => widget.state;
  MediaItem get item => app.authoringItem(widget.item.id) ?? widget.item;
  bool get matching => app.currentItem?.id == item.id;

  @override
  void initState() {
    super.initState();
    editor = LyricAuthoring(item.lyricDraft ?? LyricDraft());
    source = TextEditingController(text: editor.draft.sourceText);
    if (item.lyricDraft != null) saveStatus = '已恢复制作草稿';
    editor.addListener(changed);
    app.addListener(refresh);
    app.lyricChanges.addListener(clockChanged);
    app.attachAuthoring();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  void message(Object error) {
    if (!mounted) return;
    final text = error is FormatException
        ? error.message
        : error is StateError
            ? error.message
            : error.toString();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void action(VoidCallback run) {
    try {
      run();
    } catch (error) {
      message(error);
    }
  }

  void changed() {
    preview = false;
    if (source.text != editor.draft.sourceText) {
      source.value = TextEditingValue(
          text: editor.draft.sourceText,
          selection:
              TextSelection.collapsed(offset: editor.draft.sourceText.length));
    }
    saveStatus = '草稿有未保存修改';
    debounce?.cancel();
    debounce = Timer(const Duration(seconds: 2), () async {
      try {
        await save();
      } catch (_) {
        if (mounted) setState(() => saveStatus = '自动保存失败，请点击保存草稿重试');
      }
    });
    setState(() {});
    scrollTo(preview ? activeLine : editor.draft.selected);
  }

  Future<void> save() async {
    if (pendingSave != null) await pendingSave;
    if (savedRevision == editor.revision) return;
    final revision = editor.revision;
    final operation = app.saveLyricDraft(item.id, editor.draft);
    pendingSave = operation;
    try {
      await operation;
      savedRevision = revision;
      if (mounted)
        setState(() =>
            saveStatus = editor.revision == revision ? '草稿已保存' : '草稿有未保存修改');
    } finally {
      pendingSave = null;
    }
  }

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(title),
                content: Text(body),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认')),
                ],
              )) ??
      false;

  Future<void> close() async {
    if (busy) return;
    setState(() => busy = true);
    debounce?.cancel();
    try {
      await save();
    } catch (_) {
      if (!mounted) return;
      if (!await confirm('草稿保存失败', '是否放弃本次未保存修改并退出？')) {
        if (mounted) setState(() => busy = false);
        return;
      }
    }
    if (!mounted) return;
    setState(() => allowClose = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> perform(Future<void> Function() run) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await run();
    } catch (error) {
      message(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void playPause() {
    if (matching) {
      app.togglePlaying();
    } else {
      app.play(item);
    }
  }

  Future<void> mark() async {
    if (busy || marking || preview) return;
    final revision = editor.revision;
    setState(() => marking = true);
    try {
      final time = await app.authoringPosition(item.id);
      if (!mounted || revision != editor.revision) return;
      editor.mark(time.inMilliseconds, item.duration);
    } catch (error) {
      message(error);
    } finally {
      if (mounted) setState(() => marking = false);
    }
  }

  void scrollTo(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !rows.hasClients || index < 0) return;
      final offset = (index * 64.0 - rows.position.viewportDimension / 2 + 32)
          .clamp(0.0, rows.position.maxScrollExtent);
      rows.animateTo(offset,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  void clockChanged() {
    if (!mounted || !preview) return;
    final time = matching ? app.position.inMilliseconds : -1;
    var next = -1;
    for (var i = 0; i < editor.draft.lines.length; i++) {
      final start = editor.draft.lines[i].timeMs;
      if (start != null && start <= time) next = i;
    }
    if (next != activeLine) {
      setState(() => activeLine = next);
      scrollTo(next);
    }
  }

  void validate() {
    final errors = editor.draft.validate(item.duration);
    if (errors.isNotEmpty) throw FormatException(errors.join('\n'));
  }

  Future<void> editLine({bool insert = false}) async {
    final index = editor.draft.selected;
    final input = TextEditingController(
        text: !insert && index < editor.draft.lines.length
            ? editor.draft.lines[index].text
            : '');
    final text = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(insert ? '插入歌词' : '编辑 / 拆分歌词'),
              content: TextField(
                  controller: input,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: LyricDraft.maxTextLength,
                  decoration: const InputDecoration(
                      helperText: '换行拆分；只保留第一行原有时间，其余需重新标记。')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, input.text),
                    child: const Text('保存'))
              ],
            ));
    // 等待对话框退场，避免仍在使用的输入控件访问已释放的控制器。
    Future<void>.delayed(const Duration(milliseconds: 400), input.dispose);
    if (mounted && text != null)
      action(() => editor.replaceLine(text, insert: insert));
  }

  Future<void> editTime(int index) async {
    final input = TextEditingController(
        text: ((editor.draft.lines[index].timeMs ?? 0) / 1000)
            .toStringAsFixed(3));
    final text = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('调整当前句时间'),
              content: TextField(
                  controller: input,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: '秒，例如 12.350')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, input.text),
                    child: const Text('保存'))
              ],
            ));
    Future<void>.delayed(const Duration(milliseconds: 400), input.dispose);
    if (!mounted || text == null) return;
    action(() {
      final seconds = double.tryParse(text);
      if (seconds == null || !seconds.isFinite)
        throw const FormatException('请输入有效秒数。');
      editor.select(index);
      editor.mark((seconds * 1000).round(), item.duration);
      editor.select(index);
    });
  }

  KeyEventResult key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        busy ||
        ModalRoute.of(context)?.isCurrent != true ||
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<EditableText>() !=
            null) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyZ) {
      keyboard.isShiftPressed ? editor.redo() : editor.undo();
    } else if (event.logicalKey == LogicalKeyboardKey.space) {
      playPause();
    } else if (event.logicalKey == LogicalKeyboardKey.f8 ||
        event.logicalKey == LogicalKeyboardKey.enter) {
      mark();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: allowClose,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) close();
        },
        child: Focus(
            focusNode: focus,
            autofocus: true,
            onKeyEvent: key,
            child: Scaffold(
              appBar: AppBar(
                  title: const Text('制作 LRC 歌词'),
                  leading: IconButton(
                      onPressed: close, icon: const Icon(Icons.arrow_back))),
              body: SafeArea(
                  child: AbsorbPointer(
                      absorbing: busy,
                      child: LayoutBuilder(
                          builder: (context, viewport) => SingleChildScrollView(
                              child: SizedBox(
                                  height: viewport.maxHeight.clamp(
                                      viewport.maxWidth < 840 ? 850.0 : 580.0,
                                      double.infinity),
                                  child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(children: [
                                        Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(item.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleLarge)),
                                        player(),
                                        Expanded(child: LayoutBuilder(
                                            builder: (context, constraints) {
                                          final textPanel = Column(children: [
                                            Expanded(
                                                child: TextField(
                                                    controller: source,
                                                    expands: true,
                                                    maxLines: null,
                                                    minLines: null,
                                                    maxLength: LyricDraft
                                                        .maxTextLength,
                                                    onChanged: (value) => action(
                                                        () =>
                                                            editor
                                                                .setSourceText(
                                                                    value)),
                                                    decoration:
                                                        const InputDecoration(
                                                            border:
                                                                OutlineInputBorder(),
                                                            labelText: '粘贴歌词文本',
                                                            alignLabelWithHint:
                                                                true,
                                                            counterText: ''))),
                                            Wrap(spacing: 8, children: [
                                              TextButton(
                                                  onPressed: () =>
                                                      perform(() async {
                                                        final result = await app
                                                            .importAuthoringText();
                                                        if (mounted &&
                                                            result.didImport)
                                                          editor.setSourceText(
                                                              result
                                                                  .lyricsText);
                                                        else if (mounted &&
                                                            result.message
                                                                .isNotEmpty)
                                                          message(
                                                              result.message);
                                                      }),
                                                  child: const Text('导入 TXT')),
                                              TextButton(
                                                  onPressed: () =>
                                                      perform(() async {
                                                        if (editor.draft.lines
                                                                .isNotEmpty &&
                                                            !await confirm(
                                                                '重新拆分？',
                                                                '会清除现有打轴时间，可撤销。'))
                                                          return;
                                                        if (mounted) {
                                                          preview = false;
                                                          editor.splitSource();
                                                        }
                                                      }),
                                                  child: const Text('按行拆分')),
                                            ]),
                                          ]);
                                          if (constraints.maxWidth >= 840)
                                            return Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  SizedBox(
                                                      width: 280,
                                                      child: textPanel),
                                                  const SizedBox(width: 16),
                                                  Expanded(child: timeline())
                                                ]);
                                          return Column(children: [
                                            SizedBox(
                                                height:
                                                    constraints.maxHeight > 350
                                                        ? 140
                                                        : 80,
                                                child: textPanel),
                                            const SizedBox(height: 8),
                                            Expanded(child: timeline())
                                          ]);
                                        })),
                                        Wrap(
                                            spacing: 8,
                                            runSpacing: 4,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              FilledButton.icon(
                                                  onPressed: marking || preview
                                                      ? null
                                                      : () {
                                                          focus.requestFocus();
                                                          mark();
                                                        },
                                                  icon: const Icon(Icons.flag),
                                                  label: Text(marking
                                                      ? '读取时间…'
                                                      : '标记并下一句（Enter）')),
                                              TextButton(
                                                  onPressed: () =>
                                                      perform(save),
                                                  child: const Text('保存草稿')),
                                              TextButton(
                                                  onPressed: () => action(() {
                                                        if (!preview)
                                                          validate();
                                                        setState(() =>
                                                            preview = !preview);
                                                        clockChanged();
                                                      }),
                                                  child: Text(preview
                                                      ? '退出预览'
                                                      : '同步预览')),
                                              TextButton(
                                                  onPressed:
                                                      () => perform(() async {
                                                            validate();
                                                            final original =
                                                                item;
                                                            if (!await confirm(
                                                                '应用到歌曲',
                                                                '将替换这首歌的正式歌词并重置单曲校准。制作草稿会保留，原音频文件不变。'))
                                                              return;
                                                            await save();
                                                            await app.applyAuthoredLyrics(
                                                                item.id,
                                                                editor.draft,
                                                                expectedLyrics:
                                                                    LyricTiming.signatureFor(
                                                                        original
                                                                            .lyrics),
                                                                expectedOffset:
                                                                    original
                                                                        .lyricTiming
                                                                        .offsetMs);
                                                            message('已应用到歌曲');
                                                          }),
                                                  child: const Text('应用到歌曲')),
                                              TextButton(
                                                  onPressed: () =>
                                                      perform(() async {
                                                        validate();
                                                        await save();
                                                        final result = await app
                                                            .exportAuthoredLyrics(
                                                                item.id,
                                                                editor.draft);
                                                        message(result
                                                                .message.isEmpty
                                                            ? '导出操作已完成'
                                                            : result.message);
                                                      }),
                                                  child: const Text('导出 LRC')),
                                            ]),
                                        Text(
                                            busy
                                                ? '正在处理…'
                                                : '$saveStatus · 空格播放/暂停 · Ctrl/⌘ Z 撤销',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall),
                                      ]))))))),
            )),
      );

  Widget player() => AnimatedBuilder(
      animation: app.lyricChanges,
      builder: (context, _) {
        final duration = item.duration.inMilliseconds;
        final position = matching ? app.position.inMilliseconds : 0;
        return Column(children: [
          Row(children: [
            IconButton(
                onPressed: playPause,
                tooltip: '播放 / 暂停',
                icon: Icon(matching && app.isPlaying
                    ? Icons.pause
                    : Icons.play_arrow)),
            Expanded(
                child: Slider(
                    value: duration > 0
                        ? (position / duration).clamp(0.0, 1.0)
                        : 0,
                    onChanged:
                        matching && duration > 0 ? app.seekToFraction : null)),
            Text('${stamp(position)} / ${stamp(duration)}'),
          ]),
          Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final seconds in [-5, 5])
                  TextButton(
                      onPressed: matching && duration > 0
                          ? () => app.seekToFraction(
                              ((position + seconds * 1000) / duration)
                                  .clamp(0.0, 1.0))
                          : null,
                      child: Text('${seconds > 0 ? '+' : ''}$seconds 秒')),
                DropdownButton<double>(
                    value: app.playbackSpeed,
                    items: [
                      for (var n = 5; n <= 20; n++)
                        DropdownMenuItem(
                            value: n / 10, child: Text('${n / 10}×'))
                    ],
                    onChanged: matching
                        ? (speed) {
                            if (speed != null) app.setPlaybackSpeed(speed);
                          }
                        : null),
                TextButton(
                    onPressed: matching ? app.setAbLoopStart : null,
                    child: const Text('设 A 点')),
                TextButton(
                    onPressed: matching
                        ? () {
                            final before = app.abLoopLabel;
                            app.setAbLoopEnd();
                            if (before == app.abLoopLabel)
                              message('请先设置 A 点，B 点需晚于 A 点。');
                          }
                        : null,
                    child: const Text('设 B 点')),
                TextButton(
                    onPressed: matching ? app.clearAbLoop : null,
                    child: const Text('清除 AB')),
                Text(matching ? app.abLoopLabel : '点击播放本曲后开始打轴'),
              ]),
          const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('逐句听到开头时标记；倍速与 AB 会作用于当前播放器，退出后仍保留。',
                  style: TextStyle(fontSize: 12))),
        ]);
      });

  Widget timeline() => Column(children: [
        Wrap(spacing: 4, children: [
          IconButton(
              onPressed: editor.canUndo ? editor.undo : null,
              tooltip: '撤销',
              icon: const Icon(Icons.undo)),
          IconButton(
              onPressed: editor.canRedo ? editor.redo : null,
              tooltip: '重做',
              icon: const Icon(Icons.redo)),
          TextButton(onPressed: () => editLine(), child: const Text('编辑 / 拆分')),
          TextButton(
              onPressed: () => editLine(insert: true), child: const Text('插入')),
          TextButton(
              onPressed: () => action(editor.mergeNext),
              child: const Text('合并下句')),
          TextButton(onPressed: editor.clearTime, child: const Text('清除时间')),
          IconButton(
              onPressed: editor.deleteLine,
              tooltip: '删除当前句（可撤销）',
              icon: const Icon(Icons.delete_outline)),
        ]),
        Align(
            alignment: Alignment.centerLeft,
            child: Text(
                '已打轴 ${editor.draft.lines.where((line) => line.timeMs != null).length} / ${editor.draft.lines.length} 句 · 点击某句可重新打轴')),
        Expanded(
            child: editor.draft.lines.isEmpty
                ? const Center(child: Text('输入文本并按行拆分，然后播放歌曲、逐句标记。'))
                : ListView.builder(
                    controller: rows,
                    itemExtent: 64,
                    itemCount: editor.draft.lines.length,
                    itemBuilder: (context, index) {
                      final line = editor.draft.lines[index];
                      final selected = preview
                          ? index == activeLine
                          : index == editor.draft.selected;
                      return ListTile(
                          selected: selected,
                          selectedTileColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          leading: Text('${index + 1}'),
                          title: Text(line.text,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: TextButton(
                              onPressed: () => editTime(index),
                              child: Text(line.timeMs == null
                                  ? '未标记'
                                  : stamp(line.timeMs!))),
                          onTap: () {
                            setState(() => preview = false);
                            editor.select(index);
                            focus.requestFocus();
                          });
                    },
                  )),
      ]);

  String stamp(int ms) =>
      '${(ms ~/ 60000).toString().padLeft(2, '0')}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}';

  @override
  void dispose() {
    debounce?.cancel();
    app.removeListener(refresh);
    app.lyricChanges.removeListener(clockChanged);
    app.detachAuthoring();
    editor.removeListener(changed);
    editor.dispose();
    source.dispose();
    rows.dispose();
    focus.dispose();
    super.dispose();
  }
}
