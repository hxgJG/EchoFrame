import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme_catalog.dart';
import '../../shared/widgets/section_header.dart';
import '../device_transfer/device_transfer_page.dart';
import 'app_update_page.dart';
import 'settings_detail_page.dart';
import 'settings_theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) => SettingsTheme(
          child: Builder(
        builder: (context) => AnimatedBuilder(
          animation: state,
          builder: (context, _) {
            final theme = Theme.of(context);
            return Scaffold(
              appBar: AppBar(title: const Text('设置')),
              body: ListTileTheme(
                data: ListTileTheme.of(context).copyWith(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  horizontalTitleGap: 12,
                  minLeadingWidth: 24,
                  minVerticalPadding: 12,
                  titleTextStyle: theme.textTheme.titleMedium,
                  subtitleTextStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant, height: 1.45),
                ),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    const SectionHeader(title: '个性化与播放'),
                    Card(
                      child: Column(children: [
                        _category(
                            context,
                            SettingsCategory.appearance,
                            Icons.palette_outlined,
                            '${LumioThemeCatalog.resolve(state.settings.themeId).label} · ${_themeModeLabel(state.settings.themeMode)}'),
                        if (state.desktopLyrics.supported)
                          _category(context, SettingsCategory.desktopLyrics,
                              Icons.lyrics_outlined, '悬浮歌词、透明度、锁定与律动'),
                        _category(context, SettingsCategory.playback,
                            Icons.slideshow_rounded, '默认视图、字幕字号、颜色与位置'),
                        _category(context, SettingsCategory.audio,
                            Icons.tune_rounded, '速度、均衡器、定时器与歌词偏移'),
                        _category(context, SettingsCategory.enhancement,
                            Icons.cloud_off_rounded, '封面与歌词联网补全、离线保护'),
                      ]),
                    ),
                    const SectionHeader(title: '媒体与数据'),
                    Card(
                      child: Column(children: [
                        _category(
                            context,
                            SettingsCategory.library,
                            Icons.video_library_outlined,
                            '${state.audioItems.length} 首音乐 · ${state.videoItems.length} 个视频 · 扫描与歌词管理'),
                        _category(context, SettingsCategory.backup,
                            Icons.backup_outlined, '导出、导入、本机备份与云端备份'),
                        if (Platform.isMacOS || Platform.isAndroid)
                          _entry(
                              title: '设备互传',
                              subtitle: '局域网传输音乐、视频与歌词',
                              icon: Icons.devices_rounded,
                              onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                      builder: (_) =>
                                          DeviceTransferPage(state: state)))),
                      ]),
                    ),
                    const SectionHeader(title: '应用'),
                    Card(
                      child: Column(children: [
                        if (Platform.isMacOS || Platform.isAndroid)
                          _entry(
                              title: '应用更新',
                              subtitle: '查看版本、检查和下载更新',
                              icon: Icons.system_update_alt,
                              onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                      builder: (_) =>
                                          AppUpdatePage(state: state)))),
                        _category(context, SettingsCategory.about,
                            Icons.info_outline_rounded, '应用介绍与致谢'),
                      ]),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ));

  Widget _category(BuildContext context, SettingsCategory category,
          IconData icon, String subtitle) =>
      _entry(
        title: category.title,
        subtitle: subtitle,
        icon: icon,
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) =>
                SettingsDetailPage(state: state, category: category))),
      );

  Widget _entry(
          {required String title,
          required String subtitle,
          required IconData icon,
          required VoidCallback onTap}) =>
      ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      );

  String _themeModeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '日间',
        ThemeMode.dark => '夜间',
      };
}
