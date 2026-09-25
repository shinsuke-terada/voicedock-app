// tick の段: refreshVaultIndex（PLAN §5.4・§8.6 WikiLink・NOTE-11。voicedock worker.py:309-324）。
import VDCore
import VDNotes

extension Worker {
    /// Vault 索引を TTL で作り直す。索引は tick をまたいで持つ（毎回作らない。voicedock 変更 BK-3）。
    /// linkTags が偽なら持たない。使えない Vault では作り直さない（前の索引を保つ）。Vault の場所が変わったら TTL を待たない。
    func stageRefreshVaultIndex(_ ctx: TickContext) async {
        let wiki = ctx.config.obsidian.wiki
        guard wiki.linkTags else {
            vaultIndex = nil
            vaultIndexPath = nil
            return
        }
        guard let path = ctx.config.vault.path,
            VaultCheck.evaluate(path: path, marker: ctx.config.vault.marker).isAvailable
        else { return }
        // 単調時計（TIME-06）
        let now = ctx.deps.clock.uptime()
        // パスの比較はスカラー単位（00-api-map §0）
        if let idx = vaultIndex, let built = vaultIndexPath, PyText.scalarsEqual(built, path),
            !idx.isStale(ttlSeconds: wiki.vaultIndexCacheSeconds, now: now)
        {
            return
        }
        let vault = VaultPaths.root(path)
        let prefix = VaultIndex.rawFolderPrefix(ctx.config.obsidian.raw.folderTemplate)
        guard
            let built = try? await BlockingIO.run({
                VaultIndex.build(vault: vault, excludePrefixes: [prefix], builtAt: now)
            })
        else { return }
        vaultIndex = built
        vaultIndexPath = path
    }
}
