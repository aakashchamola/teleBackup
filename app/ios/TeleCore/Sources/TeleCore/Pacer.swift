import Foundation

/// Keeps us under Telegram's limits. Bot: token bucket (15 a minute, burst 3). Account: minimum gap.
public final class Pacer {
    private let clock: Clock
    private let botPerMinute: Int
    private let burst: Int
    private let accountMinGapMs: Int64
    private var tokens: Double
    private var lastRefill: Int64
    private var lastAccountStart: Int64 = Int64.min / 2
    private var blockedUntil: Int64 = 0
    private var routeBlockedUntil: [Route: Int64] = [:]
    private let lock = NSLock()

    public init(clock: Clock, botPerMinute: Int = 15, burst: Int = 3, accountMinGapMs: Int64 = 10_000) {
        self.clock = clock; self.botPerMinute = botPerMinute; self.burst = burst; self.accountMinGapMs = accountMinGapMs
        tokens = Double(burst); lastRefill = clock.now()
    }

    public func blockAll(until: Int64) { lock.lock(); blockedUntil = max(blockedUntil, until); lock.unlock() }
    public func blockRoute(_ r: Route, until: Int64) { lock.lock(); routeBlockedUntil[r] = max(routeBlockedUntil[r] ?? 0, until); lock.unlock() }

    /// Takes a slot and returns how long to wait first, in milliseconds (0 = go now).
    public func reserve(_ route: Route) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        let perMs = Double(botPerMinute) / 60_000.0
        tokens = min(Double(burst), tokens + Double(now - lastRefill) * perMs); lastRefill = now
        var wait = max(0, blockedUntil - now, (routeBlockedUntil[route] ?? 0) - now)
        switch route {
        case .bot:
            if tokens < 1 { wait = max(wait, Int64(ceil((1 - tokens) / perMs))) }
            tokens -= 1
        case .account:
            let next = lastAccountStart + accountMinGapMs
            wait = max(wait, next - now)
            lastAccountStart = now + wait
        }
        return wait
    }

    public func awaitSlot(_ route: Route) async {
        let w = reserve(route)
        if w > 0 { try? await Task.sleep(nanoseconds: UInt64(w) * 1_000_000) }
    }
}
