# Zhiyue 挚阅

[简体中文](README.md) | English

<p align="center">
  <img src="docs/assets/novel-icon.ico" width="112" alt="Zhiyue app icon">
</p>

<p align="center"><strong>A quieter way to read Chinese web fiction.</strong><br>Local AI, searchable stories, and reading notes that stay with you.</p>

A local-first novel reader designed for Chinese web fiction, with mobile as its final destination.

The project brings small language models, rule-based retrieval, and reading data onto the user's own device. Its goal is to make AI useful both before and during reading—without turning reading into a permanently connected cloud conversation.

> This project is in early development. Windows is the most complete version and is used for daily reading. The Android version has completed its first migration and emulator validation. iOS development is starting on a cloud Mac.

## Why This Project Exists

Readers of long-form Chinese web fiction often need answers to questions more specific than “What does this paragraph mean?”:

- Is a novel with hundreds or thousands of chapters worth starting?
- Do its protagonist, main cast, and romance structure match the reader's preferences?
- After a long break, how can the reader quickly find a character, earlier event, or relevant chapter?

The product is therefore organized into two distinct layers.

### Reading Report

The report appears on the book details page, so it can be read before starting the novel. It currently covers the cast and their relationships, the romance structure (the heroines by name), chapter overviews, a pacing chart counted from the text (no model needed), and links to the supporting passages.

A small model cannot reliably make unrestricted, book-wide judgments about a very long novel. This project therefore does not delegate every conclusion to AI. Rules and retrieval provide stable, inspectable results; the lightweight model is reserved for bounded tasks it can handle. Whenever possible, users can return to the original chapter and make the final judgment themselves.

### Reading Assistant

The in-reader assistant provides search, the reading report, background work, and reading appearance. It is kept separate from the book page so that choosing a book and reading a book do not become the same workflow.

## Features

- Local TXT import, encoding handling, chapter detection, and custom shelf categories
- Reading-position recovery, latest-chapter tracking, and completion marks for chapters actually read
- Chapter navigation and a shortcut back to the current reading position
- Inline annotations with management and source-location navigation
- Cast, relationship, and romance-structure analysis
- Chapter overviews, a whole-book pacing curve (also under the reader), and full-text semantic search
- Reading statistics computed from the reader's own reading log
- AI covers drawn by an on-device image model, and illustrations placed between chapters
- Read-aloud on Windows with an on-device Qwen3-TTS voice: play while it speaks, or prepare chapters ahead, at an adjustable pace
- Optional Youshu (优书网) reviews, fetched only when the reader opens them
- Themes, accent colors, backgrounds, interface fonts, and a Chinese/English interface
- A snapshot of the library and settings before a new build first opens them
- Recoverable local AI task queue with pause, retry, and chapter-level checkpoints
- Low-impact background, balanced, and finish-now workload modes
- Charging, battery, idle-time, and thermal constraints
- On-demand model downloads, integrity checks, resume support, and version rollback
- On-demand fonts and mobile-oriented reading interactions

### Core workflows at a glance

| Before reading | While reading | Under the hood |
| --- | --- | --- |
| Cast and romance structure, chapter overviews, and pacing | Chapter jump, current-position recovery, annotations, and semantic search | On-device models, resumable tasks, workload limits, and model rollback |

## AI on Edge Devices

The current generation baseline is **Qwen3 0.6B Q8**, with **BGE small Chinese F16** for semantic retrieval. Cast and relationship tasks read up to **8K tokens** of sampled evidence. Chapter summaries read a fixed excerpt and run in a **2K window**: measured against 8K, the summaries are word-for-word identical (78 chapters on GPU, 48 on CPU) while the KV cache is a quarter of the size. Workload modes adjust threads, scheduling, intervals, and model unloading; they never change what the model reads.

AI covers use an anime-style SD 1.5 model quantized to 0.70 GB, run by a patched [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) (Vulkan on Windows). The recipe is in `experiments/anime-cover-model/`.

Models are not bundled with the installer. They are downloaded only when the related feature is requested, keeping the application package smaller and allowing model updates or rollbacks independently of app releases.

