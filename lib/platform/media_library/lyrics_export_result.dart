enum LyricsExportStatus { completed, cancelled, unsupported, failed }

class LyricsExportResult {
  const LyricsExportResult({required this.status, this.message = ''});
  final LyricsExportStatus status;
  final String message;

  factory LyricsExportResult.fromJson(Map<Object?, Object?> json) =>
      LyricsExportResult(
        status: LyricsExportStatus.values.firstWhere(
            (value) => value.name == json['status'],
            orElse: () => LyricsExportStatus.failed),
        message: json['message']?.toString() ?? '',
      );
}
