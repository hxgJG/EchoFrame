part of 'app_state.dart';

extension LyricLibraryState on LumioAppState {
  List<LyricLibraryEntry> get lyricLibraryEntries =>
      List.unmodifiable(_lyricLibrary);
  bool get lyricLibraryBusy =>
      _lyricLibraryBusy ||
      _isExportingLyrics ||
      _isScanningLibrary ||
      !_lyricLibraryReady;
  bool get lyricPackageSupported => LyricPackageRepository.supported;
  Future<MediaLibraryScanResult> _fingerprintLyricScan(
      MediaLibraryScanResult result) async {
    final sizes = _lyricLibrary
        .where((e) => e.active && e.fingerprint.isNotEmpty)
        .map((e) => e.fileSize)
        .toSet();
    _lyricFingerprints = await LyricPackageRepository().fingerprints(result
        .audioItems
        .where((e) => sizes.contains(e.fileSizeBytes))
        .take(5000)
        .toList());
    return result;
  }

  bool get canUndoLyricLibrary => _lyricLibraryUndo != null;
  String? get lyricLibraryError => _lyricLibraryError;
  String get lyricImportContext => jsonEncode([
        _lyricLibrary
            .map((e) => [e.id, e.active, e.handled, e.excluded])
            .toList(),
        _audioItems
            .map((e) => [
                  e.id,
                  e.path,
                  e.title,
                  e.artist,
                  e.duration.inMilliseconds,
                  e.fileSizeBytes,
                  lyricStateSignature(e)
                ])
            .toList(),
      ]);

