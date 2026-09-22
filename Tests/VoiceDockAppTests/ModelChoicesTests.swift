// LLM の選択肢（ModelChoices）のテスト（T-31 §5.3）。カタログは ModelCatalog.load に §8.10 の形の JSON を渡して作る。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VoiceDockApp

@Suite("ModelChoices")
struct ModelChoicesTests {
    static let gib: UInt64 = 1024 * 1024 * 1024
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-t31-models-absent", isDirectory: true))
    static let customSHA = "0123456789abcdef" + String(repeating: "e", count: 48)

    struct LLM {
        let id: String
        var minMemoryGB = 1
        var verified = true
        var bytes = 10
    }

    /// whisper / vad は空、llm は渡したものだけのカタログ
    static func catalog(_ llms: [LLM]) throws -> ModelCatalog {
        let commit = String(repeating: "0", count: 40)
        let sha = String(repeating: "a", count: 64)
        let items = llms.map { m in
            """
            {"id": "\(m.id)", "displayName": "表示 \(m.id)", "file": "\(m.id).gguf", \
            "url": "https://huggingface.co/x/y/resolve/\(commit)/\(m.id).gguf", "sha256": "\(sha)", \
            "bytes": \(m.bytes), "license": "MIT", "minMemoryGB": \(m.minMemoryGB), "verified": \(m.verified)}
            """
        }
        let json = #"{"schema": 1, "whisper": [], "vad": [], "llm": ["# + items.joined(separator: ", ") + "]}"
        let loaded = try ModelCatalog.load(Data(json.utf8)).get()
        try #require(loaded.rejected.isEmpty)
        return loaded
    }

    @Test("verified が真のものだけ出す")
    func onlyVerifiedAreListed() throws {
        let c = try Self.catalog([LLM(id: "listed"), LLM(id: "hidden", verified: false)])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 64 * Self.gib, currentID: nil, layout: Self.layout)
        #expect(choices.map(\.id) == ["listed"])
    }

    @Test("カタログの順のまま")
    func catalogOrderIsKept() throws {
        let c = try Self.catalog([LLM(id: "zeta"), LLM(id: "alpha")])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 64 * Self.gib, currentID: nil, layout: Self.layout)
        #expect(choices.map(\.id) == ["zeta", "alpha"])
    }

    @Test("メモリ不足は選べない")
    func insufficientMemoryIsNotSelectable() throws {
        let c = try Self.catalog([LLM(id: "big", minMemoryGB: 32)])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 16 * Self.gib, currentID: nil, layout: Self.layout)
        let choice = try #require(choices.first)
        #expect(choice.selectable == false)
        #expect(choice.note == "メモリが足りません（32 GB 以上が必要。この Mac は 16 GB）")
    }

    @Test("ちょうどなら選べる")
    func exactMemoryIsSelectable() throws {
        let c = try Self.catalog([LLM(id: "fit", minMemoryGB: 16)])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 16 * Self.gib, currentID: nil, layout: Self.layout)
        let choice = try #require(choices.first)
        #expect(choice.selectable == true)
        #expect(choice.note == nil)
    }

    @Test("minMemoryGB が無ければ選べる")
    func noMinMemoryIsSelectable() throws {
        // カタログの llm は minMemoryGB が必須なので、nil になる custom の行で見る
        let c = try Self.catalog([])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 0, currentID: "custom:" + Self.customSHA, layout: Self.layout)
        let choice = try #require(choices.first)
        #expect(choice.minMemoryGB == nil)
        #expect(choice.selectable == true)
    }

    @Test("選べなくても一覧から消さない")
    func insufficientStaysInTheList() throws {
        let c = try Self.catalog([LLM(id: "a", minMemoryGB: 64), LLM(id: "b", minMemoryGB: 128)])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 8 * Self.gib, currentID: nil, layout: Self.layout)
        #expect(choices.count == 2)
        #expect(choices.allSatisfy { !$0.selectable })
    }

    @Test("custom は末尾に足す")
    func customIsAppendedLast() throws {
        let c = try Self.catalog([LLM(id: "a")])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 64 * Self.gib, currentID: "custom:" + Self.customSHA, layout: Self.layout)
        let last = try #require(choices.last)
        #expect(choices.count == 2)
        #expect(last.isCustom)
        #expect(last.id == "custom:" + Self.customSHA)
        #expect(last.note == "動作保証外のモデルです")
    }

    @Test("custom の名前は SHA 先頭 8")
    func customNameShowsShortSHA() throws {
        let c = try Self.catalog([])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 64 * Self.gib, currentID: "custom:" + Self.customSHA, layout: Self.layout)
        #expect(choices.last?.displayName == "読み込んだモデル（01234567）")
    }

    @Test("カタログの ID では custom を足さない")
    func customIsNotAddedForCatalogID() throws {
        let c = try Self.catalog([LLM(id: "a"), LLM(id: "b")])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 64 * Self.gib, currentID: "a", layout: Self.layout)
        #expect(!choices.contains { $0.isCustom })
        #expect(choices.count == 2)
    }

    @Test("在否はファイルの有無と size")
    func presenceFollowsTheFile() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let layout = HomeLayout(root: tmp.url)
        let c = try Self.catalog([LLM(id: "placed", bytes: 10), LLM(id: "missing", bytes: 10)])
        let dir = tmp.url.appendingPathComponent("models/llm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent("placed.gguf", isDirectory: false))
        let choices = ModelChoices.llm(catalog: c, physicalMemoryBytes: 64 * Self.gib, currentID: nil, layout: layout)
        #expect(choices.map(\.present) == [true, false])
        #expect(ModelChoices.llmIsPresent(id: "placed", catalog: c, layout: layout))
        #expect(!ModelChoices.llmIsPresent(id: "missing", catalog: c, layout: layout))
        #expect(!ModelChoices.llmIsPresent(id: nil, catalog: c, layout: layout))
    }

    @Test("TEST-28 空のカタログ")
    func emptyCatalogGivesNoChoices() throws {
        let c = try Self.catalog([])
        let choices = ModelChoices.llm(
            catalog: c, physicalMemoryBytes: 64 * Self.gib, currentID: nil, layout: Self.layout)
        #expect(choices == [])
    }
}
