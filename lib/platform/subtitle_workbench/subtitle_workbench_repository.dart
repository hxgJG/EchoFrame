import 'dart:io';
import 'package:flutter/services.dart';

class SubtitleWorkbenchRepository {
  static const _channel = MethodChannel('lumio/subtitle_workbench');
  static bool get supported => Platform.isMacOS;

  Future<dynamic> call(String method, [Map<String, Object?>? arguments]) {
    if (!supported) throw UnsupportedError('字幕工作台目前仅支持 macOS');
    return _channel.invokeMethod<dynamic>(method, arguments);
  }

  Future<List<dynamic>> snapshot() async =>
      List<dynamic>.from(await call('snapshot') as List);
  Future<void> restore(List<dynamic> projects) async {
    await call('restore', {'projects': projects});
  }
}
