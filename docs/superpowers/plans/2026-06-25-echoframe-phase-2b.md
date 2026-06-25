# EchoFrame Phase 2b Local Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline local persistence and scan filtering without introducing third-party dependencies.

**Architecture:** Persist app state as app-local JSON through the existing platform media MethodChannel. Keep Dart models serializable, let Android own app-private file IO, and pass scan filter arguments into the existing MediaStore bridge. This keeps the current OHOS Flutter SDK stable while leaving room for a later Drift/SQLite migration.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MethodChannel, app-local JSON files.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 首期集中力量做好 Android 端，iOS 与 HarmonyOS 均可延后。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 在线封面/歌词是非核心增强功能，默认可关闭，关闭后核心模块不可调用网络实现。
- 前端首期不新增单元测试，除非用户明确要求。
- 保持最小改动，避免无关重构和格式噪音。

---

### Task 1: Serializable Models

**Files:**
- Modify: `lib/core/models/media_item.dart`
- Modify: `lib/core/models/playlist.dart`
- Modify: `lib/core/models/echo_settings.dart`

**Interfaces:**
- Produces: `MediaItem.toJson()`, `MediaItem.fromJson(Map<String, Object?>)`
- Produces: `Playlist.toJson()`, `Playlist.fromJson(Map<String, Object?>)`
- Produces: `EchoSettings.toJson()`, `EchoSettings.fromJson(Map<String, Object?>)`

- [x] **Step 1: Add JSON helpers to `MediaItem`**
- [x] **Step 2: Add JSON helpers to `Playlist`**
- [x] **Step 3: Add JSON helpers to `EchoSettings`**

### Task 2: App State Store

**Files:**
- Create: `lib/platform/app_storage/app_storage_repository.dart`
- Create: `lib/platform/app_storage/platform_app_storage_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/echoframe/echoframe/MainActivity.kt`

**Interfaces:**
- Produces: `AppStorageRepository.load()`
- Produces: `AppStorageRepository.save(Map<String, Object?> value)`
- Produces: MethodChannel `echoframe/app_storage` methods `load` and `save`

- [x] **Step 1: Create Dart storage abstraction**
- [x] **Step 2: Implement MethodChannel storage repository**
- [x] **Step 3: Add Android app-local JSON read/write**

### Task 3: Persist Runtime State

**Files:**
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: persisted media index, playlists, settings, playback state, and library status.
- Consumes: `AppStorageRepository`

- [x] **Step 1: Load persisted snapshot on startup**
- [x] **Step 2: Save snapshot after user mutations**
- [x] **Step 3: Keep MediaStore scan snapshot restore as fallback**

### Task 4: Scan Filters

**Files:**
- Modify: `lib/platform/media_library/media_library_repository.dart`
- Modify: `lib/platform/media_library/platform_media_library_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/echoframe/echoframe/MainActivity.kt`
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `MediaLibraryScanFilter`
- Updates: `MediaLibraryRepository.scan(MediaLibraryScanFilter filter)`

- [x] **Step 1: Define scan filter model**
- [x] **Step 2: Pass filter arguments to Android**
- [x] **Step 3: Apply minimum duration and excluded folders in MediaStore queries**

### Task 5: Settings and Playlist UX

**Files:**
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `lib/features/music/music_library_page.dart`
- Modify: `lib/features/music/playlists_page.dart`

**Interfaces:**
- Produces: settings controls for minimum duration and excluded folders.
- Produces: create/rename/delete playlist and add-to-playlist actions.

- [x] **Step 1: Add settings controls**
- [x] **Step 2: Add playlist management dialogs**
- [x] **Step 3: Wire song menu add-to-playlist action**

### Task 6: Validation

**Files:**
- Modify only files touched above if verification finds issues.

- [x] **Step 1: Format Dart/Kotlin touched files**
- [x] **Step 2: Run `flutter analyze`**
- [x] **Step 3: Run `flutter build apk --debug`**
- [x] **Step 4: Run `flutter build hap --debug`**
