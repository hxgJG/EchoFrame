import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../core/models/media_item.dart';
import '../../core/subtitles/subtitle_project.dart';
import '../../platform/subtitle_workbench/subtitle_workbench_repository.dart';

bool _workbenchOpen = false;

Future<void> openSubtitleWorkbench(BuildContext context, LumioAppState state,
    {MediaItem? item}) async {
  if (!SubtitleWorkbenchRepository.supported || _workbenchOpen) return;
  _workbenchOpen = true;
  try {
    if (state.isPlaying) {
      final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('打开字幕工作台'),
                  content: const Text('将暂停当前播放。工作台使用独立预览，退出后不会自动继续播放。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('继续'))
                  ]));
      if (proceed != true || !context.mounted) return;
      if (state.isPlaying) state.togglePlaying();
    }
    if (!context.mounted) return;
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                SubtitleWorkbenchPage(state: state, initialItem: item)));
  } finally {
    _workbenchOpen = false;
  }
}

class SubtitleWorkbenchPage extends StatefulWidget {
  const SubtitleWorkbenchPage(
      {super.key, required this.state, this.initialItem});
  final LumioAppState state;
  final MediaItem? initialItem;
  @override
  State<SubtitleWorkbenchPage> createState() => _SubtitleWorkbenchPageState();
}

class _SubtitleWorkbenchPageState extends State<SubtitleWorkbenchPage> {
  final _repository = SubtitleWorkbenchRepository();
  final _undo = <String>[], _redo = <String>[];
  List<Map<String, dynamic>> _projects = [];
  SubtitleProject? _project;
  Map<String, dynamic> _preview = {}, _job = {};
  Timer? _timer;
  bool _busy = false, _polling = false, _playing = false, _allowPop = false;
  bool _scrubbing = false;
  int _position = 0, _savedRevision = 0;
  String? _selected;
  String _notice = '', _saveError = '';
  int get _duration => _preview['durationMs'] as int? ?? 0;
  bool get _hasPreview => _preview['sessionId'] != null;
  bool get _exporting =>
      _job.isNotEmpty &&
      !['completed', 'failed', 'cancelled'].contains(_job['phase']);
  EditableSubtitle? get _cue =>
      _project?.cues.where((e) => e.id == _selected).firstOrNull;
  Map<String, Object?> get _session => {'sessionId': _preview['sessionId']};

