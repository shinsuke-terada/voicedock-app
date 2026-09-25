// プロンプトへ差し込む {schema_block}（voicedock llm.py:134-184 と同一）。
import Foundation

public enum SchemaBlock {
    /// LLM-01: 件数の上限（maxItems）はどこにも出さない（見せると数を埋めに来る）。文字数の上限だけを見せる。
    public static func render(_ schema: AnalysisSchema) -> String {
        let rows = schema.fields.map { "  \"\($0.name)\": \(example($0))" }
        return ["{", rows.joined(separator: ",\n"), "}"].joined(separator: "\n")
    }

    /// voicedock `_example`。
    static func example(_ field: SchemaField) -> String {
        switch (field.name, field.shape) {
        case ("title", .text(let maxScalars)):
            return "\"内容を表す簡潔な日本語（\(maxScalars) 文字以内）\""
        case ("summary", .text(let maxScalars)):
            return "\"全体の要約（\(maxScalars) 文字以内）\""
        case ("tasks", _):
            return "[{\"text\": \"やること\", \"due\": \"2026-08-30 または null\"}]"
        default:
            return "[\"...\"]"
        }
    }
}
