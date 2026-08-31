# Cadence

Cadence is a native macOS dictation app that types into the focused application continuously instead of pasting one large transcript when recording ends.

The first build is intentionally optimized for the Mac in this workspace: Apple Silicon running macOS 15. It uses `AVAudioEngine`, Apple's Speech framework, SwiftUI/AppKit, and accessibility-approved keyboard events. Audio is not saved. Transcript history stays in local `UserDefaults`.

## Run it

```sh
./scripts/build-app.sh
open dist/Cadence.app
```

On first launch, open **Settings** in Cadence and grant:

1. Microphone
2. Speech Recognition
3. Accessibility

Put the cursor in any editor and press **Control–Option–Space**. Press it again to finish. The small floating bar can also stop or cancel a session without activating Cadence.

## Why it types differently

Speech recognizers revise their newest partial result. Cadence compares consecutive hypotheses and holds back one unstable word. Once a prefix repeats, it sends only the newly stable suffix as individual Unicode keyboard events. This gives document editors incremental history while avoiding most visible rewrites.

The tradeoff is deliberate: a fully rewritten, LLM-polished paragraph and an append-only, keystroke-by-keystroke history cannot both be guaranteed. Cadence prioritizes the latter. See [Research and architecture](docs/RESEARCH.md).

## Project layout

- `AppleSpeechEngine.swift` — live microphone capture and partial transcription
- `TranscriptStabilizer.swift` — append-only stable-prefix algorithm
- `KeystrokeInjector.swift` — character-level macOS keyboard events
- `AppModel.swift` — session orchestration, local history, permissions
- SwiftUI views — native hub, dictionary, settings, and floating Flow-style bar

## Development

```sh
swift test
swift build
```

This repository uses Swift Package Manager so it can build with Command Line Tools alone. The packaging script creates and ad-hoc signs a real `.app` bundle.
