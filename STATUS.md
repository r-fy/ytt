# YTT status

Native Swift menu bar app. Hold fn, talk, release, words land at the cursor.
Speech: Parakeet 0.6B through a resident sherpa-onnx websocket server.

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
- Next: Phase 7 (small local model for context errors) only after daily use
  shows which errors rules cannot fix. Phase 8 (correction watcher) after that.

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
