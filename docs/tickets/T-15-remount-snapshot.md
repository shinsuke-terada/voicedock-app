# T-15 VDDevice: 再マウント・snapshot・IngestService の走査

| 項目 | 値 |
|---|---|
| ID | T-15 |
| Phase | 3（取り込み） |
| 前提 | T-14（`IngestService` の骨組み・`ingestDevice`・`IngestDependencies`・`BWFWriter`）。T-13（`DeviceDetector`・`MountInspector`・`CoexistenceGuard`・`FakeMountInspector`・`ScriptedProcessRunner`）、T-06（`FileLock`・`TempDirectory`）、T-10（`FixedClock`・`RecordingSleeper`・`CapturingLogSink`）はその前提に含まれる。T-07（TestSupport の `FakeVolume`・`DiskImageVolume`）は T-13 が要る前提（README の索引への追加は T-13 のヘッダに記載） |
| 見積もり | 実装 約 550 行、テスト 約 750 行（TestSupport を含む） |

## 1. 目的

`IngestService` を完成させる: 起動契機（マウント通知・周期・`scanNow()`）の受け付けとまとめ、1 回の走査の手順（共存ガード → reaper.lock → デバイス判定 → 読み取り専用の確保 → 観測 → 取り込み → snapshot の公開）、
`DeviceSnapshot`（世代・`connectEpoch`・0 台と不明の区別）、`IngestActivity`、`scanNow()` の意味、変化したときだけ出す警告。読み取り専用の再マウントを行う `DiskutilRemounter` もここで作る（PLAN §8.1）。

## 2. 参照

- PLAN §8.1（起動契機・1 回の走査の手順・読み取り専用の確保・snapshot・沈黙の判定）、§2.1（reaper.lock・`BlockingIO`）、§5.4（`connectEpoch` と契機 2）、§8.9.6（`scanNow()` の使われ方）、§8.11（沈黙の判定）、付録 A.4
- voicedock@d3d595e: `helper/voicedock-ingest:520-547`（`_is_mounted_readonly`・`remount_readonly`）、`:803-864`（`main` の流れ、観測値を書く理由）、`src/voicedock/worker.py:272-307`（立ち上がりエッジ）、
  `tests/unit/test_helper_ingest.py:823-929`（再マウントの固定事例）・`:1213-1260`（録音 0 件のデバイス）、`tests/unit/test_worker_loop.py:334-455`（立ち上がりエッジの固定事例）
- 移植メモ V1 §6.5・§6.6、V3 §1.1

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDDevice/Remounter.swift` | `RemountOutcome`、`Remounter`、`DiskutilRemounter`、`MountEventSource`（置き場所は 00-api-map §5） |
| `Sources/VDDevice/WorkspaceMountEventSource.swift` | `WorkspaceMountEventSource`（NSWorkspace の通知。本番の実装） |
| `Sources/VDDevice/DeviceSnapshot.swift` | `DeviceSnapshot`、`DeviceObservation`、`IngestActivity` |
| `Sources/VDDevice/IngestDependencies.swift` | （T-14 のファイルに追記）`remounter`・`mountEvents` |
| `Sources/VDDevice/IngestService.swift` | （T-14 のファイルに追記）公開 API・`IngestState`（置き場所は 00-api-map §5）・走査の手順 |
| `Tests/TestSupport/FakeRemounter.swift` | `Remounter` の差し替え |
| `Tests/TestSupport/FakeMountEventSource.swift` | `MountEventSource` の差し替え |
| `Tests/TestSupport/SuspendingSleeper.swift` | 止められるまで戻らない `Sleeper`（周期の走査を止めておくため） |
| `Tests/TestSupport/DiskImageVolume+Ingest.swift` | T-07 の `DiskImageVolume` への extension（`uniqueName()`・`node`。本体は T-07 が作る。00-api-map §15） |
| `Tests/VDDeviceTests/RemounterTests.swift` | |
| `Tests/VDDeviceTests/DeviceSnapshotTests.swift` | |
| `Tests/VDDeviceTests/IngestServiceTests.swift` | |
| `Tests/VDDeviceTests/IngestServiceDiskImageTests.swift` | `.diskImage` |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 2 キーを消す（§5.6） |

## 4. 仕様

### 4.1 `Remounter.swift`

```swift
// 読み取り専用での再マウント（PLAN §8.1。ロック 2-B の実施側）。diskutil の出力文言は使わない。
public enum RemountOutcome: Equatable, Sendable {
    case alreadyReadOnly               // 既に ro。何もしなかった（DEL-31）
    case remounted(newPath: String)    // unmount → mount readOnly が成功し、マウント一覧に node が在った
    case failed(reason: String)        // no_device_node / unmount_failed / mount_failed
}

public protocol Remounter: Sendable {
    func remountReadOnly(path: String, node: String) async -> RemountOutcome
}

