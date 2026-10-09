part of 'app_state.dart';

extension DeviceTransferState on LumioAppState {
  List<MediaItem> get transferMedia => [..._audioItems, ..._videoItems];

  bool transferVisible(MediaItem item) =>
      !_hiddenMediaIds.contains(item.id) &&
      item.availability == 'available' &&
      !_settings.excludedFolders.any((folder) =>
          item.path == folder || item.path.startsWith('$folder/')) &&
      (item.sourceId == null ||
          item.sourceId == 'lumio-received' ||
          _mediaSources.any((s) => s.id == item.sourceId && s.isAvailable));

  Map<String, String> get _receivedFingerprints => {
        for (final item in _receivedMedia.values)
          if (_receivedDigests.containsKey(item.id))
            item.path: 'sha256:${_receivedDigests[item.id]}'
      };

  String get transferImportContext => sha256
      .convert(utf8.encode(jsonEncode([
        lyricImportContext,
        for (final item in _videoItems)
          [item.id, item.title, item.artist, item.album],
      ])))
      .toString();

  Map<String, Object?> _transferIndexSnapshot() => {
        'version': 1,
        'items': _receivedMedia.values.map((e) => e.toJson()).toList(),
        'digests': _receivedDigests,
        'applied': _appliedTransfers,
      };

  void _restoreTransferIndex(Object? raw) {
    _receivedMedia.clear();
    _receivedDigests.clear();
    _appliedTransfers.clear();
    if (raw is! Map || raw['version'] != 1 || raw['items'] is! List) return;
    for (final value in raw['items'] as List) {
      if (value is! Map) continue;
      final item = MediaItem.fromJson(Map<String, Object?>.from(value));
      if (!RegExp(r'^transfer-[a-f0-9]{32}$').hasMatch(item.id) ||
          item.sourceId != 'lumio-received' ||
          !_safeReceivedName(item.relativePath)) continue;
      _receivedMedia[item.id] = item;
    }
    if (raw['digests'] is Map) {
      for (final e in (raw['digests'] as Map).entries) {
        if (_receivedMedia.containsKey(e.key) &&
            e.value is String &&
            isTransferDigest(e.value))
          _receivedDigests[e.key as String] = e.value as String;
      }
    }
    if (raw['applied'] is Map) {
      for (final e in (raw['applied'] as Map).entries.take(200)) {
        if (e.key is String && isTransferDigest(e.key) && e.value is String)
          _appliedTransfers[e.key as String] = e.value as String;
      }
    }
  }

  bool _safeReceivedName(String? name) =>
      name != null && RegExp(r'^[a-f0-9]{32}\.[a-z0-9]{1,8}$').hasMatch(name);

  Future<void> _rebaseReceivedMedia() async {
    if (_receivedMedia.isEmpty) return;
    try {
      final store = await const PlatformTransferStorage().open();
      for (final old in _receivedMedia.values.toList()) {
        final path = '${store.root.path}/received/${old.relativePath}';
        final exists = await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.file;
        final artworkName = old.artworkPath?.split('/').last;
        final updated = MediaItem.fromJson({
          ...old.toJson(),
          'path': path,
          'folder': '设备互传',
          'availability': exists ? 'available' : 'missing',
          'artworkPath': _safeReceivedName(artworkName)
              ? '${store.root.path}/received/$artworkName'
              : null
        });
        _replaceItem(updated);
      }
      _lyricFingerprints.addAll(_receivedFingerprints);
    } catch (_) {
      for (final old in _receivedMedia.values.toList()) {
        _replaceItem(old.copyWith(availability: 'missing'));
      }
    }
  }

  /// Hashes local candidates, never trusts a filename or a cached scanned-file hash.
  Future<MediaItem?> findTransferDuplicate(TransferResource resource) async {
    if (resource.kind != TransferResourceKind.audio &&
        resource.kind != TransferResourceKind.video) return null;
    for (final item in transferMedia.where((item) =>
        transferVisible(item) &&
        item.kind.name == resource.kind.name &&
        item.fileSizeBytes == resource.byteLength)) {
      NativeTransferLease? lease;
      try {
        lease = await NativeTransferLease.open(item);
        if (lease.digest == resource.sha256Digest &&
            lease.size == resource.byteLength) return item;
      } catch (_) {
        /* An unreadable local file cannot stand in for a verified download. */
      } finally {
        await lease?.close();
      }
    }
    return null;
  }

  Future<void> mergeTransferMetadata(MediaItem item, TransferResource resource,
      TransferImportPolicy policy, String expectedContext) async {
    if (transferImportContext != expectedContext || lyricLibraryBusy)
      throw StateError('本地内容已变化，请重新确认导入。');
    if (!policy.syncMetadata) return;
    final latest = _findItem(item.id);
    if (latest == null) throw StateError('本地歌曲已移除。');
    final m = resource.metadata;
    final updated = latest.copyWith(
        title: m.title.trim().isEmpty ? latest.title : m.title,
        artist: m.artist.trim().isEmpty ? latest.artist : m.artist,
        album: m.album.trim().isEmpty ? latest.album : m.album,
        lyricMatchAliases:
            [...rememberLyricAlias(latest), ...m.aliases].take(32).toList());
    _replaceItem(updated);
    try {
      await _saveAuthoringLibrary();
    } catch (_) {
      _replaceItem(latest);
      rethrow;
    }
    _notifyTransferLibrary();
  }

