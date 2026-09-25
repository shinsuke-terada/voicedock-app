// ResumeStore のテスト（T-23 §5.2）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore
@testable import VDModels

@Suite("ResumeStore")
struct ResumeStoreTests {
    static let entry = ModelEntry(
        id: "test-whisper", displayName: "T", file: "ggml-t.bin",
        url: "https://huggingface.co/a/b/resolve/\(String(repeating: "0", count: 40))/ggml-t.bin",
        sha256: String(repeating: "a", count: 64), bytes: 1, license: "MIT", minMemoryGB: nil, verified: nil)

    private func world() throws -> (TempDirectory, HomeLayout) {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url)
        try layout.createDirectories()
        return (tmp, layout)
    }

    @Test("models/.<file>.resume に書く")
    func savesUnderModels() throws {
        let (tmp, layout) = try world()
        defer { tmp.remove() }
        ResumeStore.save(Data(repeating: 1, count: 64), for: Self.entry, layout: layout)
        let path = tmp.url.appendingPathComponent("models/.ggml-t.bin.resume").path(percentEncoded: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.size] as? NSNumber)?.intValue == 64)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("書いたものを読める")
    func loadsWhatWasSaved() throws {
        let (tmp, layout) = try world()
        defer { tmp.remove() }
        ResumeStore.save(Data(repeating: 1, count: 64), for: Self.entry, layout: layout)
        #expect(ResumeStore.load(Self.entry, layout: layout) == Data(repeating: 1, count: 64))
    }

    @Test("16 バイト未満は使わない")
    func shortDataIsIgnored() throws {
        let (tmp, layout) = try world()
        defer { tmp.remove() }
        try Data(repeating: 1, count: 15).write(to: layout.modelResume(file: "ggml-t.bin"))
        #expect(ResumeStore.load(Self.entry, layout: layout) == nil)
    }

    @Test("無ければ nil（TEST-28）")
    func missingIsNil() throws {
        let (tmp, layout) = try world()
        defer { tmp.remove() }
        #expect(ResumeStore.load(Self.entry, layout: layout) == nil)
    }

    @Test("捨てると消える")
    func discardRemoves() throws {
        let (tmp, layout) = try world()
        defer { tmp.remove() }
        let url = layout.modelResume(file: "ggml-t.bin")
        try Data(repeating: 1, count: 64).write(to: url)
        ResumeStore.discard(Self.entry, layout: layout)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        ResumeStore.discard(Self.entry, layout: layout)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