public struct DiskutilRemounter: Remounter {
    public static let diskutil = URL(fileURLWithPath: "/usr/sbin/diskutil")
    public static let timeout: Duration = .seconds(60)
    public init(runner: any ProcessRunning, inspector: any MountInspector, useMountPoint: Bool)
    public func remountReadOnly(path: String, node: String) async -> RemountOutcome
}
```

`remountReadOnly(path:node:)` の手順:
1. `guard let info = inspector.mountInfo(path: path) else { return .failed(reason: "no_device_node") }`
2. `if info.readOnly { return .alreadyReadOnly }`（**毎回 unmount し直さない**。DiskArbitration は ro の unmount を拒むことがあり、成功の直後の実行が必ず「失敗」を報告する。#107）
3. `guard node.hasPrefix("/dev/") else { return .failed(reason: "no_device_node") }`
4. `runner.run(ProcessSpec(executable: Self.diskutil, arguments: ["unmount", path], environment: ProcessEnvironment.cLocale), timeout: Self.timeout)` の `termination` が `.exited(0)` でなければ `.failed(reason: "unmount_failed")`
5. mount の引数: `useMountPoint` なら `["mount", "readOnly", "-mountPoint", path, node]`、そうでなければ `["mount", "readOnly", node]`。同じ環境・タイムアウトで実行し、`.exited(0)` でなければ `.failed(reason: "mount_failed")`
6. `guard let newPath = inspector.allMounts().first(where: { $0.mountFromName == node })?.mountOnName else { return .failed(reason: "mount_failed") }`
7. `.remounted(newPath: newPath)`
- `still_writable` の判定はここでしない（呼び手が statfs の観測で判定する。観測値だけを書く。DEL-31）
- `useMountPoint` の本番の値は **`false`**（P0-02 で確定。実機では `diskutil unmount` で `/Volumes/<名前>` が消え、`-mountPoint` 付きの mount は毎回 `Mountpoint … does not exist` で失敗した。付けなくてもパスは 18/18 保たれた。`docs/POC.md` 章 3）。`Bootstrap`（T-30）が渡す

### 4.2 `DeviceSnapshot.swift`

```swift
// 1 回の走査の観測（PLAN §8.1）。走査ごとに 1 つだけ公開する。時刻で新旧を比べない（generation を使う）。
public struct DeviceSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let completedAt: Instant
    public let connectEpoch: UInt64
    public let devices: [String: DeviceObservation]          // key = device_id。0 台なら空（「不明」ではない。DEL-32）
    public let unavailable: [String: String]                 // 名前 → not_listable / mount_name_mismatch / invalid_device_id
    public let notListableErrno: [String: Int32]             // not_listable の errno（EPERM のときだけ TCC の案内。DR-11）
    public init(generation:completedAt:connectEpoch:devices:unavailable:notListableErrno:)
    /// now − completedAt <= maxAgeSeconds（等号を含む）
    public func isFresh(now: Instant, maxAgeSeconds: Int) -> Bool {
        now.epochMillis - completedAt.epochMillis <= Int64(maxAgeSeconds) * 1000
    }
}

public struct DeviceObservation: Equatable, Sendable {
    public let deviceID: String
    public let mountPath: String
    public let deviceNode: String?
    public let readOnly: Bool?        // statfs の観測値。観測できなければ nil（偽と区別する。DEL-31 / DEL-32）
    public let freeBytes: Int64?
    public let relpaths: Set<String>  // _orig も denoised も全部。録音 0 件なら空（DEV-19）
    public init(deviceID:mountPath:deviceNode:readOnly:freeBytes:relpaths:)
}

public struct IngestActivity: Equatable, Sendable {
    public let scanning: Bool
    public let deviceID: String?
    public let copied: Int
    public let total: Int
    public let lastActivityAt: Instant?
    public init(scanning:deviceID:copied:total:lastActivityAt:)
    public static let idle = IngestActivity(scanning: false, deviceID: nil, copied: 0, total: 0, lastActivityAt: nil)
}
```

`IngestState`（`IngestService.swift` に置く。00-api-map §5）:
```swift
public enum IngestState: Equatable, Sendable {
    case idle
    case scanning
    case coexistenceBlocked   // voicedock の Helper が登録されている（PLAN §8.1 手順 1）
    case disabled             // 設定エラー中（configProvider が nil）
}
```

### 4.3 `MountEventSource`（`Remounter.swift`）と `WorkspaceMountEventSource.swift`

契機の種類は走査の側で区別しない（どれも「再走査要求」にまとめる）ので、ストリームの要素は `Void`（00-api-map §5）:
```swift
// Remounter.swift に置く
public protocol MountEventSource: Sendable {
    /// 購読ごとに新しいストリーム。マウント・アンマウント・スリープ復帰のたびに () を 1 つ流す。ストリームが終われば購読をやめる
    func events() -> AsyncStream<Void>
}
```
```swift
// WorkspaceMountEventSource.swift — NSWorkspace の通知（didMount / didUnmount / didWake）を () に写す
import AppKit
public struct WorkspaceMountEventSource: MountEventSource {
    public init() {}
    public func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let names: [Notification.Name] = [
                NSWorkspace.didMountNotification,
                NSWorkspace.didUnmountNotification,
                NSWorkspace.didWakeNotification,
            ]
            let tasks = names.map { name in
                Task { @MainActor in
                    for await _ in NSWorkspace.shared.notificationCenter.notifications(named: name) {
                        continuation.yield(())
                    }
                }
            }
            continuation.onTermination = { _ in
                for task in tasks { task.cancel() }   // swift format の ReplaceForEachWithForLoop
            }
        }
    }
}
```
- `AppKit` の import は VDDevice の許可リストどおり NSWorkspace の通知だけに使う（§3.4）
- `Notification` をストリームの外へ渡さない（`()` に写してから渡す）
- `WorkspaceMountEventSource` は `Bootstrap`（VoiceDockApp）が注入する公開の型で、00-api-map に無い（10 の提案 3）

### 4.4 `IngestDependencies.swift` への追記

`inspector` の後に 2 つ足す（初期化子の引数もこの順。最終の並びは 00-api-map §5: `layout, configProvider, store, inspector, remounter, mountEvents, reader, coexistence, clock, sleeper, zone, log, volumesRoot`）:
```swift
    public let remounter: any Remounter
    public let mountEvents: any MountEventSource
