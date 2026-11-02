// 仅供隔离的 .updateqa 构建使用，不是应用的正式入口。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: UpdateQA()));
}

class UpdateQA extends StatefulWidget {
  const UpdateQA({super.key});

  @override
  State<UpdateQA> createState() => _UpdateQAState();
}

class _UpdateQAState extends State<UpdateQA> {
  static const channel = MethodChannel('lumio/app_update');
  static const lifecycle = MethodChannel('lumio/app_update_lifecycle');
  Map<String, dynamic>? environment;
  String status = '正在读取隔离测试环境';

  @override
  void initState() {
    super.initState();
    lifecycle.setMethodCallHandler((call) async {
      if (call.method != 'prepareForInstall') throw MissingPluginException();
      await File('${environment!['cacheRoot']}/qa-session-saved.json')
          .writeAsString(jsonEncode(environment), flush: true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => initialize());
  }

  Future<void> initialize() async {
    try {
      environment =
          await channel.invokeMapMethod<String, dynamic>('environment');
      final root = environment!['cacheRoot'];
      await File('$root/qa-launched-${environment!['buildNumber']}.json')
          .writeAsString(jsonEncode(environment), flush: true);
      if (environment!['buildNumber'] == '9') {
        setState(() => status = '新版已启动，尚未回报成功；下载包与回退副本此时必须保留');
      } else {
        await acknowledge();
      }
    } on Object catch (error) {
      setState(() => status = '$error');
    }
  }

  Future<void> acknowledge() async {
    await lifecycle.invokeMethod<void>('launchSucceeded');
    if (mounted) setState(() => status = '环境就绪，已回报成功启动');
  }

  Future<void> run(String operation) async {
    try {
      final root = environment!['cacheRoot'];
      final args =
          jsonDecode(await File('$root/qa-package.json').readAsString())
              as Map<String, dynamic>;
      args['path'] =
          '$root/update-${args['buildNumber']}-${args['sha256']}.zip';
      if (operation == 'badSignature') {
        args['sparkleSignature'] = base64Encode(List<int>.filled(64, 0));
      }
      final result = await channel.invokeMethod<Object?>(
          operation == 'badSignature' ? 'validate' : 'open', args);
      setState(() => status = '$operation: $result');
    } on Object catch (error) {
      setState(() => status = '$operation: $error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Lumio Update QA · 独立测试数据')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                '当前版本：${environment?['version']}（${environment?['buildNumber']}）'),
            SelectableText('缓存目录：${environment?['cacheRoot']}'),
            const SizedBox(height: 16),
            SelectableText(status),
            const SizedBox(height: 16),
            FilledButton(
                onPressed:
                    environment == null ? null : () => run('badSignature'),
                child: const Text('验证错误签名会被拒绝')),
            const SizedBox(height: 16),
            FilledButton(
                onPressed: environment == null ? null : () => run('install'),
                child: const Text('安装隔离测试更新')),
            const SizedBox(height: 16),
            FilledButton(
                onPressed: environment == null ? null : acknowledge,
                child: const Text('确认新版本启动成功并清理')),
          ]),
        ),
      );
}
