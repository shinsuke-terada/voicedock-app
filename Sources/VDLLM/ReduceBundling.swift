// Reduce の入力（中間結果の JSON 配列）と束ね方（voicedock llm.py:986-1011）。
import Foundation
import VDCore

enum ReduceBundling {
    /// 中間形のスキーマで各結果を pyJSON にし、PyJSON のコンパクト形式（区切り "," ":"、非 ASCII はそのまま、sortKeys なし）で配列にした文字列。
    static func asJSON(_ partials: [AnalysisResult], schema: AnalysisSchema) -> String {
        PyJSON.dumpsCompact(.array(partials.map { $0.pyJSON(schema: schema) }))
    }

    /// 時刻順のまま貪欲に詰める。current が空でなく（asJSON(current + [item]) のスカラー数が limit を超える、または
    /// candidate.count が itemLimit を超える）なら current を確定し [item] から始める。itemLimit が nil なら件数では区切らない（X-43）。
    static func bundles(_ partials: [AnalysisResult], schema: AnalysisSchema, limit: Int, itemLimit: Int?)
        -> [[AnalysisResult]]
    {
        var bundles: [[AnalysisResult]] = []
        var current: [AnalysisResult] = []
        for item in partials {
            let candidate = current + [item]
            let overChars = !current.isEmpty && TextLimit.scalarCount(asJSON(candidate, schema: schema)) > limit
            let overItems = !current.isEmpty && (itemLimit.map { candidate.count > $0 } ?? false)
            if overChars || overItems {
                bundles.append(current)
                current = [item]
                continue
            }
            current = candidate
        }
        if !current.isEmpty {
            bundles.append(current)
        }
        return bundles
    }
}