```
- **本番の `volumesRoot` は `Contract.volumesRoot`（`/Volumes`）を `Bootstrap` が注入する。テストは必ず一時ディレクトリを渡す**（下記 5 の安全の約束）
- 初期化子の引数が増えるので、T-14 のテスト（`IngestCopyTests`）の `IngestDependencies(…)` の呼び出しにも `remounter: FakeRemounter(outcomes: [.alreadyReadOnly])`・`mountEvents: FakeMountEventSource()` を足す（本チケットの PR で直す）

### 4.5 `IngestService.swift` への追記

```swift
extension IngestService {
    public func start()                                   // 通知の購読・周期の走査・最初の走査
    public func stop()                                    // 新しい走査を始めない。待っている scanNow() に nil を返す
    public func scanNow() async -> UInt64?                // 呼び出しの後に始まり完了した走査の generation。見送りなら nil
    public func latestSnapshot() -> DeviceSnapshot?
    public func activity() -> IngestActivity
    public func state() -> IngestState
    public func updates() -> AsyncStream<Void>            // 公開・状態の変化・1 本のコピーのたびに 1 つ流す（最新 1 つだけ溜める）
}
```

actor に足す状態（`IngestService` の中に書く）:
```swift
var snapshot: DeviceSnapshot? = nil
var generation: UInt64 = 0
var connectEpoch: UInt64 = 0
var scanning = false                 // 走査のループが動いているか
var rescanRequested = false          // 走査中に届いた契機（1 つにまとめる）
var startedScans: UInt64 = 0         // 始めた走査の数（1 から）
var waiters: [(minStart: UInt64, continuation: CheckedContinuation<UInt64?, Never>)] = []
var ingestState: IngestState = .idle
var previousUnavailable: [String: String] = [:]
var updateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
var backgroundTasks: [Task<Void, Never>] = []
var started = false
static let lockAttempts = 130
static let lockRetrySeconds = 1
```

`start()`:
1. `started` なら何もしない。`started = true`、`stopRequested = false`
2. 通知の購読: `backgroundTasks.append(Task { for await _ in deps.mountEvents.events() { self.requestScan() } })`（`deps` は let で先に取り出す。actor の中で作った `Task` は actor の隔離を引き継ぐので `requestScan()` に `await` を付けない。付けると「await の中に async の呼び出しが無い」の警告がエラーになる）
3. 周期: `backgroundTasks.append(Task { while !Task.isCancelled { let seconds = await deps.configProvider()?.device.scanIntervalSeconds ?? 300; do { try await deps.sleeper.sleep(seconds: seconds) } catch { return }; self.requestScan() } })`
4. `requestScan()`（最初の走査）

`stop()`: `stopRequested = true` → `backgroundTasks` を全部 cancel して空に → `waiters` の全部に `nil` を返して空に → `updateContinuations` を全部 `finish()` して空に → `started = false`

`scanNow()`:
```swift
if stopRequested { return nil }
let target = startedScans + 1
return await withCheckedContinuation { continuation in
    waiters.append((target, continuation))
    requestScan()
}
```
- 走査中に呼ばれたら、今の走査ではなく**次に始まる**走査（再走査要求）を待つ（「呼び出しの後に始まった走査」。§8.9.6 が reaper の後の観測を得るため）

`requestScan()`（internal、同期）:
```swift
if stopRequested { return }
if scanning { rescanRequested = true; return }
scanning = true
Task { await self.runScans() }
```
`runScans()`:
```swift
repeat {
    rescanRequested = false
    await performScan()
} while rescanRequested && !stopRequested
scanning = false
notifyUpdate()
```

`performScan()`（1 回の走査。PLAN §8.1 の手順）:
```text
startedScans += 1; index = startedScans
progressDeviceID = nil; progressCopied = 0; progressTotal = 0; notifyUpdate()
if stopRequested: finishWaiters(upTo: index, nil); return
guard let config = await deps.configProvider() else { setState(.disabled); finishWaiters(index, nil); return }
if await deps.coexistence.isVoicedockHelperLoaded():
    if ingestState != .coexistenceBlocked: log WARNING coexistence_blocked   // 入ったときだけ 1 回
    setState(.coexistenceBlocked); finishWaiters(index, nil); return
setState(.scanning)
guard let lock = await acquireReaperLock() else { setState(.idle); finishWaiters(index, nil); return }
defer { lock.release() }
t0 = deps.clock.uptime()
detector = DeviceDetector(config: config.device, volumesRoot: deps.volumesRoot, inspector: deps.inspector, reader: deps.reader)
detection = (try? await BlockingIO.run { detector.detect() }) ?? DetectionResult(devices: [], skipped: [], listingError: ErrnoError(EIO))
if detection.listingError != nil:                                  // volumesRoot 自体を列挙できない = 観測できない。「0 台」として公開しない（DEL-32）
    setState(.idle); finishWaiters(index, nil); return               // 前回の snapshot を残す。scanNow() は nil
unavailable = [:]; notListableErrno = [:]
for s in detection.skipped: recordSkip(name: s.name, reason: s.reason, errno: s.listingError?.code, into: &unavailable, &notListableErrno)
observations = [:]; copiedTotal = 0
for device in detection.devices:                                   // 名前のバイト順
    if stopRequested: break
    mountPath = device.mountPath; remounted = false
    if config.device.mode == .ro:                                  // DeviceConfig.mode（T-09。不正な値は .ro）
        switch await deps.remounter.remountReadOnly(path: mountPath, node: device.node ?? ""):
        case .alreadyReadOnly: break
        case .remounted(let newPath):
            remounted = true; mountPath = newPath
            if URL(fileURLWithPath: newPath).lastPathComponent != device.deviceID
               || !DeviceDetector.nameMatchesVolume(device.deviceID, volumeName: deps.inspector.volumeName(path: newPath)):
                recordSkip(name: device.deviceID, reason: .mountNameMismatch, errno: nil, …); continue   // 規則 8 の再判定
        case .failed(let reason): log WARNING remount_failed name=<deviceID> reason=<reason>   // 取り込みは続ける（記録の保護）
    info = deps.inspector.mountInfo(path: mountPath)              // statfs は 1 回だけ。この値を判定にも観測にも使う
    isMountPoint = info.map { $0.mountOnName == SystemMountInspector.realPath(mountPath) }
                   ?? deps.inspector.isMountPoint(path: mountPath)   // statfs が取れなければ規則 4 の判定だけ（観測値は nil）
    if !isMountPoint:                                              // 再マウントの途中で外れた等。親の FS を観測しない（PLAN §8.1）
        log DEBUG volume_skipped name=<deviceID> reason=not_a_mount_point; continue
    readOnly = info?.readOnly                                      // 観測値。試行の成否から推論しない（DEL-31）
    if remounted && readOnly != true: log WARNING remount_failed name=<deviceID> reason=still_writable
    result = await ingestDevice(deviceID: device.deviceID, mountPath: mountPath, config: config)   // T-14
    copiedTotal += result.copied
    if !result.listing.complete:                                   // 一覧を信用しない（「消えた」と誤読させない）
        recordSkip(name: device.deviceID, reason: .notListable, errno: nil, …); continue
    observations[device.deviceID] = DeviceObservation(deviceID: device.deviceID, mountPath: mountPath,
        deviceNode: device.node, readOnly: readOnly, freeBytes: info?.freeBytes, relpaths: result.listing.relpaths)
