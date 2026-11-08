import ActivityKit
import Foundation

/// What the Dynamic Island and the lock screen show while a backup is going. Shared by the app and the widget extension.
struct BackupAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var done: Int          // files already backed up
        var total: Int         // all files of the backup (done + still to go)
        var current: String    // name of the file being sent, or a short status
        var waiting: Bool      // true when it is waiting (Wi-Fi, paused, system sending)
    }
    var title: String
}
