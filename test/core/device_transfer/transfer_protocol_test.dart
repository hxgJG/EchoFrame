import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/device_transfer/transfer_protocol.dart';

import '../../support/transfer_fixtures.dart';

void main() {
  test('一批逻辑资源不能超过 500 个', () {
    expect(
        () => TransferManifest(List.generate(501, (_) => transferResource())),
        throwsA(isA<TransferException>()));
    expect(
        TransferManifest(List.generate(500, (_) => transferResource()))
            .resources
            .length,
        500);
  });
  test('清单仅序列化允许的展示信息，往返保持版本', () {
    final resource = transferResource(title: '天地龙鳞');
    final bytes = TransferManifest([resource]).encode();
    final result = TransferManifest.decode(bytes).resources.single;
    expect(result.revision, resource.revision);
    expect(result.metadata.title, '天地龙鳞');
    expect(
        jsonDecode(utf8.decode(bytes))['resources'][0].keys,
        unorderedEquals([
          'id',
          'kind',
          'byteLength',
          'sha256',
          'extension',
          'metadata',
          'attachmentIds'
        ]));
  });

  test('拒绝协议降级、错误 UTF-8、超限数据及非整数版本', () {
    for (final bytes in <List<int>>[
      utf8.encode('{"version":2,"resources":[]}'),
      [255],
      List.filled(TransferLimits.manifestBytes + 1, 32),
      utf8.encode('{"version":1.0,"resources":[]}'),
    ]) {
      expect(() => TransferManifest.decode(bytes),
          throwsA(isA<TransferException>()));
    }
  });

  test('拒绝负数/浮点长度、路径型 ID、任意扩展名', () {
    final resource = transferResource();
    for (final update in [
      {'byteLength': -1},
      {'byteLength': 3.5},
      {'id': '../../secret'},
      {'extension': '../mp3'},
      {'sha256': '123'},
      {'kind': 'directory'},
    ]) {
      expect(() => TransferResource.fromJson({...resource.toJson(), ...update}),
          throwsA(isA<TransferException>()));
    }
  });

  test('拒绝重复 ID、丢失/循环附件与未受限附件种类', () {
    final resource = transferResource();
    expect(() => TransferManifest([resource, resource]),
        throwsA(isA<TransferException>()));
    expect(
        () => TransferManifest([
              transferResource(attachments: [newTransferId()])
            ]),
        throwsA(isA<TransferException>()));
    expect(
        () => TransferManifest([
              resource,
              transferResource(attachments: [resource.id])
            ]),
        throwsA(isA<TransferException>()));
  });

  test('名称变化会改变版本但不改变内容指纹，别名不可变', () {
    final resource = transferResource();
    final aliases = [
      {'title': '原歌名', 'artist': '歌手', 'album': '专辑'}
    ];
    final metadata = TransferDisplayMetadata(title: '新歌名', aliases: aliases);
    aliases[0]['title'] = '被修改';
    final changed = TransferResource.fromJson(
        {...resource.toJson(), 'metadata': metadata.toJson()});
    expect(changed.revision, isNot(resource.revision));
    expect(changed.sha256Digest, resource.sha256Digest);
    expect(changed.metadata.aliases.single['title'], '原歌名');
  });

  test('大视频长度使用完整整数，不沿用歌词 512 MiB 上限', () {
    final json = transferResource(kind: TransferResourceKind.video).toJson();
    expect(
        TransferResource.fromJson(
            {...json, 'byteLength': 8 * 1024 * 1024 * 1024}).byteLength,
        8 * 1024 * 1024 * 1024);
  });
}
