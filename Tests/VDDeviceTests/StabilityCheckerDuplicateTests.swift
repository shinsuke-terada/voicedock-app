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

    @Test(
        "F-71 重複した候補でも 1 回の待ちで 2 回数えない（3 回目の標本で size が変われば安定にしない）",
        arguments: [[StabilityCheckerDuplicateTests.nfc, StabilityCheckerDuplicateTests.nfd], ["a.WAV", "a.WAV"]])
    func duplicatesAreCountedOncePerWait(candidates: [String]) async {
        // 時計は待つたびに 3 秒進む。標本の回（0・1・2）を時計から決め、3 回目（2）だけ size を変える
        let clock = FixedClock(epochMillis: 1_790_000_000_000)
        let sleeper = RecordingSleeper(clock: clock)
        let checker = StabilityChecker(
            config: AppConfig.defaults(timeZone: "Asia/Tokyo").device, clock: clock, sleeper: sleeper)
        let result = await checker.stableCandidates(candidates) { _ in
            let round = (clock.now().epochMillis - 1_790_000_000_000) / 3000
            return FileStat(size: round >= 2 ? 11 : 10, mtime: 1_790_000_000)
        }
        #expect(result.isEmpty)
        #expect(sleeper.recorded == [3, 3])
    }

    @Test("F-71 返る鍵のスカラー列は先に並んだ候補のもの（コピーはこの relpath で原本を開く）")
    func returnedKeyKeepsFirstCandidateScalars() async throws {
        let old = Self.nowSeconds - 3600
        let first = await Self.checker(RecordingSleeper()).stableCandidates(
            [Self.nfc, Self.nfd], stat: Self.stat(mtime: old))
        #expect(first.count == 1)
        let firstKey = try #require(first.keys.first)
        #expect(firstKey.unicodeScalars.map(\.value).suffix(6) == [0x2F, 0x304C, 0x2E, 0x57, 0x41, 0x56])
        #expect(firstKey.unicodeScalars.count == 31)
        let reversed = await Self.checker(RecordingSleeper()).stableCandidates(
            [Self.nfd, Self.nfc], stat: Self.stat(mtime: old))
        #expect(reversed.count == 1)
        let reversedKey = try #require(reversed.keys.first)
        #expect(reversedKey.unicodeScalars.map(\.value).suffix(7) == [0x2F, 0x304B, 0x3099, 0x2E, 0x57, 0x41, 0x56])
        #expect(reversedKey.unicodeScalars.count == 32)
    }

    @Test("F-71 同じ relpath が 2 度並んでも（FAT の重複項目）落ちない")
    func identicalCandidates() async {
        let sleeper = RecordingSleeper()
        let result = await Self.checker(sleeper).stableCandidates(
            ["a.WAV", "a.WAV"], stat: { _ in FileStat(size: 7, mtime: 1_789_996_400) })
        #expect(result == ["a.WAV": FileStat(size: 7, mtime: 1_789_996_400)])
    }
}
