// DR-09: LLM に実リクエストを 1 回送る（PLAN §8.11。別のボタン。Worker の直列ループで実行する）。
import Foundation
import VDCore
import VDLLM

/// DR-09。ensureRunning を呼んだら、応答の後（成功でも失敗でも）llama-server を止める（F-76。LLM-15。
/// pendingJobs の段は tick の最後なので、止めないと次の tick の Part 工程（whisper）と 18 GB が重なる。PLAN §2.1）。
struct LLMProbeCheck: Sendable {
    let ctx: TickContext

    /// 停止要求が来ていたときの返事（返事は必ず返す。返さないとパネルが「実行中…」のまま固まる）
    static let stopped = DiagnosticResult(
        id: DiagnosticID.llmProbe, status: .skip, label: DiagnosticTexts.label(DiagnosticID.llmProbe),
        details: [DiagnosticTexts.probeStopped])

    /// 設定エラー中の返事（設定が読めていないので実行しない）
    static let unavailable = fail(DiagnosticTexts.configMissing)

    func run() async -> DiagnosticResult {
        let c = ctx.config
        // 1.
        guard let id = c.llm.modelID else { return Self.fail(DiagnosticTexts.llmNotSelected) }
        // 2〜3. 解析のガードと同じ判定（LLMGuard）を呼ぶ。前回の tick の ctx.pauses は見ず、書きもしない
        //       （使い捨ての PauseBook に積み、ログも出さない）
        let scratch = PauseBook(
            log: AppLog(
                sink: DiscardingLogSink(), level: .debug, unsafeContent: false, zone: ctx.zone, clock: ctx.deps.clock))
        let guardContext = TickContext(
            deps: ctx.deps, config: c, zone: ctx.zone, snapshot: ctx.snapshot, pauses: scratch,
            activity: ctx.activity, stop: ctx.stop, undeletableStreaks: ctx.undeletableStreaks)
        guard let target = LLMGuard(ctx: guardContext).evaluate() else {
            let reason = scratch.paused.first ?? .llmModelMissing
            return Self.fail(StatusTexts.pauseWord(reason))
        }
        // 4〜8.
        let result = await probe(target.model, modelID: id, config: c.llm)
        // 9. 応答の後で止める（成功でも失敗でも。F-76）
        await ctx.deps.llama.stop()
        return result
    }

    /// 手順 4〜8: 起動して 1 回だけ送る。
    private func probe(_ model: URL, modelID id: String, config: LLMConfig) async -> DiagnosticResult {
        // 4.
        let started = ctx.deps.clock.uptime()
        // 5.
        let handle: LlamaServerHandle
        switch await ctx.deps.llama.ensureRunning(model: model, modelID: id, config: config) {
        case .failure(let f): return Self.fail(DiagnosticTexts.probeFailed(f.message))
        case .success(let h): handle = h
        }
        // 6〜7. 応答の中身は見ない（疎通の確認であり、JSON の検証は AnalysisCall の仕事）
        let transport = ctx.deps.chatTransportFactory(handle, config)
        switch await transport.complete(system: LLMProbe.system, user: LLMProbe.user) {
        case .content:
            // 8.
            let elapsed = ctx.deps.clock.uptime() - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return DiagnosticResult(
                id: DiagnosticID.llmProbe, status: .ok, label: DiagnosticTexts.label(DiagnosticID.llmProbe),
                details: [DiagnosticTexts.probeOK(model: id, seconds: seconds)])
        case .failure(let f):
            return Self.fail(DiagnosticTexts.probeFailed(f.message))
        }
    }

    static func fail(_ detail: String) -> DiagnosticResult {
        DiagnosticResult(
            id: DiagnosticID.llmProbe, status: .fail, label: DiagnosticTexts.label(DiagnosticID.llmProbe),
            details: [detail])
    }
}

/// 使い捨ての PauseBook に渡す、何も書かないログの行き先（DR-09 がガードの判定だけを借りるため）。
private struct DiscardingLogSink: LogSink {
    func write(line: String, level: LogLevel, category: String) {}
}
