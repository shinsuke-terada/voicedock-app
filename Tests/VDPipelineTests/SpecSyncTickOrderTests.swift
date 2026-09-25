// tick の段と docs/SPEC.md S13（PLAN §5.4 の表）の照合（T-18 §6.12・§9。SPEC 同期は issue #18 で足した。PLAN F-68）。
import TestSupport
import Testing

@testable import VDPipeline

@Suite("SpecSyncTickOrder")
struct SpecSyncTickOrderTests {
    @Test("tick の段が SPEC S13 の表と同じ順")
    func tickOrderMatchesSpec() throws {
        let stages = try SpecDocument.load().tickStages()
        #expect(!stages.isEmpty)
        #expect(TickStage.allCases.map(\.rawValue) == stages.map(\.name))
    }

    @Test("snapshot が新鮮なときだけ行う段が SPEC S13 の条件の列と同じ")
    func freshSnapshotStagesMatchSpec() throws {
        let fresh = try SpecDocument.load().tickStages().filter { $0.condition == "snapshot が新鮮" }.map(\.name)
        #expect(!fresh.isEmpty)
        #expect(Set(TickStage.requiresFreshSnapshot.map(\.rawValue)) == Set(fresh))
    }
}
