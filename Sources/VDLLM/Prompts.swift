// system プロンプトの読み込みと差し込み（PLAN §8.5「プロンプト」）。format 相当を使わず文字列置換だけで行う。
import Foundation
import VDCore

public enum PromptKind: Sendable, Hashable, CaseIterable { case analyze, map, reduce }

public enum PromptsError: Error, Equatable, Sendable {
    /// ファイル名（例 "analyze_ja.txt"）。
    case unreadable(String)
}

/// DR-09 の疎通確認（voicedock llm.py:651）。
public enum LLMProbe {
    public static let system = "{\"ok\": true} と返してください。"
    public static let user = "ping"
}

public struct Prompts: Equatable, Sendable {
    public static let fileNames = (
        analyze: "analyze_ja.txt", map: "map_ja.txt", reduce: "reduce_ja.txt", repair: "repair_json_ja.txt"
    )

    let analyzeTemplate: String
    let mapTemplate: String
    let reduceTemplate: String
    let repairTemplate: String

    /// directory 直下の 4 ファイルを UTF-8 で読む。どれか読めない（無い・UTF-8 でない）なら PromptsError.unreadable(そのファイル名)。
    public static func load(directory: URL) throws(PromptsError) -> Prompts {
        Prompts(
            analyze: try read(directory, fileNames.analyze), map: try read(directory, fileNames.map),
            reduce: try read(directory, fileNames.reduce), repair: try read(directory, fileNames.repair))
    }

    /// 末尾の改行を含めてそのまま持つ（trim しない）。
    private static func read(_ directory: URL, _ name: String) throws(PromptsError) -> String {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
            let text = String(data: data, encoding: .utf8)
        else {
            throw PromptsError.unreadable(name)
        }
        return text
    }

    /// テンプレートの本文（テスト用）。
    public init(analyze: String, map: String, reduce: String, repair: String) {
        analyzeTemplate = analyze
        mapTemplate = map
        reduceTemplate = reduce
        repairTemplate = repair
    }

    public func analyze(schema: AnalysisSchema, custom: String) -> String {
        Self.fill(analyzeTemplate, schema: schema, custom: custom)
    }

    public func map(schema: AnalysisSchema, custom: String) -> String {
        Self.fill(mapTemplate, schema: schema, custom: custom)
    }

    public func reduce(schema: AnalysisSchema, custom: String) -> String {
        Self.fill(reduceTemplate, schema: schema, custom: custom)
    }

    /// F-92: 3 つのテンプレートの本文（差し込み前）。編集の窓が既定の本文として出す。
    public func template(_ kind: PromptKind) -> String {
        switch kind {
        case .analyze: return analyzeTemplate
        case .map: return mapTemplate
        case .reduce: return reduceTemplate
        }
    }

    /// F-92: `llm.analysis.prompts` の上書きを当てたもの。nil の種類は同梱の本文のまま。修復のプロンプトは替えない。
    public func overriding(_ o: PromptOverrides) -> Prompts {
        Prompts(
            analyze: o.analyze ?? analyzeTemplate, map: o.map ?? mapTemplate, reduce: o.reduce ?? reduceTemplate,
            repair: repairTemplate)
    }

    /// 上の 3 つへ振り分ける。
    public func system(_ kind: PromptKind, schema: AnalysisSchema, custom: String) -> String {
        switch kind {
        case .analyze: return analyze(schema: schema, custom: custom)
        case .map: return map(schema: schema, custom: custom)
        case .reduce: return reduce(schema: schema, custom: custom)
        }
    }

    /// X-12: 修復プロンプトにもスキーマを渡す。信用できない入力（previousOutput）を最後に差し込む（PLAN §8.5）。
    public func repair(schema: AnalysisSchema, errors: String, previousOutput: String) -> String {
        let withSchema = PromptText.replaceAll(
            repairTemplate, PromptOverrides.schemaPlaceholder, SchemaBlock.render(schema))
        let withErrors = PromptText.replaceAll(withSchema, "{errors}", errors)
        return PromptText.replaceAll(withErrors, "{previous_output}", previousOutput)
    }

    /// `{schema_block}` → `{custom_instructions}` の順に 1 回ずつ。
    private static func fill(_ template: String, schema: AnalysisSchema, custom: String) -> String {
        let withSchema = PromptText.replaceAll(template, PromptOverrides.schemaPlaceholder, SchemaBlock.render(schema))
        return PromptText.replaceAll(withSchema, PromptOverrides.customPlaceholder, custom)
    }
}

/// Python の `str.replace` と同じ置換（Unicode スカラーの完全一致）。
enum PromptText {
    /// `text.unicodeScalars` の上で、左から重ならないように `placeholder` の全出現を `value` に置き換える。
    /// Foundation の `replacingOccurrences` は正準等価で比べるので使わない。置き換えた `value` の中はもう一度走査しない。
    static func replaceAll(_ text: String, _ placeholder: String, _ value: String) -> String {
        let source = Array(text.unicodeScalars)
        let needle = Array(placeholder.unicodeScalars)
        guard !needle.isEmpty, needle.count <= source.count else {
            return text
        }
        var out = String.UnicodeScalarView()
        var i = 0
        while i < source.count {
            if i + needle.count <= source.count && source[i..<(i + needle.count)].elementsEqual(needle) {
                out.append(contentsOf: value.unicodeScalars)
                i += needle.count
            } else {
                out.append(source[i])
                i += 1
            }
        }
        return String(out)
    }
}
