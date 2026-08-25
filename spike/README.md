# Phase 0 spike: fn key listener

Standalone test of the fn key listener, cut down from OpenWhispr's
`resources/macos-globe-listener.swift` (MIT). No app bundle.

Files: `GlobeListener.swift` (shared), `globe/main.swift` (Phase 0),
`audio/main.swift` + `audio/Info.plist` (Phase 1).

Build both:

    ./spike/build.sh

Run (quit OpenWhispr first, both apps fight over the same key):

    ./spike/globe-spike --suppress-system-globe-action \
        --globe-preference-state "$HOME/Library/Application Support/YTT/globe-preference-state.json"
    ./spike/audio-spike  (same flags; writes /tmp/ytt-last.wav on release)

Output lines: `FN_DOWN`, `FN_UP held=<ms>`, `FN_INTERRUPTED keyCode=<n>`.
Ctrl+C or SIGTERM restores the fn key's normal action. A leftover marker
file from a crash is picked up on the next run so the original value is not lost.

Recovery if the fn key ever stays dead: System Settings > Keyboard >
"Press globe key to", pick the action you want.

## Phase 0 results (2026-08-24, macOS 26, Apple Silicon)

1. FN_DOWN on press, FN_UP with hold time on release: pass.
2. No emoji picker while running: pass. The private Carbon calls
   (TISGetFnUsageType / TISUpdateFnUsageType) still work on macOS 26.
3. FN_INTERRUPTED: cannot be tested on this Mac. While Globe is held, macOS
   delivers no other key event to any listener, not even a raw CGEvent tap.
   fn+K types nothing and fn+arrow does not move the cursor, with or
   without the spike running. The code stays because it is harmless and
   upstream-proven, but it is unverified here.
4. Ctrl+C (SIGINT) restores the Globe action and removes the marker: pass.
5. Sleep/wake: Mac slept 152 s, woke, listener still fired with no restart.
   Supports folding the listener in-process (plan D5).
6. Clean rebuild and rerun: no Accessibility re-prompt. Ad-hoc signing did
   not churn permissions (plan R3).

Other facts learned:
- Accessibility and Input Monitoring were already granted when launched from
  the Claude Code shell, no prompt appeared.
- OpenWhispr's marker lives at
  ~/Library/Application Support/open-whispr/globe-preference-state.json.
  Quit OpenWhispr before running the spike.
- fn+A, C, N, H, F, M, Q, E are macOS system shortcuts (Dock, Control
  Center, etc). Never use those as test keys.

## Phase 1 results (2026-08-24)

Mic: Neat Bumblebee II USB, 48 kHz mono. Converted to 16 kHz mono float32
with AVAudioConverter, saved as 16-bit WAV.

- Engine start latency after FN_DOWN: 238 ms first time, 128 ms after.
  First word still intact because a person starts talking later than that.
- 5.09 s hold gave 4.78 s of audio. Write took 10 ms.
- Recording level is low (peak -34.6 dB) but that is this mic, and the
  Parakeet engine transcribed it word for word.
- Orange mic dot shows only during the hold: pass.
- Playback check via `afplay` failed because the default output device is
  the Bumblebee's own headphone jack. Verified by transcription instead.

Early Phase 2 check, done here with OpenWhispr's own binary
(`sherpa-onnx-ws-darwin-arm64` on port 6007) and a 20-line Python client:
- The one-message wire protocol ([int32 rate][int32 byteCount][float32...])
  works. 306 KB message, 352 ms decode, exact transcript back.
- Server RSS after one real decode: 1084 MB. That is the real RAM cost,
  the "6 MB idle" figure in PLAN.md is before the model pages are touched.

## Phase 2 results (2026-08-24)

Files: `Sherpa.swift` (spawn + supervise the server, websocket client),
`transcribe/main.swift`. Engine binary comes from `tools/fetch-sherpa.sh`
into `vendor/sherpa/` (gitignored). Model still borrowed from
`~/.cache/openwhispr/parakeet-models/parakeet-unified-en-0.6b`.

Run: `./spike/transcribe-spike` with the same flags as the other spikes.

- Server load: 1.4 s to "Started!", 1125 MB RSS before any decode.
- 5 s dictation: 520 ms decode, exact transcript. RSS 1181 MB.
- 33.6 s dictation (2.1 MB single websocket message): 2.5 s decode, full
  paragraph back with three word errors ("this Mac" -> "his MAG",
  "text" -> "test", a first name misspelled). RSS 1520 MB.
- Risk R2 closed: URLSessionWebSocketTask sends one multi-MB binary
  message and the sherpa server reassembles it.
- Real RAM cost of the resident engine is 1.1 to 1.5 GB, not the 6 MB idle
  figure in PLAN.md.
- Ports: picked at runtime by binding port 0, so no clash with OpenWhispr.
- Ad-hoc re-sign of the upstream dylibs (1.6 in the plan) is in the fetch
  script; the vendored server ran first try.
