# T-12 VDProcess: ProcessRunner（run / spawn / terminateAll）

- Phase: 2（記録の土台）
- 前提: T-10（`BlockingIO`）。TestSupport の `TempDirectory`（T-01）は T-10 の前提として入っている
- 見積もり: 実装 約 450 行、テスト 約 400 行

## 1. 目的

子プロセスを `posix_spawn` で**新しいプロセスグループ**として起動し、引数は配列だけで渡し（シェルを通さない）、環境変数は呼び手が明示したものだけを渡す。
完了まで待つ `run`（whisper-cli・diskutil・launchctl・reaper・`--help` の検査）と、起動して手放す `spawn`（llama-server）を用意する。
タイムアウトと終了はプロセスグループごと SIGTERM → 猶予 → SIGKILL で行い、孫まで消す（ASR-07）。**actor を止めない**（出力の読み取りは `BlockingIO`、終了は `DispatchSource` で待つ。PLAN §2.1）。

## 2. 参照

- PLAN §2.1（actor の中で長い同期処理をしない・子の終了の待ち方）、§8.2、§8.4（whisper の失敗文言は stderr の末尾）、§8.5（llama-server の起動と停止）、§8.15（終了）、CR-02 / CR-03、PR-05 / PR-06、PT-03 / PT-04 / PT-09 / PT-14
- voicedock@d3d595e: `src/voicedock/transcribe.py`（`start_new_session=True`、`killpg`）、`helper/voicedock-ingest-launcher.c`（responsible process の教訓 DEV-04）、`tests/unit/test_transcribe.py`（孫のテスト）

## 3. 作るもの

```
Sources/VDProcess/ProcessSpec.swift
Sources/VDProcess/ProcessResult.swift
Sources/VDProcess/ProcessRunner.swift
Sources/VDProcess/RunningProcess.swift
Sources/VDProcess/Spawn.swift
Sources/VDProcess/OutputTail.swift
Sources/VDProcess/PipeReader.swift
Sources/VDProcess/ExitWaiter.swift
Sources/VDProcess/WaitStatus.swift
Tests/VDProcessTests/Support/ScriptWriter.swift
Tests/VDProcessTests/ProcessRunnerTests.swift
Tests/VDProcessTests/RunningProcessTests.swift
Tests/VDProcessTests/SpawnTests.swift
```

`Package.swift`: `VDProcess`（依存 `VDCore`）と `VDProcessTests`（依存 `VDProcess`・`TestSupport`）は T-01 で宣言済みであること。`VDProcessTests` を持っていなければこの PR で足す。

**import**: `VDProcess` は `Foundation`・`Darwin`・`Synchronization`・`VDCore`（`Synchronization` は PLAN §3.4 ですべてのモジュールに許されている（F-48）。PT-07 の `ImportPolicy.allowedEverywhere` も許す（T-04））。

## 4. 仕様

### 4.1 `ProcessSpec.swift`

```swift
// 子プロセスの起動の指定。引数は配列だけ、環境変数は明示したものだけ（PLAN §8.2、PR-05 / PR-06）。
import Foundation

public struct ProcessSpec: Sendable, Equatable {
    public let executable: URL          // 絶対パスの file URL
    public let arguments: [String]      // argv[1...]（argv[0] は executable のパス）
    public let environment: [String: String]
    public init(executable: URL, arguments: [String], environment: [String: String])
}

public enum ProcessEnvironment {
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// whisper-cli・llama-server・reaper 用
    public static let standard: [String: String] = ["PATH": path, "LANG": "en_US.UTF-8"]
    /// diskutil・launchctl 用（出力の文言をロケールに依存させない）
    public static let cLocale: [String: String] = ["PATH": path, "LC_ALL": "C"]
}

public enum SpawnError: Error, Equatable, Sendable {
    /// posix_spawn の戻り値（ENOENT: 無い、EACCES: 実行権が無い）。指定が不正なとき（相対パス・NUL を含む引数・= を含むか空の環境変数名）は EINVAL
    case spawnFailed(errno: Int32)
    /// pipe(2) の失敗
    case pipeFailed(errno: Int32)
}
```

（`SpawnError` の置き場所は 00-api-map §4 のとおり `ProcessSpec.swift`。）

### 4.2 `ProcessResult.swift`

```swift
// 子プロセスの結果（PLAN §8.2）。
import Foundation

public struct ProcessResult: Sendable, Equatable {
    public enum Termination: Sendable, Equatable {
        case exited(Int32)            // 終了コード
        case signaled(Int32)          // シグナル番号
        case timedOut                 // タイムアウト（または呼び手のタスクの取り消し）でこちらから止めた
        case spawnFailed(errno: Int32)
    }
    public static let stdoutTailLimit = 65_536   // --help の検査用
    public static let stderrTailLimit = 4_096

    public let termination: Termination
    public let stdoutTail: Data      // 末尾 stdoutTailLimit バイト
    public let stderrTail: Data      // 末尾 stderrTailLimit バイト
    public init(termination: Termination, stdoutTail: Data, stderrTail: Data)

    /// UTF-8 として読む（途中で切れた多バイト文字は U+FFFD になる）
    public var stdoutText: String { String(decoding: stdoutTail, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderrTail, as: UTF8.self) }
}
```

