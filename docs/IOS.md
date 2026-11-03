# teleBackup on iPhone

Same screens and the same safe-delete rule as Android. What differs is how iOS lets an app work in the background and delete photos.

## What is the same
- Rules, topics, Telegram bot setup, history, review, kill switch, pause / delay / resume.
- A file is deleted only after Telegram confirmed it (same state machine and delete gate, ported to Swift and tested: `cd app/ios/TeleCore && swift test`, 24 tests).
- Every rule starts as upload only.

## What is different
| Android | iPhone |
|---|---|
| Folders | Albums: Camera Roll, Screenshots, Videos, WhatsApp (if it keeps an album), and your own albums |
| Foreground service uploads for hours | Uploads run while the app is open, for about 30 s after you leave it, and in iOS background windows (usually overnight, on Wi-Fi). Everything is saved per file, so the next window carries on. Opening the app resumes the queue at once. |
| Silent delete | **One confirmation per batch.** The app prepares "N files ready to delete" and notifies you; you approve in the app and iPhone shows its own "Delete N photos?" prompt. Deleted photos stay 30 days in Recently Deleted. |
| All files access | Photos access: choose **Allow Full Access** |
| Battery exemption | Background App Refresh must be on for teleBackup |

## Videos over 50 MB (the Telegram account)
Same as Android: files at or over 50 MB go through your own Telegram account (TDLib), everything smaller goes through the bot. Log in once in setup (api_id and api_hash from my.telegram.org, phone, code). With the account logged in, the delete step also asks Telegram to fetch the message again just before deleting (the strong check). Without the account, big videos wait and Home says so.
TDLib is Swiftgram's build 1.8.69-025086e3 of the official sources, vendored as `app/ios/ThirdParty/TDLibFramework`; Swift downloads the binary and checks its SHA-256.

## Videos over 2 GB
Cut at keyframes into parts of at most 1.9 GB without re-encoding (nothing is lost), then sent together as one album through the account (up to 10 parts, so about 19 GB). Needs free space on the phone about equal to the video while it is cut. A video sent in parts is never deleted by the app; delete it yourself after checking it in Telegram. Only MOV, MP4, M4V and 3GP are cut. Tested on a real sample video on the Mac: every part decodes, frames and duration add up.

## Photos (HEIC) sent as media
iPhone photos are HEIC. In "media" rules they are converted to JPEG on the phone (same pixels, orientation and date kept, quality lowered only if needed to stay under Telegram's 10 MB photo limit) and arrive as normal photos, like picking images in Telegram. If a photo cannot be converted, the original goes as a file; nothing is lost. "Original" rules always send the HEIC file as it is.

## Looks after itself (for non-technical users)
Once set up, nothing needs doing:
- Failed uploads are retried automatically (2, 4, 8 ... minutes, up to 6 hours, 5 tries, then "skipped" with a note in History). Short waits are slept through while the app is running; longer ones wake the app in the background.
- When Wi-Fi comes back, the queue restarts by itself.
- A delay ("Delay 2h") ends by itself and the queue resumes.
- A daily check scans the albums, prepares the delete list, tidies old history, and asks iOS for the next wake-up at the right time (the next retry, the end of a delay, or tomorrow).
- Notifications match Android: progress with Pause, Paused with Delay/Resume, Paused until, warnings (Telegram account logged out, no Photos access, bot cannot post, topic deleted), and "Check before deleting". Tapping one opens the right screen.
- iOS decides when background work really runs (usually overnight, on Wi-Fi). Opening the app also continues the queue at once.

## Not on iPhone yet
- Documents sorting is not on iPhone (the switches are hidden).

## Installing without paying (free Apple ID)
The build script makes an unsigned file: `tools/build_ios_ipa.sh` -> `app/build/ios-release/teleBackup-ios.ipa`.
The family way is **SideStore**, which refreshes the 7-day signature on the phone by itself: follow [IOS_SIDESTORE.md](IOS_SIDESTORE.md). AltStore (altstore.io) or Sideloadly (sideloadly.io) also work.

1. On the iPhone: Settings > Privacy & Security > **Developer Mode** > on (restarts the phone).
2. Install AltServer (or Sideloadly) on a Mac or Windows PC, plug the iPhone in once, and install the `.ipa`.
3. On the iPhone: Settings > General > VPN & Device Management > trust your Apple ID.
4. Open teleBackup and follow the setup.

**The free signature lasts 7 days. This is the one thing that is not hands-off.** After that the app stops opening until it is refreshed.
- AltStore refreshes it by itself when the iPhone and the computer running AltServer are on the same Wi-Fi.
- teleBackup shows a warning on Home and sends a notification two days before it runs out.
- For people who will not touch it: keep AltServer running on an always-on computer at home (it refreshes the app by itself over Wi-Fi), or use SideStore (sidestore.io), which refreshes on the phone itself after one setup, or pay for an Apple Developer account (99 USD a year, a signature lasts a year).

## Building it
Needs full Xcode, Flutter and CocoaPods (`brew install --cask flutter && brew install cocoapods`).
- Simulator: `xcodebuild -project app/ios/Runner.xcodeproj -scheme Runner -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- Release file: `tools/build_ios_ipa.sh`
- If `flutter build ios` fails with "Failed to copy Flutter framework", build with `xcodebuild` as above (the project is inside Documents, whose file metadata upsets codesign).

## Code layout
- `app/ios/TeleCore/`: the core in Swift (Swift package, tests run on the Mac: `cd app/ios/TeleCore && swift test`, 32 tests).
- `app/ios/TeleTD/`: the TDLib adapter (`swift test` there talks to Telegram with dummy credentials to prove the adapter starts).
- `app/ios/Runner/App/`: Photos, Keychain, notifications, background tasks, the bridge implementation (`CoreHost.swift`).
- `app/ios/Runner/Bridge/CoreApi.g.swift`: generated by Pigeon (`dart run pigeon --input pigeons/core_api.dart`).

## Status
Built and launched in the iOS simulator; the core is covered by 32 tests and the TDLib adapter starts and talks to Telegram. **Not yet tested on a real iPhone** with real photos and a throwaway Telegram group. Do that first, with an upload-only rule, before turning delete on.
