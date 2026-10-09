import 'dart:convert';
import 'package:cryptography/cryptography.dart';

const releaseRepository = 'hxgJG/Lumio-Releases';
const maximumPackageBytes = 1024 * 1024 * 1024;

class UpdatePackage {
  const UpdatePackage(
      {required this.platform,
      required this.architectures,
      required this.minimumOS,
      required this.fileName,
      required this.size,
      required this.sha256,
      required this.url,
      this.certificateSha256});
  final String platform, minimumOS, fileName, sha256;
  final List<String> architectures;
  final int size;
  final Uri url;
  final String? certificateSha256;
}

class UpdateManifest {
  const UpdateManifest(
      {required this.version,
      required this.buildNumber,
      required this.publishedAt,
      required this.notes,
      required this.packages});
  final String version, notes;
  final int buildNumber;
  final DateTime publishedAt;
  final List<UpdatePackage> packages;

  static Future<UpdateManifest> verify(
      List<int> raw, String signature, String publicKey) async {
    if (raw.isEmpty || raw.length > 65536 || signature.length > 256) {
      throw const FormatException('更新清单超出允许大小。');
    }
    final key = base64Decode(publicKey);
    final sig = base64Decode(signature.trim());
    if (key.length != 32 ||
        sig.length != 64 ||
        !await Ed25519().verify(raw,
            signature: Signature(sig,
                publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)))) {
      throw const FormatException('更新清单签名不正确，已停止更新。');
    }
    // Do not decode or trust any server-provided fields before authentication.
    final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final version = json['version'] as String;
    final build = json['buildNumber'] as int;
    final notes = json['notes'] as String;
    if (json['schemaVersion'] != 1 ||
        json['channel'] != 'stable' ||
        !RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$').hasMatch(version) ||
        build < 1 ||
        build > 2100000000 ||
        notes.length > 16000) {
      throw const FormatException('暂不支持此更新清单。');
    }
    final packages = <UpdatePackage>[];
    final entries = json['packages'] as List;
    if (entries.isEmpty || entries.length > 8)
      throw const FormatException('更新包列表无效。');
    for (final entry in entries) {
      final p = entry as Map<String, dynamic>;
      final platform = p['platform'] as String;
      if (!['android', 'macos'].contains(platform))
        throw const FormatException('更新平台无效。');
      final extension = platform == 'android' ? 'apk' : 'zip';
      final name = p['fileName'] as String;
      final url = Uri.parse(p['url'] as String);
      final hash = p['sha256'] as String;
      final size = p['size'] as int;
      final architectures = (p['architectures'] as List).cast<String>();
      final minimumOS = p['minimumOS'] as String;
      final certificate = p['certificateSha256'] as String?;
      if (name != 'Lumio-$version-$build-$platform-universal.$extension' ||
          url.toString() !=
              'https://github.com/$releaseRepository/releases/download/v$version-$build/$name' ||
          size < 1 ||
          size > maximumPackageBytes ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          architectures.isEmpty ||
          architectures.length > 4 ||
          !architectures.every(['arm64', 'x86_64', 'armv7'].contains) ||
          !RegExp(platform == 'android'
                  ? r'^\d{2,3}$'
                  : r'^\d{1,3}\.\d{1,3}(\.\d{1,3})?$')
              .hasMatch(minimumOS) ||
          (platform == 'android' &&
              (certificate == null ||
                  !RegExp(r'^[a-f0-9]{64}$').hasMatch(certificate)))) {
        throw const FormatException('更新包信息不符合发布规则。');
      }
      if (packages.any((e) => e.platform == platform))
        throw const FormatException('平台更新包重复。');
      packages.add(UpdatePackage(
          platform: platform,
          architectures: architectures,
          minimumOS: minimumOS,
          fileName: name,
          size: size,
          sha256: hash,
          url: url,
          certificateSha256: certificate));
    }
    return UpdateManifest(
        version: version,
        buildNumber: build,
        publishedAt: DateTime.parse(json['publishedAt'] as String),
        notes: notes,
        packages: packages);
  }

  UpdatePackage select(String platform, String architecture, String osVersion) {
    final candidates = packages.where((p) =>
        p.platform == platform && p.architectures.contains(architecture));
    if (candidates.isEmpty) throw const FormatException('没有适合当前设备的更新包。');
    final selected = candidates.single;
    if (compareOS(osVersion, selected.minimumOS) < 0)
      throw FormatException('此更新需要 $platform ${selected.minimumOS} 或更高版本。');
    return selected;
  }

  static int compareOS(String a, String b) {
    final left = a.split('.').map(int.parse).toList();
    final right = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final result = (i < left.length ? left[i] : 0)
          .compareTo(i < right.length ? right[i] : 0);
      if (result != 0) return result;
    }
    return 0;
  }
}
