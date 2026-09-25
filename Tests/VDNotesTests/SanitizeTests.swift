// ファイル名の sanitize SN-1〜SN-9 の固定例（PLAN §8.6。T-26 §5.1）。
import Foundation
import Testing
import VDCore

@testable import VDNotes

@Suite("Sanitize")
struct SanitizeTests {
    func run(_ input: String, maxBytes: Int = 180) -> String {
        Sanitize.fileName(input, maxBytes: maxBytes)
    }

    func scalars(_ s: String) -> [UInt32] {
        s.unicodeScalars.map(\.value)
    }

    @Test("SN-1 NFD を NFC に揃える")
    func sn1NormalizesToNFC() {
        #expect(scalars(run("か\u{3099}き\u{3099}く\u{3099}")) == scalars("\u{304C}\u{304E}\u{3050}"))
    }

    @Test(
        "SN-2 制御文字を取り除く",
        arguments: [("a\u{0}b", "ab"), ("a\u{1}b", "ab"), ("a\u{1f}b", "ab"), ("a\u{7f}b", "ab"), ("a\u{a0}b", "a b")])
    func sn2RemovesControlCharacters(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }

    @Test("SN-2 タブと改行は SN-5 より先に消える", arguments: [("a\t\tb", "ab"), ("a\nb", "ab"), ("a  b", "a b")])
    func sn2RemovesTabsBeforeSN5(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }

    @Test(
        "SN-3 パス区切りと Windows の禁止文字を - にする",
        arguments: [
            ("a/b", "a-b"), ("a\\b", "a-b"), ("a:b", "a-b"), ("a*b", "a-b"), ("a?b", "a-b"), ("a\"b", "a-b"),
            ("a<b", "a-b"), ("a>b", "a-b"), ("a|b", "a-b"), ("a/b:c*d?e\"f<g>h|i", "a-b-c-d-e-f-g-h-i"),
            ("a|b<c>d*e?f\"g\\h", "a-b-c-d-e-f-g-h"),
        ])
    func sn3ReplacesForbiddenCharacters(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }

    @Test("SN-3 は SN-5 より先", arguments: [("a / b", "a - b"), ("  a / b  ", "a - b")])
    func sn3RunsBeforeSN5(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }

    @Test(
        "SN-4 Obsidian の記法文字を取り除く",
        arguments: [
            ("a#b", "ab"), ("a^b", "ab"), ("a[b", "ab"), ("a]b", "ab"), ("[[Note]]", "Note"), ("a#b^c[d]e", "abcde"),
        ])
    func sn4RemovesObsidianSyntax(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }

    @Test("SN-4 は SN-5 より先", arguments: [("a # b", "a b"), ("[ x ]", "x")])
    func sn4RunsBeforeSN5(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }

    @Test(
        "SN-5 空白を畳んで前後を落とす",
        arguments: [("  a   b  ", "a b"), ("x\u{3000}\u{3000}y", "x y"), ("a\u{a0}b\u{200b}c", "a b\u{200b}c")])
    func sn5CollapsesWhitespace(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }

    @Test(
        "SN-6 前後の . を落とす",
        arguments: [(".hidden.", "hidden"), ("...a...", "a"), ("..hidden..", "hidden"), ("a.b.c", "a.b.c")])
    func sn6StripsDots(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }

    @Test(
        "SN-7 UTF-8 のバイト数で切る",
        arguments: [
            (String(repeating: "あ", count: 80), String(repeating: "あ", count: 60)),
            (String(repeating: "あ", count: 70), String(repeating: "あ", count: 60)),
            (String(repeating: "a", count: 178) + "\u{e9}", String(repeating: "a", count: 178) + "\u{e9}"),
            (String(repeating: "a", count: 179) + "\u{e9}", String(repeating: "a", count: 179)),
            (String(repeating: "\u{e9}", count: 100), String(repeating: "\u{e9}", count: 90)),
            ("short", "short"),
        ])
    func sn7TruncatesByUTF8Bytes(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }

    @Test("SN-7 多バイト文字を割らない")
    func sn7DoesNotSplitMultibyte() {
        let result = run(String(repeating: "あ", count: 200), maxBytes: 10)
        #expect(scalars(result) == scalars("あああ"))
        #expect(result.utf8.count == 9)
    }

    @Test(
        "SN-7 末尾の結合文字を必ず削る",
        arguments: [("q\u{301}", 180, "q"), ("あああ\u{301}", 11, "あああ"), ("あああ\u{301}", 10, "あああ")])
    func sn7DropsTrailingCombiningMarks(input: String, maxBytes: Int, expected: String) {
        #expect(scalars(run(input, maxBytes: maxBytes)) == scalars(expected))
    }

    @Test("SN-7 結果が結合文字で終わらない", arguments: 1...19)
    func sn7NeverEndsWithCombiningMark(maxBytes: Int) throws {
        let result = run(String(repeating: "か\u{3099}", count: 5), maxBytes: maxBytes)
        if result == "Untitled" { return }
        let last = try #require(result.unicodeScalars.last)
        #expect(!PyText.isCombining(last))
        #expect(result.unicodeScalars.allSatisfy { $0 == "\u{304C}" })
    }

    @Test("SN-8 空なら Untitled", arguments: ["", "   ", "...", "###", "\u{0}\u{1}", "[[]]"])
    func sn8FallsBackWhenEmpty(input: String) {
        #expect(run(input) == "Untitled")
    }

    @Test(
        "SN-9 予約名に _ を付ける",
        arguments: [
            "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ])
    func sn9SuffixesReservedNames(name: String) {
        #expect(run(name) == name + "_")
    }

    @Test(
        "SN-9 大小を区別しない",
        arguments: [
            ("con", "con_"), ("Con", "Con_"), ("cOm1", "cOm1_"), ("lpt9", "lpt9_"), ("Com1", "Com1_"),
            ("LPT9.", "LPT9_"), ("NUL ", "NUL_"),
        ])
    func sn9IsCaseInsensitive(input: String, expected: String) {
        #expect(run(input) == expected)
    }

    @Test("SN-9 予約名でないものは変えない", arguments: ["CONSOLE", "COM10"])
    func sn9LeavesNonReserved(name: String) {
        #expect(run(name) == name)
    }

    @Test("SN-9 は SN-7 の後")
    func sn9RunsAfterSN7() {
        let result = run("CON", maxBytes: 3)
        #expect(result == "CON_")
        #expect(result.unicodeScalars.count == 4)
    }

    @Test("予約名の一覧は 22 個")
    func reservedNamesMatchPlan() {
        let expected: Set<String> = [
            "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ]
        #expect(Sanitize.reservedNames == expected)
        #expect(Sanitize.reservedNames.count == 22)
    }

    @Test("絵文字は残る")
    func emojiSurvives() {
        #expect(scalars(run("会議 🎤 メモ")) == scalars("会議 🎤 メモ"))
    }

    @Test("崩れた LLM のタグでも使える名前になる")
    func realisticHostileTag() {
        #expect(scalars(run(" #開発/設計: \"VoiceDock\" [メモ] ")) == scalars("開発-設計- -VoiceDock- メモ"))
    }

    @Test(
        "テンプレートの結果を sanitize する",
        arguments: [("{date}:raw", "{date}-raw"), ("2026-08-29 raw", "2026-08-29 raw"), ("tab\there\u{7f}", "tabhere")])
    func hostileTemplateIsSanitized(input: String, expected: String) {
        #expect(scalars(run(input)) == scalars(expected))
    }
}
