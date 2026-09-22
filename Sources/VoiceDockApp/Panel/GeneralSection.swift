// 「一般」の中身（PLAN §8.12 の 6）。ログイン時に起動のトグルと注意。置き場所は「はじめに」のカードか ⚙ の画面（F-65）。
import SwiftUI

/// 「一般」の中身。ログイン時に起動のトグル・許可の案内・失敗。枠（カード）は置く側が持つ。
struct GeneralSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                Strings.labelLoginItem,
                isOn: Binding(
                    get: { model.snapshot.loginItem == .enabled },
                    set: { on in Task { await model.setLoginItem(on) } })
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            if model.snapshot.loginItem == .requiresApproval {
                Text(Strings.loginItemRequiresApproval).font(.caption).foregroundStyle(.secondary)
                Button(Strings.buttonOpenLoginItemSettings) { model.openLoginItemSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if model.snapshot.loginItem == .notFound {
                Text(Strings.loginItemNotFound).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.uiStateSaveFailed {
                Text(Strings.uiStateSaveFailed).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
