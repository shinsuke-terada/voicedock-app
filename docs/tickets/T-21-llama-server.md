# T-21 VDLLM: llama-server の管理・ループバック HTTP

> （F-76・issue #116。2026-09-23）`stop()` は起動の途中（/health が 200 になる前）なら中止の印を立てて起動中のプロセスを直ちに止め、起動を次の試行・次の待ちに進ませずに `server_start_failed: cancelled` で終わらせる（読み込みの完了を待たない。アプリの終了が 15 分止まらないように）。停止の途中に来た `ensureRunning` は停止の終わりを待ってから起動する。テストは `Tests/VDLLMTests/LlamaServerSupervisorStopTests.swift`。下の本文の「起動の途中なら、その終わりを待ってから止める」は記録として残す。

| 項目 | 値 |
|---|---|
| ID | T-21 |
| Phase | 5（LLM とモデル） |
| 前提 | T-03（`Tests/Fixtures/llama-server-help.txt`）、T-12（`ProcessRunning` / `RunningProcess` / `ProcessSpec` / `ProcessEnvironment`）、T-19（`ChatTransport` / `ChatResult`・`LLMProbe`）。T-06（`AtomicFile`・`HomeLayout`・`TempDirectory`）、T-10（`AppClock`・`Sleeper`・`AppLog`・`SafeUnlink`・`AppPaths`・`TextLimit`・TestSupport の `SteppingClock` / `RecordingSleeper` / `CapturingLogSink`）、T-45（`PyText` / `PyJSON.decode`）はその前提に含まれる |
| 見積もり | ソース約 400 行・テスト約 500 行・TestSupport 約 200 行 |
| 後続 | T-22（解析工程が起動・停止する）、T-32（DR-07・DR-09）、T-24（受け入れ試験） |

## 1. 目的

同梱の `llama-server` を解析の間だけ `127.0.0.1` で起動し、ループバックの HTTP で `chat/completions` を呼ぶ部品を作る（PLAN §8.5「llama-server の起動」「HTTP」、§2.1）。
**ネットワークに出ない**（URL は `127.0.0.1` 固定の型からしか作れない。PT-02）、**API キーを引数に置かない**、**起動の失敗は別のポートで 3 回まで**、**止めるときはプロセスグループごと**。

## 2. 参照

- PLAN §8.5「llama-server の起動」「HTTP」、§2.1（解析の間だけ起動し `processReadySessions` の終わりで止める）、§8.2（`spawn` / `RunningProcess`）、§11.2（ビルド: `LLAMA_OPENSSL=OFF`・`LLAMA_USE_PREBUILT_UI=OFF`）、
  §10.1（URLSession は注入したファクトリから）、§9.4（PT-02: `URLSession` と `socket(` は `LoopbackHTTP.swift` だけ、そこでも `URL(string:` を使わない。PT-04: 長い形のフラグ）、§8.15（ログ）、付録 A.3（`LLM_UNAVAILABLE`）・A.4（`llm_server_started` / `llm_server_stopped`）
- 00-api-map §8（`LoopbackHTTP.swift`・`LlamaArgs.swift`・`LlamaServerSupervisor.swift`）
- voicedock@d3d595e `src/voicedock/llm.py:311-437`（`Endpoint` / `complete` / `_content_of`）、`tests/unit/test_llm_client.py:133-192, 294-350`（要求の形・タイムアウト・HTTP エラー・外形の壊れた応答）
- 外部の事実（2026-09-18 に確認。scratchpad/ref/V7）: llama.cpp b11033 の `llama-server` は `--model` `--host` `--port` `--api-key-file` `--ctx-size` `--n-gpu-layers` `--jinja` `--parallel` `--no-webui` `--offline` を持つ。
  `/health` は API キー不要で、読み込み中は 503、準備ができると 200 `{"status":"ok"}`

## 3. 作るもの

ソース（`Sources/VDLLM/`）:
- `LoopbackHTTP.swift`（`LoopbackEndpoint`・`LoopbackSessionFactory`・`EphemeralSessionFactory`・`LoopbackChatTransport`・`FreePort`・`LoopbackHealth`。**PT-02 のため 1 ファイルに置く**。「1 ファイル 1 主要型」の例外）
- `LlamaArgs.swift`
- `LlamaServerSupervisor.swift`（`LlamaServerSupervisor`・`LlamaServerHandle`）

テストの部品（`Tests/TestSupport/`）:
- `BlockingURLProtocol.swift`（`BlockingURLProtocol`・`LoopbackStub`・`StubRequest`・`StubReply`・`BlockingSessionFactory`）
- `FakeLlamaServer.swift`

テスト（`Tests/VDLLMTests/`）:
- `LoopbackHTTPTests.swift`、`LlamaArgsTests.swift`、`LlamaServerSupervisorTests.swift`

`Tests/PolicyTests/ConfigEffectPending.swift`（変更。§5.4）: 自分のキーの行を消す。

## 4. 仕様

### 4.1 `LoopbackHTTP.swift`（「// ループバック（127.0.0.1）への HTTP だけを行う唯一のファイル（PLAN §8.5、PT-02）。URL(string:) を使わない。」）

