// VDPipeline のテストの世界の組み立て（T-18 §6.0。後続チケットが足す）。
import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDLLM
import VDNotes
import VDProcess

@testable import VDPipeline
@testable import VDStore

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
    let chat: FakeChatTransport
    let llm: FakeLLMServer
    let physicalMemoryBytes: UInt64
    let importedKeys: ImportedKeysService

    var deps: WorkerDependencies { deps() }

    /// sleeper・license・ingest を差し替えた依存（省略したものは世界のもの）。
    func deps(
        sleeper: (any Sleeper)? = nil, license: any LicenseGate = AlwaysAllowLicenseGate(),
        ingest: (any IngestPort)? = nil
    ) -> WorkerDependencies {
        let chat = self.chat
        return WorkerDependencies(
            layout: layout, paths: paths, store: store, config: configStore, ingest: ingest ?? self.ingest,
            runner: ProcessRunner(), llama: llm, chatTransportFactory: { _, _ in chat }, clock: clock,
            sleeper: sleeper ?? self.sleeper, log: log, license: license, catalog: TestCatalogs.minimal,
            physicalMemoryBytes: physicalMemoryBytes, importedKeys: importedKeys)
    }

    /// config を設定して ConfigStore に書き、load する（検証を通らなければテストを落とす）。
    /// chat は chatTransportFactory が返す偽物、llm は llama の偽物（T-22 §6.0）。
    static func make(
        configure: (inout AppConfig) -> Void = { _ in }, chat: FakeChatTransport = FakeChatTransport(responses: []),
        llm: FakeLLMServer = FakeLLMServer(), physicalMemoryBytes: UInt64 = 1 << 40
    ) async throws -> PipelineWorld {
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
            clock: clock, sleeper: RecordingSleeper(), sink: sink, log: log, assertion: RecordingSleepAssertion(),
            chat: chat, llm: llm, physicalMemoryBytes: physicalMemoryBytes,
            importedKeys: ImportedKeysService(store: store, config: configStore, log: log))
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

/// 待たずに待ち秒を記録し、limit 回を超えたら CancellationError を投げる Sleeper
/// （工程内リトライが止まらない壊れ方でもテストが終わって落ちるようにする）。
final class LimitedSleeper: Sleeper {
    private let limit: Int
    private let seconds = Mutex<[Int]>([])

    init(limit: Int) {
        self.limit = limit
    }

    func sleep(seconds value: Int) async throws {
        let count = seconds.withLock {
            $0.append(value)
            return $0.count
        }
        if count > limit { throw CancellationError() }
    }

    var recorded: [Int] { seconds.withLock { $0 } }
}

/// 段の記録（onStage に渡す）。
final class StageRecorder: Sendable {
    private let stages = Mutex<[TickStage]>([])

    func record(_ stage: TickStage) { stages.withLock { $0.append(stage) } }

    var recorded: [TickStage] { stages.withLock { $0 } }

    func count(_ stage: TickStage) -> Int { recorded.filter { $0 == stage }.count }
}

// MARK: - LLM と Session の部品（T-22 §6.0）

extension PipelineFixtures {
    /// voicedock test_session_analysis の ANALYSIS（1 行の JSON 文字列）。
    static let analysis =
        #"{"title": "開発の一日", "summary": "削除条件を整理した。", "key_points": ["論理式に落とした"], "#
        + #""tasks": [{"text": "ND テストを書く", "due": null}], "decisions": [], "ideas": [], "tags": ["VoiceDock"]}"#

    /// ANALYSIS を既定の最終形で保存したときの analysis.json（末尾に改行 1 つ）。
    static let analysisFile = """
        {
          "title": "開発の一日",
          "summary": "削除条件を整理した。",
          "key_points": [
            "論理式に落とした"
          ],
          "tasks": [
            {
              "text": "ND テストを書く",
              "due": null
            }
          ],
          "decisions": [],
          "ideas": [],
          "tags": [
            "VoiceDock"
          ]
        }

        """

    /// 既定の Session の鍵
    static let sessionKey = "DJIMIC3:20260912"
}

