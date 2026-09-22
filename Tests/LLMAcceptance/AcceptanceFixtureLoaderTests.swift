// fixture の読み込みと長文の生成の単体（モデル不要。T-24 §5.3）。
import Foundation
import TestSupport
import Testing
import VDCore

@Suite("AcceptanceFixture")
struct AcceptanceFixtureLoaderTests {
    /// §4.3 の表の 9 つの id（昇順）。
    static let ids = [
        "s01-standup", "s02-design-review", "s03-oneonone", "s04-support-call", "s05-planning",
        "s06-retrospective", "s07-field-note", "s08-workshop", "s09-allhands",
    ]
    static let directory = PackageRoot.url.appendingPathComponent("Tests/Fixtures/llm-acceptance", isDirectory: true)

    struct LoadFailed: Error, CustomStringConvertible {
        let description: String
    }

    static func nine() throws -> [AcceptanceFixture] {
        switch AcceptanceFixture.loadAll(directory: directory) {
        case .failure(let error): throw LoadFailed(description: error.message)
        case .success(let fixtures): return fixtures
        }
    }

    @Test("既定のディレクトリの 9 本を id の昇順に読む")
    func loadsTheNineFixtures() throws {
        let fixtures = try Self.nine()
        #expect(fixtures.map(\.id) == Self.ids)
    }

    @Test("segments が startedAt から segmentSeconds 秒ずつの絶対時刻になる")
    func segmentsBecomeAbsoluteTimes() throws {
        let nine = try Self.nine()
        let s01 = try #require(nine.first { $0.id == "s01-standup" })
        let t = s01.transcript(gapSeconds: 60)
        // 2026-08-29T09:00:00+09:00、segmentSeconds 8
        let startedAt: Int64 = 1_787_961_600_000
        #expect(t.segments.count == s01.segments.count)
        #expect(t.segments.first?.at.epochMillis == startedAt)
        for (i, segment) in t.segments.enumerated() {
            #expect(segment.at.epochMillis == startedAt + Int64(i) * 8_000)
            #expect(segment.endAt - segment.at == 8 * 1000)
            #expect(segment.text == s01.segments[i])
        }
    }

    @Test("長文は決定的（同じ 9 本から同じ長文ができる）")
    func longDayIsDeterministic() throws {
        let nine = try Self.nine()
        let a = AcceptanceFixture.longDay(nine)
        let b = AcceptanceFixture.longDay(nine)
        let reversed = AcceptanceFixture.longDay(nine.reversed())
        #expect(a.segments == b.segments)
        #expect(a.segments == reversed.segments)
        #expect(a.scalarCount >= 350_000)
        #expect(a.scalarCount < 350_000 + 200)
        // 先頭は 9 本を id の昇順に連結したもの
        var expectedHead: [String] = []
        for id in Self.ids {
            expectedHead += try #require(nine.first { $0.id == id }).segments
        }
        #expect(Array(a.segments.prefix(expectedHead.count)) == expectedHead)
        #expect(a.id == "L01-longday")
        #expect(a.segmentSeconds == 12)
    }

    @Test("長文の要素はどれも元の 9 本の要素と完全に一致する（途中で切らない）")
    func longDayKeepsWholeSegments() throws {
        let nine = try Self.nine()
        let originals = Set(nine.flatMap(\.segments))
        let long = AcceptanceFixture.longDay(nine)
        #expect(!long.segments.isEmpty)
        #expect(long.segments.allSatisfy { originals.contains($0) })
    }

    @Test("長文の maxTasksWithDue は 9 本の合計 × 繰り返し回数（9 × 2 = 18）")
    func longDayCountsDues() throws {
        // 9 本の maxTasksWithDue の合計は 1+0+1+2+3+0+0+0+2 = 9。9 本で約 201,000 スカラーなので 2 周目の途中で 350,000 に達する
        let long = AcceptanceFixture.longDay(try Self.nine())
        #expect(long.maxTasksWithDue == 18)
    }

    @Test("キーが足りない JSON は失敗になり、メッセージにファイル名が入る")
    func badJSONIsAnError() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("broken.json", isDirectory: false)
        try Data(#"{"id": "broken", "dayDate": "2026-08-29", "timeZone": "Asia/Tokyo"}"#.utf8).write(to: url)
        guard case .failure(let error) = AcceptanceFixture.load(url) else {
            Issue.record("失敗にならない")
            return
        }
        #expect(error.message.contains("broken.json"))
    }

    @Test("空のディレクトリは失敗になる（TEST-28）")
    func emptyDirectoryIsAnError() throws {
        let tmp = try TempDirectory()
        guard case .failure = AcceptanceFixture.loadAll(directory: tmp.url) else {
            Issue.record("失敗にならない")
            return
        }
    }
}
