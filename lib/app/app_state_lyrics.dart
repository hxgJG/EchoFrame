part of 'app_state.dart';

/// 歌词高亮、校准、打轴与桌面歌词同步。
extension LyricsState on LumioAppState {
  void _desktopLyricsChanged() => _notify();

  void attachLyricView() {
    _lyricViewCount++;
    _reconcileLyricUpdates();
  }

  void detachLyricView() {
    _lyricViewCount = max(0, _lyricViewCount - 1);
    if (!_disposed) _reconcileLyricUpdates();
  }

  bool isLyricCalibrationValid(LyricCalibration draft) {
    final item = _currentItem;
    return identical(_lyricCalibration, draft) &&
        item?.id == draft.mediaId &&
        (identical(item!.lyrics, draft.lyrics) ||
            LyricTiming.signatureFor(item.lyrics) == draft.signature);
  }

  LyricCalibration? beginLyricCalibration() {
    final item = _currentItem;
    if (_lyricCalibration != null ||
        item == null ||
        item.kind != MediaKind.audio ||
        item.lyrics.isEmpty) return null;
    final draft = LyricCalibration(item);
    _lyricCalibration = draft;
    _reconcileLyricUpdates();
    return draft;
  }

  bool previewLyricOffset(LyricCalibration draft, int milliseconds) {
    if (!isLyricCalibrationValid(draft) ||
        draft.saving ||
        milliseconds.abs() > LyricTiming.limitMs) return false;
    draft.offsetMs = milliseconds;
    lyricChanges.value++;
    _syncDesktopLyrics();
    return true;
  }

  Future<String?> alignLyricToNow(LyricCalibration draft, int index) async {
    if (!_isPlaying) return '请先开始播放，再对齐这一句。';
    if (!isLyricCalibrationValid(draft) ||
        draft.saving ||
        index < 0 ||
        index >= draft.lyrics.length) return '歌曲或歌词已变化，请重新校准。';
    final epoch = _playbackEpoch;
    try {
      final position = await _playbackRepository
          .position()
          .timeout(const Duration(seconds: 2));
      if (_disposed ||
          epoch != _playbackEpoch ||
          !isLyricCalibrationValid(draft)) {
        return '播放状态已变化，请重新对齐。';
      }
      final offset =
          (draft.lyrics[index].time - position - _settings.lyricOffset)
              .inMilliseconds;
      if (offset.abs() > LyricTiming.limitMs)
        return '超出 ±30 秒范围，请确认选中的歌词和歌曲版本。';
      return previewLyricOffset(draft, offset) ? null : '校准状态已变化，请重试。';
    } catch (_) {
      return '读取播放进度失败，请重试。';
    }
  }

  void cancelLyricCalibration(LyricCalibration draft) {
    if (!identical(_lyricCalibration, draft)) return;
    _lyricCalibration = null;
    if (!_disposed) {
      _reconcileLyricUpdates();
      lyricChanges.value++;
      _syncDesktopLyrics();
    }
  }

  Future<String?> saveLyricCalibration(LyricCalibration draft) async {
    if (!isLyricCalibrationValid(draft) || draft.saving)
      return '歌曲或歌词已变化，请重新校准。';
    final item = _findItem(draft.mediaId);
    if (item == null) return '歌曲已不在媒体库中。';
    draft.saving = true;
    final timing =
        LyricTiming(offsetMs: draft.offsetMs, lyricsSignature: draft.signature);
    _replaceItem(item.copyWith(lyricTiming: timing));
    const partitions = {AppStoragePartition.library};
    try {
      final snapshot = _snapshotState(partitions: partitions);
      final storage = _appStorageRepository;
      if (storage is PlatformAppStorageRepository) {
        await storage.saveChecked(snapshot, partitions: partitions);
      } else {
        await storage.save(snapshot, partitions: partitions);
      }
      cancelLyricCalibration(draft);
      if (!_disposed) _notify();
      return null;
    } catch (_) {
      final latest = _findItem(draft.mediaId);
      if (latest != null && identical(latest.lyricTiming, timing)) {
        _replaceItem(latest.copyWith(lyricTiming: item.lyricTiming));
      }
      return '保存失败，调整尚未保存。请重试或取消。';
    } finally {
      draft.saving = false;
    }
  }

  void attachAuthoring() {
    _authoringViews++;
    _reconcileLyricUpdates();
  }

  void detachAuthoring() {
    if (_authoringViews > 0) _authoringViews--;
    _reconcileLyricUpdates();
  }

  MediaItem? authoringItem(String id) => _findItem(id);
  Future<LyricsImportResult> importAuthoringText() =>
      _mediaLibraryRepository.importLyricsText();

