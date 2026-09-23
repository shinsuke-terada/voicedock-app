// 前回の whisper.json の残り（F-76・issue #116。RK-34）。偽 whisper-cli を本物の ProcessRunner で起動する。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDTranscribe

@Suite("Transcriber（前回の whisper.json）", .serialized)
struct TranscriberStaleJSONTests {
    typealias Fixture = TranscriberTests.Fixture

    static let rawJSONRelative = "staging/\(TranscriberTests.slug)/whisper.json"

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test("F-76 前回の whisper.json が残っていても、終了 0 で JSON を書かなければ WHISPER_FAILED（RK-34）")
    func staleJSONIsNotReadAsSuccess() async throws {
        let f = try Fixture()
        // 前回（落ちた実行）の残り。読めば成功に見える中身
        try Data(FakeWhisper.rawDocument().utf8).write(to: f.whisperJSON)
        try FakeWhisper.write(to: f.script, output: .none)
        let outcome = await f.run()
        #expect(outcome == .failure(StageFailure(.whisperFailed, "生 JSON を読めません: \(Self.rawJSONRelative)")))
        // whisper は起動した（前回の JSON を消してから起動した）
        #expect(!FakeWhisper.recordedArgv(f.script).isEmpty)
        #expect(!Self.exists(f.transcript))
        #expect(!Self.exists(f.whisperJSON))
    }

    @Test("F-76 前回の whisper.json を消せなければ whisper を起動しない")
    func unremovableStaleJSONStopsBeforeLaunch() async throws {
        let f = try Fixture()
        // 通常ファイルでないものは SafeUnlink が消さない（notRegularFile）
        try FileManager.default.createDirectory(at: f.whisperJSON, withIntermediateDirectories: false)
        try FakeWhisper.write(to: f.script)
        let outcome = await f.run()
        #expect(
            outcome == .failure(StageFailure(.whisperFailed, "前回の生 JSON を消せません: \(Self.rawJSONRelative)")))
        #expect(FakeWhisper.recordedArgv(f.script).isEmpty)
        #expect(!Self.exists(f.transcript))
    }
}
