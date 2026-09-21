// 「戻りうる全状態に受け手がいる」の不変条件（T-18 §6.11。SM-07。voicedock test_part_resume :129-150）。
import Testing
import VDCore

@testable import VDPipeline

@Suite("StateHandler")
struct StateHandlerTests {
    static let handled = PartStates.normalizable.union(PartStates.transcribable).union(PartStates.rawWritable)

    @Test("SM-07 FAILED の戻り先すべてに受け手がいる")
    func everyResumeTargetHasAHandler() {
        #expect(!PartStates.retryableFromFailed.isEmpty)
        #expect(PartStates.retryableFromFailed.isSubset(of: Self.handled))
    }

    @Test("SM-07 復旧の戻り先に受け手がいる")
    func everyRecoveryTargetHasAHandler() {
        let targets = TransitionTable.partRecovery.map(\.to).filter { $0 != .sourceDeletePending }
        #expect(!targets.isEmpty)
        for to in targets {
            #expect(Self.handled.contains(to))
        }
    }

    @Test("工程の入口は重ならない")
    func stageEntriesDoNotOverlap() {
        #expect(PartStates.normalizable.isDisjoint(with: PartStates.transcribable))
        #expect(PartStates.normalizable.isDisjoint(with: PartStates.rawWritable))
        #expect(PartStates.transcribable.isDisjoint(with: PartStates.rawWritable))
    }
}
