# EchoFrame Phase 8f Fullscreen Orientation Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lock the video fullscreen route to landscape and restore normal orientation when leaving fullscreen.

**Architecture:** Use Flutter `SystemChrome` APIs inside the fullscreen video route lifecycle. The route hides system overlays and locks landscape while mounted, then restores edge-to-edge overlays and portrait/landscape support in `dispose`.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Fullscreen Orientation Lifecycle

**Files:**
- Modify: `lib/features/music/now_playing_page.dart`

**Interfaces:**
- Produces: fullscreen route locks landscape while mounted

- [x] **Step 1: Import Flutter services**
- [x] **Step 2: Lock landscape and hide overlays in fullscreen `initState`**
- [x] **Step 3: Restore supported orientations and overlays in `dispose`**

### Task 2: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
