import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/platform/app_storage/portable_backup_repository.dart';
import 'package:lumio/platform/app_storage/webdav_backup_repository.dart';

class _Headers implements HttpHeaders {
  final values = <String, Object>{};
  @override
  ContentType? contentType;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.bytes);
  final List<int> bytes;
  @override
  final int statusCode;
  @override
  int get contentLength => bytes.length;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream.value(bytes).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.server, this.method, this.uri);
  final _Client server;
  final String method;
  final Uri uri;
  final bytes = <int>[];
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  int contentLength = -1;
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  void write(Object? value) => add(utf8.encode('$value'));
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<HttpClientResponse> close() async {
    expect(followRedirects, false);
    expect(
        headers.values[HttpHeaders.authorizationHeader], startsWith('Basic '));
    return server.reply(this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  final files = <String, List<int>>{};
  final methods = <String>[];
  int? failure;
  String? listing;
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = Duration.zero;
  @override
  int? maxConnectionsPerHost;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    if (closed) throw const SocketException('closed');
    methods.add(method);
    return _Request(this, method, uri);
  }

  HttpClientResponse reply(_Request request) {
    if (failure != null) return _Response(failure!, []);
    switch (request.method) {
      case 'PROPFIND':
        final xml = request.headers.values['Depth'] == '0'
            ? '<d:multistatus xmlns:d="DAV:"><d:response><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:response></d:multistatus>'
            : listing ??
                '<d:multistatus xmlns:d="DAV:">${files.keys.map((path) => '<d:response><d:href>$path</d:href></d:response>').join()}</d:multistatus>';
        return _Response(207, utf8.encode(xml));
      case 'MKCOL':
        return _Response(201, []);
      case 'PUT':
        files[request.uri.path] = request.bytes;
        return _Response(201, []);
      case 'MOVE':
        expect(request.headers.values['Overwrite'], 'F');
        final path =
            Uri.parse(request.headers.values['Destination'] as String).path;
        files[path] = files.remove(request.uri.path)!;
        return _Response(201, []);
      case 'GET':
        return _Response(files.containsKey(request.uri.path) ? 200 : 404,
            files[request.uri.path] ?? []);
      default:
        throw StateError(request.method);
    }
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  WebDavConfiguration config(
          {String endpoint = 'https://dav.example/dav/',
          String folder = 'LumioBackups'}) =>
      WebDavConfiguration(
          endpoint: endpoint,
          username: 'user',
          password: 'app-password',
          folder: folder);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lumio-webdav-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PortableBackupRepository.channel,
            (_) async => {'availableBytes': 1024 * 1024 * 1024});
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test('拒绝不安全地址和目录穿越', () {
    for (final endpoint in [
      'http://dav.example/',
      'https://user:pass@dav.example/',
      'https://dav.example/?token=a'
    ]) {
      expect(() => config(endpoint: endpoint).root, throwsFormatException);
    }
    expect(() => config(folder: '../backup').root, throwsFormatException);
    expect(config(folder: '忆光备份').directory.pathSegments, contains('忆光备份'));
  });
  test('临时上传 MOVE 最后发布清单，列出并校验下载', () async {
    final client = _Client();
    final repository =
        WebDavBackupRepository(config(), clientFactory: () => client);
    final source = File('${directory.path}/source.zip');
    final bytes = List.generate(1024, (i) => i % 251);
    await source.writeAsBytes(bytes);
    await repository.upload(source);
    expect(client.methods, ['PROPFIND', 'MKCOL', 'PUT', 'MOVE', 'PUT']);
    expect(client.files.keys.any((e) => e.endsWith('.upload')), false);
    final entries = await repository.list();
    expect(entries.length, 1);
    expect(entries.single.size, bytes.length);
    final destination = File('${directory.path}/download.zip');
    await repository.download(entries.single, destination);
    expect(await destination.readAsBytes(), bytes);
    final zipPath = client.files.keys.firstWhere((e) => e.endsWith('.zip'));
    client.files[zipPath]![0] ^= 1;
    await expectLater(repository.download(entries.single, destination),
        throwsFormatException);
    repository.close();
  });
  test('认证失败、跳转和取消不会继续请求', () async {
    for (final status in [401, 403, 302, 507]) {
      final client = _Client()..failure = status;
      final repository =
          WebDavBackupRepository(config(), clientFactory: () => client);
      await expectLater(repository.testConnection(), throwsStateError);
      expect(client.methods, ['PROPFIND']);
      repository.close();
    }
    final client = _Client();
    final repository =
        WebDavBackupRepository(config(), clientFactory: () => client);
    repository.close();
    await expectLater(repository.list(), throwsStateError);
    expect(client.methods, isEmpty);
  });
  test('列表忽略异域、目录外和不完整上传，拒绝实体 XML', () async {
    const name = 'Lumio-backup-1791500000000-abcdef12.zip.json';
    final client = _Client()
      ..listing = '<d:multistatus xmlns:d="DAV:">'
          '<d:response><d:href>https://evil.example/dav/LumioBackups/$name</d:href></d:response>'
          '<d:response><d:href>/other/$name</d:href></d:response>'
          '<d:response><d:href>/dav/LumioBackups/.$name.upload</d:href></d:response></d:multistatus>';
    final repository =
        WebDavBackupRepository(config(), clientFactory: () => client);
    expect(await repository.list(), isEmpty);
    client.listing = '<!DOCTYPE x [<!ENTITY a "x">]><x/>';
    await expectLater(repository.list(), throwsFormatException);
    repository.close();
  });
}
