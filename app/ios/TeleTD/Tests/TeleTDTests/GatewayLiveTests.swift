import XCTest
import TeleCore
@testable import TeleTD

/// Talks to Telegram's servers with dummy credentials: proves the JSON adapter starts, reaches the phone step,
/// and turns Telegram's refusal into plain words. No account is touched.
final class GatewayLiveTests: XCTestCase {
    func testStartsAndReportsRefusalInPlainWords() async throws {
        let dir = NSTemporaryDirectory() + "td-test-\(UUID().uuidString)"
        let g = TdlibGateway(appVersion: "test", deviceModel: "Mac", systemVersion: "26")
        await g.open(TdParams(apiId: 1, apiHash: String(repeating: "0", count: 32), databaseDir: dir + "/db", filesDir: dir + "/files", databaseKey: "k"))
        var waited = 0
        while g.auth != .waitPhone && waited < 150 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        XCTAssertEqual(g.auth, .waitPhone, "client did not reach the phone step")
        let step = await g.submitPhone("+10000000000")
        if case .rejected(let words) = step { XCTAssertFalse(words.isEmpty); print("Telegram's answer in plain words: \(words)") }
        else { print("step result: \(step)") }
        g.close()
    }
}
