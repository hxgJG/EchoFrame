import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/models/media_item.dart';

void main() {
  test('persists the optional cached artwork file path', () {
    final item = MediaItem(
      id: 'audio-1',
      kind: MediaKind.audio,
      title: '歌曲',
      artist: '歌手',
      album: '专辑',
      duration: const Duration(minutes: 3),
      path: '/music/song.mp3',
      folder: '/music',
      addedAt: DateTime(2026),
      accentColor: const Color(0xFF123456),
      artworkPath: '/cache/audio-1.cover',
    );

    final restored = MediaItem.fromJson(item.toJson());

    expect(restored.artworkPath, '/cache/audio-1.cover');
    expect(
      restored.copyWith(artworkPath: '/cache/new.cover').artworkPath,
      '/cache/new.cover',
    );
  });
}
