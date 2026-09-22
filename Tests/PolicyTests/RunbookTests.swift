// docs/E2E.md が docs/SPEC.md の S9 と 1 対 1 で、書式が守られ、参照先が実在することの検査（PLAN §10.3 の「文書」。T-35）。
// voicedock tests/unit/test_runbook.py（#93・#55）と同じ考え: 手順の正本を git の中に置き、腐らないことを機械で守る。
import Foundation
import TestSupport
import Testing

/// `docs/E2E.md` の読み取り。**先に抽出だけを固定し（陽性・陰性対照）、その上で本体を検査する。**
struct Runbook: Sendable {
    /// 判定表の 1 行。
    struct Row: Equatable, Sendable {
        let id: String
        let title: String
        let deletion: String
        let verdict: String
        let record: String
    }

    /// シナリオの節。
    struct Section: Equatable, Sendable {
        let number: Int
        let id: String
        let title: String
        /// `####` の見出しの本文（出現順）。
        let subheadings: [String]
        /// `#### 判定` の直後の空でない行。
        let verdict: String
        /// `#### 記録` の中の空でないコードフェンスの数。
        let evidenceBlocks: Int
        /// 節の全文。
        let body: String
    }

    static let path = "docs/E2E.md"

    let document: MarkdownDocument

    static func load() throws -> Runbook { Runbook(document: try MarkdownDocument.load(path)) }

    /// 判定表（`## 2. 判定表` の中の、見出しの先頭が `#` の表）。
    func rows() throws -> [Row] {
        var found: [Row] = []
        for table in MarkdownDocument.tables(in: try document.section("2. 判定表")) where table.header.first == "#" {
            for cells in table.rows where cells.count == 5 && cells[0].hasPrefix("E2E-") {
                found.append(
                    Row(id: cells[0], title: cells[1], deletion: cells[2], verdict: cells[3], record: cells[4]))
            }
        }
        return found
    }

    /// シナリオの節（`### 3.<n> E2E-<nn> — <題>`）。
    func sections() -> [Section] {
        var found: [Section] = []
        var current: (number: Int, id: String, title: String, start: Int)?
        var inFence = false
        func close(_ end: Int) {
            guard let open = current else { return }
            let lines = Array(document.lines[open.start..<end])
            found.append(
                Section(
                    number: open.number, id: open.id, title: open.title,
                    subheadings: Self.subheadings(lines), verdict: Self.verdict(lines),
                    evidenceBlocks: Self.evidenceBlocks(lines), body: lines.joined(separator: "\n")))
            current = nil
        }
        for (index, line) in document.lines.enumerated() {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let head = Self.scenarioHeading(line) {
                close(index)
                current = (head.number, head.id, head.title, index + 1)
            } else if MarkdownDocument.headingText(line) != nil, Self.depth(line) <= 3 {
                close(index)
            }
        }
        close(document.lines.count)
        return found
    }

    static func depth(_ line: String) -> Int { line.prefix { $0 == "#" }.count }

    /// `### 3.<n> E2E-<nn> — <題>` を読む（フェンスの外だけで使う）。
    static func scenarioHeading(_ line: String) -> (number: Int, id: String, title: String)? {
        guard let text = MarkdownDocument.headingText(line), depth(line) == 3 else { return nil }
        let pattern = "^3\\.([0-9]+) (E2E-[0-9]+) — (.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
            let number = Range(match.range(at: 1), in: text), let id = Range(match.range(at: 2), in: text),
            let title = Range(match.range(at: 3), in: text), let n = Int(text[number])
        else { return nil }
        return (n, String(text[id]), String(text[title]))
    }

    static func subheadings(_ lines: [String]) -> [String] {
        var inFence = false
        var found: [String] = []
        for line in lines {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if depth(line) == 4, let text = MarkdownDocument.headingText(line) { found.append(text) }
        }
        return found
    }