if stopRequested: setState(.idle); finishWaiters(index, nil); return   // 途中で止めたら公開しない
publish(observations, unavailable, notListableErrno, copied: copiedTotal, elapsed: deps.clock.uptime() - t0)
finishWaiters(index, generation)
```

`recordSkip(name:reason:errno:into:)`:
- `reason.needsUserAction` なら `unavailable[name] = reason.rawValue`、`errno` があれば `notListableErrno[name] = errno`
- ログ `volume_skipped name=<name> reason=<reason>`（`errno` があれば `detail=<n>`。PLAN §8.1 規則 5 の「errno を detail に残す」に合わせる。付録 A.4 のフィールドに `errno` のキーは無いので `LogKey` に足さない）。レベルは `reason.needsUserAction && previousUnavailable[name] != reason.rawValue` なら WARNING、それ以外は DEBUG（**変化したときだけ WARNING**。毎回の走査で鳴らし続けない。OPS-12）

`acquireReaperLock()`:
```swift
for attempt in 1...Self.lockAttempts {
    if let lock = FileLock.tryAcquire(url: deps.layout.reaperLock) { return lock }
    if attempt == Self.lockAttempts || stopRequested { break }
    do { try await deps.sleeper.sleep(seconds: Self.lockRetrySeconds) } catch { break }
}
return nil
```
- 最大 130 回試し、試行の間に 1 秒待つ（待ちは最大 129 回）。取れなければこの回を見送る（`scanNow()` は nil）

`publish(…)`:
```text
generation += 1
previousEmpty = snapshot?.devices.isEmpty ?? true          // 前回が無いのは「0 台」と同じ扱い（voicedock の None と同じ）
if previousEmpty && !observations.isEmpty: connectEpoch += 1
snapshot = DeviceSnapshot(generation, completedAt: deps.clock.now(), connectEpoch, observations, unavailable, notListableErrno)
previousUnavailable = unavailable
log scan_completed devices=<observations.count> copied=<copied> elapsed_s=<秒 小数 1 桁>   // copied > 0 なら INFO、0 なら DEBUG
setState(.idle); notifyUpdate()
```
- `elapsed_s`: `Duration` を `Double(c.seconds) + Double(c.attoseconds) / 1e18` にし、`PyRound.round(x, digits: 1)`（T-45。Python の `round(x, 1)`。`(x * 10).rounded() / 10` は同点の丸めが違うので使わない。PLAN §5.7）
- **公開は走査の最後に 1 回だけ**。再マウントで起きた通知は `rescanRequested` にまとまるので、途中で 0 台の snapshot は作らない

`finishWaiters(upTo index:, _ generation: UInt64?)`: `minStart <= index` の待ち手に `generation` を返して取り除く

`setState(_:)`: 値が変わったときだけ `ingestState` を書き換えて `notifyUpdate()`

`activity()`: `IngestActivity(scanning: scanning, deviceID: progressDeviceID, copied: progressCopied, total: progressTotal, lastActivityAt: lastActivityAt)`

`updates()`:
```swift
let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
let id = UUID()
updateContinuations[id] = continuation
continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
return stream
```
`notifyUpdate()`: `for c in updateContinuations.values { c.yield(()) }`

T-14 の `copyOne` の 9 の後ろに `notifyUpdate()` を 1 行足す（コピーの進捗を UI と Worker に知らせる。Worker は登録された Part をコピーの完了を待たずに処理できる）

- **沈黙の判定**（PLAN §8.11。T-32 が使う）: `activity().scanning` が真か、`max(snapshot.completedAt, activity().lastActivityAt)` が `snapshotMaxAgeSeconds` 以内なら沈黙ではない

## 5. テスト

### 5.0 安全の約束（全テスト共通。必ず守る）

- **テストは `/Volumes` の実機に触れない。**利用者の DJI Mic 3 が `/Volumes/DJIMIC3`（`/dev/disk4`、msdos）にマウントされていることがある。テストが `/Volumes` 配下に対して diskutil（unmount / mount / 再マウント）・書き込み・削除を行うことを禁じる
- `IngestDependencies.volumesRoot` は**必ず一時ディレクトリ**（`<tmp>/Volumes`）。`Contract.volumesRoot` をテストで使わない
- ディスクイメージは T-07 の `DiskImageVolume` を使う。T-07 の規則どおり `/Volumes` の下には決して attach しない（`<tmp>/Volumes/<deviceID>` に `-mountpoint` で attach する）。`deviceID`（= ボリューム名）は実機と重ならない一意の名前（`DiskImageVolume.uniqueName()`。`"VDT" + 4 桁の英大文字・数字`。例 `VDT7F3A`）を渡す
- `.diskImage` のテストで `DiskutilRemounter` を使うときは**必ず `useMountPoint: true`**（`-mountPoint` を付けないと `diskutil mount readOnly` は `/Volumes` 配下にマウントする）
- `.diskImage` の各テストは最初に `try #require(!realpath(disk.mountPoint).hasPrefix("/Volumes/"))`（`disk.mountPoint.resolvingSymlinksInPath().path(percentEncoded: false)` で比べる）を置き、取り違えたら何もせずに止める
- 単体テストの再マウントは `FakeRemounter`、共存ガードは `ScriptedProcessRunner`。本物の diskutil・launchctl を動かすのは `.diskImage` のテストだけ

### 5.1 TestSupport

