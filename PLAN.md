# Hypernote2: how it was built

This documents the path from the original request to the current app, including the dead ends and the reasons behind each decision.

## 1. The request

> Under the github folder, create a subfolder `hypernote2` that clones the Hyprnote repo for AI note-taking, except that it uses AssemblyAI's STT and diarization APIs to produce a meeting transcript with speakers, plus a custom summary based on a template (1-1, brainstorming, daily standup, customer demo). The summary comes from a DeepSeek Flash key. The setup page takes two keys: AssemblyAI and DeepSeek.

Requirements added later in the thread:

| When | Requirement |
|---|---|
| After choosing the fork | Use `github.com/bahodirr/hyprnote` |
| Transcription timing | Transcribe **after** the meeting, not live |
| LLM provider | **DeepSeek** (not Moonshot/Kimi) |
| Weight | Super lightweight. No model weights or downloads, everything remote. **Stop if likely over 50 MB** |
| Shell | No Tauri. **SwiftUI menu bar app + WebKit** host, purely macOS |
| UI | Keep Hyprnote's look and feel as much as possible |

## 2. Path taken (and why it changed)

### Attempt 1: fork `fastrepl/anarlog` (abandoned)

- The first clone was `fastrepl/anarlog` (the current upstream, renamed from Hyprnote). A local copy already existed next to it.
- Findings: it already had AssemblyAI (with `speaker_labels`) and DeepSeek providers, a template system, and an onboarding flow. The plan was a thin change: replace the onboarding "login" step with a two-key step, seed four meeting templates, and select `assemblyai` + `deepseek-flash` automatically.
- I wrote a key-entry step and a template-seeding module and type-checked them, then you pointed me at a different repo. **That work was deleted** (at your request) and is not in this repo.

### Attempt 2: `bahodirr/hyprnote` (stopped by the size rule)

- Fresh shallow clone. It's an October 2025 snapshot: Tauri 2 + React with Rust plugins.
- It has **no AssemblyAI or DeepSeek support**. STT is local Whisper or a "Custom" Deepgram-style endpoint; the LLM side has a custom-endpoint view.
- Size audit against your "stop if over 50 MB" rule:
  - `apps/desktop/public/assets`: ~77 MB of tutorial GIFs shipped with the frontend.
  - ~95 MB of ONNX models (echo cancellation, speaker detection) in `crates/aec` and `crates/pyannote-local`.
  - ~31 MB of Windows DirectML/ONNX Runtime DLLs.
  - Local Whisper/llama/ONNX native crates, wired directly into the recording listener.
- Conclusion: stripping this down means rewiring the Rust listener, with no guarantee it compiles or lands under 50 MB. I stopped and offered three options; you chose a **lean rewrite**.

### Attempt 3: lean rewrite (this repo)

You then specified SwiftUI + WebKit instead of Tauri. The Hyprnote clone was moved to `../hyprnote-ref` and used only as a **visual reference** (theme tokens, layout, logo, app icon).

## 3. Architecture

```
Hypernote2.app  (924 KB)
├── Sources/Hypernote2        SwiftUI menu bar app + WKWebView host + JS bridge
├── Sources/HypernoteCore     everything else, no UI dependencies
│   ├── AppController         command dispatcher, state, recording + processing pipeline
│   ├── Recorder              mic + system audio -> mono 16 kHz AAC
│   ├── AssemblyAI            upload, transcript job, polling, diarized parsing
│   ├── DeepSeek              model discovery, streamed chat completion
│   ├── Prompts / Templates   summary prompt builder, 5 built-in templates
│   ├── Store / Secrets       JSON files on disk, Keychain for keys
└── web/                      plain HTML/CSS/JS UI (no build step)
```

Flow: **Start recording** -> mic (+ system audio) mixed to a small AAC file -> **Stop** -> upload to AssemblyAI -> transcript with `speaker_labels` -> DeepSeek Flash writes a template-shaped summary (streamed) -> optional auto-title.

JS talks to Swift via `WKScriptMessageHandlerWithReply`, so each UI action is `await native(cmd, args)`; Swift pushes events (`session`, `summary_delta`, `tick`, `level`, `toast`) back through `evaluateJavaScript`.

## 4. Decisions and rationale

