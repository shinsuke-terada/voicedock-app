// Daily ノートの警告行（PLAN §8.6 / NOTE-05。T-27 §5.2）。
import Foundation
import Testing
import VDCore

@testable import VDNotes

@Suite("DailyWarnings")
struct DailyWarningsTests {
    static let failedLine = "> ⚠ この日の録音のうち 1 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。"

    func failed(_ code: ErrorCode? = .whisperFailed) -> ExcludedPart {
        ExcludedPart(partkey: "DJIMIC3/F/f_orig.wav", status: .failed, errorCode: code, unknownCode: nil)
    }

    func skipped(_ code: ErrorCode?, unknown: String? = nil, key: String = "DJIMIC3/S/s_orig.wav") -> ExcludedPart {
        ExcludedPart(partkey: key, status: .skipped, errorCode: code, unknownCode: unknown)
    }

    @Test("FAILED だけ")
    func failedOnly() {
        #expect(DailyWarnings.lines(failed: [failed()], skipped: []) == [Self.failedLine])
    }

    @Test("無音だけなら ⚠ を付けない")
    func silenceAloneDoesNotWarn() {
        #expect(
            DailyWarnings.lines(failed: [], skipped: [skipped(.noSpeechDetected)]) == [
                "> この日の録音のうち 1 本を除外しました（無音）。自動では再試行されません。"
            ])
    }

    @Test("無音と重複（順によらない）")
    func benignPairIsOrdered() {
        let expected = ["> この日の録音のうち 2 本を除外しました（重複・無音）。自動では再試行されません。"]
        #expect(
            DailyWarnings.lines(failed: [], skipped: [skipped(.duplicateContent), skipped(.noSpeechDetected)])
                == expected)
        #expect(
            DailyWarnings.lines(failed: [], skipped: [skipped(.noSpeechDetected), skipped(.duplicateContent)])
                == expected)
    }

    @Test("元ファイル不在は操作を促す")
    func missingSourceIsActionable() {
        #expect(
            DailyWarnings.lines(failed: [], skipped: [skipped(.sourceMissing)]) == [
                "> ⚠ この日の録音のうち 1 本を除外しました（元ファイルが見つかりません）。自動では再試行されません。デバイスから採り直してください。"
            ])
    }

    @Test("1 件でも操作が要れば行全体に ⚠")
    func oneActionableMarksLine() {
        #expect(
            DailyWarnings.lines(failed: [], skipped: [skipped(.noSpeechDetected), skipped(.sourceMissing)]) == [
                "> ⚠ この日の録音のうち 2 本を除外しました（元ファイルが見つかりません・無音）。自動では再試行されません。デバイスから採り直してください。"
            ])
    }

    @Test("未知の理由は操作が要る側")
    func unknownReasonIsActionable() {
        #expect(
            DailyWarnings.lines(failed: [], skipped: [skipped(nil, unknown: "SOMETHING_NEW")]) == [
                "> ⚠ この日の録音のうち 1 本を除外しました（SOMETHING_NEW）。自動では再試行されません。デバイスから採り直してください。"
            ])
    }

    @Test("理由なしは「理由不明」")
    func noReasonIsUnknown() {
        #expect(
            DailyWarnings.lines(failed: [], skipped: [skipped(nil)]) == [
                "> ⚠ この日の録音のうち 1 本を除外しました（理由不明）。自動では再試行されません。デバイスから採り直してください。"
            ])
        #expect(DailyWarnings.displayName(nil) == "理由不明")
        #expect(DailyWarnings.displayName(.duplicateContent) == "重複")
    }

    @Test("同じ順位はコードの辞書順")
    func tiesAreSortedByCode() {
        let parts = [skipped(nil, unknown: "ZZZ"), skipped(nil, unknown: "AAA"), skipped(nil)]
        #expect(
            DailyWarnings.lines(failed: [], skipped: parts) == [
                "> ⚠ この日の録音のうち 3 本を除外しました（理由不明・AAA・ZZZ）。自動では再試行されません。デバイスから採り直してください。"
            ])
    }

    @Test("表示名の重複は除かない")
    func displayNamesAreNotDeduped() {
        #expect(
            DailyWarnings.lines(failed: [], skipped: [skipped(.sourceMissing), skipped(.normalizedMissing)]) == [
                "> ⚠ この日の録音のうち 2 本を除外しました（元ファイルが見つかりません・元ファイルが見つかりません）。自動では再試行されません。デバイスから採り直してください。"
            ])
    }

    @Test("FAILED と SKIPPED は別の行")
    func bothKindsGetOwnLine() {
        #expect(
            DailyWarnings.lines(failed: [failed()], skipped: [skipped(.noSpeechDetected)]) == [
                Self.failedLine, "> この日の録音のうち 1 本を除外しました（無音）。自動では再試行されません。",
            ])
    }

    @Test("SKIPPED に「再試行されます」と書かない")
    func skippedNeverPromisesRetry() {
        let codes: [ErrorCode?] = [nil] + ErrorCode.allCases.map { $0 }
        for code in codes {
            for other in codes {
                let lines = DailyWarnings.lines(failed: [], skipped: [skipped(code), skipped(other)])
                #expect(lines.count == 1)
                #expect(lines.allSatisfy { !$0.contains("自動で再試行されます") })
            }
        }
        let unknown = DailyWarnings.lines(failed: [], skipped: [skipped(nil, unknown: "SOMETHING_NEW")])
        #expect(unknown.allSatisfy { !$0.contains("自動で再試行されます") })
    }

    @Test("benign は無音と重複の 2 つだけ")
    func benignIsExactlyTwo() {
        #expect(SkipReasons.benign == [.noSpeechDetected, .duplicateContent])
    }

    @Test("何も無ければ空")
    func emptyInputs() {
        #expect(DailyWarnings.lines(failed: [], skipped: []) == [])
    }
}
