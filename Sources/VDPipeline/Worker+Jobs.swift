// tick の段: pendingJobs（パネルが要求した仕事。PLAN §5.4・§8.11）と、closeIdleSessions の段の今すぐ要約（F-66）。

extension Worker {
    /// 今すぐ要約（PLAN §5.4・F-66）。closeIdleSessions の段の終わりで、列から `.summarizeNow` だけを取り出して
    /// 入れた順に行う（ほかの仕事は列に残り、pendingJobs の段が行う）。要約は同じ tick の processReadySessions が進める。
    func stageSummarizeNow(_ ctx: TickContext) {
        var replies: [@Sendable (Result<Int, SummarizeNowFailure>) -> Void] = []
        var rest: [WorkerJob] = []
        for job in pendingJobs {
            if case .summarizeNow(let reply) = job {
                replies.append(reply)
            } else {
                rest.append(job)
            }
        }
        pendingJobs = rest
        for reply in replies {
            // 停止要求が来ていても返事は必ず返す（.llmProbe と同じ）
            if ctx.stop.isSet {
                reply(.failure(SummarizeNowFailure(message: DiagnosticTexts.probeStopped)))
                continue
            }
            reply(SummarizeNow(ctx: ctx).run())
        }
    }

    /// 入れた順に 1 回ずつ実行する。先に列を空にしてから回す（実行中に入った仕事は次の tick）。
    /// snapshot の新鮮さによらず毎 tick 行う（T-18 §4.8 の並び）。
    /// `.summarizeNow` は実行せず、ループの後で列の先頭へ戻す（入れた順を保つ。F-66）。
    func stagePendingJobs(_ ctx: TickContext) async {
        let jobs = pendingJobs
        pendingJobs = []
        var deferred: [WorkerJob] = []
        for job in jobs {
            switch job {
            case .summarizeNow:
                // closeIdleSessions の段より後に入った分。次の tick のその段で行う（同じ tick の要約に間に合わせるため）
                deferred.append(job)
            case .llmProbe(let reply):
                // 停止要求が来ていても返事は必ず返す（.skip で返す）
                if ctx.stop.isSet {
                    reply(LLMProbeCheck.stopped)
                    continue
                }
                reply(await LLMProbeCheck(ctx: ctx).run())
            case .backlog(let action):
                // 停止要求が来ていれば実行せずに失敗で返す（.llmProbe と同じ。PLAN §5.4）
                if ctx.stop.isSet {
                    Self.replyStopped(job)
                    continue
                }
                await BacklogPlanner(deps: DeletionDependencies(ctx: ctx)).handle(action, kind: .backlog)
            case .resolveAbsent(let action):
                if ctx.stop.isSet {
                    Self.replyStopped(job)
                    continue
                }
                await BacklogPlanner(deps: DeletionDependencies(ctx: ctx)).handle(action, kind: .resolveAbsent)
            }
        }
        // ループの途中の await（LLMProbeCheck・BacklogPlanner）の間に停止要求が来たとき。requestStop は列に無い
        // deferred を知らないので、ここで返さないと返事が永久に返らない（前後どちらの位置の .summarizeNow も）
        if ctx.stop.isSet {
            for job in deferred { Self.replyStopped(job) }
            return
        }
        pendingJobs = deferred + pendingJobs
    }

    /// 実行せずに `.fail` で返事をする（設定エラー中の tick。PLAN §6.1）。
    static func replyUnavailable(_ job: WorkerJob) {
        switch job {
        case .llmProbe(let reply): reply(LLMProbeCheck.unavailable)
        case .backlog(let action), .resolveAbsent(let action): replyFailure(action, DiagnosticTexts.configMissing)
        case .summarizeNow(let reply): reply(.failure(SummarizeNowFailure(message: DiagnosticTexts.configMissing)))
        }
    }

    /// 実行せずに `.skip` で返事をする（停止要求の後に来た仕事・待っていた仕事）。
    static func replyStopped(_ job: WorkerJob) {
        switch job {
        case .llmProbe(let reply): reply(LLMProbeCheck.stopped)
        case .backlog(let action), .resolveAbsent(let action): replyFailure(action, DiagnosticTexts.probeStopped)
        case .summarizeNow(let reply): reply(.failure(SummarizeNowFailure(message: DiagnosticTexts.probeStopped)))
        }
    }

    /// ガードで止めた tick（ライセンス）の仕事に、実行せずに失敗で返事をする。文言はガードの理由の語（F-82。今すぐ要約の
    /// 「当たった理由の pauseWord」と同じ。PLAN §5.4・§8.14）
    static func replyPaused(_ job: WorkerJob, _ message: String) {
        switch job {
        case .llmProbe(let reply): reply(LLMProbeCheck.fail(message))
        case .backlog(let action), .resolveAbsent(let action): replyFailure(action, message)
        case .summarizeNow(let reply): reply(.failure(SummarizeNowFailure(message: message)))
        }
    }

    /// 後追いの仕事を実行せずに失敗で返事をする（設定エラー中・停止要求の後。文言は DR-09 と同じ）
    static func replyFailure(_ action: BacklogAction, _ message: String) {
        switch action {
        case .preview(let reply): reply(.failure(BacklogFailure(message: message)))
        case .execute(_, let reply): reply(.failure(BacklogFailure(message: message)))
        }
    }
}
