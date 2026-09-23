// CV-13・CV-14・CV-41 のスカラー単位の判定、CV-52・CV-53 の backoff の要素数の上限、CV-54 の語の 1 か所のテスト
// （F-83。PLAN §6.4。issue #119）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ConfigValidator（F-83）")
struct ConfigValidatorScalarTests {
    /// 既定値（timeZone は Asia/Tokyo）を変えて検証する。
    static func check(_ mutate: (inout AppConfig) -> Void) -> [ConfigViolation] {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        mutate(&config)
        return ConfigValidator.validate(config, catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
    }

    static func one(_ rule: String, _ keyPath: String, _ message: String) -> [ConfigViolation] {
        [ConfigViolation(rule: rule, code: .configInvalidValue, keyPath: keyPath, message: message)]
    }

    // MARK: - CV-13・CV-14・CV-41（スカラー単位）

    @Test("CV-13 } の直後に結合文字が続いてもプレースホルダを見つける（F-83。書記素単位だと通っていた）")
    func cv13ScansScalars() {
        #expect(
            Self.check { $0.obsidian.raw.filenameTemplate = "{bad}\u{301}" }
                == Self.one(
                    "CV-13", "obsidian.raw.filenameTemplate", "未知のプレースホルダ {bad}（使えるのは {yyyymmdd} {date} {time}）"))
    }

    @Test("CV-13 名前はスカラー列で照らす（{date} の後の結合文字は名前の外なので通る）（F-83）")
    func cv13AllowedNameFollowedByCombiningMark() {
        #expect(Self.check { $0.obsidian.raw.filenameTemplate = "{date}\u{301} raw" }.isEmpty)
    }

    @Test("CV-13 {date}\\u{301}x} は Python と同じく {date} だけが名前で通る（旧実装は違反にした）（F-83）")
    func cv13MatchesPythonForATrailingBrace() {
        #expect(Self.check { $0.obsidian.raw.filenameTemplate = "{date}\u{301}x}" }.isEmpty)
    }

    @Test("CV-13 { の中の結合文字は名前の一部（{date\\u{301}} は未知）（F-83）")
    func cv13CombiningMarkInsideTheName() {
        #expect(
            Self.check { $0.obsidian.raw.filenameTemplate = "{date\u{301}}" }
                == Self.one(
                    "CV-13", "obsidian.raw.filenameTemplate",
                    "未知のプレースホルダ {date\u{301}}（使えるのは {yyyymmdd} {date} {time}）"))
    }

    @Test("CV-14 {title} の直後に結合文字が続いても見つける（F-83）")
    func cv14ScansScalars() {
        #expect(
            Self.check { $0.obsidian.wiki.filenameTemplate = "{title}\u{301}" }
                == Self.one("CV-14", "obsidian.wiki.filenameTemplate", "{title} を含んではならない（再生成のたびにファイルが増殖する）"))
    }

    @Test("CV-41 / の直後に結合文字が続いても / を見つける（F-83）")
    func cv41ScansScalars() {
        #expect(
            Self.check { $0.vault.marker = "a/\u{301}b" }
                == Self.one("CV-41", "vault.marker", "空でなく、/ を含まず、. と .. 以外であること（a/\u{301}b）"))
    }

    @Test("CV-41 空の目印は違反（TEST-28）（F-83）")
    func cv41Empty() {
        #expect(
            Self.check { $0.vault.marker = "" }
                == Self.one("CV-41", "vault.marker", "空でなく、/ を含まず、. と .. 以外であること（）"))
    }

    @Test("CV-41 . に結合文字が続く目印は . ではない（F-83）")
    func cv41DotWithCombiningMarkIsNotDot() {
        #expect(Self.check { $0.vault.marker = ".\u{301}" }.isEmpty)
    }

    // MARK: - CV-52・CV-53（要素数）

    @Test("CV-52 deleteEvaluationBackoffSeconds は 64 個以下（65 個は要素数の 1 件だけ）（F-83）")
    func cv52TooManyElements() {
        #expect(
            Self.check { $0.cleanup.deleteEvaluationBackoffSeconds = Array(repeating: 31_536_001, count: 65) }
                == Self.one("CV-52", "cleanup.deleteEvaluationBackoffSeconds", "要素は 64 個以下であること（65）"))
    }

    @Test("CV-52 64 個は通る（F-83）")
    func cv52Boundary() {
        #expect(Self.check { $0.cleanup.deleteEvaluationBackoffSeconds = Array(repeating: 60, count: 64) }.isEmpty)
    }

    @Test("CV-52 空は「空にできない」の 1 件だけ（TEST-28）（F-83）")
    func cv52Empty() {
        #expect(
            Self.check { $0.cleanup.deleteEvaluationBackoffSeconds = [] }
                == Self.one("CV-52", "cleanup.deleteEvaluationBackoffSeconds", "空にできない"))
    }

    @Test("CV-53 retry.backoffSeconds は 64 個以下（F-83）")
    func cv53TooManyElements() {
        #expect(
            Self.check { $0.retry.backoffSeconds = Array(repeating: 3, count: 65) }
                == Self.one("CV-53", "retry.backoffSeconds", "要素は 64 個以下であること（65）"))
    }

    @Test("CV-53 64 個は通る（F-83）")
    func cv53Boundary() {
        #expect(Self.check { $0.retry.backoffSeconds = Array(repeating: 3, count: 64) }.isEmpty)
    }

    @Test("CV-52 CV-53 既定値の要素数（4 個と 3 個）は上限の内側（F-83）")
    func defaultsAreWithinTheCount() {
        let defaults = AppConfig.defaults(timeZone: "Asia/Tokyo")
        #expect(defaults.cleanup.deleteEvaluationBackoffSeconds == [60, 300, 900, 3600])
        #expect(defaults.retry.backoffSeconds == [3, 10, 30])
        #expect(ConfigValidator.maxBackoffCount == 64)
        #expect(Self.check { _ in }.isEmpty)
    }

    // MARK: - CV-54（語は LogLevel の 1 か所）

    @Test("CV-54 4 語のどれでもなければ、4 語を並べた文言で違反（F-83）")
    func cv54Message() {
        #expect(
            Self.check { $0.logging.level = "info" }
                == Self.one("CV-54", "logging.level", "DEBUG / INFO / WARNING / ERROR のどれかであること（info）"))
    }

    @Test("CV-54 4 語は通る（F-83）", arguments: ["DEBUG", "INFO", "WARNING", "ERROR"])
    func cv54Words(level: String) {
        #expect(Self.check { $0.logging.level = level }.isEmpty)
    }

    @Test("CV-54 LogLevel の語は大文字の 4 語で、configValue から戻る（F-83）")
    func logLevelWords() {
        #expect(LogLevel.allCases.map(\.configValue) == ["DEBUG", "INFO", "WARNING", "ERROR"])
        #expect(LogLevel.allCases.map { LogLevel(configValue: $0.configValue) } == [.debug, .info, .warning, .error])
    }
}
