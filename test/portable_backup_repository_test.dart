import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/models/lumio_settings.dart';
import 'package:lumio/platform/app_storage/portable_backup_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String saved;
  late Map<String, Object?> snapshot;
  const name = '11111111111111111111111111111111.mp3';
  const id = 'transfer-22222222222222222222222222222222';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lumio-backup-test-');
    root = Directory(await root.resolveSymbolicLinks());
    await Directory('${root.path}/received').create();
    final path = '${root.path}/received/$name';
    await File(path).writeAsBytes(List.generate(200000, (i) => i % 251));
    final item = <String, Object?>{
      'id': id,
      'kind': 'audio',
      'path': path,
      'title': '修改后的名字',
      'artist': '歌手',
      'album': '专辑',
      'durationMs': 240000,
      'accentColor': 0xffaaddbb,
      'sourceId': 'lumio-received',
      'relativePath': name,
      'isFavorite': true,
      'shuffleWeight': 6,
      'lyrics': [
        {'timeMs': 1000, 'text': '备份歌词'}
      ],
      'lastPositionMs': 12345,
    };
    snapshot = {
      'schemaVersion': 2,
      'audioItems': [item],
      'videoItems': [],
      'playlists': [
        {
          'id': 'p1',
          'name': '我的歌单',
          'mediaIds': [id]
        }
      ],
      'settings': const LumioSettings().toJson(),
      'receivedMedia': {
        'version': 1,
        'items': [item],
        'digests': {},
        'applied': {}
      },
      'lyricLibrary': {'version': 1, 'entries': []},
      'currentItemId': id,
      'positionMs': 12345,
    };
    saved = '${root.path}/saved.zip';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PortableBackupRepository.channel,
            (call) async {
      switch (call.method) {
        case 'environment':
          return {
            'temporaryRoot': root.path,
            'managedRoots': [root.path],
            'receivedRoot': '${root.path}/received',
            'availableBytes': 8 * portableBackupLimit
          };
        case 'export':
          final source = File((call.arguments as Map)['path'] as String);
          await source.copy(saved);
          return saved;
        case 'import':
          final staging = await root.createTemp('import-');
          return (await File(saved).copy('${staging.path}/backup.zip')).path;
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PortableBackupRepository.channel, null);
    await root.delete(recursive: true);
  });

  test('流式备份往返保留媒体、歌词、权重、歌单和进度', () async {
    final repository = PortableBackupRepository();
    expect(await repository.export(snapshot, version: 1), saved);
    final preview = (await repository.select())!;
    expect(preview.audioCount, 1);
    expect(preview.playlistCount, 1);
    expect(preview.files.length, 1);
    expect(preview.state['positionMs'], 12345);
    final item = (preview.state['audioItems'] as List).single as Map;
    expect(item['title'], '修改后的名字');
    expect(item['isFavorite'], true);
    expect(item['shuffleWeight'], 6);
    expect((item['lyrics'] as List).single['text'], '备份歌词');
    final restored =
        File('${preview.directory.path}/${preview.files.single['name']}');
    expect(await restored.readAsBytes(),
        await File('${root.path}/received/$name').readAsBytes());
    await preview.directory.delete(recursive: true);
  });

  test('新版备份不打包任何媒体，统一引用可跨平台读取', () async {
    await PortableBackupRepository().export(snapshot);
    final archive = ZipDecoder().decodeBytes(await File(saved).readAsBytes());
    expect(archive.files.map((e) => e.name), ['lumio-backup.json']);
    final manifest =
        jsonDecode(utf8.decode(archive.files.single.content as List<int>))
            as Map;
    expect(manifest['version'], 2);
    manifest['platform'] = 'android';
    final metadata = utf8.encode(jsonEncode(manifest));
    final encoder = ZipFileEncoder()
      ..create(saved, level: ZipFileEncoder.STORE);
    encoder.addArchiveFile(
        ArchiveFile.noCompress('lumio-backup.json', metadata.length, metadata));
    encoder.closeSync();
    final preview = (await PortableBackupRepository().select())!;
    expect(preview.metadataOnly, true);
    expect(preview.files, isEmpty);
    final item = (preview.state['audioItems'] as List).single as Map;
    expect(item['path'], startsWith('lumio-backup://media/'));
    expect(jsonEncode(preview.state), isNot(contains(root.path)));
    expect(
        (preview.state['playlists'] as List).single['mediaIds'], [item['id']]);
    expect(preview.state['currentItemId'], item['id']);
    expect(item['shuffleWeight'], 6);
    await preview.directory.delete(recursive: true);
  });

  test('新版数据备份在真实媒体已缺失时仍保留元数据', () async {
    await File('${root.path}/received/$name').delete();
    await PortableBackupRepository().export(snapshot);
    final preview = (await PortableBackupRepository().select())!;
    expect(preview.files, isEmpty);
    expect(preview.audioCount, 1);
    await preview.directory.delete(recursive: true);
  });

  test('外部原文件仅保留索引，不打包', () async {
    (snapshot['audioItems'] as List).add({
      'id': 'external',
      'kind': 'audio',
      'path': '/external/song.mp3',
      'title': '外部歌曲',
      'lyrics': [],
      'accentColor': 0
    });
    await PortableBackupRepository().export(snapshot, version: 1);
    final preview = (await PortableBackupRepository().select())!;
    expect(preview.audioCount, 2);
    expect(preview.files.length, 1);
    await preview.directory.delete(recursive: true);
  });

  test('应用内媒体缺失时不导出不完整备份', () async {
    await File('${root.path}/received/$name').delete();
    await expectLater(PortableBackupRepository().export(snapshot, version: 1),
        throwsFormatException);
    expect(await File(saved).exists(), false);
  });

  test('媒体被篡改时拒绝导入并清理暂存', () async {
    await PortableBackupRepository().export(snapshot, version: 1);
    final archive = ZipDecoder().decodeBytes(await File(saved).readAsBytes());
    final output = ZipFileEncoder()..create(saved, level: ZipFileEncoder.STORE);
    for (final file in archive) {
      final bytes = List<int>.from(file.content as List);
      if (file.name.startsWith('media/')) bytes[0] ^= 1;
      output.addArchiveFile(ArchiveFile.noCompress(
          file.name, bytes.length, Uint8List.fromList(bytes)));
    }
    output.closeSync();
    await expectLater(
        PortableBackupRepository().select(), throwsFormatException);
    expect(
        root
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.split('/').last.startsWith('import-')),
        isEmpty);
  });

  test('拒绝危险 ZIP 路径和跨平台恢复', () async {
    final encoder = ZipFileEncoder()
      ..create(saved, level: ZipFileEncoder.STORE);
    encoder.addArchiveFile(
        ArchiveFile.noCompress('../outside', 1, Uint8List.fromList([1])));
    encoder.closeSync();
    await expectLater(
        PortableBackupRepository().select(), throwsFormatException);
    final metadata = utf8.encode(jsonEncode({
      'format': 'lumio-data-backup',
      'version': 1,
      'platform': 'unsupported-platform',
      'state': snapshot,
      'files': []
    }));
    final other = ZipFileEncoder()..create(saved, level: ZipFileEncoder.STORE);
    other.addArchiveFile(
        ArchiveFile.noCompress('lumio-backup.json', metadata.length, metadata));
    other.closeSync();
    await expectLater(
        PortableBackupRepository().select(), throwsFormatException);
  });

  test('不允许导出指向应用目录外的接收媒体', () async {
    (((snapshot['receivedMedia'] as Map)['items'] as List).single
        as Map)['path'] = '/external/private.mp3';
    await expectLater(PortableBackupRepository().export(snapshot, version: 1),
        throwsFormatException);
  });
}
