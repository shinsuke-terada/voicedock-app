// 有効化・無効化の舞台（DeletionScene に本物の ConfigStore を足したもの）。
import Darwin
import Foundation
import TestSupport
import VDContract
import VDCore

@testable import VDPipeline

/// **`/Volumes` の下には触れない**（DeletionScene の約束のまま。<HOME> も一時ディレクトリ）。
struct EnablerBench {
    let scene: DeletionScene
    let store: ConfigStore
    let ingest: ScriptedIngest
    let enabler: DeletionEnabler
    let paths: AppPaths
    let verifier: FakeSignatureVerifier
    /// <tmp>/VoiceDock.app/Contents/Helpers/voicedock-reaper（同梱の reaper に見立てた 32 バイトのファイル）
    let bundledReaper: URL

    /// 同梱の reaper に見立てた内容
    static let bundledContent = Data(repeating: 0x2A, count: 32)

    /// 既定は「削除 OFF の初期状態」（reaper 無し・reaper.conf 無し・config は false/false/ro）
    init(enabled: Bool = false, realReaper: Bool = false) async throws {
        // 1. 三重ロックを全部外した状態で作られる
        let scene = try DeletionScene()
        // 2.
        let helpers = scene.tmp.url.appendingPathComponent("VoiceDock.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let paths = AppPaths(resources: PackageRoot.file("Resources"), helpers: helpers)
        let bundledReaper = paths.bundledReaperURL
        try Self.bundledContent.write(to: bundledReaper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bundledReaper.path(percentEncoded: false))
        // 3.
        if !enabled {
            try scene.removeReaper()
            try scene.removeReaperConf()
            scene.updateConfig {
                $0.cleanup.deleteSourceAudio = false
                $0.cleanup.deleteSkippedSource = false
                $0.device.mountMode = "ro"
            }
        }
        // 4.
        try AtomicFile.write(ConfigLoader.encode(scene.config), to: scene.layout.configFile, permissions: 0o644)
        // 5.
        let layout = scene.layout
        let store = ConfigStore(
            layout: layout, catalog: TestCatalogs.minimal, log: scene.log,
            observeReaperConf: { ReaperConf.observe(at: layout.reaperConf) }, defaultTimeZone: { "Asia/Tokyo" })
        _ = await store.load()
        // 6. 台本が尽きたら generation を 1 つ進めた同じ snapshot を返す（無効化の再マウントが通った観測 = 読み取り専用。F-72）
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        await ingest.setScanner { [scene] generation in scene.snapshot(generation: generation, readOnly: true) }
        // 7.
        let verifier = scene.verifier
        // 8.
        let enabler = DeletionEnabler(
            layout: layout, paths: paths, config: store, verifier: verifier, ingest: ingest, log: scene.log)
        // 9. 本物の reaper は舞台の VOLUMES_ROOT（一時ディレクトリ）と組でだけ置く（既定の /Volumes と組み合わせない）
        if realReaper {
            guard case .valid(let conf) = ReaperConf.observe(at: layout.reaperConf),
                conf.volumesRoot != Contract.volumesRoot
            else { throw BenchError("realReaper は舞台の VOLUMES_ROOT を持つ reaper.conf（enabled: true）とだけ組み合わせる") }
            try scene.installRealReaper()
        }
        self.scene = scene
        self.store = store
        self.ingest = ingest
        self.enabler = enabler
        self.paths = paths
        self.verifier = verifier
        self.bundledReaper = bundledReaper
    }

    var layout: HomeLayout { scene.layout }

    func config() async -> AppConfig? {
        await store.current()
    }

    func reaperConf() -> ReaperConfObservation {
        ReaperConf.observe(at: layout.reaperConf)
    }

    func reaperIsInstalled() -> Bool {
        var st = stat()
        return lstat(layout.reaperExecutable.path(percentEncoded: false), &st) == 0
    }

    /// lstat の st_mode & 0o777（通常ファイルでなければ nil）
    func reaperMode() -> mode_t? {
        var st = stat()
        guard lstat(layout.reaperExecutable.path(percentEncoded: false), &st) == 0, (st.st_mode & S_IFMT) == S_IFREG
        else { return nil }
        return st.st_mode & 0o777
    }

    /// bin/.voicedock-reaper.tmp
    func tmpCopyExists() -> Bool {
        var st = stat()
        return lstat(
            layout.binDirectory.appendingPathComponent(".voicedock-reaper.tmp").path(percentEncoded: false), &st)
            == 0
    }

    func logLines() -> [String] {
        scene.logLines
    }

    // MARK: - 準備の部品

    /// queue/delete に中身を読まない要求ファイルを置く
    func placeRequest(_ name: String) throws {
        try Data("{}".utf8).write(to: layout.queueDelete.appendingPathComponent(name))
    }

    /// path にディレクトリを作る（rename・unlink を失敗させる）
    func makeDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func setPermissions(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// 期待値: 舞台の volumesRoot の文字列
    var volumesRootPath: String { scene.volumesRoot.path(percentEncoded: false) }
}

/// 舞台を作れない（組み合わせの誤り）
struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
