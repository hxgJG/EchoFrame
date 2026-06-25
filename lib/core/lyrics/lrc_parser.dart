import '../models/media_item.dart';

final RegExp _timestampPattern =
    RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');

List<LyricLine> parseLrc(String text) {
  final lines = <LyricLine>[];
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final matches = _timestampPattern.allMatches(rawLine).toList();
    if (matches.isEmpty) {
      continue;
    }
    final lyricText = rawLine.replaceAll(_timestampPattern, '').trim();
    if (lyricText.isEmpty) {
      continue;
    }
    for (final match in matches) {
      final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
      final fraction = match.group(3) ?? '0';
      final milliseconds = _fractionToMilliseconds(fraction);
      lines.add(
        LyricLine(
          time: Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: milliseconds,
          ),
          text: lyricText,
        ),
      );
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return List<LyricLine>.unmodifiable(lines);
}

int _fractionToMilliseconds(String value) {
  final normalized = value.padRight(3, '0').substring(0, 3);
  return int.tryParse(normalized) ?? 0;
}
