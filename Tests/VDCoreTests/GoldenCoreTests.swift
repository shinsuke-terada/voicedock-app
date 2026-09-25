// T-25 の golden（keys・fingerprint・blocks）との照合（PLAN §10.4。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("golden core")
struct GoldenCoreTests {
    func zone(_ item: GoldenCase) throws -> ZonedTime {
        ZonedTime(timeZone: try #require(TimeZone(identifier: try item.string("timeZone"))))
    }

    @Test("golden keys", arguments: try Golden.cases("keys"))
    func goldenKeys(item: GoldenCase) throws {
        let zone = try zone(item)
        let key: String
        switch try item.string("kind") {
        case "partkey":
            key = try PartKey.make(deviceID: try item.string("deviceID"), relpath: try item.string("relpath"))
        case "sessionKey":
            let startedAt = try #require(zone.parseISO(try item.string("startedAt")))
            key = try SessionKey.make(
                deviceID: try item.string("deviceID"), dayStamp: zone.localDate(startedAt).stamp,
                overflow: try item.int("overflow"))
        default:
            Issue.record("未知の kind: \(item.testDescription)")
            return
        }
        GoldenAssert.matchesJSON(
            ["key": .string(key), "slug": .string(KeySlug.of(key))], group: item.group, name: item.name)
    }

    @Test("golden fingerprint", arguments: try Golden.cases("fingerprint"))
    func goldenFingerprint(item: GoldenCase) throws {
        let zone = try zone(item)
        let base = try #require(zone.parseISO(try item.string("base")))
        var segments: [AbsoluteSegment] = []
        for segment in try item.array("segments") {
            let fields = try #require(segment.objectValue)
            let atMs = try #require(fields["atMs"]?.intValue)
            let endMs = try #require(fields["endMs"]?.intValue)
            let text = try #require(fields["text"]?.stringValue)
            segments.append(
                AbsoluteSegment(
                    at: base.adding(milliseconds: Int64(atMs)), endAt: base.adding(milliseconds: Int64(endMs)),
                    text: text))
        }
        var blocks: [TimeBlock] = []
        for block in try item.array("blocks") {
            let fields = try #require(block.objectValue)
            let startMs = try #require(fields["startMs"]?.intValue)
            let endMs = try #require(fields["endMs"]?.intValue)
            blocks.append(
                TimeBlock(
                    start: base.adding(milliseconds: Int64(startMs)), end: base.adding(milliseconds: Int64(endMs))))
        }
        let transcript = SessionTranscript(
            dayDate: try #require(LocalDate(dashed: try item.string("day"))), segments: segments, blocks: blocks,
            excludedPartkeys: [])
        let actual =
            TranscriptFingerprint.payload(transcript, zone: zone) + "\n"
            + TranscriptFingerprint.of(transcript, zone: zone) + "\n"
        GoldenAssert.matches(actual, group: item.group, name: item.name)
    }

    @Test("golden blocks", arguments: try Golden.cases("blocks"))
    func goldenBlocks(item: GoldenCase) throws {
        let zone = try zone(item)
        let base = try #require(zone.parseISO(try item.string("base")))
        var parts: [(startedAt: Instant, endedAt: Instant?)] = []
        for part in try item.array("parts") {
            let fields = try #require(part.objectValue)
            let startS = try #require(fields["startS"]?.intValue)
            let endJSON = try #require(fields["endS"])
            var endS: Int?
            if !endJSON.isNull {
                let seconds: Int = try #require(endJSON.intValue)
                endS = seconds
            }
            parts.append((startedAt: base.adding(seconds: startS), endedAt: endS.map { base.adding(seconds: $0) }))
        }
        let blocks = BlockComputer.blocks(parts, gapSeconds: try item.int("gapSeconds"))
        let actual = GoldenJSON.array(blocks.map { .array([.string(zone.iso($0.start)), .string(zone.iso($0.end))]) })
        GoldenAssert.matchesJSON(actual, group: item.group, name: item.name)
    }

    @Test("golden keys・fingerprint・blocks のケースが在る")
    func goldenGroupsHaveCases() throws {
        #expect(!(try Golden.cases("keys")).isEmpty)
        #expect(!(try Golden.cases("fingerprint")).isEmpty)
        #expect(!(try Golden.cases("blocks")).isEmpty)
    }
}
