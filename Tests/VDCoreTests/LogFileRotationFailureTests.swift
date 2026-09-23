// app.log の回転の rename に失敗したときに大きさを 0 に戻さないことのテスト（F-83。PLAN §8.15。issue #119 の H6）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("LogFile（F-83）")
struct LogFileRotationFailureTests {
    func contents(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test("F-83 回転の rename に失敗しても大きさを 0 に戻さず、rename できるようになった次の書き込みで回す")
    func failedRotationKeepsTheSize() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("app.log")
        // app.log.1 が中身のあるディレクトリだと rename(app.log, app.log.1) は失敗する
        let blocker = temp.url.appendingPathComponent("app.log.1", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("keep"))
        let file = LogFile(url: url, maxBytes: 10)
        file.write(line: "12345", level: .info, category: "core")
        file.write(line: "6789", level: .info, category: "core")  // 回転を試みて失敗し、そのまま追記する
        #expect(try contents(url) == "12345\n6789\n")
        try FileManager.default.removeItem(at: blocker)
        file.write(line: "ab", level: .info, category: "core")  // 11 バイトの app.log を見て回す
        file.close()
        #expect(try contents(temp.url.appendingPathComponent("app.log.1")) == "12345\n6789\n")
        #expect(try contents(url) == "ab\n")
    }

    @Test("F-83 空の行も大きさに数える（TEST-28）")
    func emptyLineCounts() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("app.log")
        let file = LogFile(url: url, maxBytes: 2)
        file.write(line: "", level: .info, category: "core")
        file.write(line: "", level: .info, category: "core")
        file.write(line: "", level: .info, category: "core")
        file.close()
        #expect(try contents(temp.url.appendingPathComponent("app.log.1")) == "\n\n")
        #expect(try contents(url) == "\n")
    }
}
