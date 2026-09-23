// 設定の検証の上限・桁あふれ・スカラー単位（F-71・#120）。既定値を 1 か所だけ変えて、違反の例と境界で通る例を見る。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ConfigValidator の上限と桁あふれ（F-71）")
struct ConfigValidatorBoundsTests {
    /// 既定値（timeZone は Asia/Tokyo）を変えて検証する。
    static func check(_ mutate: (inout AppConfig) -> Void) -> [ConfigViolation] {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        mutate(&config)
        return ConfigValidator.validate(config, catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
    }

    static func violation(_ rule: String, _ keyPath: String, _ message: String) -> ConfigViolation {
        ConfigViolation(rule: rule, code: .configInvalidValue, keyPath: keyPath, message: message)
    }

    /// keyPath の整数を value にする（上限を足したキーだけ）。
    static func set(_ keyPath: String, _ value: Int, _ c: inout AppConfig) {
        switch keyPath {
        case "session.blockGapSeconds": c.session.blockGapSeconds = value
        case "session.idleCloseSeconds": c.session.idleCloseSeconds = value
        case "device.snapshotMaxAgeSeconds": c.device.snapshotMaxAgeSeconds = value
        case "device.stabilityIntervalSeconds": c.device.stabilityIntervalSeconds = value
        case "device.scanIntervalSeconds": c.device.scanIntervalSeconds = value
        case "cleanup.deleteEvaluationBackoffSeconds.0": c.cleanup.deleteEvaluationBackoffSeconds[0] = value
        case "cleanup.deleteResultTimeoutSeconds": c.cleanup.deleteResultTimeoutSeconds = value
        case "retry.backoffSeconds.2": c.retry.backoffSeconds[2] = value
        case "transcription.maxTimeoutSeconds": c.transcription.maxTimeoutSeconds = value
        case "llm.maxSecondsPerRequest": c.llm.maxSecondsPerRequest = value
        case "llm.maxOutputTokens": c.llm.maxOutputTokens = value
        case "llm.chunkOverlapChars": c.llm.chunkOverlapChars = value
        case "llm.maxCharsPerRequest": c.llm.maxCharsPerRequest = value
        case "llm.contextSize": c.llm.contextSize = value
        case "audio.minTimeoutSeconds": c.audio.minTimeoutSeconds = value
        case "audio.hashChunkBytes": c.audio.hashChunkBytes = value
        case "obsidian.raw.timestampIntervalSeconds": c.obsidian.raw.timestampIntervalSeconds = value
        default: Issue.record("未知の keyPath \(keyPath)")
        }
    }

    /// (規則, keyPath, 上限)。秒は 365 日、hashChunkBytes は 64 MiB、文字数・トークン数は 10 億（PLAN §6.4）。
    static let bounds: [(String, String, Int)] = [
        ("CV-08", "session.blockGapSeconds", 31_536_000),
        ("CV-46", "device.snapshotMaxAgeSeconds", 31_536_000),
        ("CV-49", "device.stabilityIntervalSeconds", 31_536_000),
        ("CV-50", "device.scanIntervalSeconds", 31_536_000),
        ("CV-52", "cleanup.deleteEvaluationBackoffSeconds.0", 31_536_000),
        ("CV-52", "cleanup.deleteResultTimeoutSeconds", 31_536_000),
        ("CV-53", "retry.backoffSeconds.2", 31_536_000),
        ("CV-55", "transcription.maxTimeoutSeconds", 31_536_000),
        ("CV-56", "llm.maxSecondsPerRequest", 31_536_000),
        ("CV-56", "llm.maxOutputTokens", 1_000_000_000),
        ("CV-56", "llm.chunkOverlapChars", 1_000_000_000),
        ("CV-56", "llm.maxCharsPerRequest", 1_000_000_000),
        ("CV-56", "llm.contextSize", 1_000_000_000),
        ("CV-57", "session.idleCloseSeconds", 31_536_000),
        ("CV-58", "audio.minTimeoutSeconds", 31_536_000),
        ("CV-58", "audio.hashChunkBytes", 67_108_864),
        ("CV-59", "obsidian.raw.timestampIntervalSeconds", 31_536_000),
    ]

    // MARK: - 桁あふれ（H1）

    @Test("F-71 CV-51 maxCharsPerRequest が Int の最大でも落ちずに違反")
    func cv51SumOverflowIsViolation() {
        #expect(
            Self.check { $0.llm.maxCharsPerRequest = Int.max } == [
                Self.violation(
                    "CV-51", "llm.contextSize", "maxCharsPerRequest + maxOutputTokens + 2048（桁あふれ）以上であること（32768）"),
                Self.violation("CV-56", "llm.maxCharsPerRequest", "1000000000 以下であること（9223372036854775807）"),
            ])
    }

