// 上限への切り詰めと、pydantic v2 と同じ文言の検証（PLAN §8.5、LLM-02・LLM-09）。
import Foundation
import VDCore

public struct ValidationErrors: Error, Equatable, Sendable {
    /// "- <loc>: <msg>"
    public let lines: [String]

    /// lines を "\n" でつないだもの。
    public var rendered: String { lines.joined(separator: "\n") }
}

/// pydantic v2 の文言（voicedock の検証エラーと同じ。変えない）。
public enum LLMValidationMessages {
    public static let fieldRequired = "Field required"
    public static let extraForbidden = "Extra inputs are not permitted"
    public static let notString = "Input should be a valid string"
    public static let notList = "Input should be a valid list"
    public static let notTask = "Input should be a valid dictionary or instance of Task"

    /// "String should have at least <min> character"（min != 1 なら "characters"）。
    public static func tooShort(_ min: Int) -> String {
        "String should have at least \(min) character" + (min == 1 ? "" : "s")
    }

    /// "String should have at most <max> characters"（max == 1 なら "character"）。
    public static func tooLong(_ max: Int) -> String {
        "String should have at most \(max) character" + (max == 1 ? "" : "s")
    }

    /// "List should have at most <max> items after validation, not <actual>"（max == 1 なら "item"）。
    public static func tooManyItems(_ max: Int, _ actual: Int) -> String {
        "List should have at most \(max) item" + (max == 1 ? "" : "s") + " after validation, not \(actual)"
    }

    /// JSON を取り出せなかったときの失敗文（行形式ではない）。
    public static let notExtracted = "応答から JSON を抽出できませんでした"
}

public enum AnalysisValidator {
    /// voicedock `coerce_limits`。検証の前に行う（LLM-02）。文字列なら文字数（スカラー数）で、配列なら個数で切る。
    /// 入れ子（tasks の各 text）は切らない。最小長は扱わない。キーの並びは変えない。
    public static func trim(
        _ obj: [(String, PyJSONValue)], schema: AnalysisSchema
    ) -> (obj: [(String, PyJSONValue)], trimmed: [String]) {
        var result = obj
        var trimmed: [String] = []
        for field in schema.fields {
            guard let limit = field.trimLimit, let index = indexOf(field.name, in: result) else {
                continue
            }
            switch result[index].1 {
            case .string(let s):
                let count = TextLimit.scalarCount(s)
                if count > limit {
                    result[index].1 = .string(TextLimit.prefix(s, scalars: limit))
                    trimmed.append("\(field.name): \(count) -> \(limit)")
                }
            case .array(let items):
                if items.count > limit {
                    result[index].1 = .array(Array(items.prefix(limit)))
                    trimmed.append("\(field.name): \(items.count) -> \(limit)")
                }
            default:
                break
            }
        }
        return (result, trimmed)
    }

