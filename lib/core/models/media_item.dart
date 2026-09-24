import 'package:flutter/material.dart';
import '../lyrics/lyric_draft.dart';

enum MediaKind { audio, video }

enum PlaybackView { artwork, lyrics, video }

enum RepeatMode { off, one, all }

class LyricLine {
  const LyricLine({required this.time, required this.text});

  factory LyricLine.fromJson(Map<String, Object?> json) {
    return LyricLine(
      time: Duration(milliseconds: _asInt(json['timeMs'])),
      text: json['text']?.toString() ?? '',
    );
  }

  final Duration time;
  final String text;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'timeMs': time.inMilliseconds,
      'text': text,
    };
  }
}

class LyricTiming {
  const LyricTiming({this.offsetMs = 0, this.lyricsSignature = ''});

  static const limitMs = 30000;
  final int offsetMs;
  final String lyricsSignature;

  static String signatureFor(List<LyricLine> lines) {
    // 稳定的内容摘要仅用于判断歌词是否更换，不用于安全校验。
    var hash = 0x811c9dc5;
    for (final line in lines) {
      for (final unit
          in '${line.time.inMilliseconds}:${line.text.length}:${line.text}\n'
              .codeUnits) {
        hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
      }
    }
    return '${lines.length}:${hash.toRadixString(16)}';
  }

  static LyricTiming fromJson(Object? value, List<LyricLine> lyrics) {
    if (value is! Map || value['version'] != 1) return const LyricTiming();
    final offset = _asInt(value['offsetMs']);
    final signature = value['lyricsSignature']?.toString() ?? '';
    if (offset.abs() > limitMs || signature != signatureFor(lyrics)) {
      return const LyricTiming();
    }
    return LyricTiming(offsetMs: offset, lyricsSignature: signature);
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'offsetMs': offsetMs,
        'lyricsSignature': lyricsSignature,
      };
}

class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  factory SubtitleCue.fromJson(Map<String, Object?> json) {
    return SubtitleCue(
      start: Duration(milliseconds: _asInt(json['startMs'])),
      end: Duration(milliseconds: _asInt(json['endMs'])),
      text: json['text']?.toString() ?? '',
    );
  }

  final Duration start;
  final Duration end;
  final String text;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'startMs': start.inMilliseconds,
      'endMs': end.inMilliseconds,
      'text': text,
    };
  }
}

