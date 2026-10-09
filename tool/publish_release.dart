import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../lib/core/updates/release_config.dart';
import '../lib/core/updates/update_manifest.dart';
import 'prepare_release.dart' show run;

// Deliberately separate draft upload from publication. Never create a repository or overwrite an asset implicitly.
Future<void> main(List<String> args) async {
  if (args.length != 2 || !['draft', 'verify', 'publish'].contains(args.first))
    throw ArgumentError(
        '用法：dart run tool/publish_release.dart draft|verify|publish build/releases/v版本-构建号');
  final folder = Directory(args[1]);
  final raw = File('${folder.path}/update-manifest.json').readAsBytesSync();
  final sig = File('${folder.path}/update-manifest.sig').readAsStringSync();
  final manifest = await UpdateManifest.verify(raw, sig, updatePublicKey);
  final metadata = jsonDecode(utf8.decode(raw)) as Map;
  if (metadata['localPreview'] != false) throw StateError('不能发布本地预览附件。');
  if (metadata['sourceCommit'] != await run('git', ['rev-parse', 'HEAD']) ||
      (await run('git', ['status', '--porcelain'])).isNotEmpty)
    throw StateError('源码与准备包时的干净提交不一致，请重新构建。');
  final names = [
    ...manifest.packages.map((p) => p.fileName),
    'update-manifest.json',
    'update-manifest.sig',
    'RELEASE_NOTES.md',
    'INSTALL.md'
  ];
  for (final p in manifest.packages) {
    final file = File('${folder.path}/${p.fileName}');
    if (await file.length() != p.size ||
        (await sha256.bind(file.openRead()).first).toString() != p.sha256)
      throw StateError('本地安装包不匹配。');
  }
  final repo = jsonDecode(await run('gh', [
    'repo',
    'view',
    releaseRepository,
    '--json',
    'visibility,nameWithOwner'
  ])) as Map;
  if (repo['visibility'] != 'PUBLIC' ||
      repo['nameWithOwner'] != releaseRepository)
    throw StateError('发布仓库必须是指定公开仓库。');
  final tag = 'v${manifest.version}-${manifest.buildNumber}';
  if (args.first == 'draft') {
    final releases = jsonDecode(await run('gh', [
      'release',
      'list',
      '--repo',
      releaseRepository,
      '--limit',
      '100',
      '--json',
      'tagName'
    ])) as List;
    if (releases.any((e) => e['tagName'] == tag))
      throw StateError('此版本已存在；禁止覆盖同名附件。');
    final previous = releases
        .map((e) =>
            RegExp(r'^v[0-9.]+-([0-9]+)$').firstMatch(e['tagName'] as String))
        .whereType<RegExpMatch>()
        .map((e) => int.parse(e.group(1)!));
    if (previous.any((build) => build >= manifest.buildNumber))
      throw StateError('正式构建号必须递增。');
    await run('gh', [
      'release',
      'create',
      tag,
      '--repo',
      releaseRepository,
      '--draft',
      '--title',
      'Lumio ${manifest.version}（${manifest.buildNumber}）',
      '--notes-file',
      '${folder.path}/RELEASE_NOTES.md',
      ...names.map((name) => '${folder.path}/$name')
    ]);
    stdout.writeln('草稿已上传；未公开。请执行 verify 回读，再取得公开发布确认。');
    return;
  }
  final release = jsonDecode(await run('gh', [
    'release',
    'view',
    tag,
    '--repo',
    releaseRepository,
    '--json',
    'isDraft,assets'
  ])) as Map;
  if (release['isDraft'] != true) throw StateError('只校验或发布草稿，不修改已公开版本。');
  final remoteNames = (release['assets'] as List).map((e) => e['name']).toSet();
  if (remoteNames.length != names.length || !names.every(remoteNames.contains))
    throw StateError('草稿附件不完整或包含额外文件。');
  final readback =
      await Directory.systemTemp.createTemp('lumio-release-readback-');
  await run('gh', [
    'release',
    'download',
    tag,
    '--repo',
    releaseRepository,
    '--dir',
    readback.path
  ]);
  for (final name in names) {
    if ((await sha256.bind(File('${folder.path}/$name').openRead()).first)
            .toString() !=
        (await sha256.bind(File('${readback.path}/$name').openRead()).first)
            .toString()) throw StateError('回读附件 $name 不匹配；停止发布。');
  }
  await UpdateManifest.verify(
      File('${readback.path}/update-manifest.json').readAsBytesSync(),
      File('${readback.path}/update-manifest.sig').readAsStringSync(),
      updatePublicKey);
  stdout.writeln('所有附件回读通过，校验副本保留于 ${readback.path}。');
  if (args.first == 'publish') {
    await run('gh', [
      'release',
      'edit',
      tag,
      '--repo',
      releaseRepository,
      '--draft=false',
      '--latest'
    ]);
    stdout.writeln(
        '正式发布完成：https://github.com/$releaseRepository/releases/tag/$tag');
  }
}
