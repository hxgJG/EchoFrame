# Lumio Phase 8k ASS Subtitles and Reorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add local `.ass`/`.ssa` subtitle fallback and persistent drag sorting for queues/playlists.

**Architecture:** Reuse the existing `SubtitleCue` rendering path by parsing ASS dialogue events into plain text cues, keeping complex ASS styling out of scope. Add AppState reorder methods and wire them to Flutter `ReorderableListView` sections so queue and playlist order stays in the existing app-local JSON state.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android MediaStore MethodChannel, app-local JSON persistence, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 本阶段只做 ASS/SSA 基础纯文本字幕解析，不实现复杂 ASS 样式、特效或定位。
- 不做真实文件删除、移动、重命名或标签写回。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: ASS Subtitle Parser

**Files:**
- Create: `lib/core/subtitles/ass_parser.dart`
- Modify: `lib/platform/media_library/platform_media_library_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Produces: `List<SubtitleCue> parseAss(String text)`
- Consumes: existing `SubtitleCue`

- [x] **Step 1: Parse ASS/SSA event format lines and dialogue rows**
- [x] **Step 2: Strip common ASS override tags and newline escapes**
- [x] **Step 3: Scan Android same-name `.ass` or `.ssa` files when `.srt` is missing**
- [x] **Step 4: Use SRT subtitles first, ASS/SSA fallback second**

### Task 2: Queue and Playlist Reorder

**Files:**
- Modify: `lib/app/app_state.dart`
- Modify: `lib/features/music/playlists_page.dart`

**Interfaces:**
- Produces: `LumioAppState.reorderQueue(int oldIndex, int newIndex)`
- Produces: `LumioAppState.reorderPlaylistItems(String playlistId, int oldIndex, int newIndex)`

- [x] **Step 1: Add persisted reorder methods in AppState**
- [x] **Step 2: Replace queue list with a fixed-height ReorderableListView**
- [x] **Step 3: Replace playlist item list with a fixed-height ReorderableListView**
- [x] **Step 4: Keep item tap, remove, and empty states unchanged**

### Task 3: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
