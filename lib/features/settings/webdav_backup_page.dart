import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../platform/app_storage/portable_backup_repository.dart';
import '../../platform/app_storage/webdav_backup_repository.dart';
import '../../shared/widgets/portable_backup_action.dart';

class WebDavBackupPage extends StatefulWidget {
  const WebDavBackupPage({super.key, required this.state});
  final LumioAppState state;
  @override
  State<WebDavBackupPage> createState() => _WebDavBackupPageState();
}

class _WebDavBackupPageState extends State<WebDavBackupPage> {
  final _endpoint =
      TextEditingController(text: 'https://dav.jianguoyun.com/dav/');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _folder = TextEditingController(text: 'LumioBackups');
  List<CloudBackupEntry> _entries = [];
  WebDavBackupRepository? _operation;
  bool _busy = false, _loading = true, _cancelled = false;
  String? _message;
  double? _progress;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = await WebDavConfiguration.load();
      if (!mounted) return;
      if (config != null) {
        _endpoint.text = config.endpoint;
        _username.text = config.username;
        _password.text = config.password;
        _folder.text = config.folder;
      }
    } catch (_) {
      if (mounted) _message = '无法读取本机配置，请重新填写。';
    }
    if (mounted) setState(() => _loading = false);
  }

  WebDavConfiguration get _config => WebDavConfiguration(
      endpoint: _endpoint.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      folder: _folder.text.trim());

  Future<void> _run(
      Future<void> Function(WebDavBackupRepository repository) action) async {
    if (_busy || _loading || widget.state.portableBackupBusy) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _progress = null;
      _message = '正在处理…';
    });
    WebDavBackupRepository? repository;
    try {
      repository = WebDavBackupRepository(_config);
      _operation = repository;
      await action(repository);
    } catch (error) {
      if (mounted)
        setState(() {
          _message = _cancelled ? '已取消，未恢复任何数据。上传如已完成，可刷新列表核对。' : '$error';
        });
    } finally {
      repository?.close();
      _operation = null;
      if (mounted)
        setState(() {
          _busy = false;
          _progress = null;
        });
    }
  }

  void _onProgress(String stage, int completed, int total) {
    final now = DateTime.now();
    if (!mounted ||
        now.difference(_lastProgress).inMilliseconds < 200 &&
            completed != total) return;
    _lastProgress = now;
    setState(() {
      _message = stage;
      _progress = total > 0 ? (completed / total).clamp(0.0, 1.0) : null;
    });
  }

  Future<void> _upload(WebDavBackupRepository repository) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('上传应用数据备份'),
              content: const Text(
                  '仅上传设置、歌词、歌单、收藏、播放记录等应用数据，不包含音视频或封面原文件。不会删除或覆盖已有云端备份。\n\n备份未加密，请仅使用你信任的 WebDAV 服务。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('上传'))
              ],
            ));
    if (confirmed != true || !mounted || _cancelled) return;
    PreparedPortableBackup? prepared;
    try {
      setState(() => _message = '正在生成应用数据包和文件指纹，不会打包音视频…');
      prepared = await widget.state.prepareCloudBackup();
      if (_cancelled || !mounted) return;
      await repository.upload(prepared.file, progress: _onProgress);
      if (mounted) setState(() => _message = '备份上传成功。点击刷新查看云端历史。');
    } finally {
      try {
        await prepared?.dispose();
      } finally {
        if (prepared != null) widget.state.endPortableBackup();
      }
    }
  }

  Future<void> _download(
      WebDavBackupRepository repository, CloudBackupEntry entry) async {
    PortableBackupPreview? preview;
    try {
      preview = await widget.state.receiveCloudBackup(
          (file) => repository.download(entry, file, progress: _onProgress));
      if (!mounted || _cancelled) return;
      await confirmPortableBackupImport(context, widget.state, preview);
      if (mounted) setState(() => _message = widget.state.backupStatusMessage);
    } finally {
      if (preview != null) {
        try {
          await preview.directory.delete(recursive: true);
        } finally {
          widget.state.endPortableBackup();
        }
      }
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    _operation?.close();
    for (final field in [_endpoint, _username, _password, _folder]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('云端备份（WebDAV）')),
        body: AnimatedBuilder(
            animation: widget.state,
            builder: (context, _) {
              final disabled =
                  _loading || _busy || widget.state.portableBackupBusy;
              return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                      child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                              'macOS 与 Android 使用同一数据格式。仅备份应用数据，音视频文件需要另行保存或在新设备重新添加。'),
                          const SizedBox(height: 16),
                          TextField(
                              controller: _endpoint,
                              enabled: !disabled,
                              keyboardType: TextInputType.url,
                              decoration: const InputDecoration(
                                  labelText: 'WebDAV HTTPS 地址',
                                  border: OutlineInputBorder())),
                          const SizedBox(height: 12),
                          TextField(
                              controller: _username,
                              enabled: !disabled,
                              autofillHints: const [],
                              decoration: const InputDecoration(
                                  labelText: '账号（坚果云为邮箱）',
                                  border: OutlineInputBorder())),
                          const SizedBox(height: 12),
                          TextField(
                              controller: _password,
                              enabled: !disabled,
                              obscureText: true,
                              enableSuggestions: false,
                              autocorrect: false,
                              autofillHints: const [],
                              decoration: const InputDecoration(
                                  labelText: 'WebDAV 应用密码',
                                  helperText: '坚果云需在安全设置中创建第三方应用密码，不要使用登录密码。',
                                  border: OutlineInputBorder())),
                          const SizedBox(height: 12),
                          TextField(
                              controller: _folder,
                              enabled: !disabled,
                              decoration: const InputDecoration(
                                  labelText: '备份目录（根地址下一级）',
                                  border: OutlineInputBorder())),
                          const SizedBox(height: 10),
                          Text(
                              '应用密码仅存本机，不进入备份；macOS 使用仅当前用户可读写的配置文件，Android 使用应用私有目录。卸载或换设备后需重新配置。',
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 16),
                          Wrap(spacing: 10, runSpacing: 10, children: [
                            FilledButton.icon(
                                onPressed: disabled
                                    ? null
                                    : () => _run((repository) async {
                                          await repository.testConnection();
                                          if (_cancelled) return;
                                          await _config.save();
                                          if (mounted)
                                            setState(() =>
                                                _message = '连接正常，配置已保存到本机。');
                                        }),
                                icon: const Icon(Icons.verified_user_outlined),
                                label: const Text('保存并测试连接')),
                            OutlinedButton(
                                onPressed: disabled
                                    ? null
                                    : () async {
                                        await WebDavConfiguration.forget();
                                        if (mounted)
                                          setState(() {
                                            _password.clear();
                                            _entries = [];
                                            _message = '已清除本机配置，未删除云端备份。';
                                          });
                                      },
                                child: const Text('清除本机配置')),
                          ]),
                          const Divider(height: 36),
                          Wrap(spacing: 10, runSpacing: 10, children: [
                            FilledButton.icon(
                                onPressed:
                                    disabled ? null : () => _run(_upload),
                                icon: const Icon(Icons.cloud_upload_outlined),
                                label: const Text('上传当前数据')),
                            OutlinedButton.icon(
                                onPressed: disabled
                                    ? null
                                    : () => _run((repository) async {
                                          final entries =
                                              await repository.list();
                                          if (mounted)
                                            setState(() {
                                              _entries = entries;
                                              _message = entries.isEmpty
                                                  ? '尚无完整的云端备份，可上传当前数据。'
                                                  : '已列出最近 ${entries.length} 个备份（最多 50 个）。';
                                            });
                                        }),
                                icon: const Icon(Icons.refresh),
                                label: const Text('刷新云端备份')),
                          ]),
                          if (_message != null)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: SelectableText(_message!)),
                          if (_busy) ...[
                            LinearProgressIndicator(value: _progress),
                            TextButton(
                                onPressed: _cancelled
                                    ? null
                                    : () {
                                        setState(() => _cancelled = true);
                                        _operation?.close();
                                      },
                                child: const Text('取消网络操作')),
                          ],
                          for (final entry in _entries)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.cloud_done_outlined),
                              title: Text(entry.createdAt
                                  .toLocal()
                                  .toString()
                                  .split('.')
                                  .first),
                              subtitle: Text(
                                  '${entry.platform} · ${(entry.size / 1024 / 1024).toStringAsFixed(2)} MiB · 仅应用数据'),
                              trailing: OutlinedButton(
                                  onPressed: disabled
                                      ? null
                                      : () => _run((repository) =>
                                          _download(repository, entry)),
                                  child: const Text('下载并恢复')),
                            ),
                          const SizedBox(height: 12),
                          const Text(
                              '这是手动备份，不是实时同步。恢复前会校验完整性并再次确认覆盖；不会自动播放。音视频未匹配时保留记录，后续扫描继续关联。服务器容量、流量和请求次数以服务商规则为准。'),
                        ]),
                  )));
            }),
      );
}