  Future<void> importTransfer(ReceivedTransferReceipt receipt, File file,
      {bool reconfirm = false, String? expectedContext}) async {
    final resource = receipt.resource;
    if (_appliedTransfers.containsKey(receipt.jobId)) return;
    if (lyricLibraryBusy) throw StateError('请等待扫描或歌词保存结束，再重试入库。');
    final baseline = reconfirm
        ? transferImportContext
        : expectedContext ?? receipt.baseVersion;
    if (baseline != transferImportContext)
      throw StateError('接收期间本地内容已变化，文件已保存，请重新确认导入。');
    if (resource.kind == TransferResourceKind.lyrics) {
      if (resource.byteLength > lyricPackageLimit)
        throw const FormatException('歌词文件过大。');
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['version'] != 1 || raw['lyric'] is! Map)
        throw const FormatException('歌词格式无效。');
      final lyric = LyricLibraryEntry.fromJson(
          Map<String, Object?>.from(raw['lyric'] as Map));
      for (final item in _audioItems.where(
          (e) => transferVisible(e) && e.fileSizeBytes == lyric.fileSize)) {
        NativeTransferLease? lease;
        try {
          lease = await NativeTransferLease.open(item);
          _lyricFingerprints[item.path] = 'sha256:${lease.digest}';
        } catch (_) {
        } finally {
          await lease?.close();
        }
      }
      if (baseline != transferImportContext)
        throw StateError('本地内容已变化，请重新确认导入。');
      await importLyricPackage(
          LyricPackagePreview([lyric], [], '设备互传 · ${resource.metadata.title}'),
          overwrite: receipt.policy.overwriteLyrics,
          syncMetadata: receipt.policy.syncMetadata,
          expectedContext: lyricImportContext);
    } else if (resource.kind != TransferResourceKind.artwork) {
      final duplicate = await findTransferDuplicate(resource);
      if (baseline != transferImportContext)
        throw StateError('本地内容已变化，请重新确认导入。');
      if (duplicate != null) {
        await mergeTransferMetadata(
            duplicate, resource, receipt.policy, transferImportContext);
      } else {
        final item = MediaItem(
            id: 'transfer-${receipt.localId}',
            kind: resource.kind == TransferResourceKind.audio
                ? MediaKind.audio
                : MediaKind.video,
            title: resource.metadata.title,
            artist: resource.metadata.artist,
            album: resource.metadata.album,
            duration: Duration(milliseconds: resource.metadata.durationMs),
            path: file.path,
            folder: '设备互传',
            addedAt: DateTime.now(),
            accentColor: const Color(0xff276d60),
            fileSizeBytes: resource.byteLength,
            formatLabel: resource.extension.toUpperCase(),
            sourceId: 'lumio-received',
            relativePath: '${receipt.localId}.${resource.extension}',
            lyricMatchAliases: resource.metadata.aliases);
        _receivedMedia[item.id] = item;
        _receivedDigests[item.id] = resource.sha256Digest;
        if (item.kind == MediaKind.audio) {
          _audioItems = [..._audioItems, item];
        } else {
          _videoItems = [..._videoItems, item];
        }
        _lyricFingerprints[item.path] = 'sha256:${resource.sha256Digest}';
        try {
          await _saveAuthoringLibrary();
        } catch (_) {
          _receivedMedia.remove(item.id);
          _receivedDigests.remove(item.id);
          _lyricFingerprints.remove(item.path);
          _audioItems = _audioItems.where((e) => e.id != item.id).toList();
          _videoItems = _videoItems.where((e) => e.id != item.id).toList();
          rethrow;
        }
        // Existing pending lyrics can now match this exact content, even after a rename.
        if (_lyricLibrary.any((e) => e.active))
          await _mutateLyricLibrary(() {
            _applyPendingLyricLibrary(newPaths: {item.path});
            return '已匹配待关联歌词';
          });
      }
    }
    _appliedTransfers[receipt.jobId] = receipt.localId;
    while (_appliedTransfers.length > 200) {
      _appliedTransfers.remove(_appliedTransfers.keys.first);
    }
    try {
      await _saveAuthoringLibrary();
    } catch (_) {
      _appliedTransfers.remove(receipt.jobId);
      rethrow;
    }
    if (_portableRestorePending) {
      _associatePortableItems([..._audioItems, ..._videoItems]);
      _saveState(partitions: LumioAppState._allStoragePartitions);
    }
    _notifyTransferLibrary();
  }

  Future<void> attachTransferArtwork(
      TransferResource media, File artwork) async {
    final matches = transferMedia
        .where((e) => _receivedDigests[e.id] == media.sha256Digest)
        .toList();
    for (final item in matches)
      _replaceItem(item.copyWith(artworkPath: artwork.path));
    try {
      await _saveAuthoringLibrary();
    } catch (_) {
      for (final item in matches) _replaceItem(item);
      rethrow;
    }
    _notifyTransferLibrary();
  }
}
