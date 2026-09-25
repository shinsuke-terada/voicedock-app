// 出力先の決定と既存ノートの扱い（PLAN §8.8 / X-11。T-28 §5.4）。一時ディレクトリの中だけにノートを置く。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("OutputPathResolver")
struct OutputPathResolverTests {
    static let baseName = "2026-08-29 raw"
    static let otherSession = "DJIMIC3:20260829#2"

    func put(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    func candidate(_ folder: URL, _ n: Int) -> URL {
        let name = n == 1 ? "2026-08-29 raw.md" : "2026-08-29 raw (\(n)).md"
        return folder.appendingPathComponent(name, isDirectory: false)
    }

    func resolve(
        _ folder: URL, existing: URL? = nil, sessionKey: String = NotesFixtures.sessionKey,
        owned: Set<String> = [keyA, keyB], kind: NoteKind = .raw
    ) -> Result<URL, StageFailure> {
        OutputPathResolver.resolve(
            folder: folder, baseName: Self.baseName, existing: existing, sessionKey: sessionKey, ownedPartkeys: owned,
            kind: kind)
    }

    func resolvedPath(_ result: Result<URL, StageFailure>) throws -> String {
        try result.get().path(percentEncoded: false)
    }

    func path(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }

    /// 他人（voicedock）のノート: session_key は一致するが鍵が owned に無い
    func putForeign(_ url: URL) throws {
        try put(url, rawNote(keys: [keyV]))
    }

    /// Raw のノート（F-75 で上書きの条件に `type` が入ったので、Raw として解決するテストは voice-raw のノートを置く）
    func rawNote(
        sessionKey: String = NotesFixtures.sessionKey, keys: [String], extra: [(String, FrontmatterValue)] = []
    ) -> String {
        Frontmatter.render(
            [
                (Frontmatter.keyType, .string("voice-raw")),
                (Frontmatter.keySessionKey, .string(sessionKey)),
                (Frontmatter.keyRecordingKeys, .array(keys)),
            ] + extra) + defaultNoteBody
    }

    @Test("無ければ基本名")
    func plainPathWhenAbsent() throws {
        let temp = try TempDirectory()
        #expect(try resolvedPath(resolve(temp.url)) == path(temp.url) + "2026-08-29 raw.md")
    }

    @Test("自分のノートは上書きする")
    func ownNoteOverwritten() throws {
        let temp = try TempDirectory()
        try put(candidate(temp.url, 1), rawNote(keys: [keyA]))
        #expect(try resolvedPath(resolve(temp.url)) == path(temp.url) + "2026-08-29 raw.md")
    }

    @Test("rename の後・DB 更新の前に落ちても (2) にしない")
    func crashBeforeDBUpdateReusesBase() throws {
        let temp = try TempDirectory()
        try put(candidate(temp.url, 1), rawNote(keys: [keyA, keyB]))
        #expect(try resolvedPath(resolve(temp.url, existing: nil)) == path(temp.url) + "2026-08-29 raw.md")
    }

    @Test("voicedock のノートは上書きしない（X-11）")
    func voicedockNoteNotOverwritten() throws {
        let temp = try TempDirectory()
        try putForeign(candidate(temp.url, 1))
        #expect(try resolvedPath(resolve(temp.url)) == path(temp.url) + "2026-08-29 raw (2).md")
    }

    @Test("別の Session のノートは上書きしない")
    func otherSessionNumbered() throws {
        let temp = try TempDirectory()
        try put(candidate(temp.url, 1), rawNote(sessionKey: Self.otherSession, keys: [keyA]))
        #expect(try resolvedPath(resolve(temp.url)) == path(temp.url) + "2026-08-29 raw (2).md")
    }

    @Test("同じ日の 2 つの Session")
    func twoSessionsSameDay() throws {
        let temp = try TempDirectory()
        // Session 1（keyA・keyB）が基本名に書いた
        try put(candidate(temp.url, 1), rawNote(keys: [keyA, keyB]))
        // Session #2（自分の Part は keyC）
        let second = resolve(temp.url, sessionKey: Self.otherSession, owned: [keyC])
        #expect(try resolvedPath(second) == path(temp.url) + "2026-08-29 raw (2).md")
        try put(candidate(temp.url, 2), rawNote(sessionKey: Self.otherSession, keys: [keyC]))
        // その後 Session 1 が DB の出力パス = 基本名で
        let first = resolve(temp.url, existing: candidate(temp.url, 1))
        #expect(try resolvedPath(first) == path(temp.url) + "2026-08-29 raw.md")
    }

    @Test("読めないノートは別物")
    func unreadableIsDifferent() throws {
        let temp = try TempDirectory()
        try Data([0xFF]).write(to: candidate(temp.url, 1))
        #expect(try resolvedPath(resolve(temp.url)) == path(temp.url) + "2026-08-29 raw (2).md")
    }

    @Test("利用者が作ったノート")
    func userNoteNotOverwritten() throws {
        let temp = try TempDirectory()
        try put(candidate(temp.url, 1), "# memo\n")
        #expect(try resolvedPath(resolve(temp.url)) == path(temp.url) + "2026-08-29 raw (2).md")
    }

    @Test("衝突が続けば次の番号")
    func skipsMultipleCollisions() throws {
        let temp = try TempDirectory()
        for n in 1...3 {
            try putForeign(candidate(temp.url, n))
        }
        #expect(try resolvedPath(resolve(temp.url)) == path(temp.url) + "2026-08-29 raw (4).md")
    }

    @Test("99 を超えたら書かない（Raw）")
    func tooManyRaw() throws {
        let temp = try TempDirectory()
        for n in 1...99 {
            try putForeign(candidate(temp.url, n))
        }
        let result = resolve(temp.url, kind: .raw)
        guard case .failure(let failure) = result else {
            Issue.record("失敗するはず: \(result)")
            return
        }
        #expect(failure.code == .obsidianRawWriteFailed)
        #expect(failure.message == "同名ファイルが多すぎます: 2026-08-29 raw.md")
    }

    @Test("99 を超えたら書かない（Daily）")
    func tooManyDaily() throws {
        let temp = try TempDirectory()
        // F-75: 種類（type）でなく鍵の所有で弾かれるよう、Daily の他人のノート（voice-daily）を置く
        for n in 1...99 {
            try put(candidate(temp.url, n), buildNote(keys: [keyV]))
        }
        let result = resolve(temp.url, kind: .daily)
        guard case .failure(let failure) = result else {
            Issue.record("失敗するはず: \(result)")
            return
        }
        #expect(failure.code == .obsidianWriteFailed)
        #expect(failure.message == "同名ファイルが多すぎます: 2026-08-29 raw.md")
    }

    @Test("DB の出力パスを優先する")
    func existingPreferred() throws {
        let temp = try TempDirectory()
        let existing = candidate(temp.url, 2)
        try put(existing, rawNote(keys: [keyA]))
        #expect(try resolvedPath(resolve(temp.url, existing: existing)) == path(temp.url) + "2026-08-29 raw (2).md")
    }

    @Test("DB の出力パスのファイルが消えていればそこへ書く")
    func existingMissingReused() throws {
        let temp = try TempDirectory()
        let existing = candidate(temp.url, 2)
        #expect(try resolvedPath(resolve(temp.url, existing: existing)) == path(temp.url) + "2026-08-29 raw (2).md")
    }

    @Test("DB の出力パスが他人のノートに置き換わっていたら番号を探す")
    func existingForeignFallsBack() throws {
        let temp = try TempDirectory()
        let existing = candidate(temp.url, 2)
        try putForeign(existing)
        #expect(try resolvedPath(resolve(temp.url, existing: existing)) == path(temp.url) + "2026-08-29 raw.md")
    }

    @Test("壊れた symlink は「無い」")
    func brokenSymlinkIsAbsent() throws {
        let temp = try TempDirectory()
        try FileManager.default.createSymbolicLink(
            at: candidate(temp.url, 1), withDestinationURL: temp.url.appendingPathComponent("nowhere.md"))
        #expect(try resolvedPath(resolve(temp.url)) == path(temp.url) + "2026-08-29 raw.md")
    }

    @Test("Daily は failed / skipped の鍵も見る")
    func dailyChecksExcludedKeys() throws {
        let temp = try TempDirectory()
        try put(
            candidate(temp.url, 1),
            buildNote(
                keys: [keyA],
                extra: [(Frontmatter.keyFailedParts, .array([keyB])), (Frontmatter.keySkippedParts, .array([keyV]))]))
        #expect(try resolvedPath(resolve(temp.url, kind: .daily)) == path(temp.url) + "2026-08-29 raw (2).md")
        let allOwned: Set<String> = [keyA, keyB, keyV]
        #expect(
            try resolvedPath(resolve(temp.url, owned: allOwned, kind: .daily)) == path(temp.url) + "2026-08-29 raw.md")
        // Raw は failed / skipped を見ない（F-75: Raw として解決するので voice-raw のノートに置き換える）
        try put(
            candidate(temp.url, 1),
            rawNote(
                keys: [keyA],
                extra: [(Frontmatter.keyFailedParts, .array([keyB])), (Frontmatter.keySkippedParts, .array([keyV]))]))
        #expect(try resolvedPath(resolve(temp.url, kind: .raw)) == path(temp.url) + "2026-08-29 raw.md")
    }

    @Test("鍵の無い自分の session_key のノートは上書きしてよい")
    func emptyKeysOverwritable() throws {
        let temp = try TempDirectory()
        let url = candidate(temp.url, 1)
        try put(url, rawNote(keys: []))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("voicedock_recording_keys: []\n"))
        #expect(try resolvedPath(resolve(temp.url, owned: [])) == path(temp.url) + "2026-08-29 raw.md")
    }
}
