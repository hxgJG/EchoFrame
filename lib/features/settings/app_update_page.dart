import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/app_state.dart';
import '../../platform/app_update/app_update_controller.dart';

class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({super.key, required this.state});
  final LumioAppState state;
  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  final controller = AppUpdateController();
  @override
  void initState() {
    super.initState();
    controller.loadEnvironment().catchError((Object e) {
      if (!mounted) return;
      setState(() => controller.message = '无法读取应用版本：$e');
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (Platform.isAndroid) {
      final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('安装更新'),
                  content: const Text('安装由系统确认，过程中播放可能中断。不会自动卸载应用或清空数据。是否继续？'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('继续'))
                  ]));
      if (accepted != true || !mounted) return;
    }
    await controller.open(widget.state.prepareForApplicationUpdate);
  }

  Future<void> _showDiagnostics() async {
    try {
      final text = await controller.readDiagnosticReport();
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('网络诊断记录'),
                content: SizedBox(
                    width: 720,
                    height: 460,
                    child: SingleChildScrollView(child: SelectableText(text))),
                actions: [
                  TextButton(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: text));
                      },
                      child: const Text('复制记录')),
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭')),
                ],
              ));
    } on Object {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法读取诊断记录，请检查磁盘空间。')));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final release = controller.manifest;
        final package = controller.package;
        return Scaffold(
            appBar: AppBar(title: const Text('应用更新')),
            body: ListView(padding: const EdgeInsets.all(20), children: [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.system_update_alt),
                  title: Text(controller.environment == null
                      ? '读取当前版本…'
                      : '当前版本 ${controller.environment!['version']}（${controller.environment!['buildNumber']}）'),
                  subtitle: const Text('稳定版 · GitHub 公开发布 · 无需账号')),
              const SizedBox(height: 12),
              Text(controller.message),
              const SizedBox(height: 16),
              Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                      onPressed: controller.busy ? null : controller.check,
                      icon: const Icon(Icons.refresh),
                      label: Text(controller.phase == UpdatePhase.checking
                          ? '检查中…'
                          : '检查更新'))),
              if (release != null && package != null) ...[
                const SizedBox(height: 24),
                Text('新版本 ${release.version}（${release.buildNumber}）',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                    '${release.publishedAt.toLocal().toString().split(' ').first} · ${package.platform} · ${(package.size / 1048576).toStringAsFixed(1)} MiB'),
                const SizedBox(height: 16),
                SelectableText(release.notes),
                const SizedBox(height: 20),
                if (controller.phase == UpdatePhase.downloading) ...[
                  LinearProgressIndicator(
                      value: controller.received / package.size),
                  const SizedBox(height: 8),
                  Text(
                      '${(controller.received / 1048576).toStringAsFixed(1)} / ${(package.size / 1048576).toStringAsFixed(1)} MiB'),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                          onPressed: controller.cancel,
                          child: const Text('暂停下载'))),
                ] else if (controller.downloaded != null)
                  Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                          onPressed: controller.busy ? null : _open,
                          icon: const Icon(Icons.install_desktop),
                          label: Text(Platform.isAndroid ? '安装更新' : '显示安装包')))
                else
                  Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                          onPressed:
                              controller.busy ? null : controller.download,
                          icon: const Icon(Icons.download),
                          label:
                              Text(controller.received > 0 ? '继续下载' : '下载更新'))),
                if (!controller.busy &&
                    controller.downloaded == null &&
                    controller.received > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                      '已保存 ${(controller.received / 1048576).toStringAsFixed(1)} / ${(package.size / 1048576).toStringAsFixed(1)} MiB'),
                ],
              ],
              const SizedBox(height: 24),
              const Text(
                  '手动检查和下载会记录本机网络诊断，每 5 秒保存一次；不上传日志，不记录临时签名参数或应用数据。无 VPN 测试前请自行关闭 VPN／代理。'),
              if (controller.diagnosticReport != null) ...[
                const SizedBox(height: 8),
                SelectableText('日志位置：${controller.diagnosticReport!.path}'),
                if (controller.diagnosticWriteError != null)
                  Text(controller.diagnosticWriteError!),
                Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                        onPressed: _showDiagnostics,
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('查看／复制诊断记录'))),
              ],
              const SizedBox(height: 12),
              if (Platform.isMacOS)
                const Text(
                    'macOS 当前采用临时签名，未经过 Apple 公证。下载后需在 Finder 解压、退出 Lumio、手动替换，再重新启动。请按系统提示处理，不关闭系统保护。'),
              const SizedBox(height: 12),
              const Text(
                  '只在校验通过后提供安装入口。离开本页会暂停下载并保留进度，重新检查更新后可继续；未完成缓存保留 7 天（系统清理缓存后需重新下载）。服务器不支持续传时自动重新下载。'),
            ]));
      });
}
