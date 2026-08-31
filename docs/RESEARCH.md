# Research and architecture

Research checked on August 30, 2026. The implementation is a native macOS app, not a browser wrapper.

## Product findings

Wispr Flow and Willow Voice share a useful product shape: global dictation, a personal dictionary, automatic punctuation/formatting, per-app writing styles, transcript history, a hotkey, and a small always-available recording surface. Flow's desktop UI calls this surface the **Flow Bar** and documents resting, recording, and processing states, click-through behavior, language/microphone menus, and a compact dark capsule. Flow currently requires an internet connection for transcription and describes its core advantage as cleaning filler words, corrections, punctuation, and structure before inserting polished text.

Willow similarly focuses on contextual writing style, voice commands, automatic formatting, a personal dictionary, shortcuts, and app-aware style matching. Its newer Scribe mode goes beyond verbatim transcription and generates what the user means to say.

Useful primary product references:

- [Wispr Flow overview](https://docs.wisprflow.ai/articles/2772472373-what-is-flow)
- [Wispr Flow desktop navigation](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android)
- [Wispr Flow Bar behavior](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop)
- [Willow Voice getting started](https://help.willowvoice.com/en/collections/12093043-getting-started)

Cadence borrows the interaction pattern—not Wispr's brand assets: a small dark capsule, warm off-white surfaces, an explicit cancel/finish pair, a live waveform, transcript history, dictionary, permissions, and a global shortcut. Its distinct lime mark and typography keep the product visually independent.

## The hard constraint: polished prose versus incremental history

A model cannot know that an early word is final while the user is still correcting the thought. For example, “Meet at five—actually six” requires changing already emitted content. Sending the whole polished result at the end solves correctness but creates the single-paste history the project is meant to avoid.

Cadence uses an append-only contract:

1. Capture 1,024-frame microphone buffers.
2. Ask the recognizer for partial results.
3. Compare each hypothesis with the preceding hypothesis.
4. Hold back the newest word because it is most likely to change.
5. Commit only the repeated stable prefix.
6. Emit the delta character by character as `CGEvent` Unicode key-down/key-up pairs.
7. Flush the remaining tail when the recognizer produces a final result or the user stops.

This is structurally different from repeatedly replacing a text field through the accessibility value API. Editors see incremental keyboard input, which is the closest system-wide equivalent to real typing. The Accessibility permission is necessary for event injection. Some secure fields intentionally reject synthetic input.

## Model decision

| Engine | Strengths | Weaknesses | Decision |
|---|---|---|---|
| Apple `SFSpeechRecognizer` | Native Swift, live partial results, contextual terms, on-device mode when supported, no bundled model | Older API; locale-specific on-device availability; partials can revise | **Shipped baseline for macOS 15** |
| Apple `SpeechAnalyzer` / `SpeechTranscriber` | New on-device model, volatile + finalized ranges, progressive live preset, OS-managed assets | Requires macOS 26, while the build machine is macOS 15.7 | **Best upgrade when minimum OS moves to 26** |
| NVIDIA Parakeet TDT 0.6B v3 | 600M parameters, 25 languages, punctuation, word timestamps, permissive CC BY 4.0, transducer architecture suited to streaming | Official deployment path centers on NeMo/Python/C++; no first-party native Swift/Core ML package | **Best open model candidate after native runtime validation** |
| Whisper large-v3 via WhisperKit | Mature native Swift/Core ML integration; local; multilingual; existing live stream transcriber | Whisper is windowed/iterative rather than a true streaming transducer; more tail revision and compute | **Best practical third-party native fallback** |

References:

- [Apple live audio recognition request](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest)
- [Apple partial and final result behavior](https://developer.apple.com/documentation/speech/sfspeechrecognitionresult)
- [Apple WWDC25 SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/)
- [NVIDIA Parakeet TDT 0.6B v3 model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [WhisperKit native Swift repository](https://github.com/argmaxinc/whisperkit)
- [Apple AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement_h)

### Recommendation for an M2 Max

For this machine today, Apple Speech is the lowest-latency, lowest-memory deployable engine because the OS owns model execution and partial-result delivery. Keep `requiresOnDeviceRecognition` enabled, capture in the input node's native format, use 1,024-frame buffers, and avoid an LLM in the commit path.

For a model-owned production version, benchmark Parakeet TDT v3 in a native C++/Core ML wrapper against WhisperKit `large-v3-v20240930_626MB`. The M2 Max has enough unified memory for either. Favor Core ML/Neural Engine for the encoder and avoid high beam counts, which raise latency without helping the append-only interaction. Select the winner using median partial latency, stable-word latency, WER on the user's actual lecture/drafting audio, memory, energy, and revision rate—not offline real-time factor alone.

When macOS 26 becomes the deployment floor, migrate the engine adapter to `SpeechAnalyzer` with `.volatileResults` and the `.progressiveLiveTranscription` preset. Apple explicitly designed its finalized/volatile split for this class of UI.

## Native architecture

```text
AVAudioEngine
     │  PCM buffers + audio level
     ▼
SpeechEngine protocol boundary
(AppleSpeechEngine today)
     │  revisable partial hypotheses
     ▼
TranscriptStabilizer
     │  append-only stable deltas
     ▼
KeystrokeInjector ─────► focused macOS editor
     │                    character-level CGEvents
     ├────► TextInsertionVerifier
     │        cursor/text evidence or recovery card
     ▼
Local transcript history / stats
```

The SwiftUI hub and AppKit floating panel observe one `AppModel`. The non-activating panel stays on every Space so stopping does not steal focus from the document. A menu-bar item and global Control–Option–Space shortcut provide recovery paths. Speech, model choice, stabilization, and injection remain separate so a new engine does not affect UI or editor compatibility.

Quartz does not return a delivery receipt for a posted keyboard event. Cadence therefore captures the target application's focused accessibility element and selection before dictation, waits until its character queue drains, and compares the target, focus, cursor, and accessible text afterward. A definite failure displays a non-activating recovery card and the transcript is already in local history. Editors that intentionally hide their text state are classified as unverifiable rather than generating a false warning. This uses Apple's documented [`AXUIElement`](https://developer.apple.com/documentation/applicationservices/axuielement_h) attributes; clipboard ownership is not treated as proof of insertion because [`NSPasteboard.changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount) only reports ownership changes.

The floating panel stores a normalized position rather than raw pixels, so a freely dragged bar remains on-screen after resolution changes. Preset docking supports every screen edge and scale is independent from placement. The global shortcut stores the hardware key code plus normalized modifiers, which keeps it reliable across keyboard layouts.

Updates use [Sparkle 2](https://sparkle-project.org/documentation/). The feed and archives are signed with a Cadence-specific Ed25519 key, GitHub Releases supplies the HTTPS assets, and Sparkle handles scheduled checks, delta-aware downloads, atomic bundle replacement, and relaunching. The private key remains in the developer Keychain or an encrypted GitHub Actions secret.

## Deliberate first-build boundaries

- English (`en-US`) first; the engine boundary is ready for a language picker.
- No cloud LLM cleanup, accounts, sync, meetings, or audio retention.
- The dictionary supplies recognition context but does not yet learn automatically.
- Global shortcut monitoring depends on Accessibility, already required for typing.
- A future correction mode can issue bounded backspaces inside the one-word tail, but the default will remain append-only to protect revision history.
