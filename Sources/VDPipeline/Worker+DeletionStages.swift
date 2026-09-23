// 削除の段（PLAN §5.4・§8.9.5〜§8.9.7）。

extension Worker {
    func stageCollectDeleteResults(_ ctx: TickContext) async {
        await ResultCollector(deps: DeletionDependencies(ctx: ctx)).collectDeleteResults(
            reaperScanGeneration: reaperScanGeneration)
    }

    func stageExpireDeleteRequests(_ ctx: TickContext) async {
        await RequestExpirer(deps: DeletionDependencies(ctx: ctx)).expireDeleteRequests()
    }

    /// SessionDeletionStage.isEvaluated の Session（deleteEvaluated に在るか、COMPLETED で ID の無い RAW_SAVED の Part を持つ。F-80）を
    /// updated_at, session_key の順に、backoff を過ぎたものだけ（DEL-14）
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

    /// 根拠 B（PLAN §8.9.5）。evaluateDeletions の後・runReaperIfNeeded の前。snapshot が新鮮な tick だけ
    func stageSettleSkippedDeletions(_ ctx: TickContext) async {
        _ = await SkippedSettler(deps: DeletionDependencies(ctx: ctx)).settleSkippedDeletions()
    }
}
