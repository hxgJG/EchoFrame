import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/platform/app_update/app_update_controller.dart';
import 'package:lumio/platform/app_update/update_transport.dart';

class _ManifestTransport extends UpdateTransport {
  _ManifestTransport(this.fixture, this.visited, {this.fail = false});
  final String fixture;
  final List<Uri> visited;
  final bool fail;

  @override
  Future<Uint8List> smallFile(Uri uri, int limit) async {
    visited.add(uri);
    if (fail) throw const SocketException('offline');
    return File('test/fixtures/updates/$fixture/${uri.pathSegments.last}')
        .readAsBytes();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lumio/app_update');

  test('未下载时连续检查刷新到更新版本，重新进入也不复用旧清单，失败不冒充最新', () async {
    final root = await Directory.systemTemp.createTemp('lumio-check-test-');
    final visited = <Uri>[];
    var fixture = '1.0.7-8';
    var fail = false;
    final controllers = <AppUpdateController>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'environment') {
        return {
          'version': '1.0.6',
          'buildNumber': 7,
          'platform': 'android',
          'architecture': 'arm64',
          'osVersion': '35',
          'cacheRoot': root.path,
        };
      }
      return null;
    });
    AppUpdateController create() {
      final controller = AppUpdateController(
          transportFactory: (_) =>
              _ManifestTransport(fixture, visited, fail: fail));
      controllers.add(controller);
      return controller;
    }

    try {
      final controller = create();
      await controller.check();
      expect(controller.manifest!.buildNumber, 8);
      expect(controller.phase, UpdatePhase.available);
      expect(controller.downloaded, isNull);

      fixture = '1.0.8-9';
      await controller.check();
      expect(controller.manifest!.buildNumber, 9);
      expect(visited.length, 4);
      expect(visited[0].queryParameters['check'], isNotEmpty);
      expect(visited[0].query, visited[1].query);
      expect(visited[2].query, visited[3].query);
      expect(visited[0].query, isNot(visited[2].query));

      final reopened = create();
      await reopened.check();
      expect(reopened.manifest!.buildNumber, 9);
      expect(visited.length, 6);

      fail = true;
      await reopened.check();
      expect(reopened.phase, UpdatePhase.failed);
      expect(reopened.manifest, isNull);
      expect(reopened.package, isNull);
      expect(reopened.downloaded, isNull);
    } finally {
      for (final controller in controllers) {
        controller.dispose();
        await controller.readDiagnosticReport();
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });
}
