// PT-01〜PT-22 をリポジトリの Sources/ に当てる（PLAN §9.4。T-04）。
import Foundation
import TestSupport
import Testing

@Suite("Policy")
struct PolicyTests {
    struct MissingRule: Error, CustomStringConvertible {
        let id: String
        var description: String { "規則 \(id) がカタログに無い" }
    }

    static func rule(_ id: String) throws -> PolicyRule {
        guard let rule = PolicyCatalog.tokenRules(vocabulary: try PolicyVocabulary.load()).first(where: { $0.id == id })
        else {
            throw MissingRule(id: id)
        }
        return rule
    }

    static func violations(_ id: String) throws -> [Violation] {
        let files = try SourceTree.load()
        switch id {
        case ImportPolicy.id: return ImportPolicy.check(files: files)
        case PinningPolicy.id:
            return PinningPolicy.check(root: PackageRoot.url, requiredFiles: PolicyAnchors.requiredFiles)
        case OrderingPolicy.id:
            let required = PolicyAnchors.requiredFunctions.contains { $0.path == OrderingPolicy.path }
            return OrderingPolicy.check(files: files, required: required)
        default: return PolicyEngine.check(try rule(id), files: files)
        }
    }

    @Test("PT の一覧が PLAN §9.4 の表と一致する")
    func catalogMatchesPlan() throws {
        let plan = try MarkdownDocument.load("docs/PLAN.md")
        let ids = MarkdownDocument.tables(in: try plan.section("9.4"))
            .flatMap { table in table.rows.compactMap { row in row.first.flatMap { $0.hasPrefix("PT-") ? $0 : nil } } }
        #expect(!ids.isEmpty)
        #expect(ids.sorted() == PolicyCatalog.allIDs(vocabulary: try PolicyVocabulary.load()))
    }

    @Test("Sources に Swift のファイルがある（空で緑にしない）")
    func sourcesAreNotEmpty() throws {
        #expect(!(try SourceTree.load()).isEmpty)
    }

    @Test("PT-06 の語の一覧が空でない（空で緑にしない）")
    func vocabularyIsNotEmpty() throws {
        let vocabulary = try PolicyVocabulary.load()
        #expect(!vocabulary.stateNames.isEmpty)
        #expect(!vocabulary.errorCodeNames.isEmpty)
    }

    @Test("PT-01 削除の呼び出しは許可した場所だけ")
    func pt01Holds() throws {
        let violations = try Self.violations("PT-01")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-02 ネットワークは VDModels と LoopbackHTTP だけ")
    func pt02Holds() throws {
        let violations = try Self.violations("PT-02")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-03 子プロセスの起動は VDProcess だけ")
    func pt03Holds() throws {
        let violations = try Self.violations("PT-03")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-04 シェル経由の起動をしない")
    func pt04Holds() throws {
        let violations = try Self.violations("PT-04")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-05 status を書く SQL と行の作成は Transitions.swift だけ")
    func pt05Holds() throws {
        let violations = try Self.violations("PT-05")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-06 状態名・エラーコード名・partkey の手組みを文字列に書かない")
    func pt06Holds() throws {
        let violations = try Self.violations("PT-06")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-07 import が許可リストに収まる")
    func pt07Holds() throws {
        let violations = try Self.violations("PT-07")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-08 ログと print は Log.swift と reaper のログだけ")
    func pt08Holds() throws {
        let violations = try Self.violations("PT-08")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-09 現在時刻は Clock.swift と ReaperClock.swift だけ")
    func pt09Holds() throws {
        let violations = try Self.violations("PT-09")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-10 デバイス上のファイルを開くのは DeviceReader と InboxWriter だけ")
    func pt10Holds() throws {
        let violations = try Self.violations("PT-10")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-11 reaper の複製と bin/ は DeletionEnabler だけ")
    func pt11Holds() throws {
        let violations = try Self.violations("PT-11")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-12 ファイルの書き込みは許可した場所だけ")
    func pt12Holds() throws {
        let violations = try Self.violations("PT-12")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-13 版・URL・action・ランナーが固定されている")
    func pt13Holds() throws {
        let violations = try Self.violations("PT-13")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-14 @unchecked Sendable と nonisolated(unsafe) を使わない")
    func pt14Holds() throws {
        let violations = try Self.violations("PT-14")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-15 reaper は子プロセス・ネットワーク・再帰削除・他の VD モジュールを使わない")
    func pt15Holds() throws {
        let violations = try Self.violations("PT-15")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-16 copyOne は本体を確定してから記録する")
    func pt16Holds() throws {
        let violations = try Self.violations("PT-16")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-17 診断は書き込み・削除をしない")
    func pt17Holds() throws {
        let violations = try Self.violations("PT-17")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-18 本番のコードは環境変数を読まない")
    func pt18Holds() throws {
        let violations = try Self.violations("PT-18")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-19 precondition・assert・fatalError・try!・as! を使わない")
    func pt19Holds() throws {
        let violations = try Self.violations("PT-19")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-20 Swift の Regex を使わない")
    func pt20Holds() throws {
        let violations = try Self.violations("PT-20")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-21 .recovery は復旧の場所だけ")
    func pt21Holds() throws {
        let violations = try Self.violations("PT-21")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-22 VolumeHandle を作るのは TargetIdentity だけ")
    func pt22Holds() throws {
        let violations = try Self.violations("PT-22")
        #expect(violations.isEmpty, "\(violations)")
    }
}
