// AppServices の偽物（T-30。VoiceDockAppTests の中だけ）。read が返す値を差し替え、呼ばれた操作を記録する。
import Foundation
import Synchronization
import VDContract
import VDCore
import VDModels
import VDPipeline

@testable import VoiceDockApp

/// AppServices の偽物。Mutex<State> で持つ（@unchecked Sendable を使わない。PT-14）。
final class FakeServices: AppServices {
    private struct State {
        var snapshot: AppSnapshot
        var reload: ConfigLoadResult = .invalid([])
        var requeueCount = 0
        var reloadCount = 0
        var scanCount = 0
        var lastConnectedSeen: [Instant?] = []
        var continuations: [AsyncStream<Void>.Continuation] = []
        // T-31
        var config = AppConfig.defaults(timeZone: "UTC")
        var updateViolations: [ConfigViolation]?
        var updatedConfigs: [AppConfig] = []
        var downloadProgress: [(Int64, Int64)] = []
        var downloadResult: Result<URL, ModelError> = .success(URL(fileURLWithPath: "/tmp/voicedock-t31-model"))
        var holdCount = 0
        /// 空でなければ download の結果をここから順に取る（尽きたら downloadResult）
        var resultQueue: [Result<URL, ModelError>] = []
        /// download の途中の ID（ModelManager と同じく、同じ ID の 2 本目は内部の文字列で断る）
        var activeIDs: Set<String> = []
        var downloadGates: [AsyncStream<Void>.Continuation] = []
        var downloadEntries: [(ModelKind, ModelEntry)] = []
        var progressSinks: [@Sendable (Int64, Int64) -> Void] = []
        var cancelledIDs: [String] = []
        var importResult: Result<(id: String, url: URL), ModelError> = .failure(.io("unset"))
        var importedSources: [URL] = []
        var registerResult: LoginItemResult = .success
        var unregisterResult: LoginItemResult = .success
        var registerCount = 0
        var unregisterCount = 0
        var openSettingsCount = 0
        var saveResult = true
        var savedStates: [UIState] = []
        // T-32
        var diagnosticsResult: [DiagnosticResult] = []
        var diagnosticsCount = 0
        var holdDiagnostics = false
        var diagnosticsGates: [AsyncStream<Void>.Continuation] = []
        var jobs: [WorkerJob] = []
        var report: StatusReport?
        var statusReportCount = 0
        var openPrivacyCount = 0
    }

    private let state: Mutex<State>

    init(_ snapshot: AppSnapshot) {
        state = Mutex(State(snapshot: snapshot))
    }

    func set(_ snapshot: AppSnapshot) { state.withLock { $0.snapshot = snapshot } }
    func setReload(_ result: ConfigLoadResult) { state.withLock { $0.reload = result } }

    var requeueCount: Int { state.withLock { $0.requeueCount } }
    var reloadCount: Int { state.withLock { $0.reloadCount } }
    var scanCount: Int { state.withLock { $0.scanCount } }
    /// read に渡された値
    var lastConnectedSeen: [Instant?] { state.withLock { $0.lastConnectedSeen } }
    /// read が呼ばれた回数
    var readCount: Int { state.withLock { $0.lastConnectedSeen.count } }

    /// updates() が呼ばれた回数（購読が始まったか）
    var subscriberCount: Int { state.withLock { $0.continuations.count } }

    /// updates() のストリームに 1 件流す
    func push() {
        let continuations = state.withLock { $0.continuations }
        for c in continuations { c.yield(()) }
    }

    func read(lastConnectedAt: Instant?) async -> AppSnapshot {
        state.withLock {
            $0.lastConnectedSeen.append(lastConnectedAt)
            return $0.snapshot
        }
    }

    func requeueManual() async { state.withLock { $0.requeueCount += 1 } }

    func reloadConfig() async -> ConfigLoadResult {
        state.withLock {
            $0.reloadCount += 1
            return $0.reload
        }
    }

    func scanNow() async { state.withLock { $0.scanCount += 1 } }

    // MARK: T-31 の差し替えと記録

