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
        let targets = Self.tmpTargets(
            vault: vault, existing: s.rawOutputPath, folder: RawNote.folder(config: config.obsidian, day: day),
            baseName: RawNote.baseName(config: config.obsidian, day: day))
        discardAll(targets, vault: vault)
    }

    /// WRITING の Session: Daily ノートの一時ファイル。
    func discardVaultTmp(session row: SessionRow) {
        guard let vault = availableVault() else { return }
        guard let day = LocalDate(dashed: row.dayDate) else { return }
        let targets = Self.tmpTargets(
            vault: vault, existing: row.outputPath, folder: DailyNote.folder(config: config.obsidian, day: day),
            baseName: DailyNote.baseName(config: config.obsidian, day: day))
        discardAll(targets, vault: vault)
    }

    /// 消す一時ファイル（PLAN §5.3）: DB の出力パスがあればその tmp、**それに加えて**今の設定のテンプレートで決まるフォルダの
    /// 候補名（基本名と ` (2)`〜` (99)`）の tmp（名前が完全一致するものだけ。重複なし・この順）。
    /// F-83: 書き手は DB のパスを使えなければ（親フォルダが無い（F-75）・上書きしてはいけないノートに替わった）候補名へ書くので、
    /// DB のパスの側だけを見ると、その途中で落ちた tmp が今のフォルダに残り続けた
    static func tmpTargets(vault: URL, existing: String?, folder: String, baseName: String) -> [URL] {
        var targets: [URL] = []
        var seen: Set<[Unicode.Scalar]> = []
        let own = existing.map {
            VaultPaths.tmpCandidates(vault: vault, existing: $0, folder: folder, baseName: baseName)
        }
        let candidates = VaultPaths.tmpCandidates(vault: vault, existing: nil, folder: folder, baseName: baseName)
        for url in (own ?? []) + candidates {
            // 同じパスを 2 度消そうとしない（DB のパスが今のフォルダの候補名と同じとき）。比較はスカラー列
            if seen.insert(Array(url.standardizedFileURL.path(percentEncoded: false).unicodeScalars)).inserted {
                targets.append(url)
            }
        }
        return targets
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
