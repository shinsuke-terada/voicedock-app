// フォルダ・ファイル名のテンプレートと Raw の基本名・フォルダ（PLAN §8.6。T-26 §5.2）。
import Foundation
import Testing
import VDCore

@testable import VDNotes

@Suite("NoteTemplate")
struct NoteTemplateTests {
    @Test(
        "プレースホルダを埋める",
        arguments: [
            ("Daily/Voice/Raw/{yyyymmdd}", "Daily/Voice/Raw/20260829"), ("{date}", "2026-08-29"),
            ("x/{time}", "x/000000"), ("a/{yyyymmdd}/{date}", "a/20260829/2026-08-29"),
        ])
    func rendersPlaceholders(template: String, expected: String) throws {
        #expect(NoteTemplate.render(template, day: try NotesFixtures.day) == expected)
    }

    @Test("未知のプレースホルダは残す")
    func leavesUnknownPlaceholders() throws {
        #expect(NoteTemplate.render("{date} raw {part}", day: try NotesFixtures.day) == "2026-08-29 raw {part}")
    }

    @Test("結合文字が続くプレースホルダも埋める（スカラー単位）")
    func rendersPlaceholderBeforeCombiningMark() throws {
        let rendered = NoteTemplate.render("{date}\u{301}", day: try NotesFixtures.day)
        #expect(rendered.unicodeScalars.map(\.value) == "2026-08-29\u{301}".unicodeScalars.map(\.value))
    }

    @Test("CE obsidian.raw.filenameTemplate が Raw の基本名になる")
    func rawFolderAndBaseName() throws {
        let day = try NotesFixtures.day
        var config = NotesFixtures.config()
        #expect(RawNote.folder(config: config, day: day) == "Daily/Voice/Raw/20260829")
        #expect(RawNote.baseName(config: config, day: day) == "2026-08-29 raw")
        config.raw.filenameTemplate = "{date}:raw"
        #expect(RawNote.baseName(config: config, day: day) == "2026-08-29-raw")
    }

    @Test("CE obsidian.maxTitleBytes で基本名が切れる")
    func ceMaxTitleBytes() throws {
        let day = try NotesFixtures.day
        var config = NotesFixtures.config()
        #expect(RawNote.baseName(config: config, day: day) == "2026-08-29 raw")
        config.maxTitleBytes = 10
        #expect(RawNote.baseName(config: config, day: day) == "2026-08-29")
    }
}
