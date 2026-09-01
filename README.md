# Cadence

Cadence is a native macOS dictation app that writes into the focused application as you speak. Instead of waiting for an entire recording and pasting one large block, Cadence commits stable words incrementally as keyboard events.

This makes Cadence useful in editors where revision history, collaboration playback, or natural typing behavior matters.

## Features

- Live, low-latency dictation in any macOS text field
- Character-level keyboard injection rather than a final bulk paste
- Append-only transcript stabilization that avoids rewriting committed words
- On-device speech recognition when supported by the selected locale
- Personal dictionary for names, acronyms, and specialized vocabulary
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
- Speech Recognition access
- Accessibility access for typing into other applications

The current release build is optimized for Apple Silicon. The speech engine uses Apple's Speech framework, so recognition availability and on-device language support depend on macOS.

## Build and run

Clone the repository, then run:

```sh
./scripts/build-app.sh
open dist/Cadence.app
```

The build uses Swift Package Manager and produces an application bundle at `dist/Cadence.app`. A full Xcode installation is not required; current Command Line Tools are sufficient.

Official builds are signed with the project's `Cadence Signing` certificate so macOS privacy grants survive updates. Without that identity the script falls back to an ad-hoc signature, which works but makes macOS treat every rebuild as a new app: re-grant Accessibility after rebuilding. See [Releasing](docs/RELEASING.md) for details.

## First launch

Open **Settings** in Cadence and grant the three required permissions:

1. Microphone
2. Speech Recognition
3. Accessibility

Cadence re-checks these every few seconds while Settings is open, so changes made in System Settings show up without restarting the app. If macOS lists Cadence as enabled but Cadence still reports a permission as needed, remove Cadence from that list in System Settings and grant it again: the entry belongs to a different copy of the app.

Place the cursor in an editor and press the configured shortcut. The default is **Control–Option–Space**. Press it again to finish.

The floating bar can stop or cancel dictation without activating the main Cadence window. When idle, it collapses into a slim edge-aware handle and expands when hovered. Drag the expanded logo to snap it to one of eight screen-edge positions. Hold Command while dragging for free placement. Double-click the logo to open Cadence; a single click never opens the app.

## How incremental dictation works

Live speech recognition results are provisional: the recognizer may revise its newest words as more audio arrives. Cadence compares consecutive hypotheses, holds back the unstable tail, and commits only the repeated stable prefix. Each committed delta is emitted as individual Unicode key-down and key-up events.

This design favors append-only document history. It cannot guarantee both unrestricted whole-paragraph AI rewriting and never changing already committed text. See [Research and architecture](docs/RESEARCH.md) for the model evaluation and design rationale.

## Privacy and security

- Audio is processed through Apple's Speech framework and is not saved by Cadence.
- Transcript history and personal dictionary entries are stored locally in the app's user defaults.
- Cadence does not include analytics, advertising, accounts, or cloud sync.
- Update archives and the update feed are verified with Ed25519 signatures before installation.
- The private update-signing key is not stored in this repository.

Some locales may require Apple's network-backed speech service when on-device recognition is unavailable or disabled.

Please report security issues through the repository's private security advisory feature. See [SECURITY.md](SECURITY.md).

## Architecture

| Component | Responsibility |
|---|---|
| `AppleSpeechEngine` | Captures microphone buffers and publishes partial recognition results |
| `TranscriptStabilizer` | Converts revisable hypotheses into append-only stable deltas |
| `KeystrokeInjector` | Sends character-level Unicode keyboard events to the focused app |
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

The stable-prefix logic and persisted public preference types have unit coverage. Microphone, accessibility, and cross-application typing behavior require manual testing because macOS permission prompts cannot be automated safely.

## Releases

Maintainers can prepare a signed release without uploading it:

```sh
./scripts/prepare-release.sh 0.2.0
```

Release artifacts are written to the ignored `release/` directory. The manual **Release Cadence** workflow promotes an explicitly tested Edge commit to an intentional, versioned release. Releases below `1.0.0` are labeled Public Beta; `1.0.0` and later are Stable. The **Publish Edge Build** workflow updates one rolling prerelease after every successful commit on `main`; users must explicitly select Edge in update settings. See [Releasing Cadence](docs/RELEASING.md).

## Contributing

Contributions are welcome. Keep the speech engine, stabilization policy, and keyboard injection layers separate so recognition models can change without affecting editor behavior. Before opening a pull request, run `swift test` and verify that no credentials, local paths, generated builds, recordings, or transcript data are included.
