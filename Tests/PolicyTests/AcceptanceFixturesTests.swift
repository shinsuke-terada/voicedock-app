// LLM 受け入れ試験の fixture の形を CI でも確かめる（PLAN §10.6。T-24 §5.4）。資源の検査なので JSONSerialization で読む。
import Foundation
import TestSupport
import Testing
import VDCore

@Suite("AcceptanceFixtures")
struct AcceptanceFixturesTests {
    /// §4.3 の表: id → 目安の文字数。
    static let targets: [(id: String, scalars: Int)] = [
        ("s01-standup", 5_000), ("s02-design-review", 8_000), ("s03-oneonone", 12_000),
        ("s04-support-call", 16_000), ("s05-planning", 22_000), ("s06-retrospective", 28_000),
        ("s07-field-note", 35_000), ("s08-workshop", 45_000), ("s09-allhands", 60_000),
    ]
    static let directory = PackageRoot.file("Tests/Fixtures/llm-acceptance")
    static let phonePattern = "0[0-9]{1,3}-[0-9]{2,4}-[0-9]{4}"

    struct NotAnObject: Error, CustomStringConvertible {
        let description: String
    }

    static func object(_ id: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(id).json", isDirectory: false))
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotAnObject(description: "\(id).json が JSON のオブジェクトではない")
        }
        return top
    }

    static func segments(_ id: String) throws -> [String] {
        try object(id)["segments"] as? [String] ?? []
    }

    @Test("9 つの fixture が在り、ほかのファイルが無い")
    func nineFixturesExist() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path(percentEncoded: false))
        #expect(names.sorted() == Self.targets.map { "\($0.id).json" })
    }

    @Test("必須のキーが在り、id がファイル名と一致する", arguments: targets.map(\.id))
    func eachFixtureHasTheRequiredKeys(_ id: String) throws {
        let top = try Self.object(id)
        #expect(top["id"] as? String == id)
        #expect(top["dayDate"] is String)
        #expect(top["timeZone"] is String)
        #expect(top["startedAt"] is String)
        #expect(top["segmentSeconds"] is Int)
        #expect(top["segments"] is [String])
        let expected = top["expected"] as? [String: Any]
        #expect(expected?["maxTasksWithDue"] is Int)
    }

    @Test("文字数の合計が目安の ±20% に収まる", arguments: targets)
    func scalarCountsAreInRange(_ target: (id: String, scalars: Int)) throws {
        let total = try Self.segments(target.id).reduce(0) { $0 + TextLimit.scalarCount($1) }
        #expect(total >= target.scalars * 8 / 10, "\(target.id): \(total)")
        #expect(total <= target.scalars * 12 / 10, "\(target.id): \(total)")
    }

    @Test("各要素が 10〜200 スカラーの文で、句点・疑問符・感嘆符で終わる", arguments: targets.map(\.id))
    func segmentsAreSentences(_ id: String) throws {
        let segments = try Self.segments(id)
        #expect(!segments.isEmpty)
        for segment in segments {
            let count = TextLimit.scalarCount(segment)
            #expect((10...200).contains(count), "\(id): \(segment)")
            #expect(["。", "？", "！"].contains(segment.unicodeScalars.last.map(String.init) ?? ""), "\(id): \(segment)")
        }
    }

    @Test("どの要素にも `[[` と `]]` が無い", arguments: targets.map(\.id))
    func noWikiLinkMarkersInFixtures(_ id: String) throws {
        for segment in try Self.segments(id) {
            #expect(!segment.contains("[["), "\(id): \(segment)")
            #expect(!segment.contains("]]"), "\(id): \(segment)")
        }
    }

    @Test("メールアドレスや電話番号の形が無い", arguments: targets.map(\.id))
    func noObviousPersonalData(_ id: String) throws {
        let phone = try NSRegularExpression(pattern: Self.phonePattern)
        for segment in try Self.segments(id) {
            #expect(!segment.contains("@"), "\(id): \(segment)")
            let range = NSRange(location: 0, length: segment.utf16.count)
            #expect(phone.firstMatch(in: segment, range: range) == nil, "\(id): \(segment)")
        }
    }

    /// 暦の日付（「9月4日」）。期限つきの依頼だけがこれを持つ（§4.3）。
    static let datePattern = "[0-9]+月[0-9]+日"
    /// 期限として読める語。日付を明示した要素の外に置かない（§4.3「それ以外の依頼にはぼかした言い方だけ」）。
    static let deadlineWords = [
        "今日中", "本日中", "明日", "明後日", "あさって", "今週", "来週", "再来週", "今月中", "来月", "月末", "週末", "週明け",
        "月曜", "火曜", "水曜", "木曜", "金曜", "土曜", "日曜",
    ]
    /// 「〜までに」（「ここまでにしましょう」「ところまでにしよう」は期限ではないので除く）。
    static let untilPattern = "(?<!ここ)(?<!ところ)までに"

    @Test("期限として読める語は日付を明示した要素の中だけで、日付の要素は maxTasksWithDue 個", arguments: targets.map(\.id))
    func deadlinesOnlyInDatedSegments(_ id: String) throws {
        let top = try Self.object(id)
        let maxDue = try #require((top["expected"] as? [String: Any])?["maxTasksWithDue"] as? Int)
        let date = try NSRegularExpression(pattern: Self.datePattern)
        let until = try NSRegularExpression(pattern: Self.untilPattern)
        var dated = 0
        for segment in try Self.segments(id) {
            let range = NSRange(location: 0, length: segment.utf16.count)
            if date.firstMatch(in: segment, range: range) != nil {
                dated += 1
                continue
            }
            let words = Self.deadlineWords.filter { segment.contains($0) }
            #expect(words.isEmpty, "\(id): \(words): \(segment)")
            #expect(until.firstMatch(in: segment, range: range) == nil, "\(id): までに: \(segment)")
        }
        #expect(dated == maxDue, "\(id): 日付の要素 \(dated) 個")
    }

    @Test("startedAt が読め、dayDate と同じ日", arguments: targets.map(\.id))
    func startedAtParses(_ id: String) throws {
        let top = try Self.object(id)
        let zoneName = try #require(top["timeZone"] as? String)
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: zoneName)))
        let startedText = try #require(top["startedAt"] as? String)
        let startedAt = try #require(zone.parseISO(startedText))
        #expect(zone.localDate(startedAt).dashed == top["dayDate"] as? String)
    }
}
