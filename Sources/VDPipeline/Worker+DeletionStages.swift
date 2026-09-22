// 削除の段（PLAN §5.4・§8.9.5〜§8.9.7）。settleSkippedDeletions は T-39。

extension Worker {
    func stageCollectDeleteResults(_ ctx: TickContext) async {
        await ResultCollector(deps: DeletionDependencies(ctx: ctx)).collectDeleteResults(
            reaperScanGeneration: reaperScanGeneration)
    }

    func stageExpireDeleteRequests(_ ctx: TickContext) async {
        await RequestExpirer(deps: DeletionDependencies(ctx: ctx)).expireDeleteRequests()
    }

    /// deleteEvaluated の Session を updated_at, session_key の順に、backoff を過ぎたものだけ（DEL-14）
    func stageEvaluateDeletions(_ ctx: TickContext) async {
        let stage = SessionDeletionStage(deps: DeletionDependencies(ctx: ctx))
        for key in stage.dueSessionKeys() {
            if ctx.stop.isSet { return }
            await stage.deleteSourcesIfSafe(sessionKey: key)
        }
    }

    func stageRunReaperIfNeeded(_ ctx: TickContext) async {
        let current = reaperScanGeneration
        reaperScanGeneration = await ResultCollector(deps: DeletionDependencies(ctx: ctx)).runReaperIfNeeded(
            reaperScanGeneration: current)
    }

    // T-39 が中身を書く（PLAN §8.9.5 根拠 B）。
    func stageSettleSkippedDeletions(_ ctx: TickContext) async {}
}
