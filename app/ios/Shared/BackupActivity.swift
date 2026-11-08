import ActivityKit
import AppIntents
import Foundation

/// What the Dynamic Island and the lock screen show while a backup is going. Shared by the app and the widget extension.
struct BackupAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var done: Int          // files already backed up
        var total: Int         // all files of the backup (done + still to go)
        var current: String    // name of the file being sent, or a short status
        var waiting: Bool      // true when it is waiting (Wi-Fi, paused, system sending)
        var paused: Bool = false
    }
    var title: String
}

/// The app sets this when it starts; the Pause / Resume buttons of the Live Activity call it. (Intents of a Live Activity run inside the app.)
enum BackupControlHook {
    @MainActor static var handler: ((Bool) -> Void)?
}

@available(iOS 17.0, *)
struct BackupControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or resume the backup"
    @Parameter(title: "Pause") var pause: Bool
    init() {}
    init(pause: Bool) { self.pause = pause }
    func perform() async throws -> some IntentResult {
        await MainActor.run { BackupControlHook.handler?(pause) }
        return .result()
    }
}
