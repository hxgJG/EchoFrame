import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../lib/core/subtitles/subtitle_project.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  final report = parseSubtitleImport({
    'name': 'sample.srt',
    'bytes': Uint8List.fromList(utf8.encode(
        '1\n00:00:01,000 --> 00:00:03,000\n你好\n第二行\n\n2\n00:00:02,000 --> 00:00:04,000\n<b>重叠</b>\n\n3\n00:99:01,000 --> 00:00:05,000\n错误时间'))
  });
  check(report.cues.length == 2 && report.errors.length == 1, '严格解析 / 错误摘要');
  check(report.warnings.length == 1 && report.cues[1].text == '重叠', '样式转纯文字');
  final project = SubtitleProject(
      id: subtitleId(), name: '测试', source: {}, cues: report.cues);
  check(project.validationError == null, '合法重叠');
  final timeline = SubtitleTimeline(report.cues);
  check(timeline.at(999).isEmpty && timeline.at(1000).contains('你好'), '起始边界');
  check(timeline.at(2000).contains('重叠') && timeline.at(2000).contains('你好'),
      '重叠字幕');
  check(timeline.at(3000) == '重叠' && timeline.at(4000).isEmpty, '结束为开区间');
  final shifted = report.cues.first.shift(-1000);
  check(shifted.startMs == 0 && shifted.endMs == 2000, '提前方向');
  check(report.cues.first.shift(1000).startMs == 2000, '延后方向');
  check(report.cues.first.shift(-2000).error != null, '负时间保留草稿但阻止导出');
  check(
      SubtitleProject.fromJson(project.toJson()).cues.first.id ==
          report.cues.first.id,
      '稳定标识恢复');
  check(parseSubtitleTimestamp('00:60:00.000') == null, '分钟限制');
  check(
      parseEditableSubtitleTime('1.250') == 1250 &&
          parseEditableSubtitleTime('00：00：02.500') == 2500,
      '编辑秒数与全角输入');
  check(subtitleTimestamp(3600012) == '01:00:00.012', '毫秒格式');
  final ass = parseSubtitleImport({
    'name': 'sample.ass',
    'bytes': Uint8List.fromList(utf8.encode(
        '[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.20,0:00:03.40,Default,,0,0,0,,{\\i1}你好\\Nworld'))
  });
  check(ass.cues.single.startMs == 1200 && ass.cues.single.text == '你好\nworld',
      'ASS 时间与换行');
  final text = '1\n00:00:00,000 --> 00:00:01,000\n中文';
  final utf16 = <int>[
    255,
    254,
    for (final unit in text.codeUnits) ...[unit & 255, unit >> 8]
  ];
  check(
      parseSubtitleImport(
                  {'name': 'sample.srt', 'bytes': Uint8List.fromList(utf16)})
              .cues
              .single
              .text ==
          '中文',
      'UTF-16 BOM');
  project.cues = List.generate(
      9,
      (i) => EditableSubtitle(
          id: subtitleId(), startMs: 0, endMs: 1000, text: '$i'));
  check(project.validationError!.contains('8'), '重叠容量');
  project.cues = [const EditableSubtitle(id: 'unfinished', text: '')];
  check(
      project.validationError != null &&
          SubtitleProject.fromJson(project.toJson()).cues.single.startMs ==
              null,
      '未完成草稿可恢复');
  stdout.writeln('PASS：SRT/ASS、编码、错误摘要、时间校准、重叠限制及草稿恢复。');
}
