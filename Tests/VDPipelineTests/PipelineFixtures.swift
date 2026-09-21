// VDPipeline のテストの世界の組み立て（T-18 §6.0。後続チケットが足す）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDProcess
import VDStore

@testable import VDPipeline

/// テストの世界（一時ディレクトリの HOME・DB・ConfigStore・偽の取り込み・固定の時計・記録するログ）。
struct PipelineWorld {
    let tmp: TempDirectory
    let layout: HomeLayout
    let paths: AppPaths
    let store: Store
    let configStore: ConfigStore
    let ingest: FakeIngest
    let clock: FixedClock
    let sleeper: RecordingSleeper
    let sink: CapturingLogSink
    let log: AppLog
    let assertion: RecordingSleepAssertion

    var deps: WorkerDependencies {
        WorkerDependencies(
            layout: layout, paths: paths, store: store, config: configStore, ingest: ingest, runner: ProcessRunner(),
            catalog: TestCatalogs.minimal, license: AlwaysAllowLicenseGate(), clock: clock, sleeper: sleeper, log: log)
    }

    /// config を設定して ConfigStore に書き、load する（検証を通らなければテストを落とす）。
    static func make(configure: (inout AppConfig) -> Void = { _ in }) async throws -> PipelineWorld {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        let paths = AppPaths(
            resources: PackageRoot.url.appendingPathComponent("Resources", isDirectory: true),
            helpers: tmp.url.appendingPathComponent("helpers", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.helpers, withIntermediateDirectories: true)
        let clock = FixedClock(epochMillis: 1_788_040_812_000)
        let store = try Builders.openStore(in: tmp.url, clock: clock)
        let sink = CapturingLogSink()
        let log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: PipelineFixtures.zone, clock: clock)
        let configStore = ConfigStore(
            layout: layout, catalog: TestCatalogs.minimal, log: log, observeReaperConf: { .missing },
            defaultTimeZone: { "Asia/Tokyo" })
        var config = PipelineFixtures.baseConfig()
        configure(&config)
        try AtomicFile.write(ConfigLoader.encode(config), to: layout.configFile)
        let loaded = await configStore.load()
        guard case .valid = loaded else { throw PipelineFixtureError.invalidConfig("\(loaded)") }
        return PipelineWorld(
            tmp: tmp, layout: layout, paths: paths, store: store, configStore: configStore, ingest: FakeIngest(),
            clock: clock, sleeper: RecordingSleeper(), sink: sink, log: log, assertion: RecordingSleepAssertion())
    }

    /// 今の設定で TickContext を作る（pauses は新しい PauseBook、activity は assertion を使う ActivityBoard）。
    func context(
        snapshot: DeviceSnapshot? = nil, stop: StopFlag = StopFlag(), assertion: (any SleepAssertion)? = nil
    ) async throws -> TickContext {
        guard let config = await configStore.current() else { throw PipelineFixtureError.noConfig }
        return TickContext(
            deps: deps, config: config, zone: Worker.zone(for: config), snapshot: snapshot, pauses: PauseBook(log: log),
            activity: ActivityBoard(assertion: assertion ?? self.assertion), stop: stop)
    }

    /// assertion は self.assertion
    func worker(onStage: (@Sendable (TickStage) -> Void)? = nil) -> Worker {
        Worker(deps: deps, assertion: assertion, onStage: onStage)
    }

    /// FakeWhisper を helpers/whisper-cli に、TestCatalogs.minimal の whisper / vad のファイルを entry.bytes の 0 で置く。
    func installWhisper(utterances: [FakeWhisperUtterance] = FakeWhisper.defaultUtterances, exitCode: Int32 = 0)
        throws
    {
        try FakeWhisper.write(to: paths.whisperCLI, utterances: utterances, exitCode: exitCode)
        for kind in [ModelKind.whisper, .vad] {
            for entry in TestCatalogs.minimal.entries(kind: kind) {
                let url = ModelFiles.url(kind: kind, entry: entry, layout: layout)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: Int(entry.bytes)).write(to: url)
            }
        }
    }

    /// inbox に BWF（speech・pcm24）を書き、sha256Helper = その SHA-256 の行を登録する。
    @discardableResult
    func registerPart(
        relpath: String = PipelineFixtures.relpath, startedAt: String = PipelineFixtures.startedAt,
        seconds: Double = 2.0
    ) throws -> String {
        let inbox = layout.inboxFile(deviceID: "DJIMIC3", relpath: relpath)
        try BWFWriter.write(to: inbox, seconds: seconds, format: .pcm24, content: .speech)
        let partkey = try PartKey.make(deviceID: "DJIMIC3", relpath: relpath)
        guard let start = PipelineFixtures.zone.parseISO(startedAt), let inboxRel = layout.relativePath(of: inbox)
        else { throw PipelineFixtureError.badFixture(startedAt) }
        let endedAt = PipelineFixtures.zone.iso(start.adding(milliseconds: Int64(seconds * 1000)))
        try store.insertRecording(
            NewRecording(
                partkey: partkey, deviceID: "DJIMIC3", sourceFolder: RelPath.parent(relpath), transmitterID: "TX01",
                micIndex: 2, startedAt: startedAt, durationSeconds: seconds, endedAt: endedAt, sourcePath: relpath,
                sourceSize: try PipelineFixtures.size(of: inbox), sourceMtime: 1_787_000_000.0,
                sha256Helper: try FileHasher.sha256(of: inbox, chunkBytes: 1_048_576), inboxPath: inboxRel))
        return partkey
    }
}

