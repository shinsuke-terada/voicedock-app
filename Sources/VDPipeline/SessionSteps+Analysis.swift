// Session の解析（PLAN §5.6「解析の再利用」「古い解析」・§8.5「成功時の書き込み」。voicedock pipeline.py:1140-1227, 1402-1449）。
import Foundation
import VDContract
import VDCore
import VDLLM
import VDStore

extension SessionSteps {
    /// 解析を再利用したときの events の detail（★ MERGED→ANALYZED）。
    static let reusedDetail = "analysis_reused"
    /// 古い解析を作り直すときの events の detail（★ ANALYZED / WRITING → ANALYZING）。
    static let staleDetail = "stale_analysis"

    /// 最終形のスキーマ（今の設定の節から）。
    var finalSchema: AnalysisSchema {
        AnalysisSchema(config: AnalysisConfigView(sections: cfg.llm.analysis.sections), kind: .final)
    }

    /// MERGED / ANALYZING → ANALYZED。ANALYZED / WRITING でも指紋が違えば作り直す。
    func ensureAnalysis(_ key: String, _ t: SessionTranscript) async -> Bool {
        await guardedAsync { try await analyze(key, t) }
    }

    private func analyze(_ key: String, _ t: SessionTranscript) async throws -> Bool {
        let slug = KeySlug.of(key)
        let analysisRel = layout.relativePath(of: layout.analysisJSON(sessionSlug: slug))
        // 1.
        guard let row = try store.session(key) else { return false }
        // 2.
        if SessionStates.savedOrBeyond.contains(row.status) { return true }
        // 3.
        let analyzable = SessionStates.analyzable.contains(row.status)
        let writable = SessionStates.writable.contains(row.status)
        if !analyzable && !writable { return false }
        // 4.
        let fp = TranscriptFingerprint.of(t, zone: zone)
        let reused = reusableAnalysis(key, fingerprint: fp)
        // 5. 何も書かない
        if writable && reused != nil { return true }
        // 6. ★ MERGED→ANALYZED（analysis_path と title も書く。書き込みの後・DB の更新の前に落ちた Session のため）
        if analyzable, let r = reused {
            try store.updateSession(key, [.analysisPath(analysisRel), .title(r.title)])
            try store.recordSessionTransition(
                sessionKey: key, from: row.status, to: .analyzed, detail: Self.reusedDetail)
            return true
        }
        // 7. ガード（遷移しない。ANALYZED / WRITING の古い解析もここで待つ）
        guard let target = LLMGuard(ctx: ctx).evaluate() else { return false }
        // 8. ★ ANALYZED / WRITING → ANALYZING。ANALYZING なら記録しない
        if writable {
            try store.recordSessionTransition(
                sessionKey: key, from: row.status, to: .analyzing, detail: Self.staleDetail)
        } else if row.status == .merged {
            try store.recordSessionTransition(sessionKey: key, from: .merged, to: .analyzing)
        }
        // 9.
        ctx.activity.set(.analyzing(sessionKey: key, dayDate: row.dayDate))
        // 10.
        let prompts: Prompts
        do {
            prompts = try Prompts.load(directory: ctx.deps.paths.promptsDirectory)
        } catch {
            try failSession(
                key, from: .analyzing, code: .llmFailed, message: ErrorText.describe(error), event: .llmFailed)
            return false
        }
        // 11.
        let handle: LlamaServerHandle
        switch await ctx.deps.llama.ensureRunning(model: target.model, modelID: target.modelID, config: cfg.llm) {
        case .failure(let f):
            // アプリの終了（停止要求 → 子の停止 → llama.stop() の順）の後の失敗（server_start_failed: cancelled など）は
            // 記録しない。ANALYZING のまま返し、次回起動時の復旧が ANALYZING→MERGED に戻す（PLAN §8.15。F-82）
            if ctx.stop.isSet { return false }
            try failSession(key, from: .analyzing, code: f.code, message: f.message, event: .llmFailed)
            return false
        case .success(let h):
            handle = h
        }
        // 12.
        let clock = ctx.deps.clock
        let transport = ctx.deps.chatTransportFactory(handle, cfg.llm)
        let t0 = clock.uptime()
        let outcome = await Analyzer(transport: transport, prompts: prompts, config: cfg.llm).analyze(t)
        let elapsed = DurationSeconds.of(clock.uptime() - t0)
        switch outcome {
        case .failure(let f):
            // 13. 停止要求の後の失敗（止められたサーバとの通信の失敗など）は記録しない（上と同じ。F-82）
            if ctx.stop.isSet { return false }
            try failSession(
                key, from: .analyzing, code: f.code, message: f.message,
                event: f.code == .sessionMergeFailed ? .sessionMergeFailed : .llmFailed)
            return false
        case .success(let result, let partials, let chunks, let trimmed):
            // 14. 書き込みはこの順（LLM-03 / CONC-09）
            if !trimmed.isEmpty {
                log.info(
                    .analysisTrimmed,
                    [(.sessionKey, .string(key)), (.fields, .string(trimmed.joined(separator: "; ")))])
            }
            do {
                try AtomicFile.write(
                    PyJSON.fileData(result.pyJSON(schema: finalSchema)), to: layout.analysisJSON(sessionSlug: slug))
            } catch {
                // 指紋は書かれない
                try failSession(
                    key, from: .analyzing, code: .llmFailed, message: ErrorText.describe(error), event: .llmFailed)
                return false
            }
            // 書けなくても失敗にしない（T-29）
            saveTimeline(
                sessionKey: key, summary: result.summary, partials: partials, chunks: chunks, transcript: t,
                fingerprint: fp)
            // 最後に指紋
            do {
                try AtomicFile.write(
                    Self.sourceData(fingerprint: fp, transcript: t), to: layout.sourceJSON(sessionSlug: slug))
            } catch {
                try failSession(
                    key, from: .analyzing, code: .llmFailed, message: ErrorText.describe(error), event: .llmFailed)
                return false
            }
            try store.updateSession(
                key, [.analysisPath(analysisRel), .title(result.title), .errorCode(nil), .errorMessage(nil)])
            try store.recordSessionTransition(sessionKey: key, from: .analyzing, to: .analyzed)
            log.info(
                .llmCompleted,
                [
                    (.sessionKey, .string(key)), (.chunks, .of(chunks.count)),
                    (.elapsedS, .double(PyRound.round(elapsed, digits: 1))),
                ])
            return true
        }
    }

