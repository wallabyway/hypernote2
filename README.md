# Hypernote2

A tiny, all-cloud meeting notepad for macOS, modelled on [Hyprnote](https://github.com/fastrepl/hyprnote)'s look and feel. Record a meeting, get a transcript with speaker labels, and a summary shaped by a template.

![Summary tab: a standup summarized with the Daily Standup template](docs/screenshot-summary.png)

![Transcript tab: diarized speakers with timestamps](docs/screenshot-transcript.png)

> The screenshots are the real `web/` UI rendered with sample data (`scripts/screenshot`), not a capture of the native window.

## Features

- **Speaker-labelled transcripts** from AssemblyAI (`speaker_labels`). Click a speaker name to rename it.
- **Template summaries** from DeepSeek Flash, streamed as they're written: General, 1-1, Brainstorming, Daily Standup, Customer Demo, plus your own (Settings → Summary templates).
- **Your notes count.** What you type during the meeting steers the summary.
- **Menu bar app** with Start/Stop Recording, and optional **Launch at Login**.
- **Nothing to download.** No models, no local inference; the built app is about 1 MB.

Transcription runs **after** you press Stop (the audio file is uploaded to AssemblyAI), not live.

## Setup page

On first launch Hypernote2 asks for two keys:

| Key | Used for | Get one |
|---|---|---|
| AssemblyAI | transcription + speaker diarization | assemblyai.com/dashboard |
| DeepSeek | summaries (Flash model, detected automatically) | platform.deepseek.com/api_keys |

Each key is verified against its provider before it is saved to the macOS Keychain. You can replace them later in Settings.

## Build & run

Requires macOS 14+ and the Xcode toolchain.

```bash
./scripts/build-app.sh        # -> build/Hypernote2.app
open build/Hypernote2.app
swift test                    # parsing, prompts, storage, controller (offline, network stubbed)
```

In restricted shells, prefix with `SWIFT_BUILD_FLAGS=--disable-sandbox`.

## Launch at login

Click the waveform icon in the menu bar and toggle **Launch at Login** (a checkmark means it's on). While the window is open you can also right-click the Dock icon for the same item. This uses macOS's login-item API, so it also shows up in System Settings → General → Login Items.

If macOS refuses (it can for apps outside `/Applications`), move `Hypernote2.app` to `/Applications` and try again. If it asks for approval, Hypernote2 opens the Login Items pane for you.

## How it works

1. **Start recording** (window button or menu bar). Microphone audio, plus system audio if you allow it, is mixed into a mono 16 kHz AAC file (about 14 MB/hour).
2. **Stop** uploads the file to AssemblyAI, which returns diarized utterances.
3. DeepSeek turns the transcript, your notes and the note's template into a Markdown summary, then suggests a title.

Architecture in short: a SwiftUI menu bar app hosts a `WKWebView` (`web/`, plain HTML/CSS/JS) and talks to Swift through a small message bridge. All logic lives in the `HypernoteCore` library. See [PLAN.md](PLAN.md) for how it was built and why.

Data lives in `~/Library/Application Support/Hypernote2/` (one JSON file and `audio.m4a` per note).

## Permissions

- **Microphone** (required).
- **Screen & System Audio Recording** (optional): lets Hypernote2 capture the other side of calls. Without it, only your microphone is recorded and the app tells you so.

## Regenerating the screenshots

```bash
cd scripts/screenshot && npm install
CHROME_PATH=/path/to/chrome-or-headless-shell npm run shots
```

## License

GPL-3.0 (see `LICENSE`). The UI styling and app icon are derived from Hyprnote (GPL-3.0).
