// app.log への追記と 1 世代の回転の検査（PLAN §8.15。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("LogFile")
struct LogFileTests {
    func contents(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test("行を追記する")
    func appendsLines() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("app.log")
        let file = LogFile(url: url)
        file.write(line: "a", level: .info, category: "core")
        file.write(line: "b", level: .info, category: "core")
        file.close()
        #expect(try contents(url) == "a\nb\n")
        let reopened = LogFile(url: url)
        reopened.write(line: "", level: .info, category: "core")
        reopened.close()
        #expect(try contents(url) == "a\nb\n\n")
    }

    @Test("上限を超える書き込みの前に .1 へ回す")
    func rotatesBeforeExceeding() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("app.log")
        let file = LogFile(url: url, maxBytes: 10)
        file.write(line: "12345", level: .info, category: "core")
        file.write(line: "6789", level: .info, category: "core")
        file.close()
        #expect(try contents(temp.url.appendingPathComponent("app.log.1")) == "12345\n")
        #expect(try contents(url) == "6789\n")
    }

    @Test(".1 は 1 世代だけ")
    func rotationReplacesOldBackup() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("app.log")
        let file = LogFile(url: url, maxBytes: 10)
        for line in ["111111111", "222222222", "333333333", "444444444"] {
            file.write(line: line, level: .info, category: "core")
        }
        file.close()
        #expect(try contents(temp.url.appendingPathComponent("app.log.1")) == "333333333\n")
        #expect(try contents(url) == "444444444\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: temp.url.path(percentEncoded: false)).sorted()
        #expect(names == ["app.log", "app.log.1"])
    }

    @Test("書けない場所でも落ちない")
    func unwritableDirectoryDoesNotThrow() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("app.log")
        let file = LogFile(url: url)
        file.write(line: "a", level: .error, category: "core")
        file.close()
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