### 4.3 `Spawn.swift`（internal。PT-03 の許可場所 `VDProcess/`）

```swift
// posix_spawn の薄い包み。新しいプロセスグループ・CLOEXEC_DEFAULT・stdin は /dev/null（PLAN §8.2）。
import Darwin
import Foundation

struct SpawnedChild: Sendable {
    let pid: pid_t          // = プロセスグループの ID（SETPGROUP で 0 を指定）
    let stdoutFD: Int32     // 親が読む口
    let stderrFD: Int32
}

enum Spawn {
    static func start(_ spec: ProcessSpec) -> Result<SpawnedChild, SpawnError>
}
```

`start` の手順（この順。途中で失敗したら、それまでに作った fd をすべて閉じてから失敗を返す）:

0. `let path = spec.executable.path(percentEncoded: false)`（00-api-map §0。URL からパス文字列を取るのはこの形だけ）
1. 指定の検査（失敗は `.spawnFailed(errno: EINVAL)`。内部関数 `isValid(_:path:)`）: `spec.executable.isFileURL` かつ `path.hasPrefix("/")`。
   `path` と各引数に `"\u{0}"` を含まない。環境変数の名前が空でなく `=` と `"\u{0}"` を含まず、値に `"\u{0}"` を含まない
2. `var out: [Int32] = [-1, -1]; var err: [Int32] = [-1, -1]`。`pipe(&out)`、`pipe(&err)`。失敗 → `.pipeFailed(errno: errno)`（2 本目の失敗では 1 本目の両端を閉じてから）
3. 親の読み口 `out[0]`・`err[0]` に `fcntl(fd, F_SETFD, FD_CLOEXEC)`
4. ファイル操作:
   ```swift
   var actions: posix_spawn_file_actions_t? = nil
   posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
   posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
   posix_spawn_file_actions_adddup2(&actions, out[1], 1)
   posix_spawn_file_actions_adddup2(&actions, err[1], 2)
   ```
5. 属性:
   ```swift
   var attr: posix_spawnattr_t? = nil
   posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
   let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
   posix_spawnattr_setflags(&attr, Int16(flags))
   posix_spawnattr_setpgroup(&attr, 0)                 // 新しいグループ（pgid = 子の pid）
   var defaults: sigset_t = ~0                         // 全シグナルを既定の動作に戻す（アプリが無視している SIGPIPE などを子に持ち込まない）
   posix_spawnattr_setsigdefault(&attr, &defaults)
   var mask: sigset_t = 0                              // シグナルマスクを空に
   posix_spawnattr_setsigmask(&attr, &mask)
   ```
   （Darwin の `sigemptyset` / `sigfillset` はマクロで Swift から呼べないので、`sigset_t`（`UInt32`）に直接 `0` / `~0` を入れる）
6. `argv = [path] + spec.arguments`、`envp = spec.environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }`（**キーの昇順**。子が見る環境の順を決定的にする）。
   それぞれ `strdup` した `UnsafeMutablePointer<CChar>?` の配列の末尾に `nil` を足して渡し、呼び出しの後で `free` する（内部関数 `static func withCStringArray<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R`。`free` は `defer { for pointer in pointers { free(pointer) } }`。`forEach` は swift-format の `ReplaceForEachWithForLoop` で落ちる）
7. `let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)`（**`posix_spawnp` は使わない**。PATH を探さない）
8. 親の側の書き口 `out[1]`・`err[1]` を閉じる（成功・失敗とも）
9. `rc != 0` → 読み口を閉じて `.spawnFailed(errno: rc)`。成功 → `.success(SpawnedChild(pid: pid, stdoutFD: out[0], stderrFD: err[0]))`

- `POSIX_SPAWN_CLOEXEC_DEFAULT` により、子は 0・1・2 以外の fd を受け継がない（アプリが開いている DB やデバイスの fd を子に渡さない）
- `posix_spawn` で子として起動するので、TCC の responsible process はアプリのまま（DEV-04。`execv` で置き換えると許可が届かなかった）

### 4.4 `OutputTail.swift`（internal）

```swift
// パイプの出力の末尾だけを持つ。読み取りのスレッドと呼び手が共有する（Mutex。@unchecked を使わない）。
import Foundation
import Synchronization

final class OutputTail: Sendable {
    let limit: Int
    private let state: Mutex<State>
    struct State { var data = Data(); var finished = false; var stopRequested = false }

    init(limit: Int) { self.limit = limit; self.state = Mutex(State()) }

    /// 末尾 limit バイトだけを残す
    func append(_ bytes: UnsafeRawBufferPointer) {
        state.withLock { s in
            s.data.append(contentsOf: bytes)
            if s.data.count > limit { s.data = Data(s.data.suffix(limit)) }
        }
    }
    func finish() { state.withLock { $0.finished = true } }
    func requestStop() { state.withLock { $0.stopRequested = true } }
    var isFinished: Bool { state.withLock { $0.finished } }
    var shouldStop: Bool { state.withLock { $0.stopRequested } }
    var snapshot: Data { state.withLock { $0.data } }
}
```

### 4.5 `PipeReader.swift`（internal）

