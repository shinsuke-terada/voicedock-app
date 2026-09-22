// UIState / UIStateStore（<HOME>/ui-state.json）のテスト（T-31 §5.1）。
import Foundation
import TestSupport
import Testing

@testable import VoiceDockApp

@Suite("UIState")
struct UIStateTests {
    static func file(_ tmp: TempDirectory) -> URL {
        tmp.url.appendingPathComponent("ui-state.json", isDirectory: false)
    }

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @Test("ファイルが無ければ既定")
    func missingFileGivesDefaults() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = Self.file(tmp)
        let loaded = UIStateStore(url: url).load()
        #expect(loaded == UIState(schema: 1, loginItemDecided: false))
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("書いて読める")
    func roundTrip() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let store = UIStateStore(url: Self.file(tmp))
        #expect(store.save(UIState(schema: 1, loginItemDecided: true)))
        #expect(store.load().loginItemDecided == true)
    }

    @Test("壊れた JSON は既定")
    func brokenJSONGivesDefaults() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = Self.file(tmp)
        try Self.write("{", to: url)
        #expect(UIStateStore(url: url).load() == UIState(schema: 1, loginItemDecided: false))
    }

    @Test("将来の schema は解釈しない")
    func futureSchemaGivesDefaults() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = Self.file(tmp)
        try Self.write(#"{"schema": 2, "loginItemDecided": true}"#, to: url)
        let loaded = UIStateStore(url: url).load()
        #expect(loaded.loginItemDecided == false)
        #expect(loaded.schema == 1)
    }

    @Test("未知のキーは無視する")
    func unknownKeysAreIgnored() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = Self.file(tmp)
        try Self.write(#"{"schema":1,"loginItemDecided":true,"x":1}"#, to: url)
        #expect(UIStateStore(url: url).load().loginItemDecided == true)
    }

    /// 鍵と型は SPEC S23（PLAN §8.12 の表）から読む（SPEC 同期は issue #18 で足した。PLAN F-68）
    @Test("書くのは SPEC S23 の 2 キーだけ（型も表のとおり）")
    func savedFileHasOnlyTwoKeys() throws {
        let spec = try SpecDocument.load().uiStateKeys()
        #expect(spec.map(\.key) == ["schema", "loginItemDecided"])
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = Self.file(tmp)
        #expect(UIStateStore(url: url).save(UIState(schema: 1, loginItemDecided: true)))
        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.sorted() == spec.map(\.key).sorted())
        for row in spec {
            let value = try #require(object[row.key] as? NSNumber, "\(row.key)")
            // JSONSerialization は真偽を CFBoolean の NSNumber で返す
            let isBool = CFGetTypeID(value) == CFBooleanGetTypeID()
            switch row.type {
            case "整数": #expect(!isBool, "\(row.key) は整数")
            case "真偽": #expect(isBool, "\(row.key) は真偽")
            default: Issue.record("\(row.key) の型 \(row.type) を知らない")
            }
        }
        // 値の列がバッククォートの整数なら、その値を書く（schema の 1）
        let schema = try #require(spec.first { $0.key == "schema" })
        #expect(schema.value == "`\(UIState.currentSchema)`")
        #expect(data.last == UInt8(ascii: "\n"))
    }

    @Test("書けなければ false")
    func saveFailureReturnsFalse() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let dir = tmp.url.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path(percentEncoded: false))
        let url = dir.appendingPathComponent("ui-state.json", isDirectory: false)
        #expect(UIStateStore(url: url).save(UIState(schema: 1, loginItemDecided: true)) == false)
    }
}