#### `FakeRemounter.swift`
```swift
/// Remounter の差し替え。呼ばれた (path, node) を記録し、台本の結果を返す。onRemount で呼ばれた瞬間の動き（通知を起こす等）を差し込める
public actor FakeRemounter: Remounter {
    public init(outcomes: [RemountOutcome], onRemount: (@Sendable () async -> Void)? = nil)   // 足りなければ最後の要素を返し続ける
    public func remountReadOnly(path: String, node: String) async -> RemountOutcome
    public var calls: [(path: String, node: String)] { get }
}
```
#### `FakeMountEventSource.swift`
```swift
public final class FakeMountEventSource: MountEventSource, Sendable {
    public init()
    public func events() -> AsyncStream<Void>
    public func send()   // 購読中の全ストリームへ () を流す（Mutex を使わず、内部の AsyncStream.Continuation を actor で持つ）
}
```
（実装は内部の小さな actor に Continuation の一覧を持たせ、`send` は `Task { await box.yield() }` で渡す）
#### `SuspendingSleeper.swift`
```swift
/// sleep はタスクが止められるまで戻らない（止められたら CancellationError）。周期の走査を止めておくテスト用
public struct SuspendingSleeper: Sleeper { public init(); public func sleep(seconds: Int) async throws }
```
#### `DiskImageVolume+Ingest.swift`（T-07 の `DiskImageVolume` への extension。`.diskImage` のテスト専用）

`DiskImageVolume` 本体（`init(in: TempDirectory, deviceID:filesystem:sizeMB:)`・`volumesRoot`・`mountPoint`・`deviceID`・`image`・`reattach(readOnly:)`・`detach()`。`<tmp>/Volumes/<deviceID>` に attach し、`/Volumes` の下には決して attach しない）は **T-07 が作る**（00-api-map §15）。本チケットは次だけを足す:
```swift
extension DiskImageVolume {
    /// 実機と重ならないボリューム名 "VDT" + 4 桁（A–Z・0–9 から SystemRandomNumberGenerator で選ぶ）
    public static func uniqueName() -> String
    /// SystemMountInspector().mountInfo(path: mountPoint の path)?.mountFromName（例 "/dev/disk7"）
    public var node: String? { get }
}
```
- 作り方の例: `let disk = try DiskImageVolume(in: tmp, deviceID: DiskImageVolume.uniqueName())`（FAT32・64 MB・書き込み可）。読み取り専用で attach し直すのは `try disk.reattach(readOnly: true)`

### 5.2 `RemounterTests.swift`（`@Suite("DiskutilRemounter")`。`ScriptedProcessRunner` と `FakeMountInspector`。本物の diskutil を動かさない）

path は `<tmp>/Volumes/DJIMIC3`、node は `/dev/disk99`（実在しない番号）。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `alreadyReadOnlyDoesNotUnmount` / 「既に ro なら diskutil を 1 度も呼ばない（DEL-31）」 | info の readOnly 真 | `.alreadyReadOnly`、`recorded == []` |
| `argvIsExact` / 「unmount と mount readOnly の argv・環境・タイムアウト」 | 結果 `[.exited(0), .exited(0)]`、`allMounts` に node の項目（mountOnName = path） | `.remounted(newPath: path)`、`recorded[0]` = `/usr/sbin/diskutil` `["unmount", path]`、`recorded[1]` = `["mount", "readOnly", "/dev/disk99"]`、環境 `ProcessEnvironment.cLocale`、タイムアウト 60 秒 |
| `mountPointArgv` / 「useMountPoint なら -mountPoint を付ける」 | useMountPoint 真 | `recorded[1] == ["mount", "readOnly", "-mountPoint", path, "/dev/disk99"]` |
| `missingNodeIsNoDeviceNode` / 「node が /dev/ で始まらなければ no_device_node（diskutil を呼ばない）」 | node `""` と `disk99` | `.failed(reason: "no_device_node")`、`recorded == []` |
| `unobservableMountIsNoDeviceNode` / 「statfs が取れなければ no_device_node」 | info なし | `.failed(reason: "no_device_node")` |
| `unmountFailure` / 「unmount の失敗は unmount_failed（mount を呼ばない）」 | `[.exited(1)]` | `.failed(reason: "unmount_failed")`、`recorded.count == 1` |
| `mountFailure` / 「mount の失敗は mount_failed」 | `[.exited(0), .exited(1)]` | `.failed(reason: "mount_failed")` |
| `timeoutIsFailure` / 「タイムアウトも失敗」 | `[.timedOut]` | `.failed(reason: "unmount_failed")` |
| `mountedButNotListed` / 「成功してもマウント一覧に無ければ mount_failed」 | `allMounts` が空 | `.failed(reason: "mount_failed")` |
| `changedPathIsReported` / 「再マウントでパスが変われば新しいパスを返す」 | `allMounts` の項目の mountOnName が `<tmp>/Volumes/DJIMIC3 1` | `.remounted(newPath: "<tmp>/Volumes/DJIMIC3 1")` |

### 5.3 `DeviceSnapshotTests.swift`（`@Suite("DeviceSnapshot")`）
| 関数名 / 表示名 | 期待 |
|---|---|
| `freshnessIncludesTheBoundary` / 「ちょうど maxAge は新鮮、1 ms 超は古い」 | completedAt t、now = t + 900_000 ms → 真、+900_001 → 偽 |
| `idleActivityIsZero` / 「IngestActivity.idle は走査していない・0 件」 | |
| `zeroDevicesIsNotUnknown` / 「0 台は devices が空で、readOnly の不明（nil）とは別の値で表す（DEL-32）」 | `devices.isEmpty` と、`DeviceObservation.readOnly == nil` の観測が別の型で表せる |

### 5.4 `IngestServiceTests.swift`（`@Suite("IngestService の走査", .serialized)`）

