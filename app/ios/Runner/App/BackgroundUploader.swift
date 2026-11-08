import Foundation
import UIKit
import TeleCore

/// iOS's own background upload session. Files for the bot are handed to the system, which keeps sending them
/// with the screen off and wakes the app when Telegram has answered. The answer is recorded by `UploadEngine.completeBackground`.
final class BackgroundUploader: NSObject, BackgroundUploading, URLSessionDataDelegate {
    static let shared = BackgroundUploader()

    var api: BotApi?
    var allowCellular: () -> Bool = { false }
    var completionHandler: (() -> Void)?       // from AppDelegate, called when the system has delivered every event
    private var session: URLSession!
    private var received: [Int: Data] = [:]
    private let lock = NSLock()
    private let dir: URL

    private override init() {
        let fm = FileManager.default
        let base = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        dir = base.appendingPathComponent("bgupload", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        super.init()
        let c = URLSessionConfiguration.background(withIdentifier: (Bundle.main.bundleIdentifier ?? "telebackup") + ".bgupload")
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.waitsForConnectivity = true
        c.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    // MARK: BackgroundUploading

    func submit(_ job: SendJob, fileId: Int64) -> String? {
        guard let api = api, let built = try? api.buildSend(job) else { return nil }
        let dest = dir.appendingPathComponent("body-\(fileId).multipart")
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: built.bodyFile, to: dest) } catch { try? FileManager.default.removeItem(at: built.bodyFile); return nil }
        var req = built.request
        req.allowsCellularAccess = allowCellular()
        let task = session.uploadTask(with: req, fromFile: dest)
        task.taskDescription = String(fileId)
        task.resume()
        return dest.path
    }

    func activeFileIds() async -> Set<Int64> {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in cont.resume(returning: Set(tasks.compactMap { Int64($0.taskDescription ?? "") })) }
        }
    }

    // MARK: session events (also delivered after the system relaunched the app in the background)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); received[dataTask.taskIdentifier, default: Data()].append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let data = received.removeValue(forKey: task.taskIdentifier) ?? Data(); lock.unlock()
        guard let id = Int64(task.taskDescription ?? "") else { return }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        Runtime.shared.backgroundFinished(fileId: id, code: code, data: data, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in self?.completionHandler?(); self?.completionHandler = nil }
    }
}
