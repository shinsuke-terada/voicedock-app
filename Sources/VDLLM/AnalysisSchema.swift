// LLM の出力スキーマ。設定の sections から生成する（PLAN §8.5）。
import Foundation
import VDCore

/// 上限の定数（voicedock llm.py:42-44）。
public enum AnalysisLimits {
    public static let titleMaxScalars = 120
    public static let summaryMaxScalars = 4000
    public static let taskTextMaxScalars = 500
    /// 配列になる節の固定順（config の order ではない。voicedock LIST_SECTIONS）。
    public static let listSections: [String] = ["key_points", "tasks", "decisions", "ideas", "tags"]
}

/// スキーマの生成に使う設定の部分。
public struct AnalysisConfigView: Equatable, Sendable {
    public let sections: AnalysisSections

    public init(sections: AnalysisSections) {
        self.sections = sections
    }
}

public struct SchemaField: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        /// title / summary。最小 1 スカラー。
        case text(maxScalars: Int)
        /// key_points / decisions / ideas / tags。
        case stringList(maxItems: Int?)
        /// tasks。
        case taskList(maxItems: Int?)
    }

    /// JSON のキー（snake_case）。
    public let name: String
    public let shape: Shape
    /// title と summary だけ true。
    public let required: Bool

    /// 切り詰めの上限（text は maxScalars、配列は maxItems。nil = 切らない）。
    public var trimLimit: Int? {
        switch shape {
        case .text(let maxScalars): return maxScalars
        case .stringList(let maxItems): return maxItems
        case .taskList(let maxItems): return maxItems
        }
    }
}

public struct AnalysisSchema: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case final, partial }

    public let kind: Kind
    /// 並び = analysis.json のキー順 = schema_block の行順 = 切り詰め・検証エラーの順。
    public let fields: [SchemaField]

    /// voicedock `build_schema`。timeline は LLM の出力項目ではないので入れない（voicedock `NOT_A_SECTION`）。
    public init(config: AnalysisConfigView, kind: Kind) {
        let s = config.sections
        var fields: [SchemaField] = []
        if s.summary.enabled && kind == .final {
            fields.append(
                SchemaField(name: "title", shape: .text(maxScalars: AnalysisLimits.titleMaxScalars), required: true))
        }
        if s.summary.enabled {
            fields.append(
                SchemaField(
                    name: "summary", shape: .text(maxScalars: AnalysisLimits.summaryMaxScalars), required: true))
        }
        for name in AnalysisLimits.listSections {
            let sec: SectionConfig
            switch name {
            case "key_points": sec = s.keyPoints
            case "tasks": sec = s.tasks
            case "decisions": sec = s.decisions
            case "ideas": sec = s.ideas
            case "tags": sec = s.tags
            default: continue
            }
            if !sec.enabled {
                continue
            }
            // 中間形は title と tags を持たない。
            if kind == .partial && name == "tags" {
                continue
            }
            let shape: SchemaField.Shape =
                name == "tasks" ? .taskList(maxItems: sec.maxItems) : .stringList(maxItems: sec.maxItems)
            fields.append(SchemaField(name: name, shape: shape, required: false))
        }
        self.kind = kind
        self.fields = fields
    }

    public func field(named name: String) -> SchemaField? {
        fields.first { $0.name == name }
    }

    public var fieldNames: [String] { fields.map(\.name) }
}