```swift
public struct LoopbackEndpoint: Equatable, Sendable {
    public static let host = "127.0.0.1"
    public let port: UInt16
    public let chatCompletionsURL: URL        // http://127.0.0.1:<port>/v1/chat/completions
    public let healthURL: URL                 // http://127.0.0.1:<port>/health
    /// port が 0 なら nil。URL は URLComponents（scheme "http"・host 127.0.0.1・port・path）で作り、url が nil なら nil。
    public init?(port: UInt16)
}

public protocol LoopbackSessionFactory: Sendable {
    /// 呼ぶたびに新しい設定を返す（呼び手が timeout を書き込む）。
    func configuration() -> URLSessionConfiguration
}

public struct EphemeralSessionFactory: LoopbackSessionFactory {
    public init()
    /// .ephemeral に connectionProxyDictionary = [:]（プロキシを通さない）、requestCachePolicy = .reloadIgnoringLocalCacheData、
    /// urlCache = nil、httpCookieStorage = nil、httpShouldSetCookies = false、waitsForConnectivity = false を設定したもの。
    public func configuration() -> URLSessionConfiguration
}

public struct LoopbackChatTransport: ChatTransport {
    public init(endpoint: LoopbackEndpoint, apiKey: String, modelID: String, config: LLMConfig, factory: any LoopbackSessionFactory)
    public func complete(system: String, user: String) async -> ChatResult
    func makeConfiguration() -> URLSessionConfiguration          // internal（テスト用）
    func makeRequest(system: String, user: String) -> URLRequest?   // internal（テスト用）。本文を作れなければ nil
    static func content(of data: Data) -> String                  // internal
}

public enum FreePort {
    /// 127.0.0.1:0 に bind して割り当てられたポートを返し、ソケットは閉じる。取れなければ nil。
    public static func pick() -> UInt16?
}

public enum LoopbackHealth {
    public static let timeoutSeconds: Double = 5
    /// GET healthURL の HTTP ステータス。接続できない・HTTP でない応答なら nil。
    public static func check(_ endpoint: LoopbackEndpoint, factory: any LoopbackSessionFactory) async -> Int?
}
```

**`LoopbackChatTransport`**:
- `makeConfiguration()`: `factory.configuration()` に `timeoutIntervalForRequest = Double(config.requestTimeoutSeconds)`、`timeoutIntervalForResource = 同じ値` を設定して返す
- `makeRequest`: URL = `endpoint.chatCompletionsURL`、`httpMethod = "POST"`、ヘッダ `Authorization: Bearer <apiKey>`・`Content-Type: application/json`、`timeoutInterval = Double(config.requestTimeoutSeconds)`、
  本文 = 次の辞書を `JSONSerialization.data(withJSONObject:options: [.sortedKeys, .withoutEscapingSlashes])` で符号化したもの（サーバが読むだけなので voicedock とのバイト一致は不要。キーと値は voicedock と同じ）:
  ```text
  "model": modelID
  "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
  "temperature": config.temperature
  "top_p": config.topP
  "max_tokens": config.maxOutputTokens
  "response_format": ["type": "json_object"]
  ```
- `complete(system:user:)` の手順（**要求ごとに新しい URLSession。使い回さない。LLM-10**）:
  1. `request = makeRequest(…)`。nil なら `.failure(StageFailure(.llmUnavailable, "request_encoding_failed"))`
  2. `session = URLSession(configuration: makeConfiguration())`。終わったら（どの経路でも）`session.finishTasksAndInvalidate()`
  3. `(data, response) = try await session.data(for: request)`。
     `URLError` を捕まえたら `.failure(StageFailure(.llmUnavailable, "URLError \(error.code.rawValue)"))`（例 `URLError -1004`。ロケールに依存する説明文を入れない）、
     それ以外のエラーは `.failure(StageFailure(.llmUnavailable, String(describing: type(of: error))))`
  4. `status = (response as? HTTPURLResponse)?.statusCode ?? 0`。`status >= 400` か `status == 0` → `.failure(StageFailure(.llmUnavailable, "HTTP \(status): \(TextLimit.prefix(String(decoding: data, as: UTF8.self), scalars: 200))"))`
  5. それ以外 → `.content(Self.content(of: data))`
- `content(of:)`（voicedock `_content_of`）: 応答の読み取りは `PyJSON.decode(data)`（T-45。`JSONSerialization` は content の先頭の U+FEFF を落とすので使わない。PLAN §5.7・F-45）。
  結果が `.object(top)` → `top` のキー `"choices"`（キーはスカラー列で比べる）が `.array(items)` で空でない → `items[0]` が `.object(c)` → `"message"` が `.object(m)` → `"content"` が `.string(s)` ならそれ。
  **どこかで外れたら `""`**（不正な UTF-8・JSON でないものを含む。失敗にせず、呼び手の検証が「JSON を抽出できない」として修復へ回す）。`content` が数・真偽値・null でも `""`
- ログは出さない（プロンプトと応答の本文を扱うため。PR-08）

**`FreePort.pick()`**:
1. `fd = socket(AF_INET, SOCK_STREAM, 0)`。負なら nil。関数を抜けるとき `close(fd)`
2. `sockaddr_in` を `sin_len = MemoryLayout<sockaddr_in>.size`、`sin_family = AF_INET`、`sin_port = 0`、`sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian` で作り `bind`。失敗なら nil
3. `getsockname` でポートを読み `UInt16(bigEndian: sin_port)`。0 か失敗なら nil

**`LoopbackHealth.check`**: `URLRequest(url: healthURL)`、`httpMethod = "GET"`、`timeoutInterval = 5`。設定は `factory.configuration()` に request / resource の timeout 5 秒を入れたもの。要求ごとに新しい session、終わったら `finishTasksAndInvalidate()`。
応答が `HTTPURLResponse` ならその `statusCode`、エラー・HTTP でなければ nil。API キーを付けない（`/health` は不要）

### 4.2 `LlamaArgs.swift`（「// llama-server の引数（PLAN §8.5）。長い形のフラグだけを使い、固定した版の --help と照合する。」）

```swift
public enum LlamaArgs {
    public static let usedFlags: [String] = ["--model", "--host", "--port", "--api-key-file", "--ctx-size",
                                             "--n-gpu-layers", "--jinja", "--parallel", "--no-webui", "--offline"]
    /// argv[0] を含まない引数の列。
    public static func build(model: URL, port: UInt16, apiKeyFile: URL, contextSize: Int) -> [String]
    /// usedFlags のうち、help の出力に「語として」現れないものを usedFlags の順に返す。
    public static func missingFlags(helpOutput: String) -> [String]
}
```

