# T-23 VDModels: モデルのダウンロード・取り込み・状態

| 項目 | 値 |
|---|---|
| ID | T-23 |
| Phase | 5（LLM とモデル） |
| 前提 | T-09（`ModelCatalog`・`ModelEntry`・`ModelKind`・`CustomModelID`・`ModelFiles`・`Resources/ModelCatalog.json`・`TestCatalogs`）、T-10（`FileHasher`・`SafeUnlink`・`AppLog`・`AppClock`・`BlockingIO`・`ModelVerificationCache`）。T-06（`HomeLayout`）はその前提に含まれる。テストの部品 `BlockingURLProtocol` / `BlockingSessionFactory` は T-21 |
| 見積もり | ソース約 480 行、テスト約 620 行、TestSupport 約 170 行 |
| 後続 | T-24（カタログの確定・受け入れ試験）、T-31（「はじめに」のモデルの画面）、T-32（DR-05 / DR-08 が `ModelVerificationCache` を共有する） |

## 1. 目的

モデル（whisper / vad / llm）のダウンロード・利用者のファイルからの取り込み・在否と照合を行う `VDModels` を作る（PLAN §8.10）。

**インターネットに出るのはこのモジュールだけ**で、しかも**利用者がボタンを押したときだけ**（PT-02）。
`URLSessionConfiguration` は**注入されたファクトリ**からしか作らないので、テストは 1 本もネットワークに出ない（PLAN §10.1 TEST-12）。

## 2. 参照

- PLAN §8.10（カタログ・ダウンロード・取り込み・在否・`ModelVerificationCache`）、§2.3（`models/` の配置）、§10.1（URLSession の注入・`BlockingURLProtocol`）、§9.3・§9.4（PT-01 削除・PT-02 ネットワーク・PT-14 `@unchecked Sendable` の禁止）、付録 A.4（`model_downloaded` / `model_download_failed`）、§6.2（`audio.hashChunkBytes` = 1 MiB）
- 00-api-map.md §10（VDModels）、§2.2（`ModelCatalog`・`ModelFiles`）、§2.3（`ModelVerificationCache`・`FileHasher`・`SafeUnlink`）、§15（TestSupport の作り手）
- voicedock@d3d595e `scripts/fetch-models.sh:38-50`（モデル名の検査。`[A-Za-z0-9._-]` だけ・`.` 始まり・`..` を禁止）、`scripts/fetch-models.sh:64-78`（`.part` へ落としてから rename する理由）
- 移植メモ V7 §3（HF の実値。URL は `https://huggingface.co/<repo>/resolve/<40hex>/<file>` の形で固定できる）

## 3. 作るもの

ソース（`Sources/VDModels/`）:

| パス | 中身 |
|---|---|
| `ModelDownloader.swift` | `DownloadSessionFactory`・`EphemeralDownloadSessionFactory`・`ModelDownloader`・（internal）`ModelDownloadDelegate`・`DownloadOutcome`・`ResumeStore`・`ModelSource` |
| `ModelImporter.swift` | `ModelImporter`・（internal）`RandomHex`・`IOText` |
| `ModelManager.swift` | `ModelManager`・`ModelState`・`ModelError` |

テストの部品（`Tests/TestSupport/`）:

| パス | 中身 |
|---|---|
| `ModelHostStub.swift` | `ModelHostReply`・`ModelHostStub`・`ModelHostURLProtocol`・`ModelHostSessionFactory`・`extension BlockingSessionFactory: DownloadSessionFactory`（地図 §15 で本チケットが作るのは `ModelHostStub` / `ModelHostURLProtocol` だけ。`BlockingURLProtocol` / `BlockingSessionFactory` の作り手は T-21 で、ここは `DownloadSessionFactory` 準拠の extension を足すだけ） |

テスト（`Tests/VDModelsTests/`）:

| パス | 中身 |
|---|---|
| `ModelDownloaderTests.swift` | ダウンロードの全経路 |
| `ResumeStoreTests.swift` | 再開データの保存と読み込み |
| `ModelImporterTests.swift` | 取り込み |
| `ModelManagerTests.swift` | 状態・在否・照合 |

`Package.swift` の `VDModels` の依存は T-01 で `VDContract`・`VDCore` になっている（変更しない）。`TestSupport` は既に全モジュールに依存している。

## 4. 仕様

各ファイルの先頭 1 行のコメントは括弧内の文を逐語で書く。

### 4.1 `ModelDownloader.swift`（「// モデルのダウンロード（PLAN §8.10）。URLSession を使う 2 つのファイルのうちの 1 つ（PT-02）。」）

```swift
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
    public init()
    public func configuration() -> URLSessionConfiguration
}

public actor ModelDownloader {
    /// ダウンロードの合計の上限（秒）。18.6 GB を 1 MB/s で落としても足りる。
    public static let resourceTimeoutSeconds: Double = 86_400
    /// 1 つの応答を待つ上限（秒）。
    public static let requestTimeoutSeconds: Double = 60

    public init(layout: HomeLayout, factory: any DownloadSessionFactory, log: AppLog, hashChunkBytes: Int)

    /// 1 件のモデルを落として検査し、models/<kind>/<file> に置く。例外を投げない。
    /// progress は (これまでに書けたバイト数, 全体のバイト数) を何度も呼ぶ（呼ぶ間隔は URLSession に任せる）。
    public func download(
        _ e: ModelEntry, kind: ModelKind,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Result<URL, ModelError>

    /// 実行中なら止める（再開データが得られれば models/.<file>.resume に残る）。
    public func cancel(id: String)
}
```

`EphemeralDownloadSessionFactory.configuration()`: `URLSessionConfiguration.ephemeral` に次を設定して返す（この順）。

