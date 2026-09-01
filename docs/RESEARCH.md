# Research and architecture

Research rechecked on September 1, 2026. Cadence supports macOS 14 and later. The recognition pipeline, final AppKit delivery call, and installed application artifact are evaluated separately because correct intermediate state does not prove that an editor displayed the text.

## What the repeated failure revealed

The original live path had three independent failure modes:

1. It treated revisable `SFSpeechRecognizer` partial results as an append-only stream. Apple's [`isFinal`](https://developer.apple.com/documentation/speech/sfspeechrecognitionresult/isfinal) contract distinguishes a final result from interim results; it does not promise that interim text will retain a common prefix. When a later hypothesis changed an earlier word, Cadence's already-inserted prefix and the recognizer's preview diverged. The preview could therefore show a correct tail that the insertion stabilizer would never accept.
2. A recognition task could finish around silence while the shortcut remained held. The UI continued to look active, but later audio was no longer connected to a productive decoder.
3. It attached one Unicode scalar at a time to synthetic `CGEvent` key events. Apple's [`keyboardSetUnicodeString`](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring%28stringlength%3Aunicodestring%3A%29) documentation warns that an application framework may ignore that string and interpret the virtual key code and event state instead. Reaching `CGEvent.post` did not prove that the editor inserted the text.

The physical Command-V replacement exposed a fourth integration failure for modifier-only hold shortcuts. Cadence's own synthetic Command flags could reach its global modifier monitor; an Option-only session then looked as though Option had been released, so the first live paste stopped dictation. Each generated paste event now carries a private [`eventSourceUserData`](https://developer.apple.com/documentation/coregraphics/cgeventfield/eventsourceuserdata) marker. The monitor ignores only events with that marker and continues to process real modifier releases normally.

Streaming output can also withdraw its newest preview token. One observed sequence changed `Version this as like a like 0.` to `Version this as like a like`. The `0.` tail was still provisional, but the old emitter committed terminal punctuation immediately and then treated the withdrawal as corruption. Cadence stopped and activated its main window to expose the error. The emitter now permits any revision after the exact character prefix already inserted, and runtime errors remain in the nonactivating floating control instead of stealing focus.

The installed `/Applications/Cadence.app` was also not the previous workspace fix. Sparkle had replaced the larger local artifact with the published Edge build and relaunched it. Local builds now receive a newer timestamp build number and a visible `-local.<commit>` suffix, preventing an older published Edge artifact from silently replacing the build under test.

## Recognition research

### The required contract

Live essay dictation needs a narrower guarantee than “every partial is final”:

- show the current hypothesis in the floating preview;
- insert completed words continuously;
- never rewrite text already inserted into another application;
- after a sentence pause, flush the held last word and punctuation;
- continue the same held session with the next sentence;
- keep accepting audio for long sessions without task expiry or callback reordering.

