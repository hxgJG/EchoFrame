# EchoFrame Phase 6b Android Media Notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Android media notification controls for local playback.

**Architecture:** Extend the existing Android playback MethodChannel without adding Flutter plugins. Dart passes current media metadata to Android before playback; Android creates a low-importance media notification channel, publishes a notification with previous/play-pause/next actions, and routes notification actions back through the same Dart playback event stream. This is an Activity-owned first step toward the later foreground playback service.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MethodChannel, Android `NotificationManager`, `PendingIntent`, `MediaSession`, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- 首期集中力量做好 Android 端，iOS 与 HarmonyOS 均可延后。
- 保持最小改动，避免无关重构和格式噪音。

---

### Task 1: Playback Metadata Bridge

**Files:**
- Modify: `lib/platform/playback/platform_playback_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/echoframe/echoframe/MainActivity.kt`

**Interfaces:**
- Updates: MethodChannel `play` arguments include `title`, `artist`, `album`, and `durationMs`.
- Produces: Android notification metadata fields.

- [x] **Step 1: Send media metadata from Dart playback repository**
- [x] **Step 2: Parse and store metadata in Android playback bridge**

### Task 2: Android Media Notification

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/src/main/kotlin/com/hxg/echoframe/echoframe/MainActivity.kt`

**Interfaces:**
- Produces: notification channel `echoframe_playback`.
- Produces: media notification with previous, play/pause, next actions.
- Produces: action handling for notification `Intent`s.

- [x] **Step 1: Add `POST_NOTIFICATIONS` permission for Android 13+**
- [x] **Step 2: Create notification channel and notification action constants**
- [x] **Step 3: Publish/update notification on play/pause/resume/stop**
- [x] **Step 4: Route notification actions to Dart events and native pause/resume where appropriate**

### Task 3: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
