part of 'app_state.dart';

/// 媒体库派生视图、分组查询与应用内检索。
extension MediaQueryState on LumioAppState {
  List<MediaItem> itemsForAlbum(String album) =>
      _audioIndex.byAlbum[album] ?? const <MediaItem>[];

  List<MediaItem> itemsForArtist(String artist) =>
      _audioIndex.byArtist[artist] ?? const <MediaItem>[];

  List<MediaItem> itemsForAudioFolder(String folder) =>
      _audioIndex.byFolder[folder] ?? const <MediaItem>[];

  List<MediaItem> itemsForPlaylist(Playlist playlist) {
    final index = _mediaById;
    return playlist.mediaIds
        .map((id) => index[id])
        .whereType<MediaItem>()
        .toList(growable: false);
  }

  List<MediaItem> search(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const <MediaItem>[];
    }
    var index = _searchIndex;
    if (index == null ||
        !identical(_searchIndexAudio, _audioItems) ||
        !identical(_searchIndexVideo, _videoItems)) {
      index = _SearchEntry.build(_audioItems, _videoItems);
      _searchIndex = index;
      _searchIndexAudio = _audioItems;
      _searchIndexVideo = _videoItems;
    }
    // 界面在每次重建时都会重新取结果，同一关键词配合同一版媒体库时直接复用。
    if (normalized == _searchCacheQuery &&
        identical(_searchCacheIndex, index)) {
      return _searchCacheResult!;
    }
    final result = <MediaItem>[
      for (final entry in index)
        if (entry.text.contains(normalized)) entry.item,
    ];
    _searchCacheQuery = normalized;
    _searchCacheIndex = index;
    _searchCacheResult = result;
    return result;
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

  Map<String, MediaItem> get _mediaById {
    final cached = _mediaByIdCache;
    if (cached != null &&
        identical(_mediaByIdAudio, _audioItems) &&
        identical(_mediaByIdVideo, _videoItems)) {
      return cached;
    }
    final index = <String, MediaItem>{
      for (final item in _audioItems) item.id: item,
      for (final item in _videoItems) item.id: item,
    };
    _mediaByIdCache = index;
    _mediaByIdAudio = _audioItems;
    _mediaByIdVideo = _videoItems;
    return index;
  }

  MediaItem? _findItem(String mediaId) => _mediaById[mediaId];

  List<MediaItem> _itemsForIds(List<String> ids) {
    final index = _mediaById;
    return List<MediaItem>.unmodifiable(
      ids.map((id) => index[id]).whereType<MediaItem>(),
    );
  }

  void _replaceItem(MediaItem updated) {
    if (_receivedMedia.containsKey(updated.id))
      _receivedMedia[updated.id] = updated;
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

  List<String> get recentSearches => List<String>.unmodifiable(_recentSearches);

  /// 记录一次实际使用的搜索词：去重（忽略大小写与首尾空格）、最新的排最前。
  void recordSearch(String query) {
    final value = query.trim();
    if (value.isEmpty || value.length > 80) return;
    final normalized = value.toLowerCase();
    // 已经在首位时不必重排，也避免每次搜索都写一次状态。
    if (_recentSearches.isNotEmpty &&
        _recentSearches.first.toLowerCase() == normalized) {
      return;
    }
    _recentSearches = <String>[
      value,
      ..._recentSearches.where((item) => item.toLowerCase() != normalized),
    ].take(LumioAppState.maxRecentSearches).toList(growable: false);
    _saveState();
    _notify();
  }

  void removeRecentSearch(String query) {
    final normalized = query.toLowerCase();
    if (!_recentSearches.any((item) => item.toLowerCase() == normalized)) {
      return;
    }
    _recentSearches = _recentSearches
        .where((item) => item.toLowerCase() != normalized)
        .toList(growable: false);
    _saveState();
    _notify();
  }

  void clearRecentSearches() {
    if (_recentSearches.isEmpty) return;
    _recentSearches = const <String>[];
    _saveState();
    _notify();
  }
}
