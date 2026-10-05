// DR ごとの検査のテスト（T-32 §5.2）。<HOME>・Vault・helpers は TempDirectory の中だけ。本物の whisper-cli / llama-server は起動しない。
import Darwin
import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDProcess

@testable import VDPipeline
@testable import VDStore

/// 署名の偽物（DR-17）。
struct FakeSignature: AppSignatureReading {
    let info: AppSignatureInfo
    func read(bundle: URL) -> AppSignatureInfo { info }
}

/// 診断のテストの世界（T-32 §5.2〜§5.3）。何も起動せず、TempDirectory の外に触れない。
struct DiagnosticsWorld {
    let tmp: TempDirectory
    let layout: HomeLayout
    let paths: AppPaths
    let catalog: ModelCatalog
    let configStore: ConfigStore
    let ingest: FakeIngest
    let runner: ScriptedProcessRunner
    let cache: ModelVerificationCache
    let sink: CapturingLogSink
    let log: AppLog
    let clock: FixedClock
    let signature: any AppSignatureReading
    let physicalMemoryBytes: UInt64

    /// モデルの中身（1 バイト）と、その SHA-256（`printf m | shasum -a 256`）
    static let modelContent = Data("m".utf8)
    static let modelSHA = "62c66a7a5dd70c3146618063c344e531e6d4b59e379808443ce962b3abd63c5a"
    static let gib: UInt64 = 1024 * 1024 * 1024

    /// TestCatalogs.minimal と同じ ID で、SHA-256 だけ modelContent のものにしたカタログ
    static func catalog(llmMinMemoryGB: Int = 1) throws -> ModelCatalog {
        let commit = String(repeating: "0", count: 40)
        func item(_ id: String, _ file: String, llm: Bool) -> String {
            let extra = llm ? #", "minMemoryGB": \#(llmMinMemoryGB), "verified": true"# : ""
            return """
                {"id": "\(id)", "displayName": "\(id)", "file": "\(file)", \
                "url": "https://huggingface.co/x/y/resolve/\(commit)/\(file)", \
                "sha256": "\(modelSHA)", "bytes": 1, "license": "MIT"\(extra)}
                """
        }
        let json = """
            {"schema": 1,
             "whisper": [\(item("large-v3-turbo-q8_0", "ggml-large-v3-turbo-q8_0.bin", llm: false))],
             "vad": [\(item("silero-v5.1.2", "ggml-silero-v5.1.2.bin", llm: false))],
             "llm": [\(item("test-llm", "test-llm.gguf", llm: true))]}
            """
        guard case .success(let c) = ModelCatalog.load(Data(json.utf8)), c.rejected.isEmpty else {
            throw PipelineFixtureError.badFixture("catalog")
        }
        return c
    }

    /// 既定の設定からの変更: audio.freeSpaceMarginBytes = 0（CI の空き容量に依存させない）
    static func baseConfig() -> AppConfig {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.audio.freeSpaceMarginBytes = 0
        return config
    }

    /// loadConfig が偽なら ConfigStore は読まない（current() == nil）
    static func make(
        configure: (inout AppConfig) -> Void = { _ in }, loadConfig: Bool = true, results: [ProcessResult] = [],
        snapshot: DeviceSnapshot? = nil, llmMinMemoryGB: Int = 1, physicalMemoryBytes: UInt64 = 1 << 40,
        signature: AppSignatureInfo = AppSignatureInfo(valid: true, teamID: "ABCDE12345", message: nil)
    ) async throws -> DiagnosticsWorld {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        let paths = AppPaths(
            resources: tmp.url.appendingPathComponent("resources", isDirectory: true),
            helpers: tmp.url.appendingPathComponent("helpers", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.helpers, withIntermediateDirectories: true)
        let clock = FixedClock(epochMillis: 1_788_040_812_000)
        let sink = CapturingLogSink()
        let log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: PipelineFixtures.zone, clock: clock)
        let catalog = try catalog(llmMinMemoryGB: llmMinMemoryGB)
        let configStore = ConfigStore(
            layout: layout, catalog: catalog, log: log, observeReaperConf: { .missing },
            defaultTimeZone: { "Asia/Tokyo" })
        if loadConfig {
            var config = baseConfig()
            configure(&config)
            try AtomicFile.write(ConfigLoader.encode(config), to: layout.configFile)
            let loaded = await configStore.load()
            guard case .valid = loaded else { throw PipelineFixtureError.invalidConfig("\(loaded)") }
        }
        return DiagnosticsWorld(
            tmp: tmp, layout: layout, paths: paths, catalog: catalog, configStore: configStore,
            ingest: FakeIngest(snapshot: snapshot), runner: ScriptedProcessRunner(results: results),
            cache: ModelVerificationCache(), sink: sink, log: log, clock: clock,
            signature: FakeSignature(info: signature), physicalMemoryBytes: physicalMemoryBytes)
    }

