part of 'app_state.dart';

extension PortableBackupState on LumioAppState {
  bool get portableBackupSupported => PortableBackupRepository.supported;
  bool get portableBackupBusy => _portableBackupBusy;

  void _beginPortableBackup() {
    final transfer = _deviceTransfer;
    if (_portableBackupBusy ||
        lyricLibraryBusy ||
        _isUpdatingMediaSources ||
        transfer?.preparing == true ||
        transfer?.receiving == true ||
        transfer?.connecting == true ||
        transfer?.sharing == true ||
        transfer?.approved == true) {
      throw StateError('请先完成扫描、歌词保存或设备互传，并关闭共享和连接。');
    }
    _portableBackupBusy = true;
    _lyricLibraryBusy = true;
    _notifyTransferLibrary();
  }

  void endPortableBackup() {
    _portableBackupBusy = false;
    _lyricLibraryBusy = false;
    if (!_disposed) {
      _saveState(partitions: LumioAppState._allStoragePartitions);
      _notifyTransferLibrary();
    }
  }

  Future<String?> exportPortableBackup() async {
    _beginPortableBackup();
    try {
      final snapshot = await _portableSnapshot();
      final path = await PortableBackupRepository().export(snapshot);
      _backupStatusMessage = path == null
          ? '已取消导出，尚未保存外部备份。'
          : '跨端数据备份已保存。不含任何音视频或封面原文件；卸载前请另行保存 App 内接收的媒体。';
      return path;
    } finally {
      endPortableBackup();
    }
  }

  Future<Map<String, Object?>> _portableSnapshot() async {
    final items = [..._audioItems, ..._videoItems];
    final hashes = {
      ..._receivedFingerprints,
      ...await LyricPackageRepository().fingerprints(
          items
              .where((e) =>
                  e.sourceId != portableMediaSource &&
                  !_receivedFingerprints.containsKey(e.path))
              .take(5000)
              .toList(),
          includeVideo: true)
    };
    for (final item in items) {
      _replaceItem(item.copyWith(backupIdentity: {
        'key': portableKey(item),
        'fileName':
            item.backupIdentity['fileName'] ?? item.path.split('/').last,
        'fingerprint':
            hashes[item.path] ?? item.backupIdentity['fingerprint'] ?? '',
      }));
    }
    final snapshot = _snapshotState();
    if (platformCapabilities.supportsSubtitleEditing) {
      snapshot['subtitleProjects'] =
          await SubtitleWorkbenchRepository().snapshot();
    }
    return snapshot;
  }

  Future<PreparedPortableBackup> prepareCloudBackup() async {
    _beginPortableBackup();
    try {
      return await PortableBackupRepository()
          .prepare(await _portableSnapshot());
    } catch (_) {
      endPortableBackup();
      rethrow;
    }
  }

  Future<PortableBackupPreview> receiveCloudBackup(
      Future<void> Function(File file) download) async {
    _beginPortableBackup();
    Directory? directory;
    try {
      final env = await PortableBackupRepository().environment();
      directory =
          await Directory(env['temporaryRoot'] as String).createTemp('cloud-');
      final file = File('${directory.path}/backup.zip');
      await download(file);
      return await PortableBackupRepository().read(file);
    } catch (_) {
      try {
        await directory?.delete(recursive: true);
      } finally {
        endPortableBackup();
      }
      rethrow;
    }
  }

  Future<PortableBackupPreview?> selectPortableBackup() async {
    _beginPortableBackup();
    try {
      final preview = await PortableBackupRepository().select();
      if (preview == null) endPortableBackup();
      return preview;
    } catch (_) {
      endPortableBackup();
      rethrow;
    }
  }

