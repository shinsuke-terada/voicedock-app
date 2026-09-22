// LLM 受け入れ試験: 10 本の transcript（PLAN §10.6 の 1〜3・5。T-24 §5.1）。VOICEDOCK_LLM_MODEL が無ければ走らない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDLLM

/// 受け入れ試験 1 回分の結果（llama-server の起動は 1 回だけ。2 つのスイートが共有する）。
struct AcceptanceSession: Sendable {
    let modelID: String
    let runs: Result<[AcceptanceRun], AcceptanceError>

    /// 判定（runs が失敗なら nil）。
    var verdict: AcceptanceVerdict? {
        guard case .success(let list) = runs else { return nil }
        return AcceptanceJudge.judge(list, longID: AcceptanceFixture.longID)
    }

    /// 試験に流す fixture（§4.3）。指定のディレクトリの *.json を id の昇順に読み、9 本に満たなければ合成の fixture で埋め、
    /// 最後に長文を足す（10 本）。
    static func fixtures() -> Result<[AcceptanceFixture], AcceptanceError> {
        let synthetic = PackageRoot.url.appendingPathComponent("Tests/Fixtures/llm-acceptance", isDirectory: true)
        var base: [AcceptanceFixture]
        switch AcceptanceFixture.loadAll(directory: TestEnvironment.llmFixtureDirectory) {
        case .failure(let message): return .failure(message)
        case .success(let loaded): base = loaded
        }
        if base.count < AnalysisAcceptanceTests.baseCount {
            switch AcceptanceFixture.loadAll(directory: synthetic) {
            case .failure(let message): return .failure(message)
            case .success(let fill):
                for fixture in fill where base.count < AnalysisAcceptanceTests.baseCount {
                    if !base.contains(where: { $0.id == fixture.id }) { base.append(fixture) }
                }
            }
        }
        return .success(base + [AcceptanceFixture.longDay(base)])
    }

    static func make() async -> AcceptanceSession? {
        guard let modelID = TestEnvironment.llmModel else { return nil }
        switch fixtures() {
        case .failure(let message): return AcceptanceSession(modelID: modelID, runs: .failure(message))
        case .success(let list):
            return AcceptanceSession(
                modelID: modelID, runs: await AcceptanceHarness.run(modelID: modelID, fixtures: list))
        }
    }
}

@Suite("LLM 受け入れ試験", .serialized)
struct AnalysisAcceptanceTests {
    /// 長文を除いた本数（合成の 9 本）。
    static let baseCount = 9
    /// スイート全体で llama-server を 1 回だけ起動する（最初に触れたときに 1 回だけ作る）。
    static let runs = Task<AcceptanceSession?, Never> { await AcceptanceSession.make() }

    let session: AcceptanceSession?

    init() async {
        session = await Self.runs.value
    }

    /// 判定。試験が走らなかったら記録して nil。
    private func verdict() -> AcceptanceVerdict? {
        guard let session else {
            Issue.record("VOICEDOCK_LLM_MODEL がありません")
            return nil
        }
        if case .failure(let message) = session.runs {
            Issue.record("受け入れ試験を走らせられません: \(message)")
            return nil
        }
        return session.verdict
    }

    @Test(
        "10 本すべてが解析できる（§10.6-1）", .enabled(if: TestEnvironment.llmModel != nil), .tags(.realTools, .slow))
    func allFixturesAreAnalyzed() {
        guard let verdict = verdict(), case .success(let list)? = session?.runs else { return }
        let failed = list.compactMap { run -> String? in
            guard case .failure(let failure) = run.outcome else { return nil }
            return "\(run.fixtureID): \(failure.message)"
        }
        #expect(verdict.analyzed == verdict.total, "\(failed)")
    }

    @Test("修復なしで 90% 以上（§10.6-2）", .enabled(if: TestEnvironment.llmModel != nil), .tags(.realTools, .slow))
    func repairFreeRateIsAtLeast90() {
        guard let verdict = verdict() else { return }
        #expect(verdict.repairFreeRate >= 0.90)
    }

    @Test("修復込みで 100%（§10.6-2）", .enabled(if: TestEnvironment.llmModel != nil), .tags(.realTools, .slow))
    func everyCallEventuallyValidates() {
        guard let verdict = verdict() else { return }
        #expect(verdict.repairedRate == 1.0)
    }

    @Test("出力に `[[` が無い（§10.6-3）", .enabled(if: TestEnvironment.llmModel != nil), .tags(.realTools, .slow))
    func noWikiLinksInOutput() {
        guard let verdict = verdict() else { return }
        #expect(verdict.wikiLinkHits.isEmpty, "\(verdict.wikiLinkHits)")
    }

    @Test(
        "期限の無い task の due は null（§10.6-3）", .enabled(if: TestEnvironment.llmModel != nil),
        .tags(.realTools, .slow))
    func dueIsNullWithoutADate() {
        guard let verdict = verdict() else { return }
        #expect(verdict.badDue.isEmpty, "\(verdict.badDue)")
    }

    /// .serialized の最後に走らせる（Swift Testing は宣言の順に走らせる）。
    @Test("報告を書き出す", .enabled(if: TestEnvironment.llmModel != nil), .tags(.realTools, .slow))
    func reportIsWritten() throws {
        guard let session, let verdict = verdict(), case .success(let list) = session.runs else { return }
        let modelURL: URL
        switch AcceptanceHarness.modelURL(modelID: session.modelID, paths: AcceptanceHarness.paths) {
        case .failure(let message):
            Issue.record("\(message)")
            return
        case .success(let url): modelURL = url
        }
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        let date = zone.localDate(SystemClock().now()).dashed
        let context = AcceptanceReport.context(modelID: session.modelID, modelURL: modelURL, date: date)
        let markdown = AcceptanceReport.render(context, runs: list, verdict: verdict)
        let url = TestEnvironment.llmReportURL(model: session.modelID)
        try Data(markdown.utf8).write(to: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.hasPrefix("## 15. LLM 受け入れ試験（PLAN §10.6）\n"))
        #expect(written.contains("### 15.2 受け入れ試験"))
        #expect(written.contains("| モデル | `\(session.modelID)` |"))
        #expect(written.contains("| \(AcceptanceFixture.longID) |"))
    }
}
