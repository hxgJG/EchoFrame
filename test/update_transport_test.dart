import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/updates/update_manifest.dart';
import 'package:lumio/platform/app_update/update_transport.dart';

class _Headers implements HttpHeaders {
  _Headers([this.location]);
  final String? location;
  @override
  String? value(String name) =>
      name == HttpHeaders.locationHeader ? location : null;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.body,
      {this.statusCode = 200, this.contentLength = -1, String? location})
      : headers = _Headers(location);
  final Stream<List<int>> body;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final HttpHeaders headers;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      body.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final HttpClientResponse response;
  @override
  final HttpHeaders headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.reply);
  final Future<HttpClientResponse> Function(Uri) reply;
  final visited = <Uri>[];
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    visited.add(uri);
    return _Request(await reply(uri));
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  final bytes = utf8.encode('test package');
  UpdatePackage package({String? hash, int? size}) => UpdatePackage(
      platform: 'macos',
      architectures: ['arm64'],
      minimumOS: '13.0',
      fileName: 'fixture.zip',
      size: size ?? bytes.length,
      sha256: hash ?? sha256.convert(bytes).toString(),
      url: Uri.parse(
          'https://github.com/hxgJG/Lumio-Releases/releases/download/v1.0.1-2/fixture.zip'));
  setUp(() async =>
      root = await Directory.systemTemp.createTemp('lumio-update-test-'));
  tearDown(() async => root.delete(recursive: true));
  test('HTTPS 白名单拒绝用户信息、异域和非 TLS', () {
    for (final url in [
      'http://github.com/a',
      'https://github.com.evil.example/a',
      'https://user@github.com/a',
      'https://github.com:444/a'
    ]) {
      expect(UpdateTransport.trustedRedirect(Uri.parse(url)), false);
    }
    expect(
        UpdateTransport.trustedRedirect(Uri.parse(
            'https://release-assets.githubusercontent.com/a?token=x')),
        true);
  });
  test('流式下载验哈希并原子转为完整缓存', () async {
    final transport = UpdateTransport(
        clientFactory: () => _Client((_) async => _Response(
            Stream.fromIterable(
                [bytes.take(3).toList(), bytes.skip(3).toList()]),
            contentLength: bytes.length)));
    final file = File('${root.path}/update.zip');
    var progress = 0;
    await transport.download(package(), file, (n) => progress = n);
    expect(await file.readAsBytes(), bytes);
    expect(progress, bytes.length);
    expect(File('${file.path}.part').existsSync(), false);
  });
  test('坏哈希 不足长度 超出长度均不留下可安装文件', () async {
    for (final p in [
      package(hash: '0' * 64),
      package(size: bytes.length + 1),
      package(size: bytes.length - 1)
    ]) {
      final transport = UpdateTransport(
          clientFactory: () =>
              _Client((_) async => _Response(Stream.value(bytes))));
      final file = File('${root.path}/update.zip');
      await expectLater(
          transport.download(p, file, (_) {}), throwsFormatException);
      expect(file.existsSync(), false);
      expect(File('${file.path}.part').existsSync(), false);
    }
  });
  test('取消清理 partial', () async {
    late UpdateTransport transport;
    Stream<List<int>> body() async* {
      yield bytes.take(3).toList();
      yield bytes.skip(3).toList();
    }

    transport = UpdateTransport(
        clientFactory: () => _Client((_) async => _Response(body())));
    final file = File('${root.path}/update.zip');
    await expectLater(
        transport.download(package(), file, (_) => transport.cancel()),
        throwsA(isA<UpdateCancelled>()));
    expect(file.existsSync(), false);
    expect(File('${file.path}.part').existsSync(), false);
  });
  test('网络中断最多三次并清理；文件错误不重试', () async {
    var requests = 0;
    final transport = UpdateTransport(
        clientFactory: () => _Client((_) async {
              requests++;
              throw const SocketException('offline');
            }));
    await expectLater(
        transport.download(package(), File('${root.path}/update.zip'), (_) {}),
        throwsA(isA<SocketException>()));
    expect(requests, 3);
    requests = 0;
    final wrong = UpdateTransport(
        clientFactory: () => _Client((_) async {
              requests++;
              return _Response(Stream.value(bytes));
            }));
    await expectLater(
        wrong.download(
            package(hash: '0' * 64), File('${root.path}/update.zip'), (_) {}),
        throwsFormatException);
    expect(requests, 1);
  });
  test('拒绝不可信重定向和过大清单，未发布单独识别', () async {
    final client = _Client((_) async => _Response(const Stream.empty(),
        statusCode: 302, location: 'https://evil.example/a'));
    await expectLater(
        UpdateTransport(clientFactory: () => client)
            .smallFile(package().url, 64),
        throwsFormatException);
    expect(client.visited.length, 1);
    final large = UpdateTransport(
        clientFactory: () =>
            _Client((_) async => _Response(Stream.value(List.filled(65, 1)))));
    await expectLater(
        large.smallFile(package().url, 64), throwsFormatException);
    final unpublished = UpdateTransport(
        clientFactory: () => _Client(
            (_) async => _Response(const Stream.empty(), statusCode: 404)));
    await expectLater(unpublished.smallFile(package().url, 64),
        throwsA(isA<UpdateNotPublished>()));
  });
}
