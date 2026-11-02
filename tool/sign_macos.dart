import 'dart:io';

Future<String> _run(String command, List<String> arguments) async {
  final result = await Process.run(command, arguments);
  if (result.exitCode != 0) {
    throw StateError('$command 失败：${result.stderr}');
  }
  return result.stdout.toString().trim();
}

Future<void> sealMacBundle(String appPath) async {
  final identifier = await _run('/usr/libexec/PlistBuddy',
      ['-c', 'Print :CFBundleIdentifier', '$appPath/Contents/Info.plist']);
  if (!RegExp(r'^com\.hxg\.lumio(?:\.[a-z0-9]+)?$').hasMatch(identifier)) {
    throw StateError('拒绝签署非 Lumio 应用。');
  }
  final sparkle = '$appPath/Contents/Frameworks/Sparkle.framework/Versions/B';
  for (final relative in [
    'XPCServices/Installer.xpc',
    'XPCServices/Downloader.xpc',
    'Autoupdate',
    'Updater.app',
  ]) {
    await _run('/usr/bin/codesign', [
      '--force',
      '--sign',
      '-',
      '--options',
      'runtime',
      '--preserve-metadata=entitlements',
      '$sparkle/$relative'
    ]);
  }
  await _run('/usr/bin/codesign', [
    '--force',
    '--sign',
    '-',
    '--options',
    'runtime',
    '$appPath/Contents/Frameworks/Sparkle.framework'
  ]);
  await _run('/usr/bin/codesign',
      ['--force', '--sign', '-', '$appPath/Contents/Frameworks/App.framework']);
  final temporary =
      await Directory.systemTemp.createTemp('lumio-entitlements-');
  final entitlements = File('${temporary.path}/Release.entitlements');
  try {
    await entitlements.writeAsString(
        await File('macos/Runner/Release.entitlements').readAsString().then(
            (text) =>
                text.replaceAll(r'$(PRODUCT_BUNDLE_IDENTIFIER)', identifier)));
    await _run('/usr/bin/codesign', [
      '--force',
      '--sign',
      '-',
      '--options',
      '0',
      '--entitlements',
      entitlements.path,
      appPath
    ]);
    await _run(
        '/usr/bin/codesign', ['--verify', '--deep', '--strict', appPath]);
  } finally {
    await temporary.delete(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 1)
    throw ArgumentError('用法：dart run tool/sign_macos.dart 应用.app');
  await sealMacBundle(args.single);
  stdout.writeln('签名及完整性校验通过：${args.single}');
}