    static func verdict(_ lines: [String]) -> String {
        var seen = false
        var inFence = false
        for line in lines {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if depth(line) == 4, MarkdownDocument.headingText(line) == "判定" {
                seen = true
                continue
            }
            if seen, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    static func evidenceBlocks(_ lines: [String]) -> Int {
        var inRecord = false
        var count = 0
        var inFence = false
        var bodyLines = 0
        for line in lines {
            if MarkdownDocument.isFence(line) {
                if inFence {
                    if inRecord, bodyLines > 0 { count += 1 }
                    bodyLines = 0
                }
                inFence.toggle()
                continue
            }
            if inFence {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines += 1 }
                continue
            }
            if depth(line) == 4, let text = MarkdownDocument.headingText(line) { inRecord = (text == "記録") }
        }
        return count
    }

    /// 本文が参照するリポジトリ内のパス（`scripts/x.sh`・`Vendor/x.sh`・`tools/x/y.py`・`docs/X.md`・`Tests/…`）。
    static func referencedPaths(_ text: String) -> Set<String> {
        let pattern = "(?:^|[\\s`(])((?:scripts|Vendor|tools|docs|Resources|Tests)/[A-Za-z0-9._/-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        var found: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            if let range = Range(match.range(at: 1), in: text) {
                found.insert(String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,`)")))
            }
        }
        return found
    }

    /// 本文が挙げる `make <target>`。
    static func makeTargets(_ text: String) -> Set<String> {
        let pattern = "\\bmake ([a-z][a-z-]*)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
        }
        return found
    }
}

@Suite("Runbook")
struct RunbookTests {
    /// 判定の 4 つの記号（`✗` は U+2717）。
    static let verdictMarkers = ["✅", "✗", "⬜", "—"]

    /// voicedock の手順の写し残し（消えたスクリプト・構成）。
    static let removedNames = ["helper/", "docker compose", "voicedock-ingest"]

    /// `/Volumes/` を含む行に現れてはならない語（デバイスへ書く・マウントを変える）。
    static let deviceWriteWords = ["diskutil", "hdiutil", "rm ", "mv ", "touch ", "> "]

    static func runbook() throws -> Runbook { try Runbook.load() }

    static func fullText() throws -> String { try runbook().document.lines.joined(separator: "\n") }

    static func sectionIDs() throws -> [String] { try runbook().sections().map(\.id) }

    /// S9 の表の ID → 「削除」の列（ID の列が `E2E-` で始まる行）。
    static func specDeletion() throws -> [String: String] {
        let spec = try SpecDocument.load()
        var found: [String: String] = [:]
        for table in MarkdownDocument.tables(in: try spec.document.section("S9.")) {
            for cells in table.rows where cells.count == 3 && cells[0].hasPrefix("E2E-") {
                found[cells[0]] = cells[2]
            }
        }
        return found
    }

    static func specIDs() throws -> [String] { try SpecDocument.load().ids(.e2e) }

    /// `## 1. 前提` の「共通のコマンド」の表の「名前」の列の `[C-<n>]`。
    static func commandNames() throws -> [String] {
        let regex = try NSRegularExpression(pattern: "\\[C-[0-9]+\\]")
        var names: [String] = []
        let tables = MarkdownDocument.tables(in: try runbook().document.section("1. 前提"))
        for table in tables where table.header.first == "名前" {
            for cells in table.rows {
                guard let cell = cells.first else { continue }
                let range = NSRange(location: 0, length: cell.utf16.count)
                if let match = regex.firstMatch(in: cell, range: range), let r = Range(match.range, in: cell) {
                    names.append(String(cell[r]))
                }
            }
        }
        return names
    }

    /// `## 3.` の見出しより後の本文。
    static func scenarioText() throws -> String {
        let lines = try runbook().document.lines
        guard
            let start = lines.firstIndex(where: {
                Runbook.depth($0) == 2 && (MarkdownDocument.headingText($0)?.hasPrefix("3.") ?? false)
            })
        else { return "" }
        return lines[(start + 1)...].joined(separator: "\n")
    }

    /// デバイスへ書く手順が無い行か（`/Volumes/` を含む行に書き込み・マウント操作の語が無い）。
    static func isSafeForTheDevice(_ line: String) -> Bool {
        guard line.contains("/Volumes/") else { return true }
        return !deviceWriteWords.contains { line.contains($0) }
    }

    static func matches(_ pattern: String, _ text: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    @Test("陽性対照: シナリオの見出しを拾える")
    func theHeadingExtractionWorks() throws {
        let ten = try #require(Runbook.scenarioHeading("### 3.10 E2E-10 — 削除 ON で通し"))
        #expect(ten.number == 10)
        #expect(ten.id == "E2E-10")
        #expect(ten.title == "削除 ON で通し")
        let one = try #require(Runbook.scenarioHeading("### 3.1 E2E-01 — 1 本を通しで"))
        #expect(one.number == 1)
        #expect(one.id == "E2E-01")
        #expect(one.title == "1 本を通しで")
    }

    @Test("陰性対照: 別の見出しは拾わない")
    func theHeadingExtractionIgnoresOtherHeadings() {
        #expect(Runbook.scenarioHeading("## 3. シナリオ") == nil)
        #expect(Runbook.scenarioHeading("#### 手順") == nil)
        #expect(Runbook.scenarioHeading("### 3.1 E2E-01 削除") == nil)
        #expect(Runbook.scenarioHeading("") == nil)
    }

    @Test("陽性対照: 判定を拾える")
    func theVerdictExtractionWorks() {
        #expect(Runbook.verdict(["#### 記録", "（なし）", "#### 判定", "", "✅ PASS"]) == "✅ PASS")
        #expect(Runbook.verdict(["#### 記録", "（なし）"]).isEmpty)
        #expect(Runbook.verdict([]).isEmpty)
    }

    @Test("陽性対照: 空のフェンスは証拠と数えない")
    func theEvidenceCountIgnoresEmptyFences() {
        #expect(Runbook.evidenceBlocks(["#### 記録", "```text", "exit=0", "```", "#### 判定"]) == 1)
        #expect(Runbook.evidenceBlocks(["#### 記録", "```text", "```", "#### 判定"]) == 0)
        #expect(Runbook.evidenceBlocks(["#### 手順", "```text", "ls", "```", "#### 記録", "#### 判定"]) == 0)
    }

    @Test("docs/E2E.md が在る")
    func theRunbookExists() throws {
        _ = try Runbook.load()
    }

    @Test("E2E-nn の並びが SPEC の S9 と 1 対 1・同順")
    func theVerdictTableMatchesTheSpec() throws {
        let spec = try Self.specIDs()
        #expect(!spec.isEmpty)
        #expect(try Self.runbook().rows().map(\.id) == spec)
    }

    @Test("判定表の「削除」の列が SPEC と一致", arguments: try specDeletion().keys.sorted())
    func theDeletionColumnMatchesTheSpec(_ id: String) throws {
        let expected = try #require(try Self.specDeletion()[id])
        let row = try #require(try Self.runbook().rows().first { $0.id == id }, "判定表に \(id) が無い")
        #expect(row.deletion == expected)
    }

    @Test("判定が 4 つの記号のどれかで始まる", arguments: try runbook().rows().map(\.id))
    func everyVerdictStartsWithAMarker(_ id: String) throws {
        let row = try #require(try Self.runbook().rows().first { $0.id == id })
        #expect(Self.verdictMarkers.contains { row.verdict.hasPrefix($0) }, "判定: \(row.verdict)")
    }

    @Test("シナリオごとに手順の節が在る", arguments: try specIDs())
    func everyScenarioHasASection(_ id: String) throws {
        #expect(try Self.runbook().sections().filter { $0.id == id }.count == 1)
    }

    @Test("節の番号と E2E の番号が同じ", arguments: try sectionIDs())
    func sectionNumberMatchesTheScenario(_ id: String) throws {
        let section = try #require(try Self.runbook().sections().first { $0.id == id })
        #expect(section.number == Int(id.dropFirst("E2E-".count)))
    }

    @Test("節の題が判定表の題と同じ", arguments: try sectionIDs())
    func sectionTitleMatchesTheTable(_ id: String) throws {
        let runbook = try Self.runbook()
        let section = try #require(runbook.sections().first { $0.id == id })
        let row = try #require(try runbook.rows().first { $0.id == id }, "判定表に \(id) が無い")
        #expect(section.title == row.title)
    }

    @Test("節の判定と判定表の判定が一致", arguments: try sectionIDs())
    func sectionVerdictMatchesTheTable(_ id: String) throws {
        let runbook = try Self.runbook()
        let section = try #require(runbook.sections().first { $0.id == id })
        let row = try #require(try runbook.rows().first { $0.id == id }, "判定表に \(id) が無い")
        #expect(section.verdict == row.verdict)
    }

    @Test("節は 前提・手順・期待・記録・判定 をこの順に持つ", arguments: try sectionIDs())
    func everySectionHasTheFiveSubheadings(_ id: String) throws {
        let section = try #require(try Self.runbook().sections().first { $0.id == id })
        #expect(section.subheadings == ["前提", "手順", "期待", "記録", "判定"])
    }

    @Test(
        "PASS / FAIL のシナリオは生の出力を持つ",
        arguments: try runbook().sections().filter { $0.verdict.hasPrefix("✅") || $0.verdict.hasPrefix("✗") }.map(\.id))
    func aVerdictNeedsEvidence(_ id: String) throws {
        let section = try #require(try Self.runbook().sections().first { $0.id == id })
        #expect(section.evidenceBlocks >= 1)
    }

    @Test("実機の手順に【利用者が行う】が在る", arguments: try sectionIDs())
    func everySectionSaysWhoRunsIt(_ id: String) throws {
        let section = try #require(try Self.runbook().sections().first { $0.id == id })
        #expect(section.body.contains("【利用者が行う】"))
    }

    @Test("手順が指すリポジトリ内のファイルが実在", arguments: try Runbook.referencedPaths(fullText()).sorted())
    func referencedPathsExist(_ path: String) {
        #expect(FileManager.default.fileExists(atPath: PackageRoot.file(path).path), "\(path) が無い")
    }

    @Test("手順が挙げる make のターゲットが実在", arguments: try Runbook.makeTargets(fullText()).sorted())
    func referencedMakeTargetsExist(_ target: String) throws {
        let makefile = try String(contentsOf: PackageRoot.file("Makefile"), encoding: .utf8)
        let lines = makefile.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.contains { $0.hasPrefix(target + ":") }, "Makefile に \(target): が無い")
    }

    @Test("消えたスクリプト名を書いていない")
    func theRunbookNamesNoRemovedScript() throws {
        let text = try Self.fullText()
        for name in Self.removedNames {
            #expect(!text.contains(name), "\(name) が残っている")
        }
    }

    @Test("SPEC の版を直書きしない")
    func theRunbookDoesNotPinTheSpecVersion() throws {
        let text = try Self.fullText()
        #expect(!(try Self.matches("計画書 v[0-9]+\\.[0-9]+", text)))
        #expect(!(try Self.matches("SPEC\\.md v[0-9]+", text)))
    }

    @Test("安全: デバイスへ書く手順が無い")
    func theRunbookNeverTellsYouToWriteToTheDevice() throws {
        for line in try Self.runbook().document.lines {
            #expect(Self.isSafeForTheDevice(line), "デバイスへ書く行: \(line)")
        }
    }

    @Test("陽性対照: 上の検査が効く")
    func theSafetyCheckWouldCatchIt() {
        #expect(!Self.isSafeForTheDevice(#"rm -rf "/Volumes/$DEV/x""#))
        #expect(Self.isSafeForTheDevice(#"find "/Volumes/$DEV" -type f"#))
    }

    @Test("## 1. 前提 の共通コマンドが使われている", arguments: try commandNames())
    func theCommandTableIsUsed(_ name: String) throws {
        #expect(try Self.scenarioText().contains(name), "\(name) が ## 3. より後で使われていない")
    }

    @Test("土台: 共通のコマンドの表が空でない")
    func theCommandTableIsNotEmpty() throws {
        let names = try Self.commandNames()
        #expect(names.count >= 5)
        #expect(names.contains("[C-1]"))
        #expect(names.contains("[C-7]"))
    }
}
