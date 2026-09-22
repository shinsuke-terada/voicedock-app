// Vault の選択（PLAN §8.12 の 4）。判定は VaultCheck をそのまま使う（判定関数は 1 つ。PLAN §8.7）。
import Foundation
import VDNotes

extension AppModel {
    /// NSOpenPanel で選ばせ、`.available` のときだけ設定に書く。書けたら走査を促す。
    func chooseVault() async {
        let picked = presentModal {
            chooser.chooseFolder(message: Strings.chooseVaultMessage, prompt: Strings.chooseVaultPrompt)
        }
        guard let url = picked else { return }
        let path = url.path(percentEncoded: false)
        let marker = snapshot.vaultMarker
        let status = VaultCheck.evaluate(path: path, marker: marker)
        // .available でなければ拒否し、設定を書かない（PLAN §8.12 の 4）
        guard status == .available else {
            vaultError = status.message(path: path, marker: marker)
            return
        }
        let r = await services.updateConfig { $0.vault.path = path }
        if case .failure(let v) = r {
            vaultError = Strings.configRejected(v)
            return
        }
        vaultError = nil
        // Vault が使えるようになったので、止まっていた工程を進める（ガードは次の tick で外れる）
        await services.scanNow()
        await refresh()
    }
}
