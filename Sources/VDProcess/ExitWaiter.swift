// 子の終了を DispatchSource（kqueue の NOTE_EXIT）と continuation で待つ。waitpid で actor を止めない（PLAN §2.1）。
import Darwin
import Foundation
import Synchronization

enum ExitWaiter {
    /// NOTE_EXIT の取りこぼしに備えて waitpid(WNOHANG) を見直す間隔（起動直後）
    static let pollInterval: DispatchTimeInterval = .milliseconds(100)
    /// pollInterval で見直す回数。過ぎたら slowPollInterval に落とす（取りこぼしは登録の前後にしか起きない。llama-server は数時間動く）
    static let fastPollCount = 50
    /// fastPollCount を過ぎた後の見直しの間隔
    static let slowPollInterval: DispatchTimeInterval = .seconds(5)

    /// waitpid の生の status を返す。回収できなかった（ECHILD など）ときは nil
    static func wait(pid: pid_t) async -> Int32? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            let queue = DispatchQueue(label: "voicedock.process.exit")
            let watch = ExitWatch()
            let reap: @Sendable () -> Void = {
                var status: Int32 = 0
                var r: pid_t
                repeat { r = waitpid(pid, &status, WNOHANG) } while r == -1 && errno == EINTR
                if r == pid {
                    if watch.claim() { continuation.resume(returning: status) }
                } else if r == -1 {
                    if watch.claim() { continuation.resume(returning: nil) }
                }
                // r == 0: まだ終わっていない。次のイベントを待つ
            }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            // 予備: kqueue への登録は resume の後に非同期で行われ、その前後に終わった子の NOTE_EXIT が届かないことがある
            // （並行に 20 本を 20 回起動して十数本を取りこぼした）。pollInterval ごとに waitpid(WNOHANG) を見直す
            let timer = DispatchSource.makeTimerSource(queue: queue)
            watch.attach(source, timer: timer)  // どちらも resume より前に渡す（claim が取り消せるように）
            source.setEventHandler(handler: reap)
            timer.setEventHandler {
                reap()
                watch.tick()
            }
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: 0), repeating: pollInterval)
            source.resume()
            timer.resume()
            queue.async(execute: reap)  // source を登録する前に既に終わっていた場合（取りこぼしを防ぐ）
        }
    }
}

final class ExitWatch: Sendable {
    private let state: Mutex<State>
    struct State {
        var resumed = false
        var source: (any DispatchSourceProcess)? = nil
        var timer: (any DispatchSourceTimer)? = nil
        var ticks = 0
    }
    init() { state = Mutex(State()) }
    func attach(_ s: any DispatchSourceProcess, timer t: any DispatchSourceTimer) {
        state.withLock { st in
            st.source = s
            st.timer = t
        }
    }
    /// 予備のタイマーが 1 回鳴った。fastPollCount 回目で slowPollInterval に落とす
    func tick() {
        state.withLock { st in
            st.ticks += 1
            if st.ticks == ExitWaiter.fastPollCount {
                st.timer?.schedule(
                    deadline: DispatchTime(uptimeNanoseconds: 0), repeating: ExitWaiter.slowPollInterval,
                    leeway: .seconds(1))
            }
        }
    }
    /// 最初の 1 回だけ true。source（NOTE_EXIT と予備のタイマー）を取り消して手放す
    func claim() -> Bool {
        state.withLock { st in
            if st.resumed { return false }
            st.resumed = true
            st.source?.cancel()
            st.source = nil
            st.timer?.cancel()
            st.timer = nil
            return true
        }
    }
}
