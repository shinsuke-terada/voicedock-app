// 復旧時の Vault の一時ファイルの削除（PLAN §5.3 の本計画の差分。voicedock は残していた）。Vault の確認が通ったときだけ。
import Foundation
import VDContract
import VDCore
import VDNotes
import VDStore

extension Recovery {
    /// RAW_WRITING の Part: その Session の Raw ノートの一時ファイル。
    func discardVaultTmp(part row: RecordingRow) {
        guard let vault = availableVault() else { return }
        guard let key = row.sessionKey, let s = (try? store.session(key)) ?? nil, let day = LocalDate(dashed: s.dayDate)
        else { return }
        let targets = VaultPaths.tmpCandidates(
            vault: vault, existing: s.rawOutputPath, folder: RawNote.folder(config: config.obsidian, day: day),
            baseName: RawNote.baseName(config: config.obsidian, day: day))
        discardAll(targets, vault: vault)
    }

    /// WRITING の Session: Daily ノートの一時ファイル。
    func discardVaultTmp(session row: SessionRow) {
        guard let vault = availableVault() else { return }
        guard let day = LocalDate(dashed: row.dayDate) else { return }
        let targets = VaultPaths.tmpCandidates(
            vault: vault, existing: row.outputPath, folder: DailyNote.folder(config: config.obsidian, day: day),
            baseName: DailyNote.baseName(config: config.obsidian, day: day))
        discardAll(targets, vault: vault)
    }

    /// Vault の確認が通ったときだけその URL（判定関数は VaultCheck.evaluate の 1 つ。PLAN §8.7）。
    private func availableVault() -> URL? {
        guard let path = config.vault.path, VaultCheck.evaluate(path: path, marker: config.vault.marker).isAvailable
        else { return nil }
        return VaultPaths.root(path)
    }

    /// 消せなくても続ける（config_warning rule=recovery。パスは Vault からの相対）。
    private func discardAll(_ targets: [URL], vault: URL) {
        for target in targets {
            do {
                try SafeUnlink.remove(target, under: .vaultTmp(vault: vault), layout: layout, missingOK: true)
            } catch {
                let shown = VaultPaths.relative(target, vault: vault)
                log.warning(
                    .configWarning,
                    [(.rule, "recovery"), (.message, .string("\(shown) を消せません: \(ErrorText.describe(error))"))])
            }
        }
    }
}
