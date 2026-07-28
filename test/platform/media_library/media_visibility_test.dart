import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/models/media_item.dart';
import 'package:lumio/platform/media_library/media_visibility.dart';

void main() {
  test('hidden media stays outside later scan results', () {
    final visible = MediaItem(
      id: 'audio-1',
      kind: MediaKind.audio,
      title: '保留',
      artist: '歌手',
      album: '专辑',
      duration: const Duration(minutes: 3),
      path: '/music/keep.mp3',
      folder: '/music',
      addedAt: DateTime(2026),
      accentColor: const Color(0xFF123456),
    );
    final hidden = visible.copyWith(id: 'audio-2', title: '隐藏');

    final result = visibleMediaItems(
      <MediaItem>[visible, hidden],
      <String>{hidden.id},
    );

    expect(result.map((item) => item.id), <String>[visible.id]);
  });
}
