part of 'app_state.dart';

/// 主题、字幕外观、扫描范围与播放偏好等设置项。
extension SettingsState on LumioAppState {
  void selectSection(AppSection section) {
    if (_section == section) {
      return;
    }
    _section = section;
    _notify();
  }

  void setMusicSort(MusicSort sort) {
    if (_musicSort == sort) {
      return;
    }
    _musicSort = sort;
    _saveState();
    _notify();
  }

  void setSubtitleFontSize(double size) {
    _settings = _settings.copyWith(subtitleFontSize: size.clamp(12, 28));
    _saveState();
    _notify();
  }

  void setSubtitleTextColor(SubtitleTextColor color) {
    if (_settings.subtitleTextColor == color) {
      return;
    }
    _settings = _settings.copyWith(subtitleTextColor: color);
    _saveState();
    _notify();
  }

  void setSubtitlePosition(SubtitlePosition position) {
    if (_settings.subtitlePosition == position) {
      return;
    }
    _settings = _settings.copyWith(subtitlePosition: position);
    _saveState();
    _notify();
  }

  void setVideoScaleMode(VideoScaleMode mode) {
    if (_settings.videoScaleMode == mode) {
      return;
    }
    _settings = _settings.copyWith(videoScaleMode: mode);
    _saveState();
    _notify();
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
    _notify();
  }

  void removeIncludedFolder(String folder) {
    _settings = _settings.copyWith(
      includedFolders: _settings.includedFolders
          .where((value) => value != folder)
          .toList(growable: false),
    );
    _libraryStatusMessage = '已更新扫描包含文件夹，下次扫描会按新规则生效。';
    _saveState();
    _notify();
  }

  void setThemeMode(ThemeMode mode) {
    _settings = _settings.copyWith(themeMode: mode);
    _saveState();
    _notify();
  }

  void setLyricSpectrumEnabled(bool enabled, {bool desktop = false}) {
    _settings = desktop
        ? _settings.copyWith(desktopSpectrumEnabled: enabled)
        : _settings.copyWith(lyricSpectrumEnabled: enabled);
    _saveState();
    _notify();
  }

  void setSpectrumColorStyle(SpectrumColorStyle style) {
    if (_settings.spectrumColorStyle == style) return;
    _settings = _settings.copyWith(spectrumColorStyle: style);
    _saveState();
    _notify();
  }

  void setThemeId(String id) {
    if (_settings.themeId == id) return;
    _settings = _settings.copyWith(themeId: id);
    _saveState();
    _notify();
  }

  void toggleOnlineEnhancement(bool value) {
    _settings = _settings.copyWith(allowOnlineEnhancement: value);
    _saveState();
    _notify();
    final item = _currentItem;
    if (value && item != null) {
      unawaited(_loadOnlineEnhancement(item));
    }
  }

  void toggleDynamicColor(bool value) {
    _settings = _settings.copyWith(dynamicColor: value);
    _saveState();
    _notify();
  }

  void toggleCrossfade(bool enabled) {
    _settings = _settings.withCrossfadeEnabled(enabled);
    _playbackRepository.setCrossfadeDuration(
      Duration(seconds: _settings.crossfadeSeconds),
    );
    _saveState();
    _notify();
  }

  void setThemeAccent(ThemeAccent accent) {
    if (_settings.themeAccent == accent) {
      return;
    }
    _settings = _settings.copyWith(themeAccent: accent);
    _saveState();
    _notify();
  }

  void setMusicViewMode(MusicViewMode mode) {
    if (_settings.musicViewMode == mode) {
      return;
    }
    _settings = _settings.copyWith(musicViewMode: mode);
    _saveState();
    _notify();
  }

  void setDefaultPlaybackView(PlaybackView view) {
    _settings = _settings.copyWith(defaultPlaybackView: view);
    _playbackView = view;
    _saveState();
    _notify();
  }

