import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/device_transfer/transfer_protocol.dart';
import 'received_transfer_store.dart';

/// Does not create directories or touch user data until explicitly opened.
class PlatformTransferStorage {
  const PlatformTransferStorage();
  static const _channel = MethodChannel('lumio/app_storage');
  Future<int> availableSpace() async =>
      (await _info())['availableBytes'] as int;

  Future<ReceivedTransferStore> open() async {
    final info = await _info();
    final path = info['path'];
    if (path is! String || !path.startsWith('/') || path.contains('\x00')) {
      throw const TransferException(
          TransferFailure.storageCorrupt, '接收文件目录不可用。');
    }
    final store =
        ReceivedTransferStore(Directory(path), availableBytes: () async {
      final current = await _info();
      if (current['path'] != path) {
        throw const TransferException(
            TransferFailure.storageCorrupt, '接收文件目录已改变。');
      }
      return current['availableBytes'] as int;
    });
    await store.initialize();
    return store;
  }

  Future<Map<String, Object?>> _info() async {
    final result =
        await _channel.invokeMapMethod<String, Object?>('transferStorage');
    if (result == null ||
        result['availableBytes'] is! int ||
        (result['availableBytes'] as int) < 0) {
      throw const TransferException(
          TransferFailure.storageCorrupt, '无法读取接收目录的剩余空间。');
    }
    return result;
  }
}
