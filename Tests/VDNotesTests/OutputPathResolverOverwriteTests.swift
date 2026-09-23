// 既存ノートの上書きの判定の F-75（PLAN §8.8。issue #115）: type の一致・親フォルダの無い DB の出力パス・書き直しで消える鍵。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("OutputPathResolver（F-75）")
struct OutputPathResolverOverwriteTests {
    static let baseName = "2026-08-29 raw"
    /// 原本を消した Part の鍵（RAW_SAVED 以降の Part として守る）
    static let keyX = "DJIMIC3/TX_MIC001_20260829_101201/TX01_MIC002_20260829_101204_orig.wav"
    /// "é" を合成済み（U+00E9）と分解（U+0065 U+0301）で持つ鍵。Swift の String の == では等しい
    static let keyComposed = "DJIMIC3/caf\u{E9}_orig.wav"
    static let keyDecomposed = "DJIMIC3/cafe\u{301}_orig.wav"

    func put(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    func note(type: String?, keys: [String]) -> String {
        var fields: [(String, FrontmatterValue)] = []
        if let type { fields.append((Frontmatter.keyType, .string(type))) }
        fields += [
            (Frontmatter.keySessionKey, .string(NotesFixtures.sessionKey)),
            (Frontmatter.keyRecordingKeys, .array(keys)),
        ]
        return Frontmatter.render(fields) + defaultNoteBody
    }

    func resolved(_ folder: URL, existing: URL? = nil, kind: NoteKind) throws -> String {
        try OutputPathResolver.resolve(
            folder: folder, baseName: Self.baseName, existing: existing, sessionKey: NotesFixtures.sessionKey,
            ownedPartkeys: [keyA, keyB], kind: kind
        ).get().path(percentEncoded: false)
    }

    func base(_ temp: TempDirectory) -> URL {
        temp.url.appendingPathComponent("2026-08-29 raw.md", isDirectory: false)
    }

    // MARK: - type（F4）

    @Test("F-75 Daily は Raw のノート（type: voice-raw）を上書きしない")
    func dailyDoesNotReplaceRaw() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-raw", keys: [keyA]))
        #expect(try resolved(temp.url, kind: .daily) == temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md")
        #expect(
            OutputPathResolver.mayOverwrite(
                base(temp), sessionKey: NotesFixtures.sessionKey, ownedPartkeys: [keyA], kind: .daily) == false)
    }

    @Test("F-75 Raw は Daily のノート（type: voice-daily）を上書きしない")
    func rawDoesNotReplaceDaily() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-daily", keys: [keyA]))
        #expect(try resolved(temp.url, kind: .raw) == temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md")
    }

    @Test("F-75 type の無いノートは上書きしない")
    func missingTypeIsNotOverwritten() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: nil, keys: [keyA]))
        #expect(try resolved(temp.url, kind: .raw) == temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md")
        #expect(try resolved(temp.url, kind: .daily) == temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md")
    }

    @Test("F-75 同じ種類のノートは上書きする（type は大小を区別して一致）")
    func sameTypeIsOverwritten() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-raw", keys: [keyA]))
        #expect(try resolved(temp.url, kind: .raw) == temp.url.path(percentEncoded: false) + "2026-08-29 raw.md")
        try put(base(temp), note(type: "voice-daily", keys: [keyA]))
        #expect(try resolved(temp.url, kind: .daily) == temp.url.path(percentEncoded: false) + "2026-08-29 raw.md")
        try put(base(temp), note(type: "Voice-Raw", keys: [keyA]))
        #expect(try resolved(temp.url, kind: .raw) == temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md")
    }

    // MARK: - 親フォルダの無い DB の出力パス（F5）

    @Test("F-75 DB の出力パスの親フォルダが無ければ基本名から探す")
    func existingWithoutParentFallsBack() throws {
        let temp = try TempDirectory()
        let folder = temp.url.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = temp.url.appendingPathComponent("old/2026-08-29 raw (2).md", isDirectory: false)
        #expect(
            try resolved(folder, existing: existing, kind: .raw)
                == temp.url.path(percentEncoded: false) + "new/2026-08-29 raw.md")
    }

    @Test("F-75 DB の出力パスの親がファイルなら基本名から探す")
    func existingUnderAFileFallsBack() throws {
        let temp = try TempDirectory()
        let folder = temp.url.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try put(temp.url.appendingPathComponent("old", isDirectory: false), "not a folder\n")
        let existing = temp.url.appendingPathComponent("old/2026-08-29 raw.md", isDirectory: false)
        #expect(
            try resolved(folder, existing: existing, kind: .daily)
                == temp.url.path(percentEncoded: false) + "new/2026-08-29 raw.md")
    }

    @Test("F-75 DB の出力パスの親フォルダが在ればファイルが無くてもそこへ書く")
    func existingWithParentIsKept() throws {
        let temp = try TempDirectory()
        let folder = temp.url.appendingPathComponent("new", isDirectory: true)
        let old = temp.url.appendingPathComponent("old", isDirectory: true)
        for dir in [folder, old] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let existing = old.appendingPathComponent("2026-08-29 raw (2).md", isDirectory: false)
        #expect(
            try resolved(folder, existing: existing, kind: .raw)
                == temp.url.path(percentEncoded: false) + "old/2026-08-29 raw (2).md")
    }

    // MARK: - 書き直しで消える鍵（D2）

    @Test("F-75 守る鍵が空なら何も消えない（空の入力）")
    func emptyProtectedKeysLoseNothing() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-raw", keys: [keyA, Self.keyX]))
        #expect(OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [], newKeys: []) == [])
        try put(base(temp), note(type: "voice-raw", keys: []))
        #expect(OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [Self.keyX], newKeys: []) == [])
    }

    @Test("F-75 ファイルが無ければ消える鍵は無い")
    func absentFileLosesNothing() throws {
        let temp = try TempDirectory()
        #expect(OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [Self.keyX], newKeys: []) == [])
    }

    @Test("F-75 守る鍵が新しい内容から抜けると返す")
    func protectedKeyMissingFromNewContentIsLost() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-raw", keys: [keyA, Self.keyX]))
        #expect(
            OutputPathResolver.keysLostByOverwrite(
                base(temp), protectedKeys: [keyA, Self.keyX], newKeys: [keyA, keyB])
                == [Self.keyX])
    }

    @Test("F-75 守る鍵が新しい内容に在れば消えない")
    func protectedKeyKeptIsNotLost() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-raw", keys: [keyA, Self.keyX]))
        #expect(
            OutputPathResolver.keysLostByOverwrite(
                base(temp), protectedKeys: [keyA, Self.keyX], newKeys: [keyA, keyB, Self.keyX]) == [])
    }

    @Test("F-75 守らない鍵は新しい内容から抜けても返さない")
    func unprotectedKeyMayDrop() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-raw", keys: [keyA, keyB]))
        #expect(OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [keyA], newKeys: [keyA]) == [])
    }

    @Test("F-75 消える鍵はノートの順で重複なし")
    func lostKeysKeepNoteOrder() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-raw", keys: [Self.keyX, keyB, keyA, Self.keyX]))
        #expect(
            OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [keyA, Self.keyX], newKeys: [])
                == [Self.keyX, keyA])
    }

    @Test("F-75 在るのに読めないノートは nil（書かない側）")
    func unreadableNoteIsNil() throws {
        let temp = try TempDirectory()
        try Data([0xFF]).write(to: base(temp))
        #expect(OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [], newKeys: []) == nil)
        try put(base(temp), "# memo\n")
        #expect(OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [], newKeys: []) == nil)
    }

    @Test("F-75 鍵はスカラー列で照合する（正準等価でも別の鍵は残らない扱い）")
    func keysCompareByScalars() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-raw", keys: [Self.keyComposed]))
        // 新しい内容に在るのは分解形だけ → 合成形の本文は消える
        #expect(
            OutputPathResolver.keysLostByOverwrite(
                base(temp), protectedKeys: [Self.keyComposed], newKeys: [Self.keyDecomposed]) == [Self.keyComposed])
        // 守る鍵が分解形だけ → ノートの合成形は守る鍵ではない
        #expect(
            OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [Self.keyDecomposed], newKeys: []) == [])
        // 合成形と分解形の 2 本とも守る鍵で、新しい内容には合成形だけ → 分解形の喪失を見逃さない（Set<String> ではまとまる）
        try put(base(temp), note(type: "voice-raw", keys: [Self.keyComposed, Self.keyDecomposed]))
        #expect(
            OutputPathResolver.keysLostByOverwrite(
                base(temp), protectedKeys: [Self.keyComposed, Self.keyDecomposed], newKeys: [Self.keyComposed])
                == [Self.keyDecomposed])
    }

    // MARK: - 鍵の列が配列でないノート

    /// frontmatter の type と session_key の後に fields を並べたノート
    func note(type: String, fields: [(String, FrontmatterValue)]) -> String {
        Frontmatter.render(
            [(Frontmatter.keyType, .string(type)), (Frontmatter.keySessionKey, .string(NotesFixtures.sessionKey))]
                + fields) + defaultNoteBody
    }

    @Test("F-75 voicedock_recording_keys が無い・配列でないノートは nil（書かない側）")
    func nonArrayRecordingKeysIsNil() throws {
        let temp = try TempDirectory()
        try put(base(temp), note(type: "voice-raw", fields: [(Frontmatter.keyRecordingKeys, .string(keyA))]))
        #expect(OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [], newKeys: []) == nil)
        try put(base(temp), note(type: "voice-raw", fields: [("date", .string("2026-08-29"))]))
        #expect(OutputPathResolver.keysLostByOverwrite(base(temp), protectedKeys: [], newKeys: []) == nil)
    }

    @Test("F-75 voicedock_recording_keys が無い・配列でないノートは上書きしない")
    func nonArrayRecordingKeysIsNotOverwritten() throws {
        let temp = try TempDirectory()
        let second = temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md"
        try put(base(temp), note(type: "voice-raw", fields: [(Frontmatter.keyRecordingKeys, .string(keyA))]))
        #expect(try resolved(temp.url, kind: .raw) == second)
        try put(base(temp), note(type: "voice-raw", fields: [(Frontmatter.keyRecordingKeys, .null)]))
        #expect(try resolved(temp.url, kind: .raw) == second)
        try put(base(temp), note(type: "voice-raw", fields: []))
        #expect(try resolved(temp.url, kind: .raw) == second)
        try put(base(temp), note(type: "voice-daily", fields: [(Frontmatter.keyRecordingKeys, .string(keyA))]))
        #expect(try resolved(temp.url, kind: .daily) == second)
    }

    @Test("F-75 Daily の failed / skipped は在るのに配列でなければ上書きしない（無ければ空とみなす）")
    func dailyExcludedKeysMustBeArrays() throws {
        let temp = try TempDirectory()
        let first = temp.url.path(percentEncoded: false) + "2026-08-29 raw.md"
        let second = temp.url.path(percentEncoded: false) + "2026-08-29 raw (2).md"
        for name in [Frontmatter.keyFailedParts, Frontmatter.keySkippedParts] {
            try put(
                base(temp),
                note(
                    type: "voice-daily",
                    fields: [(Frontmatter.keyRecordingKeys, .array([keyA])), (name, .string(keyB))]))
            #expect(try resolved(temp.url, kind: .daily) == second)
            try put(
                base(temp),
                note(
                    type: "voice-daily",
                    fields: [(Frontmatter.keyRecordingKeys, .array([keyA])), (name, .array([keyB]))]))
            #expect(try resolved(temp.url, kind: .daily) == first)
        }
        try put(base(temp), note(type: "voice-daily", fields: [(Frontmatter.keyRecordingKeys, .array([keyA]))]))
        #expect(try resolved(temp.url, kind: .daily) == first)
    }
}
