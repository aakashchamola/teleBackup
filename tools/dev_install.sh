#!/usr/bin/env bash
# Builds the debug APK, installs it for the main user only (flutter install puts it in every profile and
# gradle's connected tests uninstall it), and grants what the setup screen would ask for.
# Usage: tools/dev_install.sh          (needs one phone on adb; adb from devtools/android-sdk if not on PATH)
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../app"
ADB="${ADB:-adb}"; command -v "$ADB" >/dev/null || ADB=/c/Users/aakas/devtools/android-sdk/platform-tools/adb.exe
P=com.aakashchamola.telebackup
flutter build apk --debug
"$ADB" install -r --user 0 build/app/outputs/flutter-apk/app-debug.apk
"$ADB" shell pm grant $P android.permission.POST_NOTIFICATIONS
"$ADB" shell appops set --user 0 $P MANAGE_EXTERNAL_STORAGE allow
"$ADB" shell appops set --user 0 $P RUN_IN_BACKGROUND allow
"$ADB" shell appops set --user 0 $P RUN_ANY_IN_BACKGROUND allow
"$ADB" shell dumpsys deviceidle whitelist +$P >/dev/null
echo "installed and permissions granted for user 0"
