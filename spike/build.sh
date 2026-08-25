#!/bin/sh
# Build all spikes. Run from the repo root: ./spike/build.sh
set -e
cd "$(dirname "$0")/.."

# The mic usage string is embedded into the plain binaries via an __info_plist
# section. Without it macOS kills the process on first mic access.
PLIST="-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker spike/audio/Info.plist"

swiftc -O spike/GlobeListener.swift spike/globe/main.swift -o spike/globe-spike

swiftc -O spike/GlobeListener.swift spike/AudioRecorder.swift spike/audio/main.swift \
    -o spike/audio-spike $PLIST

swiftc -O spike/GlobeListener.swift spike/AudioRecorder.swift spike/Sherpa.swift spike/transcribe/main.swift \
    -o spike/transcribe-spike $PLIST

echo "built spike/globe-spike, spike/audio-spike, spike/transcribe-spike"
