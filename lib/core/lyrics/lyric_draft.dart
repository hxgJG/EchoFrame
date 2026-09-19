class LyricDraftLine {
  const LyricDraftLine(this.text, [this.timeMs]);
  final String text;
  final int? timeMs;

  Map<String, Object?> toJson() => {'text': text, 'timeMs': timeMs};
}

class LyricDraft {
  LyricDraft(
      {this.sourceText = '',
      List<LyricDraftLine> lines = const [],
      this.selected = 0})
      : lines = List.unmodifiable(lines);

  static const maxLines = 5000;
  static const maxTextLength = 200000;
  final String sourceText;
  final List<LyricDraftLine> lines;
  final int selected;

  static LyricDraft? fromJson(Object? value) {
    if (value is! Map || value['version'] != 1 || value['lines'] is! List)
      return null;
    final raw = value['lines'] as List;
    final text =
        value['sourceText'] is String ? value['sourceText'] as String : '';
    if (raw.length > maxLines || text.length > maxTextLength) return null;
    final lines = <LyricDraftLine>[];
    for (final row in raw) {
      if (row is! Map || row['text'] is! String) return null;
      final time = row['timeMs'];
      if (time != null && (time is! int || time < 0)) return null;
      lines.add(LyricDraftLine(row['text'] as String, time as int?));
    }
    if (lines.fold<int>(0, (sum, row) => sum + row.text.length) > maxTextLength)
      return null;
    final selected = value['selected'] is int ? value['selected'] as int : 0;
    return LyricDraft(
        sourceText: text,
        lines: lines,
        selected: selected.clamp(0, lines.length));
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'sourceText': sourceText,
        'selected': selected,
        'lines': lines.map((line) => line.toJson()).toList(growable: false),
      };

  List<String> validate(Duration duration) {
    if (lines.isEmpty) return ['请先输入并拆分歌词。'];
    final sourceLines = sourceText
        .replaceAll('\uFEFF', '')
        .split(RegExp(r'\r\n|\r|\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
    if (sourceLines != lines.map((line) => line.text).join('\n'))
      return ['输入文本已变化，请按行拆分后重新打轴，或恢复原文本。'];
    final errors = <String>[];
    if (duration <= Duration.zero) errors.add('歌曲时长未知，暂不能校验时间轴。');
    int? previous;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final time = line.timeMs;
      if (line.text.trim().isEmpty) errors.add('第 ${i + 1} 句为空。');
      if (time == null) {
        errors.add('第 ${i + 1} 句尚未打轴。');
      } else {
        if (time < 0 ||
            (duration > Duration.zero && time > duration.inMilliseconds))
          errors.add('第 ${i + 1} 句超出歌曲时长。');
        if (previous != null && time <= previous)
          errors.add('第 ${i + 1} 句时间未晚于上一句，请重新标记。');
        previous = time;
      }
      if (errors.length >= 8) {
        errors.add('请修正后重新校验其余行。');
        break;
      }
    }
    return errors;
  }
}