    /// analysis/<slug>.json が読めて最終形のスキーマで検証を通れば、その結果（T-29 の ensureDailyNote も使う。判定を 2 か所に書かない）。
    /// 切り詰めずに検証する（保存したものは切り詰め済み。voicedock pipeline.py:1402-1411）。
    func loadAnalysis(_ key: String) -> AnalysisResult? {
        guard let data = try? Data(contentsOf: layout.analysisJSON(sessionSlug: KeySlug.of(key))) else { return nil }
        guard case .object(let obj)? = PyJSON.decode(data) else { return nil }
        guard case .success(let r) = AnalysisValidator.validate(obj, schema: finalSchema) else { return nil }
        return r
    }

    /// loadAnalysis が在り、.source.json の transcript_sha256 が fingerprint と一致すれば、その結果。
    /// 指紋が無い・読めないときは作り直す（旧版からの移行と、指紋の書き込みに失敗した場合）。
    func reusableAnalysis(_ key: String, fingerprint: String) -> AnalysisResult? {
        guard let r = loadAnalysis(key) else { return nil }
        let src = try? Data(contentsOf: layout.sourceJSON(sessionSlug: KeySlug.of(key)))
        guard case .object(let s)? = src.flatMap(PyJSON.decode),
            case .string(let v)? = s.first(where: { $0.0 == "transcript_sha256" })?.1,
            v == fingerprint
        else { return nil }
        return r
    }

    /// .source.json の中身（PyJSON indent 2 ＋ 末尾改行。キーはこの順）。
    static func sourceData(fingerprint: String, transcript: SessionTranscript) -> Data {
        PyJSON.fileData(
            .object([
                ("schema", .int(1)), ("transcript_sha256", .string(fingerprint)),
                ("segments", .int(Int64(transcript.segments.count))),
                ("blocks", .int(Int64(transcript.blocks.count))),
            ]))
    }
}
