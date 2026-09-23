# T-36 VDPipeline: 削除条件（DeletionPolicy）・ロックの評価（LockEvaluator）・署名検証

> （F-76・issue #116。2026-09-23。マージ後の追記）`LockEvaluator` は、ProcessRunner が閉じた後（アプリの終了の途中）で reaper の `--version` を起動できなかった（`.spawnFailed(errno: ProcessRunner.closedErrno)`。`ReaperRunner.versionRun()` が `.notLaunched` を返す）ときは版を観測できなかったとして扱い、キャッシュせず `reaper_failed` も出さず、readiness を `.unconfirmed`（`DeletionReadiness` に足した値）にする（`.disabled(reaper_invalid)` にすると削除段が RAW_SAVED→COMPLETED を永続化するため）。`reaperStatus` は表示用に `.versionMismatch(found: nil)` を返す。テストは `Tests/VDPipelineTests/LockEvaluatorClosedRunnerTests.swift`。

| 項目 | 値 |
|---|---|
| ID | T-36 |
| Phase | 8（削除） |
| 前提 | T-29（Raw ノートの工程。`RawNote`・`NoteVerifier`・`VaultCheck` を工程が使う形）、T-07（`TargetIdentity`・`VolumeOpener`・`SystemVolumeOpener`・`FakeVolumeOpener`）、T-30（`Bootstrap` を差し替える）、T-32（`LockObserving`・`DisabledLockObserver`・`LockDisplay` に準拠する）。間接に T-10（`SafeUnlink`・`FixedClock`・`CapturingLogSink`）、T-11（`Store`）、T-12（`ProcessRunning`）、T-13（`ScriptedProcessRunner`）、T-15（`DeviceSnapshot`）、T-18（`WorkerDependencies`・`PipelineWorld`・`FakeIngest`）、T-26 / T-28（`Frontmatter`・`NoteVerifier`）、T-30（`Bootstrap`） |
| 見積もり | Sources 約 650 行、Tests 約 1,300 行（TestSupport の `DeletionScene` を含む） |
| 後続 | T-38（要求・削除段・回収）、T-39（根拠 B）、T-40（有効化と常時表示・DR-14）、T-41（後追い） |

## 1. 目的

PLAN §8.9.1 の削除の必要十分条件を**式の形のまま** Swift に写し（`DeletionPolicy`）、式の形そのものを PolicyTests で固定する（TEST-30）。
三重ロックの評価（設定上の準備 `DeletionReadiness` と、デバイスの観測 `DeviceWritability`）を `LockEvaluator` に 1 つだけ置き、reaper の署名と版の検証をキャッシュする。
層 A の ND（アプリが削除条件を偽にすること）を、三重ロックを全部外した舞台（`DeletionScene`）で 1 つずつ固定する。

## 2. 参照

- PLAN §8.9.1（式）、§8.9.2（三重ロック・readiness の順と理由語・writability）、§8.9.3（署名検証・版・`SecStaticCodeCheckValidity`）、§8.9.5（`preIdentityCheck`）、§8.9.8（常時表示の 3 行）、
  §8.7（`verifyRawNote` の期待値・`VaultCheck`）、§4.5〜§4.6（`TargetIdentity`・`VolumeHandle.readOnly`）、§2.1、§5.4（`TransitionConflict`）、§9.2（CR-09・CR-25）、§9.4（PT-11・PT-22）、§10.5（ND の書き方）、付録 A.4（reason 語）、付録 B.1（ND）、付録 B.2
- 00-api-map §11（`LockEvaluator.swift`・`SignatureVerifier.swift`・`DeletionPolicy.swift`・`ReaperRunner.swift`）、§15
- voicedock@d3d595e:
  - `src/voicedock/cleaner.py:101-136`（`can_delete_source`）、`:137-171`（`_deletion_is_identified`）、`:172-202`（`_text_is_preserved`）、`:203-227`（`_nothing_to_preserve`）、`:228-262`（`_skip_reason_is_backed`）、
    `:263-272`（`device_is_writable`）、`:273-284`（`_note_contains`）、`:285-331`（`verify_raw_note`）、`:332-350`（`part_transcript_is_valid`）、`:351-390`（`target_is_identical`）
  - `src/voicedock/pipeline.py:885-919`（`_twin_of`）
  - `tests/unit/test_no_delete.py:79-257`（Scene）、`:326-433`（正の対照・ND-01〜06）、`:444-600`（根拠 B）、`:696-842`（重複）、`:895-1000`（ND-07〜09・ND-32）、`:1005-1149`（Daily・兄弟は条件にしない）、`:1202-1357`（ND-21〜31・事前確認）、`:1366-1460`（式の形の固定）
- 移植メモ V3 §6.1、V1（reaper と署名）
- 実機の確認（このチケットを書く時点で macOS 26.6 / Xcode 27.0 / Swift 6.4 で確かめた事実。scratchpad の実験）:
  - Swift では `kSecCSCheckAllArchitectures` は `UInt32` の大域定数で、`SecCSFlags(rawValue: kSecCSCheckAllArchitectures)` と書く（`SecCSFlags` は `OptionSet`、4 バイト）。既定のフラグは `SecCSFlags()`
  - `/bin/ls` に要件 `anchor apple` → `SecStaticCodeCheckValidity` が `0`（errSecSuccess）。同じファイルに `anchor apple generic and identifier "x.reaper" and certificate leaf[subject.OU] = "ABCDE12345"` → `-67050`（errSecCSReqFailed）
  - 無いパス → `SecStaticCodeCreateWithPath` が `-67068`、署名の無いスクリプト → `SecStaticCodeCheckValidity` が `-67062`（errSecCSUnsigned）、壊れた要件文字列 → `SecRequirementCreateWithString` が `-67052`（errSecCSReqInvalid）
  - Swift 6 で `switch` の対象が `ErrorCode?` でも `case .noSpeechDetected:` と書ける（警告なし）。`Set<ErrorCode>.contains(where: { $0 == optional })` も警告なし

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/VDCore/AppIdentity.swift` | `AppIdentity`（BUNDLE_ID・TEAM_ID。identity.env と同じ値） |
| `Sources/VDPipeline/DeletionReason.swift` | `DeletionReason`（削除の経路のログの reason 語・後追いの対象外の語） |
| `Sources/VDPipeline/SignatureVerifier.swift` | `SignatureVerifier`・`CodeSignatureVerifier`・`ReaperSignature` |
| `Sources/VDPipeline/ReaperRunner.swift` | `ReaperRunner` の検証の部分（`installation`・`signatureIsValid`・`runVersion`・`versionMatches`）・`ReaperInstallation`・`ReaperFileKey`。**`run()` は T-38 が足す** |
| `Sources/VDPipeline/LockEvaluator.swift` | `LockEvaluator` だけ（T-18 は骨組みを置かない。ConfigStore は `observeReaperConf` のクロージャで受ける。§11 の提案 1）。**`DeletionReadiness`・`DeviceWritability`・`LockObservation`・`ReaperStatus`・`LockDisplay` は T-32 の `LockObserving.swift` に在る**（Phase 7 の診断が Phase 8 に依存しないため。T-32 §4.11）。ここで作り直さない |
| `Sources/VDPipeline/LockObserving.swift`（変更） | `DisabledLockObserver.disabledReason` を `DeletionReason.deleteSourceAudioDisabled` に替えるだけ（同じ語。CR-06）。型の定義は動かさない |
| `Sources/VDPipeline/DeletionPolicy.swift` | `DeletionCandidate`・`TwinPart`・`DeletionContext`・`RawNoteVerdict`・`DeletionPolicy` |
| `Sources/VDPipeline/WorkerDependencies.swift`（変更） | 末尾に `locks`・`volumeOpener` を足す |
| `Sources/VoiceDockApp/Bootstrap.swift`（変更） | `LockEvaluator` を作り、ConfigStore と WorkerDependencies に渡す |
| `Tests/TestSupport/FakeSignatureVerifier.swift` | 署名検証の偽物（00-api-map §15。作り手 T-36） |
| `Tests/TestSupport/ScriptedProcessRunner+Reaper.swift` | `ScriptedProcessRunner.version(_:)`（T-13 の型への extension） |
| `Tests/TestSupport/StorePaths.swift` | 遷移表の辺だけで Part / Session を任意の状態へ進める・`source_path` の直接書き換え |
| `Tests/TestSupport/DeletionScene.swift` | 三重ロックを全部外した削除評価の舞台（T-38・T-39・T-41 も使う） |
| `Tests/VDPipelineTests/PipelineFixtures.swift`（変更） | `PipelineWorld` に `locks` を持たせ、`deps` に `locks`・`volumeOpener` を渡す |
| `Tests/VDPipelineTests/LLMProbeCheckTests.swift`（変更） | `WorkerDependencies(…)` を直接作っている所の末尾に `locks: w.locks, volumeOpener: FakeVolumeOpener()` を足すだけ（§4.8 で init の引数が増えるため） |
| `Tests/VoiceDockAppTests/AppModelTests.swift`（変更） | `WorkerDependencies(…)` を直接作っている所の末尾に `locks: LockEvaluator(layout:, verifier: FakeSignatureVerifier(), runner: ScriptedProcessRunner(results: []), log:)`・`volumeOpener: FakeVolumeOpener()` を足すだけ（同上） |
| `Tests/NoDeleteTests/TargetMarker.swift`（削除） | T-01 の目印。このモジュールに最初の実ファイル（`DeletionPolicyNDTests.swift`）を足すので消す（STATUS「実装で分かった共通の約束」） |
| `Tests/NoDeleteTests/DeletionPolicyNDTests.swift` | 層 A の ND（§6.1） |
| `Tests/VDPipelineTests/DeletionPolicyTests.swift` | 項ごとの単体（§6.2） |
| `Tests/VDPipelineTests/DeletionSceneTests.swift` | 舞台そのもののテスト（TEST-05） |
| `Tests/VDPipelineTests/LockEvaluatorTests.swift` | |
| `Tests/VDPipelineTests/LockDisplayTests.swift` | `LockDisplay.lines`（型は T-32。本チケットは `ReaperStatus` の 4 値・`DeviceWritability` の 4 値の全組み合わせを固める） |
| `Tests/VDPipelineTests/SignatureVerifierTests.swift` | 本物の SecStaticCode |
| `Tests/VDPipelineTests/ReaperRunnerTests.swift` | 検証の部分（T-38 が `run()` の行を足す） |
| `Tests/VDCoreTests/AppIdentityTests.swift` | identity.env との一致 |
| `Tests/PolicyTests/DeletionFormulaTests.swift` | 式の形の固定（TEST-30） |

## 4. 仕様

共通: `p(url)` は `url.path(percentEncoded: false)`。鍵（partkey・session_key・relpath・request_id）の照合は**スカラー列の一致**（`PyText.scalarsEqual`。00-api-map §0）。
ログのキーは `LogKey`、値は `LogValue`。状態名・エラーコード名を文字列で書かない（PT-06）。`reaperConf`・`reaperExecutable` の語を書いてよいのは `LockEvaluator.swift`・`ReaperRunner.swift` だけ（PT-11。`LockObserving.swift` は許可場所ではないので、`LockDisplay` と `LockObservation` の欄の名前は `confState`。T-32 §4.11）。

### 4.1 `Sources/VDCore/AppIdentity.swift`

```swift
// アプリの識別子（PLAN §3.1）。値は identity.env と同じ（AppIdentityTests が照合する）。本番コードはここからだけ読む（環境変数を読まない。PT-18）。
public enum AppIdentity {
    /// identity.env の BUNDLE_ID（T-01 が P0 の章 14 から写した値をそのまま書く）
    public static let bundleID = "<identity.env の BUNDLE_ID>"
    /// identity.env の TEAM_ID（10 文字）
    public static let teamID = "<identity.env の TEAM_ID>"
    /// reaper の署名の識別子（PLAN §3.1「<BUNDLE_ID>.reaper」）
    public static var reaperIdentifier: String { bundleID + ".reaper" }
}
```

- 値は実装者が `identity.env` から写す（プレースホルダのまま PR を出さない。`AppIdentityTests` が落ちる）
- os.Logger の subsystem（T-30 の Bootstrap）もこの `bundleID` を使う（T-01 §マージ後の「渡し方は T-34 / T-36 で決める」をここで決めた）

### 4.2 `DeletionReason.swift`

```swift
// 削除の経路のログの reason 語と、後追いの対象外の語（PLAN 付録 A.4・§8.9.9）。逐語。ここ以外に書かない（CR-06）。
public enum DeletionReason {
    // source_delete_skipped session_key=… reason=…（readiness。§8.9.2 の判定順）
    public static let deleteSourceAudioDisabled = "delete_source_audio_disabled"
    public static let lockMismatch = "lock_mismatch"
    public static let mountModeRO = "mount_mode_ro"
    public static let reaperNotInstalled = "reaper_not_installed"
    public static let reaperInvalid = "reaper_invalid"
    // source_delete_skipped（観測・後追い・衝突）
    public static let deviceReadonly = "device_readonly"
    public static let alreadyAbsent = "already_absent"
    public static let statusChanged = "status_changed"
    // source_delete_pending recording_key=… reason=…（RV の理由語は IdentityReason）
    public static let stillInInventory = "still_in_inventory"
    public static let noResult = "no_result"
    public static let queueWriteFailed = "queue_write_failed"
    // disk_space_low session_key=… reason=…
    public static let stagingUnlinkFailed = "staging_unlink_failed"
    // reaper_failed reason=…
    public static let signature = "signature"
    public static let versionMismatch = "version_mismatch"
    public static let timeout = "timeout"
    /// "exit_<n>"（10 進）
    public static func exit(_ code: Int32) -> String { "exit_" + String(code) }
    // 後追いの対象外（BacklogPlan の reason。§8.9.9）。IdentityReason の同じ綴りの語とは別の語彙（意味が違う）
    public static let alreadyDeleted = "already_deleted"
    public static let notDeletable = "not_deletable"
    public static let deviceAbsent = "device_absent"
    public static let stillPresent = "still_present"
    // events.detail（§8.9.9 の手動で消した分）
    public static let resolveAbsentDetail = "resolve_absent"
}
```

### 4.3 `SignatureVerifier.swift`

```swift
// reaper の署名検証（PLAN §8.9.3 の 4）。テストは FakeSignatureVerifier を注入する（本番のコードに「テストなら」分岐を作らない。CR-25）。
import Foundation
import Security
import VDCore

