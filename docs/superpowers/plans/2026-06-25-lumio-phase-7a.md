# Lumio Phase 7a Metadata Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline in-app metadata editing for local media library entries.

**Architecture:** Keep edits in the app-managed media index rather than rewriting the original media file tags. `LumioAppState` updates `MediaItem` title/artist/album through existing `copyWith` and JSON persistence; music and video menus expose a small edit dialog. This delivers the PRD metadata-management workflow safely while leaving true file-tag writing for a later platform-specific phase.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, existing app-local JSON storage, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- 保持最小改动，避免无关重构和格式噪音。
- 本阶段不直接修改用户原始媒体文件，仅更新 App 内索引。

---

### Task 1: App State Metadata Update

**Files:**
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `LumioAppState.updateMediaMetadata(String mediaId, {String? title, String? artist, String? album})`

- [x] **Step 1: Add update method that validates non-empty title**
- [x] **Step 2: Reuse `_replaceItem` so audio/video/current item all stay in sync**
- [x] **Step 3: Save JSON state and notify listeners after edit**

### Task 2: Music Metadata Dialog

**Files:**
- Modify: `lib/features/music/music_library_page.dart`
- Modify: `lib/features/music/now_playing_page.dart`

**Interfaces:**
- Consumes: `LumioAppState.updateMediaMetadata`

- [x] **Step 1: Add edit menu item to song overflow menu**
- [x] **Step 2: Add edit action to Now Playing more sheet**
- [x] **Step 3: Build title/artist/album dialog and persist changes**

### Task 3: Video Metadata Dialog

**Files:**
- Modify: `lib/features/video/video_page.dart`

**Interfaces:**
- Consumes: `LumioAppState.updateMediaMetadata`

- [x] **Step 1: Add video overflow menu**
- [x] **Step 2: Reuse title/artist/album dialog for video entries**
- [x] **Step 3: Preserve play/open behavior beside edit action**

### Task 4: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
