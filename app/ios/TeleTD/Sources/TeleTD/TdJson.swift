import Foundation
import TDLibFramework

/// A very small client for TDLib's JSON interface. One receive thread for the whole process (td_receive must not be called from two threads).
final class TdJson {
    static let shared = TdJson()
    typealias Update = ([String: Any]) -> Void

    private let lock = NSLock()
    private var waiters: [String: CheckedContinuation<[String: Any], Never>] = [:]
    private var handlers: [Int32: Update] = [:]
    private var counter: UInt64 = 0
    private var started = false

    private init() {
        // TDLib's own log can hold personal data: keep it off.
        _ = td_execute("{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":0}")
    }

    func createClient(onUpdate: @escaping Update) -> Int32 {
        let id = td_create_client_id()
        lock.lock(); handlers[id] = onUpdate; lock.unlock()
        startReceiving()
        send(id, ["@type": "getOption", "name": "version"])   // wakes the client up
        return id
    }

    func removeClient(_ id: Int32) { lock.lock(); handlers[id] = nil; lock.unlock() }

    func send(_ client: Int32, _ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        td_send(client, s)
    }

    /// Sends a request and waits for its answer (an object, or `{"@type":"error",...}`).
    func request(_ client: Int32, _ obj: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { cont in
            lock.lock(); counter += 1; let key = "r\(counter)"; waiters[key] = cont; lock.unlock()
            var o = obj; o["@extra"] = key
            send(client, o)
        }
    }

    private func startReceiving() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        let t = Thread { [weak self] in
            while let self = self {
                guard let c = td_receive(10) else { continue }
                let text = String(cString: c)
                guard let data = text.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                self.dispatch(obj)
            }
        }
        t.name = "tdlib.receive"; t.qualityOfService = .utility; t.start()
    }

    private func dispatch(_ obj: [String: Any]) {
        if let extra = obj["@extra"] as? String {
            lock.lock(); let w = waiters.removeValue(forKey: extra); lock.unlock()
            w?.resume(returning: obj); return
        }
        let id = (obj["@client_id"] as? NSNumber)?.int32Value ?? 0
        lock.lock(); let h = handlers[id]; lock.unlock()
        h?(obj)
    }
}
