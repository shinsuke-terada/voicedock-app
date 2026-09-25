// Session の削除段（PLAN §8.9.5 deleteSourcesIfSafe）。SAVED の直後に backoff を見ずに 1 回。

extension SessionSteps {
    /// 削除の評価と要求。
    func deleteSourcesIfSafe(_ key: String) async {
        await SessionDeletionStage(deps: DeletionDependencies(ctx: ctx)).deleteSourcesIfSafe(sessionKey: key)
    }
}