```swift
// パイプを EOF（か停止要求）まで読む。BlockingIO の上で動かし、actor を止めない（PLAN §2.1）。
import Darwin
import Foundation
import VDCore

enum PipeReader {
    static let chunkBytes = 65_536
    static let pollMilliseconds: Int32 = 100

    static func drain(fd: Int32, into tail: OutputTail) async {
        _ = try? await BlockingIO.run {
            var buffer = [UInt8](repeating: 0, count: chunkBytes)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while !tail.shouldStop {
                let ready = poll(&pfd, 1, pollMilliseconds)
                if ready == 0 { continue }
                if ready < 0 { if errno == EINTR { continue } else { break } }
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkBytes) }
                if n > 0 {
                    buffer.withUnsafeBytes { tail.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                } else if n == 0 {
                    break                                   // EOF（書き口がすべて閉じた）
                } else if errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    break
                }
            }
            close(fd)
            tail.finish()
        }
    }
}
```

- 出力を**読み続ける**ことが要る（読まないとパイプの 64 KiB が詰まり、子が書き込みで止まる。llama-server は数時間ログを出し続ける）
- `poll` の 100 ms は停止要求（§4.7 の「読み取りの後始末」）に気付くための間隔

### 4.6 `ExitWaiter.swift` / `WaitStatus.swift`（internal）

```swift
// 子の終了を DispatchSource（kqueue の NOTE_EXIT）と continuation で待つ。waitpid で actor を止めない（PLAN §2.1）。
import Darwin
import Foundation
import Synchronization

enum ExitWaiter {
    /// NOTE_EXIT の取りこぼしに備えて waitpid(WNOHANG) を見直す間隔（起動直後）
    static let pollInterval: DispatchTimeInterval = .milliseconds(100)
    /// pollInterval で見直す回数。過ぎたら slowPollInterval に落とす（取りこぼしは登録の前後にしか起きない。llama-server は数時間動く）
    static let fastPollCount = 50
    /// fastPollCount を過ぎた後の見直しの間隔
    static let slowPollInterval: DispatchTimeInterval = .seconds(5)

    /// waitpid の生の status を返す。回収できなかった（ECHILD など）ときは nil
    static func wait(pid: pid_t) async -> Int32?
}

final class ExitWatch: Sendable {
    private let state: Mutex<State>
    struct State {
        var resumed = false
        var source: (any DispatchSourceProcess)? = nil
        var timer: (any DispatchSourceTimer)? = nil
        var ticks = 0
    }
    init() { state = Mutex(State()) }
    func attach(_ s: any DispatchSourceProcess, timer t: any DispatchSourceTimer) {
        state.withLock { st in
            st.source = s
            st.timer = t
        }
    }
    /// 予備のタイマーが 1 回鳴った。fastPollCount 回目で slowPollInterval に落とす
    func tick() {
        state.withLock { st in
            st.ticks += 1
            if st.ticks == ExitWaiter.fastPollCount {
                st.timer?.schedule(
                    deadline: DispatchTime(uptimeNanoseconds: 0), repeating: ExitWaiter.slowPollInterval,
                    leeway: .seconds(1))
            }
        }
    }
    /// 最初の 1 回だけ true。source（NOTE_EXIT と予備のタイマー）を取り消して手放す
    func claim() -> Bool {
        state.withLock { st in
            if st.resumed { return false }
            st.resumed = true
            st.source?.cancel()
            st.source = nil
            st.timer?.cancel()
            st.timer = nil
            return true
        }
    }
}
```

`wait(pid:)` の手順:

```swift
await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
    let queue = DispatchQueue(label: "voicedock.process.exit")
    let watch = ExitWatch()
    let reap: @Sendable () -> Void = {
        var status: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &status, WNOHANG) } while r == -1 && errno == EINTR
        if r == pid {
            if watch.claim() { continuation.resume(returning: status) }
        } else if r == -1 {
            if watch.claim() { continuation.resume(returning: nil) }
        }
        // r == 0: まだ終わっていない。次のイベントを待つ
    }
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
    // 予備: kqueue への登録は resume の後に非同期で行われ、その前後に終わった子の NOTE_EXIT が届かないことがある
    // （並行に 20 本を 20 回起動して十数本を取りこぼした）。pollInterval ごとに waitpid(WNOHANG) を見直す
    let timer = DispatchSource.makeTimerSource(queue: queue)
    watch.attach(source, timer: timer)  // どちらも resume より前に渡す（claim が取り消せるように）
    source.setEventHandler(handler: reap)
    timer.setEventHandler {
        reap()
        watch.tick()
    }
    timer.schedule(deadline: DispatchTime(uptimeNanoseconds: 0), repeating: pollInterval)
    source.resume()
    timer.resume()
    queue.async(execute: reap)     // source を登録する前に既に終わっていた場合（取りこぼしを防ぐ）
}
```

- **予備のタイマーが要る理由**（実装で分かった）: `DispatchSource.makeProcessSource` の kqueue への登録は `resume()` の後に非同期で行われる。
  `queue.async(execute: reap)` が子の生存中に走り、その直後・登録の前に子が終わると、NOTE_EXIT が届かず continuation が永久に戻らない。
  `setRegistrationHandler` を足しても直らなかった（登録に失敗した source は登録の通知も終了の通知も出さない）。
  診断の試験（`/usr/bin/true` と「起動直後に SIGKILL する `/bin/sleep 30`」を 20 本並行に 20 回）で 400 本中 13〜23 本を取りこぼし、タイマーを足して 0 本になった
