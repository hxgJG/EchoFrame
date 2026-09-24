import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/app/app_state.dart';
import 'package:lumio/core/lyrics/lyric_library.dart';
import 'package:lumio/core/models/media_item.dart';
import 'package:lumio/platform/app_storage/app_storage_repository.dart';
import 'package:lumio/platform/app_storage/platform_app_storage_repository.dart';
import 'package:lumio/platform/media_library/media_library_repository.dart';
import 'package:lumio/platform/media_library/media_file_operation.dart';
import 'package:lumio/platform/playback/playback_repository.dart';

MediaItem song(
        {String id = 'song',
        String title = '原歌名',
        String path = '/music/a.mp3',
        List<LyricLine> lyrics = const []}) =>
    MediaItem(
        id: id,
        kind: MediaKind.audio,
        title: title,
        artist: '歌手',
        album: '原专辑',
        duration: const Duration(seconds: 200),
        path: path,
        folder: '/music',
        addedAt: DateTime(2026),
        accentColor: Colors.green,
        fileSizeBytes: 1234,
        lyrics: lyrics);
const lines = [
  LyricLine(time: Duration(seconds: 2), text: '第一句'),
  LyricLine(time: Duration(seconds: 4), text: '第二句')
];
final hash = 'sha256:${List.filled(64, 'a').join()}';
LyricLibraryEntry entry({bool overwrite = true, bool metadata = true}) =>
    LyricLibraryEntry.fromMedia(
            song(title: '新歌名', lyrics: lines).copyWith(
                album: '新专辑',
                lyricMatchAliases: [
                  {'title': '原歌名', 'artist': '歌手', 'album': '原专辑'}
                ],
                lyricTiming: LyricTiming(
                    offsetMs: -500,
                    lyricsSignature: LyricTiming.signatureFor(lines))),
            fingerprint: hash)
        .copyWith(overwrite: overwrite, syncMetadata: metadata);

class MemoryStorage extends AppStorageRepository {
  Map<String, Object?> data = {
    'audioItems': <Object?>[],
    'videoItems': <Object?>[]
  };
  bool fail = false;
  @override
  Future<Map<String, Object?>?> load() async =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(data)) as Map);
  @override
  Future<void> save(Map<String, Object?> value,
      {required Set<AppStoragePartition> partitions}) async {
    if (fail) throw StateError('disk full');
    for (final part in partitions)
      data.addAll(Map<String, Object?>.from(
          jsonDecode(jsonEncode(appStoragePartitionValue(value, part)))
              as Map));
  }

  @override
  Future<AppBackupInfo?> createBackup(Map<String, Object?> value) async => null;
  @override
  Future<Map<String, Object?>?> restoreLatestBackup() async => null;
  @override
  Future<AppBackupInfo?> latestBackup() async => null;
}

class Scanner extends MediaLibraryRepository {
  List<MediaItem> items = [];
  @override
  Future<MediaLibraryScanResult> scan(MediaLibraryScanFilter filter) async =>
      MediaLibraryScanResult(
          status: MediaLibraryScanStatus.completed, audioItems: items);
  @override
  Future<MediaLibraryScanResult> restoreLastScan() =>
      scan(const MediaLibraryScanFilter());
  @override
  Future<MediaFileOperationResult> performFileOperation(
          MediaFileOperationRequest request) async =>
      const MediaFileOperationResult(
          status: MediaFileOperationStatus.unsupported, message: '');
}

class SilentPlayback implements PlaybackRepository {
  @override
  Stream<PlaybackEvent> get events => const Stream.empty();
  @override
  int? get videoTextureId => null;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName == #position
          ? Future.value(Duration.zero)
          : Future<void>.value();
}