| 設定 | 値 | 理由 |
|---|---|---|
| `timeoutIntervalForRequest` | `ModelDownloader.requestTimeoutSeconds` | 無応答で止まらない |
| `timeoutIntervalForResource` | `ModelDownloader.resourceTimeoutSeconds` | 18.6 GB を落とせる |
| `waitsForConnectivity` | `false` | 圏外なら待たずに失敗する（利用者がボタンを押した文脈） |
| `httpMaximumConnectionsPerHost` | `1` | HF に並行に投げない |
| `httpShouldSetCookies` | `false` | 何も持ち回らない |
| `httpCookieAcceptPolicy` | `.never` | 同上 |
| `urlCache` | `nil` | 18.6 GB をキャッシュに複製しない |

#### 4.1.1 `ModelSource`（internal。URL の検査）

```swift
enum ModelSource {
    static let requiredPrefix = "https://huggingface.co/"
    static let resolveMarker = "/resolve/"
    /// カタログの url を URL にする。ホスト・resolve/<40hex>/・末尾のファイル名が合わなければ nil（OPS-19 / PT-13 と同じ条件）。
    static func url(_ text: String, file: String) -> URL?
    /// file が [A-Za-z0-9._-] だけで、空でなく、"." で始まらず、".." を含まない（voicedock fetch-models.sh:38-50）。
    static func isSafeFileName(_ file: String) -> Bool
}
```

`url(_:file:)` の手順（最初に外れたら nil）:
1. `text` のスカラー列が `requiredPrefix` で始まる
2. `isSafeFileName(file)` が真
3. `text` に `resolveMarker` が現れる（**最初の出現**をとる）。その直後の 40 スカラーがすべて `0-9a-f`、41 番目が `/`
4. `text` のスカラー列が `"/" + file` で終わる
5. `URL(string: text)` が nil でなく、`scheme == "https"`、`host() == "huggingface.co"` → その URL

（`URL(string:)` の禁止は `VDLLM/LoopbackHTTP.swift` の中だけ。VDModels では使ってよい。PT-02）

#### 4.1.2 `ResumeStore`（internal。再開データ）

```swift
enum ResumeStore {
    /// models/.<file>.resume（HomeLayout.modelResume）。
    static func url(_ e: ModelEntry, layout: HomeLayout) -> URL
    /// 読めて 16 バイト以上なら返す。無い・空・短い・読めないは nil。
    static func load(_ e: ModelEntry, layout: HomeLayout) -> Data?
    /// 0600 で atomic に書く（AtomicFile.write）。失敗は握りつぶす（再開できないだけ）。
    static func save(_ data: Data, for e: ModelEntry, layout: HomeLayout)
    /// SafeUnlink.remove(…, under: .models, missingOK: true)。失敗は握りつぶす。
    static func discard(_ e: ModelEntry, layout: HomeLayout)
}
```
- 16 バイト未満を捨てるのは、途中で切れた `.resume` を URLSession に渡すと毎回同じ失敗を繰り返すため
- **削除は `SafeUnlink` だけ**（`FileManager.removeItem` は禁止。PT-01）

#### 4.1.3 `ModelDownloadDelegate`（internal。URLSession の代理）

```swift
enum DownloadOutcome: Sendable, Equatable {
    case finished            // .part に置けた（HTTP は 2xx）
    case http(Int)           // 2xx でない
    case failed(ModelError)  // .cancelled / .network / .io
}

/// 進捗・完了・再開データを受け取る（NSObject の派生でも Sendable にできる。可変の状態は Mutex で守る。PT-14）。
final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    init(partURL: URL, layout: HomeLayout, expectedBytes: Int64,
         progress: @escaping @Sendable (Int64, Int64) -> Void)
    /// 完了を待つ（何度呼んでも同じ結果）。
    func wait() async -> DownloadOutcome
    /// 得られた再開データ（無ければ nil）。
    func resumeData() -> Data?
}
```

内部の状態は `Mutex<State>`（`import Synchronization`）で持つ。`State { var moved: DownloadOutcome?; var resume: Data?; var result: DownloadOutcome?; var waiter: CheckedContinuation<DownloadOutcome, Never>? }`。

代理のメソッド（この 3 つだけを実装する）:

1. `urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)`
   `progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes)`
   （再開したときの `totalBytesWritten` は再開分を含む。全体が不明なら `-1` が来るのでカタログの `bytes` を渡す）
2. `urlSession(_:downloadTask:didFinishDownloadingTo location:)`（**このメソッドから戻ると `location` は消える。だから同期で移す**）
   1. `status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0`
   2. `status < 200 || status >= 300` → `moved = .http(status)` で戻る（`location` に触らない）
   3. `try? SafeUnlink.remove(partURL, under: .models, layout: layout, missingOK: true)`（前回の `.part` を消す）
   4. `do { try FileManager.default.moveItem(at: location, to: partURL); moved = .finished }`
      `catch { moved = .failed(.io(IOText.describe(error))) }`
3. `urlSession(_:task:didCompleteWithError error:)`
   1. `if let u = error as? URLError, let d = u.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resume = d }`
      （`cancel(byProducingResumeData:)` の結果はここにも入る。両方来たときは先に入れたものを残す）
   2. `error` が nil → `finish(moved ?? .failed(.network))`
   3. `error` が `URLError` で `code == .cancelled` → `finish(.failed(.cancelled))`
   4. それ以外 → `finish(.failed(.network))`
   - `finish(_:)` は `result` に入れ、`waiter` が在れば `resume(returning:)` する（1 回だけ）

`wait()`: `result` が在ればそれを返す。無ければ `withCheckedContinuation` で `waiter` に入れて待つ。

#### 4.1.4 `download(_:kind:progress:)` の手順

`file = e.file`、`final = ModelFiles.url(kind: kind, entry: e, layout: layout)`、`part = layout.modelPart(kind: kind.rawValue, file: file)`。

