# teleBackup: Telegram integration

How the app talks to Telegram. Two clients behind one interface:
```kotlin
interface TelegramSender {
    suspend fun send(job: SendJob, progress: (sent: Long, total: Long) -> Unit): SendResult
}
// SendJob: chatId, threadId, path, displayName, mimeType, sendAs (PHOTO/VIDEO/DOCUMENT), caption, width, height, durationMs
// SendResult: Sent(SentMessage) | Failed(TgError)
// SentMessage: chatId, threadId, messageId (Bot API form), fileUniqueId, size, width, height, durationMs, kind
```
`BotSender` (Bot API over HTTPS with OkHttp) and `AccountSender` (TDLib) both implement it. `Router` picks one per file.

Items marked **(M1)** are believed true but must be confirmed on the real phone in M1. Record the answers in `docs/M1_FINDINGS.md` and fix this file.

## 1. Routing
```
size <  upload.botMaxBytes (50 MB)  -> BOT
size >= 50 MB                       -> ACCOUNT  (waits in QUEUED if the account is not READY)

uploadAs = ORIGINAL          -> DOCUMENT
uploadAs = MEDIA, photo      -> PHOTO if size <= 10 MB, else DOCUMENT (reason saved: "too big for a photo")
uploadAs = MEDIA, video      -> VIDEO
```
- Photo limits for `sendPhoto` also include width + height <= 10000 and aspect ratio <= 20. A photo outside them goes as `DOCUMENT`.
- GIFs and odd image types (HEIC, WEBP, DNG): `ORIGINAL` always works. With `MEDIA`, HEIC and DNG go as `DOCUMENT` (Telegram does not show them as photos reliably) **(M1: check HEIC)**.
- The account limit is 2 GB per file (4 GB with Premium). Files over that are `SKIPPED` with reason "Too big for Telegram (over 2 GB)".

## 2. Bot API

Base URL `https://api.telegram.org/bot<token>/<method>`. The token is read from `SecretStore` at call time and never logged. OkHttp's logging interceptor is **not** used; our own logger prints the method name and status only.

### Setup calls
| Step | Call | Use |
|---|---|---|
| Check token | `getMe` | `id`, `username`, `can_join_groups`. Saved to `telegram.botId`, `telegram.botUsername`. |
| Find the group | `getUpdates` (`allowed_updates` default, `timeout=0`) | Collect chats from `my_chat_member` and `message` updates where `chat.type == "supergroup"`. Updates are kept by Telegram for 24 h. If the bot has a webhook, `getUpdates` returns 409; tell the person to make a new bot (rare). |
| Check group | `getChat(chat_id)` | `is_forum` must be true (Topics on), title. |
| Check rights | `getChatMember(chat_id, bot_id)` | `status == "administrator"` and `can_manage_topics == true`. |
| Hello message | `sendMessage(chat_id, text)` | Proves posting works (General topic). |
| Make topic | `createForumTopic(chat_id, name)` | Returns `message_thread_id`, `name`, `icon_color`. Saved in `topics`. |

Group id changes: a basic group becomes a supergroup when Topics is turned on, and its id changes. Any call on the old id fails with 400 and `parameters.migrate_to_chat_id`; the client then saves the new id and retries once.

