// 要約プロンプトの編集の窓の中身（F-92）。種類の切り替え・本文・既定に戻す・保存。
import SwiftUI
import VDLLM

/// 要約プロンプトの編集の窓の中身（F-92）。値は AppModel.promptEditor だけを見る。
struct PromptEditorView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state = model.promptEditor {
                Picker(
                    Strings.promptKindPicker,
                    selection: Binding(get: { state.selected }, set: { model.selectPromptKind($0) })
                ) {
                    ForEach(PromptKind.allCases, id: \.self) { kind in
                        Text(Strings.promptKindLabel(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(Strings.promptKindNote(state.selected)).font(.callout).foregroundStyle(.secondary)
                PromptTextView(
                    text: Binding(get: { state.draft(state.selected) }, set: { model.editPrompt($0) }))
                Text(Strings.promptEditorHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(Strings.buttonResetPrompt) { model.resetPromptToDefault() }
                        .disabled(state.isDefault(state.selected))
                    Spacer()
                    if let error = model.promptEditorError {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                    } else if state.hasChanges {
                        Text(Strings.promptsUnsaved).font(.caption).foregroundStyle(.orange)
                    } else if let message = model.promptEditorMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(Strings.buttonSavePrompts) { Task { await model.savePrompts() } }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!state.hasChanges)
                }
            } else if let error = model.promptEditorError {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 440)
    }
}