Future<LumioAppState> createState(
    MemoryStorage storage, Scanner scanner) async {
  final state = LumioAppState(
      appStorageRepository: storage,
      mediaLibraryRepository: scanner,
      playbackRepository: SilentPlayback());
  for (var i = 0; i < 100 && state.lyricLibraryBusy; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(state.lyricLibraryBusy, false);
  return state;
}

Future<void> import(LumioAppState state, LyricLibraryEntry e,
    {bool overwrite = true, bool metadata = true}) async {
  await state.importLyricPackage(LyricPackagePreview([e], const [], 'test.zip'),
      overwrite: overwrite,
      syncMetadata: metadata,
      expectedContext: state.lyricImportContext);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumio/desktop_lyrics'),
            (_) async => {'enabled': false, 'locked': false});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumio/media_library'),
            (call) async {
      if (call.method == 'lyricAudioFingerprints')
        return {
          for (final item in (call.arguments as Map)['items'] as List)
            item['path']: hash
        };
      return null;
    });
  });
  test('新包往返保留原始毫秒、校准、别名和文件指纹；不导出本机绑定', () {
    final e = entry().copyWith(handled: {'/private/song.mp3': 'x'});
    final file = buildLyricPackage([e]);
    final decoded =
        decodeLyricPackage((file.bytes, file.fileName)).entries.single;
    expect(decoded.offsetMs, -500);
    expect(decoded.lyrics.first.time.inMilliseconds, 2000);
    expect(decoded.fingerprint, hash);
    expect(decoded.aliases.single['title'], '原歌名');
    expect(decoded.handled, isEmpty);
  });
  test('未知版本与伪造解压大小拒绝，不落盘解压', () {
    final data =
        utf8.encode('{"format":"lumio-lyrics","version":999,"entries":[]}');
    final future = Uint8List.fromList(ZipEncoder().encode(Archive()
      ..addFile(ArchiveFile('lumio-lyrics.json', data.length, data)))!);
    expect(() => decodeLyricPackage((future, 'future.zip')),
        throwsFormatException);
    final expanded = List<int>.filled(3 * 1024 * 1024, 65);
    final bomb = Uint8List.fromList(ZipEncoder().encode(Archive()
      ..addFile(ArchiveFile('bomb.lrc', expanded.length, expanded)))!);
    final view = ByteData.sublistView(bomb);
    for (var i = 0; i <= bomb.length - 28; i++) {
      if (view.getUint32(i, Endian.little) == 0x04034b50)
        view.setUint32(i + 22, 1, Endian.little);
      if (view.getUint32(i, Endian.little) == 0x02014b50)
        view.setUint32(i + 24, 1, Endian.little);
    }
    expect(() => decodeLyricPackage((bomb, 'bomb.zip')), throwsFormatException);
  });
  test('关闭歌词覆盖后重复导入仍可独立更新名字；关闭信息同步则保留本地名字', () async {
    final storage = MemoryStorage(), scanner = Scanner()..items = [song()];
    final state = await createState(storage, scanner);
    await state.scanMediaLibrary();
    await import(state, entry(), metadata: false);
    expect(state.audioItems.single.title, '原歌名');
    final changed = LyricLibraryEntry.fromMedia(
        song(
            title: '改名后的名字',
            lyrics: const [LyricLine(time: Duration.zero, text: '不应覆盖')]),
        fingerprint: hash);
    await import(state, changed, overwrite: false);
    expect(state.audioItems.single.title, '改名后的名字');
    expect(state.audioItems.single.lyrics.first.text, '第一句');
    expect(
        state.lyricLibraryEntries
            .where((e) => e.active)
            .single
            .lyrics
            .first
            .text,
        '第一句');
    state.dispose();
  });
  test('歌曲暂时移除后重新添加可再次匹配；解除关联后不再自动应用', () async {
    final storage = MemoryStorage(), scanner = Scanner()..items = [song()];
    final state = await createState(storage, scanner);
    await state.scanMediaLibrary();
    await import(state, entry());
    scanner.items = [];
    await state.scanMediaLibrary();
    scanner.items = [song()];
    await state.scanMediaLibrary();
    expect(state.audioItems.single.lyrics, isNotEmpty);
    await state.detachLyricEntry(
        state.lyricLibraryEntries.single.id, song().path);
    scanner.items = [];
    await state.scanMediaLibrary();
    scanner.items = [song()];
    await state.scanMediaLibrary();
    expect(state.audioItems.single.lyrics, isEmpty);
    expect(state.audioItems.single.title, '原歌名');
    state.dispose();
  });
  test('文件指纹优先，名称和路径均改变仍能匹配；重复文件不猜测', () {
    final target = song(title: '完全不同的名字', path: '/other/renamed.mp3');
    expect(entry().candidates([target], fingerprints: {target.path: hash}),
        [target]);
    expect(
        entry().candidates([target, song(id: 'copy')],
            fingerprints: {target.path: hash, '/music/a.mp3': hash}).length,
        2);
    expect(entry().candidates([song()]), hasLength(1));
  });
  test('展示信息与歌词替换独立，空字段不覆盖，原信息成为别名', () {
    final local =
        song(lyrics: const [LyricLine(time: Duration.zero, text: '本地')]);
    final changed = entry().apply(local, replaceLyrics: false);
    expect(changed.lyrics.first.text, '本地');
    expect(changed.title, '新歌名');
    expect(changed.album, '新专辑');
    expect(changed.lyricMatchAliases.first['title'], '原歌名');
    expect(entry(metadata: false).apply(local).title, '原歌名');
    final migrated = entry().apply(local.copyWith(title: '另一台设备的名字'));
    final exportedAgain = LyricLibraryEntry.fromMedia(migrated);
    expect(exportedAgain.aliases.map((e) => e['title']),
        containsAll(['原歌名', '另一台设备的名字']));
  });
  test('旧 ZIP 解析有效 LRC，无时间/不安全路径拒绝', () {
    Uint8List zip(String name, String text) =>
        Uint8List.fromList(ZipEncoder().encode(Archive()
          ..addFile(ArchiveFile(
              name, utf8.encode(text).length, utf8.encode(text))))!);
    final preview = decodeLyricPackage(
        (zip('1 - test.lrc', '[ti:原歌名]\n[ar:歌手]\n[00:01.234]歌词'), 'old.zip'));
    expect(preview.entries.single.lyrics.single.time.inMilliseconds, 1234);
    expect(preview.warnings, isNotEmpty);
    expect(() => decodeLyricPackage((zip('../bad.lrc', '[00:01]a'), 'bad.zip')),
        throwsFormatException);
    expect(() => decodeLyricPackage((zip('bad.lrc', '没有时间'), 'bad.zip')),
        throwsFormatException);
  });
  test('先导入无歌曲设备，重启后再扫描：歌词、名字、艺术家和专辑自动应用', () async {
    final storage = MemoryStorage(), scanner = Scanner();
    var state = await createState(storage, scanner);
    await import(state, entry());
    expect(state.lyricLibraryEntries, hasLength(1));
    expect(state.audioItems, isEmpty);
    state.dispose();
    state = await createState(storage, scanner);
    scanner.items = [song()];
    await state.scanMediaLibrary();
    expect(state.audioItems.single.title, '新歌名');
    expect(state.audioItems.single.album, '新专辑');
    expect(state.audioItems.single.lyrics.first.text, '第一句');
    expect(state.audioItems.single.lyricTiming.offsetMs, -500);
    await state.undoLyricLibrary();
    expect(state.lyricLibraryEntries, isEmpty);
    expect(state.audioItems.single.title, '原歌名');
    expect(state.audioItems.single.lyrics, isEmpty);
    state.dispose();
  });
  test('关闭覆盖：后续添加的本地歌词保留，展示信息仍可独立同步', () async {
    final storage = MemoryStorage(), scanner = Scanner();
    final state = await createState(storage, scanner);
    await import(state, entry(), overwrite: false);
    scanner.items = [
      song(lyrics: const [LyricLine(time: Duration.zero, text: '本地')])
    ];
    await state.scanMediaLibrary();
    expect(state.audioItems.single.title, '新歌名');
    expect(state.audioItems.single.lyrics.first.text, '本地');
    state.dispose();
  });
  test('多版本等待手动匹配，手动关联可撤销；后续编辑不被自动覆盖', () async {
    final storage = MemoryStorage(),
        scanner = Scanner()
          ..items = [song(), song(id: 'other', path: '/music/b.mp3')];
    final state = await createState(storage, scanner);
    await state.scanMediaLibrary();
    await import(state, entry());
    expect(state.audioItems.every((e) => e.lyrics.isEmpty), true);
    final id = state.lyricLibraryEntries.single.id;
    await state.associateLyricEntry(id, 'song', overwrite: true);
    expect(state.audioItems.firstWhere((e) => e.id == 'song').title, '新歌名');
    state.updateMediaMetadata('song', title: '再次修改');
    await state.undoLyricLibrary();
    expect(state.audioItems.firstWhere((e) => e.id == 'song').title, '再次修改');
    state.dispose();
  });
  test('保存失败回滚；新包保留旧版本；同包重复导入去重', () async {
    final storage = MemoryStorage(), scanner = Scanner()..items = [song()];
    final state = await createState(storage, scanner);
    await state.scanMediaLibrary();
    storage.fail = true;
    await expectLater(import(state, entry()), throwsStateError);
    expect(state.lyricLibraryEntries, isEmpty);
    expect(state.audioItems.single.title, '原歌名');
    storage.fail = false;
    await import(state, entry());
    await import(state, entry());
    expect(state.lyricLibraryEntries, hasLength(1));
    final changed = LyricLibraryEntry.fromMedia(
        song(title: '第三版', lyrics: lines),
        fingerprint: hash);
    await import(state, changed);
    expect(state.lyricLibraryEntries, hasLength(2));
    expect(state.lyricLibraryEntries.where((e) => e.active), hasLength(1));
    state.dispose();
  });
}
