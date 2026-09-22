// 状態の見出し（PLAN §8.12 の 1）。大きめの SF Symbol と状態の色、1 行の状態・最終接続・未処理・デバイスの空き容量、⚙。
import SwiftUI

/// 状態の見出し（PLAN §8.12 の 1）。右上の ⚙ で「設定」の画面へ（F-65）。削除が有効なら赤いゴミ箱を並べる。
struct StatusSection: View {
    let model: AppModel

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
}
