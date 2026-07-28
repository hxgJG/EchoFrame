# Lumio Phase 8h Sleep Timer Fade-Out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sleep timer fade playback volume down before pausing instead of cutting off abruptly.

**Architecture:** Dart owns the sleep timer countdown and runs a short fade timer during the final seconds. A new playback repository method sends a normalized playback volume scale to Android `MediaPlayer.setVolume`; non-Android platforms no-op. When the timer is canceled or playback resumes, volume scale is restored to `1.0`.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin `MediaPlayer.setVolume`, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Playback Volume Scale Bridge

**Files:**
- Modify: `lib/platform/playback/playback_repository.dart`
- Modify: `lib/platform/playback/platform_playback_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Produces: `PlaybackRepository.setVolumeScale(double scale)`
- Consumes: MethodChannel method `setVolumeScale`

- [x] **Step 1: Add Dart playback repository method**
- [x] **Step 2: Implement Android `MediaPlayer.setVolume` scale**
- [x] **Step 3: Reset scale when a new player starts or playback stops**

### Task 2: Sleep Timer Fade Logic

**Files:**
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Consumes: `PlaybackRepository.setVolumeScale`

- [x] **Step 1: Add fade timer state and constants**
- [x] **Step 2: Start fade during the final 10 seconds of sleep timer**
- [x] **Step 3: Restore volume on cancel, pause completion, and dispose**

### Task 3: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
