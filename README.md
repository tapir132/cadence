# Cadence

Cadence is a native macOS dictation app that transcribes locally and types completed words live into the focused application. It keeps only the unfinished frontier word provisional, flushes the tail on a pause, and uses punctuation, grammar, and pause length to decide whether the sentence is actually over.

## Features

- Live on-device English transcription with NVIDIA Parakeet Unified 0.6B through FluidAudio
- Append-only word emission with context-aware sentence boundaries after a pause
- Continuous pause rollover, including punctuation and speech in later sentences
- Fast (320 ms) and Accurate (1.12 s) local recognition profiles
- Optional filler-word cleanup for hesitation sounds such as “um” and “uh”
- Serialized standard clipboard pastes instead of lossy per-character Unicode events
- Focus-bound delivery that refuses to paste after the user changes windows
- Personal dictionary spelling, capitalization, and diacritics for names and specialized vocabulary
- Configurable global keyboard shortcut
- Edge-aware idle handle that expands on hover or while dictating
- Eight edge snap points, Command-drag free positioning, and adjustable sizing
- Adjustable floating-bar size from 65% to 135%
- Local transcript history and words-per-minute statistics
- Failed-insertion detection with a non-activating transcript recovery card
- Signed automatic updates through Sparkle and GitHub Releases
- Native SwiftUI and AppKit interface

## Requirements

- macOS 14 or later
- Microphone access
- Accessibility access for pasting into other applications

The current release build is optimized for Apple Silicon. On first launch Cadence downloads and prepares the English speech and voice-activity models (roughly 600 MB total); later transcription runs locally without sending microphone audio to a speech service. Selecting Accurate downloads one additional local encoder the first time it is used.

## Build and run

Clone the repository, then run:

```sh
./scripts/build-app.sh
open dist/Cadence.app
```

Local app bundles receive a timestamp build number and a `-local.<commit>` display version. This keeps an already-published Edge build from replacing an installed smoke-test build before it can be verified. Edge and release workflows preserve their explicitly configured distribution versions.

The build uses Swift Package Manager and produces an application bundle at `dist/Cadence.app`. A full Xcode installation is not required; current Command Line Tools are sufficient.

Official builds are signed with the project's `Cadence Signing` certificate so macOS privacy grants survive updates. Without that identity the script falls back to an ad-hoc signature, which works but makes macOS treat every rebuild as a new app: re-grant Accessibility after rebuilding. See [Releasing](docs/RELEASING.md) for details.

## First launch

Open **Settings** in Cadence and grant the two required permissions:

1. Microphone
2. Accessibility

Cadence re-checks these every few seconds while Settings is open, so changes made in System Settings show up without restarting the app. If macOS lists Cadence as enabled but Cadence still reports a permission as needed, remove Cadence from that list in System Settings and grant it again: the entry belongs to a different copy of the app.

Place the cursor in an editor, hold the configured shortcut while you speak, and release it to finish. The default is **Control–Option–Space**; a function key or a modifier-only chord such as ⌃⌥ works too.

Say **“period”**, **“full stop”**, or **“question mark”** to insert `.`, `.`, or `?` instead of the command words. These commands follow the convention used by macOS Dictation.

The floating bar can stop or cancel dictation without activating the main Cadence window. When idle, it collapses into a slim edge-aware handle and expands when hovered. Drag the expanded logo to snap it to one of eight screen-edge positions. Hold Command while dragging for free placement. Double-click the logo to open Cadence; a single click never opens the app.

## How dictation works

Cadence captures 16 kHz mono audio for as long as the shortcut is held. Silero voice-activity detection prevents leading silence from reaching the recognizer and identifies a sustained pause. Parakeet Unified streams partial hypotheses with 320 ms model latency in Fast or 1.12 s in Accurate. Cadence holds the unfinished last word—and its punctuation—until a following boundary or pause confirms it. Safe completed words are inserted immediately.

