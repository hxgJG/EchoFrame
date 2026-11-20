import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;

import '../core/models/lumio_settings.dart';
import '../core/models/media_item.dart';
import '../core/models/playlist.dart';
import '../core/subtitles/subtitle_project.dart';
import '../core/lyrics/lrc_parser.dart';
import '../core/lyrics/lyric_calibration.dart';
import '../core/lyrics/lyric_draft.dart';
import '../core/lyrics/lyrics_export.dart';
import '../core/lyrics/lyric_library.dart';
import '../platform/media_library/lyric_package_repository.dart';
import '../core/playback/playback_interruption_controller.dart';
import '../core/playback/weighted_shuffle.dart';
import '../platform/app_storage/app_storage_repository.dart';
import '../platform/app_storage/platform_app_storage_repository.dart';
import '../platform/app_storage/portable_backup_repository.dart';
import '../core/backup/portable_backup_format.dart';
import '../platform/desktop_lyrics/desktop_lyrics_controller.dart';
import '../platform/media_library/lyrics_import.dart';
import '../platform/media_library/lyrics_export_result.dart';
import '../platform/media_library/media_file_operation.dart';
import '../platform/media_library/media_library_repository.dart';
import '../platform/media_library/platform_media_library_repository.dart';
import '../platform/media_library/media_visibility.dart';
import '../platform/online_enhancement/online_enhancement_repository.dart';
import '../platform/platform_capabilities.dart';
import '../platform/subtitle_workbench/subtitle_workbench_repository.dart';
import '../platform/playback/playback_repository.dart';
import '../platform/playback/platform_playback_repository.dart';
import '../platform/playback/audio_spectrum_controller.dart';
import 'seed_data.dart';
import '../core/device_transfer/transfer_protocol.dart';
import '../platform/device_transfer/device_transfer_controller.dart';
import '../platform/device_transfer/received_transfer_store.dart';
import '../platform/device_transfer/platform_transfer_storage.dart';
import '../platform/device_transfer/shared_resource_reader.dart';
import '../platform/device_transfer/transfer_identity.dart';

part 'lyric_library_state.dart';
part 'device_transfer_state.dart';
part 'portable_backup_state.dart';
part 'app_state_playback.dart';
part 'app_state_lyrics.dart';
part 'app_state_library.dart';
part 'app_state_settings.dart';
part 'app_state_playlists.dart';
part 'app_state_persistence.dart';
part 'app_state_queries.dart';

enum AppSection { home, music, playlists, video, settings }

enum MusicSort { title, addedAt, duration, playCount, fileSize }

enum PlaybackMode { sequential, repeatAll, repeatOne, shuffle }

