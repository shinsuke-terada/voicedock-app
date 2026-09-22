# T-37 voicedock-reaper（削除を実行する唯一の実行ファイル）

| 項目 | 値 |
|---|---|
| ID | T-37 |
| Phase | 8（削除） |
| 前提 | T-07（`TargetIdentity`・`IdentityReason`・`FakeVolume`・`DiskImageVolume`）。間接に T-06（`HomeLayout`・`ReaperConf`・`ContractJSON`・`AtomicFile`・`FileLock`・`RequestID`・`AppVersion`・`Contract`）、T-01（`Package.swift` の `voicedock-reaper` ターゲットと `ReaperTests`、`TempDirectory`・`TestEnvironment`）、T-04（PT-01・08・09・12・15・22）、T-05（SPEC 同期の ND / RV の表） |
| 見積もり | Sources 約 720 行、Tests 約 1,000 行（層 R1・R3 を別ファイルに分けるので 600 行を超える。PR 本文に理由を書く） |
| ブランチ | `feat/T-37-reaper` |
| 後続 | T-38（`ReaperRunner.run` が起動する・`installRealReaper`・`.diskImage` の往復）、T-39・T-41・T-42 |

## 1. 目的

デバイス上の元音声を `unlink` できる唯一のプログラム `voicedock-reaper` を Swift で書く（PLAN §8.9.4）。
アプリの判断を一切信用せず、RV-00〜RV-13 を独立に再検証し、1 つでも偽なら削除しない。
あわせて、層 R1（普通のディレクトリ）と層 R3（FAT32 のディスクイメージ）の ND / RV テストと、
**ビルドした実行ファイルを実際に起動する**テスト部品 `ReaperBinary`（00-api-map §15 の作り手は T-37）を作る。

## 2. 参照