    var deps: DiagnosticsDependencies {
        DiagnosticsDependencies(
            layout: layout, paths: paths, catalog: catalog, config: configStore, ingest: ingest,
            locks: DisabledLockObserver(), runner: runner, verificationCache: cache, signature: signature,
            bundleURL: tmp.url.appendingPathComponent("VoiceDock.app", isDirectory: true),
            physicalMemoryBytes: physicalMemoryBytes, clock: clock, log: log)
    }

    /// 検査 1 件に渡す文脈（ConfigStore を通さずに設定を渡す。検証に通らない値も試せる）
    func context(
        config: AppConfig? = DiagnosticsWorld.baseConfig(), violations: [ConfigViolation] = [],
        snapshot: DeviceSnapshot? = nil, loginItem: LoginItemStatus = .enabled
    ) -> DiagnosticsContext {
        DiagnosticsContext(
            deps: deps, config: config, violations: violations, snapshot: snapshot, loginItem: loginItem,
            now: clock.now())
    }

    /// <HOME>/voicedock.sqlite を作る（呼び手が持っている間は開いたまま）
    func openStore() throws -> Store {
        try Store(url: layout.database, clock: clock, zone: PipelineFixtures.zone)
    }

    /// models/<kind>/<file> に中身を置く
    func placeModel(kind: ModelKind, file: String, content: Data = DiagnosticsWorld.modelContent) throws {
        let url = layout.modelFile(kind: kind.rawValue, file: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
    }

    /// helpers に中身の無い実行ファイルを置く（起動はしない。runner は台本）
    func placeHelper(_ url: URL) throws {
        try Data().write(to: url)
    }

    /// Vault（TempDirectory の中）。marker なら .obsidian/ も作る
    func makeVault(marker: Bool = true) throws -> String {
        let vault = tmp.url.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        if marker {
            try FileManager.default.createDirectory(
                at: vault.appendingPathComponent(".obsidian", isDirectory: true), withIntermediateDirectories: true)
        }
        return tmp.url.appendingPathComponent("vault").path(percentEncoded: false)
    }

    /// 行を入れて状態を強制し、inbox にファイルを置く（テストだけの近道。Tests/ は PT-05 の対象外）
    func addInboxPart(store: Store, relpath: String, status: PartStatus, bytes: Int = 4) throws {
        let row = try Builders.recording(relpath: relpath)
        try store.insertRecording(row)
        try store.pool.write { db in
            try db.execute(
                sql: "UPDATE recordings SET status = ? WHERE partkey = ?", arguments: [status.rawValue, row.partkey])
        }
        let file = layout.inboxFile(deviceID: "DJIMIC3", relpath: relpath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: file)
    }

    static func help(_ text: String, exit code: Int32 = 0) -> ProcessResult {
        ProcessResult(termination: .exited(code), stdoutTail: Data(text.utf8), stderrTail: Data())
    }

    static let whisperHelpAll =
        "usage: whisper-cli [options]\n  --vad, --vad-model FNAME --vad-threshold N --vad-min-speech-duration-ms N\n"
        + "  --vad-min-silence-duration-ms N --vad-speech-pad-ms N\n"
    static let whisperHelpNoVAD = "usage: whisper-cli [options]\n  --model FNAME\n"
    static let llamaHelpAll =
        "--model --host --port --api-key-file --ctx-size --n-gpu-layers --jinja --parallel --no-webui --offline\n"
    static let llamaHelpPartial = "--model --host --port\n"

    static func snapshot(
        devices: [String: Bool?] = [:], unavailable: [String: String] = [:], errnos: [String: Int32] = [:]
    ) -> DeviceSnapshot {
        var observed: [String: DeviceObservation] = [:]
        for (id, readOnly) in devices {
            observed[id] = DeviceObservation(
                deviceID: id, mountPath: "/tmp/vd-fake/" + id, deviceNode: nil, readOnly: readOnly, freeBytes: nil,
                relpaths: [])
        }
        return DeviceSnapshot(
            generation: 1, completedAt: Instant(epochMillis: 1_788_040_000_000), connectEpoch: 0, devices: observed,
            unavailable: unavailable, notListableErrno: errnos)
    }
}

@Suite("DR ごとの検査")
struct DiagnosticChecksTests {
    // MARK: DR-01