public protocol SignatureVerifier: Sendable {
    /// url のコードの署名が要件を満たすか。検証できない（無い・署名が無い・要件が壊れている）ものは偽。
    func verify(url: URL) -> Bool
}

public struct CodeSignatureVerifier: SignatureVerifier {
    public let requirement: String
    public init(requirement: String) { self.requirement = requirement }
    public func verify(url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else {
            return false
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &compiled) == errSecSuccess,
            let compiled
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), compiled)
            == errSecSuccess
    }
}

public enum ReaperSignature {
    /// `anchor apple generic and identifier "<bundleID>.reaper" and certificate leaf[subject.OU] = "<teamID>"`（PLAN §8.9.3。定数はこの 1 つ）
    public static func requirement(bundleID: String, teamID: String) -> String {
        "anchor apple generic and identifier \"" + bundleID + ".reaper\" and certificate leaf[subject.OU] = \""
            + teamID + "\""
    }
    /// 本番の要件（AppIdentity から）。Bootstrap が CodeSignatureVerifier に渡す
    public static var production: String { requirement(bundleID: AppIdentity.bundleID, teamID: AppIdentity.teamID) }
}
```

- `SecCSFlags` の書き方は §2 の確認どおり。`kSecCSCheckAllArchitectures` を `Int` に変換しない
- 折り返しは `swift format` の 120 桁に合わせたもの（トークンは同じ）
- OSStatus の値は記録しない（検証の結果は真偽だけ。理由は `reaper_failed reason=signature` の 1 語）

### 4.4 `ReaperRunner.swift`（検証の部分。PT-11 の許可場所）

```swift
// <HOME>/bin/voicedock-reaper の検証と起動（PLAN §8.9.3・§8.9.6）。起動できる場所はここだけで、パスを引数に取らない。
// T-36 は検証の部分を書き、T-38 が run() を足す。
import Darwin
import Foundation
import VDContract
import VDProcess

public struct ReaperFileKey: Equatable, Sendable {
    public let inode: UInt64
    public let size: Int64
    public let mtimeSeconds: Int
    public let mtimeNanoseconds: Int
}

public enum ReaperInstallation: Equatable, Sendable {
    case absent                    // 無い・lstat が失敗・通常ファイルでない（symlink・ディレクトリを含む）
    case present(ReaperFileKey)
}

public struct ReaperRunner: Sendable {
    public static let versionTimeout: Duration = .seconds(10)
    let layout: HomeLayout
    let runner: any ProcessRunning
    let verifier: any SignatureVerifier

    public init(layout: HomeLayout, runner: any ProcessRunning, verifier: any SignatureVerifier)
    /// `lstat(p(layout.reaperExecutable))`。成功して S_IFREG なら .present(st_ino, st_size, st_mtimespec)、それ以外は .absent
    public func installation() -> ReaperInstallation
    /// `verifier.verify(url: layout.reaperExecutable)`
    public func signatureIsValid() -> Bool
    /// `voicedock-reaper --version` の stdout（ProcessResult.stdoutText のまま）。終了コード 0 でなければ nil。
    /// **署名の検証が済んだ後にだけ呼ぶ**（呼び手の責任。未検証のコードを実行しない。§8.9.3 の 5）
    public func runVersion() async -> String?
    /// `await runVersion() == AppVersion.string + "\n"`
    public func versionMatches() async -> Bool
}
```

`runVersion()`:
1. `spec = ProcessSpec(executable: layout.reaperExecutable, arguments: ["--version"], environment: ProcessEnvironment.standard)`
2. `result = await runner.run(spec, timeout: Self.versionTimeout)`
3. `result.termination == .exited(0)` なら `result.stdoutText`、それ以外（`exited(≠0)`・`signaled`・`timedOut`・`spawnFailed`）は nil

`installation()` の `ReaperFileKey`: `inode = UInt64(st.st_ino)`、`size = Int64(st.st_size)`、`mtimeSeconds = Int(st.st_mtimespec.tv_sec)`、`mtimeNanoseconds = Int(st.st_mtimespec.tv_nsec)`。

### 4.5 `LockEvaluator.swift`（PT-11 の許可場所）

`DeletionReadiness`・`DeviceWritability`・`LockObservation`・`ReaperStatus`・`LockDisplay` は **T-32 の `Sources/VDPipeline/LockObserving.swift`**（§4.11）に在る。
本チケットは **`LockEvaluator` だけ**を作り、T-32 の `LockObserving` に準拠させる（Bootstrap の `DisabledLockObserver` を差し替える。§4.9）。

```swift
// 三重ロックの評価（PLAN §8.9.2）。設定上の準備（待っても変わらない）とデバイスの観測（挿し直しで変わる）を分ける。
// 式はここに 1 つだけ置き、削除段・削除条件・常時表示・DR-14 が共有する（式を書き直さない）。
// DeletionReadiness / DeviceWritability / LockObservation / ReaperStatus / LockDisplay は LockObserving.swift（T-32）。
import Foundation
import VDContract
import VDCore
import VDDevice
import VDProcess