class MediaItem {
  const MediaItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.path,
    required this.folder,
    required this.addedAt,
    required this.accentColor,
    this.playCount = 0,
    this.isFavorite = false,
    this.lyrics = const <LyricLine>[],
    this.hasCustomLyrics = false,
    this.lyricTiming = const LyricTiming(),
    this.lyricMatchAliases = const [],
    this.lyricDraft,
    this.subtitles = const <SubtitleCue>[],
    this.subtitleState = const <String, Object?>{},
    this.lastPosition = Duration.zero,
    this.resolution,
    this.fileSizeBytes = 0,
    this.fileSizeLabel,
    this.formatLabel,
    this.artworkPath,
    this.sourceId,
    this.relativePath,
    this.availability = 'available',
  });

  factory MediaItem.fromJson(Map<String, Object?> json) {
    final lyrics = _asList(json['lyrics'])
        .whereType<Map<Object?, Object?>>()
        .map((value) => LyricLine.fromJson(value.cast<String, Object?>()))
        .toList(growable: false);
    final kindName = json['kind']?.toString();
    final kind = MediaKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => MediaKind.audio,
    );
    return MediaItem(
      id: json['id']?.toString() ?? '',
      kind: kind,
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '未知艺术家',
      album: json['album']?.toString() ?? '未知专辑',
      duration: Duration(milliseconds: _asInt(json['durationMs'])),
      path: json['path']?.toString() ?? '',
      folder: json['folder']?.toString() ?? '',
      addedAt: DateTime.fromMillisecondsSinceEpoch(_asInt(json['addedAtMs'])),
      accentColor: Color(_asInt(json['accentColor'])),
      playCount: _asInt(json['playCount']),
      isFavorite: json['isFavorite'] == true,
      lyrics: lyrics,
      lyricTiming: LyricTiming.fromJson(json['lyricTiming'], lyrics),
      lyricMatchAliases: _asList(json['lyricMatchAliases'])
          .whereType<Map>()
          .take(32)
          .map((e) => Map<String, String>.from(e))
          .toList(),
      lyricDraft: LyricDraft.fromJson(json['lyricDraft']),
      hasCustomLyrics: json['hasCustomLyrics'] == true,
      subtitleState: json['subtitleState'] is Map
          ? Map<String, Object?>.from(json['subtitleState'] as Map)
          : const {},
      subtitles: _asList(json['subtitles'])
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => SubtitleCue.fromJson(
              value.cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
      lastPosition: Duration(milliseconds: _asInt(json['lastPositionMs'])),
      resolution: _nullableString(json['resolution']),
      fileSizeBytes: _asInt(json['fileSizeBytes']),
      fileSizeLabel: _nullableString(json['fileSizeLabel']),
      formatLabel: _nullableString(json['formatLabel']),
      artworkPath: _nullableString(json['artworkPath']),
      sourceId: _nullableString(json['sourceId']),
      relativePath: _nullableString(json['relativePath']),
      availability: json['availability']?.toString() ?? 'available',
    );
  }

  final String id;
  final MediaKind kind;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String path;
  final String folder;
  final DateTime addedAt;
  final Color accentColor;
  final int playCount;
  final bool isFavorite;
  final List<LyricLine> lyrics;
  final bool hasCustomLyrics;
  final LyricTiming lyricTiming;
  final List<Map<String, String>> lyricMatchAliases;
  final LyricDraft? lyricDraft;
  final List<SubtitleCue> subtitles;
  final Map<String, Object?> subtitleState;
  final Duration lastPosition;
  final String? resolution;
  final int fileSizeBytes;
  final String? fileSizeLabel;
  final String? formatLabel;
  final String? artworkPath;
  final String? sourceId;
  final String? relativePath;
  final String availability;

  String get subtitle {
    if (kind == MediaKind.video) {
      final detail = <String>[
        if (resolution != null) resolution!,
        formatDuration(duration),
        if (lastPosition > Duration.zero) '续播 ${formatDuration(lastPosition)}',
      ];
      return detail.join(' • ');
    }
    return '$artist • $album';
  }

  String get searchText {
    return '$title $artist $album $folder'.toLowerCase();
  }

  MediaItem copyWith({
    String? id,
    MediaKind? kind,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? path,
    String? folder,
    DateTime? addedAt,
    Color? accentColor,
    int? playCount,
    bool? isFavorite,
    List<LyricLine>? lyrics,
    bool? hasCustomLyrics,
    LyricTiming? lyricTiming,
    List<Map<String, String>>? lyricMatchAliases,
    LyricDraft? lyricDraft,
    bool clearLyricDraft = false,
    List<SubtitleCue>? subtitles,
    Map<String, Object?>? subtitleState,
    Duration? lastPosition,
    String? resolution,
    int? fileSizeBytes,
    String? fileSizeLabel,
    String? formatLabel,
    String? artworkPath,
    String? sourceId,
    String? relativePath,
    String? availability,
  }) {
    return MediaItem(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      path: path ?? this.path,
      folder: folder ?? this.folder,
      addedAt: addedAt ?? this.addedAt,
      accentColor: accentColor ?? this.accentColor,
      playCount: playCount ?? this.playCount,
      isFavorite: isFavorite ?? this.isFavorite,
      lyrics: lyrics ?? this.lyrics,
      hasCustomLyrics: hasCustomLyrics ?? this.hasCustomLyrics,
      lyricMatchAliases: lyricMatchAliases ?? this.lyricMatchAliases,
      lyricDraft: clearLyricDraft ? null : lyricDraft ?? this.lyricDraft,
      lyricTiming: lyricTiming ??
          (lyrics != null &&
                  !identical(lyrics, this.lyrics) &&
                  LyricTiming.signatureFor(lyrics) !=
                      this.lyricTiming.lyricsSignature
              ? const LyricTiming()
              : this.lyricTiming),
      subtitles: subtitles ?? this.subtitles,
      subtitleState: subtitleState ?? this.subtitleState,
      lastPosition: lastPosition ?? this.lastPosition,
      resolution: resolution ?? this.resolution,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      fileSizeLabel: fileSizeLabel ?? this.fileSizeLabel,
      formatLabel: formatLabel ?? this.formatLabel,
      artworkPath: artworkPath ?? this.artworkPath,
      sourceId: sourceId ?? this.sourceId,
      relativePath: relativePath ?? this.relativePath,
      availability: availability ?? this.availability,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'kind': kind.name,
      'title': title,
      'artist': artist,
      'album': album,
      'durationMs': duration.inMilliseconds,
      'path': path,
      'folder': folder,
      'addedAtMs': addedAt.millisecondsSinceEpoch,
      'accentColor': accentColor.toARGB32(),
      'playCount': playCount,
      'isFavorite': isFavorite,
      'lyrics': lyrics.map((line) => line.toJson()).toList(growable: false),
      'hasCustomLyrics': hasCustomLyrics,
      'lyricTiming': lyricTiming.toJson(),
      if (lyricMatchAliases.isNotEmpty) 'lyricMatchAliases': lyricMatchAliases,
      if (lyricDraft != null) 'lyricDraft': lyricDraft!.toJson(),
      'subtitles': subtitles.map((cue) => cue.toJson()).toList(growable: false),
      if (subtitleState.isNotEmpty) 'subtitleState': subtitleState,
      'lastPositionMs': lastPosition.inMilliseconds,
      'resolution': resolution,
      'fileSizeBytes': fileSizeBytes,
      'fileSizeLabel': fileSizeLabel,
      'formatLabel': formatLabel,
      'artworkPath': artworkPath,
      'sourceId': sourceId,
      'relativePath': relativePath,
      'availability': availability,
    };
  }
}

String formatDuration(Duration duration) {
  final totalMinutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (totalMinutes >= 60) {
    final hours = duration.inHours;
    final minutes = totalMinutes.remainder(60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }
  return '$totalMinutes:$seconds';
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<Object?> _asList(Object? value) {
  return value is List<Object?> ? value : const <Object?>[];
}

String? _nullableString(Object? value) {
  final text = value?.toString();
  return text == null || text.isEmpty ? null : text;
}
