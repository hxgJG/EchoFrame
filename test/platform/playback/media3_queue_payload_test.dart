import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/models/media_item.dart';
import 'package:lumio/platform/playback/media3_queue_payload.dart';

void main() {
  final first = MediaItem(
    id: 'audio-1',
    kind: MediaKind.audio,
    title: '第一首',
    artist: '歌手',
    album: '专辑',
    duration: const Duration(minutes: 3),
    path: '/music/first.mp3',
    folder: '/music',
    addedAt: DateTime(2026),
    accentColor: const Color(0xFF000001),
  );
  final second = MediaItem(
    id: 'audio-2',
    kind: MediaKind.audio,
    title: '第二首',
    artist: '歌手',
    album: '专辑',
    duration: const Duration(minutes: 4),
    path: '/music/second.mp3',
    folder: '/music',
    addedAt: DateTime(2026),
    accentColor: const Color(0xFF000002),
  );

  test('builds a unique Media3 queue and locates the current item', () {
    final payload = media3QueuePayload(
      current: second,
      queue: <MediaItem>[first, second, first],
      position: const Duration(seconds: 12),
    );

    expect(payload['currentIndex'], 1);
    expect(payload['positionMs'], 12000);
    expect(
      (payload['items'] as List<Object?>)
          .map((item) => (item as Map<String, Object?>)['mediaId']),
      <String>['audio-1', 'audio-2'],
    );
  });

  test('adds the current item when it is absent from the queue', () {
    final payload = media3QueuePayload(
      current: second,
      queue: <MediaItem>[first],
      position: Duration.zero,
    );

    expect(payload['currentIndex'], 0);
    expect(
      (payload['items'] as List<Object?>)
          .map((item) => (item as Map<String, Object?>)['mediaId']),
      <String>['audio-2', 'audio-1'],
    );
  });
}