共通の準備: `<tmp>/Volumes` に `FakeVolume`（T-14 の既定の木。mtime は古い）、`FakeMountInspector.mounted([<tmp>/Volumes/DJIMIC3], readOnly: false)`（`infos` の `mountOnName` は本物の statfs と同じく realpath 側（`/var` → `/private/var`）に置き換える。走査はこの値を realpath と比べる）、
`FakeRemounter(outcomes: [.alreadyReadOnly])`、`CoexistenceGuard(runner: ScriptedProcessRunner(results: [.exited(113)]), uid: 501)`、`FakeMountEventSource()`、
`RecordingSleeper`、`FixedClock`、`Store`（一時ディレクトリ）、`configProvider` は既定の設定（`mountMode = "ro"`）を返す。`volumesRoot` は `<tmp>/Volumes`（5.0）。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `firstScanPublishesGenerationOne` / 「最初の走査で generation 1 の snapshot を公開する」 | `scanNow()` | 1、`snapshot.devices["DJIMIC3"]?.relpaths.count == 4`、inbox に 2 ファイル |
| `rwModeDoesNotRemount` / 「CE device.mountMode rw なら再マウントしない」 | `mountMode = "rw"`（既定の `ro` では `FakeRemounter.calls` が 1 件） | `FakeRemounter.calls` が空 |
| `readOnlyIsObservedNotInferredFromFailure` / 「再マウントが失敗しても観測が ro なら readOnly は真（DEL-31）」 | remounter `.failed("unmount_failed")`、inspector の readOnly 真 | `readOnly == true`、WARNING `remount_failed name=DJIMIC3 reason=unmount_failed` |
| `readOnlyIsObservedNotInferredFromSuccess` / 「再マウントが成功しても観測が rw なら偽で still_writable」 | remounter `.remounted(同じパス)`、readOnly 偽 | `readOnly == false`、WARNING `remount_failed name=DJIMIC3 reason=still_writable` |
| `rwModeStillObserves` / 「rw でも観測する」 | `mountMode = "rw"`、readOnly 真 | `readOnly == true` |
| `unobservableReadOnlyIsNil` / 「statfs が取れなければ readOnly は nil（偽にしない）」 | `infos` を空にし `mountPoints` だけ登録 | `readOnly == nil`、`freeBytes == nil` |
| `parentFileSystemIsNotObserved` / 「statfs の値がマウント点のものでなければ観測に載せない（親の FS を観測しない）」 | `mountPoints` は登録したまま、`infos[path]` の `mountOnName` を `/`（apfs・rw・空き 500 GB）にする（statfs の間に外れた状態） | generation 1、`devices == [:]`、`unavailable == [:]`、DEBUG `volume_skipped name=DJIMIC3 reason=not_a_mount_point`、inbox は空 |
| `remountFailureStillIngests` / 「再マウントに失敗しても取り込みは続ける（記録の保護）」 | `.failed("mount_failed")` | inbox に 2 ファイル |
| `zeroDevicesIsEmptyNotUnknown` / 「0 台なら devices が空（DEL-32）」 | `<tmp>/Volumes` を空 | generation 1、`devices == [:]`、`unavailable == [:]` |
| `emptyDeviceIsObserved` / 「録音 0 件のデバイスも空の観測として載せる（DEV-19）」 | フォルダだけ | `devices["DJIMIC3"]?.relpaths == []` |
| `connectEpochRisesOnZeroToSome` / 「connectEpoch は 0 台（か前回なし）→ 1 台以上のたびに +1」 | 走査ごとにボリュームを 在・在・無・在（無は FakeVolume を別名へ rename） | connectEpoch = `[1, 1, 1, 2]` |
| `connectEpochStartsAfterAnEmptyScan` / 「最初が 0 台なら上がらず、次に 1 台で上がる」 | 無・在 | `[0, 1]` |
| `skippedScanDoesNotChangeEpoch` / 「見送った走査は前回の観測を変えない」 | 在 → ロックを塞いで見送り → 在 | 2 回目の `scanNow()` は nil、connectEpoch は `[1, 1]`（2 回目は公開なし、3 回目も 1 のまま） |
| `noZeroDeviceSnapshotDuringRemount` / 「再マウント中の通知で途中の 0 台の snapshot を作らない」 | `FakeRemounter(onRemount: { events.send(); events.send() })`（アンマウントとマウントの 2 通知） を `start()` で購読させた状態で走査（周期は `SuspendingSleeper`） | 公開された snapshot はすべて `devices` が 1 台、再走査が 1 回だけ起きる（generation が 2 で止まる） |
| `scanNowWaitsForAScanStartedAfterTheCall` / 「走査中に呼んだ scanNow は次に始まる走査を待つ」 | 1 回目の走査を `FakeRemounter(onRemount:)` の中で止めておき、その間に `scanNow()` を呼んでから止めを外す | 1 回目の走査は generation 1、`scanNow()` の戻り値は 2 |
| `lockBusyMakesScanNowNil` / 「reaper.lock が取れなければ 130 回試して見送る」 | テストが `FileLock.tryAcquire(url: layout.reaperLock)` で持っておく | `scanNow() == nil`、sleeper の記録が `1` を 129 回、snapshot は nil、inbox は空 |
| `lockIsReleasedAfterScan` / 「走査が終わればロックを外す」 | `scanNow()` の後 | `FileLock.tryAcquire` が取れる |
| `coexistenceBlocksAndLogsOnce` / 「voicedock の Helper が登録されていれば何もしない。ログは入ったときだけ」 | runner の結果を `.exited(0)`、2 回 `scanNow()` | どちらも nil、`state() == .coexistenceBlocked`、`coexistence_blocked` は 1 行、inbox は空 |
| `configErrorDisables` / 「設定エラー中は走査しない」 | configProvider が nil | nil、`state() == .disabled` |
| `nameMismatchAfterRemountIsUnavailable` / 「再マウントでパスに ` 1` が付けば取り込まず mount_name_mismatch」 | remounter `.remounted("<tmp>/Volumes/DJIMIC3 1")` | `devices` に無い、`unavailable["DJIMIC3"] == "mount_name_mismatch"`、inbox は空 |
| `incompleteListingIsNotObserved` / 「列挙に失敗したサブディレクトリがあればそのデバイスを観測に載せない」 | 1 つのフォルダを `chmod 000` | `devices` に無い、`unavailable["DJIMIC3"] == "not_listable"` |
| `notListableCarriesErrno` / 「not_listable の errno を snapshot に残す」 | ボリュームのルートを `chmod 000` | `notListableErrno["DJIMIC3"] == EACCES` |
| `unavailableWarnsOnlyOnChange` / 「利用者の操作が要る理由は変わったときだけ WARNING」 | 上と同じ状態で 2 回走査 | 1 回目は WARNING `volume_skipped name=DJIMIC3 reason=not_listable detail=13`、2 回目は DEBUG だけ |
| `scanCompletedLevels` / 「scan_completed はコピーがあれば INFO、無ければ DEBUG」 | 2 回走査 | 1 回目 INFO `scan_completed devices=1 copied=2 elapsed_s=…`、2 回目 DEBUG `copied=0` |
| `activityTracksCopies` / 「進捗を IngestActivity に出す」 | 走査の後 | `copied == 2`、`total == 2`、`lastActivityAt == clock.now()`、`scanning == false` |
| `updatesYieldOnPublish` / 「公開のたびに updates に流れる」 | `updates()` を購読してから `scanNow()` | 1 つ以上受け取る |
| `ceScanIntervalSeconds` / 「CE device.scanIntervalSeconds が周期の待ちになる」 | `scanIntervalSeconds = 600`（snapshotMaxAge は 900 のまま）で `start()`、`RecordingSleeper` | 周期のループの sleep が `600`（既定の設定で同じことをすると `300`）。`stop()` で後始末 |
| `mountEventTriggersScan` / 「マウント通知で走査する」 | `start()`（周期は `SuspendingSleeper`）→ 最初の走査の後に `send()` | generation が 2 になる（`updates()` を待つ。5 秒で打ち切り） |
| `stopResolvesWaiters` / 「stop で待っている scanNow に nil を返す」 | 走査を止めておき `scanNow()` を待たせてから `stop()` | nil |
| `unlistableVolumesRootIsNotPublished` / 「volumesRoot 自体を列挙できなければ 0 台として公開しない（DEL-32）」 | 1 回目は通常、2 回目の前に `<tmp>/Volumes` を `chmod 000`（テスト後に 755 へ戻す） | 2 回目の `scanNow() == nil`、`latestSnapshot()` は 1 回目のまま（generation 1、`devices["DJIMIC3"]` が在る） |

