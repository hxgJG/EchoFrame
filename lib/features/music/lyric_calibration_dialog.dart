import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/lyrics/lyric_calibration.dart';
import '../../core/models/media_item.dart';

Future<void> showLyricCalibration(
    BuildContext context, LumioAppState state) async {
  final draft = state.beginLyricCalibration();
  if (draft == null) return;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CalibrationDialog(state: state, draft: draft),
    );
  } finally {
    state.cancelLyricCalibration(draft);
  }
}

class _CalibrationDialog extends StatefulWidget {
  const _CalibrationDialog({required this.state, required this.draft});
  final LumioAppState state;
  final LyricCalibration draft;

  @override
  State<_CalibrationDialog> createState() => _CalibrationDialogState();
}

class _CalibrationDialogState extends State<_CalibrationDialog> {
  late final TextEditingController _offset;
  late final ScrollController _lines;
  int _step = 100;
  int? _selected;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _offset = TextEditingController(text: widget.draft.offsetMs.toString());
    final index = widget.state.currentLyricIndex;
    _selected = index >= 0 ? index : null;
    _lines = ScrollController(
        initialScrollOffset:
            (index - 1).clamp(0, widget.draft.lyrics.length) * 48.0);
  }

  @override
  void dispose() {
    _offset.dispose();
    _lines.dispose();
    super.dispose();
  }

  void _preview(int milliseconds) {
    final ok = widget.state.previewLyricOffset(widget.draft, milliseconds);
    setState(() {
      _error = ok ? null : '调整范围为 −30000～30000 毫秒。';
      if (ok) _offset.text = milliseconds.toString();
    });
  }

  Future<void> _align() async {
    final index = _selected;
    if (index == null) return;
    setState(() => _busy = true);
    final error = await widget.state.alignLyricToNow(widget.draft, index);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      _offset.text = widget.draft.offsetMs.toString();
    });
  }

  Future<void> _save() async {
    final input = int.tryParse(_offset.text.trim());
    if (input == null || input.abs() > LyricTiming.limitMs) {
      setState(() => _error = '请输入 −30000～30000 之间的整数毫秒。');
      return;
    }
    _preview(input);
    setState(() => _busy = true);
    final error = await widget.state.saveLyricCalibration(widget.draft);
    if (!mounted) return;
    if (error == null) {
      // 保存已完成，解除 PopScope 后关闭。
      setState(() => _busy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final draft = widget.draft;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([state, state.lyricChanges]),
      builder: (context, _) {
        final valid = state.isLyricCalibrationValid(draft);
        final enabled = valid && !_busy;
        return PopScope(
          canPop: !_busy,
          child: AlertDialog(
            title: const Text('校准歌词'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('仅此歌曲 · ${draft.title}',
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 12),
                    Text(describeLyricOffset(draft.offsetMs),
                        style: Theme.of(context).textTheme.titleLarge),
                    Text(
                        '另叠加全局设置：${describeLyricOffset(state.settings.lyricOffset.inMilliseconds)}'),
                    const SizedBox(height: 12),
                    const Text('歌词比人声晚 → 提前；歌词比人声早 → 延后。\n即时预览，不改变音乐进度或原始文件。'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(value: 100, label: Text('0.1 秒')),
                            ButtonSegment(value: 500, label: Text('0.5 秒')),
                          ],
                          selected: {_step},
                          onSelectionChanged: enabled
                              ? (values) => setState(() => _step = values.first)
                              : null,
                        ),
                        OutlinedButton(
                            onPressed: enabled &&
                                    draft.offsetMs + _step <=
                                        LyricTiming.limitMs
                                ? () => _preview(draft.offsetMs + _step)
                                : null,
                            child: const Text('提前')),
                        OutlinedButton(
                            onPressed: enabled &&
                                    draft.offsetMs - _step >=
                                        -LyricTiming.limitMs
                                ? () => _preview(draft.offsetMs - _step)
                                : null,
                            child: const Text('延后')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _offset,
                      enabled: enabled,
                      keyboardType:
                          const TextInputType.numberWithOptions(signed: true),
                      decoration: const InputDecoration(
                          labelText: '本曲偏移（毫秒，正数提前／负数延后）',
                          helperText: '范围 ±30000 毫秒；回车预览，也可直接保存。',
                          border: OutlineInputBorder()),
                      onSubmitted: (value) {
                        final number = int.tryParse(value.trim());
                        if (number == null) {
                          setState(() => _error = '请输入整数毫秒。');
                        } else {
                          _preview(number);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    const Text('选中一句，开始播放，听到唱这句时点击下方对齐按钮。'),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 156,
                      child: Scrollbar(
                        controller: _lines,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _lines,
                          itemExtent: 48,
                          itemCount: draft.lyrics.length,
                          itemBuilder: (context, index) {
                            final line = draft.lyrics[index];
                            return ListTile(
                              dense: true,
                              selected: _selected == index,
                              selectedTileColor: scheme.primaryContainer,
                              leading: Text(formatDuration(line.time)),
                              title: Text(line.text,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing:
                                  state.currentLyricIndex == index && valid
                                      ? const Icon(Icons.graphic_eq, size: 18)
                                      : null,
                              onTap: enabled
                                  ? () => setState(() => _selected = index)
                                  : null,
                            );
                          },
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.tonal(
                            onPressed:
                                enabled && state.isPlaying && _selected != null
                                    ? _align
                                    : null,
                            child: const Text('此句从现在开始')),
                        IconButton(
                            tooltip: state.isPlaying ? '暂停' : '继续播放',
                            onPressed: enabled ? state.togglePlaying : null,
                            icon: Icon(state.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow)),
                        Text(formatDuration(state.position)),
                      ],
                    ),
                    if (!valid && !_busy)
                      Text('歌曲或歌词已变化，未保存的草稿已取消。请关闭后重新校准。',
                          style: TextStyle(color: scheme.error)),
                    if (_error != null)
                      Text(_error!, style: TextStyle(color: scheme.error)),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: enabled ? () => _preview(0) : null,
                  child: const Text('恢复本曲默认')),
              TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(valid ? '取消' : '关闭')),
              FilledButton(
                  onPressed: enabled ? _save : null,
                  child: Text(_busy ? '处理中…' : '保存')),
            ],
          ),
        );
      },
    );
  }
}
