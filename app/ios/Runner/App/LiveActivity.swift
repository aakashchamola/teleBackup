import Foundation
import UIKit
import ActivityKit

/// Dynamic Island and lock-screen counter ("412 / 1830").
/// It stays up while files are left to back up (also when waiting for Wi-Fi or paused) and ends only when everything is done.
/// Every change is applied one at a time, in order, and the newest state is never dropped (no throttle that discards updates).
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<BackupAttributes>?
    private var wanted: Wanted?
    private var applying = false
    private var lastApplied: BackupAttributes.ContentState?

    enum Wanted { case show(BackupAttributes.ContentState), finish(BackupAttributes.ContentState), hide }

    /// `pending`: files still to back up. `status`: the line under the bar.
    func sync(done: Int, total: Int, status: String, waiting: Bool, paused: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = BackupAttributes.ContentState(done: done, total: total, current: status, waiting: waiting, paused: paused)
        if total <= 0 { wanted = .hide }
        else if done >= total { wanted = .finish(state) }
        else { wanted = .show(state) }
        drain()
    }

    private func drain() {
        guard !applying, let w = wanted else { return }
        wanted = nil; applying = true
        Task { @MainActor in
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = UIApplication.shared.beginBackgroundTask(withName: "live activity") { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
            await apply(w)
            try? await Task.sleep(nanoseconds: 700_000_000)   // gentle pacing; the newest wish is applied next, none is skipped
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
            applying = false
            drain()
        }
    }

    private func current() -> Activity<BackupAttributes>? {
        let all = Activity<BackupAttributes>.activities
        if let a = activity, all.contains(where: { $0.id == a.id }) { return a }
        activity = all.first                   // after a relaunch, or if the system ended ours
        return activity
    }

    private func apply(_ w: Wanted) async {
        switch w {
        case .show(let s):
            for extra in Activity<BackupAttributes>.activities.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }   // never two counters
            if let a = current() {
                if s == lastApplied { return }
                await a.update(ActivityContent(state: s, staleDate: Date().addingTimeInterval(10 * 60))); lastApplied = s
            } else if UIApplication.shared.applicationState == .active {   // iOS only starts one while the app is open; it is started on the next open otherwise
                activity = try? Activity.request(attributes: BackupAttributes(title: "teleBackup"), content: ActivityContent(state: s, staleDate: Date().addingTimeInterval(10 * 60)))
                lastApplied = activity == nil ? nil : s
            }
        case .finish(var s):
            guard let a = current() else { return }
            s.current = "Backup complete"
            await a.end(ActivityContent(state: s, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(120)))
            activity = nil; lastApplied = nil
        case .hide:
            for a in Activity<BackupAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
            activity = nil; lastApplied = nil
        }
    }
}
