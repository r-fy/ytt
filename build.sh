#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# No Xcode.app installed (only Command Line Tools), so `swift build --arch`
# multi-target is unavailable. Build each arch with an explicit triple, then
# lipo-merge. Same shape as AUX/build.sh.
swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0

[ -d vendor/sherpa/bin ] || ./tools/fetch-sherpa.sh

APP="YTT.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/lib"
lipo -create \
  ".build/arm64-apple-macosx/release/YTT" \
  ".build/x86_64-apple-macosx/release/YTT" \
  -output "$APP/Contents/MacOS/YTT"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f MenuBarIcon.png ] && cp MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
cp Resources/rules.json "$APP/Contents/Resources/rules.json"
cp Resources/models.json "$APP/Contents/Resources/models.json"

# The server finds its dylibs at @rpath = ../lib relative to the binary, so
# keep the bin/ and lib/ siblings intact inside Resources.
cp vendor/sherpa/bin/sherpa-onnx-offline-websocket-server "$APP/Contents/Resources/bin/"
cp vendor/sherpa/lib/*.dylib "$APP/Contents/Resources/lib/"

# A fixed self-signed identity keeps the signature stable across rebuilds so
# macOS keeps the Accessibility and Microphone grants (plan risk R3, confirmed
# to bite with ad-hoc signing). Created once with openssl + security import,
# see STATUS.md. Falls back to ad-hoc if the cert is missing.
if security find-identity -v -p codesigning | grep -q '"YTT Dev"'; then
  codesign --force --deep -s "YTT Dev" "$APP"
else
  echo "warning: 'YTT Dev' certificate not found, ad-hoc signing (permissions will reset)"
  codesign --force --deep -s - "$APP"
fi

echo "Built $APP"
lipo -info "$APP/Contents/MacOS/YTT"
