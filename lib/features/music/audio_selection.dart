import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/models/media_item.dart';
import 'now_playing_page.dart';

void selectAudioItem(
  BuildContext context,
  LumioAppState state,
  MediaItem item,
) {
  if (item.kind == MediaKind.audio && state.currentItem?.id == item.id) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimatedBuilder(
          animation: state,
          builder: (context, _) => NowPlayingPage(state: state),
        ),
      ),
    );
    return;
  }
  state.play(item);
}