The new pipeline uses [FluidAudio's pinned Parakeet Unified streaming manager](https://github.com/FluidInference/FluidAudio/blob/4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b/Sources/FluidAudio/ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift). Unlike the former Apple partial-result path, this manager builds its transcript by appending decoded RNNT emissions to a cache and is designed to run for hours. Cadence exposes two exports of the same English 0.6B checkpoint: Fast `[70,2,2]` uses 160 ms of new audio plus 160 ms of right context (320 ms theoretical latency); Accurate `[70,7,7]` uses 560 ms plus 560 ms (1.12 s latency).

The pinned [Unified benchmark](https://github.com/FluidInference/FluidAudio/blob/4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b/Sources/FluidAudio/ASR/Parakeet/Unified/benchmark.md) reports 2.37% aggregate WER for Fast and 2.25% for Accurate on the same 150-file LibriSpeech comparison. The difference is modest; Accurate is a larger-context profile, not a different or magically stronger language model. These corpus figures guide a latency tradeoff and are not a promise for microphones, accents, names, or essay prose.

### Stable word emission

Streaming hypotheses can expose or revise an unfinished subword—for example, `dict` before `dictation`. `LiveTranscriptEmitter` therefore holds the final whitespace-delimited word and any attached punctuation. When the next word boundary appears, the completed word becomes an insertion delta. A sentence pause finalizes the held tail. The floating bar remains free to show the provisional text, so the preview can be slightly ahead of the editor without risking a broken fragment in the document.

Committed words are inserted without trailing whitespace; the next committed word supplies its own leading separator. This makes it possible to append a period correctly even if a later hypothesis withdraws the provisional word that had followed the visible text. A revision is an error only when the new hypothesis no longer preserves the exact character prefix already inserted into the document.

Apple's [macOS dictation command reference](https://support.apple.com/guide/mac-help/mh40695/mac) treats spoken punctuation names as commands. Cadence applies `period`, `full stop`, and `question mark` to each streaming hypothesis before stabilization. Therefore the command can change while it is still preview-only, and only the resulting symbol is ever committed to the editor.

The personal dictionary runs at the same pre-insertion stage. Case- and diacritic-insensitive exact matches restore the saved spelling. A possible multiword dictionary prefix remains provisional until it completes or stops matching, so `Jose Arcadio Buendia` can safely become `José Arcadio Buendía` without revising visible text. The optional cleanup toggle removes only standalone hesitation sounds such as `um`, `uh`, `erm`, and `er`; arbitrary prose rewriting is deliberately excluded from this append-only path.

### Pause finalization and continuous rollover

[FluidAudio's Silero streaming VAD](https://github.com/FluidInference/FluidAudio/blob/4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b/Sources/FluidAudio/VAD/VadManager%2BStreaming.swift) uses hysteresis and a default 750 ms minimum silence duration. Cadence uses its speech-start signal to keep leading background silence out of ASR while retaining a short pre-roll so the first phoneme is not clipped.

The 750 ms VAD event means “speech paused,” not “the thought is grammatically complete.” Treating those concepts as identical produced `Because my Apple dictation. Was messing…`. A minimal model experiment fed those phrases through one uninterrupted Unified stream with 1.5 seconds of silence; it returned `Because my Apple dictation was messing…`, preserving the intended context and capitalization.

On speech end, Cadence now:

1. feeds the trailing silence through Parakeet's right-context window;
2. inserts the held tail immediately without forcing punctuation;
3. classifies the formatted fragment as complete, continuing, or uncertain;
4. closes immediately when the live model or a spoken command supplied terminal punctuation;
5. preserves the same decoder stream for a clear dependent clause;
6. gives an uncertain fragment two more VAD blocks (about 512 ms) in which speech can resume before finalizing it as a sentence;
7. resets decoder state only after a real sentence boundary, keeping the Core ML models loaded and the held shortcut active.

Releasing the shortcut flushes the active final segment in the same way. Audio tap buffers enter one ordered `AsyncStream`; a single actor consumes them, so independent tasks cannot reorder buffers or race the Core ML decoder.

### Model decision for the supported OS range

| Engine | Evidence | Decision |
|---|---|---|
| Apple `SFSpeechRecognizer` partials | Convenient live API, but its partial hypotheses are revisable and the observed task lifecycle stranded text after pauses. | Removed from the dictation path. |
| Apple `SpeechAnalyzer` / `SpeechTranscriber` | Apple's [WWDC25 session](https://developer.apple.com/videos/play/wwdc2025/277/) describes newer live transcription with volatile and finalized ranges. | Future benchmark; it requires macOS 26, above Cadence's current deployment floor. |
| Parakeet Unified 0.6B | Native streaming, punctuation/capitalization, a 320 ms low-latency tier, and a slightly more accurate 1.12 s context tier through FluidAudio/Core ML. | Selected with a Fast/Accurate profile control. |
| Nemotron Speech Streaming 0.6B | A credible local alternative, but the pinned evidence did not establish a reliable advantage over Unified for Cadence's punctuation-heavy append-only English path. | Revisit with an app-specific corpus rather than adding a misleading “stronger model” label. |
| Parakeet TDT whole-utterance inference | Accurate locally, but produces nothing while the user is speaking. | Rejected because live insertion is a core product requirement. |
| Whisper through a native Core ML runtime | Mature multilingual alternative, but no advantage was established for the current English-first, low-latency path. | Keep as a future multilingual benchmark. |

## Text insertion research

| Route | Result |
|---|---|
| Per-character Unicode `CGEvent` | Rejected. Application frameworks may ignore the payload, and a long event queue creates more tail-loss opportunities. |
| Replace `kAXValueAttribute` | Rejected as a universal route. It is not writable for every control and can damage selection, rich text, or editor undo semantics. |
| Pasteboard plus physical Command-V | Selected. [`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard) is the transfer mechanism editors already support, while Command-V invokes each editor's native insertion path. |

A current open-source macOS dictation implementation, [Presspeech](https://github.com/rcourtman/presspeech), independently uses the same basic route: write text to the general pasteboard and post explicit Command-down, V-down, V-up, and Command-up events.

Cadence now sends each completed-word delta through a single serialized queue. It waits 120 ms after each physical paste sequence so a later pasteboard write cannot replace the word before the target consumes the earlier Command-V. The target process and opaque focused AX window captured at session start are checked before every paste and again immediately before V-down. If focus changes, Cadence fails closed, leaves recoverable text on the clipboard, and never redirects private dictation into a different window.

Every event in that Command-V sequence is source-tagged. This prevents the shortcut monitor from confusing Cadence's synthetic Command-down/up with release of a physically held modifier-only shortcut, without suppressing any real keyboard event.

After the queue drains, Cadence checks accessible text or cursor movement when the editor exposes it. Quartz has no delivery receipt, so opaque editors remain “unverifiable” rather than being reported as successful. A definite unchanged editor or posting failure produces the recovery card.

## Product comparison with Wispr Flow

Wispr Flow's advantage is not only raw ASR. Its [context-awareness documentation](https://docs.wisprflow.ai/articles/4678293671-Context-Awareness) says it uses the active application and limited text near the cursor to adapt vocabulary, style, and formatting. Its [privacy/cloud documentation](https://docs.wisprflow.ai/articles/4709791908-understanding-privacy-mode-and-cloud-sync) describes cloud processing and personalized models.

Cadence now has a low-latency local streaming baseline, but it does not claim parity with that cloud/context pipeline. It deliberately does not read the surrounding essay, upload microphone audio, or run an LLM rewrite. Its local boundary classifier considers the recognized fragment and pause duration, and its optional cleanup removes filler sounds before insertion. The personal dictionary restores exact case and diacritics only for the same decoded letters; fuzzy substitution is avoided because it can invent words without acoustic evidence.

## Native architecture

```text
AVAudioEngine tap
      │ ordered native audio buffers
      ▼
AudioCaptureEngine ── resample to 16 kHz mono ── AsyncStream
      │
      ▼
Silero VAD ── speech start / 750 ms speech-pause signal
      │
      ▼
Parakeet Unified streaming decoder
      │ streaming partial hypothesis
      ▼
LiveTranscriptEmitter
      ├── preview: complete partial, including frontier word
      ├── pause classifier: complete / continuation / uncertain
      └── insertion: completed-word deltas and pause tail only
               │
               ▼
KeystrokeInjector (one serialized paste queue)
      ├── verify captured process + window
      ├── write one NSPasteboard delta
      ├── verify focus immediately before V-down
      └── post Command↓ V↓ V↑ Command↑
               │
               ▼
       focused macOS editor
               │
               ▼
TextInsertionVerifier ── definite failure → recovery card
```

## Verification

The opt-in production regressions synthesize speech and drive the real ASR/VAD pipeline in microphone-sized chunks. One supplies a complete sentence plus two seconds of silence, requires its last word and period before later audio enters, repeats rollover five times, and requires every append-only delta to reconstruct the final transcript. A second reproduces `Because my Apple dictation` plus a 1.5-second pause followed by `was messing that up for my summer reading`; it requires the first tail to become visible without sentence punctuation and the final result to remain one continuous sentence.

A separate regression reuses one `AVAudioConverter` over sixty consecutive tap buffers. Its input provider returns `.noDataNow` after supplying each buffer; returning `.endOfStream` would terminally close that reusable converter and recreate the observed “works at first, then stops” failure.

The paste path is separately exercised against a real AppKit editor using the signed installed application, because pasteboard state and event construction alone do not prove visible insertion.

The modifier-only regression recreates an Option-held session, passes the complete tagged Command-V sequence through the same AppKit event handler, and verifies that only an untagged Option-up releases the shortcut. Installed-app verification then holds Option across two spoken sentences and a pause, requiring timestamped visible editor updates during both sentences before releasing Option.

The provisional-tail regression reproduces the observed `…like 0.` → `…like` hypothesis change. It requires the preview to revise without an exception, requires already-inserted text to remain untouched, and verifies that a later `0.2` finalization reconstructs the intended sentence exactly.

## Deliberate boundaries

- English first; the Unified checkpoint is English-only.
- A one-time ASR/VAD model download and compilation is required before dictation becomes ready.
- Words appear after a following boundary confirms they are complete, so preview text can lead editor text by roughly one word.
- Tail words flush after approximately 750 ms of silence. Terminal punctuation can take up to roughly another 512 ms for an uncertain boundary; a clear dependent clause remains open for the next phrase or shortcut release.
- Filler cleanup is conservative. Cadence cannot safely interpret free-form corrections such as “forget that” after the referenced words have already been inserted without introducing an editor-revision path.
- No cloud LLM rewrite, accounts, sync, document-context reading, or audio retention.
- The transcript remains on the clipboard after insertion, favoring recoverability over transparent clipboard restoration.
- Secure fields and applications that reject synthetic shortcuts may still refuse insertion; Cadence preserves the transcript and reports definite failures.