    /// updateConfig が違反を返すようにする（nil なら成功）
    func setUpdateViolations(_ v: [ConfigViolation]?) { state.withLock { $0.updateViolations = v } }
    /// updateConfig に渡された変更を既定の設定に当てた結果（呼ばれた順）
    var updatedConfigs: [AppConfig] { state.withLock { $0.updatedConfigs } }
    /// download が結果を返す前に progress へ流す値と、その結果。次の holds 回は releaseDownload まで返さない
    /// （hold: true は holds: 1。止めるのは最初の回だけなので、二重起動の番人が外れてもテストは止まらない）
    func setDownload(progress: [(Int64, Int64)], result: Result<URL, ModelError>, hold: Bool = false, holds: Int = 0) {
        state.withLock {
            $0.downloadProgress = progress
            $0.downloadResult = result
            $0.holdCount = max(holds, hold ? 1 : 0)
        }
    }
    /// download の結果を回ごとに決める（尽きたら setDownload の result）
    func setDownloadResults(_ results: [Result<URL, ModelError>]) { state.withLock { $0.resultQueue = results } }
    /// ModelManager が同じ ID の 2 本目に返す内部の文字列（VDModels の internal な定数の写し。利用者に出てはいけない）
    static let alreadyRunning = "already_downloading"
    /// 止めている download を 1 つ返させる
    func releaseDownload() {
        let gates = state.withLock { s -> [AsyncStream<Void>.Continuation] in
            let g = s.downloadGates
            s.downloadGates = []
            return g
        }
        for g in gates { g.yield(()) }
    }
    /// 止めている download の数
    var heldDownloads: Int { state.withLock { $0.downloadGates.count } }
    var downloadCount: Int { state.withLock { $0.downloadEntries.count } }
    /// download に渡された progress（テストから後で流す）。index を渡せばその回の download の progress だけ
    func emitProgress(_ received: Int64, _ total: Int64, index: Int? = nil) {
        let sinks = state.withLock { $0.progressSinks }
        if let index {
            sinks[index](received, total)
        } else {
            for sink in sinks { sink(received, total) }
        }
    }
    var cancelledIDs: [String] { state.withLock { $0.cancelledIDs } }
    func setImport(_ result: Result<(id: String, url: URL), ModelError>) { state.withLock { $0.importResult = result } }
    var importedSources: [URL] { state.withLock { $0.importedSources } }
    func setRegister(_ result: LoginItemResult) { state.withLock { $0.registerResult = result } }
    var registerCount: Int { state.withLock { $0.registerCount } }
    var unregisterCount: Int { state.withLock { $0.unregisterCount } }
    var openSettingsCount: Int { state.withLock { $0.openSettingsCount } }
    func setSaveResult(_ ok: Bool) { state.withLock { $0.saveResult = ok } }
    var savedStates: [UIState] { state.withLock { $0.savedStates } }

    func updateConfig(_ mutate: @Sendable (inout AppConfig) -> Void) async -> ConfigUpdateResult {
        state.withLock {
            var c = $0.config
            mutate(&c)
            $0.updatedConfigs.append(c)
            if let v = $0.updateViolations { return .failure(v) }
            return .success(c)
        }
    }

