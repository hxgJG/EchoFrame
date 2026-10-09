import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../platform/app_storage/portable_backup_repository.dart';

Future<T> _backupProgress<T>(BuildContext context, String message,
    Future<T> Function() operation) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
          content: Row(children: [
        const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(width: 16),
        Expanded(child: Text(message)),
      ])),
    ),
  );
  navigator.push(route);
  try {
    return await operation();
  } finally {
    if (route.isActive) navigator.removeRoute(route);
  }
}

Future<void> exportPortableBackup(
    BuildContext context, LumioAppState state) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('导出迁移备份'),
      content: const Text(
          '包含设置、歌词及草稿、字幕项目、歌单、收藏、播放记录和权重，支持 macOS 与 Android 互相恢复。\n\n不包含任何音视频或封面原文件，也不包含文件授权、设备安全私钥和云端应用密码。卸载会删除 App 内接收的媒体，请先另行保存这些文件。\n\n备份未加密。请选择卸载后仍可访问的位置，确认文件已保存后再迁移。应用数据最多 128 MiB。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导出')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    final path = await _backupProgress(
        context, '正在打包并校验备份，请勿退出应用…', state.exportPortableBackup);
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(path == null ? '已取消，未保存外部备份。' : '备份已保存。请在所选位置确认文件后再卸载。'),
          duration: const Duration(seconds: 8)));
  } catch (e) {
    if (context.mounted) await _backupError(context, e);
  }
}

Future<void> importPortableBackup(
    BuildContext context, LumioAppState state) async {
  PortableBackupPreview? preview;
  try {
    preview = await _backupProgress(
        context, '正在读取并校验备份，请勿退出应用…', state.selectPortableBackup);
    if (preview == null || !context.mounted) return;
    await confirmPortableBackupImport(context, state, preview);
  } catch (e) {
    if (context.mounted) await _backupError(context, e);
  } finally {
    if (preview != null) {
      try {
        await preview.directory.delete(recursive: true);
      } catch (_) {}
      state.endPortableBackup();
    }
  }
}

Future<void> confirmPortableBackupImport(BuildContext context,
    LumioAppState state, PortableBackupPreview value) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('确认导入备份'),
      content: Text('${value.audioCount} 首音乐 · ${value.videoCount} 个视频\n'
          '${value.playlistCount} 个歌单 · ${value.projects.length} 个字幕项目\n'
          '${value.metadataOnly ? '跨端应用数据包，不含音视频原文件' : '${value.files.length} 个应用内文件（${(value.byteLength / 1024 / 1024).toStringAsFixed(1)} MiB），旧版同平台备份'}\n\n'
          '将覆盖当前设置、歌单、歌词、收藏、播放记录和字幕项目，建议先备份当前数据。\n\n'
          '不删除本机媒体文件，不恢复旧设备安全码。导入后不自动播放；按指纹或明确的歌曲信息关联本机文件，未找到的记录保留，后续扫描时继续匹配。Android 会保留桌面端字幕项目数据，但不提供字幕工作台。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('覆盖导入')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await _backupProgress(
      context, '正在恢复媒体和应用数据，请勿退出应用…', () => state.importPortableBackup(value));
  if (context.mounted)
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('备份已恢复。外部媒体请重新授权或扫描。'), duration: Duration(seconds: 8)));
}

Future<void> _backupError(BuildContext context, Object error) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('备份操作未完成'),
        content: Text('$error\n\n请不要卸载旧版，确认操作成功后再迁移。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('知道了'))
        ],
      ),
    );
