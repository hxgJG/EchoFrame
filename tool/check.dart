import 'dart:io';

/// 本地统一校验：格式、静态分析、单元测试，可选 debug 构建。
///
/// 与 `.github/workflows/ci.yml` 的检查项保持一致，便于提交前在本地复现 CI 结果。
const _usage = '''
用法：dart run tool/check.dart [选项]

  --build       追加 debug 构建（Android；macOS 主机再构建 macOS）
  --skip-test   跳过 flutter test
  --help, -h    显示本说明

依次执行：
  1. dart format --output=none --set-exit-if-changed lib test tool
  2. flutter analyze --no-pub
  3. flutter test --no-pub
  4. flutter build apk --debug --no-pub           （--build）
  5. flutter build macos --debug --no-pub         （--build 且在 macOS 上）

首次运行前请先执行 flutter pub get；本脚本统一使用 --no-pub，避免在 OHOS
分支未配置 HOS_SDK_HOME 时重复触发依赖解析。
''';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }
  final build = args.contains('--build');
  final skipTest = args.contains('--skip-test');
  final steps = <({String title, String executable, List<String> args})>[
    (
      title: '格式检查',
      executable: 'dart',
      args: <String>[
        'format',
        '--output=none',
        '--set-exit-if-changed',
        'lib',
        'test',
        'tool',
      ],
    ),
    (
      title: '静态分析',
      executable: 'flutter',
      args: <String>['analyze', '--no-pub'],
    ),
    if (!skipTest)
      (
        title: '单元测试',
        executable: 'flutter',
        args: <String>['test', '--no-pub', '--reporter=failures-only'],
      ),
    if (build)
      (
        title: '构建 Android debug APK',
        executable: 'flutter',
        args: <String>['build', 'apk', '--debug', '--no-pub'],
      ),
    if (build && Platform.isMacOS)
      (
        title: '构建 macOS debug',
        executable: 'flutter',
        args: <String>['build', 'macos', '--debug', '--no-pub'],
      ),
  ];

  final startedAt = DateTime.now();
  for (final step in steps) {
    stdout.writeln(
        '\n==> ${step.title}：${step.executable} ${step.args.join(' ')}');
    final process = await Process.start(
      step.executable,
      step.args,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code != 0) {
      stderr.writeln('\n失败：${step.title}（退出码 $code）');
      exitCode = code;
      return;
    }
  }
  final elapsed = DateTime.now().difference(startedAt).inSeconds;
  stdout.writeln('\n通过：${steps.length} 项检查完成，用时 ${elapsed}s');
}
