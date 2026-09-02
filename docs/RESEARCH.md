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
- never rewrite text during live emission; an opt-in final cleanup may replace only the exactly verified span inserted by this session;
- after a sentence pause, flush the held last word and punctuation;
- continue the same held session with the next sentence;
- keep accepting audio for long sessions without task expiry or callback reordering.

The new pipeline uses [FluidAudio's pinned Parakeet Unified streaming manager](https://github.com/FluidInference/FluidAudio/blob/4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b/Sources/FluidAudio/ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift). Unlike the former Apple partial-result path, this manager builds its transcript by appending decoded RNNT emissions to a cache and is designed to run for hours. Cadence exposes two exports of the same English 0.6B checkpoint: Fast `[70,2,2]` uses 160 ms of new audio plus 160 ms of right context (320 ms theoretical latency); Accurate `[70,7,7]` uses 560 ms plus 560 ms (1.12 s latency).

Those context windows are baked into [separate encoder bundles](https://github.com/FluidInference/FluidAudio/blob/4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b/Sources/FluidAudio/ModelNames.swift#L690-L716), not a cheap runtime parameter. Cadence previously discarded the active Core ML manager whenever the setting changed, so returning to a profile could spend roughly 24 seconds loading a 565 MB encoder that had already been prepared. The transcriber now retains one warm manager per profile, shares the VAD instance, and changes only the active reference. A first-time download/Core ML preparation is still real work; every later switch is covered by a production test with a 250 ms ceiling.

The pinned [Unified benchmark](https://github.com/FluidInference/FluidAudio/blob/4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b/Sources/FluidAudio/ASR/Parakeet/Unified/benchmark.md) reports 2.37% aggregate WER for Fast and 2.25% for Accurate on the same 150-file LibriSpeech comparison. The difference is modest; Accurate is a larger-context profile, not a different or magically stronger language model. These corpus figures guide a latency tradeoff and are not a promise for microphones, accents, names, or essay prose.

NVIDIA's broader [model-card benchmark](https://huggingface.co/nvidia/parakeet-unified-en-0.6b#asr-performance-wo-pnc) reports an average leaderboard WER of 6.92 at 0.32 seconds, 6.29 at 1.12 seconds, and 6.14 at 2.08 seconds. The extra context after 1.12 seconds buys only a small aggregate improvement while doubling latency, so Cadence exposes Fast and Accurate rather than presenting an even slower tier as a stronger model. A model picker is an accuracy/latency control, not a guarantee for rare names.

The pinned FluidAudio manager can load an additional CTC model for vocabulary boosting, but its own streaming implementation [rescans word-aligned segments of roughly 15 seconds and surfaces corrections retroactively](https://github.com/FluidInference/FluidAudio/blob/4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b/Sources/FluidAudio/ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift#L67-L88). FluidAudio also documents reduced streaming accuracy, limited multiword support, and no cross-chunk detection in its [custom-vocabulary guide](https://github.com/FluidInference/FluidAudio/blob/4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b/Documentation/ASR/CustomVocabulary.md#streaming-mode-limitations). Enabling that path would violate Cadence's append-only contract after words were already pasted. Cadence therefore keeps exact dictionary correction before insertion and does not claim acoustic vocabulary boosting yet.

### Stable word emission

[Google's primary study of streaming ASR stability](https://research.google/pubs/analyzing-the-quality-and-stability-of-a-streaming-end-to-end-on-device-speech-recognizer/) confirms that partial results can be revised before finalization. A streaming hypothesis can also expose an unfinished subword—for example, `dict` before `dictation`. `LiveTranscriptEmitter` therefore holds the final whitespace-delimited word and any attached punctuation. When the next word boundary appears, the completed word becomes an insertion delta. A sentence pause finalizes the held tail. The floating bar remains free to show the provisional text, so the preview can be slightly ahead of the editor without risking a broken fragment in the document.

The optional one-second stability buffer is implemented at this stability boundary, not as a timer in front of Command-V. Each safe prefix records when it first appeared. It becomes immutable only after the exact prefix has survived for one additional second; a contradicted, still-unpasted checkpoint is discarded. Each word keeps its own first-seen time, so the stream continues moving instead of batching an entire sentence. A VAD pause or shortcut release still flushes the current tail immediately, preventing the old missing-final-words failure from returning. Character playback is a separate downstream choice: turning it off never disables the recognition buffer, and turning it on paces any newly committed prefix one complete grapheme at a time.

Committed words are inserted without trailing whitespace; the next committed word supplies its own leading separator. This makes it possible to append a period correctly even if a later hypothesis withdraws the provisional word that had followed the visible text. A revision is an error only when the new hypothesis no longer preserves the exact character prefix already inserted into the document.

Apple's [macOS dictation command reference](https://support.apple.com/guide/mac-help/mh40695/mac) treats spoken punctuation names and layout phrases as commands. Cadence applies `period`, `full stop`, `comma`, `colon`, `semicolon`, `question mark`, `exclamation mark`, `new line`, and `new paragraph` to each streaming hypothesis before stabilization. A partial multiword command stays provisional, and explicit punctuation replaces an adjacent model-supplied mark rather than producing `. .` or `,,`. Paragraph breaks remain atomic across a decoder pause. Only the formatted symbol or line break is ever committed to the editor.

The personal dictionary runs at the same pre-insertion stage. Case- and diacritic-insensitive exact matches restore the saved spelling. A possible multiword dictionary prefix remains provisional until it completes or stops matching, so `Jose Arcadio Buendia` can safely become `José Arcadio Buendía` without revising visible text. Fuzzy substitution is deliberately excluded: acoustic errors such as `lamp` for `Liam` do not provide enough evidence to overwrite an ordinary word.

The optional live cleanup distinguishes nonlexical vocal pauses from real discourse words. Standalone `um`, `uh`, `erm`, `er`, and `hmm` can be removed directly. `like`, `well`, and `you know` are removed only when punctuation makes them a detached parenthetical; `I like this`, `well designed`, and `do you know Liam?` are preserved. This context rule matters because broader revision would need to retract text that may already be visible.

### Structured end-of-dictation repairs

The classic speech-repair structure is a reparandum (abandoned words), an optional interregnum/editing term, and a repair. The primary [Bear, Dowding, and Shriberg repair algorithm](https://arxiv.org/abs/cmp-lg/9406006) builds repair patterns from word matches, replacements, fragments, and editing terms rather than a fixed phrase template. Cadence adopts a conservative lexical subset: it finds two-or-more-word anchors repeated across optional `like`, `you know`, or `I mean` material, and it recognizes an editing-term restart only when the repair begins with an earlier multiword anchor. Single-word duplication such as `very very` and an ambiguous correction such as `Tuesday, I mean Wednesday` are preserved.

After those repair spans are removed, the local grammar classifier revisits automatic periods. A subject with no predicate, a dependent clause, or a short modal clause followed by a WH complement can be rejoined. Explicit paragraph breaks and questions are never crossed. This pass runs only after shortcut release and still depends on the verified editor replacement boundary described below; the structural evidence improves cleanup without turning it into a general language-model rewrite.

### Snippet triggers without editor rewrites

Wispr describes snippets as voice shortcuts where speaking a cue pastes the [full saved text](https://wisprflow.ai/post/snippets), and its feature page promises that the cue produces the [full formatted text at the cursor](https://try.wisprflow.ai/). Cadence implements the safe part of that contract locally: exact, case- and diacritic-insensitive whole-phrase matching, with no fuzzy trigger guessing and no recursive expansion of replacement text.

An incomplete trigger and a complete trigger at the live frontier both remain provisional. A following word confirms the phrase during continuous speech; a real pause confirms a standalone trigger. Only the expansion crosses the insertion boundary, so the editor never receives ordinary trigger words that would later need deletion. The optional stability buffer adds another second in which a falsely recognized trigger can disappear before its expansion is committed.

Cadence rejects duplicate triggers, triggers where one complete phrase is the prefix of another, and triggers containing reserved spoken-punctuation commands. Those ambiguous configurations cannot be resolved safely without revising visible text. A bare standalone snippet remains byte-for-byte equivalent to its saved plain text; automatic sentence finalization does not invent a period, while explicitly saying `period` or `question mark` still appends that symbol.

Version one intentionally stores and inserts plain text. AppKit supports RTF and plain representations on one pasteboard item, but preserving rich runs through mixed streaming deltas requires provenance that the current string-only emitter does not have. Pretending otherwise would create target-dependent formatting. Snippets are stored atomically under `~/Library/Application Support/Cadence` with owner-only file permissions and are snapshotted when dictation starts. They are local but not an encrypted secrets vault.

### Pause finalization and continuous rollover

[FluidAudio's Silero streaming VAD](https://github.com/FluidInference/FluidAudio/blob/4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b/Sources/FluidAudio/VAD/VadManager%2BStreaming.swift) uses hysteresis and a default 750 ms minimum silence duration. Cadence uses its speech-start signal to keep leading background silence out of ASR while retaining a short pre-roll so the first phoneme is not clipped.

The 750 ms VAD event means “speech paused,” not “the thought is grammatically complete.” Treating those concepts as identical produced `Because my Apple dictation. Was messing…`. A minimal model experiment fed those phrases through one uninterrupted Unified stream with 1.5 seconds of silence; it returned `Because my Apple dictation was messing…`, preserving the intended context and capitalization. A second production regression reproduced `The whole point of the app. Is that…` with Accurate recognition and a three-second thinking pause. The model's live partial contained no period; Cadence's uncertain-boundary fallback invented it. The classifier now uses Apple's local lexical tagging to keep a multiword phrase with no verb open for its predicate, and recognizes a trailing complement such as `is that` without misclassifying the complete phrase `I like that`.

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
| Pasteboard plus physical Command-V | Selected. [`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard) is the transfer mechanism editors already support, while Command-V invokes each editor's native insertion path. The same route can safely deliver either a committed text delta or one complete grapheme at a time. |

A current open-source macOS dictation implementation, [Presspeech](https://github.com/rcourtman/presspeech), independently uses the same basic route: write text to the general pasteboard and post explicit Command-down, V-down, V-up, and Command-up events.

Cadence now sends insertion units through a single serialized queue. Normal delivery keeps each committed delta intact. Optional character playback expands the same delta into Swift `Character` values, preserving composed accents and emoji as complete graphemes. Its WPM control follows the five-character word convention, with a 40–160 WPM range. Optional variation is a bounded uniform ±15% interval adjustment whose midpoint remains the selected average.

The original 35 ms implementation reproduced a real Safari failure end to end: Cadence's saved transcript contained `definitely` and `The`, while the focused web editor visibly received `definitel` and `Te`. A trusted-process Safari stress experiment then delivered only 750 of 1,140 expected characters when it replaced the pasteboard and posted consecutive Command-V sequences at that cadence. The queue now treats accessible cursor advancement as an acknowledgment, retries an unchanged character up to twice, and stops with full-transcript recovery rather than silently skipping after repeated failure. An opaque editor uses at least the conservative 120 ms timeout and may therefore run below the selected WPM. The target process and opaque focused AX window captured at session start are checked before every paste and again immediately before V-down. If focus changes, Cadence fails closed and drops the remaining queue rather than redirecting private dictation into a different window.

Every injected pasteboard item is marked [`currentHostOnly`](https://developer.apple.com/documentation/appkit/nspasteboard/contentsoptions/currenthostonly), so a paced sequence does not send each private character through Universal Clipboard. Cadence records no typing samples or biometric profile, and never adds fake mistakes or correction behavior. Timing variation is generated locally per character within a fixed bound; it is a presentation control, not identity imitation.

Deeper editing introduces one deliberately bounded editor-revision path. It computes the structurally repaired transcript locally, then requires the current document value and cursor to equal the start snapshot with the raw dictation inserted. Apple defines [`kAXSelectedTextRangeAttribute`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute) as the character range for editable text, and [`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) reports unsupported or invalid elements instead of guaranteeing mutation. Cadence therefore selects only the proven dictation span, replaces it with the editor's standard Command-V action, verifies the resulting value and cursor, and otherwise leaves the raw transcript in place. It never writes the editor's whole `kAXValueAttribute`.

Every event in that Command-V sequence is source-tagged. This prevents the shortcut monitor from confusing Cadence's synthetic Command-down/up with release of a physically held modifier-only shortcut, without suppressing any real keyboard event.

After the queue drains, Cadence checks accessible text or cursor movement when the editor exposes it. Quartz has no delivery receipt, so opaque editors remain “unverifiable” rather than being reported as successful. A definite unchanged editor or posting failure produces the recovery card.

## Update discovery and prompting

Sparkle's updater normally uses the last-check time and configured interval. Its [`checkForUpdatesInBackground`](https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html#/c:objc(cs)SPUUpdater(im)checkForUpdatesInBackground) contract explicitly recommends an immediate post-start call when an app wants a check on every launch, and also notes that background automatic installation or gentle reminders may delay visible UI. Cadence needs a stronger visible result: when automatic checks are enabled, launch performs Sparkle's silent information probe. A valid update queues the standard user-facing cycle until Sparkle reports that it can check again and its previous session has ended; a current build opens no “up to date” window. Waiting for a run-loop turn alone is insufficient because some Sparkle runtimes invoke the completion delegate while `sessionInProgress` is still true, which causes an immediate foreground check to be silently ignored. Scheduled six-hour checks remain enabled, and manual Check Now continues to use Sparkle's foreground API.

Sparkle documents that `SUAutomaticallyUpdate=YES` attempts silent download and installation. Cadence now defaults that preference to off so a new installation begins with visible approval, while continuing to respect an existing user's explicit automatic-install setting. Feed signatures, archive signatures, installation, and relaunch remain Sparkle-owned.

## Download and installation packaging

Apple recommends a disk image for directly distributing a single app bundle and says to sign the app before creating and, when possible, signing the outer container in its [macOS packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution). Sparkle specifically recommends an [`/Applications` symlink inside the website DMG](https://sparkle-project.org/documentation/#distributing-your-app) so people copy the app out of the read-only image.

Cadence's installer script copies the already-signed app into an isolated staging directory, adds that exact symlink, creates a compressed read-only UDZO image, then mount-tests the app signature, bundle property list, and symlink target. It signs the DMG only when a Developer ID Application identity is available: Apple's code-signing guidance says that is the supported identity for disk images. The current self-signed `Cadence Signing` identity preserves local privacy grants but does not satisfy Gatekeeper or replace notarization, so it is not misrepresented as a distribution signature.

The human download is the DMG. Sparkle remains ZIP-backed because its appcast already authenticates that symlink-preserving update archive with Ed25519, and building the DMG only after appcast generation prevents two same-version containers from being selected accidentally.

## Product comparison with Wispr Flow

Wispr Flow's advantage is not only raw ASR. Its [context-awareness documentation](https://docs.wisprflow.ai/articles/4678293671-Context-Awareness) says it uses the active application and limited text near the cursor to adapt vocabulary, style, and formatting. Its [privacy/cloud documentation](https://docs.wisprflow.ai/articles/4709791908-understanding-privacy-mode-and-cloud-sync) describes cloud processing and personalized models.

Cadence now has a low-latency local streaming baseline, but it does not claim parity with that cloud/context pipeline. It deliberately does not read the surrounding essay, upload microphone audio, or run an LLM rewrite. Its local boundary classifier considers the recognized fragment and pause duration. Pre-insertion cleanup uses vocal-pause and detached-aside structure; the separate opt-in end pass uses repeated anchors, editing terms, and conservative grammar signals. The personal dictionary restores exact case and diacritics only for the same decoded letters; fuzzy substitution is avoided because it can invent words without acoustic evidence.

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
      ├── format: cleanup → spoken commands → dictionary → written style → snippets
      ├── preview: complete formatted partial, including frontier word
      ├── pause classifier: complete / continuation / uncertain
      └── insertion: stable completed-word deltas and pause tail only
               └── optional one-second prefix checkpoint
               │
               ▼
KeystrokeInjector (one serialized paste queue)
      ├── choose committed delta or complete-grapheme units
      ├── verify captured process + window
      ├── write one current-host-only NSPasteboard unit
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

The paste path is separately exercised against a real AppKit editor using the signed installed application, because pasteboard state, queue contents, and event construction alone do not prove visible insertion. Character playback additionally verifies ordered visible insertion of ASCII, composed Unicode, emoji, whitespace, and punctuation.

The modifier-only regression recreates an Option-held session, passes the complete tagged Command-V sequence through the same AppKit event handler, and verifies that only an untagged Option-up releases the shortcut. Installed-app verification then holds Option across two spoken sentences and a pause, requiring timestamped visible editor updates during both sentences before releasing Option.

The provisional-tail regression reproduces the observed `…like 0.` → `…like` hypothesis change. It requires the preview to revise without an exception, requires already-inserted text to remain untouched, and verifies that a later `0.2` finalization reconstructs the intended sentence exactly.

Snippet regressions cover exact whole-phrase matching, case and diacritics, incomplete and trailing triggers, punctuation, multi-line replacements, nonrecursive expansion, invalid trigger overlap, private-file permissions, and a false trigger revised during the optional stability second. The DMG verifier mounts the actual compressed image read-only and inspects what Finder exposes rather than assuming the staging directory survived image creation.

## Deliberate boundaries

- English first; the Unified checkpoint is English-only.
- A one-time ASR/VAD model download and compilation is required before dictation becomes ready.
- Words appear after a following boundary confirms they are complete, so preview text can lead editor text by roughly one word.
- Tail words flush after approximately 750 ms of silence. Terminal punctuation can take up to roughly another 512 ms for an uncertain boundary; a clear dependent clause remains open for the next phrase or shortcut release.
- Live filler cleanup is conservative. Deeper editing can revise only an exactly verified dictation span and still does not interpret free-form commands such as “forget that.”
- Snippets are exact plain-text macros. Rich formatting needs attributed-run provenance and multiple pasteboard representations before it can be promised consistently across editors.
- Character playback and timing variation are opt-in. Cadence deliberately does not learn or imitate a person's keystroke biometrics, inject fake mistakes, or promise that every editor will group per-character paste operations into the same undo history as physical typing.
- No cloud LLM rewrite, accounts, sync, document-context reading, or audio retention.
- The transcript remains on the clipboard after insertion, favoring recoverability over transparent clipboard restoration.
- Secure fields and applications that reject synthetic shortcuts may still refuse insertion; Cadence preserves the transcript and reports definite failures.
