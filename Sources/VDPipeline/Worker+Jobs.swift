// tick の段: pendingJobs（パネルが要求した仕事。PLAN §5.4・§8.11）。

extension Worker {
    /// 入れた順に 1 回ずつ実行する。先に列を空にしてから回す（実行中に入った仕事は次の tick）。
    /// snapshot の新鮮さによらず毎 tick 行う（T-18 §4.8 の並び）。
    func stagePendingJobs(_ ctx: TickContext) async {
        let jobs = pendingJobs
        pendingJobs = []
        for job in jobs {
            switch job {
            case .llmProbe(let reply):
                // 停止要求が来ていても返事は必ず返す（.skip で返す）
                if ctx.stop.isSet {
                    reply(LLMProbeCheck.stopped)
                    continue
                }
                reply(await LLMProbeCheck(ctx: ctx).run())
            }
        }
    }

    /// 実行せずに `.skip` で返事をする（停止要求の後に来た仕事・待っていた仕事）。
    static func replyStopped(_ job: WorkerJob) {
        switch job {
        case .llmProbe(let reply): reply(LLMProbeCheck.stopped)
        }
    }
}
