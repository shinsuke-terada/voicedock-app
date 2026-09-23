// SafeUnlink の「.. を含まない」を Unicode スカラーの "/" で分けた要素で見る（PLAN §9.2・F-81・issue #119）。
// ASCII のパスの結果は変わらず、"/" の直後に結合文字が来るパスの ".." も拒む（厳しくなる側だけ）。一時ディレクトリの中だけで行う。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("SafeUnlink の .. の判定（F-81）")
struct SafeUnlinkScalarTests {
    let home: TempDirectory
    let layout: HomeLayout

    init() throws {
        home = try TempDirectory()
        layout = HomeLayout(root: home.url)
        try layout.createDirectories()
    }

    func makeFile(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    @Test("F-81 ASCII の .. を含むパスは従来どおり containsDotDot")
    func asciiDotDotIsStillRefused() throws {
        let inboxFile = try makeFile(layout.inbox.appendingPathComponent("x"))
        let target = URL(fileURLWithPath: layout.staging.path(percentEncoded: false) + "sub/../../inbox/x")
        #expect(throws: SafeUnlinkError.containsDotDot) {
            try SafeUnlink.remove(target, under: .staging, layout: layout)
        }
        #expect(exists(inboxFile))
    }

    @Test("F-81 「..x」「x..」は .. ではない（ASCII の名前は従来どおり消す）")
    func dotDotPrefixedNamesAreNotDotDot() throws {
        let leading = try makeFile(layout.staging.appendingPathComponent("..x"))
        let trailing = try makeFile(layout.staging.appendingPathComponent("x.."))
        try SafeUnlink.remove(leading, under: .staging, layout: layout)
        try SafeUnlink.remove(trailing, under: .staging, layout: layout)
        #expect(!exists(leading))
        #expect(!exists(trailing))
    }

    @Test("F-81 「/」の直後に結合文字が来ても、その前の .. を containsDotDot で拒む（書記素では区切りを見落とす）")
    func dotDotBeforeSlashWithCombiningMarkIsRefused() throws {
        let outside = try makeFile(home.url.appendingPathComponent("\u{301}x"))
        let path = layout.staging.path(percentEncoded: false) + "../\u{301}x"
        // 準備の確かめ: 書記素で分けると ".." の要素が現れない（これが成り立たなければテストが空振りする）
        try #require(!path.split(separator: "/", omittingEmptySubsequences: false).contains(".."))
        #expect(throws: SafeUnlinkError.containsDotDot) {
            try SafeUnlink.remove(URL(fileURLWithPath: path), under: .staging, layout: layout)
        }
        #expect(exists(outside))
    }

    @Test("F-81 .. の後ろに結合文字が付いた要素は .. ではない（ルートの配下なら消す）")
    func dotDotWithCombiningMarkIsAnOrdinaryName() throws {
        let file = try makeFile(layout.staging.appendingPathComponent("..\u{301}"))
        try SafeUnlink.remove(file, under: .staging, layout: layout)
        #expect(!exists(file))
    }
}
