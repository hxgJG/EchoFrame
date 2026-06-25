# EchoFrame Phase 8o Music Folder Browsing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add folder browsing to Music mode so users can navigate local audio by original directory structure.

**Architecture:** Reuse the existing `MediaItem.folder` field populated by seed data and Android MediaStore scans. Add an audio folder list getter in AppState and a fourth Music Library tab that expands each folder into playable local songs.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, app-local media index, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不做真实文件删除、移动、重命名或标签写回。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: AppState Folder Data

**Files:**
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `List<String> EchoAppState.audioFolders`
- Produces: `List<MediaItem> EchoAppState.itemsForAudioFolder(String folder)`

- [x] **Step 1: Add sorted audio folder getter**
- [x] **Step 2: Add folder item lookup helper**

### Task 2: Music Library Folders UI

**Files:**
- Modify: `lib/features/music/music_library_page.dart`

**Interfaces:**
- Consumes: `EchoAppState.audioFolders`
- Consumes: `EchoAppState.itemsForAudioFolder`

- [x] **Step 1: Increase TabController length to four**
- [x] **Step 2: Add `Folders` tab**
- [x] **Step 3: Render expandable folder cards with song rows**
- [x] **Step 4: Preserve existing Songs/Albums/Artists behavior**

### Task 3: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
