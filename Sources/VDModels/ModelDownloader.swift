// モデルのダウンロード（PLAN §8.10）。URLSession を使う 2 つのファイルのうちの 1 つ（PT-02）。
import Foundation
import Synchronization
import VDContract
import VDCore

/// URLSessionConfiguration を作る口（PLAN §10.1。テストは BlockingURLProtocol を入れた設定を返す）。
public protocol DownloadSessionFactory: Sendable {
    func configuration() -> URLSessionConfiguration
}

/// 本番の設定（Bootstrap だけが作る）。
public struct EphemeralDownloadSessionFactory: DownloadSessionFactory {
    public init() {}

    public func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ModelDownloader.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = ModelDownloader.resourceTimeoutSeconds
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return configuration
    }
}

public actor ModelDownloader {
    /// ダウンロードの合計の上限（秒）。18.6 GB を 1 MB/s で落としても足りる。
    public static let resourceTimeoutSeconds: Double = 86_400
    /// 1 つの応答を待つ上限（秒）。
    public static let requestTimeoutSeconds: Double = 60
    /// 同じ ID を二重に落とそうとしたときの io の語。
    static let alreadyRunningMessage = "already_downloading"

    private let layout: HomeLayout
    private let factory: any DownloadSessionFactory
    private let log: AppLog
    private let hashChunkBytes: Int
    private var running: [String: RunningDownload] = [:]

    /// 実行中の 1 件（止めて再開データを得るのに要るもの。F-83）
    struct RunningDownload {
        let entry: ModelEntry
        let task: URLSessionDownloadTask
        let delegate: ModelDownloadDelegate
    }

    public init(layout: HomeLayout, factory: any DownloadSessionFactory, log: AppLog, hashChunkBytes: Int) {
        self.layout = layout
        self.factory = factory
        self.log = log
        self.hashChunkBytes = hashChunkBytes
    }

    /// 1 件のモデルを落として検査し、models/<kind>/<file> に置く。例外を投げない。
    /// progress は (これまでに書けたバイト数, 全体のバイト数) を何度も呼ぶ（呼ぶ間隔は URLSession に任せる）。
    public func download(
        _ e: ModelEntry, kind: ModelKind,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Result<URL, ModelError> {
        let file = e.file
        let final = ModelFiles.url(kind: kind, entry: e, layout: layout)
        let part = layout.modelPart(kind: kind.rawValue, file: file)
        guard ModelSource.isSafeFileName(file) else { return fail(e, .badFileName) }
        guard let remote = ModelSource.url(e.url, file: file) else { return fail(e, .badHost) }
        if ModelFiles.isPresent(e, kind: kind, layout: layout) { return .success(final) }
        guard running[e.id] == nil else { return .failure(.io(ModelDownloader.alreadyRunningMessage)) }
        // 照合と rename が終わるまで同じ ID の 2 本目を通さない（戻る直前に 1 か所で消す）。
        defer { running[e.id] = nil }
        // F-83: 使える `.resume` は読んだ後も残す（このダウンロードの途中で終了・クラッシュしても、次はそこから再開できる）。
        // 消すのは、落とし終えたとき・HTTP の誤り・新しい再開データが得られずに失敗したとき（saveResume）。
        // 使えない（短い・読めない）`.resume` はここで捨てる
        let resume = ResumeStore.load(e, layout: layout)
        if resume == nil {
            ResumeStore.discard(e, layout: layout)
            removePart(part)
        }
        let delegate = ModelDownloadDelegate(
            partURL: part, layout: layout, expectedBytes: e.bytes, progress: progress)
        let session = URLSession(configuration: factory.configuration(), delegate: delegate, delegateQueue: nil)
        let task =
            resume.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: URLRequest(url: remote))
        running[e.id] = RunningDownload(entry: e, task: task, delegate: delegate)
        task.resume()
        let outcome = await delegate.wait()
        session.finishTasksAndInvalidate()
        switch outcome {
        case .http(let code):
            removePart(part)
            ResumeStore.discard(e, layout: layout)
            return fail(e, .http(code))
        case .failed(.cancelled):
            saveResume(delegate, e)
            return .failure(.cancelled)
        case .failed(let err):
            saveResume(delegate, e)
            return fail(e, err)
        case .finished:
            // F-83: 全体が .part に移った。再開データはもう要らない（.part が照合の前に落ちても、次は最初から落とす）
            ResumeStore.discard(e, layout: layout)
        }
        let size = FileProbeSize.of(part)
        guard size == e.bytes else {
            removePart(part)
            ResumeStore.discard(e, layout: layout)
            return fail(e, .sizeMismatch)
        }
        let p = part
        let c = hashChunkBytes
        guard let sha = try? await BlockingIO.run({ try FileHasher.sha256(of: p, chunkBytes: c) }) else {
            removePart(part)
            ResumeStore.discard(e, layout: layout)
            return fail(e, .io("sha256"))
        }
        guard sha == e.sha256 else {
            removePart(part)
            ResumeStore.discard(e, layout: layout)
            return fail(e, .sha256Mismatch)
        }
        // F-83: 照合した .part をドライブまで書き出してから rename し、親ディレクトリも書き出す（電源断で壊れたモデルが「在る」にならない）
        guard ModelFileSync.syncFile(part) == nil else {
            return fail(e, .io(ModelFileSync.fsyncFailure))
        }
        guard Darwin.rename(part.path(percentEncoded: false), final.path(percentEncoded: false)) == 0 else {
            return fail(e, .io(IOText.errno(errno)))
        }
        ModelFileSync.syncParent(of: final)
        log.info(.modelDownloaded, [(.id, .string(e.id))])
        return .success(final)
    }

    /// 実行中なら止める（再開データが得られれば models/.<file>.resume に残る）。
    public func cancel(id: String) {
        guard let job = running[id] else { return }
        job.task.cancel(byProducingResumeData: { _ in })
    }

    /// F-83: 実行中のダウンロードをすべて止め、得られた再開データを `models/.<file>.resume` に書き終えてから戻る
    /// （アプリの終了の後始末から呼ぶ。次の起動のダウンロードはそこから再開する）。止めた `download` は `.cancelled` を返す。
    /// 再開データが得られなければここでは何も書かない（`.resume` は download の失敗の経路と同じく捨てられる）
    public func stopAllKeepingResumeData() async {
        for (_, job) in running {
            guard let data = await job.task.cancelByProducingResumeData() else { continue }
            // download の側の saveResume が先に走っても後に走っても、この再開データを捨てない
            job.delegate.offerResume(data)
            ResumeStore.save(data, for: job.entry, layout: layout)
        }
    }

    /// 再開データが在れば残し、無ければ古いものを捨てる。
    private func saveResume(_ delegate: ModelDownloadDelegate, _ e: ModelEntry) {
        if let d = delegate.resumeData() {
            ResumeStore.save(d, for: e, layout: layout)
        } else {
            ResumeStore.discard(e, layout: layout)
        }
    }

    /// model_download_failed を出して失敗を返す（.cancelled では呼ばない）。
    private func fail(_ e: ModelEntry, _ err: ModelError) -> Result<URL, ModelError> {
        log.warning(.modelDownloadFailed, [(.id, .string(e.id)), (.reason, .string(err.logReason))])
        return .failure(err)
    }

    /// .part を消す。
    private func removePart(_ part: URL) {
        try? SafeUnlink.remove(part, under: .models, layout: layout, missingOK: true)
    }
}

