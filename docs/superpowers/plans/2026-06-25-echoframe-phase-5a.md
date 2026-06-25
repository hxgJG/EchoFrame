# EchoFrame Phase 5a Backup Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an offline JSON backup and restore flow for playlists, settings, and local media index.

**Architecture:** Reuse the existing app-local JSON snapshot format. Extend the app storage MethodChannel with Android-only backup file operations: create a timestamped backup under app external documents, restore the latest backup, and report the latest backup path. Dart keeps non-Android behavior as no-op with clear UI messages so HarmonyOS builds remain compatible.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MethodChannel, app-local JSON files, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 备份/恢复第一版不引入文件选择器插件，不访问网络。
- 首期集中力量做好 Android 端，iOS 与 HarmonyOS 均可延后。
- 保持最小改动，避免无关重构和格式噪音。

---

### Task 1: Storage Backup Contract

**Files:**
- Modify: `lib/platform/app_storage/app_storage_repository.dart`
- Modify: `lib/platform/app_storage/platform_app_storage_repository.dart`

**Interfaces:**
- Produces: `AppBackupInfo`
- Produces: `AppStorageRepository.createBackup(Map<String, Object?> value)`
- Produces: `AppStorageRepository.restoreLatestBackup()`
- Produces: `AppStorageRepository.latestBackup()`

- [x] **Step 1: Add backup info model and abstract methods**
- [x] **Step 2: Implement Android MethodChannel calls**
- [x] **Step 3: Keep non-Android platforms as unsupported fallback**

### Task 2: Android Backup Files

**Files:**
- Modify: `android/app/src/main/kotlin/com/hxg/echoframe/echoframe/MainActivity.kt`

**Interfaces:**
- Updates: MethodChannel `echoframe/app_storage`
- Produces: methods `createBackup`, `restoreLatestBackup`, `latestBackup`

- [x] **Step 1: Write timestamped JSON backups**
- [x] **Step 2: Find latest backup by modified time**
- [x] **Step 3: Restore latest backup into app state file**

### Task 3: App State and Settings UI

**Files:**
- Modify: `lib/app/app_state.dart`
- Modify: `lib/features/settings/settings_page.dart`

**Interfaces:**
- Produces: `EchoAppState.backupStatusMessage`
- Produces: `EchoAppState.createBackup()`
- Produces: `EchoAppState.restoreLatestBackup()`

- [x] **Step 1: Expose backup status and actions through app state**
- [x] **Step 2: Add Backup & Restore controls in settings**
- [x] **Step 3: Re-apply restored snapshot and notify UI**

### Task 4: Validation

**Files:**
- Modify only files touched above if verification finds issues.

- [x] **Step 1: Format Dart/Kotlin touched files**
- [x] **Step 2: Run `flutter analyze`**
- [x] **Step 3: Run `flutter build apk --debug`**
- [x] **Step 4: Run `flutter build hap --debug`**
