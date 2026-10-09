import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/media_item.dart';

const portableMediaSource = 'lumio-backup';
const portableMetadataLimit = 128 * 1024 * 1024;

String portableKey(MediaItem item) =>
    item.backupIdentity['key'] as String? ??
    sha256
        .convert(utf8.encode('${item.kind.name}\n${item.id}\n${item.path}'))
        .toString()
        .substring(0, 32);

/// Native paths, authorizations and local IDs never leave the exporting device.
Map<String, Object?> portableState(Map<String, Object?> snapshot) {
  final state =
      Map<String, Object?>.from(jsonDecode(jsonEncode(snapshot)) as Map);
  final remap = <String, String>{};
  final pathRefs = <String, String>{};
  for (final key in ['audioItems', 'videoItems']) {
    state[key] = (state[key] as List).map((raw) {
      final item = MediaItem.fromJson(Map<String, Object?>.from(raw as Map));
      final id = 'portable-${portableKey(item)}';
      remap[item.id] = id;
      final path = 'lumio-backup://media/$id';
      pathRefs[item.path] = path;
      return item.toJson()
        ..['id'] = id
        ..['path'] = path
        ..['folder'] = ''
        ..['artworkPath'] = null
        ..['sourceId'] = portableMediaSource
        ..['relativePath'] = null
        ..['availability'] = 'missing'
        ..['backupIdentity'] = {
          'key': portableKey(item),
          'fileName':
              item.backupIdentity['fileName'] ?? item.path.split('/').last,
          'fingerprint': item.backupIdentity['fingerprint'] ?? '',
        };
    }).toList();
  }
  List<String> refs(Object? raw) => (raw as List? ?? [])
      .whereType<String>()
      .where(remap.containsKey)
      .map((id) => remap[id]!)
      .toList();
  for (final raw in state['playlists'] as List) {
    (raw as Map)['mediaIds'] = refs(raw['mediaIds']);
  }
  state['queueIds'] = refs(state['queueIds']);
  state['hiddenMediaIds'] = refs(state['hiddenMediaIds']);
  state['currentItemId'] = remap[state['currentItemId']];
  state['lastAudioItemId'] = remap[state['lastAudioItemId']];
  state['receivedMedia'] = {
    'version': 1,
    'items': [],
    'digests': {},
    'applied': []
  };
  state['lyricLibraryUndo'] = null;
  for (final raw
      in (state['lyricLibrary'] as Map?)?['entries'] as List? ?? []) {
    (raw as Map)['handled'] = {};
    raw['excluded'] = [];
    raw['source'] = '';
  }
  final settings = state['settings'] as Map;
  settings['includedFolders'] = [];
  settings['excludedFolders'] = [];
  for (final raw in state['subtitleProjects'] as List? ?? []) {
    final project = raw as Map;
    final source = project['source'] as Map;
    project['source'] = {
      for (final key in [
        'name',
        'size',
        'durationMs',
        'width',
        'height',
        'fileSizeBytes'
      ])
        if (source.containsKey(key)) key: source[key],
      'fileName': source['fileName'] ??
          source['path']?.toString().split('/').last ??
          '',
      'path':
          pathRefs[source['path']] ?? 'lumio-backup://project/${project['id']}',
    };
    project.remove('libraryBinding');
  }
  const allowed = {
    'schemaVersion',
    'audioItems',
    'videoItems',
    'receivedMedia',
    'lyricLibrary',
    'lyricLibraryUndo',
    'playlists',
    'settings',
    'queueIds',
    'hiddenMediaIds',
    'currentItemId',
    'lastAudioItemId',
    'lastAudioPositionMs',
    'positionMs',
    'musicSort',
    'shuffleEnabled',
    'repeatMode',
    'playbackView',
    'playbackSpeed',
    'subtitleProjects',
  };
  state.removeWhere((key, _) => !allowed.contains(key));
  return state;
}

void validatePortableState(Map<String, Object?> state) {
  final ids = <String>{};
  for (final raw in [
    ...state['audioItems'] as List,
    ...state['videoItems'] as List
  ]) {
    final item = MediaItem.fromJson(Map<String, Object?>.from(raw as Map));
    final key = item.backupIdentity['key'];
    final hash = item.backupIdentity['fingerprint'];
    if (key is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(key) ||
        item.id != 'portable-$key' ||
        !ids.add(item.id) ||
        item.path != 'lumio-backup://media/${item.id}' ||
        item.sourceId != portableMediaSource ||
        item.fileSizeBytes < 0 ||
        item.duration.isNegative ||
        hash is! String ||
        (hash.isNotEmpty && !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(hash)) ||
        item.backupIdentity['fileName'] is! String) {
      throw const FormatException('跨端备份的媒体引用无效。');
    }
  }
  void check(Object? raw) {
    if (raw is! List || raw.any((id) => id is! String || !ids.contains(id))) {
      throw const FormatException('跨端备份含无效的歌单或播放引用。');
    }
  }

  check(state['queueIds']);
  check(state['hiddenMediaIds']);
  for (final raw in state['playlists'] as List) {
    check((raw as Map)['mediaIds']);
  }
  for (final key in ['currentItemId', 'lastAudioItemId']) {
    if (state[key] != null && !ids.contains(state[key])) {
      throw const FormatException('跨端备份的播放记录引用无效。');
    }
  }
  if (((state['receivedMedia'] as Map)['items'] as List).isNotEmpty) {
    throw const FormatException('仅数据备份不可携带本机接收路径。');
  }
  for (final raw in state['subtitleProjects'] as List? ?? []) {
    final project = raw as Map, source = project['source'] as Map;
    if (project['libraryBinding'] != null ||
        source['bookmark'] != null ||
        source['path'] is! String ||
        !(source['path'] as String).startsWith('lumio-backup://')) {
      throw const FormatException('跨端字幕项目不能携带文件授权或本机路径。');
    }
  }
}