    /// pydantic v2 の `model_validate` と同じ判定・同じ順・同じ文言。LLM-09: 入力値をエラーの文に入れない（キー名だけ）。
    public static func validate(
        _ obj: [(String, PyJSONValue)], schema: AnalysisSchema
    ) -> Result<AnalysisResult, ValidationErrors> {
        var errors: [String] = []
        var texts: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var tasks: [AnalysisTask]?
        for field in schema.fields {
            let name = field.name
            guard let index = indexOf(name, in: obj) else {
                if field.required {
                    errors.append(line(name, LLMValidationMessages.fieldRequired))
                } else if case .taskList = field.shape {
                    tasks = []
                } else {
                    lists[name] = []
                }
                continue
            }
            let value = obj[index].1
            switch field.shape {
            case .text(let maxScalars):
                guard case .string(let s) = value else {
                    errors.append(line(name, LLMValidationMessages.notString))
                    continue
                }
                let n = TextLimit.scalarCount(s)
                if n < 1 {
                    errors.append(line(name, LLMValidationMessages.tooShort(1)))
                } else if n > maxScalars {
                    errors.append(line(name, LLMValidationMessages.tooLong(maxScalars)))
                } else {
                    texts[name] = s
                }
            case .stringList(let maxItems):
                guard case .array(let items) = value else {
                    errors.append(line(name, LLMValidationMessages.notList))
                    continue
                }
                var strings: [String] = []
                var itemErrors = false
                for (i, item) in items.enumerated() {
                    guard case .string(let s) = item else {
                        errors.append(line("\(name).\(i)", LLMValidationMessages.notString))
                        itemErrors = true
                        continue
                    }
                    strings.append(s)
                }
                if itemErrors {
                    continue
                }
                if let maxItems, items.count > maxItems {
                    errors.append(line(name, LLMValidationMessages.tooManyItems(maxItems, items.count)))
                    continue
                }
                lists[name] = strings
            case .taskList(let maxItems):
                guard case .array(let items) = value else {
                    errors.append(line(name, LLMValidationMessages.notList))
                    continue
                }
                var parsed: [AnalysisTask] = []
                var itemErrors = false
                for (i, item) in items.enumerated() {
                    if let task = validateTask(item, loc: "\(name).\(i)", errors: &errors) {
                        parsed.append(task)
                    } else {
                        itemErrors = true
                    }
                }
                if itemErrors {
                    continue
                }
                if let maxItems, items.count > maxItems {
                    errors.append(line(name, LLMValidationMessages.tooManyItems(maxItems, items.count)))
                    continue
                }
                tasks = parsed
            }
        }
        let names = schema.fieldNames
        for (key, _) in obj where !names.contains(where: { PyText.scalarsEqual($0, key) }) {
            errors.append(line(key, LLMValidationMessages.extraForbidden))
        }
        guard errors.isEmpty else {
            return .failure(ValidationErrors(lines: errors))
        }
        return .success(
            AnalysisResult(
                title: texts["title"], summary: texts["summary"], keyPoints: lists["key_points"], tasks: tasks,
                decisions: lists["decisions"], ideas: lists["ideas"], tags: lists["tags"]))
    }

    /// tasks の 1 要素。誤りがあれば errors に足して nil。
    private static func validateTask(_ item: PyJSONValue, loc: String, errors: inout [String]) -> AnalysisTask? {
        guard case .object(let entries) = item else {
            errors.append(line(loc, LLMValidationMessages.notTask))
            return nil
        }
        let before = errors.count
        var text = ""
        if let index = indexOf("text", in: entries) {
            if case .string(let s) = entries[index].1 {
                let n = TextLimit.scalarCount(s)
                if n < 1 {
                    errors.append(line("\(loc).text", LLMValidationMessages.tooShort(1)))
                } else if n > AnalysisLimits.taskTextMaxScalars {
                    errors.append(
                        line("\(loc).text", LLMValidationMessages.tooLong(AnalysisLimits.taskTextMaxScalars)))
                }
                text = s
            } else {
                errors.append(line("\(loc).text", LLMValidationMessages.notString))
            }
        } else {
            errors.append(line("\(loc).text", LLMValidationMessages.fieldRequired))
        }
        var due: String?
        if let index = indexOf("due", in: entries) {
            switch entries[index].1 {
            case .null: due = nil
            case .string(let d): due = d
            default: errors.append(line("\(loc).due", LLMValidationMessages.notString))
            }
        }
        for (key, _) in entries where !PyText.scalarsEqual(key, "text") && !PyText.scalarsEqual(key, "due") {
            errors.append(line("\(loc).\(key)", LLMValidationMessages.extraForbidden))
        }
        guard errors.count == before else {
            return nil
        }
        return AnalysisTask(text: text, due: due)
    }

    private static func line(_ loc: String, _ message: String) -> String {
        "- \(loc): \(message)"
    }

    /// キーの突き合わせは Unicode スカラー列（Swift の `==` は正準等価で比べるため）。
    private static func indexOf(_ key: String, in obj: [(String, PyJSONValue)]) -> Int? {
        obj.firstIndex { PyText.scalarsEqual($0.0, key) }
    }
}
