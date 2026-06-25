# EchoFrame Phase 8e Video Fullscreen Gestures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fullscreen video viewer with basic local playback gestures: horizontal seek, left-side brightness adjustment, and right-side volume adjustment.

**Architecture:** Reuse the existing Android `MediaPlayer` Texture in a fullscreen Flutter route. Dart handles horizontal drag seeking through the existing playback repository. Brightness and volume gestures call small platform methods that are no-op outside Android and adjust only the current activity window/music stream.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MethodChannel, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Playback Gesture Platform Hooks

**Files:**
- Modify: `lib/platform/playback/playback_repository.dart`
- Modify: `lib/platform/playback/platform_playback_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/echoframe/echoframe/MainActivity.kt`

**Interfaces:**
- Produces: `adjustBrightness(double delta)`
- Produces: `adjustVolume(double delta)`

- [x] **Step 1: Add repository methods for brightness and volume adjustment**
- [x] **Step 2: Implement Android window brightness adjustment**
- [x] **Step 3: Implement Android music stream volume adjustment**

### Task 2: Fullscreen Video Route

**Files:**
- Modify: `lib/features/music/now_playing_page.dart`

**Interfaces:**
- Consumes: `EchoAppState.seekToFraction`
- Consumes: `EchoAppState.adjustBrightness`
- Consumes: `EchoAppState.adjustVolume`

- [x] **Step 1: Add fullscreen button to the video stage**
- [x] **Step 2: Render the existing video texture in a fullscreen route**
- [x] **Step 3: Add horizontal seek gesture and vertical brightness/volume gestures**

### Task 3: State Facade and Documentation

**Files:**
- Modify: `lib/app/app_state.dart`
- Modify: `docs/TECHNICAL_PLAN.md`

**Interfaces:**
- Produces: `EchoAppState.adjustBrightness(double delta)`
- Produces: `EchoAppState.adjustVolume(double delta)`

- [x] **Step 1: Add AppState facade methods**
- [x] **Step 2: Update technical plan current-state notes**
- [x] **Step 3: Run `dart format lib`**
- [x] **Step 4: Run `flutter analyze`**
- [x] **Step 5: Run `flutter build apk --debug`**
- [x] **Step 6: Run `flutter build hap --debug`**