1. `guard ModelSource.isSafeFileName(file) else { return fail(e, .badFileName) }`
2. `guard let remote = ModelSource.url(e.url, file: file) else { return fail(e, .badHost) }`
3. **既に在る**: `ModelFiles.isPresent(e, kind: kind, layout: layout)` が真 → `.success(final)`（ログを出さない。ネットワークに出ない）
4. `guard running[e.id] == nil else { return .failure(.io(ModelDownloader.alreadyRunningMessage)) }`
5. 再開データ: `resume = ResumeStore.load(e, layout: layout)`。`ResumeStore.discard(e, layout: layout)`（**読んだら必ず消す。1 回きり**）
6. `resume == nil` なら `try? SafeUnlink.remove(part, under: .models, layout: layout, missingOK: true)`（古い `.part` を捨てる）
7. `delegate = ModelDownloadDelegate(partURL: part, layout: layout, expectedBytes: e.bytes, progress: progress)`
   `session = URLSession(configuration: factory.configuration(), delegate: delegate, delegateQueue: nil)`
8. `task = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: URLRequest(url: remote))`
   `running[e.id] = task`、`task.resume()`
9. `outcome = await delegate.wait()`、`running[e.id] = nil`、`session.finishTasksAndInvalidate()`
10. `outcome` ごとに:
    - `.http(let code)` → `.part` を消す・`ResumeStore.discard` → `fail(e, .http(code))`
    - `.failed(.cancelled)` → `saveResume(delegate, e)` → `.failure(.cancelled)`（**ログを出さない**。利用者の操作）
    - `.failed(let err)`（`.network` / `.io`）→ `saveResume(delegate, e)` → `fail(e, err)`
    - `.finished` → 11 へ
11. **サイズの照合**: `size = FileProbeSize.of(part)`（`stat` の `st_size`。取れなければ `-1`）。`size != e.bytes` → `.part` を消す・`ResumeStore.discard` → `fail(e, .sizeMismatch)`
12. **SHA-256 の照合**（ストリーム。`hashChunkBytes` ずつ）:
    `let p = part, c = hashChunkBytes`
    `guard let sha = try? await BlockingIO.run({ try FileHasher.sha256(of: p, chunkBytes: c) }) else { … fail(e, .io("sha256")) }`
    `sha != e.sha256` → `.part` を消す・`ResumeStore.discard` → `fail(e, .sha256Mismatch)`
13. `rename(part, final)`: `Darwin.rename(part.path(percentEncoded: false), final.path(percentEncoded: false))` が `0` でなければ `fail(e, .io(IOText.errno(errno)))`（`.part` は残す。再実行で消える）
14. `ResumeStore.discard(e, layout: layout)`、`log.info(.modelDownloaded, [(.id, .string(e.id))])`、`.success(final)`

- `saveResume(_:_:)`: `delegate.resumeData()` が在れば `ResumeStore.save(d, for: e, layout: layout)`、無ければ `ResumeStore.discard(e, layout: layout)`
- `fail(_ e: ModelEntry, _ err: ModelError) -> Result<URL, ModelError>`: `log.warning(.modelDownloadFailed, [(.id, .string(e.id)), (.reason, .string(err.logReason))])` して `.failure(err)`
- `.part` を消す = `try? SafeUnlink.remove(part, under: .models, layout: layout, missingOK: true)`
- `alreadyRunningMessage = "already_downloading"`（`static let`）
- `FileProbeSize`（internal）: `stat` して `S_ISREG` なら `st_size`、でなければ `-1`

`cancel(id:)`: `guard let task = running[id] else { return }`、`task.cancel(byProducingResumeData: { _ in })`
（再開データは `didCompleteWithError` の `error.userInfo` から取る。同じものが両方に来る）

### 4.2 `ModelImporter.swift`（「// 利用者の .gguf を models/llm へ読みながら取り込む（PLAN §8.10「ファイルから読み込む」）。」）

```swift
public enum ModelImporter {
    /// source を読みながら SHA-256 を計算して models/llm/.custom-import-<16 hex>.gguf.part へ複製し、
    /// custom-<sha256 の先頭 16>.gguf へ rename する。既に在ればそれを使う。例外を投げない。
    public static func importGGUF(from source: URL, layout: HomeLayout, chunkBytes: Int)
        -> Result<(id: String, url: URL), ModelError>
}
```

手順:
1. `chunkBytes < 4096` → `.failure(.io("chunk_bytes"))`（CV-58 が 4096 以上を保証するが、直接呼ばれても壊れないように）
2. `lstat(source)`: 失敗 → `.failure(.io(IOText.errno(errno)))`。`S_ISREG` でない（symlink・ディレクトリ）→ `.failure(.io("not_a_regular_file"))`
3. `tmpName = "custom-import-" + RandomHex.hex16() + ".gguf"`、`tmp = layout.modelPart(kind: ModelKind.llm.rawValue, file: tmpName)`
   （= `models/llm/.custom-import-<16 hex>.gguf.part`）
4. 読み書き（**1 回しか読まない**）:
   - `guard let input = try? FileHandle(forReadingFrom: source)`（開けなければ `.io("read")`）。`defer { try? input.close() }`
   - `FileManager.default.createFile(atPath: tmp.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o644])` が偽 → `.failure(.io("create"))`
   - `guard let output = try? FileHandle(forWritingTo: tmp)`（開けなければ `.io("create")`）。`defer { try? output.close() }`
   - `var hasher = SHA256()`（`import CryptoKit`）
   - `while let d = try? input.read(upToCount: chunkBytes), !d.isEmpty { hasher.update(data: d); try? output.write(contentsOf: d) }`
     **読みと書きの失敗は握りつぶさない**: `read` が投げたら `.io("read")`、`write` が投げたら `.io("write")` にして 7 へ（`do/catch` で書く。上の擬似コードは流れだけ）
   - `try? output.synchronize()`
   - `sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()`
5. `final = layout.modelFile(kind: ModelKind.llm.rawValue, file: CustomModelID.fileName(sha256: sha))`
6. `final` が通常ファイルとして在る（`stat` して `S_ISREG`）→ `tmp` を消して `.success((CustomModelID.make(sha256: sha), final))`（**既存を使う**）
7. そうでなければ `Darwin.rename(tmp, final)`。`0` でなければ `tmp` を消して `.failure(.io(IOText.errno(errno)))`
8. `.success((CustomModelID.make(sha256: sha), final))`
- 失敗の経路ではすべて `tmp` を `SafeUnlink.remove(tmp, under: .models, layout: layout, missingOK: true)` で消す（`.part` を残さない）
- ログは出さない（取り込みは UI が結果を出す。A.4 に取り込みのイベントは無い）

