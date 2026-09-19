import '../models/media_item.dart';

class LyricCalibration {
  LyricCalibration(MediaItem item)
      : mediaId = item.id,
        title = item.title,
        lyrics = item.lyrics,
        signature = LyricTiming.signatureFor(item.lyrics),
        offsetMs = item.lyricTiming.offsetMs;

  final String mediaId;
  final String title;
  final List<LyricLine> lyrics;
  final String signature;
  int offsetMs;
  bool saving = false;
}

String describeLyricOffset(int milliseconds) {
  if (milliseconds == 0) return '无偏移';
  return '歌词${milliseconds > 0 ? '提前' : '延后'} ${(milliseconds.abs() / 1000).toStringAsFixed(3)} 秒';
}
