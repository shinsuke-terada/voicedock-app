// tick の段: refreshVaultIndex（PLAN §5.4・§8.8。本体は T-29）。

extension Worker {
    // T-29 が中身を書く（PLAN §8.8）。
    func stageRefreshVaultIndex(_ ctx: TickContext) async {}
}