extension PipelineWorld {
    /// TestCatalogs.minimal の test-llm のファイルを entry.bytes の 0 で置き、llama-server（exit 0 の sh）を 0755 で置き、
    /// llm.modelID = "test-llm" にする。
    func installLLM() async throws {
        for entry in TestCatalogs.minimal.entries(kind: .llm) where entry.id == "test-llm" {
            let url = ModelFiles.url(kind: .llm, entry: entry, layout: layout)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: Int(entry.bytes)).write(to: url)
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: paths.llamaServer)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: paths.llamaServer.path(percentEncoded: false))
        let result = await configStore.update { $0.llm.modelID = "test-llm" }
        guard case .success = result else { throw PipelineFixtureError.invalidConfig("\(result)") }
    }

    /// ISO の started_at（`<yyyy-MM-dd>T<hh:mm:ss>+09:00`）。day は `yyyyMMdd`。
    static func iso(day: String, time: String) -> String {
        let d = Array(day)
        return String(d[0..<4]) + "-" + String(d[4..<6]) + "-" + String(d[6..<8]) + "T" + time + "+09:00"
    }

    /// hour 時ちょうどに始まる 60 秒の Part（voicedock test_session_analysis add_part）。partkey を返す。
    @discardableResult
    func addSessionPart(
        hour: Int, status: PartStatus = .rawSaved, text: String? = "おはようございます。",
        sessionKey: String = PipelineFixtures.sessionKey, day: String = "20260912"
    ) throws -> String {
        let hh = String(format: "%02d", hour)
        return try addTimedPart(
            time: hh + ":00:00", stamp: hh + "0000", status: status,
            segments: text.map { [TranscriptSegment(start: 0.0, end: 3.0, text: $0)] }, sessionKey: sessionKey,
            day: day)
    }

    /// 任意の時刻（hh:mm:ss）に始まる Part。segments が nil なら transcript を書かない。ended が偽なら ended_at は NULL。
    @discardableResult
    func addTimedPart(
        time: String, stamp: String, duration: Double? = 60, ended: Bool = true, status: PartStatus = .rawSaved,
        segments: [TranscriptSegment]?, sessionKey: String? = PipelineFixtures.sessionKey, day: String = "20260912"
    ) throws -> String {
        let folder = "TX_MIC001_\(day)_\(stamp)"
        let relpath = RelPath.join([folder, "TX00_MIC001_\(day)_\(stamp)_orig.wav"])
        let pk = try PartKey.make(deviceID: "DJIMIC3", relpath: relpath)
        let started = Self.iso(day: day, time: time)
        guard let start = PipelineFixtures.zone.parseISO(started),
            let inboxRel = layout.relativePath(of: layout.inboxFile(deviceID: "DJIMIC3", relpath: relpath))
        else { throw PipelineFixtureError.badFixture(started) }
        let endedAt: String? =
            ended ? duration.map { PipelineFixtures.zone.iso(start.adding(milliseconds: Int64($0 * 1000))) } : nil
        try store.insertRecording(
            NewRecording(
                partkey: pk, deviceID: "DJIMIC3", sourceFolder: folder, transmitterID: "TX00", micIndex: 1,
                startedAt: started, durationSeconds: duration, endedAt: endedAt, sourcePath: relpath, sourceSize: 1,
                sourceMtime: 1.0, sha256Helper: String(repeating: "a", count: 64), inboxPath: inboxRel))
        try forcePart(pk, status: status, sessionKey: sessionKey)
        if let segments {
            let text = segments.map(\.text).joined()
            try AtomicFile.write(
                PartTranscriptCodec.encode(
                    PartTranscript(
                        partkey: pk, language: "ja", durationSeconds: duration, startedAt: started, text: text,
                        segments: segments)),
                to: layout.transcript(slug: KeySlug.of(pk)))
        }
        return pk
    }

    /// insertSession → forceSession。
    func addSession(
        key: String = PipelineFixtures.sessionKey, day: String = "2026-09-12", status: SessionStatus,
        regenerated: Int = 0
    ) throws {
        try store.insertSession(NewSession(sessionKey: key, dayDate: day, deviceID: "DJIMIC3"))
        try forceSession(key, status: status, regeneratedCount: regenerated)
    }

    /// 行だけを入れる（inbox のファイルは作らない。voicedock test_session_group part）。partkey を返す。
    @discardableResult
    func registerRow(
        folder: String = "TX_MIC001_20260912_120950", name: String = "TX00_MIC001_20260912_120950_orig.wav",
        started: String = "2026-09-12T12:09:50+09:00", duration: Double? = 1800.0, device: String = "DJIMIC3",
        status: PartStatus = .discovered
    ) throws -> String {
        let relpath = folder.isEmpty ? name : RelPath.join([folder, name])
        let pk = try PartKey.make(deviceID: device, relpath: relpath)
        guard let start = PipelineFixtures.zone.parseISO(started),
            let inboxRel = layout.relativePath(of: layout.inboxFile(deviceID: device, relpath: relpath))
        else { throw PipelineFixtureError.badFixture(started) }
        let endedAt = duration.map { PipelineFixtures.zone.iso(start.adding(milliseconds: Int64($0 * 1000))) }
        try store.insertRecording(
            NewRecording(
                partkey: pk, deviceID: device, sourceFolder: folder, transmitterID: String(name.prefix(4)),
                micIndex: 1, startedAt: started, durationSeconds: duration, endedAt: endedAt, sourcePath: relpath,
                sourceSize: 1, sourceMtime: 1.0, sha256Helper: String(repeating: "a", count: 64), inboxPath: inboxRel))
        if status != .discovered {
            try forcePart(pk, status: status, sessionKey: try part(pk).sessionKey)
        }
        return pk
    }

    /// テストだけの近道（Tests/ は PT-05 の対象外。本番のコードは使わない）。
    func forcePart(_ pk: String, status: PartStatus, sessionKey: String?) throws {
        try store.pool.write { db in
            try db.execute(
                sql: "UPDATE recordings SET status = ?, session_key = ? WHERE partkey = ?",
                arguments: [status.rawValue, sessionKey, pk])
        }
    }

    /// テストだけの近道（Tests/ は PT-05 の対象外。本番のコードは使わない）。
    func forceSession(_ key: String, status: SessionStatus, regeneratedCount: Int = 0) throws {
        try store.pool.write { db in
            try db.execute(
                sql: "UPDATE sessions SET status = ?, regenerated_count = ? WHERE session_key = ?",
                arguments: [status.rawValue, regeneratedCount, key])
        }
    }

    func session(_ key: String = PipelineFixtures.sessionKey) throws -> SessionRow {
        guard let row = try store.session(key) else { throw PipelineFixtureError.missingRow(key) }
        return row
    }

    func sessionEvents(_ key: String = PipelineFixtures.sessionKey) throws -> [EventRow] {
        try store.events(entity: .session, key: key)
    }

    /// ANALYSIS_FILE を置き、fingerprint が nil でなければ .source.json も置く。
    func writeAnalysis(key: String = PipelineFixtures.sessionKey, fingerprint: String?, segments: Int = 1) throws {
        let slug = KeySlug.of(key)
        try AtomicFile.write(Data(PipelineFixtures.analysisFile.utf8), to: layout.analysisJSON(sessionSlug: slug))
        if let fingerprint {
            let source =
                "{\n  \"schema\": 1,\n  \"transcript_sha256\": \"" + fingerprint + "\",\n  \"segments\": "
                + String(segments) + ",\n  \"blocks\": 1\n}\n"
            try AtomicFile.write(Data(source.utf8), to: layout.sourceJSON(sessionSlug: slug))
        }
    }
}

