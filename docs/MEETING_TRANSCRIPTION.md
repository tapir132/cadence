# Meeting transcription: channel identity and verification

## Failure and design

The old meeting path summed microphone and system audio, decoded that mixture,
and labeled every word delta using the current smoothed input energy. The
Accurate decoder has 1,120 ms of model latency, before processing and scheduling
delays. A later microphone sound could therefore label earlier remote words as
**You**, splitting one sentence across speakers. A regression reproduced this
in the exported Markdown before the mixer was removed.

The two inputs now retain their identities through independent VAD and ASR
instances. Microphone output is **You**; system output is **Them**. Input buffers
carry monotonic capture timestamps from AVAudioEngine and Core Audio. Each
detected utterance receives a stable ID and capture time, so delayed hypotheses
update the original line, and overlapping turns sort by when speech was captured.
Each stream drains its final partial VAD block when recording stops. A missing
system stream neither delays microphone words nor creates a remote speaker.

Notes use complete, revisable utterance hypotheses rather than dictation's
append-only text emitter. Decoder corrections replace that utterance instead of
restarting recognition after a visible-text revision. Conversation words such
as “new line” and “period” are not treated as dictation commands.

Speaker playback also reaches a laptop microphone acoustically. Independent
recognizers alone therefore produce duplicate You/Them lines. The microphone
now passes through SpeexDSP's adaptive echo canceller using the system tap as
its playback reference before VAD, either recognizer, or the local level meter.
The system transcript remains unchanged. This is signal processing, not deletion
of matching words: the local speaker may intentionally repeat a remote phrase.

The 16 kHz mono canceller processes 256-sample frames with a 200 ms adaptive
tail. Capture timestamps align the streams; 32 ms of reference look-ahead
allows for different converter delays. Each microphone chunk may wait at most
200 ms for missing reference, then passes through. Playback history is bounded
to two seconds. Capture discontinuities reset adaptation, and stopping drains
the final partial frame. Processing runs off capture callbacks and neither
changes the output device nor ducks other apps. No additional model or audio
file is needed. Clock alignment, adaptation during real speech, and nonlinear
speaker distortion still require checks on actual devices.

A separate Bluetooth capture failure was reproduced with the unchanged audio
engine: `start()` succeeded, a configuration change stopped the engine, and no
microphone buffers arrived. Restarting the engine restored delivery in the
minimal experiment. Capture now observes configuration changes and rebuilds
the tap/converter for the current input format while keeping the recording
stream open. Start, stop, and recovery run on one serial control queue; a late
notification after an intentional stop must not reopen the microphone.

## Research

- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
  describes taps as capture of outgoing process audio. That source is already
  distinct from microphone input; mixing it discards useful source information.