  @override
  void initState() {
    super.initState();
    if (!SubtitleWorkbenchRepository.supported) return;
    widget.state.addListener(_mainPlaybackChanged);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _poll());
    WidgetsBinding.instance.addPostFrameCallback((_) => _run(() async {
          await _refreshProjects();
          if (widget.initialItem != null)
            await _create(item: widget.initialItem);
        }));
  }

  void _mainPlaybackChanged() {
    if (widget.state.isPlaying && _playing && !_busy) {
      _run(() async {
        await _repository.call('play', {..._session, 'playing': false});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.state.removeListener(_mainPlaybackChanged);
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final status =
          Map<String, dynamic>.from(await _repository.call('status') as Map);
      if (!mounted) return;
      final job = Map<String, dynamic>.from(status['job'] as Map);
      final valid = status['sessionId'] == _preview['sessionId'];
      final position =
          valid && !_scrubbing ? status['positionMs'] as int : _position;
      final playing = valid && status['playing'] == true;
      if (position != _position ||
          playing != _playing ||
          !mapEquals(job, _job)) {
        setState(() {
          _position = position;
          _playing = playing;
          _job = job;
        });
      }
      if (valid && status['error'] != '' && status['error'] != _notice)
        setState(() => _notice = '预览失败：${status['error']}');
      if (playing && widget.state.isPlaying && !_busy) {
        await _run(() async {
          await _repository.call('play', {..._session, 'playing': false});
        });
      }
    } catch (_) {/* 操作错误由主动调用展示，轮询失败不伪造播放位置。 */} finally {
      _polling = false;
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (mounted)
        setState(() => _notice = error is PlatformException
            ? error.message ?? error.code
            : error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshProjects() async {
    _projects = (await _repository.call('list') as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList()
      ..sort((a, b) => (b['updatedAtMs'] as int? ?? 0)
          .compareTo(a['updatedAtMs'] as int? ?? 0));
  }

  Future<void> _create({MediaItem? item}) async {
    dynamic source;
    if (item != null) {
      try {
        source = await _repository.call('libraryVideo', {'path': item.path});
      } catch (_) {
        _notice = '该视频授权不可用，请从新建项目入口重新选择文件。';
        rethrow;
      }
    } else {
      source = await _repository.call('selectVideo');
    }
    if (source == null) return;
    final project = SubtitleProject(
        id: subtitleId(),
        name: source['name'] as String,
        source: Map<String, dynamic>.from(source as Map),
        cues: item?.subtitles
            .map((e) => EditableSubtitle(
                id: subtitleId(),
                startMs: e.start.inMilliseconds,
                endMs: e.end.inMilliseconds,
                text: e.text))
            .toList(),
        libraryBinding: item == null
            ? null
            : {
                'mediaId': item.id,
                'path': item.path,
                'signature': widget.state.subtitleSignature(item)
              });
    _project = project;
    _savedRevision = 0;
    _selected = project.cues.firstOrNull?.id;
    _undo.clear();
    _redo.clear();
    project.revision = 1;
    await _save();
    await _openPreview();
  }

  Future<void> _load(String id) async {
    final project = SubtitleProject.fromJson(Map<String, dynamic>.from(
        await _repository.call('load', {'id': id}) as Map));
    _project = project;
    _savedRevision = project.revision;
    _selected = project.cues.firstOrNull?.id;
    _undo.clear();
    _redo.clear();
    _saveError = '';
    await _openPreview();
  }

  Future<void> _openPreview() async {
    _preview = {};
    _position = 0;
    _playing = false;
    if (widget.state.isPlaying) widget.state.togglePlaying();
    try {
      _preview = Map<String, dynamic>.from(
          await _repository.call('open', {'source': _project!.source}) as Map);
      await _render();
    } catch (error) {
      _notice = '草稿已保留。视频不可用时可“重新选择视频”。\n$error';
    }
  }

  Future<void> _save() async {
    final project = _project!;
    try {
      await _repository.call('save',
          {'project': project.toJson(), 'expectedRevision': _savedRevision});
      _savedRevision = project.revision;
      _saveError = '';
    } catch (error) {
      _saveError = '尚未保存，请重试：$error';
      rethrow;
    }
  }

  void _remember() {
    _undo.add(jsonEncode({
      'cues': _project!.cues.map((e) => e.toJson()).toList(),
      'style': _project!.style,
      'applyOrigin': _project!.applyOrigin
    }));
    while (_undo.length > 30 ||
        (_undo.length > 1 &&
            _undo.fold<int>(0, (sum, e) => sum + e.length) > 4 * 1024 * 1024)) {
      _undo.removeAt(0);
    }
    _redo.clear();
  }

  Future<void> _changed({bool preserveOrigin = false}) async {
    if (!preserveOrigin) _project!.applyOrigin = 'edited';
    _project!.revision++;
    await _save();
    await _render();
  }

  Future<void> _render() async {
    if (!_hasPreview) return;
    final project = _project!;
    if (project.validationError != null && project.cues.isNotEmpty) {
      await _repository
          .call('document', {..._session, 'cues': [], 'style': project.style});
      _notice = '草稿已保存，修正后恢复字幕预览：${project.validationError}';
      return;
    }
    await _repository.call('document', {
      ..._session,
      'cues': project.cues.map((e) => e.toJson()).toList(),
      'style': project.style
    });
    _notice = '';
  }

  Future<void> _history(bool undo) async {
    final from = undo ? _undo : _redo, to = undo ? _redo : _undo;
    if (from.isEmpty) return;
    to.add(jsonEncode({
      'cues': _project!.cues.map((e) => e.toJson()).toList(),
      'style': _project!.style,
      'applyOrigin': _project!.applyOrigin
    }));
    final snapshot = jsonDecode(from.removeLast()) as Map<String, dynamic>;
    _project!.cues = (snapshot['cues'] as List)
        .map((e) => EditableSubtitle.fromJson(e as Map<String, dynamic>))
        .toList();
    _project!.style = Map<String, dynamic>.from(snapshot['style'] as Map);
    _project!.applyOrigin = snapshot['applyOrigin'] as String? ?? 'edited';
    await _changed(preserveOrigin: true);
  }

  Future<bool> _confirm(String title, String message,
      {String action = '确认'}) async {
    if (!mounted) return false;
    return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: Text(title),
                    content: SingleChildScrollView(child: Text(message)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(action))
                    ])) ??
        false;
  }

  Future<void> _import({bool sidecar = false}) async {
    final file = await _repository.call(
        sidecar ? 'sidecar' : 'import', sidecar ? _session : null);
    if (file == null) return;
    final report = await compute(
        parseSubtitleImport, {'name': file['name'], 'bytes': file['bytes']});
    if (report.cues.isEmpty)
      throw FormatException('没有有效字幕。${report.errors.take(5).join('\n')}');
    final accepted = await _confirm('确认导入字幕',
        '有效 ${report.cues.length} 句，无效 ${report.errors.length} 项。将替换当前草稿，可撤销。\n${report.warnings.join('\n')}\n${report.errors.take(8).join('\n')}\n\n首句：${report.cues.first.text}',
        action: report.errors.isEmpty ? '导入' : '仅导入有效条目');
    if (!accepted) return;
    _remember();
    _project!.cues = report.cues;
    _project!.importName = file['name'] as String;
    _project!.applyOrigin = sidecar ? 'sidecar' : 'edited';
    _selected = report.cues.first.id;
    await _changed(preserveOrigin: true);
  }

  Future<void> _edit({EditableSubtitle? cue}) async {
    if (cue == null && _project!.cues.length >= 20000)
      throw const FormatException('最多 20000 句');
    final result = await showDialog<EditableSubtitle>(
        context: context,
        builder: (_) => _SubtitleCueDialog(
            cue: cue ??
                EditableSubtitle(
                    id: subtitleId(),
                    startMs: _hasPreview ? _position : null,
                    text: ''),
            position: _hasPreview ? _position : null));
    if (result == null) return;
    _remember();
    if (cue == null) {
      _project!.cues.add(result);
    } else {
      final index = _project!.cues.indexWhere((e) => e.id == cue.id);
      if (index >= 0) _project!.cues[index] = result;
    }
    _selected = result.id;
    await _changed();
  }

  Future<void> _mark(bool start) async {
    final cue = _cue;
    if (cue == null) return;
    await _readPosition();
    _remember();
    final index = _project!.cues.indexWhere((e) => e.id == cue.id);
    _project!.cues[index] = EditableSubtitle(
        id: cue.id,
        startMs: start ? _position : cue.startMs,
        endMs: start ? cue.endMs : _position,
        text: cue.text);
    await _changed();
  }

  Future<void> _calibrate() async {
    if (!_hasPreview || _project!.cues.isEmpty) return;
    await _repository.call('play', {..._session, 'playing': false});
    await _readPosition();
    final base = List<EditableSubtitle>.of(_project!.cues);
    var advance = 0;
    final controller = TextEditingController(text: '0');
    var rendering = false;
    String feedback = '';
    final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(builder: (context, update) {
              Future<void> setAdvance(int next) async {
                if (rendering) return;
                if (next.abs() > 60000) {
                  update(() => feedback = '整体校准范围为 ±60 秒');
                  return;
                }
                update(() {
                  rendering = true;
                  advance = next;
                  controller.text = (-advance / 1000).toStringAsFixed(3);
                  feedback = '';
                });
                _project!.cues = base.map((e) => e.shift(-advance)).toList();
                try {
                  await _render();
                } catch (e) {
                  feedback = e.toString();
                }
                if (context.mounted) update(() => rendering = false);
              }

              return AlertDialog(
                  title: const Text('整体字幕校准'),
                  content: SizedBox(
                      width: 440,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('暂停画面实时预览。负数提前，正数延后；保存后直接修改草稿时间，导出不再重复偏移。'),
                        const SizedBox(height: 12),
                        Wrap(spacing: 8, children: [
                          for (final step in [500, 100, -100, -500])
                            OutlinedButton(
                                onPressed: rendering
                                    ? null
                                    : () => setAdvance(advance + step),
                                child: Text(
                                    '${step > 0 ? '提前' : '延后'} ${step.abs() / 1000}s'))
                        ]),
                        TextField(
                            controller: controller,
                            decoration: const InputDecoration(
                                labelText: '移动秒数（例如 1.5 表示延后）'),
                            onSubmitted: (value) {
                              final seconds = double.tryParse(value);
                              if (seconds != null && seconds.isFinite)
                                setAdvance(-(seconds * 1000).round());
                            }),
                        Wrap(spacing: 8, children: [
                          TextButton(
                              onPressed: rendering ? null : () => setAdvance(0),
                              child: const Text('重置本次调整')),
                          TextButton(
                              onPressed: rendering || _cue?.startMs == null
                                  ? null
                                  : () => setAdvance(base
                                          .firstWhere((e) => e.id == _selected)
                                          .startMs! -
                                      _position),
                              child: const Text('选中句开始对齐当前画面'))
                        ]),
                        if (feedback.isNotEmpty) Text(feedback),
                        Text(
                            '当前：${subtitleTimestamp(_position)}；${advance >= 0 ? '提前' : '延后'} ${advance.abs() / 1000}s'),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: rendering
                            ? null
                            : () => Navigator.pop(dialogContext, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: rendering
                            ? null
                            : () async {
                                final seconds =
                                    double.tryParse(controller.text);
                                if (seconds == null ||
                                    !seconds.isFinite ||
                                    seconds.abs() > 60) {
                                  update(() => feedback = '请输入 -60～60 秒');
                                  return;
                                }
                                await setAdvance(-(seconds * 1000).round());
                                if (dialogContext.mounted)
                                  Navigator.pop(dialogContext, true);
                              },
                        child: const Text('保存'))
                  ]);
            }));
    controller.dispose();
    final adjusted = _project!.cues;
    _project!.cues = base;
    if (accepted == true && advance != 0) {
      _remember();
      _project!.cues = adjusted;
      await _changed();
    } else {
      await _render();
    }
  }

  Future<void> _export() async {
    final project = _project!;
    if (project.validationError != null)
      throw FormatException(project.validationError!);
    final outOfRange = project.cues.where((e) => e.endMs! > _duration).length;
    if (outOfRange > 0 &&
        !await _confirm(
            '部分字幕超出视频', '$outOfRange 句超出视频范围，成片仅显示与视频相交的部分，草稿保持不变。是否继续？'))
      return;
    if (!project.cues.any((e) => e.startMs! < _duration))
      throw const FormatException('视频范围内没有字幕');
    await _save();
    final job = await _repository.call('export', {
      ..._session,
      'projectId': project.id,
      'revision': project.revision,
      'cues': project.cues.map((e) => e.toJson()).toList(),
      'style': project.style,
      'allowOutOfRange': outOfRange > 0
    });
    if (job != null) _job = Map<String, dynamic>.from(job as Map);
  }

  Future<void> _readPosition() async {
    final status =
        Map<String, dynamic>.from(await _repository.call('status') as Map);
    if (status['sessionId'] != _preview['sessionId'] || status['error'] != '')
      throw StateError('无法读取当前视频位置，请重新打开预览。');
    _position = status['positionMs'] as int;
    _playing = status['playing'] == true;
  }

  Future<void> _apply() async {
    final project = _project!, binding = _project!.libraryBinding;
    if (binding == null) return;
    if (project.validationError != null)
      throw FormatException(project.validationError!);
    if (!await _confirm('应用到媒体库视频', '将替换该视频在忆光中的字幕，不修改原文件，也不自动导出成片。')) return;
    await _save();
    final signature = await widget.state.applyWorkbenchSubtitles(
        binding,
        project.cues
            .map((e) => SubtitleCue(
                start: Duration(milliseconds: e.startMs!),
                end: Duration(milliseconds: e.endMs!),
                text: e.text))
            .toList(),
        origin: project.applyOrigin,
        sourceName: project.importName);
    binding['signature'] = signature;
    project.revision++;
    await _save();
    _notice = '已应用到媒体库视频';
  }

  Future<void> _leave({bool home = false}) async {
    if (_project != null) {
      try {
        await _save();
      } catch (_) {
        if (!await _confirm('项目保存失败', '退出会丢失本次尚未保存的修改。仍要退出？',
            action: '放弃未保存修改')) return;
      }
    }
    await _repository.call('close');
    if (!mounted) return;
    if (home) {
      _project = null;
      _preview = {};
      _notice = '';
      _saveError = '';
      await _refreshProjects();
    } else {
      setState(() => _allowPop = true);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!SubtitleWorkbenchRepository.supported)
      return const Scaffold(body: Center(child: Text('字幕工作台目前仅支持 macOS')));
    return PopScope(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _run(() => _leave());
        },
        child: Scaffold(
            appBar: AppBar(
                title: Text(_project == null ? '字幕工作台' : _project!.name),
                leading: IconButton(
                    tooltip: '返回',
                    onPressed: _busy ? null : () => _run(() => _leave()),
                    icon: const Icon(Icons.arrow_back)),
                actions: [
                  if (_project != null)
                    TextButton.icon(
                        onPressed:
                            _busy ? null : () => _run(() => _leave(home: true)),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('项目列表'))
                ]),
            body: Column(children: [
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (_notice.isNotEmpty || _saveError.isNotEmpty)
                Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(children: [
                          Expanded(
                              child: SelectableText([_saveError, _notice]
                                  .where((e) => e.isNotEmpty)
                                  .join('\n'))),
                          if (_saveError.isNotEmpty)
                            TextButton(
                                onPressed: _busy ? null : () => _run(_save),
                                child: const Text('重试保存')),
                          IconButton(
                              onPressed: () => setState(() => _notice = ''),
                              icon: const Icon(Icons.close))
                        ]))),
              if (_job.isNotEmpty) _jobView(),
              Expanded(child: _project == null ? _home() : _editor()),
            ])));
  }

  Widget _home() => ListView(padding: const EdgeInsets.all(24), children: [
        const Text('给本地视频制作字幕',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
            '选择视频 → 导入或手动添加字幕 → 播放校准 → 导出带字幕 MP4\n全程离线，不修改原视频。不支持 HDR、复杂 ASS 特效或多音轨。'),
        const SizedBox(height: 16),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
                onPressed: _busy ? null : () => _run(() => _create()),
                icon: const Icon(Icons.add),
                label: const Text('选择视频 · 新建项目'))),
        const SizedBox(height: 24),
        const Text('最近项目（自动保存，可在设置中随应用备份）'),
        for (final project in _projects)
          Card(
              child: ListTile(
                  title: Text(project['name'] as String),
                  subtitle: Text(
                      project['error'] as String? ?? '本地字幕项目 · 原视频不包含在备份中'),
                  onTap: _busy
                      ? null
                      : () => _run(() => _load(project['id'] as String)),
                  trailing: IconButton(
                      tooltip: '删除项目（不删除视频）',
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                                if (!await _confirm(
                                    '删除字幕项目', '只删除此项目的字幕草稿，原视频和已导出的成片不会删除。',
                                    action: '删除')) return;
                                await _repository
                                    .call('delete', {'id': project['id']});
                                await _refreshProjects();
                              }),
                      icon: const Icon(Icons.delete_outline))))
      ]);

  Widget _jobView() {
    const labels = {
      'preparing': '准备',
      'validating': '校验',
      'encoding': '编码',
      'verifying': '校验成片',
      'publishing': '写入目标',
      'completed': '导出完成',
      'failed': '导出失败',
      'cancelled': '已取消'
    };
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(
                    '视频导出 · 版本 ${_job['revision']} · ${labels[_job['phase']] ?? _job['phase']}')),
            if (_exporting)
              TextButton(
                  onPressed: () => _repository.call('cancelExport'),
                  child: const Text('取消导出'))
          ]),
          if (_exporting)
            LinearProgressIndicator(
                value: (_job['progress'] as num?)?.toDouble()),
          if (_job['path'] != null) SelectableText('已保存：${_job['path']}'),
          if (_job['error'] != null && _job['phase'] == 'failed')
            SelectableText('${_job['error']}'),
        ]));
  }

  Widget _editor() => Column(children: [
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              _action('导入字幕', Icons.subtitles_outlined, () => _import()),
              _action('恢复同名字幕', Icons.restore,
                  _hasPreview ? () => _import(sidecar: true) : null),
              _action('新增句子', Icons.add, () => _edit()),
              _action('撤销', Icons.undo,
                  _undo.isEmpty ? null : () => _history(true)),
              _action('重做', Icons.redo,
                  _redo.isEmpty ? null : () => _history(false)),
              _action('整体校准', Icons.tune,
                  _hasPreview && _project!.cues.isNotEmpty ? _calibrate : null),
              _action('重新选择视频', Icons.video_file_outlined, () async {
                if (!await _confirm(
                    '重新选择视频', '字幕草稿将保留。请选择同一版本视频；若选择不同视频，请重新核对全部时间。媒体库绑定将解除。'))
                  return;
                final source = await _repository.call('selectVideo');
                if (source == null) return;
                _project!.source = Map<String, dynamic>.from(source as Map);
                _project!.libraryBinding = null;
                _project!.revision++;
                await _save();
                await _openPreview();
              }),
              if (_project!.libraryBinding != null)
                _action('应用到媒体库', Icons.check, _apply),
              FilledButton.icon(
                  onPressed: _busy || !_hasPreview || _exporting
                      ? null
                      : () => _run(_export),
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('导出带字幕视频')),
            ])),
        Expanded(child: LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth >= 960)
            return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 6, child: _video()),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 5, child: _subtitleList())
                ]);
          return Column(children: [
            SizedBox(height: constraints.maxHeight * .48, child: _video()),
            const Divider(height: 1),
            Expanded(child: _subtitleList())
          ]);
        })),
        Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_saveError.isEmpty
                ? '已自动保存 · 版本 $_savedRevision · ${_project!.cues.length} 句 · 原视频保持不变'
                : _saveError)),
      ]);

  Widget _action(
          String label, IconData icon, Future<void> Function()? callback) =>
      OutlinedButton.icon(
          onPressed: _busy || callback == null ? null : () => _run(callback),
          icon: Icon(icon, size: 18),
          label: Text(label));

  Widget _video() => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Expanded(
            child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: !_hasPreview
                    ? const Text('重新选择视频以恢复预览',
                        style: TextStyle(color: Colors.white))
                    : AspectRatio(
                        aspectRatio: (_preview['width'] as int) /
                            (_preview['height'] as int),
                        child:
                            Texture(textureId: _preview['textureId'] as int)))),
        Row(children: [
          IconButton(
              tooltip: _playing ? '暂停预览' : '播放预览',
              onPressed: _busy || !_hasPreview
                  ? null
                  : () => _run(() async {
                        if (widget.state.isPlaying)
                          widget.state.togglePlaying();
                        await _repository
                            .call('play', {..._session, 'playing': !_playing});
                      }),
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow)),
          Expanded(
              child: Slider(
                  onChangeStart: (_) => _scrubbing = true,
                  value: _position.clamp(0, _duration).toDouble(),
                  max: _duration <= 0 ? 1 : _duration.toDouble(),
                  onChanged: _busy || !_hasPreview
                      ? null
                      : (value) => setState(() => _position = value.round()),
                  onChangeEnd: _busy || !_hasPreview
                      ? null
                      : (value) => _run(() async {
                            try {
                              await _repository.call('seek',
                                  {..._session, 'positionMs': value.round()});
                            } finally {
                              _scrubbing = false;
                            }
                            await _readPosition();
                          }))),
        ]),
        Text(
            '${subtitleTimestamp(_position)} / ${subtitleTimestamp(_duration)}',
            style:
                const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        Flexible(
            child: SingleChildScrollView(
                child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
              const Text('样式'),
              DropdownButton<String>(
                  value: _project!.style['color'] as String,
                  items: const [
                    DropdownMenuItem(value: 'white', child: Text('白色')),
                    DropdownMenuItem(value: 'yellow', child: Text('黄色')),
                    DropdownMenuItem(value: 'cyan', child: Text('青色'))
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => _run(() async {
                            _remember();
                            _project!.style['color'] = value;
                            await _changed();
                          })),
              _action('字小', Icons.text_decrease, () async {
                _remember();
                _project!.style['fontFraction'] =
                    ((_project!.style['fontFraction'] as num).toDouble() - .005)
                        .clamp(.018, .09);
                await _changed();
              }),
              _action('字大', Icons.text_increase, () async {
                _remember();
                _project!.style['fontFraction'] =
                    ((_project!.style['fontFraction'] as num).toDouble() + .005)
                        .clamp(.018, .09);
                await _changed();
              }),
              _action('上移', Icons.arrow_upward, () async {
                _remember();
                _project!.style['bottomFraction'] =
                    ((_project!.style['bottomFraction'] as num).toDouble() +
                            .02)
                        .clamp(.02, .55);
                await _changed();
              }),
              _action('下移', Icons.arrow_downward, () async {
                _remember();
                _project!.style['bottomFraction'] =
                    ((_project!.style['bottomFraction'] as num).toDouble() -
                            .02)
                        .clamp(.02, .55);
                await _changed();
              }),
              FilterChip(
                  selectedColor: Theme.of(context).colorScheme.primaryContainer,
                  label: const Text('半透明底色'),
                  selected: _project!.style['background'] == true,
                  onSelected: _busy
                      ? null
                      : (value) => _run(() async {
                            _remember();
                            _project!.style['background'] = value;
                            await _changed();
                          })),
            ]))),
      ]));

  Widget _subtitleList() => Column(children: [
        Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(spacing: 8, children: [
              _action('标记开始', Icons.first_page,
                  _cue == null || !_hasPreview ? null : () => _mark(true)),
              _action('标记结束', Icons.last_page,
                  _cue == null || !_hasPreview ? null : () => _mark(false)),
              _action('编辑选中句', Icons.edit,
                  _cue == null ? null : () => _edit(cue: _cue)),
              _action(
                  '删除',
                  Icons.delete_outline,
                  _cue == null
                      ? null
                      : () async {
                          _remember();
                          _project!.cues.removeWhere((e) => e.id == _selected);
                          _selected = null;
                          await _changed();
                        }),
            ])),
        Expanded(
            child: _project!.cues.isEmpty
                ? const Center(
                    child: Text('尚无字幕\n导入 SRT / ASS，或新增句子并标记时间',
                        textAlign: TextAlign.center))
                : ListView.builder(
                    itemCount: _project!.cues.length,
                    itemBuilder: (context, index) {
                      final cue = _project!.cues[index];
                      final active = cue.startMs != null &&
                          cue.endMs != null &&
                          cue.startMs! <= _position &&
                          _position < cue.endMs!;
                      return ListTile(
                          selected: _selected == cue.id,
                          onTap: _busy
                              ? null
                              : () => setState(() => _selected = cue.id),
                          leading: Text('${index + 1}',
                              style: TextStyle(
                                  color: active
                                      ? Theme.of(context).colorScheme.primary
                                      : null)),
                          title: Text(cue.text.isEmpty ? '未填写文字' : cue.text,
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              cue.error ??
                                  '${subtitleTimestamp(cue.startMs)} → ${subtitleTimestamp(cue.endMs)}${_duration > 0 && (cue.endMs ?? 0) > _duration ? ' · 超出视频' : ''}',
                              style: cue.error == null
                                  ? null
                                  : TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error)),
                          trailing: IconButton(
                              tooltip: '定位到开始',
                              onPressed:
                                  _busy || !_hasPreview || cue.startMs == null
                                      ? null
                                      : () => _run(() async {
                                            _selected = cue.id;
                                            await _repository.call('seek', {
                                              ..._session,
                                              'positionMs': cue.startMs
                                            });
                                            await _poll();
                                          }),
                              icon: const Icon(Icons.my_location)));
                    })),
      ]);
}

