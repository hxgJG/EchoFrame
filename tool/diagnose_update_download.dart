import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/core/updates/release_config.dart';
import '../lib/core/updates/update_manifest.dart';
import '../lib/platform/app_update/update_diagnostics.dart';
import '../lib/platform/app_update/update_transport.dart';

const _usage = '''
GitHub 更新下载诊断（默认仅显示计划，不联网）
  dart run tool/diagnose_update_download.dart --self-check
  dart run tool/diagnose_update_download.dart --platform=macos
  dart run tool/diagnose_update_download.dart --run --platform=macos --network-label=无VPN

--platform=macos|android|both，默认 macos。
--run 必须在取得实际下载确认后使用；下载基线最多 15 分钟，后置探测每跳最多 45 秒。
只读取公开 GitHub 附件，不使用 gh 登录凭证，不安装，不修改网络设置。
每个包沿用 App 现有下载器（单连接、最多三次重试）；可能重复消耗流量。
报告和校验通过的安装包保存在 build/update-diagnostics/ 下。
不读取或上传应用数据，不记录下载链接查询参数、密码或 HTTP 正文。
''';

void _selfCheck() {
  final safe = diagnosticUrl(Uri.parse(
      'https://user:secret@release-assets.githubusercontent.com/a?token=secret#secret'));
  if (safe != 'https://release-assets.githubusercontent.com/a') {
    throw StateError('链接脱敏失败。');
  }
  final diagnostics = UpdateDiagnostics();
  for (var i = 0; i < UpdateDiagnostics.maximumEvents + 2; i++) {
    diagnostics.record('sample', {'bytes': i});
  }
  if ((diagnostics.snapshot()['events'] as List).length !=
          UpdateDiagnostics.maximumEvents ||
      diagnostics.droppedEvents != 2) {
    throw StateError('日志容量限制失败。');
  }
  final error = diagnosticError(
      HttpException('secret', uri: Uri.parse('https://example.com/?secret')));
  if (jsonEncode(error).contains('secret')) throw StateError('异常脱敏失败。');
  stdout.writeln('离线自检通过；没有发起网络请求。');
}

/// Separate HEAD probes, after the App downloader, so they do not warm its DNS
/// and TLS caches before the baseline. curl phase timings are not Dart timings.
Future<List<Map<String, Object?>>> _probe(
    Uri initial, bool Function() canContinue) async {
  var uri = initial;
  final results = <Map<String, Object?>>[];
  for (var hop = 0; hop < 6; hop++) {
    if (!canContinue()) break;
    if (!UpdateTransport.trustedRedirect(uri)) {
      results.add({'status': 'rejectedUntrustedRedirect'});
      break;
    }
    final dnsClock = Stopwatch()..start();
    Map<String, Object?> dns;
    try {
      final addresses = await InternetAddress.lookup(uri.host)
          .timeout(const Duration(seconds: 10));
      dns = {
        'lookupMs': dnsClock.elapsedMilliseconds,
        'addresses': addresses.map((e) => e.address).toList(),
      };
    } on Object catch (error) {
      dns = {
        'lookupMs': dnsClock.elapsedMilliseconds,
        ...diagnosticError(error)
      };
    }
    const marker = '\nLUMIO_CURL_METRICS:';
    const fields = '{"status":%{http_code},"dnsSeconds":%{time_namelookup},'
        '"connectSeconds":%{time_connect},"tlsSeconds":%{time_appconnect},'
        '"firstByteSeconds":%{time_starttransfer},"totalSeconds":%{time_total},'
        '"remoteAddress":"%{remote_ip}","httpVersion":"%{http_version}"}';
    try {
      if (!canContinue()) break;
      final response = await Process.run('/usr/bin/curl', [
        '--silent',
        '--show-error',
        '--head',
        '--http1.1',
        '--noproxy',
        '*',
        '--proto',
        '=https',
        '--connect-timeout',
        '20',
        '--max-time',
        '35',
        '--user-agent',
        'Lumio-Updates/1',
        '--dump-header',
        '-',
        '--output',
        '/dev/null',
        '--write-out',
        '$marker$fields',
        uri.toString(),
      ]);
      final raw = response.stdout.toString();
      final split = raw.lastIndexOf(marker);
      if (split < 0) throw const FormatException('curl 没有返回计时信息。');
      final metrics = jsonDecode(raw.substring(split + marker.length))
          as Map<String, dynamic>;
      double seconds(String key) => (metrics[key] as num).toDouble();
      final connected = seconds('connectSeconds') > 0;
      final tls = seconds('tlsSeconds') > 0;
      final firstByte = seconds('firstByteSeconds') > 0;
      final result = <String, Object?>{
        'url': diagnosticUrl(uri),
        'hop': hop,
        'exitCode': response.exitCode,
        'independentDnsLookup': dns,
        'curlCumulativeTimings': metrics,
        'phaseMs': {
          'dns': seconds('dnsSeconds') * 1000,
          'tcp': connected
              ? (seconds('connectSeconds') - seconds('dnsSeconds')) * 1000
              : null,
          'tls': tls
              ? (seconds('tlsSeconds') - seconds('connectSeconds')) * 1000
              : null,
          'requestToFirstByte': firstByte && tls
              ? (seconds('firstByteSeconds') - seconds('tlsSeconds')) * 1000
              : null,
        },
      };
      results.add(result);
      final location =
          RegExp(r'^location:\s*(.+)$', multiLine: true, caseSensitive: false)
              .firstMatch(raw.substring(0, split))
              ?.group(1)
              ?.trim();
      if (response.exitCode != 0 ||
          ![301, 302, 303, 307, 308].contains(metrics['status']) ||
          location == null) break;
      uri = uri.resolve(location);
    } on Object catch (error) {
      results.add({
        'url': diagnosticUrl(uri),
        'independentDnsLookup': dns,
        ...diagnosticError(error)
      });
      break;
    }
  }
  return results;
}

