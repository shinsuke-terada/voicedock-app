// LockEvaluator（三重ロックの評価と署名・版のキャッシュ）のテスト（PLAN §8.9.2・§8.9.3。T-36 §6.4）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDProcess

@testable import VDPipeline

@Suite("LockEvaluator")
struct LockEvaluatorTests {
    /// 準備（makeEvaluator）の組
    struct Fixture {
        let tmp: TempDirectory
        let layout: HomeLayout
        let config: AppConfig
        let verifier: FakeSignatureVerifier
        let runner: ScriptedProcessRunner
        let sink: CapturingLogSink
        let evaluator: LockEvaluator

        func config(_ mutate: (inout AppConfig) -> Void) -> AppConfig {
            var c = config
            mutate(&c)
            return c
        }

        func removeReaper() throws {
            try FileManager.default.removeItem(at: layout.reaperExecutable)
        }

        func installReaper() throws {
            try LockEvaluatorTests.writeStub(layout.reaperExecutable)
        }

        func writeReaperConf(_ text: String) throws {
            try Data(text.utf8).write(to: layout.reaperConf)
        }

        func reaperFailedLines(_ reason: String) -> [String] {
            sink.lines.filter { $0.contains(" reaper_failed ") && $0.hasSuffix(" reason=" + reason) }
        }
    }

    static let stub = "#!/bin/sh\nexit 0\n"

