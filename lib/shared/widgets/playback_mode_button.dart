import 'package:flutter/material.dart';

import '../../app/app_state.dart';

class PlaybackModeButton extends StatelessWidget {
  const PlaybackModeButton(
      {super.key, required this.state, required this.color});

  final LumioAppState state;
  final Color color;

  static String _label(PlaybackMode mode) => switch (mode) {
        PlaybackMode.sequential => '顺序播放',
        PlaybackMode.repeatAll => '列表循环',
        PlaybackMode.repeatOne => '单曲循环',
        PlaybackMode.shuffle => '随机播放',
      };

  static IconData _icon(PlaybackMode mode) => switch (mode) {
        PlaybackMode.sequential => Icons.arrow_forward_rounded,
        PlaybackMode.repeatAll => Icons.repeat_rounded,
        PlaybackMode.repeatOne => Icons.repeat_one_rounded,
        PlaybackMode.shuffle => Icons.shuffle_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final selected = state.playbackMode;
    return PopupMenuButton<PlaybackMode>(
      tooltip: '播放模式：${_label(selected)}',
      initialValue: selected,
      icon: Icon(_icon(selected), color: color),
      onSelected: state.setPlaybackMode,
      itemBuilder: (context) => [
        for (final mode in PlaybackMode.values)
          PopupMenuItem(
            value: mode,
            child: Row(
              children: [
                Icon(_icon(mode), color: mode == selected ? color : null),
                const SizedBox(width: 12),
                Text(_label(mode)),
                const SizedBox(width: 20),
                if (mode == selected)
                  Icon(Icons.check_rounded, size: 20, color: color),
              ],
            ),
          ),
      ],
    );
  }
}
