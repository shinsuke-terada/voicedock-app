// 「一般」の節（PLAN §8.12 の 6）。
import SwiftUI

/// 「一般」の節。ログイン時に起動のトグル。
struct GeneralSection: View {
    let model: AppModel

    var body: some View {
        SectionBox(title: Strings.sectionGeneral) {
            Toggle(
                Strings.labelLoginItem,
                isOn: Binding(
                    get: { model.snapshot.loginItem == .enabled },
                    set: { on in Task { await model.setLoginItem(on) } }))
            if model.snapshot.loginItem == .requiresApproval {
                Text(Strings.loginItemRequiresApproval)
                Button(Strings.buttonOpenLoginItemSettings) { model.openLoginItemSettings() }
            }
            if model.snapshot.loginItem == .notFound {
                Text(Strings.loginItemNotFound).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.loginItemError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.uiStateSaveFailed {
                Text(Strings.uiStateSaveFailed).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