  Future<Duration> authoringPosition(String id) async {
    final epoch = _playbackEpoch;
    if (_currentItem?.id != id || !_isPlaying)
      throw StateError('请先播放正在制作歌词的歌曲。');
    final position = await _playbackRepository
        .position()
        .timeout(const Duration(seconds: 2));
    if (_currentItem?.id != id || !_isPlaying || epoch != _playbackEpoch)
      throw StateError('播放状态已变化，请重新标记。');
    return position;
  }

  Future<void> _saveAuthoringLibrary() async {
    const partitions = {AppStoragePartition.library};
    final snapshot = _snapshotState(partitions: partitions);
    final storage = _appStorageRepository;
    if (storage is PlatformAppStorageRepository) {
      await storage.saveChecked(snapshot, partitions: partitions);
    } else {
      await storage.save(snapshot, partitions: partitions);
    }
  }

  Future<void> saveLyricDraft(String id, LyricDraft draft) async {
    final item = _findItem(id);
    if (item == null) throw StateError('歌曲已不在媒体库中。');
    _replaceItem(item.copyWith(lyricDraft: draft));
    try {
      await _saveAuthoringLibrary();
    } catch (_) {
      final latest = _findItem(id);
      if (latest != null && identical(latest.lyricDraft, draft)) {
        _replaceItem(latest.copyWith(
            lyricDraft: item.lyricDraft,
            clearLyricDraft: item.lyricDraft == null));
      }
      rethrow;
    }
  }

  MediaItem _authoredItem(String id, LyricDraft draft) {
    final item = _findItem(id);
    if (item == null) throw StateError('歌曲已不在媒体库中。');
    final errors = draft.validate(item.duration);
    if (errors.isNotEmpty) throw FormatException(errors.join('\n'));
    return item.copyWith(
        lyrics: draft.lines
            .map((line) => LyricLine(
                time: Duration(milliseconds: line.timeMs!), text: line.text))
            .toList(),
        lyricTiming: const LyricTiming(),
        hasCustomLyrics: true,
        lyricDraft: draft);
  }

  Future<void> applyAuthoredLyrics(String id, LyricDraft draft,
      {String? expectedLyrics, int? expectedOffset}) async {
    final previous = _findItem(id);
    if (previous != null &&
        ((expectedLyrics != null &&
                LyricTiming.signatureFor(previous.lyrics) != expectedLyrics) ||
            (expectedOffset != null &&
                previous.lyricTiming.offsetMs != expectedOffset))) {
      throw StateError('正式歌词或校准已变化，请重新确认后应用。');
    }
    final updated = _authoredItem(id, draft);
    _replaceItem(updated);
    try {
      await _saveAuthoringLibrary();
    } catch (_) {
      final latest = _findItem(id);
      if (latest != null &&
          previous != null &&
          identical(latest.lyrics, updated.lyrics)) {
        _replaceItem(latest.copyWith(
            lyrics: previous.lyrics,
            lyricTiming: previous.lyricTiming,
            hasCustomLyrics: previous.hasCustomLyrics));
      }
      rethrow;
    }
    if (!_disposed) _notify();
  }

  Future<LyricsExportResult> exportAuthoredLyrics(
      String id, LyricDraft draft) async {
    if (_isExportingLyrics) throw StateError('请先完成当前导出。');
    final item = _authoredItem(id, draft);
    _isExportingLyrics = true;
    _notify();
    try {
      final file = await compute(buildLyricsExport, ([item], false));
      return await _mediaLibraryRepository.exportLyrics(file);
    } finally {
      _isExportingLyrics = false;
      if (!_disposed) _notify();
    }
  }

  void _reconcileLyricUpdates() {
    final draft = _lyricCalibration;
    if (draft != null && !isLyricCalibrationValid(draft)) {
      _lyricCalibration = null;
    }
    final audioActive = _isPlaying &&
        _currentItem?.kind == MediaKind.audio &&
        (_authoringViews > 0 ||
            ((_currentItem?.lyrics.isNotEmpty ?? false) &&
                (_lyricViewCount > 0 ||
                    desktopLyrics.enabled ||
                    _lyricCalibration != null)));
    final videoActive = _isPlaying &&
        platformCapabilities.supportsSubtitleEditing &&
        _currentItem?.kind == MediaKind.video &&
        (_currentItem?.subtitles.isNotEmpty ?? false);
    final active = audioActive || videoActive;
    if (active && _lyricTimer == null) {
      _lyricTimer = Timer.periodic(
          const Duration(milliseconds: 100), (_) => _tickHighlight());
    } else if (!active) {
      _lyricTimer?.cancel();
      _lyricTimer = null;
    }
  }

