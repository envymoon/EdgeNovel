# Zhiyue 挚阅

[简体中文](README.md) | English

<p align="center">
  <img src="docs/assets/novel-icon.ico" width="112" alt="Zhiyue">
</p>

<h3 align="center">A local-first Chinese web fiction reader with offline AI analysis</h3>

<p align="center">
  <img alt="On-device AI" src="https://img.shields.io/badge/AI-on--device-8a6d1d">
  <img alt="Free" src="https://img.shields.io/badge/cost-free%20%C2%B7%20no%20API%20key-8a6d1d">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-Windows%20%7C%20Android%20%7C%20iOS-555">
</p>

---

## Features

### Reading & Text Cleanup

- **Reading**: Local book import with paged/scroll modes, typography customization, blue-light filter, eye-rest reminders, and local reading stats.
- **Word Selection & Dictionary**: Toggle selection mode to lock page turns while highlighting text, look up words with an optional offline dictionary, or mark repeated lines as ads.
- **Text Cleanup**: Automatically groups site URLs, notices, watermarks, obfuscated domains, and repeated boilerplate lines for batch removal. Original files are never modified and can be restored at any time without losing progress or notes.

### Offline AI Analysis & Search

- **Book Report**: Cast & relationships, romance structure, pacing chart, and chapter overviews, with links to supporting passages.
- **Semantic Search**: Search by plot meaning rather than exact wording.

### Local Read-Aloud & Covers

- **Read-Aloud**: On-device speech synthesis with per-chapter progress tracking, streaming synthesis, and chapter pre-generation (iOS also includes a 200 MB lightweight voice pack).
- **AI Covers**: Generates covers locally for books without cover art.

### Book Sources

- **Legado Compatibility**: Batch-import Legado book sources via file or URL, with one-tap dead-source checking.
- **Multi-Source Search & Download**: Search across sources and download full books, filling in missing or truncated chapters from alternate sources.

## Local Execution & Data Safety

- **Fully Offline, Zero Cost**: Analysis, search, read-aloud, and image generation all run locally. No text is uploaded, and there are no accounts, API keys, ads, or analytics. Models are not bundled—each downloads on demand (with resume support) and can be deleted in Settings.
- **Low-Impact Scheduling**: Hardware acceleration via Vulkan (Windows) and Metal (iOS). Background tasks offer idle, balanced, and immediate modes, automatically pausing and resuming based on battery, temperature, and app state.
- **System Requirements**: Windows x64; Android 7.0+ (ARM64); iOS 13+ to install (iOS 16.4+ for AI features).
- **Separate Data Storage**: Bookshelf, progress, and settings are stored apart from the app binary. Windows automatically backs up data before first launch of a new version; on Android and iOS, install over the existing app rather than uninstalling first.

## Download

| Platform | Download |
| --- | --- |
| Windows | [Zhiyue 1.5.4](https://github.com/envymoon/EdgeNovel/releases/tag/windows-v1.5.4) (unzip and run `novel.exe`; keep the whole folder together) |
| Android | [Zhiyue 1.5.4](https://github.com/envymoon/EdgeNovel/releases/tag/android-v1.5.4) (ARM64; install over existing app) |
| iOS | [Zhiyue 1.5.4](https://github.com/envymoon/EdgeNovel/releases/tag/ios-v1.5.4) (unsigned; sign and install over existing app) |

## Changelog

**1.5.4** (Windows / Android / iOS) — Reworked pacing analysis with nearby chapter tags; streamlined 4-tab bottom navigation and settings; added blue-light filter, eye-rest reminder, and shelf last-read time; synced Windows to chapter-based read-aloud and added 200 MB lightweight voice pack on iOS; improved obfuscated ad-domain cleanup, locked page turning in selection mode, and added optional offline dictionary; added author tics and cast appearance views.

**1.5.3** (iOS) — Lock screen, Control Center, and headphone controls for read-aloud; fixed background synthesis stopping after screen lock and long-press-to-read in paged mode.

**1.5.2** (iOS) — Per-chapter read-aloud progress, steadier tone, faster synthesis, and background synthesis fixes; chapter and character selection in book reports.

**1.5.1** (iOS) — Smoother page turns, read-aloud starting from current page or long-pressed sentence; fixed bottom-line clipping after font changes.

**1.5.0** — Added Text Cleanup to group and batch-remove embedded ads and boilerplate with one-tap restoration.

---

<sub>Only import content you have the right to read. Zhiyue ships with no book sources. This repository has no open-source license yet; until one is added, no right to copy, modify or redistribute is granted.</sub>
