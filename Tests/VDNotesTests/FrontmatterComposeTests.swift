// frontmatter の読み取りを Yams.compose の Node から作ること（F-71・#120。PLAN §8.6）と、ノートの読み方（lstat・上限）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("Frontmatter の読み取り（F-71）")
struct FrontmatterComposeTests {
    func writeNote(_ text: String, in dir: TempDirectory, name: String = "note.md") throws -> URL {
        let url = dir.url.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("F-71 60 進の int は落ちずに読み、桁あふれは元の文字列")
    func sexagesimalIntegersNeverTrap() throws {
        let doc = try #require(
            Frontmatter.parse("---\na: 1:0:0:0:0:0:0:0:0:0:0\nb: 99999999999999:0:0:0\nc: 1:30\nd: -2:00\n---\nbody\n"))
        #expect(doc["a"] as? Int == 604_661_760_000_000_000)
        #expect(doc["b"] as? String == "99999999999999:0:0:0")
        #expect(doc["c"] as? Int == 90)
        #expect(doc["d"] as? Int == -120)
    }

    @Test("F-71 鍵の配列に 60 進の値があっても落ちない")
    func sexagesimalInRecordingKeys() throws {
        let dir = try TempDirectory()
        let text =
            "---\nvoicedock_session_key: \"DJIMIC3:20260829\"\n"
            + "voicedock_recording_keys:\n  - 1:0:0:0:0:0:0:0:0:0:0\n  - 99999999999999:0:0:0\n"
            + "  - \"DJIMIC3/A/B.wav\"\n---\nbody\n"
        let url = try writeNote(text, in: dir)
        #expect(
            Frontmatter.recordingKeys(ofFile: url) == ["604661760000000000", "99999999999999:0:0:0", "DJIMIC3/A/B.wav"])
    }

    @Test("F-71 scalar は Yams.load と同じ型（文字列・int・bool・浮動小数・null）")
    func scalarTypesMatchYamsLoad() throws {
        let doc = try #require(
            Frontmatter.parse(
                "---\ns: \"x\"\nplain: word\nq: '123'\nhex: 0x1F\noct: 017\nneg: -5\nunderscore: 1_000\n"
                    + "yes: yes\nno: off\nf: 1.5\nn: null\ntilde: ~\nt: 2026-08-29\n---\n"))
        #expect(doc["s"] as? String == "x")
        #expect(doc["plain"] as? String == "word")
        #expect(doc["q"] as? String == "123")
        #expect(doc["hex"] as? Int == 31)
        #expect(doc["oct"] as? Int == 15)
        #expect(doc["neg"] as? Int == -5)
        #expect(doc["underscore"] as? Int == 1000)
        #expect(doc["f"] as? Double == 1.5)
        #expect(doc["n"] is NSNull)
        #expect(doc["tilde"] is NSNull)
        // timestamp は構築しない（元の文字列）
        #expect(doc["t"] as? String == "2026-08-29")
        // 鍵の yes / no は bool に解決されるので、文字列の鍵としては載らない（Yams.load と同じ）
        #expect(doc["yes"] == nil)
        #expect(doc["no"] == nil)
        #expect(doc.count == 11)
    }

    @Test("F-71 bool の値は Bool")
    func boolValues() throws {
        let doc = try #require(Frontmatter.parse("---\na: yes\nb: False\nc: \"true\"\n---\n"))
        #expect(doc["a"] as? Bool == true)
        #expect(doc["b"] as? Bool == false)
        #expect(doc["c"] as? String == "true")
    }

    @Test("F-71 配列の要素は文字列化の前に Yams.load と同じ型")
    func listElementsAreTyped() throws {
        let doc = try #require(Frontmatter.parse("---\nk:\n  - 123\n  - true\n  - 1.5\n  - null\n  - \"x\"\n---\n"))
        #expect(Frontmatter.stringList(doc, "k") == ["123", "True", "1.5", "None", "x"])
    }

    @Test("F-71 入れ子の配列・辞書は中を読まない")
    func nestedValuesAreNotRead() throws {
        let doc = try #require(Frontmatter.parse("---\nk:\n  - [a, b]\n  - {c: d}\n  - e\nm: {x: 1}\n---\n"))
        #expect(Frontmatter.stringList(doc, "k") == ["[]", "[:]", "e"])
        let m = try #require(doc["m"] as? [AnyHashable: Any])
        #expect(m.isEmpty)
    }

    @Test("F-71 アンカーと別名の値も読める")
    func aliasesAreDereferenced() throws {
        let doc = try #require(Frontmatter.parse("---\na: &x \"DJIMIC3/A/B.wav\"\nk:\n  - *x\n  - *x\n---\n"))
        #expect(Frontmatter.stringList(doc, "k") == ["DJIMIC3/A/B.wav", "DJIMIC3/A/B.wav"])
    }

    @Test("F-71 重複キーは読めない（nil）")
    func duplicateKeysAreUnreadable() {
        #expect(Frontmatter.parse("---\na: 1\na: 2\n---\n") == nil)
        #expect(Frontmatter.parse("---\n\u{304C}: 1\n\u{304B}\u{3099}: 2\n---\n") == nil)
    }

    @Test("F-71 マージの鍵は展開しない")
    func mergeKeysAreNotExpanded() throws {
        let doc = try #require(Frontmatter.parse("---\n<<: {voicedock_session_key: \"DJIMIC3:20260829\"}\n---\n"))
        #expect(doc[Frontmatter.keySessionKey] == nil)
        #expect(doc.isEmpty)
    }

    @Test("F-71 空の frontmatter は nil")
    func emptyFrontmatterIsNil() {
        #expect(Frontmatter.parse("---\n---\nbody\n") == nil)
    }

    @Test("F-71 FIFO のノートは開かずに空（止まらない）", .timeLimit(.minutes(1)))
    func fifoIsNotRead() throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("fifo.md")
        #expect(mkfifo(url.path(percentEncoded: false), 0o600) == 0)
        #expect(Frontmatter.recordingKeys(ofFile: url) == [])
    }

    @Test("F-71 symlink のノートは辿らずに空")
    func symlinkIsNotFollowed() throws {
        let dir = try TempDirectory()
        let target = try writeNote(
            "---\nvoicedock_recording_keys:\n  - \"DJIMIC3/A/B.wav\"\n---\nbody\n", in: dir, name: "target.md")
        #expect(Frontmatter.recordingKeys(ofFile: target) == ["DJIMIC3/A/B.wav"])
        let link = dir.url.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(Frontmatter.recordingKeys(ofFile: link) == [])
    }

    @Test("F-71 64 MiB を超えるノートは読まずに空")
    func oversizedNoteIsNotRead() throws {
        let dir = try TempDirectory()
        let url = try writeNote("---\nvoicedock_recording_keys:\n  - \"DJIMIC3/A/B.wav\"\n---\nbody\n", in: dir)
        #expect(Frontmatter.recordingKeys(ofFile: url) == ["DJIMIC3/A/B.wav"])
        // 疎なファイルで 64 MiB + 1 バイトに伸ばす（中身は先頭の frontmatter と NUL）
        #expect(truncate(url.path(percentEncoded: false), 67_108_865) == 0)
        #expect(Frontmatter.recordingKeys(ofFile: url) == [])
    }

    @Test("F-71 ディレクトリは読まずに空")
    func directoryIsNotRead() throws {
        let dir = try TempDirectory()
        #expect(Frontmatter.recordingKeys(ofFile: dir.url) == [])
    }
}
