#!/usr/bin/env bash
# Builds an UNSIGNED iPhone app file (teleBackup-ios.ipa) for AltStore / Sideloadly.
# Each person signs it with their own free Apple ID when they install it, so no paid account is needed.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"
flutter pub get
cd ios
DD="${TMPDIR:-/tmp}/telebackup-ios-derived"   # outside Documents: macOS file metadata there breaks the Flutter framework step
xcodebuild -project Runner.xcodeproj -scheme Runner -sdk iphoneos -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  DEVELOPER_DIR="$DEVELOPER_DIR" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
APP="$DD/Build/Products/Release-iphoneos/Runner.app"
OUT="$ROOT/app/build/ios-release"
rm -rf "$OUT"; mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/teleBackup.app"
(cd "$OUT" && zip -qr teleBackup-ios.ipa Payload && rm -rf Payload)
echo "Made: $OUT/teleBackup-ios.ipa"
