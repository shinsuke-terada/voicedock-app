// ModelFiles（モデルの置き場所と在否。PLAN §8.10）のテスト（T-09）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ModelFiles")
struct ModelFilesTests {
    static let entry = ModelEntry(
        id: "w", displayName: "w", file: "w.bin",
        url: "https://huggingface.co/x/y/resolve/\(String(repeating: "0", count: 40))/w.bin",
        sha256: String(repeating: "a", count: 64), bytes: 4, license: "MIT", minMemoryGB: nil, verified: nil)

    static func put(_ bytes: Int, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test("url は models/<kind>/<file>")
    func urlIsUnderKindDirectory() {
        let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/vd-home", isDirectory: true))
        let url = ModelFiles.url(kind: .whisper, entry: Self.entry, layout: layout)
        #expect(url.path(percentEncoded: false) == "/tmp/vd-home/models/whisper/w.bin")
    }

    @Test("customLLMURL は custom-<先頭 16>.gguf、形が違えば nil")
    func customLLMURL() {
        let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/vd-home", isDirectory: true))
        let sha = "0123456789abcdef" + String(repeating: "0", count: 48)
        let url = ModelFiles.customLLMURL(id: "custom:" + sha, layout: layout)
        #expect(url?.path(percentEncoded: false) == "/tmp/vd-home/models/llm/custom-0123456789abcdef.gguf")
        #expect(ModelFiles.customLLMURL(id: "custom:" + String(repeating: "A", count: 64), layout: layout) == nil)
        #expect(ModelFiles.customLLMURL(id: "custom:abc", layout: layout) == nil)
        #expect(ModelFiles.customLLMURL(id: "test-llm", layout: layout) == nil)
        #expect(ModelFiles.customLLMURL(id: "", layout: layout) == nil)
    }

    @Test("サイズが bytes と一致する通常ファイルだけ在る")
    func isPresentChecksSize() throws {
        let home = try TempDirectory()
        defer { home.remove() }
        let layout = HomeLayout(root: home.url)
        let target = ModelFiles.url(kind: .whisper, entry: Self.entry, layout: layout)
        #expect(!ModelFiles.isPresent(Self.entry, kind: .whisper, layout: layout))
        try Self.put(4, at: target)
        #expect(ModelFiles.isPresent(Self.entry, kind: .whisper, layout: layout))
        #expect(!ModelFiles.isPresent(Self.entry, kind: .vad, layout: layout))
        try Self.put(3, at: target)
        #expect(!ModelFiles.isPresent(Self.entry, kind: .whisper, layout: layout))
    }

    @Test("0 バイトのファイルは在ると言わない")
    func zeroByteFileIsNotPresent() throws {
        let home = try TempDirectory()
        defer { home.remove() }
        let layout = HomeLayout(root: home.url)
        try Self.put(0, at: ModelFiles.url(kind: .whisper, entry: Self.entry, layout: layout))
        #expect(!ModelFiles.isPresent(Self.entry, kind: .whisper, layout: layout))
    }

    @Test("symlink は辿って判定し、ディレクトリは在ると言わない")
    func symlinkIsFollowed() throws {
        let home = try TempDirectory()
        defer { home.remove() }
        let layout = HomeLayout(root: home.url)
        let target = ModelFiles.url(kind: .whisper, entry: Self.entry, layout: layout)
        let real = home.url.appendingPathComponent("real.bin")
        try Self.put(4, at: real)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: real)
        #expect(ModelFiles.isPresent(Self.entry, kind: .whisper, layout: layout))
        let vadTarget = ModelFiles.url(kind: .vad, entry: Self.entry, layout: layout)
        try FileManager.default.createDirectory(at: vadTarget, withIntermediateDirectories: true)
        #expect(!ModelFiles.isPresent(Self.entry, kind: .vad, layout: layout))
    }
}
