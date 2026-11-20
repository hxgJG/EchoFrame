part of 'app_state.dart';

/// 媒体库扫描与来源管理、媒体文件操作、元数据与扫描结果合并。
extension MediaLibraryState on LumioAppState {
  void share(MediaItem item) {
    _playbackRepository.share(item).catchError((Object error) {
      _libraryStatusMessage = '分享失败：$error';
      _saveState();
      _notify();
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
      _notify();
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
    _notify();
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
    _notify();
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
        lyricMatchAliases: rememberLyricAlias(current),
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
    _notify();
  }

  Future<void> scanMediaLibrary() async {
    if (_isScanningLibrary || _lyricLibraryBusy) {
      return;
    }
    _isScanningLibrary = true;
    _libraryStatusMessage = '正在扫描或导入本机音频和视频...';
    _mediaScanStatusMessage = _libraryStatusMessage;
    _notify();

    var result = await _mediaLibraryRepository.scan(
      MediaLibraryScanFilter(
        minimumAudioDuration: _settings.minimumAudioDuration,
        includedFolders: _settings.includedFolders,
        excludedFolders: _settings.excludedFolders,
      ),
    );
    if (result.status == MediaLibraryScanStatus.completed) {
      result = await _fingerprintLyricScan(result);
      final restoredPosition = _portableRestorePending ? _position : null;
      _stopPlayback();
      if (restoredPosition != null) _position = restoredPosition;
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
    _notify();
  }

  Future<void> addMediaSources() => _addMediaSources();

  Future<void> addVideoSources() => _addMediaSources(videos: true);

  Future<void> _addMediaSources({bool videos = false}) async {
    if (!_platformCapabilities.supportsFolderPicker ||
        _isUpdatingMediaSources ||
        _isScanningLibrary) {
      return;
    }
    _isUpdatingMediaSources = true;
    _notify();
    try {
      final added = videos
          ? await _mediaLibraryRepository.addVideoSources()
          : await _mediaLibraryRepository.addSources();
      await _refreshMediaSources(notify: false);
      if (added.isNotEmpty) {
        _libraryStatusMessage = '已添加媒体来源，正在建立索引。';
        await scanMediaLibrary();
      }
    } catch (error) {
      _libraryStatusMessage = '添加媒体来源失败：$error';
    } finally {
      _isUpdatingMediaSources = false;
      _notify();
    }
  }

  Future<void> removeMediaSource(MediaSource source) async {
    if (_isUpdatingMediaSources) {
      return;
    }
    _isUpdatingMediaSources = true;
    _notify();
    try {
      await _mediaLibraryRepository.removeSource(source.id);
      await _refreshMediaSources(notify: false);
      _libraryStatusMessage = '已移除媒体来源「${source.displayName}」，源文件未删除。';
    } catch (error) {
      _libraryStatusMessage = '移除媒体来源失败：$error';
    } finally {
      _isUpdatingMediaSources = false;
      _saveState();
      _notify();
    }
  }

  Future<void> cancelMediaLibraryScan() async {
    if (!_isScanningLibrary) {
      return;
    }
    await _mediaLibraryRepository.cancelScan();
    _libraryStatusMessage = '正在取消扫描…';
    _mediaScanStatusMessage = _libraryStatusMessage;
    _notify();
  }

  Future<void> _refreshMediaSources({bool notify = true}) async {
    if (!_platformCapabilities.supportsPersistentFolderAccess) {
      return;
    }
    _mediaSources = await _mediaLibraryRepository.listSources();
    if (notify) {
      _notify();
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
      _notify();
    }
    return result;
  }

  void _handleExternalMediaOpened(List<MediaItem> items, String message) {
    if (_disposed) return;
    if (items.isEmpty) {
      _libraryStatusMessage = message;
      _notify();
      return;
    }
    final opened = <MediaItem>[];
    if (_portableRestorePending) _associatePortableItems(items);
    for (final item in items) {
      final index = _videoItems.indexWhere(
          (existing) => existing.id == item.id || existing.path == item.path);
      // 再次从 Finder 打开同一文件时保留用户的标题、字幕和播放记录。
      if (index >= 0) {
        opened.add(_videoItems[index]);
      } else {
        _videoItems = [..._videoItems, item];
        opened.add(item);
      }
    }
    _section = AppSection.video;
    _libraryStatusMessage =
        message.isEmpty ? '已打开 ${opened.length} 个视频，源文件未复制。' : message;
    unawaited(_refreshMediaSources());
    play(opened.first);
    onExternalMediaOpened?.call();
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

  void _applyScanResult(
    MediaLibraryScanResult result, {
    required String emptyCompletedMessage,
  }) {
    _lastScanStatus = result.status;
    switch (result.status) {
      case MediaLibraryScanStatus.completed:
        if (_portableRestorePending) {
          _associatePortableItems([
            ...result.audioItems,
            ...result.videoItems,
            ..._receivedMedia.values
          ]);
        }
        final previousPaths = _audioItems.map((item) => item.path).toSet();
        final restoring = _portableRestorePending;
        final scannedPaths = [...result.audioItems, ...result.videoItems]
            .map((e) => e.path)
            .toSet();
        final retainedAudio = restoring
            ? _audioItems
                .where((e) =>
                    e.sourceId != 'lumio-received' &&
                    !scannedPaths.contains(e.path))
                .toList()
            : <MediaItem>[];
        final retainedVideo = restoring
            ? _videoItems
                .where((e) =>
                    e.sourceId != 'lumio-received' &&
                    !scannedPaths.contains(e.path))
                .toList()
            : <MediaItem>[];
        if (restoring)
          _remapPortableReferences(
              [...result.audioItems, ...result.videoItems]);
        final restoredCurrentId = _currentItem?.id;
        _audioItems = visibleMediaItems(
          [
            ..._mergePersistedMediaMetadata(result.audioItems),
            ...retainedAudio,
            ..._receivedMedia.values
                .where((item) => item.kind == MediaKind.audio)
          ],
          _hiddenMediaIds,
        );
        _videoItems = visibleMediaItems(
          [
            ..._mergePersistedMediaMetadata(result.videoItems),
            ...retainedVideo,
            ..._receivedMedia.values
                .where((item) => item.kind == MediaKind.video)
          ],
          _hiddenMediaIds,
        );
        final matchedLyrics = _applyPendingLyricLibrary(
            newPaths: _audioItems
                .map((item) => item.path)
                .toSet()
                .difference(previousPaths));
        _currentItem = _audioItems.isNotEmpty
            ? _audioItems.first
            : _videoItems.isNotEmpty
                ? _videoItems.first
                : null;
        if (restoring) {
          _currentItem = restoredCurrentId == null
              ? _currentItem
              : _findItem(restoredCurrentId);
          _playbackNeedsReload = true;
          _portableRestorePending =
              retainedAudio.isNotEmpty || retainedVideo.isNotEmpty;
        }
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
        if (matchedLyrics > 0)
          _libraryStatusMessage += ' 已自动关联 $matchedLyrics 首歌词包歌词。';
        if (_portableRestorePending)
          _libraryStatusMessage +=
              ' 仍有 ${retainedAudio.length + retainedVideo.length} 个备份媒体未重新授权或找到，已保留其歌词、歌单和播放记录。';
      case MediaLibraryScanStatus.cancelled:
        _libraryStatusMessage = result.message;
      case MediaLibraryScanStatus.permissionDenied:
        _libraryStatusMessage = result.message;
      case MediaLibraryScanStatus.unsupported:
        _libraryStatusMessage = result.message;
      case MediaLibraryScanStatus.failed:
        _libraryStatusMessage = result.message;
    }
    _mediaScanStatusMessage = _libraryStatusMessage;
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
        lyricMatchAliases: rememberLyricAlias(previous, additional: {
          'title': item.title,
          'artist': item.artist,
          'album': item.album,
        }),
        playCount: previous.playCount,
        shuffleWeight: previous.shuffleWeight,
        isFavorite: previous.isFavorite,
        lastPosition: previous.lastPosition,
        // 用户单独选择的歌词优先于扫描时发现的同名歌词。
        lyrics: previous.hasCustomLyrics ? previous.lyrics : item.lyrics,
        lyricTiming: previous.hasCustomLyrics ||
                LyricTiming.signatureFor(item.lyrics) ==
                    previous.lyricTiming.lyricsSignature
            ? previous.lyricTiming
            : const LyricTiming(),
        hasCustomLyrics: previous.hasCustomLyrics,
        lyricDraft: previous.lyricDraft,
        subtitles: previous.subtitleState['origin'] == 'edited' ||
                (previous.subtitleState.isNotEmpty &&
                    previous.subtitleState['version'] != 1)
            ? previous.subtitles
            : item.subtitles,
        subtitleState: previous.subtitleState,
        backupIdentity: previous.backupIdentity,
      );
    }).toList(growable: false);
  }

  void dismissMediaScanStatus() {
    _mediaScanStatusMessage = null;
    _notify();
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
      _notify();
    } finally {
      _onlineEnhancementRequests.remove(item.id);
    }
  }
}
