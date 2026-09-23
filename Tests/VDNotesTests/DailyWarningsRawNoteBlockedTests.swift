// Daily の警告行の F-75（PLAN §8.6。issue #115）: 書き直すと本文が消えるので Raw ノートを書かずに止めた FAILED は別の行にする。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("DailyWarnings（F-75）")
struct DailyWarningsRawNoteBlockedTests {
    static let failedLine1 = "> ⚠ この日の録音のうち 1 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。"

    static func blockedLine(_ n: Int) -> String {
        "> ⚠ この日の録音のうち " + String(n)
            + " 本は Raw ノートに書けませんでした（書き直すと、文字起こしを読めなくなった録音の本文が Raw ノートから消えるため）。"
            + "自動では直りません。VoiceDock の要対応を確かめてください。"
    }

    func failed(_ name: String, blocked: Bool) -> ExcludedPart {
        ExcludedPart(
            partkey: "DJIMIC3/F/" + name + "_orig.wav", status: .failed, errorCode: .obsidianRawWriteFailed,
            unknownCode: nil, rawNoteBlocked: blocked)
    }

    @Test("F-75 Raw ノートを書かずに止めた FAILED は別の行（自動で再試行されますと書かない）")
    func blockedHasItsOwnLine() {
        #expect(DailyWarnings.lines(failed: [failed("f1", blocked: true)], skipped: []) == [Self.blockedLine(1)])
    }

    @Test("F-75 一時的な FAILED と混ざれば、FAILED の行が先で本数を分ける")
    func mixedFailuresSplit() {
        let lines = DailyWarnings.lines(
            failed: [failed("f1", blocked: true), failed("f2", blocked: false), failed("f3", blocked: true)],
            skipped: [])
        #expect(lines == [Self.failedLine1, Self.blockedLine(2)])
    }

    @Test("F-75 SKIPPED と合わせて 3 行（FAILED・止めた FAILED・SKIPPED の順）")
    func threeLines() {
        let skipped = ExcludedPart(
            partkey: "DJIMIC3/S/s1_orig.wav", status: .skipped, errorCode: .noSpeechDetected, unknownCode: nil)
        let lines = DailyWarnings.lines(
            failed: [failed("f1", blocked: false), failed("f2", blocked: true)], skipped: [skipped])
        #expect(
            lines == [
                Self.failedLine1, Self.blockedLine(1), "> この日の録音のうち 1 本を除外しました（無音）。自動では再試行されません。",
            ])
    }

    @Test("F-75 除外が無ければ行は無い（空の入力）・既定は止めた FAILED ではない")
    func emptyAndDefault() {
        #expect(DailyWarnings.lines(failed: [], skipped: []).isEmpty)
        let plain = ExcludedPart(
            partkey: "DJIMIC3/F/f_orig.wav", status: .failed, errorCode: .whisperFailed, unknownCode: nil)
        #expect(plain.rawNoteBlocked == false)
        #expect(DailyWarnings.lines(failed: [plain], skipped: []) == [Self.failedLine1])
    }
}
