import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/updates/update_manifest.dart';
import 'package:lumio/platform/app_update/update_transport.dart';
import 'package:lumio/platform/app_update/update_diagnostics.dart';

class _Headers implements HttpHeaders {
  _Headers([this.location, Map<String, String>? initial])
      : values = {...?initial};
  final String? location;
  final Map<String, String> values;
  @override
  String? value(String name) =>
      name == HttpHeaders.locationHeader ? location : values[name];
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.body,
      {this.statusCode = 200,
      this.contentLength = -1,
      String? location,
      Map<String, String>? headerValues})
      : headers = _Headers(location, headerValues);
  final Stream<List<int>> body;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final HttpHeaders headers;
  @override
  HttpConnectionInfo? get connectionInfo => null;
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
  final requests = <_Request>[];
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    visited.add(uri);
    final request = _Request(await reply(uri));
    requests.add(request);
    return request;
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
  test('诊断记录原下载器耗时与字节数，不保留重定向签名参数', () async {
    final diagnostics = UpdateDiagnostics();
    final asset = Uri.parse(
        'https://release-assets.githubusercontent.com/a?token=secret');
    final client = _Client((uri) async => uri.host == 'github.com'
        ? _Response(const Stream.empty(),
            statusCode: 302, location: asset.toString())
        : _Response(Stream.value(bytes), contentLength: bytes.length));
    await UpdateTransport(clientFactory: () => client, diagnostics: diagnostics)
        .download(package(), File('${root.path}/update.zip'), (_) {});
    final snapshot = diagnostics.snapshot();
    expect(jsonEncode(snapshot), isNot(contains('secret')));
    final events = (snapshot['events'] as List).cast<Map<String, Object?>>();
    expect(events.where((e) => e['type'] == 'responseHeaders').length, 2);
    expect(
        events.singleWhere((e) => e['type'] == 'bodyComplete')['receivedBytes'],
        bytes.length);
    expect(events.last['type'], 'hashVerified');
    expect(await File('${root.path}/update.zip').readAsBytes(), bytes);
  });
  test('坏哈希和超出长度均清理不可安装文件', () async {
    for (final p in [
      package(hash: '0' * 64),
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
  test('暂停保留 partial，重新创建下载器后跨重定向续传', () async {
    late UpdateTransport transport;
    Stream<List<int>> body() async* {
      yield bytes.take(3).toList();
      yield bytes.skip(3).toList();
    }

    transport = UpdateTransport(
        clientFactory: () => _Client((_) async => _Response(body())));
    final file = File('${root.path}/update.zip');
    await expectLater(
        transport.download(package(), file, (n) {
          if (n > 0) transport.cancel();
        }),
        throwsA(isA<UpdateCancelled>()));
    expect(file.existsSync(), false);
    expect(
        await File('${file.path}.part').readAsBytes(), bytes.take(3).toList());
    expect(await UpdateTransport.retainedBytes(package(), file), 3);
    final client = _Client((uri) async => uri.host == 'github.com'
        ? _Response(const Stream.empty(),
            statusCode: 302,
            location:
                'https://release-assets.githubusercontent.com/a?signature=new')
        : _Response(Stream.value(bytes.skip(3).toList()),
            statusCode: 206,
            contentLength: bytes.length - 3,
            headerValues: {
                'content-range': 'bytes 3-${bytes.length - 1}/${bytes.length}'
              }));
    await UpdateTransport(clientFactory: () => client)
        .download(package(), file, (_) {});
    expect(await file.readAsBytes(), bytes);
    expect(client.requests.every((r) => r.headers.value('range') == 'bytes=3-'),
        true);
    expect(File('${file.path}.part.json').existsSync(), false);
  });
  test('连接失败最多三次；文件错误不重试', () async {
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

  Future<File> seedPartial({int count = 3, String? etag, String? hash}) async {
    final file = File('${root.path}/resume.zip');
    await File('${file.path}.part').writeAsBytes(bytes.take(count).toList());
    await File('${file.path}.part.json').writeAsString(jsonEncode({
      'schemaVersion': 1,
      'size': bytes.length,
      'sha256': hash ?? package().sha256,
      if (etag != null) 'etag': etag,
    }));
    return file;
  }

  test('网络中断从已写入位置自动续传，强 ETag 发送 If-Range', () async {
    Stream<List<int>> broken() async* {
      yield bytes.take(3).toList();
      throw const SocketException('network changed');
    }

    var count = 0;
    final diagnostics = UpdateDiagnostics();
    final client = _Client((_) async => ++count == 1
        ? _Response(broken(),
            contentLength: bytes.length, headerValues: {'etag': '"fixture"'})
        : _Response(Stream.value(bytes.skip(3).toList()),
            statusCode: 206,
            contentLength: bytes.length - 3,
            headerValues: {
                'etag': '"fixture"',
                'content-range': 'bytes 3-${bytes.length - 1}/${bytes.length}',
              }));
    final file = File('${root.path}/resume.zip');
    await UpdateTransport(clientFactory: () => client, diagnostics: diagnostics)
        .download(package(), file, (_) {});
    expect(await file.readAsBytes(), bytes);
    expect(client.requests.last.headers.value('range'), 'bytes=3-');
    expect(client.requests.last.headers.value('if-range'), '"fixture"');
    final events = (diagnostics.snapshot()['events'] as List).cast<Map>();
    expect(events.singleWhere((e) => e['type'] == 'attemptFailed')['errorType'],
        'SocketException');
    expect(
        events
            .lastWhere((e) => e['type'] == 'bodyComplete')['transferredBytes'],
        bytes.length - 3);
  });

  test('服务器忽略 Range 返回 200 时截断旧缓存，不追加整包', () async {
    final file = await seedPartial(etag: '"old"');
    final client = _Client((_) async =>
        _Response(Stream.value(bytes), contentLength: bytes.length));
    await UpdateTransport(clientFactory: () => client)
        .download(package(), file, (_) {});
    expect(client.requests.single.headers.value('range'), 'bytes=3-');
    expect(await file.readAsBytes(), bytes);
  });

  test('416、错位范围、错误总长、ETag 改变均安全回退整包', () async {
    for (final bad in [
      _Response(const Stream.empty(), statusCode: 416),
      _Response(const Stream.empty(), statusCode: 206, headerValues: {
        'content-range': 'bytes 2-${bytes.length - 1}/${bytes.length}'
      }),
      _Response(const Stream.empty(), statusCode: 206, headerValues: {
        'content-range': 'bytes 3-${bytes.length}/${bytes.length + 1}'
      }),
      _Response(const Stream.empty(), statusCode: 206, headerValues: {
        'content-range': 'bytes 3-${bytes.length - 1}/${bytes.length}',
        'etag': '"changed"'
      }),
    ]) {
      final file = await seedPartial(etag: '"fixture"');
      if (await file.exists()) await file.delete();
      var count = 0;
      final client = _Client((_) async => ++count == 1
          ? bad
          : _Response(Stream.value(bytes), contentLength: bytes.length));
      await UpdateTransport(clientFactory: () => client)
          .download(package(), file, (_) {});
      expect(client.requests.length, 2);
      expect(client.requests.last.headers.value('range'), null);
      expect(await file.readAsBytes(), bytes);
    }
  });

  test('弱 ETag 不作为 If-Range，完整哈希仍校验续传结果', () async {
    final file = await seedPartial(etag: 'W/"fixture"');
    final client = _Client((_) async => _Response(
            Stream.value(bytes.skip(3).toList()),
            statusCode: 206,
            headerValues: {
              'content-range': 'bytes 3-${bytes.length - 1}/${bytes.length}'
            }));
    await UpdateTransport(clientFactory: () => client)
        .download(package(), file, (_) {});
    expect(client.requests.single.headers.value('if-range'), null);
    expect(await file.readAsBytes(), bytes);
  });

  test('不同包、过期缓存不续传，完整已下载缓存离线验哈希复用', () async {
    for (final expired in [false, true]) {
      final file = await seedPartial(hash: expired ? null : '0' * 64);
      if (await file.exists()) await file.delete();
      if (expired)
        await File('${file.path}.part')
            .setLastModified(DateTime.now().subtract(const Duration(days: 8)));
      final client = _Client((_) async => _Response(Stream.value(bytes)));
      await UpdateTransport(clientFactory: () => client)
          .download(package(), file, (_) {});
      expect(client.requests.single.headers.value('range'), null);
      final offline =
          _Client((_) async => throw const SocketException('offline'));
      await UpdateTransport(clientFactory: () => offline)
          .download(package(), file, (_) {});
      expect(offline.visited, isEmpty);
      expect(await file.readAsBytes(), bytes);
    }
  });

  test('所有网络重试失败保留 partial，下次可继续；坏拼接结果清理', () async {
    final file = await seedPartial();
    final offline =
        _Client((_) async => throw const SocketException('offline'));
    await expectLater(
        UpdateTransport(clientFactory: () => offline)
            .download(package(), file, (_) {}),
        throwsA(isA<SocketException>()));
    expect(offline.visited.length, 3);
    expect(await UpdateTransport.retainedBytes(package(), file), 3);
    final wrong = _Client((_) async => _Response(
            Stream.value(List.filled(bytes.length - 3, 0)),
            statusCode: 206,
            headerValues: {
              'content-range': 'bytes 3-${bytes.length - 1}/${bytes.length}'
            }));
    await expectLater(
        UpdateTransport(clientFactory: () => wrong)
            .download(package(), file, (_) {}),
        throwsFormatException);
    expect(file.existsSync(), false);
    expect(File('${file.path}.part').existsSync(), false);
  });

  test('正常结束但不足长度按中断处理，后续请求继续剩余字节', () async {
    var count = 0;
    final client = _Client((_) async => ++count == 1
        ? _Response(Stream.value(bytes.take(3).toList()))
        : _Response(Stream.value(bytes.skip(3).toList()),
            statusCode: 206,
            headerValues: {
                'content-range': 'bytes 3-${bytes.length - 1}/${bytes.length}'
              }));
    final file = File('${root.path}/resume.zip');
    await UpdateTransport(clientFactory: () => client)
        .download(package(), file, (_) {});
    expect(await file.readAsBytes(), bytes);
    expect(client.requests.length, 2);
    expect(client.requests.last.headers.value('range'), 'bytes=3-');
  });

  test('完整 partial 在暂停后无需网络，验哈希再转为完整缓存', () async {
    final file = await seedPartial(count: bytes.length);
    final client = _Client((_) async => throw const SocketException('offline'));
    await UpdateTransport(clientFactory: () => client)
        .download(package(), file, (_) {});
    expect(client.visited, isEmpty);
    expect(await file.readAsBytes(), bytes);
    expect(File('${file.path}.part.json').existsSync(), false);
  });

  test('损坏的完整 partial、不符长度和压缩响应拒绝安装并清理', () async {
    for (final mode in ['corrupt', 'length', 'encoding']) {
      final file =
          await seedPartial(count: mode == 'corrupt' ? bytes.length : 3);
      if (mode == 'corrupt')
        await File('${file.path}.part')
            .writeAsBytes(List.filled(bytes.length, 0));
      final client = _Client((_) async => _Response(
              Stream.value(bytes.skip(3).toList()),
              statusCode: 206,
              contentLength: mode == 'length' ? 999 : bytes.length - 3,
              headerValues: {
                'content-range': 'bytes 3-${bytes.length - 1}/${bytes.length}',
                if (mode == 'encoding') 'content-encoding': 'gzip',
              }));
      await expectLater(
          UpdateTransport(clientFactory: () => client)
              .download(package(), file, (_) {}),
          throwsFormatException);
      expect(file.existsSync(), false);
      expect(File('${file.path}.part').existsSync(), false);
    }
  });

  test('同一缓存不允许两个下载器同时写入', () async {
    final response = Completer<HttpClientResponse>();
    final client = _Client((_) => response.future);
    final file = File('${root.path}/resume.zip');
    final first = UpdateTransport(clientFactory: () => client)
        .download(package(), file, (_) {});
    await expectLater(
        UpdateTransport(clientFactory: () => client)
            .download(package(), file, (_) {}),
        throwsA(isA<UpdateDownloadBusy>()));
    response.complete(_Response(Stream.value(bytes)));
    await first;
    expect(await file.readAsBytes(), bytes);
    expect(client.visited.length, 1);
  });
}