- `build` の結果は**この並びで逐語**:
  `["--model", <model のパス>, "--host", "127.0.0.1", "--port", "<port の 10 進>", "--api-key-file", <apiKeyFile のパス>, "--ctx-size", "<contextSize の 10 進>", "--n-gpu-layers", "999", "--jinja", "--parallel", "1", "--no-webui", "--offline"]`
  - パスは `url.path(percentEncoded: false)`（`Application Support` の空白をそのまま渡す。シェルを通さないので引用しない）。host は `LoopbackEndpoint.host`
  - `-c` などの短い形は使わない（PT-04 の誤検知を避ける）
- `missingFlags`: help の出力（stdout と stderr を連結した文字列）の `unicodeScalars` で、フラグの出現のうち**直前と直後の文字がどちらも `[A-Za-z0-9-]` でない**ものが 1 つでも在れば「在る」
  （`--port` は `--portable` の一部としては数えない）。DR-07（T-32）も同じ関数を使う

### 4.3 `LlamaServerSupervisor.swift`（「// llama-server の起動と停止（PLAN §8.5・§2.1）。Worker と DR-09 が単一のインスタンスを共有する。」）

```swift
public struct LlamaServerHandle: Equatable, Sendable {
    public let endpoint: LoopbackEndpoint
    public let apiKey: String                 // 小文字 16 進 32 文字
    public let modelID: String                // 要求本文の "model" に入れる（カタログの ID か custom:<sha256>）
    public init(endpoint: LoopbackEndpoint, apiKey: String, modelID: String)   // 00-api-map §8 の行に合わせる（T-22 の偽物が作る）
}

public actor LlamaServerSupervisor {
    public static let maxAttempts = 3
    public static let startupTimeoutSeconds = 300
    public static let stopGraceSeconds = 10
    public init(runner: any ProcessRunning, paths: AppPaths, layout: HomeLayout, clock: AppClock, sleeper: Sleeper, log: AppLog,
                factory: any LoopbackSessionFactory, portPicker: @escaping @Sendable () -> UInt16? = FreePort.pick)
    /// 起動済みで同じモデル・同じ contextSize・生きていればそれを返す。違えば止めてから起動し直す。
    public func ensureRunning(model: URL, modelID: String, config: LLMConfig) async -> Result<LlamaServerHandle, StageFailure>
    /// 起動していなければ何もしない。
    public func stop() async
}
```

状態: `private var current: (process: RunningProcess, handle: LlamaServerHandle, model: URL, contextSize: Int)?`、`private var starting: Task<Result<LlamaServerHandle, StageFailure>, Never>?`、`private var stopping: Task<Void, Never>?`

**`ensureRunning`**:
1. ループ: `starting` が在ればその `value` を待って 1 に戻る。`stopping` が在ればその `value` を待って 1 に戻る（**待った結果を返さない**。起動中の結果は別のモデルのものかもしれないので、自分の条件で比べ直す。再レビューで判明）
2. `c = current` が在り、`model`・`config.contextSize`・`modelID` が同じで `await c.process.isRunning` なら、返す前に `starting == nil && stopping == nil && current?.handle == c.handle` を確かめて `.success(c.handle)`。外れたら（`isRunning` の `await` の間に起動・停止が始まった・`current` が替わった）1 に戻る
3. `starting` か `stopping` が在れば 1 に戻る（2 の `await` の間に別の呼び手が起動・停止を始めていることがある）。どちらも無ければループを抜ける
4. `starting = Task { await self.stopCurrent(); let r = await self.startServer(model:modelID:contextSize:); self.starting = nil; return r }`（`current` が違う・死んでいるなら止めてから起動。`stopCurrent()` は § stop の 2〜5 で、`current` が nil なら何もしない）
   → `await starting.value` を返す。**`starting = nil` は Task の中で終わる前に行う**（呼び手の側で空にすると、1 で待っていた別の呼び手が、終わった Task を `await` しても中断しないまま回り続け、呼び手が戻れずに止まる。実装で判明）。
   **止めることと起動することを 1 つの Task に入れ、最初の `await` より前に `starting` を立てる**（`stopCurrent()` を Task の外で `await` すると、terminate の最大 10 秒の間に別の呼び手が入り、2 つ起動して片方を止められなくなる。レビューで判明。テスト `concurrentCallsKeepOnlyOneAlive`）
- `starting` の Task は構造化されていないので、呼び手のタスクの取り消しは伝わらない（`server_start_failed: cancelled` は `Sleeper` が投げたときだけ通る）。取り消しを伝えたいなら T-22 が別に決める
- **T-22 / T-32 への申し送り**: 別のモデル（か contextSize）で `ensureRunning` を呼ぶと、前の呼び手に返した handle のサーバーが止まる。DR-09 などは Worker の解析と直列にするか、同じモデルを使う

