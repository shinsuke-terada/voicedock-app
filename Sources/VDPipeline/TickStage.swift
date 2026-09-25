// tick の段（PLAN §5.4 の順。この宣言順 = 実行順 = SPEC の「Worker の tick の順」）。

/// tick の段（PLAN §5.4 の順。この宣言順 = 実行順 = SPEC の「Worker の tick の順」）。
enum TickStage: String, CaseIterable, Sendable {
    case manualRequeue, groupNewParts, requeueRecopied, closeIdleSessions, processPendingParts,
        refreshVaultIndex, processReadySessions, collectDeleteResults, expireDeleteRequests,
        evaluateDeletions, settleSkippedDeletions, runReaperIfNeeded, pendingJobs, requeueOnConnect

    /// snapshot が新鮮なときだけ行う段（PLAN §5.4）。
    static let requiresFreshSnapshot: Set<TickStage> = [
        .evaluateDeletions, .settleSkippedDeletions, .runReaperIfNeeded,
    ]
}