```swift
enum RandomHex {
    /// SystemRandomNumberGenerator の 8 バイトを小文字 16 進 16 桁に。
    static func hex16() -> String
}
enum IOText {
    /// strerror の文字列（"No such file or directory" など）。
    static func errno(_ code: Int32) -> String
    /// Error から 1 行（NSError なら domain + code、それ以外は型の名前）。本文を混ぜない。
    static func describe(_ e: any Error) -> String
}
```
`IOText.describe`: `let n = e as NSError; return "\(n.domain) \(n.code)"`（利用者の文言は `ModelError.displayMessage` が作る。ここは機械の語だけ）

### 4.3 `ModelManager.swift`（「// モデルの状態・在否・SHA-256 の照合（PLAN §8.10）。UI（T-31）と診断（T-32）が使う。」）

```swift
public enum ModelState: Equatable, Sendable {
    case absent
    case downloading(Double)   // 0.0〜1.0。全体が分からないときは 0.0
    case present
    case failed(String)        // 利用者に見せる 1 行（ModelError.displayMessage）
}

public enum ModelError: Error, Equatable, Sendable {
    case badHost, badFileName, sha256Mismatch, sizeMismatch
    case http(Int)
    case network, cancelled
    case io(String)

    /// ログの reason（付録 A.4）。
    public var logReason: String
    /// 利用者に見せる 1 行（日本語）。
    public var displayMessage: String
}

public actor ModelManager {
    public init(layout: HomeLayout, catalog: ModelCatalog, downloader: ModelDownloader,
                cache: ModelVerificationCache, log: AppLog, hashChunkBytes: Int)

    public func state(kind: ModelKind, id: String) -> ModelState
    public func isPresent(_ e: ModelEntry, kind: ModelKind) -> Bool
    public func url(kind: ModelKind, id: String) -> URL?
    public func verifySHA(kind: ModelKind, id: String) async -> Bool
    /// 落として state を動かす（UI はこれだけを呼ぶ）。progress は受け取った値をそのまま渡す。
    public func download(
        _ id: String, kind: ModelKind, progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Result<URL, ModelError>
    public func cancel(id: String) async
    /// 利用者の .gguf を取り込む。
    public func importCustomLLM(from source: URL) async -> Result<(id: String, url: URL), ModelError>
    /// physicalMemoryBytes >= minMemoryGB × 1024³（minMemoryGB が nil なら真）。T-22 のガードと同じ式。
    public nonisolated static func meetsMemory(_ e: ModelEntry, physicalMemoryBytes: UInt64) -> Bool
}
```

`logReason`（逐語。**付録 A.4 の `model_download_failed` の `reason` の語**: `sha256_mismatch|size_mismatch|http_<code>|network|cancelled|bad_url|bad_file_name|io`。下の 8 行がその全部）:

| case | `logReason` |
|---|---|
| `.sha256Mismatch` | `sha256_mismatch` |
| `.sizeMismatch` | `size_mismatch` |
| `.http(let c)` | `http_<c>` |
| `.network` | `network` |
| `.badHost` | `bad_url` |
| `.badFileName` | `bad_file_name` |
| `.cancelled` | `cancelled` |
| `.io` | `io` |

`logReason` は全 case を網羅する全域関数なので `cancelled` も持つが、**この語がログに出ることは無い**（キャンセルは `model_download_failed` を出さない。`cancelStopsAndDoesNotLog`）。付録 A.4 に語が載っているのは「`logReason` の値の集合 = A.4 の語の集合」を固定するためで、消してはならない。

`displayMessage`（逐語。UI にそのまま出す）:

| case | 文言 |
|---|---|
| `.badHost` | `ダウンロード元の URL が不正です` |
| `.badFileName` | `モデルのファイル名が不正です` |
| `.sha256Mismatch` | `ダウンロードしたファイルが壊れています（SHA-256 が一致しません）` |
| `.sizeMismatch` | `ダウンロードしたファイルが壊れています（サイズが一致しません）` |
| `.http(let c)` | `ダウンロードに失敗しました（HTTP <c>）` |
| `.network` | `ネットワークに接続できませんでした` |
| `.cancelled` | `ダウンロードを中止しました` |
| `.io(let d)` | `ファイルの読み書きに失敗しました（<d>）` |

状態（actor の中）: `var downloading: [Key: Double]`、`var failures: [Key: ModelError]`。`Key` は `struct Key: Hashable { let kind: ModelKind; let id: String }`（internal）。

- `state(kind:id:)`:
  1. `downloading[k]` が在れば `.downloading(その値)`
  2. `failures[k]` が在れば `.failed(err.displayMessage)`
  3. `catalog.entry(kind: kind, id: id)` が在れば `ModelFiles.isPresent(…) ? .present : .absent`
  4. `kind == .llm` かつ `ModelFiles.customLLMURL(id: id, layout: layout)` が在れば、通常ファイルで `st_size > 0` なら `.present`、でなければ `.absent`
  5. それ以外 → `.absent`
- `isPresent(_:kind:)` = `ModelFiles.isPresent(e, kind: kind, layout: layout)`（**在否の判定は 1 か所**。CR-06）
- `url(kind:id:)` = カタログに在れば `ModelFiles.url(kind:entry:layout:)`、無ければ `kind == .llm` のとき `ModelFiles.customLLMURL(id:layout:)`、それ以外 nil
- `download(_:kind:progress:)`（名前と引数は 00-api-map §10 が正）:
  1. `guard let e = catalog.entry(kind: kind, id: id) else { return .failure(.badFileName) }`
  2. `failures[k] = nil`、`downloading[k] = 0.0`
  3. `let box = ProgressBox()`（`final class ProgressBox: Sendable` で `Mutex<Double>` を持つ。進捗のクロージャは actor の外から呼ばれるため）
     `r = await downloader.download(e, kind: kind, progress: { written, total in box.set(total > 0 ? Double(written) / Double(total) : 0.0); progress(written, total) })`
     **進捗は UI がポーリングで読む**（`state(kind:id:)` が `downloading[k]` の代わりに `box` の値を読む）。`downloading[k]` は `box` を指す辞書 `[Key: ProgressBox]` にする
  4. 戻りが `.failure(let err)` なら `failures[k] = err`。`downloading[k] = nil`
  5. そのまま返す
