// ModelImporter のテスト（T-23 §5.3）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDModels

@Suite("ModelImporter")
struct ModelImporterTests {
    static let gguf = Data((0..<2_500_000).map { UInt8($0 % 97) })
    static let sha = FileHasher.sha256(gguf)
    /// 空のデータの SHA-256（固定値）。
    static let emptySHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private func world() throws -> (TempDirectory, HomeLayout) {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url)
        try layout.createDirectories()
        return (tmp, layout)
    }

    private func llmContents(_ layout: HomeLayout) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: layout.models(kind: "llm").path(percentEncoded: false))
            .sorted()
    }

    /// tmp/<name> に data を置く。
    private func source(_ tmp: TempDirectory, _ name: String, _ data: Data) throws -> URL {
        let url = tmp.url.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url)
        return url
    }

    @Test("custom-<sha16>.gguf に置いて custom:<sha> を返す")
    func importsAndNamesBySHA() throws {
        let (tmp, layout) = try world()
        let src = try source(tmp, "in.gguf", Self.gguf)
        let r = ModelImporter.importGGUF(from: src, layout: layout, chunkBytes: 1_048_576)
        let v = try r.get()
        #expect(v.id == "custom:" + Self.sha)
        #expect(v.url == tmp.url.appendingPathComponent("models/llm/custom-\(Self.sha.prefix(16)).gguf"))
        #expect(try Data(contentsOf: v.url) == Self.gguf)
    }

    @Test("`.part` を残さない")
    func partIsRemovedAfterRename() throws {
        let (tmp, layout) = try world()
        let src = try source(tmp, "in.gguf", Self.gguf)
        _ = try ModelImporter.importGGUF(from: src, layout: layout, chunkBytes: 1_048_576).get()
        #expect(try llmContents(layout) == ["custom-\(Self.sha.prefix(16)).gguf"])
    }

    @Test("既に在れば `.part` を消して既存を使う")
    func existingFileIsReused() throws {
        let (tmp, layout) = try world()
        let existing = layout.modelFile(kind: "llm", file: "custom-\(Self.sha.prefix(16)).gguf")
        try Data([1, 2, 3]).write(to: existing)
        let src = try source(tmp, "in.gguf", Self.gguf)
        let v = try ModelImporter.importGGUF(from: src, layout: layout, chunkBytes: 1_048_576).get()
        #expect(v.id == "custom:" + Self.sha)
        #expect(v.url == existing)
        #expect(try Data(contentsOf: existing) == Data([1, 2, 3]))
        #expect(try llmContents(layout).count == 1)
    }

    @Test("中身が違えば別の ID")
    func differentContentGivesDifferentID() throws {
        let (tmp, layout) = try world()
        let a = try source(tmp, "a.gguf", Self.gguf)
        let b = try source(tmp, "b.gguf", Self.gguf + Data([0]))
        let ra = try ModelImporter.importGGUF(from: a, layout: layout, chunkBytes: 1_048_576).get()
        let rb = try ModelImporter.importGGUF(from: b, layout: layout, chunkBytes: 1_048_576).get()
        #expect(ra.id != rb.id)
        #expect(try llmContents(layout).count == 2)
    }

    @Test("無いファイルは io")
    func missingSourceFails() throws {
        let (tmp, layout) = try world()
        let r = ModelImporter.importGGUF(
            from: tmp.url.appendingPathComponent("nope.gguf"), layout: layout, chunkBytes: 1_048_576)
        guard case .failure(.io) = r else {
            Issue.record("io で失敗するはず: \(r)")
            return
        }
        #expect(try llmContents(layout).isEmpty)
    }

    @Test("ディレクトリは受けない")
    func directorySourceFails() throws {
        let (tmp, layout) = try world()
        let dir = tmp.url.appendingPathComponent("dir.gguf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let r = ModelImporter.importGGUF(from: dir, layout: layout, chunkBytes: 1_048_576)
        #expect(r.failureValue == .io("not_a_regular_file"))
    }

    @Test("symlink は受けない")
    func symlinkSourceFails() throws {
        let (tmp, layout) = try world()
        let target = try source(tmp, "in.gguf", Self.gguf)
        let link = tmp.url.appendingPathComponent("link.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let r = ModelImporter.importGGUF(from: link, layout: layout, chunkBytes: 1_048_576)
        #expect(r.failureValue == .io("not_a_regular_file"))
        #expect(try llmContents(layout).isEmpty)
    }

    @Test("空ファイルも取り込める（TEST-28）")
    func emptyFileIsImported() throws {
        let (tmp, layout) = try world()
        let src = try source(tmp, "empty.gguf", Data())
        let v = try ModelImporter.importGGUF(from: src, layout: layout, chunkBytes: 1_048_576).get()
        #expect(v.id == "custom:" + Self.emptySHA)
        #expect(try Data(contentsOf: v.url).isEmpty)
    }

    @Test("chunkBytes が 4096 未満なら断る")
    func tooSmallChunkIsRefused() throws {
        let (tmp, layout) = try world()
        let src = try source(tmp, "in.gguf", Self.gguf)
        let r = ModelImporter.importGGUF(from: src, layout: layout, chunkBytes: 100)
        #expect(r.failureValue == .io("chunk_bytes"))
        #expect(try llmContents(layout).isEmpty)
    }
}

extension Result where Failure == ModelError {
    /// 失敗なら誤り、成功なら nil。
    fileprivate var failureValue: ModelError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
