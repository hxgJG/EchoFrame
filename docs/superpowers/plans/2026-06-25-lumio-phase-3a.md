# Lumio Phase 3a Android Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace simulated playback state with a first Android local-file playback loop.

**Architecture:** Add a small Dart playback repository abstraction and a platform MethodChannel implementation. Android uses native `MediaPlayer` for local file playback, position polling, pause/resume, seek, and completion callbacks; non-Android platforms keep a no-op fallback so HarmonyOS HAP builds continue to compile.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MethodChannel, Android `MediaPlayer`, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 首期集中力量做好 Android 端，iOS 与 HarmonyOS 均可延后。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- 前端首期不新增单元测试，除非用户明确要求。
- 保持最小改动，避免无关重构和格式噪音。

---

### Task 1: Playback Repository

**Files:**
- Create: `lib/platform/playback/playback_repository.dart`
- Create: `lib/platform/playback/platform_playback_repository.dart`

**Interfaces:**
- Produces: `PlaybackRepository.play(MediaItem item, Duration position)`
- Produces: `PlaybackRepository.pause()`
- Produces: `PlaybackRepository.resume()`
- Produces: `PlaybackRepository.seek(Duration position)`
- Produces: `PlaybackRepository.stop()`
- Produces: `PlaybackRepository.position()`
- Produces: `PlaybackRepository.events`

- [x] **Step 1: Define playback abstraction and event model**
- [x] **Step 2: Implement MethodChannel playback repository**
- [x] **Step 3: Keep non-Android platforms as no-op fallback**

### Task 2: Android MediaPlayer Bridge

**Files:**
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Produces: MethodChannel `lumio/playback`
- Produces: methods `play`, `pause`, `resume`, `seek`, `stop`, `position`
- Produces: events `completed`, `error`

- [x] **Step 1: Register playback MethodChannel**
- [x] **Step 2: Add `MediaPlayer` lifecycle and local file playback**
- [x] **Step 3: Send completion and error events to Dart**

### Task 3: App State Integration

**Files:**
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Consumes: `PlaybackRepository`
- Produces: real Android play/pause/resume/seek synchronization.

- [x] **Step 1: Inject playback repository**
- [x] **Step 2: Route play/pause/resume/seek through platform playback**
- [x] **Step 3: Poll current position while playing**
- [x] **Step 4: Handle playback completion with repeat/shuffle/next behavior**

### Task 4: Validation

**Files:**
- Modify only files touched above if verification finds issues.

- [x] **Step 1: Format Dart/Kotlin touched files**
- [x] **Step 2: Run `flutter analyze`**
- [x] **Step 3: Run `flutter build apk --debug`**
- [x] **Step 4: Run `flutter build hap --debug`**
