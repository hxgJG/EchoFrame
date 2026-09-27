import 'dart:io';

import 'transfer_invitation.dart';
import 'transfer_protocol.dart';

String normalizeSafetyCode(String value) {
  final code = value.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  if (!RegExp(r'^[0-9A-F]{16}$').hasMatch(code)) {
    throw const FormatException('请输入对方完整的 16 位安全码。');
  }
  return code;
}

String displaySafetyCode(String digest) =>
    List.generate(4, (i) => digest.substring(i * 4, i * 4 + 4).toUpperCase())
        .join(' ');

class TransferDeviceInfo {
  const TransferDeviceInfo({this.type = '', this.brand = '', this.model = ''});
  final String type, brand, model;
  String get label =>
      [type, brand, model].where((s) => s.isNotEmpty).join(' · ');
  Map<String, Object?> toJson() =>
      {'type': type, 'brand': brand, 'model': model};
  factory TransferDeviceInfo.fromJson(Object? raw) {
    if (raw == null) return const TransferDeviceInfo();
    if (raw is! Map || raw.length > 8) invalidTransferMessage();
    String field(String key) {
      final value = raw[key];
      if (value == null) return '';
      if (value is! String ||
          value.length > 80 ||
          value
              .contains(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'))) {
        invalidTransferMessage();
      }
      return value.trim();
    }

    return TransferDeviceInfo(
        type: field('type'), brand: field('brand'), model: field('model'));
  }
}

/// Discovery provides only routing hints; the handshake and user confirmation
/// must authenticate the identity before any access is requested.
class TransferEndpoint {
  TransferEndpoint(
      {required this.address,
      required this.port,
      required this.identityDigest,
      required this.certificateDigest,
      bool allowLoopback = false}) {
    final ip = InternetAddress.tryParse(address);
    if (ip == null ||
        !isLocalTransferAddress(ip, allowLoopback: allowLoopback) ||
        port < 1 ||
        port > 65535 ||
        !isTransferDigest(identityDigest) ||
        !isTransferDigest(certificateDigest)) invalidTransferMessage();
  }
  final String address, identityDigest, certificateDigest;
  final int port;
  String get safetyCode => displaySafetyCode(identityDigest);
}

class TransferRemoteDevice {
  const TransferRemoteDevice(this.identityDigest, this.name, this.info);
  final String identityDigest, name;
  final TransferDeviceInfo info;
  String get safetyCode => displaySafetyCode(identityDigest);
}
