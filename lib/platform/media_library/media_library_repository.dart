import '../../core/models/media_item.dart';

enum MediaLibraryScanStatus {
  completed,
  permissionDenied,
  unsupported,
  failed,
}

class MediaLibraryScanFilter {
  const MediaLibraryScanFilter({
    this.minimumAudioDuration = const Duration(seconds: 45),
    this.includedFolders = const <String>[],
    this.excludedFolders = const <String>[],
  });

  final Duration minimumAudioDuration;
  final List<String> includedFolders;
  final List<String> excludedFolders;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'minimumAudioDurationMs': minimumAudioDuration.inMilliseconds,
      'includedFolders': includedFolders,
      'excludedFolders': excludedFolders,
    };
  }
}

class MediaLibraryScanResult {
  const MediaLibraryScanResult({
    required this.status,
    this.audioItems = const <MediaItem>[],
    this.videoItems = const <MediaItem>[],
    this.message = '',
  });

  final MediaLibraryScanStatus status;
  final List<MediaItem> audioItems;
  final List<MediaItem> videoItems;
  final String message;

  bool get hasMedia => audioItems.isNotEmpty || videoItems.isNotEmpty;
}

abstract class MediaLibraryRepository {
  Future<MediaLibraryScanResult> scan(MediaLibraryScanFilter filter);

  Future<MediaLibraryScanResult> restoreLastScan();
}