- タイマーの初回は `DispatchTime(uptimeNanoseconds: 0)`（過去の時刻 = すぐ）。`DispatchTime.now()` は PT-09 で使えない
- 起動から 5 秒（100 ms × 50 回）を過ぎたら 5 秒ごと（leeway 1 秒）に落とす。メニューバーに常駐するアプリで、数時間動く llama-server のために 10 Hz で起き続けないため
- `ExitWatch.attach` の引数は `any DispatchSourceProcess` と `any DispatchSourceTimer` の型のまま持つ（`[any DispatchSourceProtocol]` に入れると Swift 6 の region isolation で `withLock` の中に渡せない）

- `waitpid` を呼ぶのはここだけ（`waitpid(-1, …)` は使わない。他の子を横取りしない）

`WaitStatus.termination(_ raw: Int32?) -> ProcessResult.Termination`（Darwin の `WIFEXITED` などはマクロで使えないので自前で）:
`raw == nil` → `.exited(-1)`。`let low = raw & 0x7f`。`low == 0` → `.exited((raw >> 8) & 0xff)`。それ以外 → `.signaled(low)`（停止状態 0x7f は `WUNTRACED` を渡さないので起きない）。

### 4.7 `ProcessRunner.swift`

```swift
// 子プロセスの実行（PLAN §8.2）。起動・出力の末尾・タイムアウト・プロセスグループごとの停止。
import Darwin
import Foundation
import Synchronization
import VDCore

public protocol ProcessRunning: Sendable {
    func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult
    func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess
}

public actor ProcessRunner: ProcessRunning {
    public static let killGrace: Duration = .seconds(5)          // SIGTERM から SIGKILL まで（PLAN §8.2）
    static let readerDrainGrace: Duration = .seconds(2)          // 子の終了後に出力の EOF を待つ上限

    private var active: Set<pid_t> = []                           // run 中と spawn 中の子（= プロセスグループ）

    public init() {}
    public func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult
    public func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess
    public func terminateAll(grace: Duration) async
    func unregister(_ pid: pid_t) { active.remove(pid) }

    /// プロセスグループへシグナルを送る（ESRCH は無視）
    static func signalGroup(_ pgid: pid_t, _ signal: Int32) { _ = kill(-pgid, signal) }
    /// exit が timeout 以内に終われば true。呼び手のタスクが取り消されていれば false（= 止める側に倒す）
    static func race(exit: Task<Int32?, Never>, timeout: Duration) async -> Bool
    /// 出力の EOF を readerDrainGrace だけ待ち、過ぎたら読み取りに停止を要求して終わりを待つ
    static func finishReaders(_ readers: Task<Void, Never>, _ tails: [OutputTail]) async
    /// task が timeout 以内に終われば true。時間切れと呼び手のタスクの取り消しは false（race と finishReaders の本体）
    static func finishes<T: Sendable>(_ task: Task<T, Never>, within timeout: Duration) async -> Bool
}

/// 最初に決まった Bool を 1 回だけ返す（finishes の時間切れと終了の早い方）。同じ ProcessRunner.swift に置く internal の補助
final class FirstOutcome: Sendable {
    private let state: Mutex<State>          // ProcessRunner.swift は Synchronization も import する
    struct State {
        var settled: Bool? = nil
        var continuation: CheckedContinuation<Bool, Never>? = nil
    }
    init() { state = Mutex(State()) }
    /// 最初の 1 回だけが効く。待っている value() があれば起こす
    func settle(_ result: Bool)
    /// 決まるまで待つ（既に決まっていればすぐ返す）
    func value() async -> Bool
}
```

`run(_:timeout:)` の手順:

1. `Spawn.start(spec)`。失敗 → `ProcessResult(termination: .spawnFailed(errno: e), stdoutTail: Data(), stderrTail: Data())`（`pipeFailed(e)` も `.spawnFailed(errno: e)`。**投げない**）
2. `let stdout = OutputTail(limit: ProcessResult.stdoutTailLimit)`、`let stderr = OutputTail(limit: ProcessResult.stderrTailLimit)`
3. `let readers = Task { async let a: Void = PipeReader.drain(fd: child.stdoutFD, into: stdout); async let b: Void = PipeReader.drain(fd: child.stderrFD, into: stderr); _ = await (a, b) }`
4. `let exit = Task { await ExitWaiter.wait(pid: child.pid) }`（**非構造化タスク**。呼び手の取り消しで待ちが中断されない）
5. `active.insert(child.pid)`
6. `var timedOut = false`。`if await !Self.race(exit: exit, timeout: timeout)` なら:
   `timedOut = true` → `signalGroup(pid, SIGTERM)` → `if await !Self.race(exit: exit, timeout: Self.killGrace) { signalGroup(pid, SIGKILL) }`
7. `let raw = await exit.value`
8. `signalGroup(pid, SIGKILL)`（**子の終了後に同じグループに残った孫を消す**。正常終了でも行う。グループが無ければ ESRCH で何も起きない）
9. `await Self.finishReaders(readers, [stdout, stderr])`
10. `active.remove(child.pid)`
11. `ProcessResult(termination: timedOut ? .timedOut : WaitStatus.termination(raw), stdoutTail: stdout.snapshot, stderrTail: stderr.snapshot)`

