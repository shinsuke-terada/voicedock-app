// 要約プロンプトの編集の窓の中身（F-92）。既定の本文・保存済みの上書き・下書きを持つ値で、AppModel が 1 つ持つ。
import VDCore
import VDLLM

/// 要約プロンプトの編集の窓の中身（F-92）。本文の比較は Unicode スカラーの完全一致（PromptText と同じ）。
struct PromptEditorState: Equatable {
    /// 保存する 1 件（value が nil なら既定に戻す = config.json に null を書く）
    struct Change: Equatable, Sendable {
        let kind: PromptKind
        let value: String?
    }

    /// 同梱の本文（Resources/prompts）
    let defaults: [PromptKind: String]
    /// config.json の上書き（nil = 既定）
    private(set) var saved: PromptOverrides
    /// 窓の中で編集している本文
    private(set) var drafts: [PromptKind: String]
    var selected: PromptKind = .analyze

    init(bundled: Prompts, saved: PromptOverrides) {
        var defaults: [PromptKind: String] = [:]
        var drafts: [PromptKind: String] = [:]
        for kind in PromptKind.allCases {
            defaults[kind] = bundled.template(kind)
            drafts[kind] = Self.value(saved, kind) ?? bundled.template(kind)
        }
        self.defaults = defaults
        self.saved = saved
        self.drafts = drafts
    }

    func draft(_ kind: PromptKind) -> String { drafts[kind] ?? "" }

    mutating func setDraft(_ text: String, for kind: PromptKind) { drafts[kind] = text }

    /// 下書きが既定の本文と同じか
    func isDefault(_ kind: PromptKind) -> Bool { Self.same(draft(kind), defaults[kind] ?? "") }

    /// 下書きが保存済みの本文（上書きが無ければ既定）と違うか
    func isDirty(_ kind: PromptKind) -> Bool {
        !Self.same(draft(kind), Self.value(saved, kind) ?? defaults[kind] ?? "")
    }

    var hasChanges: Bool { PromptKind.allCases.contains { isDirty($0) } }

    /// 下書きだけを既定の本文に戻す（保存は別に押す）
    mutating func resetToDefault(_ kind: PromptKind) { drafts[kind] = defaults[kind] ?? "" }

    /// 保存する変更（変わった種類だけ、analyze → map → reduce の順）。既定と同じ本文は nil（null）にする
    func changes() -> [Change] {
        PromptKind.allCases.filter { isDirty($0) }.map { kind in
            Change(kind: kind, value: isDefault(kind) ? nil : draft(kind))
        }
    }

    /// 保存できた変更を保存済みに写す
    mutating func markSaved(_ changes: [Change]) {
        for change in changes { Self.apply(change, to: &saved) }
    }

    /// 1 件を上書きに当てる（ConfigStore.update の中でも使う）
    static func apply(_ change: Change, to overrides: inout PromptOverrides) {
        switch change.kind {
        case .analyze: overrides.analyze = change.value
        case .map: overrides.map = change.value
        case .reduce: overrides.reduce = change.value
        }
    }

    static func value(_ overrides: PromptOverrides, _ kind: PromptKind) -> String? {
        switch kind {
        case .analyze: overrides.analyze
        case .map: overrides.map
        case .reduce: overrides.reduce
        }
    }

    /// `String.==` は正準等価で比べるので使わない（見た目が同じ別の本文を「変わっていない」としない）
    private static func same(_ a: String, _ b: String) -> Bool { PyText.scalarsEqual(a, b) }
}