  void adjustLyricOffset(Duration delta) {
    final next = _settings.lyricOffset + delta;
    _settings = _settings.copyWith(
      lyricOffset: Duration(
        milliseconds: next.inMilliseconds.clamp(-10000, 10000),
      ),
    );
    _saveState();
    _notify();
  }

  void setMinimumAudioDuration(Duration duration) {
    _settings = _settings.copyWith(
      minimumAudioDuration: Duration(
        seconds: duration.inSeconds.clamp(0, 600),
      ),
    );
    _libraryStatusMessage = '扫描过滤已更新，下次扫描会按新规则生效。';
    _saveState();
    _notify();
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
    _notify();
  }

  void removeExcludedFolder(String folder) {
    _settings = _settings.copyWith(
      excludedFolders: _settings.excludedFolders
          .where((value) => value != folder)
          .toList(growable: false),
    );
    _libraryStatusMessage = '已更新排除文件夹，下次扫描会按新规则生效。';
    _saveState();
    _notify();
  }

  String subtitleSignature(MediaItem item) {
    final value = jsonEncode(
        [item.subtitles.map((e) => e.toJson()).toList(), item.subtitleState]);
    var hash = 0x811c9dc5;
    for (final code in value.codeUnits) {
      hash = ((hash ^ code) * 0x01000193) & 0xffffffff;
    }
    return '${value.length}:${hash.toRadixString(16)}';
  }

  Future<String> applyWorkbenchSubtitles(
      Map<String, dynamic> binding, List<SubtitleCue> cues,
      {String origin = 'edited', String sourceName = ''}) async {
    if (!platformCapabilities.supportsSubtitleEditing)
      throw UnsupportedError('仅桌面端支持字幕编辑');
    final id = binding['mediaId'] as String;
    final previous = _findItem(id);
    if (previous == null ||
        previous.path != binding['path'] ||
        subtitleSignature(previous) != binding['signature']) {
      throw StateError('媒体已移动、删除或字幕已更新，请从视频重新打开工作台。当前草稿会保留。');
    }
    if (previous.subtitleState.isNotEmpty &&
        previous.subtitleState['version'] != 1)
      throw StateError('不支持的字幕数据版本，未覆盖。');
    final updated = previous.copyWith(subtitles: cues, subtitleState: {
      'version': 1,
      'revision': (previous.subtitleState['revision'] as int? ?? 0) + 1,
      'origin': origin == 'sidecar' ? 'sidecar' : 'edited',
      'sourceName': sourceName,
      'visible': previous.subtitleState['visible'] ?? true,
    });
    _replaceItem(updated);
    try {
      await _saveAuthoringLibrary();
    } catch (_) {
      final latest = _findItem(id);
      if (latest != null && identical(latest.subtitles, cues))
        _replaceItem(latest.copyWith(
            subtitles: previous.subtitles,
            subtitleState: previous.subtitleState));
      rethrow;
    }
    _notify();
    return subtitleSignature(updated);
  }

  Future<void> setVideoSubtitlesVisible(String id, bool visible) async {
    if (!platformCapabilities.supportsSubtitleEditing) return;
    final item = _findItem(id);
    if (item == null) return;
    if (item.subtitleState.isNotEmpty && item.subtitleState['version'] != 1)
      throw StateError('不支持的字幕数据版本');
    final metadata = {...item.subtitleState, 'version': 1, 'visible': visible};
    _replaceItem(item.copyWith(subtitleState: metadata));
    try {
      await _saveAuthoringLibrary();
    } catch (_) {
      final latest = _findItem(id);
      if (latest != null && identical(latest.subtitleState, metadata))
        _replaceItem(latest.copyWith(subtitleState: item.subtitleState));
      rethrow;
    }
    _notify();
  }

  void _syncSpectrum() => audioSpectrum.updatePlayback(
        playing: _isPlaying && _currentItem?.kind == MediaKind.audio,
        mediaId: _currentItem?.id,
      );
}