String _text(String value) => value.trim().toLowerCase();

List<String> _matchKeys(MediaItem item) {
  final duration = item.duration.inMilliseconds;
  if (duration <= 0) return [];
  final size = item.fileSizeBytes;
  final file = _text(
      item.backupIdentity['fileName'] as String? ?? item.path.split('/').last);
  return [
    for (final bucket in [
      duration ~/ 1000 - 1,
      duration ~/ 1000,
      duration ~/ 1000 + 1
    ]) ...[
      if (size > 0 && file.isNotEmpty) 'file:$file:$bucket:$size',
      for (final alias in [
        {'title': item.title, 'artist': item.artist},
        ...item.lyricMatchAliases
      ])
        if (_text(alias['title'] ?? '').isNotEmpty &&
            _text(alias['artist'] ?? '').isNotEmpty &&
            alias['artist'] != '未知艺术家')
          'name:${_text(alias['title'] ?? '')}:${_text(alias['artist'] ?? '')}:$bucket:$size',
    ],
  ];
}

/// Only unambiguous one-to-one matches; conflicting known hashes never fall back.
Map<String, MediaItem> matchPortableMedia(List<MediaItem> pending,
    List<MediaItem> local, Map<String, String> fingerprints) {
  final byHash = <String, List<MediaItem>>{},
      byKey = <String, List<MediaItem>>{};
  String hash(MediaItem e) =>
      fingerprints[e.path] ?? e.backupIdentity['fingerprint'] as String? ?? '';
  final uniqueLocal = {for (final item in local) item.id: item};
  for (final item
      in uniqueLocal.values.where((e) => e.sourceId != portableMediaSource)) {
    final h = hash(item);
    if (h.isNotEmpty) (byHash['${item.kind.name}:$h'] ??= []).add(item);
    for (final key in _matchKeys(item).toSet()) {
      (byKey['${item.kind.name}:$key'] ??= []).add(item);
    }
  }
  final proposed = <String, MediaItem>{};
  for (final item in pending.where((e) => e.sourceId == portableMediaSource)) {
    final h = hash(item);
    var candidates =
        h.isEmpty ? <MediaItem>[] : byHash['${item.kind.name}:$h'] ?? [];
    if (candidates.isEmpty) {
      final unique = <String, MediaItem>{};
      for (final key in _matchKeys(item)) {
        for (final candidate
            in byKey['${item.kind.name}:$key'] ?? <MediaItem>[]) {
          if ((item.duration - candidate.duration).inMilliseconds.abs() > 1000)
            continue;
          if (h.isNotEmpty &&
              hash(candidate).isNotEmpty &&
              h != hash(candidate)) continue;
          unique[candidate.id] = candidate;
        }
      }
      candidates = unique.values.toList();
    }
    if (candidates.length == 1) proposed[item.id] = candidates.single;
  }
  final counts = <String, int>{};
  for (final item in proposed.values) {
    counts[item.id] = (counts[item.id] ?? 0) + 1;
  }
  proposed.removeWhere((_, item) => counts[item.id] != 1);
  return proposed;
}

MediaItem bindPortableMedia(MediaItem saved, MediaItem local) => local.copyWith(
      title: saved.title,
      artist: saved.artist,
      album: saved.album,
      playCount: saved.playCount,
      shuffleWeight: saved.shuffleWeight,
      isFavorite: saved.isFavorite,
      lastPosition: saved.lastPosition,
      lyrics: saved.lyrics.isNotEmpty ? saved.lyrics : local.lyrics,
      hasCustomLyrics: saved.lyrics.isNotEmpty || saved.hasCustomLyrics,
      lyricTiming: saved.lyricTiming,
      lyricDraft: saved.lyricDraft,
      lyricMatchAliases: saved.lyricMatchAliases,
      subtitles: saved.subtitles.isNotEmpty ? saved.subtitles : local.subtitles,
      subtitleState: saved.subtitleState,
      backupIdentity: saved.backupIdentity,
    );
