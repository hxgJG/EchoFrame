# Lumio Phase 4a Android Video Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render Android local videos inside the existing Now Playing surface and add a first PiP entry point.

**Architecture:** Extend the playback MethodChannel with Android texture-backed video playback. Dart keeps using the existing playback repository; when the current item is video, it requests a texture ID and the UI renders `Texture(textureId: id)`. Android owns `SurfaceTexture`, `Surface`, `MediaPlayer`, and PiP entry; non-Android platforms fall back to the current placeholder so HarmonyOS builds stay healthy.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MethodChannel, Android `MediaPlayer`, Flutter `TextureRegistry`, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 首期集中力量做好 Android 端，iOS 与 HarmonyOS 均可延后。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS 首发可不支持 PiP。
- 保持最小改动，避免无关重构和格式噪音。

---

### Task 1: Video Playback Contract

**Files:**
- Modify: `lib/platform/playback/playback_repository.dart`
- Modify: `lib/platform/playback/platform_playback_repository.dart`

**Interfaces:**
- Produces: `PlaybackRepository.videoTextureId`
- Produces: `PlaybackRepository.enterPictureInPicture()`
- Produces: event `videoTextureChanged`

- [x] **Step 1: Add video texture state to playback repository**
- [x] **Step 2: Parse Android texture events**
- [x] **Step 3: Add PiP method fallback for non-Android platforms**

### Task 2: Android Texture Playback

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Updates: MethodChannel `lumio/playback` method `play` returns `textureId` for video.
- Produces: MethodChannel `enterPictureInPicture`.

- [x] **Step 1: Create and release Flutter surface textures for video**
- [x] **Step 2: Attach `MediaPlayer` video output to the texture surface**
- [x] **Step 3: Enable Activity PiP support and bridge entry method**

### Task 3: UI Integration

**Files:**
- Modify: `lib/app/app_state.dart`
- Modify: `lib/features/music/now_playing_page.dart`
- Modify: `lib/features/video/video_page.dart`

**Interfaces:**
- Consumes: `LumioAppState.videoTextureId`
- Consumes: `LumioAppState.enterPictureInPicture()`

- [x] **Step 1: Expose video texture ID through app state**
- [x] **Step 2: Render Android video texture in Now Playing**
- [x] **Step 3: Route video list taps to Now Playing and PiP button to platform bridge**

### Task 4: Validation

**Files:**
- Modify only files touched above if verification finds issues.

- [x] **Step 1: Format Dart/Kotlin touched files**
- [x] **Step 2: Run `flutter analyze`**
- [x] **Step 3: Run `flutter build apk --debug`**
- [x] **Step 4: Run `flutter build hap --debug`**
