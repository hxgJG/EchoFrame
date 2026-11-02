import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import '../../lib/core/updates/release_config.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2 || !args[1].contains('com.hxg.lumio.updateqa')) {
    throw ArgumentError(
        '用法：dart run tool/qa/prepare_macos_update.dart 测试ZIP 隔离QA缓存目录');
  }
  final archive = File(args[0]);
  final bytes = await archive.readAsBytes();
  final hash = sha256.convert(bytes).toString();
  final secret = jsonDecode(await File(
          '${Platform.environment['HOME']}/.lumio-release/manifest-key.json')
      .readAsString()) as Map;
  final pair = await Ed25519()
      .newKeyPairFromSeed(base64Decode(secret['seed'] as String));
  if (base64Encode((await pair.extractPublicKey()).bytes) != updatePublicKey) {
    throw StateError('测试签名密钥不匹配。');
  }
  final root = Directory(args[1]);
  await root.create(recursive: true);
  final file = await archive.copy('${root.path}/update-9-$hash.zip');
  final metadata = {
    'version': '1.0.8',
    'buildNumber': 9,
    'sha256': hash,
    'size': bytes.length,
    'sparkleSignature':
        base64Encode((await Ed25519().sign(bytes, keyPair: pair)).bytes),
  };
  await File('${root.path}/qa-package.json')
      .writeAsString(jsonEncode(metadata), flush: true);
  stdout.writeln('隔离验收包已准备：${file.path}');
}
