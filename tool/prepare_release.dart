import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import '../lib/core/updates/release_config.dart';
import '../lib/core/updates/update_manifest.dart';

Future<String> run(String command, List<String> args) async {
  final result = await Process.run(command, args);
  if (result.exitCode != 0) throw StateError('$command 校验失败：${result.stderr}');
  return result.stdout.toString().trim();
}

Future<void> main(List<String> args) async {
  if (args.isEmpty)
    throw ArgumentError(
        '用法：dart run tool/prepare_release.dart 更新说明文件 [--local-preview]。请先构建两端 Release。');
  final preview = args.contains('--local-preview');
  final dirty = (await run('git', ['status', '--porcelain'])).isNotEmpty;
  if (dirty && !preview)
    throw StateError('正式发布必须使用已提交的干净源码；本地验收可加 --local-preview，但不可上传预览附件。');
  final sourceCommit = await run('git', ['rev-parse', 'HEAD']);
  if (!preview) {
    // Always rebuild a formal release from the clean commit, never label stale build output with a new commit.
    for (final target in ['apk', 'macos']) {
      final process = await Process.start(
          'flutter', ['build', target, '--release', '--no-pub'],
          mode: ProcessStartMode.inheritStdio);
      if (await process.exitCode != 0) throw StateError('$target 正式构建失败，停止打包。');
    }
    if ((await run('git', ['status', '--porcelain'])).isNotEmpty ||
        await run('git', ['rev-parse', 'HEAD']) != sourceCommit) {
      throw StateError('构建期间源码发生变化，停止发布附件准备。');
    }
  }
  final match =
      RegExp(r'^version: ([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$', multiLine: true)
          .firstMatch(File('pubspec.yaml').readAsStringSync())!;
  final version = match.group(1)!;
  final build = int.parse(match.group(2)!);
  final tag = 'v$version-$build';
  final notes = File(args.first).readAsStringSync();
  if (notes.length > 16000) throw StateError('更新说明超过上限。');
  final androidSDK = Platform.environment['ANDROID_SDK_ROOT'] ??
      Platform.environment['ANDROID_HOME'];
  if (androidSDK == null) throw StateError('请配置 ANDROID_SDK_ROOT。');
  final tools = Directory('$androidSDK/build-tools')
      .listSync()
      .whereType<Directory>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final bin = tools.last.path;
  final apk = File(
      'build/app/outputs/apk/release/Lumio-$version-$build-android-universal.apk');
  if (!apk.existsSync()) throw StateError('未找到当前版本 Release APK。');
  final certificateOutput =
      await run('$bin/apksigner', ['verify', '--print-certs', apk.path]);
  final certificate =
      RegExp(r'Signer #1 certificate SHA-256 digest: ([a-fA-F0-9]+)')
          .firstMatch(certificateOutput)
          ?.group(1)
          ?.toLowerCase();
  if (certificate == null || certificateOutput.contains('Signer #2'))
    throw StateError('APK 签名格式不符合首版规则。');
  final keyRoot = '${Platform.environment['HOME']}/.lumio-release';
  final properties =
      File('$keyRoot/android-signing.properties').readAsLinesSync();
  final secrets = <String, String>{};
  for (final line in properties) {
    final separator = line.indexOf('=');
    if (separator > 0)
      secrets[line.substring(0, separator)] = line.substring(separator + 1);
  }
  final keytool = '${Platform.environment['JAVA_HOME']}/bin/keytool';
  final cert = await Process.run(
      keytool,
      [
        '-exportcert',
        '-keystore',
        secrets['storeFile']!,
        '-alias',
        secrets['keyAlias']!,
        '-storepass:env',
        'LUMIO_KEY_PASSWORD'
      ],
      environment: {'LUMIO_KEY_PASSWORD': secrets['storePassword']!},
      stdoutEncoding: null);
  if (cert.exitCode != 0 ||
      sha256.convert(cert.stdout as List<int>).toString() != certificate)
    throw StateError('APK 不是当前专用发布密钥签名。');
  final badging = await run('$bin/aapt', ['dump', 'badging', apk.path]);
  if (!badging.contains(
          "package: name='com.hxg.lumio' versionCode='$build' versionName='$version'") ||
      !badging.contains("sdkVersion:'24'") ||
      !['arm64-v8a', 'armeabi-v7a', 'x86_64']
          .every((abi) => badging.contains("'$abi'")))
    throw StateError('APK 版本、包名、最低系统或架构不正确。');
  final app = Directory('build/macos/Build/Products/Release/Lumio.app');
  final plist = '${app.path}/Contents/Info.plist';
  for (final entry in {
    'CFBundleIdentifier': 'com.hxg.lumio',
    'CFBundleShortVersionString': version,
    'CFBundleVersion': '$build',
    'LSMinimumSystemVersion': '13.0'
  }.entries) {
    if (await run(
            '/usr/libexec/PlistBuddy', ['-c', 'Print :${entry.key}', plist]) !=
        entry.value) throw StateError('macOS ${entry.key} 不匹配。');
  }
  final folder = Directory(
      'build/releases/${preview ? 'preview-$tag-${DateTime.now().microsecondsSinceEpoch}' : tag}');
  if (folder.existsSync()) throw StateError('发布目录已存在，不覆盖既有附件。');
  folder.createSync(recursive: true);
  final staged = '${folder.path}/staging/Lumio.app';
  await run('/usr/bin/ditto', [app.path, staged]);
  // Incremental Flutter builds may invalidate the App.framework seal. Re-seal only the staging copy.
  await run('/usr/bin/codesign',
      ['--force', '--sign', '-', '$staged/Contents/Frameworks/App.framework']);
  await run('/usr/bin/codesign', [
    '--force',
    '--sign',
    '-',
    '--options',
    '0',
    '--entitlements',
    'macos/Runner/Release.entitlements',
    staged
  ]);
  await run('/usr/bin/codesign', ['--verify', '--deep', '--strict', staged]);
  for (final entity in Directory(staged)
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()) {
    final type = await run('/usr/bin/file', ['-b', entity.path]);
    if (type.contains('Mach-O'))
      await run(
          '/usr/bin/lipo', [entity.path, '-verify_arch', 'arm64', 'x86_64']);
  }
  final apkName = 'Lumio-$version-$build-android-universal.apk';
  final zipName = 'Lumio-$version-$build-macos-universal.zip';
  await apk.copy('${folder.path}/$apkName');
  await run('/usr/bin/ditto', [
    '-c',
    '-k',
    '--sequesterRsrc',
    '--keepParent',
    staged,
    '${folder.path}/$zipName'
  ]);
  final packages = <Map<String, Object?>>[];
  for (final platform in ['android', 'macos']) {
    final name = platform == 'android' ? apkName : zipName;
    final file = File('${folder.path}/$name');
    packages.add({
      'platform': platform,
      'architectures': platform == 'android'
          ? ['arm64', 'armv7', 'x86_64']
          : ['arm64', 'x86_64'],
      'minimumOS': platform == 'android' ? '24' : '13.0',
      'fileName': name,
      'size': await file.length(),
      'sha256': (await sha256.bind(file.openRead()).first).toString(),
      'url':
          'https://github.com/$releaseRepository/releases/download/$tag/$name',
      if (platform == 'android') 'certificateSha256': certificate
    });
  }
  final data = utf8.encode('${const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'channel': 'stable',
        'version': version,
        'buildNumber': build,
        'publishedAt': DateTime.now().toUtc().toIso8601String(),
        'notes': notes,
        'sourceCommit': sourceCommit,
        'localPreview': preview,
        'packages': packages
      })}\n');
  final secret =
      jsonDecode(File('$keyRoot/manifest-key.json').readAsStringSync()) as Map;
  if (secret['publicKey'] != updatePublicKey)
    throw StateError('发布密钥与客户端内置公钥不一致，禁止发布。');
  final pair = await Ed25519()
      .newKeyPairFromSeed(base64Decode(secret['seed'] as String));
  final signature =
      base64Encode((await Ed25519().sign(data, keyPair: pair)).bytes);
  await UpdateManifest.verify(data, signature, updatePublicKey);
  File('${folder.path}/update-manifest.json').writeAsBytesSync(data);
  File('${folder.path}/update-manifest.sig').writeAsStringSync('$signature\n');
  File('${folder.path}/RELEASE_NOTES.md').writeAsStringSync(notes);
  File('${folder.path}/INSTALL.md').writeAsStringSync(
      'Android：正式版后续版本可覆盖更新；旧测试签名与正式签名不兼容，不要自动卸载。确需卸载时，请先导出备份，并另外保存 App 内接收的音视频文件。新版备份只包含应用数据，不包含实际音视频和封面文件。\n\nmacOS：未经过 Apple 公证。解压、退出 Lumio、手动替换应用；保留原有应用数据，按系统提示处理，不关闭系统保护。\n');
  stdout.writeln(
      '已准备并验签：${folder.path}。${preview ? '本地预览附件禁止公开上传。' : '待确认后创建草稿和回读验收；未公开。'}');
}
