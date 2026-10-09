import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../../core/backup/portable_backup_format.dart';
import 'portable_backup_repository.dart';

const _cloudLimit = portableMetadataLimit + 4 * 1024 * 1024;
const _timeout = Duration(seconds: 30);
final _name = RegExp(r'^Lumio-backup-([0-9]{13})-[a-f0-9]{8}\.zip$');

class WebDavConfiguration {
  WebDavConfiguration(
      {required this.endpoint,
      required this.username,
      required this.password,
      this.folder = 'LumioBackups'});
  final String endpoint, username, password, folder;
  Uri get root {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请填写 HTTPS WebDAV 地址，不要包含账号、参数或片段。');
    }
    if (username.trim().isEmpty ||
        username.contains(':') ||
        username.contains('\n') ||
        password.isEmpty ||
        username.length > 1024 ||
        password.length > 4096 ||
        endpoint.length > 4096 ||
        !RegExp(r'^[\p{L}\p{N}_-]{1,64}$', unicode: true).hasMatch(folder)) {
      throw const FormatException('请填写账号和应用密码；目录名仅支持文字、数字、下划线或短横线（最多 64 字）。');
    }
    return uri.replace(
        path: uri.path.endsWith('/') ? uri.path : '${uri.path}/');
  }

  Uri get directory => root.resolve('${Uri.encodeComponent(folder)}/');
  Map<String, Object?> toJson() => {
        'endpoint': endpoint,
        'username': username,
        'password': password,
        'folder': folder
      };
  factory WebDavConfiguration.fromJson(Map value) => WebDavConfiguration(
      endpoint: value['endpoint'] as String,
      username: value['username'] as String,
      password: value['password'] as String,
      folder: value['folder'] as String? ?? 'LumioBackups');
  static Future<WebDavConfiguration?> load() async {
    final value = await PortableBackupRepository.channel
        .invokeMapMethod('loadWebDavConfiguration');
    return value == null ? null : WebDavConfiguration.fromJson(value);
  }

  Future<void> save() async {
    root;
    await PortableBackupRepository.channel
        .invokeMethod('saveWebDavConfiguration', {'configuration': toJson()});
  }

  static Future<void> forget() => PortableBackupRepository.channel
      .invokeMethod<void>('saveWebDavConfiguration', {'configuration': null});
}

class CloudBackupEntry {
  CloudBackupEntry(
      this.name, this.createdAt, this.size, this.digest, this.platform);
  final String name, digest, platform;
  final DateTime createdAt;
  final int size;
  factory CloudBackupEntry.parse(String name, List<int> bytes) {
    final value = jsonDecode(utf8.decode(bytes)) as Map;
    if (!_name.hasMatch(name) ||
        value['format'] != 'lumio-cloud-backup' ||
        value['version'] != 1 ||
        value['backupVersion'] != 2 ||
        value['mediaMode'] != 'references' ||
        value['name'] != name ||
        value['size'] is! int ||
        value['size'] < 22 ||
        value['size'] > _cloudLimit ||
        value['createdAtMs'] is! int ||
        value['createdAtMs'].toString() != _name.firstMatch(name)!.group(1) ||
        value['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sha256'])) {
      throw const FormatException('云端备份清单无效。');
    }
    return CloudBackupEntry(
        name,
        DateTime.fromMillisecondsSinceEpoch(value['createdAtMs']),
        value['size'],
        value['sha256'],
        value['platform']?.toString() ?? '未知平台');
  }
}

typedef BackupProgress = void Function(String stage, int completed, int total);

class WebDavBackupRepository {
  WebDavBackupRepository(this.configuration,
      {HttpClient Function()? clientFactory})
      : _client = (clientFactory ?? HttpClient.new)() {
    configuration.root;
    _client.connectionTimeout = _timeout;
    _client.idleTimeout = _timeout;
    _client.maxConnectionsPerHost = 2;
  }
  final WebDavConfiguration configuration;
  final HttpClient _client;
  bool _cancelled = false;
  void close() {
    _cancelled = true;
    _client.close(force: true);
  }

