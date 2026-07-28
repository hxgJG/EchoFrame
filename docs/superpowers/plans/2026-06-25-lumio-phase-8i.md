# Lumio Phase 8i Fullscreen Video Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add synced playback controls to the fullscreen video route.

**Architecture:** Keep fullscreen playback state driven by `LumioAppState`. The fullscreen route already listens through `AnimatedBuilder`; add play/pause, previous/next, current time, duration, and draggable seek controls that call existing AppState methods.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Fullscreen Control Bar

**Files:**
- Modify: `lib/features/music/now_playing_page.dart`

**Interfaces:**
- Consumes: `LumioAppState.togglePlaying`
- Consumes: `LumioAppState.previous`
- Consumes: `LumioAppState.next`
- Consumes: `LumioAppState.seekToFraction`

- [x] **Step 1: Add previous/play-next buttons to fullscreen route**
- [x] **Step 2: Add current time and duration labels**
- [x] **Step 3: Replace readonly progress with draggable slider**

### Task 2: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