| Decision | Why | Trade-off |
|---|---|---|
| Transcribe **after** the meeting | You chose it. AssemblyAI's pre-recorded API gives the most reliable diarization, and it avoids a live WebSocket pipeline. | No live transcript during the meeting. |
| DeepSeek, not Moonshot | You chose DeepSeek ("Moonshot" is a different company with a different key). | Only one LLM provider is wired. |
| Pick the Flash model from `/models` at key-save time | DeepSeek's docs now name it `deepseek-flash`; earlier sources said `deepseek-v4-flash`. Discovery avoids hard-coding a name that may change. Falls back to `deepseek-flash`. | One extra request when saving the key. |
| DeepSeek with `thinking: disabled` | Summaries don't need chain-of-thought; faster and cheaper. | Slightly less reasoning on complex meetings. |
| Library + executable split (`HypernoteCore`) | Keeps almost all logic testable without UI; the executable is ~100 lines. | Small amount of `public` surface. |
| Swift 5 language mode | Avoids strict-concurrency friction around AVFoundation/ScreenCaptureKit callbacks. | Fewer compile-time data-race checks. |
| Plain HTML/CSS/JS, no framework or bundler | Keeps the app tiny and the build a single script; the UI is ~500 lines of JS. | No component framework; manual re-rendering. |
| Mic is the master clock when mixing | Mic delivers continuously; system audio is zero-padded if it lags and trimmed to <= 1 s drift. | Possible small sync error between sources on long meetings. |
| Mono 16 kHz AAC at 32 kbps | ~14 MB/hour on disk and upload; fine for speech recognition. | Not archival quality. |
| System audio via ScreenCaptureKit (optional) | Needed to capture the other side of calls; falls back to mic-only with a visible warning if denied. | Requires Screen & System Audio Recording permission. |
| API keys in macOS Keychain; verified before saving | Keys never touch disk; bad keys are rejected on the setup page. | Ad-hoc signing means rebuilds can re-trigger Keychain prompts. |
| Menu bar app (`LSUIElement`) that shows a Dock icon only while its window is open | Matches the "menu bar app" request; the regular activation policy while open provides the Edit menu so paste works in key fields. | Dock icon appears and disappears. |
| Inline "Delete?" confirm and inline speaker rename instead of `confirm()`/`prompt()` | `WKWebView` ignores JS dialogs unless a UI delegate implements them. | Slightly more JS. |
| Custom markdown renderer that escapes HTML first | Summaries come from an LLM and are inserted as HTML; escaping first prevents injection. | Supports only the subset of Markdown the prompt asks for. |
| Built-in templates are read-only; "Duplicate" to customize | Prevents accidental edits to the four requested types; custom ones are stored separately. | An extra click to tweak a built-in. |
| "Launch at Login" as a toggle in the menu bar menu and the Dock menu, via `SMAppService.mainApp` | A menu bar app's right/left-click menu is its context menu; the system API also surfaces it in Login Items. | Can fail outside `/Applications` or ask for approval; both are surfaced in the UI. Not exercised on this machine so as not to change your login items. |
| Added a fifth "General Meeting" template | A sensible default when no meeting type fits. | Not in your original list of four. |
| GPL-3.0 license | Styling and icon are derived from Hyprnote (GPL-3.0). | The code is GPL too. |

## 5. Verification

- `swift test`: 20 tests pass (AssemblyAI parsing incl. no-diarization fallback, DeepSeek SSE and model pick, prompt/template content, mixer/queue logic, storage, and the controller with the network stubbed: key verification, summary streaming + auto-title, template lifecycle, missing-key errors).
- `./scripts/build-app.sh` builds a release `.app` (924 KB, ad-hoc signed); it launches and stays running.
- README screenshots are the web UI rendered in headless Chrome with sample data (`scripts/screenshot`), because screen capture of the native window is blocked in this environment.
- UI states (setup, notes, summary, transcript, settings, error, start/recording, streaming) were rendered in headless Chrome against a stubbed bridge and reviewed by eye.

## 6. Not verified yet

- Anything needing real credentials or permissions: live AssemblyAI upload/transcription, live DeepSeek summary, actual microphone and system-audio capture.
- Window dragging from the top bar (uses `performDrag` with `NSApp.currentEvent`).
- Pasting into key fields via the regular-policy Edit menu.
- Behavior when the app is quit mid-recording: the note is marked interrupted and the partial audio is kept for retry.
- Toggling Launch at Login (compiled and launched, but not switched on).
- Pixel-level comparison with the real Hyprnote UI.

## 7. Possible next steps

- Live captions via AssemblyAI streaming (would replace the "after the meeting" flow only if you want it).
- Stop and save the recording cleanly on quit.
- Provider choice (Moonshot/Kimi) as an alternative summarizer.
- Calendar-triggered recording and export to Markdown/PDF.
