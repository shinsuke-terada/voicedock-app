// 乗り換えの走査を呼ぶ契機（PLAN §8.13。起動時と Vault を選んだ直後）。
import Foundation
import VDCore
import VDNotes
import VDStore

/// 走査の契機（ログには出さない。呼び出し側の意図を型で示す）。
public enum ImportedKeysScanReason: String, Sendable {
    case startup
    case vaultSelected = "vault_selected"
}

/// 乗り換えの走査を呼ぶ契機（PLAN §8.13）。actor なので同時に 2 回走らない。
public actor ImportedKeysService {
    let store: Store
    let config: ConfigStore
    let log: AppLog

    public init(store: Store, config: ConfigStore, log: AppLog) {
        self.store = store
        self.config = config
        self.log = log
    }

    /// Vault が .available のときだけ走る。戻りは足した件数（走らなければ 0）。例外を投げない。
    @discardableResult
    public func scanIfAvailable(_ reason: ImportedKeysScanReason) async -> Int {
        guard let cfg = await config.current() else { return 0 }
        guard let path = cfg.vault.path, VaultCheck.evaluate(path: path, marker: cfg.vault.marker).isAvailable else {
            return 0
        }
        let vault = VaultPaths.root(path)
        let s = store
        let o = cfg.obsidian
        let g = log
        do {
            return try await BlockingIO.run { try ImportedKeysScanner(store: s, log: g).scan(vault: vault, config: o) }
        } catch {
            g.warning(
                .configWarning, [(.rule, .string("store")), (.message, .string(String(describing: type(of: error))))])
            return 0
        }
    }
}
