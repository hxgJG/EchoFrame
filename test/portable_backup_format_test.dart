import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/backup/portable_backup_format.dart';
import 'package:lumio/core/models/media_item.dart';

MediaItem item(String id, String path,
        {String title = '原曲名',
        String artist = '歌手',
        String? hash,
        bool pending = false}) =>
    MediaItem.fromJson({
      'id': id,
      'kind': 'audio',
      'path': path,
      'title': title,
      'artist': artist,
      'durationMs': 240000,
      'fileSizeBytes': 1234,
      if (pending) 'sourceId': portableMediaSource,
      'backupIdentity': {
        'key': 'a' * 32,
        'fileName': 'song.mp3',
        'fingerprint': hash ?? ''
      },
    });

void main() {
  test('同一文件指纹优先，歌曲改名和移动后仍能匹配', () {
    final saved = item('portable', 'lumio-backup://media/a',
        title: '修改后名称', hash: 'sha256:${'a' * 64}', pending: true);
    final local = item('android-1', '/new/location.mp3');
    final matches = matchPortableMedia(
        [saved], [local], {local.path: 'sha256:${'a' * 64}'});
    expect(matches[saved.id]?.id, local.id);
    final restored = bindPortableMedia(
        saved.copyWith(isFavorite: true, shuffleWeight: 6), local);
    expect(restored.title, '修改后名称');
    expect(restored.path, local.path);
    expect(restored.isFavorite, true);
    expect(restored.shuffleWeight, 6);
  });
  test('名称别名恢复且不依赖跨端路径', () {
    final saved =
        item('portable', 'lumio-backup://media/a', title: '新名字', pending: true)
            .copyWith(backupIdentity: {
      'key': 'a' * 32,
      'fileName': 'old.mp3',
      'fingerprint': ''
    }, lyricMatchAliases: [
      {'title': '原曲名', 'artist': '歌手', 'album': ''}
    ]);
    final local =
        item('android', '/music/new.mp3').copyWith(backupIdentity: {});
    expect(matchPortableMedia([saved], [local], {})[saved.id]?.id, local.id);
  });
  test('已知指纹冲突或候选重复不猜测', () {
    final saved = item('portable', 'lumio-backup://media/a',
        hash: 'sha256:${'a' * 64}', pending: true);
    final local = item('local', '/music/song.mp3');
    expect(
        matchPortableMedia(
            [saved], [local], {local.path: 'sha256:${'b' * 64}'}),
        isEmpty);
    expect(
        matchPortableMedia(
            [saved], [local, item('local2', '/music2/song.mp3')], {}),
        isEmpty);
    expect(
        matchPortableMedia(
            [saved, saved.copyWith(id: 'portable2')], [local], {}),
        isEmpty);
  });
  test('未知艺术家且缺少文件名和大小不弱匹配', () {
    final saved = item('portable', 'lumio-backup://media/a',
            artist: '未知艺术家', pending: true)
        .copyWith(fileSizeBytes: 0);
    expect(
        matchPortableMedia(
            [saved], [item('local', '/song.mp3', artist: '未知艺术家')], {}),
        isEmpty);
  });
}
