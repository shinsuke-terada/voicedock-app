// 「要約プロンプト」の中身（⚙ の画面。F-92）。編集は別の窓で行う。
import SwiftUI

/// 「要約プロンプト」の中身。編集の窓を開くボタンと注意。枠（カード）は置く側が持つ。
struct PromptsSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(Strings.buttonEditPrompts) { Task { await model.openPromptEditor() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.snapshot.configPresent)
            Text(Strings.promptsNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.promptEditor == nil, let error = model.promptEditorError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
