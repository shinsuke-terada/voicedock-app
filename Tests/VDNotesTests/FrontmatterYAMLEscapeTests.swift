// frontmatter の quote が YAML の読み手の拒む文字を `\uXXXX` で書くことのテスト（F-83。PLAN §8.6・X-40。issue #119 の F3）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("Frontmatter（F-83）")
struct FrontmatterYAMLEscapeTests {
    /// C1 制御文字と U+FFFE・U+FFFF を含むボリューム名（DeviceID.isValid は C1 を拒まない）と、それを含む鍵
    static let device = "MIC\u{80}\u{9F}\u{FFFE}\u{FFFF}"
    static let sessionKey = device + ":20260829"
    static let partkey = device + "/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

    @Test("F-83 空の値は空の二重引用符（TEST-28）")
    func emptyValue() {
        #expect(Frontmatter.quote("") == "\"\"")
    }

    @Test("F-83 C1 制御文字（U+0080〜U+0084・U+0086〜U+009F）は \\uXXXX（大文字 4 桁）で書く")
    func c1IsEscaped() {
        #expect(Frontmatter.quote("a\u{80}b\u{84}c\u{86}d\u{9F}e") == "\"a\\u0080b\\u0084c\\u0086d\\u009Fe\"")
    }

    @Test("F-83 U+FFFE と U+FFFF も \\uXXXX で書く")
    func nonCharactersAreEscaped() {
        #expect(Frontmatter.quote("\u{FFFE}x\u{FFFF}") == "\"\\uFFFEx\\uFFFF\"")
    }

    @Test("F-83 U+0085・U+2028・U+2029・U+00A0 以降は今までどおりそのまま（golden と同じ）")
    func readableScalarsAreKept() {
        #expect(
            scalars(Frontmatter.quote("\u{85}\u{2028}\u{2029}\u{A0}\u{D7FF}\u{E000}\u{FFFD}\u{10000}"))
                == [0x22, 0x85, 0x2028, 0x2029, 0xA0, 0xD7FF, 0xE000, 0xFFFD, 0x10000, 0x22])
    }

    @Test("F-83 C0 制御文字は今までどおり取り除き、バックスラッシュは先に二重にする")
    func controlAndBackslashAreUnchanged() {
        #expect(Frontmatter.quote("\\\u{80}\u{1}\"") == "\"\\\\\\u0080\\\"\"")
    }

    @Test("F-83 C1 を含む値の frontmatter を libyaml が読め、値がそのまま戻る")
    func escapedValuesRoundTrip() throws {
        let text =
            Frontmatter.render([
                (Frontmatter.keySessionKey, .string(Self.sessionKey)),
                (Frontmatter.keyRecordingKeys, .array([Self.partkey])),
            ]) + "body\n"
        // parse は Yams.compose（libyaml）で読む。読めなければ nil
        let doc = try #require(Frontmatter.parse(text))
        let key = try #require(doc[Frontmatter.keySessionKey] as? String)
        #expect(scalars(key) == [0x4D, 0x49, 0x43, 0x80, 0x9F, 0xFFFE, 0xFFFF] + scalars(":20260829"))
        #expect(Frontmatter.stringList(doc, Frontmatter.keyRecordingKeys).map(scalars) == [scalars(Self.partkey)])
    }

    @Test("F-83 C1 を含む鍵の Raw ノートが保存の検証（RN-1〜RN-6）を通る")
    func noteWithC1KeysPassesVerification() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("2026-08-29 raw.md", isDirectory: false)
        let content =
            Frontmatter.render([
                (Frontmatter.keyType, .string("voice-raw")),
                (Frontmatter.keySessionKey, .string(Self.sessionKey)),
                (Frontmatter.keyRecordingKeys, .array([Self.partkey])),
            ]) + "\n# 2026-08-29 の文字起こし\n"
        let sha = try NoteWriter.write(content, to: url)
        let result = NoteVerifier.verify(
            url: url, kind: .raw, sessionKey: Self.sessionKey, expectedSHA256: sha, expectedKeys: [Self.partkey],
            summaryHeading: "## Summary")
        #expect(result.failedRules == [])
        #expect(result.results.map(\.rule) == ["RN-1", "RN-2", "RN-3", "RN-4", "RN-5", "RN-6"])
    }
}
