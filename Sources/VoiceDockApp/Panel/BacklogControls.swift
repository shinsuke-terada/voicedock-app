// 後追いの 2 つのボタンと、プレビュー・実行・結果の表示（PLAN §8.9.9。「詳細」の節の中。新しい画面を作らない。D-7）。
import SwiftUI
import VDPipeline

/// 後追いの 2 つのボタン。1 回目の押下でプレビュー、もう一度押して実行する。
struct BacklogControls: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.backlogState {
            case .idle, .done, .failed:
                kindButtons(disabled: false)
                outcome(model.backlogState)
            case .working:
                kindButtons(disabled: true)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.backlogExecuting ? BacklogTexts.executing : BacklogTexts.working)
                        .foregroundStyle(.secondary)
                }
            case .preview(let kind, let plan):
                ForEach(Array(BacklogTexts.previewLines(kind, plan).enumerated()), id: \.offset) { _, line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if !plan.eligible.isEmpty {
                        Button(BacklogTexts.executeTitle(kind, count: plan.eligible.count)) {
                            model.executeBacklog(kind)
                        }
                    }
                    Button(BacklogTexts.cancel) { model.dismissBacklog() }
                }
            }
        }
    }

    /// 2 つのボタン（working の間は無効。二重に入れない）
    @ViewBuilder
    private func kindButtons(disabled: Bool) -> some View {
        ForEach([BacklogKind.backlog, .resolveAbsent], id: \.self) { kind in
            Button(BacklogTexts.buttonTitle(kind)) { model.previewBacklog(kind) }
                .disabled(disabled)
        }
    }

    /// done・failed の 1 行と「閉じる」
    @ViewBuilder
    private func outcome(_ state: BacklogPanelState) -> some View {
        switch state {
        case .done(let kind, let execution):
            Text(BacklogTexts.resultLine(kind, execution)).fixedSize(horizontal: false, vertical: true)
            Button(BacklogTexts.close) { model.dismissBacklog() }
        case .failed(_, let message):
            Text(BacklogTexts.failureLine(message)).fixedSize(horizontal: false, vertical: true)
            Button(BacklogTexts.close) { model.dismissBacklog() }
        default:
            EmptyView()
        }
    }
}