- `noZeroDeviceSnapshotDuringRemount` の `onRemount` は**最初の 1 回だけ** `send()` を 2 回呼び、通知が走査に届くまで（300 ms）待ってから戻る。`send()` は `Task` で渡すので、待たないと走査が終わった後に届いて別の走査になる。2 回目以降の `onRemount` は何もしない（毎回送ると再走査が止まらない）。数えるのは `scan_completed` の行（2 行とも `devices=1`）
- `scanNowWaitsForAScanStartedAfterTheCall`・`stopResolvesWaiters` の「走査を止めておく」は、`onRemount` の中で開けるまで待つ門（テスト内の小さな actor）。2 本目の `scanNow()` が待ちに入ったことは `waiters.count == 2`（`@testable`）で確かめてから門を開ける／`stop()` する

### 5.5 `IngestServiceDiskImageTests.swift`（`@Suite("IngestService × FAT32 イメージ", .serialized, .enabled(if: TestEnvironment.diskTests))`、タグ `.diskImage`）

5.0 の約束を守る（T-07 の `DiskImageVolume(in: tmp, deviceID: DiskImageVolume.uniqueName())` で `<tmp>/Volumes/VDTxxxx` に attach、`useMountPoint: true`）。`volumesRoot` は `disk.volumesRoot`。`SystemMountInspector` と本物の `ProcessRunner` を使う。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `diskImageIsDetectedAndIngested` / 「本物の FAT をマウント点として検出し取り込む（realpath の比較）」 | イメージに BWF の `_orig` を 1 本置き（mtime を古くする）、`mountMode = "rw"` | `devices[<名前>]` が在り `readOnly == false`、inbox に 1 ファイル、`source_mtime` が FAT の 2 秒刻みの値 |
| `realRemountMakesItReadOnly` / 「本物の diskutil で読み取り専用に再マウントし、観測が真になる」 | `mountMode = "ro"`、`DiskutilRemounter(runner: ProcessRunner(), inspector: SystemMountInspector(), useMountPoint: true)` | `readOnly == true`、`statfs` の `MNT_RDONLY` が立つ、mountpoint は `<tmp>` の下のまま |
| `alreadyReadOnlyImageIsNotUnmounted` / 「読み取り専用で attach したイメージは再マウントしない」 | `disk.reattach(readOnly: true)`、runner は `ScriptedProcessRunner` | `.alreadyReadOnly`、`recorded == []` |

- `-mountPoint` を付けた再マウントで mountpoint のディレクトリが残るか（DiskArbitration が消すか）は P0-02・P0-10 で確かめ、結果に合わせてこのテストの準備（ディレクトリの作り直しの要否）を直す。直した内容を PR に書く
- P0-02 でディスクイメージ（/Volumes の外）は、アンマウント後もマウント点のディレクトリが残った（20/20。`docs/POC.md` 章 3）ので準備は変更していない。使用中の拒否（dissented）が実機で 20 回中 2 回あり、`realRemountMakesItReadOnly` が不安定になりうる

