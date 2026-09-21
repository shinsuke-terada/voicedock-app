// 検証を通った解析結果（PLAN §8.5）。nil は無効な節。
import Foundation
import VDCore

public struct AnalysisTask: Equatable, Sendable {
    public let text: String
    /// 無ければ nil（JSON では null）。
    public let due: String?

    public init(text: String, due: String?) {
        self.text = text
        self.due = due
    }
}

public struct AnalysisResult: Equatable, Sendable {
    /// 中間形・summary 無効なら nil。
    public let title: String?
    public let summary: String?
    /// 節が無効（スキーマに無い）なら nil。有効で欠落なら []。
    public let keyPoints: [String]?
    public let tasks: [AnalysisTask]?
    public let decisions: [String]?
    public let ideas: [String]?
    public let tags: [String]?

    public init(
        title: String?, summary: String?, keyPoints: [String]?, tasks: [AnalysisTask]?,
        decisions: [String]?, ideas: [String]?, tags: [String]?
    ) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.tasks = tasks
        self.decisions = decisions
        self.ideas = ideas
        self.tags = tags
    }

    /// schema.fields の順にキーを並べた PyJSON のオブジェクト（voicedock の model_dump と同じ形）。
    public func pyJSON(schema: AnalysisSchema) -> PyJSONValue {
        var entries: [(String, PyJSONValue)] = []
        for field in schema.fields {
            let value: PyJSONValue
            switch field.name {
            case "title": value = Self.text(title)
            case "summary": value = Self.text(summary)
            case "key_points": value = Self.list(keyPoints)
            case "tasks": value = .array((tasks ?? []).map(Self.task))
            case "decisions": value = Self.list(decisions)
            case "ideas": value = Self.list(ideas)
            case "tags": value = Self.list(tags)
            default: continue
            }
            entries.append((field.name, value))
        }
        return .object(entries)
    }

    private static func text(_ value: String?) -> PyJSONValue {
        value.map { .string($0) } ?? .null
    }

    private static func list(_ items: [String]?) -> PyJSONValue {
        .array((items ?? []).map { .string($0) })
    }

    /// due は nil でも必ず出す。
    private static func task(_ task: AnalysisTask) -> PyJSONValue {
        .object([("text", .string(task.text)), ("due", task.due.map { .string($0) } ?? .null)])
    }
}
