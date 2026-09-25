// 「保存先（Vault）」のカード（PLAN §8.12 の 4）。1 行で、押すと選び直す（F-65）。
import SwiftUI

/// 「保存先（Vault）」のカード。フォルダ名の 1 行（全体のパスはヘルプに出す）。押すと「変更…」と同じく選び直す。
struct VaultSection: View {
    let model: AppModel

    /// 1 行に出す名前（パスの最後の要素。未選択なら「まだ選ばれていません」）
    static func displayName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return Strings.vaultNotChosen }
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? path : last
    }

    var body: some View {
        let s = model.snapshot
        SectionBox(title: Strings.sectionVault) {
            Button {
                Task { await model.chooseVault() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: s.vault == .available ? "folder.fill" : "folder.badge.questionmark")
                        .foregroundStyle(s.vault == .available ? Color.accentColor : Color.orange)
                    Text(Self.displayName(s.vaultPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(s.vaultPath == nil ? .secondary : .primary)
                    Spacer(minLength: 8)
                    Text(Strings.buttonChangeVault).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(s.vaultPath ?? Strings.chooseVaultMessage)
            // 未選択は 1 行目の「まだ選ばれていません」で足りる（赤い行を出さない）
            if s.vault != .available && s.vault != .notConfigured {
                Text(s.vault.message(path: s.vaultPath ?? "", marker: s.vaultMarker))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.vaultError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
