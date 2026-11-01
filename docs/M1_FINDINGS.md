# M1 findings (fill in on the real phone)

Answers from `docs/phases/M1.md`. Each row: what was tried, what happened, and what it means for the design. Fix the design doc named in the last column in the same commit.

**Phone:** _model, Android version, SDK level_ · **TDLib:** _version, source_ · **Date:** _yyyy-mm-dd_

## Questions (ROADMAP "M1 questions")
| # | Question | Result | Design change | Doc fixed |
|---|---|---|---|---|
| Q1 | Does deleting with All files access work for Gallery photos, WhatsApp media (`Android/media/com.whatsapp/...`) and Screenshots? | | | |
| Q2 | After a delete, does the gallery still show the file until a MediaStore refresh? | | | |
| Q3 | Does `sendVideo` keep the video bytes? What does `sendPhoto` do to a full-resolution photo (sizes in `photo[]`)? | | | |
| Q4 | Is the bot reply enough to match the file (size, dimensions, duration)? When does 429 start, what `retry_after`? | | | |
| Q5 | Which TDLib works on Android: prebuilt artifact or our own build? Version? | | | |
| Q6 | Can the account re-fetch a message the bot posted (id conversion)? | | | |
| Q7 | Does the foreground service survive the screen off for hours? Can it start from the background (with battery exemption)? | | | |

## Other things measured
| Item | Result |
|---|---|
| Bot: update types that revealed the group in `getUpdates` | |
| Bot: 50 MB edge (exact error at 50 MB, ok at 49.9 MB?) | |
| Bot: photo > 10 MB and 12000x1000 errors | |
| Bot: HEIC as photo | |
| Bot: rotated video width/height | |
| Bot: unicode file name shown right | |
| TDLib: login states seen (any email step?) | |
| TDLib: what was needed before `getChat` on the group worked | |
| TDLib: topic parameter name in `sendMessage` | |
| TDLib: upload speed (MB/s) on home Wi-Fi | |
| TDLib: resume after Wi-Fi drop mid-file | |
| Delete: `contentResolver.delete` vs `File.delete` + scan | |
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
