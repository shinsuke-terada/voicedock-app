// SpeakerAssigner のテスト（T-48 §5。PLAN §8.4.1）。
import Foundation
import Testing
import VDCore

@testable import VDTranscribe

@Suite("SpeakerAssigner")
struct SpeakerAssignerTests {
    static func seg(_ start: Double, _ end: Double, _ text: String = "x") -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    static func turn(_ start: Double, _ end: Double, _ speaker: String) -> SpeakerTurn {
        SpeakerTurn(start: start, end: end, speaker: speaker)
    }

    @Test("重なりの最も長い話者を付ける")
    func maxOverlapWins() {
        // 2 つ目の区間 [1,2] は X だけ。1 つ目が Y（A）なら X は B になる（最小を取ると 2 つとも A）
        let turns = [Self.turn(0, 3, "X"), Self.turn(3, 10, "Y")]
        let out = SpeakerAssigner.assign([Self.seg(0, 10), Self.seg(1, 2)], turns: turns)
        #expect(
            out == [
                TranscriptSegment(start: 0, end: 10, text: "x", speaker: "A"),
                TranscriptSegment(start: 1, end: 2, text: "x", speaker: "B"),
            ])
    }

    @Test("ラベルは区間の順に初めて出た順")
    func labelsFollowSegmentOrder() {
        // RTTM の先の行は後で話す人（RTTM の名前 A）。区間は先に話す人（RTTM の名前 B）の発話が先。
        // 区間の順に初めて出た順なので、B の人が A、A の人が B（RTTM の名前のまま・RTTM の順ではない）
        let turns = [Self.turn(5, 7, "A"), Self.turn(0, 2, "B")]
        let out = SpeakerAssigner.assign([Self.seg(0, 2, "一"), Self.seg(5, 7, "二")], turns: turns)
        #expect(
            out == [
                TranscriptSegment(start: 0, end: 2, text: "一", speaker: "A"),
                TranscriptSegment(start: 5, end: 7, text: "二", speaker: "B"),
            ])
    }

    @Test("同点は RTTM で先に出た話者")
    func tieGoesToEarlierRTTMSpeaker() {
        // 区間 [0,4]（X と Y が同点）・[2.5,3.5]（Y だけ）・[0.5,1.5]（X だけ）。ラベルの並びで 1 つ目の側を見分ける
        let turns = [Self.turn(0, 2, "X"), Self.turn(2, 4, "Y")]
        let out = SpeakerAssigner.assign([Self.seg(0, 4), Self.seg(2.5, 3.5), Self.seg(0.5, 1.5)], turns: turns)
        // 1 つ目は X（A）。2 つ目は Y だけ（B）。3 つ目は X だけ（A）
        #expect(out.map(\.speaker) == ["A", "B", "A"])
    }

    @Test("重なりが無ければ 1 秒以内の最も近い話者")
    func nearestWithinTolerance() {
        let out = SpeakerAssigner.assign([Self.seg(5, 6)], turns: [Self.turn(6.5, 8, "X")])
        #expect(out == [TranscriptSegment(start: 5, end: 6, text: "x", speaker: "A")])
    }

    @Test("1 秒より離れていれば話者なし")
    func beyondToleranceIsNil() {
        #expect(SpeakerAssigner.nearestToleranceSeconds == 1.0)
        let out = SpeakerAssigner.assign([Self.seg(5, 6)], turns: [Self.turn(7.1, 8, "X")])
        #expect(out == [TranscriptSegment(start: 5, end: 6, text: "x", speaker: nil)])
    }

    @Test("同じ話者の複数の行の重なりを足す")
    func sumsAcrossTurns() {
        // 区間 [0,10]（X は 3 + 3 = 6、Y は 4）・[4,6]（Y だけ）。ラベルの並びで 1 つ目の側を見分ける
        let turns = [Self.turn(3, 7, "Y"), Self.turn(0, 3, "X"), Self.turn(7, 10, "X")]
        let out = SpeakerAssigner.assign([Self.seg(0, 10), Self.seg(4, 6)], turns: turns)
        // 1 つ目は X（6 > 4）で A。2 つ目は Y だけで B
        #expect(out.map(\.speaker) == ["A", "B"])
    }

    @Test("長さ 0 の区間は近さで決める")
    func zeroLengthSegment() {
        let out = SpeakerAssigner.assign([Self.seg(2, 2)], turns: [Self.turn(1, 3, "X")])
        #expect(out == [TranscriptSegment(start: 2, end: 2, text: "x", speaker: "A")])
    }

    @Test("RTTM が空なら全部話者なし（TEST-28）")
    func emptyTurns() {
        let segments = [Self.seg(0, 3.2, "おはようございます。"), Self.seg(5.5, 9.0, "今日の予定を確認します。")]
        let out = SpeakerAssigner.assign(segments, turns: [])
        #expect(
            out == [
                TranscriptSegment(start: 0, end: 3.2, text: "おはようございます。", speaker: nil),
                TranscriptSegment(start: 5.5, end: 9.0, text: "今日の予定を確認します。", speaker: nil),
            ])
    }

    @Test("区間が空なら空（TEST-28）")
    func emptySegments() {
        #expect(SpeakerAssigner.assign([], turns: [Self.turn(0, 1, "X")]) == [])
    }

    @Test("区間に付かなかった話者はラベルを使わない")
    func unusedSpeakerConsumesNoLabel() {
        let turns = [Self.turn(0, 1, "X"), Self.turn(10, 11, "Y"), Self.turn(20, 21, "Z")]
        let out = SpeakerAssigner.assign([Self.seg(0, 1), Self.seg(20, 21)], turns: turns)
        #expect(out.map(\.speaker) == ["A", "B"])
    }
}
