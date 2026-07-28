import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumio/core/models/media_item.dart';
import 'package:lumio/platform/online_enhancement/online_enhancement_repository.dart';

void main() {
  late Directory cacheDirectory;
  late MediaItem item;

  setUp(() async {
    cacheDirectory =
        await Directory.systemTemp.createTemp('lumio-online-test-');
    item = MediaItem(
      id: 'external-audio-42',
      kind: MediaKind.audio,
      title: '测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
      duration: const Duration(minutes: 3),
      path: '/music/test.mp3',
      folder: '/music',
      addedAt: DateTime(2026),
      accentColor: const Color(0xFF123456),
    );
  });

  tearDown(() async {
    await cacheDirectory.delete(recursive: true);
  });

  test('disabled mode performs zero network requests', () async {
    var requestCount = 0;
    final repository = FileOnlineEnhancementRepository(
      client: MockClient((_) async {
        requestCount++;
        return http.Response('unexpected', 500);
      }),
      cacheDirectory: () async => cacheDirectory,
      requestDelay: Duration.zero,
    );

    final result = await repository.fetch(item, enabled: false);

    expect(requestCount, 0);
    expect(result, OnlineEnhancementResult.empty);
  });

  test('downloads lyrics and cover once then serves the file cache', () async {
    var requestCount = 0;
    final repository = FileOnlineEnhancementRepository(
      client: MockClient((request) async {
        requestCount++;
        if (request.url.host == 'lrclib.net') {
          expect(
            request.headers['user-agent'],
            'Lumio/1.0.0 (https://github.com/hxgJG/EchoFrame)',
          );
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'syncedLyrics': '[00:01.00]第一行',
                'plainLyrics': '第一行',
              }),
            ),
            200,
            headers: <String, String>{
              HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
            },
          );
        }
        if (request.url.host == 'musicbrainz.org') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'releases': <Object?>[
                <String, Object?>{'id': 'release-id'},
              ],
            }),
            200,
          );
        }
        if (request.url.host == 'coverartarchive.org') {
          return http.Response.bytes(<int>[1, 2, 3, 4], 200);
        }
        return http.Response('not found', 404);
      }),
      cacheDirectory: () async => cacheDirectory,
      requestDelay: Duration.zero,
    );

    final first = await repository.fetch(item, enabled: true);
    final requestsAfterFirstFetch = requestCount;
    final second = await repository.fetch(item, enabled: true);

    expect(first.lyricsText, '[00:01.00]第一行');
    expect(await File(first.artworkPath!).readAsBytes(), <int>[1, 2, 3, 4]);
    expect(second.lyricsText, first.lyricsText);
    expect(second.artworkPath, first.artworkPath);
    expect(requestsAfterFirstFetch, 3);
    expect(requestCount, requestsAfterFirstFetch);
  });

  test('rate limited response is not retried immediately', () async {
    var requestCount = 0;
    final repository = FileOnlineEnhancementRepository(
      client: MockClient((request) async {
        requestCount++;
        return http.Response(
          'rate limited',
          429,
          headers: <String, String>{'retry-after': '60'},
        );
      }),
      cacheDirectory: () async => cacheDirectory,
      requestDelay: Duration.zero,
    );

    final result = await repository.fetch(item, enabled: true);

    expect(requestCount, 1);
    expect(result, OnlineEnhancementResult.empty);
  });
}
