import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/updates/update_manifest.dart';
import 'update_diagnostics.dart';

class UpdateNotPublished implements Exception {}

class UpdateCancelled implements Exception {}

class UpdateDownloadBusy implements Exception {}

class UpdateTransport {
  UpdateTransport({HttpClient Function()? clientFactory, this.diagnostics})
      : _makeClient = clientFactory ?? HttpClient.new;
  final HttpClient Function() _makeClient;
  final UpdateDiagnostics? diagnostics;
  HttpClient? _client;
  bool _cancelled = false;
  static final _activeDownloads = <String>{};
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

  Future<HttpClientResponse> _open(Uri uri,
      {int offset = 0, String? etag}) async {
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
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
        if (etag != null) request.headers.set(HttpHeaders.ifRangeHeader, etag);
      }
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
          'requestedOffset': offset,
          'contentRange':
              response.headers.value(HttpHeaders.contentRangeHeader),
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
      if (response.statusCode != 200 &&
          !(offset > 0 && [206, 416].contains(response.statusCode))) {
        await response.listen((_) {}).cancel();
        throw HttpException('更新服务器返回 ${response.statusCode}');
      }
      return response;
    }
    throw const FormatException('下载重定向次数过多。');
  }

  static String? _strongETag(String? value) => value != null &&
          value.length <= 1024 &&
          RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value)
      ? value
      : null;

  static Future<Map<String, dynamic>?> _resumeState(
      UpdatePackage package, File destination) async {
    final partial = File('${destination.path}.part');
    final metadata = File('${partial.path}.json');
    if (!await partial.exists() || !await metadata.exists()) return null;
    try {
      final stat = await partial.stat();
      if (stat.size > package.size ||
          DateTime.now().difference(stat.modified) > const Duration(days: 7) ||
          await metadata.length() > 4096) return null;
      final state =
          jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
      if (state['schemaVersion'] != 1 ||
          state['sha256'] != package.sha256 ||
          state['size'] != package.size) {
        return null;
      }
      return {
        'offset': stat.size,
        'etag': _strongETag(state['etag'] as String?)
      };
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static Future<int> retainedBytes(
      UpdatePackage package, File destination) async {
    if (await destination.exists() &&
        await destination.length() == package.size) {
      return package.size;
    }
    return (await _resumeState(package, destination))?['offset'] as int? ?? 0;
  }

  static Future<bool> _validFile(UpdatePackage package, File file) async {
    if (!await file.exists() || await file.length() != package.size)
      return false;
    final path = file.path;
    final digest = await Isolate.run(() async =>
        (await sha256.bind(File(path).openRead()).first).toString());
    return digest == package.sha256;
  }

  static bool _validRange(HttpClientResponse response, int offset, int size) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
    return match != null &&
        int.tryParse(match[1]!) == offset &&
        int.tryParse(match[2]!) == size - 1 &&
        int.tryParse(match[3]!) == size;
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
    final metadata = File('${partial.path}.json');
    final metadataTemporary = File('${metadata.path}.tmp');
    final key = destination.absolute.path;
    if (!_activeDownloads.add(key)) throw UpdateDownloadBusy();
    var retainPartial = false;
    Future<void> discardPartial() async {
      for (final file in [partial, metadata, metadataTemporary]) {
        if (await file.exists()) await file.delete();
      }
    }

    try {
      if (await destination.exists()) {
        if (await _validFile(package, destination)) {
          _checkCancelled();
          diagnostics
              ?.record('verifiedCacheReused', {'receivedBytes': package.size});
          onProgress(package.size);
          return;
        }
        await destination.delete();
      }
      final state = await _resumeState(package, destination);
      if (state == null) await discardPartial();
      var etag = state?['etag'] as String?;
      retainPartial = state != null;
      for (var attempt = 0; attempt < 3; attempt++) {
        _checkCancelled();
        final attemptClock =
            diagnostics == null ? null : (Stopwatch()..start());
        final bodyClock = Stopwatch();
        final diskClock = diagnostics == null ? null : Stopwatch();
        var offset = await partial.exists() ? await partial.length() : 0;
        var received = offset;
        var chunks = 0;
        var maximumChunkGapMs = 0;
        var lastChunkMs = 0;
        var lastSampleMs = 0;
        diagnostics?.record(
            'attemptStart', {'attempt': attempt + 1, 'resumeOffset': offset});
        onProgress(received);
        _checkCancelled();
        IOSink? sink;
        Object? writeError;
        try {
          if (offset == package.size) {
            if (!await _validFile(package, partial)) {
              throw const FormatException('更新包校验失败，已停止安装。');
            }
            _checkCancelled();
            await partial.rename(destination.path);
            diagnostics
                ?.record('verifiedPartialReused', {'receivedBytes': received});
            onProgress(received);
            retainPartial = false;
            return;
          }
          // Always start at the release URL to obtain a fresh signed asset URL.
          var response = await _open(package.url, offset: offset, etag: etag);
          final responseETag =
              _strongETag(response.headers.value(HttpHeaders.etagHeader));
          if (offset > 0 &&
              (response.statusCode == 416 ||
                  (response.statusCode == 206 &&
                      (!_validRange(response, offset, package.size) ||
                          (etag != null &&
                              responseETag != null &&
                              etag != responseETag))))) {
            diagnostics?.record('resumeRestarted', {
              'reason': 'rangeOrValidatorMismatch',
              'discardedBytes': offset
            });
            await response.listen((_) {}).cancel();
            _client?.close(force: true);
            _client = null;
            await discardPartial();
            offset = received = 0;
            etag = null;
            retainPartial = false;
            onProgress(0);
            response = await _open(package.url);
          }
          if (response.statusCode == 200 && offset > 0) {
            diagnostics?.record('resumeRestarted',
                {'reason': 'serverReturnedFullFile', 'discardedBytes': offset});
            offset = received = 0;
            onProgress(0);
          }
          final encoding =
              response.headers.value(HttpHeaders.contentEncodingHeader);
          if (encoding != null && encoding.toLowerCase() != 'identity') {
            throw const FormatException('更新包传输编码不符合字节续传要求。');
          }
          if (response.contentLength != -1 &&
              response.contentLength != package.size - offset)
            throw const FormatException('更新包长度与清单不一致。');
          // Truncate before updating metadata when falling back to a full response.
          if (offset == 0) await partial.writeAsBytes(const [], flush: true);
          etag = _strongETag(response.headers.value(HttpHeaders.etagHeader)) ??
              (offset > 0 ? etag : null);
          await metadataTemporary.writeAsString(
              jsonEncode({
                'schemaVersion': 1,
                'sha256': package.sha256,
                'size': package.size,
                if (etag != null) 'etag': etag,
              }),
              flush: true);
          await metadataTemporary.rename(metadata.path);
          retainPartial = true;
          diagnostics?.record('resumeAccepted',
              {'offset': offset, 'hasStrongValidator': etag != null});
          sink = partial.openWrite(mode: FileMode.append);
          // Surface asynchronous disk errors while the network is still streaming.
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
                  'resumeOffset': offset,
                  'transferredBytes': received - offset,
                  'averageBytesPerSecond': (received - offset) * 1000 / nowMs,
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
            'resumeOffset': offset,
            'transferredBytes': received - offset,
            'chunks': chunks,
            'maximumChunkGapMs': maximumChunkGapMs,
            'flushWaitMs': diskClock?.elapsedMilliseconds,
          });
          _checkCancelled();
          if (received != package.size) throw const HttpException('更新包传输提前结束。');
          final hashClock = diagnostics == null ? null : (Stopwatch()..start());
          final valid = await _validFile(package, partial);
          _checkCancelled();
          if (!valid) throw const FormatException('更新包校验失败，已停止安装。');
          diagnostics?.record(
              'hashVerified', {'hashMs': hashClock?.elapsedMilliseconds});
          if (await destination.exists())
            throw const FileSystemException('缓存文件已存在，请重新下载。');
          await partial.rename(destination.path);
          retainPartial = false;
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
          retainPartial = retainPartial &&
              writeError == null &&
              e is! FormatException &&
              e is! FileSystemException &&
              (_cancelled ||
                  e is UpdateCancelled ||
                  e is SocketException ||
                  e is TimeoutException ||
                  e is HttpException);
          if (await partial.exists()) onProgress(await partial.length());
          if (_cancelled) throw UpdateCancelled();
          if (attempt == 2 ||
              (e is! SocketException &&
                  e is! TimeoutException &&
                  e is! HttpException)) rethrow;
          await Future<void>.delayed(
              Duration(milliseconds: 400 * (attempt + 1)));
        } finally {
          _client?.close(force: true);
          _client = null;
        }
      }
    } finally {
      try {
        if (!retainPartial) await discardPartial();
      } finally {
        _activeDownloads.remove(key);
        _client?.close(force: true);
        _client = null;
      }
    }
  }
}
