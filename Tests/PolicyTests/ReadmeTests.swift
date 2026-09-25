// README.md の件数・参照・逐語の文・見出しの順序の検査（PLAN §10.3 の「文書」。T-43）。
// voicedock tests/unit/test_readme.py と同じ考え: 件数を直書きすると、実装を直したときに文書だけが古くなる。
import Foundation
import TestSupport
import Testing

/// README.md の読み取り。
struct Readme: Sendable {
    static let path = "README.md"
    /// 開発者向けの節の置き場所（F-93 で README から分けた）。
    static let developmentPath = "docs/DEVELOPMENT.md"

    let document: MarkdownDocument
    let text: String

    static func load() throws -> Readme {
        let document = try MarkdownDocument.load(path)
        return Readme(document: document, text: document.lines.joined(separator: "\n"))
    }

    /// parametrize の元を作るときの本文。読めなければ空（`theReadmeExists` が落ちる）。
    static func loadedText() -> String { (try? load().text) ?? "" }

    /// 見出し（深さと本文。フェンスの中は数えない）。
    func headings() -> [(depth: Int, text: String)] {
        var inFence = false
        var found: [(depth: Int, text: String)] = []
        for line in document.lines {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let body = MarkdownDocument.headingText(line) {
                found.append((depth: line.prefix { $0 == "#" }.count, text: body))
            }
        }
        return found
    }

    /// 本文が指すリポジトリ内のパス。
    static func referencedPaths(_ text: String) -> Set<String> {
        let pattern = "(?:^|[\\s`(\\[])((?:docs|scripts|Resources|Vendor|tools)/[A-Za-z0-9._/-]+)"
        return captures(pattern, in: text)
    }

    /// 本文が挙げる `make <target>`。
    static func makeTargets(_ text: String) -> Set<String> { captures("\\bmake ([a-z][a-z-]*)\\b", in: text) }

    /// 本文に現れる `X.Y.Z` の形の数（版の直書きを探す）。
    /// 直後が数字か「.数字」なら 4 つ以上の区切りの一部なので拾わない（`.dmg` や文末の `.` は許す）。
    static func versionLikeNumbers(_ text: String) -> Set<String> {
        captures("(?<![0-9.])([0-9]+\\.[0-9]+\\.[0-9]+)(?![0-9]|\\.[0-9])", in: text)
    }

    /// 本文が挙げる DR の ID。
    static func diagnosticIDs(_ text: String) -> Set<String> { captures("\\b(DR-[0-9]+)\\b", in: text) }

    /// 本文が挙げる RK の ID。
    static func riskIDs(_ text: String) -> Set<String> { captures("\\b(RK-[0-9]+)\\b", in: text) }

