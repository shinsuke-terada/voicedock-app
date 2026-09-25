// 要約プロンプトの編集（PLAN §8.12 の 6 の ⚙ → 別の窓。F-92）。
import Foundation
import VDLLM

extension AppModel {
    /// 窓を開く。開いていれば読み直さずに前へ出す（編集中の下書きを捨てない）
    func openPromptEditor() async {
        if promptEditor == nil {
            // 読み込み中の二度押しは捨てる（後から来た読み込みで編集中の下書きを上書きしない）
            guard !promptEditorOpening else { return }
            promptEditorOpening = true
            let sources = await services.promptSources()
            promptEditorOpening = false
            guard let sources else {
                promptEditorError = Strings.promptsUnavailable
                return
            }
            promptEditor = PromptEditorState(bundled: sources.bundled, saved: sources.saved)
            promptEditorMessage = nil
            promptEditorError = nil
        }
        presentPromptEditor()
    }

    func selectPromptKind(_ kind: PromptKind) { promptEditor?.selected = kind }

    func editPrompt(_ text: String) {
        guard let kind = promptEditor?.selected else { return }
        promptEditor?.setDraft(text, for: kind)
        promptEditorMessage = nil
        promptEditorError = nil
    }

    /// 選んでいる種類の下書きを既定の本文に戻す（保存は別に押す）
    func resetPromptToDefault() {
        guard let kind = promptEditor?.selected else { return }
        promptEditor?.resetToDefault(kind)
        promptEditorMessage = nil
        promptEditorError = nil
    }

    /// 変わった種類だけ config.json に書く。違反（CV-60 など）なら書かずに promptEditorError に出す
    func savePrompts() async {
        guard let changes = promptEditor?.changes(), !changes.isEmpty else { return }
        let r = await services.updateConfig { c in
            for change in changes { PromptEditorState.apply(change, to: &c.llm.analysis.prompts) }
        }
        // 書いている間に窓が閉じられたら結果を出さない（閉じた窓の失敗を ⚙ の画面に残さない）
        guard promptEditor != nil else { return }
        switch r {
        case .failure(let v):
            promptEditorError = Strings.configRejected(v)
            promptEditorMessage = nil
        case .success:
            promptEditor?.markSaved(changes)
            promptEditorError = nil
            promptEditorMessage = Strings.promptsSaved
        }
    }

    /// 窓を閉じたら下書きを捨てる（次に開くときは config.json から読み直す）
    func promptEditorDidClose() {
        promptEditor = nil
        promptEditorMessage = nil
        promptEditorError = nil
    }
}
