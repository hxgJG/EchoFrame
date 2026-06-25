# EchoFrame Phase 5b Offline Playback Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline playback controls for speed, sleep timer, and AB loop.

**Architecture:** Keep enhancement state in `EchoAppState`, persist it in the existing JSON snapshot, and route speed changes to the Android playback MethodChannel. Sleep timer and AB loop are implemented in Dart timers/position sync so they remain platform-neutral; Android only needs a `setSpeed` bridge.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MethodChannel, Android `MediaPlayer.playbackParams`, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- 保持最小改动，避免无关重构和格式噪音。

---

### Task 1: Playback Speed Bridge

**Files:**
- Modify: `lib/platform/playback/playback_repository.dart`
- Modify: `lib/platform/playback/platform_playback_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/echoframe/echoframe/MainActivity.kt`

**Interfaces:**
- Produces: `PlaybackRepository.setSpeed(double speed)`
- Produces: MethodChannel `setSpeed`

- [x] **Step 1: Add speed method to Dart playback contract**
- [x] **Step 2: Implement Android MethodChannel speed call**
- [x] **Step 3: Apply speed to active/new MediaPlayer instances**

### Task 2: App State Enhancements

**Files:**
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `playbackSpeed`, `setPlaybackSpeed`
- Produces: `sleepTimerLabel`, `setSleepTimer`, `cancelSleepTimer`
- Produces: `abLoopLabel`, `setAbLoopStart`, `setAbLoopEnd`, `clearAbLoop`

- [x] **Step 1: Add persisted speed and AB loop fields**
- [x] **Step 2: Add sleep timer scheduling and cancellation**
- [x] **Step 3: Loop playback between A and B during position sync**

### Task 3: UI Controls

**Files:**
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `lib/features/music/now_playing_page.dart`

**Interfaces:**
- Consumes: speed/sleep/AB APIs from `EchoAppState`

- [x] **Step 1: Add playback speed slider in Settings**
- [x] **Step 2: Add sleep timer action buttons in Settings**
- [x] **Step 3: Add AB loop actions to Now Playing more menu**

### Task 4: Validation

**Files:**
- Modify only files touched above if verification finds issues.

- [x] **Step 1: Format Dart/Kotlin touched files**
- [x] **Step 2: Run `flutter analyze`**
- [x] **Step 3: Run `flutter build apk --debug`**
- [x] **Step 4: Run `flutter build hap --debug`**
