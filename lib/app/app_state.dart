import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/models/lumio_settings.dart';
import '../core/models/media_item.dart';
import '../core/models/playlist.dart';
import '../core/lyrics/lrc_parser.dart';
import '../core/playback/playback_interruption_controller.dart';
import '../platform/app_storage/app_storage_repository.dart';
import '../platform/app_storage/platform_app_storage_repository.dart';
import '../platform/desktop_lyrics/desktop_lyrics_controller.dart';
import '../platform/media_library/lyrics_import.dart';
import '../platform/media_library/media_file_operation.dart';
import '../platform/media_library/media_library_repository.dart';
import '../platform/media_library/platform_media_library_repository.dart';
import '../platform/media_library/media_visibility.dart';
import '../platform/online_enhancement/online_enhancement_repository.dart';
import '../platform/platform_capabilities.dart';
import '../platform/playback/playback_repository.dart';
import '../platform/playback/platform_playback_repository.dart';
import 'seed_data.dart';

enum AppSection { home, music, playlists, video, settings }

enum MusicSort { title, addedAt, duration, playCount, fileSize }

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
    addListener(_syncDesktopLyrics);
    desktopLyrics.addListener(_desktopLyricsChanged);
    desktopLyrics.initialize(
      onPrevious: previous,
      onTogglePlaying: togglePlaying,
      onNext: next,
    );
    _restorePersistedState();
  }

  final MediaLibraryRepository _mediaLibraryRepository;
  final DesktopLyricsController desktopLyrics = DesktopLyricsController();
  final AppStorageRepository _appStorageRepository;
  final PlaybackRepository _playbackRepository;
  final OnlineEnhancementRepository _onlineEnhancementRepository;
  final PlatformCapabilities _platformCapabilities;
  final Random _random = Random();
  final PlaybackInterruptionController _interruptionController =
      PlaybackInterruptionController();
  late final StreamSubscription<PlaybackEvent> _playbackEventSubscription;
  Timer? _positionTimer;
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
  bool _isPlaying = false;
  bool _shuffleEnabled = false;
  RepeatMode _repeatMode = RepeatMode.off;
  PlaybackView _playbackView = PlaybackView.artwork;
  Duration _position = const Duration(minutes: 1, seconds: 12);
  bool _isScanningLibrary = false;
  bool _isUpdatingMediaSources = false;
  List<MediaSource> _mediaSources = const <MediaSource>[];
  MediaLibraryScanStatus? _lastScanStatus;
  String _libraryStatusMessage = '尚未扫描本机媒体。';
  int? _videoTextureId;
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

  List<MediaItem> get audioItems => _sortedAudioItems();
  List<MediaItem> get videoItems => List<MediaItem>.unmodifiable(_videoItems);
  List<Playlist> get playlists => List<Playlist>.unmodifiable(_playlists);
  List<MediaItem> get queueItems => _itemsForIds(_queueIds);
  LumioSettings get settings => _settings;
  AppSection get section => _section;
  MusicSort get musicSort => _musicSort;
  MediaItem? get currentItem => _currentItem;
  bool get isPlaying => _isPlaying;
  bool get shuffleEnabled => _shuffleEnabled;
  RepeatMode get repeatMode => _repeatMode;
  PlaybackView get playbackView => _playbackView;
  Duration get position => _position;
  bool get isScanningLibrary => _isScanningLibrary;
  bool get isUpdatingMediaSources => _isUpdatingMediaSources;
  List<MediaSource> get mediaSources =>
      List<MediaSource>.unmodifiable(_mediaSources);
  PlatformCapabilities get platformCapabilities => _platformCapabilities;
  MediaLibraryScanStatus? get lastScanStatus => _lastScanStatus;
  String get libraryStatusMessage => _libraryStatusMessage;
  int? get videoTextureId => _videoTextureId;
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
    final effectivePosition = _position + _settings.lyricOffset;
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

  void _desktopLyricsChanged() => notifyListeners();

  void _syncDesktopLyrics() {
    if (!desktopLyrics.supported || !desktopLyrics.enabled) return;
    final item = _currentItem;
    final lines = item?.lyrics ?? const <LyricLine>[];
    final index = currentLyricIndex;
    desktopLyrics.publish(<String, Object>{
      'audio': item == null || item.kind == MediaKind.audio,
      'title': item?.title ?? '忆光 · 桌面歌词',
      'playing': _isPlaying,
      'canControl': item?.kind == MediaKind.audio,
      'current': item == null
          ? '播放音乐后在这里显示歌词'
          : lines.isEmpty
              ? '暂无歌词，可在播放页导入 LRC'
              : index < 0
                  ? '等待歌词开始…'
                  : lines[index].text,
      'next': lines.isNotEmpty && index + 1 < lines.length
          ? lines[index + 1].text
          : '',
    });
  }

  String get currentSubtitleText {
    final item = _currentItem;
    if (item == null ||
        item.kind != MediaKind.video ||
        item.subtitles.isEmpty) {
      return '';
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

  List<MediaItem> get recentlyAdded {
    final items = List<MediaItem>.from(_audioItems)
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return List<MediaItem>.unmodifiable(items.take(4));
  }

  List<MediaItem> get mostPlayed {
    final items = List<MediaItem>.from(_audioItems)
      ..sort((a, b) => b.playCount.compareTo(a.playCount));
    return List<MediaItem>.unmodifiable(items.take(4));
  }

  List<String> get albums {
    final values = _audioItems.map((item) => item.album).toSet().toList()
      ..sort();
    return List<String>.unmodifiable(values);
  }

  List<String> get artists {
    final values = _audioItems.map((item) => item.artist).toSet().toList()
      ..sort();
    return List<String>.unmodifiable(values);
  }

  List<String> get audioFolders {
    final values = _audioItems.map((item) => item.folder).toSet().toList()
      ..sort();
    return List<String>.unmodifiable(values);
  }

  List<String> get videoFolders {
    final values = _videoItems.map((item) => item.folder).toSet().toList()
      ..sort();
    return List<String>.unmodifiable(values);
  }

  List<MediaItem> itemsForAlbum(String album) {
    return _audioItems.where((item) => item.album == album).toList();
  }

  List<MediaItem> itemsForArtist(String artist) {
    return _audioItems.where((item) => item.artist == artist).toList();
  }

  List<MediaItem> itemsForAudioFolder(String folder) {
    return _audioItems.where((item) => item.folder == folder).toList();
  }

  List<MediaItem> itemsForPlaylist(Playlist playlist) {
    final all = <String, MediaItem>{
      for (final item in <MediaItem>[..._audioItems, ..._videoItems])
        item.id: item,
    };
    return playlist.mediaIds
        .map((id) => all[id])
        .whereType<MediaItem>()
        .toList(growable: false);
  }

  List<MediaItem> search(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const <MediaItem>[];
    }
    return <MediaItem>[..._audioItems, ..._videoItems]
        .where((item) => item.searchText.contains(normalized))
        .toList(growable: false);
  }

  void selectSection(AppSection section) {
    if (_section == section) {
      return;
    }
    _section = section;
    notifyListeners();
  }

  void setMusicSort(MusicSort sort) {
    if (_musicSort == sort) {
      return;
    }
    _musicSort = sort;
    _saveState();
    notifyListeners();
  }

  void play(MediaItem item) {
    _interruptionController.cancelPendingResume();
    final startPosition = _initialPlaybackPosition(item);
    _currentItem = item.copyWith(playCount: item.playCount + 1);
    _position = startPosition;
    _isPlaying = true;
    _replaceItem(_currentItem!);
    _startPositionTimer();
    _playbackRepository.setSpeed(_playbackSpeed);
    _playbackRepository.setCrossfadeDuration(
      Duration(seconds: _settings.crossfadeSeconds),
    );
    _applyEqualizerPreset();
    _playbackRepository.setShuffleEnabled(_shuffleEnabled);
    _playbackRepository.setRepeatMode(_repeatMode);
    _playbackRepository
        .play(
      _currentItem!,
      _position,
      queue: _nativePlaybackQueue(_currentItem!),
    )
        .catchError(
      (Object error) {
        _isPlaying = false;
        _stopPositionTimer();
        _libraryStatusMessage = '播放失败：$error';
        _saveState();
        notifyListeners();
      },
    ).whenComplete(
      () {
        _videoTextureId = _playbackRepository.videoTextureId;
        notifyListeners();
      },
    );
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    unawaited(_loadOnlineEnhancement(_currentItem!));
    notifyListeners();
  }

  void togglePlaying() {
    _interruptionController.cancelPendingResume();
    if (_currentItem == null) {
      _currentItem = _audioItems.isNotEmpty
          ? _audioItems.first
          : _videoItems.isNotEmpty
              ? _videoItems.first
              : null;
    }
    if (_currentItem == null) {
      return;
    }
    _isPlaying = !_isPlaying;
    if (_isPlaying) {
      _playbackRepository.setVolumeScale(1.0);
      _startPositionTimer();
      _playbackRepository.resume().catchError(
        (Object error) {
          final item = _currentItem;
          if (item != null) {
            _playbackRepository
                .play(
              item,
              _position,
              queue: _nativePlaybackQueue(item),
            )
                .catchError(
              (Object retryError) {
                _isPlaying = false;
                _stopPositionTimer();
                _libraryStatusMessage = '播放失败：$retryError';
                _saveState();
                notifyListeners();
              },
            );
          } else {
            _isPlaying = false;
            _stopPositionTimer();
            _libraryStatusMessage = '播放失败：$error';
          }
        },
      );
    } else {
      _updateCurrentVideoResumePosition(forceSave: true);
      _stopPositionTimer();
      _playbackRepository.pause();
    }
    _saveState();
    notifyListeners();
  }

  void next() {
    final queued = _popNextQueuedItem();
    if (queued != null) {
      play(queued);
      return;
    }
    final current = _currentItem;
    final pool =
        current?.kind == MediaKind.video ? _videoItems : _sortedAudioItems();
    if (pool.isEmpty) {
      return;
    }
    final index =
        current == null ? -1 : pool.indexWhere((item) => item.id == current.id);
    final nextIndex = _shuffleEnabled
        ? _randomOtherIndex(pool)
        : (index + 1).clamp(0, pool.length - 1);
    play(pool[nextIndex]);
  }

  void previous() {
    final current = _currentItem;
    final pool =
        current?.kind == MediaKind.video ? _videoItems : _sortedAudioItems();
    if (pool.isEmpty) {
      return;
    }
    final index =
        current == null ? 0 : pool.indexWhere((item) => item.id == current.id);
    final previousIndex = index <= 0 ? 0 : index - 1;
    play(pool[previousIndex]);
  }

  void shuffleAll(MediaKind kind) {
    final pool = kind == MediaKind.audio ? _audioItems : _videoItems;
    if (pool.isEmpty) {
      return;
    }
    _shuffleEnabled = true;
    if (_repeatMode == RepeatMode.one) _repeatMode = RepeatMode.off;
    play(pool[_randomOtherIndex(pool)]);
  }

  int _randomOtherIndex(List<MediaItem> pool) {
    final currentIndex = pool.indexWhere((item) => item.id == _currentItem?.id);
    if (pool.length == 1 || currentIndex < 0) {
      return _random.nextInt(pool.length);
    }
    final index = _random.nextInt(pool.length - 1);
    return index >= currentIndex ? index + 1 : index;
  }

  void toggleShuffle() {
    _shuffleEnabled = !_shuffleEnabled;
    if (_shuffleEnabled && _repeatMode == RepeatMode.one) {
      _repeatMode = RepeatMode.off;
      _playbackRepository.setRepeatMode(_repeatMode);
    }
    _playbackRepository.setShuffleEnabled(_shuffleEnabled);
    _saveState();
    notifyListeners();
  }

  void cycleRepeatMode() {
    _repeatMode = switch (_repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    _playbackRepository.setRepeatMode(_repeatMode);
    _saveState();
    notifyListeners();
  }

  void togglePlaybackView() {
    if (_currentItem?.kind == MediaKind.video) {
      _playbackView = PlaybackView.video;
    } else {
      _playbackView = _playbackView == PlaybackView.artwork
          ? PlaybackView.lyrics
          : PlaybackView.artwork;
    }
    _saveState();
    notifyListeners();
  }

  void setPlaybackView(PlaybackView view) {
    _playbackView = view;
    _saveState();
    notifyListeners();
  }

  void seekToFraction(double fraction) {
    final item = _currentItem;
    if (item == null) {
      return;
    }
    _position = item.duration * fraction.clamp(0, 1);
    _playbackRepository.seek(_position);
    _updateCurrentVideoResumePosition(forceSave: true);
    _saveState();
    notifyListeners();
  }

  void enterPictureInPicture() {
    _playbackRepository.enterPictureInPicture().catchError((Object error) {
      _libraryStatusMessage = '进入小窗失败：$error';
      _saveState();
      notifyListeners();
    });
  }

  void adjustBrightness(double delta) {
    _playbackRepository.adjustBrightness(delta).catchError((Object error) {
      _libraryStatusMessage = '亮度调节失败：$error';
      _saveState();
      notifyListeners();
    });
  }

  void adjustVolume(double delta) {
    _playbackRepository.adjustVolume(delta).catchError((Object error) {
      _libraryStatusMessage = '音量调节失败：$error';
      _saveState();
      notifyListeners();
    });
  }

  void share(MediaItem item) {
    _playbackRepository.share(item).catchError((Object error) {
      _libraryStatusMessage = '分享失败：$error';
      _saveState();
      notifyListeners();
    });
  }

  void shareMany(Iterable<String> mediaIds) {
    final items = mediaIds.map(_findItem).whereType<MediaItem>().toList();
    if (items.isEmpty) {
      return;
    }
    _playbackRepository.shareMany(items).catchError((Object error) {
      _libraryStatusMessage = '批量分享失败：$error';
      _saveState();
      notifyListeners();
    });
  }

  Future<MediaFileOperationResult> deleteMediaFiles(
    Iterable<String> mediaIds,
  ) async {
    final ids = mediaIds.where((id) => _findItem(id) != null).toSet();
    if (ids.isEmpty) {
      return const MediaFileOperationResult(
        status: MediaFileOperationStatus.failed,
        message: '没有可从列表移除的媒体。',
      );
    }
    if (ids.contains(_currentItem?.id)) {
      _stopPlayback();
    }
    _hiddenMediaIds = <String>{..._hiddenMediaIds, ...ids};
    _audioItems = visibleMediaItems(_audioItems, ids);
    _videoItems = visibleMediaItems(_videoItems, ids);
    _queueIds = _queueIds.where((id) => !ids.contains(id)).toList();
    if (ids.contains(_currentItem?.id)) {
      _currentItem = _audioItems.isNotEmpty
          ? _audioItems.first
          : _videoItems.isNotEmpty
              ? _videoItems.first
              : null;
    }
    _libraryStatusMessage = '已从忆光媒体库移除 ${ids.length} 个媒体，设备源文件未删除。';
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    notifyListeners();
    return MediaFileOperationResult(
      status: MediaFileOperationStatus.completed,
      message: _libraryStatusMessage,
      affectedMediaIds: ids.toList(growable: false),
    );
  }

  Future<void> restoreHiddenMedia() async {
    if (_hiddenMediaIds.isEmpty) {
      return;
    }
    _hiddenMediaIds = <String>{};
    _saveState();
    await scanMediaLibrary();
  }

  Future<MediaFileOperationResult> renameMediaFile(
    String mediaId,
    String displayName,
  ) {
    return _performFileOperation(
      MediaFileOperationRequest.rename(
        mediaId: mediaId,
        displayName: displayName,
      ),
    );
  }

  Future<MediaFileOperationResult> moveMediaFiles(
    Iterable<String> mediaIds,
    String relativePath,
  ) {
    return _performFileOperation(
      MediaFileOperationRequest.move(
        mediaIds: mediaIds.toList(growable: false),
        relativePath: relativePath,
      ),
    );
  }

  Future<MediaFileOperationResult> writeMediaTags(
    String mediaId, {
    required String title,
    required String artist,
    required String album,
  }) {
    if (_currentItem?.id == mediaId) {
      _stopPlayback();
    }
    return _performFileOperation(
      MediaFileOperationRequest.writeTags(
        mediaId: mediaId,
        title: title,
        artist: artist,
        album: album,
      ),
    );
  }

  void setPlaybackSpeed(double speed) {
    _playbackSpeed = ((speed * 10).roundToDouble() / 10).clamp(0.5, 2.0);
    _playbackRepository.setSpeed(_playbackSpeed);
    _saveState();
    notifyListeners();
  }

  void setEqualizerPreset(EqualizerPreset preset) {
    if (_settings.equalizerPreset == preset) {
      return;
    }
    _settings = _settings.copyWith(equalizerPreset: preset);
    _applyEqualizerPreset();
    _saveState();
    notifyListeners();
  }

  void setCustomEqualizerGain(int index, double gain) {
    if (index < 0 || index >= _settings.customEqualizerGains.length) {
      return;
    }
    final gains = List<double>.from(_settings.customEqualizerGains);
    gains[index] = gain.clamp(-10, 10).toDouble();
    _settings = _settings.copyWith(
      equalizerPreset: EqualizerPreset.custom,
      customEqualizerGains: gains,
    );
    _applyEqualizerPreset();
    _saveState();
    notifyListeners();
  }

  void setSubtitleFontSize(double size) {
    _settings = _settings.copyWith(subtitleFontSize: size.clamp(12, 28));
    _saveState();
    notifyListeners();
  }

  void setSubtitleTextColor(SubtitleTextColor color) {
    if (_settings.subtitleTextColor == color) {
      return;
    }
    _settings = _settings.copyWith(subtitleTextColor: color);
    _saveState();
    notifyListeners();
  }

  void setSubtitlePosition(SubtitlePosition position) {
    if (_settings.subtitlePosition == position) {
      return;
    }
    _settings = _settings.copyWith(subtitlePosition: position);
    _saveState();
    notifyListeners();
  }

  void setVideoScaleMode(VideoScaleMode mode) {
    if (_settings.videoScaleMode == mode) {
      return;
    }
    _settings = _settings.copyWith(videoScaleMode: mode);
    _saveState();
    notifyListeners();
  }

  void addIncludedFolder(String folder) {
    final normalized = folder.trim();
    if (normalized.isEmpty || _settings.includedFolders.contains(normalized)) {
      return;
    }
    _settings = _settings.copyWith(
      includedFolders: <String>[..._settings.includedFolders, normalized],
    );
    _libraryStatusMessage = '已更新扫描包含文件夹，下次扫描会按新规则生效。';
    _saveState();
    notifyListeners();
  }

  void removeIncludedFolder(String folder) {
    _settings = _settings.copyWith(
      includedFolders: _settings.includedFolders
          .where((value) => value != folder)
          .toList(growable: false),
    );
    _libraryStatusMessage = '已更新扫描包含文件夹，下次扫描会按新规则生效。';
    _saveState();
    notifyListeners();
  }

  void setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    _playbackRepository.setVolumeScale(1.0);
    _sleepTimerEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      _sleepFadeTimer?.cancel();
      _isPlaying = false;
      _stopPositionTimer();
      _updateCurrentVideoResumePosition(forceSave: true);
      _playbackRepository.pause();
      _playbackRepository.setVolumeScale(1.0);
      _sleepTimerEndsAt = null;
      _saveState();
      notifyListeners();
    });
    if (duration > _sleepFadeDuration) {
      _sleepFadeTimer = Timer(duration - _sleepFadeDuration, _startSleepFade);
    } else {
      _startSleepFade();
    }
    _saveState();
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    _sleepTimer = null;
    _sleepFadeTimer = null;
    _sleepTimerEndsAt = null;
    _playbackRepository.setVolumeScale(1.0);
    _saveState();
    notifyListeners();
  }

  void _startSleepFade() {
    _sleepFadeTimer?.cancel();
    _sleepFadeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final endsAt = _sleepTimerEndsAt;
      if (endsAt == null) {
        _sleepFadeTimer?.cancel();
        _sleepFadeTimer = null;
        _playbackRepository.setVolumeScale(1.0);
        return;
      }
      final remaining = endsAt.difference(DateTime.now());
      final scale =
          (remaining.inMilliseconds / _sleepFadeDuration.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
      _playbackRepository.setVolumeScale(scale);
      if (remaining <= Duration.zero) {
        _sleepFadeTimer?.cancel();
        _sleepFadeTimer = null;
      }
    });
  }

  void setAbLoopStart() {
    _abLoopStart = _position;
    final end = _abLoopEnd;
    if (end != null && end <= _abLoopStart!) {
      _abLoopEnd = null;
    }
    _saveState();
    notifyListeners();
  }

  void setAbLoopEnd() {
    final start = _abLoopStart;
    if (start == null || _position <= start) {
      return;
    }
    _abLoopEnd = _position;
    _saveState();
    notifyListeners();
  }

  void clearAbLoop() {
    _abLoopStart = null;
    _abLoopEnd = null;
    _saveState();
    notifyListeners();
  }

  void toggleFavorite(String mediaId) {
    final current = _findItem(mediaId);
    if (current == null) {
      return;
    }
    _replaceItem(current.copyWith(isFavorite: !current.isFavorite));
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.library,
      },
    );
    notifyListeners();
  }

  void updateMediaMetadata(
    String mediaId, {
    String? title,
    String? artist,
    String? album,
  }) {
    final current = _findItem(mediaId);
    if (current == null) {
      return;
    }
    final nextTitle = title?.trim();
    if (nextTitle == null || nextTitle.isEmpty) {
      return;
    }
    final nextArtist = artist?.trim();
    final nextAlbum = album?.trim();
    _replaceItem(
      current.copyWith(
        title: nextTitle,
        artist: nextArtist == null || nextArtist.isEmpty
            ? current.artist
            : nextArtist,
        album:
            nextAlbum == null || nextAlbum.isEmpty ? current.album : nextAlbum,
      ),
    );
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.library,
      },
    );
    notifyListeners();
  }

  Future<LyricsImportResult> importLyrics(String mediaId) async {
    final current = _findItem(mediaId);
    if (current == null || current.kind != MediaKind.audio) {
      return const LyricsImportResult(
        status: LyricsImportStatus.failed,
        message: '只能为媒体库中的音乐导入歌词。',
      );
    }
    final result = await _mediaLibraryRepository.importLyrics();
    if (!result.didImport) {
      return result;
    }
    final lyrics = parseLrc(result.lyricsText);
    if (lyrics.isEmpty) {
      return result.copyWith(
        status: LyricsImportStatus.failed,
        message: '没有解析到带时间标签的歌词，请选择有效的 LRC 文件。',
      );
    }
    _replaceItem(
      current.copyWith(
        lyrics: lyrics,
        hasCustomLyrics: true,
      ),
    );
    _playbackView = PlaybackView.lyrics;
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    notifyListeners();
    return result.copyWith(
      message: '已为《${current.title}》导入 ${lyrics.length} 行歌词。',
    );
  }

  void removeLyrics(String mediaId) {
    final current = _findItem(mediaId);
    if (current == null || current.kind != MediaKind.audio) {
      return;
    }
    _replaceItem(
      current.copyWith(
        lyrics: const <LyricLine>[],
        hasCustomLyrics: false,
      ),
    );
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.library,
      },
    );
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    _settings = _settings.copyWith(themeMode: mode);
    _saveState();
    notifyListeners();
  }

  void setThemeId(String id) {
    if (_settings.themeId == id) return;
    _settings = _settings.copyWith(themeId: id);
    _saveState();
    notifyListeners();
  }

  void toggleOnlineEnhancement(bool value) {
    _settings = _settings.copyWith(allowOnlineEnhancement: value);
    _saveState();
    notifyListeners();
    final item = _currentItem;
    if (value && item != null) {
      unawaited(_loadOnlineEnhancement(item));
    }
  }

  void toggleDynamicColor(bool value) {
    _settings = _settings.copyWith(dynamicColor: value);
    _saveState();
    notifyListeners();
  }

  void toggleCrossfade(bool enabled) {
    _settings = _settings.withCrossfadeEnabled(enabled);
    _playbackRepository.setCrossfadeDuration(
      Duration(seconds: _settings.crossfadeSeconds),
    );
    _saveState();
    notifyListeners();
  }

  void setThemeAccent(ThemeAccent accent) {
    if (_settings.themeAccent == accent) {
      return;
    }
    _settings = _settings.copyWith(themeAccent: accent);
    _saveState();
    notifyListeners();
  }

  void setMusicViewMode(MusicViewMode mode) {
    if (_settings.musicViewMode == mode) {
      return;
    }
    _settings = _settings.copyWith(musicViewMode: mode);
    _saveState();
    notifyListeners();
  }

  void setDefaultPlaybackView(PlaybackView view) {
    _settings = _settings.copyWith(defaultPlaybackView: view);
    _playbackView = view;
    _saveState();
    notifyListeners();
  }

  void adjustLyricOffset(Duration delta) {
    final next = _settings.lyricOffset + delta;
    _settings = _settings.copyWith(
      lyricOffset: Duration(
        milliseconds: next.inMilliseconds.clamp(-10000, 10000),
      ),
    );
    _saveState();
    notifyListeners();
  }

  void setMinimumAudioDuration(Duration duration) {
    _settings = _settings.copyWith(
      minimumAudioDuration: Duration(
        seconds: duration.inSeconds.clamp(0, 600),
      ),
    );
    _libraryStatusMessage = '扫描过滤已更新，下次扫描会按新规则生效。';
    _saveState();
    notifyListeners();
  }

  void addExcludedFolder(String folder) {
    final normalized = folder.trim();
    if (normalized.isEmpty ||
        _settings.excludedFolders
            .any((value) => value.toLowerCase() == normalized.toLowerCase())) {
      return;
    }
    _settings = _settings.copyWith(
      excludedFolders: <String>[..._settings.excludedFolders, normalized],
    );
    _libraryStatusMessage = '已添加排除文件夹，下次扫描会跳过匹配路径。';
    _saveState();
    notifyListeners();
  }

  void removeExcludedFolder(String folder) {
    _settings = _settings.copyWith(
      excludedFolders: _settings.excludedFolders
          .where((value) => value != folder)
          .toList(growable: false),
    );
    _libraryStatusMessage = '已更新排除文件夹，下次扫描会按新规则生效。';
    _saveState();
    notifyListeners();
  }

  void createPlaylist(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final playlist = Playlist(
      id: 'playlist-${now.microsecondsSinceEpoch}',
      name: trimmed,
      description: '自定义播放列表',
      mediaIds: const <String>[],
      updatedAt: now,
    );
    _playlists = <Playlist>[playlist, ..._playlists];
    _savePlaylists();
    notifyListeners();
  }

  void renamePlaylist(String playlistId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _playlists = _playlists
        .map(
          (playlist) => playlist.id == playlistId
              ? playlist.copyWith(name: trimmed, updatedAt: DateTime.now())
              : playlist,
        )
        .toList(growable: false);
    _savePlaylists();
    notifyListeners();
  }

  void deletePlaylist(String playlistId) {
    _playlists = _playlists
        .where((playlist) => playlist.id != playlistId)
        .toList(growable: false);
    _savePlaylists();
    notifyListeners();
  }

  void addToPlaylist(String playlistId, String mediaId) {
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId || playlist.mediaIds.contains(mediaId)) {
        return playlist;
      }
      return playlist.copyWith(
        mediaIds: <String>[...playlist.mediaIds, mediaId],
        updatedAt: DateTime.now(),
      );
    }).toList(growable: false);
    _savePlaylists();
    notifyListeners();
  }

  void addManyToPlaylist(String playlistId, Iterable<String> mediaIds) {
    final validIds = mediaIds.where((id) => _findItem(id) != null).toSet();
    if (validIds.isEmpty) {
      return;
    }
    var changed = false;
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      final nextIds = <String>{...playlist.mediaIds, ...validIds}.toList();
      if (nextIds.length == playlist.mediaIds.length) {
        return playlist;
      }
      changed = true;
      return playlist.copyWith(mediaIds: nextIds, updatedAt: DateTime.now());
    }).toList(growable: false);
    if (!changed) {
      return;
    }
    _savePlaylists();
    notifyListeners();
  }

  void removeFromPlaylist(String playlistId, String mediaId) {
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      return playlist.copyWith(
        mediaIds: playlist.mediaIds
            .where((id) => id != mediaId)
            .toList(growable: false),
        updatedAt: DateTime.now(),
      );
    }).toList(growable: false);
    _savePlaylists();
    notifyListeners();
  }

  void removeManyFromPlaylist(String playlistId, Iterable<String> mediaIds) {
    final idsToRemove = mediaIds.toSet();
    if (idsToRemove.isEmpty) {
      return;
    }
    var changed = false;
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      final nextIds = playlist.mediaIds
          .where((id) => !idsToRemove.contains(id))
          .toList(growable: false);
      if (nextIds.length == playlist.mediaIds.length) {
        return playlist;
      }
      changed = true;
      return playlist.copyWith(mediaIds: nextIds, updatedAt: DateTime.now());
    }).toList(growable: false);
    if (!changed) {
      return;
    }
    _savePlaylists();
    notifyListeners();
  }

  void reorderPlaylistItems(String playlistId, int oldIndex, int newIndex) {
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      final mediaIds = List<String>.from(playlist.mediaIds);
      if (!_canReorder(mediaIds, oldIndex, newIndex)) {
        return playlist;
      }
      _reorder(mediaIds, oldIndex, newIndex);
      return playlist.copyWith(mediaIds: mediaIds, updatedAt: DateTime.now());
    }).toList(growable: false);
    _savePlaylists();
    notifyListeners();
  }

  void addToQueue(String mediaId) {
    if (_findItem(mediaId) == null) {
      return;
    }
    _queueIds = <String>[..._queueIds, mediaId];
    _saveState();
    notifyListeners();
  }

  void addManyToQueue(Iterable<String> mediaIds) {
    final validIds = mediaIds.where((id) => _findItem(id) != null).toList();
    if (validIds.isEmpty) {
      return;
    }
    _queueIds = <String>[..._queueIds, ...validIds];
    _saveState();
    notifyListeners();
  }

  void removeFromQueue(String mediaId) {
    final ids = List<String>.from(_queueIds);
    ids.remove(mediaId);
    _queueIds = ids;
    _saveState();
    notifyListeners();
  }

  void removeFromQueueAt(int index) {
    final ids = List<String>.from(_queueIds);
    if (index < 0 || index >= ids.length) {
      return;
    }
    ids.removeAt(index);
    _queueIds = ids;
    _saveState();
    notifyListeners();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    final ids = List<String>.from(_queueIds);
    if (!_canReorder(ids, oldIndex, newIndex)) {
      return;
    }
    _reorder(ids, oldIndex, newIndex);
    _queueIds = ids;
    _saveState();
    notifyListeners();
  }

  void clearQueue() {
    if (_queueIds.isEmpty) {
      return;
    }
    _queueIds = const <String>[];
    _saveState();
    notifyListeners();
  }

  Future<void> scanMediaLibrary() async {
    if (_isScanningLibrary) {
      return;
    }
    _isScanningLibrary = true;
    _libraryStatusMessage = '正在扫描或导入本机音频和视频...';
    notifyListeners();

    final result = await _mediaLibraryRepository.scan(
      MediaLibraryScanFilter(
        minimumAudioDuration: _settings.minimumAudioDuration,
        includedFolders: _settings.includedFolders,
        excludedFolders: _settings.excludedFolders,
      ),
    );
    if (result.status == MediaLibraryScanStatus.completed) {
      _stopPlayback();
    }
    _applyScanResult(
      result,
      emptyCompletedMessage: '没有找到或导入符合条件的本地媒体。',
    );
    _isScanningLibrary = false;
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    notifyListeners();
  }

  Future<void> addMediaSources() async {
    if (!_platformCapabilities.supportsFolderPicker ||
        _isUpdatingMediaSources) {
      return;
    }
    _isUpdatingMediaSources = true;
    notifyListeners();
    try {
      final added = await _mediaLibraryRepository.addSources();
      await _refreshMediaSources(notify: false);
      if (added.isNotEmpty) {
        _libraryStatusMessage = '已添加 ${added.length} 个媒体文件夹，正在建立索引。';
        await scanMediaLibrary();
      }
    } catch (error) {
      _libraryStatusMessage = '添加媒体文件夹失败：$error';
    } finally {
      _isUpdatingMediaSources = false;
      notifyListeners();
    }
  }

  Future<void> removeMediaSource(MediaSource source) async {
    if (_isUpdatingMediaSources) {
      return;
    }
    _isUpdatingMediaSources = true;
    notifyListeners();
    try {
      await _mediaLibraryRepository.removeSource(source.id);
      await _refreshMediaSources(notify: false);
      _libraryStatusMessage = '已移除媒体来源「${source.displayName}」，源文件未删除。';
    } catch (error) {
      _libraryStatusMessage = '移除媒体来源失败：$error';
    } finally {
      _isUpdatingMediaSources = false;
      _saveState();
      notifyListeners();
    }
  }

  Future<void> cancelMediaLibraryScan() async {
    if (!_isScanningLibrary) {
      return;
    }
    await _mediaLibraryRepository.cancelScan();
    _libraryStatusMessage = '正在取消扫描…';
    notifyListeners();
  }

  Future<void> _refreshMediaSources({bool notify = true}) async {
    if (!_platformCapabilities.supportsPersistentFolderAccess) {
      return;
    }
    _mediaSources = await _mediaLibraryRepository.listSources();
    if (notify) {
      notifyListeners();
    }
  }

  Future<MediaFileOperationResult> _performFileOperation(
    MediaFileOperationRequest request,
  ) async {
    final result = await _mediaLibraryRepository.performFileOperation(request);
    _libraryStatusMessage = result.message;
    if (result.didChangeFiles) {
      await scanMediaLibrary();
      _libraryStatusMessage = result.message;
      _saveState();
    } else {
      _saveState();
      notifyListeners();
    }
    return result;
  }

  Future<void> _loadOnlineEnhancement(MediaItem item) async {
    if (!_onlineEnhancementRequests.add(item.id)) {
      return;
    }
    try {
      final enhancement = await _onlineEnhancementRepository.fetch(
        item,
        enabled: _settings.allowOnlineEnhancement,
      );
      if (!_settings.allowOnlineEnhancement || enhancement.isEmpty) {
        return;
      }
      final current = _findItem(item.id);
      if (current == null) {
        return;
      }
      final fetchedLyrics = enhancement.lyricsText == null
          ? const <LyricLine>[]
          : parseLrc(enhancement.lyricsText!);
      final updated = current.copyWith(
        lyrics: current.lyrics.isEmpty && fetchedLyrics.isNotEmpty
            ? fetchedLyrics
            : current.lyrics,
        artworkPath: enhancement.artworkPath,
      );
      _replaceItem(updated);
      _saveState(
        partitions: const <AppStoragePartition>{
          AppStoragePartition.library,
        },
      );
      notifyListeners();
    } finally {
      _onlineEnhancementRequests.remove(item.id);
    }
  }

  Future<void> createBackup() async {
    final info = await _appStorageRepository.createBackup(_snapshotState());
    if (info == null) {
      _backupStatusMessage = '当前平台暂不支持备份导出。';
    } else {
      _backupStatusMessage = '已创建备份：${info.path}';
    }
    notifyListeners();
  }

  Future<void> restoreLatestBackup() async {
    final restored = await _appStorageRepository.restoreLatestBackup();
    if (restored == null || !_applyPersistedState(restored)) {
      _backupStatusMessage = '没有找到可恢复的备份。';
      notifyListeners();
      return;
    }
    _backupStatusMessage = '已从最近备份恢复。';
    _stopPlayback();
    _saveState(partitions: _allStoragePartitions);
    notifyListeners();
  }

  Future<void> _restorePersistedState() async {
    final persisted = await _appStorageRepository.load();
    if (persisted != null && _applyPersistedState(persisted)) {
      await _refreshMediaSources(notify: false);
      notifyListeners();
      return;
    }
    await _restoreLastScan();
    await _refreshMediaSources();
  }

  Future<void> _restoreLastScan() async {
    final result = await _mediaLibraryRepository.restoreLastScan();
    if (result.status != MediaLibraryScanStatus.completed || !result.hasMedia) {
      return;
    }
    _applyScanResult(result, emptyCompletedMessage: '');
    _libraryStatusMessage =
        '已恢复上次扫描：${_audioItems.length} 首音频、${_videoItems.length} 个视频。';
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    notifyListeners();
  }

  bool _applyPersistedState(Map<String, Object?> json) {
    _hiddenMediaIds = _asStringList(json['hiddenMediaIds']).toSet();
    final audioItems = visibleMediaItems(
      _dropRemovedSeedItems(_parseMediaItems(json['audioItems'])),
      _hiddenMediaIds,
    );
    final videoItems = visibleMediaItems(
      _dropRemovedSeedItems(_parseMediaItems(json['videoItems'])),
      _hiddenMediaIds,
    );

    _audioItems = audioItems;
    _videoItems = videoItems;
    final validMediaIds = _mediaIdsFor(<MediaItem>[
      ..._audioItems,
      ..._videoItems,
    ]);
    _playlists = _dropRemovedSeedPlaylists(
      _parsePlaylists(json['playlists']),
      validMediaIds,
    );
    _queueIds = _asStringList(json['queueIds'])
        .where(validMediaIds.contains)
        .toList(growable: false);
    final settings = json['settings'];
    if (settings is Map<Object?, Object?>) {
      _settings = LumioSettings.fromJson(settings.cast<String, Object?>());
    }
    _musicSort = _enumFromName(
      MusicSort.values,
      json['musicSort']?.toString(),
      MusicSort.addedAt,
    );
    _shuffleEnabled = json['shuffleEnabled'] == true;
    _repeatMode = _enumFromName(
      RepeatMode.values,
      json['repeatMode']?.toString(),
      RepeatMode.off,
    );
    _playbackView = _enumFromName(
      PlaybackView.values,
      json['playbackView']?.toString(),
      _settings.defaultPlaybackView,
    );
    _position = Duration(milliseconds: _asInt(json['positionMs']));
    _libraryStatusMessage =
        json['libraryStatusMessage']?.toString() ?? '已恢复本地媒体库。';
    _backupStatusMessage =
        json['backupStatusMessage']?.toString() ?? _backupStatusMessage;
    _playbackSpeed = _asDouble(json['playbackSpeed'], 1.0).clamp(0.5, 2.0);
    _abLoopStart = _durationFromMs(json['abLoopStartMs']);
    _abLoopEnd = _durationFromMs(json['abLoopEndMs']);

    final currentId = json['currentItemId']?.toString();
    _currentItem = currentId == null ? null : _findItem(currentId);
    _currentItem ??= _audioItems.isNotEmpty
        ? _audioItems.first
        : _videoItems.isNotEmpty
            ? _videoItems.first
            : null;
    _isPlaying = false;
    _playbackRepository.setSpeed(_playbackSpeed);
    _playbackRepository.setCrossfadeDuration(
      Duration(seconds: _settings.crossfadeSeconds),
    );
    _applyEqualizerPreset();
    if (_audioItems.isEmpty && _videoItems.isEmpty) {
      _libraryStatusMessage = '尚未扫描本机媒体。';
      _saveState();
    }
    return true;
  }

  List<MediaItem> _parseMediaItems(Object? value) {
    if (value is! List<Object?>) {
      return const <MediaItem>[];
    }
    return value
        .whereType<Map<Object?, Object?>>()
        .map((item) => MediaItem.fromJson(item.cast<String, Object?>()))
        .where((item) => item.id.isNotEmpty && item.path.isNotEmpty)
        .toList(growable: false);
  }

  List<MediaItem> _dropRemovedSeedItems(List<MediaItem> items) {
    return items
        .where((item) => !removedSeedMediaIds.contains(item.id))
        .toList(growable: false);
  }

  Set<String> _mediaIdsFor(List<MediaItem> items) {
    return items.map((item) => item.id).toSet();
  }

  List<Playlist> _dropRemovedSeedPlaylists(
    List<Playlist> playlists,
    Set<String> validMediaIds,
  ) {
    return playlists
        .where((playlist) => !removedSeedPlaylistIds.contains(playlist.id))
        .map(
          (playlist) => playlist.copyWith(
            mediaIds: playlist.mediaIds
                .where(validMediaIds.contains)
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
  }

  List<Playlist> _parsePlaylists(Object? value) {
    if (value is! List<Object?>) {
      return const <Playlist>[];
    }
    return value
        .whereType<Map<Object?, Object?>>()
        .map((item) => Playlist.fromJson(item.cast<String, Object?>()))
        .where((playlist) => playlist.id.isNotEmpty)
        .toList(growable: false);
  }

  void _handlePlaybackEvent(PlaybackEvent event) {
    switch (event.type) {
      case PlaybackEventType.completed:
        if (event.mediaId == null || event.mediaId == _currentItem?.id) {
          _handlePlaybackCompleted();
        }
      case PlaybackEventType.error:
        _isPlaying = false;
        _stopPositionTimer();
        _libraryStatusMessage =
            event.message.isEmpty ? '播放失败。' : '播放失败：${event.message}';
        _saveState();
        notifyListeners();
      case PlaybackEventType.videoTextureChanged:
        _videoTextureId = event.videoTextureId;
        notifyListeners();
      case PlaybackEventType.play:
        _resumeFromSystem();
      case PlaybackEventType.pause:
        _pauseFromSystem();
      case PlaybackEventType.toggle:
        togglePlaying();
      case PlaybackEventType.next:
        next();
      case PlaybackEventType.previous:
        previous();
      case PlaybackEventType.interruptionBegan:
        _interruptionController.begin(
          wasPlaying: _isPlaying,
          mayResume: event.mayResume,
        );
        _pauseFromSystem();
      case PlaybackEventType.interruptionEnded:
        if (_interruptionController.end()) {
          _resumeFromSystem();
        }
      case PlaybackEventType.pictureInPictureChanged:
        _isInPictureInPicture = event.isInPictureInPicture;
        notifyListeners();
      case PlaybackEventType.mediaItemChanged:
        _handleNativeMediaItemChanged(event.mediaId);
      case PlaybackEventType.nativePlaybackStateChanged:
        _handleNativePlaybackStateChanged(event.isPlaying);
    }
  }

  void _handleNativeMediaItemChanged(String? mediaId) {
    if (mediaId == null || mediaId == _currentItem?.id) {
      return;
    }
    final item = _findItem(mediaId);
    if (item == null) {
      return;
    }
    final queueIndex = _queueIds.indexOf(mediaId);
    if (queueIndex >= 0) {
      final nextQueueIds = List<String>.from(_queueIds)..removeAt(queueIndex);
      _queueIds = nextQueueIds;
    }
    _updateCurrentVideoResumePosition(forceSave: true);
    _currentItem = item.copyWith(
      playCount: item.playCount + 1,
      lastPosition: Duration.zero,
    );
    _replaceItem(_currentItem!);
    _position = Duration.zero;
    _isPlaying = true;
    _startPositionTimer();
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    notifyListeners();
  }

  void _handleNativePlaybackStateChanged(bool isPlaying) {
    if (_isPlaying == isPlaying) {
      return;
    }
    _isPlaying = isPlaying;
    if (isPlaying) {
      _startPositionTimer();
    } else {
      _stopPositionTimer();
      _updateCurrentVideoResumePosition(forceSave: true);
    }
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    notifyListeners();
  }

  void _pauseFromSystem() {
    if (!_isPlaying) {
      return;
    }
    _isPlaying = false;
    _stopPositionTimer();
    _updateCurrentVideoResumePosition(forceSave: true);
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    notifyListeners();
  }

  void _resumeFromSystem() {
    if (_isPlaying) {
      return;
    }
    togglePlaying();
  }

  void _handlePlaybackCompleted() {
    final current = _currentItem;
    if (current == null) {
      _isPlaying = false;
      _stopPositionTimer();
      notifyListeners();
      return;
    }
    _replaceItem(current.copyWith(lastPosition: Duration.zero));
    if (_repeatMode == RepeatMode.one) {
      _position = Duration.zero;
      play(_currentItem ?? current);
      return;
    }
    final pool =
        current.kind == MediaKind.video ? _videoItems : _sortedAudioItems();
    final index = pool.indexWhere((item) => item.id == current.id);
    final isLast = index < 0 || index >= pool.length - 1;
    if (_repeatMode == RepeatMode.off && isLast && !_shuffleEnabled) {
      _position = current.duration;
      _isPlaying = false;
      _stopPositionTimer();
      _saveState(
        partitions: const <AppStoragePartition>{
          AppStoragePartition.session,
          AppStoragePartition.library,
        },
      );
      notifyListeners();
      return;
    }
    next();
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      _syncPlaybackPosition();
    });
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _syncPlaybackPosition() async {
    if (!_isPlaying) {
      return;
    }
    final position = await _playbackRepository.position();
    if (!_isPlaying || position == Duration.zero) {
      return;
    }
    final item = _currentItem;
    _position = item == null || item.duration == Duration.zero
        ? position
        : position > item.duration
            ? item.duration
            : position;
    _updateCurrentVideoResumePosition();
    final loopStart = _abLoopStart;
    final loopEnd = _abLoopEnd;
    if (loopStart != null && loopEnd != null && _position >= loopEnd) {
      _position = loopStart;
      await _playbackRepository.seek(loopStart);
    }
    notifyListeners();
  }

  void _stopPlayback() {
    _updateCurrentVideoResumePosition(forceSave: true);
    _sleepFadeTimer?.cancel();
    _sleepFadeTimer = null;
    _playbackRepository.setVolumeScale(1.0);
    _isPlaying = false;
    _position = Duration.zero;
    _stopPositionTimer();
    _playbackRepository.stop();
  }

  void _updateCurrentVideoResumePosition({bool forceSave = false}) {
    final item = _currentItem;
    if (item == null || item.kind != MediaKind.video) {
      return;
    }
    final nextLastPosition = _position >= item.duration - _resumeEndThreshold
        ? Duration.zero
        : _position;
    if (item.lastPosition == nextLastPosition && !forceSave) {
      return;
    }
    _replaceItem(item.copyWith(lastPosition: nextLastPosition));
    if (!forceSave) {
      final now = DateTime.now();
      final lastSaveAt = _lastResumePositionSaveAt;
      if (lastSaveAt != null &&
          now.difference(lastSaveAt) < _resumeSaveInterval) {
        return;
      }
      _lastResumePositionSaveAt = now;
    }
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
  }

  void _applyEqualizerPreset() {
    _playbackRepository.setEqualizerPreset(
      _settings.equalizerPreset.name,
      customGains: _settings.customEqualizerGains,
    );
  }

  void _saveState({
    Set<AppStoragePartition> partitions = const <AppStoragePartition>{
      AppStoragePartition.session,
    },
  }) {
    _appStorageRepository.save(
      _snapshotState(partitions: partitions),
      partitions: partitions,
    );
  }

  void _savePlaylists() {
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.playlists,
      },
    );
  }

  Map<String, Object?> _snapshotState({
    Set<AppStoragePartition> partitions = _allStoragePartitions,
  }) {
    final snapshot = <String, Object?>{'schemaVersion': 2};
    if (partitions.contains(AppStoragePartition.library)) {
      snapshot.addAll(<String, Object?>{
        'audioItems': _audioItems.map((item) => item.toJson()).toList(),
        'videoItems': _videoItems.map((item) => item.toJson()).toList(),
      });
    }
    if (partitions.contains(AppStoragePartition.playlists)) {
      snapshot['playlists'] =
          _playlists.map((playlist) => playlist.toJson()).toList();
    }
    if (partitions.contains(AppStoragePartition.session)) {
      snapshot.addAll(<String, Object?>{
        'queueIds': _queueIds,
        'hiddenMediaIds': _hiddenMediaIds.toList(growable: false),
        'settings': _settings.toJson(),
        'currentItemId': _currentItem?.id,
        'musicSort': _musicSort.name,
        'shuffleEnabled': _shuffleEnabled,
        'repeatMode': _repeatMode.name,
        'playbackView': _playbackView.name,
        'positionMs': _position.inMilliseconds,
        'libraryStatusMessage': _libraryStatusMessage,
        'backupStatusMessage': _backupStatusMessage,
        'playbackSpeed': _playbackSpeed,
        'abLoopStartMs': _abLoopStart?.inMilliseconds,
        'abLoopEndMs': _abLoopEnd?.inMilliseconds,
        'savedAtMs': DateTime.now().millisecondsSinceEpoch,
      });
    }
    return snapshot;
  }

  void _applyScanResult(
    MediaLibraryScanResult result, {
    required String emptyCompletedMessage,
  }) {
    _lastScanStatus = result.status;
    switch (result.status) {
      case MediaLibraryScanStatus.completed:
        _audioItems = visibleMediaItems(
          _mergePersistedMediaMetadata(result.audioItems),
          _hiddenMediaIds,
        );
        _videoItems = visibleMediaItems(
          _mergePersistedMediaMetadata(result.videoItems),
          _hiddenMediaIds,
        );
        _currentItem = _audioItems.isNotEmpty
            ? _audioItems.first
            : _videoItems.isNotEmpty
                ? _videoItems.first
                : null;
        _isPlaying = false;
        if (result.hasMedia) {
          _libraryStatusMessage = result.message.isNotEmpty
              ? '${result.message} 当前媒体库：${_audioItems.length} 首音频、${_videoItems.length} 个视频。'
              : '已扫描到 ${_audioItems.length} 首音频、${_videoItems.length} 个视频。';
        } else {
          _libraryStatusMessage = result.message.isNotEmpty
              ? result.message
              : emptyCompletedMessage;
        }
      case MediaLibraryScanStatus.cancelled:
        _libraryStatusMessage = result.message;
      case MediaLibraryScanStatus.permissionDenied:
        _libraryStatusMessage = result.message;
      case MediaLibraryScanStatus.unsupported:
        _libraryStatusMessage = result.message;
      case MediaLibraryScanStatus.failed:
        _libraryStatusMessage = result.message;
    }
  }

  List<MediaItem> _mergePersistedMediaMetadata(List<MediaItem> scannedItems) {
    final previousByPath = <String, MediaItem>{
      for (final item in <MediaItem>[..._audioItems, ..._videoItems])
        item.path: item,
    };
    return scannedItems.map((item) {
      final previous = previousByPath[item.path];
      if (previous == null) {
        return item;
      }
      return item.copyWith(
        title: previous.title,
        artist: previous.artist,
        album: previous.album,
        playCount: previous.playCount,
        isFavorite: previous.isFavorite,
        lastPosition: previous.lastPosition,
        // 用户单独选择的歌词优先于扫描时发现的同名歌词。
        lyrics: previous.hasCustomLyrics ? previous.lyrics : item.lyrics,
        hasCustomLyrics: previous.hasCustomLyrics,
      );
    }).toList(growable: false);
  }

  Duration _initialPlaybackPosition(MediaItem item) {
    if (item.kind != MediaKind.video || item.lastPosition <= Duration.zero) {
      return Duration.zero;
    }
    if (item.duration <= _resumeEndThreshold ||
        item.lastPosition >= item.duration - _resumeEndThreshold) {
      return Duration.zero;
    }
    return item.lastPosition;
  }

  T _enumFromName<T extends Enum>(List<T> values, String? name, T fallback) {
    return values.firstWhere(
      (value) => value.name == name,
      orElse: () => fallback,
    );
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

  double _asDouble(Object? value, double fallback) {
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  Duration? _durationFromMs(Object? value) {
    final milliseconds = _asInt(value);
    return milliseconds <= 0 ? null : Duration(milliseconds: milliseconds);
  }

  List<String> _asStringList(Object? value) {
    if (value is! List<Object?>) {
      return const <String>[];
    }
    return value.map((item) => item.toString()).toList(growable: false);
  }

  bool _canReorder(List<Object?> items, int oldIndex, int newIndex) {
    final adjustedNewIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    return oldIndex >= 0 &&
        oldIndex < items.length &&
        adjustedNewIndex >= 0 &&
        adjustedNewIndex < items.length &&
        oldIndex != adjustedNewIndex;
  }

  void _reorder<T>(List<T> items, int oldIndex, int newIndex) {
    final item = items.removeAt(oldIndex);
    final adjustedNewIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    items.insert(adjustedNewIndex, item);
  }

  List<MediaItem> _sortedAudioItems() {
    final items = List<MediaItem>.from(_audioItems);
    switch (_musicSort) {
      case MusicSort.title:
        items.sort((a, b) => a.title.compareTo(b.title));
      case MusicSort.addedAt:
        items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case MusicSort.duration:
        items.sort((a, b) => b.duration.compareTo(a.duration));
      case MusicSort.playCount:
        items.sort((a, b) => b.playCount.compareTo(a.playCount));
      case MusicSort.fileSize:
        items.sort((a, b) => b.fileSizeBytes.compareTo(a.fileSizeBytes));
    }
    return List<MediaItem>.unmodifiable(items);
  }

  MediaItem? _findItem(String mediaId) {
    for (final item in <MediaItem>[..._audioItems, ..._videoItems]) {
      if (item.id == mediaId) {
        return item;
      }
    }
    return null;
  }

  List<MediaItem> _itemsForIds(List<String> ids) {
    final all = <String, MediaItem>{
      for (final item in <MediaItem>[..._audioItems, ..._videoItems])
        item.id: item,
    };
    return List<MediaItem>.unmodifiable(
      ids.map((id) => all[id]).whereType<MediaItem>(),
    );
  }

  MediaItem? _popNextQueuedItem() {
    while (_queueIds.isNotEmpty) {
      final ids = List<String>.from(_queueIds);
      final nextId = ids.removeAt(0);
      _queueIds = ids;
      final item = _findItem(nextId);
      if (item != null) {
        _saveState();
        notifyListeners();
        return item;
      }
    }
    return null;
  }

  List<MediaItem> _nativePlaybackQueue(MediaItem current) {
    final pool =
        current.kind == MediaKind.video ? _videoItems : _sortedAudioItems();
    final currentIndex = pool.indexWhere((item) => item.id == current.id);
    final beforeAndCurrent = currentIndex < 0
        ? <MediaItem>[current]
        : pool.take(currentIndex + 1).toList(growable: false);
    final remaining = currentIndex < 0
        ? pool
        : pool.skip(currentIndex + 1).toList(growable: false);
    return <MediaItem>[
      ...beforeAndCurrent,
      ...queueItems.where((item) => item.kind == current.kind),
      ...remaining,
    ];
  }

  void _replaceItem(MediaItem updated) {
    if (updated.kind == MediaKind.audio) {
      _audioItems = _audioItems
          .map((item) => item.id == updated.id ? updated : item)
          .toList(growable: false);
    } else {
      _videoItems = _videoItems
          .map((item) => item.id == updated.id ? updated : item)
          .toList(growable: false);
    }
    if (_currentItem?.id == updated.id) {
      _currentItem = updated;
    }
  }

  @override
  void dispose() {
    removeListener(_syncDesktopLyrics);
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
