// 「モデル」のカード（PLAN §8.12 の 5）。1 モデル 1 行。LLM の選択と「ファイルから読み込む…」は Menu の中（F-65）。
import SwiftUI
import VDCore

/// 「モデル」のカード。Whisper・VAD の在否と入手、LLM の選択（Menu）・入手・ファイルから読み込む。
struct ModelsSection: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        SectionBox(title: Strings.sectionModels) {
            ModelRow(
                model: model, label: Strings.labelWhisperModel, present: s.whisperPresent,
                slot: s.whisperEntry == nil ? nil : .whisper
            ) {
                if let name = s.whisperEntry?.displayName { Text(name).lineLimit(1) }
            }
            ModelRow(
                model: model, label: Strings.labelVADModel, present: s.vadPresent,
                slot: s.vadEntry == nil ? nil : .vad
            ) {
                if let name = s.vadEntry?.displayName { Text(name).lineLimit(1) }
            }
            if !s.vadEnabled {
                Text(Strings.vadDisabled).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ModelRow(model: model, label: Strings.labelLLMModel, present: s.llmPresent, slot: llmSlot(s)) {
                LLMMenu(model: model)
            }
            if model.downloads[.customImport] == .importing {
                ProgressView().controlSize(.small)
            }
            if let error = model.modelError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.modelNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        // 要対応の「モデルの節を開く」で目立たせる（主画面のカードのまま。F-65）
        .overlay(
            RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(model.modelsHighlighted ? 0.6 : 0), lineWidth: 1)
        )
    }

    /// 入手の対象になる LLM の枠（カタログの項目が選ばれているときだけ。読み込んだモデルは入手しない）
    private func llmSlot(_ s: AppSnapshot) -> ModelSlot? {
        guard let id = s.llmModelID, let choice = s.llmChoices.first(where: { $0.id == id }), !choice.isCustom else {
            return nil
        }
        return .llm(id)
    }
}

/// LLM の選択（Menu の中に Picker と「ファイルから読み込む…」）。
private struct LLMMenu: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        Menu {
            Picker(
                Strings.labelLLMModel,
                selection: Binding(
                    get: { s.llmModelID ?? "" },
                    set: { id in Task { await model.selectLLM(id) } })
            ) {
                if s.llmModelID == nil { Text(Strings.llmNotSelected).tag("") }
                // 設定の ID が一覧に無い（verified でない・カタログから消えた）ときも選択を表せる行を置く
                if let id = s.llmModelID, !s.llmChoices.contains(where: { $0.id == id }) { Text(id).tag(id) }
                // 選べないものも一覧から消さない（理由を同じ行に出す。PLAN §8.10）
                ForEach(s.llmChoices) { choice in
                    Text(Self.choiceLabel(choice)).tag(choice.id).disabled(!choice.selectable)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button(Strings.buttonImportGGUF) { Task { await model.importLLMFromFile() } }
        } label: {
            Text(Self.selectedName(s)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
    }

    /// 選ばれている LLM の表示名（一覧に無ければ ID、未選択なら「選ばれていません」）
    static func selectedName(_ s: AppSnapshot) -> String {
        guard let id = s.llmModelID else { return Strings.llmNotSelected }
        return s.llmChoices.first(where: { $0.id == id })?.displayName ?? id
    }

    /// 表示名と、選べない理由・注意（あれば）
    static func choiceLabel(_ choice: LLMChoice) -> String {
        guard let note = choice.note else { return choice.displayName }
        return choice.displayName + " — " + note
    }
}

/// 1 つのモデルの行（ラベル・名前・在否か入手・進捗・やめる）。slot が nil なら入手の操作を出さない。
private struct ModelRow<Name: View>: View {
    let model: AppModel
    let label: String
    let present: Bool
    let slot: ModelSlot?
    @ViewBuilder let name: () -> Name

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                name()
                Spacer(minLength: 6)
                status
            }
            if let slot, case .running(let received, let total) = model.downloads[slot] {
                HStack(spacing: 6) {
                    if let fraction = model.downloads[slot]?.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(Strings.modelProgress(received: received, total: total))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        Task { await model.cancelModel(slot) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(Strings.buttonCancelDownload)
                    .accessibilityLabel(Strings.buttonCancelDownload)
                }
            }
            if let slot, case .failed(let message) = model.downloads[slot] {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 右端: 入手済みなら緑のチェック、未入手なら「入手する」（入手中は出さない）
    @ViewBuilder
    private var status: some View {
        if present {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(Strings.modelPresent)
                .accessibilityLabel(Strings.modelPresent)
        } else if let slot, !isRunning(slot) {
            Button(Strings.buttonFetchModel) { Task { await model.fetchModel(slot) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if slot == nil {
            Text(Strings.modelAbsent).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func isRunning(_ slot: ModelSlot) -> Bool {
        if case .running = model.downloads[slot] { return true }
        return false
    }
}