### Send calls
All are multipart `POST` with the file streamed from disk (never loaded into memory). Common fields: `chat_id`, `message_thread_id` (omit for General), `caption`, `disable_notification=true` (the person's own phone should not buzz for every photo).
| `sendAs` | Method | Extra fields | What we read back |
|---|---|---|---|
| `PHOTO` | `sendPhoto` | `photo` | `photo[]` (sizes). Largest = last item: `width`, `height`, `file_size`, `file_unique_id`. |
| `VIDEO` | `sendVideo` | `video`, `width`, `height`, `duration` (s), `supports_streaming=true` | `video.width/height/duration/file_size/file_unique_id/mime_type` |
| `DOCUMENT` | `sendDocument` | `document`, `disable_content_type_detection=true` | `document.file_size/file_unique_id/file_name/mime_type` |

- Multipart file names with non-ASCII characters are sent with RFC 5987 `filename*` (OkHttp handles it via `MultipartBody.Part.createFormData`; covered by a test with a unicode name) **(M1: check Telegram shows the name right)**.
- Progress: a counting `RequestBody` wrapper reports bytes written.
- Timeouts: connect 15 s, write 60 s per chunk without progress, read 120 s after the body is sent (Telegram processes video after upload).

### Reply checks (the "verified" step)
`Verifier.checkReply(job, local, sent)` returns `Ok` or `Mismatch(reason)`:
| `sendAs` | Must hold |
|---|---|
| `DOCUMENT` | `sent.size == local.sizeBytes`. |
| `VIDEO` | duration within 1 s; width/height equal (or swapped for rotated videos). If the bot reply's `file_size` equals the local size, note it (it means no recompression) **(M1)**. |
| `PHOTO` | Telegram makes photos smaller, so sizes never match. Check the aspect ratio of the largest size is within 1% of the original, and its long side >= min(original long side, 1280) **(M1: record the actual long side)**. |
And for all: `sent.chatId == job.chatId`, `sent.threadId == job.threadId` (null for General), `messageId > 0`.

### Errors
`TgError` is a sealed class. The upload loop acts on its kind, not on text.
| Telegram says | `TgError` | Counts as attempt? | What happens |
|---|---|---|---|
| 429, `parameters.retry_after = N` | `FloodWait(N)` | No | Whole sender pauses N s (+1). File back to `QUEUED` with `nextAttemptAt = now + N`. |
| 413 Request Entity Too Large | `TooLarge` | No | Re-route: send by account (if not already) else `SKIPPED`. |
| 400 `message thread not found` | `TopicMissing` | No | Topic marked `missing`, rule paused for upload, attention notification "Topic gone". |
| 400 with `migrate_to_chat_id` | `ChatMigrated(newId)` | No | Save new id, retry once. |
| 400 other (wrong file, bad caption) | `BadRequest(desc)` | Yes | Backoff; after max attempts `SKIPPED` with desc. |
| 401 Unauthorized | `BadToken` | No | Stop all bot sends, attention "Bot problem", Home warning. |
| 403 bot was kicked / not a member / not enough rights | `Forbidden(desc)` | No | Stop bot sends, attention "Bot removed". |
| 5xx | `Server(code)` | After 3 in a row | Backoff. |
| IO error, timeout, no network | `Network` | No | Back to `QUEUED`; the worker checks the network and stops if it is gone. |

### Pace
- `Pacer`: a token bucket per chat, `upload.botPacePerMinute` (15) tokens per minute, burst 3. Telegram's documented limit is about 20 messages per minute into one group, so 15 leaves room.
- One send at a time. No parallel bot sends in v1.
- A `FloodWait` blocks the bucket for its whole duration, for every route.

## 3. Account (TDLib)

TDLib is Telegram's official client library (C++ with a Java/JNI layer, `org.drinkless.tdlib`). It handles login, big uploads, resuming uploads and most flood-waits. It runs inside the core in its own thread; `TdClient.kt` wraps it with coroutines.

### Getting TDLib into the app (decided in M1)
- **Option A: prebuilt.** A maintained Android AAR/Maven artifact of TDLib with `libtdjni.so` for `arm64-v8a` (and `armeabi-v7a` if a family phone needs it). Check: recent (matches a TDLib release from the last 6 months), licence (TDLib is BSL-1.0), and that it ships the `TdApi` Java classes.
- **Option B: build ourselves.** TDLib's repo has `example/android` with a build script for all ABIs. Needs the NDK, CMake, gperf, a few GB of disk and RAM; takes about an hour once. Output (`.so` files + `TdApi.java`) goes in `app/android/tdlib/` as a local module, and the build steps are written down in `docs/SETUP.md`.
- Pick A if a good artifact exists; else B. Pin the exact TDLib version in `docs/M1_FINDINGS.md`.

### Parameters
`setTdlibParameters`: `use_test_dc=false`, `database_directory = no_backup/tdlib/db`, `files_directory = no_backup/tdlib/files`, `database_encryption_key` from `SecretStore`, `use_file_database=true`, `use_chat_info_database=true`, `use_message_database=false` (we do not need history), `use_secret_chats=false`, `api_id`, `api_hash`, `system_language_code="en"`, `device_model=Build.MODEL`, `application_version` = app version. `setLogVerbosityLevel(1)` and TDLib's log file off in release (its logs can hold personal data).

### Login states -> UI steps (S-LOGIN)
| TDLib `AuthorizationState` | UI |
|---|---|
| `WaitTdlibParameters` | core sends parameters (needs api_id/api_hash from step 1) |
| `WaitPhoneNumber` | step 2: phone number -> `setAuthenticationPhoneNumber` |
| `WaitCode` | step 3: code -> `checkAuthenticationCode`. `code_info` says where it was sent. |
| `WaitEmailAddress` / `WaitEmailCode` | shown as "Telegram asks for an email. Finish login in the Telegram app first." (rare; **M1** check) |
| `WaitPassword` | step 4: 2FA password -> `checkAuthenticationPassword`, show `password_hint` |
| `Ready` | done. `getMe` -> `account.displayName`. `account.state = READY`. |
| `LoggingOut` / `Closed` after `Ready`, or `WaitPhoneNumber` after `Ready` | session ended -> `account.state = EXPIRED`, attention notification "Telegram account logged out" |

The core keeps one TDLib client alive only while it is needed (login, an account upload, a strong check), then closes it, so it does not run all day. Re-opening with the saved database needs no code again.

### Account sends
`sendMessage(chat_id, <topic>, input_message_content, options)`:
- `<topic>`: the forum topic to post in. Older TDLib names this `message_thread_id` (TDLib form of the thread id), newer TDLib uses a `topic_id` object. Use whatever the pinned version has **(M1)**.
- `DOCUMENT`: `inputMessageDocument(inputFileLocal(path), thumbnail=null, disable_content_type_detection=true, caption)`.
- `VIDEO`: `inputMessageVideo(inputFileLocal(path), thumbnail=null, duration, width, height, supports_streaming=true, caption)`.
- `PHOTO` via account is not used (photos under 50 MB always go by bot).
- `sendMessage` returns a temporary message at once. The real result arrives as an update: `updateMessageSendSucceeded(message, old_message_id)` or `updateMessageSendFailed(message, old_message_id, error)`. `TdClient` waits for the update matching `old_message_id`.
- Progress comes from `updateFile` (`remote.uploaded_size` of the file being sent).
- Cancel (pause is not used mid-file, but a stop is): `deleteMessages` on the temporary message cancels the upload.

### Id forms
TDLib message ids are Bot API ids shifted left by 20 bits (`tdlibId = botApiId * 1048576`) for messages in supergroups **(M1: confirm)**. Chat ids for supergroups are the same `-100...` number in both. The database always stores Bot API form; `TdIds.kt` converts.

### Strong check before delete
`AccountVerifier.recheck(file)`: `getMessage(tgChatId, toTdlib(tgMessageId))`, then the same content checks as the reply checks (document size, video duration/size). Result `Ok`, `Mismatch`, `NotFound` (message deleted in Telegram -> never delete; file goes back to `QUEUED` to upload again) or `Unavailable` (account not ready / offline -> deny this time, try at the next clean). **(M1: the account can fetch a message the bot posted, in a group where the account is a member.)**

### Errors (TDLib)
| TDLib error | Meaning | Action |
|---|---|---|
| 429 / `FLOOD_WAIT_N` / "Too Many Requests: retry after N" | rate limit | `FloodWait(N)` as for bots |
| 401 / `AUTH_KEY_UNREGISTERED`, `SESSION_REVOKED`, `USER_DEACTIVATED` | logged out | `account.state = EXPIRED` |
| 400 `CHAT_WRITE_FORBIDDEN`, `TOPIC_CLOSED`, `TOPIC_DELETED` | can't post | as for bots (Forbidden / TopicMissing) |
| 400 `FILE_PARTS_INVALID`, `FILE_PART_*_MISSING` | upload broke | retry (counts as attempt) |
| network | | as for bots |

## 4. Captions
```
IMG_20261101_093012.jpg
1 Nov 2026 09:30 · Gallery photos
#tb a1b2c3d4e5f6
```
- Line 1: original file name. Line 2: taken date (phone's time zone) and rule name. Line 3: `#tb` + first 12 hex chars of SHA-256 (a hashtag, so Telegram search finds it).
- Max 1024 characters: the file name is cut in the middle with "..." if needed. Test with a 300-character name.
- Plain text, no Markdown parse mode, so names with `_` or `*` are safe.

## 5. Links
- Message: `https://t.me/c/<internal>/<messageId>` where `<internal>` is the chat id without the `-100` prefix. Opens in the Telegram app for members of the group.
- Topic: `https://t.me/c/<internal>/<threadId>`.

## 6. Duplicates after a crash
If the app dies after Telegram accepted a file but before the database saved the message id, the file is still `UPLOADING` at the next start and is sent again. That makes a duplicate message in Telegram, never a loss. The `#tb` hash makes duplicates easy to spot. v1 does not try to find and remove them.

## 7. What Telegram sees
Only the files the rules pick, their names, dates and the rule name in captions. Nothing else from the phone. The bot token and account session never leave the phone except to talk to Telegram itself.