    @Test("DR-01 設定が読め違反が無ければ ok")
    func dr01OKWhenNoViolations() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr01(w.context())
        #expect(r == DiagnosticResult(id: "DR-01", status: .ok, label: "設定", details: ["違反はありません"]))
    }

    @Test("DR-01 違反を 1 件 1 行で出して fail")
    func dr01FailListsEachViolation() async throws {
        let w = try await DiagnosticsWorld.make()
        let v = [
            ConfigViolation(rule: "CV-01", code: .configInvalidValue, keyPath: "device.stabilityChecks", message: "a"),
            ConfigViolation(rule: "CV-32", code: .configInvalidValue, keyPath: "timeZone", message: "b"),
        ]
        let r = await DiagnosticChecks.dr01(w.context(config: nil, violations: v))
        #expect(r.status == .fail)
        #expect(
            r.details == [
                "CV-01  CONFIG_INVALID_VALUE  device.stabilityChecks: a", "CV-32  CONFIG_INVALID_VALUE  timeZone: b",
            ])
    }

    @Test("DR-01 設定が読めず違反も無ければ『読めません』")
    func dr01FailWhenUnreadable() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr01(w.context(config: nil))
        #expect(r.status == .fail)
        #expect(r.details == ["設定ファイルを読めません"])
    }

    // MARK: DR-16

    @Test("DR-16 解決できるタイムゾーンは ok")
    func dr16OK() async throws {
        let w = try await DiagnosticsWorld.make()
        var c = DiagnosticsWorld.baseConfig()
        c.timeZone = "Asia/Tokyo"
        let r = await DiagnosticChecks.dr16(w.context(config: c))
        #expect(r == DiagnosticResult(id: "DR-16", status: .ok, label: "タイムゾーン", details: ["Asia/Tokyo"]))
    }

    @Test("DR-16 解決できないタイムゾーンは fail")
    func dr16Fail() async throws {
        let w = try await DiagnosticsWorld.make()
        var c = DiagnosticsWorld.baseConfig()
        c.timeZone = "Nowhere/Nope"
        let r = await DiagnosticChecks.dr16(w.context(config: c))
        #expect(r.status == .fail)
        #expect(r.details == ["タイムゾーン Nowhere/Nope を解決できません"])
    }

    // MARK: DR-02

    @Test("DR-02 DB が無ければ notice で、作らない")
    func dr02NoticeWhenMissing() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr02(w.context())
        #expect(r == DiagnosticResult(id: "DR-02", status: .notice, label: "データベース", details: ["まだ作られていません"]))
        #expect(!PipelineFixtures.exists(w.layout.database))
    }

    @Test("DR-02 Store で作った DB は ok")
    func dr02OK() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        let r = await DiagnosticChecks.dr02(w.context())
        #expect(r.status == .ok)
        #expect(r.details == ["quick_check ok、マイグレーション v1_initial"])
        #expect(r.details.first?.hasPrefix("quick_check ok、マイグレーション ") == true)
        _ = store
    }

    @Test("DR-02 マイグレーションが最新でなければ fail")
    func dr02FailOnBadMigrations() async throws {
        let w = try await DiagnosticsWorld.make()
        var old = DatabaseMigrator()
        old.registerMigration("v0_old") { db in try db.execute(sql: "CREATE TABLE old_table (x INTEGER)") }
        let store = try Store(url: w.layout.database, clock: w.clock, zone: PipelineFixtures.zone, migrator: old)
        let r = await DiagnosticChecks.dr02(w.context())
        #expect(r.status == .fail)
        // 知らない識別子は GRDB の appliedMigrations に現れないので、適用済みは空として出る
        #expect(r.details.first?.hasPrefix("適用済みのマイグレーションが ") == true)
        #expect(r.details == ["適用済みのマイグレーションが なし です（最新は v1_initial）"])
        _ = store
    }

    // MARK: DR-03

    @Test("DR-03 空き容量が足りれば ok")
    func dr03OK() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr03(w.context())
        #expect(r.status == .ok)
        #expect(r.details.count == 1)
        #expect(r.details.first?.hasPrefix("空き ") == true)
        #expect(r.details.first?.hasSuffix(" GiB") == true)
    }

    @Test("DR-03 staging の上限を超えるなら notice（§8.3 の文言）")
    func dr03NoticeWhenStagingOverLimit() async throws {
        let w = try await DiagnosticsWorld.make()
        var c = DiagnosticsWorld.baseConfig()
        c.audio.stagingMaxBytes = 1
        let r = await DiagnosticChecks.dr03(w.context(config: c))
        #expect(r.status == .notice)
        #expect(r.details == ["staging 使用量 0 + 想定 57600000 が上限 1 を超える"])
    }

    // MARK: DR-04

    @Test("DR-04 whisper-cli が無ければ fail")
    func dr04FailWhenMissing() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr04(w.context())
        #expect(r.status == .fail)
        #expect(r.details == [w.paths.whisperCLI.path(percentEncoded: false) + " がありません"])
        #expect(await w.runner.recorded.isEmpty)
    }

    @Test("DR-04 --help が exit 2 なら fail")
    func dr04FailWhenHelpFails() async throws {
        let w = try await DiagnosticsWorld.make(results: [DiagnosticsWorld.help("", exit: 2)])
        try w.placeHelper(w.paths.whisperCLI)
        let r = await DiagnosticChecks.dr04(w.context())
        #expect(r.status == .fail)
        #expect(r.details == ["--help が失敗しました（exit 2）"])
    }

    @Test("DR-04 VAD の 6 フラグが在れば ok")
    func dr04OKWithAllVADFlags() async throws {
        let w = try await DiagnosticsWorld.make(results: [DiagnosticsWorld.help(DiagnosticsWorld.whisperHelpAll)])
        try w.placeHelper(w.paths.whisperCLI)
        let r = await DiagnosticChecks.dr04(w.context())
        #expect(r == DiagnosticResult(id: "DR-04", status: .ok, label: "whisper-cli", details: ["VAD のフラグ 6 個が在ります"]))
        let spec = await w.runner.recorded.first
        #expect(spec?.arguments == ["--help"])
        #expect(spec?.executable == w.paths.whisperCLI)
    }

    @Test("DR-04 VAD 無効ならフラグが無くても notice")
    func dr04NoticeWhenVADDisabled() async throws {
        let w = try await DiagnosticsWorld.make(results: [DiagnosticsWorld.help(DiagnosticsWorld.whisperHelpNoVAD)])
        try w.placeHelper(w.paths.whisperCLI)
        var c = DiagnosticsWorld.baseConfig()
        c.transcription.vad.enabled = false
        let r = await DiagnosticChecks.dr04(w.context(config: c))
        #expect(r.status == .notice)
        #expect(
            r.details == [
                "VAD のフラグがありません: --vad --vad-model --vad-threshold --vad-min-speech-duration-ms "
                    + "--vad-min-silence-duration-ms --vad-speech-pad-ms"
            ])
    }

    @Test("DR-04 VAD 有効でフラグが無ければ fail")
    func dr04FailWhenVADEnabled() async throws {
        let w = try await DiagnosticsWorld.make(results: [DiagnosticsWorld.help(DiagnosticsWorld.whisperHelpNoVAD)])
        try w.placeHelper(w.paths.whisperCLI)
        let r = await DiagnosticChecks.dr04(w.context())
        #expect(r.status == .fail)
        #expect(r.details.first?.hasPrefix("VAD のフラグがありません: --vad ") == true)
    }

    // MARK: DR-05

    @Test("DR-05 モデルが在り SHA-256 が一致すれば ok")
    func dr05OK() async throws {
        let w = try await DiagnosticsWorld.make()
        try w.placeModel(kind: .whisper, file: "ggml-large-v3-turbo-q8_0.bin")
        let r = await DiagnosticChecks.dr05(w.context())
        #expect(
            r
                == DiagnosticResult(
                    id: "DR-05", status: .ok, label: "Whisper モデル", details: ["large-v3-turbo-q8_0（SHA-256 一致）"]))
    }

    @Test("DR-05 モデルが無ければ fail")
    func dr05FailMissing() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr05(w.context())
        #expect(r.status == .fail)
        #expect(r.details == ["ggml-large-v3-turbo-q8_0.bin がありません"])
    }

    @Test("DR-05 中身が違えば SHA-256 の不一致で fail")
    func dr05FailSHA() async throws {
        let w = try await DiagnosticsWorld.make()
        try w.placeModel(kind: .whisper, file: "ggml-large-v3-turbo-q8_0.bin", content: Data("x".utf8))
        let r = await DiagnosticChecks.dr05(w.context())
        #expect(r.status == .fail)
        #expect(r.details == ["SHA-256 が一致しません"])
    }

    @Test("DR-05 2 回目は ModelVerificationCache の記録を使いハッシュを計算し直さない")
    func dr05UsesTheVerificationCache() async throws {
        let w = try await DiagnosticsWorld.make()
        try w.placeModel(kind: .whisper, file: "ggml-large-v3-turbo-q8_0.bin")
        let url = w.layout.modelFile(kind: "whisper", file: "ggml-large-v3-turbo-q8_0.bin")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path(percentEncoded: false))
        let first = await DiagnosticChecks.dr05(w.context())
        #expect(first.status == .ok)
        // 同じ inode・同じサイズ・同じ mtime のまま中身だけ変える（計算し直せば SHA が一致しない）
        let handle = try FileHandle(forUpdating: url)
        try handle.write(contentsOf: Data("x".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path(percentEncoded: false))
        let second = await DiagnosticChecks.dr05(w.context())
        #expect(second.status == .ok)
        #expect(second.details == ["large-v3-turbo-q8_0（SHA-256 一致）"])
    }

    // MARK: DR-06

    @Test("DR-06 VAD 無効なら notice（ASR-02 の逐語）")
    func dr06NoticeWhenDisabled() async throws {
        let w = try await DiagnosticsWorld.make()
        var c = DiagnosticsWorld.baseConfig()
        c.transcription.vad.enabled = false
        let r = await DiagnosticChecks.dr06(w.context(config: c))
        #expect(
            r
                == DiagnosticResult(
                    id: "DR-06", status: .notice, label: "VAD モデル", details: ["無音から幻覚が生成され、13 倍以上遅くなります"]))
    }

    @Test("DR-06 VAD 有効でモデルが在れば ok")
    func dr06OK() async throws {
        let w = try await DiagnosticsWorld.make()
        try w.placeModel(kind: .vad, file: "ggml-silero-v5.1.2.bin")
        let r = await DiagnosticChecks.dr06(w.context())
        #expect(r.status == .ok)
        #expect(r.details == ["silero-v5.1.2（SHA-256 一致）"])
    }

    @Test("DR-06 VAD 有効でモデルが無ければ fail")
    func dr06Fail() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr06(w.context())
        #expect(r.status == .fail)
        #expect(r.details == ["ggml-silero-v5.1.2.bin がありません"])
    }

    // MARK: DR-07

    @Test("DR-07 llama-server が無ければ fail")
    func dr07FailWhenMissing() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr07(w.context())
        #expect(r.status == .fail)
        #expect(r.details == [w.paths.llamaServer.path(percentEncoded: false) + " がありません"])
    }

    @Test("DR-07 使うフラグが欠けていれば fail")
    func dr07FailWhenFlagsMissing() async throws {
        let w = try await DiagnosticsWorld.make(results: [DiagnosticsWorld.help(DiagnosticsWorld.llamaHelpPartial)])
        try w.placeHelper(w.paths.llamaServer)
        let r = await DiagnosticChecks.dr07(w.context())
        #expect(r.status == .fail)
        #expect(r.details.first?.hasPrefix("使えないフラグがあります: ") == true)
        #expect(
            r.details == [
                "使えないフラグがあります: --api-key-file --ctx-size --n-gpu-layers --jinja --parallel --no-webui --offline"
            ])
    }

    @Test("DR-07 使うフラグが全部在れば ok")
    func dr07OK() async throws {
        let w = try await DiagnosticsWorld.make(results: [DiagnosticsWorld.help(DiagnosticsWorld.llamaHelpAll)])
        try w.placeHelper(w.paths.llamaServer)
        let r = await DiagnosticChecks.dr07(w.context())
        #expect(r == DiagnosticResult(id: "DR-07", status: .ok, label: "llama-server", details: ["使うフラグ 10 個が在ります"]))
    }

    // MARK: DR-08

    @Test("DR-08 LLM が選ばれていなければ fail")
    func dr08FailWhenNotSelected() async throws {
        let w = try await DiagnosticsWorld.make()
        var c = DiagnosticsWorld.baseConfig()
        c.llm.modelID = nil
        let r = await DiagnosticChecks.dr08(w.context(config: c))
        #expect(r == DiagnosticResult(id: "DR-08", status: .fail, label: "LLM モデル", details: ["LLM モデルが選ばれていません"]))
    }

    @Test("DR-08 メモリが足りなければ fail（ModelMemory の式）")
    func dr08FailWhenNotEnoughMemory() async throws {
        let w = try await DiagnosticsWorld.make(llmMinMemoryGB: 32, physicalMemoryBytes: 16 * DiagnosticsWorld.gib)
        try w.placeModel(kind: .llm, file: "test-llm.gguf")
        var c = DiagnosticsWorld.baseConfig()
        c.llm.modelID = "test-llm"
        let r = await DiagnosticChecks.dr08(w.context(config: c))
        #expect(r.status == .fail)
        #expect(r.details.contains("メモリが足りません（32 GB 以上が必要。この Mac は 16 GB）"))
    }

    @Test("DR-08 読み込んだモデルは SHA だけ見て ok、動作保証外と出す")
    func dr08OKForCustom() async throws {
        let w = try await DiagnosticsWorld.make()
        let id = "custom:" + DiagnosticsWorld.modelSHA
        let url = try #require(ModelFiles.customLLMURL(id: id, layout: w.layout))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DiagnosticsWorld.modelContent.write(to: url)
        var c = DiagnosticsWorld.baseConfig()
        c.llm.modelID = id
        let r = await DiagnosticChecks.dr08(w.context(config: c))
        #expect(r.status == .ok)
        #expect(r.details == ["読み込んだモデル 62c66a7a（SHA-256 一致）", "動作保証外のモデルです"])
    }

    // MARK: DR-10

    @Test("DR-10 .obsidian/ の在る Vault は ok")
    func dr10OKWhenVaultAvailable() async throws {
        let w = try await DiagnosticsWorld.make()
        let path = try w.makeVault()
        var c = DiagnosticsWorld.baseConfig()
        c.vault.path = path
        let r = await DiagnosticChecks.dr10(w.context(config: c))
        #expect(r == DiagnosticResult(id: "DR-10", status: .ok, label: "Vault", details: [path]))
    }

    @Test("DR-10 目印が無ければ『Vault でない』の文言で fail")
    func dr10FailWhenMarkerMissing() async throws {
        let w = try await DiagnosticsWorld.make()
        let path = try w.makeVault(marker: false)
        var c = DiagnosticsWorld.baseConfig()
        c.vault.path = path
        let r = await DiagnosticChecks.dr10(w.context(config: c))
        #expect(r.status == .fail)
        #expect(r.details.count == 1)
        #expect(r.details.first?.contains("に .obsidian/ がありません") == true)
    }

    @Test("DR-10 書けない Vault は『書き込めません』の文言で fail")
    func dr10FailWhenNotWritable() async throws {
        let w = try await DiagnosticsWorld.make()
        let path = try w.makeVault()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        var c = DiagnosticsWorld.baseConfig()
        c.vault.path = path
        let r = await DiagnosticChecks.dr10(w.context(config: c))
        #expect(r.status == .fail)
        #expect(r.details.first?.contains("に書き込めません（errno ") == true)
        #expect(r.details == [path + " に書き込めません（errno 13）"])
    }

    @Test("DR-10 NOTE-16 Vault に何も作らない")
    func dr10CreatesNothing() async throws {
        let w = try await DiagnosticsWorld.make()
        let path = try w.makeVault()
        var c = DiagnosticsWorld.baseConfig()
        c.vault.path = path
        let before = try FileTree.listing(URL(fileURLWithPath: path, isDirectory: true))
        _ = await DiagnosticChecks.dr10(w.context(config: c))
        let after = try FileTree.listing(URL(fileURLWithPath: path, isDirectory: true))
        #expect(after == before)
        #expect(before == [".obsidian/"])
    }

    // MARK: DR-11

    @Test("DR-11 まだ走査していなければ skip")
    func dr11SkipWhenNoSnapshot() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr11(w.context(snapshot: nil))
        #expect(r == DiagnosticResult(id: "DR-11", status: .skip, label: "デバイスの列挙", details: ["まだ走査していません"]))
    }

    @Test("DR-11 デバイス未接続なら skip（TEST-28 0 台）")
    func dr11SkipWhenNoDevice() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr11(w.context(snapshot: DiagnosticsWorld.snapshot()))
        #expect(r.status == .skip)
        #expect(r.details == ["デバイスが接続されていません"])
    }

    @Test("DR-11 列挙できれば台数を出して ok")
    func dr11OK() async throws {
        let w = try await DiagnosticsWorld.make()
        let s = DiagnosticsWorld.snapshot(devices: ["DJIMIC3": false, "DJIMIC3_2": false])
        let r = await DiagnosticChecks.dr11(w.context(snapshot: s))
        #expect(r.status == .ok)
        #expect(r.details == ["2 台を列挙できました"])
    }

    @Test("DR-11 列挙できない名前を errno つきで出し、許可の場所を案内して fail")
    func dr11FailWithErrno() async throws {
        let w = try await DiagnosticsWorld.make()
        let s = DiagnosticsWorld.snapshot(unavailable: ["X": "not_listable"], errnos: ["X": EPERM])
        let r = await DiagnosticChecks.dr11(w.context(snapshot: s))
        #expect(r.status == .fail)
        #expect(
            r.details == [
                "X を列挙できません（errno 1）",
                "システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム",
            ])
    }

    // MARK: DR-12

    @Test("DR-12 登録されていれば ok")
    func dr12OK() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr12(w.context(loginItem: .enabled))
        #expect(r == DiagnosticResult(id: "DR-12", status: .ok, label: "ログイン項目", details: ["登録されています"]))
    }

    @Test("DR-12 .enabled 以外は notice（逐語 3 通り）")
    func dr12NoticeForEachStatus() async throws {
        let w = try await DiagnosticsWorld.make()
        let cases: [(LoginItemStatus, String)] = [
            (.requiresApproval, "許可が要ります"), (.notRegistered, "登録されていません"), (.notFound, "アプリの場所が不明です"),
        ]
        for (status, text) in cases {
            let r = await DiagnosticChecks.dr12(w.context(loginItem: status))
            #expect(r.status == .notice)
            #expect(r.details == [text])
        }
    }

    // MARK: DR-15

    @Test("DR-15 取り残しが無ければ ok")
    func dr15OKWhenNone() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        let r = await DiagnosticChecks.dr15(w.context())
        #expect(r == DiagnosticResult(id: "DR-15", status: .ok, label: "inbox の取り残し", details: ["ありません"]))
        _ = store
    }

    @Test("DR-15 終端の Part の inbox ファイルを数えて notice、消さない")
    func dr15NoticeWithCountAndBytes() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try w.addInboxPart(
            store: store, relpath: "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav", status: .rawSaved)
        try w.addInboxPart(
            store: store, relpath: "TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav",
            status: .completed)
        // FAILED（再試行の入力）と処理中は取り残しではない
        try w.addInboxPart(
            store: store, relpath: "TX_MIC001_20260829_093000/TX01_MIC002_20260829_093000_orig.wav", status: .failed)
        try w.addInboxPart(
            store: store, relpath: "TX_MIC001_20260829_100000/TX01_MIC002_20260829_100000_orig.wav",
            status: .normalized)
        let r = await DiagnosticChecks.dr15(w.context())
        #expect(r.status == .notice)
        #expect(r.details == ["2 件 0.0 GiB（自動では消しません）"])
        let kept = w.layout.inboxFile(
            deviceID: "DJIMIC3", relpath: "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav")
        #expect(PipelineFixtures.exists(kept))
    }

    // MARK: DR-17

    @Test("DR-17 有効で Team ID が在れば ok")
    func dr17OK() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr17(w.context())
        #expect(r == DiagnosticResult(id: "DR-17", status: .ok, label: "アプリの署名", details: ["有効（Team ID ABCDE12345）"]))
    }

    @Test("DR-17 ad-hoc 署名は notice")
    func dr17NoticeForAdhoc() async throws {
        let w = try await DiagnosticsWorld.make(signature: AppSignatureInfo(valid: true, teamID: nil, message: nil))
        let r = await DiagnosticChecks.dr17(w.context())
        #expect(r.status == .notice)
        #expect(r.details == ["ad-hoc 署名です。ビルドのたびにリムーバブルボリュームの許可が失効します"])
    }

    @Test("DR-17 無効な署名は notice")
    func dr17NoticeForInvalid() async throws {
        let w = try await DiagnosticsWorld.make(signature: AppSignatureInfo(valid: false, teamID: nil, message: nil))
        let r = await DiagnosticChecks.dr17(w.context())
        #expect(r.status == .notice)
        #expect(r.details == ["署名が無効です"])
    }

    // MARK: DR-14

    @Test("DR-14 常に notice で、details は LockDisplay.lines と同一")
    func dr14AlwaysNotice() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr14(w.context())
        let expected = LockDisplay(
            appEnabled: false, confState: .missing, reaper: .notInstalled, mountMode: "ro", devices: nil,
            readiness: .disabled("delete_source_audio_disabled"))
        #expect(r.status == .notice)
        #expect(r.label == "元音声の削除")
        #expect(r.details == expected.lines)
        #expect(
            r.details == [
                "ロック 1  : アプリ=無効, reaper.conf=無し", "ロック 2-A: 削除モジュール=未導入", "ロック 2-B: 設定=ro, 観測=不明",
            ])
    }

    @Test("DR-14 3 行")
    func dr14HasThreeLines() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = await DiagnosticChecks.dr14(w.context())
        #expect(r.details.count == 3)
        #expect(r.details.first?.hasPrefix("ロック 1  : ") == true)
    }
}

/// ディレクトリの中身の一覧（相対パス・サイズ・mtime。ディレクトリは末尾に "/"）。前後の突き合わせに使う。
enum FileTree {
    static func listing(_ root: URL) throws -> [String] {
        let base = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard
            let items = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [])
        else { return [] }
        var out: [String] = []
        for case let url as URL in items {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let path = url.standardizedFileURL.path(percentEncoded: false)
            var rel = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            if values.isDirectory == true {
                if !rel.hasSuffix("/") { rel += "/" }
                out.append(rel)
            } else if rel == "voicedock.sqlite-shm" {
                // WAL の共有メモリの索引は、読み取り専用の接続でも読み手の印（read mark）を書くので mtime が動く
                // （SQLite の仕組み。中身のデータではない）。在否とサイズだけを比べる
                out.append(rel + " " + String(values.fileSize ?? -1))
            } else {
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                out.append(rel + " " + String(values.fileSize ?? -1) + " " + String(mtime))
            }
        }
        return out.sorted()
    }
}
