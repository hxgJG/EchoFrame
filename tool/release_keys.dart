import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

// Run once. Never rotate these keys merely to fix a build or authorization error.
Future<void> main() async {
  final root = Directory('${Platform.environment['HOME']}/.lumio-release');
  if (root.existsSync()) throw StateError('密钥目录已存在；不覆盖任何现有密钥。');
  root.createSync();
  await Process.run('/bin/chmod', ['700', root.path]);
  final random = Random.secure();
  final seed = List<int>.generate(32, (_) => random.nextInt(256));
  final pair = await Ed25519().newKeyPairFromSeed(seed);
  final public = await pair.extractPublicKey();
  final secret = File('${root.path}/manifest-key.json');
  secret.writeAsStringSync(jsonEncode(
      {'seed': base64Encode(seed), 'publicKey': base64Encode(public.bytes)}));
  await Process.run('/bin/chmod', ['600', secret.path]);
  final password =
      base64UrlEncode(List<int>.generate(36, (_) => random.nextInt(256)));
  final keytool = '${Platform.environment['JAVA_HOME']}/bin/keytool';
  final result = await Process.run(keytool, [
    '-genkeypair',
    '-keystore',
    '${root.path}/android-release.p12',
    '-storetype',
    'PKCS12',
    '-alias',
    'lumio',
    '-keyalg',
    'RSA',
    '-keysize',
    '3072',
    '-validity',
    '10000',
    '-dname',
    'CN=Lumio Release',
    '-storepass:env',
    'LUMIO_KEY_PASSWORD',
    '-keypass:env',
    'LUMIO_KEY_PASSWORD',
  ], environment: {
    'LUMIO_KEY_PASSWORD': password
  });
  if (result.exitCode != 0) throw StateError('keytool 生成失败；目录保留，请检查后处理，不自动重建。');
  final properties = File('${root.path}/android-signing.properties');
  properties.writeAsStringSync(
      'storeFile=${root.path}/android-release.p12\nstorePassword=$password\nkeyPassword=$password\nkeyAlias=lumio\n');
  for (final name in ['android-signing.properties', 'android-release.p12']) {
    await Process.run('/bin/chmod', ['600', '${root.path}/$name']);
  }
  stdout.writeln('公钥：${base64Encode(public.bytes)}');
  stdout.writeln('密钥已生成于 ${root.path}。请另行离线安全备份整个目录；不要提交或公开。');
}
