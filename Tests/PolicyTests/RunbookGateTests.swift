// docs/E2E.md の「削除のゲート」と「削除 ON での再実行」の検査（PLAN §12.4。T-42）。
// T-35 の Runbook 型を使う（同じターゲットなので import は要らない）。
import Foundation
import TestSupport
import Testing

/// `## 4. 削除のゲート` と `## 6. 削除 ON での E2E-01〜09 の再実行` の読み取り。
struct RunbookGate: Sendable {
    /// 表の 1 行（`| G-1 | 条件 | 判定 | 記録 |` と `| R-01 | 元 | 違い | 判定 | 記録 |`）。
    struct Row: Equatable, Sendable {
        let id: String
        let verdict: String
    }

    let runbook: Runbook

    static func load() throws -> RunbookGate { RunbookGate(runbook: try Runbook.load()) }

    /// ゲートの行（先頭の列が `G-<n>`、判定は 3 列目）。
    func gateRows() throws -> [Row] {
        var found: [Row] = []
        for table in MarkdownDocument.tables(in: try runbook.document.section("4. 削除のゲート")) {
            for cells in table.rows where cells.count == 4 && cells[0].hasPrefix("G-") {
                found.append(Row(id: cells[0], verdict: cells[2]))
            }
        }
        return found
    }

    /// ゲートの行の「条件」の列（2 列目）。
    func gateConditions() throws -> [String] {
        var found: [String] = []
        for table in MarkdownDocument.tables(in: try runbook.document.section("4. 削除のゲート")) {
            for cells in table.rows where cells.count == 4 && cells[0].hasPrefix("G-") {
                found.append(cells[1])
            }
        }
        return found
    }

    /// 再実行の行（先頭の列が `R-<nn>`、判定は 4 列目）。
    func rerunRows() throws -> [Row] {
        var found: [Row] = []
        for table in MarkdownDocument.tables(in: try runbook.document.section("6. 削除 ON")) {
            for cells in table.rows where cells.count == 5 && cells[0].hasPrefix("R-") {
                found.append(Row(id: cells[0], verdict: cells[3]))
            }
        }
        return found
    }

    /// `**ゲート: 開**` / `**ゲート: 閉**` の 1 行（フェンスの外。無ければ nil）。
    func gateState() throws -> String? {
        var inFence = false
        for line in try runbook.document.section("4. 削除のゲート") {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "**ゲート: 開**" || trimmed == "**ゲート: 閉**" { return trimmed }
        }
        return nil
    }

    /// 判定が「通った」と言えるか（`✅` か `—` で始まる）。
    static func passes(_ verdict: String) -> Bool { verdict.hasPrefix("✅") || verdict.hasPrefix("—") }

    /// 判定が「実施した」と言えるか（`✅` か `✗` で始まる）。生の出力を要求する条件。
    static func wasRun(_ verdict: String) -> Bool { verdict.hasPrefix("✅") || verdict.hasPrefix("✗") }

    /// フェンスの外の、中身が空でないコードフェンスの数（`####` の見出しを問わない）。
    static func nonEmptyFences(_ lines: [String]) -> Int {
        var count = 0
        var inFence = false
        var bodyLines = 0
        for line in lines {
            if MarkdownDocument.isFence(line) {
                if inFence, bodyLines > 0 { count += 1 }
                bodyLines = 0
                inFence.toggle()
                continue
            }
            if inFence, !line.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines += 1 }
        }
        return count
    }
}

@Suite("RunbookGate")
struct RunbookGateTests {
    /// 判定の 4 つの記号（`✗` は U+2717）。T-35 と同じ。
    static let verdictMarkers = RunbookTests.verdictMarkers

    /// ゲートの条件の列に現れなければならない語（PLAN §12.4 の 1〜4）。
    static let planWords = ["付録 B.1", "付録 B.3", ".diskImage", "1 日"]

    /// 1 日運用の節の見出しの前方一致の鍵。
    static let oneDayKey = "5. 三重ロックを全部外して 1 日"

    /// G-1 と G-3 の記録の節（見出しの前方一致の鍵 → G の ID）。
    static let rawRecordSections = ["4.1 G-1 の記録": "G-1", "4.3 G-3 の記録": "G-3"]

    static let fiveSubheadings = ["前提", "手順", "期待", "記録", "判定"]

    static func gate() throws -> RunbookGate { try RunbookGate.load() }

    /// `### 6.<n> R-0<n> — ` の節の行。
    static func rerunSection(_ id: String) throws -> [String] {
        let n = try #require(Int(id.dropFirst("R-".count)), "R の番号が読めない: \(id)")
        return try gate().runbook.document.section("6.\(n) \(id) — ")
    }

    /// PLAN §12.4 の番号付きの条件の行（`1. …`）。
    static func planConditions() throws -> [String] {
        let regex = try NSRegularExpression(pattern: "^[0-9]+\\. ")
        return try SpecDocument.plan().document.section("12.4").filter { line in
            regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
        }
    }

    @Test("陽性対照: 「通った」の判定が正確")
    func thePassPredicateIsExact() {
        #expect(RunbookGate.passes("✅ PASS"))
        #expect(RunbookGate.passes("— 対象外"))
        #expect(!RunbookGate.passes("⬜ 未実施"))
        #expect(!RunbookGate.passes("✗ FAIL"))
        #expect(!RunbookGate.passes("PASS"))
        #expect(!RunbookGate.passes(""))
    }

