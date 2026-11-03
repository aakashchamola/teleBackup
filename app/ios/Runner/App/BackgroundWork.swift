import Foundation
import BackgroundTasks
import UIKit
import TeleCore

/// What iOS lets a backup app do in the background (no foreground service exists on iPhone):
/// - a processing task (usually overnight, on power and Wi-Fi) that scans, uploads and prepares the delete list;
/// - a short refresh task that scans and starts the queue;
/// - extra time (~30 s) when the app is sent to the background in the middle of a file.
enum BackgroundWork {
    static let processId = "com.aakashchamola.telebackup.process"
    static let refreshId = "com.aakashchamola.telebackup.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processId, using: nil) { task in handle(task as! BGProcessingTask) }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshId, using: nil) { task in handle(task as! BGAppRefreshTask) }
    }

    /// Asks iOS to wake the app at the next time something is due: a failed file's retry, the end of a delay, or the daily check.
    /// iOS decides the exact moment (usually when the phone is idle, on Wi-Fi or charging); it never runs earlier than asked.
    static func schedule() {
        let rt = Runtime.shared
        guard rt.settings.setupDone else { return }
        let at = WakePlanner.nextWake(store: rt.store, settings: rt.settings, now: rt.clock.now())
        let date = Date(timeIntervalSince1970: Double(at) / 1000)
        let sooner = min(date, Date(timeIntervalSinceNow: 30 * 60))
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processId)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshId)
        let p = BGProcessingTaskRequest(identifier: processId)
        p.requiresNetworkConnectivity = true; p.requiresExternalPower = false
        p.earliestBeginDate = date
        try? BGTaskScheduler.shared.submit(p)
        let r = BGAppRefreshTaskRequest(identifier: refreshId)
        r.earliestBeginDate = sooner
        try? BGTaskScheduler.shared.submit(r)
    }

    private static func handle(_ task: BGTask) {
        let rt = Runtime.shared
        schedule()   // always line up the next window first
        let work = Task {
            if !rt.isRunning { await rt.performRun(scan: true) }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { rt.cancelRun(); work.cancel() }   // the file in flight goes back to the queue
    }
}
