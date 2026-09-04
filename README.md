# Cadence

Cadence is a native macOS dictation app that transcribes locally and types completed words live into the focused application. It keeps only the unfinished frontier word provisional, flushes the tail on a pause, and uses punctuation, grammar, and pause length to decide whether the sentence is actually over.

[Public usage statistics](https://github.com/tapir132/cadence/issues?q=is%3Aissue%20label%3Ausage-stats) show GitHub release downloads, update fetches, and repository interest without adding analytics to the app.

## Features

- Live on-device English transcription with NVIDIA Parakeet Unified 0.6B through FluidAudio
- Append-only word emission with context-aware sentence boundaries after a pause
- Continuous pause rollover, including punctuation and speech in later sentences
- Live retraction of a period that a thinking pause invented, once the next words prove the sentence continued
- Per-app writing style: Formal, Casual, Very casual, or Excited tones for personal messengers, work messengers, email, and everything else
- Fast (320 ms) and Accurate (1.12 s) local recognition profiles
- Quick, Normal, and Essay profiles labeled by use case, with complete manual controls under Advanced
- One Auto cleanup control: None, Light (context-aware filler cleanup before insertion), or Medium (adds logic-driven end-of-dictation repair for repeated starts, editing terms, and false sentence boundaries)
- Spoken punctuation, paragraph, and common correspondence formatting commands
- Reliable standard clipboard pastes instead of lossy synthetic Unicode events
- Essay-only character delivery with adjustable WPM and Steady, Natural, or Expressive typing rhythms
- Optional global music pause for Apple Music and Spotify while Cadence listens
- Focus-bound delivery that refuses to paste after the user changes windows
- Personal dictionary spelling, capitalization, and diacritics for names and specialized vocabulary
- Local snippets that expand a spoken trigger before any trigger words reach the editor
- Optional one-second recognition-stability buffer with an immediate live preview
- Configurable global keyboard shortcut
- Edge-aware idle handle that expands on hover or while dictating
- Eight edge snap points, Command-drag free positioning, and adjustable sizing
- Adjustable floating-bar size from 65% to 135%
- Local transcript history and words-per-minute statistics
- Failed-insertion detection with a non-activating transcript recovery card
- Local bug-report export with settings, version, insertion status, and three recent transcripts
- Signed automatic updates through Sparkle and GitHub Releases
- Native SwiftUI and AppKit interface

## Requirements

- macOS 14 or later
- Microphone access
- Accessibility access for pasting into other applications

The optional Pause music setting asks for macOS Automation access only when it first needs to control a running Music or Spotify app.

The current release build is optimized for Apple Silicon. On first launch Cadence downloads both Fast and Accurate English encoders plus the voice-activity model (roughly 1.2 GB total); later transcription runs locally without sending microphone audio to a speech service. The files live in `~/Library/Application Support/FluidAudio/Models`, outside `Cadence.app`, so Sparkle updates reuse them instead of downloading them again. Cadence still has to load the selected encoder from disk into Core ML after each launch; Settings labels that separately from a real download. Core ML keeps its compiled form in `~/Library/Caches`, and a warm launch takes well under a second. macOS purges that cache when the disk is nearly full, which makes every launch recompile for 20-60 seconds; Settings warns when free space drops below about 20 GB. After both profiles have been loaded during one run, later Fast/Accurate switches keep using the warm managers.

## Build and run

Clone the repository, then run:

```sh
./scripts/build-app.sh
open dist/Cadence.app
```

Local app bundles receive a timestamp build number and a `-local.<commit>` display version. This keeps an already-published Edge build from replacing an installed smoke-test build before it can be verified. Edge and release workflows preserve their explicitly configured distribution versions.

The build uses Swift Package Manager and produces an application bundle at `dist/Cadence.app`. A full Xcode installation is not required; current Command Line Tools are sufficient.

To create and mount-test the same drag-to-Applications installer attached to downloads:

```sh
./scripts/build-dmg.sh
./scripts/verify-dmg.sh release/installers/Cadence.dmg
```

Official builds are signed with the project's `Cadence Signing` certificate so macOS privacy grants survive updates. Without that identity the script falls back to an ad-hoc signature, which works but makes macOS treat every rebuild as a new app: re-grant Accessibility after rebuilding. See [Releasing](docs/RELEASING.md) for details.

## First launch

Open the downloaded `Cadence.dmg`, then drag **Cadence** onto the **Applications** shortcut in its Finder window. Launch the installed copy from Applications. The ZIP attached to each release remains the signed Sparkle update archive; the DMG is the human-facing installer.

Open **Settings** in Cadence and grant the two required permissions:

1. Microphone
2. Accessibility

Cadence re-checks these every few seconds while Settings is open, so changes made in System Settings show up without restarting the app. If macOS lists Cadence as enabled but Cadence still reports a permission as needed, remove Cadence from that list in System Settings and grant it again: the entry belongs to a different copy of the app.

Place the cursor in an editor, hold the configured shortcut while you speak, and release it to finish. The default is **Control–Option–Space**; a function key or a modifier-only chord such as ⌃⌥ works too.

Say **“period”**, **“full stop”**, **“comma”**, **“question mark”**, **“new line”**, or **“new paragraph”** to format text instead of typing the command words. Cadence keeps command names literal when sentence grammar makes their meaning clear—for example, “a new line,” “the words new paragraph,” and “a question mark.” Cadence also writes an honorific such as “doctor Solarz” as “Dr. Solarz.” These follow the conventions used by macOS Dictation.

The floating bar can stop or cancel dictation without activating the main Cadence window. When idle, it collapses into a slim edge-aware handle and expands when hovered. Drag the expanded logo to snap it to one of eight screen-edge positions. Hold Command while dragging for free placement. Double-click the logo to open Cadence; a single click never opens the app.

## How dictation works

Cadence captures 16 kHz mono audio for as long as the shortcut is held. Silero voice-activity detection prevents leading silence from reaching the recognizer and identifies a sustained pause. Parakeet Unified streams partial hypotheses with 320 ms model latency in Fast or 1.12 s in Accurate. Cadence holds the unfinished last word—and its punctuation—until a following boundary or pause confirms it. Safe completed words are inserted immediately.

After about 750 ms of speech-ending silence, Cadence inserts the sentence tail and classifies the boundary. Explicit or model-supplied terminal punctuation closes immediately. A dependent clause such as “Because my Apple dictation…”, a subject still waiting for its predicate, such as “The whole point of the app…”, and a fragment ending in a preposition or a noun-subject copula (“things like…”, “the whole point is…”) keep the same decoder stream and language context when speech resumes. Other uncertain fragments get roughly 1.5 s more; if silence continues, Cadence closes them with a period and starts a fresh stream without ending the held shortcut. Releasing the shortcut finalizes any open thought.

That automatic period is provisional in one specific way. When the reset decoder restarts in lowercase, or the next segment begins with a word that cannot open a sentence (“which”, “than”, “until”, “especially”), the pause was mid-sentence: Cadence deletes the period with a single Delete keystroke, then continues with the lowercase word. The retraction is queued in the same serialized paste queue, and an accessible editor must show that period immediately before the caret or the document is left alone. A period you said out loud, a question mark, or a paragraph break is never retracted; after those, a lowercase restart is capitalized as a new sentence.

The Style section chooses a tone per app category. Cadence recognizes personal messengers, work messengers, and email apps from the frontmost app's bundle identifier, and web apps such as Gmail, Slack, or WhatsApp from the browser tab title; everything else is “Other”. Formal keeps the model's capitalization and punctuation. Casual drops the model's commas (spoken “comma” stays) and, in messengers, the closing period of the dictation. Very casual also lowercases sentence starts while preserving “I”, mixed-case words, and dictionary terms. Excited turns the closing period into an exclamation mark. If you release the shortcut after a pause already closed the last sentence, Casual and Excited retract that period through the same Delete path. Auto cleanup is a separate, single control under Settings > Recognition > Advanced: None, Light (filler-word cleanup before insertion), or Medium (adds Deeper editing after you release the shortcut). Quick, Normal, and Essay set it to None, Medium, and Light: Medium's end pass replaces the whole dictated span with one paste, which is invisible in a chat message but would undo the character-by-character typing history that Essay exists for. Changing the level makes the profile Custom like any other advanced setting.

Personal-dictionary matching occurs before text becomes visible. Cadence can therefore hold a possible multiword name briefly and safely restore exact case and diacritics—for example, `Jose Arcadio Buendia` to `José Arcadio Buendía`—without editing text after it was pasted. It deliberately does not fuzzily turn a different decoded word such as `lamp` into `Liam`; use Accurate for more acoustic context, and save a dictionary entry to preserve spelling once the model hears the right name. The Light cleanup level also runs at this pre-insertion stage. It removes unmistakable vocal pauses, while words such as “like,” “well,” and “you know” are removed only when punctuation marks them as detached asides. Semantic uses such as “I like this” remain untouched.

The Medium level adds Deeper editing, which runs only after the shortcut is released. It models a repair as abandoned words, an optional editing term, and a replacement. Repeated multiword anchors support safe removal of starts such as “I think we should—I mean—I think we can,” while the sentence-boundary classifier rejoins a noun phrase or modal complement that was clearly split during a thinking pause. Ambiguous corrections such as “Tuesday, I mean Wednesday” remain untouched because the lexical evidence cannot prove which span to replace. Before changing visible text, Cadence proves that the focused editor still contains exactly the document captured at dictation start plus this transcript, selects only that UTF-16 span through Accessibility, and replaces it through the editor's normal paste command. If the editor is opaque, focus moved, the cursor moved, or any surrounding text changed, Cadence leaves the original dictation untouched.

Snippets use that same append-only boundary. Cadence holds an incomplete or just-completed trigger in the preview, expands it locally, and inserts only the replacement after a following word or pause confirms the trigger. It never types the trigger and edits it afterward, and snippets do **not** require the one-second stability buffer. That optional buffer adds another second in which any unpasted partial prefix may change; pauses and shortcut release still flush immediately.

Each safe text delta is written to the current Mac's pasteboard and delivered with a complete physical Command-down, V-down, V-up, Command-up sequence. Paste operations are serialized, and every accessible cursor advance is acknowledged before later text can replace the pasteboard. Essay splits only this final delivery step into complete user-perceived characters; Quick and Normal paste complete chunks. Essay's 40–160 WPM control uses the standard five-character word convention. Steady, Natural, and Expressive rhythms add progressively wider local timing variation plus word- and punctuation-aware pauses; they never add mistakes.

When an editor exposes its insertion point, every chunk or character must advance the cursor before Cadence proceeds. A swallowed paste is retried twice; repeated failure stops the queue and surfaces the complete transcript instead of silently dropping text. Verification reads the editor through Accessibility the instant delivery finishes and again after completion; wrapped or respaced text still counts as delivered, and only an untouched editor, a focus change, or a posting failure shows the recovery card. Editors without accessible cursor progress use a conservative timeout and may run below the selected WPM.

The application and focused window captured at recording start are checked again immediately before the V key-down. If the target changed, Cadence leaves the transcript on the clipboard and shows a recovery card instead of risking a paste into the wrong window. See [Research and architecture](docs/RESEARCH.md) for the evidence and tradeoffs behind this design.

## Privacy and security

- Audio is processed locally by the downloaded Parakeet/Core ML model and is not saved by Cadence.
- Transcript history and personal dictionary entries are stored locally in the app's user defaults. Snippet bodies are stored as an atomic JSON file in Cadence's Application Support directory.
- Snippets are plain text and are not an encrypted password vault; do not use them for passwords or other secrets.
- Cadence does not include analytics, advertising, accounts, or cloud sync.
- Public adoption counters come from GitHub's release and repository APIs; Cadence does not report launches or active-install identities.
- Update archives and the update feed are verified with Ed25519 signatures before installation.
- The private update-signing key is not stored in this repository.

The speech model files are downloaded from the public model host during first-time setup and kept in the user's Application Support directory across app updates. Dictation is currently English-only.

Please report security issues through the repository's private security advisory feature. See [SECURITY.md](SECURITY.md).

## Architecture

| Component | Responsibility |
|---|---|
| `AudioCaptureEngine` | Captures and streams ordered 16 kHz mono microphone chunks |
| `LiveSpeechTranscriber` | Runs Silero VAD and streaming Parakeet Unified decoding with pause rollover |
| `LiveTranscriptEmitter` | Holds the unfinished word and emits only safe append-only text deltas, plus a single-period retraction when a pause split a sentence |
| `WritingStyle` | Detects the app category and applies the chosen tone's punctuation and capitalization rules |
| `DeepSpeechCleanupFormatter` | Applies bounded opt-in revisions after dictation finishes |
| `SnippetFormatter` | Replaces exact spoken triggers while keeping their live frontier provisional |
| `KeystrokeInjector` | Serializes focus-bound clipboard pastes to the target app |
| `FloatingPanelController` | Manages the cross-Space, dockable, draggable recording surface |
| `AppModel` | Coordinates sessions, permissions, preferences, and local history |
| `CadenceBugReport` | Encodes a privacy-labeled local support snapshot for explicit export |
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
./scripts/prepare-release.sh 0.3.0
```

Release artifacts are written to the ignored `release/` directory. The manual **Release Cadence** workflow promotes an explicitly tested Edge commit to an intentional, versioned release. Releases below `1.0.0` are labeled Public Beta; `1.0.0` and later are Stable. The **Publish Edge Build** workflow updates one rolling prerelease after every successful commit on `main`; users must explicitly select Edge in update settings. See [Releasing Cadence](docs/RELEASING.md).

## Contributing

Contributions are welcome. Keep audio capture, streaming recognition, transcript stabilization, and text insertion separate so recognition models can change without affecting editor behavior. Before opening a pull request, run `swift test` and verify that no credentials, local paths, generated builds, recordings, or transcript data are included.
