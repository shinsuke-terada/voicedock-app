// LLM 受け入れ試験: 350,000 文字の Map-Reduce（PLAN §10.6 の 4。T-24 §5.2）。VOICEDOCK_LLM_MODEL が無ければ走らない。
import Foundation
import TestSupport
import Testing
import VDCore
import VDLLM

@Suite("350,000 文字の Map-Reduce", .serialized)
struct LongTranscriptAcceptanceTests {
    @Test(
        "350,000 文字が 30 分以内（§10.6-4）", .enabled(if: TestEnvironment.llmModel != nil), .tags(.realTools, .slow))
    func longDayFitsIn30Minutes() async throws {
        // llama-server の起動は 10 本の試験と共有する（1 回だけ）
        let shared = await AnalysisAcceptanceTests.runs.value
        let session = try #require(shared)
        guard case .success(let list) = session.runs else {
            Issue.record("受け入れ試験を走らせられません: \(session.runs)")
            return
        }
        let long = try #require(list.first { $0.fixtureID == AcceptanceFixture.longID })
        let verdict = AcceptanceJudge.judge(list, longID: AcceptanceFixture.longID)
        #expect(verdict.longSeconds <= 1_800)
        guard case .success(_, _, let chunks, _) = long.outcome else {
            Issue.record("長文の解析が失敗しました: \(long.outcome)")
            return
        }
        // Map-Reduce に入っている
        #expect(chunks.count >= 2)
    }
}