/// カタログの URL とファイル名の検査。
enum ModelSource {
    static let requiredPrefix = "https://huggingface.co/"
    static let resolveMarker = "/resolve/"
    /// URL のホスト。
    static let host = "huggingface.co"
    /// resolve の直後のコミット SHA の桁数。
    static let commitLength = 40

    /// カタログの url を URL にする。ホスト・resolve/<40hex>/・末尾のファイル名が合わなければ nil（OPS-19 / PT-13 と同じ条件）。
    static func url(_ text: String, file: String) -> URL? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.starts(with: requiredPrefix.unicodeScalars) else { return nil }
        guard isSafeFileName(file) else { return nil }
        let marker = Array(resolveMarker.unicodeScalars)
        guard let start = firstIndex(of: marker, in: scalars) else { return nil }
        let commitStart = start + marker.count
        guard scalars.count > commitStart + commitLength else { return nil }
        let commit = scalars[commitStart..<(commitStart + commitLength)]
        guard commit.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        guard scalars[commitStart + commitLength] == "/" else { return nil }
        let suffix = Array(("/" + file).unicodeScalars)
        guard scalars.count >= suffix.count, scalars.suffix(suffix.count).elementsEqual(suffix) else { return nil }
        guard let url = URL(string: text), url.scheme == "https", url.host() == host else { return nil }
        guard url.query == nil, url.fragment == nil else { return nil }
        guard url.path(percentEncoded: false).hasSuffix("/" + file) else { return nil }
        return url
    }

    /// file が [A-Za-z0-9._-] だけで、空でなく、"." で始まらず、".." を含まない（voicedock fetch-models.sh:38-50）。
    static func isSafeFileName(_ file: String) -> Bool {
        guard !file.isEmpty, !file.hasPrefix("."), !file.contains("..") else { return false }
        return file.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    /// needle が最初に現れる位置。
    private static func firstIndex(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where haystack[i..<(i + needle.count)].elementsEqual(needle) {
            return i
        }
        return nil
    }
}