- [Deepgram: Multichannel versus diarization](https://developers.deepgram.com/docs/multichannel-vs-diarization)
  distinguishes independent channel transcription from identifying people
  within one channel. Cadence uses this channel separation principle locally;
  it does not call Deepgram or upload audio.
- The pinned FluidAudio `StreamingUnifiedAsrManager` exposes independent actor
  instances, `getPartialTranscript()`, `finish()`, and `reset()`. Its
  `UnifiedConfig` defines the Accurate profile's latency. Inspect the resolved
  source under `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Unified`
  when changing this integration.
- [Apple: What's new in voice processing](https://developer.apple.com/videos/play/wwdc2023/10235/)
  documents echo cancellation and how voice processing can duck other apps'
  audio. Enabling it in a recorder is not evidence that third-party call
  playback is correctly echo-cancelled; that requires a separate live experiment.
- [Speex: echo cancellation](https://www.speex.org/docs/manual/speex-manual/node7.html)
  specifies the explicit microphone/playback reference API and its timing,
  sample-clock, and acoustic-path requirements. The vendored sources are pinned
  to SpeexDSP 1.2.1; provenance and licenses are in `Sources/CSpeexDSP`.
- [Apple: AVAudioEngine configuration changes](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)
  specifies that hardware sample-rate or channel-count changes stop and
  uninitialize the engine. A successful start is insufficient evidence that
  a live microphone continues delivering samples.

## Automated verification

### Background preparation and echo processing

App launch starts meeting preparation after the shared dictation models are
ready. Downloads are shared across concurrent requests, cached outside the app,
and survive app updates. The two live meeting managers load first; optional
Cohere loading and its first prediction run in background setup. Recording only
waits for the live managers. If Cohere is still preparing or failed, that
recording uses Parakeet and displays a notice. A later recording can use ready
Cohere. Setup outlives a cancelled recording and ready managers stay in memory.
First installation still needs a network connection and local Core ML setup;
readiness is displayed before the user starts a meeting.

The following checks use only numeric arrays and mock loaders: no audio device,
playback, speech synthesis, model inference, or application launch occurs.

```sh
swift test -Xswiftc -warnings-as-errors \
  --filter 'MeetingModelPreparationTests|MeetingEchoCancellationTests'
```

The echo fixtures require at least 20 dB attenuation of a delayed copy after
adaptation and independently check preservation of a second, overlapping signal.
The buffered fixture uses different producer block sizes and arrival times and
checks every output timestamp. Other cases cover absent/late playback, gaps,
bounded history, and final partial frames. Setup tests cover simultaneous start
requests, cancellation, failed setup/retry, warm reuse, and stale progress.
These checks are arithmetic regressions, not evidence of recognition accuracy
or successful echo cancellation in a real room. Live capture, startup timings,
and the visible readiness UI must be checked separately when device testing is
permitted.

### Cohere Beta

Notes and Settings share a persisted model selector. Cohere Transcribe is the
default on macOS 15+, with Parakeet selectable between recordings. The shipped
INT8 Cohere encoder declares macOS 15 as its minimum OS; older supported Macs
use Parakeet and disable the Cohere option. Dictation remains independent.

Parakeet still supplies the live hypothesis. On each VAD endpoint, a single
Cohere worker transcribes that source's audio and replaces the same utterance
ID. Continuous speech is split at approximately eight seconds to stay below
the converted decoder's fixed 108-token cache (including its language prompt).
Only four phrases may wait behind the current inference. Queue overflow,
empty output, decode errors, or a saturated token budget preserve the live
words and show a fallback notice. Audio exists only in these bounded in-memory
buffers. Stop closes capture immediately, drains both sources and the refinement
queue, then saves; inference time is excluded from the meeting duration.

Use `CoherePipeline` with `.cpuAndNeuralEngine`. In a minimal M2 Max experiment,
`.all` spent roughly 113 seconds compiling the encoder's Metal execution graph
on its first prediction. CPU/ANE completed the same synthetic 4.45-second clip
in 2.72 seconds initially and 2.16 seconds warm. The first CPU/ANE model load
also compiled a cache and took substantially longer than subsequent loads.
These measurements verify execution, not accuracy on real call audio.

The opt-in suite below also checks the actual Cohere revisions on independent
channels, quiet speech, missing system audio, stopping during the last phrase,
long continuous speech, and switching back to Parakeet. Unit tests cover
preference persistence, partial downloads, bounded backlog, failed/empty
refinements, cancellation, and late revisions retaining their original speaker.

```sh
CADENCE_RUN_MEETING_MODEL_TEST=1 CADENCE_RUN_STREAMING_MODEL_TEST=1 \
  CADENCE_RUN_COHERE_MODEL_TEST=1 swift test -c release -Xswiftc -warnings-as-errors
```

### Capture and Parakeet

```sh
CADENCE_RUN_MEETING_MODEL_TEST=1 CADENCE_RUN_STREAMING_MODEL_TEST=1 \
  swift test -Xswiftc -warnings-as-errors
./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 dist/Cadence.app
CADENCE_SMOKE_TEST=notes-capture dist/Cadence.app/Contents/MacOS/Cadence
```

The model test synthesizes temporary speech files locally and exercises quiet
microphone speech, overlapping inputs, repeated remote turns, output while the
other input has supplied no data, out-of-order completion, stopping without
trailing silence, model reuse, and microphone-only fallback. It asserts the
saved note's speakers, words, chronology, and Markdown round trip. Unit tests
cover delayed revisions and loading existing notes without timestamps.

The signed-bundle `notes-capture` mode checks two consecutive real microphone
and system-tap starts, timestamp validity, sample delivery, and stop/drain
completion. It also stops the real dictation engine, posts a configuration-change
notification, asserts audio resumes through the original stream, and checks
that a late notification after intentional stop leaves the microphone closed. It does not
play, transcribe, or save audio. It requires the app's existing audio grants.
Set `CADENCE_NOTES_MICROPHONE_ONLY=1` to check the unavailable-system fallback.
This capture check does not prove speech recognition or speaker accuracy.

## Live-call checks and limits

In Discord with Mac speakers, alternate local and remote sentences, speak over
remote speech at a lower volume, make a brief interjection, and stop during a
final word. Check the live notepad and exported Markdown: complete local
phrases must remain **You**, remote phrases **Them**, and delayed updates must
remain on their original turns. Repeat with the call's actual microphone and
output devices. Repeat with headphones and at low, moderate, and high speaker
volume. Check that remote-only speech does not add **You** lines and that local
interruptions remain intact. Also check system-audio permission denied, playback
stalls, and device changes. Start two consecutive notes after readiness and one
while Cohere is still preparing; verify actual capture starts without waiting
for Cohere and the recording's displayed model matches the model in use.

The microphone follows the
Mac's default input, which can differ from an explicit Discord device selection.
The system tap captures all playback, including other apps, and all remote
people share **Them**. Individual remote speakers, real speakerphone echo quality,
device routing, and recognition of names/slang need their own evidence. Do not
claim those are fixed solely by channel separation or numeric fixtures.
Two recognizers use more memory
and inference work than the old mixed stream.

Cadence does not save call audio, so an old transcript cannot be reliably
retranscribed or relabeled without its original recording.
