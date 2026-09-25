// 状態の見出し（PLAN §8.12 の 1）。大きめの SF Symbol と状態の色、1 行の状態・最終接続・未処理・デバイスの空き容量、
// 今すぐ要約の小さなボタン（F-66）、⚙。
import SwiftUI
import VDCore

/// 状態の見出し（PLAN §8.12 の 1）。右上の ⚙ で「設定」の画面へ（F-65）。削除が有効なら赤いゴミ箱を並べる。
/// 文言の下に「今すぐ要約」の小さなボタンと、その返事の短い通知を置く（F-66）。
struct StatusSection: View {
    let model: AppModel

    /// 今すぐ要約のボタンの SF Symbol（F-66）
    static let summarizeNowSymbol = "sparkles"

    var body: some View {
        let state = model.iconState
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: PanelStyle.headerSymbol(state))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PanelStyle.tint(state))
                .frame(width: 30, height: 30)
                .accessibilityLabel(Strings.iconDescription(state))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.statusLine).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if model.showsTrash {
                        Image(systemName: IconState.trashSymbolName)
                            .foregroundStyle(.red)
                            .help(Strings.iconTrashDescription)
                            .accessibilityLabel(Strings.iconTrashDescription)
                    }
                }
                Text(Strings.statusDetailLine(lastConnected: model.lastConnectedLine, backlog: model.backlogLine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let free = model.deviceFreeLine {
                    Text(Strings.deviceFreeLine(free)).font(.caption).foregroundStyle(.secondary)
                }
                summarizeNowRow.padding(.top, 3)
                // 起動時のデータの初期化の結果（閉じるまで。F-95）
                if let notice = model.dataResetNotice {
                    Text(notice).font(.caption)
                        .foregroundStyle(model.dataResetNoticeIsWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button {
                Task { await model.show(.settings) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help(Strings.screenSettings)
            .accessibilityLabel(Strings.screenSettings)
        }
        .padding(PanelStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous).fill(.quaternary.opacity(0.5))
        )
    }

    /// 「今すぐ要約」のボタンと通知（F-66）。実行中は押せない。通知は数秒で消す（閉じれば AppModel が消す）
    private var summarizeNowRow: some View {
        let state = model.summarizeNow
        return HStack(spacing: 6) {
            Button {
                Task { await model.requestSummarizeNow() }
            } label: {
                Label(Strings.buttonSummarizeNow, systemImage: Self.summarizeNowSymbol)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state == .running)
            if state == .running {
                ProgressView().controlSize(.small)
            }
            if let notice = model.summarizeNowNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(isFailure(state) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: state) {
            guard model.summarizeNowNotice != nil else { return }
            do { try await TaskSleeper().sleep(seconds: AppModel.summarizeNowNoticeSeconds) } catch { return }
            model.dismissSummarizeNowNotice(state)
        }
    }

    private func isFailure(_ state: AppModel.SummarizeNowState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
