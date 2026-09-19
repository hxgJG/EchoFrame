import 'dart:convert';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

String subtitleId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class EditableSubtitle {
  const EditableSubtitle(
      {required this.id, this.startMs, this.endMs, required this.text});
  final String id;
  final int? startMs;
  final int? endMs;
  final String text;

  factory EditableSubtitle.fromJson(Map<String, dynamic> value) =>
      EditableSubtitle(
          id: value['id'] as String,
          startMs: value['startMs'] as int?,
          endMs: value['endMs'] as int?,
          text: value['text'] as String);

  Map<String, dynamic> toJson() =>
      {'id': id, 'startMs': startMs, 'endMs': endMs, 'text': text};
  String? get error {
    if (startMs == null || endMs == null) return '请标记开始和结束时间';
    if (startMs! < 0 || endMs! <= startMs! || endMs! > 604800000)
      return '时间须满足 0 ≤ 开始 < 结束（最长 7 天）';
    if (text.trim().isEmpty) return '请输入字幕文字';
    if (text.contains('\u0000') || utf8.encode(text).length > 16384)
      return '文字含非法字符或超过 16 KiB';
    return null;
  }

  EditableSubtitle shift(int delta) => EditableSubtitle(
      id: id,
      startMs: startMs == null ? null : startMs! + delta,
      endMs: endMs == null ? null : endMs! + delta,
      text: text);
}

class SubtitleProject {
  SubtitleProject(
      {required this.id,
      required this.name,
      required this.source,
      this.revision = 0,
      List<EditableSubtitle>? cues,
      Map<String, dynamic>? style,
      this.libraryBinding,
      this.importName = '',
      this.applyOrigin = 'edited'})
      : cues = cues ?? [],
        style = style ??
            {
              'fontFraction': 0.045,
              'bottomFraction': 0.08,
              'color': 'white',
              'background': true
            };
  final String id;
  String name;
  Map<String, dynamic> source;
  int revision;
  List<EditableSubtitle> cues;
  Map<String, dynamic> style;
  Map<String, dynamic>? libraryBinding;
  String importName;
  String applyOrigin;

  factory SubtitleProject.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1)
      throw const FormatException('项目版本不受支持，文件未被修改。');
    final project = SubtitleProject(
        id: json['id'] as String,
        name: json['name'] as String,
        source: Map<String, dynamic>.from(json['source'] as Map),
        revision: json['revision'] as int,
        cues: (json['cues'] as List)
            .map((e) =>
                EditableSubtitle.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        style: Map<String, dynamic>.from(json['style'] as Map),
        libraryBinding: json['libraryBinding'] == null
            ? null
            : Map<String, dynamic>.from(json['libraryBinding'] as Map),
        importName: json['importName'] as String? ?? '',
        applyOrigin: json['applyOrigin'] == 'sidecar' ? 'sidecar' : 'edited');
    if (project.cues.length > 20000)
      throw const FormatException('项目超过 20000 句。');
    final font = project.style['fontFraction'],
        bottom = project.style['bottomFraction'];
    if (font is! num ||
        !font.isFinite ||
        font < .018 ||
        font > .09 ||
        bottom is! num ||
        !bottom.isFinite ||
        bottom < .02 ||
        bottom > .55 ||
        !['white', 'yellow', 'cyan'].contains(project.style['color']) ||
        project.style['background'] is! bool) {
      throw const FormatException('项目样式数据无效，未修改原文件。');
    }
    return project;
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'id': id,
        'name': name,
        'source': source,
        'revision': revision,
        'cues': cues.map((e) => e.toJson()).toList(),
        'style': style,
        'libraryBinding': libraryBinding,
        'importName': importName,
        'applyOrigin': applyOrigin,
      };

  String? get validationError {
    if (cues.isEmpty || cues.length > 20000) return '请提供 1～20000 句字幕';
    final identities = <String>{};
    var total = 0;
    final events = <(int, int)>[];
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      if (cue.error != null) return '第 ${i + 1} 句：${cue.error}';
      if (!identities.add(cue.id)) return '字幕标识重复';
      total += utf8.encode(cue.text).length;
      events.add((cue.startMs!, 1));
      events.add((cue.endMs!, -1));
    }
    if (total > 2 * 1024 * 1024) return '字幕文字总量不能超过 2 MiB';
    events.sort(
        (a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
    var active = 0;
    for (final event in events) {
      active += event.$2;
      if (active > 8) return '同时显示超过 8 句，请减少重叠字幕';
    }
    return null;
  }
}

