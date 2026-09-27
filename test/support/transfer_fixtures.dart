import 'package:crypto/crypto.dart';
import 'package:lumio/core/device_transfer/transfer_authorization.dart';
import 'package:lumio/core/device_transfer/transfer_protocol.dart';

const transferPeerDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const transferChannelDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

TransferResource transferResource({
  List<int> bytes = const [1, 2, 3],
  String? id,
  String title = '本地音乐',
  List<String> attachments = const [],
  TransferResourceKind kind = TransferResourceKind.audio,
}) =>
    TransferResource(
        id: id ?? newTransferId(),
        kind: kind,
        byteLength: bytes.length,
        sha256Digest: sha256.convert(bytes).toString(),
        extension: switch (kind) {
          TransferResourceKind.audio => 'mp3',
          TransferResourceKind.video => 'mp4',
          TransferResourceKind.lyrics => 'json',
          TransferResourceKind.artwork => 'png',
        },
        metadata: TransferDisplayMetadata(title: title),
        attachmentIds: attachments);

TransferPeerBinding transferPeer(
        {String identity = transferPeerDigest,
        String channel = transferChannelDigest}) =>
    TransferPeerBinding(
        identityDigest: identity,
        channelDigest: channel,
        displayName: '测试接收设备');

class FakeTransferClock implements TransferClock {
  @override
  DateTime now = DateTime.utc(2026, 9, 26);
  @override
  Duration elapsed = Duration.zero;
  void advance(Duration value) {
    now = now.add(value);
    elapsed += value;
  }
}
