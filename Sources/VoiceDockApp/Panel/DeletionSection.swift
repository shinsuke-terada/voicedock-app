// 「元音声の削除」の画面の中身（PLAN §8.9.8・§8.12 の 7）。値と操作は AppModel、文言は DeletionStrings と Strings。
import SwiftUI
import VDPipeline

/// 「元音声の削除」の画面の中身。3 つのロックの個別表示・有効化（赤いボタンの 3 秒の長押し。F-65）・根拠 B（同じ長押し）・
/// 削除モジュールの更新（有効な間に版が違うとき。同じ長押しで有効化をもう一度通す。F-84）・
/// 無効化（確認なしの 1 クリック）。確認語の判定はしない（長押しの完了で AppModel が定数を DeletionEnabler に渡す）。
/// 操作の実行中はボタンを押せない。設定エラー中でも、消す能力が残っていれば「無効にする」だけを出す（PLAN §8.9.8 の常時表示）。
struct DeletionSection: View {
    let model: AppModel

    /// 主画面に「元音声の削除」の行を出すか（設定が読めているか、消す能力が残っている間）
    static func isAvailable(_ model: AppModel) -> Bool {
        model.deletion != nil || model.showsDisableButton
    }

    var body: some View {
        if let deletion = model.deletion {
            released(deletion)
        } else if !model.showsDisableButton {
            Text(Strings.deletionUnavailable).font(.callout).foregroundStyle(.secondary)
        }
        if model.showsDisableButton {
            SectionBox {
                // 確認を出さない（止めたいときに止められること）
                Button {
                    Task { _ = await model.disableDeletion() }
                } label: {
                    Label(Strings.buttonDisableDeletion, systemImage: "lock.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.deletionBusy)
                // 最後の再マウントの完了を待つ間（コピー中は数分）、押せないままにせず進んでいることを出す（F-84）
                if model.deletionDisabling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(Strings.disablingDeletion).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let error = model.enableError {
            Text(Strings.enableFailed(error)).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !model.disableFailedStages.isEmpty {
            Text(Strings.disableFailed(model.disableFailedStages)).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 設定が読めているときの表示（3 行・注意書き・有効化か根拠 B）
    @ViewBuilder
    private func released(_ deletion: DeletionPanelState) -> some View {
        // 3 つのロックの個別表示（LockDisplay.lines のまま）と注意書き
        SectionBox(title: deletion.showsTrash ? Strings.deletionOn : Strings.deletionOff) {
            ForEach(Array(deletion.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(deletion.notices.enumerated()), id: \.offset) { _, notice in
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.deletionNotice, !deletion.notices.contains(notice) {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        if deletion.showsTrash {
            // 削除モジュールの版が違う（要対応「削除モジュールの更新が必要です」）なら、有効な間でも長押しで有効化をもう一度通す
            // （PLAN §8.9.3 の 5。自動で複製し直さない。F-84）
            if model.showsReaperUpdate {
                SectionBox {
                    Text(Strings.holdToUpdateHint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HoldToConfirmButton(title: Strings.buttonUpdateReaper, disabled: model.deletionBusy) {
                        Task { _ = await model.enableDeletion() }
                    }
                }
                .attentionHighlight(model.deletionHighlighted)
            }
            if deletion.showsSkippedToggle && !deletion.skippedEnabled {
                SectionBox {
                    Text(Strings.holdToEnableHint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HoldToConfirmButton(title: Strings.buttonEnableSkippedDeletion, disabled: model.deletionBusy) {
                        Task { _ = await model.enableSkippedDeletion() }
                    }
                }
            }
        } else {
            // 有効化の事前確認（PLAN §8.9.8 の 1）と、赤いボタンの長押し（同 2）
            SectionBox {
                Label {
                    Text(DeletionStrings.confirmVerified).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                }
                Label {
                    Text(DeletionStrings.confirmIrreversible).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                // 最新の診断結果 = パネルを開いている間に実行したもの（閉じたら AppModel が捨てる。F-72）。無ければ実行のボタン
                if case .done(let results) = model.diagnostics {
                    Text(Diagnostics.summary(results)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(Strings.buttonRunDiagnostics) { Task { await model.runDiagnostics() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.diagnostics == .running)
                }
                Divider()
                Text(Strings.holdToEnableHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HoldToConfirmButton(title: Strings.buttonEnableDeletion, disabled: model.deletionBusy) {
                    Task { _ = await model.enableDeletion() }
                }
            }
            // 要対応の「有効化フローを開く」で来たら目立たせる（F-84）
            .attentionHighlight(model.deletionHighlighted)
        }
    }
}