// MARK: - Vault と Part の部品（T-29 §6.0）

extension PipelineFixtures {
    /// Part の組（relpath・started_at・長さ）。
    typealias PartSpec = (relpath: String, startedAt: String, seconds: Double)

    static let partA: PartSpec = (
        relpath: "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
        startedAt: "2026-08-29T07:12:04+09:00", seconds: 2.0
    )
    /// A と違う長さにして SHA を変える（重複にしない）
    static let partB: PartSpec = (
        relpath: "TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav",
        startedAt: "2026-08-29T07:42:10+09:00", seconds: 3.0
    )
    static let partC: PartSpec = (
        relpath: "TX_MIC001_20260829_093000/TX01_MIC002_20260829_093000_orig.wav",
        startedAt: "2026-08-29T09:30:00+09:00", seconds: 2.0
    )
    /// FakeWhisper の既定と同じ
    static let whisperSegments = [
        TranscriptSegment(start: 0.0, end: 3.2, text: "おはようございます。"),
        TranscriptSegment(start: 5.5, end: 9.0, text: "今日の予定を確認します。"),
    ]
    /// Vault のテストの Session の鍵
    static let vaultSessionKey = "DJIMIC3:20260829"
}

extension PipelineWorld {
    /// テストの Vault（TempDirectory の中だけ）。
    var vaultURL: URL { tmp.url.appendingPathComponent("vault", isDirectory: true) }

