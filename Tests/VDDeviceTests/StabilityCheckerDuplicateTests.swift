// 安定性判定で正準等価な relpath・重複した relpath が並んでも落ちない（F-71・#120。C4）。stat は台本の閉包、待ちは RecordingSleeper。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDDevice

@Suite("StabilityChecker の重複した候補（F-71）")
struct StabilityCheckerDuplicateTests {
    /// 2026-09-21T13:33:20Z
    static let nowSeconds: Double = 1_790_000_000
    static let clock = FixedClock(epochMillis: 1_790_000_000_000)
    /// 「が」の NFC（U+304C）と NFD（U+304B U+3099）。String としては等しい
    static let nfc = "TX_MIC001_20260829_071201/\u{304C}.WAV"
    static let nfd = "TX_MIC001_20260829_071201/\u{304B}\u{3099}.WAV"

    static func checker(_ sleeper: any Sleeper) -> StabilityChecker {
        StabilityChecker(config: AppConfig.defaults(timeZone: "Asia/Tokyo").device, clock: clock, sleeper: sleeper)
    }

    /// スカラー列で比べて、NFC なら size 1、NFD なら size 2 を返す
    static func stat(mtime: Double) -> @Sendable (String) -> FileStat? {
        { rel in
            rel.unicodeScalars.elementsEqual(nfc.unicodeScalars)
                ? FileStat(size: 1, mtime: mtime) : FileStat(size: 2, mtime: mtime)
        }
    }

    @Test("F-71 正準等価な relpath が並んでも落ちず、先に並んだ候補の観測を残す（fast path）")
    func canonicallyEquivalentCandidatesFastPath() async {
        let sleeper = RecordingSleeper()
        let result = await Self.checker(sleeper).stableCandidates(
            [Self.nfc, Self.nfd], stat: Self.stat(mtime: Self.nowSeconds - 3600))
        #expect(result.count == 1)
        #expect(result[Self.nfc] == FileStat(size: 1, mtime: 1_789_996_400))
        #expect(sleeper.recorded == [])
    }

    @Test("F-71 並びが逆なら NFD の候補の観測を残す（決定的）")
    func canonicallyEquivalentCandidatesReversed() async {
        let sleeper = RecordingSleeper()
        let result = await Self.checker(sleeper).stableCandidates(
            [Self.nfd, Self.nfc], stat: Self.stat(mtime: Self.nowSeconds - 3600))
        #expect(result.count == 1)
        #expect(result[Self.nfd] == FileStat(size: 2, mtime: 1_789_996_400))
    }

    @Test("F-71 正準等価な relpath が並んでも落ちない（待ってから判定する経路）")
    func canonicallyEquivalentCandidatesSlowPath() async {
        let sleeper = RecordingSleeper()
        let result = await Self.checker(sleeper).stableCandidates(
            [Self.nfc, Self.nfd], stat: Self.stat(mtime: Self.nowSeconds))
        #expect(result.count == 1)
        #expect(result[Self.nfc] == FileStat(size: 1, mtime: 1_790_000_000))
        #expect(sleeper.recorded == [3, 3])
    }

    @Test("F-71 同じ relpath が 2 度並んでも（FAT の重複項目）落ちない")
    func identicalCandidates() async {
        let sleeper = RecordingSleeper()
        let result = await Self.checker(sleeper).stableCandidates(
            ["a.WAV", "a.WAV"], stat: { _ in FileStat(size: 7, mtime: 1_789_996_400) })
        #expect(result == ["a.WAV": FileStat(size: 7, mtime: 1_789_996_400)])
    }
}
