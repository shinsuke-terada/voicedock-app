// T-25 の golden（sanitize・frontmatter・raw_note・note_filename の Raw）との照合（PLAN §10.4。T-26 §5.5）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("RawNote golden")
struct RawNoteGoldenTests {
    enum GoldenInputError: Error {
        case unknownFieldType(String)
    }

    func zone(_ item: GoldenCase) throws -> ZonedTime {
        ZonedTime(timeZone: try #require(TimeZone(identifier: try item.string("timeZone"))))
    }

    func day(_ item: GoldenCase) throws -> LocalDate {
        try #require(LocalDate(dashed: try item.string("day")))
    }

    /// `[キー, [型, 値]]` を FrontmatterValue に写す。
    func field(_ json: GoldenJSON) throws -> (String, FrontmatterValue) {
        let pair = try #require(json.arrayValue)
        let key = try #require(pair.first?.stringValue)
        let typed = try #require(pair.last?.arrayValue)
        let type = try #require(typed.first?.stringValue)
        switch type {
        case "s":
            return (key, .string(try #require(typed.last?.stringValue)))
        case "i":
            return (key, .int(try #require(typed.last?.intValue)))
        case "b":
            guard let flag = typed.last?.boolValue else { throw GoldenInputError.unknownFieldType(type) }
            return (key, .bool(flag))
        case "n":
            return (key, .null)
        case "a":
            let items = try #require(typed.last?.arrayValue)
            return (key, .array(try items.map { try #require($0.stringValue) }))
        default:
            throw GoldenInputError.unknownFieldType(type)
        }
    }

    @Test("golden sanitize", arguments: try Golden.cases("sanitize"))
    func goldenSanitize(item: GoldenCase) throws {
        let actual = Sanitize.fileName(try item.string("input"), maxBytes: try item.int("maxBytes"))
        GoldenAssert.matches(actual, group: item.group, name: item.name)
    }

    @Test("golden frontmatter", arguments: try Golden.cases("frontmatter"))
    func goldenFrontmatter(item: GoldenCase) throws {
        switch try item.string("kind") {
        case "render":
            let fields = try item.array("fields").map(field)
            GoldenAssert.matches(Frontmatter.render(fields), group: item.group, name: item.name)
        case "quote":
            GoldenAssert.matches(Frontmatter.quote(try item.string("text")), group: item.group, name: item.name)
        case "escapeBody":
            GoldenAssert.matches(Frontmatter.escapeBody(try item.string("text")), group: item.group, name: item.name)
        case "split":
            let actual: GoldenJSON =
                Frontmatter.split(try item.string("text")).map {
                    .object(["front": .string($0.front), "body": .string($0.body)])
                } ?? .null
            GoldenAssert.matchesJSON(actual, group: item.group, name: item.name)
        default:
            Issue.record("未知の kind: \(item.testDescription)")
        }
    }

    @Test("golden raw_note", arguments: try Golden.cases("raw_note"))
    func goldenRawNote(item: GoldenCase) throws {
        let config = try GoldenConfig.make(item)
        let zone = try zone(item)
        var parts: [RawPart] = []
        for json in try item.array("parts") {
            let fields = try #require(json.objectValue)
            let startedAt = try #require(fields["startedAt"]?.stringValue)
            let base = try #require(zone.parseISO(startedAt))
            var segments: [AbsoluteSegment] = []
            for segment in try #require(fields["segments"]?.arrayValue) {
                let s = try #require(segment.objectValue)
                let startMs = try #require(s["startMs"]?.intValue)
                let endMs = try #require(s["endMs"]?.intValue)
                segments.append(
                    AbsoluteSegment(
                        at: base.adding(milliseconds: Int64(startMs)), endAt: base.adding(milliseconds: Int64(endMs)),
                        text: try #require(s["text"]?.stringValue)))
            }
            parts.append(
                RawPart(
                    partkey: try #require(fields["partkey"]?.stringValue), startedAt: startedAt,
                    endedAt: fields["endedAt"]?.stringValue, segments: segments, zone: zone))
        }
        let actual = RawNote.render(
            parts: parts, day: try day(item), sessionKey: try item.string("sessionKey"), config: config.obsidian)
        GoldenAssert.matches(actual, group: item.group, name: item.name)
    }

    @Test("golden note_filename（Raw）", arguments: try Golden.cases("note_filename"))
    func goldenRawNoteFilename(item: GoldenCase) throws {
        let config = try GoldenConfig.make(item)
        switch try item.string("kind") {
        case "raw":
            let actual = RawNote.baseName(config: config.obsidian, day: try day(item))
            GoldenAssert.matches(actual, group: item.group, name: item.name)
        case "rawFolder":
            let actual = RawNote.folder(config: config.obsidian, day: try day(item))
            GoldenAssert.matches(actual, group: item.group, name: item.name)
        default:
            return  // daily / dailyFolder は T-27 の goldenDailyFilename が確かめる
        }
    }

    @Test("golden sanitize・frontmatter・raw_note・note_filename のケースが在る")
    func goldenGroupsHaveCases() throws {
        #expect(!(try Golden.cases("sanitize")).isEmpty)
        #expect(!(try Golden.cases("frontmatter")).isEmpty)
        #expect(!(try Golden.cases("raw_note")).isEmpty)
        #expect(!(try Golden.cases("note_filename")).isEmpty)
    }
}
