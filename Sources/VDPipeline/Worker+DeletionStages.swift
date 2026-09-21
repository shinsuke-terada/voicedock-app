// tick の段: 削除の 5 段（PLAN §5.4・§8.9。本体は T-38 / T-39）。

extension Worker {
    // T-38 が中身を書く（PLAN §8.9.6）。
    func stageCollectDeleteResults(_ ctx: TickContext) async {}

    // T-38 が中身を書く（PLAN §8.9.7）。
    func stageExpireDeleteRequests(_ ctx: TickContext) async {}

    // T-38 が中身を書く（PLAN §8.9.5）。
    func stageEvaluateDeletions(_ ctx: TickContext) async {}

    // T-39 が中身を書く（PLAN §8.9.1）。
    func stageSettleSkippedDeletions(_ ctx: TickContext) async {}

    // T-38 が中身を書く（PLAN §8.9.6）。
    func stageRunReaperIfNeeded(_ ctx: TickContext) async {}
}
