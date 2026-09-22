// 保存検証 RN-1〜RN-6 / DN-1〜DN-9（PLAN §8.7。T-28 §5.3）。一時ディレクトリの中だけにノートを置く。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

let keyA = NotesFixtures.keyA
let keyB = NotesFixtures.keyB
let keyC = "DJIMIC3/TX_MIC001_20260829_081201/TX01_MIC002_20260829_081204_orig.wav"
/// voicedock が書いたノートの鍵（アプリの DB に無い）
let keyV = "DJIMIC3/TX_MIC001_20260829_091201/TX01_MIC002_20260829_091204_orig.wav"
let defaultNoteBody = "\n# 2026-08-29\n\n## Summary\n\n打ち合わせをした。\n\n[[2026-08-29 raw]]\n"

/// ノートの内容を作る補助（T-28 §5）。frontmatter のキーは T-26 の定数で書く（CR-06）。
/// 種類の値は "voice-daily"（T-27 の `DailyNote.noteType`）だが、本チケットは T-27 の型を使わないので値を直接書く。
func buildNote(
    sessionKey: String = NotesFixtures.sessionKey, keys: [String] = [keyA, keyB],
    body: String = defaultNoteBody, extra: [(String, FrontmatterValue)] = []
) -> String {
    Frontmatter.render(
        [
            (Frontmatter.keyType, .string("voice-daily")),
            (Frontmatter.keySessionKey, .string(sessionKey)),
            (Frontmatter.keyRecordingKeys, .array(keys)),
        ] + extra) + body
}

@Suite("NoteVerifier")
struct NoteVerifierTests {
    /// 空のデータの SHA-256（固定値）
    static let emptySHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let rawRules = ["RN-1", "RN-2", "RN-3", "RN-4", "RN-5", "RN-6"]
    static let dailyRules = ["DN-1", "DN-2", "DN-3", "DN-4", "DN-5", "DN-6", "DN-7", "DN-8", "DN-9"]

