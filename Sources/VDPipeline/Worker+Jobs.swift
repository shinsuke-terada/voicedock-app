// tick の段: pendingJobs（パネルが要求した仕事。PLAN §5.4・§8.11。本体は T-32）。

extension Worker {
    // T-32 が中身を書く（PLAN §8.11）。
    func stagePendingJobs(_ ctx: TickContext) async {}
}
