// tick の段: processReadySessions（PLAN §5.4・§5.6。本体は T-22）。

extension Worker {
    // T-22 が中身を書く（PLAN §5.6）。
    func stageProcessReadySessions(_ ctx: TickContext) async {}
}