    static func writeStub(_ url: URL) throws {
        try Data(stub.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    static func makeEvaluator(
        results: [ProcessResult] = [ScriptedProcessRunner.version()], signatureValid: Bool = true
    ) throws -> Fixture {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        try FileManager.default.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
        try writeStub(layout.reaperExecutable)
        try ReaperConf(deleteSourceAudio: true, volumesRoot: "/tmp/vd-volumes").render().write(to: layout.reaperConf)
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.cleanup.deleteSourceAudio = true
        config.device.mountMode = "rw"
        let verifier = FakeSignatureVerifier(valid: signatureValid)
        let runner = ScriptedProcessRunner(results: results)
        let sink = CapturingLogSink()
        let clock = FixedClock(epochMillis: 1_788_040_812_000)
        let log = AppLog(
            sink: sink, level: .debug, unsafeContent: false, zone: ZonedTime(fixedOffsetSeconds: 9 * 3600),
            clock: clock)
        let evaluator = LockEvaluator(layout: layout, verifier: verifier, runner: runner, log: log)
        return Fixture(
            tmp: tmp, layout: layout, config: config, verifier: verifier, runner: runner, sink: sink,
            evaluator: evaluator)
    }

    static func snapshot(_ devices: [String: Bool?]) -> DeviceSnapshot {
        var observed: [String: DeviceObservation] = [:]
        for (id, readOnly) in devices {
            observed[id] = DeviceObservation(
                deviceID: id, mountPath: "/tmp/vd-volumes/" + id, deviceNode: nil, readOnly: readOnly, freeBytes: nil,
                relpaths: [])
        }
        return DeviceSnapshot(
            generation: 1, completedAt: Instant(epochMillis: 1_788_040_812_000), connectEpoch: 1, devices: observed,
            unavailable: [:], notListableErrno: [:])
    }

    @Test("全部そろえば configured")
    func configuredWhenEverythingIsReleased() async throws {
        let f = try Self.makeEvaluator()
        #expect(await f.evaluator.readiness(config: f.config) == .configured)
    }

    @Test("readiness の判定順と理由語（パラメータ化）", arguments: ["a", "b", "c", "d", "e", "f", "g", "h"])
    func readinessOrderAndWords(_ label: String) async throws {
        let f: Fixture
        let config: AppConfig
        let want: String
        switch label {
        case "a":
            f = try Self.makeEvaluator()
            config = f.config { $0.cleanup.deleteSourceAudio = false }
            try f.removeReaper()
            want = "delete_source_audio_disabled"
        case "b":
            f = try Self.makeEvaluator()
            config = f.config { $0.device.mountMode = "ro" }
            try f.writeReaperConf("SCHEMA=1\nDELETE_SOURCE_AUDIO=false\nVOLUMES_ROOT=/tmp/vd-volumes\n")
            want = "lock_mismatch"
        case "c":
            f = try Self.makeEvaluator()
            config = f.config { $0.device.mountMode = "ro" }
            try f.removeReaper()
            want = "mount_mode_ro"
        case "d":
            f = try Self.makeEvaluator()
            config = f.config
            try f.removeReaper()
            want = "reaper_not_installed"
        case "e":
            f = try Self.makeEvaluator(signatureValid: false)
            config = f.config
            want = "reaper_invalid"
        case "f":
            f = try Self.makeEvaluator(results: [ScriptedProcessRunner.version("0.9.0\n")])
            config = f.config
            want = "reaper_invalid"
        case "g":
            f = try Self.makeEvaluator(results: [ScriptedProcessRunner.exited(1)])
            config = f.config
            want = "reaper_invalid"
        default:
            f = try Self.makeEvaluator(
                results: [ProcessResult(termination: .timedOut, stdoutTail: Data(), stderrTail: Data())])
            config = f.config
            want = "reaper_invalid"
        }
        #expect(await f.evaluator.readiness(config: config) == .disabled(want))
    }

    @Test("reaper.conf が無い・不正は lock_mismatch（パラメータ化）", arguments: ["無い", "SCHEMA 欠落"])
    func reaperConfUnknownIsMismatch(_ kind: String) async throws {
        let f = try Self.makeEvaluator()
        if kind == "無い" {
            try FileManager.default.removeItem(at: f.layout.reaperConf)
        } else {
            try f.writeReaperConf("DELETE_SOURCE_AUDIO=true\n")
        }
        #expect(await f.evaluator.readiness(config: f.config) == .disabled("lock_mismatch"))
    }

    @Test("通常ファイルでない reaper は未導入（パラメータ化）", arguments: ["ディレクトリ", "symlink"])
    func reaperDirectoryOrSymlinkIsNotInstalled(_ kind: String) async throws {
        let f = try Self.makeEvaluator()
        try f.removeReaper()
        if kind == "ディレクトリ" {
            try FileManager.default.createDirectory(at: f.layout.reaperExecutable, withIntermediateDirectories: false)
        } else {
            let other = f.tmp.url.appendingPathComponent("other-reaper", isDirectory: false)
            try Self.writeStub(other)
            try FileManager.default.createSymbolicLink(
                atPath: f.layout.reaperExecutable.path(percentEncoded: false),
                withDestinationPath: other.path(percentEncoded: false))
        }
        #expect(await f.evaluator.readiness(config: f.config) == .disabled("reaper_not_installed"))
        #expect(f.verifier.verifiedURLs == [])
    }

    @Test("設定で決まれば署名も版も見ない")
    func disabledConfigDoesNotSpawn() async throws {
        let f = try Self.makeEvaluator()
        _ = await f.evaluator.readiness(config: f.config { $0.cleanup.deleteSourceAudio = false })
        #expect(f.verifier.verifiedURLs == [])
        #expect(await f.runner.recorded == [])
    }

    @Test("版は署名の後。署名 NG なら実行しない")
    func versionRunsAfterSignature() async throws {
        let f = try Self.makeEvaluator(signatureValid: false)
        _ = await f.evaluator.readiness(config: f.config)
        #expect(await f.runner.recorded == [])
        #expect(f.verifier.verifiedURLs == [f.layout.reaperExecutable])
    }

    @Test("--version の argv・環境・時間の上限")
    func versionArgvIsExact() async throws {
        let f = try Self.makeEvaluator()
        _ = await f.evaluator.readiness(config: f.config)
        let recorded = await f.runner.recorded
        let timeouts = await f.runner.recordedTimeouts
        try #require(recorded.count == 1)
        #expect(recorded[0].executable == f.layout.reaperExecutable)
        #expect(recorded[0].arguments == ["--version"])
        #expect(recorded[0].environment == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"])
        #expect(timeouts[0] == .seconds(10))
    }

    @Test("(inode, size, mtime) が同じならキャッシュを使う")
    func verificationIsCached() async throws {
        let f = try Self.makeEvaluator()
        for _ in 0..<3 {
            #expect(await f.evaluator.readiness(config: f.config) == .configured)
        }
        #expect(f.verifier.verifiedURLs.count == 1)
        #expect(await f.runner.recorded.count == 1)
    }

    @Test("useCache: false は必ず検証し直す")
    func useCacheFalseVerifiesAgain() async throws {
        let f = try Self.makeEvaluator()
        _ = await f.evaluator.readiness(config: f.config)
        _ = await f.evaluator.readiness(config: f.config, useCache: false)
        #expect(f.verifier.verifiedURLs.count == 2)
        #expect(await f.runner.recorded.count == 2)
    }

    @Test("ファイルが変われば検証し直す（パラメータ化: mtime・size・置き換え（新しい inode））", arguments: ["mtime", "size", "置き換え"])
    func changedFileInvalidatesCache(_ change: String) async throws {
        let f = try Self.makeEvaluator()
        _ = await f.evaluator.readiness(config: f.config)
        let path = f.layout.reaperExecutable.path(percentEncoded: false)
        switch change {
        case "mtime":
            var st = stat()
            #expect(lstat(path, &st) == 0)
            let seconds = Int(st.st_mtimespec.tv_sec) + 10
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            #expect(utimes(path, &times) == 0)
        case "size":
            var data = try Data(contentsOf: f.layout.reaperExecutable)
            data.append(0x0A)
            try data.write(to: f.layout.reaperExecutable)
        default:
            let other = f.layout.binDirectory.appendingPathComponent("replacement", isDirectory: false)
            try Self.writeStub(other)
            #expect(rename(other.path(percentEncoded: false), path) == 0)
        }
        _ = await f.evaluator.readiness(config: f.config)
        #expect(f.verifier.verifiedURLs.count == 2)
        #expect(await f.runner.recorded.count == 2)
    }

    @Test("失敗もキャッシュし、ログは検証したときだけ")
    func cacheKeepsTheFailure() async throws {
        let f = try Self.makeEvaluator(signatureValid: false)
        for _ in 0..<3 {
            _ = await f.evaluator.readiness(config: f.config)
        }
        #expect(f.reaperFailedLines("signature").count == 1)
        #expect(f.verifier.verifiedURLs.count == 1)
    }

    @Test("版の不一致をログに出す")
    func versionMismatchIsLogged() async throws {
        let f = try Self.makeEvaluator(results: [ScriptedProcessRunner.version("0.9.0\n")])
        _ = await f.evaluator.readiness(config: f.config)
        #expect(f.reaperFailedLines("version_mismatch").count == 1)
        #expect(await f.evaluator.reaperStatus() == .versionMismatch(found: "0.9.0"))
    }

    @Test("消えたら未導入に戻り、置き直せば検証し直す")
    func removedReaperClearsCache() async throws {
        let f = try Self.makeEvaluator()
        #expect(await f.evaluator.readiness(config: f.config) == .configured)
        try f.removeReaper()
        #expect(await f.evaluator.readiness(config: f.config) == .disabled("reaper_not_installed"))
        try f.installReaper()
        #expect(await f.evaluator.readiness(config: f.config) == .configured)
        #expect(f.verifier.verifiedURLs.count == 2)
    }

    @Test(
        "観測の 4 値（パラメータ化）",
        arguments: [
            ("snapshot nil", DeviceWritability.absent), ("デバイス無し", .absent), ("readOnly false", .writable),
            ("readOnly true", .readOnly), ("readOnly nil", .unknown),
        ])
    func writabilityObservesSnapshot(_ label: String, _ want: DeviceWritability) async throws {
        let f = try Self.makeEvaluator()
        let snapshot: DeviceSnapshot?
        switch label {
        case "snapshot nil": snapshot = nil
        case "デバイス無し": snapshot = Self.snapshot([:])
        case "readOnly false": snapshot = Self.snapshot(["DJIMIC3": false])
        case "readOnly true": snapshot = Self.snapshot(["DJIMIC3": true])
        default: snapshot = Self.snapshot(["DJIMIC3": Bool?.none])
        }
        #expect(await f.evaluator.writability(deviceID: "DJIMIC3", snapshot: snapshot) == want)
    }

    @Test("設定値 mountMode を観測に使わない")
    func writabilityIgnoresMountModeSetting() async throws {
        let f = try Self.makeEvaluator()
        let config = f.config { $0.device.mountMode = "ro" }
        let snapshot = Self.snapshot(["DJIMIC3": false])
        #expect(await f.evaluator.writability(deviceID: "DJIMIC3", snapshot: snapshot) == .writable)
        #expect(await f.evaluator.readiness(config: config) == .disabled("mount_mode_ro"))
    }

    @Test(
        "allReleased は準備と観測の両方（パラメータ化）",
        arguments: [
            ("configured", "writable", true), ("configured", "unknown", false), ("configured", "readOnly", false),
            ("disabled", "writable", false), ("configured", "absent", false),
        ])
    func allReleasedNeedsBoth(_ readiness: String, _ observed: String, _ want: Bool) async throws {
        let f = try Self.makeEvaluator()
        let config = f.config { $0.cleanup.deleteSourceAudio = readiness == "configured" }
        let snapshot: DeviceSnapshot
        switch observed {
        case "writable": snapshot = Self.snapshot(["DJIMIC3": false])
        case "unknown": snapshot = Self.snapshot(["DJIMIC3": Bool?.none])
        case "readOnly": snapshot = Self.snapshot(["DJIMIC3": true])
        default: snapshot = Self.snapshot([:])
        }
        #expect(await f.evaluator.allReleased(deviceID: "DJIMIC3", config: config, snapshot: snapshot) == want)
    }

    @Test("observe は reaper.conf の VOLUMES_ROOT を運ぶ", arguments: ["既定", "reaper.conf 無し"])
    func observeCarriesVolumesRoot(_ kind: String) async throws {
        let f = try Self.makeEvaluator()
        if kind == "reaper.conf 無し" {
            try FileManager.default.removeItem(at: f.layout.reaperConf)
        }
        let o = await f.evaluator.observe(config: f.config, snapshot: nil)
        #expect(o.volumesRoot == (kind == "既定" ? "/tmp/vd-volumes" : nil))
    }

    @Test("observeReaperConf は bin/reaper.conf を読む")
    func observeReaperConfReadsTheFile() async throws {
        let f = try Self.makeEvaluator()
        #expect(
            await f.evaluator.observeReaperConf()
                == .valid(ReaperConf(deleteSourceAudio: true, volumesRoot: "/tmp/vd-volumes")))
    }
}
