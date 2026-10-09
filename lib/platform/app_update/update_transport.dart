import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/updates/update_manifest.dart';

class UpdateNotPublished implements Exception {}

class UpdateCancelled implements Exception {}

class UpdateTransport {
  UpdateTransport({HttpClient Function()? clientFactory})
      : _makeClient = clientFactory ?? HttpClient.new;
  final HttpClient Function() _makeClient;
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

  Future<HttpClientResponse> _open(Uri uri) async {
    final client = _client ??= _makeClient()
      ..connectionTimeout = const Duration(seconds: 20);
    for (var i = 0; i < 6; i++) {
      _checkCancelled();
      if (!trustedRedirect(uri))
        throw const FormatException('下载重定向不在可信 HTTPS 域名内。');
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 25));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Lumio-Updates/1');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response =
          await request.close().timeout(const Duration(seconds: 25));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) throw const FormatException('下载重定向缺少目标。');
        // Discard redirect bodies without waiting for an unbounded server stream.
        await response.listen((_) {}).cancel();
        uri = uri.resolve(location);
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
          var received = 0;
          var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
          await for (final bytes
              in response.timeout(const Duration(seconds: 30))) {
            _checkCancelled();
            if (writeError != null) throw writeError!;
            received += bytes.length;
            if (received > package.size)
              throw const FormatException('更新包超过清单大小。');
            sink.add(bytes);
            // Keep memory bounded even if storage is slower than the network.
            await sink.flush();
            final now = DateTime.now();
            if (now.difference(lastReport).inMilliseconds >= 200) {
              onProgress(received);
              lastReport = now;
            }
          }
          await sink.close();
          sink = null;
          _checkCancelled();
          if (received != package.size)
            throw const FormatException('更新包下载不完整。');
          final path = partial.path;
          final digest = await Isolate.run(() async =>
              (await sha256.bind(File(path).openRead()).first).toString());
          _checkCancelled();
          if (digest != package.sha256)
            throw const FormatException('更新包校验失败，已停止安装。');
          if (await destination.exists())
            throw const FileSystemException('缓存文件已存在，请重新下载。');
          await partial.rename(destination.path);
          onProgress(received);
          return;
        } on Object catch (e) {
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