    @Test("ゲートの 4 条件が PLAN §12.4 と対応する")
    func theGateTableCoversPlanSection124() throws {
        let plan = try Self.planConditions()
        #expect(plan.count >= 4, "PLAN §12.4 の条件が読めない")
        let ids = try Self.gate().gateRows().map(\.id)
        #expect(ids.count >= 4)
        #expect(ids.count >= plan.count, "PLAN §12.4 は \(plan.count) 条件、ゲートの表は \(ids.count) 行")
        #expect(ids == (0..<ids.count).map { "G-\($0 + 1)" }, "G の行が連番でない: \(ids)")
        let conditions = try Self.gate().gateConditions()
        for word in Self.planWords {
            #expect(conditions.contains { $0.contains(word) }, "\(word) がどの条件にも無い")
        }
    }

    @Test("ゲートの開閉が 1 行で書いてある")
    func theGateHasAState() throws {
        #expect(try Self.gate().gateState() != nil)
    }

    @Test("ゲートを開けるのは全部通ってから")
    func theGateIsClosedUntilEverythingPasses() throws {
        let gate = try Self.gate()
        guard try gate.gateState() == "**ゲート: 開**" else { return }
        let table = try gate.runbook.rows().map { RunbookGate.Row(id: $0.id, verdict: $0.verdict) }
        let gates = try gate.gateRows()
        let reruns = try gate.rerunRows()
        // 番犬: 表が読めないまま「全部通った」にしない
        #expect(!table.isEmpty && !gates.isEmpty && !reruns.isEmpty)
        let failing = (table + gates + reruns).filter { !RunbookGate.passes($0.verdict) }.map(\.id)
        #expect(failing.isEmpty, "ゲートが開なのに通っていない: \(failing.joined(separator: ", "))")
    }

    @Test("G の判定が 4 つの記号のどれかで始まる", arguments: try gate().gateRows().map(\.id))
    func everyGateVerdictStartsWithAMarker(_ id: String) throws {
        let row = try #require(try Self.gate().gateRows().first { $0.id == id })
        #expect(Self.verdictMarkers.contains { row.verdict.hasPrefix($0) }, "判定: \(row.verdict)")
    }

    @Test("R の判定が 4 つの記号のどれかで始まる", arguments: try gate().rerunRows().map(\.id))
    func everyRerunVerdictStartsWithAMarker(_ id: String) throws {
        let row = try #require(try Self.gate().rerunRows().first { $0.id == id })
        #expect(Self.verdictMarkers.contains { row.verdict.hasPrefix($0) }, "判定: \(row.verdict)")
    }

    @Test("再実行の表が R-01〜R-09 の 9 行")
    func theRerunTableCoversOneToNine() throws {
        #expect(
            try Self.gate().rerunRows().map(\.id) == [
                "R-01", "R-02", "R-03", "R-04", "R-05", "R-06", "R-07", "R-08", "R-09",
            ])
    }

    @Test("再実行のそれぞれに節が在る", arguments: try gate().rerunRows().map(\.id))
    func everyRerunHasASection(_ id: String) throws {
        let lines = try Self.rerunSection(id)
        #expect(Runbook.subheadings(lines) == Self.fiveSubheadings)
    }

    @Test("節の判定と表の判定が一致", arguments: try gate().rerunRows().map(\.id))
    func theRerunSectionVerdictMatchesTheTable(_ id: String) throws {
        let row = try #require(try Self.gate().rerunRows().first { $0.id == id })
        #expect(Runbook.verdict(try Self.rerunSection(id)) == row.verdict)
    }

    @Test("「三重ロックを全部外して 1 日」の節が在る")
    func theOneDaySectionExists() throws {
        let lines = try Self.gate().runbook.document.section(Self.oneDayKey)
        #expect(Runbook.subheadings(lines) == Self.fiveSubheadings)
        let verdict = Runbook.verdict(lines)
        #expect(Self.verdictMarkers.contains { verdict.hasPrefix($0) }, "判定: \(verdict)")
    }

    @Test("1 日運用に生の出力が在る")
    func theOneDaySectionHasEvidence() throws {
        let lines = try Self.gate().runbook.document.section(Self.oneDayKey)
        guard RunbookGate.wasRun(Runbook.verdict(lines)) else { return }
        #expect(Runbook.evidenceBlocks(lines) >= 1)
    }

    @Test("G-1 と G-3 の記録に生の出力が在る", arguments: rawRecordSections.keys.sorted())
    func theGateRecordsAreRaw(_ key: String) throws {
        let gate = try Self.gate()
        let id = try #require(Self.rawRecordSections[key])
        let row = try #require(try gate.gateRows().first { $0.id == id }, "ゲートの表に \(id) が無い")
        let lines = try gate.runbook.document.section(key)
        guard RunbookGate.wasRun(row.verdict) else { return }
        #expect(RunbookGate.nonEmptyFences(lines) >= 1, "\(id) は \(row.verdict) なのに \(key) に生の出力が無い")
    }

    @Test("陽性対照: 空のフェンスは生の出力と数えない")
    func theFenceCountIgnoresEmptyFences() {
        #expect(RunbookGate.nonEmptyFences(["```text", "ok", "```"]) == 1)
        #expect(RunbookGate.nonEmptyFences(["```text", "", "```"]) == 0)
        #expect(RunbookGate.nonEmptyFences([]) == 0)
    }

    @Test("削除 ON の 3 件が判定表で ON になっている")
    func theScenariosThatDeleteAreMarked() throws {
        let rows = try Self.gate().runbook.rows()
        #expect(rows.first { $0.id == "E2E-10" }?.deletion == "ON")
        #expect(rows.first { $0.id == "E2E-11" }?.deletion == "ON")
        #expect(rows.first { $0.id == "E2E-17" }?.deletion == "ON→OFF")
    }
}
