// PromptEditorState（要約プロンプトの編集の窓の中身）のテスト（F-92）。
import Testing
import VDCore
import VDLLM

@testable import VoiceDockApp

@Suite("PromptEditorState")
struct PromptEditorStateTests {
    static let bundled = Prompts(analyze: "既定A", map: "既定M", reduce: "既定R", repair: "修復")
    static let none = PromptOverrides(analyze: nil, map: nil, reduce: nil)

    @Test("下書きは保存済みの上書き、無ければ既定の本文から始まる")
    func draftsStartFromSavedOrDefault() {
        let state = PromptEditorState(
            bundled: Self.bundled, saved: PromptOverrides(analyze: nil, map: "保存M", reduce: nil))
        #expect(state.draft(.analyze) == "既定A")
        #expect(state.draft(.map) == "保存M")
        #expect(state.draft(.reduce) == "既定R")
        #expect(state.selected == .analyze)
        #expect(!state.hasChanges)
        #expect(state.isDefault(.analyze))
        #expect(!state.isDefault(.map))
    }

    @Test("上書きが無く何も変えていなければ変更は 0 件（TEST-28）")
    func noChangesWhenUntouched() {
        let state = PromptEditorState(bundled: Self.bundled, saved: Self.none)
        #expect(state.changes() == [])
        #expect(!state.hasChanges)
    }

    @Test("変えた種類だけを保存する（既定と同じ本文は null）")
    func changesOnlyEditedKinds() {
        var state = PromptEditorState(
            bundled: Self.bundled, saved: PromptOverrides(analyze: nil, map: "保存M", reduce: nil))
        state.setDraft("新R", for: .reduce)
        state.setDraft("既定M", for: .map)
        #expect(
            state.changes() == [
                PromptEditorState.Change(kind: .map, value: nil),
                PromptEditorState.Change(kind: .reduce, value: "新R"),
            ])
        #expect(state.hasChanges)
    }

    @Test("既定に戻すのは下書きだけ（保存済みは変わらない）")
    func resetChangesTheDraftOnly() {
        var state = PromptEditorState(
            bundled: Self.bundled, saved: PromptOverrides(analyze: "保存A", map: nil, reduce: nil))
        state.resetToDefault(.analyze)
        #expect(state.draft(.analyze) == "既定A")
        #expect(state.saved.analyze == "保存A")
        #expect(state.changes() == [PromptEditorState.Change(kind: .analyze, value: nil)])
    }

    @Test("保存できた変更を保存済みに写すと変更は無くなる")
    func markSavedClearsChanges() {
        var state = PromptEditorState(bundled: Self.bundled, saved: Self.none)
        state.setDraft("新A", for: .analyze)
        state.markSaved(state.changes())
        #expect(state.saved == PromptOverrides(analyze: "新A", map: nil, reduce: nil))
        #expect(!state.hasChanges)
    }

    @Test("正準等価でもスカラーが違えば変更とみなす（é と e + ́）")
    func comparesScalars() {
        let bundled = Prompts(analyze: "caf\u{E9}", map: "M", reduce: "R", repair: "P")
        var state = PromptEditorState(bundled: bundled, saved: Self.none)
        state.setDraft("cafe\u{301}", for: .analyze)
        #expect(state.hasChanges)
        #expect(state.changes() == [PromptEditorState.Change(kind: .analyze, value: "cafe\u{301}")])
    }

    @Test("apply は種類ごとのキーだけを書く")
    func applyWritesOneKey() {
        var o = PromptOverrides(analyze: "A", map: "M", reduce: "R")
        PromptEditorState.apply(PromptEditorState.Change(kind: .map, value: nil), to: &o)
        #expect(o == PromptOverrides(analyze: "A", map: nil, reduce: "R"))
    }
}