String subtitleTimestamp(int? ms) {
  if (ms == null) return '';
  final abs = ms.abs();
  final h = (abs ~/ 3600000).toString().padLeft(2, '0');
  final m = (abs ~/ 60000 % 60).toString().padLeft(2, '0');
  final s = (abs ~/ 1000 % 60).toString().padLeft(2, '0');
  return '${ms < 0 ? '-' : ''}$h:$m:$s.${(abs % 1000).toString().padLeft(3, '0')}';
}

int? parseSubtitleTimestamp(String value) {
  final match = RegExp(r'^(\d{1,3}):(\d{2}):(\d{2})[.,](\d{1,3})$')
      .firstMatch(value.trim());
  if (match == null) return null;
  final h = int.parse(match[1]!),
      m = int.parse(match[2]!),
      s = int.parse(match[3]!);
  if (m > 59 || s > 59) return null;
  return ((h * 60 + m) * 60 + s) * 1000 + int.parse(match[4]!.padRight(3, '0'));
}

/// 编辑框兼容中文输入法分隔符及秒数；字幕文件导入仍使用严格时间格式。
int? parseEditableSubtitleTime(String value) {
  final normalized = value
      .trim()
      .replaceAll('：', ':')
      .replaceAll('．', '.')
      .replaceAll('，', ',');
  if (normalized.isEmpty) return null;
  if (RegExp(r'^-?\d+(?:\.\d{1,3})?$').hasMatch(normalized)) {
    final seconds = double.tryParse(normalized);
    if (seconds != null && seconds.isFinite && seconds.abs() <= 604800)
      return (seconds * 1000).round();
  } else {
    final negative = normalized.startsWith('-');
    final result =
        parseSubtitleTimestamp(negative ? normalized.substring(1) : normalized);
    if (result != null) return negative ? -result : result;
  }
  throw const FormatException('请输入秒数或 hh:mm:ss.mmm，分钟和秒须小于 60');
}

class SubtitleImportReport {
  const SubtitleImportReport(this.cues, this.errors, this.warnings);
  final List<EditableSubtitle> cues;
  final List<String> errors;
  final List<String> warnings;
}

/// 起止事件索引：结束为开区间；索引不重复缓存字幕全文。
class SubtitleTimeline {
  SubtitleTimeline(this.cues) {
    final events = <(int, int, int)>[];
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      if (cue.startMs == null ||
          cue.endMs == null ||
          cue.endMs! <= cue.startMs!) continue;
      events.add((cue.startMs!, 1, i));
      events.add((cue.endMs!, -1, i));
    }
    events.sort(
        (a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
    final active = SplayTreeSet<int>();
    var index = 0;
    while (index < events.length) {
      final time = events[index].$1;
      while (index < events.length && events[index].$1 == time) {
        final event = events[index++];
        if (event.$2 == -1) {
          active.remove(event.$3);
        } else {
          active.add(event.$3);
        }
      }
      _times.add(time);
      _indices.add(active.take(8).toList());
      _overflow.add(active.length > 8);
    }
  }
  final List<EditableSubtitle> cues;
  final _times = <int>[];
  final _indices = <List<int>>[];
  final _overflow = <bool>[];
  String at(int milliseconds) {
    var lo = 0, hi = _times.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_times[mid] <= milliseconds) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == 0) return '';
    return _indices[lo - 1].map((i) => cues[i].text).join('\n') +
        (_overflow[lo - 1] ? '\n[重叠超过 8 句，请在工作台查看完整内容]' : '');
  }
}

