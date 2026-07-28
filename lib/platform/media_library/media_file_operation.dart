enum MediaFileOperationType { rename, move, writeTags }

enum MediaFileOperationStatus { completed, cancelled, failed, unsupported }

class MediaFileOperationResult {
  const MediaFileOperationResult({
    required this.status,
    required this.message,
    this.affectedMediaIds = const <String>[],
  });

  factory MediaFileOperationResult.fromJson(Map<String, Object?> json) {
    final statusName = json['status']?.toString();
    return MediaFileOperationResult(
      status: MediaFileOperationStatus.values.firstWhere(
        (value) => value.name == statusName,
        orElse: () => MediaFileOperationStatus.failed,
      ),
      message: json['message']?.toString() ?? '',
      affectedMediaIds: switch (json['affectedMediaIds']) {
        final List<Object?> values =>
          values.map((value) => value.toString()).toList(growable: false),
        _ => const <String>[],
      },
    );
  }

  final MediaFileOperationStatus status;
  final String message;
  final List<String> affectedMediaIds;

  bool get didChangeFiles =>
      status == MediaFileOperationStatus.completed &&
      affectedMediaIds.isNotEmpty;
}

class MediaFileOperationRequest {
  const MediaFileOperationRequest._({
    required this.type,
    required this.mediaIds,
    this.displayName,
    this.relativePath,
    this.title,
    this.artist,
    this.album,
  });

  factory MediaFileOperationRequest.rename({
    required String mediaId,
    required String displayName,
  }) {
    return MediaFileOperationRequest._(
      type: MediaFileOperationType.rename,
      mediaIds: <String>[mediaId],
      displayName: displayName,
    );
  }

  factory MediaFileOperationRequest.move({
    required List<String> mediaIds,
    required String relativePath,
  }) {
    return MediaFileOperationRequest._(
      type: MediaFileOperationType.move,
      mediaIds: mediaIds,
      relativePath: relativePath,
    );
  }

  factory MediaFileOperationRequest.writeTags({
    required String mediaId,
    required String title,
    required String artist,
    required String album,
  }) {
    return MediaFileOperationRequest._(
      type: MediaFileOperationType.writeTags,
      mediaIds: <String>[mediaId],
      title: title,
      artist: artist,
      album: album,
    );
  }

  final MediaFileOperationType type;
  final List<String> mediaIds;
  final String? displayName;
  final String? relativePath;
  final String? title;
  final String? artist;
  final String? album;

  bool get requiresConfirmation => true;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'type': type.name,
      'mediaIds': mediaIds,
      if (displayName != null) 'displayName': displayName,
      if (normalizedRelativePath != null)
        'relativePath': normalizedRelativePath,
      if (title != null) 'title': title!.trim(),
      if (artist != null) 'artist': artist!.trim(),
      if (album != null) 'album': album!.trim(),
    };
  }

  String? get normalizedRelativePath {
    final value = relativePath?.trim();
    if (value == null || value.isEmpty || !_isSafeRelativePath(value)) {
      return null;
    }
    return value.endsWith('/') ? value : '$value/';
  }

  bool get isValid {
    if (mediaIds.isEmpty || mediaIds.any((id) => id.trim().isEmpty)) {
      return false;
    }
    return switch (type) {
      MediaFileOperationType.rename =>
        mediaIds.length == 1 && _isSafeDisplayName(displayName),
      MediaFileOperationType.move => normalizedRelativePath != null,
      MediaFileOperationType.writeTags => mediaIds.length == 1 &&
          <String?>[title, artist, album]
              .any((value) => value?.trim().isNotEmpty == true),
    };
  }

  static bool _isSafeDisplayName(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isNotEmpty &&
        normalized != '.' &&
        normalized != '..' &&
        !normalized.contains('/') &&
        !normalized.contains(r'\');
  }

  static bool _isSafeRelativePath(String value) {
    if (value.startsWith('/') || value.contains(r'\')) {
      return false;
    }
    final segments = value.split('/').where((segment) => segment.isNotEmpty);
    return segments.isNotEmpty &&
        segments.every((segment) => segment != '.' && segment != '..');
  }
}
