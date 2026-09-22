// ConfigStore のテスト（T-18 §6.1。PLAN §6.1）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("ConfigStore")
struct ConfigStoreTests {
    /// 一時ディレクトリの HOME と ConfigStore。
    struct Scene {
        let tmp: TempDirectory
        let layout: HomeLayout
        let sink: CapturingLogSink
        let log: AppLog

        init() throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            sink = CapturingLogSink()
            let clock = FixedClock(epochMillis: 1_788_040_812_000)
            log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: PipelineFixtures.zone, clock: clock)
        }

        func store(_ observe: @escaping @Sendable () async -> ReaperConfObservation = { .missing }) -> ConfigStore {
            ConfigStore(
                layout: layout, catalog: TestCatalogs.minimal, log: log, observeReaperConf: observe,
                defaultTimeZone: { "Asia/Tokyo" })
        }

        func write(_ config: AppConfig) throws {
            try AtomicFile.write(ConfigLoader.encode(config), to: layout.configFile)
        }

        func writeText(_ text: String) throws {
            try Data(text.utf8).write(to: layout.configFile)
        }

        func fileBytes() throws -> [UInt8] { Array(try Data(contentsOf: layout.configFile)) }

        func fileConfig() throws -> AppConfig {
            try JSONDecoder().decode(AppConfig.self, from: try Data(contentsOf: layout.configFile))
        }

        func lines(_ event: String) -> [String] { sink.lines.filter { $0.contains(" " + event + " ") } }
    }

    static func rules(_ result: ConfigLoadResult) -> [String] {
        if case .invalid(let v) = result { return v.map(\.rule) }
        return []
    }

    static func isValid(_ result: ConfigLoadResult) -> Bool {
        if case .valid = result { return true }
        return false
    }

    static func failureRules(_ result: ConfigUpdateResult) -> [String]? {
        if case .failure(let v) = result { return v.map(\.rule) }
        return nil
    }

    static let deleteOn = ReaperConfObservation.valid(ReaperConf(deleteSourceAudio: true))
    static let deleteOff = ReaperConfObservation.valid(ReaperConf(deleteSourceAudio: false))

    @Test("無ければ既定を書く")
    func writesDefaultsWhenAbsent() async throws {
        let s = try Scene()
        let store = s.store()
        let result = await store.load()
        #expect(Self.isValid(result))
        #expect(try s.fileBytes() == Array(ConfigLoader.encode(AppConfig.defaults(timeZone: "Asia/Tokyo"))))
        #expect(await store.didCreateDefaults() == true)
    }

    @Test("在るが不正なら上書きしない")
    func doesNotOverwriteInvalidFile() async throws {
        let s = try Scene()
        try s.writeText("{")
        let store = s.store()
        let result = await store.load()
        #expect(Self.rules(result) == ["CV-39"])
        #expect(try s.fileBytes() == Array("{".utf8))
        #expect(await store.current() == nil)
        #expect(await store.didCreateDefaults() == false)
        #expect(s.lines("config_invalid").contains { $0.contains("ERROR config_invalid rule=CV-39 key=<file>") })
    }

    @Test("壊れた symlink は「無い」ではない")
    func danglingSymlinkIsNotAbsent() async throws {
        let s = try Scene()
        try FileManager.default.createSymbolicLink(
            atPath: s.layout.configFile.path(percentEncoded: false),
            withDestinationPath: s.tmp.url.appendingPathComponent("nowhere.json").path(percentEncoded: false))
        let result = await s.store().load()
        #expect(!Self.isValid(result))
        let type =
            try FileManager.default.attributesOfItem(atPath: s.layout.configFile.path(percentEncoded: false))[
                .type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
    }

    @Test("空のファイルは不正（既定で埋めない）")
    func emptyFileIsInvalid() async throws {
        let s = try Scene()
        try s.writeText("")
        let result = await s.store().load()
        #expect(Self.rules(result) == ["CV-39"])
        #expect(try s.fileBytes() == [])
    }

    @Test("正しい設定を読む")
    func validFileLoads() async throws {
        let s = try Scene()
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.vault.path = "/tmp/v"
        try s.write(config)
        let store = s.store()
        _ = await store.load()
        #expect(await store.current()?.vault.path == "/tmp/v")
        #expect(await store.violations() == [])
    }

    @Test("違反を 1 件ずつ ERROR で出す")
    func logsEveryViolation() async throws {
        let s = try Scene()
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.session.maxParts = 0
        config.llm.topP = 0
        try s.write(config)
        _ = await s.store().load()
        let lines = s.lines("config_invalid")
        #expect(lines.count == 2)
        #expect(lines.count == 2 && lines[0].contains("rule=CV-56") && lines[1].contains("rule=CV-57"))
    }

    @Test("update は書く前に検証する")
    func updateValidatesBeforeWriting() async throws {
        let s = try Scene()
        let store = s.store()
        _ = await store.load()
        let before = try s.fileBytes()
        let result = await store.update { $0.session.maxParts = 0 }
        #expect(Self.failureRules(result) == ["CV-57"])
        #expect(try s.fileBytes() == before)
        #expect(await store.current()?.session.maxParts == 64)
    }

    @Test("update は検証を通れば書く")
    func updateWrites() async throws {
        let s = try Scene()
        let store = s.store()
        _ = await store.load()
        let result = await store.update { $0.vault.path = "/tmp/w" }
        #expect(Self.failureRules(result) == nil)
        #expect(try s.fileConfig().vault.path == "/tmp/w")
        #expect(await store.current()?.vault.path == "/tmp/w")
    }

    @Test("update は渡された reaper.conf の観測で検証する")
    func updateUsesGivenObservation() async throws {
        let s = try Scene()
        let store = s.store()
        _ = await store.load()
        let result = await store.update({ $0.vault.path = "/tmp/w" }, reaperConfObservation: Self.deleteOn)
        #expect(Self.failureRules(result)?.contains("CV-30") == true)
    }

    @Test("設定エラー中の update は書かない")
    func updateWhileInvalidFails() async throws {
        let s = try Scene()
        try s.writeText("{")
        let store = s.store()
        _ = await store.load()
        let result = await store.update { $0.vault.path = "/tmp/w" }
        #expect(Self.failureRules(result) != nil)
        #expect(try s.fileBytes() == Array("{".utf8))
    }

    @Test("CV-30 は修復口が無ければ設定エラー")
    func cv30WithoutReconcilerIsInvalid() async throws {
        let s = try Scene()
        try s.write(AppConfig.defaults(timeZone: "Asia/Tokyo"))
        let result = await s.store({ ConfigStoreTests.deleteOn }).load()
        #expect(Self.rules(result).contains("CV-30"))
    }

    @Test("CV-30 は両方を無効側に揃えて読み直す")
    func cv30IsReconciled() async throws {
        let s = try Scene()
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.cleanup.deleteSourceAudio = true
        config.device.mountMode = "rw"
        try s.write(config)
        // 有効化・無効化の途中で落ちた片方だけの状態: reaper.conf は無効（修復の前も後も）、config は有効。
        let reconciled = Mutex<Int>(0)
        let store = s.store { ConfigStoreTests.deleteOff }
        await store.setLock1Reconciler {
            reconciled.withLock { $0 += 1 }
            return true
        }
        let result = await store.load()
        #expect(reconciled.withLock { $0 } == 1)
        #expect(Self.isValid(result))
        let written = try s.fileConfig()
        #expect(written.cleanup.deleteSourceAudio == false)
        #expect(written.cleanup.deleteSkippedSource == false)
        #expect(written.device.mountMode == "ro")
        #expect(s.lines("config_warning").contains { $0.contains("WARNING config_warning rule=CV-30") })
    }

    @Test("修復口が偽なら設定エラー")
    func cv30ReconcileFailureStaysInvalid() async throws {
        let s = try Scene()
        try s.write(AppConfig.defaults(timeZone: "Asia/Tokyo"))
        let before = try s.fileBytes()
        let store = s.store { ConfigStoreTests.deleteOn }
        await store.setLock1Reconciler { false }
        let result = await store.load()
        #expect(Self.rules(result).contains("CV-30"))
        #expect(try s.fileBytes() == before)
    }

    @Test("修復は 1 回だけ")
    func cv30IsReconciledOnlyOnce() async throws {
        let s = try Scene()
        try s.write(AppConfig.defaults(timeZone: "Asia/Tokyo"))
        let calls = Mutex<Int>(0)
        let store = s.store { ConfigStoreTests.deleteOn }
        await store.setLock1Reconciler {
            calls.withLock { $0 += 1 }
            return true
        }
        let result = await store.load()
        #expect(calls.withLock { $0 } == 1)
        #expect(Self.rules(result).contains("CV-30"))
    }

    /// 観測の口を止めておく門。armed の間、2 つの呼び手が揃うまで待たせる。
    actor ObservationGate {
        private var armed = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func arm() { armed = true }

        func pass() async {
            guard armed else { return }
            if waiting.count + 1 >= 2 {
                armed = false
                for continuation in waiting { continuation.resume() }
                waiting = []
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    @Test("並行した 2 つの update の変更が両方残る（actor の再入）")
    func concurrentUpdatesKeepBothChanges() async throws {
        let s = try Scene()
        let gate = ObservationGate()
        let store = s.store {
            await gate.pass()
            return .missing
        }
        _ = await store.load()
        await gate.arm()
        async let first = store.update { $0.vault.path = "/tmp/a" }
        async let second = store.update { $0.session.maxParts = 10 }
        let results = await [first, second]
        #expect(results.allSatisfy { Self.failureRules($0) == nil })
        #expect(await store.current()?.vault.path == "/tmp/a")
        #expect(await store.current()?.session.maxParts == 10)
        let written = try s.fileConfig()
        #expect(written.vault.path == "/tmp/a")
        #expect(written.session.maxParts == 10)
    }
}
