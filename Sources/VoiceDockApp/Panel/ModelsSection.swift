// 「モデル」の節（PLAN §8.12 の 5）。
import SwiftUI
import VDCore

/// 「モデル」の節。Whisper・VAD の在否と入手、LLM の選択・入手・ファイルから読み込む。
struct ModelsSection: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        SectionBox(title: Strings.sectionModels) {
            ModelRow(
                model: model, label: Strings.labelWhisperModel, name: s.whisperEntry?.displayName,
                present: s.whisperPresent, slot: .whisper)
            ModelRow(
                model: model, label: Strings.labelVADModel, name: s.vadEntry?.displayName, present: s.vadPresent,
                slot: .vad)
            if !s.vadEnabled {
                Text(Strings.vadDisabled).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker(
                Strings.labelLLMModel,
                selection: Binding(
                    get: { s.llmModelID ?? "" },
                    set: { id in Task { await model.selectLLM(id) } })
            ) {
                if s.llmModelID == nil { Text(Strings.llmNotSelected).tag("") }
                // 選べないものも一覧から消さない（理由を同じ行に出す。PLAN §8.10）
                ForEach(s.llmChoices) { choice in
                    Text(choiceLabel(choice)).tag(choice.id).disabled(!choice.selectable)
                }
            }
            if let id = s.llmModelID, let choice = s.llmChoices.first(where: { $0.id == id }), !choice.isCustom {
                ModelRow(
                    model: model, label: Strings.labelLLMModel, name: choice.displayName, present: s.llmPresent,
                    slot: .llm(id))
            }
            Button(Strings.buttonImportGGUF) { Task { await model.importLLMFromFile() } }
            if model.downloads[.customImport] == .importing { ProgressView().controlSize(.small) }
            if let error = model.modelError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.modelNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 表示名と、選べない理由・注意（あれば）
    private func choiceLabel(_ choice: LLMChoice) -> String {
        guard let note = choice.note else { return choice.displayName }
        return choice.displayName + " — " + note
    }
}

/// 1 つのモデルの行（名前・在否・入手・進捗・やめる）。
private struct ModelRow: View {
    let model: AppModel
    let label: String
    let name: String?
    let present: Bool
    let slot: ModelSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                if let name { Text(name) }
                Spacer()
                Text(present ? Strings.modelPresent : Strings.modelAbsent)
            }
            if case .running(let received, let total) = model.downloads[slot] {
                HStack {
                    if let fraction = model.downloads[slot]?.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(Strings.modelProgress(received: received, total: total)).font(.caption)
                    Button(Strings.buttonCancelDownload) { Task { await model.cancelModel(slot) } }
                }
            } else if !present && name != nil {
                Button(Strings.buttonFetchModel) { Task { await model.fetchModel(slot) } }
            }
            if case .failed(let message) = model.downloads[slot] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
