import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app_state.dart';
import 'app/theme.dart';
import 'features/music/music_home_page.dart';
import 'features/music/music_library_page.dart';
import 'features/music/now_playing_page.dart';
import 'features/music/lyric_calibration_dialog.dart';
import 'features/music/playlists_page.dart';
import 'features/settings/settings_page.dart';
import 'features/video/video_page.dart';
import 'shared/widgets/mini_player.dart';
import 'shared/widgets/mobile_player_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(LumioApp(state: LumioAppState()));
}

class LumioApp extends StatefulWidget {
  const LumioApp({super.key, required this.state});

  final LumioAppState state;

  @override
  State<LumioApp> createState() => _LumioAppState();
}

class _LumioAppState extends State<LumioApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  LumioAppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.desktopLyrics.onOpenCalibration = _openCalibration;
  }

  @override
  void didUpdateWidget(covariant LumioApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != state) {
      oldWidget.state.desktopLyrics.onOpenCalibration = null;
      state.desktopLyrics.onOpenCalibration = _openCalibration;
    }
  }

  void _openCalibration(String mediaId) {
    final context = _navigatorKey.currentContext;
    if (context != null && state.currentItem?.id == mediaId) {
      showLyricCalibration(context, state);
    }
  }

  @override
  void dispose() {
    state.desktopLyrics.onOpenCalibration = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: _navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: LumioTheme.light(
              accent: state.settings.themeAccent,
              themeId: state.settings.themeId),
          darkTheme: LumioTheme.dark(
              accent: state.settings.themeAccent,
              themeId: state.settings.themeId),
          themeMode: state.settings.themeMode,
          title: '忆光',
          builder: (context, child) {
            final scheme = Theme.of(context).colorScheme;
            state.desktopLyrics.setAppearance({
              'backgroundColor': scheme.surfaceContainerLow.toARGB32(),
              'foregroundColor': LumioTheme.audioColor(context).toARGB32(),
              'secondaryColor': scheme.onSurfaceVariant.toARGB32(),
              'borderColor': scheme.outlineVariant.toARGB32(),
              'dark': scheme.brightness == Brightness.dark,
            });
            return child!;
          },
          home: LumioShell(state: state),
        );
      },
    );
  }
}

class LumioShell extends StatelessWidget {
  const LumioShell({super.key, required this.state});

  final LumioAppState state;

