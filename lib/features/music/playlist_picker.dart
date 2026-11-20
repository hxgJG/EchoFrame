import 'package:flutter/material.dart';

import '../../app/app_state.dart';

/// 把媒体加入播放列表：没有歌单时先引导新建，返回被加入的歌单名。
Future<String?> showPlaylistPicker(
  BuildContext context,
  LumioAppState state,
  Iterable<String> mediaIds,
) async {
  final ids = mediaIds.toSet();
  if (ids.isEmpty) {
    return null;
  }
  if (state.playlists.isEmpty) {
    final name = await showPlaylistNameDialog(
      context,
      title: '新建播放列表',
      confirmLabel: '创建并加入',
    );
    if (name == null) {
      return null;
    }
    state.createPlaylist(name);
    final created = state.playlists.first;
    state.addManyToPlaylist(created.id, ids);
    return created.name;
  }

  final playlistId = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('加入播放列表'),
      children: state.playlists
          .map(
            (playlist) => SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(playlist.id),
              child: Text(playlist.name),
            ),
          )
          .toList(),
    ),
  );
  if (playlistId == null) {
    return null;
  }
  final playlist =
      state.playlists.firstWhere((value) => value.id == playlistId);
  state.addManyToPlaylist(playlist.id, ids);
  return playlist.name;
}

Future<String?> showPlaylistNameDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
}) async {
  final controller = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '例如：通勤歌单'),
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
