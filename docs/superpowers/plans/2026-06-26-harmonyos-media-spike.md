# HarmonyOS Media Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use inline execution for this already-scoped spike. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Lumio import user-selected HarmonyOS local media and complete minimal audio/video playback on a real HarmonyOS device.

**Architecture:** Keep the existing Flutter `ChangeNotifier + Repository + MethodChannel` architecture. Dart repositories enable the existing `lumio/media_library` and `lumio/playback` channels on `Platform.isOhos`, while OHOS ArkTS plugins use system pickers for privacy-safe media import and AVPlayer for playback.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart MethodChannel, HarmonyOS ArkTS, `picker.AudioViewPicker`, `photoAccessHelper.PhotoViewPicker`, `fs.openSync`, `media.AVMetadataExtractor`, `media.AVPlayer`, Flutter OHOS TextureRegistry.

## Global Constraints

- 默认中文沟通和默认中文界面。
- 最小改动，不重复做已完成的 Lumio 重命名、搜索页、中文默认和演示数据移除。
- 不新增前端单测。
- 不回退或覆盖用户已有改动。
- 涉及外网、删除、提交、推送、签名材料处理时先确认。
- `ohos/build-profile.json5` 可能包含本机签名材料，本 spike 不修改它。
- 每个可运行阶段后执行 `flutter analyze` 和 `flutter build hap --debug`。
- 真机运行前提示用户解锁 `4UQ9K25729004312` 并保持亮屏，避免 `10106102`。
- HarmonyOS 公共媒体目录不按 Android MediaStore 模式全盘扫描；采用系统 Picker，由用户主动选择音频/视频 URI 后索引。

---

### Task 1: Dart Platform Gating

**Files:**
- Modify: `lib/platform/media_library/platform_media_library_repository.dart`
- Modify: `lib/platform/playback/platform_playback_repository.dart`

**Interfaces:**
- Consumes: existing channels `lumio/media_library` and `lumio/playback`.
- Produces: Dart calls reach OHOS native plugins when `Platform.isOhos`.

- [ ] Add a local helper such as `_isSupportedPlatform => Platform.isAndroid || Platform.isOhos`.
- [ ] Keep iOS unsupported messaging unchanged.
- [ ] Leave PiP and Android-only extras as native no-op on OHOS.
- [ ] Run `flutter analyze`.
- [ ] Run `flutter build hap --debug`.

### Task 2: HarmonyOS Media Library Plugin

**Files:**
- Create: `ohos/entry/src/main/ets/plugins/LumioMediaLibraryPlugin.ets`
- Modify: `ohos/entry/src/main/ets/entryability/EntryAbility.ets`

**Interfaces:**
- Consumes: Dart method `scan(filterJson)` and `restoreLastScan()`.
- Produces: scan result map with `status`, `message`, `audioItems`, and `videoItems`.

- [x] Register the plugin from `EntryAbility.configureFlutterEngine`.
- [x] Use `picker.AudioViewPicker` for user-selected audio URIs.
- [x] Use `photoAccessHelper.PhotoViewPicker` with `PhotoViewMIMETypes.VIDEO_TYPE` for user-selected video URIs.
- [x] Use `fs.openSync` + `AVMetadataExtractor.fdSrc` to populate title, artist, album, duration, size, format, and video resolution where available.
- [x] Treat picker cancellation as `cancelled` so the existing media library and current playback stay unchanged.
- [x] Run `flutter analyze`.
- [x] Run `flutter build hap --debug`.

### Task 3: HarmonyOS Audio Playback Plugin

**Files:**
- Create: `ohos/entry/src/main/ets/plugins/LumioPlaybackPlugin.ets`
- Modify: `ohos/entry/src/main/ets/entryability/EntryAbility.ets`

**Interfaces:**
- Consumes: Dart playback methods `play`, `pause`, `resume`, `seek`, `setSpeed`, `setVolumeScale`, `stop`, `position`.
- Produces: native playback events `completed`, `error`, and optional `videoTextureChanged`.

- [ ] Create and manage one `media.AVPlayer`.
- [x] Create and manage one `media.AVPlayer`.
- [x] Prefer `fs.openSync(uri)` + `AVPlayer.fdSrc` for picker URIs; fall back to `AVPlayer.url`.
- [x] Prepare, seek, apply speed/volume, and play for audio.
- [x] Return success for unsupported extras such as PiP/share/EQ to keep UI stable.
- [x] Run `flutter analyze`.
- [x] Run `flutter build hap --debug`.

### Task 4: HarmonyOS Video Texture Playback

**Files:**
- Modify: `ohos/entry/src/main/ets/plugins/LumioPlaybackPlugin.ets`

**Interfaces:**
- Consumes: `FlutterPluginBinding.getTextureRegistry()`.
- Produces: a Flutter texture id returned by `play` for video items.

- [x] Register a texture and obtain its `surfaceId`.
- [x] Assign `AVPlayer.surfaceId` before `prepare`.
- [x] Return `textureId` to Dart so the existing `Texture` widget can render video.
- [x] Release texture/player resources and close fd handles on stop and plugin detach.
- [x] Run `flutter analyze`.
- [x] Run `flutter build hap --debug`.

### Task 5: Device Smoke Verification

**Files:**
- No planned source changes.

**Interfaces:**
- Consumes: device id `4UQ9K25729004312`.
- Produces: real-device smoke result and a list of remaining HarmonyOS gaps.

- [x] Tell the user to unlock the HarmonyOS device and keep the screen on.
- [x] Run `flutter run -d 4UQ9K25729004312`.
- [ ] Verify picker import, audio play, and video play as far as the device/media library allows.
- [x] Summarize unsupported items, risks, and next steps.

Current device result: `flutter run -d 4UQ9K25729004312` built and began install/launch, but failed at launch with `10106102 The device screen is locked during the application launch`. Retry after unlocking the device and keeping the screen on.
