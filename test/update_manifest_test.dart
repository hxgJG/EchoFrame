import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/updates/update_manifest.dart';

void main() {
  late SimpleKeyPair pair;
  late String public;
  setUp(() async {
    pair = await Ed25519().newKeyPair();
    public = base64Encode((await pair.extractPublicKey()).bytes);
  });
  Map<String, Object?> fixture() => {
        'schemaVersion': 1,
        'channel': 'stable',
        'version': '1.0.1',
        'buildNumber': 2,
        'publishedAt': '2026-10-09T00:00:00Z',
        'notes': '更新说明',
        'packages': [
          {
            'platform': 'android',
            'architectures': ['arm64', 'armv7', 'x86_64'],
            'minimumOS': '24',
            'fileName': 'Lumio-1.0.1-2-android-universal.apk',
            'size': 100,
            'sha256': 'a' * 64,
            'certificateSha256': 'b' * 64,
            'url':
                'https://github.com/hxgJG/Lumio-Releases/releases/download/v1.0.1-2/Lumio-1.0.1-2-android-universal.apk'
          },
          {
            'platform': 'macos',
            'architectures': ['arm64', 'x86_64'],
            'minimumOS': '13.0',
            'fileName': 'Lumio-1.0.1-2-macos-universal.zip',
            'size': 100,
            'sha256': 'c' * 64,
            'url':
                'https://github.com/hxgJG/Lumio-Releases/releases/download/v1.0.1-2/Lumio-1.0.1-2-macos-universal.zip'
          },
        ]
      };
  Future<UpdateManifest> signed(Map<String, Object?> value) async {
    final raw = utf8.encode(jsonEncode(value));
    final sig = await Ed25519().sign(raw, keyPair: pair);
    return UpdateManifest.verify(raw, base64Encode(sig.bytes), public);
  }

  test('认证清单按平台架构和系统筛选', () async {
    final value = await signed(fixture());
    expect(value.select('android', 'arm64', '24').platform, 'android');
    expect(value.select('macos', 'x86_64', '13.0.1').platform, 'macos');
    expect(() => value.select('macos', 'arm64', '12.9'), throwsFormatException);
    expect(() => value.select('android', 'mips', '30'), throwsFormatException);
    expect(
        () => value.select('windows', 'x86_64', '30'), throwsFormatException);
  });
  test('篡改原始字节及错误公钥拒绝，不先解析 JSON', () async {
    final raw = utf8.encode(jsonEncode(fixture()));
    final signature =
        base64Encode((await Ed25519().sign(raw, keyPair: pair)).bytes);
    expect(UpdateManifest.verify([...raw, 32], signature, public),
        throwsFormatException);
    final other = await Ed25519().newKeyPair();
    expect(
        UpdateManifest.verify(raw, signature,
            base64Encode((await other.extractPublicKey()).bytes)),
        throwsFormatException);
    expect(
        UpdateManifest.verify([255], signature, public), throwsFormatException);
  });
  test('清单和签名限制大小', () async {
    expect(UpdateManifest.verify(List.filled(65537, 0), '', public),
        throwsFormatException);
    expect(UpdateManifest.verify([1], base64Encode(List.filled(63, 0)), public),
        throwsFormatException);
  });
  test('合法签名也不能指向任意 URL 或 latest 安装包', () async {
    for (final url in [
      'http://github.com/a.apk',
      'https://evil.example/a.apk',
      'https://github.com/hxgJG/Lumio-Releases/releases/latest/download/Lumio-1.0.1-2-android-universal.apk'
    ]) {
      final value = fixture();
      ((value['packages'] as List).first as Map)['url'] = url;
      expect(signed(value), throwsFormatException);
    }
  });
  test('格式 大小 重复平台与缺失 APK 证书拒绝', () async {
    for (final mutate in <void Function(Map)>[
      (value) => value['schemaVersion'] = 99,
      (value) => value['notes'] = 'x' * 16001,
      (value) =>
          (value['packages'] as List).add((value['packages'] as List).first),
      (value) => ((value['packages'] as List).first as Map)['size'] =
          maximumPackageBytes + 1,
      (value) => ((value['packages'] as List).first as Map)
          .remove('certificateSha256'),
    ]) {
      final value = fixture();
      mutate(value);
      expect(signed(value), throwsFormatException);
    }
  });
}