  void _check() {
    if (_cancelled) throw StateError('已取消云备份操作。');
  }

  Uri _file(String name) =>
      configuration.directory.resolve(Uri.encodeComponent(name));

  Future<HttpClientRequest> _request(String method, Uri uri) async {
    _check();
    final request = await _client.openUrl(method, uri).timeout(_timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('${configuration.username}:${configuration.password}'))}');
    return request;
  }

  void _status(int status, Set<int> expected) {
    _check();
    if (expected.contains(status)) return;
    final message = switch (status) {
      401 || 403 => '认证失败或无权限，请检查 WebDAV 账号、应用密码及目录权限。',
      404 => 'WebDAV 地址或备份目录不存在。',
      409 => '上级目录不存在，请检查 WebDAV 根地址。',
      412 => '云端文件名冲突，未覆盖旧备份，请重试。',
      423 => '云端文件被锁定，请稍后重试。',
      429 => '请求过于频繁，请稍后重试。',
      507 => '云端存储空间或额度不足。',
      >= 300 && < 400 => '服务器要求跳转。为保护应用密码已停止，请填写最终 HTTPS WebDAV 地址。',
      _ => 'WebDAV 操作失败（HTTP $status）。',
    };
    throw StateError(message);
  }

  Future<List<int>> _small(HttpClientResponse response, int limit) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      _check();
      if (bytes.length + chunk.length > limit)
        throw const FormatException('云端响应超过限制。');
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Future<void> _discard(HttpClientResponse response) async {
    await _small(response, 64 * 1024);
  }

  Future<void> testConnection() async {
    final request = await _request('PROPFIND', configuration.root);
    request.headers.set('Depth', '0');
    request.headers.contentType =
        ContentType('application', 'xml', charset: 'utf-8');
    request.write(_propfind);
    final response = await request.close().timeout(_timeout);
    _status(response.statusCode, {207});
    final document = _xml(await _small(response, 2 * 1024 * 1024));
    if (!document.descendants
        .whereType<XmlElement>()
        .any((e) => e.name.local == 'collection')) {
      throw const FormatException('WebDAV 地址不是可用目录。');
    }
  }

  Future<void> _ensureDirectory() async {
    final request = await _request('MKCOL', configuration.directory);
    final response = await request.close().timeout(_timeout);
    _status(response.statusCode, {201, 405});
    await _discard(response);
  }

  XmlDocument _xml(List<int> bytes) {
    final text = utf8.decode(bytes);
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
      throw const FormatException('不支持包含外部实体的 WebDAV 响应。');
    }
    return XmlDocument.parse(text);
  }

  Future<List<CloudBackupEntry>> list() async {
    final request = await _request('PROPFIND', configuration.directory);
    request.headers.set('Depth', '1');
    request.headers.contentType =
        ContentType('application', 'xml', charset: 'utf-8');
    request.write(_propfind);
    final response = await request.close().timeout(_timeout);
    if (response.statusCode == 404) {
      await _discard(response);
      return [];
    }
    _status(response.statusCode, {207});
    final document = _xml(await _small(response, 2 * 1024 * 1024));
    final names = <String>{};
    for (final element in document.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'href')) {
      final uri = configuration.directory.resolve(element.innerText);
      if (uri.origin != configuration.directory.origin ||
          uri.hasQuery ||
          uri.hasFragment) continue;
      final parts = uri.pathSegments;
      if (parts.isEmpty) continue;
      final name = parts.last;
      if (!name.endsWith('.zip.json')) continue;
      final zipName = name.substring(0, name.length - 5);
      if (_name.hasMatch(zipName) && uri.path == _file(name).path)
        names.add(zipName);
    }
    final recent = names.toList()..sort((a, b) => b.compareTo(a));
    final entries = <CloudBackupEntry>[];
    // A bounded listing also respects providers with tight WebDAV request quotas.
    for (final name in recent.take(50)) {
      final request = await _request('GET', _file('$name.json'));
      final response = await request.close().timeout(_timeout);
      _status(response.statusCode, {200});
      entries.add(CloudBackupEntry.parse(name, await _small(response, 8192)));
    }
    return entries;
  }

  Future<String> upload(File file, {BackupProgress? progress}) async {
    final size = await file.length();
    if (size < 22 || size > _cloudLimit)
      throw const FormatException('云备份只支持最多 132 MiB 的应用数据包。');
    await testConnection();
    await _ensureDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final token = List.generate(4, (_) => Random.secure().nextInt(256))
        .map((e) => e.toRadixString(16).padLeft(2, '0'))
        .join();
    final name = 'Lumio-backup-$stamp-$token.zip';
    final temporary = '.$name.upload';
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final request = await _request('PUT', _file(temporary));
    request.contentLength = size;
    request.headers.contentType = ContentType('application', 'zip');
    var completed = 0;
    await request
        .addStream(file.openRead().map((chunk) {
          _check();
          completed += chunk.length;
          progress?.call('上传数据', completed, size);
          return chunk;
        }))
        .timeout(const Duration(minutes: 10));
    final response = await request.close().timeout(_timeout);
    _status(response.statusCode, {200, 201, 204});
    await _discard(response);
    final move = await _request('MOVE', _file(temporary));
    move.headers.set('Destination', _file(name).toString());
    move.headers.set('Overwrite', 'F');
    final moved = await move.close().timeout(_timeout);
    _status(moved.statusCode, {201, 204});
    await _discard(moved);
    // Publish the catalog entry last; interrupted uploads never appear restorable.
    final metadata = utf8.encode(jsonEncode({
      'format': 'lumio-cloud-backup',
      'version': 1,
      'backupVersion': 2,
      'mediaMode': 'references',
      'name': name,
      'size': size,
      'sha256': digest,
      'createdAtMs': stamp,
      'platform': Platform.operatingSystem,
    }));
    final manifest = await _request('PUT', _file('$name.json'));
    manifest.headers.set('If-None-Match', '*');
    manifest.contentLength = metadata.length;
    manifest.headers.contentType = ContentType('application', 'json');
    manifest.add(metadata);
    final published = await manifest.close().timeout(_timeout);
    _status(published.statusCode, {200, 201, 204});
    await _discard(published);
    progress?.call('上传完成', size, size);
    return name;
  }

  Future<void> download(CloudBackupEntry entry, File destination,
      {BackupProgress? progress}) async {
    if (!_name.hasMatch(entry.name) ||
        entry.size > _cloudLimit ||
        entry.size < 22) {
      throw const FormatException('云端备份条目无效。');
    }
    final env = await PortableBackupRepository().environment();
    if ((env['availableBytes'] as int) < entry.size + 64 * 1024 * 1024) {
      throw StateError('本机临时空间不足。');
    }
    final request = await _request('GET', _file(entry.name));
    final response = await request.close().timeout(_timeout);
    _status(response.statusCode, {200});
    if (response.contentLength != -1 && response.contentLength != entry.size) {
      throw const FormatException('云端文件大小与清单不一致。');
    }
    final output = await destination.open(mode: FileMode.write);
    var completed = 0;
    try {
      await for (final chunk in response.timeout(_timeout)) {
        _check();
        completed += chunk.length;
        if (completed > entry.size) throw const FormatException('云端文件超过清单大小。');
        await output.writeFrom(chunk);
        progress?.call('下载数据', completed, entry.size);
      }
    } finally {
      await output.close();
    }
    if (completed != entry.size ||
        (await sha256.bind(destination.openRead()).first).toString() !=
            entry.digest) {
      throw const FormatException('云端备份校验失败，未导入。');
    }
  }
}

const _propfind = '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>';