enum PipelineFixtures {
    static let relpath = "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    static let startedAt = "2026-08-29T07:12:04+09:00"
    static let partkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    /// Asia/Tokyo（テストの前提。無ければ UTC+9 の固定で代える）。
    static let zone: ZonedTime = {
        if let tokyo = TimeZone(identifier: "Asia/Tokyo") { return ZonedTime(timeZone: tokyo) }
        return ZonedTime(fixedOffsetSeconds: 9 * 3600)
    }()

    /// 既定の設定からの変更: audio.freeSpaceMarginBytes = 0（CI の空き容量に依存させない）
    static func baseConfig() -> AppConfig {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.audio.freeSpaceMarginBytes = 0
        return config
    }

    static func size(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

enum PipelineFixtureError: Error {
    case invalidConfig(String)
    case noConfig
    case badFixture(String)
    case missingRow(String)
    case timedOut(String)
}

/// SleepAssertion の記録（begin / end の回数と今の状態。Mutex で守る）。onBegin は begin のたびに呼ぶ。
final class RecordingSleepAssertion: SleepAssertion {
    private struct State {
        var begins = 0
        var ends = 0
        var active = false
    }

    private let state = Mutex<State>(State())
    private let onBegin: (@Sendable () -> Void)?

    init(onBegin: (@Sendable () -> Void)? = nil) {
        self.onBegin = onBegin
    }

    func begin() {
        state.withLock {
            $0.begins += 1
            $0.active = true
        }
        onBegin?()
    }

    func end() {
        state.withLock {
            $0.ends += 1
            $0.active = false
        }
    }

    var begins: Int { state.withLock { $0.begins } }
    var ends: Int { state.withLock { $0.ends } }
    var active: Bool { state.withLock { $0.active } }
}

// MARK: - テストの共通の手順（行の準備・ログと events の読み取り・待ち）

extension PipelineWorld {
    /// Builders.recording の行を作る（inbox のファイルは置かない）。partkey を返す。
    @discardableResult
    func insertPart(
        relpath: String = PipelineFixtures.relpath, startedAt: String = PipelineFixtures.startedAt
    ) throws -> String {
        let row = try Builders.recording(relpath: relpath, startedAt: startedAt)
        try store.insertRecording(row)
        return row.partkey
    }

    /// Part を今の状態から path の順に遷移させる（FAILED への遷移は code を付ける）。
    func movePart(_ pk: String, _ path: [PartStatus], code: ErrorCode = .importFailed) throws {
        for to in path {
            guard let row = try store.recording(pk) else { throw PipelineFixtureError.missingRow(pk) }
            try store.recordPartTransition(
                partkey: pk, from: row.status, to: to, errorCode: to == .failed ? code : nil,
                errorMessage: to == .failed ? "x" : nil)
        }
    }

    /// Session を作り（無ければ）、今の状態から path の順に遷移させる。
    func moveSession(_ key: String, _ path: [SessionStatus], code: ErrorCode = .llmFailed) throws {
        if try store.session(key) == nil {
            try store.insertSession(Builders.session(key: key))
        }
        for to in path {
            guard let row = try store.session(key) else { throw PipelineFixtureError.missingRow(key) }
            try store.recordSessionTransition(
                sessionKey: key, from: row.status, to: to, errorCode: to == .failed ? code : nil,
                errorMessage: to == .failed ? "x" : nil)
        }
    }

    func part(_ pk: String) throws -> RecordingRow {
        guard let row = try store.recording(pk) else { throw PipelineFixtureError.missingRow(pk) }
        return row
    }

    func partEvents(_ pk: String) throws -> [EventRow] { try store.events(entity: .recording, key: pk) }

    /// 全部の events の数（Part と Session の和）。
    func eventCount(parts: [String], sessions: [String] = []) throws -> Int {
        var n = 0
        for pk in parts { n += try store.events(entity: .recording, key: pk).count }
        for key in sessions { n += try store.events(entity: .session, key: key).count }
        return n
    }

    /// event 名を含むログの行。
    func lines(_ event: String) -> [String] {
        sink.lines.filter { $0.contains(" " + event + " ") || $0.hasSuffix(" " + event) }
    }
}

/// 条件が真になるまで 10 ms ずつ待つ（最大 5 秒）。
func waitUntil(_ what: String, _ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PipelineFixtureError.timedOut(what)
}

/// 段の記録（onStage に渡す）。
final class StageRecorder: Sendable {
    private let stages = Mutex<[TickStage]>([])

    func record(_ stage: TickStage) { stages.withLock { $0.append(stage) } }

    var recorded: [TickStage] { stages.withLock { $0 } }

    func count(_ stage: TickStage) -> Int { recorded.filter { $0 == stage }.count }
}