Target device tiers (pending broader physical-device testing):

| Tier | Suggested device | Local AI support |
| --- | --- | --- |
| Reading first | 4GB RAM or less | Core reading features; generative AI is not guaranteed |

Actual performance depends on the processor, available memory, operating-system background limits, and cooling—not memory capacity alone.

## Edge-first Workload Design

Edge computing is not only about placing a model on the device. Zhiyue continuously adjusts **when** and **how much** work is done so reading stays responsive:

- It combines charging state, battery level, thermal state, idle time, memory pressure, and task priority before starting a slice of work.
- **Quiet idle** works in small slices, yields to the reader, and unloads the model between longer intervals when possible.
- **Balanced** keeps a steady background pace for chapter analysis and retrieval.
- **Finish now** uses the available resources to complete a requested result sooner, while still respecting device safety limits.
- These modes change scheduling, thread count, intervals, and model residency—not what the model reads or the meaning of the result.

The goal is not to pretend that inference has no cost. It is to make that cost adaptive, visible, and appropriate for a phone that is also being used for reading.

## Platform Status and Downloads

Windows and Android use separate GitHub Releases. Their packages and release tags are not shared.

### Windows

**Release tag:** [`windows-v1.2.0`](https://github.com/envymoon/EdgeNovel/releases/tag/windows-v1.2.0)  
**Download:** `Zhiyue-Windows-x64-1.2.0.zip`

Windows is currently the most complete version. The `novel.exe` file must remain beside the bundled `data` directory and DLL files; copying or downloading the executable alone will not work.

Upgrading keeps the bookshelf: reading data lives in `%APPDATA%\com.novel\novel\`, not beside the executable, so replacing the extracted folder does not touch it. The first launch of a new build also copies the library and settings to `backups/` there.

### Android

**Release tag:** [`android-v1.0.0-preview.1`](https://github.com/envymoon/EdgeNovel/releases/tag/android-v1.0.0-preview.1)  
**Download:** `Novel-Android-arm64-v8a-1.0.0-preview.1.apk`

The Android migration includes emulator tests for the bookshelf, book details, settings, reader, annotations, chapter navigation, completed-chapter marks, background recovery, model download failures, and Android system-back behavior.

Current status: the first ARM64 Android preview is available. It uses a development signing key and has not yet been validated on a physical phone; a later official signing key may require reinstalling the app.

### iOS

There is no iOS build yet. Development is starting on a cloud Mac, with a TestFlight build on a physical iPhone as the first goal and the Windows design carried over. iOS does not allow helper processes, so the inference engine will run inside the app on Metal.

See the [release guide](docs/RELEASING.md) for platform-specific packaging rules.

## Repository Structure

- `app/`: Flutter UI, platform projects, application state, and shared mobile layer
- `app/rust/`: Rust data and AI bridge used by the application
- `core/`: novel parsing, cast, relationship, romance, and diagnostic algorithms
- `tts-server/`: optional remote text-to-speech service
- `app/docs/`: mobile migration and implementation notes

## Current Limitations

- A 0.6B model cannot independently understand an entire long-form web novel with consistent accuracy. Some analysis may still miss evidence or produce incorrect results.
- The reading report supports decision-making; it is not a definitive statement about a novel. Important results should be checked against their source passages.
- Android has not yet undergone physical-device testing for memory use, temperature, battery consumption, or long-running background behavior.
- iOS is in early development and has no build yet.
- No open-source license has been selected yet. Until a license is added, no permission is granted to copy, modify, or redistribute the code.

## Roadmap

The short-term priority is the iOS version on a physical iPhone while keeping the Windows version stable; Android follows. The next stage will fine-tune a model on purpose-built Chinese web-fiction data to improve character, relationship, and chapter tasks instead of simply increasing the on-device model size.

## Content and Privacy

Novel text, reading history, annotations, and generated caches are stored locally by default. The public repository and Releases do not include test novels, user databases, model weights, or personal reading data. Users should only import content they are authorized to use.