**`startServer`**（`maxAttempts` 回まで。1 回ごとに別のポート）:
```text
lastReason = "no_port"; lastStderr = ""
for attempt in 1...3:
  port = portPicker()、endpoint = LoopbackEndpoint(port:)。どちらかが nil → lastReason = "no_port"; lastStderr = ""; continue
  key = SystemRandomNumberGenerator の 16 バイトを小文字 16 進 2 桁ずつつないだ 32 文字
  AtomicFile.write(Data(key.utf8), to: layout.llamaAPIKeyFile, permissions: 0o600)。失敗 → 鍵ファイルを消す（前の試行の鍵が残っていることがある。下と同じ SafeUnlink）→ return .failure(StageFailure(.llmUnavailable, "server_start_failed: api_key_file"))
  spec = ProcessSpec(executable: paths.llamaServer, arguments: LlamaArgs.build(model:, port:, apiKeyFile: layout.llamaAPIKeyFile, contextSize:), environment: ProcessEnvironment.standard)
  process = try await runner.spawn(spec)。失敗 → lastReason = "spawn_failed"; lastStderr = ""; continue
  started = clock.uptime()
  loop:
    await LoopbackHealth.check(endpoint, factory:) == 200 →
        current = (process, LlamaServerHandle(endpoint:, apiKey: key, modelID:), model, contextSize)
        log.info(.llmServerStarted, [(.port, .int(Int64(port))), (.elapsedS, .double(小数 1 桁に丸めた経過秒))])
        return .success(handle)
    await process.isRunning が偽 →
        t = await process.terminate(grace: .zero)                 // 既に終わっているので終了の状態を得るだけ
        lastReason = reason(t); lastStderr = await process.stderrTail() を UTF-8（不正は置換）で文字列に; break loop
    clock.uptime() − started >= .seconds(300) →
        _ = await process.terminate(grace: .seconds(10)); lastReason = "timeout"; lastStderr = …; break loop
    try await sleeper.sleep(seconds: 1)。失敗（キャンセル）→ terminate(grace: 10 秒)・鍵ファイルを消す・return .failure(StageFailure(.llmUnavailable, "server_start_failed: cancelled"))
鍵ファイルを消す（SafeUnlink.remove(layout.llamaAPIKeyFile, under: .run, layout:, missingOK: true)。失敗は無視）
return .failure(StageFailure(.llmUnavailable, message(lastReason, lastStderr)))
```
- `reason(t)`: `.exited(n)` → `"exited(\(n))"`、`.signaled(n)` → `"signaled(\(n))"`、`.timedOut` → `"timeout"`、`.spawnFailed` → `"spawn_failed"`
- `message(reason, stderr)`: `s = PyText.strip(stderr)`。空なら `"server_start_failed: \(reason)"`、そうでなければ `"server_start_failed: \(reason): \(s の末尾 150 スカラー)"`（PLAN §8.5 の `server_start_failed: <理由>: <stderr の末尾 150 スカラー>`。DB で 200 文字に切られても理由が残る長さ。
  stderr が空のときに `": "` で終わらせないのと、理由語の `signaled(<n>)`・`api_key_file`・`cancelled` は、いまの PLAN §8.5 の理由語の列に反映済み）
- **API キーファイルは停止したときと起動に失敗したときに必ず消す**（PLAN §8.5）: `startServer` のどの失敗の経路（`api_key_file`・`cancelled`・3 回の失敗）でも、`stop()` / `stopCurrent()` でも消す
- 経過秒 = `clock.uptime() − started` を秒の `Double` にし、`PyRound.round(x, digits: 1)`（T-45。Python の `round(x, 1)`。PLAN §5.7）
- 1 回ごとの失敗はログに出さない（最後の失敗は呼び手が `llm_failed` で出す）
- **メモリの確認はしない**（PLAN §5.4 のガードで Worker が起動の前に行う。ここでは渡されたモデルをそのまま起動する）
- stdout / stderr はファイルに残さない（`ProcessRunner` が末尾だけメモリに持つ。PR-08）

**`stop()`**（と `stopCurrent()`。`stopCurrent()` は 2〜5）:
1. （`stop()` だけ）`starting` か `stopping` が在る間はその `value` を待つ（起動の途中で呼ばれても、起動したものを残さない）。その後 `stopping = Task { await self.stopCurrent(); self.stopping = nil }` を立てて待つ。
   停止も Task にして `stopping` に置くのは、terminate の最大 10 秒の間に来た `ensureRunning` を待たせ、新しい起動の鍵ファイルを古い停止が消さないため（再レビューで判明）。`private var stopping: Task<Void, Never>?` を状態に足す
2. `current` が nil なら何もしない
3. `c = current; current = nil`
4. `_ = await c.process.terminate(grace: .seconds(10))`（SIGTERM → 10 秒 → SIGKILL。プロセスグループごと）
5. `log.info(.llmServerStopped, [(.port, .int(Int64(c.handle.endpoint.port)))])`、鍵ファイルを消す（SafeUnlink、`missingOK: true`、失敗は無視）

**使い方**（T-22 と T-32 が書く。参考）:
```swift
switch await supervisor.ensureRunning(model: modelURL, modelID: id, config: cfg.llm) {
case .success(let h):
    let transport = LoopbackChatTransport(endpoint: h.endpoint, apiKey: h.apiKey, modelID: h.modelID, config: cfg.llm, factory: factory)
    // Analyzer(transport:prompts:config:) か、DR-09 なら transport.complete(system: LLMProbe.system, user: LLMProbe.user)
case .failure(let f): // Session を ANALYZING→FAILED（f.code = LLM_UNAVAILABLE）
}
// processReadySessions の終わりで必ず: await supervisor.stop()
```

### 4.4 テストの部品

**`BlockingURLProtocol.swift`**（`Tests/TestSupport/`。PLAN §10.1 の `BlockingURLProtocol` に、ループバックの応答の差し替えを足したもの）:

```swift
public struct StubRequest: Sendable { public let method: String; public let url: URL; public let headers: [String: String]; public let body: Data }
public enum StubReply: Sendable { case http(status: Int, body: Data); case failure(URLError.Code) }

public enum LoopbackStub {
    /// 127.0.0.1:<port> への要求に handler で応答する（テストごとに別のポートを使えば並行に走らせても混ざらない）。
    public static func register(port: UInt16, _ handler: @escaping @Sendable (StubRequest) -> StubReply)
    public static func unregister(port: UInt16)
    /// 受けた要求（順に）。
    public static func requests(port: UInt16) -> [StubRequest]
}

public final class BlockingURLProtocol: URLProtocol {
    // canInit: 常に true。canonicalRequest: そのまま。
    // startLoading:
    //   host が "127.0.0.1" でない → client に URLError(.notConnectedToInternet) を渡す（ネットワークへ出さない。TEST-12）
    //   port に handler が無い → URLError(.cannotConnectToHost)
    //   在れば body（httpBody か httpBodyStream を全部読んだもの）を添えて記録し handler を呼ぶ。
    //     .http → HTTPURLResponse(url:, statusCode:, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) → didLoad(body) → didFinishLoading
    //     .failure(code) → didFailWithError(URLError(code))
    // stopLoading: 何もしない
}

public struct BlockingSessionFactory: LoopbackSessionFactory {
    public init()
    /// .ephemeral に protocolClasses = [BlockingURLProtocol.self]
    public func configuration() -> URLSessionConfiguration
}
```
- 登録の表と記録は `Synchronization.Mutex` で守る（`import Synchronization`。Tests/ は PT の対象外だが、`@unchecked Sendable` と `nonisolated(unsafe)` はここでも使わない）
- 作り手は本チケット（00-api-map §15）。VDModels（T-23）のテストは使うだけ（`DownloadSessionFactory` への準拠は T-23 が extension で足す）

**`FakeLlamaServer.swift`**（`Tests/TestSupport/`）:

```swift
public struct FakeLlamaServer: Sendable {
    public enum Mode: Sendable, Equatable {
        case stayAlive                          // exec /bin/sleep 600
        case exitImmediately(code: Int32)       // すぐ exit
        case exitBeforeAttempt(Int, code: Int32) // n 回目より前の起動は exit、n 回目以降は留まる
    }
    public let helpersDirectory: URL           // <directory>/Helpers（この中の llama-server を AppPaths(helpers:) に渡す）
    public init(directory: URL, mode: Mode) throws
    public func invocationCount() -> Int       // <directory>/count（無ければ 0）
    public func arguments(ofInvocation n: Int) throws -> [String]   // <directory>/argv.<n> の行（1 始まり）
    public func apiKey(ofInvocation n: Int) throws -> String        // <directory>/key.<n> の中身
}
```
`<directory>/Helpers/llama-server`（パーミッション 0755）の中身（`<D>` は directory の絶対パス、`<MODE>` はモードごとの行）:
```sh
#!/bin/sh
D="<D>"
N=$(cat "$D/count" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$D/count"
: > "$D/argv.$N"
for a in "$@"; do printf '%s\n' "$a" >> "$D/argv.$N"; done
K=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--api-key-file" ]; then K="$2"; fi
  shift
done
if [ -n "$K" ]; then cat "$K" > "$D/key.$N"; fi
echo "fake llama-server attempt $N" 1>&2
<MODE>
```
`<MODE>`: stayAlive → `exec /bin/sleep 600`、exitImmediately(c) → `exit c`、exitBeforeAttempt(n, c) → `if [ "$N" -lt n ]; then exit c; fi` の行と `exec /bin/sleep 600` の行。

## 5. テスト

すべて `import Testing`、`@testable import VDLLM`、`import VDCore`、`import VDContract`、`import VDProcess`、`import TestSupport`。
ポートは `FreePort.pick()` で得たもの（`LoopbackStub` の登録と `portPicker` に使う）。各テストの終わりに `LoopbackStub.unregister`。

### 5.1 `LoopbackHTTPTests.swift`（`@Suite("LoopbackHTTP") struct LoopbackHTTPTests`）

準備: `config = AppConfig.defaults(timeZone: "Asia/Tokyo").llm`、`transport = LoopbackChatTransport(endpoint: LoopbackEndpoint(port: p)!, apiKey: "k" × 32, modelID: "qwen3-30b-a3b-instruct-2507-q4_k_m", config: config, factory: BlockingSessionFactory())`。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `endpointURLs` / 「URL は 127.0.0.1 固定」 | `LoopbackEndpoint(port: 8080)` | `http://127.0.0.1:8080/v1/chat/completions` と `http://127.0.0.1:8080/health`。`LoopbackEndpoint(port: 0) == nil` |
| `requestMatchesTheSpec` / 「要求の形が voicedock と同じ」 | 200 `{"choices":[{"message":{"content":"{}"}}]}` を返す stub | 受けた要求 1 件: POST、URL が chatCompletionsURL、`Authorization: Bearer kk…`、`Content-Type: application/json`、本文の JSON のキーがちょうど 6 つで `model`・`messages`（system と user の 2 件、role と content が渡したもの）・`temperature` 0.1・`top_p` 0.9・`max_tokens` 4096・`response_format` `{"type":"json_object"}` |
| `timeoutComesFromTheConfiguration` / 「CE llm.requestTimeoutSeconds がタイムアウトになる」 | 既定と `requestTimeoutSeconds = 60` | `makeConfiguration()` の request / resource がそれぞれ 1800 / 60 |
| `ceTemperature` / 「CE llm.temperature が本文に入る」 | `temperature = 0.7`、200 の stub | 受けた本文の `temperature` が 0.7（既定なら 0.1） |
| `ceTopP` / 「CE llm.topP が本文の top_p に入る」 | `topP = 0.5` | 本文の `top_p` が 0.5（既定なら 0.9） |
| `ceMaxOutputTokens` / 「CE llm.maxOutputTokens が本文の max_tokens に入る」 | `maxOutputTokens = 256` | 本文の `max_tokens` が 256（既定なら 4096） |
| `validResponseIsParsed` / 「content を取り出す」 | 200 `{"choices":[{"message":{"content":"{\"a\":1}"}}],"usage":{"total_tokens":42}}` | `.content("{\"a\":1}")` |
| `contentKeepsLeadingBOM` / 「content の先頭の U+FEFF を落とさない（PyJSON.decode）」 | 200 `{"choices":[{"message":{"content":"\ufeff{}"}}]}` | `.content("\u{FEFF}{}")` |
| `malformedEnvelopeIsEmpty(body:)` / 「外形が壊れた応答は空文字（修復へ回す）」 | 200 で本文が `{"choices":[]}`・`{"choices":[{}]}`・`{"choices":[{"message":{}}]}`・`{"choices":"nope"}`・`{}`・`[]`・`<html>nope</html>`・`{"choices":[{"message":{"content":5}}]}`・空の本文 `""`（TEST-28） | どれも `.content("")` |
| `httpErrorIsUnavailable(status:)` / 「HTTP 400 以上は LLM_UNAVAILABLE」 | 400・500・503、本文 `busy` | `.failure(StageFailure(.llmUnavailable, "HTTP <status>: busy"))` |
| `httpErrorBodyIsCutAt200Scalars` / 「本文は先頭 200 スカラーまで」 | 500、本文が `あ` × 300 | メッセージが `"HTTP 500: " + "あ" × 200` |
| `connectionFailureIsUnavailable` / 「接続できなければ URLError の番号」 | stub を登録しない | `.failure(StageFailure(.llmUnavailable, "URLError -1004"))` |
| `newSessionPerRequest` / 「要求ごとに新しい設定（使い回さない）」 | 呼ばれた回数を数えるファクトリで 2 回 complete | `configuration()` が 2 回呼ばれる |
| `healthStatus` / 「/health のステータスを返す」 | 200・503 の stub、登録なし | 200・503・nil。/health の要求に Authorization が無い |
| `freePortIsBindable` / 「空きポートは再び bind できる」 | `FreePort.pick()` | nil でない、0 でない、同じポートに `127.0.0.1` で bind できる |