public actor LockEvaluator: LockObserving {
    /// 起動と検証の窓口（T-38 の runReaperIfNeeded もこれを使う。WorkerDependencies に reaper を別に持たない）
    public nonisolated let reaper: ReaperRunner
    private let layout: HomeLayout
    private let log: AppLog
    private var cache: CachedVerification?

    public init(layout: HomeLayout, verifier: any SignatureVerifier, runner: any ProcessRunning, log: AppLog)
    /// `ReaperConf.observe(at: layout.reaperConf)`（ConfigStore の observeReaperConf もこれ。§4.9）
    public func observeReaperConf() -> ReaperConfObservation
    public func readiness(config: AppConfig, useCache: Bool = true) async -> DeletionReadiness
    public func writability(deviceID: String, snapshot: DeviceSnapshot?) -> DeviceWritability
    public func allReleased(deviceID: String, config: AppConfig, snapshot: DeviceSnapshot?) async -> Bool
    // LockObserving の 2 つ（引数ラベルはプロトコルのとおり。既定引数つきの多重定義は準拠の証人にならない）
    public func observe(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockObservation
    public func reaperStatus() async -> ReaperStatus
    // キャッシュを使わない版（T-38 の起動直前と本チケットのテストが使う）
    public func observe(config: AppConfig, snapshot: DeviceSnapshot?, useCache: Bool) async -> LockObservation
    public func reaperStatus(useCache: Bool) async -> ReaperStatus
    // display(config:snapshot:) は LockObserving の既定実装（T-32 §4.11）。ここに書かない
}

private struct CachedVerification: Equatable, Sendable {
    let key: ReaperFileKey
    let signatureValid: Bool
    let stdout: String?        // 署名が不正なら実行しないので nil
}
```

`observe(config:snapshot:)` = `await observe(config: config, snapshot: snapshot, useCache: true)`、`reaperStatus()` = `await reaperStatus(useCache: true)`（プロトコルの証人はこの 2 つ。呼び分けは Swift の多重定義の解決で既定引数の無い側が選ばれる）。

`init`: `reaper = ReaperRunner(layout: layout, runner: runner, verifier: verifier)`、`cache = nil`。**init は検証しない**（キャッシュは空で始まる）。

**`readiness(config:useCache:)`**（PLAN §8.9.2 の 1。**この順に**評価し、最初に当たった語を返す。先の段で決まったら後の段の子プロセス・署名検証をしない）:
1. `config.cleanup.deleteSourceAudio == false` → `.disabled(DeletionReason.deleteSourceAudioDisabled)`
2. `observeReaperConf()` が `.valid(conf)` で `conf.deleteSourceAudio == true` でなければ（`.missing`・`.invalid`・`false`）→ `.disabled(DeletionReason.lockMismatch)`
3. `config.device.mode == .ro`（不正な値も `.ro`。T-09）→ `.disabled(DeletionReason.mountModeRO)`
4. `switch await reaperStatus(useCache: useCache)`: `.notInstalled` → `.disabled(DeletionReason.reaperNotInstalled)`、`.signatureInvalid`・`.versionMismatch` → `.disabled(DeletionReason.reaperInvalid)`、`.valid` → `.configured`

**`reaperStatus(useCache:)`**（署名と版のキャッシュ。PLAN §8.9.2「(inode, size, mtime) が変わらない限りキャッシュ」）:
1. `switch reaper.installation()`: `.absent` → `cache = nil`、`.notInstalled` を返す
2. `.present(key)`: `useCache` が真で `cache?.key == key` なら `status(from: cache)` を返す（子プロセスも署名検証もしない）
3. `signatureValid = reaper.signatureIsValid()`。`stdout = signatureValid ? await reaper.runVersion() : nil`（**署名の後に版**。未検証のコードを実行しない）
4. `entry = CachedVerification(key: key, signatureValid: signatureValid, stdout: stdout)`、`cache = entry`
5. ログ（**検証したときだけ**。キャッシュを返したときは出さない）: `!signatureValid` → `log.warning(.reaperFailed, [(.reason, .string(DeletionReason.signature))])`、
   そうでなく `stdout != AppVersion.string + "\n"` → `log.warning(.reaperFailed, [(.reason, .string(DeletionReason.versionMismatch))])`
6. `status(from: entry)` を返す

`status(from:)`: `!signatureValid` → `.signatureInvalid`。`stdout == AppVersion.string + "\n"` → `.valid(version: AppVersion.string)`。それ以外 → `.versionMismatch(found: stdout.map(dropOneTrailingNewline))`（`dropOneTrailingNewline` は末尾が `"\n"` なら 1 つだけ除く）。

- actor の再入: 手順 3 の `await` の間に別の呼び出しが同じ検証をしてもよい（結果は同じ。キャッシュは最後の書き込みが残る）。キャッシュの鍵は検証の**前**に読んだ値で、検証中にファイルが替わっても次の呼び出しで鍵が一致せず検証し直す

`writability(deviceID:snapshot:)` = `DeviceWritability.observe(deviceID:snapshot:)`。

`allReleased(deviceID:config:snapshot:)` = `await observe(config: config, snapshot: snapshot).allReleased(for: deviceID)`。

**`observe(config:snapshot:useCache:)`**:
1. `readiness = await readiness(config: config, useCache: useCache)`
2. `let observed = observeReaperConf()`。`volumesRoot`: `observed` が `.valid(c)` なら `c.volumesRoot`、それ以外は nil
3. `confState`: `observed` が `.missing` → `.missing`、`.invalid` → `.invalid`、`.valid(c)` → `c.deleteSourceAudio ? .enabled : .disabled`（表示の 1 行目。T-32 §4.11）
4. `LockObservation(readiness: readiness, snapshot: snapshot, volumesRoot: volumesRoot, confState: confState)`

**`display(config:snapshot:)`** は `LockObserving` の既定実装（T-32 §4.11）をそのまま使う。**本チケットは上書きしない**
（`observe` が `readiness`・`confState`・`devices` を、`reaperStatus()` が 2 行目を埋める。式を 2 か所に書かない）。

### 4.6 `LockDisplay`（T-32 §4.11。本チケットでは作らない）

`LockDisplay`（`ConfState`・`Device`・`appEnabled`・`confState`・`reaper`・`mountMode`・`devices`・`readiness`・`lines` の 3 行の逐語）は
**T-32 の `LockObserving.swift`** に在る。本チケットはそれを埋める値（`ReaperStatus` の 4 値・`DeviceWritability` の 4 値・`ConfState` の 4 値）を本物にするだけで、
`lines` の文言も式も書き直さない（§6.5 でその全組み合わせを固める）。表示の 1 行目の欄の名前が `reaperConf` ではなく `confState` なのは PT-11（`LockObserving.swift` は許可場所ではない）。

### 4.7 `DeletionPolicy.swift`

```swift
// 元音声の削除の必要十分条件（PLAN §8.9.1。式の形を変えない）とアプリ側の事前確認（§8.9.5）。
// 式の 5 つの関数の本体は DeletionFormulaTests（PolicyTests）がトークン単位で固定している。変えるなら PLAN を先に直す（TEST-30）。
import Foundation
import VDContract
import VDCore
import VDDevice
import VDNotes
import VDStore

/// 評価する 1 件。parts は Session の全 Part（Store.recordings(inSession:) の順）。
public struct DeletionCandidate: Sendable {
    public let part: RecordingRow
    public let session: SessionRow
    public let parts: [RecordingRow]
    /// 重複（DUPLICATE_CONTENT）の双子。根拠 B の重複だけが使う
    public let twin: TwinPart?
    public init(part: RecordingRow, session: SessionRow, parts: [RecordingRow], twin: TwinPart?)
    /// DB から組み立てる。Part が無い・session_key が nil・Session が無い → nil。twin は TwinPart.load
    public static func load(partkey: String, store: Store) throws -> DeletionCandidate?
}

/// 双子（先に正規化された同じ内容の Part）。session と parts は**双子の側**のもの（重複と双子は別の日でありうる）。
public struct TwinPart: Sendable {
    public let part: RecordingRow
    public let session: SessionRow
    public let parts: [RecordingRow]
    public init(part: RecordingRow, session: SessionRow, parts: [RecordingRow])
    /// 双子の引き方（voicedock pipeline.py:885-919 の _twin_of）: duplicate_of → その Part → その session_key → その Session → その Session の全 Part。どれかが欠ければ nil
    public static func load(for part: RecordingRow, store: Store) throws -> TwinPart?
}

public struct DeletionContext: Sendable {
    public let config: AppConfig
    public let locks: LockObservation
    public let layout: HomeLayout
    /// 事前確認のボリュームを開く（本番 SystemVolumeOpener。テスト FakeVolumeOpener。PLAN §4.6）
    public let volumeOpener: any VolumeOpener
    public init(config: AppConfig, locks: LockObservation, layout: HomeLayout, volumeOpener: any VolumeOpener)
    public var snapshot: DeviceSnapshot? { locks.snapshot }
    /// config.vault.path の URL（未設定なら nil）
    public var vaultRoot: URL? { config.vault.path.map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

public enum RawNoteVerdict: Equatable, Sendable {
    case passed
    case notRecorded            // raw_output_path か raw_output_sha256 が NULL
    case vaultUnavailable       // VaultCheck が .available でない（空の Vault に騙されない。DEL-06 / ND-36）
    case failed([String])       // 落ちた規則（NoteVerification.failedRules。"RN-1" …）
}

public enum DeletionPolicy {
    public static func canDeleteSource(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool
    public static func deletionIsIdentified(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool
    public static func textIsPreserved(_ part: RecordingRow, _ session: SessionRow, _ parts: [RecordingRow], _ ctx: DeletionContext) -> Bool
    public static func nothingToPreserve(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool
    public static func skipReasonIsBacked(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool
    public static func preIdentityCheck(_ part: RecordingRow, _ ctx: DeletionContext) -> Bool
    public static func verifyRawNote(_ session: SessionRow, _ parts: [RecordingRow], _ ctx: DeletionContext) -> RawNoteVerdict
    public static func frontmatterKeys(_ rawOutputPath: String?, _ ctx: DeletionContext) -> [String]
    public static func partTranscriptIsValid(_ part: RecordingRow, _ ctx: DeletionContext) -> Bool
    /// 鍵の照合（スカラー列の一致。00-api-map §0）。どちらかが nil なら偽
    static func sameKey(_ a: String?, _ b: String?) -> Bool
}
```

#### 4.7.1 式の 5 つの関数（**本体はこの通りに書く**。空白・改行・コメントは自由。トークンの並びを DeletionFormulaTests が固定する）

```swift
    /// 共通の同定 AND（根拠 A OR 根拠 B）。|| を共通項の外へ出してはならない（出すと根拠 B がロックも番犬も通らずに真になる）。
    public static func canDeleteSource(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool {
        deletionIsIdentified(c, ctx)
            && (textIsPreserved(c.part, c.session, c.parts, ctx) || nothingToPreserve(c, ctx))
    }

    /// ロック・番犬・対象の同定。根拠 A と B の両方が必ず通る共通項。
    public static func deletionIsIdentified(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool {
        ctx.locks.allReleased(for: c.part.deviceID)
            && sameKey(c.part.sessionKey, c.session.sessionKey)
            && c.parts.count >= 1                         // 番犬: 空集合で真にしない（DEL-03 / CR-09）
            && c.part.sourcePath != nil
            && c.part.sourcePath?.isEmpty == false        // 番犬: "" はボリュームのルートを指す
            && preIdentityCheck(c.part, ctx)
    }

    /// 根拠 A: テキストが 2 か所に在る（Vault の Raw ノートと transcripts/parts/）。DB の status を信用しない（PR-12）。
    public static func textIsPreserved(
        _ part: RecordingRow, _ session: SessionRow, _ parts: [RecordingRow], _ ctx: DeletionContext
    ) -> Bool {
        session.rawOutputPath != nil
            && verifyRawNote(session, parts, ctx) == .passed
            && frontmatterKeys(session.rawOutputPath, ctx).contains(where: { sameKey($0, part.partkey) })
            && PartStates.deletable.contains(part.status)
            && part.transcriptPath != nil
            && partTranscriptIsValid(part, ctx)
    }

    /// 根拠 B: 保全すべき本文が無い（SKIPPED のまま。遷移させない。SM-20）。
    public static func nothingToPreserve(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool {
        ctx.config.cleanup.deleteSkippedSource == true
            && c.part.status == .skipped
            && SkipReasons.deletable.contains(where: { $0 == c.part.errorCode })
            && skipReasonIsBacked(c, ctx)
    }

    /// 理由ごとの「本文が無い」根拠。表に無い理由は消さない側（SOURCE_MISSING も）。双子には同定を要求しない。
    public static func skipReasonIsBacked(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool {
        switch c.part.errorCode {
        case .noSpeechDetected:
            return partTranscriptIsValid(c.part, ctx)
        case .duplicateContent:
            guard let twinKey = c.part.duplicateOf, let twin = c.twin, sameKey(twin.part.partkey, twinKey),
                !sameKey(twin.part.partkey, c.part.partkey), sameKey(twin.part.sessionKey, twin.session.sessionKey)
            else { return false }
            return textIsPreserved(twin.part, twin.session, twin.parts, ctx)
        default:
            return false
        }
    }
```

- PLAN の `part.sourcePath != ""` は `c.part.sourcePath?.isEmpty == false` と書く（意味は同じ。文字列リテラルは PolicyTests の字句解析でコードから消えるので、トークンで固定できる形にした）
- PLAN の `part.sessionKey == session.sessionKey` / `twin.part.partkey == twinKey` などの鍵の比較は `sameKey`（スカラー列の一致）
- `verifyRawNote(…) == .passed` は PLAN の形のまま（戻り値を bool にしない。理由を診断に出せる）

#### 4.7.2 項の関数

**`sameKey(a, b)`**: `guard let a, let b else { return false }; return PyText.scalarsEqual(a, b)`。

**`preIdentityCheck(part, ctx)`**（PLAN §8.9.5。voicedock cleaner.py:351-390 ＋ 実ファイルへの検証。**この順**。安いものを先に、デバイスに触れるのは最後）:
1. `guard let relpath = part.sourcePath, !relpath.isEmpty` でなければ偽
2. `RelPath.isSafe(relpath)` でなければ偽
3. `(try? PartKey.make(deviceID: part.deviceID, relpath: relpath))` が nil か `!sameKey(made, part.partkey)` なら偽（鍵と実際に消すパスが一致すること。RV-05 と同じ）
4. `ctx.snapshot?.devices[part.deviceID]` が nil、またはその `relpaths` に `sameKey($0, relpath)` のものが無ければ偽（いま在ること。DEL-20 の新鮮さは呼び手が確かめる）
5. `part.sourceSize` か `part.sourceMtime` が nil なら偽
6. `ctx.locks.volumesRoot` が nil なら偽
7. `ctx.volumeOpener.open(volumesRoot: volumesRoot, deviceID: part.deviceID)` が `.opened(volume)` でなければ偽（`.absent`・`.rejected`）
8. `volume.readOnly == false` でなければ偽（snapshot の観測に加えて同じ fd の fstatfs でも確かめる二重確認。PLAN §4.6）
9. `TargetIdentity.withVerifiedTarget(volume: volume, relpath: relpath, expectedSize: size, expectedMtime: mtime) { _ in () }` が `.success` なら真、`.failure` なら偽（body では何もしない。reaper は unlink の直前に同じ検証を独立にやり直す。DEL-26）

- `volume`（`VolumeHandle`）は関数を抜けると解放され fd が閉じる。関数の外へ持ち出さない
- `size` / `mtime` は **DB の値**（デバイス上の原本の値。DEL-12）。inbox のコピーを stat しない

**`verifyRawNote(session, parts, ctx)`**（PLAN §8.7 の期待値。書き込み直後の検証と同じ `NoteVerifier.verify` を呼ぶ）:
1. `guard let relative = session.rawOutputPath, let sha = session.rawOutputSHA256 else { return .notRecorded }`
2. `VaultCheck.evaluate(path: ctx.config.vault.path, marker: ctx.config.vault.marker).isAvailable` が偽、または `ctx.vaultRoot` が nil → `.vaultUnavailable`
3. `expected = Set(parts.filter { RawNoteMembership.isMember(status: $0.status, transcriptReadable: partTranscriptIsValid($0, ctx)) }.map(\.partkey))`（**書き手と同じ関数**で Part 集合を作る。§9.1 原則 2）
4. `v = NoteVerifier.verify(url: vault.appendingPathComponent(relative, isDirectory: false), kind: .raw, sessionKey: session.sessionKey, expectedSHA256: sha, expectedKeys: expected, summaryHeading: "")`（`summaryHeading` は Raw では使われない）
5. `v.passed` なら `.passed`、そうでなければ `.failed(v.failedRules)`

**`frontmatterKeys(rawOutputPath, ctx)`**（voicedock notes.py:194-211）: `rawOutputPath` か `ctx.vaultRoot` が nil → `[]`。そうでなければ `Frontmatter.recordingKeys(ofFile: vault.appendingPathComponent(rawOutputPath, isDirectory: false))`（読めない・UTF-8 でない・frontmatter が無い・配列でない → `[]`。要素は文字列化。T-26）。

**`partTranscriptIsValid(part, ctx)`**（実ファイルだけを根拠にする。`transcript_path` 列を見ない。voicedock cleaner.py:332-350）:
`url = ctx.layout.transcript(slug: KeySlug.of(part.partkey))`、`guard let data = try? Data(contentsOf: url) else { return false }`、`return PartTranscriptCodec.decode(data) != nil`（§8.4 の合格条件。T-10）。

**`DeletionCandidate.load(partkey:store:)`**:
1. `guard let part = try store.recording(partkey), let key = part.sessionKey, let session = try store.session(key) else { return nil }`
2. `parts = try store.recordings(inSession: key)`、`twin = try TwinPart.load(for: part, store: store)`
3. `DeletionCandidate(part: part, session: session, parts: parts, twin: twin)`

**`TwinPart.load(for:store:)`**: `guard let twinKey = part.duplicateOf, let twinRow = try store.recording(twinKey), let key = twinRow.sessionKey, let session = try store.session(key) else { return nil }` →
`TwinPart(part: twinRow, session: session, parts: try store.recordings(inSession: key))`。
（`duplicate_of` が指す Part が自分自身でも引く。弾くのは `skipReasonIsBacked` の番犬）

- 要約（Daily ノート・解析）の成否は**条件にしない**。評価は Part ごと（DEL-04）。兄弟の Part の進み具合は条件にしない（`expected` に入るのは Raw に載る Part だけ）
- DeletionPolicy は DB を書かない・ログを出さない（判定だけ）

### 4.8 `WorkerDependencies.swift`（変更）

末尾（既に在るフィールドの後）に 2 つ足す。init の引数も同じ順で末尾に足す。
**末尾に足す順は 00-api-map §11 の `WorkerDependencies` の行が正**: T-18 の並び → 本チケットの `locks`・`volumeOpener`（この 2 つが最後。T-33 の `importedKeys` は取り下げ。PLAN F-60）。
T-18 の並びの直後に足す:
```swift
    /// 三重ロックの評価と reaper の検証・起動（T-36。reaper は locks.reaper。別のフィールドに持たない）
    public let locks: LockEvaluator
    /// 事前確認のボリュームを開く（本番 SystemVolumeOpener）
    public let volumeOpener: any VolumeOpener
```

### 4.9 `Bootstrap.swift`（T-30 のファイルの変更）

T-30（Phase 7）の Bootstrap は本チケットの型を 1 つも使わない形で書いてある（T-30 §4.2 の手順。T-32 §4.10 が `DisabledLockObserver` を入れる）。本チケットが**差し替える**:

1. 手順 6 の `let locks: any LockObserving = DisabledLockObserver()`（T-32 §4.10）を
   `let locks = LockEvaluator(layout: layout, verifier: CodeSignatureVerifier(requirement: ReaperSignature.production), runner: runner, log: log.withCategory("pipeline"))` に替える
   （`DiagnosticsDependencies` と `AppContext.locks` は `any LockObserving` を取るので、ここ 1 行の差し替えで両方が本物になる）
2. ConfigStore の `observeReaperConf: { .missing }` を `observeReaperConf: { await locks.observeReaperConf() }` に替える（T-18 §10）
3. `WorkerDependencies(…)` の末尾に `locks: locks, volumeOpener: SystemVolumeOpener()` を足す（T-30・T-32 はこの 2 つを渡していない。§4.8 の並び。T-18 の並びの後ろ）
4. `SystemVolumeOpener` は T-07 が `VDContract/TargetIdentity.swift` に作ってある（`VolumeOpener` の本番実装。T-38 も使う）。T-30 は使わない
- os.Logger の subsystem が文字列で書かれていれば `AppIdentity.bundleID` に替える

### 4.10 TestSupport

#### `FakeSignatureVerifier.swift`

```swift
// 署名検証の偽物（PLAN §10.2。作り手 T-36）。呼ばれた URL を記録し、setValid の値を返す。
import Foundation
import Synchronization
import VDPipeline

public final class FakeSignatureVerifier: SignatureVerifier {
    private let state: Mutex<(valid: Bool, urls: [URL])>
    public init(valid: Bool = true)
    public func setValid(_ valid: Bool)
    public func verify(url: URL) -> Bool          // urls に足し、valid を返す
    public var verifiedURLs: [URL] { get }
}
```

#### `ScriptedProcessRunner+Reaper.swift`

```swift
// reaper の --version の結果（T-13 の ScriptedProcessRunner への extension。作り手 T-36）。
import Foundation
import VDContract
import VDProcess

extension ScriptedProcessRunner {
    /// 終了コード 0、stdout = output（既定は AppVersion.string + "\n"）、stderr は空
    public static func version(_ output: String = AppVersion.string + "\n") -> ProcessResult {
        ProcessResult(termination: .exited(0), stdoutTail: Data(output.utf8), stderrTail: Data())
    }
}
```

#### `StorePaths.swift`

```swift
// テストの行を遷移表の辺だけで任意の状態へ進める（SQL で status を書かない。PT-05 の趣旨）。作り手 T-36。
import Foundation
import GRDB
import VDCore
@testable import VDStore

public struct StorePathError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String)   // TestSupport の中だけで投げる（公開しない）
}

public enum StorePaths {
    /// DISCOVERED から status までの経路（最初の DISCOVERED を含まない）
    public static func partPath(to status: PartStatus, errorCode: ErrorCode?) -> [PartStatus]
    /// OPEN から status までの経路（最初の OPEN を含まない）
    public static func sessionPath(to status: SessionStatus) -> [SessionStatus]
    /// 今の状態から経路に沿って status まで。今の状態が経路に無ければ StorePathError。最後の辺にだけ errorCode を渡す
    public static func advancePart(_ store: Store, partkey: String, to status: PartStatus, errorCode: ErrorCode? = nil) throws
    public static func advanceSession(_ store: Store, sessionKey: String, to status: SessionStatus) throws
    /// source_path を直接書き換える（RecordingField に無い列。ND-21 の nil と "" を作るためだけ）
    public static func setSourcePath(_ store: Store, partkey: String, _ value: String?) throws
}
```

経路（`partPath`）:

| status | 経路 |
|---|---|
| discovered | `[]` |
| normalizing / normalized / transcribing / transcribed / rawWriting / rawSaved | `[normalizing, normalized, transcribing, transcribed, rawWriting, rawSaved]` をその状態までで切ったもの |
| sourceDeleting | `[…, rawSaved, sourceDeleting]` |
| sourceDeletePending | `[…, rawSaved, sourceDeleting, sourceDeletePending]` |
| completed | `[…, rawSaved, completed]` |
| failed | `[normalizing, normalized, transcribing, failed]` |
| skipped | errorCode が `.sourceMissing` → `[skipped]`、`.duplicateContent` → `[normalizing, skipped]`、それ以外（nil を含む）→ `[normalizing, normalized, transcribing, skipped]` |

`sessionPath`: `open` → `[]`、`ready`〜`saved` は `[ready, merging, merged, analyzing, analyzed, writing, saved]` を切ったもの、`sourceDeleting` → `[…saved, sourceDeleting]`、`sourceDeletePending` → `[…saved, sourceDeleting, sourceDeletePending]`、
`cleanup` → `[…saved, cleanup]`、`completed` → `[…saved, cleanup, completed]`、`failed` → `[ready, merging, failed]`。

`advancePart`: `row = try store.recording(partkey)`（無ければ `StorePathError`）。`path = partPath(to:errorCode:)`。`row.status == .discovered` なら開始位置 0、そうでなければ `path.firstIndex(of: row.status)! + 1`（無ければ `StorePathError("\(row.status) から \(status) への経路が無い")`。`!` は使わず `guard let`）。
残りの各 `s` について `try store.recordPartTransition(partkey:, from: 直前の状態, to: s, errorCode: s が最後なら errorCode、それ以外 nil)`。Session も同じ（errorCode なし）。

`setSourcePath`: `try store.pool.write { try $0.execute(sql: "UPDATE recordings SET source_path = ? WHERE partkey = ?", arguments: [value, partkey]) }`（`@testable`。PT-05 は `Sources/` だけが対象）。

#### `DeletionScene.swift`（作り手 T-36。T-38・T-39・T-41 が使う）

```swift
// 削除の評価の舞台（PLAN §10.5）: 三重ロックを全部外し、Part 1 件を与えた状態の Session。ND と正の対照と削除フローのテストが共有する。
import Darwin
import Foundation
import Synchronization
import VDContract
import VDCore
import VDDevice
import VDNotes
import VDPipeline
import VDProcess
import VDStore

public final class DeletionScene: Sendable {
    // static の鍵は偽のボリューム（FakeVolumeOpener）の既定。ディスクイメージは DJIMIC3 を名乗れない（PLAN §10.2）ので、
    // Part を指すときはインスタンスの deviceID / partkey / sessionKey を使う
    public static let deviceID = "DJIMIC3"
    public static let folder = "TX_MIC001_20260912_090000"
    public static let fileName = "TX00_MIC001_20260912_090000_orig.wav"
    public static let relpath = "TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    public static let partkey = "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    public static let sessionKey = "DJIMIC3:20260912"
    public static let dayDate = "2026-09-12"
    public static let startedAt = "2026-09-12T09:00:00+09:00"
    /// 2026-09-12T09:01:00+09:00。偶数秒（FAT の 2 秒分解能でも変わらない）
    public static let sourceMtime: Double = 1_789_171_260
    /// FakeVolume.standardContent と同じ（b"x" × 4096）
    public static let content = Data(repeating: 0x78, count: 4096)
    /// 2026-09-12T12:00:00+09:00
    public static let now = Instant(epochMillis: 1_789_182_000_000)
    public static let transcriptText = "おはようございます。"

    public let deviceID: String            // diskImage?.deviceID ?? DeletionScene.deviceID
    public let partkey: String             // PartKey.make(deviceID:, relpath: DeletionScene.relpath)
    public let sessionKey: String          // SessionKey.make(deviceID:, dayStamp: "20260912")
    public let tmp: TempDirectory
    public let layout: HomeLayout          // <tmp>/home（createDirectories 済み。bin も作る）
    public let vault: URL                  // <tmp>/vault（.obsidian を持つ）
    public let volumesRoot: URL            // <tmp>/Volumes、またはディスクイメージの volumesRoot
    public let deviceRoot: URL             // diskImage?.mountPoint ?? <volumesRoot>/DJIMIC3
    public let store: Store                // layout.database
    public let clock: FixedClock           // now
    public let zone: ZonedTime             // Asia/Tokyo
    public let sink: CapturingLogSink
    public let log: AppLog                 // DEBUG、unsafeContent false
    public let verifier: FakeSignatureVerifier
    public let runner: ScriptedProcessRunner
    public let locks: LockEvaluator
    public let opener: any VolumeOpener    // ディスクイメージなら SystemVolumeOpener、それ以外 FakeVolumeOpener()

    /// 既定: Part を RAW_SAVED、Session を SAVED まで進め、Raw ノートと transcript を置き、三重ロックを全部外す。
    /// readiness は評価しない（署名と版のキャッシュは空で始まる）。
    public init(status: PartStatus = .rawSaved, errorCode: ErrorCode? = nil, sessionStatus: SessionStatus = .saved,
                reaperVersionOutput: String = AppVersion.string + "\n",
                in tmp: TempDirectory? = nil, diskImage: DiskImageVolume? = nil) throws

    public var config: AppConfig { get }
    public func updateConfig(_ mutate: (inout AppConfig) -> Void)
    /// snapshot に載せる relpath の既定（デバイスに置いた Part の relpath）
    public var deviceRelpaths: Set<String> { get }

    // 観測と評価
    /// completedAt が nil なら clock.now()（古い snapshot は `completedAt: DeletionScene.now.adding(seconds: -901)` のように渡す）
    public func snapshot(generation: UInt64 = 1, readOnly: Bool? = false, relpaths: Set<String>? = nil, includeDevice: Bool = true,
                         completedAt: Instant? = nil) -> DeviceSnapshot
    /// デバイスを実際に走査した snapshot（DeviceReader.scan の relpaths、SystemMountInspector の readOnly）。ディスクイメージの往復で使う
    public func scannedSnapshot(generation: UInt64) -> DeviceSnapshot
    public func context(snapshot: DeviceSnapshot?, locks: LockEvaluator? = nil, opener: (any VolumeOpener)? = nil, useCache: Bool = true) async -> DeletionContext
    public func candidate(_ partkey: String? = nil) throws -> DeletionCandidate   // nil なら self.partkey

    // 組み立て
    /// 同じ Session に Part を足す。transcript が真なら transcripts/parts に置き transcript_path を書く。onDevice が真ならデバイスに置く。
    /// inRawNote が真なら Raw ノートに載せる対象にする（載せ直すのは writeRawNote）
    @discardableResult
    public func addPart(fileName: String, folder: String = DeletionScene.folder, startedAt: String, status: PartStatus,
                        errorCode: ErrorCode? = nil, duplicateOf: String? = nil, sessionKey: String? = nil,
                        onDevice: Bool = true, transcript: Bool = true, inRawNote: Bool = true) throws -> String
    /// 別の日の Session を作る（OPEN）。重複の双子を別の日に置くため
    public func addSession(key: String, dayDate: String) throws
    /// Session の Raw ノートを書き直す（載せる対象の Part を RawNote.render で。DB の raw_output_path・raw_output_sha256 を更新）
    public func writeRawNote(sessionKey: String? = nil) throws
    public func rawNoteURL(sessionKey: String? = nil) throws -> URL
    /// ノートの中の文字列を置き換える。updateSHA が真なら DB の raw_output_sha256 を新しい SHA にする（鍵の包含だけを壊す）
    public func replaceInRawNote(_ target: String, with replacement: String, updateSHA: Bool, sessionKey: String? = nil) throws
    /// 末尾に追記する（SHA は更新しない。改竄）
    public func appendToRawNote(_ text: String, sessionKey: String? = nil) throws
    public func transcriptURL(_ partkey: String) -> URL
    public func placeOnDevice(_ relpath: String) throws       // content を書き mtime を sourceMtime に（utimes）。deviceRelpaths に足す
    public func removeFromDevice(_ relpath: String) throws    // ファイルを消し deviceRelpaths から除く
    public func movePart(_ partkey: String, to status: PartStatus, errorCode: ErrorCode? = nil) throws   // StorePaths.advancePart
    public func moveSession(to status: SessionStatus, sessionKey: String? = nil) throws
    public func installReaperStub() throws                    // "#!/bin/sh\nexit 0\n"、0o755
    public func removeReaper() throws
    public func writeReaperConf(deleteSourceAudio: Bool) throws   // ReaperConf(deleteSourceAudio:, volumesRoot: p(volumesRoot)).render()
    public func writeReaperConfRaw(_ data: Data) throws
    public func removeReaperConf() throws
    public func requests() -> [URL]                           // queue/delete の . 始まりでない .json（名前のバイト順）
    public func results() -> [URL]                            // queue/result の同上
    @discardableResult
    public func writeResult(partkey: String, requestID: String, status: DeleteResultStatus, detail: String) throws -> URL
    public var logLines: [String] { get }                      // sink.lines
}
```

`init` の手順（この順）:
1. `tmp` を使う（nil なら `try TempDirectory()`）。`layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))`、`createDirectories()`、`FileManager.default.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)`（テストの舞台なので bin を作ってよい）
2. `vault = tmp.url/vault`、`vault/.obsidian` を作る
3. `volumesRoot = diskImage?.volumesRoot ?? tmp.url/Volumes`、`deviceID = diskImage?.deviceID ?? DeletionScene.deviceID`、`deviceRoot = diskImage?.mountPoint ?? volumesRoot/<deviceID>`、`partkey = try PartKey.make(deviceID:, relpath: DeletionScene.relpath)`、`sessionKey = try SessionKey.make(deviceID:, dayStamp: "20260912")`。ディスクイメージでなければ `deviceRoot` を作る（`sessionKey: String? = nil` の引数は、nil なら `self.sessionKey`）
4. `placeOnDevice(DeletionScene.relpath)`。置いた後に `lstat` した mtime を**実際の原本の mtime**として控える（FAT は 2 秒刻み。偽のボリュームでは `sourceMtime` のまま）
5. `clock = FixedClock(now: DeletionScene.now)`、`zone = ZonedTime(timeZone: Asia/Tokyo)`（`TimeZone(identifier:)` の nil は `StorePathError` にして投げる）、`sink = CapturingLogSink()`、`log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: zone, clock: clock)`
6. 設定: `AppConfig.defaults(timeZone: "Asia/Tokyo")` に `vault.path = p(vault)`、`cleanup.deleteSourceAudio = true`、`device.mountMode = "rw"`（`deleteSkippedSource` は既定の false）
7. `installReaperStub()`、`writeReaperConf(deleteSourceAudio: true)`
8. `verifier = FakeSignatureVerifier(valid: true)`、`runner = ScriptedProcessRunner(results: [ScriptedProcessRunner.version(reaperVersionOutput)])`、`locks = LockEvaluator(layout:, verifier:, runner:, log:)`
9. `opener = diskImage == nil ? FakeVolumeOpener() : SystemVolumeOpener()`
10. `store = try Store(url: layout.database, clock: clock, zone: zone)`、`insertSession(NewSession(sessionKey:, dayDate:, deviceID:))`
11. 既定の Part: `addPart(fileName: DeletionScene.fileName, startedAt: DeletionScene.startedAt, status: status, errorCode: errorCode, onDevice: false /* 4 で置いた */, transcript: true, inRawNote: true)`
12. `writeRawNote()`、`moveSession(to: sessionStatus)`

`addPart` の手順: `relpath = folder + "/" + fileName`、`pk = try PartKey.make(deviceID: self.deviceID, relpath:)`、`onDevice` なら `placeOnDevice(relpath)`、
`NewRecording(partkey: pk, deviceID: self.deviceID, sourceFolder: folder, transmitterID: String(fileName.prefix(4)), micIndex: 1, startedAt:, durationSeconds: 60.0, endedAt: zone.iso(zone.parseISO(startedAt)! + 60 秒)（`guard let`）, sourcePath: relpath, sourceSize: 4096, sourceMtime: 4 で控えた mtime, sha256Helper: FileHasher.sha256(content), inboxPath: "inbox/" + deviceID + "/" + relpath)` を `insertRecording` →
`updateRecording(pk, [.sessionKey(sessionKey)] + (duplicateOf.map { [.duplicateOf($0)] } ?? []) + (transcript ? [.transcriptPath(layout.relativePath(of: layout.transcript(slug: KeySlug.of(pk))))] : []))` →
`transcript` なら `PartTranscriptCodec.encode(PartTranscript(partkey: pk, language: "ja", durationSeconds: 60.0, startedAt: startedAt, text: transcriptText, segments: [TranscriptSegment(start: 0.0, end: 3.0, text: transcriptText)]))` を `layout.transcript(slug: KeySlug.of(pk))` に書く →
`StorePaths.advancePart(store, partkey: pk, to: status, errorCode: errorCode)` → `inRawNote` なら載せる対象に足す（`Mutex<[String: [String]]>`、Session ごとに追加順）→ `pk` を返す。

`writeRawNote(sessionKey:)`: 載せる対象の各 Part について `RawPart(partkey:, startedAt:, endedAt:, segments: [AbsoluteSegment(at: startedAt の Instant, endAt: +3000 ms, text: transcriptText)], zone: zone)`、
`day = LocalDate(dashed: その Session の day_date)`、`text = RawNote.render(parts:, day:, sessionKey:, config: config.obsidian)`、
`folderURL = try NoteFolder.ensure(relative: RawNote.folder(config: config.obsidian, day: day), vault: vault)`、
`url = folderURL.appendingPathComponent(RawNote.baseName(config: config.obsidian, day: day) + ".md")`、`sha = try NoteWriter.write(text, to: url)`、
`updateSession(sessionKey, [.rawOutputPath(RawNote.folder(…) + "/" + RawNote.baseName(…) + ".md"), .rawOutputSHA256(sha)])`（既定の Session では `Daily/Voice/Raw/20260912/2026-09-12 raw.md`）。

`snapshot(…)`: `DeviceSnapshot(generation:, completedAt: completedAt ?? clock.now(), connectEpoch: 1, devices: includeDevice ? [deviceID: DeviceObservation(deviceID: deviceID, mountPath: p(deviceRoot), deviceNode: "/dev/disk9", readOnly: readOnly, freeBytes: 1_000_000_000, relpaths: relpaths ?? deviceRelpaths)] : [:], unavailable: [:], notListableErrno: [:])`。

`scannedSnapshot(generation:)`: `relpaths = DeviceReader().scan(volumeRoot: p(deviceRoot), maxDepth: 3).relpaths`、`readOnly = SystemMountInspector().mountInfo(path: p(deviceRoot))?.readOnly`、ほかは `snapshot` と同じ。

`context(snapshot:locks:opener:useCache:)`: `DeletionContext(config: config, locks: await (locks ?? self.locks).observe(config: config, snapshot: snapshot, useCache: useCache), layout: layout, volumeOpener: opener ?? self.opener)`。

`writeResult`: `ContractJSON.encode(DeleteResult(requestID:, completedAt: zone.iso(clock.now()), reaperVersion: AppVersion.string, deviceID: deviceID, partkey:, status:, detail:))` を `layout.queueResult/<requestID>.json` に `Data.write`。

- 可変の状態（設定・デバイス上の relpath・Raw に載せる Part）は `Mutex` で持つ（`@unchecked Sendable` を使わない）
- **`/Volumes` の下には触れない**（volumesRoot は必ず一時ディレクトリかディスクイメージの一時マウント点）

#### `PipelineFixtures.swift`（T-18 のファイルの変更）

`PipelineWorld` に `let locks: LockEvaluator` と `let verifier: FakeSignatureVerifier` を足す。`make` で
`verifier = FakeSignatureVerifier(valid: true)`、`locks = LockEvaluator(layout: layout, verifier: verifier, runner: ScriptedProcessRunner(results: [ScriptedProcessRunner.version()]), log: log)` を作り、
`deps` の末尾に `locks: locks, volumeOpener: FakeVolumeOpener()` を渡す（ConfigStore の `observeReaperConf` は `{ .missing }` のまま）。

## 5. ログ（このチケットが出すもの）

| イベント | レベル | フィールド | 出す場所 |
|---|---|---|---|
| `reaper_failed` | WARNING | `reason=signature` / `reason=version_mismatch` | `LockEvaluator.reaperStatus`（検証したときだけ） |

## 6. テスト

共通: `import Testing`、`import TestSupport`、`@testable import VDPipeline`、`import VDContract`、`import VDCore`、`import VDStore`、`import VDDevice`。
舞台は `let scene = try DeletionScene()`、評価は `let ctx = await scene.context(snapshot: scene.snapshot())`・`let c = try scene.candidate()`。
**各テストは弾かせたい条件以外をすべて満たす**（TEST-19）。「対照」と書いた行は、同じ準備で壊した項だけを戻すと真になることも確かめる。

### 6.1 `Tests/NoDeleteTests/DeletionPolicyNDTests.swift`（`@Suite("DeletionPolicy の ND（層 A）") struct DeletionPolicyNDTests`）

表示名は `ND-nn [A] …` で始める（SPEC 同期が層ごとに集める）。期待の「偽」は `DeletionPolicy.canDeleteSource(c, ctx) == false`。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `everyTermHoldsWhenEverythingIsValid` | 正の対照 [A] 三重ロックを外し本文が 2 か所に在れば削除条件が真 | 既定 | `canDeleteSource`・`deletionIsIdentified`・`textIsPreserved`・`preIdentityCheck`・`partTranscriptIsValid` が真、`verifyRawNote == .passed`、`frontmatterKeys` が partkey を含む、`ctx.locks.readiness == .configured`、`nothingToPreserve` が偽 |
| `nd01PartStillNormalizing` | ND-01 [A] 変換中（NORMALIZING）の Part は消さない | `DeletionScene(status: .normalizing)` | 偽。`deletionIsIdentified` は真・`verifyRawNote == .passed`（壊したのは状態だけ） |
| `nd02NormalizeVerifyFailed` | ND-02 [A] 変換結果の長さがずれて FAILED の Part は消さない | `status: .failed, errorCode: .normalizeVerifyFailed` | 同上 |
| `nd03DuplicateKeptWhileLockBIsClosed` | ND-03 [A] 重複は deleteSkippedSource が偽なら消さない | 既定の Part を双子に、`addPart(fileName: "TX00_MIC002_20260912_093000_orig.wav", startedAt: "2026-09-12T09:30:00+09:00", status: .skipped, errorCode: .duplicateContent, duplicateOf: DeletionScene.partkey, transcript: false, inRawNote: false)` の candidate | 偽。対照: `updateConfig { $0.cleanup.deleteSkippedSource = true }` の後は真（twin が引けている） |
| `nd04WhisperFailed` | ND-04 [A] whisper の失敗で FAILED の Part は消さない | `status: .failed, errorCode: .whisperFailed` | 偽、`deletionIsIdentified` 真 |
| `nd05WhisperTimeout` | ND-05 [A] whisper のタイムアウトで FAILED の Part は消さない | `status: .failed, errorCode: .whisperTimeout` | 同上 |
| `nd06NoSpeechKeptWhileLockBIsClosed` | ND-06 [A] 無音は deleteSkippedSource が偽なら消さない | 既定の舞台に `addPart(fileName: "TX00_MIC001_20260912_100000_orig.wav", folder: "TX_MIC001_20260912_100000", startedAt: "2026-09-12T10:00:00+09:00", status: .skipped, errorCode: .noSpeechDetected, inRawNote: false)`（transcript のファイルは在る）、`updateRecording(pk, [.transcriptPath(nil)])` | その Part で偽。対照: ロック B を開けると真（根拠 B は実ファイルだけを見る。列で門前払いする退行を落とす）。既定の Part は真のまま |
| `nd07MissingRawNotePath` | ND-07 [A] Raw ノートの書き込みに失敗（raw_output_path が NULL）なら消さない | `updateSession(sessionKey, [.rawOutputPath(nil)])` | 偽、`verifyRawNote == .notRecorded` |
| `nd08RawNoteChangedAfterSaving` | ND-08 [A] 保存後に Raw ノートが消えた・改変されたら消さない（パラメータ化: 削除・追記） | (a) ノートを消す (b) `appendToRawNote("\n追記された行\n")` | (a) 偽、`.failed(["RN-1"])` (b) 偽、`.failed(["RN-4"])`、`frontmatterKeys` はまだ partkey を含む（verifyRawNote を単独で落とす） |
| `nd09RawNoteWithoutThisKey` | ND-09 [A] Raw ノートの鍵に当該 Part が無ければ消さない | `replaceInRawNote(DeletionScene.partkey, with: "DJIMIC3/other/other.wav", updateSHA: true)` | 偽、`frontmatterKeys` が partkey を含まない |
| `nd21EmptyPartsIsNotDeletable` | ND-21 [A] Part 0 件の Session では消さない（番犬） | `DeletionCandidate(part:, session:, parts: [], twin: nil)` | 偽。`textIsPreserved(part, session, [], ctx)` は**真**（番犬だけが落とす） |
| `nd21NullOrEmptySourcePath` | ND-21 [A] source_path が nil か空なら消さない（パラメータ化） | `StorePaths.setSourcePath(store, partkey:, nil)` / `""` | どちらも偽、`preIdentityCheck` 偽 |
| `nd22EitherSideOfLockOneBlocks` | ND-22 [A] ロック 1 の片方だけ偽でも消さない（パラメータ化: アプリ・reaper.conf） | (a) `deleteSourceAudio = false` (b) `writeReaperConf(deleteSourceAudio: false)` | (a) readiness `.disabled("delete_source_audio_disabled")` (b) `.disabled("lock_mismatch")`、どちらも偽 |
| `nd23ReadOnlyObservedBlocks` | ND-23 [A] デバイスが読み取り専用（観測）なら消さない | `snapshot(readOnly: true)` | 偽、`ctx.locks.writability("DJIMIC3") == .readOnly` |
| `nd23ReadOnlyVolumeHandleBlocks` | ND-23 [A] 事前確認で開いたボリュームが読み取り専用なら消さない（二重確認） | snapshot は rw、`opener: FakeVolumeOpener(readOnly: true)` | 偽、`deletionIsIdentified` の中で `preIdentityCheck` だけが偽（`allReleased` は真） |
| `nd26ReaperNotInstalledBlocks` | ND-26 [A] bin/voicedock-reaper が無ければ要求の条件が偽 | `removeReaper()` | 偽、readiness `.disabled("reaper_not_installed")`、`verifier.verifiedURLs` が空、`runner.recorded` が空（無いものを検証・起動しない） |
| `nd31KeyFromAnotherDeviceBlocks` | ND-31 [A] device_id だけが違う鍵では消さない | `other = PartKey.make(deviceID: "NO NAME", relpath: DeletionScene.relpath)`、`replaceInRawNote(partkey, with: other, updateSHA: true)` | 偽、`frontmatterKeys` が `other` を含み partkey を含まない |
| `nd32BrokenPartTranscriptBlocks` | ND-32 [A] Part の transcript が無いか壊れていれば消さない（パラメータ化: 列が NULL・ファイルが無い・JSON が壊れている） | (a) `updateRecording(pk, [.transcriptPath(nil)])` (b) transcript を消す (c) `"{こわれた"` を書く | すべて偽。(a) は `partTranscriptIsValid` が真のまま（列の項だけを落とす）、(b)(c) は `verifyRawNote == .passed` のまま（`partTranscriptIsValid` だけを落とす） |
| `nd36EmptyVaultBlocks` | ND-36 [A] Vault の .obsidian が無ければ（空の Vault）消さない | `vault/.obsidian` を消す | 偽、`verifyRawNote == .vaultUnavailable` |
| `nd41InvalidReaperBlocks` | ND-41 [A] reaper の署名が不正・版が違えば条件が偽（パラメータ化） | (a) 新しい舞台で `verifier.setValid(false)` (b) `DeletionScene(reaperVersionOutput: "0.0.1\n")` | どちらも readiness `.disabled("reaper_invalid")`、偽。(a) は `runner.recorded` が空（署名が不正なら --version も実行しない） |
| `nd45UnknownReaperConfBlocks` | ND-45 [A] reaper.conf が無い・不正・symlink なら消さない（不明は安全側。パラメータ化） | (a) `removeReaperConf()` (b) `writeReaperConfRaw("SCHEMA=1\nDELETE_SOURCE_AUDIO=maybe\n")` (c) 正しい reaper.conf を `<tmp>/other.conf` に置き、`bin/reaper.conf` をそこへの symlink に | すべて readiness `.disabled("lock_mismatch")`、偽 |

- 故障の注入そのもの（I/O エラー・長さのずれ・whisper の失敗など）は T-16・T-17・T-18 のテストが見る。ここは**その結果の状態から削除条件が偽になること**を見る（voicedock test_no_delete.py:383-433 と同じ分担）
- 要求ファイルが書かれないこと（層 A の観測できる結果）は、同じ故障の一覧で T-38 の `everyLayerAFaultWritesNoRequest` が確かめる
- ND-33〜35 は T-39、ND-42・46・47 は T-38 が書く

### 6.2 `Tests/VDPipelineTests/DeletionPolicyTests.swift`（`@Suite("DeletionPolicy") struct DeletionPolicyTests`）

項を 1 つずつ落とす（DEL-05: どの項を消しても落ちるテストが在ること）。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `fileAbsentFromSnapshotBlocks` | snapshot にファイルが無ければ事前確認が偽 | `snapshot(relpaths: [])` | `preIdentityCheck` 偽、`canDeleteSource` 偽、`allReleased` 真 |
| `deviceAbsentFromSnapshotBlocks` | snapshot にデバイスが無ければ偽 | `snapshot(includeDevice: false)` | `preIdentityCheck` 偽、`writability == .absent` |
| `nilSnapshotBlocks` | snapshot が無ければ偽 | `context(snapshot: nil)` | `canDeleteSource` 偽 |
| `keyThatDisagreesWithPathBlocks` | 鍵と source_path が食い違えば偽 | `addPart(fileName: "TX00_MIC002_20260912_090000_orig.wav", …, inRawNote: false)` でデバイスと snapshot に置き、既定の Part の source_path をその relpath に `setSourcePath` | `preIdentityCheck` 偽、`canDeleteSource` 偽 |
| `unsafeRelpathBlocks` | 不健全な relpath は偽 | `setSourcePath(pk, "../" + DeletionScene.relpath)` | 偽 |
| `missingSizeOrMtimeBlocks` | source_size / source_mtime が無ければ偽（パラメータ化） | `updateRecording(pk, [.sourceSize(nil)])` / `[.sourceMtime(nil)]` | 偽 |
| `unopenableVolumeBlocks` | 事前確認でボリュームが開けなければ偽 | `writeReaperConf` の VOLUMES_ROOT を `<tmp>/NoVolumes` にした reaper.conf を `writeReaperConfRaw` | `ctx.locks.volumesRoot == <tmp>/NoVolumes`、`preIdentityCheck` 偽、`canDeleteSource` 偽 |
| `changedFileOnDeviceBlocks` | デバイス上のファイルのサイズが DB と違えば偽（withVerifiedTarget） | デバイスのファイルに 1 バイト追記し mtime を戻す | `preIdentityCheck` 偽、`canDeleteSource` 偽（snapshot には在る） |
| `copyTimestampIsRejected` | DEL-12 inbox のコピーの時刻（4 時間 34 分後）では事前確認が偽 | `updateRecording(pk, [.sourceMtime(DeletionScene.sourceMtime + 16_440)])` | `preIdentityCheck` 偽、`canDeleteSource` 偽 |
| `verifierPassesWhenNoteMatches` | Raw ノートが一致すれば passed | 既定 | `.passed` |
| `verifierNeedsRecordedSHA` | raw_output_sha256 が無ければ notRecorded | `updateSession(key, [.rawOutputSHA256(nil)])` | `.notRecorded` |
| `verifierNeedsConfiguredVault` | vault.path が nil なら vaultUnavailable | `updateConfig { $0.vault.path = nil }` | `.vaultUnavailable` |
| `expectedKeysFollowRawNoteMembership` | 期待する鍵は Raw に載る Part だけ（書き手と同じ関数。BI-1） | `addPart(fileName: "TX00_MIC001_20260912_100000_orig.wav", folder: "TX_MIC001_20260912_100000", startedAt: "2026-09-12T10:00:00+09:00", status: .failed, errorCode: .obsidianRawWriteFailed, inRawNote: false)`（transcript は読める） | 既定の Part の `canDeleteSource` は真 |
| `unfinishedSiblingDoesNotBlock` | 兄弟の Part が未完でも消せる（Part ごとに評価。DEL-04） | 兄弟を `status: .transcribing, transcript: false, inRawNote: false` で足す | 真 |
| `siblingNotYetInRawNoteBlocksUntilRewritten` | TRANSCRIBED の兄弟が Raw に未掲載なら、書き直すまで偽（RN-6） | 兄弟を `status: .transcribed`（inRawNote は既定の真。ノートはまだ書き直さない）で足す → 評価 → `writeRawNote()` → 評価 | 1 回目は `.failed(["RN-6"])`・偽、書き直した後は真 |
| `dailyNoteIsNotACondition` | Daily ノートと解析の有無は条件にしない（AY-1） | `updateSession(key, [.outputPath(nil), .outputSHA256(nil), .analysisPath(nil)])` | 真 |
| `frontmatterKeysOfUnreadableNote` | 読めないノートの鍵は空（パラメータ化） | ノートを (a) 非 UTF-8 のバイト列 (b) frontmatter の無い本文 (c) `voicedock_recording_keys: x`（配列でない）に置き換える | すべて `[]` |
| `transcriptValidityReadsTheFile` | transcript の妥当性は実ファイルで決める | (a) 既定 (b) ファイルを消す（列は残す） | (a) 真 (b) 偽 |
| `keysCompareByScalars` | 鍵はスカラー列で比べる（正準等価で一致させない） | `sameKey("が", "か\u{3099}")`、`sameKey("a", "a")`、`sameKey(nil, "a")` | 偽・真・偽 |
| `candidateLoadsTheSessionAndTwin` | candidate は Session・全 Part・双子を引く | 重複の Part を足し `DeletionCandidate.load(partkey: dup, store:)` | `twin?.part.partkey == DeletionScene.partkey`、`twin?.session.sessionKey == DeletionScene.sessionKey`、`parts.count == 2` |
| `candidateIsNilWithoutSession` | Part か Session が無ければ nil（パラメータ化） | (a) 無い partkey (b) session_key を nil にした Part（`updateRecording(pk, [.sessionKey(nil)])`） | nil |
| `twinIsNilWhenTheRecordedTwinIsMissing` | duplicate_of の指す Part が無ければ双子は nil | 重複を `duplicateOf: "DJIMIC3/none/none_orig.wav"` で足す | `twin == nil`、ロック B を開けても偽 |
| `duplicateWithoutDuplicateOfIsNotBacked` | duplicate_of が nil の重複は、双子を渡しても根拠が無い | 重複を `duplicateOf: nil` で足し、`DeletionCandidate(part: dup, …, twin: TwinPart(既定の Part…))` を直接作る。ロック B を開ける | `skipReasonIsBacked` 偽。対照: `updateRecording(dup, [.duplicateOf(DeletionScene.partkey)])` の後は真 |
| `onlyTheRecordedTwinIsAccepted` | duplicate_of で指名された双子だけを認める | 重複を `duplicateOf: "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC009_20260912_120000_orig.wav"` で足し、既定の Part を twin として渡す | 偽。対照: 指名を既定の partkey に直すと真 |
| `missingTwinArgumentIsNotBacked` | duplicate_of が在っても twin が nil なら偽 | 重複（指名は既定の partkey）、`twin: nil` で直接作る | 偽 |
| `twinOnAnotherDayIsEvaluatedOnItsOwnSession` | 双子が別の日でも双子の Session で根拠 A を見る | `addSession(key: "DJIMIC3:20260911", dayDate: "2026-09-11")`、双子をその日に RAW_SAVED で足し `writeRawNote(sessionKey: "DJIMIC3:20260911")`、重複を既定の日に | 真 |
| `nonSkippedPartIsNotGroundB` | SKIPPED でなければ理由が揃っても根拠 B ではない | `DeletionScene(status: .failed, errorCode: .noSpeechDetected)`、ロック B | `nothingToPreserve` 偽（`skipReasonIsBacked` は真） |
| `sourceMissingHasNoBasis` | SOURCE_MISSING は許可リストに無く根拠も無い | `status: .skipped, errorCode: .sourceMissing`、ロック B | `nothingToPreserve` 偽、`skipReasonIsBacked` 偽 |
| `lockOneAlsoStopsGroundB` | ロック 1 は根拠 B にも掛かる | 無音の舞台、ロック B を開け `deleteSourceAudio = false` | 偽（共通項が落とす） |
| `readOnlyAlsoStopsGroundB` | ロック 2-B も根拠 B に掛かる | 無音の舞台、ロック B、`snapshot(readOnly: true)` | 偽 |
| `everyDeletableSkipReasonHasABasis` | 許可リストの全理由に根拠の分岐がある（TEST-08） | `for code in SkipReasons.deletable`: `.noSpeechDetected` → 無音の舞台、`.duplicateContent` → 重複の舞台、それ以外 → `Issue.record("\(code) の舞台が無い")`。ロック B を開ける | 各 `skipReasonIsBacked` が真（許可リストにだけ足して分岐を書き忘れると落ちる） |
| `frontmatterKeysAloneBlocksWhenExpectedIsEmpty` | Raw ノートに当該の鍵が無ければ、RN-6 が空集合で通っても偽 | 重複（指名は既定の partkey）を足しロック B を開け、`replaceInRawNote(scene.partkey, with: scene.deviceID + "/other/other.wav", updateSHA: true)`、`DeletionCandidate(part: dup, session:, parts:, twin: TwinPart(part: 既定の Part, session:, parts: []))` | `verifyRawNote(session, [], ctx) == .passed`、`canDeleteSource` 偽。対照: `writeRawNote()` で戻すと真 |
| `partFromAnotherSessionIsNotIdentified` | Part の session_key と渡された Session が食い違えば同定しない | `addSession(key: "DJIMIC3:20260911", dayDate: "2026-09-11")`、その日に Part を RAW_SAVED で足し `writeRawNote(sessionKey: "DJIMIC3:20260911")`、DB の session_key だけを既定の Session に変え、`DeletionCandidate(part:, session: 20260911 の Session, parts: [part], twin: nil)` | `textIsPreserved` 真、`deletionIsIdentified` 偽、`canDeleteSource` 偽 |
| `twinSessionMismatchIsNotBacked` | 双子の session_key と双子の Session が食い違えば根拠が無い | 双子を 20260911 に RAW_SAVED で足し Raw を書き、重複を既定の日に、ロック B。双子の行の session_key だけを既定の Session に変え、`TwinPart(part: 変えた行, session: 20260911 の Session, parts: [変えた行])` | `textIsPreserved(双子)` 真、`skipReasonIsBacked` 偽。対照: 変える前の行で作った TwinPart なら真 |

### 6.3 `Tests/VDPipelineTests/DeletionSceneTests.swift`（`@Suite("DeletionScene")`。偽物そのもののテスト。TEST-05）

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `sceneMatchesTheDevice` | 舞台の DB の値はデバイス上の原本と一致する | 既定の Part の `sourceSize == 4096`、`sourceMtime` がデバイスのファイルの lstat の mtime と等しい、`sourcePath == DeletionScene.relpath`、`partkey == DeletionScene.partkey` |
| `sceneRawNoteCarriesTheKey` | Raw ノートに既定の Part の鍵が載り、SHA が DB と一致する | `Frontmatter.recordingKeys(ofFile:)` が partkey を含む、`FileHasher.sha256(of:)` == `rawOutputSHA256`、`rawOutputPath == "Daily/Voice/Raw/20260912/2026-09-12 raw.md"` |
| `sceneTranscriptDecodes` | transcript が §8.4 の合格条件を満たす | `PartTranscriptCodec.decode` が nil でない |
| `sceneLocksAreReleased` | 三重ロックが全部外れている | `readiness == .configured`、`observe(...).allReleased(for: "DJIMIC3") == true`、`volumesRoot == p(volumesRoot)` |
| `sceneHasNoRequests` | 始めは要求も結果も無い | `requests() == []`、`results() == []` |
| `storePathsReachEveryStatus` | StorePaths は全状態へ辺だけで進める（パラメータ化: `PartStatus.allCases`） | 新しい Part を各状態へ `advancePart`。例外なし、行の status が一致 |
| `sessionPathsReachEveryStatus` | 同じく Session（`SessionStatus.allCases`） | 同上 |

### 6.4 `Tests/VDPipelineTests/LockEvaluatorTests.swift`（`@Suite("LockEvaluator")`）

準備（`makeEvaluator`）: `TempDirectory`、`HomeLayout`（createDirectories、bin を作る）、`bin/voicedock-reaper`（`"#!/bin/sh\nexit 0\n"`、0o755）、`ReaperConf(deleteSourceAudio: true, volumesRoot: "/tmp/vd-volumes").render()` を reaper.conf に、
設定は既定に `deleteSourceAudio = true`・`mountMode = "rw"`、`FakeSignatureVerifier(valid: true)`、`ScriptedProcessRunner(results: [.version()])`、`CapturingLogSink`。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `configuredWhenEverythingIsReleased` | 全部そろえば configured | 既定 | `.configured` |
| `readinessOrderAndWords` | readiness の判定順と理由語（パラメータ化） | (a) 設定 false かつ reaper 無し (b) reaper.conf false かつ mountMode ro (c) mountMode ro かつ reaper 無し (d) reaper 無し (e) 署名 NG (f) 版 `"0.9.0\n"` (g) 版の終了コード 1 (h) 版のタイムアウト（`ProcessResult(termination: .timedOut, …)`） | (a) `delete_source_audio_disabled` (b) `lock_mismatch` (c) `mount_mode_ro` (d) `reaper_not_installed` (e)〜(h) `reaper_invalid` |
| `reaperConfUnknownIsMismatch` | reaper.conf が無い・不正は lock_mismatch（パラメータ化） | 無い / `"DELETE_SOURCE_AUDIO=true\n"`（SCHEMA 欠落） | `.disabled("lock_mismatch")` |
| `reaperDirectoryOrSymlinkIsNotInstalled` | 通常ファイルでない reaper は未導入（パラメータ化） | bin/voicedock-reaper をディレクトリ / 別ファイルへの symlink に | `.disabled("reaper_not_installed")`、署名検証を呼ばない |
| `disabledConfigDoesNotSpawn` | 設定で決まれば署名も版も見ない | 設定 false | `verifier.verifiedURLs == []`、`runner.recorded == []` |
| `versionRunsAfterSignature` | 版は署名の後。署名 NG なら実行しない | 署名 NG | `runner.recorded == []`、`verifiedURLs == [layout.reaperExecutable]` |
| `versionArgvIsExact` | --version の argv・環境・時間の上限 | 既定 | `recorded[0].executable == layout.reaperExecutable`、`arguments == ["--version"]`、`environment == ProcessEnvironment.standard`、`recordedTimeouts[0] == .seconds(10)` |
| `verificationIsCached` | (inode, size, mtime) が同じならキャッシュを使う | readiness を 3 回 | 署名検証 1 回・--version 1 回 |
| `useCacheFalseVerifiesAgain` | useCache: false は必ず検証し直す | readiness → `readiness(useCache: false)` | 署名検証 2 回・--version 2 回 |
| `changedFileInvalidatesCache` | ファイルが変われば検証し直す（パラメータ化: mtime・size・置き換え（新しい inode）） | 1 回評価 → (a) `utimes` で mtime +10 秒 (b) 1 バイト追記 (c) 別ファイルを書いて rename で置き換え → もう一度 | 署名検証 2 回・--version 2 回 |
| `cacheKeepsTheFailure` | 失敗もキャッシュし、ログは検証したときだけ | 署名 NG で 3 回 | `reaper_failed reason=signature` の行が 1 本、署名検証 1 回 |
| `versionMismatchIsLogged` | 版の不一致をログに出す | 版 `"0.9.0\n"` | `reaper_failed reason=version_mismatch` が 1 本、`reaperStatus() == .versionMismatch(found: "0.9.0")` |
| `removedReaperClearsCache` | 消えたら未導入に戻り、置き直せば検証し直す | 評価 → 消す → 評価 → 置き直す → 評価 | `.configured` → `reaper_not_installed` → `.configured`、署名検証 2 回（消えた時点で cache を空にし、置き直したファイルは鍵も変わる二重の防御。cache = nil だけは次の行が固定する） |
| `cacheIsClearedWhenReaperDisappears` | 消えたらキャッシュを捨てる（同じファイルを rename で戻しても検証し直す） | 評価（`.configured`）→ reaper を `bin/aside` へ rename → 評価 → `verifier.setValid(false)` → 元の名前へ rename で戻す（inode・size・mtime は同じ）→ 評価 | `.configured` → `reaper_not_installed` → `reaper_invalid` |
| `writabilityObservesSnapshot` | 観測の 4 値（パラメータ化） | snapshot nil / デバイス無し / readOnly false / true / nil | `.absent`・`.absent`・`.writable`・`.readOnly`・`.unknown` |
| `writabilityIgnoresMountModeSetting` | 設定値 mountMode を観測に使わない | 設定 `mountMode = "ro"`、観測 readOnly false | `writability == .writable`（readiness は `mount_mode_ro`） |
| `allReleasedNeedsBoth` | allReleased は準備と観測の両方（パラメータ化） | (configured, writable) / (configured, unknown) / (configured, readOnly) / (disabled, writable) / (configured, absent) | 真・偽・偽・偽・偽 |
| `observeCarriesVolumesRoot` | observe は reaper.conf の VOLUMES_ROOT を運ぶ | 既定 / reaper.conf 無し | `"/tmp/vd-volumes"` / nil |
| `observeReaperConfReadsTheFile` | observeReaperConf は bin/reaper.conf を読む | 既定 | `.valid(ReaperConf(deleteSourceAudio: true, volumesRoot: "/tmp/vd-volumes"))` |

### 6.5 `Tests/VDPipelineTests/LockDisplayTests.swift`（`@Suite("LockDisplay")`）

`LockDisplay(…)`（型は T-32 §4.11）を直接作り `lines` を見る（期待は T-32 §4.11 の表から手で書く）。1 本だけ `LockEvaluator` の `display`（`LockObserving` の既定実装）を通す。
T-32 §5.10 は `DisabledLockObserver` の 3 行だけを見る。ここは `ReaperStatus` と `DeviceWritability` と `ConfState` の全値を見る（重複ではない）。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `allReleasedLines` | 全部外れたときの 3 行（PLAN §8.9.8 の例） | appEnabled 真、enabled、`.valid(version: "1.0.0")`、`"rw"`、`[Device("DJIMIC3", .writable)]` | `["ロック 1  : アプリ=有効, reaper.conf=有効", "ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 1.0.0）", "ロック 2-B: 設定=rw, DJIMIC3=読み書き可能（観測）"]` |
| `defaultLines` | 既定（削除無効）の 3 行 | 偽、missing、notInstalled、`"ro"`、`[]` | `["ロック 1  : アプリ=無効, reaper.conf=無し", "ロック 2-A: 削除モジュール=未導入", "ロック 2-B: 設定=ro, デバイス未接続"]` |
| `unknownIsNotWritable` | 観測できないを読み書き可能に丸めない（#107 / #148） | devices `[Device("DJIMIC3", .unknown)]` / devices nil | 3 行目が `…, DJIMIC3=不明（観測）` / `…, 観測=不明` |
| `readOnlyAndSeveralDevices` | 読み取り専用と複数台 | `[("A", .writable), ("B", .readOnly)]` | `ロック 2-B: 設定=rw, A=読み書き可能（観測）, B=読み取り専用（観測）` |
| `reaperStates` | 削除モジュールの各状態（パラメータ化） | signatureInvalid / `versionMismatch(found: "0.9.0")` / `versionMismatch(found: nil)` | `導入済み（署名 NG）` / `導入済み（署名 OK, 版 0.9.0）。削除モジュールの更新が必要です` / `導入済み（署名 OK, 版 不明）。削除モジュールの更新が必要です` |
| `confStates` | 設定ファイルの各状態（パラメータ化） | `confState` が disabled / invalid | `reaper.conf=無効` / `reaper.conf=不正` |
| `evaluatorBuildsTheDisplay` | LockEvaluator.display は観測を並べ替えて渡す | §6.4 の準備、snapshot のデバイス `"B"`（rw）と `"A"`（nil） | `devices == [Device("A", .unknown), Device("B", .writable)]`、`reaper == .valid(version: AppVersion.string)`、`readiness == .configured` |

### 6.6 `Tests/VDPipelineTests/SignatureVerifierTests.swift`（`@Suite("CodeSignatureVerifier")`。本物の Security.framework）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `appleBinarySatisfiesAnchorApple` | Apple の署名は anchor apple を満たす（検証が動いていることの対照） | `CodeSignatureVerifier(requirement: "anchor apple").verify(url: /bin/ls)` | 真 |
| `wrongRequirementFails` | 要件に合わなければ偽 | `requirement: ReaperSignature.requirement(bundleID: "x", teamID: "ABCDE12345")`、`/bin/ls` | 偽 |
| `missingFileFails` | 無いファイルは偽 | `<tmp>/none` | 偽 |
| `unsignedFileFails` | 署名の無いファイルは偽 | `<tmp>/s.sh` に `"#!/bin/sh\necho hi\n"`、`anchor apple` | 偽 |
| `brokenRequirementFails` | 壊れた要件は偽（例外にしない） | `requirement: "not a requirement ((("` | 偽 |
| `requirementIsVerbatim` | 要件の文字列（逐語） | `ReaperSignature.requirement(bundleID: "io.github.shinsuke-terada.VoiceDock", teamID: "ABCDE12345")` | `anchor apple generic and identifier "io.github.shinsuke-terada.VoiceDock.reaper" and certificate leaf[subject.OU] = "ABCDE12345"` |
| `productionRequirementIsVerbatim` | 本番の要件の文字列（逐語。Team ID で束縛する） | `ReaperSignature.production` | `anchor apple generic and identifier "io.github.shinsuke-terada.VoiceDock.reaper" and certificate leaf[subject.OU] = "ZCWP35H248"` |
| `productionUsesAppIdentity` | 本番の要件は AppIdentity から作る | `ReaperSignature.production` | `requirement(bundleID: AppIdentity.bundleID, teamID: AppIdentity.teamID)` と等しく、`AppIdentity.reaperIdentifier` を含む |
| `fakeRecordsCalls` | 偽物は呼ばれた URL を記録し setValid に従う（TEST-05） | `FakeSignatureVerifier()` → verify → `setValid(false)` → verify | 真・偽、`verifiedURLs.count == 2` |

### 6.7 `Tests/VDPipelineTests/ReaperRunnerTests.swift`（`@Suite("ReaperRunner")`。T-36 の分）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `installationIsAbsentWithoutFile` | 無ければ absent | bin を作らない | `.absent` |
| `installationRejectsNonRegular` | 通常ファイルでなければ absent（パラメータ化: symlink・ディレクトリ） | | `.absent` |
| `installationKeyFollowsStat` | 鍵は lstat の inode・size・mtime | 4096 バイトのファイル、`utimes` で mtime 1_789_171_260 | `.present(key)`、`key.size == 4096`、`key.mtimeSeconds == 1_789_171_260`、`key.inode` が `lstat` の値 |
| `signatureChecksTheInstalledPath` | 署名検証は bin/voicedock-reaper だけを見る | `FakeSignatureVerifier` | `verifiedURLs == [layout.reaperExecutable]` |
| `versionMatchesExactly` | 版は stdout の完全一致（パラメータ化） | `AppVersion.string + "\n"` / `AppVersion.string`（改行なし）/ `AppVersion.string + "\n\n"` / `" " + AppVersion.string + "\n"` | 真・偽・偽・偽 |
| `versionNilOnFailure` | 終了コード ≠ 0・タイムアウトは nil | `exited(1)` / `.timedOut` | `runVersion() == nil` |

### 6.8 `Tests/VDCoreTests/AppIdentityTests.swift`（`@Suite("AppIdentity")`）

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `matchesIdentityEnv` | AppIdentity は identity.env と同じ | `PackageRoot.file("identity.env")` を行ごとに `KEY=VALUE` で読み、`BUNDLE_ID == AppIdentity.bundleID`、`TEAM_ID == AppIdentity.teamID`。TEAM_ID は `^[A-Z0-9]{10}$` に一致（プレースホルダのままなら落ちる） |
| `reaperIdentifierAppendsSuffix` | reaper の識別子は <BUNDLE_ID>.reaper | `AppIdentity.reaperIdentifier == AppIdentity.bundleID + ".reaper"` |

### 6.9 `Tests/PolicyTests/DeletionFormulaTests.swift`（TEST-30。全文）

```swift
// 削除の必要十分条件の式の形そのものを固定する（PLAN §8.9.1・TEST-30。T-36）。
// 振る舞いでは落とせない冗長な項（番犬）が式に在ること、|| が共通項の内側にあることを、ソースのトークンで確かめる。
// 式を変えるなら PLAN §8.9.1 を先に直し、ここの期待値を同じ PR で直す。
import Foundation
import TestSupport
import Testing

@Suite("DeletionFormula")
struct DeletionFormulaTests {
    static let path = "VDPipeline/DeletionPolicy.swift"

    /// 期待する本体（PLAN §8.9.1 の式を Swift に写したもの）。トークンを並べ、識別子・数値が隣り合う所だけ空白 1 つを挟んだ形。
    /// 振る舞いでは落とせない項と、その理由:
    /// - canDeleteSource の `&&(…||…)`: 根拠 B 単独のテストは `||` が外に出ても通る（共通項を迂回した形でも根拠 B の正の対照は真のまま）
    /// - 同 `c.part.sourcePath!=nil` と `c.part.sourcePath?.isEmpty==false`: preIdentityCheck が同じ値を先に偽にする
    /// - textIsPreserved の `session.rawOutputPath!=nil`: verifyRawNote が .notRecorded で先に偽にする
    /// - skipReasonIsBacked の `!sameKey(twin.part.partkey,c.part.partkey)`: 自分を双子にすると SKIPPED は deletable に無く根拠 A が偽
    /// - 同 `default:return false`: 許可リストに無い理由は nothingToPreserve の SkipReasons.deletable が先に落とす
    /// - 双子に deletionIsIdentified を要求しないこと: 双子の元音声は通常もう無いので、要求すると根拠 B が永久に偽（振る舞いは T-39 の正の対照が見る）
    /// 振る舞いでも落とせる項（形でも固定する。落とすテストは DeletionPolicyTests）:
    /// - deletionIsIdentified の `sameKey(c.part.sessionKey,c.session.sessionKey)`: partFromAnotherSessionIsNotIdentified
    /// - textIsPreserved の `frontmatterKeys(…).contains(…)`: frontmatterKeysAloneBlocksWhenExpectedIsEmpty（期待する鍵が空集合なら RN-6 は通る）
    /// - skipReasonIsBacked の `sameKey(twin.part.sessionKey,twin.session.sessionKey)`: twinSessionMismatchIsNotBacked
    static let expected: [String: String] = [
        "canDeleteSource":
            "deletionIsIdentified(c,ctx)&&(textIsPreserved(c.part,c.session,c.parts,ctx)||nothingToPreserve(c,ctx))",
        "deletionIsIdentified":
            "ctx.locks.allReleased(for:c.part.deviceID)&&sameKey(c.part.sessionKey,c.session.sessionKey)"
            + "&&c.parts.count>=1&&c.part.sourcePath!=nil&&c.part.sourcePath?.isEmpty==false&&preIdentityCheck(c.part,ctx)",
        "textIsPreserved":
            "session.rawOutputPath!=nil&&verifyRawNote(session,parts,ctx)==.passed"
            + "&&frontmatterKeys(session.rawOutputPath,ctx).contains(where:{sameKey($0,part.partkey)})"
            + "&&PartStates.deletable.contains(part.status)&&part.transcriptPath!=nil&&partTranscriptIsValid(part,ctx)",
        "nothingToPreserve":
            "ctx.config.cleanup.deleteSkippedSource==true&&c.part.status==.skipped"
            + "&&SkipReasons.deletable.contains(where:{$0==c.part.errorCode})&&skipReasonIsBacked(c,ctx)",
        "skipReasonIsBacked":
            "switch c.part.errorCode{case.noSpeechDetected:return partTranscriptIsValid(c.part,ctx)"
            + "case.duplicateContent:guard let twinKey=c.part.duplicateOf,let twin=c.twin,sameKey(twin.part.partkey,twinKey),"
            + "!sameKey(twin.part.partkey,c.part.partkey),sameKey(twin.part.sessionKey,twin.session.sessionKey)"
            + "else{return false}return textIsPreserved(twin.part,twin.session,twin.parts,ctx)default:return false}",
    ]

    struct Missing: Error, CustomStringConvertible { let description: String }

    /// トークンを連結する。識別子・数値が隣り合う所だけ空白 1 つ。
    static func normalized(_ tokens: [CodeToken]) -> String {
        var out = ""
        var previousIsWord = false
        for token in tokens {
            let isWord = token.kind == .identifier || token.kind == .number
            if isWord && previousIsWord { out += " " }
            out += token.text
            previousIsWord = isWord
        }
        return out
    }

    /// `func <name>(` の本体（外側の `{` `}` を除く。先頭の `return` も除く）を normalized にする。
    static func normalizedBody(_ function: String) throws -> String {
        let text = try String(contentsOf: PackageRoot.file("Sources/" + path), encoding: .utf8)
        let file = SourceFile(relativePath: path, text: text)
        guard let body = OrderingPolicy.body(of: function, in: file.tokens) else {
            throw Missing(description: "\(path) に func \(function)( が無い")
        }
        var inner = Array(body.dropFirst().dropLast())
        if inner.first?.kind == .identifier && inner.first?.text == "return" { inner.removeFirst() }
        return normalized(inner)
    }

    @Test("TEST-30 削除条件の式の形を固定する", arguments: ["canDeleteSource", "deletionIsIdentified", "textIsPreserved", "nothingToPreserve", "skipReasonIsBacked"])
    func formulaShapeIsFixed(_ function: String) throws {
        let want = try #require(Self.expected[function])
        #expect(try Self.normalizedBody(function) == want)
    }

    @Test("期待値の表が 5 つの関数を過不足なく持つ")
    func expectedCoversTheFormula() {
        #expect(Set(Self.expected.keys) == ["canDeleteSource", "deletionIsIdentified", "textIsPreserved", "nothingToPreserve", "skipReasonIsBacked"])
    }

    @Test("正規化はコメントと空白を無視し、語の間だけ空白を残す（自己テスト）")
    func normalizationSelfTest() {
        let source = "func f() -> Bool {\n    // コメント\n    return a.b(c: 1) >= 2\n        && !x?.isEmpty\n}\n"
        let file = SourceFile(relativePath: "X.swift", text: source)
        let body = OrderingPolicy.body(of: "f", in: file.tokens)
        #expect(body.map { Self.normalized(Array($0.dropFirst().dropLast())) } == "return a.b(c:1)>=2&&!x?.isEmpty")
    }
}
```

- `arguments:` に同じ 5 つの名前を書き、`expectedCoversTheFormula` で表と一致させる（引数の元を検証対象そのものにしない。TEST-01）
- 行が 120 桁を超える所は `swift format` の整形に従って折り返してよい（トークンは変わらない）

## 7. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | canDeleteSource を `deletionIsIdentified(c, ctx) && textIsPreserved(…) \|\| nothingToPreserve(c, ctx)`（`\|\|` を外へ） | `formulaShapeIsFixed(canDeleteSource)` |
| 2 | `ctx.locks.allReleased(…)` の項を消す | `nd22EitherSideOfLockOneBlocks`、`nd23ReadOnlyObservedBlocks`、`nd26ReaperNotInstalledBlocks`、`nd41InvalidReaperBlocks`、`lockOneAlsoStopsGroundB`、`readOnlyAlsoStopsGroundB`、`formulaShapeIsFixed(deletionIsIdentified)`（`nd45UnknownReaperConfBlocks` は落ちない: reaper.conf が不明なら `volumesRoot` が nil で、`preIdentityCheck` の手順 6 も偽にする） |
| 3 | `c.parts.count >= 1` を消す | `nd21EmptyPartsIsNotDeletable`、`formulaShapeIsFixed(deletionIsIdentified)` |
| 4 | `c.part.sourcePath?.isEmpty == false` を消す | `formulaShapeIsFixed(deletionIsIdentified)`（振る舞いでは落ちない。番犬） |
| 5 | `preIdentityCheck` の項を消す | `nd23ReadOnlyVolumeHandleBlocks`、`unsafeRelpathBlocks`、`missingSizeOrMtimeBlocks`、`fileAbsentFromSnapshotBlocks`、`keyThatDisagreesWithPathBlocks`、`unopenableVolumeBlocks`、`changedFileOnDeviceBlocks`、`copyTimestampIsRejected`（この 5 本は `canDeleteSource` の偽も見る）、`formulaShapeIsFixed(deletionIsIdentified)` |
| 6 | preIdentityCheck の snapshot の relpath の確認を消す | `fileAbsentFromSnapshotBlocks` |
| 7 | preIdentityCheck の `volume.readOnly == false` を消す | `nd23ReadOnlyVolumeHandleBlocks` |
| 8 | preIdentityCheck の `withVerifiedTarget` を消す（常に真） | `changedFileOnDeviceBlocks`、`copyTimestampIsRejected` |
| 9 | preIdentityCheck の PartKey の照合を消す | `keyThatDisagreesWithPathBlocks` |
| 10 | `verifyRawNote(…) == .passed` を消す | `nd08RawNoteChangedAfterSaving`(b)、`formulaShapeIsFixed(textIsPreserved)` |
| 11 | verifyRawNote の VaultCheck を消す | `nd36EmptyVaultBlocks`（`verifierNeedsConfiguredVault` は落ちない: vault.path が nil なら `ctx.vaultRoot` も nil で `.vaultUnavailable` のまま） |
| 12 | verifyRawNote の期待する鍵を `parts.map(\.partkey)`（RawNoteMembership を使わない）にする | `expectedKeysFollowRawNoteMembership`、`unfinishedSiblingDoesNotBlock`、`nd03DuplicateKeptWhileLockBIsClosed`、`onlyTheRecordedTwinIsAccepted`、`duplicateWithoutDuplicateOfIsNotBacked`、`everyDeletableSkipReasonHasABasis`（`nd32BrokenPartTranscriptBlocks`(b)(c) は落ちない: 壊した Part の鍵はノートに載ったままなので RN-6 の包含は真） |
| 13 | `PartStates.deletable.contains(part.status)` を消す | `nd01PartStillNormalizing`、`nd02…`、`nd04…`、`nd05…` |
| 14 | `part.transcriptPath != nil` を消す | `nd32BrokenPartTranscriptBlocks`(a) |
| 15 | partTranscriptIsValid を `part.transcriptPath != nil` にする（ファイルを読まない） | `nd32BrokenPartTranscriptBlocks`(b)(c)、`transcriptValidityReadsTheFile` |
| 16 | `deleteSkippedSource == true` の項を消す | `nd03DuplicateKeptWhileLockBIsClosed`、`nd06NoSpeechKeptWhileLockBIsClosed` |
| 17 | `c.part.status == .skipped` を消す | `nonSkippedPartIsNotGroundB` |
| 18 | skipReasonIsBacked の `default: return false` を `return true` にする | `sourceMissingHasNoBasis`、`formulaShapeIsFixed(skipReasonIsBacked)` |
| 19 | skipReasonIsBacked の `sameKey(twin.part.partkey, twinKey)` を消す | `onlyTheRecordedTwinIsAccepted` |
| 20 | skipReasonIsBacked の `.noSpeechDetected` の分岐を消す（default に落ちる） | `everyDeletableSkipReasonHasABasis`、`formulaShapeIsFixed(skipReasonIsBacked)` |
| 21 | sameKey を `==`（正準等価）にする | `keysCompareByScalars` |
| 22 | readiness の 2 と 3 を入れ替える | `readinessOrderAndWords`(b) |
| 23 | reaperStatus で署名より先に --version を実行する | `versionRunsAfterSignature`、`nd41InvalidReaperBlocks`(a) |
| 24 | キャッシュの鍵の比較を消す（常にキャッシュを使う） | `changedFileInvalidatesCache`（`removedReaperClearsCache` は落ちない: 消えた時点で手順 1 がキャッシュを空にするので、置き直した後は鍵を比べずとも検証し直す） |
| 25 | `useCache` を無視する | `useCacheFalseVerifiesAgain` |
| 26 | `DeviceWritability.observe` で readOnly nil を `.writable` にする | `writabilityObservesSnapshot`、`allReleasedNeedsBoth` |
| 27 | LockDisplay で devices `[]` を `観測=不明` にする | `defaultLines` |
| 28 | `ReaperSignature.requirement` の `.reaper` を消す | `requirementIsVerbatim` |
| 29 | CodeSignatureVerifier の `SecStaticCodeCheckValidity` の結果を見ずに真を返す | `wrongRequirementFails`、`unsignedFileFails` |
| 30 | `AppIdentity.teamID` を 1 文字変える | `matchesIdentityEnv`、`productionRequirementIsVerbatim` |
| 31 | textIsPreserved の `frontmatterKeys(…).contains(…)` の項を消す | `frontmatterKeysAloneBlocksWhenExpectedIsEmpty`、`formulaShapeIsFixed(textIsPreserved)` |
| 32 | deletionIsIdentified の `sameKey(c.part.sessionKey, c.session.sessionKey)` を消す | `partFromAnotherSessionIsNotIdentified`、`formulaShapeIsFixed(deletionIsIdentified)` |
| 33 | skipReasonIsBacked の `sameKey(twin.part.sessionKey, twin.session.sessionKey)` を消す | `twinSessionMismatchIsNotBacked`、`formulaShapeIsFixed(skipReasonIsBacked)` |
| 34 | reaperStatus の手順 1 の `cache = nil` を消す | `cacheIsClearedWhenReaperDisappears` |
| 35 | skipReasonIsBacked の無音の分岐に `c.part.transcriptPath != nil &&` を足す（列で門前払い） | `nd06NoSpeechKeptWhileLockBIsClosed`、`formulaShapeIsFixed(skipReasonIsBacked)` |

## 8. 受け入れ条件

- [ ] §3 のファイルがすべて在り、公開宣言が §4 と 00-api-map §11（と §11 の提案）に一致する
- [ ] `DeletionFormulaTests` が通り、式の 5 つの関数の本体が §4.7.1 のトークン列と一致する
- [ ] `reaperConf`・`reaperExecutable` の語が VDPipeline では `LockEvaluator.swift`・`ReaperRunner.swift` にしか無い（PT-11。`LockObserving.swift` の欄は `confState`）。`VolumeHandle(` が Sources に無い（PT-22）
- [ ] 層 A の ND（ND-01〜09・21・22・23・26・31・32・36・41・45）の `[A]` のテストがあり、正の対照が真
- [ ] `make test` が通る（`SignatureVerifierTests` は CI の macOS でも走る）
- [ ] 破壊による証明の 35 項目で表のテストが落ちることを確かめ、PR 本文に貼った
- [ ] `AppIdentity` の値が identity.env と一致し、Bootstrap が `ReaperSignature.production` と `locks.observeReaperConf()` を渡している

## 9. SPEC の変更

なし（reason 語は付録 A.4 の既存の語だけを使う。ND の ID と層は付録 B.1 のまま。ND の集合の一致は T-39 が有効にする）。

## 10. マージ後にやること

- 00-api-map §11・§15 を §11 の提案どおりに直す（同じ PR で直せなかった分）
- T-38 は `LockEvaluator.reaper` に `run()` を足し、`DeletionScene` を使って要求・回収のテストを書く
- T-38 は reaper を起動する直前に `observe(config:snapshot:useCache: false)`（または `readiness(config:useCache: false)`）で署名と版を検証し直すことを確かめる（キャッシュの鍵は (inode, size, mtime) で ctime を含まない。§11 の記録 4）

## 11. API 地図への変更提案

1. `SignatureVerifier.swift`・`LockEvaluator.swift` の置き場所は地図どおり。T-18 は ConfigStore に `observeReaperConf` のクロージャを注入する形にした（T-18 §11 の 1）ので、**T-18 は LockEvaluator の骨組みを置かない**。T-36 が新規に作り、Bootstrap の `{ .missing }` を `{ await locks.observeReaperConf() }` に替える
2. `LockEvaluator.init(layout:verifier:runner:)` → `init(layout:verifier:runner:log:)`（署名・版の不一致の `reaper_failed` を検証したときだけ出すため）。`public nonisolated let reaper: ReaperRunner` を持たせる。**`observe(config:snapshot:)` と `reaperStatus()` は `LockObserving`（T-32）の要件**なのでラベルは地図のまま。キャッシュを使わない `observe(config:snapshot:useCache:)`・`reaperStatus(useCache:)` を多重定義で足す（T-38 の起動直前と本チケットのテストが使う。地図 §11 の `LockEvaluator` の行にこの 2 つの多重定義も載せることを提案する）
3. `LockObservation`（readiness・snapshot・volumesRoot・confState。`allReleased(for:)` の式はここに 1 つ）・`ReaperStatus`・`DeviceWritability.observe(deviceID:snapshot:)` は **T-32 の `LockObserving.swift`** に置く（Phase 7 の診断が Phase 8 に依存しないため） → 地図 §11 に反映済み
4. `WorkerDependencies` から `reaper: ReaperRunner` を外す（`locks.reaper` を使う。署名検証の実装を 1 つにする）。T-36 は末尾に `locks`・`volumeOpener` を足す
5. 事前確認のボリュームの親（volumesRoot）は **reaper.conf の VOLUMES_ROOT**（`LockObservation.volumesRoot`）から取る（reaper が開くのと同じ場所。WorkerDependencies に volumesRoot を足さない。食い違えば事前確認が偽になる = 消さない側）
6. `DeletionPolicy` の引数を確定: `canDeleteSource(_ c: DeletionCandidate, _ ctx: DeletionContext)`、`textIsPreserved(_ part:_ session:_ parts:_ ctx:)`、`preIdentityCheck(_ part:_ ctx:)`、`verifyRawNote(…) -> RawNoteVerdict`、`frontmatterKeys(_:_:) -> [String]`、`partTranscriptIsValid(_:_:)`。`DeletionCandidate`・`TwinPart`（`load`）・`DeletionContext`（config・locks・layout・volumeOpener）・`RawNoteVerdict` を地図に載せる
7. `ReaperRunner` は T-36 が検証の部分（`installation()`・`signatureIsValid()`・`runVersion()`・`versionMatches()`、`ReaperInstallation`・`ReaperFileKey`）を作り、T-38 が `run()` を足す
8. `ReaperSignature.production`（`AppIdentity` から）と `VDCore/AppIdentity.swift`（`bundleID`・`teamID`・`reaperIdentifier`）を足す。os.Logger の subsystem も `AppIdentity.bundleID`
9. `DeletionReason`（VDPipeline。削除の経路の reason 語と後追いの対象外の語）を足す
10. `LockDisplay`（`lines` の逐語は T-32 §4.11）は **T-32** が `LockObserving.swift` に作る。T-40 のパネルと DR-14 はこれを表示する。**PT-11 のため欄の名前は `confState`**（`reaperConf` ではない）。T-40 §4 の `display.reaperConf` の参照も `display.confState` に直す必要がある（T-40 の担当へ）
11. §15 に `DeletionScene`・`StorePaths`・`ScriptedProcessRunner.version(_:)`（作り手 T-36、使う T-38・T-39・T-41）を足す。`FakeSignatureVerifier` は `final class`（`setValid(_:)`・`verifiedURLs`）

### 記録（レビューで見つけ、このチケットでは直さないもの）

1. `LockEvaluator.observe(config:snapshot:useCache:)` は reaper.conf を 2 回読む（`readiness` の手順 2 と、`volumesRoot`・`confState` を作る手順 2）。2 回の間に書き換わると、readiness と volumesRoot が別の版の reaper.conf から来うる。どちらの版でも食い違えば事前確認が偽になる側（消さない側）に倒れるので直さない
2. `DeletionPolicy.preIdentityCheck` の手順 4 の `ctx.snapshot?.devices[part.deviceID]` は Swift の辞書の引き当てなので、device_id を正準等価で比べる（relpath はスカラー列で比べている）。device_id はボリューム名で、正規化の違う 2 台が同時につながる状況は想定しないので直さない
3. T-07 の `TargetIdentity.openVolume` の `mnton != path` は Swift の String の比較（正準等価）で、コメントの「バイト列の完全一致」と食い違う。T-07 の担当で確かめる
4. 署名と版のキャッシュの鍵は (inode, size, mtime) で ctime を含まない。同じ inode のまま中身を書き換えて mtime を戻すと、キャッシュが古い検証結果を返しうる。reaper を起動する直前は `useCache: false` にすることで防ぐ（T-38 で確かめる。§10）
