import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/models/media_item.dart';
import 'package:lumio/platform/playback/share_payload.dart';

void main() {
  test('serializes the minimum fields needed by native sharing', () {
    final item = MediaItem(
      id: 'android-audio-42',
      kind: MediaKind.audio,
      title: '本地歌曲',
      artist: '歌手',
      album: '专辑',
      duration: const Duration(minutes: 3),
      path: '/Music/song.mp3',
      folder: '/Music',
      addedAt: DateTime.fromMillisecondsSinceEpoch(1),
      accentColor: Colors.blue,
    );

    expect(mediaSharePayload(item), <String, Object?>{
      'mediaId': 'android-audio-42',
      'kind': 'audio',
      'title': '本地歌曲',
      'path': '/Music/song.mp3',
    });
  });
}
