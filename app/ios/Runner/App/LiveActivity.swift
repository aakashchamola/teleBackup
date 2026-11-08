import Foundation
import UIKit
import ActivityKit

/// Dynamic Island and lock-screen counter ("412 / 1830"). It starts while the app is open and keeps updating whenever the app
/// runs, including the moments iOS wakes it because the system finished uploading files in the background.
final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<BackupAttributes>?
    private var last = Date.distantPast
    private var lastState: BackupAttributes.ContentState?

    /// `busy`: a run is going, or the system is still uploading files for us.
    func sync(done: Int, total: Int, current: String, busy: Bool, waiting: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity == nil { activity = Activity<BackupAttributes>.activities.first }   // after a relaunch
        let state = BackupAttributes.ContentState(done: done, total: total, current: current, waiting: waiting)
        guard total > 0, done < total, busy else { end(final: state, finished: total > 0 && done >= total); return }
        if state == lastState { return }
        if Date().timeIntervalSince(last) < 2 { return }   // iOS limits how often an activity may change
        last = Date(); lastState = state
        if let a = activity {
            Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
        } else if UIApplication.shared.applicationState == .active {   // iOS only lets an app start one while it is open
            do { activity = try Activity.request(attributes: BackupAttributes(title: "teleBackup"), content: ActivityContent(state: state, staleDate: nil)) }
            catch { activity = nil }
        }
    }

    private func end(final: BackupAttributes.ContentState, finished: Bool) {
        guard let a = activity else { return }
        activity = nil; lastState = nil
        var s = final; if finished { s.current = "Backup complete" }
        Task { await a.end(ActivityContent(state: s, staleDate: nil), dismissalPolicy: finished ? .after(Date().addingTimeInterval(60)) : .immediate) }
    }
}