    static func captures(_ pattern: String, in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        var found: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            if let range = Range(match.range(at: 1), in: text) {
                found.insert(String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,`)]")))
            }
        }
        return found
    }

    /// 逐語の文（V-7 は欠番）。**この配列がチケットと README をつなぐ唯一の点**。
    static let verbatim: [String] = [
        "**クラウドの AI は使いません。音声もテキストも外部へ出ません。**",  // V-1
        "**使い始める前に、デバイスのボリューム名を決めてください。**",  // V-2
        "システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム",  // V-3
        "**録って、挿す。以上です。**",  // V-4
        "**コピーが終われば抜いて大丈夫です。**",  // V-5
        "**手で書き加えた内容は次の再生成で失われます。**",  // V-6
        "**既定では削除しません。**",  // V-8
        "**元音声の削除は、Raw ノートの検証を通った録音だけを対象にします。**",  // V-9
        "**消した録音は戻りません。**",  // V-10
        "**使い始めた後に、設定のタイムゾーンを変えないでください。**",  // V-11
        "**どちらか一方でも欠けていれば削除しません。**",  // V-12
        "録音デバイスから音声を読み込むために使います",  // V-13
        "Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います",  // V-14
    ]

    /// `Info.plist` と一字一句同じでなければならない 2 つの説明文（V-13・V-14）。
    static let usageDescriptions: [String] = Array(verbatim.suffix(2))

    /// V-3（許可を出し直すシステム設定の経路）。
    static let systemSettingsPath: String = verbatim[2]

    /// 本文の見出し（`#` の個数と本文）を、表の書き方の 1 行にしたもの。
    func headingLines() -> [String] {
        headings().map { String(repeating: "#", count: $0.depth) + " " + $0.text }
    }

    /// PLAN §14 の表にある RK の ID。
    static func planRiskIDs() throws -> Set<String> {
        let lines = try SpecDocument.plan().document.section("14.")
        return captures("^\\| (RK-[0-9]+) \\|", in: lines.joined(separator: "\n"))
    }
}

/// SPEC から数えた件数。**README の数字の唯一の出所。**
struct DocumentedCounts: Sendable {
    /// S6 の生きた ID
    let diagnostics: Int
    /// S6 の「順」の列が `別` の行
    let diagnosticsOnDemand: Int
    /// S8（RV）
    let reaperChecks: Int
    /// S7（ND）
    let noDelete: Int
    /// S9
    let e2e: Int

    static func load() throws -> DocumentedCounts {
        let spec = try SpecDocument.load()
        var onDemand = 0
        for table in MarkdownDocument.tables(in: try spec.document.section("S6")) where table.header.first == "ID" {
            onDemand += table.rows.filter { $0.count > 1 && $0[0].hasPrefix("DR-") && $0[1] == "別" }.count
        }
        return DocumentedCounts(
            diagnostics: try spec.ids(.dr).count, diagnosticsOnDemand: onDemand,
            reaperChecks: try spec.ids(.rv).count, noDelete: try spec.ids(.nd).count, e2e: try spec.ids(.e2e).count)
    }

    var diagnosticsSentence: String {
        "診断は **\(diagnostics) 件**（うち **\(diagnosticsOnDemand) 件** は LLM への実リクエストで、別のボタンから実行します）。"
    }
    var reaperSentence: String { "実行側が判断を信用せず **\(reaperChecks) 項目**を独立に再検証します。" }
    var safetySentence: String { "削除禁止テスト **\(noDelete) 件**（ND）・実機試験 **\(e2e) 件**（E2E）で守っています。" }
}

@Suite("Readme")
struct ReadmeTests {
    /// §4.1 の見出しの表（順序込み）。
    static let expectedHeadings: [String] = [
        "# VoiceDock for Mac",
        "## できること",
        "## 必要なもの",
        "## インストール",
        "### 1. dmg から入れる",
        "### 2. 最初の起動と、許可の出し方",
        "### 3. 「はじめに」を上から済ませる",
        "## 使い方",
        "### できあがるもの",
        "### 状況を見る",
        "### 設定を変える",
        "## 元音声の削除",
        "### 三重ロック",
        "### 削除の根拠",
        "### 有効にする",
        "### 元に戻す",
        "## 困ったとき",
        "## 既知の制約",
        "## データと更新",
        "### データの置き場所",
        "### バックアップ",
        "### 更新",
        "### アンインストール",
        "## ライセンス",
        "## 開発者の方へ",
    ]

    static func currentPaths() -> [String] { Readme.referencedPaths(Readme.loadedText()).sorted() }
    static func developmentGuidePaths() -> [String] {
        let guide = (try? String(contentsOf: PackageRoot.file(Readme.developmentPath), encoding: .utf8)) ?? ""
        return Readme.referencedPaths(guide).sorted()
    }
    static func currentMakeTargets() -> [String] { Readme.makeTargets(Readme.loadedText()).sorted() }
    static func currentDiagnosticIDs() -> [String] { Readme.diagnosticIDs(Readme.loadedText()).sorted() }
    static func currentRiskIDs() -> [String] { Readme.riskIDs(Readme.loadedText()).sorted() }
    static func currentVersionNumbers() -> [String] { Readme.versionLikeNumbers(Readme.loadedText()).sorted() }

    @Test("陽性対照: 参照の抽出が効く")
    func theExtractionFindsAPath() {
        #expect(
            Readme.referencedPaths("[手順](docs/E2E.md) と `scripts/release.sh`") == ["docs/E2E.md", "scripts/release.sh"])
        #expect(Readme.referencedPaths("AVFoundation/CoreAudio").isEmpty)
    }

    @Test("陽性対照: 版の抽出が効く")
    func theExtractionFindsAVersionNumber() {
        #expect(Readme.versionLikeNumbers("VoiceDock-1.0.0.dmg") == ["1.0.0"])
        #expect(Readme.versionLikeNumbers("macOS 15.0 以上").isEmpty)
        #expect(Readme.versionLikeNumbers("約 18.6 GB").isEmpty)
        // 4 つ組の一部（後読みが無いと 2.3.4 を拾う）
        #expect(Readme.versionLikeNumbers("1.2.3.4").isEmpty)
    }

    @Test("空の文字列からは何も抽出しない")
    func theExtractionOfEmptyTextFindsNothing() {
        #expect(Readme.referencedPaths("").isEmpty)
        #expect(Readme.makeTargets("").isEmpty)
        #expect(Readme.versionLikeNumbers("").isEmpty)
        #expect(Readme.diagnosticIDs("").isEmpty)
        #expect(Readme.riskIDs("").isEmpty)
    }

    @Test("README.md が在る")
    func theReadmeExists() throws {
        _ = try Readme.load()
    }

    @Test("見出しが §4.1 の表のとおり")
    func theHeadingsAreInOrder() throws {
        let readme = try Readme.load()
        #expect(readme.headingLines() == Self.expectedHeadings)
    }

    @Test("逐語の文が在る", arguments: Readme.verbatim)
    func everyVerbatimSentenceIsPresent(_ sentence: String) throws {
        let readme = try Readme.load()
        #expect(readme.text.contains(sentence))
    }

    @Test("TCC の説明文が Info.plist と一字一句同じ", arguments: Readme.usageDescriptions)
    func theUsageDescriptionsMatchTheInfoPlist(_ sentence: String) throws {
        let readme = try Readme.load()
        let plist = try String(contentsOf: PackageRoot.file("Resources/Info.plist.template"), encoding: .utf8)
        #expect(plist.contains(sentence))
        #expect(readme.text.contains(sentence))
    }

    @Test("診断の件数が SPEC と一致")
    func theDiagnosticsCountMatchesTheSpec() throws {
        let readme = try Readme.load()
        let counts = try DocumentedCounts.load()
        #expect(readme.text.contains(counts.diagnosticsSentence))
    }

    @Test("reaper の検証の件数が SPEC と一致")
    func theReaperCheckCountMatchesTheSpec() throws {
        let readme = try Readme.load()
        let counts = try DocumentedCounts.load()
        #expect(readme.text.contains(counts.reaperSentence))
    }

    @Test("ND と E2E の件数が SPEC と一致")
    func theSafetyCountsMatchTheSpec() throws {
        let readme = try Readme.load()
        let counts = try DocumentedCounts.load()
        #expect(readme.text.contains(counts.safetySentence))
    }

    @Test("土台: 数える元が空でない")
    func theCountsAreNotZero() throws {
        let counts = try DocumentedCounts.load()
        #expect(counts.diagnostics >= 1)
        #expect(counts.diagnosticsOnDemand >= 1)
        #expect(counts.reaperChecks >= 1)
        #expect(counts.noDelete >= 1)
        #expect(counts.e2e >= 1)
    }

    @Test("README が指すファイルが実在", arguments: ReadmeTests.currentPaths())
    func everyReferencedPathExists(_ path: String) {
        #expect(FileManager.default.fileExists(atPath: PackageRoot.file(path).path))
    }

    @Test("README が挙げる make のターゲットが実在", arguments: ReadmeTests.currentMakeTargets())
    func everyMakeTargetExists(_ target: String) throws {
        let makefile = try String(contentsOf: PackageRoot.file("Makefile"), encoding: .utf8)
        let pattern = "^" + NSRegularExpression.escapedPattern(for: target) + ":"
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(location: 0, length: makefile.utf16.count)
        #expect(regex.firstMatch(in: makefile, range: range) != nil)
    }

    @Test("README が挙げる DR が SPEC に在る", arguments: ReadmeTests.currentDiagnosticIDs())
    func everyDiagnosticIDExists(_ id: String) throws {
        let known = try SpecDocument.load().ids(.dr)
        #expect(known.contains(id))
    }

    @Test("README が挙げる RK が PLAN §14 に在る", arguments: ReadmeTests.currentRiskIDs())
    func everyRiskIDExists(_ id: String) throws {
        let known = try Readme.planRiskIDs()
        #expect(known.contains(id))
    }

    @Test("利用者に効く RK が README に在る", arguments: ["RK-18", "RK-28", "RK-32"])
    func theKnownLimitationsCoverTheUserFacingRisks(_ id: String) throws {
        let readme = try Readme.load()
        #expect(Readme.riskIDs(readme.text).contains(id))
    }

    @Test("版を直書きしない", arguments: ReadmeTests.currentVersionNumbers())
    func theReadmeDoesNotPinAnyVersion(_ number: String) throws {
        // whisper.cpp / llama.cpp の版（Vendor/versions.env に在るもの）だけが書ける
        let versions = try String(contentsOf: PackageRoot.file("Vendor/versions.env"), encoding: .utf8)
        #expect(versions.contains(number))
    }

    @Test("SPEC・計画書の版を書かない")
    func theReadmeDoesNotNameTheSpecVersion() throws {
        let readme = try Readme.load()
        let pattern = "(計画書 ?v[0-9]+\\.[0-9]+|SPEC ?v[0-9]+|詳細仕様書 ?v[0-9]+)"
        #expect(Readme.captures(pattern, in: readme.text).isEmpty)
    }

    @Test(
        "voicedock（Docker 版）の語を持ち込まない",
        arguments: ["docker", "Docker", "compose", "LaunchAgent", "launchctl", "ffmpeg"])
    func theReadmeCarriesNoDockerLeftovers(_ word: String) throws {
        let readme = try Readme.load()
        #expect(!readme.text.contains(word))
    }

    @Test("README が開発者向けの文書を指す")
    func theReadmeLinksTheDevelopmentGuide() throws {
        let readme = try Readme.load()
        #expect(Readme.referencedPaths(readme.text).contains(Readme.developmentPath))
    }

    @Test(
        "主要な文書へのリンクが開発者向けの文書に在る（F-93）",
        arguments: ["docs/PLAN.md", "docs/SPEC.md", "docs/E2E.md", "docs/POC.md", "docs/tickets/README.md"])
    func theDevelopmentGuideLinksTheKeyDocuments(_ path: String) throws {
        let guide = try String(contentsOf: PackageRoot.file(Readme.developmentPath), encoding: .utf8)
        #expect(Readme.referencedPaths(guide).contains(path))
    }

    @Test("開発者向けの文書が指すファイルが実在", arguments: ReadmeTests.developmentGuidePaths())
    func everyPathInTheDevelopmentGuideExists(_ path: String) {
        #expect(FileManager.default.fileExists(atPath: PackageRoot.file(path).path))
    }

    @Test("ライセンスの章が本体と同梱物のライセンスを指す（F-93）", arguments: ["LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"])
    func theLicenseChapterLinksTheLicenseFiles(_ name: String) throws {
        let readme = try Readme.load()
        let body = try readme.document.section("ライセンス").joined(separator: "\n")
        #expect(body.contains("(" + name + ")"))
        #expect(body.contains("Apache License 2.0"))
    }

    @Test("元に戻す手順が在る")
    func theReadmeTellsYouHowToTurnDeletionOff() throws {
        let readme = try Readme.load()
        let body = try readme.document.section("元に戻す").joined(separator: "\n")
        #expect(body.contains("確認は求められません"))
        #expect(body.contains("読み取り専用"))
    }

    @Test("インストールの章が TCC を説明する")
    func theInstallChapterExplainsTCC() throws {
        let readme = try Readme.load()
        let body = try readme.document.section("2. 最初の起動と、許可の出し方").joined(separator: "\n")
        #expect(body.contains(Readme.systemSettingsPath))
        #expect(body.contains(Readme.usageDescriptions[0]))
    }
}
