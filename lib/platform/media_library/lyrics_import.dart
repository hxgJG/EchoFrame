enum LyricsImportStatus { completed, cancelled, unsupported, failed }

class LyricsImportResult {
  const LyricsImportResult({
    required this.status,
    this.fileName = '',
    this.lyricsText = '',
    this.message = '',
  });

  factory LyricsImportResult.fromJson(Map<Object?, Object?> json) {
    final statusName = json['status']?.toString() ?? 'failed';
    final status = LyricsImportStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () => LyricsImportStatus.failed,
    );
    return LyricsImportResult(
      status: status,
      fileName: json['fileName']?.toString() ?? '',
      lyricsText: json['lyricsText']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
    );
  }

  final LyricsImportStatus status;
  final String fileName;
  final String lyricsText;
  final String message;

  bool get didImport => status == LyricsImportStatus.completed;

  LyricsImportResult copyWith({
    LyricsImportStatus? status,
    String? fileName,
    String? lyricsText,
    String? message,
  }) {
    return LyricsImportResult(
      status: status ?? this.status,
      fileName: fileName ?? this.fileName,
      lyricsText: lyricsText ?? this.lyricsText,
      message: message ?? this.message,
    );
  }
}
