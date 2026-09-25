// データの初期化の配線（PLAN §8.15・F-95）: Bootstrap.build は単一起動のロック → 設定の読み込み（ロック 1 の修復を含む）→
// DataReset.performIfRequested（消す能力と設定の deleteSourceAudio の両方を渡す）→ Store の順に呼び、LiveServices.requestDataReset は
// 同じ 2 つを確かめてから DataReset.request を呼ぶ。SafeUnlinkRoot.database を使うのは SafeUnlink と DataReset だけ。
// Bootstrap と LiveServices は本物の <HOME> と AppContext を使うのでふるまいのテストに載せられない。中身は DataResetTests が固定し、
// ここは配線をトークンで固定する。
import Foundation
import TestSupport
import Testing

@Suite("データの初期化の配線（F-95）")
struct DataResetWiringTests {
    static let bootstrapPath = "VoiceDockApp/Bootstrap.swift"
    static let servicesPath = "VoiceDockApp/AppServices.swift"
    /// `.database`（SafeUnlinkRoot）を書いてよいファイル
    static let databaseRootAllowed: Set<String> = ["VDCore/SafeUnlink.swift", "VDPipeline/DataReset.swift"]

    /// 本体の中で `receiver . name (` が最初に現れる位置
    static func firstCall(_ receiver: String, _ name: String, in body: ArraySlice<CodeToken>) -> Int? {
        body.indices.first { index in
            index >= body.startIndex + 2 && index + 1 < body.endIndex && body[index].kind == .identifier
                && body[index].text == name && body[index + 1].text == "(" && body[index - 1].text == "."
                && body[index - 2].text == receiver
        }
    }

    /// range の中に識別子 name があるか
    static func mentions(_ name: String, in body: ArraySlice<CodeToken>, _ range: Range<Int>) -> Bool {
        range.contains { body[$0].kind == .identifier && body[$0].text == name }
    }

    /// Bootstrap.build の違反（無ければ空）
    static func bootstrapViolations(in file: SourceFile) -> [String] {
        guard let body = OrderingPolicy.body(of: "build", in: file.tokens) else { return ["func build( がありません"] }
        let lock = OrderingPolicy.firstCall("acquireInstanceLock", in: body)
        let load = firstCall("config", "load", in: body)
        let reset = firstCall("DataReset", "performIfRequested", in: body)
        let store = OrderingPolicy.firstCall("Store", in: body)
        var out: [String] = []
        if lock == nil { out.append("acquireInstanceLock( がありません") }
        if load == nil { out.append("config.load( がありません") }
        if reset == nil { out.append("DataReset.performIfRequested( がありません") }
        if store == nil { out.append("Store( がありません") }
        guard let lock, let load, let reset, let store else { return out }
        if !(lock < load && load < reset && reset < store) {
            out.append("順が acquireInstanceLock → config.load → DataReset.performIfRequested → Store でない")
        }
        if load < reset {
            if !mentions("hasRemainingCapability", in: body, load..<reset) {
                out.append("performIfRequested の前に hasRemainingCapability がありません")
            }
            if !mentions("deleteSourceAudio", in: body, load..<reset) {
                out.append("performIfRequested の前に deleteSourceAudio がありません")
            }
        }
        return out
    }

    /// LiveServices.requestDataReset の違反（無ければ空）
    static func servicesViolations(in file: SourceFile) -> [String] {
        let tokens = AttentionWiringTests.liveServices(file.tokens)
        guard let body = OrderingPolicy.body(of: "requestDataReset", in: tokens) else {
            return ["LiveServices の func requestDataReset( がありません"]
        }
        guard let request = firstCall("DataReset", "request", in: body) else {
            return ["DataReset.request( がありません"]
        }
        var out: [String] = []
        if !mentions("hasRemainingCapability", in: body, body.startIndex..<request) {
            out.append("DataReset.request の前に hasRemainingCapability がありません")
        }
        if !mentions("deleteSourceAudio", in: body, body.startIndex..<request) {
            out.append("DataReset.request の前に deleteSourceAudio がありません")
        }
        return out
    }

    /// 識別子として字句になるが、後ろの `.x` が省略形になるキーワード
    static let keywordsBeforeShorthand: Set<String> = [
        "case", "return", "in", "where", "is", "as", "try", "await", "throw", "else", "if", "guard", "switch",
    ]

    /// `.database` を enum の省略形か `SafeUnlinkRoot.database` で書いているか（`layout.database` などのメンバーは除く）
    static func usesDatabaseRoot(_ file: SourceFile) -> Bool {
        let t = file.tokens
        return t.indices.contains { i in
            guard i >= 1, t[i].kind == .identifier, t[i].text == "database", t[i - 1].text == "." else { return false }
            // `.database(` は値を持つ別の型のケース（BootFailure など）。SafeUnlinkRoot.database は値を持たない
            if i + 1 < t.count, t[i + 1].text == "(" { return false }
            guard i >= 2 else { return true }
            let before = t[i - 2]
            if before.text == "SafeUnlinkRoot" { return true }
            // メンバー（`layout.database`・`f().database`・`a[0].database`・`x?.database`）。キーワードの後は省略形
            let member =
                (before.kind == .identifier && !Self.keywordsBeforeShorthand.contains(before.text))
                || [")", "]", "?", "!"].contains(before.text)
            return !member
        }
    }

