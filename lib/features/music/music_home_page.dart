import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../core/models/media_item.dart';
import '../search/search_page.dart';
import '../../shared/widgets/media_tile.dart';
import '../../shared/widgets/metric_card.dart';
import '../../shared/widgets/section_header.dart';

class MusicHomePage extends StatelessWidget {
  const MusicHomePage({super.key, required this.state});

  final LumioAppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audioColor = LumioTheme.audioColor(scheme.brightness);
    final textTheme = Theme.of(context).textTheme;
    final recent = state.recentlyAdded;
    final mostPlayed = state.mostPlayed;
    final hasSongs = recent.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/branding/lumio_logo_128.png',
                width: 34,
                height: 34,
                cacheWidth: 102,
                cacheHeight: 102,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
            ),
            const SizedBox(width: 10),
            const Text('忆光'),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '搜索',
            onPressed: () => _openSearch(context, state),
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () => state.selectSection(AppSection.settings),
            icon: const Icon(Icons.settings_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: <Widget>[
          _WelcomePanel(totalSongs: state.audioItems.length),
          const SizedBox(height: 16),
          if (!hasSongs)
            _EmptyMusicPanel(
                onScan: () => state.selectSection(AppSection.settings))
          else ...<Widget>[
            GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.45,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: <Widget>[
                MetricCard(
                  icon: Icons.history_rounded,
                  label: '最近播放',
                  value: '${mostPlayed.first.playCount} 次',
                  color: audioColor,
                  onTap: () => state.play(mostPlayed.first),
                ),
                MetricCard(
                  icon: Icons.fiber_new_rounded,
                  label: '最近添加',
                  value: '${recent.length} 首',
                  color: const Color(0xFFFF9A1A),
                  onTap: () => state.play(recent.first),
                ),
                MetricCard(
                  icon: Icons.local_fire_department_rounded,
                  label: '最多播放',
                  value: mostPlayed.first.title,
                  color: const Color(0xFFF27600),
                  onTap: () => state.play(mostPlayed.first),
                ),
                MetricCard(
                  icon: Icons.shuffle_rounded,
                  label: '随机全部',
                  value: '随机',
                  color: const Color(0xFFFFC044),
                  onTap: () => state.shuffleAll(MediaKind.audio),
                ),
              ],
            ),
            SectionHeader(
              title: '推荐',
              actionLabel: '全部歌曲',
              onAction: () => state.selectSection(AppSection.music),
            ),
            _SuggestionCard(
              item: recent.first,
              count: recent.length,
              onPlay: () => state.play(recent.first),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 124,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: mostPlayed.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final item = mostPlayed[index];
                  return _HorizontalAlbum(
                    item: item,
                    onTap: () => state.play(item),
                  );
                },
              ),
            ),
            SectionHeader(
              title: '最近艺术家',
              actionLabel: '查看全部',
              onAction: () => state.selectSection(AppSection.music),
            ),
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: state.artists.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final artist = state.artists[index];
                  final item = state.itemsForArtist(artist).first;
                  return _ArtistBubble(
                    name: artist,
                    color: item.accentColor,
                    onTap: () => state.play(item),
                  );
                },
              ),
            ),
            const SectionHeader(title: '最近添加'),
            ...recent.map(
              (item) => MediaTile(item: item, onTap: () => state.play(item)),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            state.settings.allowOnlineEnhancement
                ? '在线封面/歌词增强已开启，仍优先使用本地信息。'
                : '当前完全离线运行，本地媒体体验不依赖网络。',
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

void _openSearch(BuildContext context, LumioAppState state) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => SearchPage(state: state)),
  );
}

class _EmptyMusicPanel extends StatelessWidget {
  const _EmptyMusicPanel({required this.onScan});

  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audioColor = LumioTheme.audioColor(scheme.brightness);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: <Widget>[
          Icon(Icons.library_music_outlined, color: audioColor, size: 42),
          const SizedBox(height: 10),
          Text('还没有音频媒体', style: textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '可以在设置中扫描本机媒体；没有网络也能完成本地索引。',
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.manage_search_rounded),
            label: const Text('去扫描'),
          ),
        ],
      ),
    );
  }
}

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel({required this.totalSongs});

  final int totalSongs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audioColor = LumioTheme.audioColor(scheme.brightness);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: audioColor.withValues(
          alpha: scheme.brightness == Brightness.dark ? 0.18 : 0.11,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 26,
            backgroundColor: audioColor,
            child: const Text(
              '忆',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 24,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '欢迎回到忆光',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$totalSongs 首本地歌曲已准备好',
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.item,
    required this.count,
    required this.onPlay,
  });

  final MediaItem item;
  final int count;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audioColor = LumioTheme.audioColor(scheme.brightness);
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPlay,
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: <Widget>[
            MediaArtwork(
              item: item,
              size: 86,
              icon: Icons.auto_awesome_rounded,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('最近添加合集', style: textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    '$count 首来自本机的新曲目',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: audioColor,
                      foregroundColor: scheme.brightness == Brightness.dark
                          ? LumioTheme.night
                          : Colors.white,
                    ),
                    onPressed: onPlay,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('播放'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HorizontalAlbum extends StatelessWidget {
  const _HorizontalAlbum({required this.item, required this.onTap});

  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 118,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            MediaArtwork(item: item, size: 68),
            const SizedBox(height: 6),
            Text(
              item.album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleSmall,
            ),
            Text(
              item.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistBubble extends StatelessWidget {
  const _ArtistBubble({
    required this.name,
    required this.color,
    required this.onTap,
  });

  final String name;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      width: 78,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(
          children: <Widget>[
            CircleAvatar(
              radius: 28,
              backgroundColor: color,
              child: Text(
                name.characters.first,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}
