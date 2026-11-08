import Foundation
import UIKit
import ActivityKit
import UserNotifications
import TeleCore

/// All notifications, the same set as on Android (docs/UI.md section 8):
/// progress with Pause, "Paused" with Delay / Resume, "Paused until", things only the person can fix, and "Check before deleting".
/// iPhone has no foreground service, so progress is shown only while the app is in the background; the Home screen shows it otherwise.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, ReviewNotifier {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private var lastProgress = Date.distantPast
    static let progressId = "tb.progress", controlId = "tb.control", expiryId = "tb.expiry", attentionPrefix = "tb.attention.", reviewPrefix = "tb.review."
    private static let attentionKinds: [AttentionKind] = [.loginExpired, .allFilesLost, .botProblem, .topicMissing]

    // MARK: setup

    func setup() {
        center.delegate = self
        registerCategories()
    }

    /// Delay buttons come from the settings, so this is called again when they change.
    func registerCategories() {
        let rt = Runtime.shared
        func delayTitle(_ m: Int) -> String { "Delay " + Self.delayLabel(m) }
        let pause = UNNotificationAction(identifier: "pause", title: "Pause", options: [])
        let delays = rt.settings.delayOptionsMinutes.prefix(2).enumerated().map { UNNotificationAction(identifier: "delay\($0.offset)", title: delayTitle($0.element), options: []) }
        let resume = UNNotificationAction(identifier: "resume", title: "Resume", options: [])
        let resumeNow = UNNotificationAction(identifier: "resume", title: "Resume now", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "running", actions: [pause], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "paused", actions: delays + [resume], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "delayed", actions: [resumeNow], intentIdentifiers: [], options: []),
        ])
    }

    func requestAuthorization() async -> Bool { (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false }

    // MARK: formats

    static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func delayLabel(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60)h" : "\(m)m" }
    static func clock(_ ms: Int64) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func post(_ id: String, title: String, body: String, category: String? = nil, route: String? = nil, sound: Bool = false, passive: Bool = false) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if let cat = category { c.categoryIdentifier = cat }
        if let r = route { c.userInfo = ["route": r] }
        if sound { c.sound = .default }
        if passive { c.interruptionLevel = .passive }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // MARK: progress

    /// Nothing while the Dynamic Island / lock-screen counter is running, and never one per image.
    /// Without a Live Activity (switched off in Settings) there is a single "Backing up" notification per run, with no per-file updates.
    func progress(_ t: RunTracker) {
        guard t.running else { shownForRun = false; clearProgress(); return }
        if !Activity<BackupAttributes>.activities.isEmpty { if shownForRun { clearProgress() }; shownForRun = false; return }
        guard !shownForRun, UIApplication.shared.applicationState != .active else { return }
        shownForRun = true
        post(Self.progressId, title: "teleBackup · Backing up", body: "Your photos and videos are being sent to Telegram.", category: "running", route: "home", passive: true)
    }
    private var shownForRun = false

    func clearProgress() { center.removeDeliveredNotifications(withIdentifiers: [Self.progressId]) }

    // MARK: paused / delayed

    /// Shows Paused (with Delay and Resume buttons) or Paused until, or removes it when nothing is held.
    func showControlState() {
        let rt = Runtime.shared
        let waiting = rt.store.queueCount(now: rt.clock.now(), allowBot: true, allowAccount: rt.settings.accountState == .ready).count
        switch rt.settings.controlState {
        case .paused: post(Self.controlId, title: "teleBackup · Paused", body: "\(waiting) file\(waiting == 1 ? "" : "s") waiting", category: "paused", route: "home", passive: true)
        case .delayed: post(Self.controlId, title: "teleBackup · Paused until \(Self.clock(rt.settings.delayedUntil ?? rt.clock.now()))", body: "Resumes by itself", category: "delayed", route: "home", passive: true)
        case .running: clearControl()
        }
    }
    func clearControl() { center.removeDeliveredNotifications(withIdentifiers: [Self.controlId]) }

    // MARK: things only the person can fix

    /// Posts each problem once, and removes the notification when the problem is gone.
    func raiseAttention(_ list: [Attention]) {
        let key = "ios.raised"
        let rt = Runtime.shared
        let before = Set((rt.store.setting(key) ?? "").split(separator: ",").map(String.init))
        var now = Set<String>()
        for a in list where Self.attentionKinds.contains(a.kind) {
            let k = "\(a.kind)" + (a.ruleId.map { ":\($0)" } ?? "")
            now.insert(k)
            if before.contains(k) { continue }
            let (title, route): (String, String)
            switch a.kind {
            case .loginExpired: (title, route) = ("Telegram account logged out", "login")
            case .allFilesLost: (title, route) = ("teleBackup can't reach your photos", "perm:files")
            case .botProblem: (title, route) = ("teleBackup can't post to your group", "telegram")
            default: (title, route) = ("A topic was deleted", "rule:\(a.ruleId ?? 0)")
            }
            post(Self.attentionPrefix + k, title: title, body: a.text, route: route, sound: true)
        }
        for k in before.subtracting(now) { center.removeDeliveredNotifications(withIdentifiers: [Self.attentionPrefix + k]) }
        rt.store.put(key, now.sorted().joined(separator: ","))
    }

    // MARK: delete check

    func reviewWaiting(rule: CRule, review: ReviewRecord) {
        post(Self.reviewPrefix + String(rule.id), title: "Check before deleting",
             body: "\(rule.name): \(review.fileCount) files (\(Self.size(review.totalBytes))) are ready to delete from your phone. iPhone will ask you to confirm.",
             route: "review:\(rule.id)", sound: true)
    }
    func clearReview(ruleId: Int64) { center.removeDeliveredNotifications(withIdentifiers: [Self.reviewPrefix + String(ruleId)]) }

    /// The free Apple ID signature lasts 7 days: remind the person two days before.
    func scheduleExpiryReminder(expiresAt: Int64) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.expiryId])
        let fire = Date(timeIntervalSince1970: Double(expiresAt) / 1000 - 2 * 86400)
        guard fire > Date() else { return }
        let c = UNMutableNotificationContent()
        c.title = "teleBackup needs a refresh"; c.body = "This install runs out in 2 days. Open LocalDevVPN, tap Connect, then open SideStore and refresh teleBackup, or backups will stop."
        c.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(identifier: Self.expiryId, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    // MARK: buttons and taps

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let rt = Runtime.shared
        switch response.actionIdentifier {
        case "pause": await MainActor.run { rt.pauseNow() }
        case "delay0", "delay1":
            let i = response.actionIdentifier == "delay0" ? 0 : 1
            if let m = rt.settings.delayOptionsMinutes[safe: i] { await MainActor.run { rt.delayNow(minutes: m) } }
        case "resume": await MainActor.run { rt.resumeNow() }
        default:
            let route = response.notification.request.content.userInfo["route"] as? String ?? (response.notification.request.identifier.hasPrefix(Self.reviewPrefix) ? "home" : "home")
            await MainActor.run { rt.openRoute(route) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