    @Test("F-95 起動はロック → 設定 → 初期化（消す能力と deleteSourceAudio を渡す）→ DB の順")
    func bootstrapResetsBeforeOpeningTheStore() throws {
        let files = try SourceTree.load()
        let file = try #require(files.first { $0.relativePath == Self.bootstrapPath })
        #expect(Self.bootstrapViolations(in: file) == [])
    }

    @Test("F-95 LiveServices.requestDataReset は消す能力と deleteSourceAudio を確かめてから予約する")
    func servicesCheckDeletionBeforeRequesting() throws {
        let files = try SourceTree.load()
        let file = try #require(files.first { $0.relativePath == Self.servicesPath })
        #expect(Self.servicesViolations(in: file) == [])
    }

    @Test("F-95 SafeUnlinkRoot.database を使うのは SafeUnlink と DataReset だけ")
    func databaseRootIsUsedOnlyByTheReset() throws {
        let files = try SourceTree.load()
        let users = files.filter { Self.usesDatabaseRoot($0) }.map(\.relativePath)
        #expect(Set(users) == Self.databaseRootAllowed)
    }

    static let bootstrap = """
        func build() async {
            switch acquireInstanceLock(layout: layout) { default: break }
            let loaded = await config.load()
            let residual = await enabler.hasRemainingCapability()
            let appEnabled = loadedConfig?.cleanup.deleteSourceAudio == true
            _ = DataReset.performIfRequested(layout: layout, deletionCapable: residual || appEnabled, log: log)
            do { store = try Store(url: layout.database) } catch {}
        }
        """

    @Test(
        "F-95 自己テスト: Bootstrap の欠落・順の入れ替え・確かめの欠落・関数が無い（空の入力。TEST-28）を検出する",
        arguments: [
            (bootstrap, [String]()),
            (
                bootstrap.replacingOccurrences(of: "DataReset.performIfRequested", with: "DataReset.other"),
                ["DataReset.performIfRequested( がありません"]
            ),
            (
                bootstrap.replacingOccurrences(of: "enabler.hasRemainingCapability()", with: "false"),
                ["performIfRequested の前に hasRemainingCapability がありません"]
            ),
            (
                bootstrap.replacingOccurrences(of: "loadedConfig?.cleanup.deleteSourceAudio == true", with: "false"),
                ["performIfRequested の前に deleteSourceAudio がありません"]
            ),
            (
                """
                func build() async {
                    switch acquireInstanceLock(layout: layout) { default: break }
                    do { store = try Store(url: layout.database) } catch {}
                    let loaded = await config.load()
                    let residual = await enabler.hasRemainingCapability()
                    let appEnabled = loadedConfig?.cleanup.deleteSourceAudio == true
                    _ = DataReset.performIfRequested(layout: layout, deletionCapable: residual || appEnabled, log: log)
                }
                """,
                ["順が acquireInstanceLock → config.load → DataReset.performIfRequested → Store でない"]
            ),
            ("", ["func build( がありません"]),
        ])
    func bootstrapSelfTest(_ source: String, _ expected: [String]) {
        #expect(Self.bootstrapViolations(in: SourceFile(relativePath: Self.bootstrapPath, text: source)) == expected)
    }

    static let services = """
        protocol AppServices { func requestDataReset() async -> Bool }
        struct LiveServices: AppServices {
            func requestDataReset() async -> Bool {
                let residual = await context.enabler.hasRemainingCapability()
                let appEnabled = await context.config.current()?.cleanup.deleteSourceAudio == true
                return DataReset.request(layout: context.layout, deletionCapable: residual || appEnabled, log: log)
            }
        }
        """

    @Test(
        "F-95 自己テスト: LiveServices の確かめの欠落・予約の欠落・関数が無い（空の入力。TEST-28）を検出する",
        arguments: [
            (services, [String]()),
            (
                services.replacingOccurrences(of: "context.enabler.hasRemainingCapability()", with: "false"),
                ["DataReset.request の前に hasRemainingCapability がありません"]
            ),
            (
                services.replacingOccurrences(
                    of: "context.config.current()?.cleanup.deleteSourceAudio == true", with: "false"),
                ["DataReset.request の前に deleteSourceAudio がありません"]
            ),
            (
                services.replacingOccurrences(of: "DataReset.request", with: "DataReset.other"),
                ["DataReset.request( がありません"]
            ),
            ("", ["LiveServices の func requestDataReset( がありません"]),
        ])
    func servicesSelfTest(_ source: String, _ expected: [String]) {
        #expect(Self.servicesViolations(in: SourceFile(relativePath: Self.servicesPath, text: source)) == expected)
    }

    @Test(
        "F-95 自己テスト: .database の省略形と SafeUnlinkRoot.database を拾い、layout.database などのメンバーは拾わない",
        arguments: [
            ("try SafeUnlink.remove(url, under: .database, layout: layout)", true),
            ("let r = SafeUnlinkRoot.database", true),
            ("switch root { case .database: return layout.root }", true),
            ("return .database", true),
            ("return .failure(.database(ErrorText.describe(error)))", false),
            ("let u = layout.database", false),
            ("let u = context?.database", false),
            ("let u = context.layout().database", false),
            ("", false),
        ])
    func databaseRootSelfTest(_ source: String, _ expected: Bool) {
        #expect(Self.usesDatabaseRoot(SourceFile(relativePath: "X/Y.swift", text: source)) == expected)
    }
}
