# Lumio Phase 8b Video Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist per-video playback positions and automatically continue to the next video when a video finishes.

**Architecture:** Store each media item's last playback position in the existing app-local JSON model. When playing a video, resume from the stored position unless it is near the end; while playback progresses, persist the latest position on the current item. Completion handling reuses the current ordered video list to advance to the next video when repeat mode allows it.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MediaPlayer bridge, app-local JSON persistence, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- 保持最小改动，避免无关重构和格式噪音。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Persist Media Resume Position

**Files:**
- Modify: `lib/core/models/media_item.dart`
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `MediaItem.lastPosition`
- Produces: JSON field `lastPositionMs`

- [x] **Step 1: Add `lastPosition` to `MediaItem`, `copyWith`, `toJson`, and `fromJson`**
- [x] **Step 2: Update the current media item with playback progress during position sync**
- [x] **Step 3: Preserve scanned item resume metadata when rescanning the same path**

### Task 2: Resume and Auto-Continue Video Playback

**Files:**
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Consumes: `MediaItem.lastPosition`
- Produces: video play starts from saved position when valid

- [x] **Step 1: Resume video playback from saved position unless it is near the end**
- [x] **Step 2: Clear resume position after a media item completes**
- [x] **Step 3: Auto-continue from the current video list when a video reaches the end**

### Task 3: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
