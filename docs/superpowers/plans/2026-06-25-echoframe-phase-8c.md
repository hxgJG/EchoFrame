# EchoFrame Phase 8c Batch Media Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline batch actions for songs and playlists without introducing new dependencies or platform file mutations.

**Architecture:** Extend `EchoAppState` with batch queue and playlist helpers that reuse the existing JSON persistence. Add a long-press multi-select mode to the Songs tab and simple playlist bulk removal controls, keeping the operation scope inside the app index rather than modifying user media files.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, app-local JSON persistence, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 本阶段只做 App 内索引和播放列表批量操作，不删除、移动或重命名真实媒体文件。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Batch State Helpers

**Files:**
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `addManyToQueue(Iterable<String> mediaIds)`
- Produces: `addManyToPlaylist(String playlistId, Iterable<String> mediaIds)`
- Produces: `removeManyFromPlaylist(String playlistId, Iterable<String> mediaIds)`

- [x] **Step 1: Add batch queue insertion with missing-media filtering**
- [x] **Step 2: Add batch playlist insertion with duplicate filtering**
- [x] **Step 3: Add batch playlist removal**

### Task 2: Songs Multi-Select UI

**Files:**
- Modify: `lib/features/music/music_library_page.dart`

**Interfaces:**
- Consumes: `EchoAppState.addManyToQueue`
- Consumes: `EchoAppState.addManyToPlaylist`

- [x] **Step 1: Convert Songs tab to stateful selection mode**
- [x] **Step 2: Add long-press/tap selection behavior and select-all control**
- [x] **Step 3: Add batch actions for queue and playlist**

### Task 3: Playlist Bulk Removal UI

**Files:**
- Modify: `lib/features/music/playlists_page.dart`

**Interfaces:**
- Consumes: `EchoAppState.removeManyFromPlaylist`

- [x] **Step 1: Add playlist-level clear-items action**
- [x] **Step 2: Add confirmation dialog before removing all items**

### Task 4: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
