// processed.log に結果も残し、unlink の後に結果を書けなかった要求を RV-04 で DELETED として書き直す（PLAN §8.9.4・付録 B.2。F-80・issue #119 の A5）。
// ProcessedLog の読み書きは @testable import で直接、RV-04 の書き直しはビルドした実行ファイルを起動して外から観測する（層 R1。デバイスには触れない）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract

@testable import voicedock_reaper

@Suite("ProcessedLog")
struct ProcessedLogTests {
    static let id = ReaperBench.requestID
    static let otherID = "20260912T090001Z-a5d046dce76cfedc-a1b2c4"

    static func logged(_ bench: ReaperBench, _ tail: String) -> Bool {
        bench.logLines().contains { $0.hasSuffix(" " + tail) }
    }

    static func write(_ lines: [String], to url: URL) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }

    // MARK: - 行の読み書き

    @Test(
        "F-80 processed.log の行を読む（パラメータ化: ID だけ・<ID> DELETED・<ID> SOURCE_IDENTITY_MISMATCH・区切りが 2 つ・DELETED の小文字）",
        arguments: [
            ("A", true, false), ("A DELETED", true, true), ("A SOURCE_IDENTITY_MISMATCH", true, false),
            ("A DELETED x", true, false), ("A deleted", true, false),
        ])
    func linesAreParsed(_ line: String, _ processed: Bool, _ deleted: Bool) throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("processed.log")
        let full = line.replacingOccurrences(of: "A", with: Self.id)
        try Self.write([full], to: url)
        let log = ProcessedLog(url: url)
        #expect(log.contains(Self.id) == processed)
        #expect(log.recordedDeleted(Self.id) == deleted)
        // 前方一致で拾わない（別の ID は処理済みでない）
        #expect(!log.contains(Self.otherID))
        #expect(!log.recordedDeleted(Self.otherID))
    }

    @Test("F-80 append(deleted: true) は <request_id> DELETED を書き、同じ実行の中でも DELETED と分かる（拒否は ID だけ）")
    func appendWritesTheResultWord() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("processed.log")
        var log = ProcessedLog(url: url)
        let deletedAppended = log.append(Self.id, deleted: true)
        let refusedAppended = log.append(Self.otherID)
        #expect(deletedAppended)
        #expect(refusedAppended)
        #expect(log.contains(Self.id))
        #expect(log.recordedDeleted(Self.id))
        #expect(log.contains(Self.otherID))
        #expect(!log.recordedDeleted(Self.otherID))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == Self.id + " DELETED\n" + Self.otherID + "\n")
        // 読み直しても同じ
        let reread = ProcessedLog(url: url)
        #expect(reread.recordedDeleted(Self.id))
        #expect(!reread.recordedDeleted(Self.otherID))
    }

    @Test("F-80 processed.log が読めなければ、どの ID も DELETED として扱わない（fail-closed は replayed のまま）")
    func unreadableLogIsNeverDeleted() throws {
        let tmp = try TempDirectory()
        // ディレクトリは通常ファイルでないので読めない
        let url = tmp.url.appendingPathComponent("processed.log", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let log = ProcessedLog(url: url)
        #expect(log.contains(Self.id))
        #expect(!log.recordedDeleted(Self.id))
    }

    @Test("F-80 TEST-28 processed.log が無い・空なら、どの ID も処理済みでも DELETED でもない")
    func emptyLogKnowsNothing() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("processed.log")
        let missing = ProcessedLog(url: url)
        #expect(!missing.contains(Self.id))
        #expect(!missing.recordedDeleted(Self.id))
        try Data().write(to: url)
        let empty = ProcessedLog(url: url)
        #expect(!empty.contains(Self.id))
        #expect(!empty.recordedDeleted(Self.id))
        #expect(!empty.contains(""))
    }

    // MARK: - RV-04 の書き直し（層 R1）

    @Test("F-80 RV-04 前回 DELETED と記録した要求が残っていれば、結果 DELETED（detail = relpath）を書き直して要求を消す（消し直さない・拒否のログを出さない）")
    func rv04RedeliversTheDeletedResult() throws {
        let bench = try ReaperBench()
        try Self.write([Self.id + " DELETED"], to: bench.layout.processedLog)
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        let result = try bench.result(Self.id)
        #expect(result.status == .deleted)
        #expect(result.detail == "TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav")
        #expect(result.partkey == "VDT0037/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav")
        #expect(result.deviceID == "VDT0037")
        #expect(bench.requests() == [])
        // processed.log には再追記しない
        #expect(bench.processedLines() == [Self.id + " DELETED"])
        // デバイスには触れない（置いた原本はそのまま）
        #expect(bench.sourceExists())
        #expect(!bench.logLines().contains { $0.contains(" source_delete_rejected ") })
        #expect(!bench.logLines().contains { $0.contains(" source_deleted ") })
        #expect(Self.logged(bench, "INFO  reaper_completed requests=1"))
    }

    @Test(
        "F-80 RV-04 DELETED と記録していない行（ID だけ・MISMATCH）は従来どおり replayed（パラメータ化）",
        arguments: ["", " SOURCE_IDENTITY_MISMATCH"])
    func rv04OtherLinesStayReplayed(_ suffix: String) throws {
        let bench = try ReaperBench()
        try Self.write([Self.id + suffix], to: bench.layout.processedLog)
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        let result = try bench.result(Self.id)
        #expect(result.status == .sourceIdentityMismatch)
        #expect(result.detail == "replayed")
        #expect(bench.requests() == [])
        #expect(Self.logged(bench, "WARN  source_delete_rejected request_id=\(Self.id) reason=replayed"))
    }

    @Test("F-80 RV-04 DELETED を書き直せなければ要求を残して次へ（結果も processed.log の追記もログも無い・消し直さない）")
    func rv04RedeliveryKeepsTheRequestWhenTheResultCannotBeWritten() throws {
        let bench = try ReaperBench()
        try Self.write([Self.id + " DELETED"], to: bench.layout.processedLog)
        let name = try bench.writeRequest()
        let resultDir = bench.layout.queueResult.path(percentEncoded: false)
        #expect(chmod(resultDir, 0o555) == 0)
        defer { _ = chmod(resultDir, 0o755) }
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(bench.requests() == [name])
        #expect(bench.results() == [])
        #expect(bench.processedLines() == [Self.id + " DELETED"])
        #expect(
            !bench.logLines().contains { $0.contains(" source_delete_rejected ") || $0.contains(" source_deleted ") })
        #expect(bench.logLines().last?.hasSuffix(" INFO  reaper_completed requests=1") == true)
        #expect(bench.sourceExists())
    }

    @Test("F-80 RV-04 DELETED の書き直しでも、同じ名前の結果が既に在れば上書きしない（要求だけ消す）")
    func rv04RedeliveryDoesNotOverwrite() throws {
        let bench = try ReaperBench()
        try Self.write([Self.id + " DELETED"], to: bench.layout.processedLog)
        let existing = DeleteResult(
            requestID: Self.id, completedAt: "2026-09-12T18:00:05+09:00", reaperVersion: AppVersion.string,
            deviceID: "VDT0037", partkey: ReaperBench.partkey, status: .deleted, detail: ReaperBench.relpath)
        let resultURL = bench.layout.queueResult.appendingPathComponent(Self.id + ".json")
        let bytes = try ContractJSON.encode(existing)
        try bytes.write(to: resultURL)
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(try Data(contentsOf: resultURL) == bytes)
        #expect(bench.requests() == [])
    }
}