### 5.2 `LlamaArgsTests.swift`

| 関数名 / 表示名 | 期待 |
|---|---|
| `buildIsExact` / 「引数の並びが逐語」 | `build(model: URL(filePath: "/Users/x/Library/Application Support/VoiceDock/models/llm/m.gguf"), port: 40123, apiKeyFile: URL(filePath: "/Users/x/Library/Application Support/VoiceDock/run/llama-api-key"), contextSize: 32768)` が §4.2 の列（パスの空白はそのまま） |
| `usedFlagsAreInTheHelp` / 「使うフラグは固定した版の --help に在る」 | `Tests/Fixtures/llama-server-help.txt`（T-03）を読み、`missingFlags == []`。ファイルが無ければ skip ではなく fail |
| `missingFlagIsReported` / 「--help に無いフラグを返す」 | `--offline` を含まない help 文 → `["--offline"]` |
| `flagMustBeAWord` / 「部分一致を数えない」 | `--portable` だけを含み `--port` を含まない help 文 → 結果に `--port` |
| `noShortForms` / 「短い形のフラグを使わない」 | `build` の結果に `-c`・`-m`・`-ngl`・`-np` が無い |
| `emptyHelpMissesEverything` / 「空の help ならすべてのフラグを返す」（TEST-28） | `missingFlags(helpOutput: "")` が `usedFlags` と同じ 10 個を同じ順で（リテラルで比べる） |
| `ceContextSize` / 「CE llm.contextSize が --ctx-size に渡る」 | `contextSize:` に `AppConfig.defaults(timeZone: "Asia/Tokyo").llm.contextSize` と、`contextSize` を 8192 にした設定の値を渡すと、`--ctx-size` の次がそれぞれ `32768` と `8192` |

### 5.3 `LlamaServerSupervisorTests.swift`（`@Suite(.serialized)`。本物の `ProcessRunner` と `FakeLlamaServer`）

