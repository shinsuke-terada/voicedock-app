// voicedock-reaper の走査と要求（T-37 §5.3。層 R1。ビルドした実行ファイルを起動して外から観測する）。
// 末尾の「ReaperLog の行」だけは行の書式の単体なので @testable import で直接呼ぶ（T-37 §4.6）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract

@testable import voicedock_reaper

@Suite("voicedock-reaper の走査と要求（層 R1）")
struct ReaperQueueTests {
    static let id = ReaperBench.requestID

    static func logged(_ bench: ReaperBench, _ tail: String) -> Bool {
        bench.logLines().contains { $0.hasSuffix(" " + tail) }
    }

    /// 外へ書かない: queue/ の下のファイルが delete/・result/・rejected/ の下だけ
    static func expectNothingOutsideQueueDirectories(_ bench: ReaperBench) {
        let files = bench.filesUnderQueue()
        #expect(
            files.allSatisfy { $0.hasPrefix("delete/") || $0.hasPrefix("result/") || $0.hasPrefix("rejected/") },
            "\(files)")
    }

    /// 手で組む要求の JSON（RV-02b・RV-03 の形を壊すため）。既定は通る要求と同じ中身
    static func json(
        _ bench: ReaperBench, schema: String = "1", requestID: String = "\"" + ReaperBench.requestID + "\"",
        size: String? = nil, mtime: String? = nil, targets: String? = nil, dropSessionKey: Bool = false,
        extra: Bool = false
    ) throws -> String {
        let actual = try bench.actualStat()
        let target =
            "{\"relpath\": \"" + ReaperBench.relpath + "\", \"size\": " + (size ?? String(actual.size))
            + ", \"mtime\": " + (mtime ?? String(actual.mtime)) + "}"
        var fields = [
            "\"schema\": " + schema,
            "\"request_id\": " + requestID,
            "\"created_at\": \"" + ReaperBench.createdAt + "\"",
            "\"device_id\": \"" + bench.deviceID + "\"",
            "\"partkey\": \"" + bench.partkey + "\"",
        ]
        if !dropSessionKey { fields.append("\"session_key\": \"" + ReaperBench.sessionKey + "\"") }
        fields.append("\"targets\": " + (targets ?? "[" + target + "]"))
        if extra { fields.append("\"extra\": 1") }
        return "{" + fields.joined(separator: ", ") + "}\n"
    }

    // MARK: - 層 R1 の正の対照

    @Test("ND-39 [R1] <VOLUMES_ROOT>/<device_id> がただのディレクトリなら not_a_mount_point")
    func nd39PlainDirectoryIsNotAMountPoint() throws {
        let bench = try ReaperBench()
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(bench.processedLines() == [Self.id])
        #expect(bench.results() == [Self.id + ".json"])
        let result = try bench.result(Self.id)
        #expect(result.status == .sourceIdentityMismatch)
        #expect(result.detail == "not_a_mount_point")
        #expect(result.partkey == ReaperBench.partkey)
        #expect(result.deviceID == "DJIMIC3")
        #expect(result.requestID == Self.id)
        #expect(result.reaperVersion == AppVersion.string)
        #expect(bench.requests() == [])
        #expect(bench.sourceExists())
        #expect(Self.logged(bench, "WARN  source_delete_rejected request_id=\(Self.id) reason=not_a_mount_point"))
    }

    // MARK: - RV-02（ファイル名と request_id）

    /// rejected/ へ退避した共通の期待
    static func expectRejected(_ bench: ReaperBench, _ run: ReaperRun, name: String) {
        #expect(run.exitCode == 0)
        #expect(bench.rejected() == [name])
        #expect(bench.requests() == [])
        #expect(bench.results() == [])
        #expect(bench.processedLines() == [])
        expectNothingOutsideQueueDirectories(bench)
        #expect(logged(bench, "WARN  request_rejected file=\(name) reason=malformed_request_id"))
        #expect(bench.sourceExists())
    }

    @Test(
        "ND-38 [R1] ファイル名が request_id の形でなければ rejected/ へ",
        arguments: [
            "evil.json", "20260912T090000Z-a5d046dce76cfedc-a1b2c3..json",
            "20260912T090000Z-a5d046dce76cfedc-A1B2C3.json",
            "20260912T090000Z-a5d046dce76cfedc-a1b2c3.JSON", "20260912T090000Z-a5d046dce76cfedc-a1b2c3.json.bak",
        ])
    func nd38BadFileNamesGoToRejected(_ name: String) throws {
        let bench = try ReaperBench()
        try bench.writeRequest(fileName: name)
        let run = try bench.run()
        Self.expectRejected(bench, run, name: name)
    }

    @Test("ND-38 [R1] JSON の request_id がファイル名と違えば rejected/ へ（RV-02b）")
    func nd38InnerRequestIDMismatchGoesToRejected() throws {
        let bench = try ReaperBench()
        let name = Self.id + ".json"
        try bench.writeRawRequest(fileName: name, Self.json(bench, requestID: "\"../evil\""))
        let run = try bench.run()
        Self.expectRejected(bench, run, name: name)
        let evil = bench.layout.root.appendingPathComponent("queue/evil.json")
        #expect(!FileManager.default.fileExists(atPath: evil.path(percentEncoded: false)))
    }

    @Test("RV-02b request_id が文字列でなければ rejected/ へ")
    func rv02bNonStringRequestIDGoesToRejected() throws {
        let bench = try ReaperBench()
        let name = Self.id + ".json"
        try bench.writeRawRequest(fileName: name, Self.json(bench, requestID: "1"))
        let run = try bench.run()
        Self.expectRejected(bench, run, name: name)
    }

    @Test(".json で終わらない名前は rejected/ へ")
    func nonJSONNamesGoToRejected() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: "README", "hello\n")
        let run = try bench.run()
        Self.expectRejected(bench, run, name: "README")
    }

    @Test(". で始まる名前は無視する")
    func dotFilesAreIgnored() throws {
        let bench = try ReaperBench()
        let name = ".20260912T090000Z-a5d046dce76cfedc-a1b2c3.json.tmp"
        try bench.writeRequest(fileName: name)
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(Self.logged(bench, "INFO  reaper_completed requests=0"))
        #expect(bench.requests() == [name])
        #expect(bench.rejected() == [])
        #expect(bench.results() == [])
    }

    // MARK: - RV-03（JSON の形）

    /// malformed_request の共通の期待: 結果 1 件・processed に 1 行・要求が消える・ファイルが在る・device_id と partkey が ""
    static func expectMalformed(_ bench: ReaperBench) throws {
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(bench.results() == [id + ".json"])
        let result = try bench.result(id)
        #expect(result.status == .sourceIdentityMismatch)
        #expect(result.detail == "malformed_request")
        #expect(result.deviceID == "")
        #expect(result.partkey == "")
        #expect(bench.processedLines() == [id])
        #expect(bench.requests() == [])
        #expect(bench.sourceExists())
        #expect(logged(bench, "WARN  source_delete_rejected request_id=\(id) reason=malformed_request"))
    }

    @Test("手書きの要求 JSON は壊さなければ not_a_mount_point まで進む（RV-03 の対照）")
    func handWrittenJSONPassesWhenIntact() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench))
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(try bench.result(Self.id).detail == "not_a_mount_point")
    }

    @Test("RV-03 余分なキーがあれば malformed_request")
    func rv03ExtraKeyIsMalformed() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench, extra: true))
        try Self.expectMalformed(bench)
    }

    @Test("RV-03 キーが欠けていれば malformed_request")
    func rv03MissingKeyIsMalformed() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench, dropSessionKey: true))
        try Self.expectMalformed(bench)
    }

    @Test("RV-03 schema が真偽値なら malformed_request")
    func rv03BoolSchemaIsMalformed() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench, schema: "true"))
        try Self.expectMalformed(bench)
    }

    @Test("RV-03 schema が小数の表記なら malformed_request")
    func rv03FloatSchemaIsMalformed() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench, schema: "1.0"))
        try Self.expectMalformed(bench)
    }

    @Test("RV-03 schema が 1 以外なら malformed_request")
    func rv03WrongSchemaIsMalformed() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench, schema: "2"))
        try Self.expectMalformed(bench)
    }

    @Test("RV-03 targets がちょうど 1 要素でなければ malformed_request", arguments: [0, 2])
    func rv03TargetCountIsMalformed(_ count: Int) throws {
        let bench = try ReaperBench()
        let actual = try bench.actualStat()
        let one =
            "{\"relpath\": \"" + ReaperBench.relpath + "\", \"size\": " + String(actual.size) + ", \"mtime\": "
            + String(actual.mtime) + "}"
        let targets = "[" + Array(repeating: one, count: count).joined(separator: ", ") + "]"
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench, targets: targets))
        try Self.expectMalformed(bench)
    }

    @Test("RV-03 size が負なら malformed_request")
    func rv03NegativeSizeIsMalformed() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench, size: "-1"))
        try Self.expectMalformed(bench)
    }

    @Test("RV-03 size が真偽値なら malformed_request")
    func rv03BoolSizeIsMalformed() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench, size: "true"))
        try Self.expectMalformed(bench)
    }

    @Test("RV-03 mtime が数でなければ malformed_request")
    func rv03StringMtimeIsMalformed() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench, mtime: "\"1\""))
        try Self.expectMalformed(bench)
    }

    @Test("RV-03 JSON オブジェクトでなければ malformed_request")
    func rv03NotAnObjectIsMalformed() throws {
        let bench = try ReaperBench()
        // ファイル名は正しい。RV-02b の peek も失敗する経路
        try bench.writeRawRequest(fileName: Self.id + ".json", "[]\n")
        try Self.expectMalformed(bench)
    }

    @Test("64 KiB を超える要求は malformed_request")
    func oversizedRequestIsMalformed() throws {
        let bench = try ReaperBench()
        try bench.writeRawRequest(fileName: Self.id + ".json", Self.json(bench) + String(repeating: " ", count: 65_536))
        try Self.expectMalformed(bench)
    }

    @Test("要求が symlink なら malformed_request")
    func symlinkedRequestIsMalformed() throws {
        let bench = try ReaperBench()
        let real = bench.tmp.url.appendingPathComponent("real-request.json")
        try Data(Self.json(bench).utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            atPath: bench.layout.queueDelete.appendingPathComponent(Self.id + ".json").path(percentEncoded: false),
            withDestinationPath: real.path(percentEncoded: false))
        try Self.expectMalformed(bench)
        #expect(FileManager.default.fileExists(atPath: real.path(percentEncoded: false)))
    }

    // MARK: - RV-04〜RV-06 とロック・走査

    @Test("ND-27 [R1] 同じ request_id の 2 回目は replayed")
    func nd27ReplayedRequestIsRefused() throws {
        let bench = try ReaperBench()
        try bench.writeRequest()
        _ = try bench.run()
        #expect(try bench.result(Self.id).detail == "not_a_mount_point")
        // アプリが 1 回目の結果を回収した（消した）後に、同じ ID の要求がもう一度置かれた
        try FileManager.default.removeItem(at: bench.layout.queueResult.appendingPathComponent(Self.id + ".json"))
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        let result = try bench.result(Self.id)
        #expect(result.status == .sourceIdentityMismatch)
        #expect(result.detail == "replayed")
        #expect(bench.processedLines() == [Self.id])
        #expect(bench.requests() == [])
        #expect(Self.logged(bench, "WARN  source_delete_rejected request_id=\(Self.id) reason=replayed"))
    }

    @Test("RV-04 replayed は既に在る結果を上書きしない")
    func replayedDoesNotOverwriteAnExistingResult() throws {
        let bench = try ReaperBench()
        try Data((Self.id + "\n").utf8).write(to: bench.layout.processedLog)
        let deleted = DeleteResult(
            requestID: Self.id, completedAt: "2026-09-12T18:00:05+09:00", reaperVersion: AppVersion.string,
            deviceID: "DJIMIC3", partkey: ReaperBench.partkey, status: .deleted, detail: ReaperBench.relpath)
        let resultURL = bench.layout.queueResult.appendingPathComponent(Self.id + ".json")
        let bytes = try ContractJSON.encode(deleted)
        try bytes.write(to: resultURL)
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(try Data(contentsOf: resultURL) == bytes)
        #expect(bench.requests() == [])
        #expect(bench.processedLines() == [Self.id])
        #expect(Self.logged(bench, "WARN  source_delete_rejected request_id=\(Self.id) reason=replayed"))
    }

    @Test("ND-44 [R1] device_id/relpath が partkey と違えば partkey_mismatch")
    func nd44PartkeyMismatchIsRefused() throws {
        let bench = try ReaperBench()
        try bench.writeRequest(partkey: "DJIMIC3/other.wav")
        _ = try bench.run()
        #expect(try bench.result(Self.id).detail == "partkey_mismatch")
        #expect(bench.requests() == [])
        #expect(bench.sourceExists())
    }

    @Test("ND-44 [R1] partkey の device_id だけが違えば partkey_mismatch")
    func nd44DeviceIDMismatchIsRefused() throws {
        let bench = try ReaperBench()
        try bench.writeRequest(partkey: "OTHER/" + ReaperBench.relpath)
        _ = try bench.run()
        #expect(try bench.result(Self.id).detail == "partkey_mismatch")
        #expect(bench.requests() == [])
        #expect(bench.sourceExists())
    }

    @Test("RV-06 デバイスが無ければ要求を残す")
    func rv06AbsentDeviceLeavesTheRequest() throws {
        let bench = try ReaperBench()
        let name = try bench.writeRequest(deviceID: "NOSUCH", partkey: "NOSUCH/" + ReaperBench.relpath)
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(bench.requests() == [name])
        #expect(bench.results() == [])
        #expect(bench.processedLines() == [])
        #expect(Self.logged(bench, "WARN  device_absent request_id=\(Self.id) device=NOSUCH"))
    }

    @Test("RV-06 device_id が不正なら not_a_mount_point", arguments: [".hidden", "a:b"])
    func rv06InvalidDeviceIDIsRejected(_ deviceID: String) throws {
        let bench = try ReaperBench()
        try bench.writeRequest(deviceID: deviceID, partkey: deviceID + "/" + ReaperBench.relpath)
        _ = try bench.run()
        #expect(try bench.result(Self.id).detail == "not_a_mount_point")
        #expect(bench.requests() == [])
    }

    @Test("要求は名前のバイト順に処理される")
    func namesAreProcessedInByteOrder() throws {
        let bench = try ReaperBench()
        let ids = [
            "20260912T090000Z-a5d046dce76cfedc-a00003", "20260912T090000Z-a5d046dce76cfedc-a00001",
            "20260912T090000Z-a5d046dce76cfedc-a00002",
        ]
        for id in ids { try bench.writeRequest(requestID: id) }
        _ = try bench.run()
        #expect(
            bench.processedLines() == [
                "20260912T090000Z-a5d046dce76cfedc-a00001", "20260912T090000Z-a5d046dce76cfedc-a00002",
                "20260912T090000Z-a5d046dce76cfedc-a00003",
            ])
        #expect(Self.logged(bench, "INFO  reaper_completed requests=3"))
    }

    /// ASCII の範囲では UTF-8 のバイト順と Swift の文字列の順が一致するので、正規化で順が入れ替わる名前で確かめる。
    /// U+212B（Å の記号。UTF-8 は E2 84 AB）は Swift の比較では NFC の U+00C5 として扱われ U+00D0（C3 90）より前になるが、
    /// バイト順では後。どちらも rejected/ へ退避されるので、ログの request_rejected の行の順が処理の順
    @Test("正規化で順が変わる名前もバイト順に処理される（rejected/ へ退避する名前）")
    func nonASCIINamesAreProcessedInByteOrder() throws {
        let bench = try ReaperBench()
        let sign = "\u{212B}.json"
        let eth = "\u{00D0}.json"
        try bench.writeRawRequest(fileName: sign, "{}\n")
        try bench.writeRawRequest(fileName: eth, "{}\n")
        _ = try bench.run()
        let rejectedLines = bench.logLines().filter { $0.contains(" request_rejected ") }
        #expect(rejectedLines.count == 2)
        #expect(rejectedLines.first?.contains("file=\"\u{00D0}.json\"") == true, "\(rejectedLines)")
        #expect(rejectedLines.last?.contains("file=\"\u{212B}.json\"") == true, "\(rejectedLines)")
    }

    @Test("RV-04 processed.log が読めなければ replayed（fail-closed）")
    func rv04UnreadableProcessedLogIsFailClosed() throws {
        let bench = try ReaperBench()
        try Data().write(to: bench.layout.processedLog)
        let path = bench.layout.processedLog.path(percentEncoded: false)
        #expect(chmod(path, 0o000) == 0)
        defer { _ = chmod(path, 0o644) }
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(try bench.result(Self.id).detail == "replayed")
        #expect(bench.requests() == [])
        #expect(bench.sourceExists())
    }

    @Test("要求が 0 件でも正常に終わる（TEST-28）")
    func anEmptyQueueCompletesWithZero() throws {
        let bench = try ReaperBench()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(Self.logged(bench, "INFO  reaper_completed requests=0"))
        #expect(bench.logLines().filter { $0.hasSuffix(" INFO  reaper_started") }.count == 1)
    }

    @Test("ロックが取れなければ何もせず 4")
    func aHeldLockStopsTheReaper() throws {
        let bench = try ReaperBench()
        let name = try bench.writeRequest()
        let lock = try #require(FileLock.tryAcquire(url: bench.layout.reaperLock))
        let run = try bench.run()
        withExtendedLifetime(lock) {}
        #expect(run.exitCode == 4)
        #expect(Self.logged(bench, "WARN  reaper_busy"))
        #expect(bench.requests() == [name])
        #expect(bench.results() == [])
        #expect(bench.rejected() == [])
        #expect(bench.processedLines() == [])
        #expect(bench.sourceExists())
    }

    @Test("実行が終わればロックは外れる（対照）")
    func theLockIsReleasedAfterTheRun() throws {
        let bench = try ReaperBench()
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(FileLock.tryAcquire(url: bench.layout.reaperLock) != nil)
    }

    @Test("ログは 5 MiB を超える書き込みの前に .1 へ回る")
    func theLogRotatesAtFiveMiB() throws {
        let bench = try ReaperBench()
        let padding = Data(repeating: 0x2E, count: 5 * 1024 * 1024)
        try padding.write(to: bench.layout.reaperLog)
        let run = try bench.run()
        #expect(run.exitCode == 0)
        let rotated = bench.layout.logsDirectory.appendingPathComponent("reaper.log.1")
        #expect(try Data(contentsOf: rotated) == padding)
        let lines = bench.logLines()
        #expect(lines.count == 2)
        #expect(lines.first?.hasSuffix(" INFO  reaper_started") == true)
        #expect(lines.last?.hasSuffix(" INFO  reaper_completed requests=0") == true)
    }

    @Test("SIGTERM は処理中の 1 件を終えてから止まる")
    func sigtermStopsBetweenRequests() throws {
        let bench = try ReaperBench()
        // 1 件あたりの照合を重くする詰め物
        let filler = (0..<50_000).map { String(format: "20260101T000000Z-0000000000000000-%06x", $0) }
        try Data((filler.joined(separator: "\n") + "\n").utf8).write(to: bench.layout.processedLog)
        var names: [String] = []
        for index in 0..<50 {
            let id = String(format: "20260912T090000Z-a5d046dce76cfedc-b%05d", index)
            names.append(try bench.writeRequest(requestID: id, partkey: "DJIMIC3/other.wav"))
        }
        let process = try bench.start()
        // 1 件目の結果が現れる（= ハンドラを入れた後に走査が始まった）まで待ってから送る
        var waited = 0
        while bench.results().isEmpty && waited < 10_000 {
            usleep(1_000)
            waited += 1
        }
        process.sendTermination()
        let run = process.wait()
        #expect(run.exitCode == 0)
        let results = Set(bench.results())
        let remaining = Set(bench.requests())
        // どの要求も中途半端でない: 結果が在るなら要求が消えている、結果が無いなら要求が残っている
        for name in names {
            #expect(results.contains(name) != remaining.contains(name), "\(name)")
        }
        #expect(!remaining.isEmpty)
        #expect(Self.logged(bench, "INFO  reaper_completed requests=\(results.count)"))
    }
}

