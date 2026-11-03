import Foundation
import BackgroundTasks
import UIKit

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

    static func schedule() {
        let p = BGProcessingTaskRequest(identifier: processId)
        p.requiresNetworkConnectivity = true; p.requiresExternalPower = false
        p.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(p)
        let r = BGAppRefreshTaskRequest(identifier: refreshId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    private static func handle(_ task: BGTask) {
        schedule()   // always line up the next window first
        let rt = Runtime.shared
        let work = Task {
            if !rt.isRunning { await rt.performRun(scan: true) }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { rt.cancelRun(); work.cancel() }   // the file in flight goes back to the queue
    }
}
