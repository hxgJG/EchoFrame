# EchoFrame Phase 8n Scan Include Folders and Size Sort Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional scan include folders and file-size sorting for the local media library.

**Architecture:** Persist include folders in `EchoSettings` alongside excluded folders. Pass include folders through the existing MediaStore scan filter and apply it on Android before returning scan rows. Persist raw `fileSizeBytes` on `MediaItem` so AppState can sort songs by file size without parsing display labels.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android MediaStore MethodChannel, app-local JSON persistence, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- Include folders are optional; an empty include list must preserve current all-media scanning behavior.
- 不做真实文件删除、移动、重命名或标签写回。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Models and Scan Filter

**Files:**
- Modify: `lib/core/models/echo_settings.dart`
- Modify: `lib/core/models/media_item.dart`
- Modify: `lib/platform/media_library/media_library_repository.dart`
- Modify: `lib/platform/media_library/platform_media_library_repository.dart`
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `EchoSettings.includedFolders`
- Produces: `MediaItem.fileSizeBytes`
- Produces: `EchoAppState.addIncludedFolder(String folder)`
- Produces: `EchoAppState.removeIncludedFolder(String folder)`
- Produces: `MusicSort.fileSize`

- [x] **Step 1: Persist include folders in settings JSON**
- [x] **Step 2: Persist raw file size bytes on media items**
- [x] **Step 3: Pass include folders through scan filter**
- [x] **Step 4: Add AppState setters and file-size sort**

### Task 2: Android Scan Filtering

**Files:**
- Modify: `android/app/src/main/kotlin/com/hxg/echoframe/echoframe/MainActivity.kt`

**Interfaces:**
- Consumes: `includedFolders` list from MethodChannel arguments

- [x] **Step 1: Parse include folders from scan arguments**
- [x] **Step 2: Keep current behavior when include folders are empty**
- [x] **Step 3: Exclude rows outside include folders when include folders are set**

### Task 3: Settings and Sorting UI

**Files:**
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `lib/features/music/music_library_page.dart`

**Interfaces:**
- Consumes: include folder setters and `MusicSort.fileSize`

- [x] **Step 1: Add include folder settings controls**
- [x] **Step 2: Add removable include folder chips**
- [x] **Step 3: Add song sort option for file size**

### Task 4: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