- `cancel(id:)`（00-api-map §10 が正）: `await downloader.cancel(id: id)` を呼ぶための `Task` を作らず、`cancel` を `async` にしてそのまま `await` する（actor 間の呼び出し）
- `importCustomLLM(from:)`: `let l = layout, c = hashChunkBytes`。`(try? await BlockingIO.run { ModelImporter.importGGUF(from: source, layout: l, chunkBytes: c) }) ?? .failure(.io("blocking_io"))`
- `verifySHA(kind:id:)`:
  1. `guard let u = url(kind: kind, id: id) else { return false }`
  2. 期待値 `expected`: カタログに在れば `entry.sha256`、無ければ `CustomModelID.sha256(of: id)`。どちらも無ければ `false`
  3. `stat(u)` が失敗、または `S_ISREG` でなければ `false`。`inode = st_ino`、`size = st_size`、`mtime = Double(st_mtimespec.tv_sec) + Double(st_mtimespec.tv_nsec) / 1_000_000_000`
  4. `if let s = await cache.verifiedSHA256(path: path, inode: inode, size: size, mtime: mtime) { return s == expected }`（**照合を飛ばす**。18.6 GB で数十秒かかる）
  5. `guard let sha = try? await BlockingIO.run({ try FileHasher.sha256(of: u, chunkBytes: c) }) else { return false }`
  6. `await cache.record(path: path, inode: inode, size: size, mtime: mtime, sha256: sha)`（**一致しなくても記録する**。実際の値だから。診断が同じ値を使い回せる）
  7. `return sha == expected`
- `path` は `u.path(percentEncoded: false)`（00-api-map §0）
- `meetsMemory(_:physicalMemoryBytes:)`: `guard let gb = e.minMemoryGB else { return true }`、`physicalMemoryBytes >= UInt64(gb) * 1_073_741_824`（T-22 §4.3 のガードと同じ式・同じ定数。**式を 2 か所に書かない**ため、T-22 のガードは VDPipeline に在るままにし、ここは UI 用の同じ式を `static` で置く。CR-06 の例外として本チケットの受け入れ条件に「両者の値が 1_073_741_824 で一致する」ことを書く）

### 4.4 ログ

| イベント | レベル | フィールド | いつ |
|---|---|---|---|
| `model_downloaded` | INFO | `id` | rename まで終わったとき（§4.1.4 の 14） |
| `model_download_failed` | WARNING | `id`, `reason` | `.cancelled` 以外の失敗（§4.1.4 の `fail`） |

- `reason` の語は §4.3 の表のとおり。**新しい語を足すときは付録 A.4 にも足す**（§8 の提案 4）
- 取り込み（`ModelImporter`）と照合（`verifySHA`）はログを出さない（UI と診断が結果を出す）

### 4.5 `Tests/TestSupport/ModelHostStub.swift`

```swift
import Foundation
import Synchronization
import VDModels

public enum ModelHostReply: Sendable {
    case body(Data)                             // 200 で全部返す
    case http(status: Int, body: Data)
    case failure(URLError.Code)
    case truncated(Data, URLError.Code)         // 途中まで返してから失敗する
}

/// 絶対 URL ごとに応答を決める（**ネットワークには決して出ない**）。テストごとに register / unregister する。
public enum ModelHostStub {
    public static func register(url: String, _ reply: @escaping @Sendable () -> ModelHostReply)
    public static func unregister(url: String)
    /// その URL に来た要求の数。
    public static func requests(url: String) -> Int
    public static func reset()
}

public final class ModelHostURLProtocol: URLProtocol {
    // canInit: 常に true。canonicalRequest: そのまま。
    // startLoading: request.url の absoluteString で登録を引く。
    //   無ければ URLError(.notConnectedToInternet)（BlockingURLProtocol と同じ）
    //   .body(d)      → HTTPURLResponse(status 200, "Content-Length": "<d.count>") → 64 KiB ずつ didLoad → didFinishLoading
    //   .http(s, d)   → HTTPURLResponse(status s) → didLoad(d) → didFinishLoading
    //   .failure(c)   → didFailWithError(URLError(c))
    //   .truncated(d, c) → 200 の応答 → didLoad(d) → didFailWithError(URLError(c))
    // stopLoading: 何もしない
}

public struct ModelHostSessionFactory: DownloadSessionFactory {
    public init()
    /// .ephemeral に protocolClasses = [ModelHostURLProtocol.self]
    public func configuration() -> URLSessionConfiguration
}

/// T-21 の BlockingSessionFactory をダウンロードにも使えるようにする（中身は空。configuration() は既に在る）。
extension BlockingSessionFactory: DownloadSessionFactory {}
```
- 登録の表と件数は `Mutex` で守る（`@unchecked Sendable` と `nonisolated(unsafe)` を使わない）
- `ModelHostStub` / `ModelHostURLProtocol`（と同じファイルの `ModelHostReply` / `ModelHostSessionFactory`）の作り手は本チケット（00-api-map §15 に反映済み）。`BlockingURLProtocol` / `BlockingSessionFactory` は **T-21 のものを使うだけ**（ここは extension を足すだけ）

## 5. テスト

