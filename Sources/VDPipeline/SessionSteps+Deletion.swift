// Session の削除段（PLAN §8.9.5 deleteSourcesIfSafe。本体は T-38）。

extension SessionSteps {
    /// 削除の評価と要求。
    func deleteSourcesIfSafe(_ key: String) async {}  // T-38 が中身を書く
}
