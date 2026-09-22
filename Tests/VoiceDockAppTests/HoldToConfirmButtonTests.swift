// 長押しで確かめるボタンの時間の計算（T-40 §4.7・F-65）。ビューは作らない。純粋な関数と Tracker だけを見る。
import Testing

@testable import VoiceDockApp

@Suite("HoldToConfirmButton")
struct HoldToConfirmButtonTests {
    typealias Progress = HoldToConfirmButton.Progress

    @Test("押し続ける時間は 3 秒（PLAN §8.9.8 の 2）")
    func holdDurationIsThreeSeconds() {
        #expect(HoldToConfirmButton.holdDuration == 3.0)
    }

    @Test(
        "経過時間 → 進捗と完了（0 秒・1.5 秒・3.0 秒・それより後）",
        arguments: [
            (0.0, Progress(fraction: 0, complete: false)),
            (1.5, Progress(fraction: 0.5, complete: false)),
            (3.0, Progress(fraction: 1, complete: true)),
            (4.5, Progress(fraction: 1, complete: true)),
        ])
    func progressFollowsElapsedTime(elapsed: Double, expected: Progress) {
        #expect(HoldToConfirmButton.progress(elapsed: elapsed) == expected)
    }

    @Test("2.99 秒ではまだ完了しない（リングはほぼ満ちている）")
    func almostThereIsNotComplete() {
        let p = HoldToConfirmButton.progress(elapsed: 2.99)
        #expect(p.complete == false)
        #expect(p.fraction > 0.99 && p.fraction < 1)
    }

    @Test("TEST-28 押した瞬間（0 秒）と負の経過は完了せず、進捗は 0")
    func zeroAndNegativeElapsedAreNotComplete() {
        #expect(HoldToConfirmButton.progress(elapsed: 0) == Progress(fraction: 0, complete: false))
        #expect(HoldToConfirmButton.progress(elapsed: -1) == Progress(fraction: 0, complete: false))
    }

    @Test("押していなければ進捗は 0 で、完了を知らせない")
    func idleTrackerNeverFires() {
        var t = HoldToConfirmButton.Tracker()
        #expect(t.isHolding == false)
        #expect(t.progress(at: 100) == Progress(fraction: 0, complete: false))
        #expect(t.tick(at: 100) == false)
    }

    @Test("3 秒押し続けたら完了を 1 回だけ知らせる（押したままの次の tick では知らせない）")
    func firesExactlyOnce() {
        var t = HoldToConfirmButton.Tracker()
        t.press(at: 10)
        #expect(t.tick(at: 10) == false)
        #expect(t.tick(at: 11.5) == false)
        #expect(t.tick(at: 12.99) == false)
        #expect(t.tick(at: 13.0) == true)
        #expect(t.tick(at: 13.016) == false)
        #expect(t.tick(at: 20) == false)
        #expect(t.progress(at: 20) == Progress(fraction: 1, complete: true))
    }

    @Test("途中で離すと何もしない（離した後の tick も、時間が過ぎても知らせない）")
    func releasingEarlyCancels() {
        var t = HoldToConfirmButton.Tracker()
        t.press(at: 10)
        #expect(t.tick(at: 11.5) == false)
        #expect(t.progress(at: 11.5) == Progress(fraction: 0.5, complete: false))
        t.release()
        #expect(t.isHolding == false)
        #expect(t.progress(at: 14) == Progress(fraction: 0, complete: false))
        #expect(t.tick(at: 14) == false)
    }

    @Test("onEnded を経ずに押下が取り消されたら、3 秒に達していても知らせずに最初に戻す")
    func cancelledGestureNeverFires() {
        var t = HoldToConfirmButton.Tracker()
        t.press(at: 10)
        #expect(t.tick(at: 11) == false)
        #expect(t.tick(at: 13, stillPressed: false) == false)
        #expect(t.isHolding == false)
        #expect(t.tick(at: 14) == false)
    }

    @Test("押し直すと 0 から数え直す（離す前の時間を足さない）")
    func pressingAgainStartsOver() {
        var t = HoldToConfirmButton.Tracker()
        t.press(at: 10)
        #expect(t.tick(at: 12) == false)
        t.release()
        t.press(at: 20)
        #expect(t.tick(at: 21) == false)
        #expect(t.tick(at: 23) == true)
    }

    @Test("押している間の 2 回目の press は押し始めの時刻を動かさない")
    func secondPressWhileHoldingIsIgnored() {
        var t = HoldToConfirmButton.Tracker()
        t.press(at: 10)
        t.press(at: 12)
        #expect(t.tick(at: 13) == true)
    }

    @Test("完了して離した後、もう一度 3 秒押せばもう一度知らせる（1 回の押下につき 1 回）")
    func eachPressFiresOnce() {
        var t = HoldToConfirmButton.Tracker()
        t.press(at: 0)
        #expect(t.tick(at: 3) == true)
        t.release()
        t.press(at: 10)
        #expect(t.tick(at: 12) == false)
        #expect(t.tick(at: 13) == true)
        #expect(t.tick(at: 14) == false)
    }
}
