#!/bin/sh
# Fetch sherpa-onnx 1.13.4 (the version OpenWhispr ships), keep only the
# offline websocket server and its libraries, and ad-hoc sign them.
# Upstream 1.13.4 ships an invalid arm64 signature on libonnxruntime, and
# dyld SIGKILLs the process on load without the re-sign.
#
# Output: vendor/sherpa/bin/sherpa-onnx-offline-websocket-server
#         vendor/sherpa/lib/*.dylib
set -e
cd "$(dirname "$0")/.."

VERSION=1.13.4
NAME="sherpa-onnx-v${VERSION}-osx-universal2-shared"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${NAME}.tar.bz2"
SHA256=02b9b0cf30819a18c6d5cf861aebf32336cb79958ab97a2b248227059678058b
ARCHIVE="vendor/sherpa-${VERSION}.tar.bz2"
OUT=vendor/sherpa

mkdir -p vendor
if [ ! -f "$ARCHIVE" ]; then
    echo "downloading $URL"
    # Download to a .part file so an interrupted transfer never leaves a
    # truncated archive that every later build trips over.
    curl -sSL -o "$ARCHIVE.part" "$URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi

if ! echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "error: $ARCHIVE does not match the expected checksum. Delete it and rerun." >&2
    exit 1
fi

rm -rf "$OUT" vendor/"$NAME"
tar -xjf "$ARCHIVE" -C vendor \
    "$NAME/bin/sherpa-onnx-offline-websocket-server" \
    "$NAME/lib/libsherpa-onnx-c-api.dylib" \
    "$NAME/lib/libsherpa-onnx-cxx-api.dylib" \
    "$NAME/lib/libonnxruntime.1.27.0.dylib" \
    "$NAME/lib/libonnxruntime.dylib"
mv vendor/"$NAME" "$OUT"

for f in "$OUT"/bin/* "$OUT"/lib/*.dylib; do
    codesign --force --sign - "$f" 2>/dev/null
done

echo "sherpa $VERSION ready in $OUT"