すべて `import Testing`、`@testable import VDModels`、`import VDCore`、`import VDContract`、`import TestSupport`。
`ModelEntry` を直に作るファイル（`ModelDownloaderTests` / `ResumeStoreTests` / `ModelManagerTests`）は `ModelEntry` の memberwise init が internal なので `@testable import VDCore` にする（公開 API は足さない）。
各テストは `TempDirectory()` を作り `HomeLayout(root:)` の `createDirectories()` を呼ぶ。`log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: ZonedTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!), clock: FixedClock(epochMillis: 1_756_000_000_000))`。

共通の準備（各スイートの `private func world()` に置く）:
```swift
let tmp = try TempDirectory()
let layout = HomeLayout(root: tmp.url); try layout.createDirectories()
let sink = CapturingLogSink()
let entry = ModelEntry(id: "test-whisper", displayName: "T", file: "ggml-t.bin",
                       url: "https://huggingface.co/a/b/resolve/\(String(repeating: "0", count: 40))/ggml-t.bin",
                       sha256: FileHasher.sha256(payload), bytes: Int64(payload.count),
                       license: "MIT", minMemoryGB: nil, verified: nil)
```
`payload` は `Data((0..<3_000_000).map { UInt8($0 % 251) })`（3 MB。`hashChunkBytes = 1_048_576` で 3 回に分けて読む）。
**期待する sha256 は `FileHasher.sha256(payload)`（T-10 の別の関数）から得る**。ダウンローダの実装を呼んで作らない（TEST-01）。

### 5.1 `ModelDownloaderTests.swift`（`@Suite("ModelDownloader")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `downloadsAndVerifies` / 「落として SHA とサイズを照合して置く」 | `ModelHostStub.register(url: entry.url) { .body(payload) }` | `.success(models/whisper/ggml-t.bin)`、中身が `payload`、`.part` と `.resume` が無い、ログに `model_downloaded id=test-whisper` が 1 行 |
| `progressReachesTheTotal` / 「進捗は最後に全体と一致する」 | 同上、進捗を配列に集める | 最後の要素が `(payload.count, payload.count)`、単調非減少 |
| `shaMismatchRemovesThePart` / 「SHA が違えば .part を消して失敗」 | `entry.sha256` を `"b" × 64` に差し替え | `.failure(.sha256Mismatch)`、`models/whisper/` が空、`model_download_failed id=test-whisper reason=sha256_mismatch` |
| `sizeMismatchIsDetectedBeforeHashing` / 「サイズ違いは SHA より先に落とす」 | `entry.bytes` を `payload.count + 1` に | `.failure(.sizeMismatch)`、`reason=size_mismatch`、`.part` が無い |
| `httpErrorIsReported` / 「2xx でなければ http_<code>」 | `.http(status: 404, body: Data("no".utf8))` | `.failure(.http(404))`、`reason=http_404`、`.part` が無い |
| `networkFailureIsReported` / 「接続できなければ network」 | `.failure(.cannotConnectToHost)` | `.failure(.network)`、`reason=network` |
| `blockedFactoryNeverLeavesTheMachine` / 「BlockingURLProtocol では必ず失敗する（TEST-12）」 | `factory = BlockingSessionFactory()`（実在の HF の URL を使う） | `.failure(.network)`、`.part` が無い |
| `badHostIsRejectedBeforeAnyRequest` / 「ホストが違えば要求を出さない」 | `entry.url = "https://example.com/x/y/resolve/<40hex>/ggml-t.bin"` | `.failure(.badHost)`、`ModelHostStub.requests(url:) == 0`、`reason=bad_url` |
| `mainInsteadOfCommitIsRejected` / 「resolve/main は受けない（PT-13 と同じ条件）」 | url の `<40hex>` を `main` に | `.failure(.badHost)`、要求 0 件 |
| `fileNameMismatchIsRejected` / 「url の末尾がファイル名と違えば受けない」 | url の末尾を `other.bin` に | `.failure(.badHost)`、要求 0 件 |
| `unsafeFileNameIsRejected` / 「`..` を含むファイル名は受けない（OPS-19）」 | `file = "../x.bin"`（url も合わせる） | `.failure(.badFileName)`、要求 0 件 |
| `presentFileSkipsTheNetwork` / 「在って size が一致すれば落とさない」 | `models/whisper/ggml-t.bin` に `payload` を置く | `.success`、要求 0 件、`model_downloaded` を出さない |
| `staleResumeIsRemovedWhenUnused` / 「使わない `.resume` は消える」 | 15 バイトの `.resume` を置く（短いので使わない） | 落とした後に `.resume` が無い |
| `stalePartIsRemovedBeforeStart` / 「再開しないときは古い `.part` を捨てる」 | `.part` に 10 バイト置く | 落とした後の中身が `payload`（連結されていない） |
| `cancelStopsAndDoesNotLog` / 「キャンセルは cancelled でログを出さない」 | `.body(大きな payload)` を返す応答の作り手の中でセマフォを待たせ（要求が届いたまま止まる）、`requests(url:) == 1` を待ってから `cancel(id:)` → セマフォを開ける（確定的に「実行中」を作る） | `.failure(.cancelled)`、`model_download_failed` が 0 行 |
| `twoDownloadsOfTheSameIDAreRefused` / 「同じ ID の二重実行は断る」 | 1 本目を同じ方法（応答の作り手の中でセマフォ）で止めたまま 2 本目 | 2 本目が `.failure(.io("already_downloading"))`、セマフォを開けた後 1 本目は成功 |
| `emptyBodyIsASizeMismatch` / 「空の応答はサイズ違い（TEST-28）」 | `.body(Data())` | `.failure(.sizeMismatch)` |

- キャンセルのテストは `.serialized` にせず、URL をテストごとに変える（`ModelHostStub` は URL で引く）
- 各テストの終わりに `ModelHostStub.unregister(url:)`

