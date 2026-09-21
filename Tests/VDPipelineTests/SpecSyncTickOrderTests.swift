// tick の順の逐語の照合（T-18 §6.12・§9）。
// docs/SPEC.md は tools/spec/make-spec.py が PLAN の決まった節から作る生成物で、PLAN に tick の順のブロックが無いため
// 「Worker の tick の順」の節を足せない（T-17 §9 と同じ事情。GitHub issue #18）。当面は §9 のブロックを固定値で照合する。
import Testing

@testable import VDPipeline

@Suite("SpecSyncTickOrder")
struct SpecSyncTickOrderTests {
    /// T-18 §9 の `text` ブロック（逐語）。
    static let block = """
        manualRequeue groupNewParts requeueRecopied closeIdleSessions processPendingParts refreshVaultIndex \
        processReadySessions collectDeleteResults expireDeleteRequests evaluateDeletions settleSkippedDeletions \
        runReaperIfNeeded pendingJobs requeueOnConnect
        """

    @Test("tick の順がチケット §9 のブロックと一致")
    func tickOrderIsVerbatim() {
        let words = Self.block.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        #expect(words.count == 14)
        #expect(TickStage.allCases.map(\.rawValue) == words)
    }
}
