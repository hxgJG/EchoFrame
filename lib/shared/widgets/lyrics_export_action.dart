import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../platform/media_library/lyrics_export_result.dart';

Future<void> runLyricsExport(BuildContext context, LumioAppState state,
    {String? mediaId}) async {
  final result = await state.exportLyrics(mediaId: mediaId);
  if (!context.mounted || result.status == LyricsExportStatus.cancelled) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(result.message)));
}