### 5.2 `ResumeStoreTests.swift`（`@Suite("ResumeStore")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `savesUnderModels` / 「models/.<file>.resume に書く」 | `save(Data(repeating: 1, count: 64), …)` | `<HOME>/models/.ggml-t.bin.resume` が在り 64 バイト、権限 0600 |
| `loadsWhatWasSaved` / 「書いたものを読める」 | 同上 → `load` | 同じ 64 バイト |
| `shortDataIsIgnored` / 「16 バイト未満は使わない」 | 15 バイトを置く | `load` が nil |
| `missingIsNil` / 「無ければ nil（TEST-28）」 | 置かない | `load` が nil |
| `discardRemoves` / 「捨てると消える」 | 置いて `discard` | ファイルが無い、2 回目の `discard` も落ちない |

### 5.3 `ModelImporterTests.swift`（`@Suite("ModelImporter")`）

`gguf = Data((0..<2_500_000).map { UInt8($0 % 97) })`、`sha = FileHasher.sha256(gguf)`。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `importsAndNamesBySHA` / 「custom-<sha16>.gguf に置いて custom:<sha> を返す」 | `source` に `gguf` | `id == "custom:" + sha`、`url` が `models/llm/custom-\(sha.prefix(16)).gguf`、中身が一致 |
| `partIsRemovedAfterRename` / 「`.part` を残さない」 | 同上 | `models/llm` の中身が 1 件だけ |
| `existingFileIsReused` / 「既に在れば `.part` を消して既存を使う」 | 先に `custom-<sha16>.gguf` に別の 3 バイトを置く | 成功、既存の 3 バイトが**変わっていない**、`models/llm` の中身が 1 件 |
| `differentContentGivesDifferentID` / 「中身が違えば別の ID」 | `gguf` と `gguf + [0]` | ID が異なり、ファイルが 2 つ |
| `missingSourceFails` / 「無いファイルは io」 | 存在しないパス | `.failure(.io(…))`、`models/llm` が空 |
| `directorySourceFails` / 「ディレクトリは受けない」 | ディレクトリを渡す | `.failure(.io("not_a_regular_file"))` |
| `symlinkSourceFails` / 「symlink は受けない」 | `gguf` への symlink | `.failure(.io("not_a_regular_file"))` |
| `emptyFileIsImported` / 「空ファイルも取り込める（TEST-28）」 | 0 バイト | 成功、`sha` は空の SHA-256、ファイルが 0 バイト |
| `tooSmallChunkIsRefused` / 「chunkBytes が 4096 未満なら断る」 | `chunkBytes: 100` | `.failure(.io("chunk_bytes"))`、`models/llm` が空 |

### 5.4 `ModelManagerTests.swift`（`@Suite("ModelManager")`）

カタログは `TestCatalogs.minimal`（T-09）。`downloader` は `ModelDownloader(layout: layout, factory: BlockingSessionFactory(), log: log, hashChunkBytes: 1_048_576)`（引数の並びは地図 §10 が正）。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `absentWhenMissing` / 「ファイルが無ければ absent」 | 何も置かない | `.absent` |
| `presentWhenSizeMatches` / 「在って size が一致すれば present」 | `entry.bytes` バイトの 0 を置く | `.present` |
| `wrongSizeIsAbsent` / 「size が違えば absent（速い判定）」 | 1 バイト少なく置く | `.absent` |
| `unknownIDIsAbsent` / 「知らない ID は absent」 | `id = "nope"` | `.absent`、`url(kind:id:)` が nil |
| `customIDResolves` / 「custom:<sha> は models/llm/custom-<16>.gguf を指す」 | ファイルを置く | `url` が一致、`state` が `.present` |
| `verifySHAMatches` / 「SHA が一致すれば真」 | 中身と `sha256` を合わせる | 真 |
| `verifySHADetectsChange` / 「中身が違えば偽」 | 別の中身 | 偽 |
| `verifySHAUsesTheCache` / 「同じ (inode,size,mtime) なら 2 回目は読み直さない」 | 1 回目の後、**ファイルを読めなくする**（0000 に chmod） | 2 回目も真（キャッシュから）。`chmod` を戻して後始末 |
| `verifySHARecomputesAfterTouch` / 「mtime が変われば読み直す」 | 1 回目の後に中身を書き換える（mtime が進む） | 2 回目は偽 |
| `verifySHAOfCustomUsesTheID` / 「custom の期待値は ID の中の sha」 | 取り込んだファイル | 真。ID を 1 文字変えると偽 |
| `verifySHAOfMissingIsFalse` / 「無いファイルは偽（TEST-28）」 | 置かない | 偽、キャッシュに何も入らない |
| `failureIsShownAsAMessage` / 「失敗すると failed に日本語が出る」 | `BlockingSessionFactory` で `download(_:kind:progress:)` | `state` が `.failed("ネットワークに接続できませんでした")` |
| `downloadClearsThePreviousFailure` / 「もう一度押すと失敗表示が消える」 | 失敗の後にファイルを置いて `download` | `.success`、`state` が `.present` |
| `meetsMemoryUsesGiB` / 「32 GB のモデルは 32 GiB 必要」（パラメータ化） | `minMemoryGB: 32` と `physicalMemoryBytes` = `32 × 1024³ - 1` / `32 × 1024³` | 偽 / 真 |
| `meetsMemoryIsTrueWithoutLimit` / 「minMemoryGB が無ければ常に真」 | whisper の項目 | 真 |

## 6. 破壊による証明

