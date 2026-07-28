import '../../core/models/media_item.dart';

enum PlaybackEventType {
  completed,
  error,
  videoTextureChanged,
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
    this.mayResume = false,
    this.isInPictureInPicture = false,
    this.isPlaying = false,
  });

  final PlaybackEventType type;
  final String? mediaId;
  final String message;
  final int? videoTextureId;
  final bool mayResume;
  final bool isInPictureInPicture;
  final bool isPlaying;
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

  Future<void> setRepeatMode(RepeatMode mode);

  Future<void> stop();

  Future<Duration> position();

  Future<void> enterPictureInPicture();

  Future<void> adjustBrightness(double delta);

  Future<void> adjustVolume(double delta);

  Future<void> share(MediaItem item);

  Future<void> shareMany(List<MediaItem> items);
}
