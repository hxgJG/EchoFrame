import 'dart:convert';
import 'dart:io';

import 'transfer_protocol.dart';

bool isLocalTransferAddress(InternetAddress address,
    {bool allowLoopback = false}) {
  if (address.isLoopback) return allowLoopback;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254);
  }
  // Scoped link-local IPv6 addresses are interface-dependent on the receiver.
  // ULA is supported; use the displayed IPv4 address for scoped-only networks.
  return (bytes[0] & 0xfe) == 0xfc;
}

class TransferInvitation {
  TransferInvitation(
      {required this.address,
      required this.port,
      required this.certificateDigest,
      required this.sessionId,
      required this.token,
      required this.expiresAt,
      bool allowLoopback = false}) {
    final ip = InternetAddress.tryParse(address);
    if (ip == null ||
        !isLocalTransferAddress(ip, allowLoopback: allowLoopback) ||
        port < 1 ||
        port > 65535 ||
        !isTransferDigest(certificateDigest) ||
        !isTransferId(sessionId) ||
        !isTransferId(token)) invalidTransferMessage();
  }
  final String address, certificateDigest, sessionId, token;
  final int port;
  final DateTime expiresAt;
  String encode() => 'LUMIO1-${base64Url.encode(utf8.encode(jsonEncode({
            'v': 1,
            'a': address,
            'p': port,
            'c': certificateDigest,
            's': sessionId,
            't': token,
            'e': expiresAt.millisecondsSinceEpoch,
          })))}';

  factory TransferInvitation.decode(String input,
      {bool allowLoopback = false}) {
    if (input.length > 2048) invalidTransferMessage();
    final text = input.replaceAll(RegExp(r'\s+'), '');
    if (!text.startsWith('LUMIO1-'))
      throw const FormatException('请粘贴对方 App 中完整的 LUMIO1 连接码。');
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(text.substring(7))));
      if (json is! Map ||
          json['v'] != 1 ||
          json['a'] is! String ||
          json['p'] is! int ||
          json['c'] is! String ||
          json['s'] is! String ||
          json['t'] is! String ||
          json['e'] is! int) invalidTransferMessage();
      return TransferInvitation(
          address: json['a'] as String,
          port: json['p'] as int,
          certificateDigest: json['c'] as String,
          sessionId: json['s'] as String,
          token: json['t'] as String,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(json['e'] as int),
          allowLoopback: allowLoopback);
    } on FormatException {
      throw const FormatException('连接码不完整或格式错误，请重新复制。');
    }
  }
}