  void _restoreLyricLibrary(Map<String, Object?> json) {
    _lyricLibrary = [];
    _lyricLibraryUndo = null;
    _unreadableLyricLibrary = null;
    _lyricLibraryError = null;
    final raw = json['lyricLibrary'];
    if (raw == null) return;
    try {
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['entries'] is! List ||
          (raw['entries'] as List).length > lyricLibraryLimit)
        throw const FormatException();
      _lyricLibrary = (raw['entries'] as List)
          .map((e) => LyricLibraryEntry.fromJson(
              Map<String, Object?>.from(e as Map),
              local: true))
          .toList();
      if (_lyricLibrary.map((e) => e.id).toSet().length != _lyricLibrary.length)
        throw const FormatException();
      if (json['lyricLibraryUndo'] is Map)
        _lyricLibraryUndo =
            Map<String, Object?>.from(json['lyricLibraryUndo'] as Map);
    } catch (_) {
      _lyricLibrary = [];
      _unreadableLyricLibrary = raw;
      _lyricLibraryError = '歌词库数据或版本无法读取，已保留原始数据，请勿回退应用版本。';
    }
  }

  Future<LyricPackagePreview?> readLyricPackage() async {
    if (lyricLibraryBusy || _lyricLibraryError != null)
      throw StateError('请等待扫描/保存结束，或先处理歌词库错误。');
    _lyricLibraryBusy = true;
    _notifyLyricLibrary();
    try {
      final picked = await LyricPackageRepository().pick();
      if (picked == null) return null;
      final preview = await compute(decodeLyricPackage, picked);
      final sizes = preview.entries
          .where((e) => e.fingerprint.isNotEmpty)
          .map((e) => e.fileSize)
          .toSet();
      _lyricFingerprints.addAll(await LyricPackageRepository().fingerprints(
          _audioItems
              .where((e) => sizes.contains(e.fileSizeBytes))
              .take(5000)
              .toList()));
      return preview;
    } finally {
      _lyricLibraryBusy = false;
      if (!_disposed) _notifyLyricLibrary();
    }
  }

  String lyricEntryStatus(LyricLibraryEntry entry) {
    if (!entry.active) return '历史版本（不自动匹配）';
    final bound = _audioItems
        .where((item) => entry.handled[item.path] == lyricStateSignature(item))
        .length;
    if (bound > 0) return '已关联 $bound 首歌曲';
    final candidates =
        entry.candidates(_audioItems, fingerprints: _lyricFingerprints);
    if (candidates.length > 1) return '待确认：存在多个版本';
    if (candidates.length == 1 &&
        entry.handled.containsKey(candidates.single.path)) return '已跳过或本地歌词已修改';
    return '待匹配（可手动关联）';
  }

  String lyricImportSummary(LyricPackagePreview preview, bool overwrite) {
    var match = 0, conflict = 0, pending = 0, existing = 0;
    final destinations = <String, int>{};
    for (final entry in preview.entries) {
      final targets =
          entry.candidates(_audioItems, fingerprints: _lyricFingerprints);
      if (targets.length == 1)
        destinations.update(targets.single.id, (v) => v + 1, ifAbsent: () => 1);
    }
    for (final entry in preview.entries) {
      if (_lyricLibrary.any((e) => e.active && e.matchKey == entry.matchKey))
        existing++;
      final targets =
          entry.candidates(_audioItems, fingerprints: _lyricFingerprints);
      if (targets.length != 1 || destinations[targets.single.id] != 1) {
        pending++;
        continue;
      }
      match++;
      if (targets.single.lyrics.isNotEmpty) conflict++;
    }
    return '共 ${preview.entries.length} 首：唯一匹配 $match 首，待匹配/待确认 $pending 首。\n'
        '$conflict 首本地已有歌词，${overwrite ? '将优先使用导入版本' : '将保留本地歌词'}。\n'
        '歌词库有 $existing 条同歌曲记录，${overwrite ? '新版本启用，旧版本保留' : '保留已有版本'}。\n'
        '未匹配歌词会保存，后续扫描时按本次覆盖选项自动匹配。';
  }

  Future<String> importLyricPackage(LyricPackagePreview preview,
      {required bool overwrite,
      required bool syncMetadata,
      required String expectedContext}) async {
    if (expectedContext != lyricImportContext)
      throw StateError('媒体库或歌词已变化，请重新预览后确认。');
    var retained = 0;
    return _mutateLyricLibrary(() {
      for (final raw in preview.entries) {
        final existing = _lyricLibrary
            .where((e) => e.active && e.matchKey == raw.matchKey)
            .toList();
        final incoming = !overwrite && existing.isNotEmpty
            ? raw.copyWith(
                lyrics: existing.last.lyrics, offsetMs: existing.last.offsetMs)
            : raw;
        if (existing.any((e) =>
            e.contentSignature == incoming.contentSignature &&
            e.overwrite == overwrite &&
            e.syncMetadata == syncMetadata)) {
          retained++;
          continue;
        }
        _lyricLibrary = _lyricLibrary
            .map((e) => e.active && e.matchKey == raw.matchKey
                ? e.copyWith(active: false)
                : e)
            .toList();
        _lyricLibrary.add(incoming.copyWith(
            overwrite: overwrite,
            syncMetadata: syncMetadata,
            source: preview.fileName));
      }
      final applied = _applyPendingLyricLibrary();
      return '已保存歌词包，为 $applied 首应用歌词及/或展示信息，保留/去重 $retained 条；其他歌词可在歌词库查看并关联。';
    });
  }

  Future<String> associateLyricEntry(String entryId, String mediaId,
          {required bool overwrite}) =>
      _mutateLyricLibrary(() {
        final index = _lyricLibrary.indexWhere((e) => e.id == entryId);
        final item = _findItem(mediaId);
        if (index < 0 || item == null || item.kind != MediaKind.audio)
          throw StateError('歌曲或歌词已移除。');
        if (item.lyrics.isNotEmpty && !overwrite) return '已保留本地歌词，未覆盖。';
        final entry = _lyricLibrary[index];
        _applyLibraryLyrics(entry, item);
        _lyricLibrary[index] = entry.copyWith(handled: {
          ...entry.handled,
          item.path: lyricStateSignature(_findItem(mediaId)!)
        }, excluded: entry.excluded.where((p) => p != item.path).toList());
        return '已为《${item.title}》关联歌词。';
      });

  Future<String> detachLyricEntry(String entryId, String path) =>
      _mutateLyricLibrary(() {
        _lyricLibrary = _lyricLibrary
            .map((entry) => entry.id != entryId
                ? entry
                : entry.copyWith(
                    handled: {...entry.handled}..remove(path),
                    excluded: {...entry.excluded, path}.toList()))
            .toList();
        return '已解除关联，当前歌曲歌词保留，不会再次自动关联该路径。';
      });

  Future<String> deleteLyricEntry(String entryId) => _mutateLyricLibrary(() {
        _lyricLibrary =
            _lyricLibrary.where((entry) => entry.id != entryId).toList();
        return '已删除歌词库记录，已应用到歌曲的歌词保留。可撤销本次操作。';
      });

  void _applyLibraryLyrics(LyricLibraryEntry entry, MediaItem item,
      {bool replaceLyrics = true}) {
    final updated = entry.apply(item, replaceLyrics: replaceLyrics);
    final changes = _lyricLibraryUndo?['changes'];
    if (changes is Map) {
      final previous = changes[item.id];
      changes[item.id] = {
        'path': item.path,
        'before': previous is Map
            ? previous['before']
            : {
                'lyrics': item.lyrics.map((e) => e.toJson()).toList(),
                'lyricTiming': item.lyricTiming.toJson(),
                'hasCustomLyrics': item.hasCustomLyrics,
                'title': item.title,
                'artist': item.artist,
                'album': item.album,
                'aliases': item.lyricMatchAliases,
              },
        'after': lyricStateSignature(updated),
      };
    }
    if (_lyricCalibration?.mediaId == item.id) _lyricCalibration = null;
    _replaceItem(updated);
  }

  int _applyPendingLyricLibrary({Set<String> newPaths = const {}}) {
    if (_lyricLibraryError != null || _lyricLibrary.isEmpty) return 0;
    final matches = <String, List<MediaItem>>{};
    final owners = <String, int>{};
    for (final entry in _lyricLibrary.where((e) => e.active)) {
      final targets =
          entry.candidates(_audioItems, fingerprints: _lyricFingerprints);
      matches[entry.id] = targets;
      if (targets.length == 1 &&
          !entry.excluded.contains(targets.single.path)) {
        owners.update(targets.single.id, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    var applied = 0;
    _lyricLibrary = _lyricLibrary.map((entry) {
      final targets = matches[entry.id] ?? const <MediaItem>[];
      if (targets.length != 1 || owners[targets.single.id] != 1) return entry;
      final item = _findItem(targets.single.id)!;
      if ((entry.handled.containsKey(item.path) &&
              !newPaths.contains(item.path)) ||
          entry.excluded.contains(item.path)) return entry;
      if (entry.overwrite || item.lyrics.isEmpty || entry.syncMetadata) {
        _applyLibraryLyrics(entry, item,
            replaceLyrics: entry.overwrite || item.lyrics.isEmpty);
        applied++;
        return entry.copyWith(handled: {
          ...entry.handled,
          item.path: lyricStateSignature(_findItem(item.id)!)
        });
      }
      return entry.copyWith(handled: {...entry.handled, item.path: 'skipped'});
    }).toList();
    if (applied > 0) lyricChanges.value++;
    return applied;
  }

  Future<String> _mutateLyricLibrary(String Function() action,
      {bool undo = false}) async {
    if (lyricLibraryBusy || _lyricLibraryError != null)
      throw StateError('请等待扫描/保存结束，或先处理歌词库错误。');
    _lyricLibraryBusy = true;
    final oldEntries = _lyricLibrary;
    final oldUndo = _lyricLibraryUndo;
    final oldMedia = {for (final item in _audioItems) item.id: item};
    Map<String, String> after = {};
    _notifyLyricLibrary();
    try {
      if (!undo)
        _lyricLibraryUndo = {
          'entries':
              oldEntries.map((entry) => entry.toJson(local: true)).toList(),
          'changes': <String, Object?>{},
        };
      final message = action();
      after = {
        for (final item in _audioItems) item.id: lyricStateSignature(item)
      };
      if (_lyricLibrary.length > lyricLibraryLimit ||
          utf8
                  .encode(jsonEncode(
                      _lyricLibrary.map((e) => e.toJson(local: true)).toList()))
                  .length >
              lyricPackageLimit ||
          utf8.encode(jsonEncode(_lyricLibraryUndo)).length >
              lyricPackageLimit) {
        throw StateError('歌词库或撤销记录超过限制（最多 5000 条 / 32 MiB），请先导出并清理历史记录。');
      }
      await _saveAuthoringLibrary();
      lyricChanges.value++;
      return message;
    } catch (_) {
      _lyricLibrary = oldEntries;
      _lyricLibraryUndo = oldUndo;
      for (final item in oldMedia.values) {
        final latest = _findItem(item.id);
        if (latest != null &&
            (after.isEmpty || after[item.id] == lyricStateSignature(latest))) {
          _replaceItem(latest.copyWith(
              lyrics: item.lyrics,
              lyricTiming: item.lyricTiming,
              title: item.title,
              artist: item.artist,
              album: item.album,
              lyricMatchAliases: item.lyricMatchAliases,
              hasCustomLyrics: item.hasCustomLyrics));
        }
      }
      rethrow;
    } finally {
      _lyricLibraryBusy = false;
      if (!_disposed) _notifyLyricLibrary();
    }
  }

  Future<String> undoLyricLibrary() => _mutateLyricLibrary(() {
        final undo = _lyricLibraryUndo;
        if (undo == null) throw StateError('没有可撤销的操作。');
        var skipped = 0;
        final restored = (undo['entries'] as List)
            .map((e) => LyricLibraryEntry.fromJson(
                Map<String, Object?>.from(e as Map),
                local: true))
            .toList();
        for (final change in (undo['changes'] as Map).entries) {
          final item = _findItem(change.key as String);
          final data = change.value as Map;
          if (item == null ||
              item.path != data['path'] ||
              lyricStateSignature(item) != data['after']) {
            skipped++;
            continue;
          }
          final before = data['before'] as Map;
          final lines = (before['lyrics'] as List)
              .map((e) =>
                  LyricLine.fromJson(Map<String, Object?>.from(e as Map)))
              .toList();
          _replaceItem(item.copyWith(
              lyrics: lines,
              title: before['title'] as String?,
              artist: before['artist'] as String?,
              album: before['album'] as String?,
              lyricMatchAliases: (before['aliases'] as List?)
                  ?.map((e) => Map<String, String>.from(e as Map))
                  .toList(),
              hasCustomLyrics: before['hasCustomLyrics'] == true,
              lyricTiming: LyricTiming.fromJson(before['lyricTiming'], lines)));
        }
        _lyricLibrary = restored;
        _lyricLibraryUndo = null;
        return '已撤销；$skipped 首已被后续修改或移除的歌曲未回退。';
      }, undo: true);

  Future<LyricsExportResult> exportLyricPackage() async {
    if (lyricLibraryBusy || _lyricLibraryError != null)
      throw StateError('当前无法导出，请等待操作结束。');
    _isExportingLyrics = true;
    _notifyLyricLibrary();
    try {
      final exportItems = _audioItems.where(_hasExportableLyrics).toList();
      final hashes = await LyricPackageRepository()
          .fingerprints(exportItems.take(5000).toList());
      final entries = <String, LyricLibraryEntry>{};
      final audioVersions = <String, String>{};
      for (final entry in _lyricLibrary.where((e) => e.active))
        entries[entry.matchKey] = entry;
      for (final item in exportItems) {
        // 已关联条目使用当前歌曲的正式歌词，避免携带后续编辑前的旧版本。
        entries.removeWhere((_, entry) =>
            entry.handled.containsKey(item.path) &&
            entry.handled[item.path] != 'skipped');
        final entry = LyricLibraryEntry.fromMedia(item,
            fingerprint: hashes[item.path] ?? '');
        final previousVersion = audioVersions[entry.matchKey];
        if (previousVersion != null &&
            previousVersion != entry.contentSignature) {
          throw StateError('《${item.title}》的同一音频存在不同歌词或展示信息，请先统一重复歌曲的版本后导出。');
        }
        audioVersions[entry.matchKey] = entry.contentSignature;
        entries[entry.matchKey] = entry;
      }
      final file = await compute(buildLyricPackage, entries.values.toList());
      final result = await _mediaLibraryRepository.exportLyrics(file);
      return result.status == LyricsExportStatus.completed
          ? LyricsExportResult(
              status: result.status,
              message: '已导出 ${file.count} 首歌词（含待匹配记录和单曲校准，不含音频及全局偏移）。'
                  '${exportItems.length > hashes.length ? '其中 ${exportItems.length - hashes.length} 首未取得文件指纹，将使用歌曲信息/别名匹配或手动关联。' : ''}')
          : result;
    } finally {
      _isExportingLyrics = false;
      if (!_disposed) _notifyLyricLibrary();
    }
  }
}