/// 再開データ。
enum ResumeStore {
    /// これより短い再開データは使わない（途中で切れた .resume で同じ失敗を繰り返さない）。
    static let minimumBytes = 16

    /// models/.<file>.resume（HomeLayout.modelResume）。
    static func url(_ e: ModelEntry, layout: HomeLayout) -> URL {
        layout.modelResume(file: e.file)
    }

    /// 読めて 16 バイト以上なら返す。無い・空・短い・読めないは nil。
    static func load(_ e: ModelEntry, layout: HomeLayout) -> Data? {
        guard let data = try? Data(contentsOf: url(e, layout: layout)), data.count >= minimumBytes else { return nil }
        return data
    }

    /// 0600 で atomic に書く（AtomicFile.write）。失敗は握りつぶす（再開できないだけ）。
    static func save(_ data: Data, for e: ModelEntry, layout: HomeLayout) {
        try? AtomicFile.write(data, to: url(e, layout: layout), permissions: 0o600)
    }

    /// SafeUnlink.remove(…, under: .models, missingOK: true)。失敗は握りつぶす。
    static func discard(_ e: ModelEntry, layout: HomeLayout) {
        try? SafeUnlink.remove(url(e, layout: layout), under: .models, layout: layout, missingOK: true)
    }
}

/// URLSession の代理が伝える結末。
enum DownloadOutcome: Sendable, Equatable {
    /// .part に置けた（HTTP は 2xx）
    case finished
    /// 2xx でない
    case http(Int)
    /// .cancelled / .network / .io
    case failed(ModelError)
}

/// 進捗・完了・再開データを受け取る（NSObject の派生でも Sendable にできる。可変の状態は Mutex で守る。PT-14）。
final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    struct State {
        var moved: DownloadOutcome?
        var resume: Data?
        var result: DownloadOutcome?
        var waiter: CheckedContinuation<DownloadOutcome, Never>?
    }

    private let partURL: URL
    private let layout: HomeLayout
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private let state = Mutex(State())

    init(
        partURL: URL, layout: HomeLayout, expectedBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.partURL = partURL
        self.layout = layout
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    /// 完了を待つ（何度呼んでも同じ結果）。
    func wait() async -> DownloadOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<DownloadOutcome, Never>) in
            let ready: DownloadOutcome? = state.withLock { s in
                if let result = s.result { return result }
                s.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// 得られた再開データ（無ければ nil）。
    func resumeData() -> Data? {
        state.withLock { $0.resume }
    }

    /// F-83: `cancelByProducingResumeData` で得た再開データを渡す（まだ無いときだけ入れる）。
    func offerResume(_ data: Data) {
        state.withLock { s in
            if s.resume == nil { s.resume = data }
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes)
    }

    /// このメソッドから戻ると location は消える。だから同期で移す。
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if status < 200 || status >= 300 {
            state.withLock { $0.moved = .http(status) }
            return
        }
        try? SafeUnlink.remove(partURL, under: .models, layout: layout, missingOK: true)
        let moved: DownloadOutcome
        do {
            try FileManager.default.moveItem(at: location, to: partURL)
            moved = .finished
        } catch {
            moved = .failed(.io(IOText.describe(error)))
        }
        state.withLock { $0.moved = moved }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let u = error as? URLError, let d = u.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            state.withLock { s in
                if s.resume == nil { s.resume = d }
            }
        }
        guard let error else {
            finish(state.withLock { $0.moved } ?? .failed(.network))
            return
        }
        if let u = error as? URLError, u.code == .cancelled {
            finish(.failed(.cancelled))
        } else {
            finish(.failed(.network))
        }
    }

    /// result に入れ、待っている者が在れば 1 回だけ起こす。
    private func finish(_ outcome: DownloadOutcome) {
        let waiter: CheckedContinuation<DownloadOutcome, Never>? = state.withLock { s in
            guard s.result == nil else { return nil }
            s.result = outcome
            let w = s.waiter
            s.waiter = nil
            return w
        }
        waiter?.resume(returning: outcome)
    }
}

/// stat の大きさ。
enum FileProbeSize {
    /// stat して S_ISREG なら st_size、でなければ -1。
    static func of(_ url: URL) -> Int64 {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return -1 }
        return Int64(info.st_size)
    }
}
