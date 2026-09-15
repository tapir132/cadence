# SpeexDSP echo canceller

Unmodified echo-cancellation and small FFT sources from Xiph SpeexDSP 1.2.1,
commit `1b28a0f61bc31162979e1f26f3981fc3637095c8`:
https://github.com/xiph/speexdsp/tree/SpeexDSP-1.2.1

Built with floating-point arithmetic and the BSD-licensed smallft backend.
The local `config.h` includes system math constants before portable fallbacks.
No microphone, device, playback, file-recording, or network APIs are included.
Cadence passes fixed 256-sample mono frames at 16 kHz to this static library.
`COPYING` and the source headers retain the upstream license and copyrights.
`NOTICES` reproduces the individual source preambles. The production app
includes both in `Resources/SpeexDSP-LICENSE.txt`.
