# M1 findings (fill in on the real phone)

Answers from `docs/phases/M1.md`. Each row: what was tried, what happened, and what it means for the design. Fix the design doc named in the last column in the same commit.

**Phone:** Motorola moto g62 5G, Android 13, SDK 33 (4 users on it; the app is installed for user 0 only) · **TDLib:** 1.8.67 from the community AAR `io.github.tdlib-android:core:0.1.1` (SHA-256 1ec6d6c6c83b655349d8a91182145cdd5400392246136ad79432253ad6004106), see Q5 · **Date:** 2026-11-02 (bot and on-device tests; TDLib, delete-in-Gallery and background tests still open)

## Questions (ROADMAP "M1 questions")
| # | Question | Result | Design change | Doc fixed |
|---|---|---|---|---|
| Q1 | Does deleting with All files access work for Gallery photos, WhatsApp media (`Android/media/com.whatsapp/...`) and Screenshots? | | | |
| Q2 | After a delete, does the gallery still show the file until a MediaStore refresh? | | | |
| Q3 | Does `sendVideo` keep the video bytes? What does `sendPhoto` do to a full-resolution photo (sizes in `photo[]`)? | `sendPhoto` of a 4000x3000 JPEG (2,027,563 B) came back as 5 sizes, largest 2560x1920 / 785,596 B: re-encoded and downscaled, so the original is NOT kept. `sendDocument` of the same file: `file_size` 2,027,563 = local, and a download through `getFile` was byte-identical (SHA-256 equal). `sendVideo` of a 30,645,709 B clip: `video.file_size` = local size exactly (30 MB is over the bot download limit of 20 MB, so bytes not compared here; needs the account, Q6). | Photos sent as media can only be checked by aspect ratio and "not smaller than", never by size; originals belong in `sendDocument` (the rule `uploadAs=document` exists for this). | |
| Q4 | Is the bot reply enough to match the file (size, dimensions, duration)? When does 429 start, what `retry_after`? | Size: yes for documents and videos (exact match). Dimensions and duration: NO. My ffmpeg clips came back as 320x320, duration 0 because the bot did not read them; a sender must pass `width`/`height`/`duration` itself and the reply check must not compare them unless it did. 429: 25 `sendMessage` in a row into one topic gave no 429 (about 4 per second), so the start point is not found; the pacer keeps its conservative default. | `Verifier`: for video/document compare `file_size` only; for photo-as-media compare ratio. | |
| Q5 | Which TDLib works on Android: prebuilt artifact or our own build? Version? | A community prebuilt AAR on Maven Central (`io.github.tdlib-android:core:0.1.1`, by one person, BSL-1.0, 4 ABIs, TDLib 1.8.67 with the new `topicId: MessageTopic` API) loads on the Moto G62, starts, reaches the phone-number step in 3 s and rejects a made-up api_id (`TdlibSmokeTest`). It is NOT the official distribution and the binary holds the account session, so it is used for development and the test; before a family release build it from tdlib/td (same `org.drinkless.tdlib` API, a drop-in swap of the dependency). | `TdlibGateway` uses `MessageTopicForum(forumTopicId)` for the topic. | TELEGRAM.md |
| Q6 | Can the account re-fetch a message the bot posted (id conversion)? | | | |
| Q7 | Does the foreground service survive the screen off for hours? Can it start from the background (with battery exemption)? | | | |

## Other things measured
| Item | Result |
|---|---|
| Bot: update types that revealed the group in `getUpdates` | `my_chat_member` (bot added, then made admin) and `message`. The group first showed as a basic group (-5589307777), then as a supergroup (-1003949844407) once Topics was turned on: **the chat id changes when Topics is switched on**; `Find my group` must pick the newest/forum one. |
| Bot: 50 MB edge (exact error at 50 MB, ok at 49.9 MB?) | 49,375,836 B as document: ok. 53,025,240 B as document: HTTP 413 `Request Entity Too Large` (no JSON description). Exactly 52,428,800 B not tried. |
| Bot: photo > 10 MB and 12000x1000 errors | 46 MB photo: 400 `file of size 46210584 bytes is too big for a photo; the maximum size is 10485760 bytes`. 12000x1000: 400 `PHOTO_INVALID_DIMENSIONS`. |
| Bot: HEIC as photo | |
| Bot: rotated video width/height | INCONCLUSIVE: the reply gave 320x320 for every video (see Q4). |
| Bot: unicode file name shown right | INCONCLUSIVE: the reply said `file_name: "file"` for `ünïcödé name & spaces (1).jpg`, but it was sent with curl on Windows (its multipart name handling), not from the app. Re-test from the Kotlin sender. |
| TDLib: login states seen (any email step?) | |
| TDLib: what was needed before `getChat` on the group worked | |
| TDLib: topic parameter name in `sendMessage` | `SendMessage.topicId: MessageTopic` (`MessageTopicForum(forumTopicId: int)`), not `messageThreadId`. Written but not yet run against Telegram (needs the account login). |
| TDLib: upload speed (MB/s) on home Wi-Fi | |
| TDLib: resume after Wi-Fi drop mid-file | |
| Delete: `contentResolver.delete` vs `File.delete` + scan | End to end on the phone (`BotEndToEndTest`, run twice): a test JPEG written with the File API (not in MediaStore) was found by the scanner's file fallback, sent by the bot to a new topic, reply check passed (VERIFIED), the cleaner made a review and deleted nothing, the review was approved, then `FileDeleter` removed the file (state DELETED). On the phone, `AndroidFileDeleter` (All files access granted) deleted a test file in `Pictures/teleBackupTest/` and reported the freed bytes; a missing file is reported as a failure (`FileDeleterTest`, 2/2 pass). Not yet checked: the Gallery app after delete, WhatsApp/Screenshots/Camera folders, no-permission behaviour. |
| Background: heartbeat gaps on charger / on battery | |
| Background: Android 15 time limit stop reason | |
| Background: maker settings needed | |
| SHA-256 of 1 GB on the phone (seconds) | |

## Decisions
| # | Decision | Answer | Decided by |
|---|---|---|---|
| D1 | May a bot-only setup (no account) delete files? | | owner |
| D2 | TDLib source and pinned version | | |
| D3 | Photo-as-media reply check rule | | |
| D4 | Delete method for `FileDeleter` | | |
| D5 | Foreground start approach (or fallback) | | |
