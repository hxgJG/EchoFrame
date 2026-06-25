class AppBackupInfo {
  const AppBackupInfo({
    required this.path,
    required this.updatedAt,
  });

  final String path;
  final DateTime updatedAt;
}

abstract class AppStorageRepository {
  Future<Map<String, Object?>?> load();

  Future<void> save(Map<String, Object?> value);

  Future<AppBackupInfo?> createBackup(Map<String, Object?> value);

  Future<Map<String, Object?>?> restoreLatestBackup();

  Future<AppBackupInfo?> latestBackup();
}