- PLAN §8.9.2（三重ロックとロック 1 の観測）、**§8.9.3 の 3（RV-00）**、**§8.9.4（全体。処理の順序の表が規範）**、§4.1〜§4.6（名前規則・鍵・relpath・要求／結果の JSON・共有定数・`TargetIdentity`）、§2.1（`reaper.lock`・`flock`）、§2.3（`<HOME>` の配置）、§3.4（import の許可リスト）、§8.15（ログの値の書式）、§9.4（PT-01・08・09・12・15・20・22）、§10.5（層 R1〜R3 の分け方）、付録 B.1（ND-18〜20・22(R)・23〜25・27〜29・31・37〜40・43・44）、付録 B.2（RV と理由語）、付録 F の F-51
- 00-api-map §0・§1（VDContract の全 API）・§13（`voicedock-reaper` のファイル）・§14（`ReaperTests` の依存）・§15（`ReaperBinary` の作り手）・§16
- 先行チケット: T-06 §4.12〜§4.19（`RequestID`・`DeleteRequest`／`DeleteResult`・`ContractJSON`・`ReaperConf`・`HomeLayout`・`AtomicFile`・`FileLock`）、T-07 §4.1〜§4.5（`TargetIdentity`・`IdentityReason`・`FakeVolume`・`DiskImageVolume`）
- voicedock@d3d595e: `helper/voicedock-reaper`（全体。`locks_are_released` 292-314、`process_request` 212-281、`target_is_identical` 138-173、`write_result` 180-197、`reject` 283-288、`main` 320-357）、`d419397` の差分（`request_id_is_safe`・`move_to_rejected`）、`tests/unit/test_reaper.py`
- 移植メモ V1 §4（`4.1` 起動と設定、`4.2` 1 件の処理順、`4.3` d419397、**`4.4` Swift reaper の推奨仕様**）、§8（RV と voicedock の検証番号の対応）

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/voicedock-reaper/main.swift` | 入口（`print` と stderr への書き出しはこのファイルだけ。PT-08） |
| `Sources/voicedock-reaper/ReaperArguments.swift` | `ReaperArguments` |
| `Sources/voicedock-reaper/SelfLocation.swift` | `SelfLocation`（RV-00） |
| `Sources/voicedock-reaper/ReaperMain.swift` | `ReaperMain`・`ReaperExit`（起動時の検査 → flock → 走査 → 1 件ずつ） |
| `Sources/voicedock-reaper/RequestProcessor.swift` | `RequestProcessor`・`RequestOutcome`（RV-02〜RV-13） |
| `Sources/voicedock-reaper/QueueFiles.swift` | `QueueFiles`（列挙・読み取り・`rejected/` への rename・結果の書き込み。PT-12 の許可場所） |
| `Sources/voicedock-reaper/ProcessedLog.swift` | `ProcessedLog`（PT-12 の許可場所） |
| `Sources/voicedock-reaper/ReaperLog.swift` | `ReaperLog`（PT-08・PT-12 の許可場所） |
| `Sources/voicedock-reaper/ReaperClock.swift` | `ReaperClock`（PT-09 の許可場所） |
| `Sources/voicedock-reaper/Unlinker.swift` | `Unlinker`（PT-01 の許可場所） |
| `Sources/voicedock-reaper/Signals.swift` | `Signals`（SIGTERM） |
| `Sources/voicedock-reaper/ReaperIO.swift` | `ReaperIO`（fd の読み書きの共通部。00-api-map §13 に足す。§11 の提案 1） |
| `Tests/TestSupport/ReaperBinary.swift` | `ReaperBinary`・`ReaperRun`・`ReaperProcess`・`ReaperBinaryError`（作り手 T-37） |
| `Tests/ReaperTests/ReaperBench.swift` | 層 R1・R3 が共有する舞台（test ターゲット内の internal） |
| `Tests/ReaperTests/ReaperArgumentsTests.swift` | 引数・`--version`・RV-00（層 R1） |
| `Tests/ReaperTests/ReaperConfGateTests.swift` | reaper.conf とロック 1（層 R1） |
| `Tests/ReaperTests/ReaperQueueTests.swift` | 走査・RV-02〜RV-06・ロック・ログ・SIGTERM（層 R1） |
| `Tests/ReaperTests/ReaperDiskImageTests.swift` | 層 R3（`.diskImage`） |
| `Tests/PolicyTests/SpecSync/SpecCoverage.swift`（変更） | `activated` に `.rv` を足す（T-05 §4。T-37 の積み残しを issue #87 で足した） |
| `Tests/PolicyTests/SpecSync/SpecCoverageTests.swift`（行を直す） | `activatedKeepsTheCheckedKinds` が `.rv` も含むこと（§5.5） |

`Tests/ReaperTests/TargetIdentityNDTests.swift`（層 R2）は **T-07 が作る**（このチケットでは作らない）。

## 4. 仕様

共通の約束:

- `p(url)` は `url.path(percentEncoded: false)`。import は **Foundation・Darwin・Synchronization・VDContract だけ**（PLAN §3.4。PT-07・PT-15）
- `Date()` を書いてよいのは `ReaperClock.swift`、`print(` は `main.swift`、`unlinkat(` は `Unlinker.swift`、`O_CREAT`／`rename(`／`renameat(` は `ProcessedLog.swift`・`ReaperLog.swift`・`QueueFiles.swift` だけ（PT-01・08・09・12）
- 子プロセスを起動しない・ネットワークを使わない・ディレクトリを再帰削除しない・マウント操作をしない（PR-19。文字列に `diskutil` を書かない。PT-15）
- **ディレクトリを作らない。**`<HOME>` 配下のディレクトリはアプリの `HomeLayout.createDirectories()` が作る。無ければその書き込みが失敗するだけ（下の「書き込みに失敗したとき」の規則に従う）
- 鍵の照合（RV-02b・RV-05）は**スカラー列の一致**で行う（`Array(a.unicodeScalars) == Array(b.unicodeScalars)`。Swift の `==` は正準等価で比べるため。00-api-map §0）。この比較は `RequestProcessor.scalarsEqual(_:_:)` の 1 か所に置く
- 型はすべて `internal`（実行ファイルのターゲットなので `public` にしない）。テストは `@testable import voicedock_reaper` を使わず、**実行ファイルを起動して外から観測する**（PLAN §10.5）。例外は §5.3 末尾の `@Suite("ReaperLog の行")`（行の書式の単体。§4.6 の `format` / `value` を直接呼ぶ）だけで、`ReaperQueueTests.swift` の先頭で `@testable import voicedock_reaper` する（実装時に確かめた: 実行ファイルのターゲットも `-enable-testing` でビルドされ、テストから import できる）

### 4.1 `ReaperIO.swift`（「// fd の読み書き（voicedock-reaper の中だけ。VDContract の PosixIO は internal で使えない）。」）

```swift
import Darwin
import Foundation

enum ReaperIO {
    /// 最大 limit バイトまで読む。EINTR は再試行、0 で終わり。limit を超えて読めたら nil（大きすぎる）。失敗も nil
    static func readAll(fd: Int32, limit: Int) -> Data?
    /// 部分書き込みを続けて全部書く。EINTR は再試行。成功で true
    static func writeAll(fd: Int32, _ data: Data) -> Bool
    /// realpath(3)。失敗で nil（返った領域は free する）
    static func realpath(_ path: String) -> String?
    /// lstat が成功し S_IFREG なら true
    static func isRegularFile(_ path: String) -> Bool
}
```

- `readAll`: 4096 バイトずつ `read(2)`。読んだ合計が `limit` を超えた時点で nil を返す（呼び手は `limit = Contract.maxRequestBytes + 1` のように 1 バイト多く渡して「超えている」を判定する）

### 4.2 `ReaperClock.swift`（「// reaper の時刻（PLAN §8.9.4。config.json を読まないのでシステムのローカル時刻を使う）。PT-09 の許可場所。」）

```swift
import Foundation

struct ReaperClock: Sendable {
    /// PLAN §4.4・§8.9.4。例 `2026-09-12T18:00:05+09:00`
    static let isoFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
    /// システムのローカルタイムゾーンで今を書式化する
    func nowISO() -> String
}
```

`nowISO()`: `f = DateFormatter()`、`f.locale = Locale(identifier: "en_US_POSIX")`、`f.timeZone = TimeZone.current`、`f.dateFormat = Self.isoFormat`、`f.string(from: Date())`。
（`DateFormatter` は `Sendable` でないので保持せず、呼ばれるたびに作る。呼ばれるのは 1 要求につき 1 回とログ 1 行につき 1 回）

### 4.3 `Signals.swift`（「// SIGTERM を受けたら『今の 1 件の後に止まる』（PLAN §8.9.4）。」）

```swift
import Darwin
import Synchronization

/// ファイルスコープの let（シグナルハンドラは捕捉を持てないのでグローバルに置く。`nonisolated(unsafe)` は使わない。PT-14）
private let stopFlag = Atomic<Bool>(false)

enum Signals {
    /// SIGTERM のハンドラを入れる。ハンドラはアトミックなフラグを立てるだけ（async-signal-safe）
    static func installTerminationHandler() {
        signal(SIGTERM, { _ in stopFlag.store(true, ordering: .relaxed) })
    }
    static var stopRequested: Bool { stopFlag.load(ordering: .relaxed) }
}
```

### 4.4 `ReaperArguments.swift`（「// 引数の解析（PLAN §8.9.4）。`--home <HOME>` か `--version` だけ。」）

```swift
enum ReaperArguments: Equatable, Sendable {
    case version
    case run(home: String)
    case invalid
    static let usage = "usage: voicedock-reaper --home <HOME> | --version\n"
    /// CommandLine.arguments の先頭（実行ファイル名）を落としたもの
    static func parse(_ arguments: [String]) -> ReaperArguments
}
```

`parse`（完全一致。ほかの形は全部 `.invalid`）:
1. `arguments == ["--version"]` → `.version`
2. `arguments.count == 2 && arguments[0] == "--home" && !arguments[1].isEmpty` → `.run(home: arguments[1])`
3. それ以外（`[]`・`["--help"]`・`["-h"]`・`["--home"]`・引数が 3 つ以上）→ `.invalid`

### 4.5 `SelfLocation.swift`（「// RV-00: 自分が `<HOME>/bin/voicedock-reaper` から起動されたことを確かめる（PLAN §8.9.3 の 3）。」）

```swift
import Darwin
import Foundation
import VDContract

enum SelfLocation {
    /// `.app/Contents/` を含むパスは常に偽（バンドル内の reaper を直接起動された場合）
    static let bundleMarker = ".app/Contents/"
    /// `_NSGetExecutablePath` → `realpath(3)`。失敗で nil
    static func executablePath() -> String?
    /// RV-00。真でなければ呼び手は何も書かずに終了コード 3
    static func isAtExpectedPlace(home: String) -> Bool
}
```

`executablePath()`:
1. `var size = UInt32(PATH_MAX)`、`var buf = [CChar](repeating: 0, count: Int(size))`
2. `_NSGetExecutablePath(&buf, &size) == 0` でなければ（バッファが足りない）`buf` を `size` で作り直して 1 回だけやり直す。2 回目も失敗なら nil
3. `raw = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)` → `ReaperIO.realpath(raw)`（symlink 経由で起動された場合に実体へ直す）。`String(cString:)` の配列版は Xcode 27.0 で非推奨の警告になり、警告はエラーなので使わない（実装時に確かめた）

`isAtExpectedPlace(home:)`（この順。どれか 1 つでも偽なら偽）:
1. `guard let selfPath = executablePath() else { return false }`
2. `selfPath.contains(Self.bundleMarker)` なら偽
3. `guard let homeReal = ReaperIO.realpath(home) else { return false }`（`--home` が無いディレクトリなら偽）
4. `expected = p(HomeLayout(root: URL(fileURLWithPath: homeReal, isDirectory: true)).reaperExecutable)`（`reaperExecutable` の語を書いてよい場所。PT-11）
5. `selfPath == expected` でなければ偽（バイト列の完全一致）
6. `ReaperIO.isRegularFile(expected)` でなければ偽（`lstat`。symlink・ディレクトリを拒む）
7. 真

- 手順 2 を手順 5 より先に置く（`<HOME>` を `.app/Contents/` の下に作られても弾く）
- **この関数はログを書かない**（RV-00 が偽のときは「何も書かない」。PLAN §8.9.4）

### 4.6 `ReaperLog.swift`（「// `logs/reaper.log`（PLAN §8.9.4）。5 MiB を超える書き込みの前に `.1` へ回す。PT-08・PT-12 の許可場所。」）

```swift
import Darwin
import Foundation
import Synchronization

final class ReaperLog: Sendable {
    enum Level: String, Sendable { case info = "INFO", warn = "WARN" }

    /// イベント名（PLAN §8.9.4。固定。ここ以外に書かない。CR-06）
    enum Event {
        static let started = "reaper_started"
        static let busy = "reaper_busy"
        static let disabled = "reaper_disabled"
        static let requestRejected = "request_rejected"
        static let sourceDeleteRejected = "source_delete_rejected"
        static let deviceAbsent = "device_absent"
        static let mountReadonly = "mount_readonly"
        static let sourceDeleted = "source_deleted"
        static let completed = "reaper_completed"
    }
    /// キー（PLAN §8.9.4 の逐語）
    enum Key {
        static let reason = "reason", file = "file", requestID = "request_id"
        static let device = "device", partkey = "partkey", requests = "requests"
    }

    static let maxBytes = 5 * 1024 * 1024
    init(url: URL, maxBytes: Int = ReaperLog.maxBytes, clock: ReaperClock = ReaperClock())
    func info(_ event: String, _ fields: [(String, String)] = [])
    func warn(_ event: String, _ fields: [(String, String)] = [])
    func close()
    /// PLAN §8.15 の値の書式（テストが直接呼ぶ）
    static func format(ts: String, level: Level, event: String, fields: [(String, String)]) -> String
    static func value(_ s: String) -> String
}
```

`format`: `ts + " " + level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0) + " " + event` に、`fields` の順に `" " + k + "=" + value(v)` を足したもの（末尾の改行は含まない）。

`value(_ s:)`（PLAN §8.15。voicedock との差: 全体一致で判定する）:
- `s` が空でなく、**全スカラーが U+0021〜U+007E で、`"` でも `=` でもない**ならそのまま返す
- そうでなければ JSON の文字列表記（`ensure_ascii=False` と同じ）: 先頭と末尾に `"`、`\` → `\\`、`"` → `\"`、U+0008 → `\b`、U+0009 → `\t`、U+000A → `\n`、U+000C → `\f`、U+000D → `\r`、その他の U+0000〜U+001F と U+007F → `\u00XX`（小文字 16 進 4 桁）、それ以外のスカラーはそのまま

書き込み（`info` / `warn` 共通。状態 `struct State { var fd: Int32 = -1; var size: Int64 = 0 }` を `Mutex<State>` で守る。PT-14）:
1. `line = Self.format(ts: clock.nowISO(), level: level, event: event, fields: fields) + "\n"`、`bytes = Data(line.utf8)`
2. `fd < 0` なら `open(p(url), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)`。失敗なら**何もせず返る**（ログの失敗はログに書けない）。成功なら `fstat` で `size`
3. `size > 0 && size + Int64(bytes.count) > maxBytes` なら `close(fd)` → `rename(p(url), p(url) + ".1")`（既存の `.1` を置き換える）→ 2 と同じく開き直し `size = 0`
4. `ReaperIO.writeAll(fd:, bytes)`。成功なら `size += bytes.count`、失敗なら `close(fd)`・`fd = -1`
- `fsync` はしない（ログは失ってもよい）。`close()` は `fd >= 0` なら閉じて `-1`

レベル（voicedock と同じ割り当て）:

| イベント | レベル | フィールド（この順） |
|---|---|---|
| `reaper_started` | INFO | （無し） |
| `reaper_busy` | WARN | （無し） |
| `reaper_disabled` | INFO | `reason=lock1` / `reason=conf_invalid` |
| `request_rejected` | WARN | `file=<名前>` `reason=malformed_request_id` |
| `source_delete_rejected` | WARN | `request_id=…` `reason=<理由語>` |
| `device_absent` | WARN | `request_id=…` `device=…` |
| `mount_readonly` | WARN | `request_id=…` `device=…` |
| `source_deleted` | INFO | `request_id=…` `partkey=…` |
| `reaper_completed` | INFO | `requests=<N>` |

### 4.7 `ProcessedLog.swift`（「// `state/processed.log`（PLAN §8.9.4）。1 行 1 request_id。照合は行の完全一致。PT-12 の許可場所。」）

```swift
import Darwin
import Foundation

struct ProcessedLog: Sendable {
    let url: URL
    /// 読めるうちに 1 度だけ全部読んで持つ（1 回の実行の間は reaper だけが書く）。
    /// 読めない（ENOENT 以外の失敗）→ true を返し続ける（fail-closed。RV-04 で `replayed` になり、何も消えない）
    init(url: URL)
    func contains(_ requestID: String) -> Bool
    /// `O_WRONLY | O_APPEND | O_CREAT` で 1 行追記し `fsync`。成功で true（失敗は呼び手が無視する）
    @discardableResult mutating func append(_ requestID: String) -> Bool
    static let maxBytes = 64 * 1024 * 1024
}
```

`init`:
1. `fd = open(p(url), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)`。失敗して `errno == ENOENT` → 空の集合・`unreadable = false`。ほかの失敗 → `unreadable = true`
2. `ReaperIO.readAll(fd:, limit: Self.maxBytes)` が nil → `unreadable = true`。成功 → `\n`（0x0A）で分け（空の部分列を省かない）、**バイト列のまま** `Set<[UInt8]>` に入れる（空行は入れない）
3. `close(fd)`

`contains(_:)`: `unreadable` なら true。そうでなければ `lines.contains(Array(requestID.utf8))`。

`append(_:)`:
1. `fd = open(p(url), O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)`。失敗 → false
2. `ReaperIO.writeAll(fd:, Data((requestID + "\n").utf8))` が偽 → `close`・false
3. `fsync(fd) == 0` でなければ `close`・false
4. `close(fd)`、`lines.insert(Array(requestID.utf8))`（同じ実行の中の 2 件目を捕まえる）、true

### 4.8 `QueueFiles.swift`（「// `queue/delete` の列挙と読み取り、`queue/rejected` への退避、`queue/result` への書き込み（PLAN §8.9.4）。PT-12 の許可場所。」）

```swift
import Darwin
import Foundation
import VDContract

final class QueueFiles {
    let layout: HomeLayout
    /// queue/delete のディレクトリ fd（openat / unlinkat / renameat がこれを起点に働く。TOCTOU の窓を消す）
    let deleteFD: Int32
    /// queue/rejected のディレクトリ fd。開けなければ -1（退避は失敗として扱う）
    let rejectedFD: Int32

    /// queue/delete を `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` で開く。開けなければ nil
    /// （`rejected/` は `O_RDONLY | O_DIRECTORY | O_CLOEXEC`。開けなければ -1 のまま）
    /// 名前を `open` にしない（Darwin の `open(2)` と紛れるため）
    static func make(layout: HomeLayout) -> QueueFiles?
    private init(layout: HomeLayout, deleteFD: Int32, rejectedFD: Int32)
    deinit   // 開いた fd を閉じる

    /// `.` で始まらない名前を UTF-8 のバイト順の昇順に。読めなければ []
    func names() -> [String]
    /// RV-02a。`<request_id>.json` の形か
    static func isRequestFileName(_ name: String) -> Bool
    /// 名前から `.json` を落とした stem（`isRequestFileName` を通ったものだけに使う）
    static func stem(of name: String) -> String
    /// `openat(deleteFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)` → 通常ファイル → `Contract.maxRequestBytes` 以下 → 全部読む。どれかが偽なら nil
    func readRequest(named name: String) -> Data?
    /// `renameat(deleteFD, name, rejectedFD, name)`。同名は上書きされる。成功で true
    func moveToRejected(named name: String) -> Bool
    /// `queue/result/<request_id>.json` が（`.` を除く通常のファイルとして）在るか
    func resultExists(requestID: String) -> Bool
    /// `ContractJSON.encode` → `AtomicFile.write(_, to:, permissions: 0o644)`。成功で true
    func writeResult(_ result: DeleteResult) -> Bool
}
```

- `names()`: `FileManager.default.contentsOfDirectory(atPath: p(layout.queueDelete))`（throw → `[]`）→ `filter { !$0.hasPrefix(".") }` → `sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }`
- `isRequestFileName(_ name:)`: `name.hasSuffix(".json") && RequestID.isValid(String(name.dropLast(5)))`（正規表現を別に持たない。`RequestID.pattern` が唯一の出どころ。CR-06）
- `stem(of:)`: `String(name.dropLast(5))`
- `readRequest`: `fstat` が `S_IFREG` でなければ nil、`st_size > Contract.maxRequestBytes` なら nil、`ReaperIO.readAll(fd:, limit: Contract.maxRequestBytes + 1)` が nil なら nil。どの経路でも `close`
- `resultExists`: `lstat(p(layout.queueResult) + "/" + requestID + ".json")` が成功して `S_IFREG`
- `writeResult`: 符号化か書き込みが投げたら false

### 4.9 `Unlinker.swift`（「// 削除は `unlinkat` だけ（PLAN §8.9.4）。デバイス上の対象と `queue/delete` の要求ファイルの両方をここが消す。PT-01 の許可場所。」）

```swift
import Darwin
import VDContract

enum Unlinker {
    enum UnlinkOutcome: Equatable, Sendable { case ok, unlinkFailed, stillPresent }

    /// RV-13。検証済みの親 fd に `unlinkat` → 同じ fd に `fstatat(AT_SYMLINK_NOFOLLOW)` が ENOENT
    static func unlinkTarget(_ target: VerifiedTarget) -> UnlinkOutcome
    /// `queue/delete` 直下の `.json` だけを消す。成功で true（失敗は呼び手が無視する）
    static func removeRequest(named name: String, inQueueDelete fd: Int32) -> Bool
}
```

`unlinkTarget`:
1. `unlinkat(target.parentFD, target.name, 0) != 0` → `.unlinkFailed`
2. `var st = stat()`、`fstatat(target.parentFD, target.name, &st, AT_SYMLINK_NOFOLLOW)`。`0` を返した（まだ在る）→ `.stillPresent`
3. `errno == ENOENT` → `.ok`。それ以外の errno → `.stillPresent`（確かめられなければ消えたことにしない。fail-closed）

`removeRequest`: `name.hasSuffix(".json")`、`!name.contains("/")`、`name != "."`、`name != ".."` を確かめ、`unlinkat(fd, name, 0) == 0`。
`AT_REMOVEDIR` を渡さない（ディレクトリは消さない。PR-16）。

### 4.10 `RequestProcessor.swift`（「// 1 件の要求の検証と実行（PLAN §8.9.4 の表。RV-02〜RV-13）。」）

```swift
import Darwin
import Foundation
import VDContract

enum RequestOutcome: Equatable, Sendable {
    /// `rejected/` へ退避した（結果も processed.log も書かない）
    case rejectedFileName
    /// 拒否（processed.log → 結果 SOURCE_IDENTITY_MISMATCH → 要求を消す）
    case refused(String)
    /// 残す（何も書かない。アプリ側の期限切れが取り下げる）
    case left(String)
    case deleted(relpath: String)
}

struct RequestProcessor {
    let layout: HomeLayout
    let conf: ReaperConf
    let queue: QueueFiles
    let log: ReaperLog
    let clock: ReaperClock
    var processed: ProcessedLog

    /// 1 件を処理して結果を返す（ログもここで書く）
    mutating func process(name: String) -> RequestOutcome

    /// 拒否の書き込み（processed.log → 結果 → 要求を消す → ログ）。下の「refuse」の手順
    private mutating func refuse(name: String, stem: String, deviceID: String, partkey: String,
                                 reason: String) -> RequestOutcome

    /// 鍵の照合はスカラー列で（00-api-map §0）
    static func scalarsEqual(_ a: String, _ b: String) -> Bool
}
```

`process(name:)`（PLAN §8.9.4 の表の順。1 つでも偽なら削除しない）:

1. **RV-02a** `QueueFiles.isRequestFileName(name)` が偽 → `queue.moveToRejected(named: name)`（失敗は無視）→
   `log.warn(.requestRejected, [(Key.file, name), (Key.reason, IdentityReason.malformedRequestID)])` → `.rejectedFileName`
2. `stem = QueueFiles.stem(of: name)`
3. **読み取り** `guard let data = queue.readRequest(named: name) else { return refuse(name: name, stem: stem, deviceID: "", partkey: "", reason: IdentityReason.malformedRequest) }`
4. **RV-02b** `JSONSerialization.jsonObject(with: data)` が `[String: Any]` でない → 3 と同じ `refuse(… deviceID: "", partkey: "", reason: malformed_request)`。
   `obj["request_id"] as? String` が nil か `!Self.scalarsEqual(その値, stem)` → 1 と同じく `moveToRejected` → `request_rejected` → `.rejectedFileName`
   （**`request_id` は結果ファイルの名前になる。信用できない値をファイル名にしない**。d419397 / ND-38）
5. **RV-03** `ContractJSON.decodeRequest(data)` が `.failure` → `refuse(name:stem:deviceID: "", partkey: "", reason: malformed_request)`。`.success(r)`
6. **RV-04** `processed.contains(stem)` が真 →
   `queue.resultExists(requestID: stem)` が偽なら結果 `SOURCE_IDENTITY_MISMATCH` / `detail = replayed` を書く（**在れば書かない**。DELETED を MISMATCH で上書きしない）→
   `Unlinker.removeRequest(named: name, inQueueDelete: queue.deleteFD)` →
   `log.warn(.sourceDeleteRejected, [(Key.requestID, stem), (Key.reason, IdentityReason.replayed)])` → `.refused(replayed)`。
   **processed.log には再追記しない**
7. **RV-05** `Self.scalarsEqual(r.deviceID + "/" + r.target.relpath, r.partkey)` が偽 → `refuse(… r.deviceID, r.partkey, partkey_mismatch)`（以下、要求を読めた段の `refuse` は `deviceID: r.deviceID`・`partkey: r.partkey` を渡す）
   （これは partkey の**照合**であって組み立てではない。`PartKey.make` を使うと不正な relpath が `relpath_unsafe` ではなく `partkey_mismatch` になり ND-24 の理由語が変わるので使わない）
8. **RV-06** `TargetIdentity.openVolume(volumesRoot: conf.volumesRoot, deviceID: r.deviceID)`:
   - `.absent` → `log.warn(.deviceAbsent, [(Key.requestID, stem), (Key.device, r.deviceID)])` → `.left(device_absent)`（**要求を残し processed にも書かない**）
   - `.rejected(m)` → `refuse(… m.reason)`（`not_a_mount_point` / `unexpected_fs`）
   - `.opened(volume)` → 次へ
9. **RV-07** `volume.readOnly` が真 → `log.warn(.mountReadonly, [(Key.requestID, stem), (Key.device, r.deviceID)])` → `.left(mount_readonly)`（**要求を残す**）
10. **RV-08〜RV-13**
    ```swift
    let outcome = TargetIdentity.withVerifiedTarget(
        volume: volume, relpath: r.target.relpath,
        expectedSize: r.target.size, expectedMtime: r.target.mtime) { target in
        Unlinker.unlinkTarget(target)      // RV-13 は検証済みの親 fd の上で行う（開き直さない）
    }
    ```
    - `.failure(m)` → `refuse(… m.reason)`（RV-08〜RV-12 の理由語）
    - `.success(.unlinkFailed)` → `refuse(… unlink_failed)`
    - `.success(.stillPresent)` → `refuse(… still_present)`
    - `.success(.ok)` → **成功**（次へ）
11. **成功の書き込み順**: `processed.append(stem)`（失敗は無視）→
    `queue.writeResult(result(stem: stem, deviceID: r.deviceID, partkey: r.partkey, status: .deleted, detail: r.target.relpath))`（失敗したら**要求を残して**次へ。`source_deleted` は出す）→
    `Unlinker.removeRequest(named: name, inQueueDelete: queue.deleteFD)`（失敗は無視）→
    `log.info(.sourceDeleted, [(Key.requestID, stem), (Key.partkey, r.partkey)])` → `.deleted(relpath: r.target.relpath)`

`refuse(name:stem:deviceID:partkey:reason:)`（**拒否の書き込み順**）:
1. `processed.append(stem)`（失敗は無視）
2. `queue.writeResult(result(stem: stem, deviceID: deviceID, partkey: partkey, status: .sourceIdentityMismatch, detail: reason))`。
   **偽なら要求を残して `.refused(reason)` を返す前に `source_delete_rejected` を出さない**（結果を書けていないのに「拒否した」と記録しない。アプリ側の期限切れが取り下げる）
3. `Unlinker.removeRequest(named: name, inQueueDelete: queue.deleteFD)`（失敗は無視）
4. `log.warn(.sourceDeleteRejected, [(Key.requestID, stem), (Key.reason, reason)])`
5. `.refused(reason)`

`result(stem:deviceID:partkey:status:detail:)`: `DeleteResult(schema: Contract.resultSchema, requestID: stem, completedAt: clock.nowISO(), reaperVersion: AppVersion.string, deviceID: deviceID, partkey: partkey, status: …, detail: …)`。
**JSON が読めなかった段（手順 3・5）では `deviceID` と `partkey` は空文字列 `""`**（voicedock の `${RESULT_DEVICE_ID:-}` と同じ）。

- 手順 6（RV-04 の `replayed`）・手順 11・`refuse` の 3 か所以外に結果を書くコードを置かない（手順 6 も結果を書くので「2 か所」ではない。実装時に直した）
- 手順 1 と手順 4（RV-02b）の退避は同じ処理なので `private func reject(name: String) -> RequestOutcome`（`moveToRejected` → `request_rejected` → `.rejectedFileName`）の 1 か所に置く
- `detail` は連結しない（DELETED は relpath、MISMATCH は理由語の**どちらか一方**。PLAN §4.4）

### 4.11 `ReaperMain.swift`（「// 起動時の検査 → flock → 走査 → 1 件ずつ（PLAN §8.9.4）。」）

（`import Darwin` は使わないので書かない。レビューで外した）

```swift
import Foundation
import VDContract

struct ReaperExit: Equatable, Sendable {
    let code: Int32
    let stdout: String     // 空なら何も書かない
    let stderr: String
    static let ok = ReaperExit(code: 0, stdout: "", stderr: "")
}

enum ReaperMain {
    /// 終了コード: 0 正常 / 2 引数不正・conf 不正 / 3 RV-00 / 4 ロックが取れない
    static func run(arguments: [String]) -> ReaperExit
}
```

`run(arguments:)`:
1. `switch ReaperArguments.parse(arguments)`
   - `.version` → **RV-00 より前に**、`ReaperExit(code: 0, stdout: AppVersion.string + "\n", stderr: "")`（ほかの I/O はしない）
   - `.invalid` → `ReaperExit(code: 2, stdout: "", stderr: ReaperArguments.usage)`（**何も読まない・書かない**）
   - `.run(home)` → 2 へ
2. **RV-00** `SelfLocation.isAtExpectedPlace(home: home)` が偽 → `ReaperExit(code: 3, stdout: "", stderr: "")`（**何も書かない**。ログも開かない）
3. `layout = HomeLayout(root: URL(fileURLWithPath: ReaperIO.realpath(home) ?? home, isDirectory: true))`
4. `log = ReaperLog(url: layout.reaperLog)`、`clock = ReaperClock()`。`defer { log.close() }`
5. `log.info(.started)`
6. **reaper.conf** `switch ReaperConf.observe(at: layout.reaperConf)`:
   - `.valid(conf)` → 7 へ
   - `.missing` / `.invalid` → `log.info(.disabled, [(Key.reason, IdentityReason.confInvalid)])` → `ReaperExit(code: 2, …)`（**要求に触らない**）
7. **RV-01** `conf.deleteSourceAudio == false` → `log.info(.disabled, [(Key.reason, IdentityReason.lock1)])` → `ReaperExit.ok`（**要求に触らない**）
8. **flock** `guard let lock = FileLock.tryAcquire(url: layout.reaperLock) else { log.warn(.busy); return ReaperExit(code: 4, …) }`。
   `defer { lock.release() }`（終わるまで持ち続ける。PLAN §2.1）
9. `Signals.installTerminationHandler()`
10. `guard let queue = QueueFiles.make(layout: layout) else { log.info(.completed, [(Key.requests, "0")]); return .ok }`
11. `var proc = RequestProcessor(layout: layout, conf: conf, queue: queue, log: log, clock: clock, processed: ProcessedLog(url: layout.processedLog))`
    （`ProcessedLog` は値型。`RequestProcessor` が持つ 1 つだけが更新される）
12. `var count = 0`。`for name in queue.names()`:
    - `if Signals.stopRequested { break }`（**次の要求に進まない**。処理中の 1 件は終わっている）
    - `_ = proc.process(name: name)`、`count += 1`
13. `log.info(.completed, [(Key.requests, String(count))])` → `ReaperExit.ok`

- ロックは 1 回だけ試す（待たない。待つのは IngestService 側。PLAN §2.1）
- 手順 12 の `count` は**この実行で処理した要求の数**（`rejected/` へ退避したものを含む。SIGTERM で止めたらそこまで）
- 手順 6 で `.missing` も `conf_invalid` にする（PLAN §8.9.4「reaper.conf が無い・読めない・不正 → 終了コード 2」）

### 4.12 `main.swift`（「// voicedock-reaper の入口（PLAN §8.9.4）。`print` と stderr への書き出しはこのファイルだけ（PT-08）。」）

```swift
import Foundation

let result = ReaperMain.run(arguments: Array(CommandLine.arguments.dropFirst()))
if !result.stdout.isEmpty { print(result.stdout, terminator: "") }
if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
exit(result.code)
```

### 4.13 `Tests/TestSupport/ReaperBinary.swift`（作り手 T-37。00-api-map §15）

```swift
// ビルドした voicedock-reaper を実際に起動する（PLAN §10.5「reaper 層はビルドした実行ファイルを起動する」）。
// テストターゲット ReaperTests は voicedock-reaper に依存しているので、.xctest と同じディレクトリに実行ファイルが在る。
import Foundation

public struct ReaperRun: Sendable, Equatable {
    public let exitCode: Int32       // シグナルで終わったときは 128 + シグナル番号
    public let stdout: String
    public let stderr: String
}

public struct ReaperBinaryError: Error, CustomStringConvertible {
    public let description: String
}

public enum ReaperBinary {
    /// ビルドした実行ファイルの場所（見つからなければ投げる）
    public static func url() throws -> URL
    /// `--home <home>` で起動して終わりを待つ
    public static func run(home: URL) throws -> ReaperRun
    /// 任意の引数で起動する（`--version` と RV-00 のテスト用）
    public static func run(executable: URL, arguments: [String]) throws -> ReaperRun
    /// 起動して制御を返す（SIGTERM のテスト用）
    public static func start(executable: URL, arguments: [String]) throws -> ReaperProcess
}

public final class ReaperProcess: Sendable {
    public func sendTermination()            // SIGTERM
    public func wait() -> ReaperRun
}
```

`url()`:
1. `bundle = Bundle(for: ReaperProcess.self).bundleURL`（このファイルが静的にリンクされたテストバンドル）、`var dir = bundle`。`dir.pathExtension == "xctest"` なら `dir = dir.deletingLastPathComponent()`。**`Bundle.main` は使わない**（`swift test` では Bundle.main がツールチェーンの `usr/libexec/swift/pm/`（swiftpm-testing-helper）を指し、実行ファイルが見つからない。実装時に確かめた）
2. `dir` から最大 4 回まで `deletingLastPathComponent()` しながら、`dir.appendingPathComponent(Contract.reaperFileName)` が `lstat` で通常ファイルかつ `access(X_OK)` が通るものを探す
3. 見つからなければ `ReaperBinaryError(description: "voicedock-reaper が見つかりません（swift build をしてください）: " + p(bundle))`

`run(executable:arguments:)`: `Foundation.Process`（`Tests/` は PT-03 の対象外）。`standardOutput` / `standardError` は `Pipe`、
`environment = ["PATH": "/usr/bin:/bin"]`（余計な環境を渡さない）、`run()` → 先に両方の `readDataToEndOfFile()` を**別スレッドで**読んでから `waitUntilExit()`（パイプの詰まりを避ける）。
`terminationReason == .uncaughtSignal` なら `exitCode = 128 + terminationStatus`。文字列は `String(decoding: data, as: UTF8.self)`。

`run(home:)`: `try run(executable: url(), arguments: ["--home", p(home)])`。

`ReaperProcess`: `Process` と 2 つの `Pipe` と読み終えたデータを `Mutex` で持つ。`sendTermination()` は `process.terminate()`（SIGTERM）。`wait()` は上と同じ組み立て。

- **`/Volumes` 配下には一切触れない**（`home` は必ず一時ディレクトリの下）

### 4.14 `Tests/ReaperTests/ReaperBench.swift`（層 R1・R3 が共有する舞台）

```swift
// reaper を本物として起動するための舞台（PLAN §10.5 の層 R1・R3）。三重ロックは全部外した状態で作る（TEST-04）。
import Foundation
import TestSupport
import VDContract

struct ReaperBench {
    /// 層 R1 のディレクトリ名と層 R3 のディスクイメージの名前（PLAN §10.2: 実機と同じ DJIMIC3 を使わない。`DiskImageVolume` が DJIMIC3 を拒む）。
    /// 層 R1 でも DJIMIC3 にしない: 壊した reaper（破壊による証明の 3 など）が VOLUMES_ROOT を既定の /Volumes に倒しても、
    /// 利用者の実機 /Volumes/DJIMIC3 ではなく device_absent になる（実装時に、実機が挿さったまま証明の 3 を行って気づいた）
    static let deviceID = "VDT0037"
    static let folder = "TX_MIC001_20260912_090000"
    static let fileName = "TX00_MIC001_20260912_090000_orig.wav"
    static let relpath = "TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    static let partkey = "VDT0037/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    static let sessionKey = "VDT0037:20260912"
    static let createdAt = "2026-09-12T18:00:00+09:00"
    /// 2026-09-12T09:01:00+09:00。偶数秒（FAT の 2 秒分解能でも変わらない）
    static let mtime: Double = 1_789_171_260
    static let content = Data(repeating: 0x78, count: 4096)      // FakeVolume.standardContent と同じ
    static let requestID = "20260912T090000Z-a5d046dce76cfedc-a1b2c3"

    let tmp: TempDirectory
    let layout: HomeLayout
    let volumesRoot: URL
    let deviceRoot: URL
    let image: DiskImageVolume?

    /// diskImage が nil なら普通のディレクトリ（層 R1）、在れば FAT32 / HFS+ のマウント点（層 R3）
    init(in tmp: TempDirectory? = nil, diskImage: DiskImageVolume? = nil, deleteSourceAudio: Bool = true) throws

    // 準備
    func placeSource(_ relpath: String = ReaperBench.relpath, content: Data = ReaperBench.content) throws
    /// 実際に置いたファイルの (size, mtime)（FAT は 2 秒刻みなので lstat した値を使う）
    func actualStat(_ relpath: String = ReaperBench.relpath) throws -> (size: Int64, mtime: Double)
    /// volumesRoot が nil ならこの舞台の volumesRoot（**`/Volumes` を既定にしない**）
    func writeReaperConf(deleteSourceAudio: Bool = true, volumesRoot: String? = nil) throws
    func writeReaperConfRaw(_ text: String) throws
    func removeReaperConf() throws
    /// 既定は「今のデバイス上の実物と一致する、通る要求」。引数で 1 か所だけ壊す
    @discardableResult
    func writeRequest(requestID: String = ReaperBench.requestID, deviceID: String = ReaperBench.deviceID,
                      relpath: String = ReaperBench.relpath, partkey: String? = nil,
                      size: Int64? = nil, mtime: Double? = nil, fileName: String? = nil) throws -> String
    /// 生のバイト列をそのまま置く（RV-03 の形を壊すテスト用）
    func writeRawRequest(fileName: String, _ text: String) throws

    // 実行
    func run() throws -> ReaperRun
    func start() throws -> ReaperProcess

    // 観測
    func requests() -> [String]        // queue/delete の名前（バイト順）
    func results() -> [String]         // queue/result の名前
    func rejected() -> [String]        // queue/rejected の名前
    func result(_ requestID: String) throws -> DeleteResult
    func processedLines() -> [String]
    func logLines() -> [String]
    func sourceExists(_ relpath: String = ReaperBench.relpath) -> Bool
    /// queue/result の外にファイルが作られていないこと（ND-38）
    func filesUnderQueue() -> [String]

    /// 実機に触れ得る舞台を拒む（hdiutil を使わずに確かめられるよう static）: deviceID が `"DJIMIC3"`、
    /// または volumesRoot の realpath（無ければ標準化したパス）か標準化したパスが `/Volumes` かその下（末尾の `/` は落として比べる）→ `BenchError`
    static func refuseUnsafe(volumesRoot: URL, deviceID: String) throws
}
```

`init` の手順:
1. `tmp` を使う（nil なら `try TempDirectory()`）。`layout = HomeLayout(root: tmp.url/"home")`、`createDirectories()`、`bin` を作る
2. **ビルドした reaper を `layout.reaperExecutable` に複製し `chmod 0o755`**（RV-00 は `<HOME>/bin/voicedock-reaper` からの起動だけを許すため。`Data(contentsOf:)` → `write(to:)` → `chmod`）
3. ディスクイメージの `deviceID` が `ReaperBench.deviceID` でなければ `BenchError`。`root = diskImage?.volumesRoot ?? tmp.url/"Volumes"` を **`Self.refuseUnsafe(volumesRoot: root, deviceID: diskImage?.deviceID ?? ReaperBench.deviceID)` に通してから** `volumesRoot = root`、`deviceRoot = volumesRoot/ReaperBench.deviceID`。ディスクイメージでなければ `deviceRoot` を作る（構造で守る。レビューで足した）
4. `placeSource()`
5. `writeReaperConf(deleteSourceAudio: deleteSourceAudio, volumesRoot: p(volumesRoot))`

`placeSource`: 親を作り、`content` を書き、`utimes` で mtime を `ReaperBench.mtime` にする。
`writeRequest`: `partkey ?? (deviceID + "/" + relpath)`、`size ?? actualStat(relpath).size`、`mtime ?? actualStat(relpath).mtime` で `DeleteRequest` を作り、
`ContractJSON.encode` を `layout.queueDelete/(fileName ?? requestID + ".json")` に書く。戻り値は書いた名前。
`run()`: `try ReaperBinary.run(executable: layout.reaperExecutable, arguments: ["--home", p(layout.root)])`。
準備の失敗は同じファイルの `struct BenchError: Error, CustomStringConvertible { let description: String }` を投げる（`ReaperBinaryError` の初期化子は TestSupport の外から呼べない）。

- **`/Volumes` の下には決して置かない**（`volumesRoot` は必ず一時ディレクトリかディスクイメージの一時マウント点。T-07 §4.5 と同じ約束）

## 5. テスト

すべて `import Testing`、`import TestSupport`、`import VDContract`。ND の表示名は `ND-nn [層] …`、RV の表示名は `RV-nn …` で始める（T-05 の SPEC 同期が読む）。

### 5.1 `ReaperArgumentsTests.swift`（`@Suite("voicedock-reaper の引数と置き場所（層 R1）") struct ReaperArgumentsTests`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `versionIsPrintedAndNothingElseHappens` | `--version` は版だけを出す | 舞台、要求 1 件 | exit 0、stdout == `AppVersion.string + "\n"`、stderr 空、`logs/reaper.log` が無い、要求が残る、結果 0 件 |
| `versionWorksBeforeTheLocationCheck` | RV-00 `--version` は置き場所の検査より前 | ビルド元の実行ファイル（`<HOME>/bin` の外）を `--version` で起動 | exit 0、stdout == 版、何も書かれない |
| `nd40BundledReaperDoesNothing` | `ND-40 [R1] バンドル内の reaper を起動しても何も消えず何も書かれない` | `<tmp>/VoiceDock.app/Contents/Helpers/voicedock-reaper` に複製、`--home <HOME>` | exit 3、stdout・stderr 空、`logs/reaper.log` が無い、要求が残る、結果 0 件、デバイス上のファイルが在る |
| `nd40AnyOtherPlaceIsRefused` | `ND-40 [R1] <HOME>/bin 以外の場所からの起動は 3` | `<tmp>/elsewhere/voicedock-reaper` に複製 | 同上（exit 3） |
| `rv00SymlinkedReaperIsRefused` | `RV-00 <HOME>/bin/voicedock-reaper が symlink なら 3` | 本体を `bin/real` に置き、`bin/voicedock-reaper` をその symlink に | exit 3、何も書かれない |
| `rv00AnotherHomeIsRefused` | `RV-00 別の --home を渡すと 3` | 舞台を 2 つ作り、A の実行ファイルに `--home <B>` | exit 3、A・B のどちらにも何も書かれない |
| `rv00HomeInsideABundleIsRefused` | `RV-00 <HOME> が .app/Contents/ の下なら 3` | 舞台の `<HOME>` を `<tmp>/VoiceDock.app/Contents/home` へ移し、その `bin/voicedock-reaper` を `--home <移した先>` で起動（置き場所の一致は通る） | exit 3、stdout・stderr 空、ログが無い、要求が残る、結果 0 件（§6 の 2 のために足した。`nd40BundledReaperDoesNothing` は一致の検査でも弾かれるので、`bundleMarker` の検査を消しても緑のままだった） |
| `rv00MissingHomeIsRefused` | `RV-00 --home が無いディレクトリなら 3` | `--home <tmp>/nope` | exit 3 |
| `badArgumentsExitTwo` | 引数が不正なら 2（キューに触らない） | `[]`・`["--help"]`・`["-h"]`・`["--home"]`・`["--home", "<HOME>", "--x"]`・`["--version", "x"]`（パラメタ化） | exit 2、stderr == `ReaperArguments.usage`、`logs/reaper.log` が無い、要求が残る |

同じファイルの `@Suite("ReaperBench は実機に触れ得る舞台を拒む") struct ReaperBenchSafetyTests`（hdiutil を使わない。レビューで足した）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `volumesRootUnderVolumesIsRefused` | volumesRoot が /Volumes かその下なら舞台を作らない | `refuseUnsafe(volumesRoot:)` に `/Volumes`・`/Volumes/`・`/Volumes/VDT0037`（パラメタ化。何も書かない） | `BenchError` を投げる |
| `symlinkToVolumesIsRefused` | /Volumes を指す symlink も realpath で拒む | 一時ディレクトリに `Volumes -> /Volumes` の symlink を作り、それを渡す | `BenchError` を投げる |
| `realDeviceNameIsRefused` | deviceID が DJIMIC3 なら舞台を作らない | 一時ディレクトリの volumesRoot と `deviceID: "DJIMIC3"` | `BenchError` を投げる |
| `temporaryRootIsAccepted` | 一時ディレクトリの下で VDT0037 なら通る（対照） | 一時ディレクトリの volumesRoot と `VDT0037`、続けて `ReaperBench(in: tmp)` | 投げない。舞台の volumesRoot が一時ディレクトリの下 |

### 5.2 `ReaperConfGateTests.swift`（`@Suite("reaper.conf とロック 1（層 R1）")`）

準備は共通で「舞台 ＋ 通る要求 1 件」。**手で書く reaper.conf には、壊す 1 か所以外に必ず `VOLUMES_ROOT=<舞台の volumesRoot>` を入れる**（壊した reaper が不正な conf を受け入れても、既定の `/Volumes` ではなく一時ディレクトリを見るように）。期待の「要求に触らない」= `requests() == [name]`・`results() == []`・`rejected() == []`・`processedLines() == []`・デバイス上のファイルが在る。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `nd22Lock1FalseTouchesNothing` | `ND-22 [R1] reaper.conf の DELETE_SOURCE_AUDIO=false なら要求に触らない` | `writeReaperConf(deleteSourceAudio: false)` | exit 0、`reaper_disabled reason=lock1`、要求に触らない |
| `nd43UnknownKeyIsInvalid` | `ND-43 [R1] 未知のキーは無効側` | `SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=<ROOT>\nEXTRA=1\n` | exit 2、`reaper_disabled reason=conf_invalid`、要求に触らない |
| `nd43DuplicateKeyIsInvalid` | `ND-43 [R1] 重複したキーは無効側` | `DELETE_SOURCE_AUDIO` を 2 行 | 同上 |
| `nd43BadValueIsInvalid` | `ND-43 [R1] 不正な値は無効側` | `DELETE_SOURCE_AUDIO=yes` / `SCHEMA=2` / `VOLUMES_ROOT=rel`（パラメタ化） | 同上 |
| `nd43MissingKeyIsInvalid` | `ND-43 [R1] 必須のキーが欠けていたら無効側` | `SCHEMA=1\nVOLUMES_ROOT=<ROOT>\n` / `DELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=<ROOT>\n`（パラメタ化） | 同上 |
| `nd43MalformedLineIsInvalid` | `ND-43 [R1] 書式に合わない行は無効側` | `delete_source_audio=true`（小文字）/ `SCHEMA = 1`（空白） | 同上 |
| `missingConfIsInvalid` | reaper.conf が無ければ無効側 | `removeReaperConf()` | 同上 |
| `symlinkedConfIsInvalid` | reaper.conf が symlink なら無効側 | `bin/reaper.conf` を別ファイルへの symlink に | 同上 |
| `oversizedConfIsInvalid` | reaper.conf が 64 KiB を超えたら無効側 | `#` 行で `Contract.maxRequestBytes + 1` バイト | 同上 |
| `commentsAndBlankLinesArePassed` | 空行と `#` の行は無視される（対照） | 正しい 3 行の前後に空行と `#` を挟む | exit 0、要求が処理される（`not_a_mount_point`） |
| `rv01Lock1FalseExitsZeroAndTouchesNothing` | `RV-01 DELETE_SOURCE_AUDIO=false なら reaper_disabled reason=lock1 で 0、要求に触らない` | `SCHEMA=1\nDELETE_SOURCE_AUDIO=false\nVOLUMES_ROOT=<ROOT>\n`（手書き） | exit 0、`reaper_disabled reason=lock1`、`reason=conf_invalid` の行が無い、要求に触らない（issue #87。ND-22 と振る舞いは重なるが RV の規範 ID のテストとして独立させる） |
| `rv01InvalidConfExitsTwoAndTouchesNothing` | `RV-01 reaper.conf が不正なら reaper_disabled reason=conf_invalid で 2、要求に触らない` | `SCHEMA=1\nDELETE_SOURCE_AUDIO=1\nVOLUMES_ROOT=<ROOT>\n` | exit 2、`reaper_disabled reason=conf_invalid`、`reason=lock1` の行が無い、要求に触らない（issue #87） |
| `rv01Lock1TrueProceedsToRequests` | `RV-01 DELETE_SOURCE_AUDIO=true なら要求の処理へ進む（対照）` | `SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=<ROOT>\n` | exit 0、`reaper_disabled` の行が無い、要求が消え結果の `detail == "not_a_mount_point"`（上の 2 本が手書きの conf のほかの行で弾かれていないことの担保。TEST-19） |

### 5.3 `ReaperQueueTests.swift`（`@Suite("voicedock-reaper の走査と要求（層 R1）")`）

**層 R1 の正の対照**（PLAN §10.5: R1 は RV-06 まで進んで `not_a_mount_point` になる）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `nd39PlainDirectoryIsNotAMountPoint` | `ND-39 [R1] <VOLUMES_ROOT>/<device_id> がただのディレクトリなら not_a_mount_point`（R1 の正の対照） | 通る要求 1 件 | exit 0、`processedLines() == [requestID]`、結果 1 件で `status == .sourceIdentityMismatch`・`detail == "not_a_mount_point"`・`partkey` が載っている・`reaperVersion == AppVersion.string`、要求が消えている、デバイス上のファイルは**残っている**、`source_delete_rejected request_id=… reason=not_a_mount_point` |

**RV-02（ファイル名と request_id）**。期待の「外へ書かない」= `filesUnderQueue()` が `delete/`・`result/`・`rejected/` の下だけで、`queue/` 直下に増えたファイルが無い。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `nd38BadFileNamesGoToRejected` | `ND-38 [R1] ファイル名が request_id の形でなければ rejected/ へ` | 名前 `evil.json`・`20260912T090000Z-a5d046dce76cfedc-a1b2c3..json`（`..` を含む。`..json` は `.` で始まり走査が無視するので使わない）・`20260912T090000Z-a5d046dce76cfedc-A1B2C3.json`（大文字 16 進）・`20260912T090000Z-a5d046dce76cfedc-a1b2c3.JSON`・`20260912T090000Z-a5d046dce76cfedc-a1b2c3.json.bak`（パラメタ化）。**中の `request_id` はファイル名の stem（`.json` で終わらない名前は名前そのもの）にする**（既定の request_id のままだと RV-02b が代わりに弾き、§6 の 6 で落ちなかった） | exit 0、`rejected() == [その名前]`、`results() == []`、`processedLines() == []`、外へ書かない、`request_rejected file=<名前> reason=malformed_request_id`、デバイス上のファイルが在る |
| `nd38InnerRequestIDMismatchGoesToRejected` | `ND-38 [R1] JSON の request_id がファイル名と違えば rejected/ へ（RV-02b）` | 正しい名前、中の `request_id` を `../evil` に | 同上。加えて `<HOME>/queue/evil.json` が無い |
| `rv02bNonStringRequestIDGoesToRejected` | `RV-02 request_id が文字列でなければ rejected/ へ（02b）` | 中の `request_id` を `1` に | 同上（旧表示名 `RV-02b …` は T-05 の表示名の正規表現 `^(RV-[0-9]+)(?: \[..\])?(?: \|$)` に合わず、RV-02 として数えられなかった。issue #87 で改名） |
| `rv02aMalformedFileNameGoesToRejected` | `RV-02 ファイル名が <request_id>.json の形でなければ rejected/ へ（02a）` | 名前 `20260912T090000Z-a5d046dce76cfedc-a1b2c.json`（乱数部が 5 桁）、中の `request_id` は stem | 同上（issue #87） |
| `rv02bInnerRequestIDMismatchGoesToRejected` | `RV-02 JSON の request_id がファイル名の stem と違えば rejected/ へ（02b）` | 正しい名前、中の `request_id` を形は正しい別の ID `20260912T090000Z-a5d046dce76cfedc-ffffff` に（形ではなく一致を見ていること） | 同上（issue #87） |
| `rv02MatchingNameProceeds` | `RV-02 ファイル名と中の request_id が一致すれば not_a_mount_point まで進む（対照）` | 通る要求 1 件 | exit 0、`rejected() == []`、結果の `detail == "not_a_mount_point"`（issue #87） |
| `nonJSONNamesGoToRejected` | `.json` で終わらない名前は rejected/ へ | 名前 `README` | 同上 |
| `dotFilesAreIgnored` | `.` で始まる名前は無視する | `.20260912T090000Z-a5d046dce76cfedc-a1b2c3.json.tmp` を置く | exit 0、`reaper_completed requests=0`、そのファイルが残る、`rejected() == []` |

**RV-03（JSON の形）**。すべて `detail == "malformed_request"` の MISMATCH。期待: 結果 1 件・processed に 1 行・要求が消える・デバイス上のファイルが在る・結果の `device_id` と `partkey` が `""`。

| 関数名 | 表示名 | 準備 |
|---|---|---|
| `handWrittenJSONPassesWhenIntact` | `手書きの要求 JSON は壊さなければ not_a_mount_point まで進む（RV-03 の対照）` | 下の行が使う手書きの JSON を壊さずに置く（期待は `detail == "not_a_mount_point"`。TEST-19: 各行が「弾かせたい 1 か所」以外を満たしていることの担保） |
| `rv03ExtraKeyIsMalformed` | `RV-03 余分なキーがあれば malformed_request` | 正しい JSON に `"extra": 1` を足す |
| `rv03MissingKeyIsMalformed` | `RV-03 キーが欠けていれば malformed_request` | `session_key` を消す |
| `rv03BoolSchemaIsMalformed` | `RV-03 schema が真偽値なら malformed_request` | `"schema": true` |
| `rv03FloatSchemaIsMalformed` | `RV-03 schema が小数の表記なら malformed_request` | `"schema": 1.0` |
| `rv03WrongSchemaIsMalformed` | `RV-03 schema が 1 以外なら malformed_request` | `"schema": 2` |
| `rv03TargetCountIsMalformed` | `RV-03 targets がちょうど 1 要素でなければ malformed_request` | `targets` を 0 件 / 2 件（パラメタ化） |
| `rv03NegativeSizeIsMalformed` | `RV-03 size が負なら malformed_request` | `"size": -1` |
| `rv03BoolSizeIsMalformed` | `RV-03 size が真偽値なら malformed_request` | `"size": true` |
| `rv03StringMtimeIsMalformed` | `RV-03 mtime が数でなければ malformed_request` | `"mtime": "1"` |
| `rv03NotAnObjectIsMalformed` | `RV-03 JSON オブジェクトでなければ malformed_request` | `[]`（ただしファイル名は正しい。RV-02b の peek も失敗する経路） |
| `oversizedRequestIsMalformed` | 64 KiB を超える要求は malformed_request | 正しい JSON のあとに 64 KiB の空白 |
| `symlinkedRequestIsMalformed` | 要求が symlink なら malformed_request | 要求を別ファイルへの symlink に |

**RV-04〜RV-06 とロック・走査**

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `nd27ReplayedRequestIsRefused` | `ND-27 [R1] 同じ request_id の 2 回目は replayed` | 1 回目を走らせた後、**1 回目の結果ファイルを消し**（アプリが回収した後。残っていると RV-04 は結果を書かない）、同じ ID の要求をもう一度置いて 2 回目を走らせる | 2 回目は結果の `detail == "replayed"`、`processedLines()` が 1 行のまま（再追記しない）、要求が消える、`reason=replayed` のログ |
| `replayedDoesNotOverwriteAnExistingResult` | `RV-04 replayed は既に在る結果を上書きしない` | `processed.log` に ID を 1 行、`queue/result/<ID>.json` に `DELETED`（detail = relpath）を置き、同じ ID の要求を置く | 結果ファイルのバイト列が**変わらない**、要求が消える、`processedLines()` が 1 行のまま、`reason=replayed` のログ |
| `nd44PartkeyMismatchIsRefused` | `ND-44 [R1] device_id/relpath が partkey と違えば partkey_mismatch` | `partkey: "VDT0037/other.wav"` | `detail == "partkey_mismatch"`、要求が消える、ファイルが在る |
| `nd44DeviceIDMismatchIsRefused` | `ND-44 [R1] partkey の device_id だけが違えば partkey_mismatch` | `partkey: "OTHER/" + relpath` | 同上 |
| `rv05PartkeyMismatchKeepsTheSource` | `RV-05 device_id/relpath が partkey と違えば partkey_mismatch、原本は残る` | `partkey` を同じフォルダの別名 `VDT0037/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090001_orig.wav` に | exit 0、結果 1 件で `status == .sourceIdentityMismatch`・`detail == "partkey_mismatch"`・`deviceID == "VDT0037"`・`partkey` が要求のもの、`processedLines() == [requestID]`、要求が消える、デバイス上のファイルが在り大きさが 4096 のまま、`source_delete_rejected request_id=… reason=partkey_mismatch`（issue #87。ND-44 と振る舞いは重なるが RV の規範 ID のテストとして独立させる） |
| `rv06AbsentDeviceLeavesTheRequest` | `RV-06 デバイスが無ければ要求を残す` | `deviceID: "NOSUCH"`、`partkey` も合わせる | exit 0、要求が**残る**、`results() == []`、`processedLines() == []`、`device_absent request_id=… device=NOSUCH` |
| `rv06InvalidDeviceIDIsRejected` | `RV-06 device_id が不正なら not_a_mount_point` | `.hidden`・`a:b`（パラメタ化。partkey も合わせる） | `detail == "not_a_mount_point"`、要求が消える |
| `namesAreProcessedInByteOrder` | 要求は名前のバイト順に処理される | 乱数部だけ違う 3 件（`…-a00001`・`…-a00002`・`…-a00003`）を作る順を入れ替えて置く | `processedLines()` が昇順、`reaper_completed requests=3` |
| `nonASCIINamesAreProcessedInByteOrder` | 正規化で順が変わる名前もバイト順に処理される（rejected/ へ退避する名前） | `\u{212B}.json`（UTF-8 は E2 84 AB。Swift の比較では NFC の U+00C5）と `\u{00D0}.json`（C3 90）を置く（§6 の 14 のために足した。ASCII の名前では Swift の順とバイト順が一致し落ちない） | `request_rejected` の行が `\u{00D0}.json` → `\u{212B}.json` の順 |
| `rv04UnreadableProcessedLogIsFailClosed` | `RV-04 processed.log が読めなければ replayed（fail-closed）` | 空の `processed.log` を `chmod 0o000`（`state/` ごとではない。`state/` を 000 にするとロックが取れず exit 4 になる）＋ 通る要求 | 結果の `detail == "replayed"`、要求が消える、ファイルが在る（§6 の 19 のために足した） |
| `anEmptyQueueCompletesWithZero` | 要求が 0 件でも正常に終わる（TEST-28） | 要求を置かない | exit 0、`reaper_completed requests=0`、`reaper_started` が 1 行 |
| `aHeldLockStopsTheReaper` | ロックが取れなければ何もせず 4 | テスト側で `FileLock.tryAcquire(url: layout.reaperLock)` を保持したまま起動 | exit 4、`reaper_busy`、要求に触らない |
| `theLockIsReleasedAfterTheRun` | 実行が終わればロックは外れる（対照） | 1 回走らせた後にテスト側で `FileLock.tryAcquire` | 取れる（nil でない） |
| `theLogRotatesAtFiveMiB` | ログは 5 MiB を超える書き込みの前に `.1` へ回る | `logs/reaper.log` に `ReaperLog.maxBytes` バイトの詰め物を置いてから 1 回走らせる | `reaper.log.1` が詰め物と同じ、`reaper.log` が今回の行だけ |
| `theLogDoesNotRotateAtExactlyFiveMiB` | 書いた後がちょうど 5 MiB になる行では回さない（境界） | `logs/reaper.log` に `5 MiB − 47` バイトの詰め物（最初の行 `<ts 25 桁> INFO  reaper_started\n` が 47 バイト）を置いてから 1 回走らせる | `reaper.log.1` が 5 MiB ちょうどで詰め物 ＋ `reaper_started` の行、`reaper.log` が `reaper_completed` の 1 行だけ（§6 の 18 のために足した。詰め物が 5 MiB ちょうどだと `>` と `>=` のどちらでも回り、`theLogRotatesAtFiveMiB` は緑のままだった） |
| `sigtermStopsBetweenRequests` | SIGTERM は処理中の 1 件を終えてから止まる | 通らない要求（`partkey_mismatch`）を 500 件（1 件ごとに processed.log の fsync・結果の AtomicFile の fsync 2 回・要求の unlink があり、1 件目の結果が見えてから SIGTERM が届くまでに全部は片付かない。processed.log の詰め物は読み込みを遅くするだけで 1 件あたりの照合は重くならないので使わない。10 回続けて緑を確かめた）。`start()` → `results()` が空でなくなる（= ハンドラを入れた後に走査が始まった）まで 1 ms ごとに待ち（最大 10 秒）→ `sendTermination()` → `wait()`（60 ms 固定では、複製したばかりの実行ファイルの起動が間に合わず、ハンドラを入れる前の SIGTERM で終了コード 143 になった。実装時に確かめた） | exit 0、**どの要求も中途半端でない**（結果が在るなら要求が消えている、結果が無いなら要求が残っている）、要求が 1 件以上残る、`reaper_completed requests=<結果の数>` |

- `ReaperLog.format` / `ReaperLog.value` の単体（同じファイル内の `@Suite("ReaperLog の行") struct ReaperLogLineTests`。`infoIsPaddedToFive`「INFO は 5 桁左寄せ（INFO と 2 つの空白の後に event）」・`fieldsAreAppendedInOrder`「フィールドは順に k=v で足される」・`valuesAreQuoted`「値は §8.15 のとおりに引用される」（パラメタ化））: 空白を含む値・`=` を含む値・空文字列・`"` を含む値・改行を含む値・非 ASCII が §8.15 のとおりに引用されること、`INFO` が 5 桁左寄せ（`"INFO  "` の後に event）であること

### 5.4 `ReaperDiskImageTests.swift`（`@Suite("voicedock-reaper × FAT32（層 R3）", .serialized, .enabled(if: TestEnvironment.diskTests))`）

共通の準備: `let image = try DiskImageVolume(in: tmp, deviceID: ReaperBench.deviceID, filesystem: .fat32)`（`"VDT0037"`。PLAN §10.2 により DJIMIC3 は使えない）、`let bench = try ReaperBench(in: tmp, diskImage: image)`。
要求の `size` / `mtime` は `bench.actualStat()` の値（**FAT が丸めた実物の値**）。各テストは**弾かせたい条件以外をすべて満たす**（TEST-19）。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `aValidRequestActuallyDeletes` | 正の対照: 通る要求は本当に消える | 既定 | exit 0、**デバイス上のファイルが無い**、結果が `DELETED`・`detail == relpath`・`partkey` が載る、`processedLines() == [ID]`、要求が消える、`source_deleted request_id=… partkey=…` |
| `nd18SizeMismatchBlocksTheDelete` | `ND-18 [R3] 削除直前にサイズが変わると size_mismatch` | 要求の `size` を `+1` | `detail == "size_mismatch"`、**ファイルが在る**、要求が消える |
| `nd19MtimeMismatchBlocksTheDelete` | `ND-19 [R3] 削除直前に mtime が変わると mtime_mismatch` | 要求の `mtime` を `+4.0` | `detail == "mtime_mismatch"`、ファイルが在る |
| `aSmallMtimeDriftIsTolerated` | 対照: mtime の差が 2 秒未満なら消える | 要求の `mtime` を `+1.0` | ファイルが無い、`DELETED` |
| `fatMtimeHasTwoSecondResolution` | FAT の mtime は 2 秒刻み（実物の値を使う） | `actualStat().mtime` を確かめる | `mtime.truncatingRemainder(dividingBy: 2) == 0`、小数部が 0 |
| `nd20ASymlinkTargetIsNeverDeleted` | `ND-20 [R3] 対象自身が symlink なら target_is_symlink` | 別名の実体を置き、`relpath` の位置を実体への symlink に | `detail == "target_is_symlink"`、symlink も実体も在る |
| `nd25ASymlinkInThePathIsNotFollowed` | `ND-25 [R3] 経路の途中が symlink なら path_contains_symlink` | 実フォルダを別名で作り、`folder` をそこへの symlink に。ファイルは実フォルダの中 | `detail == "path_contains_symlink"`、ファイルが在る |
| `nd24ATraversalRelpathIsRefused` | `ND-24 [R3] relpath に ../ があれば relpath_unsafe` | `relpath` を `TX_MIC001_20260912_090000/../TX_MIC001_20260912_090000/TX00…_orig.wav`（partkey も合わせる） | `detail == "relpath_unsafe"`、ファイルが在る |
| `nd28ADotPrefixedElementIsRefused` | `ND-28 [R3] . で始まる要素があれば relpath_unsafe` | `.Trashes/TX00…_orig.wav` / `TX_MIC001_20260912_090000/.TX00…_orig.wav`（パラメタ化。実物も置く） | `detail == "relpath_unsafe"`、置いたファイルが在る |
| `nd23AReadOnlyMountLeavesTheRequest` | `ND-23 [R3] 読み取り専用で再マウントされていたら要求を残す（RV-07）` | `image.reattach(readOnly: true)` | exit 0、**要求が残る**、`results() == []`、`processedLines() == []`、`mount_readonly request_id=… device=VDT0037`、ファイルが在る |
| `nd29AFolderThatBreaksTheRuleIsRefused` | `ND-29 [R3] 親フォルダ名が規則外なら folder_rule` | フォルダ名を `OTHER` に（ファイル名は規則どおり） | `detail == "folder_rule"`、ファイルが在る |
| `nd29AFileAtTheVolumeRootIsRefused` | `ND-29 [R3] ボリューム直下のファイルは常に folder_rule` | `relpath` を `TX00_MIC001_20260912_090000_orig.wav` に | 同上 |
| `nd37ADenoisedFileIsRefused` | `ND-37 [R3] _orig の無いファイルは filename_rule` | ファイル名を `TX00_MIC001_20260912_090000.wav` に | `detail == "filename_rule"`、ファイルが在る |
| `nd31AnotherDeviceIsNotTouched` | `ND-31 [R3] device_id だけが違う同名ファイルは消さない` | イメージを 2 つ（`VDT0037` と `VDT0038`）作り、同じ relpath のファイルを両方に置く。要求は `VDT0037` の分だけ | `VDT0037` の分が消え、**`VDT0038` の分は在る** |
| `nd39AnHfsImageIsUnexpectedFS` | `ND-39 [R3] HFS+ のイメージは unexpected_fs` | `DiskImageVolume(.hfsPlus)` | `detail == "unexpected_fs"`、ファイルが在る |
| `rv09AMissingTargetIsRefused` | `RV-09 対象が無ければ target_missing` | 要求を書いた後にファイルを消す | `detail == "target_missing"` |
| `rv09AMissingDirectoryIsRefused` | `RV-09 経路の途中が無ければ target_missing` | フォルダごと消す | 同上 |
| `rv10ADirectoryIsNotARegularFile` | `RV-10 対象がディレクトリなら not_regular_file` | `relpath` の位置をディレクトリに（規則に合う名前のディレクトリ） | `detail == "not_regular_file"`、ディレクトリが在る |
| `rv13TheAbsenceIsVerifiedAfterUnlink` | `RV-13 unlink の後に不在を確かめる` | 既定（正の対照と同じ） | `DELETED`、`fstatat` が ENOENT を返す状態（ファイルが無い）。**この検査を外すと `aValidRequestActuallyDeletes` は緑のままなので、破壊による証明の 10 で担保する** |
| `twoRequestsAreBothDeleted` | 2 件の要求が両方とも消える（走査の続き） | 2 つ目の録音を置き、要求を 2 件 | 両方消える、`reaper_completed requests=2` |

- `.diskImage` のテストは `/Volumes` の下に attach しない（`DiskImageVolume` が一時ディレクトリにマウントする。T-07）
- **ND-20 / ND-25 は macOS の msdos が symlink（`XSym` 形式）を作れることに依存する。**実装時に `symlink(2)` が `ENOTSUP` で失敗したら、その 2 本は層 R2（T-07）だけに残し、PLAN 付録 B.1 の「層」の列と `docs/SPEC.md` の S7 を同じ PR で `R2` に直す（§9 に手順を書いた）

### 5.5 `Tests/PolicyTests/SpecSync/SpecCoverageTests.swift`（行を直す。T-39 §6.7 の行）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `activatedKeepsTheCheckedKinds` | 有効にした種類は .cv・.dr・.nd・.rv を含む（外すと集合の一致の検査が黙って止まる。T-39・issue #87） | なし | `SpecCoverage.activated.isSuperset(of: [.cv, .dr, .nd, .rv])` |

`.rv` を `activated` に足すと、`activatedKindsMatchSpec` が SPEC の RV-00〜RV-13 とテストの表示名の RV の集合の一致を確かめる（T-05 §4）。

## 6. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | `SelfLocation.isAtExpectedPlace` を `true` を返すだけにする | `nd40BundledReaperDoesNothing`、`nd40AnyOtherPlaceIsRefused`、`rv00SymlinkedReaperIsRefused`、`rv00AnotherHomeIsRefused` |
| 2 | `SelfLocation` の `bundleMarker` の検査だけを消す | `nd40BundledReaperDoesNothing` |
| 3 | `ReaperMain` の手順 6 で `.missing` を `.valid(ReaperConf(deleteSourceAudio: true))` に倒す（**この変異は VOLUMES_ROOT を既定の `/Volumes` にする。実機を抜いてから行う**。舞台の deviceID を DJIMIC3 にしないのはこのため） | `missingConfIsInvalid` |
| 4 | 手順 7（RV-01）を消す | `nd22Lock1FalseTouchesNothing` |
| 5 | 手順 8 の `FileLock` を取らない | `aHeldLockStopsTheReaper` |
| 6 | `QueueFiles.isRequestFileName` を `name.hasSuffix(".json")` だけにする | `nd38BadFileNamesGoToRejected` |
| 7 | `RequestProcessor` の手順 4（RV-02b）を消す | `nd38InnerRequestIDMismatchGoesToRejected`、`rv02bNonStringRequestIDGoesToRejected` |
| 8 | 手順 6 の `queue.resultExists` の確認を消す（いつも結果を書く） | `replayedDoesNotOverwriteAnExistingResult` |
| 9 | 手順 7（RV-05）を消す | `nd44PartkeyMismatchIsRefused`、`nd44DeviceIDMismatchIsRefused` |
| 10 | `Unlinker.unlinkTarget` の `fstatat` の確認を消し常に `.ok` を返す | 落ちない（正常系では消えているため）。**この防御は検査で担保できないので、代わりに `unlinkat` を `0` を返すだけのスタブにして `aValidRequestActuallyDeletes` が落ちる（`still_present` にならず `DELETED` を書いてしまう）ことを PR に貼る** |
| 11 | 手順 8 の `.absent` を `refuse(device_absent)` に変える | `rv06AbsentDeviceLeavesTheRequest` |
| 12 | 手順 9（RV-07）を消す | `nd23AReadOnlyMountLeavesTheRequest` |
| 13 | `withVerifiedTarget` の戻りを無視して `unlinkat` を直接呼ぶ | 層 R3 の ND-18・19・20・24・25・28・29・37 が全部落ちる |
| 14 | `names()` の並べ替えを `sorted()`（Swift の文字列順）にする | `namesAreProcessedInByteOrder`（ASCII の範囲では落ちないので、**乱数部に `-` と `_` を含む名前を 1 件足してから**行う。落ちなければ検査を足す） |
| 15 | 手順 12 の `Signals.stopRequested` の確認を消す | `sigtermStopsBetweenRequests` |
| 16 | 結果の `detail` を `relpath + " \| " + reason` の連結にする | 層 R1・R3 の `detail` を見る全テスト |
| 17 | `ReaperLog.value` の引用を「そのまま返す」だけにする | `ReaperLog の行` の引用のテスト |
| 18 | `ReaperLog` の回転の条件を `size + n >= maxBytes` にする | `theLogRotatesAtFiveMiB` |
| 19 | `ProcessedLog.contains` の `unreadable` を `false` に倒す（fail-open） | （直接の検査が無い。`state/` を `chmod 0o000` にして `processedLines()` が読めない舞台で `nd39PlainDirectoryIsNotAMountPoint` が `replayed` にならないことを確かめるテストを足すか、レビュー項目として PR に書く） |
| 20 | `ReaperBench` の手順 2（`<HOME>/bin` への複製）を消す | 層 R1・R3 の全テスト（exit 3 になる） |
| 21 | RV-01 の 3 本（§5.2）の表示名から `RV-01 ` を外す（1 本だけでは残りの 2 本が RV-01 を数えるので落ちない。issue #87） | `activatedKindsMatchSpec`（SPEC だけに RV-01） |
| 22 | 手順 7（RV-01）を消す（4 と同じ変異。issue #87） | `rv01Lock1FalseExitsZeroAndTouchesNothing` |
| 23 | 手順 6 の `.missing, .invalid` の分岐で `reason=lock1` を出して 0 を返す（issue #87） | `rv01InvalidConfExitsTwoAndTouchesNothing` |
| 24 | `RequestProcessor` の手順 4（RV-02b）の照合を「文字列であること」だけにする（issue #87） | `rv02bInnerRequestIDMismatchGoesToRejected` |
| 25 | `QueueFiles.isRequestFileName` を `name.hasSuffix(".json")` だけにする（6 と同じ変異。issue #87） | `rv02aMalformedFileNameGoesToRejected` |
| 26 | 手順 7（RV-05）を消す（9 と同じ変異。issue #87） | `rv05PartkeyMismatchKeepsTheSource` |

### 6.1 実施結果（T-37 の実装時。コミット後の清潔な状態で 1 項目ずつ壊し、`git checkout --` で戻した。層 R1 だけ）

| # | 落ちたテスト |
|---|---|
| 1 | ND-40 ×2、RV-00 symlink・別の --home・--home が無い（5 本） |
| 2 | 最初は落ちなかった（`nd40BundledReaperDoesNothing` は一致の検査でも弾かれる）→ `rv00HomeInsideABundleIsRefused` を足して落ちた |
| 3 | `missingConfIsInvalid`（**実機が挿さったまま行ってしまった**。この変異は VOLUMES_ROOT を `/Volumes` にし、当時の舞台の deviceID は DJIMIC3 だったので reaper は実機を開いた。対象のフォルダ `TX_MIC001_20260912_090000` が実機に無く `target_missing` で止まり何も消えていない。以後、舞台の deviceID を VDT0037 にした） |
| 4 | `nd22Lock1FalseTouchesNothing` |
| 5 | `aHeldLockStopsTheReaper` |
| 6 | 最初は落ちなかった（中の request_id が既定のままだと RV-02b が代わりに弾く）→ 中の request_id を stem にして `nd38BadFileNamesGoToRejected` が落ちた |
| 7 | `nd38InnerRequestIDMismatchGoesToRejected`、`rv02bNonStringRequestIDGoesToRejected` |
| 8 | `replayedDoesNotOverwriteAnExistingResult` |
| 9 | `nd44PartkeyMismatchIsRefused`、`nd44DeviceIDMismatchIsRefused` |
| 10・12・13 | **未実施**（層 R3。ディスクイメージが要る）。【利用者が行う】実機を抜いてから、壊す → build → `VOICEDOCK_DISK_TESTS=1 swift test --filter ReaperDiskImageTests` → 戻す を 10a（fstatat の確認だけ消す。落ちない見込み）・10b（加えて unlinkat をスタブに）・12・13 の順に行い、最後に壊していない層 R3 を通すスクリプトを用意した（PR 本文に場所と結果を貼る）。各変異がちょうど 1 か所に当たりビルドが通ることは、ディスクイメージのテストを回さずに確かめた |
| 11 | `rv06AbsentDeviceLeavesTheRequest` |
| 14 | `nonASCIINamesAreProcessedInByteOrder`（ASCII の名前の `namesAreProcessedInByteOrder` は落ちない） |
| 15 | `sigtermStopsBetweenRequests` |
| 16 | `detail` を見る層 R1 の 20 本（RV-03 の 12 本・ND-27・ND-39・ND-44 ×2・RV-06 不正な device_id・RV-04 fail-closed・対照 2 本） |
| 17 | `valuesAreQuoted`、`nonASCIINamesAreProcessedInByteOrder` |
| 18 | 最初は落ちなかった（5 MiB ちょうどの詰め物では `>` と `>=` のどちらでも回る）→ `theLogDoesNotRotateAtExactlyFiveMiB` を足して落ちた |
| 19 | `rv04UnreadableProcessedLogIsFailClosed`（足したテスト） |
| 20 | 舞台を使う層 R1 の 53 本すべて（`ReaperLog の行` の 3 本だけが緑） |

issue #87 で足した 21〜26（同じく層 R1 だけ。コミット後の清潔な状態で 1 項目ずつ壊し、Python の `finally` で `git checkout --` した）:

| # | 落ちたテスト |
|---|---|
| 21 | `activatedKindsMatchSpec` |
| 22 | `rv01Lock1FalseExitsZeroAndTouchesNothing`、`nd22Lock1FalseTouchesNothing` |
| 23 | `rv01InvalidConfExitsTwoAndTouchesNothing`、ND-43 の 5 本（パラメタ化を含む）、`missingConfIsInvalid`・`symlinkedConfIsInvalid`・`oversizedConfIsInvalid` |
| 24 | `rv02bInnerRequestIDMismatchGoesToRejected`、`nd38InnerRequestIDMismatchGoesToRejected`（`rv02bNonStringRequestIDGoesToRejected` は型の検査が残るので緑） |
| 25 | `rv02aMalformedFileNameGoesToRejected`、`nd38BadFileNamesGoToRejected`（5 件のパラメタ） |
| 26 | `rv05PartkeyMismatchKeepsTheSource`、`nd44PartkeyMismatchIsRefused`、`nd44DeviceIDMismatchIsRefused` |

## 7. 受け入れ条件

- [ ] `Sources/voicedock-reaper/` の import が Foundation・Darwin・Synchronization・VDContract だけ（PT-07・PT-15 が通る）
- [ ] `unlinkat(` が `Unlinker.swift`、`print(` が `main.swift`、`Date()` が `ReaperClock.swift`、`O_CREAT`／`rename(`／`renameat(` が `ProcessedLog.swift`・`ReaperLog.swift`・`QueueFiles.swift` にしか無い（PT-01・08・09・12 が通る）
- [ ] `VolumeHandle(` を書いていない（PT-22）。ボリュームは `TargetIdentity.openVolume` からだけ得る
- [ ] 終了コード 0 / 2 / 3 / 4 が PLAN §8.9.4 のとおり。`--version` が RV-00 より前に処理される
- [ ] 処理の順序が PLAN §8.9.4 の表と一致し、`rejected/` へ移す段だけが結果と processed.log を書かない
- [ ] 層 R1 の全テストが CI で回る（`.diskImage` を要求しない）。層 R3 が `make test-disk` で通る
- [ ] 層 R1・R3 それぞれに正の対照がある（R1 `nd39PlainDirectoryIsNotAMountPoint`、R3 `aValidRequestActuallyDeletes`）
- [ ] `ReaperBinary` が `.xctest` と同じディレクトリから実行ファイルを見つけ、`/Volumes` に一切触れない
- [ ] 破壊による証明の結果（落ちたテスト名）が PR 本文にある

## 8. SPEC の変更

`docs/SPEC.md` に足す表（T-05 の SPEC 同期が読む）:

| 節 | 内容 |
|---|---|
| S8（reaper の終了コード。新設） | `0` 正常（ロック 1 が false も含む）/ `2` 引数不正・reaper.conf が無い・読めない・不正 / `3` RV-00 / `4` ロックが取れない |
| S9（reaper のログイベント。新設） | `reaper_started`・`reaper_busy`・`reaper_disabled`・`request_rejected`・`source_delete_rejected`・`device_absent`・`mount_readonly`・`source_deleted`・`reaper_completed` の 9 件をこの順で |

（PLAN §8.9.4 に同じ内容が散文で在る。SPEC 同期のテストが照合できるよう表にする。T-05 の `SpecDocument` の鍵に `S8`・`S9` を足すのは**このチケットの PR**で行う）

**未実施（判断待ち）**: 実装時の `docs/SPEC.md` では **S8 は「reaper の検証 RV（付録 B.2）」、S9 は「実機試験 E2E（付録 B.3）」として既に使われている**ので、上の表の節番号は衝突する。
また `docs/SPEC.md` と `Tests/TestSupport/Spec/SpecDocument.swift` は §3「作るもの」の表に無く、SPEC は PLAN から `make spec`（`tools/spec/make-spec.py`）で写す物なので、このチケットの PR では変えていない。
新設するなら節番号（例 S10・S11）と PLAN 側の表の置き場所を決めてから、PLAN → `make spec` → `SpecDocument` の順に別の PR で行う。

## 9. マージ後にやること

- T-38 が `ReaperRunner.run()` でこの実行ファイルを起動し、`DeletionScene.installRealReaper()`（T-38）が `ReaperBinary.url()` を使う
- **層 R3 の symlink（ND-20 / ND-25）が msdos で作れなかった場合**: その 2 本を消し、PLAN 付録 B.1 と `docs/SPEC.md` の S7 の「層」の列を `R2・R3` → `R2` に直す PR を同じ Phase 内で出す（T-05 の `ndLayersMatchPlan` と `ndLayersAreCovered` が守る）
- T-34 の `make-app.sh` が `Contents/Helpers/voicedock-reaper` にこの実行ファイルを入れ、`<BUNDLE_ID>.reaper` の識別子で署名する（T-36 の `ReaperSignature.requirement` と合わせる）

## 10. API 地図への変更提案

1. §13 に `ReaperIO.swift`（fd の読み書き・`realpath`・`lstat` の共通部）を足す。VDContract の `PosixIO` は internal なので reaper からは使えず、`QueueFiles`・`ProcessedLog`・`ReaperLog`・`SelfLocation` の 4 つが同じループを持つのを避けるため（代案: `PosixIO` を `public` にする）
2. §13 の `main.swift` の役割を「`ReaperMain.run(arguments:)` が返す `ReaperExit`（code / stdout / stderr）を出力して `exit`」にする。`--version` の出力を `main.swift` に閉じる（PT-08）ために、`ReaperMain` は書かずに返す
3. §15 の `ReaperBinary` の説明に `ReaperRun`・`ReaperProcess`（SIGTERM を送る）・`ReaperBinaryError` を足す
4. PLAN §3.4 の `voicedock-reaper` の import に **`Synchronization`** が含まれることを明示する（§3.4 の前文の「すべてのモジュールで import してよい」で読めるが、行にも書く）。
   加えて、`_NSGetExecutablePath` が `import Darwin` だけで見えない場合は **`MachO`** を足す必要がある（実装時に確かめ、必要なら PLAN §3.4・PT-07 の許可リストと同じ PR で直す）
5. PLAN §8.9.4 に**書き込みに失敗したときの扱い**を足す（本チケット §4.10 で決めた）: 「processed.log への追記の失敗は無視して先へ進む」「結果を書けなかったら要求を残して次へ回す（拒否の場合は `source_delete_rejected` も出さない。成功の場合は `source_deleted` を出す）」「要求ファイルの unlink の失敗は無視する」
6. PLAN §8.9.4 の `reaper_completed requests=<N>` を「要求が 0 件でも出す」と明記する（voicedock は 0 件のとき出さなかった）
7. `ProcessedLog.append` と `ReaperLog` の追記用の `open` に **`O_NOFOLLOW` を足す**（利用者の判断待ち。未実装）。いまは `state/processed.log` や `logs/reaper.log` が symlink だと、それを辿って `<HOME>` の外のファイルへ追記できる（`ReaperLog` の回転の `rename` は symlink そのものを動かすので外には書かない）。足すなら、symlink のときは追記に失敗し、processed.log は「追記の失敗は無視」、ログは「書けなければ何もしない」の既存の規則に落ちる
