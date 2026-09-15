# YTT status

Native Swift menu bar app. Hold fn, talk, release, words land at the cursor.
Speech: Parakeet TDT 0.6B v3 (multilingual, int8) through a resident sherpa-onnx
websocket server.

## Build and install

    ./build.sh                       # both arches, lipo, bundle, sign
    rm -rf /Applications/YTT.app && cp -R YTT.app /Applications/
    open /Applications/YTT.app

Log: `~/Library/Logs/YTT.log`. Quit from the menu bar icon or `pkill YTT`.

## Phase log

- Phase 0 (2026-08-24): fn key spike passes. See `spike/README.md`.
- Phase 1 (2026-08-24): record while held, 16 kHz WAV. Mic opens in 130 to 240 ms.
- Phase 2 (2026-08-24): transcribe via vendored sherpa 1.13.4. 5 s in 0.5 s, 34 s in 2.5 s.
- Phase 3 (2026-08-24): app bundle. Listener folded in-process (decided by the Phase 0 sleep test).
- Phase 4 (2026-08-24): rules engine. `rules.json` in the data folder, seeded from
  `Resources/rules.json`, reloaded on every dictation when its mtime changes.
  Check: `./tools/check-rules.sh`.
- Phase 5 (2026-08-24): AppIcon.icns (gpt-image-2), model moved to
  `~/Library/Application Support/YTT/models/`. Menu bar icon uses SF Symbols
  with state colors, no PNG needed.
- Phase 6 (2026-08-24): ModelStore downloads from `Resources/models.json`
  (GitHub asr-models release, 501 MB archive, `tar -xjf`, `.installed.json`
  marker with archive SHA-256). Menu: "Edit cleanup rules", "Check for model
  updates" (opens the release page, updating stays manual on purpose).
  Hotwords ship: every `to` in the rules.json dictionary goes to the engine
  as a hotword with `modified_beam_search`, score 1.5, and a `bpe.vocab`
  built from tokens.txt (`Hotwords.swift`). A/B on one recording: two
  misheard names fixed at the engine level, +50 ms decode. Score 2.0 dropped
  neighbouring words, so 1.5 it is. Switch off with `"hotwords": false` in
  rules.json (needs relaunch).
- History: one JSON line per dictation in `history.jsonl` in the data folder.
- Phase 7 (2026-09-05): decode while you talk. `PauseChunker` in
  `AudioRecorder.swift` judges 100 ms frames; a pause is 0.9 s of frames under
  max(0.002, 3 x quietest frame of the hold). After 4 s of audio a pause closes
  the chunk at the middle of the quiet run; 30 s with no pause forces a cut.
  Each chunk goes to the server during the hold, one at a time (`Dictation`
  in `AppDelegate.swift`), results join in order after release. last.wav, the
  120 s cap, the 0.25 s tap rule, and history audio seconds all still use the
  full recording. Log lines: `CHUNK i decode= audio=`, `REC_STOP ... chunks=
  silenceRMS=`. Check: `YTT --chunk-test file.wav` prints cut points.
  Constants are set for an assumed working range (speech 0.003 to 0.007 RMS,
  noise 0.0005), not a measurement taken from this mic; watch `silenceRMS=`
  in the log on other mics. The threshold is capped at a fraction of the
  loudest frame heard so far, so a hold with no true silence never lets the
  threshold climb into speech and cut mid-word.
- Phase 7 (2026-09-05): the pause that ends a chunk grew from half a second to
  0.9 s, so cuts land more often on a real sentence break. When a cut still
  lands mid-sentence, `Seam.stitch` in `AppDelegate.swift` fixes the join: it
  lowercases a wrongly capitalized word at the start of the next chunk,
  unless the word is "I" or a contraction of it, an acronym in capitals, or a term
  from the cleanup dictionary; a name not in the dictionary still gets lowercased. Check:
  `YTT --stitch-test "a|b|c"`.
- Phase 8 (2026-09-14): paragraph breaks. A pause of 1.5 s or more ends a
  paragraph, but only if the chunk before it ends in `.`, `?`, or `!` and the
  paragraph so far has at least two sentences. A one-sentence paragraph gets
  merged back into its neighbour, so you never get a lonely single line.
  Switch off with `"paragraphs": false` in rules.json. A local LLM cleanup
  stage was also benchmarked across 12 models on 2026-09-14 and shelved, see
  `private/LLM_FORMAT_BENCH_2026-09-14.md`.
- Model switch (2026-09-14): switched the default model to Parakeet TDT 0.6B v3
  on Raffi's request; A/B against Unified on `last.wav` gave an identical
  transcript at 697 ms vs 757 ms median decode, so v3 replaced Unified as
  default while the Unified entry stays in `Resources/models.json` for a
  one-word revert.
- Next: small local model for context errors only after daily use shows
  which errors rules cannot fix. Correction watcher after that.

## Data folder

`rules.json` and `history.jsonl` live in `~/Library/Application Support/YTT`
by default. To share them across Macs, point YTT at a synced folder:

    defaults write local.ytt.menubar dataDir "$HOME/Sync/YTT"

and relaunch.

## Code signing (read before touching build.sh)

Ad-hoc signing (`-s -`) changes the app identity on every build and macOS
drops the Accessibility grant each time (confirmed 2026-08-24). So `build.sh`
signs with a self-signed certificate named "YTT Dev" if one exists in the
keychain, and falls back to ad-hoc otherwise. With the cert, a rebuild keeps
the grant.

To create the cert without a keychain password prompt during builds, put it
in its own keychain: openssl self-signed cert with
`extendedKeyUsage=codeSigning`, export p12 with `-legacy`, `security
create-keychain`, `security import` with `-T /usr/bin/codesign`,
`set-key-partition-list`, add the keychain to the search list,
`add-trusted-cert -p codeSign`. See README for the exact commands.

Stale grants: if Accessibility shows on but the log says
`accessibility=false`, run `tccutil reset Accessibility local.ytt.menubar`,
relaunch, and grant again.

## Known facts

- Speech server RSS: 1.1 GB after load, 1.5 GB after a long decode.
- On the test Mac (macOS 26, external USB keyboard), macOS delivers no key
  events while Globe is held, so FN_INTERRUPTED never fires. Kept as a
  safety net.
- fn+A/C/N/H/F/M/Q/E are system shortcuts. Never use as test keys.
- While YTT runs it holds the system Globe action at "Do Nothing" and puts
  the original back on quit. Any other app doing the same (OpenWhispr does)
  must be quit first. If the fn key ever stays dead: System Settings >
  Keyboard > "Press globe key to".
- Clipboard managers see every dictation, because the paste goes through the
  pasteboard.
- Playback of `last.wav` with `afplay` goes to the default output device,
  which on a USB mic with a headphone jack may be the mic itself.

## Public release hardening (2026-08-24)

Second reviewer pass before sharing found and fixed: sherpa listened on all
interfaces (now pinned to 127.0.0.1 via `tools/bindfix.c` loaded with
DYLD_INSERT_LIBRARIES), orphaned servers after a force quit (reaped at
launch, SIGKILL fallback in stop), clipboard restore losing the original on
two quick dictations (single snapshot slot), "Ready" shown while
Accessibility was missing (sticky blocking issue), no transcription timeout
(30 s watchdog), transcript text in the log (removed, history.jsonl only),
half-extracted model adopted as good (staging dir + size floor + sha pin),
truncated sherpa archive poisoning builds (.part + sha), paste into a
different app than the one you dictated into (target pid check), keychain
search list clobbered by the signing doc (append). README gained uninstall,
upgrade, and disclosure sections.
