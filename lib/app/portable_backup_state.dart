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
      final snapshot = _snapshotState();
      if (platformCapabilities.supportsSubtitleEditing) {
        snapshot['subtitleProjects'] =
            await SubtitleWorkbenchRepository().snapshot();
      }
      final path = await PortableBackupRepository().export(snapshot);
      _backupStatusMessage = path == null
          ? '已取消导出，尚未保存外部备份。'
          : '迁移备份已保存到所选位置。卸载前请确认文件可访问；不含外部音视频和设备安全私钥。';
      return path;
    } finally {
      endPortableBackup();
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
      final store = await const PlatformTransferStorage().open();
      if (await const PlatformTransferStorage().availableSpace() <
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
            '${store.root.path}/received/$randomName.${originalName.split('.').last}');
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
      void rebase(Map raw) {
        final path = raw['path'];
        if (replacements.containsKey(path)) {
          raw['path'] = replacements[path];
          raw['relativePath'] = (raw['path'] as String).split('/').last;
          raw['availability'] = 'available';
        } else {
          raw['availability'] = 'permissionRequired';
        }
        final artwork = raw['artworkPath'];
        if (replacements.containsKey(artwork))
          raw['artworkPath'] = replacements[artwork];
        else if (artwork is String && artwork.startsWith('/'))
          raw['artworkPath'] = null;
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
      snapshot['backupStatusMessage'] = '已恢复迁移备份。外部文件需重新授权或扫描；设备安全码保持本机身份。';
      snapshot['libraryStatusMessage'] = '已恢复媒体索引与应用内媒体。请重新授权或扫描外部文件。';
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
