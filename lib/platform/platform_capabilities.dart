import 'dart:io' show Platform;

class PlatformCapabilities {
  const PlatformCapabilities({
    required this.supportsFolderPicker,
    required this.supportsPersistentFolderAccess,
    required this.supportsFileRename,
    required this.supportsFileMove,
    required this.supportsTagWrite,
    required this.supportsShare,
    required this.supportsVideoTexture,
    required this.supportsPictureInPicture,
    required this.supportsBrightnessAdjustment,
    required this.supportsEqualizer,
    required this.supportsCrossfade,
    required this.supportsSystemMediaControls,
  });

  factory PlatformCapabilities.current() {
    if (Platform.isMacOS) {
      return const PlatformCapabilities(
        supportsFolderPicker: true,
        supportsPersistentFolderAccess: true,
        supportsFileRename: true,
        supportsFileMove: true,
        supportsTagWrite: false,
        supportsShare: true,
        supportsVideoTexture: true,
        supportsPictureInPicture: false,
        supportsBrightnessAdjustment: false,
        supportsEqualizer: false,
        supportsCrossfade: false,
        supportsSystemMediaControls: true,
      );
    }
    if (Platform.isAndroid) {
      return const PlatformCapabilities(
        supportsFolderPicker: false,
        supportsPersistentFolderAccess: false,
        supportsFileRename: true,
        supportsFileMove: true,
        supportsTagWrite: true,
        supportsShare: true,
        supportsVideoTexture: true,
        supportsPictureInPicture: true,
        supportsBrightnessAdjustment: true,
        supportsEqualizer: true,
        supportsCrossfade: true,
        supportsSystemMediaControls: true,
      );
    }
    return const PlatformCapabilities(
      supportsFolderPicker: false,
      supportsPersistentFolderAccess: false,
      supportsFileRename: false,
      supportsFileMove: false,
      supportsTagWrite: false,
      supportsShare: false,
      supportsVideoTexture: false,
      supportsPictureInPicture: false,
      supportsBrightnessAdjustment: false,
      supportsEqualizer: false,
      supportsCrossfade: false,
      supportsSystemMediaControls: false,
    );
  }

  final bool supportsFolderPicker;
  final bool supportsPersistentFolderAccess;
  final bool supportsFileRename;
  final bool supportsFileMove;
  final bool supportsTagWrite;
  final bool supportsShare;
  final bool supportsVideoTexture;
  final bool supportsPictureInPicture;
  final bool supportsBrightnessAdjustment;
  final bool supportsEqualizer;
  final bool supportsCrossfade;
  final bool supportsSystemMediaControls;
}
