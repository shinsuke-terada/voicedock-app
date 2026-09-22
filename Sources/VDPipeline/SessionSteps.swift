// Session の工程（PLAN §5.6・§8.5）。T-18 は Worker と PartSteps が呼ぶ口だけを置く。本体は T-22。

/// Session の 1 件の処理の結果。
enum SessionStepResult: Equatable, Sendable { case stopped, empty, analyzed, saved }

/// Session の工程（本体は T-22）。
struct SessionSteps {
    /// 生成は `SessionSteps(ctx:)`（合成された init）。
    let ctx: TickContext

    // T-22 が中身を書く（PLAN §5.6）。
    func groupNewParts() throws {}

    // T-22 が中身を書く（PLAN §5.6）。
    func closeIdleSessions() throws {}

    /// 再オープン。行えたら true。TransitionConflict は false（PLAN §5.6）。
    // T-22 が中身を書く（PLAN §5.6）。
    func reopenSession(_ sessionKey: String) -> Bool { false }

    // T-22 が中身を書く（PLAN §8.5）。
    func process(sessionKey: String) async -> SessionStepResult { .stopped }
}