    @Test("F-71 CV-51 2048 を足すところで桁あふれしても違反")
    func cv51LastAdditionOverflowIsViolation() {
        // 9223372036854771711 + 4096 = Int.max（ここではあふれない）、+ 2048 であふれる
        #expect(
            Self.check { $0.llm.maxCharsPerRequest = 9_223_372_036_854_771_711 } == [
                Self.violation(
                    "CV-51", "llm.contextSize", "maxCharsPerRequest + maxOutputTokens + 2048（桁あふれ）以上であること（32768）"),
                Self.violation("CV-56", "llm.maxCharsPerRequest", "1000000000 以下であること（9223372036854771711）"),
            ])
    }

    @Test("F-71 CV-10 chunkOverlapChars の 2 倍が Int の最大を超えても落ちずに違反")
    func cv10TwiceOverflowIsViolation() {
        #expect(
            Self.check { $0.llm.chunkOverlapChars = 4_611_686_018_427_387_904 } == [
                Self.violation(
                    "CV-10", "llm.maxCharsPerRequest",
                    "chunkOverlapChars の 2 倍より大きいこと（chunkOverlapChars の 2 倍が桁あふれ: 4611686018427387904）"),
                Self.violation("CV-56", "llm.chunkOverlapChars", "1000000000 以下であること（4611686018427387904）"),
            ])
    }

    @Test("F-71 CV-10 chunkOverlapChars が Int の最小でも落ちずに違反")
    func cv10NegativeTwiceOverflowIsViolation() {
        #expect(
            Self.check { $0.llm.chunkOverlapChars = Int.min } == [
                Self.violation(
                    "CV-10", "llm.maxCharsPerRequest",
                    "chunkOverlapChars の 2 倍より大きいこと（chunkOverlapChars の 2 倍が桁あふれ: -9223372036854775808）"),
                Self.violation("CV-56", "llm.chunkOverlapChars", "0 以上であること（-9223372036854775808）"),
            ])
    }

    @Test("F-71 CV-10 2 倍がちょうど Int に収まれば、いままでどおりの比較")
    func cv10LargestTwiceStillCompares() {
        #expect(
            Self.check { $0.llm.chunkOverlapChars = 4_611_686_018_427_387_903 } == [
                Self.violation(
                    "CV-10", "llm.maxCharsPerRequest",
                    "chunkOverlapChars の 2 倍より大きいこと（20000 <= 9223372036854775806）"),
                Self.violation("CV-56", "llm.chunkOverlapChars", "1000000000 以下であること（4611686018427387903）"),
            ])
    }

    // MARK: - 上限

    @Test("F-71 上限ちょうどは通り、1 超えると「<上限> 以下であること」", arguments: bounds)
    func upperBound(rule: String, keyPath: String, maximum: Int) {
        let atMaximum = Self.check { Self.set(keyPath, maximum, &$0) }.filter { $0.keyPath == keyPath }
        #expect(atMaximum.isEmpty)
        let over = Self.check { Self.set(keyPath, maximum + 1, &$0) }.filter { $0.keyPath == keyPath }
        #expect(over == [Self.violation(rule, keyPath, "\(maximum) 以下であること（\(maximum + 1)）")])
    }

    @Test("F-71 上限のキーに Int の最大を書いても落ちずに違反", arguments: bounds)
    func intMaxIsViolation(rule: String, keyPath: String, maximum: Int) {
        let over = Self.check { Self.set(keyPath, Int.max, &$0) }.filter { $0.keyPath == keyPath }
        #expect(over == [Self.violation(rule, keyPath, "\(maximum) 以下であること（9223372036854775807）")])
    }

    @Test("F-71 下限の違反は上限の文言を出さない（1 キー 1 件）")
    func lowerBoundWinsOverUpperBound() {
        #expect(
            Self.check { $0.device.scanIntervalSeconds = 59 }.filter { $0.keyPath == "device.scanIntervalSeconds" }
                == [Self.violation("CV-50", "device.scanIntervalSeconds", "60 以上であること（59）")])
        #expect(
            Self.check { $0.audio.hashChunkBytes = 4095 }
                == [Self.violation("CV-58", "audio.hashChunkBytes", "4096 以上であること（4095）")])
    }

    @Test("F-71 CV-55 minTimeoutSeconds は maxTimeoutSeconds 以下の鎖で上限に収まる")
    func cv55MinimumIsBoundedByChain() {
        #expect(
            Self.check { $0.transcription.minTimeoutSeconds = 31_536_001 } == [
                Self.violation(
                    "CV-55", "transcription.maxTimeoutSeconds", "minTimeoutSeconds 以上であること（21600 < 31536001）")
            ])
    }

    @Test("F-71 既定値はすべて上限の内側")
    func defaultsAreWithinBounds() {
        let d = AppConfig.defaults(timeZone: "Asia/Tokyo")
        #expect(d.session.blockGapSeconds == 3600)
        #expect(d.device.snapshotMaxAgeSeconds == 900)
        #expect(d.device.stabilityIntervalSeconds == 3)
        #expect(d.device.scanIntervalSeconds == 300)
        #expect(d.cleanup.deleteEvaluationBackoffSeconds == [60, 300, 900, 3600])
        #expect(d.cleanup.deleteResultTimeoutSeconds == 3600)
        #expect(d.retry.backoffSeconds == [3, 10, 30])
        #expect(d.transcription.maxTimeoutSeconds == 21_600)
        #expect(d.llm.maxSecondsPerRequest == 3600)
        #expect(d.llm.maxOutputTokens == 4096)
        #expect(d.llm.chunkOverlapChars == 500)
        #expect(d.llm.maxCharsPerRequest == 20_000)
        #expect(d.llm.contextSize == 32_768)
        #expect(d.session.idleCloseSeconds == 1800)
        #expect(d.audio.minTimeoutSeconds == 180)
        #expect(d.audio.hashChunkBytes == 1_048_576)
        #expect(d.obsidian.raw.timestampIntervalSeconds == 300)
        for (_, keyPath, maximum) in Self.bounds {
            let value = Self.value(keyPath, d)
            #expect(value <= maximum, "\(keyPath) = \(value)")
        }
        #expect(Self.check { _ in }.isEmpty)
    }

    @Test("F-71 上限の値で使う側の × 1000 と加算があふれない")
    func useSideArithmeticAtBounds() {
        // 秒の上限 × 1000 のミリ秒（DeviceSnapshot.isFresh・RequestExpirer・Chunker などと同じ形）
        #expect(Instant(epochMillis: 1_790_000_000_000).adding(seconds: -31_536_000).epochMillis == 1_758_464_000_000)
        // Block の間隔（session.blockGapSeconds）: ちょうど上限の間隔は同じ塊
        let blocks = BlockComputer.blocks(
            [
                (startedAt: Instant(epochMillis: 0), endedAt: Instant(epochMillis: 0)),
                (startedAt: Instant(epochMillis: 31_536_000_000), endedAt: Instant(epochMillis: 31_536_000_000)),
            ], gapSeconds: 31_536_000)
        #expect(blocks == [TimeBlock(start: Instant(epochMillis: 0), end: Instant(epochMillis: 31_536_000_000))])
        #expect(RetryDelay.deleteEvaluation(attempts: 1, backoff: [31_536_000]) == 31_536_000)
    }

    /// 既定値の中の keyPath の値（`set` と同じキー）。
    static func value(_ keyPath: String, _ c: AppConfig) -> Int {
        switch keyPath {
        case "session.blockGapSeconds": c.session.blockGapSeconds
        case "session.idleCloseSeconds": c.session.idleCloseSeconds
        case "device.snapshotMaxAgeSeconds": c.device.snapshotMaxAgeSeconds
        case "device.stabilityIntervalSeconds": c.device.stabilityIntervalSeconds
        case "device.scanIntervalSeconds": c.device.scanIntervalSeconds
        case "cleanup.deleteEvaluationBackoffSeconds.0": c.cleanup.deleteEvaluationBackoffSeconds[0]
        case "cleanup.deleteResultTimeoutSeconds": c.cleanup.deleteResultTimeoutSeconds
        case "retry.backoffSeconds.2": c.retry.backoffSeconds[2]
        case "transcription.maxTimeoutSeconds": c.transcription.maxTimeoutSeconds
        case "llm.maxSecondsPerRequest": c.llm.maxSecondsPerRequest
        case "llm.maxOutputTokens": c.llm.maxOutputTokens
        case "llm.chunkOverlapChars": c.llm.chunkOverlapChars
        case "llm.maxCharsPerRequest": c.llm.maxCharsPerRequest
        case "llm.contextSize": c.llm.contextSize
        case "audio.minTimeoutSeconds": c.audio.minTimeoutSeconds
        case "audio.hashChunkBytes": c.audio.hashChunkBytes
        case "obsidian.raw.timestampIntervalSeconds": c.obsidian.raw.timestampIntervalSeconds
        default: Int.max
        }
    }

    // MARK: - スカラー単位（H5）

    @Test("F-71 CV-11 結合文字が続く .. も '..' として違反")
    func cv11ParentFollowedByCombiningMark() {
        #expect(
            Self.check { $0.obsidian.wiki.folderTemplate = "../\u{301}x" }
                == [Self.violation("CV-11", "obsidian.wiki.folderTemplate", "'..' を含んではならない（../\u{301}x）")])
    }

    @Test("F-71 CV-11 先頭の / に結合文字が続いても絶対パスとして違反")
    func cv11SlashFollowedByCombiningMark() {
        #expect(
            Self.check { $0.obsidian.raw.folderTemplate = "/\u{301}abs/{yyyymmdd}" }
                == [Self.violation("CV-11", "obsidian.raw.folderTemplate", "相対パスであること（/\u{301}abs/{yyyymmdd}）")])
    }

    @Test("F-71 CV-11 結合文字の付いた ..\u{301} の要素は .. ではない")
    func cv11ParentWithCombiningMarkIsNotParent() {
        #expect(Self.check { $0.obsidian.wiki.folderTemplate = "a/..\u{301}/b" }.isEmpty)
    }

    @Test("F-71 CV-11 空のテンプレートは違反にしない")
    func cv11EmptyTemplate() {
        #expect(Self.check { $0.obsidian.raw.folderTemplate = "" }.isEmpty)
    }

    @Test("F-71 CV-19 \\r\\n を含む見出しは違反")
    func cv19CarriageReturnLineFeed() {
        #expect(
            Self.check { $0.llm.analysis.sections.summary.heading = "## A\r\nB" }
                == [
                    Self.violation("CV-19", "llm.analysis.sections.summary.heading", "'#' で始まる 1 行であること")
                ])
    }

    @Test("F-71 CV-19 # に結合文字が続いても # で始まる（Python の startswith と同じ）")
    func cv19HashFollowedByCombiningMark() {
        #expect(Self.check { $0.llm.analysis.sections.summary.heading = "#\u{301} Summary" }.isEmpty)
    }
}