`race(exit:timeout:)` は `await finishes(exit, within: timeout)`。

`finishes(_:within:)`:

```swift
let outcome = FirstOutcome()
Task {  // task が終われば自然に終わる
    _ = await task.value
    outcome.settle(true)
}
let timer = Task {
    try? await Task.sleep(for: timeout)
    outcome.settle(false)
}
let first = await withTaskCancellationHandler {
    await outcome.value()
} onCancel: {
    outcome.settle(false)  // 取り消し（呼び手の取り消し）は「時間切れ」と同じに扱い、止める側へ倒す
}
timer.cancel()
return first
```

`FirstOutcome.settle(_:)` は `withLock` の中で「未決なら `settled` に入れ、待っている continuation を取り出す」だけを行い、`resume` はロックの外で呼ぶ。
`value()` は `withCheckedContinuation` の中で `withLock` し、決まっていればその値ですぐ `resume`、未決なら continuation を預ける。

- **`withTaskGroup` を使わない理由**（実装で分かった）: `withTaskGroup` は本体を抜ける前に残った子タスクを待つ。`Task.value` の待ちは取り消しで中断されないので、
  「時間切れ」の側が先に返っても `exit.value` を待つ子が残り、`race` は子が終わるまで返らなかった（`timeoutKillsChildAndGrandchild` が 30 秒、`cancellingTheCallerStopsTheChild` が 30 秒かかった）。
  `finishReaders` も同じで、停止要求が EOF の後にしか届かなかった

- `Task.sleep(for:)` を使ってよい（実プロセスの時間切れは実時間で測る。`Sleeper` の注入は Worker などの待ちのためのもので、ここには使わない）。`ContinuousClock()` は書かない（PT-09）
- 呼び手の `Task` が取り消されると、`onCancel` が即座に `false` に決めるので、子は SIGTERM → 即座に SIGKILL で止まり、`.timedOut` が返る
- 取り消された後は `finishReaders` の `finishes` もすぐ `false` を返すので、EOF を待たずに停止を要求する（パイプに残った最後の出力を読み落とすことがある）。
  取り消された `run` の結果は `.timedOut` で、出力の末尾は使わない前提。停止の後の stderr の末尾が要る呼び手（T-21）は、`RunningProcess.terminate` を取り消されていないタスクから呼ぶ

`finishReaders(_:_:)`:

```swift
let done = await finishes(readers, within: readerDrainGrace)
if !done {
    for tail in tails { tail.requestStop() }
    await readers.value
}
```

（EOF が来ないのは、グループの外へ出た子孫（`setsid` したデーモンなど）が書き口を持ち続けている場合だけ。停止要求で 100 ms 以内に読み取りが終わる）

`spawn(_:)` の手順:

1. `let child = try Spawn.start(spec).get()`（`SpawnError` をそのまま投げる）
2. `OutputTail` を 2 つ（64 KiB / 4 KiB）、`readers` のタスク（run と同じ）
3. `let record = ExitRecord()`、`let exit = Task { let raw = await ExitWaiter.wait(pid: child.pid); record.set(raw); return raw }`
4. `active.insert(child.pid)`
5. `let process = RunningProcess(pid: child.pid, exit: exit, record: record, readers: readers, stdout: stdout, stderr: stderr)`
6. `Task { _ = await exit.value; self.unregister(child.pid) }`（actor の中で作った `Task` は actor に隔離されるので `await` は要らない。書くと「async の操作が無い await」の警告 = エラー）
7. `return process`

`terminateAll(grace:)`（アプリの終了。PLAN §8.15）:

1. `let pids = active`（写しを取る）。空なら何もしない
2. 各 pid に `signalGroup(pid, SIGTERM)`
3. `try? await Task.sleep(for: grace)`
4. `active` にまだ残っている pid（`pids.intersection(active)`）に `signalGroup(pid, SIGKILL)`
5. run 中の子は、それぞれの `run` が終了を観測して結果を返す（`.signaled(SIGTERM)` か `.signaled(SIGKILL)`）

### 4.8 `RunningProcess.swift`

```swift
// spawn した子（llama-server）。止めるのは terminate（PLAN §8.5）。
import Darwin
import Foundation
import Synchronization

public final class RunningProcess: Sendable {
    public let pid: pid_t
    let exit: Task<Int32?, Never>
    let record: ExitRecord
    let readers: Task<Void, Never>
    let stdout: OutputTail
    let stderr: OutputTail

    init(pid: pid_t, exit: Task<Int32?, Never>, record: ExitRecord, readers: Task<Void, Never>, stdout: OutputTail, stderr: OutputTail)

    public var isRunning: Bool { get async { !record.isSet } }
    public func stderrTail() async -> Data { stderr.snapshot }
    public func stdoutTail() async -> Data { stdout.snapshot }
    /// SIGTERM（グループ）→ grace 待つ → SIGKILL（グループ）。既に終わっていれば、その終わり方を返す
    public func terminate(grace: Duration) async -> ProcessResult.Termination
    /// 終了を待つ（llama-server が勝手に落ちたことの検出に使う）
    public func waitForExit() async -> ProcessResult.Termination
}

final class ExitRecord: Sendable {
    private let state: Mutex<(set: Bool, raw: Int32?)>
    init() { state = Mutex((set: false, raw: nil)) }
    func set(_ raw: Int32?) { state.withLock { $0 = (true, raw) } }
    var isSet: Bool { state.withLock { $0.set } }
    var raw: Int32? { state.withLock { $0.raw } }
}
```

