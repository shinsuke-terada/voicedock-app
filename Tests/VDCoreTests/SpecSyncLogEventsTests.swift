// LogEvent の登録順が docs/SPEC.md の S4 と一致することの検査（PLAN §10.3。T-10）。
import TestSupport
import Testing

@testable import VDCore

@Suite("SpecSyncLogEvents")
struct SpecSyncLogEventsTests {
    @Test("LogEvent の宣言順が SPEC と同じ")
    func logEventsMatchSpec() throws {
        #expect(try LogEvent.allCases.map(\.rawValue) == SpecDocument.load().logEvents())
    }
}