    func download(
        kind: ModelKind, entry: ModelEntry, progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Result<URL, ModelError> {
        let started = state.withLock { s -> (events: [(Int64, Int64)], hold: Bool)? in
            s.downloadEntries.append((kind, entry))
            s.progressSinks.append(progress)
            if s.activeIDs.contains(entry.id) { return nil }
            s.activeIDs.insert(entry.id)
            let hold = s.holdCount > 0
            if hold { s.holdCount -= 1 }
            return (s.downloadProgress, hold)
        }
        guard let (events, hold) = started else { return .failure(.io(Self.alreadyRunning)) }
        defer { _ = state.withLock { $0.activeIDs.remove(entry.id) } }
        for (received, total) in events { progress(received, total) }
        if hold {
            let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
            state.withLock { $0.downloadGates.append(continuation) }
            var it = gate.makeAsyncIterator()
            _ = await it.next()
        }
        return state.withLock { $0.resultQueue.isEmpty ? $0.downloadResult : $0.resultQueue.removeFirst() }
    }

    func cancelDownload(id: String) async { state.withLock { $0.cancelledIDs.append(id) } }

    func importGGUF(from source: URL) async -> Result<(id: String, url: URL), ModelError> {
        state.withLock {
            $0.importedSources.append(source)
            return $0.importResult
        }
    }

    func registerLoginItem() -> LoginItemResult {
        state.withLock {
            $0.registerCount += 1
            return $0.registerResult
        }
    }

    func unregisterLoginItem() -> LoginItemResult {
        state.withLock {
            $0.unregisterCount += 1
            return $0.unregisterResult
        }
    }

    func openSystemSettingsLoginItems() { state.withLock { $0.openSettingsCount += 1 } }

    func saveUIState(_ ui: UIState) -> Bool {
        state.withLock {
            $0.savedStates.append(ui)
            return $0.saveResult
        }
    }

    // MARK: T-32 の差し替えと記録

    /// runDiagnostics が返す結果。hold なら releaseDiagnostics まで返さない
    func setDiagnostics(_ results: [DiagnosticResult], hold: Bool = false) {
        state.withLock {
            $0.diagnosticsResult = results
            $0.holdDiagnostics = hold
        }
    }
    func releaseDiagnostics() {
        let gates = state.withLock { s -> [AsyncStream<Void>.Continuation] in
            let g = s.diagnosticsGates
            s.diagnosticsGates = []
            return g
        }
        for g in gates { g.yield(()) }
    }
    var diagnosticsCount: Int { state.withLock { $0.diagnosticsCount } }
    /// enqueue に渡された仕事（入れた順）
    var jobs: [WorkerJob] { state.withLock { $0.jobs } }
    func setStatusReport(_ report: StatusReport) { state.withLock { $0.report = report } }
    var statusReportCount: Int { state.withLock { $0.statusReportCount } }
    var openPrivacyCount: Int { state.withLock { $0.openPrivacyCount } }

    func runDiagnostics() async -> [DiagnosticResult] {
        let hold = state.withLock { s -> Bool in
            s.diagnosticsCount += 1
            return s.holdDiagnostics
        }
        if hold {
            let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
            state.withLock { $0.diagnosticsGates.append(continuation) }
            var it = gate.makeAsyncIterator()
            _ = await it.next()
        }
        return state.withLock { $0.diagnosticsResult }
    }

    func enqueue(_ job: WorkerJob) async { state.withLock { $0.jobs.append(job) } }

    func statusReport() async -> StatusReport {
        state.withLock {
            $0.statusReportCount += 1
            return $0.report ?? Self.emptyReport
        }
    }

    func openSystemSettingsPrivacyFilesAndFolders() { state.withLock { $0.openPrivacyCount += 1 } }

    /// DB も snapshot も無い <HOME> の状態の詳細（存在しないパスを読むだけ。何も作らない）
    static let emptyReport = StatusReporter.build(
        layout: HomeLayout(root: URL(fileURLWithPath: "/nonexistent/voicedock-fake-home", isDirectory: true)),
        config: nil, snapshot: nil, now: Instant(epochMillis: 0), zone: ZonedTime(fixedOffsetSeconds: 0))

    func updates() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        state.withLock { $0.continuations.append(continuation) }
        return stream
    }
}

/// FinderOpening の偽物。渡された URL を順に覚える。
final class FakeFinder: FinderOpening {
    private let urls = Mutex<[URL]>([])

    var revealed: [URL] { urls.withLock { $0 } }

    func reveal(_ url: URL) { urls.withLock { $0.append(url) } }
}

/// FolderChooser の偽物（T-31）。返す URL を差し替え、呼ばれた回数を数える。
final class FakeFolderChooser: FolderChooser {
    private let state: Mutex<(url: URL?, calls: Int)>

    init(_ url: URL?) { state = Mutex((url, 0)) }

    var calls: Int { state.withLock { $0.calls } }

    func chooseFolder(message: String, prompt: String) -> URL? {
        state.withLock {
            $0.calls += 1
            return $0.url
        }
    }
}

/// FileChooser の偽物（T-31）。
final class FakeFileChooser: FileChooser {
    private let state: Mutex<(url: URL?, calls: Int)>

    init(_ url: URL?) { state = Mutex((url, 0)) }

    var calls: Int { state.withLock { $0.calls } }

    func chooseFile(message: String, prompt: String, allowedExtensions: [String]) -> URL? {
        state.withLock {
            $0.calls += 1
            return $0.url
        }
    }
}