    /// vault.path に入れる文字列（末尾の "/" なし）。
    var vaultPath: String { tmp.url.appendingPathComponent("vault").path(percentEncoded: false) }

    /// tmp の vault を作り、marker なら .obsidian/ も作る。vault.path を設定する。
    @discardableResult
    func installVault(marker: Bool = true) async throws -> URL {
        let vault = vaultURL
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        if marker {
            try FileManager.default.createDirectory(
                at: vault.appendingPathComponent(".obsidian", isDirectory: true), withIntermediateDirectories: true)
        }
        let path = vaultPath
        let result = await configStore.update { $0.vault.path = path }
        guard case .success = result else { throw PipelineFixtureError.invalidConfig("\(result)") }
        return vault
    }

    /// 行を registerRow と同じ形で入れ（inbox なら BWF も書く）、状態と session_key を強制し、
    /// Session が在れば集計を更新し、segments が nil でなければ transcript を書く。partkey を返す。
    @discardableResult
    func addPart(
        _ spec: PipelineFixtures.PartSpec, status: PartStatus,
        sessionKey: String = PipelineFixtures.vaultSessionKey,
        segments: [TranscriptSegment]? = PipelineFixtures.whisperSegments, inbox: Bool = false
    ) throws -> String {
        let folder = RelPath.parent(spec.relpath)
        let name = URL(fileURLWithPath: spec.relpath).lastPathComponent
        let pk = try registerRow(folder: folder, name: name, started: spec.startedAt, duration: spec.seconds)
        if inbox {
            try BWFWriter.write(
                to: layout.inboxFile(deviceID: "DJIMIC3", relpath: spec.relpath), seconds: spec.seconds,
                format: .pcm24, content: .speech)
        }
        try forcePart(pk, status: status, sessionKey: sessionKey)
        if try store.session(sessionKey) != nil {
            try store.refreshSessionAggregates(sessionKey)
        }
        if let segments {
            try AtomicFile.write(
                PartTranscriptCodec.encode(
                    PartTranscript(
                        partkey: pk, language: "ja", durationSeconds: spec.seconds, startedAt: spec.startedAt,
                        text: segments.map(\.text).joined(), segments: segments)),
                to: layout.transcript(slug: KeySlug.of(pk)))
        }
        return pk
    }

    /// Vault の中のファイルを UTF-8 で読む。
    func noteText(_ relative: String) throws -> String {
        let data = try Data(contentsOf: vaultURL.appendingPathComponent(relative))
        guard let text = String(data: data, encoding: .utf8) else { throw PipelineFixtureError.badFixture(relative) }
        return text
    }
}

// MARK: - 乗り換えの部品（T-33 §5.0）

extension PipelineFixtures {
    /// アプリの DB に入れない鍵（voicedock が書いたノートにだけ在る）
    static let foreignKeyA = "DJIMIC3/TX_MIC001_20260829_060000/TX01_MIC002_20260829_060000_orig.wav"
    static let foreignKeyB = "DJIMIC3/TX_MIC001_20260829_061000/TX01_MIC002_20260829_061000_orig.wav"
}

extension PipelineWorld {
    /// Vault の中に中間ディレクトリごと作って UTF-8 で書く（末尾に改行を足さない。渡した文字列をそのまま）。
    func writeVaultNote(_ relative: String, _ text: String) throws {
        let url = vaultURL.appendingPathComponent(relative, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// voicedock が書いた Raw ノートに見える最小の本文（frontmatter は Frontmatter.render。本文は 1 行）。
    func voicedockRawNote(sessionKey: String = "DJIMIC3:20260829", keys: [String], day: String = "2026-08-29")
        -> String
    {
        Frontmatter.render([
            (Frontmatter.keyType, .string(RawNote.noteType)),
            (Frontmatter.keySessionKey, .string(sessionKey)),
            (Frontmatter.keyRecordingKeys, .array(keys)),
            ("date", .string(day)),
        ]) + "\n# \(day) の記録（voicedock）\n\nこんにちは。\n"
    }
}
