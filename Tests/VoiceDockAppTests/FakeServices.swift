// AppServices の偽物（T-30。VoiceDockAppTests の中だけ）。read が返す値を差し替え、呼ばれた操作を記録する。
import Foundation
import Synchronization
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
        var holdDownload = false
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
    /// download が結果を返す前に progress へ流す値と、その結果。hold なら releaseDownload まで返さない
    func setDownload(progress: [(Int64, Int64)], result: Result<URL, ModelError>, hold: Bool = false) {
        state.withLock {
            $0.downloadProgress = progress
            $0.downloadResult = result
            $0.holdDownload = hold
        }
    }
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
    /// download に渡された progress（テストから後で流す）
    func emitProgress(_ received: Int64, _ total: Int64) {
        let sinks = state.withLock { $0.progressSinks }
        for sink in sinks { sink(received, total) }
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
        let (events, hold) = state.withLock {
            $0.downloadEntries.append((kind, entry))
            $0.progressSinks.append(progress)
            return ($0.downloadProgress, $0.holdDownload)
        }
        for (received, total) in events { progress(received, total) }
        if hold {
            let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
            state.withLock { $0.downloadGates.append(continuation) }
            var it = gate.makeAsyncIterator()
            _ = await it.next()
        }
        return state.withLock { $0.downloadResult }
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
