import '../models/media_item.dart';

final RegExp _timeRangePattern = RegExp(
  r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})',
);

List<SubtitleCue> parseSrt(String text) {
  final cues = <SubtitleCue>[];
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final blocks = normalized.split(RegExp(r'\n{2,}'));
  for (final block in blocks) {
    final lines = block
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      continue;
    }
    final rangeIndex = lines.indexWhere(_timeRangePattern.hasMatch);
    if (rangeIndex < 0 || rangeIndex == lines.length - 1) {
      continue;
    }
    final match = _timeRangePattern.firstMatch(lines[rangeIndex]);
    if (match == null) {
      continue;
    }
    final start = _parseTimestamp(match, 1);
    final end = _parseTimestamp(match, 5);
    final cueText = lines.skip(rangeIndex + 1).join('\n').trim();
    if (cueText.isEmpty || end <= start) {
      continue;
    }
    cues.add(SubtitleCue(start: start, end: end, text: cueText));
  }
  cues.sort((a, b) => a.start.compareTo(b.start));
  return List<SubtitleCue>.unmodifiable(cues);
}

Duration _parseTimestamp(RegExpMatch match, int offset) {
  final hours = int.tryParse(match.group(offset) ?? '') ?? 0;
  final minutes = int.tryParse(match.group(offset + 1) ?? '') ?? 0;
  final seconds = int.tryParse(match.group(offset + 2) ?? '') ?? 0;
  final milliseconds = _fractionToMilliseconds(match.group(offset + 3) ?? '0');
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: milliseconds,
  );
}

int _fractionToMilliseconds(String value) {
  final normalized = value.padRight(3, '0').substring(0, 3);
  return int.tryParse(normalized) ?? 0;
}