class LumioAppState extends ChangeNotifier {
  LumioAppState({
    MediaLibraryRepository mediaLibraryRepository =
        const PlatformMediaLibraryRepository(),
    AppStorageRepository appStorageRepository =
        const PlatformAppStorageRepository(),
    PlaybackRepository? playbackRepository,
    OnlineEnhancementRepository? onlineEnhancementRepository,
    PlatformCapabilities? platformCapabilities,
  })  : _mediaLibraryRepository = mediaLibraryRepository,
        _appStorageRepository = appStorageRepository,
        _playbackRepository =
            playbackRepository ?? PlatformPlaybackRepository(),
        _onlineEnhancementRepository =
            onlineEnhancementRepository ?? FileOnlineEnhancementRepository(),
        _platformCapabilities =
            platformCapabilities ?? PlatformCapabilities.current(),
        _audioItems = List<MediaItem>.from(seedAudioItems),
        _videoItems = List<MediaItem>.from(seedVideoItems),
        _playlists = List<Playlist>.from(seedPlaylists) {
    _currentItem = _audioItems.isNotEmpty ? _audioItems.first : null;
    _playbackEventSubscription =
        _playbackRepository.events.listen(_handlePlaybackEvent);
    addListener(_reconcileLyricUpdates);
    addListener(_syncDesktopLyrics);
    addListener(_syncSpectrum);
    desktopLyrics.addListener(_desktopLyricsChanged);
    desktopLyrics.initialize(
      onPrevious: previous,
      onTogglePlaying: togglePlaying,
      onNext: next,
    );
    startupReady = _restorePersistedState();
    if (Platform.isMacOS || Platform.isAndroid) {
      // Generate only the local identity at startup; never start sharing here.
      unawaited(TransferIdentity.load()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    }
  }

  final MediaLibraryRepository _mediaLibraryRepository;
  late final Future<void> startupReady;
  final DesktopLyricsController desktopLyrics = DesktopLyricsController();
  final AudioSpectrumController audioSpectrum = AudioSpectrumController();
  final AppStorageRepository _appStorageRepository;
  final PlaybackRepository _playbackRepository;
  final OnlineEnhancementRepository _onlineEnhancementRepository;
  final PlatformCapabilities _platformCapabilities;
  VoidCallback? onExternalMediaOpened;
  final Random _random = Random();
  final PlaybackInterruptionController _interruptionController =
      PlaybackInterruptionController();
  late final StreamSubscription<PlaybackEvent> _playbackEventSubscription;
  Timer? _positionTimer;
  Timer? _lyricTimer;
  bool _positionQueryInFlight = false;
  bool _disposed = false;
  int _playbackEpoch = 0;
  int _lyricViewCount = 0;
  int _authoringViews = 0;
  LyricCalibration? _lyricCalibration;
  final ValueNotifier<int> lyricChanges = ValueNotifier(0);
  final ValueNotifier<int> subtitleChanges = ValueNotifier(0);
  List<SubtitleCue>? _subtitleIndexSource;
  SubtitleTimeline? _subtitleTimeline;
  Timer? _sleepTimer;
  Timer? _sleepFadeTimer;
  List<MediaItem> _audioItems;
  List<MediaItem> _videoItems;
  List<Playlist> _playlists;
  List<String> _queueIds = const <String>[];
  Set<String> _hiddenMediaIds = <String>{};
  LumioSettings _settings = const LumioSettings();
  AppSection _section = AppSection.home;
  MusicSort _musicSort = MusicSort.addedAt;
  MediaItem? _currentItem;
  String? _lastAudioItemId;
  Duration _lastAudioPosition = Duration.zero;
  bool _playbackNeedsReload = false;
  bool _isPlaying = false;
  bool _shuffleEnabled = false;
  RepeatMode _repeatMode = RepeatMode.off;
  PlaybackView _playbackView = PlaybackView.artwork;
  Duration _position = const Duration(minutes: 1, seconds: 12);
  bool _isScanningLibrary = false;
  bool _isExportingLyrics = false;
  bool _portableBackupBusy = false;
  bool _portableRestorePending = false;
  List<Object?> _portableSubtitleProjects = [];
  List<LyricLibraryEntry> _lyricLibrary = [];
  Map<String, Object?>? _lyricLibraryUndo;
  bool _lyricLibraryBusy = false;
  bool _lyricLibraryReady = false;
  String? _lyricLibraryError;
  Object? _unreadableLyricLibrary;
  Map<String, String> _lyricFingerprints = {};
  final Map<String, MediaItem> _receivedMedia = {};
  final Map<String, String> _receivedDigests = {};
  final Map<String, String> _appliedTransfers = {};
  DeviceTransferController? _deviceTransfer;
  DeviceTransferController get deviceTransfer =>
      _deviceTransfer ??= DeviceTransferController(this);

  /// 供 part 扩展使用：ChangeNotifier.notifyListeners 是 protected，
  /// 扩展不是其子类，必须经由类内方法转发。
  void _notify() => notifyListeners();
  void _notifyLyricLibrary() => notifyListeners();
  void _notifyTransferLibrary() => notifyListeners();
  bool _isUpdatingMediaSources = false;
  List<MediaSource> _mediaSources = const <MediaSource>[];
  MediaLibraryScanStatus? _lastScanStatus;
  String _libraryStatusMessage = '尚未扫描本机媒体。';
  String? _mediaScanStatusMessage;
  int? _videoTextureId;
  double? _videoAspectRatio;
  String? _playbackError;
  int _playbackStartRevision = 0;
  String _backupStatusMessage = '播放列表和设置项会自动离线保存。';
  bool _isInPictureInPicture = false;
  double _playbackSpeed = 1.0;
  DateTime? _sleepTimerEndsAt;
  Duration? _abLoopStart;
  Duration? _abLoopEnd;
  DateTime? _lastResumePositionSaveAt;
  final Set<String> _onlineEnhancementRequests = <String>{};
  static const Duration _resumeEndThreshold = Duration(seconds: 5);
  static const Duration _resumeSaveInterval = Duration(seconds: 30);
  static const Duration _sleepFadeDuration = Duration(seconds: 10);
  static const Set<AppStoragePartition> _allStoragePartitions =
      <AppStoragePartition>{
    AppStoragePartition.session,
    AppStoragePartition.library,
    AppStoragePartition.playlists,
  };

  // 排序结果与不可变视图按「源列表身份 + 排序方式」缓存。媒体库只在整块替换时
  // 换新列表实例，MediaItem 本身不可变，因此不必每次访问都复制并重新排序。
  // 新增就地修改 _audioItems/_videoItems 的代码时必须同时置空对应缓存。
  List<MediaItem>? _sortedAudioCache;
  List<MediaItem>? _sortedAudioCacheSource;
  MusicSort? _sortedAudioCacheSort;
  List<MediaItem>? _videoItemsView;
  List<MediaItem>? _videoItemsViewSource;
  List<Playlist>? _playlistsView;
  List<Playlist>? _playlistsViewSource;
  List<MediaItem>? _queueItemsCache;
  List<String>? _queueItemsCacheIds;
  List<MediaItem>? _queueItemsCacheAudio;
  List<MediaItem>? _queueItemsCacheVideo;
  // 检索索引在首次搜索时建立，媒体库整块替换后重建。
  List<_SearchEntry>? _searchIndex;
  List<MediaItem>? _searchIndexAudio;
  List<MediaItem>? _searchIndexVideo;
  // 按 id 的索引，同样在媒体库整块替换后重建。
  Map<String, MediaItem>? _mediaByIdCache;
  List<MediaItem>? _mediaByIdAudio;
  List<MediaItem>? _mediaByIdVideo;

  List<MediaItem> get audioItems {
    final cached = _sortedAudioCache;
    if (cached != null &&
        _sortedAudioCacheSort == _musicSort &&
        identical(_sortedAudioCacheSource, _audioItems)) {
      return cached;
    }
    final items = _sortedAudioItems();
    _sortedAudioCache = items;
    _sortedAudioCacheSource = _audioItems;
    _sortedAudioCacheSort = _musicSort;
    return items;
  }

  List<MediaItem> get videoItems {
    final cached = _videoItemsView;
    if (cached != null && identical(_videoItemsViewSource, _videoItems)) {
      return cached;
    }
    final items = List<MediaItem>.unmodifiable(_videoItems);
    _videoItemsView = items;
    _videoItemsViewSource = _videoItems;
    return items;
  }

  List<Playlist> get playlists {
    final cached = _playlistsView;
    if (cached != null && identical(_playlistsViewSource, _playlists)) {
      return cached;
    }
    final items = List<Playlist>.unmodifiable(_playlists);
    _playlistsView = items;
    _playlistsViewSource = _playlists;
    return items;
  }

  /// 只关心数量时使用，避免为了取长度而复制并排序整个媒体库。
  int get audioCount => _audioItems.length;
  int get videoCount => _videoItems.length;
  int get playlistCount => _playlists.length;

  List<MediaItem> get queueItems {
    final cached = _queueItemsCache;
    if (cached != null &&
        identical(_queueItemsCacheIds, _queueIds) &&
        identical(_queueItemsCacheAudio, _audioItems) &&
        identical(_queueItemsCacheVideo, _videoItems)) {
      return cached;
    }
    final items = _itemsForIds(_queueIds);
    _queueItemsCache = items;
    _queueItemsCacheIds = _queueIds;
    _queueItemsCacheAudio = _audioItems;
    _queueItemsCacheVideo = _videoItems;
    return items;
  }

  LumioSettings get settings => _settings;
  AppSection get section => _section;
  MusicSort get musicSort => _musicSort;
  MediaItem? get currentItem => _currentItem;
  bool get isPlaying => _isPlaying;
  bool get shuffleEnabled => _shuffleEnabled;
  RepeatMode get repeatMode => _repeatMode;
  PlaybackMode get playbackMode => _shuffleEnabled
      ? PlaybackMode.shuffle
      : switch (_repeatMode) {
          RepeatMode.off => PlaybackMode.sequential,
          RepeatMode.all => PlaybackMode.repeatAll,
          RepeatMode.one => PlaybackMode.repeatOne,
        };
  PlaybackView get playbackView => _playbackView;
  Duration get position => _position;
  bool get isScanningLibrary => _isScanningLibrary;
  bool get isExportingLyrics => _isExportingLyrics;
  // 与音频库索引一起统计，避免每次重建都遍历全部媒体的歌词。
  int get exportableLyricsCount => _audioIndex.exportableLyricCount;

  bool get isUpdatingMediaSources => _isUpdatingMediaSources;
  List<MediaSource> get mediaSources =>
      List<MediaSource>.unmodifiable(_mediaSources);
  PlatformCapabilities get platformCapabilities => _platformCapabilities;
  MediaLibraryScanStatus? get lastScanStatus => _lastScanStatus;
  String get libraryStatusMessage => _libraryStatusMessage;
  String get mediaScanStatusMessage =>
      _mediaScanStatusMessage ??
      '当前媒体库：${_audioItems.length} 首音频、${_videoItems.length} 个视频。';
  bool get hasMediaScanStatus => _mediaScanStatusMessage != null;
  int? get videoTextureId => _videoTextureId;
  double? get videoAspectRatio => _videoAspectRatio;
  String? get playbackError => _playbackError;
  int get playbackStartRevision => _playbackStartRevision;
  bool get isInPictureInPicture => _isInPictureInPicture;
  int get hiddenMediaCount => _hiddenMediaIds.length;
  String get backupStatusMessage => _backupStatusMessage;
  double get playbackSpeed => _playbackSpeed;
  String get sleepTimerLabel {
    final endsAt = _sleepTimerEndsAt;
    if (endsAt == null) {
      return '未开启';
    }
    final remaining = endsAt.difference(DateTime.now());
    if (remaining.isNegative) {
      return '即将停止';
    }
    return '${remaining.inMinutes + 1} 分钟后停止';
  }

  String get abLoopLabel {
    final start = _abLoopStart;
    final end = _abLoopEnd;
    if (start == null && end == null) {
      return '未设置';
    }
    return '${start == null ? 'A 未设' : formatDuration(start)} - ${end == null ? 'B 未设' : formatDuration(end)}';
  }

  int get currentLyricIndex {
    final lines = _currentItem?.lyrics ?? const <LyricLine>[];
    if (lines.isEmpty) {
      return -1;
    }
    final effectivePosition = _position +
        _settings.lyricOffset +
        Duration(
            milliseconds: _lyricCalibration?.offsetMs ??
                _currentItem?.lyricTiming.offsetMs ??
                0);
    var currentIndex = -1;
    for (var index = 0; index < lines.length; index += 1) {
      if (lines[index].time <= effectivePosition) {
        currentIndex = index;
      } else {
        break;
      }
    }
    return currentIndex;
  }

  String get currentSubtitleText {
    final item = _currentItem;
    if (item == null ||
        item.kind != MediaKind.video ||
        item.subtitles.isEmpty) {
      return '';
    }
    if (platformCapabilities.supportsSubtitleEditing) {
      if (item.subtitleState['visible'] == false) return '';
      if (!identical(_subtitleIndexSource, item.subtitles)) {
        _subtitleIndexSource = item.subtitles;
        _subtitleTimeline = SubtitleTimeline([
          for (var i = 0; i < item.subtitles.length; i++)
            EditableSubtitle(
                id: '$i',
                startMs: item.subtitles[i].start.inMilliseconds,
                endMs: item.subtitles[i].end.inMilliseconds,
                text: item.subtitles[i].text)
        ]);
      }
      return _subtitleTimeline!.at(_position.inMilliseconds);
    }
    for (final cue in item.subtitles) {
      if (_position >= cue.start && _position <= cue.end) {
        return cue.text;
      }
      if (cue.start > _position) {
        break;
      }
    }
    return '';
  }

  // 音频库派生视图（最近添加、最常播放、专辑/艺术家/文件夹聚合）按源列表身份缓存，
  // 避免在每次界面重建时重复全量扫描与排序。
  _AudioIndex? _audioIndexCache;
  List<MediaItem>? _audioIndexSource;
  List<String>? _videoFoldersCache;
  List<MediaItem>? _videoFoldersSource;

  _AudioIndex get _audioIndex {
    final cached = _audioIndexCache;
    if (cached != null && identical(_audioIndexSource, _audioItems)) {
      return cached;
    }
    final index = _AudioIndex.from(_audioItems);
    _audioIndexCache = index;
    _audioIndexSource = _audioItems;
    return index;
  }

  List<MediaItem> get recentlyAdded => _audioIndex.recentlyAdded;

  List<MediaItem> get mostPlayed => _audioIndex.mostPlayed;

  List<String> get albums => _audioIndex.albums;

  List<String> get artists => _audioIndex.artists;

  List<String> get audioFolders => _audioIndex.folders;

  List<String> get videoFolders {
    final cached = _videoFoldersCache;
    if (cached != null && identical(_videoFoldersSource, _videoItems)) {
      return cached;
    }
    final values = List<String>.unmodifiable(
        _videoItems.map((item) => item.folder).toSet().toList()..sort());
    _videoFoldersCache = values;
    _videoFoldersSource = _videoItems;
    return values;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_mediaLibraryRepository.setExternalOpenHandler(null));
    _deviceTransfer?.dispose();
    _lyricTimer?.cancel();
    lyricChanges.dispose();
    subtitleChanges.dispose();
    removeListener(_reconcileLyricUpdates);
    removeListener(_syncDesktopLyrics);
    removeListener(_syncSpectrum);
    audioSpectrum.dispose();
    desktopLyrics.removeListener(_desktopLyricsChanged);
    desktopLyrics.dispose();
    _positionTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    _playbackRepository.setVolumeScale(1.0);
    _playbackEventSubscription.cancel();
    super.dispose();
  }
}