class _SubtitleCueDialog extends StatefulWidget {
  const _SubtitleCueDialog({required this.cue, required this.position});
  final EditableSubtitle cue;
  final int? position;
  @override
  State<_SubtitleCueDialog> createState() => _SubtitleCueDialogState();
}

class _SubtitleCueDialogState extends State<_SubtitleCueDialog> {
  late final _text = TextEditingController(text: widget.cue.text);
  late final _start =
      TextEditingController(text: subtitleTimestamp(widget.cue.startMs));
  late final _end =
      TextEditingController(text: subtitleTimestamp(widget.cue.endMs));
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('编辑字幕'),
          content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: _text,
                    autofocus: true,
                    minLines: 3,
                    maxLines: 8,
                    maxLength: 8000,
                    decoration: const InputDecoration(labelText: '字幕文字（支持多行）')),
                TextField(
                    controller: _start,
                    decoration: InputDecoration(
                        labelText: '开始：秒数或 hh:mm:ss.mmm（可留空）',
                        suffixIcon: widget.position == null
                            ? null
                            : IconButton(
                                tooltip: '当前画面',
                                onPressed: () => _start.text =
                                    subtitleTimestamp(widget.position),
                                icon: const Icon(Icons.flag)))),
                TextField(
                    controller: _end,
                    decoration: InputDecoration(
                        labelText: '结束：秒数或 hh:mm:ss.mmm',
                        suffixIcon: widget.position == null
                            ? null
                            : IconButton(
                                tooltip: '当前画面',
                                onPressed: () => _end.text =
                                    subtitleTimestamp(widget.position),
                                icon: const Icon(Icons.flag)))),
                if (_error != null)
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                const Text('未完成的时间和文字可保存为草稿；导出前需要全部修正。'),
              ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: () {
                  try {
                    Navigator.pop(
                        context,
                        EditableSubtitle(
                            id: widget.cue.id,
                            startMs: parseEditableSubtitleTime(_start.text),
                            endMs: parseEditableSubtitleTime(_end.text),
                            text: _text.text));
                  } catch (e) {
                    setState(() => _error = e.toString());
                  }
                },
                child: const Text('保存草稿'))
          ]);
}