  static const List<_LumioDestination> _destinations = <_LumioDestination>[
    _LumioDestination(
      section: AppSection.home,
      label: '首页',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
    ),
    _LumioDestination(
      section: AppSection.music,
      label: '音乐库',
      icon: Icons.library_music_outlined,
      selectedIcon: Icons.library_music_rounded,
    ),
    _LumioDestination(
      section: AppSection.playlists,
      label: '播放列表',
      icon: Icons.queue_music_outlined,
      selectedIcon: Icons.queue_music_rounded,
    ),
    _LumioDestination(
      section: AppSection.video,
      label: '视频',
      icon: Icons.movie_outlined,
      selectedIcon: Icons.movie_rounded,
    ),
    _LumioDestination(
      section: AppSection.settings,
      label: '设置',
      icon: Icons.tune_rounded,
      selectedIcon: Icons.tune_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final shell = CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () =>
            state.selectSection(AppSection.home),
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () =>
            state.selectSection(AppSection.music),
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () =>
            state.selectSection(AppSection.playlists),
        const SingleActivator(LogicalKeyboardKey.digit4, meta: true): () =>
            state.selectSection(AppSection.video),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
            state.selectSection(AppSection.settings),
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
            state.addMediaSources,
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            state.scanMediaLibrary,
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (!_editingText()) {
            state.togglePlaying();
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return constraints.maxWidth >= 1000
                ? _DesktopShell(
                    state: state,
                    destinations: _destinations,
                    onOpenNowPlaying: () => _openNowPlaying(context),
                  )
                : _CompactShell(
                    state: state,
                    destinations: _destinations,
                    onOpenNowPlaying: () => _openNowPlaying(context),
                  );
          },
        ),
      ),
    );
    if (!Platform.isMacOS) {
      return shell;
    }
    return PlatformMenuBar(
      menus: <PlatformMenuItem>[
        const PlatformMenu(
          label: 'Lumio',
          menus: <PlatformMenuItem>[
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.about,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.servicesSubmenu,
            ),
            PlatformMenuItemGroup(
              members: <PlatformMenuItem>[
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hide,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hideOtherApplications,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.showAllApplications,
                ),
              ],
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.quit,
            ),
          ],
        ),
        PlatformMenu(
          label: '文件',
          menus: <PlatformMenuItem>[
            PlatformMenuItem(
              label: '添加媒体文件夹…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyO,
                meta: true,
              ),
              onSelected: state.addMediaSources,
            ),
            PlatformMenuItem(
              label: '重新扫描媒体库',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyR,
                meta: true,
              ),
              onSelected: state.scanMediaLibrary,
            ),
          ],
        ),
        PlatformMenu(
          label: '播放',
          menus: <PlatformMenuItem>[
            PlatformMenuItem(
              label: state.isPlaying ? '暂停' : '播放',
              onSelected: state.togglePlaying,
            ),
            PlatformMenuItem(label: '上一首', onSelected: state.previous),
            PlatformMenuItem(label: '下一首', onSelected: state.next),
          ],
        ),
        PlatformMenu(
          label: '前往',
          menus: <PlatformMenuItem>[
            for (final destination in _destinations)
              PlatformMenuItem(
                label: destination.label,
                onSelected: () => state.selectSection(destination.section),
              ),
          ],
        ),
        PlatformMenu(
          label: '显示',
          menus: <PlatformMenuItem>[
            PlatformMenuItem(
              label: state.desktopLyrics.enabled ? '关闭桌面歌词' : '开启桌面歌词',
              onSelected: () =>
                  state.desktopLyrics.setEnabled(!state.desktopLyrics.enabled),
            ),
            PlatformMenuItem(
              label: state.desktopLyrics.locked ? '解锁桌面歌词' : '锁定桌面歌词',
              onSelected: state.desktopLyrics.enabled
                  ? () =>
                      state.desktopLyrics.setLocked(!state.desktopLyrics.locked)
                  : null,
            ),
            PlatformMenuItem(
              label: '跟随系统外观',
              onSelected: () => state.setThemeMode(ThemeMode.system),
            ),
            PlatformMenuItem(
              label: '浅色外观',
              onSelected: () => state.setThemeMode(ThemeMode.light),
            ),
            PlatformMenuItem(
              label: '夜间模式',
              onSelected: () => state.setThemeMode(ThemeMode.dark),
            ),
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.toggleFullScreen,
            ),
          ],
        ),
        const PlatformMenu(
          label: '窗口',
          menus: <PlatformMenuItem>[
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
            ),
          ],
        ),
        PlatformMenu(
          label: '帮助',
          menus: <PlatformMenuItem>[
            PlatformMenuItem(
              label: '关于与版本信息',
              onSelected: () => state.selectSection(AppSection.settings),
            ),
          ],
        ),
      ],
      child: shell,
    );
  }

  bool _editingText() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context?.widget is EditableText ||
        context?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _openNowPlaying(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimatedBuilder(
          animation: state,
          builder: (context, _) => NowPlayingPage(state: state),
        ),
      ),
    );
  }
}

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.state,
    required this.destinations,
    required this.onOpenNowPlaying,
  });

  final LumioAppState state;
  final List<_LumioDestination> destinations;
  final VoidCallback onOpenNowPlaying;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: <Widget>[
          _MediaShelf(state: state, destinations: destinations),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: <Widget>[
                Expanded(
                  child: SafeArea(bottom: false, child: _pageFor(state)),
                ),
                MiniPlayer(state: state, onExpand: onOpenNowPlaying),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaShelf extends StatelessWidget {
  const _MediaShelf({required this.state, required this.destinations});

  final LumioAppState state;
  final List<_LumioDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 220,
      color: scheme.surfaceContainerLowest,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 3,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    LumioTheme.brandMint,
                    LumioTheme.brandJade,
                    LumioTheme.peach,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 14, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset(
                          'assets/branding/lumio_logo_128.png',
                          width: 38,
                          height: 38,
                          cacheWidth: 114,
                          cacheHeight: 114,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '忆光',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text('LUMIO', style: TextStyle(fontSize: 10)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  for (final destination in destinations)
                    _ShelfDestination(
                      destination: destination,
                      selected: state.section == destination.section,
                      onTap: () => state.selectSection(destination.section),
                    ),
                  const Spacer(),
                  if (state.mediaSources.isEmpty &&
                      state.platformCapabilities.supportsFolderPicker)
                    OutlinedButton.icon(
                      onPressed: state.addMediaSources,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('添加媒体'),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '${state.audioItems.length} 首音乐  ·  '
                    '${state.videoItems.length} 个视频',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShelfDestination extends StatelessWidget {
  const _ShelfDestination({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _LumioDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: <Widget>[
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  destination.label,
                  style: TextStyle(
                    color:
                        selected ? scheme.onPrimaryContainer : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactShell extends StatelessWidget {
  const _CompactShell({
    required this.state,
    required this.destinations,
    required this.onOpenNowPlaying,
  });

  final LumioAppState state;
  final List<_LumioDestination> destinations;
  final VoidCallback onOpenNowPlaying;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final navigationColor = switch (state.section) {
      AppSection.home ||
      AppSection.music ||
      AppSection.playlists =>
        LumioTheme.audioColor(context),
      AppSection.video => LumioTheme.videoColor(context),
      AppSection.settings => scheme.primary,
    };
    final navigation = NavigationBarTheme(
      data: NavigationBarThemeData(
        indicatorColor: navigationColor.withValues(
          alpha: scheme.brightness == Brightness.dark ? 0.24 : 0.14,
        ),
      ),
      child: NavigationBar(
        selectedIndex: state.section.index,
        onDestinationSelected: (index) {
          state.selectSection(destinations[index].section);
        },
        destinations: destinations
            .map(
              (destination) => NavigationDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.selectedIcon),
                label: destination.label,
              ),
            )
            .toList(growable: false),
      ),
    );
    if (Platform.isAndroid ||
        Platform.isIOS ||
        Platform.operatingSystem == 'ohos') {
      return MobilePlayerShell(
        state: state,
        body: _pageFor(state),
        navigationBar: navigation,
        onOpenNowPlaying: onOpenNowPlaying,
      );
    }
    return Scaffold(
      body: SafeArea(bottom: false, child: _pageFor(state)),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniPlayer(state: state, onExpand: onOpenNowPlaying),
          navigation
        ],
      ),
    );
  }
}

Widget _pageFor(LumioAppState state) {
  return switch (state.section) {
    AppSection.home => MusicHomePage(state: state),
    AppSection.music => MusicLibraryPage(state: state),
    AppSection.playlists => PlaylistsPage(state: state),
    AppSection.video => VideoPage(state: state),
    AppSection.settings => SettingsPage(state: state),
  };
}

class _LumioDestination {
  const _LumioDestination({
    required this.section,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final AppSection section;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