  void _syncDesktopLyrics() {
    if (!desktopLyrics.supported || !desktopLyrics.enabled) return;
    final item = _currentItem;
    final lines = item?.lyrics ?? const <LyricLine>[];
    final index = currentLyricIndex;
    final artist = item?.artist.trim() ?? '';
    final durationMs = item?.duration.inMilliseconds ?? 0;
    final progress = durationMs <= 0
        ? 0.0
        : (displayPosition.inMilliseconds / durationMs).clamp(0.0, 1.0);
    final title = item == null
        ? '忆光 · 桌面歌词'
        : artist.isEmpty || artist == '未知艺术家'
            ? item.title
            : '$artist · ${item.title}';
    final payload = <String, Object>{
      'audio': item == null || item.kind == MediaKind.audio,
      'title': title,
      'playing': _isPlaying,
      'progress': (progress * 1000).floor() / 1000,
      'spectrumEnabled': _settings.desktopSpectrumEnabled,
      'canControl': item?.kind == MediaKind.audio,
      'mediaId': item?.id ?? '',
      'canCalibrate': item?.kind == MediaKind.audio && lines.isNotEmpty,
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
    };
    // 歌词内容变化立即推送；只是进度推进时按 250ms 合并，避免以 10Hz 往返通道。
    final now = DateTime.now();
    final contentKey = <Object?>[
      payload['audio'],
      payload['title'],
      payload['playing'],
      payload['spectrumEnabled'],
      payload['canControl'],
      payload['mediaId'],
      payload['canCalibrate'],
      payload['current'],
      payload['next'],
    ].join('\u0000');
    final lastAt = _desktopLyricsPublishedAt;
    if (contentKey == _desktopLyricsContentKey &&
        lastAt != null &&
        now.difference(lastAt) < LumioAppState._desktopLyricsProgressInterval) {
      return;
    }
    _desktopLyricsContentKey = contentKey;
    _desktopLyricsPublishedAt = now;
    desktopLyrics.publish(payload);
  }

  bool _hasExportableLyrics(MediaItem item) =>
      item.kind == MediaKind.audio &&
      item.lyrics.any((line) => line.text.trim().isNotEmpty);

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
    final latest = _findItem(mediaId);
    if (latest == null) return result.copyWith(message: '歌曲已移除，未应用歌词。');
    if (_lyricCalibration?.mediaId == mediaId) _lyricCalibration = null;
    _replaceItem(
      latest.copyWith(
        lyrics: lyrics,
        lyricTiming: const LyricTiming(),
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
    _notify();
    return result.copyWith(
      message: '已为《${latest.title}》导入 ${lyrics.length} 行歌词，已重置本曲校准。',
    );
  }

  void removeLyrics(String mediaId) {
    if (_lyricCalibration?.mediaId == mediaId) _lyricCalibration = null;
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
    _notify();
  }

  Future<LyricsExportResult> exportLyrics({String? mediaId}) async {
    if (_isExportingLyrics) {
      return const LyricsExportResult(
          status: LyricsExportStatus.failed, message: '已有歌词正在导出，请先完成当前操作。');
    }
    final selected = mediaId == null ? null : _findItem(mediaId);
    final items = mediaId == null
        ? _audioItems.where(_hasExportableLyrics).toList(growable: false)
        : selected != null && _hasExportableLyrics(selected)
            ? [selected]
            : <MediaItem>[];
    if (items.isEmpty) {
      return const LyricsExportResult(
          status: LyricsExportStatus.failed, message: '没有可导出的歌词，请先导入 LRC 歌词。');
    }
    final skipped = mediaId == null ? _audioItems.length - items.length : 0;
    _isExportingLyrics = true;
    _notify();
    try {
      final file = await compute(buildLyricsExport, (items, mediaId == null));
      if (_disposed)
        return const LyricsExportResult(status: LyricsExportStatus.cancelled);
      final result = await _mediaLibraryRepository.exportLyrics(file);
      if (result.status != LyricsExportStatus.completed) return result;
      return LyricsExportResult(
          status: LyricsExportStatus.completed,
          message:
              '已导出 ${file.count} 首歌词${mediaId == null ? '（ZIP）' : '（LRC）'}，包含已保存的单曲校准。'
              '${skipped > 0 ? '已跳过 $skipped 首无歌词歌曲。' : ''}'
              '${file.clampedLines > 0 ? '${file.clampedLines} 行校准后早于零秒，已按 00:00.000 导出。' : ''}');
    } on FormatException catch (error) {
      return LyricsExportResult(
          status: LyricsExportStatus.failed, message: error.message);
    } catch (_) {
      return const LyricsExportResult(
          status: LyricsExportStatus.failed, message: '歌词导出失败，请重试。');
    } finally {
      _isExportingLyrics = false;
      if (!_disposed) _notify();
    }
  }
}
