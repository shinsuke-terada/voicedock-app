// docs/RELEASE.md と、v1.0 を出せる状態かの検査（PLAN §11.4・§12.4。T-44）。
import Foundation
import TestSupport
import Testing

struct ReleaseDoc: Sendable {
    static let path = "docs/RELEASE.md"

    let document: MarkdownDocument
    let text: String

    static func load() throws -> ReleaseDoc {
        let document = try MarkdownDocument.load(path)
        return ReleaseDoc(document: document, text: document.lines.joined(separator: "\n"))
    }

    /// 確認表の行（`| RL-01 | 条件 | 確かめ方 | 判定 | 記録 |`）。
    func checklist() throws -> [(id: String, verdict: String)] {
        var found: [(String, String)] = []
        for table in MarkdownDocument.tables(in: try document.section("2. リリース前の確認表")) {
            for cells in table.rows where cells.count == 5 && cells[0].hasPrefix("RL-") {
                found.append((cells[0], cells[3]))
            }
        }
        return found.map { (id: $0.0, verdict: $0.1) }
    }

    /// `VERSION` の中身（前後の空白を除く）。
    static func versionString() throws -> String {
        try String(contentsOf: PackageRoot.file("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `X.Y.Z` を数値の組にする（`AppVersion.components` と同じ規則。PolicyTests は VDContract に依存しないので写す）。
    static func components(_ s: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return (numbers[0], numbers[1], numbers[2])
    }
}

@Suite("ReleaseChecklist")
struct ReleaseChecklistTests {
    /// §4.1 の見出しの表（順序込み。19 行）。
    static let expectedHeadings: [String] = [
        "# VoiceDock for Mac のリリース手順",
        "## 0. この文書の約束",
        "## 1. 版の決め方",
        "## 2. リリース前の確認表",
        "## 3. 手順",
        "### 3.1 版を上げる PR",
        "### 3.2 develop → main",
        "### 3.3 タグを打つ",
        "### 3.4 make release",
        "### 3.5 GitHub のリリースを作る（公開リポジトリ）",
        "### 3.6 リリース後",
        "## 4. 失敗したときの戻し方",
        "## 5. 記録",
        "### 5.1 削除のゲート",
        "### 5.2 make test",
        "### 5.3 make test-disk",
        "### 5.4 make release と verify-bundle",
        "### 5.5 別アカウントでの導入",
        "### 5.6 未解決の issue",
    ]

    /// 手順が触れていなければならないコマンド（§5 の表）。
    static let gateCommands = [
        "make release", "scripts/verify-bundle.sh", "gh release create", "--verify-tag", "shasum -a 256", "git tag -a",
    ]

    static let templatePath = "docs/release-notes/TEMPLATE.md"

    /// 版の組。`VERSION` が読めなければ nil（`theVersionIsOnePointZeroOrLater` が落ちる）。
    static func version() -> (major: Int, minor: Int, patch: Int)? {
        (try? ReleaseDoc.versionString()).flatMap(ReleaseDoc.components)
    }

    /// v1.0 を名乗っているか（`major >= 1`）。0.x.y の間はゲートの 3 本が素通りする。
    static func claimsOnePointZero() -> Bool { (version()?.major ?? 0) >= 1 }

    /// parametrize の元。読めなければ空（`theReleaseDocExists` が落ちる）。
    static func loadedText() -> String { (try? ReleaseDoc.load().text) ?? "" }
    static func checklistIDs() -> [String] { (try? ReleaseDoc.load().checklist().map(\.id)) ?? [] }
    static func currentPaths() -> [String] { Readme.referencedPaths(loadedText()).sorted() }
    static func currentMakeTargets() -> [String] { Readme.makeTargets(loadedText()).sorted() }

    /// コードフェンスの外の行だけを連結したもの（`## 5. 記録` の生の出力には版が出るので見ない）。
    static func proseOutsideFences(_ text: String) -> String {
        var inFence = false
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if !inFence { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    static func pinnedVersionsInDoc() -> [String] {
        Readme.versionLikeNumbers(proseOutsideFences(loadedText())).sorted()
    }

    static func templateText() -> String {
        (try? String(contentsOf: PackageRoot.file(templatePath), encoding: .utf8)) ?? ""
    }

    static func pinnedVersionsInTemplate() -> [String] { Readme.versionLikeNumbers(templateText()).sorted() }

    /// 比べやすいように配列にする（タプルは Equatable でない）。
    static func parsed(_ s: String) -> [Int]? {
        ReleaseDoc.components(s).map { [$0.major, $0.minor, $0.patch] }
    }

    @Test("陽性対照: 版の読み取りが正確")
    func theComponentParserIsExact() {
        #expect(Self.parsed("1.0.0") == [1, 0, 0])
        #expect(Self.parsed("1.10.0") == [1, 10, 0])
        #expect(Self.parsed("1.0") == nil)
        #expect(Self.parsed("1.0.0 ") == nil)
        #expect(Self.parsed("1.0.0a") == nil)
        #expect(Self.parsed("01.0.0") == [1, 0, 0])
        // 空の入力（TEST-28）
        #expect(Self.parsed("") == nil)
    }

    @Test("版が 1.0.0 以上")
    func theVersionIsOnePointZeroOrLater() throws {
        let v = try #require(Self.version())
        #expect((v.major, v.minor, v.patch) >= (1, 0, 0))
    }

    @Test("docs/RELEASE.md が在る")
    func theReleaseDocExists() throws {
        _ = try ReleaseDoc.load()
    }

    @Test("見出しが §4.1 のとおり")
    func theReleaseHeadingsAreInOrder() throws {
        let doc = try ReleaseDoc.load()
        let lines = Readme(document: doc.document, text: doc.text).headingLines()
        #expect(lines.count == 19)
        #expect(lines == Self.expectedHeadings)
    }

    @Test("確認表が RL-01 から連番")
    func theChecklistIsConsecutive() throws {
        let ids = try ReleaseDoc.load().checklist().map(\.id)
        #expect(ids.count >= 12)
        #expect(ids == (1...max(ids.count, 1)).map { String(format: "RL-%02d", $0) })
    }

    @Test("確認表の判定が記号で始まる", arguments: ReleaseChecklistTests.checklistIDs())
    func everyChecklistVerdictStartsWithAMarker(_ id: String) throws {
        let row = try #require(try ReleaseDoc.load().checklist().first { $0.id == id })
        #expect(RunbookTests.verdictMarkers.contains { row.verdict.hasPrefix($0) }, "判定: \(row.verdict)")
    }

    @Test("ゲートが開いていなければ v1.0 を名乗れない")
    func theReleaseIsGatedOnTheDeletionGate() throws {
        guard Self.claimsOnePointZero() else { return }
        #expect(try RunbookGate.load().gateState() == "**ゲート: 開**")
    }

    @Test("E2E-06 が済んでいなければ v1.0 を名乗れない")
    func theOneDayScenarioIsDone() throws {
        guard Self.claimsOnePointZero() else { return }
        let row = try #require(try Runbook.load().rows().first { $0.id == "E2E-06" })
        #expect(row.verdict.hasPrefix("✅"), "E2E-06: \(row.verdict)")
    }

    @Test("確認表が全部通っている")
    func everyChecklistPassesBeforeRelease() throws {
        guard Self.claimsOnePointZero() else { return }
        for row in try ReleaseDoc.load().checklist() {
            #expect(RunbookGate.passes(row.verdict), "\(row.id): \(row.verdict)")
        }
    }

    @Test("docs/DEVELOPMENT.md の Phase 9 が — のままでない")
    func theReadmeStatusIsUpdated() throws {
        guard Self.claimsOnePointZero() else { return }
        let guide = try MarkdownDocument.load(Readme.developmentPath)
        let rows = MarkdownDocument.tables(in: try guide.section("状態")).flatMap(\.rows)
        let phase9 = try #require(rows.first { $0.first?.hasPrefix("9") == true })
        #expect(phase9.count >= 2)
        #expect(phase9.dropFirst().first != "—")
    }

    @Test("RELEASE.md が指すファイルが実在", arguments: ReleaseChecklistTests.currentPaths())
    func everyReferencedPathExists(_ path: String) {
        #expect(FileManager.default.fileExists(atPath: PackageRoot.file(path).path))
    }

    @Test("RELEASE.md が挙げる make のターゲットが実在", arguments: ReleaseChecklistTests.currentMakeTargets())
    func everyMakeTargetExists(_ target: String) throws {
        let makefile = try String(contentsOf: PackageRoot.file("Makefile"), encoding: .utf8)
        let pattern = "^" + NSRegularExpression.escapedPattern(for: target) + ":"
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(location: 0, length: makefile.utf16.count)
        #expect(regex.firstMatch(in: makefile, range: range) != nil)
    }

    @Test("手順に版を直書きしない", arguments: ReleaseChecklistTests.pinnedVersionsInDoc())
    func theReleaseDocDoesNotPinTheVersion(_ number: String) {
        Issue.record("docs/RELEASE.md のフェンスの外に版の直書き: \(number)（`$version` か `<版>` で書く）")
    }

    @Test("雛形に版を直書きしない", arguments: ReleaseChecklistTests.pinnedVersionsInTemplate())
    func theTemplateDoesNotPinTheVersion(_ number: String) {
        Issue.record("\(Self.templatePath) に版の直書き: \(number)（`<版>` で書く）")
    }

    @Test("リリースノートの雛形が在る")
    func theReleaseNotesTemplateExists() throws {
        let text = try String(contentsOf: PackageRoot.file(Self.templatePath), encoding: .utf8)
        #expect(text.contains("<版>"))
    }

    @Test("手順が必須のコマンドに触れている", arguments: ReleaseChecklistTests.gateCommands)
    func theReleaseDocNamesTheGate(_ command: String) throws {
        #expect(try ReleaseDoc.load().text.contains(command))
    }

    @Test("公開リポジトリの配り方を説明している（F-101）")
    func theReleaseDocExplainsPublicDistribution() throws {
        let section = try ReleaseDoc.load().document.section("3.5").joined(separator: "\n")
        #expect(section.contains("gh release download"))
        #expect(section.contains("匿名"))
    }
}
