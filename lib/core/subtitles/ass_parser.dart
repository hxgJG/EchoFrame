import '../models/media_item.dart';

final RegExp _sectionPattern = RegExp(r'^\s*\[(.+)]\s*$');
final RegExp _overrideTagPattern = RegExp(r'\{[^}]*}');
final RegExp _drawingCommandPattern = RegExp(
  r'^\s*(m|n|l|b|s|p|c)\s+[-\d.\s]+$',
  caseSensitive: false,
);

List<SubtitleCue> parseAss(String text) {
  final cues = <SubtitleCue>[];
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  var inEvents = false;
  var startIndex = 1;
  var endIndex = 2;
  var textIndex = 9;
  var fieldCount = 10;

  for (final rawLine in normalized.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith(';')) {
      continue;
    }

    final section = _sectionPattern.firstMatch(line);
    if (section != null) {
      inEvents = section.group(1)?.toLowerCase() == 'events';
      continue;
    }
    if (!inEvents) {
      continue;
    }

    final separatorIndex = line.indexOf(':');
    if (separatorIndex < 0) {
      continue;
    }
    final type = line.substring(0, separatorIndex).trim().toLowerCase();
    final value = line.substring(separatorIndex + 1).trim();
    if (type == 'format') {
      final fields = value
          .split(',')
          .map((field) => field.trim().toLowerCase())
          .toList(growable: false);
      final nextStart = fields.indexOf('start');
      final nextEnd = fields.indexOf('end');
      final nextText = fields.indexOf('text');
      if (nextStart >= 0 && nextEnd >= 0 && nextText >= 0) {
        startIndex = nextStart;
        endIndex = nextEnd;
        textIndex = nextText;
        fieldCount = fields.length;
      }
      continue;
    }
    if (type != 'dialogue') {
      continue;
    }

    final fields = _splitDialogueFields(value, fieldCount);
    if (fields.length <= textIndex ||
        fields.length <= startIndex ||
        fields.length <= endIndex) {
      continue;
    }
    final start = _parseAssTimestamp(fields[startIndex]);
    final end = _parseAssTimestamp(fields[endIndex]);
    final cueText = _cleanAssText(fields[textIndex]);
    if (start == null || end == null || end <= start || cueText.isEmpty) {
      continue;
    }
    cues.add(SubtitleCue(start: start, end: end, text: cueText));
  }

  cues.sort((a, b) => a.start.compareTo(b.start));
  return List<SubtitleCue>.unmodifiable(cues);
}

List<String> _splitDialogueFields(String value, int fieldCount) {
  final limit = fieldCount <= 1 ? 10 : fieldCount;
  final fields = <String>[];
  var start = 0;
  for (var i = 1; i < limit; i += 1) {
    final commaIndex = value.indexOf(',', start);
    if (commaIndex < 0) {
      break;
    }
    fields.add(value.substring(start, commaIndex));
    start = commaIndex + 1;
  }
  fields.add(value.substring(start));
  return fields;
}

Duration? _parseAssTimestamp(String value) {
  final parts = value.trim().split(':');
  if (parts.length != 3) {
    return null;
  }
  final hours = int.tryParse(parts[0]);
  final minutes = int.tryParse(parts[1]);
  final secondParts = parts[2].split('.');
  if (secondParts.length != 2) {
    return null;
  }
  final seconds = int.tryParse(secondParts[0]);
  final centiseconds =
      int.tryParse(secondParts[1].padRight(2, '0').substring(0, 2));
  if (hours == null ||
      minutes == null ||
      seconds == null ||
      centiseconds == null) {
    return null;
  }
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: centiseconds * 10,
  );
}

String _cleanAssText(String value) {
  final withoutTags = value
      .replaceAll(_overrideTagPattern, '')
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\h', ' ');
  final lines = withoutTags
      .split('\n')
      .map((line) => line.trim())
      .where(
          (line) => line.isNotEmpty && !_drawingCommandPattern.hasMatch(line))
      .toList(growable: false);
  return lines.join('\n').trim();
}
