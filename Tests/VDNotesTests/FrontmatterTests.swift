// frontmatter の書き出し・読み取り・本文の退避（PLAN §8.6 / NOTE-06。T-26 §5.3）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("Frontmatter")
struct FrontmatterTests {
    func scalars(_ s: String) -> [UInt32] {
        s.unicodeScalars.map(\.value)
    }

    func writeNote(_ data: Data, in dir: TempDirectory) throws -> URL {
        let url = dir.url.appendingPathComponent("note.md")
        try data.write(to: url)
        return url
    }

    @Test("書き出しは voicedock と同じバイト列")
    func renderMatchesVoicedockBytes() {
        let rendered = Frontmatter.render([
            ("s", .string("a\"b\\c\u{1}d\u{7f}e\u{85}f")), ("i", .int(3)), ("b", .bool(true)), ("n", .null),
            ("e", .array([])), ("l", .array(["x", "y\""])),
        ])
        let expected =
            "---\ns: \"a\\\"b\\\\cde\u{85}f\"\ni: 3\nb: true\nn: null\ne: []\nl:\n  - \"x\"\n  - \"y\\\"\"\n---\n"
        #expect(scalars(rendered) == scalars(expected))
    }

    @Test("文字列は必ず二重引用符で囲む")
    func stringsAreAlwaysQuoted() {
        let rendered = Frontmatter.render([
            ("a", .string("plain")), (Frontmatter.keySessionKey, .string(NotesFixtures.sessionKey)),
        ])
        #expect(rendered.contains("a: \"plain\"\n"))
        #expect(rendered.contains("voicedock_session_key: \"DJIMIC3:20260829\"\n"))
    }

    @Test("制御文字は値から落とす")
    func quoteStripsControlCharacters() {
        #expect(Frontmatter.quote("a\u{0}b\u{1f}c") == "\"abc\"")
    }

    @Test("quote はスカラー単位で置換する（結合文字が続く \\ と \"）")
    func quoteUsesScalars() {
        let quoted = Frontmatter.quote("a\\\u{301}\"\u{301}")
        #expect(scalars(quoted) == scalars("\"a\\\\\u{301}\\\"\u{301}\""))
    }

    @Test(
        "崩れやすい値が書いて読んで戻る",
        arguments: ["say \"hi\"", "back\\slash", "colon: here", "#hash", "- dash", "[bracket]", "{brace}", "@at"])
    func trickyValuesRoundTrip(value: String) {
        let text = Frontmatter.render([("tag", .string(value))]) + "body\n"
        #expect(Frontmatter.parse(text)?["tag"] as? String == value)
    }

    @Test("配列はブロック形式")
    func listsAreBlockStyle() {
        let rendered = Frontmatter.render([(Frontmatter.keyRecordingKeys, .array([NotesFixtures.keyA]))])
        #expect(rendered.contains("voicedock_recording_keys:\n"))
        #expect(rendered.contains("  - \"\(NotesFixtures.keyA)\"\n"))
        #expect(!rendered.contains("["))
    }

    @Test("空配列は []")
    func emptyListIsBrackets() {
        #expect(Frontmatter.render([("k", .array([]))]) == "---\nk: []\n---\n")
    }

    @Test(
        "形の崩れた frontmatter は nil",
        arguments: ["", "no frontmatter\n", "---\nunterminated\n", "--\na: 1\n--\n", " ---\na: 1\n---\n"])
    func malformedFrontmatterIsNil(text: String) {
        #expect(Frontmatter.parse(text) == nil)
    }

    @Test("壊れた YAML は nil")
    func brokenYAMLIsNil() {
        #expect(Frontmatter.parse("---\na: [unclosed\n---\nbody\n") == nil)
    }

    @Test("辞書でない frontmatter は nil")
    func nonMappingIsNil() {
        #expect(Frontmatter.parse("---\n- a\n- b\n---\nbody\n") == nil)
    }

