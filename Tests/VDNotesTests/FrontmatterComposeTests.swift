// frontmatter の読み取りを Yams.compose の Node から作ること（F-71・#120。PLAN §8.6）と、ノートの読み方（lstat・上限）。
import Foundation
import Synchronization
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
                    + "f: 1.5\nn: null\ntilde: ~\nt: 2026-08-29\n---\n"))
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
        #expect(doc.count == 11)
    }

    /// F-71 で変えた挙動: 旧実装（`Yams.load`）は鍵をすべて文字列化していた（`yes:` は鍵 "yes"）。
    /// 新しい実装は str の scalar でない鍵が 1 つでもあれば全体を読めない（nil）にする（上書きの判定を緩めない）
    @Test(
        "F-71 最上位に str でない鍵があれば全体が nil（新しい挙動。旧実装は文字列化していた）",
        arguments: [
            "---\nyes: 1\nvoicedock_session_key: \"DJIMIC3:20260829\"\n---\n",
            "---\n123: a\nvoicedock_session_key: \"DJIMIC3:20260829\"\n---\n",
            "---\nnull: a\n---\n", "---\n~: a\n---\n", "---\n1.5: a\n---\n", "---\n!!int 7: a\n---\n",
        ])
    func nonStringKeysMakeWholeUnreadable(text: String) {
        #expect(Frontmatter.parse(text) == nil)
    }

    @Test("F-71 引用した鍵は str なので読める（\"yes\"・\"<<\"）")
    func quotedKeysAreStrings() throws {
        let doc = try #require(Frontmatter.parse("---\n\"yes\": 1\n'<<': x\n---\n"))
        #expect(doc["yes"] as? Int == 1)
        #expect(doc["<<"] as? String == "x")
    }

    @Test("F-71 複合鍵でも落ちずに nil（旧実装は強制アンラップで落ちていた）")
    func complexKeysDoNotTrap() {
        #expect(Frontmatter.parse("---\n? [a, b]\n: 1\n---\n") == nil)
        #expect(Frontmatter.parse("---\n? {c: d}\n: 1\nvoicedock_session_key: \"x\"\n---\n") == nil)
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

    @Test("F-71 マージの鍵があれば展開せず全体が nil（鍵を黙って落とさない）")
    func mergeKeysMakeWholeUnreadable() {
        #expect(Frontmatter.parse("---\n<<: {voicedock_session_key: \"DJIMIC3:20260829\"}\n---\n") == nil)
        #expect(
            Frontmatter.parse(
                "---\nvoicedock_session_key: \"DJIMIC3:20260829\"\n"
                    + "voicedock_recording_keys:\n  - \"DJIMIC3/A/B.wav\"\n<<: {voicedock_failed_parts: [\"DJIMIC3/C/D.wav\"]}\n---\n"
            ) == nil)
    }

    @Test("F-71 マージの鍵がある自分のノートは上書きしない（mayOverwrite が偽）")
    func mergeKeyBlocksOverwrite() throws {
        let dir = try TempDirectory()
        let url = try writeNote(
            "---\nvoicedock_session_key: \"DJIMIC3:20260829\"\nvoicedock_recording_keys:\n  - \"DJIMIC3/A/B.wav\"\n"
                + "<<: {voicedock_failed_parts: [\"USER/other.wav\"]}\n---\nbody\n", in: dir)
        #expect(
            !OutputPathResolver.mayOverwrite(
                url, sessionKey: "DJIMIC3:20260829", ownedPartkeys: ["DJIMIC3/A/B.wav"], kind: .daily))
        #expect(Frontmatter.recordingKeys(ofFile: url) == [])
    }

    @Test("F-71 空の frontmatter は nil")
    func emptyFrontmatterIsNil() {
        #expect(Frontmatter.parse("---\n---\nbody\n") == nil)
    }

    /// 別スレッドで読んだ結果（FIFO の番犬用）
    final class Outcome: Sendable {
        let keys = Mutex<[String]?>(nil)
    }

    /// `.timeLimit` は同期の open / read を中断できないので、別スレッドで呼んでセマフォで待つ。
    /// 時間切れなら FIFO を書き手として開いて閉じ（読み手は EOF で戻る）、止まったことを Issue に記録する
    @Test("F-71 FIFO のノートは開かずに空（止まらない）")
    func fifoIsNotRead() throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("fifo.md")
        let path = url.path(percentEncoded: false)
        #expect(mkfifo(path, 0o600) == 0)
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let keys = Frontmatter.recordingKeys(ofFile: url)
            outcome.keys.withLock { $0 = keys }
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut {
            // 読み手を解放する（開いた読み手が居なければ ENXIO で -1。読み手がまだ open の手前なら繰り返す）
            for _ in 0..<50 {
                let writer = open(path, O_WRONLY | O_NONBLOCK)
                if writer >= 0 {
                    close(writer)
                }
                if done.wait(timeout: .now() + 0.2) == .success { break }
            }
            Issue.record("FIFO を読もうとして止まった（10 秒で戻らなかった）")
            return
        }
        #expect(outcome.keys.withLock { $0 } == [])
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
