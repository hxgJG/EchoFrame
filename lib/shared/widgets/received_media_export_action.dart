import 'package:flutter/material.dart';

import '../../core/models/media_item.dart';
import '../../platform/device_transfer/device_transfer_controller.dart';
import '../../platform/device_transfer/shared_resource_reader.dart';

Future<void> exportReceivedMedia(BuildContext context, MediaItem item) async {
  if (item.sourceId != 'lumio-received') return;
  try {
    final exported = await NativeTransferLease.channel.invokeMethod<bool>(
        'exportReceived', {'path': item.path, 'name': item.title});
    if (context.mounted && exported == true)
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已另存到所选位置，App 内原文件保留。')));
  } catch (e) {
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(DeviceTransferController.describe(e))));
  }
}
