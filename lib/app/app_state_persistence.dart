part of 'app_state.dart';

/// 分区快照、备份恢复与应用更新前的状态落盘。
extension PersistenceState on LumioAppState {
  Future<void> createBackup() async {
    final snapshot = _snapshotState();
    if (platformCapabilities.supportsSubtitleEditing) {
      try {
        snapshot['subtitleProjects'] =
            await SubtitleWorkbenchRepository().snapshot();
      } catch (e) {
        _backupStatusMessage = '字幕项目备份失败，未创建不完整备份：$e';
        _notify();
        return;
      }
    }
    final info = await _appStorageRepository.createBackup(snapshot);
    if (info == null) {
      _backupStatusMessage = '当前平台暂不支持备份导出。';
    } else {
      _backupStatusMessage = '已创建备份：${info.path}';
    }
    _notify();
  }

  Future<void> restoreLatestBackup() async {
    if (_lyricLibraryBusy || _isScanningLibrary) return;
    final restored = await _appStorageRepository.restoreLatestBackup();
    if (restored != null &&
        platformCapabilities.supportsSubtitleEditing &&
        restored['subtitleProjects'] is List) {
      try {
        await SubtitleWorkbenchRepository()
            .restore(restored['subtitleProjects'] as List);
      } catch (e) {
        _backupStatusMessage = '字幕项目恢复失败：$e';
        _notify();
        return;
      }
    }
    if (restored == null || !_applyPersistedState(restored)) {
      _backupStatusMessage = '没有找到可恢复的备份。';
      _notify();
      return;
    }
    _backupStatusMessage = '已从最近备份恢复。';
    _stopPlayback();
    _saveState(partitions: LumioAppState._allStoragePartitions);
    _notify();
  }

  Future<void> _restorePersistedState() async {
    try {
      final persisted = await _appStorageRepository.load();
      if (persisted != null && _applyPersistedState(persisted)) {
        await _rebaseReceivedMedia();
        await _refreshMediaSources(notify: false);
        _notify();
        return;
      }
      await _restoreLastScan();
      await _refreshMediaSources();
    } finally {
      _lyricLibraryReady = true;
      if (!_disposed) _notify();
      if (!_disposed) {
        await _mediaLibraryRepository
            .setExternalOpenHandler(_handleExternalMediaOpened);
      }
    }
  }

  Future<void> _restoreLastScan() async {
    var result = await _mediaLibraryRepository.restoreLastScan();
    if (result.status != MediaLibraryScanStatus.completed || !result.hasMedia) {
      return;
    }
    result = await _fingerprintLyricScan(result);
    _applyScanResult(result, emptyCompletedMessage: '');
    _libraryStatusMessage =
        '已恢复上次扫描：${_audioItems.length} 首音频、${_videoItems.length} 个视频。';
    _saveState(
      partitions: const <AppStoragePartition>{
        AppStoragePartition.session,
        AppStoragePartition.library,
      },
    );
    _notify();
  }

  bool _applyPersistedState(Map<String, Object?> json) {
    _portableRestorePending = json['portableRestorePending'] == true;
    _portableSubtitleProjects =
        List<Object?>.from(json['subtitleProjects'] as List? ?? []);
    _restoreLyricLibrary(json);
    _restoreTransferIndex(json['receivedMedia']);
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
    if (_libraryStatusMessage.startsWith('播放失败')) {
      _libraryStatusMessage = '已恢复本地媒体库。';
    }
    _mediaScanStatusMessage = null;
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
    _lastAudioItemId = json['lastAudioItemId']?.toString();
    _lastAudioPosition =
        Duration(milliseconds: _asInt(json['lastAudioPositionMs']));
    if (_currentItem?.kind == MediaKind.audio) {
      _rememberAudioPlayback();
    } else if (_currentItem?.kind == MediaKind.video) {
      unawaited(_playbackRepository.stop().catchError((Object _) {}));
      _restoreAudioPlayback();
    }
    // Persisted records do not guarantee that the native player has this song
    // loaded (Android's service can outlive the Flutter page/process).
    _playbackNeedsReload = true;
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

  Future<void> prepareForApplicationUpdate() async {
    if (_portableBackupBusy) throw StateError('备份或恢复尚未结束，请稍后更新。');
    final storage = _appStorageRepository;
    final snapshot = _snapshotState();
    if (storage is PlatformAppStorageRepository) {
      await storage.saveChecked(snapshot,
          partitions: LumioAppState._allStoragePartitions);
    } else {
      await storage.save(snapshot,
          partitions: LumioAppState._allStoragePartitions);
    }
  }

  void _saveState({
    Set<AppStoragePartition> partitions = const <AppStoragePartition>{
      AppStoragePartition.session,
    },
  }) {
    if (_portableBackupBusy) return;
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
    Set<AppStoragePartition> partitions = LumioAppState._allStoragePartitions,
  }) {
    final snapshot = <String, Object?>{'schemaVersion': 2};
    if (partitions.contains(AppStoragePartition.library)) {
      snapshot.addAll(<String, Object?>{
        'audioItems': _audioItems.map((item) => item.toJson()).toList(),
        'videoItems': _videoItems.map((item) => item.toJson()).toList(),
        'lyricLibrary': _unreadableLyricLibrary ??
            {
              'version': 1,
              'entries': _lyricLibrary
                  .map((entry) => entry.toJson(local: true))
                  .toList(),
            },
        'lyricLibraryUndo': _lyricLibraryUndo,
        'receivedMedia': _transferIndexSnapshot(),
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
        'lastAudioItemId': _currentItem?.kind == MediaKind.audio
            ? _currentItem!.id
            : _lastAudioItemId,
        'lastAudioPositionMs': (_currentItem?.kind == MediaKind.audio
                ? _position
                : _lastAudioPosition)
            .inMilliseconds,
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
        'portableRestorePending': _portableRestorePending,
        if (_portableSubtitleProjects.isNotEmpty)
          'subtitleProjects': _portableSubtitleProjects,
      });
    }
    return snapshot;
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
}