準備: `TempDirectory`、`layout = HomeLayout(root: tmp/home)` と `createDirectories()`、`fake = FakeLlamaServer(directory: tmp/fake, mode: …)`、
`paths = AppPaths(resources: PackageRoot.url.appendingPathComponent("Resources"), helpers: fake.helpersDirectory)`、`model = tmp/m.gguf`（空ファイル）、
`factory = BlockingSessionFactory()`、ポートは `FreePort.pick()` で先に取った列を返す `portPicker`、`/health` の応答は `LoopbackStub` に登録（503 を何回返してから 200 にするかをテストごとに決める）。
`/health` の handler は、そのポートで起動する偽物の n 回目が API キーファイルを読み終える（`fake.apiKey(ofInvocation: n)` が 32 文字になる。最大 10 秒）まで応答を止めてから数える（本物は起動してから応答するので、偽物もスクリプトが走る前に 200 を返さない。止めないと `invocationCount` や stderr がまだ書かれていない。実装で判明）。
pid の生死を確かめるため、本物の `ProcessRunner` に委ねて spawn した `RunningProcess` を覚えるだけの `ProcessRunning`（テストファイルの中の `SpawnRecordingRunner`）を渡す。
ログの行は `LogLevel.info.token` が `"INFO "`（5 桁左寄せ）なので、イベント名以降を `hasSuffix` / `contains` で比べる。
時計・待ち・ログは T-10 の TestSupport を使う（00-api-map §15。このファイルで偽物を作らない）: `RecordingSleeper()`（待たずに秒数を `recorded` に記録する）、`SteppingClock(start: Instant(epochMillis: 0), stepMilliseconds: 1000)`（`now()` と `uptime()` を呼ぶたびに 1 秒進む。時間切れのテストだけ）、それ以外の時計は `FixedClock(epochMillis: 0)`、ログは `CapturingLogSink()`（`lines`）を `AppLog(sink:level: .debug, …)` に渡す。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `startsAndWaitsForHealth` / 「起動して /health が 200 になるまで待つ」 | stayAlive、/health は 503・503・200 | `.success`、handle のポートが picker の 1 つ目、起動 1 回、`fake.arguments(ofInvocation: 1)` が §4.2 の列（ポート・パスを埋めたリテラル。TEST-01 のため `LlamaArgs.build` を呼ばない）、鍵ファイルのパーミッションが 0600・中身が小文字 16 進 32 文字で `handle.apiKey` と `fake.apiKey(ofInvocation: 1)` に等しい、`RecordingSleeper.recorded == [1, 1]`、ログに `llm_server_started port=<port>` |
| `reusesARunningServer` / 「同じ条件なら起動し直さない」 | 上の後にもう一度 `ensureRunning` | 同じ handle、起動 1 回のまま |
| `restartsWhenTheModelChanges` / 「モデルが変わったら止めて起動し直す」 | 2 回目は別の model | 起動 2 回、1 回目の pid に `kill(pid, 0)` が `ESRCH`、ログに `llm_server_stopped` |
| `retriesOnAnotherPort` / 「起動に失敗したら別のポートで」 | exitBeforeAttempt(3, code: 1)、picker `[p1, p2, p3]`、p3 の /health は 200 | `.success`、handle のポートが p3、起動 3 回、それぞれの `--port` が p1・p2・p3 |
| `failsAfterThreeAttempts` / 「3 回失敗したら LLM_UNAVAILABLE」 | exitImmediately(code: 1) | `.failure`、code `.llmUnavailable`、message が `server_start_failed: exited(1): fake llama-server attempt 3`、起動 3 回、鍵ファイルが無い |
| `timesOutAfter300Seconds` / 「300 秒で諦める」 | stayAlive、/health は常に 503、`SteppingClock`（1 秒刻み） | message が `server_start_failed: timeout: fake llama-server attempt 3`、起動 3 回、どのプロセスも残っていない |
| `noPortFails` / 「空きポートが取れなければ起動しない」 | picker が常に nil | message `server_start_failed: no_port`、起動 0 回 |
| `stopTerminatesAndRemovesTheKey` / 「停止でプロセスと鍵ファイルを消す」 | 起動の後に `stop()` | pid が `ESRCH`、鍵ファイルが無い、ログに `llm_server_stopped port=<port>` |
| `stopWithoutServerDoesNothing` / 「起動していなければ停止は何もしない」 | 起動せずに `stop()` | ログが空、エラーにならない |
| `keyIsNotInTheArguments` / 「API キーを引数に置かない」 | 成功の後 | `fake.arguments(ofInvocation: 1)` のどの要素も `handle.apiKey` を含まない |
| `concurrentCallsKeepOnlyOneAlive` / 「同時に呼ばれても 2 つを同時に生かさない（actor の再入）」 | stayAlive、1 つ起動した後に、別のモデル b と c で `ensureRunning` を `async let` で同時に 2 回、その後 `stop()` | 2 つとも `.success` で handle の endpoint が互いに違う（どちらも自分のモデルで起動したもの）、spawn は合わせて 3 回、`stop()` の前に生きているのは 1 つだけ、`stop()` の後はどの pid も `ESRCH`、鍵ファイルが無い |

後片付け: 各テストは TempDirectory から Rig を作って本体を渡す `withRig` で包み、本体が投げても `stop()` と spawn したすべての `terminate(grace: .zero)` と `LoopbackStub.unregister` を行う（`sleep 600` を残さない）。スイートに `.timeLimit(.minutes(1))` を付ける（壊し方によっては待ちのループが終わらない）。

### 5.4 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`llm.contextSize`・`llm.temperature`・`llm.topP`・`llm.maxOutputTokens`・`llm.requestTimeoutSeconds` の 5 行を消す（CE テストは §5.1・§5.2）。

## 6. 破壊による証明

| 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|
| `LoopbackChatTransport` で session を static に持って使い回す | `newSessionPerRequest` |
| `content(of:)` で外形が壊れた応答を `.failure` にする | `malformedEnvelopeIsEmpty` |
| HTTP エラーの本文を切らない | `httpErrorBodyIsCutAt200Scalars` |
| `URLError` の説明文（`localizedDescription`）を入れる | `connectionFailureIsUnavailable` |
| `LlamaArgs.build` で `--ctx-size` を `-c` にする | `buildIsExact`、`noShortForms` |
| `LlamaArgs.build` で `--api-key <key>` を渡す（引数に鍵を置く） | `buildIsExact`、`keyIsNotInTheArguments` |
| `missingFlags` を部分一致にする | `flagMustBeAWord` |
| 起動の失敗で同じポートを使い回す | `retriesOnAnotherPort` |
| `maxAttempts` を 1 にする | `retriesOnAnotherPort`、`failsAfterThreeAttempts` |
| `stop()` で鍵ファイルを消さない | `stopTerminatesAndRemovesTheKey` |
| 起動に 3 回失敗した後に鍵ファイルを消さない | `failsAfterThreeAttempts` |
| `content(of:)` を `JSONSerialization` に戻す | `contentKeepsLeadingBOM` |
| 2 回目の `ensureRunning` で生死を確かめずに起動し直す | `reusesARunningServer` |
| `ensureRunning` の `stopCurrent()` を `starting` の Task の外で `await` し、その後の `starting` の再確認を消す（v1 の手順） | `concurrentCallsKeepOnlyOneAlive` |

