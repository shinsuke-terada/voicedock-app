// reaper の queue/delete の名前の判定を Unicode スカラーで見る（PLAN §8.9.4・F-81・issue #119）。
// 列挙の「. で始まる」と、要求ファイルの unlink の「/ を含む」。ASCII の名前の結果は変わらず、結合文字の名前は厳しくなる側だけ。
// HOME は一時ディレクトリ（デバイスには触れない）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract

@testable import voicedock_reaper

@Suite("reaper の要求ファイルの名前のスカラー単位の判定（F-81）")
struct QueueNameScalarTests {
    static let early = "20260912T080000Z-a5d046dce76cfedc-a1b2c3.json"
    static let late = "20260912T090000Z-a5d046dce76cfedc-a1b2c3.json"

    struct Stage {
        let tmp: TempDirectory
        let layout: HomeLayout
        let queue: QueueFiles

        init() throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            guard let queue = QueueFiles.make(layout: layout) else {
                throw BenchError(description: "queue/delete を開けない")
            }
            self.queue = queue
        }

        /// queue/delete の下に置く（relative は "/" を含んでよい。親は作る）
        @discardableResult
        func add(_ relative: String) throws -> URL {
            let url = layout.queueDelete.appendingPathComponent(relative, isDirectory: false)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
            return url
        }

        func exists(_ url: URL) -> Bool {
            var st = stat()
            return lstat(url.path(percentEncoded: false), &st) == 0
        }
    }

    @Test("F-81 ASCII の名前の列挙は変わらない（. 始まりを除き、UTF-8 のバイト順）")
    func asciiNamesAreListedAsBefore() throws {
        let s = try Stage()
        try s.add(Self.late)
        try s.add(Self.early)
        try s.add(".tmp.json")
        try s.add("._" + Self.early)
        #expect(s.queue.names() == [Self.early, Self.late])
    }

    @Test("F-81 queue/delete が空なら列挙は 0 件（TEST-28）")
    func emptyQueueListsNothing() throws {
        let s = try Stage()
        #expect(s.queue.names() == [])
    }

    @Test("F-81 「.」の直後に結合文字が来る名前も列挙しない（書記素では「.」始まりに見えない）")
    func dotFollowedByCombiningMarkIsNotListed() throws {
        let hidden = ".\u{301}x.json"
        // 準備の確かめ: 書記素の hasPrefix では「.」始まりに見えない（これが成り立たなければテストが空振りする）
        try #require(!hidden.hasPrefix("."))
        let s = try Stage()
        try s.add(hidden)
        try s.add(Self.early)
        #expect(s.queue.names() == [Self.early])
    }

    @Test("F-81 removeRequest は直下の ASCII の .json を従来どおり消す")
    func removeRequestStillRemovesAsciiJSON() throws {
        let s = try Stage()
        let url = try s.add(Self.early)
        #expect(Unlinker.removeRequest(named: Self.early, inQueueDelete: s.queue.deleteFD))
        #expect(!s.exists(url))
    }

    @Test("F-81 removeRequest は「/」の直後に結合文字が来る名前を消さない（サブディレクトリの中の .json に届かない）")
    func removeRequestRefusesSlashFollowedByCombiningMark() throws {
        let name = "a/\u{301}b.json"
        // 準備の確かめ: 書記素（Character）で探すと "/" が見つからない
        try #require(!name.contains(Character("/")))
        let s = try Stage()
        let url = try s.add(name)
        #expect(!Unlinker.removeRequest(named: name, inQueueDelete: s.queue.deleteFD))
        #expect(s.exists(url))
    }

    @Test("F-81 removeRequest は空の名前・「.」・「..」・.json でない名前を消さない（TEST-28）")
    func removeRequestRefusesEmptyAndDotNames() throws {
        let s = try Stage()
        let other = try s.add("x.txt")
        #expect(!Unlinker.removeRequest(named: "", inQueueDelete: s.queue.deleteFD))
        #expect(!Unlinker.removeRequest(named: ".", inQueueDelete: s.queue.deleteFD))
        #expect(!Unlinker.removeRequest(named: "..", inQueueDelete: s.queue.deleteFD))
        #expect(!Unlinker.removeRequest(named: "x.txt", inQueueDelete: s.queue.deleteFD))
        #expect(s.exists(other))
        #expect(s.exists(s.layout.queueDelete))
    }
}
