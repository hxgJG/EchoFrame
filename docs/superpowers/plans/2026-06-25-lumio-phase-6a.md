# Lumio Phase 6a Android Playback Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Android audio focus, noisy route pause, and basic media-key handling for local playback.

**Architecture:** Keep the existing playback MethodChannel and extend Android `MainActivity` with platform system integration only. Android requests audio focus before playback, pauses when focus is lost or headphones disconnect, and forwards MediaSession media button actions to Dart as playback events. Dart handles those events in `LumioAppState` by toggling play/pause or moving previous/next.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MethodChannel, Android `AudioManager`, `AudioFocusRequest`, `MediaSession`, `BroadcastReceiver`, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- 首期集中力量做好 Android 端，iOS 与 HarmonyOS 均可延后。
- 保持最小改动，避免无关重构和格式噪音。

---

### Task 1: Playback Events

**Files:**
- Modify: `lib/platform/playback/playback_repository.dart`
- Modify: `lib/platform/playback/platform_playback_repository.dart`
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `PlaybackEventType.play`, `pause`, `toggle`, `next`, `previous`
- Consumes: Android MethodChannel events of the same method names.

- [x] **Step 1: Add system media event enum values**
- [x] **Step 2: Parse MethodChannel media events in platform repository**
- [x] **Step 3: Route events to `LumioAppState` controls**

### Task 2: Android Audio Focus

**Files:**
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Produces: audio focus request before `MediaPlayer.start()`
- Produces: pause event on transient/permanent focus loss.

- [x] **Step 1: Add `AudioManager` and focus request fields**
- [x] **Step 2: Request audio focus before playback/resume**
- [x] **Step 3: Pause playback and notify Dart on focus loss**
- [x] **Step 4: Abandon focus when playback is stopped or activity destroyed**

### Task 3: Noisy Route and Media Keys

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Produces: headset/noisy route pause.
- Produces: MediaSession callback for play/pause/next/previous.

- [x] **Step 1: Register `ACTION_AUDIO_BECOMING_NOISY` receiver while activity is alive**
- [x] **Step 2: Create active `MediaSession` with transport callbacks**
- [x] **Step 3: Release receiver and session on destroy**

### Task 4: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