実施の結果（2026-09-21。コミット後の清潔な状態で 1 項目ずつ壊し、`git checkout --` で戻した）: どの項目でも表のテストが落ちた。表に無いテストも落ちたのは次のとおり。
- `-c` にする: `startsAndWaitsForHealth`・`ceContextSize` も落ちる
- `--api-key <key>`: Supervisor で `LlamaArgs.build(…) + ["--api-key", key]` にすると `keyIsNotInTheArguments` と `startsAndWaitsForHealth`、`LlamaArgs.build` の末尾に足すと `buildIsExact` と `startsAndWaitsForHealth` が落ちる（1 か所では両方は落ちない。表の 2 つはそれぞれの壊し方で落ちる）
- 同じポートを使い回す: `retriesOnAnotherPort` は 3 回目が登録の無いポートで待ち続け、`FixedClock` が進まないので終わらない。`.timeLimit(.minutes(1))` で失敗と記録されるが、ループが取り消しを見ないのでテストのプロセスは残る（手で止めた）
- `maxAttempts = 1`: `timesOutAfter300Seconds` も落ちる
- `stop()` で鍵を消さない: `concurrentCallsKeepOnlyOneAlive` も落ちる
- 3 回の失敗の後に鍵を消さない: `timesOutAfter300Seconds` も落ちる
- 手順 2 の「返す前の比べ直し」（`starting == nil && stopping == nil && current?.handle == c.handle`）を `true` にする: 3 回回して、落ちるテストは無かった（`isRunning` の `await` の間に別の呼び手が起動・停止を始める窓を、決まった順で作るテストが無い）。表には載せない。この 3 回で落ちたのは `failsAfterThreeAttempts` だけで、それは T-12 の stderr の取りこぼし（§8-9、T-12 側の PR #42）によるもので、比べ直しとは関係ない
- v1 の再入の手順: 3 回のうち 2 回は落ちるまでに数分かかった（2 つの起動が同じ鍵ファイルを書き、偽物の `/health` の待ちが食い違うため）。3 回目は手で止めた（この項目は再レビューの修正より前の実装で行った。修正後の `concurrentCallsKeepOnlyOneAlive` は 1 と 3 の比べ直しと、生きているのが 1 つだけであることも見る）

## 7. 受け入れ条件

- [ ] §3 のファイルがあり、`make lint` と `make test` が通る
- [ ] `URLSession` と `socket(` が `LoopbackHTTP.swift` の外に無く、そこに `URL(string:` が無い（PT-02 が緑）
- [ ] `--help` の fixture との照合テストが緑
- [ ] 破壊による証明の各項目で、表のテストが落ちることを確かめ、PR 本文に貼った

## 8. API 地図への変更提案

1. `LoopbackEndpoint.init(port:)` を `init?(port:)` にする（PT-02 で `URL(string:)` を使えないので `URLComponents.url`（Optional）から作る。port 0 も nil）。`static let host`・`port` を公開 → `init?(port:)` は 00-api-map に反映済み（2026-09-18）。`host`・`port` は地図の §16 に反映済み
2. `LlamaServerSupervisor.init` に `portPicker: @escaping @Sendable () -> UInt16? = FreePort.pick` を足す（テストでポートを決めて `/health` の応答を差し替えるため）。`maxAttempts` などの定数を公開 → `portPicker` は 00-api-map に反映済み（2026-09-18。「API キーファイルは停止・失敗で消す」も地図の注記どおり）。定数は地図に無い
3. `LlamaArgs.missingFlags(helpOutput:)` を足す（DR-07 と共有）→ 00-api-map に反映済み（2026-09-18）
4. `LlamaServerHandle` に `Equatable` と `public init(endpoint:apiKey:modelID:)` → 地図の §8 の行と §16 に反映済み（本チケットの §4.3 も地図に合わせて init を足した）
5. T-12 への前提: `RunningProcess.terminate(grace:)` は、既に終了したプロセスに対しては待たずにその終了の状態（`.exited(n)` / `.signaled(n)`）を返すこと。`stderrTail()` は終了の後も読めること → 00-api-map（「終了済みなら待たずに返す」）と T-12 に反映済み（2026-09-18）
6. T-10 への前提: `LogKey` に `port` と `elapsed_s` が在ること → T-10 の `LogKey` に在る（2026-09-18 確認）
7. TestSupport に `BlockingURLProtocol`・`LoopbackStub`・`StubRequest`・`StubReply`・`BlockingSessionFactory`・`FakeLlamaServer` を足す（§4.4）。T-23 も `BlockingURLProtocol` を使う → 00-api-map §15 に反映済み（2026-09-18。作り手は T-21）
8. 00-api-map §8・§16 への追記（まとめて 1 項）: `LoopbackEndpoint: Equatable`（`LlamaServerHandle: Equatable` のために要る。地図の §8 の行は `Sendable` だけ。実装には不可欠）と、公開定数 `LlamaServerSupervisor.maxAttempts`・`startupTimeoutSeconds`・`stopGraceSeconds`・`LoopbackHealth.timeoutSeconds`（2 の「定数は地図に無い」に `LoopbackHealth.timeoutSeconds` が漏れていた）
9. T-12 への申し送り: `RunningProcess.terminate(grace:)` は既に終了したプロセスに対しては読み取りの後始末（`finishReaders`）を待たずに返すので、直後の `stderrTail()` に最後の出力がまだ入っていないことがありうる（プロセスの終了の検出と stderr の EOF の読み取りの競争）。
   終了を検出してから `stderrTail()` を読むまでの間に待ちは何も無く、揃う保証は無い（実測では `failsAfterThreeAttempts` を負荷の下で数百回回して落ちなかったが、それは偶然の余裕）。本番では `server_start_failed: exited(1)` の後ろの stderr が欠けうる。
   T-12 の側で「終了済みでも読み取りの EOF を `readerDrainGrace` まで待ってから返す」にすることを提案する（VDProcess は本チケットのパスではないので触らない）

## 9. SPEC の変更

なし

## 10. マージ後にやること

なし