### 5.6 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`device.mountMode`・`device.scanIntervalSeconds` の 2 行を消す（CE テストは §5.4）。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `DiskutilRemounter` の「既に ro なら何もしない」を消す | `alreadyReadOnlyDoesNotUnmount` |
| snapshot の `readOnly` を再マウントの成否から決める（`.remounted` なら真） | `readOnlyIsObservedNotInferredFromSuccess` |
| `readOnly` の観測が取れないとき `false` を入れる | `unobservableReadOnlyIsNil` |
| 走査の中のマウント点の判定を `isMountPoint` と `mountInfo` の 2 回の statfs に戻す（判定に使った値と観測に使う値が別になる） | `parentFileSystemIsNotObserved` |
| `connectEpoch` を前回の snapshot を見ずに「今回 1 台以上なら +1」にする | `connectEpochRisesOnZeroToSome`（`[1, 2, 2, 3]` になる） |
| 走査中の `requestScan()` で新しい走査を並べて起こす（まとめない） | `noZeroDeviceSnapshotDuringRemount` |
| `scanNow()` の目標を `startedScans`（今の走査）にする | `scanNowWaitsForAScanStartedAfterTheCall` |
| `acquireReaperLock` を 1 回だけ試す | `lockBusyMakesScanNowNil`（sleeper の記録が 129 回にならない） |
| `listing.complete` を見ずに観測へ載せる | `incompleteListingIsNotObserved` |
| `detection.listingError` を見ずに公開する | `unlistableVolumesRootIsNotPublished` |
| 共存ガードのログを毎回出す | `coexistenceBlocksAndLogsOnce` |
| `recordSkip` で毎回 WARNING を出す | `unavailableWarnsOnlyOnChange` |

実施結果（コミット後の清潔な状態で 1 項目ずつ。11 項目とも表の「落ちるべきテスト」が落ちた）:
- 「既に ro なら何もしない」を消すと `info` が使われない警告がエラーになるので、`_ = info` を残して壊した
- `requestScan()` をまとめない壊し方では、`noZeroDeviceSnapshotDuringRemount` に加えて `scanNowWaitsForAScanStartedAfterTheCall`・`stopResolvesWaiters`・`ceScanIntervalSeconds` も落ちた（並んだ走査が reaper.lock を取り合う）
- `connectEpoch` を前回を見ずに上げる壊し方では、`skippedScanDoesNotChangeEpoch` も落ちた
- `.diskImage` の 3 本（§5.5）は `VOICEDOCK_DISK_TESTS` が要るので、実装者は回していない（利用者が実機を抜いて `make test-disk` で確かめる）

## 7. 受け入れ条件

- [ ] 走査の手順が PLAN §8.1 の 1〜5 の順（共存ガード → ロック → 判定 → 再マウント → 観測 → 取り込み → 公開 → ロックを外す）
- [ ] snapshot は走査の最後に 1 回だけ公開し、`readOnly` は statfs の観測値
- [ ] `scanNow()` は呼び出しの後に始まった走査の generation を返し、見送りなら nil
- [ ] actor の中で長い同期 I/O をしない（判定・走査・コピーは `BlockingIO`）
- [ ] テストは `/Volumes` の実機に触れない（5.0）。`volumesRoot` はテストで一時ディレクトリ
- [ ] 上記のテストがすべて緑（`.diskImage` は手元で `make test-disk` の結果を PR に貼る）、`make lint` が通る

## 8. SPEC の変更

- （PLAN v1.1 に反映済み。F-48）§8.1 の snapshot の定義に `notListableErrno: [String: Int32]` を足す（DR-11 の「EPERM のときだけ TCC の案内」に errno が要る）
- （PLAN v1.1 に反映済み。F-48）§8.1 の 1 回の走査の手順に「列挙に失敗したディレクトリがあったデバイスは `devices` に入れず `unavailable` に `not_listable`」「再マウント後にマウント点でなくなったデバイスは観測しない」を足す
- §8.1 に「`/Volumes` 自体を列挙できない走査は snapshot を公開しない（0 台と観測できないを混同しない。DEL-32）」を足す
- §8.1 に「テストは `/Volumes` の実機に触れない。`volumesRoot` は注入し、テストでは一時ディレクトリを使う。ディスクイメージは `/Volumes` 以外に attach し、再マウントは `-mountPoint` を付ける」を足す（§10.2 の `DiskImageVolume` の行にも）

## 9. マージ後にやること

- P0-02 で本番の `useMountPoint` は `false` に決まった（`docs/POC.md` 章 3・章 14）。T-30 の `Bootstrap.useMountPoint = false` のまま

## 10. API 地図への変更提案

1. `DiskutilRemounter.init` に `inspector: any MountInspector` を足す（`alreadyReadOnly` の判定と、再マウント後の新しいパスの探し直しに要る）。`diskutil` / `timeout` の公開定数を足す → `inspector` は 00-api-map に反映済み（2026-09-18）。`diskutil` / `timeout` の公開定数は地図に無い（地図への追記が要る）
2. `DeviceSnapshot` に `notListableErrno: [String: Int32]` と公開の初期化子を足し、`DeviceSnapshot`・`DeviceObservation`・`IngestActivity` を `Equatable` にする。`IngestActivity.idle` を足す → 00-api-map に反映済み（2026-09-18）
3. `MountEvent`・`MountEventSource`・`WorkspaceMountEventSource` を足し、`IngestDependencies` に `remounter` と `mountEvents` を足す（`volumesRoot` の後）→ 形を変えて 00-api-map に反映済み（2026-09-18）: `MountEventSource.events()` は `AsyncStream<Void>`（`MountEvent` は採用されず、本文から外した）、置き場所は `Remounter.swift`、`remounter`・`mountEvents` は `inspector` の後。**`WorkspaceMountEventSource`（`Bootstrap` が注入する本番の実装）は地図に無いので追記が要る**
4. `IngestService.updates()` が流す契機を「公開・状態の変化・1 本のコピー」と定める
5. `IngestState` の 4 値（`idle / scanning / coexistenceBlocked / disabled`）を確定する → 00-api-map に反映済み（2026-09-18。置き場所は `IngestService.swift`）
6. `DiskImageVolume` と `FakeVolume` は T-07 が作る（00-api-map §15）→ 本チケットの `DiskImageVolume` を外し、T-07 の型への extension（`uniqueName()`・`node`）だけにした。**00-api-map §15 か §16 に T-15 の extension（`DiskImageVolume.uniqueName()`・`node`）を追記する**（地図は本チケットでは編集しない）
