# Hypernote2

A tiny, all-cloud meeting notepad for macOS, modelled on [Hyprnote](https://github.com/fastrepl/hyprnote)'s look and feel.

- **SwiftUI** menu bar app + a **WKWebView** hosting the UI (`web/`, plain HTML/CSS/JS, no build step).
- **Transcription:** AssemblyAI pre-recorded API with `speaker_labels` (diarization) — runs *after* the meeting.
- **Summaries:** DeepSeek Flash (`deepseek-flash`, auto-detected from `/models`), streamed, using a template.
- **Templates:** General, 1-1, Brainstorming, Daily Standup, Customer Demo, plus your own (Settings → Summary templates).
- **No models, no downloads.** The built app is under 1 MB.

## Setup page

First launch asks for two keys — AssemblyAI and DeepSeek. Each is verified against the provider, then stored in the macOS Keychain.

## Build & run

```bash
./scripts/build-app.sh        # -> build/Hypernote2.app
open build/Hypernote2.app
swift test                    # core logic: parsing, prompts, storage, controller (offline, stubbed network)
```

Requires macOS 14+ and the Xcode toolchain. In restricted shells add `SWIFT_BUILD_FLAGS=--disable-sandbox`.

## How it works

1. Press **Start recording** (or use the menu bar item). Mic audio — and system audio via ScreenCaptureKit if allowed — is mixed to a mono 16 kHz AAC file (~14 MB/hour).
2. On **Stop**, the file is uploaded to AssemblyAI, transcribed with speaker labels, then summarized by DeepSeek with the note's template.
3. Click a speaker name in the Transcript tab to rename it; regenerate the summary to use the names.

Data lives in `~/Library/Application Support/Hypernote2/` (JSON + `audio.m4a` per note).

## Permissions

Microphone (required). Screen & System Audio Recording (optional, to capture the other side of calls). Without it Hypernote2 records the mic only and says so.

## License

GPL-3.0 (see `LICENSE`). The UI styling and app icon are derived from Hyprnote (GPL-3.0).
