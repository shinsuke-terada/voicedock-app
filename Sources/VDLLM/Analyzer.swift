// Session の解析: 単一パスか Map → Reduce（voicedock llm.py:821-1011）。例外を投げない。
import Foundation
import VDCore

public enum AnalyzeOutcome: Equatable, Sendable {
    /// partials: 1 段目の Map の結果（チャンクと同じ順。単一パスなら []）。Timeline の素材（T-27）。
    /// chunks: 分割したチャンク（llm_completed の chunks= と Timeline の時刻範囲に使う）。
    /// trimmed: 切り詰めの記録（段の前置き付き。単一パスは前置き無し）。呼び手が analysis_trimmed に出す。
    case success(AnalysisResult, partials: [AnalysisResult], chunks: [Chunk], trimmed: [String])
    case failure(StageFailure)
}

public struct Analyzer: Sendable {
    /// voicedock REDUCE_MAX_DEPTH。
    public static let reduceMaxDepth = 3

    private let config: LLMConfig
    private let finalSchema: AnalysisSchema
    private let partialSchema: AnalysisSchema
    private let call: AnalysisCall

    public init(transport: any ChatTransport, prompts: Prompts, config: LLMConfig) {
        self.config = config
        finalSchema = AnalysisSchema(config: .init(sections: config.analysis.sections), kind: .final)
        partialSchema = AnalysisSchema(config: .init(sections: config.analysis.sections), kind: .partial)
        call = AnalysisCall(
            transport: transport, prompts: prompts, customInstructions: config.analysis.customInstructions,
            repairAttempts: config.repairAttempts)
    }

    /// 時刻は LLM に渡さない（チャンクの本文に時刻を入れない）。経過時間は測らない（呼び手が測る）。
    public func analyze(_ t: SessionTranscript) async -> AnalyzeOutcome {
        let chunks = Chunker.chunk(
            t.segments, maxChars: config.maxCharsPerRequest, maxSeconds: config.maxSecondsPerRequest,
            overlapChars: config.chunkOverlapChars)
        guard let first = chunks.first else {
            return .failure(StageFailure(.sessionMergeFailed, "チャンクが 0 個です（統合結果が空）"))
        }
        if chunks.count == 1 {
            // 単一パス: 重複除去しない。trimmed に前置きを付けない。
            switch await call.run(kind: .analyze, schema: finalSchema, body: first.text) {
            case .failure(let failure): return .failure(failure)
            case .success(let r): return .success(r.result, partials: [], chunks: chunks, trimmed: r.trimmed)
            }
        }
        var partials: [AnalysisResult] = []
        var trimmed: [String] = []
        // チャンクの順に 1 つずつ（並行に投げない）。Map が 1 つでも落ちたら Reduce へ進まない。
        for chunk in chunks {
            switch await call.run(kind: .map, schema: partialSchema, body: chunk.text) {
            case .failure(let failure): return .failure(failure)
            case .success(let r):
                trimmed += r.trimmed.map { "map: " + $0 }
                partials.append(r.result)
            }
        }
        switch await reduce(partials, depth: 1) {
        case .failure(let failure): return .failure(failure)
        case .success(let (result, notes)):
            return .success(result, partials: partials, chunks: chunks, trimmed: trimmed + notes)
        }
    }

    /// Reduce（必要なら多段）。原文 transcript を再送しない（user は中間結果の JSON 配列だけ）。
    func reduce(_ items: [AnalysisResult], depth: Int) async -> Result<(AnalysisResult, [String]), StageFailure> {
        let body = ReduceBundling.asJSON(items, schema: partialSchema)
        if TextLimit.scalarCount(body) <= config.maxCharsPerRequest || items.count <= 1 {
            // 最終形で検証する。
            switch await call.run(kind: .reduce, schema: finalSchema, body: body) {
            case .failure(let failure): return .failure(failure)
            case .success(let r): return .success((Dedupe.apply(r.result), r.trimmed.map { "reduce: " + $0 }))
            }
        }
        if depth >= Self.reduceMaxDepth {
            return .failure(StageFailure(.llmInvalidJSON, "多段 Reduce が上限 \(Self.reduceMaxDepth) 段に達しました"))
        }
        var folded: [AnalysisResult] = []
        var notes: [String] = []
        for bundle in ReduceBundling.bundles(items, schema: partialSchema, limit: config.maxCharsPerRequest) {
            // 中間段の出力は中間形。
            let bundleBody = ReduceBundling.asJSON(bundle, schema: partialSchema)
            switch await call.run(kind: .map, schema: partialSchema, body: bundleBody) {
            case .failure(let failure): return .failure(failure)
            case .success(let r):
                notes += r.trimmed.map { "reduce\(depth): " + $0 }
                folded.append(r.result)
            }
        }
        switch await reduce(folded, depth: depth + 1) {
        case .failure(let failure): return .failure(failure)
        case .success(let (result, deeperNotes)): return .success((result, notes + deeperNotes))
        }
    }
}
