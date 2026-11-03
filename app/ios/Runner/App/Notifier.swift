import Foundation
import UIKit
import UserNotifications
import TeleCore

/// Local notifications: progress with Pause / Delay / Resume buttons, and "ready to delete".
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private var lastPost = Date.distantPast
    static let progressId = "tb.progress", reviewId = "tb.review", heldId = "tb.held", expiryId = "tb.expiry"

    func setup() {
        center.delegate = self
        let rt = Runtime.shared
        let opts = rt.settings.delayOptionsMinutes
        var actions = [UNNotificationAction(identifier: "pause", title: "Pause", options: [])]
        for (i, m) in opts.prefix(2).enumerated() { actions.append(UNNotificationAction(identifier: "delay\(i)", title: "Delay \(ControlService.describe(m).replacingOccurrences(of: " hours", with: "h").replacingOccurrences(of: " hour", with: "h"))", options: [])) }
        let running = UNNotificationCategory(identifier: "running", actions: actions, intentIdentifiers: [], options: [])
        let held = UNNotificationCategory(identifier: "held", actions: [UNNotificationAction(identifier: "resume", title: "Resume", options: [])], intentIdentifiers: [], options: [])
        center.setNotificationCategories([running, held])
    }

    func requestAuthorization() async -> Bool { (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false }

    func progress(_ t: RunTracker) {
        guard UIApplication.shared.applicationState != .active, Date().timeIntervalSince(lastPost) > 3 else { return }
        lastPost = Date()
        let c = UNMutableNotificationContent()
        c.title = t.pausing ? "Pausing after this file…" : "Backing up \(t.filesDone + 1) of \(max(t.filesTotal, t.filesDone + 1))"
        c.body = t.currentFileName ?? ""
        c.categoryIdentifier = "running"; c.interruptionLevel = .passive
        center.add(UNNotificationRequest(identifier: Self.progressId, content: c, trigger: nil))
    }

    func clearProgress() { center.removeDeliveredNotifications(withIdentifiers: [Self.progressId]) }

    func refreshAfterRun() {
        clearProgress()
        let rt = Runtime.shared
        let waiting = rt.store.allWaitingReviews()
        guard !waiting.isEmpty else { return }
        let n = waiting.reduce(0) { $0 + $1.fileCount }
        let bytes = waiting.reduce(Int64(0)) { $0 + $1.totalBytes }
        let c = UNMutableNotificationContent()
        c.title = "\(n) backed-up file\(n == 1 ? "" : "s") ready to delete"
        c.body = "Open teleBackup to free \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). iPhone will ask you to confirm."
        c.sound = .default
        center.add(UNNotificationRequest(identifier: Self.reviewId, content: c, trigger: nil))
    }

    func showHeld(queued: Int) {
        let c = UNMutableNotificationContent()
        c.title = "Backup is paused"; c.body = queued > 0 ? "\(queued) files are waiting." : "Nothing is waiting."; c.categoryIdentifier = "held"; c.interruptionLevel = .passive
        center.add(UNNotificationRequest(identifier: Self.heldId, content: c, trigger: nil))
    }
    func clearHeld() { center.removeDeliveredNotifications(withIdentifiers: [Self.heldId]) }

    /// The free Apple ID signature lasts 7 days: remind the person two days before.
    func scheduleExpiryReminder(expiresAt: Int64) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.expiryId])
        let fire = Date(timeIntervalSince1970: Double(expiresAt) / 1000 - 2 * 86400)
        guard fire > Date() else { return }
        let c = UNMutableNotificationContent()
        c.title = "teleBackup needs a refresh"; c.body = "This install runs out in 2 days. Open AltStore on your computer's Wi-Fi to refresh it, or backups will stop."
        c.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(identifier: Self.expiryId, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    // buttons
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let rt = Runtime.shared
        switch response.actionIdentifier {
        case "pause": rt.control.pause(); rt.tracker.pausing = rt.tracker.running; showHeld(queued: rt.store.queueCount(now: rt.clock.now(), allowBot: true, allowAccount: false).count)
        case "delay0", "delay1":
            let i = response.actionIdentifier == "delay0" ? 0 : 1
            if let m = rt.settings.delayOptionsMinutes[safe: i] { rt.control.delay(minutes: m); rt.tracker.pausing = rt.tracker.running }
        case "resume": rt.control.resume(); clearHeld(); await MainActor.run { rt.startRun() }
        default:
            if response.notification.request.identifier == Self.reviewId { try? await rt.events_?.onOpenRoute(route: "/rules") }
        }
        rt.pushStatus()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
