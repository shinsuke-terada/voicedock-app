// 判定の式の単体（モデル不要。AcceptanceRun を手で組み立て、LLM を呼ばない。T-24 §5.3）。
import Foundation
import Testing
import VDCore
import VDLLM

@Suite("AcceptanceJudge")
struct AcceptanceJudgeTests {
    static let longID = "L01-longday"

    static func result(summary: String = "朝会の要約です。", tasks: [AnalysisTask] = []) -> AnalysisResult {
        AnalysisResult(
            title: "朝会", summary: summary, keyPoints: ["要点です。"], tasks: tasks, decisions: [], ideas: [],
            tags: ["meeting"])
    }

    static func run(
        _ id: String, outcome: AnalyzeOutcome = .success(result(), partials: [], chunks: [], trimmed: []),
        calls: Int = 1, repairedCalls: Int = 0, repairs: Int = 0, seconds: Int64 = 10, maxTasksWithDue: Int = 0
    ) -> AcceptanceRun {
        AcceptanceRun(
            fixtureID: id, scalarCount: 5_000, maxTasksWithDue: maxTasksWithDue, outcome: outcome, calls: calls,
            repairedCalls: repairedCalls, repairs: repairs, elapsed: .seconds(seconds))
    }

    /// s01〜s09（本体の要求 1 つずつ）と長文（600 秒）。
    static func tenRuns(longSeconds: Int64 = 600) -> [AcceptanceRun] {
        (1...9).map { run("s0\($0)") } + [run(longID, seconds: longSeconds)]
    }

    @Test("すべて通れば合格")
    func passesWhenEverythingIsClean() {
        let verdict = AcceptanceJudge.judge(Self.tenRuns(), longID: Self.longID)
        #expect(verdict.passed)
        #expect(verdict.repairFreeRate == 1.0)
    }

    @Test("修復なしの割合がちょうど 90% なら合格")
    func rateIsExactlyAtTheThreshold() {
        var runs = Self.tenRuns()
        runs[0] = Self.run("s01", calls: 1, repairedCalls: 1, repairs: 1)
        let verdict = AcceptanceJudge.judge(runs, longID: Self.longID)
        #expect(verdict.calls == 10)
        #expect(verdict.repairFreeRate == 0.9)
        #expect(verdict.passed)
    }

    @Test("修復なしの割合が 90% を下回ると不合格")
    func justBelowTheThresholdFails() {
        // 本体 20 要求のうち 3 要求に修復
        var runs = (1...9).map { Self.run("s0\($0)", calls: 2) } + [Self.run(Self.longID, calls: 2, seconds: 600)]
        for index in 0..<3 {
            runs[index] = Self.run("s0\(index + 1)", calls: 2, repairedCalls: 1, repairs: 1)
        }
        let verdict = AcceptanceJudge.judge(runs, longID: Self.longID)
        #expect(verdict.calls == 20)
        #expect(verdict.repairFreeRate == 0.85)
        #expect(verdict.passed == false)
    }

    @Test("1 本の失敗で J1 と修復込みの割合が両方落ちる")
    func oneFailureBreaksBoth() {
        var runs = Self.tenRuns()
        runs[4] = Self.run("s05", outcome: .failure(StageFailure(.llmInvalidJSON, "修復しても検証を通りません")), calls: 1)
        let verdict = AcceptanceJudge.judge(runs, longID: Self.longID)
        #expect(verdict.analyzed == 9)
        #expect(verdict.repairedRate < 1.0)
        #expect(verdict.passed == false)
    }

    @Test("summary の `[[` を見つける")
    func wikiLinkIsFound() {
        var runs = Self.tenRuns()
        let bad = Self.result(summary: "これは [[別のノート]] です")
        runs[1] = Self.run("s02", outcome: .success(bad, partials: [], chunks: [], trimmed: []))
        let verdict = AcceptanceJudge.judge(runs, longID: Self.longID)
        #expect(verdict.wikiLinkHits.count == 1)
        #expect(verdict.passed == false)
    }

    @Test("partials の `[[` を見つける")
    func wikiLinkInPartialsIsFound() {
        var runs = Self.tenRuns()
        let partial = AnalysisResult(
            title: nil, summary: nil, keyPoints: ["[[x]]"], tasks: [], decisions: [], ideas: [], tags: [])
        runs[9] = Self.run(
            Self.longID, outcome: .success(Self.result(), partials: [partial], chunks: [], trimmed: []), seconds: 600)
        let verdict = AcceptanceJudge.judge(runs, longID: Self.longID)
        #expect(verdict.wikiLinkHits.count == 1)
        #expect(verdict.passed == false)
    }

    @Test("due の形が違えば不合格")
    func badDueFormatFails() {
        var runs = Self.tenRuns()
        let r = Self.result(tasks: [AnalysisTask(text: "資料を送る", due: "2026/09/05")])
        runs[0] = Self.run("s01", outcome: .success(r, partials: [], chunks: [], trimmed: []), maxTasksWithDue: 1)
        let verdict = AcceptanceJudge.judge(runs, longID: Self.longID)
        #expect(verdict.badDue.count == 1)
    }

    @Test("本文に日付の無い fixture で due が出れば不合格")
    func tooManyDuesFail() {
        var runs = Self.tenRuns()
        let r = Self.result(tasks: [AnalysisTask(text: "資料を送る", due: "2026-09-05")])
        runs[1] = Self.run("s02", outcome: .success(r, partials: [], chunks: [], trimmed: []), maxTasksWithDue: 0)
        let verdict = AcceptanceJudge.judge(runs, longID: Self.longID)
        #expect(verdict.badDue.count == 1)
    }

    @Test("due がすべて null なら問題なし")
    func nullDueIsFine() {
        var runs = Self.tenRuns()
        let r = Self.result(tasks: [AnalysisTask(text: "資料を送る", due: nil), AnalysisTask(text: "確認する", due: nil)])
        runs[2] = Self.run("s03", outcome: .success(r, partials: [], chunks: [], trimmed: []), maxTasksWithDue: 0)
        let verdict = AcceptanceJudge.judge(runs, longID: Self.longID)
        #expect(verdict.badDue.isEmpty)
    }

    @Test("長文が 30 分を 1 秒超えると不合格")
    func justOver30MinutesFails() {
        let verdict = AcceptanceJudge.judge(Self.tenRuns(longSeconds: 1_801), longID: Self.longID)
        #expect(verdict.passed == false)
    }

    @Test("空の結果でも落ちない（TEST-28）")
    func emptyRunsDoNotCrash() {
        let verdict = AcceptanceJudge.judge([], longID: Self.longID)
        #expect(verdict.analyzed == 0)
        #expect(verdict.repairFreeRate == 0.0)
        #expect(verdict.passed == false)
    }
}
