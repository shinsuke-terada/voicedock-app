// T-25 の golden（daily_note・daily_parts・timeline・timeline_decode・wiki・note_filename の Daily）との照合（PLAN §10.4。T-27 §5.6）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("DailyNote golden")
struct DailyNoteGoldenTests {
    enum GoldenInputError: Error {
        case unknownStatus(String)
    }

    func zone(_ item: GoldenCase) throws -> ZonedTime {
        ZonedTime(timeZone: try #require(TimeZone(identifier: try item.string("timeZone"))))
    }

    func day(_ item: GoldenCase) throws -> LocalDate {
        try #require(LocalDate(dashed: try item.string("day")))
    }

    func strings(_ json: GoldenJSON?) throws -> [String] {
        try #require(json?.arrayValue).map { try #require($0.stringValue) }
    }

    /// base に startMs などのミリ秒を足した瞬間
    func instant(_ base: Instant, _ fields: [String: GoldenJSON], _ key: String) throws -> Instant {
        base.adding(milliseconds: Int64(try #require(fields[key]?.intValue)))
    }

    /// `{partkey, status, errorCode}` → ExcludedPart（未知のコードは unknownCode、null は理由なし）
    func excludedPart(_ json: GoldenJSON) throws -> ExcludedPart {
        let fields = try #require(json.objectValue)
        let statusText = try #require(fields["status"]?.stringValue)
        guard let status = PartStatus(rawValue: statusText) else { throw GoldenInputError.unknownStatus(statusText) }
        let codeText = fields["errorCode"]?.stringValue
        let code = codeText.flatMap { ErrorCode(rawValue: $0) }
        return ExcludedPart(
            partkey: try #require(fields["partkey"]?.stringValue), status: status, errorCode: code,
            unknownCode: code == nil ? codeText : nil)
    }

    /// 配列の節: 入力に在ればその要素、無ければ []（節が無効なら nil）
    func sectionItems(_ analysis: [String: GoldenJSON], _ key: String, _ config: AppConfig) throws -> [String]? {
        if let json = analysis[key] {
            return try strings(json)
        }
        let enabled = config.llm.analysis.sections.section(named: key)?.enabled ?? false
        return enabled ? [] : nil
    }

    func analysisView(_ analysis: [String: GoldenJSON], _ config: AppConfig) throws -> AnalysisView {
        var tasks: [(text: String, due: String?)]?
        if let items = analysis["tasks"]?.arrayValue {
            tasks = try items.map { item in
                let task = try #require(item.objectValue)
                return (text: try #require(task["text"]?.stringValue), due: task["due"]?.stringValue)
            }
        } else if config.llm.analysis.sections.tasks.enabled {
            tasks = []
        }
        return AnalysisView(
            title: analysis["title"]?.stringValue, summary: analysis["summary"]?.stringValue,
            keyPoints: try sectionItems(analysis, "key_points", config),
            decisions: try sectionItems(analysis, "decisions", config),
            ideas: try sectionItems(analysis, "ideas", config), tags: try sectionItems(analysis, "tags", config),
            tasks: tasks)
    }

    @Test("golden daily_note", arguments: try Golden.cases("daily_note"))
    func goldenDailyNote(item: GoldenCase) throws {
        let config = try GoldenConfig.make(item)
        let zone = try zone(item)
        let timeline = try item.object("timeline")
        let baseText = try #require(timeline["base"]?.stringValue)
        let base = try #require(zone.parseISO(baseText))
        let blocks = try #require(timeline["blocks"]?.arrayValue).map { json in
            let fields = try #require(json.objectValue)
            return TimelineBlock(
                start: try instant(base, fields, "startMs"), end: try instant(base, fields, "endMs"),
                lines: try strings(fields["lines"]))
        }
        let links = try item.object("links")
        let plan = LinkPlan(
            dailyNote: links["dailyNote"]?.stringValue, adjacent: try strings(links["adjacent"]),
            tags: try strings(links["tags"]), raw: try strings(links["raw"]), dropped: [])
        let input = DailyInput(
            analysis: try analysisView(try item.object("analysis"), config), day: try day(item),
            sessionKey: try item.string("sessionKey"), recordingKeys: try item.strings("recordingKeys"),
            excluded: try item.array("excluded").map(excludedPart),
            recordedSeconds: try item.optionalDouble("recordedSeconds"),
            blockCount: try item.int("blockCount"), timeline: blocks, links: plan, zone: zone)
        GoldenAssert.matches(DailyNote.render(input, config: config), group: item.group, name: item.name)
    }

    @Test("golden daily_parts", arguments: try Golden.cases("daily_parts"))
    func goldenDailyParts(item: GoldenCase) throws {
        switch try item.string("kind") {
        case "recorded":
            let values = try item.array("inputs").map { json -> GoldenJSON in
                if json.isNull { return .string(DailyNote.recorded(nil)) }
                let seconds = try #require(json.doubleValue)
                return .string(DailyNote.recorded(seconds))
            }
            GoldenAssert.matchesJSON(.array(values), group: item.group, name: item.name)
        case "tags":
            let tagsJSON = try item.value("tags")
            let tags = tagsJSON.isNull ? nil : try strings(tagsJSON)
            let actual = DailyNote.tags(analysisTags: tags, defaults: try item.strings("defaults"))
            GoldenAssert.matchesJSON(.array(actual.map { .string($0) }), group: item.group, name: item.name)
        case "warnings":
            let sets = try item.array("sets").map { set in
                let parts = try #require(set.arrayValue).map(excludedPart)
                let lines = DailyWarnings.lines(
                    failed: parts.filter { $0.status == .failed }, skipped: parts.filter { $0.status != .failed })
                return GoldenJSON.array(lines.map { .string($0) })
            }
            GoldenAssert.matchesJSON(.array(sets), group: item.group, name: item.name)
        case "sentences":
            let values = try item.strings("inputs").map { text in
                GoldenJSON.array(Timeline.sentences(text).map { .string($0) })
            }
            GoldenAssert.matchesJSON(.array(values), group: item.group, name: item.name)
        default:
            Issue.record("未知の kind: \(item.testDescription)")
        }
    }

    @Test("golden timeline", arguments: try Golden.cases("timeline"))
    func goldenTimeline(item: GoldenCase) throws {
        let zone = try zone(item)
        let base = try #require(zone.parseISO(try item.string("base")))
        let partials = try item.array("partials").map { json in
            let fields = try #require(json.objectValue)
            return AnalysisView(
                title: nil, summary: fields["summary"]?.stringValue,
                keyPoints: try fields["key_points"].map { try strings($0) } ?? [], decisions: nil, ideas: nil,
                tags: nil,
                tasks: nil)
        }
        let chunks = try item.array("chunks").map { json in
            let fields = try #require(json.objectValue)
            return (start: try instant(base, fields, "startMs"), end: try instant(base, fields, "endMs"))
        }
        let transcriptFields = try item.object("transcript")
        let segments = try #require(transcriptFields["segments"]?.arrayValue).map { json in
            let fields = try #require(json.objectValue)
            return AbsoluteSegment(
                at: try instant(base, fields, "atMs"), endAt: try instant(base, fields, "endMs"),
                text: try #require(fields["text"]?.stringValue))
        }
        let blocks = try #require(transcriptFields["blocks"]?.arrayValue).map { json in
            let fields = try #require(json.objectValue)
            return TimeBlock(start: try instant(base, fields, "startMs"), end: try instant(base, fields, "endMs"))
        }
        let transcript = SessionTranscript(
            dayDate: try day(item), segments: segments, blocks: blocks, excludedPartkeys: [])
        let built = Timeline.build(
            partials: partials, chunks: chunks, transcript: transcript, summary: try item.optionalString("summary"))
        let data = Timeline.encode(built, fingerprint: try item.string("fingerprint"), zone: zone)
        GoldenAssert.matches(try #require(String(validating: data, as: UTF8.self)), group: item.group, name: item.name)
    }

    @Test("golden timeline_decode", arguments: try Golden.cases("timeline_decode"))
    func goldenTimelineDecode(item: GoldenCase) throws {
        let zone = try zone(item)
        let blocks = Timeline.decode(
            Data(try item.string("document").utf8), fingerprint: try item.string("fingerprint"), zone: zone)
        let actual = GoldenJSON.array(
            blocks.map { block in
                .object([
                    "start": .string(zone.iso(block.start)), "end": .string(zone.iso(block.end)),
                    "lines": .array(block.lines.map { .string($0) }),
                ])
            })
        GoldenAssert.matchesJSON(actual, group: item.group, name: item.name)
    }

    @Test("golden wiki", arguments: try Golden.cases("wiki"))
    func goldenWiki(item: GoldenCase) throws {
        switch try item.string("kind") {
        case "normalize":
            let values = try item.strings("inputs").map { GoldenJSON.string(VaultIndex.normalize($0)) }
            GoldenAssert.matchesJSON(.array(values), group: item.group, name: item.name)
        case "plan":
            let config = try GoldenConfig.make(item)
            let day = try day(item)
            let namesJSON = try item.value("indexNames")
            let index =
                namesJSON.isNull
                ? nil : VaultIndex(names: Set(try strings(namesJSON).map(VaultIndex.normalize)), builtAt: .zero)
            let plan = LinkPlanner.plan(
                config: config.obsidian, day: day, tags: try item.strings("tags"), index: index,
                selfName: DailyNote.baseName(config: config.obsidian, day: day),
                nameForDay: { DailyNote.baseName(config: config.obsidian, day: $0) },
                rawNames: try item.strings("rawNames"))
            let actual: GoldenJSON = .object([
                "dailyNote": plan.dailyNote.map { .string($0) } ?? .null,
                "adjacent": .array(plan.adjacent.map { .string($0) }),
                "tags": .array(plan.tags.map { .string($0) }),
                "raw": .array(plan.raw.map { .string($0) }),
                "dropped": .array(plan.dropped.map { .string($0) }),
            ])
            GoldenAssert.matchesJSON(actual, group: item.group, name: item.name)
        case "buildIndex":
            let config = try GoldenConfig.make(item)
            let temp = try TempDirectory()
            let root = temp.url
            for rel in try item.strings("files") {
                let url = root.appendingPathComponent(rel)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            }
            for pair in try item.array("symlinkDirs") {
                let names = try strings(pair)
                let link = try #require(names.first)
                let target = try #require(names.last)
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent(link).path(percentEncoded: false),
                    withDestinationPath: root.appendingPathComponent(target).path(percentEncoded: false))
            }
            let index = VaultIndex.build(
                vault: root, excludePrefixes: [VaultIndex.rawFolderPrefix(config.obsidian.raw.folderTemplate)],
                builtAt: .zero)
            let sorted = index.names.sorted {
                $0.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.unicodeScalars.map(\.value))
            }
            GoldenAssert.matchesJSON(.array(sorted.map { .string($0) }), group: item.group, name: item.name)
        case "rawPrefix":
            let config = try GoldenConfig.make(item)
            GoldenAssert.matches(
                VaultIndex.rawFolderPrefix(config.obsidian.raw.folderTemplate), group: item.group, name: item.name)
        default:
            Issue.record("未知の kind: \(item.testDescription)")
        }
    }

    @Test("golden note_filename（Daily）", arguments: try Golden.cases("note_filename"))
    func goldenDailyFilename(item: GoldenCase) throws {
        let config = try GoldenConfig.make(item)
        switch try item.string("kind") {
        case "daily":
            GoldenAssert.matches(
                DailyNote.baseName(config: config.obsidian, day: try day(item)), group: item.group, name: item.name)
        case "dailyFolder":
            GoldenAssert.matches(
                DailyNote.folder(config: config.obsidian, day: try day(item)), group: item.group, name: item.name)
        case "raw", "rawFolder":
            return  // T-26 の goldenRawNoteFilename が確かめる
        default:
            Issue.record("未知の kind: \(item.testDescription)")
        }
    }

    @Test("golden daily_note・daily_parts・timeline・timeline_decode・wiki のケースが在る")
    func goldenGroupsHaveCases() throws {
        #expect(!(try Golden.cases("daily_note")).isEmpty)
        #expect(!(try Golden.cases("daily_parts")).isEmpty)
        #expect(!(try Golden.cases("timeline")).isEmpty)
        #expect(!(try Golden.cases("timeline_decode")).isEmpty)
        #expect(!(try Golden.cases("wiki")).isEmpty)
    }
}
