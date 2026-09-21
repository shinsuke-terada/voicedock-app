// 状態・遷移・復旧写像・エラーコードが docs/SPEC.md の表と一致することの検査（PLAN §10.3。T-08）。
import TestSupport
import Testing

@testable import VDCore

@Suite("SpecSyncStates")
struct SpecSyncStatesTests {
    @Test("Part の状態の宣言順が SPEC と同じ")
    func partStatesMatchSpec() throws {
        #expect(try PartStatus.allCases.map(\.rawValue) == SpecDocument.load().stateNames(.part))
    }

    @Test("Session の状態の宣言順が SPEC と同じ")
    func sessionStatesMatchSpec() throws {
        #expect(try SessionStatus.allCases.map(\.rawValue) == SpecDocument.load().stateNames(.session))
    }

    @Test("Part の遷移表が SPEC と同じ（辺の集合）")
    func partTransitionsMatchSpec() throws {
        let implemented = Set(TransitionTable.part.map { SpecEdge(from: $0.from.rawValue, to: $0.to.rawValue) })
        #expect(try implemented == Set(SpecDocument.load().transitionEdges(.part)))
    }

    @Test("Session の遷移表が SPEC と同じ（辺の集合）")
    func sessionTransitionsMatchSpec() throws {
        let implemented = Set(TransitionTable.session.map { SpecEdge(from: $0.from.rawValue, to: $0.to.rawValue) })
        #expect(try implemented == Set(SpecDocument.load().transitionEdges(.session)))
    }

    @Test("Part の復旧写像が SPEC と同じ（順も）")
    func partRecoveryMatchesSpec() throws {
        let implemented = TransitionTable.partRecovery.map { SpecEdge(from: $0.from.rawValue, to: $0.to.rawValue) }
        #expect(try implemented == SpecDocument.load().recoveryEdges(.part))
    }

    @Test("Session の復旧写像が SPEC と同じ（順も）")
    func sessionRecoveryMatchesSpec() throws {
        let implemented = TransitionTable.sessionRecovery.map { SpecEdge(from: $0.from.rawValue, to: $0.to.rawValue) }
        #expect(try implemented == SpecDocument.load().recoveryEdges(.session))
    }

    @Test("エラーコードの宣言順と再試行が SPEC と同じ")
    func errorCodesMatchSpec() throws {
        let rows = try SpecDocument.load().errorCodes()
        #expect(ErrorCode.allCases.map(\.rawValue) == rows.map(\.code))
        for row in rows {
            let code = try #require(ErrorCode(rawValue: row.code))
            #expect(String(describing: code.retryPolicy) == row.retry, "\(row.code)")
        }
    }
}