`terminate(grace:)`:

1. `if record.isSet { return WaitStatus.termination(record.raw) }`
2. `ProcessRunner.signalGroup(pid, SIGTERM)`
3. `if await !ProcessRunner.race(exit: exit, timeout: grace) { ProcessRunner.signalGroup(pid, SIGKILL) }`
4. `let raw = await exit.value` → `ProcessRunner.signalGroup(pid, SIGKILL)`（残った孫）→ `await ProcessRunner.finishReaders(readers, [stdout, stderr])`
5. `return WaitStatus.termination(raw)`（`.timedOut` は返さない。実際の終わり方を返す）

`waitForExit()`: `WaitStatus.termination(await exit.value)`

### 4.9 使う側の約束（後続のチケットが守る）

- 実行ファイルのパスは `AppPaths` / `HomeLayout` から得た絶対パス（`/usr/sbin/diskutil`・`/bin/launchctl` は定数）
- whisper-cli・llama-server・reaper は `ProcessEnvironment.standard`、diskutil・launchctl は `ProcessEnvironment.cLocale`
- テストは `ProcessRunning` プロトコルで偽物に差し替える（本物の `ProcessRunner` のテストはこのチケットだけ）

## 5. テスト

共通: スイートはすべて `@Suite(…, .serialized, .timeLimit(.minutes(1)))`（プロセスグループとシグナルを扱うため直列）。
スクリプトは `ScriptWriter.write(_ body: String, name: String, in dir: URL) throws -> URL`（`#!/bin/sh\n` + body を書いて `chmod 0755`。テストのターゲットの中の補助。`AtomicFile` は使わなくてよい）。
孫の消滅の確認は `waitUntilGone(pid:within:)`（`kill(pid, 0) == -1 && errno == ESRCH` になるまで 50 ms ごとに最大 2 秒。ゾンビの間は `kill` が成功するため待つ）。`ScriptWriter.swift` に置き、pid ファイルを読む `readPID(_:)` も同じ所に置く。
経過時間はテストの中で `ContinuousClock` を使って測る（PT-09 は `Sources/` だけが対象）。

**書いたばかりのスクリプトの最初の exec は macOS の検査で 0.1〜0.3 秒かかる**（実装で分かった）。その間に届いた SIGTERM は `trap` より先に効くので、
時間切れの短いテスト（`timeoutKillsChildAndGrandchild`・`timeoutEscalatesToSIGKILL`）はスクリプトの先頭に `[ "$1" = warm ] && exit 0` を置き、
引数 `warm` で 1 回空で起動してから本番を起動する（テスト内の補助 `warmUp(_:)`）。`terminateEscalatesToSIGKILL` はスクリプトに `echo ready >&2` を足し、
`stderrTail()` に `ready` が出るまで待ってから `terminate` する（補助 `waitForStderr(_:containing:)`。`stderrTailWhileRunning` と共用）。