    func place(_ temp: TempDirectory, _ text: String, name: String = "note.md") throws -> URL {
        let url = temp.url.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// 既定の期待値で verify を呼ぶ。expectedSHA256 はファイルの実際の SHA（無ければ空の SHA）
    func check(
        _ url: URL, _ kind: NoteKind, sessionKey: String = NotesFixtures.sessionKey, expectedSHA256: String? = nil,
        expectedKeys: Set<String> = [keyA, keyB], summaryHeading: String = "## Summary"
    ) -> NoteVerification {
        let actual = (try? Data(contentsOf: url)).map { FileHasher.sha256($0) } ?? Self.emptySHA
        return NoteVerifier.verify(
            url: url, kind: kind, sessionKey: sessionKey, expectedSHA256: expectedSHA256 ?? actual,
            expectedKeys: expectedKeys, summaryHeading: summaryHeading)
    }

    /// 規則 rule の結果（評価されていなければ nil）
    func outcome(_ v: NoteVerification, _ rule: String) -> Bool? {
        v.results.first { $0.rule == rule }?.passed
    }

    func rules(_ v: NoteVerification) -> [String] {
        v.results.map(\.rule)
    }

    /// 規則の列は SPEC S12（PLAN §8.7 の表）から読む（SPEC 同期は issue #18 で足した。PLAN F-68）
    @Test("RN と DN の件数（SPEC S12 の表と同じ）")
    func ruleCounts() throws {
        let spec = try SpecDocument.load()
        let temp = try TempDirectory()
        let url = try place(temp, buildNote())
        #expect(rules(check(url, .raw)) == (try spec.noteRules(.raw)))
        #expect(rules(check(url, .daily)) == (try spec.noteRules(.daily)))
        // 下のテストが使う固定の列も SPEC と同じ
        #expect(Self.rawRules == (try spec.noteRules(.raw)))
        #expect(Self.dailyRules == (try spec.noteRules(.daily)))
    }

    @Test("正しいノートは全部通る")
    func validNotePasses() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote())
        let raw = check(url, .raw)
        let daily = check(url, .daily)
        #expect(raw.passed)
        #expect(daily.passed)
        #expect(raw.failedRules.isEmpty)
        #expect(daily.failedRules.isEmpty)
    }

    @Test("RN-1 / DN-1 ファイルが無い")
    func rule1Missing() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("missing.md")
        let raw = check(url, .raw)
        let daily = check(url, .daily)
        #expect(raw.failedRules == ["RN-1"])
        #expect(raw.results.count == 1)
        #expect(daily.failedRules == ["DN-1"])
        #expect(daily.results.count == 1)
        #expect(!raw.passed)
    }

    @Test("RN-1 / DN-1 symlink を拒む")
    func rule1Symlink() throws {
        let temp = try TempDirectory()
        let target = try place(temp, buildNote())
        let link = temp.url.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(check(link, .raw).results == [NoteRuleResult(rule: "RN-1", passed: false)])
        #expect(check(link, .daily).results == [NoteRuleResult(rule: "DN-1", passed: false)])
    }

    @Test("RN-1 / DN-1 ディレクトリを拒む")
    func rule1Directory() throws {
        let temp = try TempDirectory()
        let dir = temp.url.appendingPathComponent("dir.md", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(check(dir, .raw).results == [NoteRuleResult(rule: "RN-1", passed: false)])
        #expect(check(dir, .daily).results == [NoteRuleResult(rule: "DN-1", passed: false)])
    }

    @Test("RN-2 / DN-2 空のファイル")
    func rule2Empty() throws {
        let temp = try TempDirectory()
        let url = try place(temp, "")
        let raw = check(url, .raw)
        #expect(rules(raw) == ["RN-1", "RN-2"])
        #expect(raw.failedRules == ["RN-2"])
        let daily = check(url, .daily)
        #expect(rules(daily) == ["DN-1", "DN-2"])
        #expect(daily.failedRules == ["DN-2"])
    }

    @Test("RN-3 / DN-3 UTF-8 でない")
    func rule3InvalidUTF8() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("bad.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        let raw = check(url, .raw)
        #expect(rules(raw) == ["RN-1", "RN-2", "RN-3"])
        #expect(raw.failedRules == ["RN-3"])
        let daily = check(url, .daily)
        #expect(rules(daily) == ["DN-1", "DN-2", "DN-3"])
        #expect(daily.failedRules == ["DN-3"])
    }

    @Test("RN-4 / DN-4 SHA が違う（続けて評価する）")
    func rule4Mismatch() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote())
        let raw = check(url, .raw, expectedSHA256: Self.emptySHA)
        #expect(rules(raw) == Self.rawRules)
        #expect(raw.failedRules == ["RN-4"])
        let daily = check(url, .daily, expectedSHA256: Self.emptySHA)
        #expect(rules(daily) == Self.dailyRules)
        #expect(daily.failedRules == ["DN-4"])
    }

    @Test("DN-5 frontmatter の区切りが無い")
    func dn5RequiresBlock() throws {
        let temp = try TempDirectory()
        let url = try place(temp, defaultNoteBody)
        let daily = check(url, .daily)
        #expect(outcome(daily, "DN-5") == false)
        #expect(rules(daily) == Self.dailyRules)
    }

    @Test("DN-5 閉じの区切りが無い")
    func dn5RequiresClosing() throws {
        let temp = try TempDirectory()
        let url = try place(temp, "---\na: 1\n")
        #expect(outcome(check(url, .daily), "DN-5") == false)
    }

    @Test("Raw に DN-5 は無い")
    func rawHasNoDN5() throws {
        let temp = try TempDirectory()
        // 区切りの無いノート: Raw では「区切り」の規則を足さず、RN-5 は session_key の規則
        let url = try place(temp, defaultNoteBody)
        let raw = check(url, .raw)
        #expect(rules(raw) == Self.rawRules)
        #expect(raw.failedRules == ["RN-5", "RN-6"])
        // 区切りも鍵もある Raw で session_key だけが違えば RN-5 だけが落ちる
        let other = try place(temp, buildNote(sessionKey: "DJIMIC3:20260829#2"), name: "other.md")
        #expect(check(other, .raw).failedRules == ["RN-5"])
    }

    @Test("RN-5 / DN-6 session_key が違う")
    func sessionKeyMismatch() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote(sessionKey: "DJIMIC3:20260829#2"))
        #expect(check(url, .raw).failedRules == ["RN-5"])
        #expect(check(url, .daily).failedRules == ["DN-6"])
    }

    @Test("RN-5 / DN-6 session_key が無い")
    func sessionKeyMissing() throws {
        let temp = try TempDirectory()
        let text =
            Frontmatter.render([
                (Frontmatter.keyType, .string("voice-daily")), (Frontmatter.keyRecordingKeys, .array([keyA, keyB])),
            ]) + defaultNoteBody
        let url = try place(temp, text)
        #expect(check(url, .raw).failedRules == ["RN-5"])
        #expect(check(url, .daily).failedRules == ["DN-6"])
    }

    @Test("RN-5 / DN-6 session_key が文字列でない")
    func sessionKeyNotString() throws {
        let temp = try TempDirectory()
        let text =
            Frontmatter.render([
                (Frontmatter.keyType, .string("voice-daily")), (Frontmatter.keySessionKey, .int(123)),
                (Frontmatter.keyRecordingKeys, .array([keyA, keyB])),
            ]) + defaultNoteBody
        #expect(text.contains("voicedock_session_key: 123\n"))
        let url = try place(temp, text)
        #expect(check(url, .raw, sessionKey: "123").failedRules == ["RN-5"])
        #expect(check(url, .daily, sessionKey: "123").failedRules == ["DN-6"])
    }

    @Test("YAML が読めなくても残りの規則を報告する")
    func unparseableReportsRules() throws {
        let temp = try TempDirectory()
        let url = try place(temp, "---\na: [unclosed\n---\n" + defaultNoteBody)
        let raw = check(url, .raw)
        #expect(raw.results.count == 6)
        #expect(raw.failedRules == ["RN-5", "RN-6"])
        let daily = check(url, .daily)
        #expect(daily.results.count == 9)
        #expect(rules(daily) == Self.dailyRules)
        #expect(daily.failedRules == ["DN-6", "DN-7"])
        #expect(outcome(daily, "DN-8") == true)
        #expect(outcome(daily, "DN-9") == true)
    }

    @Test("RN-6 は包含")
    func rn6ContainmentOnly() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote(keys: [keyA, keyB, keyC]))
        #expect(outcome(check(url, .raw), "RN-6") == true)
    }

    @Test("RN-6 は欠けると偽")
    func rn6MissingKeyFails() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote(keys: [keyA]))
        #expect(outcome(check(url, .raw), "RN-6") == false)
    }

    @Test("DN-7 は完全一致")
    func dn7ExactEquality() throws {
        let temp = try TempDirectory()
        let extra = try place(temp, buildNote(keys: [keyA, keyB, keyC]), name: "extra.md")
        #expect(outcome(check(extra, .daily), "DN-7") == false)
        let reordered = try place(temp, buildNote(keys: [keyB, keyA]), name: "reordered.md")
        #expect(outcome(check(reordered, .daily), "DN-7") == true)
    }

    @Test("RN-6 / DN-7 鍵の欄が無い")
    func keysFieldMissing() throws {
        let temp = try TempDirectory()
        let text =
            Frontmatter.render([
                (Frontmatter.keyType, .string("voice-daily")),
                (Frontmatter.keySessionKey, .string(NotesFixtures.sessionKey)),
            ]) + defaultNoteBody
        let url = try place(temp, text)
        #expect(check(url, .raw).failedRules == ["RN-6"])
        #expect(check(url, .daily).failedRules == ["DN-7"])
    }

    @Test("DN-8 見出しの下に本文が要る")
    func dn8RequiresContent() throws {
        let temp = try TempDirectory()
        let empty = try place(temp, buildNote(body: "\n## Summary\n\n## Timeline\n- 07:12 x\n\n[[a]]\n"), name: "e.md")
        #expect(outcome(check(empty, .daily), "DN-8") == false)
        // 見出しの 2 行目に本文があるケース（既定の本文）
        let filled = try place(temp, buildNote(), name: "f.md")
        #expect(outcome(check(filled, .daily), "DN-8") == true)
    }

    @Test("DN-8 見出しが無い")
    func dn8MissingHeading() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote(body: "\n# 2026-08-29\n\n本文\n\n[[a]]\n"))
        #expect(outcome(check(url, .daily), "DN-8") == false)
    }

    @Test("DN-8 設定の見出しを使う")
    func dn8UsesConfiguredHeading() throws {
        let temp = try TempDirectory()
        let ja = try place(temp, buildNote(body: "\n## 要約\n\n本文\n\n[[a]]\n"), name: "ja.md")
        #expect(outcome(check(ja, .daily, summaryHeading: "## 要約"), "DN-8") == true)
        let en = try place(temp, buildNote(body: "\n## Summary\n\n本文\n\n[[a]]\n"), name: "en.md")
        #expect(outcome(check(en, .daily, summaryHeading: "## 要約"), "DN-8") == false)
    }

    @Test("DN-8 次の見出しで止まる")
    func dn8StopsAtNextHeading() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote(body: "\n## Summary\n\n## Timeline\n\n本文\n\n[[a]]\n"))
        #expect(outcome(check(url, .daily), "DN-8") == false)
    }

    @Test("DN-8 見出しの後ろの空白を許す")
    func dn8AllowsTrailingSpaces() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote(body: "\n## Summary   \n本文\n\n[[a]]\n"))
        #expect(outcome(check(url, .daily), "DN-8") == true)
    }

    @Test("DN-8 # が 7 個は見出しでない")
    func dn8SevenHashesNotHeading() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote(body: "\n## Summary\n####### x\n"))
        #expect(outcome(check(url, .daily), "DN-8") == true)
    }

    @Test("DN-9 リンクが要る")
    func dn9RequiresLink() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote(body: "\n## Summary\n\n本文\n"))
        #expect(outcome(check(url, .daily), "DN-9") == false)
    }

    @Test("DN-9 [[…]] があれば通る")
    func dn9SatisfiedByLink() throws {
        let temp = try TempDirectory()
        let cases: [(String, Bool)] = [
            ("[[2026-08-29 raw]]", true), ("[[]]", false), ("[[a]b]]", false), ("[[[x]]", true),
        ]
        for (index, (link, expected)) in cases.enumerated() {
            let url = try place(temp, buildNote(body: "\n## Summary\n\n本文 " + link + "\n"), name: "\(index).md")
            #expect(outcome(check(url, .daily), "DN-9") == expected, "\(link)")
        }
    }

    @Test("落ちた規則の列と文言")
    func failedRulesAndMessage() throws {
        let temp = try TempDirectory()
        let url = try place(temp, buildNote(sessionKey: "DJIMIC3:20260829#2"))
        let raw = check(url, .raw, expectedSHA256: Self.emptySHA)
        #expect(raw.failedRules == ["RN-4", "RN-5"])
        #expect(raw.failureMessage == "落ちた規則: RN-4, RN-5")
        #expect(!raw.passed)
    }
}
