// モデルの状態・在否・SHA-256 の照合（PLAN §8.10）。UI（T-31）と診断（T-32）が使う。
import Foundation
import Synchronization
import VDContract
import VDCore

public enum ModelState: Equatable, Sendable {
    case absent
    /// 0.0〜1.0。全体が分からないときは 0.0
    case downloading(Double)
    case present
    /// 利用者に見せる 1 行（ModelError.displayMessage）
    case failed(String)
}

public enum ModelError: Error, Equatable, Sendable {
    case badHost, badFileName, sha256Mismatch, sizeMismatch
    case http(Int)
    case network, cancelled
    case io(String)

    /// ログの reason（付録 A.4）。
    public var logReason: String {
        switch self {
        case .sha256Mismatch: return "sha256_mismatch"
        case .sizeMismatch: return "size_mismatch"
        case .http(let c): return "http_\(c)"
        case .network: return "network"
        case .badHost: return "bad_url"
        case .badFileName: return "bad_file_name"
        case .cancelled: return "cancelled"
        case .io: return "io"
        }
    }

    /// 利用者に見せる 1 行（日本語）。
    public var displayMessage: String {
        switch self {
        case .badHost: return "ダウンロード元の URL が不正です"
        case .badFileName: return "モデルのファイル名が不正です"
        case .sha256Mismatch: return "ダウンロードしたファイルが壊れています（SHA-256 が一致しません）"
        case .sizeMismatch: return "ダウンロードしたファイルが壊れています（サイズが一致しません）"
        case .http(let c): return "ダウンロードに失敗しました（HTTP \(c)）"
        case .network: return "ネットワークに接続できませんでした"
        case .cancelled: return "ダウンロードを中止しました"
        case .io(let d): return "ファイルの読み書きに失敗しました（\(d)）"
        }
    }
}