  Future<void> importPortableBackup(PortableBackupPreview preview) async {
    if (!_portableBackupBusy) throw StateError('请重新选择备份文件。');
    final created = <File>[];
    var committed = false;
    try {
      final store = preview.files.isEmpty
          ? null
          : await const PlatformTransferStorage().open();
      if (store != null &&
          await const PlatformTransferStorage().availableSpace() <
              preview.byteLength + 64 * 1024 * 1024) {
        throw StateError('应用内媒体恢复空间不足。');
      }
      final replacements = <String, String>{};
      for (final raw in preview.files) {
        final entry = raw as Map;
        final originalName = entry['name'] as String;
        final randomName =
            List.generate(16, (_) => Random.secure().nextInt(256))
                .map((e) => e.toRadixString(16).padLeft(2, '0'))
                .join();
        final destination = File(
            '${store!.root.path}/received/$randomName.${originalName.split('.').last}');
        if (await destination.exists()) throw StateError('恢复文件名冲突，请重新导入。');
        created.add(destination);
        await File('${preview.directory.path}/$originalName')
            .copy(destination.path);
        if (await destination.length() != entry['size'] ||
            (await sha256.bind(destination.openRead()).first).toString() !=
                entry['sha256']) {
          throw StateError('恢复文件校验失败，未覆盖应用数据。');
        }
        replacements[entry['originalPath'] as String] = destination.path;
      }
      final snapshot = preview.state;
      if (preview.metadataOnly) {
        final local = [..._audioItems, ..._videoItems];
        final hashes = {
          ..._receivedFingerprints,
          ...await LyricPackageRepository().fingerprints(
              local
                  .where((e) => e.sourceId != portableMediaSource)
                  .take(5000)
                  .toList(),
              includeVideo: true)
        };
        final pending = [
          ...snapshot['audioItems'] as List,
          ...snapshot['videoItems'] as List
        ]
            .map((raw) =>
                MediaItem.fromJson(Map<String, Object?>.from(raw as Map)))
            .toList();
        final matches = matchPortableMedia(pending, local, hashes);
        final remap = <String, String>{};
        for (final key in ['audioItems', 'videoItems']) {
          snapshot[key] = (snapshot[key] as List).map((raw) {
            final saved =
                MediaItem.fromJson(Map<String, Object?>.from(raw as Map));
            final match = matches[saved.id];
            if (match == null) return saved.toJson();
            remap[saved.id] = match.id;
            return bindPortableMedia(saved, match).toJson();
          }).toList();
        }
        _remapSnapshot(snapshot, remap);
        // Physical received files belong to this device, even after replacing metadata.
        final index = _transferIndexSnapshot();
        final restored = {
          for (final raw in [
            ...snapshot['audioItems'] as List,
            ...snapshot['videoItems'] as List
          ])
            (raw as Map)['id']: raw
        };
        index['items'] = (index['items'] as List)
            .map((raw) => restored[(raw as Map)['id']] ?? raw)
            .toList();
        snapshot['receivedMedia'] = index;
        for (final key in ['audioItems', 'videoItems']) {
          final list = snapshot[key] as List;
          final ids = list.map((raw) => (raw as Map)['id']).toSet();
          list.addAll((index['items'] as List).where((raw) =>
              (raw as Map)['kind'] ==
                  (key == 'audioItems' ? 'audio' : 'video') &&
              !ids.contains(raw['id'])));
        }
        final settings = snapshot['settings'] as Map;
        settings['includedFolders'] = _settings.includedFolders;
        settings['excludedFolders'] = _settings.excludedFolders;
      }
      void rebase(Map raw) {
        final path = raw['path'];
        if (replacements.containsKey(path)) {
          raw['path'] = replacements[path];
          raw['relativePath'] = (raw['path'] as String).split('/').last;
          raw['availability'] = 'available';
        } else if (!preview.metadataOnly) {
          raw['availability'] = 'permissionRequired';
        }
        final artwork = raw['artworkPath'];
        if (replacements.containsKey(artwork))
          raw['artworkPath'] = replacements[artwork];
        else if (!preview.metadataOnly &&
            artwork is String &&
            artwork.startsWith('/')) raw['artworkPath'] = null;
      }

      for (final raw in [
        ...snapshot['audioItems'] as List,
        ...snapshot['videoItems'] as List
      ]) {
        rebase(raw as Map);
      }
      for (final raw in (snapshot['receivedMedia'] as Map)['items'] as List) {
        rebase(raw as Map);
      }
      for (final raw in snapshot['subtitleProjects'] as List? ?? []) {
        final source = (raw as Map)['source'] as Map;
        if (replacements.containsKey(source['path']))
          source['path'] = replacements[source['path']];
      }
      snapshot['backupStatusMessage'] =
          '已恢复备份数据。未找到的音视频记录会保留，添加或扫描文件后自动关联；设备安全码保持本机身份。';
      snapshot['libraryStatusMessage'] = '已恢复备份数据。请添加或扫描对应音视频。';
      snapshot['abLoopStartMs'] = null;
      snapshot['abLoopEndMs'] = null;
      snapshot['portableRestorePending'] = true;
      ++_playbackEpoch;
      _interruptionController.cancelPendingResume();
      _playbackNeedsReload = true;
      _stopPositionTimer();
      await _playbackRepository.stop();
      _isPlaying = false;
      await PortableBackupRepository().commit(snapshot);
      committed = true;
      _videoTextureId = null;
      _videoAspectRatio = null;
      _playbackError = null;
      _applyPersistedState(snapshot);
      _lyricFingerprints.clear();
      _lyricFingerprints.addAll(_receivedFingerprints);
      _section = AppSection.settings;
      lyricChanges.value++;
      subtitleChanges.value++;
      _backupStatusMessage = snapshot['backupStatusMessage'] as String;
    } finally {
      if (!committed) {
        for (final file in created) {
          if (await file.exists()) await file.delete();
        }
      }
    }
  }

