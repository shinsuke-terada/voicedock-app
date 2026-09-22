// LLM 受け入れ試験の transcript の fixture（型・読み込み・長文の生成。PLAN §10.6。T-24 §4.3）。
import Foundation
import VDContract
import VDCore

/// 受け入れ試験の部品の失敗（`Result` の Failure は `Error` でなければならないため、メッセージを包む）。
struct AcceptanceError: Error, Equatable, Sendable, CustomStringConvertible, ExpressibleByStringInterpolation {
    let message: String

    init(stringLiteral value: String) {
        message = value
    }

    var description: String { message }
}

/// 1 セッション分の transcript の fixture（`Tests/Fixtures/llm-acceptance/<id>.json`）。
struct AcceptanceFixture: Sendable {
    let id: String
    let dayDate: LocalDate
    let zone: ZonedTime
    let startedAt: Instant
    let segmentSeconds: Int
    let segments: [String]
    let maxTasksWithDue: Int

    /// 長文の目標のスカラー数（§4.3）。
    static let longTargetScalars = 350_000
    /// 長文の ID（ファイルにしない。生成する）。
    static let longID = "L01-longday"
    /// 長文の開始時刻と 1 要素の秒数（§4.3）。
    static let longStartedAt = "2026-08-29T07:00:00+09:00"
    static let longSegmentSeconds = 12
    static let longTimeZone = "Asia/Tokyo"

    /// segments の TextLimit.scalarCount の合計。
    var scalarCount: Int { segments.reduce(0) { $0 + TextLimit.scalarCount($1) } }

    /// PLAN §5.6 の形。blocks は BlockComputer.blocks(…, gapSeconds: config.session.blockGapSeconds)。
    /// i 番目の要素は `at = startedAt + i × segmentSeconds`、`endAt = at + segmentSeconds`。録音は 1 本として塊を求める。
    func transcript(gapSeconds: Int) -> SessionTranscript {
        let absolute = segments.enumerated().map { index, text in
            let at = startedAt.adding(seconds: index * segmentSeconds)
            return AbsoluteSegment(at: at, endAt: at.adding(seconds: segmentSeconds), text: text)
        }
        let endedAt = startedAt.adding(seconds: segments.count * segmentSeconds)
        let blocks = BlockComputer.blocks([(startedAt: startedAt, endedAt: endedAt)], gapSeconds: gapSeconds)
        return SessionTranscript(dayDate: dayDate, segments: absolute, blocks: blocks, excludedPartkeys: [])
    }

    /// 1 ファイルを読む。失敗のメッセージにはファイル名を入れる。
    static func load(_ url: URL) -> Result<AcceptanceFixture, AcceptanceError> {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { return .failure("\(name): 読めません") }
        guard let parsed = try? JSONSerialization.jsonObject(with: data), let top = parsed as? [String: Any] else {
            return .failure("\(name): JSON のオブジェクトではありません")
        }
        guard let id = top["id"] as? String else { return .failure("\(name): id がありません") }
        guard let dayText = top["dayDate"] as? String, let dayDate = LocalDate(dashed: dayText) else {
            return .failure("\(name): dayDate がありません")
        }
        guard let zoneName = top["timeZone"] as? String, let timeZone = TimeZone(identifier: zoneName) else {
            return .failure("\(name): timeZone がありません")
        }
        let zone = ZonedTime(timeZone: timeZone)
        guard let startedText = top["startedAt"] as? String, let startedAt = zone.parseISO(startedText) else {
            return .failure("\(name): startedAt がありません")
        }
        guard let seconds = top["segmentSeconds"] as? Int, seconds > 0 else {
            return .failure("\(name): segmentSeconds がありません")
        }
        guard let segments = top["segments"] as? [String] else { return .failure("\(name): segments がありません") }
        guard let expected = top["expected"] as? [String: Any], let maxDue = expected["maxTasksWithDue"] as? Int
        else {
            return .failure("\(name): expected.maxTasksWithDue がありません")
        }
        return .success(
            AcceptanceFixture(
                id: id, dayDate: dayDate, zone: zone, startedAt: startedAt, segmentSeconds: seconds,
                segments: segments, maxTasksWithDue: maxDue))
    }

    /// ディレクトリの *.json の数（ディレクトリが読めなければ nil）。
    static func jsonCount(directory: URL) -> Int? {
        let path = directory.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return names.filter { $0.hasSuffix(".json") }.count
    }

    /// ディレクトリの *.json を id の昇順に読む（読めないものは Result の失敗にする）。
    static func loadAll(directory: URL) -> Result<[AcceptanceFixture], AcceptanceError> {
        let path = directory.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return .failure("\(path): ディレクトリが読めません")
        }
        var fixtures: [AcceptanceFixture] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            switch load(directory.appendingPathComponent(name, isDirectory: false)) {
            case .failure(let message): return .failure(message)
            case .success(let fixture): fixtures.append(fixture)
            }
        }
        guard !fixtures.isEmpty else { return .failure("\(path): fixture（*.json）がありません") }
        return .success(fixtures.sorted { $0.id < $1.id })
    }

    /// 9 本から約 350,000 スカラーの 1 本を作る（§4.3）。
    /// 9 本を id の昇順に連結した segments を、合計が longTargetScalars に達するまで要素ごと足す（切り詰めない）。
    /// maxTasksWithDue = 9 本の合計 × 繰り返し回数（途中まで使った回も 1 回と数える）。
    static func longDay(_ base: [AcceptanceFixture]) -> AcceptanceFixture {
        let ordered = base.sorted { $0.id < $1.id }
        let pool = ordered.flatMap(\.segments)
        let duesPerPass = ordered.reduce(0) { $0 + $1.maxTasksWithDue }
        var segments: [String] = []
        var total = 0
        var passes = 0
        if !pool.isEmpty {
            outer: while true {
                passes += 1
                for segment in pool {
                    segments.append(segment)
                    total += TextLimit.scalarCount(segment)
                    if total >= longTargetScalars { break outer }
                }
            }
        }
        let zone = ZonedTime(timeZone: TimeZone(identifier: longTimeZone) ?? .gmt)
        let startedAt = zone.parseISO(longStartedAt) ?? Instant(epochMillis: 0)
        return AcceptanceFixture(
            id: longID, dayDate: zone.localDate(startedAt), zone: zone, startedAt: startedAt,
            segmentSeconds: longSegmentSeconds, segments: segments, maxTasksWithDue: duesPerPass * passes)
    }
}
