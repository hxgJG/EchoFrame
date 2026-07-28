import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/models/media_item.dart';

class OnlineEnhancementResult {
  const OnlineEnhancementResult({
    this.lyricsText,
    this.artworkPath,
  });

  static const empty = OnlineEnhancementResult();

  final String? lyricsText;
  final String? artworkPath;

  bool get isEmpty => lyricsText == null && artworkPath == null;

  @override
  bool operator ==(Object other) {
    return other is OnlineEnhancementResult &&
        other.lyricsText == lyricsText &&
        other.artworkPath == artworkPath;
  }

  @override
  int get hashCode => Object.hash(lyricsText, artworkPath);
}

abstract class OnlineEnhancementRepository {
  Future<OnlineEnhancementResult> fetch(
    MediaItem item, {
    required bool enabled,
  });
}

class FileOnlineEnhancementRepository implements OnlineEnhancementRepository {
  FileOnlineEnhancementRepository({
    http.Client? client,
    Future<Directory> Function()? cacheDirectory,
    this.requestDelay = const Duration(milliseconds: 300),
  })  : _client = client ?? http.Client(),
        _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory;

  static const _userAgent = 'Lumio/1.0.0 (https://github.com/hxgJG/EchoFrame)';

  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;
  final Duration requestDelay;
  DateTime? _rateLimitedUntil;

  @override
  Future<OnlineEnhancementResult> fetch(
    MediaItem item, {
    required bool enabled,
  }) async {
    if (!enabled || item.kind != MediaKind.audio) {
      return OnlineEnhancementResult.empty;
    }
    try {
      final root = Directory(
        '${(await _cacheDirectory()).path}/lumio_online_enhancement',
      );
      await root.create(recursive: true);
      final cacheKey = _safeCacheKey(item.id);
      final lyricsFile = File('${root.path}/$cacheKey.lrc');
      final artworkFile = File('${root.path}/$cacheKey.cover');

      var lyricsText =
          await lyricsFile.exists() ? await lyricsFile.readAsString() : null;
      var artworkPath = await artworkFile.exists() ? artworkFile.path : null;
      if (lyricsText != null && artworkPath != null) {
        return OnlineEnhancementResult(
          lyricsText: lyricsText,
          artworkPath: artworkPath,
        );
      }

      if (lyricsText == null && item.lyrics.isEmpty) {
        lyricsText = await _fetchLyrics(item);
        if (lyricsText != null && lyricsText.trim().isNotEmpty) {
          await lyricsFile.writeAsString(lyricsText, flush: true);
        } else {
          lyricsText = null;
        }
      }

      if (artworkPath == null && !_isRateLimited) {
        if (requestDelay > Duration.zero) {
          await Future<void>.delayed(requestDelay);
        }
        final artwork = await _fetchArtwork(item);
        if (artwork != null && artwork.isNotEmpty) {
          await artworkFile.writeAsBytes(artwork, flush: true);
          artworkPath = artworkFile.path;
        }
      }
      return OnlineEnhancementResult(
        lyricsText: lyricsText,
        artworkPath: artworkPath,
      );
    } catch (_) {
      return OnlineEnhancementResult.empty;
    }
  }

  Future<String?> _fetchLyrics(MediaItem item) async {
    if (_isRateLimited) {
      return null;
    }
    final response = await _get(
      Uri.https('lrclib.net', '/api/get', <String, String>{
        'track_name': item.title,
        'artist_name': item.artist,
        'album_name': item.album,
        'duration': item.duration.inSeconds.toString(),
      }),
    );
    if (response?.statusCode != HttpStatus.ok) {
      return null;
    }
    final value = jsonDecode(response!.body);
    if (value is! Map<String, Object?>) {
      return null;
    }
    final synced = value['syncedLyrics']?.toString().trim();
    if (synced != null && synced.isNotEmpty) {
      return synced;
    }
    final plain = value['plainLyrics']?.toString().trim();
    return plain == null || plain.isEmpty ? null : plain;
  }

  Future<List<int>?> _fetchArtwork(MediaItem item) async {
    final searchResponse = await _get(
      Uri.https('musicbrainz.org', '/ws/2/release/', <String, String>{
        'query': 'release:"${item.album}" AND artist:"${item.artist}"',
        'fmt': 'json',
        'limit': '1',
      }),
    );
    if (searchResponse?.statusCode != HttpStatus.ok) {
      return null;
    }
    final value = jsonDecode(searchResponse!.body);
    if (value is! Map<String, Object?>) {
      return null;
    }
    final releases = value['releases'];
    if (releases is! List<Object?> || releases.isEmpty) {
      return null;
    }
    final first = releases.first;
    if (first is! Map<String, Object?>) {
      return null;
    }
    final releaseId = first['id']?.toString().trim();
    if (releaseId == null || releaseId.isEmpty) {
      return null;
    }
    if (requestDelay > Duration.zero) {
      await Future<void>.delayed(requestDelay);
    }
    final artworkResponse = await _get(
      Uri.https(
        'coverartarchive.org',
        '/release/$releaseId/front-500',
      ),
    );
    return artworkResponse?.statusCode == HttpStatus.ok
        ? artworkResponse!.bodyBytes
        : null;
  }

  Future<http.Response?> _get(Uri uri) async {
    if (_isRateLimited) {
      return null;
    }
    final response = await _client.get(
      uri,
      headers: const <String, String>{
        HttpHeaders.userAgentHeader: _userAgent,
        HttpHeaders.acceptHeader: 'application/json, image/*',
      },
    ).timeout(const Duration(seconds: 12));
    if (response.statusCode == HttpStatus.tooManyRequests) {
      final seconds = int.tryParse(response.headers['retry-after'] ?? '') ?? 60;
      _rateLimitedUntil = DateTime.now().add(
        Duration(seconds: seconds.clamp(1, 86400)),
      );
    }
    return response;
  }

  bool get _isRateLimited {
    final until = _rateLimitedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  String _safeCacheKey(String value) {
    final safe = value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return safe.isEmpty ? 'unknown' : safe;
  }

  static Future<Directory> _defaultCacheDirectory() async {
    try {
      return await getTemporaryDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }
}
