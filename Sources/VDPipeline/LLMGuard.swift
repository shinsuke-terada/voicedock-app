// 解析の前のガード（PLAN §5.4・§8.5「解析の前のガード」）。通らなければ遷移せずに待つ。
import Foundation
import VDCore

/// ガードを通ったときに llama-server の起動に使うモデル。
struct LLMTarget: Equatable, Sendable {
    let model: URL
    let modelID: String
}

/// ガードの判定（ctx.pauses に積む前）。blocked の理由は 1 件以上。
enum LLMGuardVerdict: Equatable, Sendable {
    case pass(LLMTarget)
    case blocked([PauseReason])
}

/// 解析の前のガード。独立した理由はすべて ctx.pauses に積む。
struct LLMGuard {
    let ctx: TickContext

    /// minMemoryGB の 1 GB（2^30 バイト）
    static let bytesPerGB: UInt64 = 1_073_741_824

    /// ガードを通れば起動に使うモデル。通らなければ理由をすべて ctx.pauses.trip して nil（遷移しない）。
    func evaluate() -> LLMTarget? {
        switch inspect() {
        case .pass(let target):
            return target
        case .blocked(let reasons):
            for reason in reasons { ctx.pauses.trip(reason) }
            return nil
        }
    }

    /// ガードの判定だけ（ctx.pauses に積まない）。
    /// evaluate と、今すぐ要約の事前確認（SummarizeNow。PLAN §5.4・F-66）が使う。
    func inspect() -> LLMGuardVerdict {
        let layout = ctx.deps.layout
        // 1. 未選択なら以降を見ない
        guard let id = ctx.config.llm.modelID else {
            return .blocked([.llmNotSelected])
        }
        // 2.
        var reasons: [PauseReason] = []
        var model: URL?
        if let e = ctx.deps.catalog.entry(kind: .llm, id: id) {
            // 3. カタログのモデル
            model = ModelFiles.url(kind: .llm, entry: e, layout: layout)
            if !ModelFiles.isPresent(e, kind: .llm, layout: layout) {
                reasons.append(.llmModelMissing)
            }
            if let gb = e.minMemoryGB {
                // UInt64(gb) * 1_073_741_824。範囲外の値でトラップしない（CR-16）: 溢れたら足りない側
                let (need, overflow) = UInt64(clamping: gb).multipliedReportingOverflow(by: Self.bytesPerGB)
                if overflow || ctx.deps.physicalMemoryBytes < need {
                    reasons.append(.llmInsufficientMemory)
                }
            }
        } else if let u = ModelFiles.customLLMURL(id: id, layout: layout) {
            // 4. カスタムのモデル（メモリの目安は分からないので確かめない。警告は選ぶときの UI が出す）
            model = u
            if !FileProbe.isNonEmptyRegularFile(u) {
                reasons.append(.llmModelMissing)
            }
        } else {
            // 5. どちらでもない（CV-42 で起きない）
            model = nil
            reasons.append(.llmModelMissing)
        }
        // 6. llama-server
        if !FileProbe.isExecutableFile(ctx.deps.paths.llamaServer) {
            reasons.append(.llamaServerMissing)
        }
        // 7. model が nil なら 5. で llm_model_missing が入っているので、blocked の理由は空にならない
        if reasons.isEmpty, let model { return .pass(LLMTarget(model: model, modelID: id)) }
        return .blocked(reasons)
    }
}
