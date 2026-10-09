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
          '包含设置、歌词及草稿、字幕项目、歌单、收藏、播放记录、权重，以及 App 内保存的媒体和封面。\n\n不重复打包外部音视频，不含设备安全私钥或文件授权。备份未加密，包含名称和文件路径，请妥善保管。\n\n请选择卸载后仍可访问的位置，完成并确认文件已保存后再卸载。单个备份最多 2 GiB。'),
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
    final value = preview;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('确认导入备份'),
        content: Text('${value.audioCount} 首音乐 · ${value.videoCount} 个视频\n'
            '${value.playlistCount} 个歌单 · ${value.projects.length} 个字幕项目\n'
            '${value.files.length} 个应用内文件（${(value.byteLength / 1024 / 1024).toStringAsFixed(1)} MiB）\n\n'
            '将覆盖当前设置、媒体索引、歌单、歌词和字幕项目，不与当前数据合并。建议先导出当前数据。\n\n'
            '不删除外部原文件，不恢复旧设备安全码。导入后不自动播放；外部媒体与字幕视频需要重新授权或扫描。'),
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
    await _backupProgress(context, '正在恢复媒体和应用数据，请勿退出应用…',
        () => state.importPortableBackup(value));
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('备份已恢复。外部媒体请重新授权或扫描。'),
          duration: Duration(seconds: 8)));
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
