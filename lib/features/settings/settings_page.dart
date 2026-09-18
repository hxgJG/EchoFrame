import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../app/theme_catalog.dart';
import '../../core/models/lumio_settings.dart';
import '../../core/models/media_item.dart';
import '../../shared/widgets/section_header.dart';

const List<String> _equalizerBands = <String>['60', '230', '910', '4k', '14k'];

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final capabilities = state.platformCapabilities;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: <Widget>[
          const SectionHeader(title: '外观'),
          _SettingsCard(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.style_outlined),
                title: const Text('主题方案'),
                subtitle: const Text('每套方案均包含日间与夜间配色'),
                trailing: DropdownButton<String>(
                  value: LumioThemeCatalog.resolve(state.settings.themeId).id,
                  underline: const SizedBox.shrink(),
                  items: LumioThemeCatalog.themes
                      .map(
                        (theme) => DropdownMenuItem(
                            value: theme.id, child: Text(theme.label)),
                      )
                      .toList(growable: false),
                  onChanged: (id) {
                    if (id != null) state.setThemeId(id);
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.brightness_6_rounded),
                title: const Text('明暗模式'),
                subtitle: Text(_themeLabel(state.settings.themeMode)),
                trailing: SegmentedButton<ThemeMode>(
                  segments: const <ButtonSegment<ThemeMode>>[
                    ButtonSegment(
                      value: ThemeMode.system,
                      tooltip: '跟随系统',
                      icon: Icon(Icons.phone_android_rounded),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      tooltip: '日间模式',
                      icon: Icon(Icons.light_mode_rounded),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      tooltip: '夜间模式',
                      icon: Icon(Icons.dark_mode_rounded),
                    ),
                  ],
                  selected: <ThemeMode>{state.settings.themeMode},
                  onSelectionChanged: (value) =>
                      state.setThemeMode(value.first),
                ),
              ),
              const SwitchListTile(
                secondary: Icon(Icons.palette_rounded),
                title: Text('动态取色'),
                subtitle: Text('当前构建尚未接入 Material You，暂不可用'),
                value: false,
                onChanged: null,
              ),
              ListTile(
                leading: const Icon(Icons.color_lens_rounded),
                title: const Text('主题色'),
                subtitle: Text(_themeAccentLabel(state.settings.themeAccent)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SegmentedButton<ThemeAccent>(
                  segments: ThemeAccent.values
                      .map(
                        (accent) => ButtonSegment<ThemeAccent>(
                          value: accent,
                          icon: Icon(
                            Icons.circle,
                            color: scheme.brightness == Brightness.dark
                                ? LumioTheme.darkAccentColor(accent)
                                : LumioTheme.accentColor(accent),
                          ),
                        ),
                      )
                      .toList(growable: false),
                  selected: <ThemeAccent>{state.settings.themeAccent},
                  onSelectionChanged: (value) =>
                      state.setThemeAccent(value.first),
                ),
              ),
            ],
          ),
          if (state.desktopLyrics.supported) ...<Widget>[
            const SectionHeader(title: '桌面歌词'),
            _SettingsCard(children: <Widget>[
              SwitchListTile(
                secondary: const Icon(Icons.lyrics_outlined),
                title: const Text('显示桌面歌词'),
                subtitle: Text(state.desktopLyrics.error ??
                    'macOS 置顶显示当前句和下一句，最小化主窗口后仍可查看。'),
                value: state.desktopLyrics.enabled,
                onChanged: state.desktopLyrics.setEnabled,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.lock_outline_rounded),
                title: const Text('锁定桌面歌词'),
                subtitle: const Text('锁定后鼠标穿透；可从此处或“显示”菜单解锁。'),
                value: state.desktopLyrics.locked,
                onChanged: state.desktopLyrics.enabled
                    ? state.desktopLyrics.setLocked
                    : null,
              ),
              ListTile(
                leading: const Icon(Icons.center_focus_strong_rounded),
                title: const Text('重置歌词窗口位置'),
                subtitle: const Text('恢复到主屏幕底部，并解除锁定。'),
                enabled: state.desktopLyrics.enabled,
                onTap: state.desktopLyrics.enabled
                    ? state.desktopLyrics.resetPosition
                    : null,
              ),
            ]),
          ],
          const SectionHeader(title: '播放页'),
          _SettingsCard(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.slideshow_rounded),
                title: const Text('默认播放页视图'),
                subtitle: const Text('控制打开播放页时优先显示的内容'),
                trailing: SegmentedButton<PlaybackView>(
                  segments: const <ButtonSegment<PlaybackView>>[
                    ButtonSegment(
                      value: PlaybackView.artwork,
                      icon: Icon(Icons.album_rounded),
                    ),
                    ButtonSegment(
                      value: PlaybackView.lyrics,
                      icon: Icon(Icons.lyrics_rounded),
                    ),
                  ],
                  selected: <PlaybackView>{state.settings.defaultPlaybackView},
                  onSelectionChanged: (value) =>
                      state.setDefaultPlaybackView(value.first),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.subtitles_rounded),
                title: const Text('字幕字号'),
                subtitle: Text(
                  '${state.settings.subtitleFontSize.toStringAsFixed(0)} px',
                ),
              ),
              Slider(
                min: 12,
                max: 28,
                divisions: 8,
                label:
                    '${state.settings.subtitleFontSize.toStringAsFixed(0)} px',
                value: state.settings.subtitleFontSize,
                onChanged: state.setSubtitleFontSize,
              ),
              ListTile(
                leading: const Icon(Icons.format_color_text_rounded),
                title: const Text('字幕颜色'),
                subtitle: Text(
                  _subtitleTextColorLabel(state.settings.subtitleTextColor),
                ),
                trailing: SegmentedButton<SubtitleTextColor>(
                  segments: const <ButtonSegment<SubtitleTextColor>>[
                    ButtonSegment(
                      value: SubtitleTextColor.white,
                      icon: Icon(Icons.circle_rounded),
                    ),
                    ButtonSegment(
                      value: SubtitleTextColor.yellow,
                      icon: Icon(Icons.circle_rounded),
                    ),
                    ButtonSegment(
                      value: SubtitleTextColor.cyan,
                      icon: Icon(Icons.circle_rounded),
                    ),
                  ],
                  selected: <SubtitleTextColor>{
                    state.settings.subtitleTextColor,
                  },
                  onSelectionChanged: (value) =>
                      state.setSubtitleTextColor(value.first),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.vertical_align_bottom_rounded),
                title: const Text('字幕位置'),
                subtitle: Text(
                  _subtitlePositionLabel(state.settings.subtitlePosition),
                ),
                trailing: SegmentedButton<SubtitlePosition>(
                  segments: const <ButtonSegment<SubtitlePosition>>[
                    ButtonSegment(
                      value: SubtitlePosition.low,
                      icon: Icon(Icons.vertical_align_bottom_rounded),
                    ),
                    ButtonSegment(
                      value: SubtitlePosition.middle,
                      icon: Icon(Icons.vertical_align_center_rounded),
                    ),
                    ButtonSegment(
                      value: SubtitlePosition.high,
                      icon: Icon(Icons.vertical_align_top_rounded),
                    ),
                  ],
                  selected: <SubtitlePosition>{
                    state.settings.subtitlePosition,
                  },
                  onSelectionChanged: (value) =>
                      state.setSubtitlePosition(value.first),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.aspect_ratio_rounded),
                title: const Text('视频画面比例'),
                subtitle:
                    Text(_videoScaleModeLabel(state.settings.videoScaleMode)),
                trailing: SegmentedButton<VideoScaleMode>(
                  segments: const <ButtonSegment<VideoScaleMode>>[
                    ButtonSegment(
                      value: VideoScaleMode.fit,
                      icon: Icon(Icons.fit_screen_rounded),
                    ),
                    ButtonSegment(
                      value: VideoScaleMode.stretch,
                      icon: Icon(Icons.open_in_full_rounded),
                    ),
                    ButtonSegment(
                      value: VideoScaleMode.crop,
                      icon: Icon(Icons.crop_free_rounded),
                    ),
                  ],
                  selected: <VideoScaleMode>{state.settings.videoScaleMode},
                  onSelectionChanged: (value) =>
                      state.setVideoScaleMode(value.first),
                ),
              ),
            ],
          ),
          const SectionHeader(title: '封面与歌词'),
          _SettingsCard(
            children: <Widget>[
              SwitchListTile(
                secondary: Icon(
                  state.settings.allowOnlineEnhancement
                      ? Icons.cloud_sync_rounded
                      : Icons.cloud_off_rounded,
                ),
                title: const Text('允许联网获取封面/歌词'),
                subtitle: const Text(
                  '默认关闭；开启后仅在本地内容不足时按需查询并写入文件缓存',
                ),
                value: state.settings.allowOnlineEnhancement,
                onChanged: state.toggleOnlineEnhancement,
              ),
              ListTile(
                leading: Icon(Icons.offline_pin_rounded, color: scheme.primary),
                title: const Text('离线优先保护'),
                subtitle: const Text(
                  '关闭时零网络请求；已缓存内容仍可离线使用。',
                ),
              ),
            ],
          ),
          const SectionHeader(title: '音频'),
          _SettingsCard(
            children: <Widget>[
              SwitchListTile(
                secondary: const Icon(Icons.compare_arrows_rounded),
                title: const Text('交叉淡入淡出'),
                subtitle: Text(capabilities.supportsCrossfade
                    ? (state.settings.crossfadeEnabled
                        ? '切歌时重叠渐变 3 秒'
                        : '默认关闭；开启后使用 3 秒')
                    : '当前平台首版暂不支持'),
                value: capabilities.supportsCrossfade &&
                    state.settings.crossfadeEnabled,
                onChanged: capabilities.supportsCrossfade
                    ? state.toggleCrossfade
                    : null,
              ),
              ListTile(
                leading: const Icon(Icons.speed_rounded),
                title: const Text('播放速度'),
                subtitle: Text('${state.playbackSpeed.toStringAsFixed(1)}x'),
              ),
              Slider(
                min: 0.5,
                max: 2.0,
                divisions: 15,
                label: '${state.playbackSpeed.toStringAsFixed(1)}x',
                value: state.playbackSpeed,
                onChanged: state.setPlaybackSpeed,
              ),
              ListTile(
                leading: const Icon(Icons.equalizer_rounded),
                title: const Text('均衡器预设'),
                subtitle: Text(
                  _equalizerPresetLabel(state.settings.equalizerPreset),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SegmentedButton<EqualizerPreset>(
                  segments: const <ButtonSegment<EqualizerPreset>>[
                    ButtonSegment(
                      value: EqualizerPreset.off,
                      icon: Icon(Icons.power_settings_new_rounded),
                    ),
                    ButtonSegment(
                      value: EqualizerPreset.bassBoost,
                      icon: Icon(Icons.graphic_eq_rounded),
                    ),
                    ButtonSegment(
                      value: EqualizerPreset.vocal,
                      icon: Icon(Icons.record_voice_over_rounded),
                    ),
                    ButtonSegment(
                      value: EqualizerPreset.rock,
                      icon: Icon(Icons.music_note_rounded),
                    ),
                    ButtonSegment(
                      value: EqualizerPreset.classical,
                      icon: Icon(Icons.piano_rounded),
                    ),
                    ButtonSegment(
                      value: EqualizerPreset.custom,
                      icon: Icon(Icons.tune_rounded),
                    ),
                  ],
                  selected: <EqualizerPreset>{
                    state.settings.equalizerPreset,
                  },
                  onSelectionChanged: capabilities.supportsEqualizer
                      ? (value) => state.setEqualizerPreset(value.first)
                      : null,
                ),
              ),
              if (capabilities.supportsEqualizer &&
                  state.settings.equalizerPreset == EqualizerPreset.custom)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    children: <Widget>[
                      for (final band in _equalizerBands.indexed)
                        Row(
                          children: <Widget>[
                            SizedBox(
                              width: 44,
                              child: Text(
                                band.$2,
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                min: -10,
                                max: 10,
                                divisions: 20,
                                label:
                                    '${state.settings.customEqualizerGains[band.$1].toStringAsFixed(0)} dB',
                                value: state
                                    .settings.customEqualizerGains[band.$1],
                                onChanged: (value) => state
                                    .setCustomEqualizerGain(band.$1, value),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.timer_rounded),
                title: const Text('睡眠定时器'),
                subtitle: Text(state.sleepTimerLabel),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    OutlinedButton(
                      onPressed: () =>
                          state.setSleepTimer(const Duration(minutes: 15)),
                      child: const Text('15 分钟'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          state.setSleepTimer(const Duration(minutes: 30)),
                      child: const Text('30 分钟'),
                    ),
                    TextButton(
                      onPressed: state.cancelSleepTimer,
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.repeat_on_rounded),
                title: const Text('AB 循环'),
                subtitle: Text(state.abLoopLabel),
              ),
              ListTile(
                leading: const Icon(Icons.lyrics_rounded),
                title: const Text('歌词偏移'),
                subtitle: Text(_lyricOffsetLabel(state.settings.lyricOffset)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: () => state.adjustLyricOffset(
                        const Duration(milliseconds: -500),
                      ),
                      icon: const Icon(Icons.remove_rounded),
                      label: const Text('500ms'),
                    ),
                    TextButton(
                      onPressed: () => state.adjustLyricOffset(
                        -state.settings.lyricOffset,
                      ),
                      child: const Text('重置'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => state.adjustLyricOffset(
                        const Duration(milliseconds: 500),
                      ),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('500ms'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SectionHeader(title: '媒体库'),
          _SettingsCard(
            children: <Widget>[
              if (capabilities.supportsFolderPicker) ...<Widget>[
                ListTile(
                  leading: const Icon(Icons.create_new_folder_rounded),
                  title: const Text('媒体来源'),
                  subtitle: Text(state.mediaSources.isEmpty
                      ? '添加音乐或视频所在的文件夹'
                      : '已授权 ${state.mediaSources.length} 个文件夹'),
                  trailing: FilledButton.icon(
                    onPressed: state.isUpdatingMediaSources
                        ? null
                        : state.addMediaSources,
                    icon: state.isUpdatingMediaSources
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_rounded),
                    label: const Text('添加'),
                  ),
                ),
                for (final source in state.mediaSources)
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 48, right: 12),
                    leading: Icon(
                      source.isAvailable
                          ? Icons.folder_rounded
                          : Icons.folder_off_rounded,
                      color: source.isAvailable ? scheme.primary : scheme.error,
                    ),
                    title: Text(source.displayName),
                    subtitle: Text(
                      source.isAvailable
                          ? source.resolvedPath
                          : '授权已失效，请移除后重新添加',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: '移除来源（不删除文件）',
                      onPressed: state.isUpdatingMediaSources
                          ? null
                          : () => state.removeMediaSource(source),
                      icon: const Icon(Icons.remove_circle_outline_rounded),
                    ),
                  ),
              ],
              ListTile(
                leading: state.isScanningLibrary
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.manage_search_rounded),
                title: const Text('扫描/导入本机媒体'),
                subtitle: Text(state.libraryStatusMessage),
                trailing: state.isScanningLibrary
                    ? OutlinedButton.icon(
                        onPressed: state.cancelMediaLibraryScan,
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('取消'),
                      )
                    : FilledButton.icon(
                        onPressed: state.scanMediaLibrary,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('开始'),
                      ),
              ),
              ListTile(
                leading: const Icon(Icons.restore_from_trash_rounded),
                title: const Text('恢复已移除媒体'),
                subtitle: Text(
                  state.hiddenMediaCount == 0
                      ? '没有被隐藏的媒体'
                      : '重新显示 ${state.hiddenMediaCount} 个媒体并扫描',
                ),
                trailing: TextButton(
                  onPressed: state.hiddenMediaCount == 0
                      ? null
                      : state.restoreHiddenMedia,
                  child: const Text('恢复'),
                ),
              ),
              if (!capabilities.supportsFolderPicker)
                ListTile(
                  leading: const Icon(Icons.folder_open_rounded),
                  title: const Text('包含文件夹'),
                  subtitle: Text(
                    state.settings.includedFolders.isEmpty
                        ? '未设置，扫描全部媒体'
                        : '${state.settings.includedFolders.length} 个路径',
                  ),
                  trailing: IconButton(
                    tooltip: '添加',
                    onPressed: () => _showAddIncludedFolderDialog(context),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ),
              if (!capabilities.supportsFolderPicker &&
                  state.settings.includedFolders.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: state.settings.includedFolders
                        .map(
                          (folder) => InputChip(
                            label: Text(folder),
                            onDeleted: () => state.removeIncludedFolder(folder),
                          ),
                        )
                        .toList(),
                  ),
                ),
              if (!capabilities.supportsFolderPicker)
                ListTile(
                  leading: const Icon(Icons.folder_off_rounded),
                  title: const Text('排除文件夹'),
                  subtitle: Text(
                    state.settings.excludedFolders.isEmpty
                        ? '未设置'
                        : '${state.settings.excludedFolders.length} 个路径',
                  ),
                  trailing: IconButton(
                    tooltip: '添加',
                    onPressed: () => _showAddExcludedFolderDialog(context),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ),
              if (!capabilities.supportsFolderPicker &&
                  state.settings.excludedFolders.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: state.settings.excludedFolders
                        .map(
                          (folder) => InputChip(
                            label: Text(folder),
                            onDeleted: () => state.removeExcludedFolder(folder),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.filter_alt_rounded),
                title: const Text('最短音频时长'),
                subtitle: Text(
                  '当前默认 ${state.settings.minimumAudioDuration.inSeconds} 秒',
                ),
              ),
              Slider(
                min: 0,
                max: 300,
                divisions: 20,
                label: '${state.settings.minimumAudioDuration.inSeconds} 秒',
                value: state.settings.minimumAudioDuration.inSeconds
                    .clamp(0, 300)
                    .toDouble(),
                onChanged: (value) => state.setMinimumAudioDuration(
                  Duration(seconds: value.round()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.backup_rounded),
                title: const Text('备份与恢复'),
                subtitle: Text(state.backupStatusMessage),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: state.createBackup,
                      icon: const Icon(Icons.save_alt_rounded),
                      label: const Text('创建备份'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _confirmRestoreBackup(context),
                      icon: const Icon(Icons.restore_rounded),
                      label: const Text('恢复最近备份'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SectionHeader(title: '关于'),
          const _SettingsCard(
            children: <Widget>[
              ListTile(
                leading: Icon(Icons.info_rounded),
                title: Text('忆光'),
                subtitle: Text('本地媒体核心链路 • 兼容鸿蒙构建'),
              ),
              ListTile(
                leading: Icon(Icons.favorite_rounded),
                title: Text('致谢'),
                subtitle: Text('设计参考经典音乐播放器与主流本地播放器体验'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _themeLabel(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => '跟随系统',
      ThemeMode.light => '日间 · 浅色',
      ThemeMode.dark => '夜间 · 深色',
    };
  }

  String _themeAccentLabel(ThemeAccent accent) {
    return switch (accent) {
      ThemeAccent.blue => '薄荷绿',
      ThemeAccent.coral => '柔桃粉',
      ThemeAccent.teal => '深青绿',
      ThemeAccent.violet => '鼠尾草',
    };
  }

  String _lyricOffsetLabel(Duration offset) {
    final milliseconds = offset.inMilliseconds;
    if (milliseconds == 0) {
      return '0ms';
    }
    return '${milliseconds > 0 ? '+' : ''}${milliseconds}ms';
  }

  String _equalizerPresetLabel(EqualizerPreset preset) {
    return switch (preset) {
      EqualizerPreset.off => '关闭',
      EqualizerPreset.bassBoost => '低音增强',
      EqualizerPreset.vocal => '人声',
      EqualizerPreset.rock => '摇滚',
      EqualizerPreset.classical => '古典',
      EqualizerPreset.custom => '自定义',
    };
  }

  String _subtitleTextColorLabel(SubtitleTextColor color) {
    return switch (color) {
      SubtitleTextColor.white => '白色',
      SubtitleTextColor.yellow => '黄色',
      SubtitleTextColor.cyan => '青色',
    };
  }

  String _subtitlePositionLabel(SubtitlePosition position) {
    return switch (position) {
      SubtitlePosition.low => '靠下',
      SubtitlePosition.middle => '居中',
      SubtitlePosition.high => '靠上',
    };
  }

  String _videoScaleModeLabel(VideoScaleMode mode) {
    return switch (mode) {
      VideoScaleMode.fit => '适应屏幕',
      VideoScaleMode.stretch => '拉伸',
      VideoScaleMode.crop => '裁剪填充',
    };
  }

  Future<void> _showAddExcludedFolderDialog(BuildContext context) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加排除文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '/storage/emulated/0/录音',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) {
      state.addExcludedFolder(value);
    }
  }

  Future<void> _showAddIncludedFolderDialog(BuildContext context) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加包含文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '/storage/emulated/0/音乐',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) {
      state.addIncludedFolder(value);
    }
  }

  Future<void> _confirmRestoreBackup(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复最近备份'),
        content: const Text('会用最近的备份覆盖当前播放列表、设置和本地媒体索引。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.restoreLatestBackup();
    }
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(children: children),
    );
  }
}
