// 「元音声の削除」の節（PLAN §8.9.8・§8.12 の 7）。値と操作は AppModel、文言は DeletionStrings と Strings。
import SwiftUI
import VDPipeline

/// 「元音声の削除」の節。3 つのロックの個別表示・有効化（ENABLE の入力）・根拠 B・無効化（確認なし）。
/// ENABLE の判定はしない（入力をそのまま DeletionEnabler に渡す）。
struct DeletionSection: View {
    let model: AppModel
    @State private var confirmation = ""
    @State private var skippedConfirmation = ""

    var body: some View {
        if let deletion = model.deletion {
            SectionBox(title: Strings.sectionDeletion) {
                // 3 つのロックの個別表示（LockDisplay.lines のまま）と注意書き
                ForEach(Array(deletion.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced))
                }
                ForEach(Array(deletion.notices.enumerated()), id: \.offset) { _, notice in
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                }
                if let notice = model.deletionNotice, !deletion.notices.contains(notice) {
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                }
                if deletion.showsTrash {
                    if deletion.showsSkippedToggle && !deletion.skippedEnabled {
                        HStack {
                            TextField(DeletionStrings.confirmationWord, text: $skippedConfirmation)
                            Button(Strings.buttonEnableSkippedDeletion) {
                                let word = skippedConfirmation
                                Task {
                                    if case .success = await model.enableSkippedDeletion(confirmation: word) {
                                        skippedConfirmation = ""
                                    }
                                }
                            }
                        }
                    }
                    // 確認を出さない（止めたいときに止められること）
                    Button(Strings.buttonDisableDeletion) { Task { _ = await model.disableDeletion() } }
                } else {
                    // 有効化の事前確認（PLAN §8.9.8 の 1）
                    Text(DeletionStrings.confirmVerified).fixedSize(horizontal: false, vertical: true)
                    Text(DeletionStrings.confirmIrreversible).fixedSize(horizontal: false, vertical: true)
                    if case .done(let results) = model.diagnostics {
                        Text(Diagnostics.summary(results))
                    } else {
                        Button(Strings.buttonRunDiagnostics) { Task { await model.runDiagnostics() } }
                            .disabled(model.diagnostics == .running)
                    }
                    HStack {
                        TextField(DeletionStrings.confirmationWord, text: $confirmation)
                        Button(Strings.buttonEnableDeletion) {
                            let word = confirmation
                            Task {
                                if case .success = await model.enableDeletion(confirmation: word) {
                                    confirmation = ""
                                }
                            }
                        }
                    }
                }
                if let error = model.enableError {
                    Text(Strings.enableFailed(error)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if !model.disableFailedStages.isEmpty {
                    Text(Strings.disableFailed(model.disableFailedStages)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
