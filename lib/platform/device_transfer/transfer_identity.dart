import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/device_transfer/transfer_protocol.dart';
import '../../core/device_transfer/transfer_pairing.dart';

class TransferIdentity {
  TransferIdentity._(this.privateKey, this.publicKey, this.certificate);
  final String privateKey, publicKey, certificate;
  String get digest => publicKeyDigest(publicKey);
  String get certificateDigest =>
      sha256.convert(pemBytes(certificate)).toString();
  String get safetyCode =>
      List.generate(4, (i) => digest.substring(i * 4, i * 4 + 4).toUpperCase())
          .join(' ');

  static const channel = MethodChannel('lumio/device_transfer');
  static Future<TransferDeviceInfo> deviceInfo() async {
    try {
      return TransferDeviceInfo.fromJson(
          await channel.invokeMethod<Object?>('deviceInfo'));
    } catch (_) {
      return TransferDeviceInfo(
          type: Platform.isMacOS ? 'Mac 电脑' : 'Android 设备');
    }
  }

  static Future<TransferIdentity>? _loading;
  static Future<TransferIdentity> load() =>
      _loading ??= _load().catchError((Object error) {
        _loading = null;
        throw error;
      });

  static Future<TransferIdentity> _load() async {
    var value = await channel.invokeMethod<String>('loadIdentity');
    if (value == null) {
      value = await compute(_generate, 2048);
      await channel.invokeMethod<void>('saveIdentity', {'value': value});
    }
    return fromStored(value!);
  }

  @visibleForTesting
  static Future<TransferIdentity> ephemeral() async =>
      fromStored(await compute(_generate, 2048));

  static TransferIdentity fromStored(String value) {
    if (value.length > 32768) invalidTransferMessage();
    final json = jsonDecode(value);
    if (json is! Map ||
        json['version'] != 1 ||
        json['privateKey'] is! String ||
        json['publicKey'] is! String ||
        json['certificate'] is! String) {
      throw const FormatException('设备身份无法读取，未覆盖原身份。');
    }
    return TransferIdentity._(json['privateKey'] as String,
        json['publicKey'] as String, json['certificate'] as String);
  }

  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(privateKey));

  String sign(List<int> challenge) => base64Encode(CryptoUtils.rsaSign(
      CryptoUtils.rsaPrivateKeyFromPem(privateKey),
      Uint8List.fromList(challenge)));

  static bool verify(String key, List<int> challenge, String signature) {
    if (key.length > 4096 || signature.length > 1024) return false;
    try {
      final public = CryptoUtils.rsaPublicKeyFromPem(key);
      if (public.modulus!.bitLength < 2048 || public.modulus!.bitLength > 4096)
        return false;
      return CryptoUtils.rsaVerify(
          public, Uint8List.fromList(challenge), base64Decode(signature));
    } catch (_) {
      return false;
    }
  }
}

String _generate(int bits) {
  final keys = CryptoUtils.generateRSAKeyPair(keySize: bits);
  final private = keys.privateKey as RSAPrivateKey;
  final public = keys.publicKey as RSAPublicKey;
  final csr =
      X509Utils.generateRsaCsrPem({'CN': 'Lumio device'}, private, public);
  return jsonEncode({
    'version': 1,
    'privateKey': CryptoUtils.encodeRSAPrivateKeyToPem(private),
    'publicKey': CryptoUtils.encodeRSAPublicKeyToPem(public),
    'certificate': X509Utils.generateSelfSignedCertificate(private, csr, 3650,
        serialNumber: BigInt.parse(newTransferId(), radix: 16).toString(),
        notBefore: DateTime.now().toUtc().subtract(const Duration(days: 1))),
  });
}

Uint8List pemBytes(String pem) => base64Decode(pem
    .replaceAll(RegExp(r'-----[^-]+-----'), '')
    .replaceAll(RegExp(r'\s'), ''));
String publicKeyDigest(String pem) => sha256
    .convert(pemBytes(CryptoUtils.encodeRSAPublicKeyToPem(
        CryptoUtils.rsaPublicKeyFromPem(pem))))
    .toString();

List<int> peerChallenge(
        {required String session,
        required String certificate,
        required String nonce,
        required String clientNonce,
        required String publicKey,
        required String name}) =>
    utf8.encode(jsonEncode([
      'Lumio peer possession v1',
      session,
      certificate,
      nonce,
      clientNonce,
      publicKeyDigest(publicKey),
      name,
    ]));

List<int> pairingChallenge(
        {required String session,
        required String certificate,
        required String nonce,
        required String clientNonce,
        required String serverKey,
        required String clientKey,
        required String serverName,
        required String clientName,
        required TransferDeviceInfo serverInfo,
        required TransferDeviceInfo clientInfo,
        required String resumeKey}) =>
    utf8.encode(jsonEncode([
      'Lumio mutual pairing v2',
      session,
      certificate,
      nonce,
      clientNonce,
      publicKeyDigest(serverKey),
      publicKeyDigest(clientKey),
      serverName,
      clientName,
      serverInfo.toJson(),
      clientInfo.toJson(),
      resumeKey,
    ]));
