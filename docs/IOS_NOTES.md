# iOS: what a version could and could not do

Not planned for version 1. Written so the owner can decide later.

## What iOS cannot do
- **Run a long background upload.** iOS gives short background windows (BGProcessingTask, usually when charging and on Wi-Fi), not a foreground service. A 1 GB video may need several windows.
- **Delete photos silently.** Deleting from the photo library shows a system confirmation every time. "Upload and delete" cannot be hands-free.
- **Read arbitrary folders.** Only the photo library (and files the person picks), no WhatsApp or screenshot folders by path.

## What it could do
- Upload new photos and videos from the library to the same Telegram group, when iOS grants a window, using the same Bot API and the same rules model.
- Show the same Home, Rules and History screens (the Flutter UI is shared). The Kotlin core would need a Swift twin: scanner (PhotoKit), uploader (URLSession background uploads), database, delete gate.
- Keep "upload only" mode as the default and the only mode that works well.

## Sizing
A reduced "upload only" iOS app is a project of its own (core rewrite in Swift, background-task tuning, Apple developer account and TestFlight for distribution, since sideloading is not practical). Decide after the Android version has run in the family for a few months.
