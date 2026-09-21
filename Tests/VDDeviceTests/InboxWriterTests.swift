// InboxWriter の .partial への書き込みと確定（T-14 §5.2）。一時ディレクトリの HomeLayout だけを使う。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDDevice

@Suite("InboxWriter")
struct InboxWriterTests {
    /// 100 KiB の既知のバイト
    static let data = Data((0..<102_400).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
    static let relpath = "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"

    struct Fixture {
        let tmp: TempDirectory
        let layout: HomeLayout
        let writer: InboxWriter
        let partial: URL
        let final: URL

        init() throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            writer = InboxWriter(layout: layout)
            partial = layout.inboxPartial(deviceID: "DJIMIC3", relpath: InboxWriterTests.relpath)
            final = layout.inboxFile(deviceID: "DJIMIC3", relpath: InboxWriterTests.relpath)
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    @Test(".partial に書き SHA-256 を返す（まだ確定しない）")
    func writesPartialAndReturnsSHA() throws {
        let f = try Fixture()
        let result = f.writer.writePartial(
            from: FakeChunkReader(bytes: Self.data), expectedSize: Int64(Self.data.count), partial: f.partial,
            chunkBytes: 4096)
        #expect(result == .success(FileHasher.sha256(Self.data)))
        #expect(f.exists(f.partial))
        #expect(!f.exists(f.final))
    }

    @Test("確定で最終の名前になり .partial は消える")
    func commitRenamesToFinal() throws {
        let f = try Fixture()
        _ = f.writer.writePartial(
            from: FakeChunkReader(bytes: Self.data), expectedSize: Int64(Self.data.count), partial: f.partial,
            chunkBytes: 4096)
        let committed = f.writer.commitPartial(f.partial, to: f.final)
        #expect((try? committed.get()) != nil)
        #expect(try Data(contentsOf: f.final) == Self.data)
        #expect(!f.exists(f.partial))
    }

    @Test("読み取りエラーで .partial を消す（抜去）")
    func readErrorRemovesPartial() throws {
        let f = try Fixture()
        let result = f.writer.writePartial(
            from: FakeChunkReader(bytes: Self.data, failAfterChunks: 2), expectedSize: Int64(Self.data.count),
            partial: f.partial, chunkBytes: 4096)
        #expect(result == .failure(.readError(EIO)))
        #expect(!f.exists(f.partial))
    }

    @Test("書いた量が size と違えば copy_size_mismatch で消す")
    func shortReadIsSizeMismatch() throws {
        let f = try Fixture()
        let result = f.writer.writePartial(
            from: FakeChunkReader(bytes: Data(repeating: 0x61, count: 10)), expectedSize: 11, partial: f.partial,
            chunkBytes: 4096)
        #expect(result == .failure(.sizeMismatch))
        #expect(!f.exists(f.partial))
    }

    @Test("CE audio.hashChunkBytes ずつ読む")
    func readsInConfiguredChunks() throws {
        let f = try Fixture()
        let large = FakeChunkReader(bytes: Self.data)
        let small = FakeChunkReader(bytes: Self.data)
        let a = f.writer.writePartial(
            from: large, expectedSize: Int64(Self.data.count), partial: f.partial, chunkBytes: 1_048_576)
        let b = f.writer.writePartial(
            from: small, expectedSize: Int64(Self.data.count), partial: f.partial, chunkBytes: 4096)
        #expect(!large.requestedSizes.isEmpty)
        #expect(large.requestedSizes.allSatisfy { $0 == 1_048_576 })
        // 100 KiB を 4096 ずつ: 25 回で読み切り、26 回目が空（終わり）
        #expect(small.requestedSizes == [Int](repeating: 4096, count: 26))
        #expect(a == .success(FileHasher.sha256(Self.data)))
        #expect(b == .success(FileHasher.sha256(Self.data)))
    }

    @Test("0 バイトは空の SHA-256")
    func emptyFileHasEmptySHA() throws {
        let f = try Fixture()
        let result = f.writer.writePartial(
            from: FakeChunkReader(bytes: Data()), expectedSize: 0, partial: f.partial, chunkBytes: 4096)
        #expect(result == .success("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
    }

    @Test("既存の最終ファイルを確定で置き換える（再コピー）")
    func recopyOverwritesFinal() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(
            at: f.final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: f.final)
        _ = f.writer.writePartial(
            from: FakeChunkReader(bytes: Self.data), expectedSize: Int64(Self.data.count), partial: f.partial,
            chunkBytes: 4096)
        _ = f.writer.commitPartial(f.partial, to: f.final)
        #expect(try Data(contentsOf: f.final) == Self.data)
    }
}