| 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|
| `ModelSource.url` の 40 桁の検査を消す | `mainInsteadOfCommitIsRejected` |
| `ModelSource.url` のホストの検査を消す | `badHostIsRejectedBeforeAnyRequest` |
| `ModelSource.url` の「`/` + file で終わる」の検査を消す | `fileNameMismatchIsRejected` |
| `ModelSource.isSafeFileName` の `..` の検査を消す | `unsafeFileNameIsRejected` |
| §4.1.4 の 11（サイズの照合）を消す | `sizeMismatchIsDetectedBeforeHashing` |
| §4.1.4 の 12（SHA の照合）を消す | `shaMismatchRemovesThePart` |
| 照合に失敗しても `.part` を消さない | `shaMismatchRemovesThePart`、`sizeMismatchIsDetectedBeforeHashing` |
| `.finished` でないのに rename する | `httpErrorIsReported` |
| 再開データを読んだ後に `.resume` を消さない | `staleResumeIsRemovedWhenUnused` |
| 再開しないときに古い `.part` を消さない | `stalePartIsRemovedBeforeStart` |
| `.cancelled` でも `model_download_failed` を出す | `cancelStopsAndDoesNotLog` |
| `running` の二重起動の検査を消す | `twoDownloadsOfTheSameIDAreRefused` |
| 既に在るときもダウンロードする | `presentFileSkipsTheNetwork` |
| `ModelImporter` で `.part` を経由せず直接 `custom-….gguf` へ書く | `existingFileIsReused` |
| 既存があっても上書きする | `existingFileIsReused` |
| `ModelVerificationCache` を見ずに毎回計算する | `verifySHAUsesTheCache` |
| キャッシュの照合から `mtime` を外す | `verifySHARecomputesAfterTouch` |
| `meetsMemory` の `1_073_741_824` を `1_000_000_000` にする | `meetsMemoryUsesGiB` |
| `ModelFiles.isPresent` の代わりに「在るだけ」で判定する | `wrongSizeIsAbsent` |

## 7. 受け入れ条件

- [ ] §3 のファイルがあり、`make lint` と `make test` が通る
- [ ] `URLSession` が `Sources/VDModels/` と `VDLLM/LoopbackHTTP.swift` の外に無い（PT-02 が緑）
- [ ] `FileManager.removeItem` を使っていない。削除はすべて `SafeUnlink`（PT-01 が緑）
- [ ] `@unchecked Sendable` と `nonisolated(unsafe)` が無い（PT-14 が緑）。`ModelDownloadDelegate` は `Mutex` で守っている
- [ ] テストが 1 本もネットワークに出ない（`ModelHostURLProtocol` と `BlockingURLProtocol` のどちらかを必ず通る。登録の無い URL は `.notConnectedToInternet`）
- [ ] `ModelManager.meetsMemory` の定数 `1_073_741_824` が T-22 の `LLMGuard` と同じ値である（両方を `grep` して PR 本文に貼る）
- [ ] 破壊による証明の各項目で、表のテストが落ちることを確かめ、PR 本文に貼った

## 8. API 地図への変更提案

1. `ModelDownloader.init` に `hashChunkBytes: Int` を足す（ストリームの SHA-256 は `audio.hashChunkBytes` ずつ。PLAN §8.10。値を 2 か所に書かないため設定から渡す）
2. `ModelDownloader.download` の `progress` を `@escaping @Sendable (Int64, Int64) -> Void` にする（代理が持つので escaping）
3. `ModelManager.init` を `init(layout:catalog:downloader:cache:log:hashChunkBytes:)` にする（地図は `init(layout:catalog:downloader:clock:)`。`ModelVerificationCache` は診断と共有するので**注入**が要る（PLAN §8.10）。`clock` は使わないので外す）
4. `ModelManager` に `download(_:kind:progress:)`・`cancel(id:)`（名前と引数は地図 §10 のとおり。当初の案 `download(kind:id:)`・`cancel(kind:id:)` は地図に合わせて改めた）・`importCustomLLM(from:)`・`static meetsMemory(_:physicalMemoryBytes:)` を足す（`ModelState.downloading` / `.failed` を動かす者が要る。UI は ModelManager だけを見る）
5. `ModelError` に `logReason` と `displayMessage` を足す（ログの語と UI の文言を 1 か所に置く）
6. `DownloadSessionFactory` の本番の実装 `EphemeralDownloadSessionFactory` を足す（地図はプロトコルだけ）
7. 00-api-map §15 に `ModelHostStub`・`ModelHostURLProtocol`・`ModelHostSessionFactory`（作り手 T-23、使うのは T-23・T-32）を足す。`BlockingSessionFactory: DownloadSessionFactory` の準拠は本チケットが extension で足す（T-21 §8 の 7 のとおり）
8. 付録 A.4 の `model_download_failed` の `reason` に `cancelled` / `bad_url` / `bad_file_name` / `io` を足す（PLAN の本文 §8.10 は `sha256_mismatch|size_mismatch|http_<code>|network` の 4 つしか挙げていないが、URL とファイル名の検査・ファイルの入出力の失敗にも語が要る。「新しい語を足すときはここに足す」に従う） → 仕様 付録 A.4 に反映済み（`sha256_mismatch|size_mismatch|http_<code>|network|cancelled|bad_url|bad_file_name|io`。整合修正 M-8）
9. （実装で判明）地図 §10 の `ModelManager.download(_ id: String, kind: ModelKind, progress:)` の `progress:` に型が無い。`ModelDownloader.download` と同じ `@escaping @Sendable (Int64, Int64) -> Void` と書き足す。`cancel(id:)` は `ModelDownloader.cancel(id:)` を `await` するので `async` と書き足す（実装はこの形。地図の名前と引数は変えていない）

## 9. SPEC の変更

`reason` の語は付録 A.4（§8 の 8）に反映済み: `model_download_failed` の `reason=sha256_mismatch|size_mismatch|http_<code>|network|cancelled|bad_url|bad_file_name|io`。`docs/SPEC.md` を PLAN 付録 A.4 と同じ語にする（`LogEvent` の一覧そのものは T-10 が SPEC に同期させている）。

## 10. マージ後にやること

- T-31（「はじめに」のモデルの画面）は `ModelManager` だけを使う（`ModelDownloader` を直接持たない）。`hashChunkBytes` は `config.audio.hashChunkBytes` を渡す
- T-32（DR-05 / DR-08）は Bootstrap が作った**同じ** `ModelVerificationCache` を受け取る（`WorkerDependencies.verificationCache` と同一のインスタンス）
- T-24 でカタログの値（URL のコミット SHA・sha256・bytes・license）を確かめ直したら、`Resources/ModelCatalog.json` を直す。本チケットのテストはカタログの値に依存しない（自前の `ModelEntry` を作る）
