import Foundation

/// When the app should next wake by itself (a background task is asked for this time).
public enum WakePlanner {
    public static let dailyMs = Time.day

    /// The earliest of: a failed file's retry time, the end of a delay, the next daily check. Never in the past.
    public static func nextWake(store: Store, settings: Settings, now: Int64) -> Int64 {
        var times: [Int64] = [(settings.lastScanAt ?? now) + dailyMs]
        if let r = store.earliestRetryAt() { times.append(r) }
        if settings.controlState == .delayed, let d = settings.delayedUntil { times.append(d) }
        return max(now + 60_000, times.min() ?? now + dailyMs)
    }
}

public extension ControlService {
    /// The delay timer ran out: go back to running. Does nothing if the person already resumed or paused again.
    @discardableResult
    func resumeIfDelayExpired() -> Bool {
        guard settings.controlState == .delayed, (settings.delayedUntil ?? Int64.max) <= clock.now() + Time.minute else { return false }
        resume(); return true
    }
}
