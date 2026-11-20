part of 'app_state.dart';

/// 持久播放列表的增删改与排序。
extension PlaylistState on LumioAppState {
  void createPlaylist(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final playlist = Playlist(
      id: 'playlist-${now.microsecondsSinceEpoch}',
      name: trimmed,
      description: '自定义播放列表',
      mediaIds: const <String>[],
      updatedAt: now,
    );
    _playlists = <Playlist>[playlist, ..._playlists];
    _savePlaylists();
    _notify();
  }

  void renamePlaylist(String playlistId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _playlists = _playlists
        .map(
          (playlist) => playlist.id == playlistId
              ? playlist.copyWith(name: trimmed, updatedAt: DateTime.now())
              : playlist,
        )
        .toList(growable: false);
    _savePlaylists();
    _notify();
  }

  void deletePlaylist(String playlistId) {
    _playlists = _playlists
        .where((playlist) => playlist.id != playlistId)
        .toList(growable: false);
    _savePlaylists();
    _notify();
  }

  void addToPlaylist(String playlistId, String mediaId) {
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId || playlist.mediaIds.contains(mediaId)) {
        return playlist;
      }
      return playlist.copyWith(
        mediaIds: <String>[...playlist.mediaIds, mediaId],
        updatedAt: DateTime.now(),
      );
    }).toList(growable: false);
    _savePlaylists();
    _notify();
  }

  void addManyToPlaylist(String playlistId, Iterable<String> mediaIds) {
    final validIds = mediaIds.where((id) => _findItem(id) != null).toSet();
    if (validIds.isEmpty) {
      return;
    }
    var changed = false;
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      final nextIds = <String>{...playlist.mediaIds, ...validIds}.toList();
      if (nextIds.length == playlist.mediaIds.length) {
        return playlist;
      }
      changed = true;
      return playlist.copyWith(mediaIds: nextIds, updatedAt: DateTime.now());
    }).toList(growable: false);
    if (!changed) {
      return;
    }
    _savePlaylists();
    _notify();
  }

  void removeFromPlaylist(String playlistId, String mediaId) {
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      return playlist.copyWith(
        mediaIds: playlist.mediaIds
            .where((id) => id != mediaId)
            .toList(growable: false),
        updatedAt: DateTime.now(),
      );
    }).toList(growable: false);
    _savePlaylists();
    _notify();
  }

  void removeManyFromPlaylist(String playlistId, Iterable<String> mediaIds) {
    final idsToRemove = mediaIds.toSet();
    if (idsToRemove.isEmpty) {
      return;
    }
    var changed = false;
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      final nextIds = playlist.mediaIds
          .where((id) => !idsToRemove.contains(id))
          .toList(growable: false);
      if (nextIds.length == playlist.mediaIds.length) {
        return playlist;
      }
      changed = true;
      return playlist.copyWith(mediaIds: nextIds, updatedAt: DateTime.now());
    }).toList(growable: false);
    if (!changed) {
      return;
    }
    _savePlaylists();
    _notify();
  }

  void reorderPlaylistItems(String playlistId, int oldIndex, int newIndex) {
    _playlists = _playlists.map((playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      final mediaIds = List<String>.from(playlist.mediaIds);
      if (!_canReorder(mediaIds, oldIndex, newIndex)) {
        return playlist;
      }
      _reorder(mediaIds, oldIndex, newIndex);
      return playlist.copyWith(mediaIds: mediaIds, updatedAt: DateTime.now());
    }).toList(growable: false);
    _savePlaylists();
    _notify();
  }
}
