#!/bin/bash
# Builds Medal4Mac.app (and a .zip to send) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Medal4Mac"
OUT="build"
APP="$OUT/$APP_NAME.app"

echo "==> Building $APP_NAME (release)…"
# Try a universal build (Apple Silicon + Intel). That needs full Xcode;
# with only the Command Line Tools we fall back to this Mac's architecture.
if swift build -c release --arch arm64 --arch x86_64; then
    BIN=".build/apple/Products/Release/$APP_NAME"
    echo "==> Universal build OK (works on Intel and Apple Silicon Macs)"
else
    echo "==> Universal build not available, building for this Mac only ($(uname -m))"
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
fi

echo "==> Creating $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Zipping"
rm -f "$OUT/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"

echo ""
echo "Done!"
echo "  App: $APP"
echo "  Zip: $OUT/$APP_NAME.zip   <- send this one"
