# Lumio Phase 8m Media Details and Share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add richer local media file details and Android system share intents without deleting or moving user files.

**Architecture:** Reuse existing metadata already stored on `MediaItem` for the detail dialogs. Add one playback MethodChannel method that resolves scanned Android MediaStore IDs to content URIs and launches `ACTION_SEND`; non-Android platforms no-op through the repository boundary.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android MediaStore content URI sharing, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不做真实文件删除、移动、重命名或标签写回。
- Android 分享必须优先使用 MediaStore content URI，不暴露 `file://`。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Platform Share Bridge

**Files:**
- Modify: `lib/platform/playback/playback_repository.dart`
- Modify: `lib/platform/playback/platform_playback_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Produces: `Future<void> PlaybackRepository.share(MediaItem item)`

- [x] **Step 1: Add share method to playback repository abstraction**
- [x] **Step 2: Invoke Android MethodChannel with media id, kind, title, and path**
- [x] **Step 3: Resolve `android-audio-*` and `android-video-*` ids to MediaStore content URIs**
- [x] **Step 4: Launch chooser with read URI permission**

### Task 2: UI Menus and Detail Dialogs

**Files:**
- Modify: `lib/app/app_state.dart`
- Modify: `lib/features/music/music_library_page.dart`
- Modify: `lib/features/video/video_page.dart`

**Interfaces:**
- Produces: `LumioAppState.share(MediaItem item)`

- [x] **Step 1: Add AppState share method with status message fallback**
- [x] **Step 2: Add audio share menu item**
- [x] **Step 3: Add video detail and share menu items**
- [x] **Step 4: Expand details to include path, folder, format, size, duration, resolution, and resume position**

### Task 3: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
