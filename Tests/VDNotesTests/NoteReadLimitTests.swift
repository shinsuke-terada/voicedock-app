// 保存検証と上書きの判定がノートを `Frontmatter.readNote`（64 MiB の上限・O_NOFOLLOW）で読むことのテスト（F-83。PLAN §8.7・§8.8。issue #119）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("NoteReadLimit（F-83）")
struct NoteReadLimitTests {
    static let baseName = "2026-08-29 raw"
    /// 読む上限（64 MiB）を 1 バイト超える大きさ
    static let tooLarge: UInt64 = 67_108_865

    /// 上書きしてよい Raw ノート（type・session_key・鍵がこの Session のもの）
    static func ownedNote() -> String {
        Frontmatter.render([
            (Frontmatter.keyType, .string("voice-raw")),
            (Frontmatter.keySessionKey, .string(NotesFixtures.sessionKey)),
            (Frontmatter.keyRecordingKeys, .array([NotesFixtures.keyA])),
        ]) + "\n# 2026-08-29 の文字起こし\n"
    }

    /// text を書き、ファイルの大きさを size まで伸ばす（後ろは 0 のバイト。APFS では疎なので実際には書かない）
    static func sparse(_ url: URL, _ text: String, size: UInt64) throws {
        try Data(text.utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
    }

    func base(_ temp: TempDirectory) -> URL {
        temp.url.appendingPathComponent(Self.baseName + ".md", isDirectory: false)
    }

    func resolved(_ temp: TempDirectory) throws -> String {
        try OutputPathResolver.resolve(
            folder: temp.url, baseName: Self.baseName, existing: nil, sessionKey: NotesFixtures.sessionKey,
            ownedPartkeys: [NotesFixtures.keyA], kind: .raw
        ).get().path(percentEncoded: false)
    }

    // MARK: - NoteVerifier

    @Test("F-83 RN-3 64 MiB を超えるノートは読まずに偽で打ち切る")
    func verifierRefusesTooLargeNote() throws {
        let temp = try TempDirectory()
        let url = base(temp)
        try Self.sparse(url, Self.ownedNote(), size: Self.tooLarge)
        let result = NoteVerifier.verify(
            url: url, kind: .raw, sessionKey: NotesFixtures.sessionKey,
            expectedSHA256: String(repeating: "0", count: 64),
            expectedKeys: [NotesFixtures.keyA], summaryHeading: "## Summary")
        #expect(
            result.results == [
                NoteRuleResult(rule: "RN-1", passed: true), NoteRuleResult(rule: "RN-2", passed: true),
                NoteRuleResult(rule: "RN-3", passed: false),
            ])
    }

    @Test("F-83 DN-3 Daily も同じ上限で打ち切る")
    func verifierRefusesTooLargeDailyNote() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("2026-08-29 Voice.md", isDirectory: false)
        try Self.sparse(url, Self.ownedNote(), size: Self.tooLarge)
        let result = NoteVerifier.verify(
            url: url, kind: .daily, sessionKey: NotesFixtures.sessionKey,
            expectedSHA256: String(repeating: "0", count: 64), expectedKeys: [NotesFixtures.keyA],
            summaryHeading: "## Summary")
        #expect(result.failedRules == ["DN-3"])
        #expect(result.results.count == 3)
    }

    // MARK: - OutputPathResolver

    @Test("F-83 64 MiB を超える既存のノートは読めない扱いで上書きしない（` (2)` へ）")
    func resolverDoesNotOverwriteTooLargeNote() throws {
        let temp = try TempDirectory()
        try Self.sparse(base(temp), Self.ownedNote(), size: Self.tooLarge)
        #expect(
            OutputPathResolver.mayOverwrite(
                base(temp), sessionKey: NotesFixtures.sessionKey, ownedPartkeys: [NotesFixtures.keyA], kind: .raw)
                == false)
        #expect(try resolved(temp) == temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md")
    }

    @Test("F-83 64 MiB を超える既存のノートは、書き直しで消える鍵を判定できない（nil = 書かない）")
    func lostKeysOfTooLargeNoteAreUnknown() throws {
        let temp = try TempDirectory()
        try Self.sparse(base(temp), Self.ownedNote(), size: Self.tooLarge)
        #expect(
            OutputPathResolver.keysLostByOverwrite(
                base(temp), protectedKeys: [NotesFixtures.keyA], newKeys: []) == nil)
    }

    @Test("F-83 symlink のノートは辿らずに読めない扱い（上書きしない）")
    func resolverDoesNotFollowSymlinkedNote() throws {
        let temp = try TempDirectory()
        let target = temp.url.appendingPathComponent("elsewhere.md", isDirectory: false)
        try Data(Self.ownedNote().utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: base(temp), withDestinationURL: target)
        #expect(
            OutputPathResolver.mayOverwrite(
                base(temp), sessionKey: NotesFixtures.sessionKey, ownedPartkeys: [NotesFixtures.keyA], kind: .raw)
                == false)
        #expect(try resolved(temp) == temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md")
        #expect(try Data(contentsOf: target) == Data(Self.ownedNote().utf8))
    }

    @Test("F-83 上限の内側の自分のノートは今までどおり上書きする")
    func ownedNoteIsStillOverwritten() throws {
        let temp = try TempDirectory()
        try Data(Self.ownedNote().utf8).write(to: base(temp))
        #expect(try resolved(temp) == temp.url.path(percentEncoded: false) + "2026-08-29 raw.md")
    }

    @Test("F-83 空のノートは読めても frontmatter が無いので上書きしない（TEST-28）")
    func emptyNoteIsNotOverwritten() throws {
        let temp = try TempDirectory()
        try Data().write(to: base(temp))
        #expect(try resolved(temp) == temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md")
    }
}