/// 在 compute isolate 中运行；只转换已识别样式，不执行任何字幕命令。
SubtitleImportReport parseSubtitleImport(Map<String, Object?> input) {
  final bytes = input['bytes'] as Uint8List;
  if (bytes.length > 2 * 1024 * 1024)
    throw const FormatException('字幕文件不能超过 2 MiB');
  String text;
  if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    if (bytes.length.isOdd) throw const FormatException('UTF-16 文件长度无效');
    final endian = bytes[0] == 255 ? Endian.little : Endian.big;
    final data = ByteData.sublistView(bytes);
    final units = [
      for (var i = 2; i < bytes.length; i += 2) data.getUint16(i, endian)
    ];
    for (var i = 0; i < units.length; i++) {
      if (units[i] >= 0xd800 && units[i] <= 0xdbff) {
        if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff)
          throw const FormatException('UTF-16 字符无效');
      } else if (units[i] >= 0xdc00 && units[i] <= 0xdfff) {
        throw const FormatException('UTF-16 字符无效');
      }
    }
    text = String.fromCharCodes(units);
  } else {
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      throw const FormatException('编码无法识别，请将字幕转换为 UTF-8 或带 BOM 的 UTF-16 后导入。');
    }
  }
  if (text.contains('\u0000'))
    throw const FormatException('文件含空字符，可能是无 BOM 的 UTF-16，请转换为 UTF-8。');
  text = text
      .replaceFirst(RegExp('^\uFEFF'), '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final cues = <EditableSubtitle>[], errors = <String>[], warnings = <String>[];
  final name = (input['name'] as String).toLowerCase();
  void add(String? start, String? end, String content, int number) {
    final cue = EditableSubtitle(
        id: subtitleId(),
        startMs: parseSubtitleTimestamp(start ?? ''),
        endMs: parseSubtitleTimestamp(end ?? ''),
        text: content.trim());
    if (cue.error != null) {
      errors.add('第 $number 项：${cue.error}');
    } else {
      cues.add(cue);
    }
    if (cues.length + errors.length > 20000)
      throw const FormatException('字幕条目超过 20000');
  }

  if (name.endsWith('.srt')) {
    var number = 0;
    for (final block in text.trim().split(RegExp(r'\n\s*\n'))) {
      if (block.trim().isEmpty) continue;
      number++;
      if (number > 20000) throw const FormatException('字幕条目超过 20000');
      final lines = block.trim().split('\n');
      final index = RegExp(r'^\d+$').hasMatch(lines.first.trim()) ? 1 : 0;
      if (index >= lines.length || !lines[index].contains('-->')) {
        errors.add('第 $number 项：缺少时间范围');
        continue;
      }
      final times = lines[index].split('-->');
      var content = lines.skip(index + 1).join('\n');
      final cleaned = content.replaceAll(
          RegExp(r'</?(?:b|i|u|font)(?:\s+[^>]*)?>', caseSensitive: false), '');
      if (cleaned != content && warnings.isEmpty)
        warnings.add('SRT 字体样式已转为纯文本');
      content = cleaned;
      if (RegExp(r'<[^>]+>').hasMatch(content) &&
          !warnings.contains('未识别的标签将按原文显示')) {
        warnings.add('未识别的标签将按原文显示');
      }
      add(times.first, times.length == 2 ? times.last : null, content, number);
    }
  } else if (name.endsWith('.ass') || name.endsWith('.ssa')) {
    warnings.add('ASS/SSA 仅导入文字和时间，不保留字体、位置、动画及特效；绘图条目不支持。');
    var inEvents = false;
    var fields = <String>[];
    var number = 0;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        inEvents = line.toLowerCase() == '[events]';
        continue;
      }
      if (!inEvents) continue;
      if (line.toLowerCase().startsWith('format:')) {
        fields = line
            .substring(7)
            .split(',')
            .map((e) => e.trim().toLowerCase())
            .toList();
        continue;
      }
      if (!line.toLowerCase().startsWith('dialogue:')) continue;
      number++;
      if (number > 20000) throw const FormatException('字幕条目超过 20000');
      if (!fields.contains('start') ||
          !fields.contains('end') ||
          fields.lastOrNull != 'text') {
        errors.add('第 $number 项：Events Format 不受支持');
        continue;
      }
      final rawFields = line.substring(9).split(',');
      if (rawFields.length < fields.length) {
        errors.add('第 $number 项：字段缺失');
        continue;
      }
      final content = rawFields.skip(fields.length - 1).join(',');
      if (RegExp(r'\{[^}]*\\p[1-9]').hasMatch(content)) {
        errors.add('第 $number 项：不支持 ASS 绘图');
        continue;
      }
      add(
          rawFields[fields.indexOf('start')],
          rawFields[fields.indexOf('end')],
          content
              .replaceAll(RegExp(r'\{[^}]*\}'), '')
              .replaceAll(r'\N', '\n')
              .replaceAll(r'\n', '\n')
              .replaceAll(r'\h', ' '),
          number);
    }
    if (number == 0) errors.add('未找到 ASS/SSA Events Dialogue');
  } else {
    throw const FormatException('仅支持 SRT、ASS、SSA');
  }
  if (cues.length > 20000) throw const FormatException('字幕超过 20000 句');
  return SubtitleImportReport(cues, errors, warnings);
}
