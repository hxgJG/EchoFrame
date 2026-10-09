import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../core/device_transfer/transfer_protocol.dart';
import '../../core/device_transfer/transfer_pairing.dart';
import '../../platform/device_transfer/device_transfer_controller.dart';
import '../../platform/device_transfer/received_transfer_store.dart';
import '../../platform/device_transfer/platform_transfer_storage.dart';
import '../music/lyric_library_page.dart';

class DeviceTransferPage extends StatefulWidget {
  const DeviceTransferPage({super.key, required this.state});
  final LumioAppState state;
  @override
  State<DeviceTransferPage> createState() => _DeviceTransferPageState();
}

class _DeviceTransferPageState extends State<DeviceTransferPage> {
  late final controller = widget.state.deviceTransfer;
  final _code = TextEditingController();
  final _shareSelection = <String>{}, _downloadSelection = <String>{};
  bool _includeLyrics = true,
      _includeArtwork = true,
      _overwrite = true,
      _syncMetadata = true;
  String? _address;
  String _query = '';
  TransferResourceKind? _kind;
  int _minutes = 60;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize({bool allowIdentityInteraction = false}) async {
    try {
      await controller.initialize(
          allowIdentityInteraction: allowIdentityInteraction);
    } catch (_) {
      /* The controller exposes the initialization error and retry. */
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _code.dispose();
    unawaited(controller.stopDiscovery());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(DeviceTransferController.describe(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: Text(title), content: Text(body), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确认')),
              ])) ??
      false;

  Future<bool> _confirmDevice(TransferRemoteDevice device) async {
    if (!mounted) return false;
    return _confirm(
        '核对对方安全码',
        '${device.name}\n${device.info.label}\n\n${device.safetyCode}\n\n'
            '请与对方 App 的本机安全码逐组核对。一致后申请连接，对方仍需批准。');
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return DefaultTabController(
            length: 3,
            child: Scaffold(
              appBar: AppBar(
                  title: const Text('设备互传'),
                  bottom: TabBar(
                      onTap: (index) {
                        if (index == 1 &&
                            controller.identity != null &&
                            !_busy) {
                          unawaited(_run(controller.discover));
                        }
                      },
                      tabs: const [
                        Tab(text: '提供资源', icon: Icon(Icons.upload_rounded)),
                        Tab(text: '接收资源', icon: Icon(Icons.download_rounded)),
                        Tab(
                            text: '已接收',
                            icon: Icon(Icons.inventory_2_outlined)),
                      ])),
              body: controller.initializing
                  ? const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('正在准备本机安全身份…')
                    ]))
                  : controller.identity == null
                      ? Center(
                          child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(controller.error ?? '设备互传尚未初始化'),
                                    const SizedBox(height: 16),
                                    FilledButton(
                                        onPressed: () => _initialize(
                                            allowIdentityInteraction: controller
                                                .identityAuthorizationRequired),
                                        child: Text(controller
                                                .identityAuthorizationRequired
                                            ? '授权钥匙串'
                                            : '重试')),
                                  ])))
                      : Column(children: [
                          if (controller.error case final error?)
                            MaterialBanner(
                                content: Text(error,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis),
                                actions: [
                                  TextButton(
                                      onPressed: () {
                                        controller.error = null;
                                        setState(() {});
                                      },
                                      child: const Text('知道了'))
                                ]),
                          Expanded(
                              child: TabBarView(children: [
                            _share(),
                            _receive(),
                            _history()
                          ])),
                        ]),
            ));
      });

  Widget _page(List<Widget> children) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              children: children)));
  Widget _panel(List<Widget> children, {bool accent = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: accent ? scheme.primaryContainer : scheme.surface,
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(16)),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children));
  }

  Widget _heading(String title, String subtitle) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
      ]));
  Widget _identity() => _panel([
        Row(children: [
          const Icon(Icons.verified_user_outlined),
          const SizedBox(width: 12),
          Expanded(
              child: Text(controller.name,
                  style: Theme.of(context).textTheme.titleMedium)),
          IconButton(
              tooltip: '修改设备名称',
              onPressed:
                  controller.sharing || controller.connecting ? null : _rename,
              icon: const Icon(Icons.edit_outlined))
        ]),
        if (controller.deviceInfo.label.isNotEmpty)
          Text(controller.deviceInfo.label),
        const Text('本机安全码 · 连接时与对方逐组核对'),
        const SizedBox(height: 8),
        SelectableText(controller.identity!.safetyCode,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontFamily: 'monospace', letterSpacing: 1.5)),
        const SizedBox(height: 6),
        const Text('安全码固定不变，知道安全码不代表获得访问权限。'),
      ], accent: true);

  Future<void> _rename() async {
    final input = TextEditingController(text: controller.name);
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('设备名称'),
                content: TextField(
                    controller: input,
                    maxLength: 40,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: '例如：客厅 Mac')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, input.text.trim()),
                      child: const Text('保存')),
                ]));
    // The dialog route may animate out while its TextField still references this controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (value != null &&
        value.isNotEmpty &&
        !value.contains(RegExp(r'[\x00-\x1f\x7f]')) &&
        mounted) setState(() => controller.name = value);
  }

  Widget _share() {
    final auth = controller.server?.host.authorization;
    final pending = auth?.pending, grant = auth?.grant;
    final choices = controller.choices
        .where((e) =>
            (_kind == null || e.kind == _kind) &&
            '${e.title} ${e.subtitle}'
                .toLowerCase()
                .contains(_query.toLowerCase()))
        .toList();
    final endpoint = controller.server?.endpoint;
    return _page([
      _heading(
          '由你决定分享什么', '两端需处于同一 Wi-Fi、局域网或热点，并保持 App 在前台。关闭共享后，已接收的文件无法远程收回。'),
      _identity(),
      if (pending != null)
        _panel([
          Text('新连接申请', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(pending.peer.displayName),
          if (pending.peer.deviceInfo.label.isNotEmpty)
            Text(pending.peer.deviceInfo.label),
          const Text('请与对方 App 显示的本机安全码核对：'),
          const SizedBox(height: 8),
          SelectableText(pending.peer.safetyCode,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontFamily: 'monospace')),
          const SizedBox(height: 12),
          Text('批准后可在期限内自由浏览并下载当前 ${auth!.scope.length} 项资源（含附件），无需逐次确认。'),
          DropdownButtonFormField<int>(
              initialValue: _minutes,
              decoration: const InputDecoration(labelText: '允许访问时长'),
              items: [5, 15, 30, 60, 120, 240, 480, 1440]
                  .map((n) => DropdownMenuItem(
                      value: n,
                      child: Text(n < 60 ? '$n 分钟' : '${n ~/ 60} 小时')))
                  .toList(),
              onChanged: (n) => setState(() => _minutes = n!)),
          const SizedBox(height: 12),
          Wrap(spacing: 12, children: [
            FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() => controller.approve(_minutes)),
                icon: const Icon(Icons.check),
                label: const Text('已核对，允许连接')),
            OutlinedButton(
                onPressed: controller.reject, child: const Text('拒绝')),
          ]),
        ], accent: true),
      if (grant != null)
        _panel([
          Text('已授权：${grant.peer.displayName}',
              style: Theme.of(context).textTheme.titleMedium),
          Text('安全码 ${grant.peer.safetyCode}'),
          if (grant.peer.deviceInfo.label.isNotEmpty)
            Text(grant.peer.deviceInfo.label),
          Text('到期时间：${_time(grant.expiresAt)} · 不会自动续期'),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  onPressed: () => _run(controller.disconnect),
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开连接'))),
        ]),
      if (controller.sharing)
        _panel([
          Text('共享中 · ${auth!.scope.length} 项（含附件）',
              style: Theme.of(context).textTheme.titleMedium),
          if (endpoint != null)
            Text('本机地址 ${endpoint.address}:${endpoint.port}')
          else
            const Text('网络暂不可用，已暂停共享；返回原网络接口后恢复。'),
          Text(
              '共享总量 ${_size(controller.sharedResources.fold<int>(0, (sum, r) => sum + r.byteLength))} · 已发送 ${_size(controller.sentBytes)}'),
          ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('查看共享范围与发送记录'),
              children: [
                for (final r in controller.sharedResources)
                  ListTile(
                      dense: true,
                      leading: Icon(_kindIcon(r.kind)),
                      title: Text(r.metadata.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${_kindLabel(r.kind)} · ${_size(r.byteLength)} · 已发送 ${_size(controller.sentResources[r.id] ?? 0)}（含重传）')),
              ]),
          const SizedBox(height: 10),
          const Text('让对方在“接收资源”选择本机，或输入本机安全码申请连接。'),
          const SizedBox(height: 10),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: controller.identity!.safetyCode));
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('安全码已复制。对方也可以直接选择附近设备。')));
                },
                icon: const Icon(Icons.copy),
                label: const Text('复制安全码')),
            OutlinedButton(
                onPressed: () => _run(controller.stopSharing),
                child: const Text('停止共享')),
          ]),
          const SizedBox(height: 8),
          const Text('如需更改共享范围，请停止后重新选择。新范围需对方再次申请。'),
        ]),
      if (controller.preparing)
        _panel([
          Text('校验文件 ${controller.prepared} / ${controller.prepareTotal}'),
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text('首次需要完整读取所选文件以核对内容；不会额外复制视频。大文件可能需要一些时间。'),
          TextButton(
              onPressed: controller.cancelPreparation,
              child: const Text('取消准备')),
        ]),
      if (!controller.sharing && !controller.preparing) ...[
        _panel([
          if (controller.addresses.isEmpty)
            const Text('没有找到局域网地址，请连接 Wi-Fi、有线网络或热点后刷新。')
          else
            DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: controller.addresses
                        .any((e) => e.address.address == _address)
                    ? _address
                    : controller.addresses.first.address.address,
                decoration: const InputDecoration(labelText: '用于共享的网络地址'),
                items: controller.addresses
                    .map((e) => DropdownMenuItem(
                        value: e.address.address,
                        child: Text(e.label, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: (s) => setState(() => _address = s)),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  onPressed: () => _run(controller.refreshAddresses),
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新网络地址'))),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('音乐附带正式歌词'),
              value: _includeLyrics,
              onChanged: (v) => setState(() => _includeLyrics = v)),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('附带封面'),
              value: _includeArtwork,
              onChanged: (v) => setState(() => _includeArtwork = v)),
          const Text('仅开放勾选的可访问资源；不分享草稿、外挂字幕、播放列表、收藏或历史。'),
        ]),
        TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: '筛选名称或艺术家'),
            onChanged: (v) => setState(() => _query = v)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          for (final kind in <TransferResourceKind?>[
            null,
            TransferResourceKind.audio,
            TransferResourceKind.video,
            TransferResourceKind.lyrics
          ])
            ChoiceChip(
                label: Text(kind == null ? '全部' : _kindLabel(kind)),
                selected: _kind == kind,
                onSelected: (_) => setState(() => _kind = kind)),
        ]),
        Row(children: [
          Expanded(child: Text('已选择 ${_shareSelection.length} / 500 项')),
          TextButton(
              onPressed: () => setState(() {
                    for (final e in choices) {
                      if (_shareSelection.length >= 500) break;
                      _shareSelection.add(e.key);
                    }
                  }),
              child: const Text('全选筛选项')),
          TextButton(
              onPressed: () => setState(_shareSelection.clear),
              child: const Text('清空'))
        ]),
        if (choices.isEmpty)
          const Padding(
              padding: EdgeInsets.all(24),
              child: Text('没有可共享的资源。请先扫描媒体或导入正式歌词。')),
        for (final choice in choices)
          CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(_kindIcon(choice.kind)),
              title: Text(choice.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(choice.subtitle,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              value: _shareSelection.contains(choice.key),
              onChanged: (v) => setState(() {
                    if (v == true && _shareSelection.length < 500)
                      _shareSelection.add(choice.key);
                    else
                      _shareSelection.remove(choice.key);
                  })),
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed:
                _shareSelection.isEmpty || controller.addresses.isEmpty || _busy
                    ? null
                    : () {
                        final address = controller.addresses
                            .firstWhere((e) => e.address.address == _address,
                                orElse: () => controller.addresses.first)
                            .address;
                        _run(() => controller.startSharing(
                            Set.of(_shareSelection), address,
                            includeLyrics: _includeLyrics,
                            includeArtwork: _includeArtwork));
                      },
            icon: const Icon(Icons.wifi_tethering),
            label: Text('开启共享 · ${_shareSelection.length} 项')),
      ],
      if (controller.discoveryWarning case final warning?) Text(warning),
    ]);
  }

  Widget _receive() {
    final attachments =
        controller.remote.expand((e) => e.attachmentIds).toSet();
    final resources = controller.remote
        .where((e) =>
            !attachments.contains(e.id) &&
            e.kind != TransferResourceKind.artwork)
        .toList();
    final client = controller.client;
    return _page([
      _heading('从另一台设备接收', '让对方开启共享，选择附近设备并核对安全码即可申请。接收不会自动开放自己的媒体库。'),
      _identity(),
      _panel([
        TextField(
            controller: _code,
            maxLines: 1,
            maxLength: 32,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: '对方安全码',
                hintText: 'XXXX XXXX XXXX XXXX',
                alignLabelWithHint: true)),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: _busy || controller.connecting || controller.receiving
                  ? null
                  : () => _run(
                      () => controller.connect(_code.text, _confirmDevice)),
              icon: const Icon(Icons.link),
              label: Text(controller.connecting ? '安全连接中…' : '申请连接')),
          OutlinedButton(
              onPressed: _busy ||
                      controller.receiving ||
                      controller.connecting ||
                      !controller.canReconnect
                  ? null
                  : () => _run(() => controller.reconnect(_confirmDevice)),
              child: const Text('重连上次设备')),
          if (client != null)
            TextButton(
                onPressed: () => _run(controller.disconnect),
                child: const Text('断开连接')),
          TextButton.icon(
              onPressed: () => _run(controller.discover),
              icon: const Icon(Icons.radar),
              label: const Text('发现附近设备')),
        ]),
        if (controller.nearby.isNotEmpty) ...[
          const Divider(),
          const Text('附近开启了共享的设备 · 点击后核对安全码'),
          for (final service in controller.nearby)
            ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices),
                title: Text(service.name ?? '附近设备',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle:
                    Text(DeviceTransferController.serviceSubtitle(service)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy || controller.connecting || controller.receiving
                    ? null
                    : () => _run(() =>
                        controller.connectService(service, _confirmDevice))),
        ],
        if (controller.discoveryWarning case final warning?) Text(warning),
      ]),
      if (client != null)
        _panel([
          Text(client.remoteName,
              style: Theme.of(context).textTheme.titleMedium),
          if (client.remoteInfo.label.isNotEmpty) Text(client.remoteInfo.label),
          Text(controller.approved
              ? '已获得访问授权'
              : client.closed
                  ? '连接已断开，请重连'
                  : '等待对方核对设备码并批准…'),
          Text('对方安全码：${_safetyCode(client.remoteIdentity)}'),
          if (client.status['expiresAt'] case final int expiry)
            Text('授权到期：${_time(DateTime.fromMillisecondsSinceEpoch(expiry))}'),
        ]),
      if (controller.approved) ...[
        _panel([
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('覆盖已有歌词'),
              subtitle: const Text('关闭后只补充缺失歌词；尚无歌曲的歌词保留待关联。'),
              value: _overwrite,
              onChanged: controller.receiving
                  ? null
                  : (v) => setState(() => _overwrite = v)),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('同步歌名、艺术家和专辑'),
              subtitle: const Text('只修改 App 展示信息，保留旧名称为匹配别名，不改原文件标签。'),
              value: _syncMetadata,
              onChanged: controller.receiving
                  ? null
                  : (v) => setState(() => _syncMetadata = v)),
          const Text(
              '相同内容不重复下载；同名不同内容保留两份。接收文件保存在 App 私有目录，卸载/清除数据可能删除，请按需另行导出。'),
        ]),
        Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                  '已选 ${_downloadSelection.intersection(resources.map((e) => e.id).toSet()).length} 项'),
              TextButton(
                  onPressed: controller.receiving
                      ? null
                      : () => setState(() {
                            _downloadSelection
                                .addAll(resources.take(500).map((e) => e.id));
                          }),
                  child: const Text('全选')),
              TextButton(
                  onPressed: controller.receiving
                      ? null
                      : () => setState(_downloadSelection.clear),
                  child: const Text('清空')),
              TextButton.icon(
                  onPressed:
                      controller.receiving ? null : controller.refreshCatalog,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新资源')),
            ]),
        if (resources.isEmpty)
          const Padding(
              padding: EdgeInsets.all(24),
              child: Text('对方当前没有可访问资源，请让对方检查所选范围与文件权限。')),
        for (final r in resources)
          CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(_kindIcon(r.kind)),
              value: _downloadSelection.contains(r.id),
              title: Text(r.metadata.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  '${_kindLabel(r.kind)} · ${_size(r.byteLength)}${r.attachmentIds.isEmpty ? '' : ' · 含 ${r.attachmentIds.length} 个附件'}\n${controller.outcomes[r.id] ?? r.metadata.artist}'),
              onChanged: controller.receiving
                  ? null
                  : (v) => setState(() {
                        if (v == true)
                          _downloadSelection.add(r.id);
                        else
                          _downloadSelection.remove(r.id);
                      })),
        const SizedBox(height: 12),
        FilledButton.icon(
            onPressed: controller.receiving || _downloadSelection.isEmpty
                ? null
                : () async {
                    final selected = _downloadSelection
                        .intersection(resources.map((e) => e.id).toSet());
                    if (selected.isEmpty) return;
                    final ids = {
                      ...selected,
                      for (final r
                          in resources.where((r) => selected.contains(r.id)))
                        ...r.attachmentIds
                    };
                    final size = controller.remote
                        .where((r) => ids.contains(r.id))
                        .fold<int>(0, (sum, r) => sum + r.byteLength);
                    int? free;
                    try {
                      free = await const PlatformTransferStorage()
                          .availableSpace();
                    } catch (_) {}
                    if (!mounted) return;
                    if (await _confirm('接收 ${selected.length} 项资源？',
                        '含附件最多 ${_size(size)}，实际会跳过相同内容。\n可用空间：${free == null ? '读取失败，写入前将再次检查' : _size(free)}\n保存位置：App 私有“已接收”目录\n\n歌词覆盖：${_overwrite ? '开启' : '关闭'}\n展示信息同步：${_syncMetadata ? '开启' : '关闭'}\n\n请保持两端 App 前台。')) {
                      await controller.download(
                          selected,
                          TransferImportPolicy(
                              overwriteLyrics: _overwrite,
                              syncMetadata: _syncMetadata));
                    }
                  },
            icon: const Icon(Icons.download),
            label: const Text('接收到本机')),
      ],
      if (controller.receiving)
        _panel([
          Text(controller.currentTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          LinearProgressIndicator(
              value: controller.totalBytes == 0
                  ? null
                  : controller.receivedBytes / controller.totalBytes),
          const SizedBox(height: 8),
          Text(
              '${_size(controller.receivedBytes)} / ${_size(controller.totalBytes)} · ${_size(controller.bytesPerSecond.round())}/s'),
          Text('本批完成 ${controller.completed} / ${controller.batchTotal} 项'),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: controller.pause, child: const Text('暂停'))),
        ]),
      const SizedBox(height: 16),
      Text(controller.message),
    ]);
  }

  Widget _history() => _page([
        _heading('接收记录',
            '已完成的音乐、视频会自动加入媒体库。未完成的分块保留 24 小时；记录最多保留 200 项 / 30 天，清理记录不删除已入库的文件。'),
        _panel([
          const Text('文件保存在 App 管理的持久目录，不是临时缓存。卸载或清除 App 数据可能删除它们，请及时导出重要资源。'),
          TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => LyricLibraryPage(state: widget.state))),
              icon: const Icon(Icons.lyrics_outlined),
              label: const Text('歌词库 · 查看、关联与导出')),
        ]),
        if (controller.history.isEmpty)
          const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('还没有接收记录'))),
        for (final receipt in controller.history
            .where((e) => e.resource.kind != TransferResourceKind.artwork))
          _panel([
            Text(receipt.resource.metadata.title,
                style: Theme.of(context).textTheme.titleMedium),
            Text(
                '${_kindLabel(receipt.resource.kind)} · ${_size(receipt.offset)} / ${_size(receipt.resource.byteLength)}'),
            Text(receipt.indexed
                ? '已接收并入库'
                : receipt.stage == ReceivedTransferStage.downloading
                    ? '未完成 · 连接同一来源后重新选择，可断点继续'
                    : '已校验保存 · 等待入库确认'),
            Wrap(spacing: 8, children: [
              if (receipt.stage != ReceivedTransferStage.downloading &&
                  !receipt.indexed)
                TextButton(
                    onPressed: _busy || controller.receiving
                        ? null
                        : () => _run(() async {
                              if (await _confirm('重新确认入库？',
                                  '按本次接收时的选项导入：\n覆盖歌词：${receipt.policy.overwriteLyrics ? '开启' : '关闭'}\n同步展示信息：${receipt.policy.syncMetadata ? '开启' : '关闭'}\n\n如有本地修改，开启覆盖/同步可能替换它们。'))
                                await controller.retryImport(receipt);
                            }),
                    child: const Text('确认并重试入库')),
              if (receipt.stage != ReceivedTransferStage.downloading &&
                  receipt.resource.kind != TransferResourceKind.lyrics)
                TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() => controller.export(receipt)),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('另存到…')),
              if (receipt.stage == ReceivedTransferStage.downloading)
                TextButton(
                    onPressed: _busy || controller.receiving
                        ? null
                        : () => _run(() async {
                              if (await _confirm(
                                  '取消此任务？', '只删除此任务的未完成分块，不影响已经入库的媒体。'))
                                await controller.cancelPartial(receipt);
                            }),
                    child: const Text('取消并清理分块')),
            ]),
          ]),
      ]);

  String _time(DateTime time) {
    final t = time.toLocal();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  String _safetyCode(String digest) =>
      List.generate(4, (i) => digest.substring(i * 4, i * 4 + 4).toUpperCase())
          .join(' ');
  String _size(int bytes) => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB'
      : bytes >= 1024 * 1024
          ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB'
          : '${(bytes / 1024).toStringAsFixed(1)} KiB';
  String _kindLabel(TransferResourceKind kind) => switch (kind) {
        TransferResourceKind.audio => '音乐',
        TransferResourceKind.video => '视频',
        TransferResourceKind.lyrics => '歌词',
        TransferResourceKind.artwork => '封面',
      };
  IconData _kindIcon(TransferResourceKind kind) => switch (kind) {
        TransferResourceKind.audio => Icons.music_note,
        TransferResourceKind.video => Icons.movie_outlined,
        TransferResourceKind.lyrics => Icons.lyrics_outlined,
        TransferResourceKind.artwork => Icons.image_outlined,
      };
}
