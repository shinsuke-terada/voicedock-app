// Raw ノートを保存した直後の削除評価（PLAN §5.5。その Part だけでなく Session の全 Part）。

extension PartSteps {
    /// 書いた要求の数（requestDeletions(session)。snapshot の新鮮さは要求を書く直前に確かめる。DEL-20）。
    func requestDeletionsAfterRawNote(sessionKey: String) async -> Int {
        await DeletionRequester(deps: DeletionDependencies(ctx: ctx)).requestDeletions(sessionKey: sessionKey)
    }
}
