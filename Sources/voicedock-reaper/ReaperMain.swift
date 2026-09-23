// 起動時の検査 → flock → 走査 → 1 件ずつ（PLAN §8.9.4）。
import Foundation
import VDContract

struct ReaperExit: Equatable, Sendable {
    let code: Int32
    /// 空なら何も書かない
    let stdout: String
    let stderr: String

    static let ok = ReaperExit(code: 0, stdout: "", stderr: "")
}

enum ReaperMain {
    /// 終了コード: 0 正常 / 2 引数不正・conf 不正 / 3 RV-00 / 4 ロックが取れない
    static func run(arguments: [String]) -> ReaperExit {
        let home: String
        switch ReaperArguments.parse(arguments) {
        case .version:
            // RV-00 より前に。ほかの I/O はしない
            return ReaperExit(code: 0, stdout: AppVersion.string + "\n", stderr: "")
        case .invalid:
            // 何も読まない・書かない
            return ReaperExit(code: 2, stdout: "", stderr: ReaperArguments.usage)
        case .run(let value):
            home = value
        }
        // RV-00。何も書かない（ログも開かない）
        guard SelfLocation.isAtExpectedPlace(home: home) else { return ReaperExit(code: 3, stdout: "", stderr: "") }
        let layout = HomeLayout(root: URL(fileURLWithPath: ReaperIO.realpath(home) ?? home, isDirectory: true))
        let log = ReaperLog(url: layout.reaperLog)
        let clock = ReaperClock()
        defer { log.close() }
        log.info(ReaperLog.Event.started)
        // reaper.conf。無い・読めない・不正は conf_invalid（要求に触らない）
        let conf: ReaperConf
        switch ReaperConf.observe(at: layout.reaperConf) {
        case .valid(let value):
            conf = value
        case .missing, .invalid:
            log.info(ReaperLog.Event.disabled, [(ReaperLog.Key.reason, IdentityReason.confInvalid)])
            return ReaperExit(code: 2, stdout: "", stderr: "")
        }
        // RV-01。要求に触らない
        guard conf.deleteSourceAudio else {
            log.info(ReaperLog.Event.disabled, [(ReaperLog.Key.reason, IdentityReason.lock1)])
            return .ok
        }
        // flock。1 回だけ試す（待たない。PLAN §2.1）。終わるまで持ち続ける
        guard let lock = FileLock.tryAcquire(url: layout.reaperLock) else {
            log.warn(ReaperLog.Event.busy)
            return ReaperExit(code: 4, stdout: "", stderr: "")
        }
        defer { lock.release() }
        Signals.installTerminationHandler()
        guard let queue = QueueFiles.make(layout: layout) else {
            log.info(ReaperLog.Event.completed, [(ReaperLog.Key.requests, "0")])
            return .ok
        }
        // ProcessedLog は値型。RequestProcessor が持つ 1 つだけが更新される
        var proc = RequestProcessor(
            layout: layout, conf: conf, queue: queue, log: log, clock: clock,
            processed: ProcessedLog(url: layout.processedLog))
        let scanned = scan(
            queue.names(), stopRequested: { Signals.stopRequested }, process: { proc.process(name: $0) })
        log.info(ReaperLog.Event.completed, [(ReaperLog.Key.requests, String(scanned.requests))])
        return ReaperExit(code: scanned.code, stdout: "", stderr: "")
    }

    /// 走査の本体。names を順に process に渡す。requests はこの実行で処理した要求の数
    /// （rejected/ へ退避したものを含む。SIGTERM で止めたらそこまで）。
    /// 列挙の後に消えていた要求（`.gone`）は数えずに次へ。unlink の直前にロック 1 が閉じていた（`.stopped`。走行中の無効化）ら
    /// 数えずに残りの要求に進まず、終了コードは起動時と同じ（lock1 は 0、conf_invalid は 2）にする（F-73）
    static func scan(
        _ names: [String], stopRequested: () -> Bool, process: (String) -> RequestOutcome
    ) -> (requests: Int, code: Int32) {
        var count = 0
        for name in names {
            // 次の要求に進まない（処理中の 1 件は終わっている）
            if stopRequested() { break }
            let outcome = process(name)
            if outcome == .gone { continue }
            if case .stopped(let reason) = outcome {
                return (count, reason == IdentityReason.confInvalid ? 2 : 0)
            }
            count += 1
        }
        return (count, 0)
    }
}