public actor ModelManager {
    struct Key: Hashable {
        let kind: ModelKind
        let id: String
    }

    /// 進捗（actor の外の URLSession の代理から書かれ、UI のポーリングが読む）。
    final class ProgressBox: Sendable {
        private let value = Mutex<Double>(0.0)

        func set(_ v: Double) { value.withLock { $0 = v } }
        func get() -> Double { value.withLock { $0 } }
    }

    private let layout: HomeLayout
    private let catalog: ModelCatalog
    private let downloader: ModelDownloader
    private let cache: ModelVerificationCache
    private let log: AppLog
    private let hashChunkBytes: Int
    private var downloading: [Key: ProgressBox] = [:]
    private var failures: [Key: ModelError] = [:]
    /// 走っている取り込みの数（F-83。0 のときだけ前回の途中のファイルを消す）
    private var importsInFlight = 0
    /// 走っている「前回の取り込みの残り」の掃除（F-83。終わるまで取り込みは tmp を作らない）
    private var staleCleanup: Task<Int, Never>?

    public init(
        layout: HomeLayout, catalog: ModelCatalog, downloader: ModelDownloader,
        cache: ModelVerificationCache, log: AppLog, hashChunkBytes: Int
    ) {
        self.layout = layout
        self.catalog = catalog
        self.downloader = downloader
        self.cache = cache
        self.log = log
        self.hashChunkBytes = hashChunkBytes
    }

    public func state(kind: ModelKind, id: String) -> ModelState {
        let k = Key(kind: kind, id: id)
        if let box = downloading[k] { return .downloading(box.get()) }
        if let err = failures[k] { return .failed(err.displayMessage) }
        if let e = catalog.entry(kind: kind, id: id) {
            return ModelFiles.isPresent(e, kind: kind, layout: layout) ? .present : .absent
        }
        if kind == .llm, let u = ModelFiles.customLLMURL(id: id, layout: layout) {
            var info = stat()
            guard stat(u.path(percentEncoded: false), &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                info.st_size > 0
            else { return .absent }
            return .present
        }
        return .absent
    }

    public func isPresent(_ e: ModelEntry, kind: ModelKind) -> Bool {
        ModelFiles.isPresent(e, kind: kind, layout: layout)
    }

    public func url(kind: ModelKind, id: String) -> URL? {
        if let e = catalog.entry(kind: kind, id: id) { return ModelFiles.url(kind: kind, entry: e, layout: layout) }
        if kind == .llm { return ModelFiles.customLLMURL(id: id, layout: layout) }
        return nil
    }

    public func verifySHA(kind: ModelKind, id: String) async -> Bool {
        guard let u = url(kind: kind, id: id) else { return false }
        guard let expected = catalog.entry(kind: kind, id: id)?.sha256 ?? CustomModelID.sha256(of: id) else {
            return false
        }
        let path = u.path(percentEncoded: false)
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        let inode = UInt64(info.st_ino)
        let size = Int64(info.st_size)
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        if let s = await cache.verifiedSHA256(path: path, inode: inode, size: size, mtime: mtime) {
            return s == expected
        }
        let c = hashChunkBytes
        guard let sha = try? await BlockingIO.run({ try FileHasher.sha256(of: u, chunkBytes: c) }) else {
            return false
        }
        await cache.record(path: path, inode: inode, size: size, mtime: mtime, sha256: sha)
        return sha == expected
    }

    /// 落として state を動かす（UI はこれだけを呼ぶ）。progress は受け取った値をそのまま渡す。
    public func download(
        _ id: String, kind: ModelKind, progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Result<URL, ModelError> {
        guard let e = catalog.entry(kind: kind, id: id) else { return .failure(.badFileName) }
        let k = Key(kind: kind, id: id)
        guard downloading[k] == nil else { return .failure(.io(ModelDownloader.alreadyRunningMessage)) }
        failures[k] = nil
        let box = ProgressBox()
        downloading[k] = box
        let r = await downloader.download(
            e, kind: kind,
            progress: { written, total in
                box.set(total > 0 ? Double(written) / Double(total) : 0.0)
                progress(written, total)
            })
        if case .failure(let err) = r { failures[k] = err }
        downloading[k] = nil
        return r
    }

    public func cancel(id: String) async {
        await downloader.cancel(id: id)
    }

    /// 利用者の .gguf を取り込む。
    /// F-83: ほかの取り込みが走っていなければ、始める前に前回の途中で残った `.custom-import-*.gguf.part` を消す
    /// （`discardStaleImports` と同じ掃除。掃除が終わるまで tmp を作らないので、走っている取り込みの途中のファイルは消さない）。
    public func importCustomLLM(from source: URL) async -> Result<(id: String, url: URL), ModelError> {
        let l = layout
        let c = hashChunkBytes
        // 数えるのは actor の上で（判定と数え上げの間に await を挟まない）。消すのは BlockingIO の中
        let cleanup = importsInFlight == 0 ? (staleCleanup ?? startStaleCleanup()) : staleCleanup
        importsInFlight += 1
        defer { importsInFlight -= 1 }
        if let cleanup { await finish(cleanup) }
        return (try? await BlockingIO.run { ModelImporter.importGGUF(from: source, layout: l, chunkBytes: c) })
            ?? .failure(.io("blocking_io"))
    }

    /// F-83: 前回の取り込みが途中で終わって残った `models/llm/.custom-import-<16 桁の小文字 16 進>.gguf.part` を消す
    /// （起動時に呼ぶ口。配線は VoiceDockApp の Bootstrap）。取り込みが走っていれば何もせずに 0（その tmp を消さない）。
    /// 数えるのは actor の上、消すのは BlockingIO の中。消えるまで新しい取り込みは tmp を作らない。消した数を返す
    @discardableResult
    public func discardStaleImports() async -> Int {
        guard importsInFlight == 0 else { return 0 }
        return await finish(staleCleanup ?? startStaleCleanup())
    }

    /// 掃除を BlockingIO で始めて覚える（呼び手は actor の上で、importsInFlight が 0 を確かめた直後）
    private func startStaleCleanup() -> Task<Int, Never> {
        let l = layout
        let task = Task { (try? await BlockingIO.run { ModelImporter.discardStaleParts(layout: l) }) ?? 0 }
        staleCleanup = task
        return task
    }

    /// 掃除の終わりを待ち、覚えているのがその掃除なら忘れる
    @discardableResult
    private func finish(_ task: Task<Int, Never>) async -> Int {
        let removed = await task.value
        if staleCleanup == task { staleCleanup = nil }
        return removed
    }

    /// physicalMemoryBytes >= minMemoryGB × 1024³（minMemoryGB が nil なら真）。T-22 のガードと同じ式。
    /// F-83: 式は `ModelMemory.hasEnough` の 1 か所（CR-06。負の値・掛け算のあふれでトラップしない）。
    public nonisolated static func meetsMemory(_ e: ModelEntry, physicalMemoryBytes: UInt64) -> Bool {
        ModelMemory.hasEnough(minMemoryGB: e.minMemoryGB, physicalMemoryBytes: physicalMemoryBytes)
    }
}
