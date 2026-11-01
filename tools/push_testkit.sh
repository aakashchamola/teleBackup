#!/usr/bin/env bash
# Copies ./testkit/ to the phone's test folder and tells MediaStore about each file. Needs adb and a phone in USB debugging.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="/sdcard/Pictures/teleBackupTest"
adb get-state >/dev/null || { echo "No phone found. Check 'adb devices'."; exit 1; }
adb shell mkdir -p "$DEST"
adb push testkit/. "$DEST/"
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$DEST" >/dev/null || true
adb shell content call --method scan_volume --uri content://media --arg external_primary >/dev/null || true
echo "Pushed to $DEST. Open the Gallery app to confirm the files show."