  void _remapSnapshot(
      Map<String, Object?> snapshot, Map<String, String> remap) {
    String id(String value) => remap[value] ?? value;
    for (final raw in snapshot['playlists'] as List) {
      (raw as Map)['mediaIds'] =
          (raw['mediaIds'] as List).cast<String>().map(id).toList();
    }
    for (final key in ['queueIds', 'hiddenMediaIds']) {
      snapshot[key] =
          (snapshot[key] as List? ?? []).cast<String>().map(id).toList();
    }
    for (final key in ['currentItemId', 'lastAudioItemId']) {
      if (snapshot[key] is String) snapshot[key] = id(snapshot[key] as String);
    }
  }

  void _associatePortableItems(List<MediaItem> scanned) {
    final pending = [..._audioItems, ..._videoItems];
    final matches = matchPortableMedia(pending, scanned, _lyricFingerprints);
    if (matches.isEmpty) return;
    final remap = {for (final e in matches.entries) e.key: e.value.id};
    final snapshot = _snapshotState();
    _remapSnapshot(snapshot, remap);
    _playlists = (snapshot['playlists'] as List)
        .map((e) => Playlist.fromJson(Map<String, Object?>.from(e as Map)))
        .toList();
    _queueIds = (snapshot['queueIds'] as List).cast<String>();
    _hiddenMediaIds =
        (snapshot['hiddenMediaIds'] as List).cast<String>().toSet();
    if (_lastAudioItemId != null)
      _lastAudioItemId = remap[_lastAudioItemId] ?? _lastAudioItemId;
    for (final saved in pending) {
      final local = matches[saved.id];
      if (local == null) continue;
      final bound = bindPortableMedia(saved, local);
      _audioItems = _audioItems
          .where((e) => e.id != local.id)
          .map((e) => e.id == saved.id ? bound : e)
          .toList();
      _videoItems = _videoItems
          .where((e) => e.id != local.id)
          .map((e) => e.id == saved.id ? bound : e)
          .toList();
      if (_receivedMedia.containsKey(local.id))
        _receivedMedia[local.id] = bound;
      if (_currentItem?.id == saved.id) _currentItem = bound;
      for (final project in _portableSubtitleProjects.whereType<Map>()) {
        final source = project['source'] as Map?;
        if (source?['path'] == saved.path) source!['path'] = bound.path;
      }
    }
    _savePlaylists();
  }

  void _remapPortableReferences(List<MediaItem> scanned) {
    final previousByPath = {
      for (final item in [..._audioItems, ..._videoItems]) item.path: item.id
    };
    final remap = <String, String>{
      for (final item in scanned)
        if (previousByPath.containsKey(item.path))
          previousByPath[item.path]!: item.id,
    };
    String id(String old) => remap[old] ?? old;
    _playlists = _playlists
        .map((p) => p.copyWith(mediaIds: p.mediaIds.map(id).toList()))
        .toList();
    _queueIds = _queueIds.map(id).toList();
    _hiddenMediaIds = _hiddenMediaIds.map(id).toSet();
    if (_lastAudioItemId != null) _lastAudioItemId = id(_lastAudioItemId!);
    if (_currentItem != null)
      _currentItem = _currentItem!.copyWith(id: id(_currentItem!.id));
    if (remap.isNotEmpty) _savePlaylists();
  }
}