After about 750 ms of speech-ending silence, Cadence inserts the sentence tail and classifies the boundary. Explicit or model-supplied terminal punctuation closes immediately. A dependent clause such as “Because my Apple dictation…” keeps the same decoder stream and language context when speech resumes. An uncertain fragment gets a short grace window; if silence continues, Cadence closes it with punctuation and starts a fresh stream without ending the held shortcut. Releasing the shortcut finalizes any open thought.

Personal-dictionary matching occurs before text becomes visible. Cadence can therefore hold a possible multiword name briefly and safely restore exact case and diacritics—for example, `Jose Arcadio Buendia` to `José Arcadio Buendía`—without editing text after it was pasted. Optional filler-word cleanup also runs at this pre-insertion stage. It is intentionally conservative and does not rewrite earlier prose or interpret “forget that” as a destructive edit.

Each safe text delta is written to the pasteboard and delivered with a complete physical Command-down, V-down, V-up, Command-up sequence. Paste operations are serialized so a later word cannot replace the pasteboard before the focused editor consumes the previous one.

The application and focused window captured at recording start are checked again immediately before the V key-down. If the target changed, Cadence leaves the transcript on the clipboard and shows a recovery card instead of risking a paste into the wrong window. See [Research and architecture](docs/RESEARCH.md) for the evidence and tradeoffs behind this design.

## Privacy and security

- Audio is processed locally by the downloaded Parakeet/Core ML model and is not saved by Cadence.
- Transcript history and personal dictionary entries are stored locally in the app's user defaults.
- Cadence does not include analytics, advertising, accounts, or cloud sync.
- Update archives and the update feed are verified with Ed25519 signatures before installation.
- The private update-signing key is not stored in this repository.

The speech model files are downloaded from the public model host on first use. Dictation is currently English-only.

Please report security issues through the repository's private security advisory feature. See [SECURITY.md](SECURITY.md).

## Architecture

| Component | Responsibility |
|---|---|
| `AudioCaptureEngine` | Captures and streams ordered 16 kHz mono microphone chunks |
| `LiveSpeechTranscriber` | Runs Silero VAD and streaming Parakeet Unified decoding with pause rollover |
| `LiveTranscriptEmitter` | Holds the unfinished word and emits only safe append-only text deltas |
| `KeystrokeInjector` | Serializes focus-bound clipboard pastes to the target app |
| `FloatingPanelController` | Manages the cross-Space, dockable, draggable recording surface |
| `AppModel` | Coordinates sessions, permissions, preferences, and local history |
| `TextInsertionVerifier` | Confirms delivery from accessibility text state and surfaces recoverable failures |
| `UpdateManager` | Connects Sparkle's signed update lifecycle to the app and settings |

## Development

Run the test suite and debug build with:

```sh
swift test
swift build
```

Audio conversion, word stability, punctuation rollover, pasteboard fidelity, physical paste events, insertion evidence, window behavior, and preferences have automated coverage. The full production path is opt-in because it downloads the ASR and VAD models:

```sh
CADENCE_RUN_STREAMING_MODEL_TEST=1 swift test --filter StreamingModelIntegrationTests
```

Microphone permissions and cross-application insertion still require testing with the signed app because macOS privacy grants cannot be automated safely.

## Releases

Maintainers can prepare a signed release without uploading it:

```sh
./scripts/prepare-release.sh 0.2.0
```

Release artifacts are written to the ignored `release/` directory. The manual **Release Cadence** workflow promotes an explicitly tested Edge commit to an intentional, versioned release. Releases below `1.0.0` are labeled Public Beta; `1.0.0` and later are Stable. The **Publish Edge Build** workflow updates one rolling prerelease after every successful commit on `main`; users must explicitly select Edge in update settings. See [Releasing Cadence](docs/RELEASING.md).

## Contributing

Contributions are welcome. Keep audio capture, streaming recognition, transcript stabilization, and text insertion separate so recognition models can change without affecting editor behavior. Before opening a pull request, run `swift test` and verify that no credentials, local paths, generated builds, recordings, or transcript data are included.