/// 音频库的派生视图。只在音频列表整块替换时重建，供最近添加、最常播放、
/// 专辑/艺术家/文件夹聚合与分组查询复用，避免界面每次重建都重复全量扫描与排序。
class _AudioIndex {
  _AudioIndex._(
    this.recentlyAdded,
    this.mostPlayed,
    this.exportableLyricCount, {
    required Map<String, List<MediaItem>> byAlbum,
    required Map<String, List<MediaItem>> byArtist,
    required Map<String, List<MediaItem>> byFolder,
  })  : byAlbum = Map<String, List<MediaItem>>.unmodifiable(byAlbum),
        byArtist = Map<String, List<MediaItem>>.unmodifiable(byArtist),
        byFolder = Map<String, List<MediaItem>>.unmodifiable(byFolder),
        albums = List<String>.unmodifiable(byAlbum.keys.toList()..sort()),
        artists = List<String>.unmodifiable(byArtist.keys.toList()..sort()),
        folders = List<String>.unmodifiable(byFolder.keys.toList()..sort());

  factory _AudioIndex.from(List<MediaItem> items) {
    List<MediaItem> top(int Function(MediaItem a, MediaItem b) compare) =>
        List<MediaItem>.unmodifiable(
          (List<MediaItem>.from(items)..sort(compare)).take(4),
        );
    var exportableLyricCount = 0;
    final byAlbum = <String, List<MediaItem>>{};
    final byArtist = <String, List<MediaItem>>{};
    final byFolder = <String, List<MediaItem>>{};
    for (final item in items) {
      (byAlbum[item.album] ??= <MediaItem>[]).add(item);
      (byArtist[item.artist] ??= <MediaItem>[]).add(item);
      (byFolder[item.folder] ??= <MediaItem>[]).add(item);
      if (item.kind == MediaKind.audio &&
          item.lyrics.any((line) => line.text.trim().isNotEmpty)) {
        exportableLyricCount++;
      }
    }
    // 分组结果会被界面长期持有，转成不可变副本，避免调用方就地修改污染缓存。
    for (final group in <Map<String, List<MediaItem>>>[
      byAlbum,
      byArtist,
      byFolder,
    ]) {
      for (final key in group.keys) {
        group[key] = List<MediaItem>.unmodifiable(group[key]!);
      }
    }
    return _AudioIndex._(
      top((a, b) => b.addedAt.compareTo(a.addedAt)),
      top((a, b) => b.playCount.compareTo(a.playCount)),
      exportableLyricCount,
      byAlbum: byAlbum,
      byArtist: byArtist,
      byFolder: byFolder,
    );
  }

  final List<MediaItem> recentlyAdded;
  final List<MediaItem> mostPlayed;
  final int exportableLyricCount;
  final List<String> albums;
  final List<String> artists;
  final List<String> folders;
  final Map<String, List<MediaItem>> byAlbum;
  final Map<String, List<MediaItem>> byArtist;
  final Map<String, List<MediaItem>> byFolder;
}

/// 一条检索记录：预先算好小写检索文本，避免每次输入都重新拼接。
class _SearchEntry {
  _SearchEntry(this.item) : text = item.searchText;

  static List<_SearchEntry> build(
    List<MediaItem> audio,
    List<MediaItem> video,
  ) =>
      List<_SearchEntry>.unmodifiable(<_SearchEntry>[
        for (final item in audio) _SearchEntry(item),
        for (final item in video) _SearchEntry(item),
      ]);

  final MediaItem item;
  final String text;
}
