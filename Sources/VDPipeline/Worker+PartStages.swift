// tick の段: manualRequeue・groupNewParts・requeueRecopied・closeIdleSessions・processPendingParts・requeueOnConnect（PLAN §5.4）。
import VDStore

extension Worker {
    /// 再試行ボタン（契機 3）。requeue() が積んだ理由を tick の先頭で行う。
    func stageManualRequeue(_ ctx: TickContext) {
        let reasons = pendingRequeues
        pendingRequeues = []
        for reason in reasons {
            requeueFailed(reason, ctx)
        }
    }

    func stageGroupNewParts(_ ctx: TickContext) {
        do {
            try SessionSteps(ctx: ctx).groupNewParts()
        } catch {
            warnStore(error)
        }
    }

    /// 契機 4（再コピーの完了）。
    func stageRequeueRecopied(_ ctx: TickContext) {
        do {
            _ = try Requeue(ctx: ctx).requeueRecopied()
        } catch {
            warnStore(error)
        }
    }

    /// idle が経った OPEN を閉じ（F-66: 日付では閉じない）、続けてパネルの今すぐ要約（F-66）を行う（同じ tick で要約まで進める）。
    func stageCloseIdleSessions(_ ctx: TickContext) {
        do {
            try SessionSteps(ctx: ctx).closeIdleSessions()
        } catch {
            warnStore(error)
        }
        stageSummarizeNow(ctx)
    }

    /// 一覧を先に確定（started_at, partkey 順）し、1 件ごとに工程内リトライ。停止要求は Part の区切りで効く。
    /// 停止の確認・活動の表示は ctx の stop / activity だけを使う（テストが ctx を差し替えて直接呼べる）。
    func stageProcessPendingParts(_ ctx: TickContext) async {
        let keys: [String]
        do {
            keys = try ctx.deps.store.nonTerminalPartkeys()
        } catch {
            ctx.warnStore(error)
            return
        }
        let steps = PartSteps(ctx: ctx)
        let retry = InProcessRetry(ctx: ctx)
        for key in keys {
            if ctx.stop.isSet { return }
            await retry.run(entity: .recording, key: key) { _ = await steps.process(partkey: key) }
            ctx.activity.set(.idle)
        }
    }

    /// 契機 2（接続の立ち上がり。起動後の最初の接続も含む）。
    func stageRequeueOnConnect(_ ctx: TickContext) {
        if let s = ctx.snapshot, s.connectEpoch > lastSeenConnectEpoch {
            requeueFailed(.connect, ctx)
            lastSeenConnectEpoch = s.connectEpoch
        }
    }
}
