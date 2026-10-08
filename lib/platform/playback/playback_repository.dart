import '../../core/models/media_item.dart';

enum PlaybackEventType {
  completed,
  error,
  videoTextureChanged,
  videoAspectRatioChanged,
  play,
  pause,
  toggle,
  next,
  previous,
  interruptionBegan,
  interruptionEnded,
  pictureInPictureChanged,
  mediaItemChanged,
  nativePlaybackStateChanged,
}

class PlaybackEvent {
  const PlaybackEvent({
    required this.type,
    this.mediaId,
    this.message = '',
    this.videoTextureId,
    this.videoAspectRatio,
    this.mayResume = false,
    this.isInPictureInPicture = false,
    this.isPlaying = false,
    this.restarted = false,
  });

  final PlaybackEventType type;
  final String? mediaId;
  final String message;
  final int? videoTextureId;
  final double? videoAspectRatio;
  final bool mayResume;
  final bool isInPictureInPicture;
  final bool isPlaying;
  final bool restarted;
}

abstract class PlaybackRepository {
  Stream<PlaybackEvent> get events;

  int? get videoTextureId;

  Future<void> play(
    MediaItem item,
    Duration position, {
    List<MediaItem> queue = const <MediaItem>[],
  });

  Future<void> pause();

  Future<void> resume();

  Future<void> seek(Duration position);

  Future<void> setSpeed(double speed);

  Future<void> setEqualizerPreset(
    String presetName, {
    List<double> customGains = const <double>[],
  });

  Future<void> setVolumeScale(double scale);

  Future<void> setCrossfadeDuration(Duration duration);

  Future<void> setShuffleEnabled(bool enabled);

  Future<void> setShuffleWeights(Map<String, int> weights);

  Future<void> setRepeatMode(RepeatMode mode);

  Future<void> stop();

  Future<Duration> position();

  Future<void> enterPictureInPicture();

  Future<double?> adjustBrightness(double delta);

  Future<double?> adjustVolume(double delta);

  Future<void> setVideoFullscreen(bool enabled);

  Future<void> share(MediaItem item);

  Future<void> shareMany(List<MediaItem> items);
}
