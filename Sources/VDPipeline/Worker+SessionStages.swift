// tick の段: processReadySessions（PLAN §5.4・§5.6。voicedock worker.py:326-340, 391-412）。
import VDCore
import VDStore

extension Worker {
    /// Part が全部終端の processable な Session を session_key 順に処理し、終わりで必ず llama-server を止める。
    /// 一覧は先に確定する。Part が 0 件の Session は対象にしない。停止要求は Session の区切りで効く。
    func stageProcessReadySessions(_ ctx: TickContext) async {
        let store = ctx.deps.store
        var keys: [String] = []
        do {
            // 宣言順
            for status in SessionStatus.allCases where SessionStates.processable.contains(status) {
                // session_key 順
                for row in try store.sessions(status: status) {
                    let parts = try store.recordings(inSession: row.sessionKey)
                    if !parts.isEmpty && parts.allSatisfy({ PartStates.terminal.contains($0.status) }) {
                        keys.append(row.sessionKey)
                    }
                }
            }
        } catch {
            ctx.warnStore(error)
        }
        // 最終的な処理順は session_key（コードポイント）昇順
        keys.sort { $0.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
        var c = ctx
        c.vaultIndex = vaultIndex
        let steps = SessionSteps(ctx: c)
        let retry = InProcessRetry(ctx: ctx)
        for key in keys {
            if ctx.stop.isSet { break }
            // 工程内リトライ（毎回 Map からやり直す）
            await retry.run(entity: .session, key: key) { _ = await steps.process(sessionKey: key) }
            ctx.activity.set(.idle)
        }
        // 必ず止める（空でも・停止要求で抜けても。18 GB を常駐させない。§2.1）
        await ctx.deps.llama.stop()
    }
}
