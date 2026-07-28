import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'app/theme.dart';
import 'features/music/music_home_page.dart';
import 'features/music/music_library_page.dart';
import 'features/music/now_playing_page.dart';
import 'features/music/playlists_page.dart';
import 'features/settings/settings_page.dart';
import 'features/video/video_page.dart';
import 'shared/widgets/mini_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(LumioApp(state: LumioAppState()));
}

class LumioApp extends StatelessWidget {
  const LumioApp({super.key, required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumioTheme.light(accent: state.settings.themeAccent),
          darkTheme: LumioTheme.dark(accent: state.settings.themeAccent),
          themeMode: state.settings.themeMode,
          title: '忆光',
          home: LumioShell(state: state),
        );
      },
    );
  }
}

class LumioShell extends StatelessWidget {
  const LumioShell({super.key, required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final navigationColor = switch (state.section) {
      AppSection.home ||
      AppSection.music ||
      AppSection.playlists =>
        LumioTheme.audioColor(brightness),
      AppSection.video => LumioTheme.videoColor(brightness),
      AppSection.settings => scheme.primary,
    };
    final page = switch (state.section) {
      AppSection.home => MusicHomePage(state: state),
      AppSection.music => MusicLibraryPage(state: state),
      AppSection.playlists => PlaylistsPage(state: state),
      AppSection.video => VideoPage(state: state),
      AppSection.settings => SettingsPage(state: state),
    };

    return Scaffold(
      body: SafeArea(bottom: false, child: page),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          MiniPlayer(state: state, onExpand: () => _openNowPlaying(context)),
          NavigationBarTheme(
            data: NavigationBarThemeData(
              indicatorColor: navigationColor.withValues(
                alpha: brightness == Brightness.dark ? 0.24 : 0.14,
              ),
              iconTheme: WidgetStateProperty.resolveWith(
                (states) => IconThemeData(
                  color: states.contains(WidgetState.selected)
                      ? navigationColor
                      : scheme.onSurfaceVariant,
                ),
              ),
              labelTextStyle: WidgetStateProperty.resolveWith(
                (states) => TextStyle(
                  color: states.contains(WidgetState.selected)
                      ? navigationColor
                      : scheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: states.contains(WidgetState.selected)
                      ? FontWeight.w800
                      : FontWeight.w600,
                ),
              ),
            ),
            child: NavigationBar(
              selectedIndex: state.section.index,
              onDestinationSelected: (index) {
                state.selectSection(AppSection.values[index]);
              },
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: '首页',
                ),
                NavigationDestination(
                  icon: Icon(Icons.library_music_outlined),
                  selectedIcon: Icon(Icons.library_music_rounded),
                  label: '音乐库',
                ),
                NavigationDestination(
                  icon: Icon(Icons.queue_music_outlined),
                  selectedIcon: Icon(Icons.queue_music_rounded),
                  label: '列表',
                ),
                NavigationDestination(
                  icon: Icon(Icons.movie_outlined),
                  selectedIcon: Icon(Icons.movie_rounded),
                  label: '视频',
                ),
                NavigationDestination(
                  icon: Icon(Icons.tune_rounded),
                  selectedIcon: Icon(Icons.tune_rounded),
                  label: '设置',
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
