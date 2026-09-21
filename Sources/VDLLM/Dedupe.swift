// Reduce の結果の重複除去（voicedock llm.py:1015-1066）。曖昧一致はしない。
import Foundation
import VDCore

public enum Dedupe {
    /// 正規形 = casefold(strip(NFKC(s)))。この順（voicedock normalize_for_dedupe）。
    public static func key(_ s: String) -> String {
        PyText.casefold(PyText.strip(PyText.nfkc(s)))
    }

    /// 順序を保ち、同じ key の 2 つ目以降を落とす。
    public static func strings(_ values: [String]) -> [String] {
        var seen: Set<[Unicode.Scalar]> = []
        return values.filter { seen.insert(scalars($0)).inserted }
    }

    /// tasks は text の key で比べる（due が違っても 1 件）。最初の要素を残す。
    public static func tasks(_ values: [AnalysisTask]) -> [AnalysisTask] {
        var seen: Set<[Unicode.Scalar]> = []
        return values.filter { seen.insert(scalars($0.text)).inserted }
    }

    /// key_points / decisions / ideas / tags（nil でなく空でないものだけ）と tasks（nil でなければ）に適用する。title と summary は変えない。
    public static func apply(_ r: AnalysisResult) -> AnalysisResult {
        AnalysisResult(
            title: r.title, summary: r.summary, keyPoints: list(r.keyPoints), tasks: r.tasks.map(tasks),
            decisions: list(r.decisions), ideas: list(r.ideas), tags: list(r.tags))
    }

    private static func list(_ values: [String]?) -> [String]? {
        guard let values, !values.isEmpty else {
            return values
        }
        return strings(values)
    }

    /// key をスカラー列で比べる（Python の set と同じ。Swift の String の == は正準等価で比べる）。
    private static func scalars(_ s: String) -> [Unicode.Scalar] {
        Array(key(s).unicodeScalars)
    }
}