    @Test("split は閉じ行の後ろの空白を許す")
    func splitAllowsTrailingSpaces() throws {
        let parts = try #require(Frontmatter.split("---\na: 1\n---   \nbody"))
        #expect(parts.front == "a: 1\n")
        #expect(parts.body == "\nbody")
    }

    @Test("recordingKeys はフィールドを読む")
    func recordingKeysReadsField() throws {
        let dir = try TempDirectory()
        let text =
            Frontmatter.render([
                (Frontmatter.keySessionKey, .string(NotesFixtures.sessionKey)),
                (Frontmatter.keyRecordingKeys, .array([NotesFixtures.keyA, NotesFixtures.keyB])),
            ]) + "body\n"
        let url = try writeNote(Data(text.utf8), in: dir)
        #expect(Frontmatter.recordingKeys(ofFile: url) == [NotesFixtures.keyA, NotesFixtures.keyB])
    }

    @Test(
        "読めないときは空",
        arguments: [
            Data("broken".utf8), Data("---\na: 1\n---\nbody\n".utf8), Data("---\n{}\n---\n".utf8), Data([0xFF, 0xFE]),
        ])
    func recordingKeysEmptyWhenUnreadable(content: Data) throws {
        let dir = try TempDirectory()
        let url = try writeNote(content, in: dir)
        #expect(Frontmatter.recordingKeys(ofFile: url) == [])
        #expect(Frontmatter.recordingKeys(ofFile: dir.url.appendingPathComponent("missing.md")) == [])
    }

    @Test("鍵の要素は文字列化する")
    func recordingKeysStringifiesElements() throws {
        let dir = try TempDirectory()
        let text = "---\nvoicedock_recording_keys:\n  - 123\n  - true\n  - \"x\"\n---\nbody\n"
        let url = try writeNote(Data(text.utf8), in: dir)
        #expect(Frontmatter.recordingKeys(ofFile: url) == ["123", "True", "x"])
    }

    @Test("浮動小数は Python の repr で文字列化する")
    func pyStrUsesPythonRepr() {
        #expect(PyStr.describe(9_007_199_254_740_994.0) == "9007199254740994.0")
        #expect(PyStr.describe(1.0) == "1.0")
        #expect(PyStr.describe(Double.nan) == "nan")
        #expect(PyStr.describe(-Double.infinity) == "-inf")
    }

    @Test("本文の行頭 --- を退避する")
    func escapeBodyProtectsBoundary() {
        #expect(Frontmatter.escapeBody("a\n---\nb\n") == "a\n\\---\nb\n")
        #expect(Frontmatter.escapeBody("---\n") == "\\---\n")
        #expect(Frontmatter.escapeBody("---\na\n --- \n----x\n") == "\\---\na\n --- \n\\----x\n")
    }

    @Test("行中の --- は変えない")
    func escapeBodyLeavesInlineDashes() {
        #expect(Frontmatter.escapeBody("a --- b\n") == "a --- b\n")
        #expect(scalars(Frontmatter.escapeBody("x\r---")) == scalars("x\r---"))
    }

    @Test("結合文字が続く --- も退避する")
    func escapeBodyUsesScalars() {
        #expect(scalars(Frontmatter.escapeBody("---\u{301}x")) == scalars("\\---\u{301}x"))
    }

    @Test("退避しない本文は境界を壊す")
    func unescapedBodyBreaksBoundary() throws {
        let front = Frontmatter.render([(Frontmatter.keySessionKey, .string(NotesFixtures.sessionKey))])
        let parts = try #require(Frontmatter.split(front + "body\n---\nmore\n"))
        #expect(!parts.front.contains("body"))
        let document = try #require(Frontmatter.parse(front + Frontmatter.escapeBody("body\n---\nmore\n")))
        #expect(document[Frontmatter.keySessionKey] as? String == NotesFixtures.sessionKey)
    }
}
