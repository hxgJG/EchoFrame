import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/updates/update_manifest.dart';
import 'update_diagnostics.dart';

class UpdateNotPublished implements Exception {}

class UpdateCancelled implements Exception {}

class UpdateTransport {
  UpdateTransport({HttpClient Function()? clientFactory, this.diagnostics})
      : _makeClient = clientFactory ?? HttpClient.new;
  final HttpClient Function() _makeClient;
  final UpdateDiagnostics? diagnostics;
  HttpClient? _client;
  bool _cancelled = false;
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  static bool trustedRedirect(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      uri.fragment.isEmpty &&
      const [
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com'
      ].contains(uri.host);

  void _checkCancelled() {
    if (_cancelled) throw UpdateCancelled();
  }

  Future<T> _requestStep<T>(
      Uri uri, String stage, Future<T> Function() operation) async {
    if (diagnostics == null) return operation();
    final clock = Stopwatch()..start();
    try {
      final value = await operation();
      diagnostics!.record('requestStepComplete', {
        'url': diagnosticUrl(uri),
        'stage': stage,
        'durationMs': clock.elapsedMilliseconds,
      });
      return value;
    } on Object catch (error) {
      diagnostics!.record('requestStepFailed', {
        'url': diagnosticUrl(uri),
        'stage': stage,
        'durationMs': clock.elapsedMilliseconds,
        ...diagnosticError(error),
      });
      rethrow;
    }
  }

  Future<HttpClientResponse> _open(Uri uri) async {
    final client = _client ??= _makeClient()
      ..connectionTimeout = const Duration(seconds: 20);
    for (var i = 0; i < 6; i++) {
      _checkCancelled();
      if (!trustedRedirect(uri))
        throw const FormatException('下载重定向不在可信 HTTPS 域名内。');
      final requestClock = diagnostics == null ? null : (Stopwatch()..start());
      diagnostics
          ?.record('requestStart', {'url': diagnosticUrl(uri), 'hop': i});
      final request = await _requestStep(uri, 'getUrlCombinedConnection',
          () => client.getUrl(uri).timeout(const Duration(seconds: 25)));
      final requestReadyMs = requestClock?.elapsedMilliseconds;
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Lumio-Updates/1');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await _requestStep(uri, 'requestToHeaders',
          () => request.close().timeout(const Duration(seconds: 25)));
      if (diagnostics != null) {
        diagnostics!.record('responseHeaders', {
          'url': diagnosticUrl(uri),
          'status': response.statusCode,
          'requestReadyMs': requestReadyMs,
          'headersMs': requestClock!.elapsedMilliseconds,
          'remoteAddress': response.connectionInfo?.remoteAddress.address,
          'contentLength': response.contentLength,
          'acceptRanges': response.headers.value('accept-ranges'),
          'httpClient': 'Dart HttpClient / App 原有 GET 路径',
        });
      }
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) throw const FormatException('下载重定向缺少目标。');
        // Discard redirect bodies without waiting for an unbounded server stream.
        await response.listen((_) {}).cancel();
        final target = uri.resolve(location);
        diagnostics?.record('redirect', {
          'from': diagnosticUrl(uri),
          'to': diagnosticUrl(target),
        });
        uri = target;
        continue;
      }
      if (response.statusCode == 404) {
        await response.listen((_) {}).cancel();
        throw UpdateNotPublished();
      }
      if (response.statusCode != 200) {
        await response.listen((_) {}).cancel();
        throw HttpException('更新服务器返回 ${response.statusCode}');
      }
      return response;
    }
    throw const FormatException('下载重定向次数过多。');
  }

  Future<Uint8List> smallFile(Uri uri, int limit) async {
    try {
      final response = await _open(uri);
      if (response.contentLength > limit)
        throw const FormatException('更新信息过大。');
      final buffer = BytesBuilder(copy: false);
      await for (final bytes in response.timeout(const Duration(seconds: 20))) {
        _checkCancelled();
        if (buffer.length + bytes.length > limit)
          throw const FormatException('更新信息过大。');
        buffer.add(bytes);
      }
      return buffer.takeBytes();
    } finally {
      _client?.close(force: true);
      _client = null;
    }
  }

  Future<void> download(UpdatePackage package, File destination,
      void Function(int) onProgress) async {
    final partial = File('${destination.path}.part');
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        _checkCancelled();
        final attemptClock =
            diagnostics == null ? null : (Stopwatch()..start());
        final bodyClock = Stopwatch();
        final diskClock = diagnostics == null ? null : Stopwatch();
        var received = 0;
        var chunks = 0;
        var maximumChunkGapMs = 0;
        var lastChunkMs = 0;
        var lastSampleMs = 0;
        diagnostics?.record('attemptStart', {'attempt': attempt + 1});
        IOSink? sink;
        try {
          final response = await _open(package.url);
          if (response.contentLength != -1 &&
              response.contentLength != package.size)
            throw const FormatException('更新包长度与清单不一致。');
          sink = partial.openWrite();
          // Surface asynchronous disk errors while the network is still streaming.
          Object? writeError;
          unawaited(sink.done.catchError((Object e) {
            writeError = e;
          }));
          var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
          bodyClock.start();
          await for (final bytes
              in response.timeout(const Duration(seconds: 30))) {
            _checkCancelled();
            if (writeError != null) throw writeError!;
            received += bytes.length;
            if (diagnostics != null) {
              final nowMs = bodyClock.elapsedMilliseconds;
              final gap = nowMs - lastChunkMs;
              if (gap > maximumChunkGapMs) maximumChunkGapMs = gap;
              lastChunkMs = nowMs;
              chunks++;
              if (chunks == 1) {
                diagnostics!.record('firstBodyChunk', {
                  'attempt': attempt + 1,
                  'attemptMs': attemptClock!.elapsedMilliseconds,
                  'bodyWaitMs': nowMs,
                });
              }
              if (nowMs - lastSampleMs >= 1000) {
                diagnostics!.record('downloadSample', {
                  'attempt': attempt + 1,
                  'bodyMs': nowMs,
                  'receivedBytes': received,
                  'averageBytesPerSecond': received * 1000 / nowMs,
                  'flushWaitMs': diskClock!.elapsedMilliseconds,
                });
                lastSampleMs = nowMs;
              }
            }
            if (received > package.size)
              throw const FormatException('更新包超过清单大小。');
            sink.add(bytes);
            // Keep memory bounded even if storage is slower than the network.
            diskClock?.start();
            await sink.flush();
            diskClock?.stop();
            final now = DateTime.now();
            if (now.difference(lastReport).inMilliseconds >= 200) {
              onProgress(received);
              lastReport = now;
            }
          }
          await sink.close();
          sink = null;
          bodyClock.stop();
          diagnostics?.record('bodyComplete', {
            'attempt': attempt + 1,
            'bodyMs': bodyClock.elapsedMilliseconds,
            'receivedBytes': received,
            'chunks': chunks,
            'maximumChunkGapMs': maximumChunkGapMs,
            'flushWaitMs': diskClock?.elapsedMilliseconds,
          });
          _checkCancelled();
          if (received != package.size)
            throw const FormatException('更新包下载不完整。');
          final path = partial.path;
          final hashClock = diagnostics == null ? null : (Stopwatch()..start());
          final digest = await Isolate.run(() async =>
              (await sha256.bind(File(path).openRead()).first).toString());
          _checkCancelled();
          if (digest != package.sha256)
            throw const FormatException('更新包校验失败，已停止安装。');
          diagnostics?.record(
              'hashVerified', {'hashMs': hashClock?.elapsedMilliseconds});
          if (await destination.exists())
            throw const FileSystemException('缓存文件已存在，请重新下载。');
          await partial.rename(destination.path);
          onProgress(received);
          return;
        } on Object catch (e) {
          diagnostics?.record('attemptFailed', {
            'attempt': attempt + 1,
            'attemptMs': attemptClock?.elapsedMilliseconds,
            'receivedBytes': received,
            'bodyMs': bodyClock.elapsedMilliseconds,
            'flushWaitMs': diskClock?.elapsedMilliseconds,
            'maximumChunkGapMs': maximumChunkGapMs,
            ...diagnosticError(e),
          });
          if (sink != null) {
            try {
              await sink.close();
            } on Object {/* Primary error wins. */}
          }
          if (_cancelled) throw UpdateCancelled();
          if (attempt == 2 ||
              (e is! SocketException &&
                  e is! TimeoutException &&
                  e is! HttpException)) rethrow;
          onProgress(0);
          await Future<void>.delayed(
              Duration(milliseconds: 400 * (attempt + 1)));
        } finally {
          _client?.close(force: true);
          _client = null;
        }
      }
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}
