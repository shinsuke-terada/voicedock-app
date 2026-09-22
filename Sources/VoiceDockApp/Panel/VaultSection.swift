// 「保存先（Vault）」の節（PLAN §8.12 の 4）。
import SwiftUI

/// 「保存先（Vault）」の節。パスと状態、「変更…」。
struct VaultSection: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        SectionBox(title: Strings.sectionVault) {
            Text(s.vaultPath ?? Strings.vaultNotChosen)
                .fixedSize(horizontal: false, vertical: true)
            // 未選択は 1 行目の「まだ選ばれていません」で足りる（赤い行を出さない）
            if s.vault != .available && s.vault != .notConfigured {
                Text(s.vault.message(path: s.vaultPath ?? "", marker: s.vaultMarker))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(Strings.buttonChangeVault) { Task { await model.chooseVault() } }
            if let error = model.vaultError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
