import '../../core/models/media_item.dart';
import 'media_file_operation.dart';

enum MediaLibraryScanStatus {
  completed,
  cancelled,
  permissionDenied,
  unsupported,
  failed,
}

class MediaSource {
  const MediaSource({
    required this.id,
    required this.displayName,
    required this.resolvedPath,
    required this.status,
    required this.readOnly,
  });

  factory MediaSource.fromJson(Map<Object?, Object?> json) {
    return MediaSource(
      id: json['id']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? '媒体文件夹',
      resolvedPath: json['resolvedPath']?.toString() ?? '',
      status: json['status']?.toString() ?? 'unavailable',
      readOnly: json['readOnly'] == true,
    );
  }

  final String id;
  final String displayName;
  final String resolvedPath;
  final String status;
  final bool readOnly;

  bool get isAvailable => status == 'available';
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
  Future<List<MediaSource>> addSources() async => const <MediaSource>[];

  Future<List<MediaSource>> listSources() async => const <MediaSource>[];

  Future<void> removeSource(String sourceId) async {}

  Future<void> cancelScan() async {}

  Future<MediaLibraryScanResult> scan(MediaLibraryScanFilter filter);

  Future<MediaLibraryScanResult> restoreLastScan();

  Future<MediaFileOperationResult> performFileOperation(
    MediaFileOperationRequest request,
  );
}
