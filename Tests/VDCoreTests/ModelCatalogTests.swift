// ModelCatalog の読み込み（OPS-19 の捨て方）と CustomModelID のテスト（T-09）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("ModelCatalog")
struct ModelCatalogTests {
    static let commit = String(repeating: "0", count: 40)
    static let sha = String(repeating: "a", count: 64)

    static func bundled() throws -> ModelCatalog {
        let data = try Data(contentsOf: PackageRoot.url.appendingPathComponent("Resources/ModelCatalog.json"))
        guard case .success(let catalog) = ModelCatalog.load(data) else {
            throw CatalogError.notJSONObject
        }
        return catalog
    }

    /// 形式を満たす whisper の項目（辞書）。
    static func whisperItem(id: String = "w", file: String = "w.bin") -> [String: Any] {
        [
            "id": id, "displayName": id, "file": file,
            "url": "https://huggingface.co/x/y/resolve/\(commit)/\(file)", "sha256": sha, "bytes": 1, "license": "MIT",
        ]
    }

    /// 形式を満たす llm の項目（辞書）。
    static func llmItem() -> [String: Any] {
        var item = whisperItem(id: "l", file: "l.gguf")
        item["minMemoryGB"] = 1
        item["verified"] = true
        return item
    }

    static func load(whisper: [Any] = [], vad: [Any] = [], llm: [Any] = []) throws -> ModelCatalog {
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "whisper": whisper, "vad": vad, "llm": llm,
        ])
        guard case .success(let catalog) = ModelCatalog.load(data) else {
            throw CatalogError.notJSONObject
        }
        return catalog
    }

    @Test("同梱のカタログは捨てる項目なしで読める")
    func bundledCatalogLoads() throws {
        let catalog = try Self.bundled()
        #expect(catalog.rejected.isEmpty)
        #expect(catalog.schema == 1)
        #expect(catalog.whisper.count == 1)
        #expect(catalog.vad.count == 1)
        #expect(catalog.llm.count == 2)
    }

    @Test("既定の ID がカタログに在る")
    func bundledCatalogHasDefaultIDs() throws {
        let catalog = try Self.bundled()
        #expect(catalog.entry(kind: .whisper, id: "large-v3-turbo-q5_0") != nil)
        #expect(catalog.entry(kind: .vad, id: "silero-v5.1.2") != nil)
    }

    @Test("URL はコミット SHA で固定されている（PT-13 と同じ条件）")
    func bundledURLsArePinned() throws {
        let catalog = try Self.bundled()
        for kind in ModelKind.allCases {
            for entry in catalog.entries(kind: kind) {
                #expect(!entry.url.contains("/resolve/main/"), "\(entry.id)")
            }
        }
    }

    @Test("verified が false の LLM は一覧に出ない")
    func listedLLMsExcludeUnverified() throws {
        #expect(try Self.bundled().listedLLMs.isEmpty)
    }

    @Test("空のカタログは項目 0 件で読める")
    func emptyListsLoad() throws {
        let catalog = try Self.load()
        #expect(catalog.whisper.isEmpty && catalog.vad.isEmpty && catalog.llm.isEmpty)
        #expect(catalog.rejected.isEmpty)
        #expect(catalog.listedLLMs.isEmpty)
    }

    @Test("不合格の理由ごとに捨てる（OPS-19）")
    func rejectsEachRule() throws {
        func modified(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var item = Self.whisperItem()
            change(&item)
            return item
        }
        let whisperCases: [(Any, String)] = [
            ("not an object", "not_object"),
            (modified { $0["extra"] = 1 }, "unknown_key"),
            (modified { $0["license"] = nil }, "missing_key"),
            (modified { $0["bytes"] = "1" }, "wrong_type"),
            (modified { $0["id"] = "Upper" }, "bad_id"),
            (
                modified {
                    $0["file"] = "../x"
                    $0["url"] = "https://huggingface.co/x/y/resolve/\(Self.commit)/../x"
                }, "bad_file_name"
            ),
            (
                modified {
                    $0["file"] = ".x"
                    $0["url"] = "https://huggingface.co/x/y/resolve/\(Self.commit)/.x"
                }, "bad_file_name"
            ),
            (modified { $0["url"] = "https://huggingface.co/x/y/resolve/main/w.bin" }, "bad_url"),
            (modified { $0["url"] = "https://example.com/x/y/resolve/\(Self.commit)/w.bin" }, "bad_url"),
            (modified { $0["sha256"] = String(repeating: "a", count: 63) }, "bad_sha256"),
            (modified { $0["bytes"] = 0 }, "bad_bytes"),
        ]
        for (item, reason) in whisperCases {
            let catalog = try Self.load(whisper: [item])
            #expect(catalog.whisper.isEmpty, "\(reason)")
            #expect(catalog.rejected.map(\.reason) == [reason])
            #expect(catalog.rejected.map(\.kind) == [.whisper])
            #expect(catalog.rejected.map(\.index) == [0])
        }
        var badVerified = Self.llmItem()
        badVerified["verified"] = 1
        let catalog = try Self.load(llm: [badVerified])
        #expect(catalog.llm.isEmpty)
        #expect(catalog.rejected.map(\.reason) == ["wrong_type"])
        #expect(catalog.rejected.map(\.kind) == [.llm])
    }

    @Test("同じ ID は先のものを残す")
    func duplicateIDKeepsFirst() throws {
        let catalog = try Self.load(whisper: [Self.whisperItem(file: "a.bin"), Self.whisperItem(file: "b.bin")])
        #expect(catalog.whisper.map(\.file) == ["a.bin"])
        #expect(catalog.rejected.map(\.reason) == ["duplicate_id"])
        #expect(catalog.rejected.map(\.index) == [1])
    }

    @Test("カタログ全体の不正")
    func catalogErrors() throws {
        #expect(ModelCatalog.load(Data("[]".utf8)) == .failure(.notJSONObject))
        #expect(ModelCatalog.load(Data()) == .failure(.notJSONObject))
        let schema2 = try JSONSerialization.data(withJSONObject: ["schema": 2, "whisper": [], "vad": [], "llm": []])
        #expect(ModelCatalog.load(schema2) == .failure(.badSchema))
        let noVAD = try JSONSerialization.data(withJSONObject: ["schema": 1, "whisper": [], "llm": []])
        #expect(ModelCatalog.load(noVAD) == .failure(.missingKind("vad")))
        let extra = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "whisper": [], "vad": [], "llm": [], "x": 1,
        ])
        #expect(ModelCatalog.load(extra) == .failure(.unknownKey("x")))
    }

    @Test("custom:<sha256> の作り方と読み方")
    func customModelID() {
        let lower = String(repeating: "a", count: 64)
        #expect(CustomModelID.make(sha256: "ab") == "custom:ab")
        #expect(CustomModelID.sha256(of: "custom:" + lower) == lower)
        #expect(CustomModelID.sha256(of: "custom:" + String(repeating: "A", count: 64)) == nil)
        #expect(CustomModelID.sha256(of: "custom:" + String(repeating: "a", count: 63)) == nil)
        #expect(CustomModelID.sha256(of: "") == nil)
        let sha = "0123456789abcdef" + String(repeating: "0", count: 48)
        #expect(CustomModelID.fileName(sha256: sha) == "custom-0123456789abcdef.gguf")
    }
}