Future<void> main(List<String> args) async {
  const allowed = {'--run', '--self-check', '--help'};
  if (args.any((e) =>
      !allowed.contains(e) &&
      !e.startsWith('--platform=') &&
      !e.startsWith('--network-label='))) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  if (args.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }
  if (args.contains('--self-check')) {
    _selfCheck();
    return;
  }
  String option(String name, String fallback) => args
      .firstWhere((e) => e.startsWith('$name='),
          orElse: () => '$name=$fallback')
      .substring(name.length + 1);
  final platform = option('--platform', 'macos');
  if (!['macos', 'android', 'both'].contains(platform)) {
    stderr.writeln('平台只能为 macos、android 或 both。');
    exitCode = 64;
    return;
  }
  if (!args.contains('--run')) {
    stdout.writeln(_usage);
    stdout
        .writeln('待确认计划：读取 latest 签名清单，下载 $platform 最新包，之后进行分阶段 HEAD 探测。尚未联网。');
    return;
  }
  final root = Directory(
      'build/update-diagnostics/${DateTime.now().microsecondsSinceEpoch}');
  await root.create(recursive: true);
  final reportFile = File('${root.path}/report.json');
  final diagnostics = UpdateDiagnostics();
  final report = <String, Object?>{
    'schemaVersion': 1,
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'runtime': Platform.version.split('\n').first,
    'devicePlatform': Platform.operatingSystem,
    'networkLabel': option('--network-label', '未确认是否启用 VPN'),
    'networkLabelSource': '操作者声明；工具不能证明系统 VPN 或透明代理关闭',
    'downloader': 'App 原有 Dart UpdateTransport，保留单连接、重试、逐块 flush 和原校验',
    'timingBoundary':
        'Dart requestReadyMs 是 getUrl 综合等待，不能拆成 DNS/TCP/TLS；curl HEAD 是后置独立探测，缓存和请求方法不同，不能等同原 GET。',
    'packages': <Map<String, Object?>>[],
    'status': 'running',
  };
  Future<void> save() async {
    report['appTransport'] = diagnostics.snapshot();
    await reportFile
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  }

  var transport = UpdateTransport(diagnostics: diagnostics);
  var stopped = false;
  void stop() {
    stopped = true;
    transport.cancel();
  }

  final deadline = Timer(const Duration(minutes: 15), stop);
  final signals = ProcessSignal.sigint.watch().listen((_) => stop());
  final manifestUri = Uri.parse(
      'https://github.com/$releaseRepository/releases/latest/download/update-manifest.json');
  final signatureUri = Uri.parse(
      'https://github.com/$releaseRepository/releases/latest/download/update-manifest.sig');
  var phase = 'manifest';
  try {
    final raw = await transport.smallFile(manifestUri, 65536);
    final signature = await transport.smallFile(signatureUri, 256);
    final manifest = await UpdateManifest.verify(
        raw, utf8.decode(signature), updatePublicKey);
    report['release'] = {
      'version': manifest.version,
      'buildNumber': manifest.buildNumber,
      'signatureVerified': true
    };
    final packages = manifest.packages
        .where((p) => platform == 'both' || p.platform == platform)
        .toList();
    if (packages.isEmpty) throw const FormatException('清单中没有所选平台安装包。');
    for (final package in packages) {
      if (stopped) throw UpdateCancelled();
      phase = package.platform;
      transport = UpdateTransport(diagnostics: diagnostics);
      final entry = <String, Object?>{
        'platform': package.platform,
        'fileName': package.fileName,
        'expectedBytes': package.size,
        'expectedSha256': package.sha256,
        'url': diagnosticUrl(package.url),
        'status': 'downloading',
      };
      (report['packages'] as List).add(entry);
      await save();
      stdout.writeln('开始原下载器基线：${package.fileName}，${package.size} 字节。');
      final clock = Stopwatch()..start();
      var progressMs = 0;
      try {
        await transport.download(
            package, File('${root.path}/${package.fileName}'), (bytes) {
          if (clock.elapsedMilliseconds - progressMs >= 5000) {
            stdout.writeln(
                '${package.platform}: $bytes / ${package.size} 字节，已用 ${clock.elapsed.inSeconds}s');
            progressMs = clock.elapsedMilliseconds;
          }
        });
        entry['status'] = 'downloadedAndHashVerified';
      } on Object catch (error) {
        entry['status'] = 'failed';
        entry['error'] = diagnosticError(error);
        exitCode = 1;
      }
      entry['downloadElapsedMs'] = clock.elapsedMilliseconds;
      await save();
      stdout.writeln('开始独立 DNS / TCP / TLS / HEAD 探测（不是原 GET 计时）。');
      entry['postDownloadHeadProbes'] =
          await _probe(package.url, () => !stopped);
      await save();
    }
    report['status'] = exitCode == 0 ? 'complete' : 'completedWithFailure';
  } on Object catch (error) {
    report['status'] = 'failed';
    report['failedPhase'] = phase;
    report['error'] = diagnosticError(error);
    exitCode = 1;
    // Even a failed manifest fetch deserves connection-level evidence.
    report['manifestHeadProbes'] = await _probe(manifestUri, () => !stopped);
  } finally {
    deadline.cancel();
    await signals.cancel();
    transport.cancel();
    report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    await save();
    stdout.writeln('诊断结果：${reportFile.absolute.path}。未安装、未修改系统网络配置。');
  }
}