### 5.1 `ProcessRunnerTests.swift` — `@Suite("ProcessRunner.run")`

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `argumentsArePassedVerbatim` | 引数は配列のまま渡りシェルを通らない | `/usr/bin/printf` に `["%s\|", "a b", "$HOME", "; echo x", "*", ""]` | `.exited(0)`、stdout が `a b\|$HOME\|; echo x\|*\|\|` |
| `environmentIsOnlyWhatIsGiven` | 環境変数は渡したものだけ（キーの昇順） | `/usr/bin/env`、環境 `["B": "2", "A": "1"]` | stdout がちょうど `A=1\nB=2\n` |
| `emptyEnvironment` | 空の環境でも起動できる | `/usr/bin/env`、`[:]` | stdout が空、`.exited(0)` |
| `exitCodeIsReported` | 終了コードを返す | スクリプト `exit 7` | `.exited(7)` |
| `signalIsReported` | シグナルで終わったことを返す | スクリプト `kill -USR1 $$` | `.signaled(SIGUSR1)` |
| `stdinIsDevNull` | stdin は /dev/null（待たずに終わる） | `/bin/cat` | `.exited(0)`、stdout が空、1 秒以内に返る |
| `missingExecutableIsSpawnFailed` | 無い実行ファイルは spawnFailed(ENOENT) | `<tmp>/nope` | `.spawnFailed(errno: ENOENT)`、tail は空 |
| `nonExecutableIsSpawnFailed` | 実行権の無いファイルは spawnFailed(EACCES) | 0644 のスクリプト | `.spawnFailed(errno: EACCES)` |
| `relativePathIsRejected` | 相対パスは EINVAL | executable に `try #require(URL(string: "file:ls"))`（file URL だがパスが `/` で始まらない） | `.spawnFailed(errno: EINVAL)` |
| `nulInArgumentIsRejected` | NUL を含む引数は EINVAL | `["a\u{0}b"]` | `.spawnFailed(errno: EINVAL)` |
| `stderrTailKeepsLast4KiB` | stderr は末尾 4 KiB | `0123456789` を 1000 回 stderr へ、最後に `END` | `stderrTail.count == 4096`、末尾が `END` |
| `stdoutTailKeepsLast64KiB` | stdout は末尾 64 KiB | `head -c 100000 /dev/zero \| tr '\0' x; printf END` | `stdoutTail.count == 65536`、末尾が `END` |
| `largeOutputDoesNotBlockChild` | 大量の出力でも子が止まらない | stdout と stderr にそれぞれ 1 MB | 5 秒以内に `.exited(0)` |
| `newProcessGroup` | 子は新しいプロセスグループの先頭 | `echo $$; ps -o pgid= -p $$`（環境 `standard`） | 2 行の値（空白を除く）が等しく、`getpgrp()` と違う |
| `childDoesNotInheritParentFDs` | 子は 0・1・2 以外の fd を受け継がない | テストで `/dev/null` を開き `dup2(fd, 200)`、`/bin/ls /dev/fd` | 出力の行に `200` が無い（後で `close(200)`） |
| `timeoutKillsChildAndGrandchild` | タイムアウトで子と孫をグループごと止める（ASR-07） | `[ "$1" = warm ] && exit 0` + `sleep 30 & echo $! > "$1"; sleep 30`、`warmUp` の後に timeout 0.5 秒 | `.timedOut`、5 秒未満で返る（子の `sleep 30` が自然に終わるのを待っていない）、pid ファイルの孫が 2 秒以内に消える |
| `timeoutEscalatesToSIGKILL` | SIGTERM を無視する子は 5 秒後に SIGKILL | `[ "$1" = warm ] && exit 0` + `trap '' TERM; sleep 30`、`warmUp` の後に timeout 0.2 秒 | `.timedOut`、経過が 5 秒以上 8 秒未満 |
| `lingeringGrandchildIsKilledAfterExit` | 正常終了でもグループに残った孫を消す | `sleep 30 & echo $! > "$1"; exit 0` | `.exited(0)`、2 秒以内に返り、孫が消える |
| `runsDoNotBlockEachOther` | 2 つの run は並行に進む（actor を止めない） | `async let` で `/bin/sleep 1` を 2 つ | 両方 `.exited(0)`、合計の経過が 1.9 秒未満 |
| `cancellingTheCallerStopsTheChild` | 呼び手のタスクを取り消すと子を止める | `Task { await runner.run(sleep 30, timeout: 60 秒) }` を 0.2 秒後に `cancel()` | `.timedOut`、1 秒以内に返る |
| `exitWaiterDoesNotMissEarlyExit` | すぐ終わる子の終了を取りこぼさない | `/usr/bin/true` を 50 回 `run(timeout: 5 秒)` | すべて `.exited(0)`、合計 10 秒未満 |

### 5.2 `RunningProcessTests.swift` — `@Suite("ProcessRunner.spawn")`

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `spawnAndTerminate` | spawn した子を terminate で止める | `/bin/sleep 30` を spawn | `isRunning == true` → `terminate(grace: 1 秒)` が `.signaled(SIGTERM)` → `isRunning == false` |
| `terminateTwiceReturnsSameResult` | 2 回目の terminate は最初の終わり方を返す | 上に続けて | 同じ `.signaled(SIGTERM)`、すぐ返る |
| `terminateEscalatesToSIGKILL` | SIGTERM を無視する子は grace の後 SIGKILL | `trap '' TERM; echo ready >&2; sleep 30`、`ready` を待ってから（2 秒で出なければ `#require` で止める）grace 0.5 秒 | `.signaled(SIGKILL)` |
| `spawnMissingExecutableThrows` | 無い実行ファイルの spawn は SpawnError | `<tmp>/nope` | `SpawnError.spawnFailed(errno: ENOENT)` を投げる |
| `stderrTailWhileRunning` | 動いている間も stderr の末尾を読める | `echo ready >&2; sleep 30` | 2 秒以内に `stderrTail()` が `ready\n` を含む。最後に terminate |
| `waitForExitReportsCrash` | 勝手に終わったことを waitForExit で知れる | `sleep 0.2; exit 3` | `waitForExit()` が `.exited(3)`、`isRunning == false` |
| `terminateAllStopsSpawnedAndRunning` | terminateAll は spawn した子と run 中の子を止める | spawn 2 つ（`sleep 30`）＋別タスクで `run(sleep 30, timeout: 60 秒)`、0.2 秒後に `terminateAll(grace: 1 秒)` | spawn の 2 つが `isRunning == false`、run が `.signaled(SIGTERM)` を返す |

### 5.3 `SpawnTests.swift` — `@Suite("Spawn")`（internal を `@testable import VDProcess` で）

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `waitStatusDecoding` | waitpid の status を終了コードとシグナルに写す | `0x0700` → `.exited(7)`、`0x0009` → `.signaled(9)`、`nil` → `.exited(-1)` |
| `outputTailKeepsSuffix` | OutputTail は末尾だけを持つ | limit 4 に `abc` と `defg` を足すと `defg` |
| `exitWaiterConcurrentEarlyExits` | 並行に起動してすぐ終わる子の終了も取りこぼさない | `Spawn.start` で `/usr/bin/true` と「起動直後に SIGKILL する `/bin/sleep 30`」を交互に 20 本並行、それを 20 回。各本を `ExitWaiter.wait` で待ち、`ProcessRunner.finishes(_, within: 3 秒)` が全部 true（取りこぼし 0 本。取りこぼした子は SIGKILL と `waitpid` で回収して pid を記録） |
| `environmentKeyWithEqualsIsRejected` | = を含む環境変数名は EINVAL | `Spawn.start` が `.spawnFailed(errno: EINVAL)` |