@Suite("ReaperLog の行")
struct ReaperLogLineTests {
    static let ts = "2026-09-12T18:00:05+09:00"

    @Test("INFO は 5 桁左寄せ（INFO と 2 つの空白の後に event）")
    func infoIsPaddedToFive() {
        #expect(
            ReaperLog.format(ts: Self.ts, level: .info, event: "reaper_started", fields: [])
                == "2026-09-12T18:00:05+09:00 INFO  reaper_started")
    }

    @Test("フィールドは順に k=v で足される")
    func fieldsAreAppendedInOrder() {
        #expect(
            ReaperLog.format(
                ts: Self.ts, level: .warn, event: "device_absent", fields: [("request_id", "X1"), ("device", "NOSUCH")])
                == "2026-09-12T18:00:05+09:00 WARN  device_absent request_id=X1 device=NOSUCH")
    }

    @Test(
        "値は §8.15 のとおりに引用される",
        arguments: [
            ("DJIMIC3/TX_MIC001/a_orig.wav", "DJIMIC3/TX_MIC001/a_orig.wav"),
            ("a b", "\"a b\""),
            ("a=b", "\"a=b\""),
            ("", "\"\""),
            ("a\"b", "\"a\\\"b\""),
            ("a\nb", "\"a\\nb\""),
            ("a\\b c", "\"a\\\\b c\""),
            ("録音", "\"録音\""),
            ("\u{01}\u{7F}\t\r\u{08}\u{0C}", "\"\\u0001\\u007f\\t\\r\\b\\f\""),
        ])
    func valuesAreQuoted(_ input: String, _ expected: String) {
        #expect(ReaperLog.value(input) == expected)
    }
}
