part of 'app_state.dart';

/// 播放控制、队列、计时器与原生播放事件。
/// 拆到独立 part 只为可读性，状态仍由 LumioAppState 独占，订阅关系未变。
extension PlaybackState on LumioAppState {
  void play(MediaItem item, {Duration? startPosition}) {
    _playbackStartRevision++;
    if (item.sourceId == portableMediaSource) {
      _playbackError = '这是备份中的媒体记录，尚未关联本机文件。请添加或扫描对应音视频后再播放。';
      _notify();
      return;
    }
    _rememberAudioPlayback();
    _playbackNeedsReload = false;
    _playbackEpoch++;
    _lyricCalibration = null;
    _interruptionController.cancelPendingResume();
    final initialPosition = startPosition ?? _initialPlaybackPosition(item);
    _videoAspectRatio = null;
    _playbackError = null;
    _currentItem = item.copyWith(playCount: item.playCount + 1);
    _position = initialPosition;
    _positionSampledAt = DateTime.now();
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
        _playbackError = error.toString();
        _isPlaying = false;
        _stopPositionTimer();
        _saveState();
        _notify();
      },
    ).whenComplete(
      () {
        _videoTextureId = _playbackRepository.videoTextureId;
        _notify();
      },
    );
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    unawaited(_loadOnlineEnhancement(_currentItem!));
    _notify();
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
    if (_playbackNeedsReload) {
      play(_currentItem!, startPosition: _position);
      return;
    }
    if (_playbackError != null && !_isPlaying) {
      play(_currentItem!);
      return;
    }
    _isPlaying = !_isPlaying;
    if (_isPlaying) {
      _playbackStartRevision++;
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
                _playbackError = retryError.toString();
                _isPlaying = false;
                _stopPositionTimer();
                _saveState();
                _notify();
              },
            );
          } else {
            _playbackError = error.toString();
            _isPlaying = false;
            _stopPositionTimer();
          }
        },
      );
    } else {
      _updateCurrentVideoResumePosition(forceSave: true);
      _stopPositionTimer();
      _playbackRepository.pause();
    }
    _saveState();
    _notify();
  }

  void _rememberAudioPlayback() {
    if (_currentItem?.kind != MediaKind.audio) return;
    _lastAudioItemId = _currentItem!.id;
    _lastAudioPosition = _position;
  }

  void _restoreAudioPlayback() {
    final previous =
        _lastAudioItemId == null ? null : _findItem(_lastAudioItemId!);
    _currentItem = previous?.kind == MediaKind.audio ? previous : null;
    final duration = _currentItem?.duration ?? Duration.zero;
    _position = Duration(
        milliseconds: _lastAudioPosition.inMilliseconds
            .clamp(0, duration.inMilliseconds));
    _isPlaying = false;
    _playbackNeedsReload = true;
    _videoTextureId = null;
    _videoAspectRatio = null;
    _playbackError = null;
    _playbackView = _settings.defaultPlaybackView;
    _abLoopStart = null;
    _abLoopEnd = null;
  }

  void leaveVideoPlaybackPage() {
    if (_disposed ||
        _currentItem?.kind != MediaKind.video ||
        _isInPictureInPicture) return;
    _interruptionController.cancelPendingResume();
    _updateCurrentVideoResumePosition(forceSave: true);
    _stopPositionTimer();
    // Release the video without loading or auto-playing the remembered song.
    unawaited(_playbackRepository.stop().catchError((Object error) {
      if (_disposed) return;
      _libraryStatusMessage = '暂停视频失败：$error';
      _notify();
    }));
    _restoreAudioPlayback();
    _saveState();
    _notify();
  }

  void next() {
    final queued = _popNextQueuedItem();
    if (queued != null) {
      play(queued);
      return;
    }
    final current = _currentItem;
    final pool =
        (current?.kind == MediaKind.video ? _videoItems : _sortedAudioItems())
            .where((e) => e.sourceId != portableMediaSource)
            .toList();
    if (pool.isEmpty) {
      return;
    }
    final index =
        current == null ? -1 : pool.indexWhere((item) => item.id == current.id);
    final nextIndex = _shuffleEnabled
        ? _randomOtherIndex(pool)
        : _repeatMode == RepeatMode.all
            ? (index + 1) % pool.length
            : (index + 1).clamp(0, pool.length - 1);
    play(pool[nextIndex]);
  }

  void previous() {
    final current = _currentItem;
    final pool =
        (current?.kind == MediaKind.video ? _videoItems : _sortedAudioItems())
            .where((e) => e.sourceId != portableMediaSource)
            .toList();
    if (pool.isEmpty) {
      return;
    }
    final index =
        current == null ? 0 : pool.indexWhere((item) => item.id == current.id);
    final previousIndex = index <= 0 ? 0 : index - 1;
    play(pool[previousIndex]);
  }

  void shuffleAll(MediaKind kind) {
    final pool = (kind == MediaKind.audio ? _audioItems : _videoItems)
        .where((e) => e.sourceId != portableMediaSource)
        .toList();
    if (pool.isEmpty) {
      return;
    }
    setPlaybackMode(PlaybackMode.shuffle);
    play(pool[_randomOtherIndex(pool)]);
  }

  int _randomOtherIndex(List<MediaItem> pool) {
    final currentIndex = pool.indexWhere((item) => item.id == _currentItem?.id);
    if (pool.first.kind == MediaKind.audio) {
      return weightedShuffleIndex(
        pool.map((item) => item.shuffleWeight).toList(growable: false),
        _random,
        currentIndex: currentIndex,
      );
    }
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
    if (_shuffleEnabled) {
      _playbackRepository.setShuffleWeights({
        for (final song in _audioItems) song.id: song.shuffleWeight,
      });
    }
    _playbackRepository.setShuffleEnabled(_shuffleEnabled);
    _saveState();
    _notify();
  }

  void setPlaybackMode(PlaybackMode mode) {
    _shuffleEnabled = mode == PlaybackMode.shuffle;
    _repeatMode = switch (mode) {
      PlaybackMode.sequential => RepeatMode.off,
      PlaybackMode.repeatOne => RepeatMode.one,
      PlaybackMode.repeatAll || PlaybackMode.shuffle => RepeatMode.all,
    };
    if (_shuffleEnabled) {
      _playbackRepository.setShuffleWeights({
        for (final song in _audioItems) song.id: song.shuffleWeight,
      });
    }
    _playbackRepository.setShuffleEnabled(_shuffleEnabled);
    _playbackRepository.setRepeatMode(_repeatMode);
    _saveState();
    _notify();
  }

  Future<void> setShuffleWeight(String mediaId, int value) async {
    final item = _findItem(mediaId);
    if (item == null || item.kind != MediaKind.audio) return;
    final weight = value.clamp(1, MediaItem.maximumShuffleWeight);
    if (weight == item.shuffleWeight) return;
    _replaceItem(item.copyWith(shuffleWeight: weight));
    _saveState(partitions: const {AppStoragePartition.library});
    _notify();
    await _playbackRepository.setShuffleWeights({
      for (final song in _audioItems) song.id: song.shuffleWeight,
    });
  }

  void cycleRepeatMode() {
    _repeatMode = switch (_repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    _playbackRepository.setRepeatMode(_repeatMode);
    _saveState();
    _notify();
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
    _notify();
  }

  void setPlaybackView(PlaybackView view) {
    _playbackView = view;
    _saveState();
    _notify();
  }

  void seekToFraction(double fraction) {
    final item = _currentItem;
    if (item == null) {
      return;
    }
    _playbackEpoch++;
    _position = item.duration * fraction.clamp(0, 1);
    _positionSampledAt = DateTime.now();
    if (!_playbackNeedsReload) _playbackRepository.seek(_position);
    _updateCurrentVideoResumePosition(forceSave: true);
    _saveState();
    _notify();
  }

  void enterPictureInPicture() {
    _playbackRepository.enterPictureInPicture().catchError((Object error) {
      _libraryStatusMessage = '进入小窗失败：$error';
      _saveState();
      _notify();
    });
  }

  Future<double?> adjustBrightness(double delta) {
    return _playbackRepository
        .adjustBrightness(delta)
        .catchError((Object error) {
      _libraryStatusMessage = '亮度调节失败：$error';
      _saveState();
      _notify();
      return null;
    });
  }

  Future<double?> adjustVolume(double delta) {
    return _playbackRepository.adjustVolume(delta).catchError((Object error) {
      _libraryStatusMessage = '音量调节失败：$error';
      _saveState();
      _notify();
      return null;
    });
  }

  Future<void> setVideoFullscreen(bool enabled) async {
    try {
      await _playbackRepository.setVideoFullscreen(enabled);
    } catch (error) {
      _libraryStatusMessage = '全屏亮度状态恢复失败：$error';
      _notify();
    }
  }

  void setPlaybackSpeed(double speed) {
    _playbackEpoch++;
    _playbackSpeed = ((speed * 10).roundToDouble() / 10).clamp(0.5, 2.0);
    _playbackRepository.setSpeed(_playbackSpeed);
    _saveState();
    _notify();
  }

  void setEqualizerPreset(EqualizerPreset preset) {
    if (_settings.equalizerPreset == preset) {
      return;
    }
    _settings = _settings.copyWith(equalizerPreset: preset);
    _applyEqualizerPreset();
    _saveState();
    _notify();
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
    _notify();
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
      _notify();
    });
    if (duration > LumioAppState._sleepFadeDuration) {
      _sleepFadeTimer =
          Timer(duration - LumioAppState._sleepFadeDuration, _startSleepFade);
    } else {
      _startSleepFade();
    }
    _saveState();
    _notify();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    _sleepTimer = null;
    _sleepFadeTimer = null;
    _sleepTimerEndsAt = null;
    _playbackRepository.setVolumeScale(1.0);
    _saveState();
    _notify();
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
      final scale = (remaining.inMilliseconds /
              LumioAppState._sleepFadeDuration.inMilliseconds)
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
    _notify();
  }

  void setAbLoopEnd() {
    final start = _abLoopStart;
    if (start == null || _position <= start) {
      return;
    }
    _abLoopEnd = _position;
    _saveState();
    _notify();
  }

  void clearAbLoop() {
    _abLoopStart = null;
    _abLoopEnd = null;
    _saveState();
    _notify();
  }

  void addToQueue(String mediaId) {
    if (_findItem(mediaId) == null) {
      return;
    }
    _queueIds = <String>[..._queueIds, mediaId];
    _saveState();
    _notify();
  }

  /// 从合集（专辑/艺术家/歌单）第一首开始播放，其余按顺序排入队列。
  /// 备份中尚未关联本机文件的记录会被跳过。
  void playAll(Iterable<String> mediaIds) {
    final items = _itemsForIds(mediaIds.toList(growable: false))
        .where((item) => item.sourceId != portableMediaSource)
        .toList(growable: false);
    if (items.isEmpty) return;
    play(items.first);
    final rest = items.skip(1).map((item) => item.id).toList(growable: false);
    if (rest.isNotEmpty) addManyToQueue(rest);
  }

  void addManyToQueue(Iterable<String> mediaIds) {
    final validIds = mediaIds.where((id) => _findItem(id) != null).toList();
    if (validIds.isEmpty) {
      return;
    }
    _queueIds = <String>[..._queueIds, ...validIds];
    _saveState();
    _notify();
  }

  void removeFromQueue(String mediaId) {
    final ids = List<String>.from(_queueIds);
    ids.remove(mediaId);
    _queueIds = ids;
    _saveState();
    _notify();
  }

  void removeFromQueueAt(int index) {
    final ids = List<String>.from(_queueIds);
    if (index < 0 || index >= ids.length) {
      return;
    }
    ids.removeAt(index);
    _queueIds = ids;
    _saveState();
    _notify();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    final ids = List<String>.from(_queueIds);
    if (!_canReorder(ids, oldIndex, newIndex)) {
      return;
    }
    _reorder(ids, oldIndex, newIndex);
    _queueIds = ids;
    _saveState();
    _notify();
  }

  void clearQueue() {
    if (_queueIds.isEmpty) {
      return;
    }
    _queueIds = const <String>[];
    _saveState();
    _notify();
  }

  void _handlePlaybackEvent(PlaybackEvent event) {
    if (_playbackNeedsReload &&
        (event.type == PlaybackEventType.completed ||
            event.type == PlaybackEventType.mediaItemChanged ||
            event.type == PlaybackEventType.nativePlaybackStateChanged)) return;
    switch (event.type) {
      case PlaybackEventType.completed:
        if (event.mediaId == null || event.mediaId == _currentItem?.id) {
          _handlePlaybackCompleted();
        }
      case PlaybackEventType.error:
        if (event.mediaId != null && event.mediaId != _currentItem?.id) return;
        _playbackError = event.message.isEmpty ? '媒体播放失败。' : event.message;
        _isPlaying = false;
        _stopPositionTimer();
        _saveState();
        _notify();
      case PlaybackEventType.videoTextureChanged:
        _videoTextureId = event.videoTextureId;
        _videoAspectRatio = null;
        _notify();
      case PlaybackEventType.videoAspectRatioChanged:
        if (event.mediaId != null && event.mediaId != _currentItem?.id) return;
        _videoAspectRatio = event.videoAspectRatio;
        _notify();
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
        _notify();
      case PlaybackEventType.mediaItemChanged:
        _handleNativeMediaItemChanged(event.mediaId,
            restarted: event.restarted);
      case PlaybackEventType.nativePlaybackStateChanged:
        _handleNativePlaybackStateChanged(event.isPlaying);
    }
  }

  void _handleNativeMediaItemChanged(String? mediaId,
      {bool restarted = false}) {
    if (mediaId == null || (mediaId == _currentItem?.id && !restarted)) {
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
    _playbackEpoch++;
    _lyricCalibration = null;
    _updateCurrentVideoResumePosition(forceSave: true);
    _rememberAudioPlayback();
    _currentItem = item.copyWith(
      playCount: item.playCount + 1,
      lastPosition: Duration.zero,
    );
    _videoAspectRatio = null;
    _playbackError = null;
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
    _notify();
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
    _notify();
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
    _notify();
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
      _notify();
      return;
    }
    _replaceItem(current.copyWith(lastPosition: Duration.zero));
    if (_repeatMode == RepeatMode.one) {
      _position = Duration.zero;
      play(_currentItem ?? current);
      return;
    }
    final pool =
        (current.kind == MediaKind.video ? _videoItems : _sortedAudioItems())
            .where((e) => e.sourceId != portableMediaSource)
            .toList();
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
      _notify();
      return;
    }
    next();
  }

  void _startPositionTimer() {
    _playbackEpoch++;
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      _syncPlaybackPosition();
    });
  }

  void _stopPositionTimer() {
    _playbackEpoch++;
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _syncPlaybackPosition() async {
    if (!_isPlaying || _positionQueryInFlight || _disposed) {
      return;
    }
    final epoch = _playbackEpoch;
    _positionQueryInFlight = true;
    Duration position;
    try {
      position = await _playbackRepository
          .position()
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return;
    } finally {
      _positionQueryInFlight = false;
    }
    if (_disposed ||
        !_isPlaying ||
        epoch != _playbackEpoch ||
        position == Duration.zero) {
      return;
    }
    final item = _currentItem;
    _position = item == null || item.duration == Duration.zero
        ? position
        : position > item.duration
            ? item.duration
            : position;
    _positionSampledAt = DateTime.now();
    _updateCurrentVideoResumePosition();
    final loopStart = _abLoopStart;
    final loopEnd = _abLoopEnd;
    if (loopStart != null && loopEnd != null && _position >= loopEnd) {
      _playbackEpoch++;
      _position = loopStart;
      _positionSampledAt = DateTime.now();
      await _playbackRepository.seek(loopStart);
    }
    if (_disposed) return;
    _notify();
  }

  /// 歌词/字幕高亮的刷新节拍。只做本地插值与通知，不读平台通道；
  /// 真实进度由 700ms 的位置采样校正。
  void _tickHighlight() {
    if (!_isPlaying || _disposed) return;
    if (_currentItem?.kind == MediaKind.video &&
        platformCapabilities.supportsSubtitleEditing) {
      subtitleChanges.value++;
    } else {
      lyricChanges.value++;
      _syncDesktopLyrics();
    }
  }

  void _stopPlayback() {
    _lyricCalibration = null;
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
    final nextLastPosition =
        _position >= item.duration - LumioAppState._resumeEndThreshold
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
          now.difference(lastSaveAt) < LumioAppState._resumeSaveInterval) {
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

  Duration _initialPlaybackPosition(MediaItem item) {
    if (item.kind != MediaKind.video || item.lastPosition <= Duration.zero) {
      return Duration.zero;
    }
    if (item.duration <= LumioAppState._resumeEndThreshold ||
        item.lastPosition >=
            item.duration - LumioAppState._resumeEndThreshold) {
      return Duration.zero;
    }
    return item.lastPosition;
  }

  List<MediaItem> _nativePlaybackQueue(MediaItem current) {
    final pool =
        (current.kind == MediaKind.video ? _videoItems : _sortedAudioItems())
            .where((e) => e.sourceId != portableMediaSource)
            .toList();
    final currentIndex = pool.indexWhere((item) => item.id == current.id);
    final beforeAndCurrent = currentIndex < 0
        ? <MediaItem>[current]
        : pool.take(currentIndex + 1).toList(growable: false);
    final remaining = currentIndex < 0
        ? pool
        : pool.skip(currentIndex + 1).toList(growable: false);
    return <MediaItem>[
      ...beforeAndCurrent,
      ...queueItems.where((item) =>
          item.kind == current.kind && item.sourceId != portableMediaSource),
      ...remaining,
    ];
  }

  MediaItem? _popNextQueuedItem() {
    final unresolved = <String>[];
    while (_queueIds.isNotEmpty) {
      final ids = List<String>.from(_queueIds);
      final nextId = ids.removeAt(0);
      _queueIds = ids;
      final item = _findItem(nextId);
      if (item?.sourceId == portableMediaSource) unresolved.add(nextId);
      if (item != null && item.sourceId != portableMediaSource) {
        _queueIds = [...unresolved, ...ids];
        _saveState();
        _notify();
        return item;
      }
    }
    _queueIds = unresolved;
    return null;
  }
}
