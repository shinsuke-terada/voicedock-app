// AppServices の偽物（T-30。VoiceDockAppTests の中だけ）。read が返す値を差し替え、呼ばれた操作を記録する。
import Foundation
import Synchronization
import VDContract
import VDCore
import VDLLM
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
        /// 0 より大きければ、次の read をその数だけ止める（観測とファイルを読んだ後、返す前。F-70 の重なりのテスト）
        var holdReads = 0
        var readGates: [AsyncStream<Void>.Continuation] = []
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
        // F-92
        var promptSources: (bundled: Prompts, saved: PromptOverrides)?
        var promptSourcesCount = 0
        /// 真なら次の updateConfig を releaseUpdate まで返さない（書いている間に窓を閉じるテスト）
        var holdUpdate = false
        var updateGates: [AsyncStream<Void>.Continuation] = []
        // T-32
        var diagnosticsResult: [DiagnosticResult] = []
        var diagnosticsCount = 0
        var holdDiagnostics = false
        var diagnosticsGates: [AsyncStream<Void>.Continuation] = []
        var jobs: [WorkerJob] = []
        var report: StatusReport?
        var statusReportCount = 0
        var openPrivacyCount = 0
        // T-40
        var enableResult: Result<Void, EnableError> = .success(())
        var enableConfirmations: [String] = []
        var skippedConfirmations: [String] = []
        var disableResult: [String] = []
        var disableCount = 0
        var holdDisable = false
        var disableGates: [AsyncStream<Void>.Continuation] = []
        // F-84
        /// 0 より大きければ、次の statusReport をその数だけ止める（返す値は止める前に決まる。重なりのテスト）
        var holdReports = 0
        var reportGates: [AsyncStream<Void>.Continuation] = []
        /// 真なら enableDeletion を releaseEnable まで返さない（閉じた後に終わる有効化のテスト）
        var holdEnable = false
        var enableGates: [AsyncStream<Void>.Continuation] = []
    }

    private let state: Mutex<State>
    /// 与えたら ui-state.json を本物のファイルで持つ（F-70 の再起動のテスト）。
    /// read は LiveServices と同じく、ファイルを読んで uiState に入れ、最終接続を LastConnected.resolve で決める。
    /// saveUIState は savedStates に記録した上で、saveResult が真ならファイルにも書く
    private let uiStore: UIStateStore?

    init(_ snapshot: AppSnapshot, uiStore: UIStateStore? = nil) {
        state = Mutex(State(snapshot: snapshot))
        self.uiStore = uiStore
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
        var (s, hold) = state.withLock { st -> (AppSnapshot, Bool) in
            st.lastConnectedSeen.append(lastConnectedAt)
            let hold = st.holdReads > 0
            if hold { st.holdReads -= 1 }
            return (st.snapshot, hold)
        }
        if let uiStore {
            s.uiState = uiStore.load()
            s.lastConnectedAt = LastConnected.resolve(
                device: s.device, carried: lastConnectedAt, persisted: s.uiState.lastConnectedAt)
        }
        if hold {
            let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
            state.withLock { $0.readGates.append(continuation) }
            var it = gate.makeAsyncIterator()
            _ = await it.next()
        }
        return s
    }

    /// 次の n 回の read を止める（読んだ値は止める前に決まる）
    func holdNextReads(_ n: Int) { state.withLock { $0.holdReads = n } }
    /// 止まっている read の数
    var heldReadCount: Int { state.withLock { $0.readGates.count } }
    /// 止まっている read のうち、いちばん先に止めたものだけを返す（F-84。重なった read の終わる順を決めるテスト）
    func releaseOldestRead() {
        let gate = state.withLock { st -> AsyncStream<Void>.Continuation? in
            st.readGates.isEmpty ? nil : st.readGates.removeFirst()
        }
        gate?.yield(())
        gate?.finish()
    }
    /// 止まっている read をすべて返す
    func releaseReads() {
        let gates = state.withLock { st -> [AsyncStream<Void>.Continuation] in
            defer { st.readGates = [] }
            return st.readGates
        }
        for g in gates {
            g.yield(())
            g.finish()
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

    // MARK: F-92

    /// promptSources が返す値（nil なら読めない）
    func setPromptSources(_ value: (bundled: Prompts, saved: PromptOverrides)?) {
        state.withLock { $0.promptSources = value }
    }
    var promptSourcesCount: Int { state.withLock { $0.promptSourcesCount } }

    func promptSources() async -> (bundled: Prompts, saved: PromptOverrides)? {
        state.withLock {
            $0.promptSourcesCount += 1
            return $0.promptSources
        }
    }

    /// 次の updateConfig を 1 回止める
    func setHoldUpdate() { state.withLock { $0.holdUpdate = true } }
    /// 止めている updateConfig の数
    var heldUpdates: Int { state.withLock { $0.updateGates.count } }
    /// 止めている updateConfig を返させる
    func releaseUpdate() {
        let gates = state.withLock { s -> [AsyncStream<Void>.Continuation] in
            let g = s.updateGates
            s.updateGates = []
            return g
        }
        for g in gates { g.yield(()) }
    }

    func updateConfig(_ mutate: @Sendable (inout AppConfig) -> Void) async -> ConfigUpdateResult {
        let (result, gate) = state.withLock { s -> (ConfigUpdateResult, AsyncStream<Void>?) in
            var c = s.config
            mutate(&c)
            s.updatedConfigs.append(c)
            let result: ConfigUpdateResult = s.updateViolations.map { .failure($0) } ?? .success(c)
            guard s.holdUpdate else { return (result, nil) }
            s.holdUpdate = false
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            s.updateGates.append(continuation)
            return (result, stream)
        }
        if let gate {
            for await _ in gate { break }
        }
        return result
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
        let ok = state.withLock {
            $0.savedStates.append(ui)
            return $0.saveResult
        }
        guard ok, let uiStore else { return ok }
        return uiStore.save(ui)
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
        let (report, hold) = state.withLock { s -> (StatusReport, Bool) in
            s.statusReportCount += 1
            let hold = s.holdReports > 0
            if hold { s.holdReports -= 1 }
            return (s.report ?? Self.emptyReport, hold)
        }
        if hold {
            let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
            state.withLock { $0.reportGates.append(continuation) }
            var it = gate.makeAsyncIterator()
            _ = await it.next()
        }
        return report
    }

    /// 次の n 回の statusReport を止める（F-84）
    func holdNextStatusReports(_ n: Int) { state.withLock { $0.holdReports = n } }
    /// 止まっている statusReport の数
    var heldStatusReportCount: Int { state.withLock { $0.reportGates.count } }
    /// 止まっている statusReport をすべて返す
    func releaseStatusReports() {
        let gates = state.withLock { s -> [AsyncStream<Void>.Continuation] in
            defer { s.reportGates = [] }
            return s.reportGates
        }
        for g in gates {
            g.yield(())
            g.finish()
        }
    }

    func openSystemSettingsPrivacyFilesAndFolders() { state.withLock { $0.openPrivacyCount += 1 } }

    // MARK: T-40 の差し替えと記録

    /// enableDeletion / enableSkippedDeletion が返す結果
    func setEnableResult(_ r: Result<Void, EnableError>) { state.withLock { $0.enableResult = r } }
    /// disableDeletion が返す段の名前
    func setDisableResult(_ stages: [String]) { state.withLock { $0.disableResult = stages } }
    var enableConfirmations: [String] { state.withLock { $0.enableConfirmations } }
    var skippedConfirmations: [String] { state.withLock { $0.skippedConfirmations } }
    var disableCount: Int { state.withLock { $0.disableCount } }
    /// disableDeletion を releaseDisable まで返さない
    func setHoldDisable(_ hold: Bool) { state.withLock { $0.holdDisable = hold } }
    func releaseDisable() {
        let gates = state.withLock { s -> [AsyncStream<Void>.Continuation] in
            let g = s.disableGates
            s.disableGates = []
            return g
        }
        for g in gates { g.yield(()) }
    }

    func enableDeletion(confirmation: String) async -> Result<Void, EnableError> {
        let hold = state.withLock { s -> Bool in
            s.enableConfirmations.append(confirmation)
            return s.holdEnable
        }
        if hold {
            let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
            state.withLock { $0.enableGates.append(continuation) }
            var it = gate.makeAsyncIterator()
            _ = await it.next()
        }
        return state.withLock { $0.enableResult }
    }

    /// enableDeletion を releaseEnable まで返さない（F-84）
    func setHoldEnable(_ hold: Bool) { state.withLock { $0.holdEnable = hold } }
    func releaseEnable() {
        let gates = state.withLock { s -> [AsyncStream<Void>.Continuation] in
            defer { s.enableGates = [] }
            return s.enableGates
        }
        for g in gates {
            g.yield(())
            g.finish()
        }
    }

    func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError> {
        state.withLock {
            $0.skippedConfirmations.append(confirmation)
            return $0.enableResult
        }
    }

    func disableDeletion() async -> [String] {
        let hold = state.withLock { s -> Bool in
            s.disableCount += 1
            return s.holdDisable
        }
        if hold {
            let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
            state.withLock { $0.disableGates.append(continuation) }
            var it = gate.makeAsyncIterator()
            _ = await it.next()
        }
        return state.withLock { $0.disableResult }
    }

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
