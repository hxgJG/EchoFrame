import 'package:flutter/foundation.dart';

import 'lyric_draft.dart';

class LyricAuthoring extends ChangeNotifier {
  LyricAuthoring(this.draft);
  LyricDraft draft;
  int revision = 0;
  final List<LyricDraft> _undo = [];
  final List<LyricDraft> _redo = [];
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void _change(LyricDraft next, {bool history = true}) {
    if (history) {
      _undo.add(draft);
      if (_undo.length > 100) _undo.removeAt(0);
      _redo.clear();
    }
    draft = next;
    revision++;
    notifyListeners();
  }

  void setSourceText(String text) {
    if (text == draft.sourceText) return;
    if (text.length > LyricDraft.maxTextLength)
      throw const FormatException('歌词文本不能超过 20 万字符。');
    _change(
        LyricDraft(
            sourceText: text, lines: draft.lines, selected: draft.selected),
        history: false);
  }

  List<String> _split(String text) => text
      .replaceAll('\uFEFF', '')
      .split(RegExp(r'\r\n|\r|\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  void splitSource() {
    final lines = _split(draft.sourceText);
    if (lines.isEmpty || lines.length > LyricDraft.maxLines)
      throw const FormatException('请输入 1～5000 行非空歌词。');
    _change(LyricDraft(
        sourceText: draft.sourceText,
        lines: lines.map((line) => LyricDraftLine(line)).toList()));
  }

  void select(int index) {
    if (index < 0 || index >= draft.lines.length) return;
    _change(
        LyricDraft(
            sourceText: draft.sourceText, lines: draft.lines, selected: index),
        history: false);
  }

  void mark(int milliseconds, Duration duration) {
    final index = draft.selected;
    if (index >= draft.lines.length)
      throw const FormatException('所有句子已标记，可选中某句重新打轴。');
    if (milliseconds < 0 ||
        duration <= Duration.zero ||
        milliseconds > duration.inMilliseconds)
      throw const FormatException('标记时间超出歌曲时长。');
    int? previous, next;
    for (var i = index - 1; i >= 0; i--) {
      if (draft.lines[i].timeMs != null) {
        previous = draft.lines[i].timeMs;
        break;
      }
    }
    for (var i = index + 1; i < draft.lines.length; i++) {
      if (draft.lines[i].timeMs != null) {
        next = draft.lines[i].timeMs;
        break;
      }
    }
    if ((previous != null && milliseconds <= previous) ||
        (next != null && milliseconds >= next)) {
      throw const FormatException('时间必须位于前后已标记句子之间。可清除相邻标记后重打。');
    }
    final lines = List<LyricDraftLine>.of(draft.lines);
    lines[index] = LyricDraftLine(lines[index].text, milliseconds);
    _change(LyricDraft(
        sourceText: draft.sourceText, lines: lines, selected: index + 1));
  }

  void clearTime() {
    if (draft.selected >= draft.lines.length) return;
    final lines = List<LyricDraftLine>.of(draft.lines);
    lines[draft.selected] = LyricDraftLine(lines[draft.selected].text);
    _change(LyricDraft(
        sourceText: draft.sourceText, lines: lines, selected: draft.selected));
  }

  void replaceLine(String text, {bool insert = false}) {
    final parts = _split(text);
    if (parts.isEmpty) throw const FormatException('歌词不能为空。');
    final lines = List<LyricDraftLine>.of(draft.lines);
    final index = draft.selected.clamp(0, lines.length);
    final time = !insert && index < lines.length ? lines[index].timeMs : null;
    if (!insert && index < lines.length) lines.removeAt(index);
    lines.insertAll(index, [
      for (var i = 0; i < parts.length; i++)
        LyricDraftLine(parts[i], i == 0 ? time : null)
    ]);
    if (lines.length > LyricDraft.maxLines ||
        lines.fold<int>(0, (sum, row) => sum + row.text.length) >
            LyricDraft.maxTextLength)
      throw const FormatException('歌词超出 5000 行或 20 万字符限制。');
    _change(LyricDraft(
        sourceText: lines.map((line) => line.text).join('\n'),
        lines: lines,
        selected: index));
  }

  void mergeNext() {
    final index = draft.selected;
    if (index + 1 >= draft.lines.length) return;
    final lines = List<LyricDraftLine>.of(draft.lines);
    lines[index] = LyricDraftLine(
        '${lines[index].text} ${lines[index + 1].text}', lines[index].timeMs);
    lines.removeAt(index + 1);
    _change(LyricDraft(
        sourceText: lines.map((line) => line.text).join('\n'),
        lines: lines,
        selected: index));
  }

  void deleteLine() {
    if (draft.selected >= draft.lines.length) return;
    final lines = List<LyricDraftLine>.of(draft.lines)
      ..removeAt(draft.selected);
    _change(LyricDraft(
        sourceText: lines.map((line) => line.text).join('\n'),
        lines: lines,
        selected: draft.selected.clamp(0, lines.length)));
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(draft);
    _change(_undo.removeLast(), history: false);
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(draft);
    _change(_redo.removeLast(), history: false);
  }
}