## 6. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | `POSIX_SPAWN_SETPGROUP` を flags から外す | `newProcessGroup`、`timeoutKillsChildAndGrandchild` |
| 2 | `signalGroup` を `kill(pgid, signal)`（グループでなく本人だけ）にする | `timeoutKillsChildAndGrandchild`、`lingeringGrandchildIsKilledAfterExit` |
| 3 | `POSIX_SPAWN_CLOEXEC_DEFAULT` を外す | `childDoesNotInheritParentFDs` |
| 4 | envp に `ProcessInfo.processInfo.environment` を混ぜる（PT-18 にも反する） | `environmentIsOnlyWhatIsGiven`、`emptyEnvironment` |
| 5 | `run` の手順 6 の SIGKILL への引き上げを消す | `timeoutEscalatesToSIGKILL`（1 分の制限で落ちる） |
| 6 | `OutputTail.append` で先頭を残す（`prefix(limit)`） | `stderrTailKeepsLast4KiB`、`stdoutTailKeepsLast64KiB`、`outputTailKeepsSuffix` |
| 7 | `run` の手順 8（終了後のグループへの SIGKILL）を消す | `lingeringGrandchildIsKilledAfterExit` |
| 8 | `finishes` の `onCancel` を `outcome.settle(true)` にする | `cancellingTheCallerStopsTheChild` |
| 9 | `ExitWaiter` の `queue.async(execute: reap)` と予備のタイマーの `timer.resume()` を両方消す | `exitWaiterConcurrentEarlyExits`（source の登録より前に終わった子を取りこぼす） |
| 10 | `PipeReader` の読み取りを子の終了後にだけ始める | `largeOutputDoesNotBlockChild` |
| 11 | 予備のタイマーの `timer.resume()` だけを消す | `exitWaiterConcurrentEarlyExits` |


## 7. 受け入れ条件

- [ ] §3 のファイルがすべて在り、`swift build` と `make test` が通る（`VDProcessTests` が 1 分以内）
- [ ] `posix_spawn` は `Sources/VDProcess/Spawn.swift` にだけ在る。`posix_spawnp`・`Process(`・`NSTask`・`fork`・`exec*` がどこにも無い（PT-03）
- [ ] シェルのパス（`/bin/sh` など）の文字列と `system(` / `popen(` が `Sources/` に無い（PT-04）
- [ ] `@unchecked Sendable` / `nonisolated(unsafe)` を使っていない（状態の共有は `Mutex`。PT-14）
- [ ] `waitpid` の呼び出しは `ExitWaiter.swift` だけで、actor の中で同期的に待っていない
- [ ] PLAN §3.4 と PT-07 の許可リストに `Synchronization`（VDProcess）を足した
- [ ] 破壊による証明の表の各項目で、表のテストが落ちることを確かめ、PR 本文に貼った

## 8. SPEC の変更

なし。

## 9. マージ後にやること

なし。

## 10. API 地図への変更提案

1. **`Synchronization` の import を VDProcess に許す**（PLAN §3.4 の VDProcess 行に足す）。出力の末尾と終了の記録を、読み取りのスレッド・終了の通知・呼び手が共有するため `Mutex` を使う（`@unchecked Sendable` を使わずに Swift 6 の strict concurrency を満たす唯一の簡単な方法。macOS 15 以上で使える）。同じ理由で後続のチケット（VDDevice の `IngestActivity` など）でも要るなら、そのチケットで同じ提案をする → PLAN §3.4（F-48）と 00-api-map §0 に反映済み（2026-09-18。すべてのモジュールで import してよい）
2. `SpawnError` を `ProcessResult.swift` に定義する（API 地図に型の定義が無い）: `spawnFailed(errno:)`、`pipeFailed(errno:)` → 00-api-map に反映済み（2026-09-18）。ただし地図の置き場所は `ProcessSpec.swift` なので、§4.1 に移した（整合修正）
3. `ProcessSpec` に `Equatable` と `init`、`ProcessResult` に `init`・`stdoutText`・`stderrText`・`stdoutTailLimit`・`stderrTailLimit` を足す → 00-api-map に反映済み（2026-09-18）
4. `ProcessEnvironment.path`（PATH の値）を足す → 00-api-map に反映済み（2026-09-18）
5. `RunningProcess` に `stdoutTail()` と `waitForExit()` を足す（llama-server が勝手に落ちたことの検出。T-21 が使う） → 00-api-map に反映済み（2026-09-18）
6. `ProcessRunner.killGrace`（5 秒）を public の定数にする → 00-api-map に反映済み（2026-09-18）
7. PLAN §8.2 の `spawn` は `throws`（型なし）、API 地図は `throws(SpawnError)`。API 地図に合わせて型付きにする（PLAN の表記を直す） → PLAN §8.2 に反映済み（2026-09-18）
