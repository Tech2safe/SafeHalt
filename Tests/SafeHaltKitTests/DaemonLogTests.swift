import Foundation
import Testing
@testable import SafeHaltKit

struct DaemonLogTests {
    @Test func lineHasLocalTimestampAndTag() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let d = Date(timeIntervalSince1970: 1_794_183_680)   // 2026-11-09 08:21:20 +0800
        #expect(DaemonLog.line("启动", at: d, timeZone: tz) == "2026-11-09 08:21:20 [safehalt] 启动\n")
    }
}
