# T-41 後追い: 過去分を削除対象にする・手動で消した分を完了にする（プレビューと実行の 2 段）

| 項目 | 値 |
|---|---|
| ID | T-41 |
| Phase | 8（削除） |
| 前提 | T-38（`DeletionDependencies`・`RequestWriter`・`DeleteQueue`・全件回収・`ScriptedIngest`・`DeletionScene+Steps`）、**T-30（`AppModel`・`Strings`）、T-32（`WorkerJob`・`enqueue`・`stagePendingJobs`・`DetailsSection`）**（README の索引と一致）。間接に T-36（`DeletionPolicy`・`DeletionReason`・`DeletionScene`） |
| 見積もり | Sources 約 350 行（VDPipeline 約 220・VoiceDockApp 約 130）、Tests 約 450 行 |
| 後続 | T-42（実機 E2E で過去分を消す） |

## 1. 目的

削除 OFF の期間に COMPLETED で終わった Part と、利用者が手で消した SOURCE_DELETE_PENDING の Part を、パネルの「詳細」から後で片付けられるようにする（voicedock の `cleanup --backlog` / `--resolve-absent`）。
**どちらも先にプレビュー（件数と、対象外の件数と理由）を出し、もう一度押して実行する**。判定は削除条件の式（`DeletionPolicy.canDeleteSource`）をそのまま使い、2 本目の式を作らない。
実行は Worker の直列ループに 1 件の仕事として入れる（whisper・LLM・削除の段と重ならない）。

## 2. 参照

- PLAN §8.9.9（全体）、§8.9.1（式）、§8.9.6（全件回収: 後追いで SOURCE_DELETING にした Part も回収される）、§8.12（パネルの「詳細」）、§5.4（pendingJobs の段）、付録 A.2（`COMPLETED→SOURCE_DELETING`・`SOURCE_DELETE_PENDING→SOURCE_DELETING→COMPLETED`）、付録 A.4（`source_delete_skipped reason=already_absent|status_changed`）
- 00-api-map §11（`BacklogPlanner.swift`・`WorkerJob`）、§12（`AppModel`・`Panel/DetailsSection`）
- voicedock@d3d595e: `src/voicedock/backlog.py:48-73`（`plan_backlog`）、`:74-91`（`plan_absent`）、`:92-134`（`run`・`_render`）、`:135-187`（`_request_deletions`）、`:188-238`（`_mark_absent`）、
  `tests/unit/test_backlog.py:121-340`
- 移植メモ V3 §6.8（voicedock の欠陥: 後追いで SOURCE_DELETING にした Part が二度と回収されなかった → 本アプリは全件回収で拾う）

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/VDPipeline/BacklogPlanner.swift` | `BacklogKind`・`BacklogSkip`・`BacklogPlan`・`BacklogExecution`・`BacklogFailure`・`BacklogAction`（public）、`BacklogPlanner`（internal） |
| `Sources/VDPipeline/Worker.swift`（変更） | `WorkerJob` に `.backlog(BacklogAction)`・`.resolveAbsent(BacklogAction)` を足す |
| `Sources/VDPipeline/Worker+Jobs.swift`（変更） | 仕事の振り分けに 2 つの case を足す。`replyUnavailable`・`replyStopped` にも 2 つの case を足す（§4.2） |
| `Sources/VoiceDockApp/Panel/BacklogTexts.swift` | 文言（逐語）と整形 |
| `Sources/VoiceDockApp/Panel/BacklogControls.swift` | 2 つのボタンとプレビュー・実行・結果の表示（SwiftUI） |
| `Sources/VoiceDockApp/Panel/DetailsSection.swift`（変更） | `BacklogControls` を足す |
| `Sources/VoiceDockApp/AppModel.swift`（変更） | `backlogState`・`backlogExecuting` と 3 つの操作 |
| `Tests/VDPipelineTests/BacklogPlannerTests.swift` | |
| `Tests/VDPipelineTests/BacklogJobTests.swift` | Worker の仕事として回す |
| `Tests/VoiceDockAppTests/BacklogTextsTests.swift` | 文言 |
| `Tests/VoiceDockAppTests/AppModelBacklogTests.swift` | AppModel の `backlogState` の遷移 |
| `Tests/VoiceDockAppTests/AppModelDiagnosticsTests.swift`（変更） | `WorkerJob` の `switch` 4 か所に `case .backlog, .resolveAbsent: Issue.record("DR-09 の仕事ではない")` を足す（case が増えて網羅でなくなるため。T-32 のテストの中身は変えない） |

## 4. 仕様

共通は T-38 §4 と同じ（鍵の照合は `DeletionPolicy.sameKey`、reason 語は `DeletionReason`）。

### 4.1 `BacklogPlanner.swift`

```swift
// 後追い（PLAN §8.9.9。voicedock backlog.py）。判定は DeletionPolicy.canDeleteSource をそのまま使う（式を 2 本にしない）。
// 2 つの操作をまとめない: 「過去分」は「消してよい」、「手動で消した分」は「もう無い」を言う（不在のファイルは同定できない）。
import VDContract
import VDCore
import VDDevice
import VDStore

public enum BacklogKind: String, Sendable, Equatable {
    case backlog          // 過去分を削除対象にする
    case resolveAbsent    // 手動で消した分を完了にする
}

public struct BacklogSkip: Equatable, Sendable {
    public let partkey: String
    public let reason: String      // DeletionReason.alreadyDeleted / notDeletable / deviceAbsent / stillPresent
    public init(partkey: String, reason: String)
}

public struct BacklogPlan: Equatable, Sendable {
    public let eligible: [String]
    public let skipped: [BacklogSkip]
    public init(eligible: [String], skipped: [BacklogSkip])
}

public struct BacklogExecution: Equatable, Sendable {
    public let plan: BacklogPlan   // 実行の直前に立て直した計画
    public let done: Int
    public init(plan: BacklogPlan, done: Int)
}

public struct BacklogFailure: Error, Equatable, Sendable {
    public let message: String
    public init(message: String)
}

/// パネルからの 1 件の仕事（Worker の直列ループで実行する）。reply は Worker の文脈で 1 回だけ呼ばれる。
public enum BacklogAction: Sendable {
    case preview(reply: @Sendable (Result<BacklogPlan, BacklogFailure>) -> Void)
    case execute(reply: @Sendable (Result<BacklogExecution, BacklogFailure>) -> Void)
}

struct BacklogPlanner {
    let deps: DeletionDependencies
    func planBacklog() async throws -> BacklogPlan
    func planResolveAbsent() async throws -> BacklogPlan
    /// 計画の eligible を 1 件ずつ実行する。実行した数
    func executeBacklog(_ plan: BacklogPlan) async throws -> Int
    func executeResolveAbsent(_ plan: BacklogPlan) async throws -> Int
    /// 仕事を実行して reply を 1 回呼ぶ。実行は計画を立て直してから（プレビューの後に状態が変わりうる）
    func handle(_ action: BacklogAction, kind: BacklogKind) async
}
```

**`planBacklog()`**（逐語。voicedock backlog.py:48-73 ＋ 本計画の差分）:
```text
snapshot = await deps.freshSnapshot()                                  // 新鮮でなければ nil（→ 式が偽 = not_deletable）
ctx = await deps.context(snapshot: snapshot)
eligible = []; skipped = []
for session in store.sessions(status: .completed):                      // session_key 順
    parts = store.recordings(inSession: session.sessionKey)
    for part in parts where part.status == .completed || part.status == .sourceDeletePending:
        if part.sourceDeletedAt != nil:        skipped.append(BacklogSkip(part.partkey, DeletionReason.alreadyDeleted))
        else if part.deleteRequestID != nil:   skipped.append(BacklogSkip(part.partkey, DeletionReason.notDeletable))   // 結果待ち（復旧の PENDING は ID を持ったまま。二重に要求しない）
        else if DeletionPolicy.canDeleteSource(DeletionCandidate(part: part, session: session, parts: parts, twin: nil), ctx):
                                               eligible.append(part.partkey)
        else:                                  skipped.append(BacklogSkip(part.partkey, DeletionReason.notDeletable))
return BacklogPlan(eligible, skipped)
```

**`executeBacklog(plan)`**（逐語。voicedock backlog.py:135-187）:
```text
snapshot = await deps.freshSnapshot(); ctx = await deps.context(snapshot: snapshot); done = 0
for pk in plan.eligible:
  do {                                                                                                          // DEL-19: 1 件ごとに捕捉して残りを続ける（DeletionRequester と同じ形）
    guard let part = store.recording(pk), part.status == .completed || part.status == .sourceDeletePending,
          part.deleteRequestID == nil, part.sourceDeletedAt == nil,
          let key = part.sessionKey, let session = store.session(key) else { deps.logStatusChanged(recordingKey: pk); continue }     // 計画の後に状態が変わった（DEL-19）
    parts = store.recordings(inSession: key)
    guard DeletionPolicy.canDeleteSource(DeletionCandidate(part: part, session: session, parts: parts, twin: nil), ctx) else continue   // 式が偽になった（ログなし。voicedock と同じ）
    guard let id = RequestWriter(deps).write(part: part, sessionKey: key) else continue                        // ①ID → ②要求ファイル
    recordPartTransition(pk, from: part.status, to: .sourceDeleting)                                            // ③ COMPLETED か SOURCE_DELETE_PENDING から
    log.info(.deleteRequested, [(.requestID, id), (.recordingKey, pk), (.sessionKey, key)])
    done += 1
  } catch is TransitionConflict { deps.logStatusChanged(recordingKey: pk); continue }
    catch { deps.warn(error); continue }                                                                        // Store の予期しない例外も 1 件で止めない（途中まで書いた数を失わない）
return done
```
- 回収は T-38 の全件回収が拾う（Session が COMPLETED でも。voicedock では二度と回収されなかった）

**`planResolveAbsent()`**（逐語。voicedock backlog.py:74-91 ＋ 本計画の差分: 未接続を「無い」と判定しない）:
```text
snapshot = await deps.freshSnapshot()
for part in store.recordings(status: .sourceDeletePending):            // started_at, partkey 順
    guard let s = snapshot, let obs = s.devices[part.deviceID] else { skipped (device_absent); continue }   // デバイスが無い・snapshot が古い
    guard let rel = part.sourcePath, !obs.relpaths.contains(where: { sameKey($0, rel) }) else { skipped (still_present); continue }   // 在る（source_path が無いものも「無い」と確かめられない）
    eligible.append(part.partkey)
```

**`executeResolveAbsent(plan)`**（逐語。voicedock backlog.py:188-238）:
```text
snapshot = await deps.freshSnapshot(); done = 0
for pk in plan.eligible:
  do {                                                                                                          // DEL-19: 1 件ごとに捕捉して残りを続ける
    guard let part = store.recording(pk), part.status == .sourceDeletePending else { deps.logStatusChanged(recordingKey: pk); continue }   // DEL-19
    guard let s = snapshot, let obs = s.devices[part.deviceID], let rel = part.sourcePath,
          !obs.relpaths.contains(where: { sameKey($0, rel) }) else continue          // 実行の時点で「無い」を確かめ直す（デバイスが消えた・snapshot が古い・在るなら完了にしない）
    recordPartTransition(pk, from: .sourceDeletePending, to: .sourceDeleting, detail: DeletionReason.resolveAbsentDetail)
    recordPartTransition(pk, from: .sourceDeleting, to: .completed, detail: DeletionReason.alreadyAbsent)
    DeleteQueue.withdrawRequests(partkey: pk, layout); DeleteQueue.withdrawResults(partkey: pk, layout)      // 対応する試行の無い要求・結果を残さない（#160）
    store.updateRecording(pk, [.deleteRequestID(nil)])
    log.info(.sourceDeleteSkipped, [(.recordingKey, pk), (.reason, DeletionReason.alreadyAbsent)])
    done += 1
  } catch is TransitionConflict { deps.logStatusChanged(recordingKey: pk); continue }
    catch { deps.warn(error); continue }
return done
```
- **`source_deleted_at` を入れない**（VoiceDock が消したのではない。不可逆操作の記録に嘘を混ぜない。PLAN §8.9.9）
- 直通の辺を足さない（付録 A.2 の 2 遷移で行う）

**`handle(action, kind)`**:
```text
switch action:
case .preview(let reply):
    do { reply(.success(kind == .backlog ? try await planBacklog() : try await planResolveAbsent())) }
    catch { reply(.failure(BacklogFailure(message: ErrorText.describe(error)))) }
case .execute(let reply):
    do {
        plan = kind == .backlog ? try await planBacklog() : try await planResolveAbsent()
        done = plan.eligible.isEmpty ? 0 : (kind == .backlog ? try await executeBacklog(plan) : try await executeResolveAbsent(plan))
        reply(.success(BacklogExecution(plan: plan, done: done)))
    } catch { reply(.failure(BacklogFailure(message: ErrorText.describe(error)))) }
```
- プレビューは**何も書かない**（DB・queue・ログ。`--dry-run` と同じ）
- 実行は計画を立て直す（プレビューの後に状態が変わりうる。実行した計画は結果に載せてパネルに出す）

### 4.2 `WorkerJob` と振り分け（T-32 の宣言・段への追加）

`Worker.swift` の `public enum WorkerJob: Sendable`（T-32）に 2 つの case を足す（00-api-map §11 の形）:
```swift
    case backlog(BacklogAction)
    case resolveAbsent(BacklogAction)
```
`Worker+Jobs.swift` の仕事を 1 件ずつ実行する `switch`（T-32 の `stagePendingJobs`）に足す:
```swift
    case .backlog(let action):
        // 停止要求が来ていれば実行せずに失敗で返す（.llmProbe と同じ。PLAN §5.4）
        if ctx.stop.isSet {
            Self.replyStopped(job)
            continue
        }
        await BacklogPlanner(deps: DeletionDependencies(ctx: ctx)).handle(action, kind: .backlog)
    case .resolveAbsent(let action):
        if ctx.stop.isSet {
            Self.replyStopped(job)
            continue
        }
        await BacklogPlanner(deps: DeletionDependencies(ctx: ctx)).handle(action, kind: .resolveAbsent)
```
（pendingJobs の段は snapshot の新鮮さによらず毎 tick 行う。新鮮でなければ計画は not_deletable / device_absent になるだけ）

同じファイルの `replyUnavailable`（設定エラー中の tick）と `replyStopped`（停止要求の後）にも足す。文言は DR-09 と同じ定数を使う（CR-06）:
```swift
        case .backlog(let action), .resolveAbsent(let action): replyFailure(action, DiagnosticTexts.configMissing)   // replyUnavailable
        case .backlog(let action), .resolveAbsent(let action): replyFailure(action, DiagnosticTexts.probeStopped)    // replyStopped

    /// 後追いの仕事を実行せずに失敗で返事をする（設定エラー中・停止要求の後。文言は DR-09 と同じ）
    static func replyFailure(_ action: BacklogAction, _ message: String) {
        switch action {
        case .preview(let reply): reply(.failure(BacklogFailure(message: message)))
        case .execute(let reply): reply(.failure(BacklogFailure(message: message)))
        }
    }
```
（返事は必ず返す。返さないとパネルが「対象を調べています…」のまま固まる。T-32 §4 の `llmProbe` と同じ約束）

### 4.3 `BacklogTexts.swift`（VoiceDockApp。文言は逐語）

```swift
// 後追いの 2 つのボタンの文言と整形（PLAN §8.9.9）。
import VDPipeline

enum BacklogTexts {
    static let working = "対象を調べています…"
    static let executing = "実行しています…"
    static let cancel = "やめる"
    static let close = "閉じる"
    static let nothing = "対象はありません"
    static let resolveAbsentNote = "デバイスに無いことを確かめた録音だけを完了にします（削除した記録は付けません）"
    /// 対象外の理由の並び（この順に出す）
    static let reasonOrder = [DeletionReason.alreadyDeleted, DeletionReason.notDeletable, DeletionReason.deviceAbsent, DeletionReason.stillPresent]

    static func buttonTitle(_ kind: BacklogKind) -> String      // backlog: "過去分を削除対象にする"、resolveAbsent: "手動で消した分を完了にする"
    static func reasonLabel(_ reason: String) -> String         // 下の表（キーは DeletionReason の定数で書く。語を再掲しない。CR-06）。表に無い語はそのまま
    static func previewLines(_ kind: BacklogKind, _ plan: BacklogPlan) -> [String]
    static func executeTitle(_ kind: BacklogKind, count: Int) -> String   // backlog: "削除要求を書く（<n> 件）"、resolveAbsent: "完了にする（<n> 件）"
    static func resultLine(_ kind: BacklogKind, _ execution: BacklogExecution) -> String
    static func failureLine(_ message: String) -> String       // "実行できませんでした: " + message
}
```

| reason | 表示 |
|---|---|
| `already_deleted` | `削除済み` |
| `not_deletable` | `削除の条件を満たさない` |
| `device_absent` | `デバイスが未接続か観測が古い` |
| `still_present` | `デバイスにまだ在る` |

`previewLines(kind, plan)`（`n = plan.eligible.count`、`m = plan.skipped.count`。数は `String(n)`）:
1. `kind == .backlog` → `"削除要求を書く対象: " + n + " 件"`、`.resolveAbsent` → `"完了にする対象: " + n + " 件"`
2. `n == 0` なら `nothing`
3. `m > 0` なら `"対象外: " + m + " 件"`、続けて `reasonOrder` の順に件数が 1 以上の理由ごとに `"・" + reasonLabel(r) + ": " + 件数 + " 件"`、その後に `reasonOrder` に無い理由を最初に現れた順に同じ形で
4. `kind == .resolveAbsent && n > 0` なら `resolveAbsentNote`

`resultLine(kind, e)`: `.backlog` → `String(e.done) + " 件の削除要求を書きました"`、`.resolveAbsent` → `String(e.done) + " 件を完了にしました"`。
`e.done < e.plan.eligible.count` なら後ろに `"（" + String(e.plan.eligible.count - e.done) + " 件は状態が変わったため飛ばしました）"`。

### 4.4 `AppModel.swift`（T-30 のファイルへの追加）

```swift
enum BacklogPanelState: Equatable {
    case idle
    case working(BacklogKind)                     // 計画・実行の返事を待っている
    case preview(BacklogKind, BacklogPlan)
    case done(BacklogKind, BacklogExecution)
    case failed(BacklogKind, String)
}

// AppModel に足す（T-40 の欄の後。書くのは同じファイルの extension だけ）
private(set) var backlogState: BacklogPanelState = .idle
/// working が実行の返事を待っているか（preview から入ったら真。「実行しています…」を出す）
private(set) var backlogExecuting = false
/// 1 回目の押下。working にして preview の仕事を入れる（working 中は何もしない）
func previewBacklog(_ kind: BacklogKind)
/// 2 回目の押下（preview の状態からだけ）。working にして execute の仕事を入れる
func executeBacklog(_ kind: BacklogKind)
/// やめる・閉じる。idle に戻す
func dismissBacklog()
```
- 仕事は `Task { await services.enqueue(.backlog(.preview(reply: { [weak self] result in Task { @MainActor in self?.receive(kind, result) } }))) }`（resolveAbsent は `.resolveAbsent(…)`。AppModel は Worker を直接持たず、T-32 の `AppServices.enqueue(_:)` を通す）。reply は Worker の文脈で呼ばれるので MainActor へ移してから状態を変える
- `previewBacklog` は `backlogExecuting = false`、`executeBacklog` は `backlogExecuting = true` にしてから `.working(kind)` に入れる。`dismissBacklog` は `false` に戻す
- `receive`: `.success(plan)` → `.preview(kind, plan)`、`.success(execution)` → `.done(kind, execution)`、`.failure(f)` → `.failed(kind, f.message)`
- 返事が来る前に `dismissBacklog()` されたら、届いた返事は捨てる（`backlogState` が `.working(kind)` のときだけ受け取る）
- 世代の番号は持たない。`.working` の間は「やめる」「閉じる」のボタンが出ない（§4.5）ので、返事を待っている間に `dismissBacklog()` が呼ばれて押し直され、古い返事を新しい押下の返事として受け取ることは起きない。将来 `dismissBacklog()` を他から呼ぶ（パネルを閉じたときなど）なら、DR-09 の `probeGeneration` と同じ世代が要る

### 4.5 `BacklogControls.swift` と `DetailsSection.swift`

`BacklogControls(model: AppModel)`（SwiftUI の `View`）:
- `idle`・`done`・`failed` のとき: 2 つのボタン（`buttonTitle(.backlog)`・`buttonTitle(.resolveAbsent)`）。押すと `previewBacklog(kind)`
- `working`: `ProgressView()` と、直前の押下が preview なら `working`、execute なら `executing` の文言（どちらかは AppModel が `working` に入れる前の状態で決め、`backlogExecuting` に持つ。`preview` からなら `executing`）
- `preview(kind, plan)`: `previewLines` を 1 行ずつ `Text`。`plan.eligible` が空でなければ `executeTitle(kind, count:)` のボタン（押すと `executeBacklog(kind)`）。`cancel` のボタン（`dismissBacklog()`）
- `done(kind, e)`: `resultLine`、`close` のボタン
- `failed(_, message)`: `failureLine(message)`、`close` のボタン
- ボタンは `working` の間は無効（二重に入れない）

`DetailsSection`（T-32）の末尾に `BacklogControls(model: model)` を 1 つ置く（見出しは T-32 の節の中に入れる。新しい画面を作らない。D-7）。
F-65 で「詳細・診断」は popover の中の別の画面になり、`BacklogControls` はその画面の「後追い」（`Strings.sectionBacklog`）のカードの中に置く（ボタンは `.bordered`・`.small`）。

## 5. ログ（このチケットが出すもの）

| イベント | レベル | フィールド（この順） | 出す場所 |
|---|---|---|---|
| `delete_requested` | INFO | `request_id`, `recording_key`, `session_key` | executeBacklog |
| `source_delete_skipped` | INFO | `recording_key`, `reason=already_absent` | executeResolveAbsent |
| `source_delete_skipped` | WARNING | `recording_key`, `reason=status_changed` | 両方の実行（DEL-19） |

## 6. テスト

共通: T-38 §6 と同じ。「過去分の舞台」= `DeletionScene(status: .completed, sessionStatus: .completed)`（Raw ノート・transcript・デバイス上の原本がそろい、三重ロックが外れている）。
「手動で消した分の舞台」= `DeletionScene(status: .sourceDeletePending, errorCode: .sourceIdentityMismatch, sessionStatus: .completed)` に ingest を `snapshot(relpaths: [])`（デバイスは在り、ファイルが無い）。
`planner = BacklogPlanner(deps: scene.deletionDependencies(ingest: ingest))`。表の `(p, r)` は `BacklogSkip(partkey: p, reason: r)` の略。

### 6.1 `Tests/VDPipelineTests/BacklogPlannerTests.swift`（`@Suite("BacklogPlanner")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `planListsCompletedPartsThatPassTheFormula` | 過去分: COMPLETED の Session の COMPLETED の Part で式が真なら対象（TEST-20: 対象 1 件以上で試す） | 過去分の舞台 | `eligible == [pk]`、`skipped == []` |
| `planIncludesPendingParts` | SOURCE_DELETE_PENDING の Part も対象 | `DeletionScene(status: .sourceDeletePending, errorCode: .sourceIdentityMismatch, sessionStatus: .completed)`（ファイル在り） | `eligible == [pk]` |
| `alreadyDeletedIsSkipped` | source_deleted_at が在れば already_deleted | 過去分の舞台、`updateRecording(pk, [.sourceDeletedAt("2026-09-12T10:00:00+09:00")])` | `skipped == [BacklogSkip(partkey: pk, reason: "already_deleted")]` |
| `formulaFalseIsNotDeletable` | 式が偽なら not_deletable（パラメータ化: デバイスに無い・Raw の鍵が無い・ロック 1 が偽） | (a) `snapshot(relpaths: [])` (b) `replaceInRawNote(pk, with: "DJIMIC3/other/other.wav", updateSHA: true)` (c) `deleteSourceAudio = false` | `skipped == [(pk, not_deletable)]` |
| `awaitingResultIsNotDeletable` | 結果待ち（ID が在る）は二重に要求しない | `updateRecording(pk, [.deleteRequestID("20260912T030000Z-8483e42457304a9d-abcdef")])` | `(pk, not_deletable)` |
| `staleSnapshotMakesEverythingNotDeletable` | snapshot が古ければ not_deletable | completedAt = now − 901 秒 | `(pk, not_deletable)` |
| `onlyCompletedSessionsAreConsidered` | COMPLETED でない Session の Part は見ない（パラメータ化: SAVED・SOURCE_DELETING） | `DeletionScene(status: .completed, sessionStatus:)` | `eligible == []`、`skipped == []` |
| `onlyCompletedOrPendingPartsAreConsidered` | 対象の状態は COMPLETED と SOURCE_DELETE_PENDING だけ | 過去分の舞台に 10:00 の SKIPPED(NO_SPEECH) と 11:00 の FAILED(WHISPER_FAILED) の兄弟 | `eligible == [pk]`、`skipped == []`（兄弟は現れない） |
| `emptyDatabasePlansNothing` | COMPLETED の Session が無ければ空（TEST-28） | 既定の舞台（SAVED） | `eligible == []`、`skipped == []` |
| `previewWritesNothing` | TEST-20 プレビューは何も書かない（対象 1 件以上で） | 過去分の舞台、`handle(.preview(reply:), kind: .backlog)`（reply を `Mutex` に記録） | reply が 1 回・`.success` で `eligible == [pk]`、`requests() == []`、Part COMPLETED、events の本数が変わらない、ログが増えない |
| `executeRequestsAndTransitions` | 実行は ID → 要求 → COMPLETED→SOURCE_DELETING | `handle(.execute(reply:), kind: .backlog)` | `.success(BacklogExecution(plan: [pk] の計画, done: 1))`、要求 1 件（partkey と DB の ID が一致）、Part SOURCE_DELETING、最後の events が `COMPLETED→SOURCE_DELETING`、`delete_requested` のログ |
| `executeFromPending` | PENDING からは SOURCE_DELETE_PENDING→SOURCE_DELETING | `planIncludesPendingParts` の舞台で execute | events の最後が `SOURCE_DELETE_PENDING→SOURCE_DELETING` |
| `statusChangeDuringExecutionContinues` | DEL-19 計画の後に状態が変わった Part は status_changed で飛ばし、残りを続ける | 過去分の舞台に 10:00 の COMPLETED の兄弟（デバイスに在り、Raw に載せ `writeRawNote()`。兄弟の relpath を載せるため ingest を `snapshot()` に差し替える）。`plan = planBacklog()`（2 件）→ `store.recordPartTransition(partkey: pk, from: .completed, to: .sourceDeleting)` → `executeBacklog(plan)` | 戻り値 1、兄弟が SOURCE_DELETING で要求が在る、`source_delete_skipped recording_key=<pk> reason=status_changed`（WARNING） |
| `storeErrorDuringExecutionContinues` | DEL-19 途中の 1 件で Store が例外を投げても残りを続ける（config_warning rule=store） | 過去分の舞台に、別の日の Session の Part を足し status 列を読めない値（`BROKEN`）にする（`store.pool` に生の SQL）。`executeBacklog(BacklogPlan(eligible: [broken, pk], skipped: []))` | 戻り値 1、pk が SOURCE_DELETING で要求が在る、`config_warning rule=store`（WARNING） |
| `executedPartsAreCollected` | 後追いで SOURCE_DELETING にした Part も全件回収で完了する（voicedock の欠陥を直した） | execute → DELETED の結果 → ingest を `snapshot(generation: 2, relpaths: [])` → `ResultCollector(deps:).collectDeleteResults(reaperScanGeneration: 2)` | Part COMPLETED、`sourceDeletedAt` 在り（Session は COMPLETED のまま） |
| `resolveAbsentPlansGoneFiles` | 手動で消した分: 新鮮な snapshot にデバイスが在り relpath が無い PENDING が対象 | 手動で消した分の舞台 | `eligible == [pk]` |
| `resolveAbsentNeedsTheDevice` | デバイスが無い・snapshot が古い・無いなら device_absent（パラメータ化。未接続を「無い」と判定しない） | `snapshot(includeDevice: false)` / completedAt = now − 901 秒 / nil | `skipped == [(pk, device_absent)]` |
| `resolveAbsentLeavesPresentFiles` | relpath が在れば still_present | `snapshot()`（ファイル在り） | `(pk, still_present)` |
| `resolveAbsentWithoutSourcePathIsStillPresent` | source_path が無ければ「無い」と確かめられない | `StorePaths.setSourcePath(store, partkey: pk, nil)` | `(pk, still_present)` |
| `resolveAbsentCompletesWithoutDeletionTime` | 実行: 2 遷移で COMPLETED、source_deleted_at を入れず、要求・結果を取り下げ ID を外す | 手動で消した分の舞台、`updateRecording(pk, [.deleteRequestID(id)])`、pk の要求ファイルと結果ファイルを置く、`handle(.execute(reply:), kind: .resolveAbsent)` | `done == 1`、COMPLETED、`sourceDeletedAt == nil`、ID nil、最後の 2 本の events の detail が `resolve_absent`・`already_absent`、`requests() == []`、`results() == []`、`source_delete_skipped recording_key=<pk> reason=already_absent`（INFO） |
| `resolveAbsentStatusChangeContinues` | DEL-19 手動で消した分も状態が変わった Part を飛ばして続ける | PENDING の兄弟（10:00、デバイスに無い）を足す。`plan = planResolveAbsent()`（2 件）→ `store.recordPartTransition(partkey: pk, from: .sourceDeletePending, to: .sourceDeleting)` → `executeResolveAbsent(plan)` | 戻り値 1、兄弟 COMPLETED、`reason=status_changed` |
| `resolveAbsentRechecksAbsence` | 実行の時点で在ることが分かれば完了にしない | `plan = planResolveAbsent()`（1 件）→ ingest を `snapshot()`（ファイル在り）→ `executeResolveAbsent(plan)` | 0、PENDING のまま |
| `resolveAbsentRechecksDeviceAndFreshness` | 実行の時点でデバイスが消えた・snapshot が古くなったなら完了にしない（パラメータ化） | `plan = planResolveAbsent()`（1 件）→ ingest を `snapshot(includeDevice: false)` / `snapshot(relpaths: [], completedAt: now − 901 秒)` → `executeResolveAbsent(plan)` | 0、PENDING のまま |
| `resolveAbsentStoreErrorContinues` | DEL-19 手動で消した分も途中の 1 件で Store が例外を投げても残りを続ける | 手動で消した分の舞台に `storeErrorDuringExecutionContinues` と同じ壊れた Part。`executeResolveAbsent(BacklogPlan(eligible: [broken, pk], skipped: []))` | 戻り値 1、pk COMPLETED、`config_warning rule=store`（WARNING） |
| `emptyPendingPlansNothing` | PENDING が無ければ空（TEST-28） | 過去分の舞台 | `planResolveAbsent()` の eligible・skipped が空 |

### 6.2 `Tests/VDPipelineTests/BacklogJobTests.swift`（`@Suite("後追いの仕事", .serialized)`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `workerRunsBacklogPreviewAsAJob` | Worker の直列ループで 1 件の仕事として実行する | `PipelineWorld`（T-18）、`worker.enqueue(.backlog(.preview(reply:)))`（reply を記録）→ `tick()` | reply が 1 回だけ呼ばれ `.success(BacklogPlan(eligible: [], skipped: []))`（COMPLETED の Session が無い） |
| `workerRunsResolveAbsentAsAJob` | 手動で消した分も同じ | `.resolveAbsent(.preview(reply:))` → tick | 1 回、`.success` |
| `jobRunsOnceAcrossTicks` | 仕事は 1 回だけ実行される | enqueue → tick → tick | reply が 1 回 |
| `stopRequestedRepliesWithFailure` | 停止要求が立っていれば後追いを実行せず、失敗で 1 回返事をする（パラメータ化: 過去分・手動で消した分） | enqueue → 停止を立てた `StopFlag` の ctx で `stagePendingJobs` | reply が 1 回、`.failure(BacklogFailure(message: "終了中のため実行しませんでした"))` |
| `configErrorRepliesWithFailure` | 設定エラー中の tick は後追いに失敗で 1 回返事をする | 設定ファイルを `{` にして load → `.backlog(.preview)` と `.resolveAbsent(.execute)` を enqueue → tick → tick | それぞれ 1 回、`.failure(BacklogFailure(message: "設定が読めていません"))`、`pendingJobs` が空 |
| `requestStopRepliesWithFailure` | 停止要求の前後に入れた後追いにも失敗で 1 回返事をする | `.backlog(.execute)` を enqueue → `requestStop()` → `.resolveAbsent(.preview)` を enqueue → tick | どちらも 1 回、`.failure(BacklogFailure(message: "終了中のため実行しませんでした"))` |

### 6.4 `Tests/VoiceDockAppTests/AppModelBacklogTests.swift`（`@MainActor @Suite("AppModel+Backlog")`）

`FakeServices`（T-30）の `jobs` に入った仕事の reply を手で呼ぶ。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `previewExecuteDone` | 過去分: preview → execute → done の順に移り、閉じると idle | `previewBacklog(.backlog)` → 仕事の reply に `.success(plan)` → `executeBacklog(.backlog)` → reply に `.success(execution)` → `dismissBacklog()` | `.working(.backlog)`（`backlogExecuting` 偽）→ `.preview(.backlog, plan)` → `.working(.backlog)`（真）→ `.done(.backlog, execution)` → `.idle`（偽） |
| `resolveAbsentFailure` | 手動で消した分は resolveAbsent の仕事を入れ、失敗は failed | `previewBacklog(.resolveAbsent)` → reply に `.failure(BacklogFailure(message: "x"))` | 仕事が `.resolveAbsent(.preview)`、`.failed(.resolveAbsent, "x")` |
| `mismatchedRepliesAreDropped` | kind が違う返事と、閉じた後の返事は捨てる | `previewBacklog(.backlog)` → `receive(.resolveAbsent, …)`（計画・実行）→ `dismissBacklog()` → `receive(.backlog, .success(plan))` | `.working(.backlog)` のまま → `.idle` のまま |
| `pressesOutsideTheirStateAreIgnored` | working の間の押下と、preview でないときの実行は何もしない（空の状態から。TEST-28） | idle で `executeBacklog(.backlog)` → `previewBacklog(.backlog)` → `previewBacklog(.resolveAbsent)` | idle のまま → `.working(.backlog)`、仕事は 1 件だけ |

### 6.3 `Tests/VoiceDockAppTests/BacklogTextsTests.swift`（`@Suite("BacklogTexts")`）

期待はすべて §4.3 から手で書く。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `backlogPreviewLines` | 過去分のプレビュー | `BacklogPlan(eligible: ["a", "b"], skipped: [("c", "not_deletable"), ("d", "already_deleted"), ("e", "not_deletable")])` | `["削除要求を書く対象: 2 件", "対象外: 3 件", "・削除済み: 1 件", "・削除の条件を満たさない: 2 件"]` |
| `resolveAbsentPreviewLines` | 手動で消した分のプレビュー（注記つき） | `eligible: ["a"]`、`skipped: [("b", "device_absent"), ("c", "still_present")]` | `["完了にする対象: 1 件", "対象外: 2 件", "・デバイスが未接続か観測が古い: 1 件", "・デバイスにまだ在る: 1 件", "デバイスに無いことを確かめた録音だけを完了にします（削除した記録は付けません）"]` |
| `emptyPreview` | 対象 0 件（TEST-28） | `eligible: []`、`skipped: []` | `["削除要求を書く対象: 0 件", "対象はありません"]` |
| `unknownReasonIsShownAsIs` | 表に無い理由はそのまま最後に | `skipped: [("a", "weird")]` | `["削除要求を書く対象: 0 件", "対象はありません", "対象外: 1 件", "・weird: 1 件"]` |
| `resultLines` | 結果の 1 行（パラメータ化） | (backlog, done 2 / 2) / (backlog, 1 / 3) / (resolveAbsent, 1 / 1) | `"2 件の削除要求を書きました"` / `"1 件の削除要求を書きました（2 件は状態が変わったため飛ばしました）"` / `"1 件を完了にしました"` |
| `titles` | ボタンの文言 | | `"過去分を削除対象にする"`・`"手動で消した分を完了にする"`・`executeTitle(.backlog, count: 3) == "削除要求を書く（3 件）"`・`executeTitle(.resolveAbsent, count: 1) == "完了にする（1 件）"`・`failureLine("x") == "実行できませんでした: x"` |

## 7. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | planBacklog で canDeleteSource を呼ばずに全部を対象にする | `formulaFalseIsNotDeletable`、`staleSnapshotMakesEverythingNotDeletable` |
| 2 | planBacklog の Session の絞り込み（COMPLETED）を消す | `onlyCompletedSessionsAreConsidered` |
| 3 | planBacklog の Part の状態の絞り込みを COMPLETED だけにする（voicedock の形） | `planIncludesPendingParts` |
| 4 | already_deleted の確認を消す | `alreadyDeletedIsSkipped` |
| 5 | 結果待ちの確認を消す | `awaitingResultIsNotDeletable` |
| 6 | handle の preview で execute を呼ぶ | `previewWritesNothing` |
| 7 | executeBacklog の TransitionConflict・状態の確認で残りをやめる（`return`） | `statusChangeDuringExecutionContinues` |
| 8 | executeBacklog で ③ の遷移を省く | `executeRequestsAndTransitions` |
| 9 | planResolveAbsent で「デバイスが snapshot に無い」を対象にする（voicedock の形） | `resolveAbsentNeedsTheDevice` |
| 10 | executeResolveAbsent で source_deleted_at を書く | `resolveAbsentCompletesWithoutDeletionTime` |
| 11 | executeResolveAbsent で結果の取り下げを消す | `resolveAbsentCompletesWithoutDeletionTime` |
| 12 | executeResolveAbsent の実行時の確かめ直しを消す | `resolveAbsentRechecksAbsence` |
| 13 | Worker+Jobs の `.backlog` の case を空にする | `workerRunsBacklogPreviewAsAJob` |
| 14 | BacklogTexts の理由の並びを入れ替える | `backlogPreviewLines` |
| 15 | Worker+Jobs の `.backlog` / `.resolveAbsent` の停止要求の確認を消す | `stopRequestedRepliesWithFailure` |
| 16 | executeBacklog の `catch { deps.warn(error); continue }` を外し、例外を呼び手へ投げる | `storeErrorDuringExecutionContinues` |
| 17 | executeResolveAbsent の同じ捕捉を外す | `resolveAbsentStoreErrorContinues` |
| 18 | executeResolveAbsent の確かめ直しから `let obs = s.devices[…]` を外す（デバイスが無くても完了にする） | `resolveAbsentRechecksDeviceAndFreshness` |
| 19 | executeResolveAbsent の snapshot を `freshSnapshot()` でなく `ingest.latestSnapshot()` にする | `resolveAbsentRechecksDeviceAndFreshness` |

## 8. 受け入れ条件

- [ ] 後追いの判定が `DeletionPolicy.canDeleteSource` だけを使う（BacklogPlanner に削除条件の式を書き直していない）
- [ ] 要求を書くのは `RequestWriter` 経由だけ（PR-09 の「後追い」）
- [ ] プレビューが何も書かないことを対象 1 件以上で確かめた（TEST-20）
- [ ] 手動で消した分の実行が `source_deleted_at` を書かない
- [ ] パネルの「詳細」に 2 つのボタンが在り、プレビュー → 実行の 2 段で動く（手元で .app を起動し、スクリーンショットを PR に貼る。削除 OFF の舞台で「対象はありません」まで）
- [ ] `make test` が通り、破壊による証明の結果が PR 本文にある

## 9. SPEC の変更

なし（reason 語は付録 A.4 の `already_absent`・`status_changed` と PLAN §8.9.9 の対象外の語だけ）。

## 10. マージ後にやること

- T-42 の実機 E2E で、削除 OFF の期間に処理した録音を「過去分を削除対象にする」で消せることを確かめる（【利用者が行う】）
- README（T-43）に 2 つのボタンの使い分け（「消してよい」と「もう無い」）を書く

## 11. API 地図への変更提案

1. README の索引の T-41 の前提に T-30（AppModel）と T-32（`WorkerJob`・`enqueue`・`stagePendingJobs`・`DetailsSection`）を足す → README に反映済み（整合修正 M-7）
2. `BacklogPlan.skipped` を `[(partkey: String, reason: String)]`（タプル。Equatable にできない）から `[BacklogSkip]` にする。`BacklogKind`・`BacklogExecution`・`BacklogFailure` を足す → 00-api-map §11 に反映済み（整合修正 M-3）
3. `BacklogAction` の形を確定: `.preview(reply: @Sendable (Result<BacklogPlan, BacklogFailure>) -> Void)`・`.execute(reply: @Sendable (Result<BacklogExecution, BacklogFailure>) -> Void)`。`WorkerJob` の `.backlog` / `.resolveAbsent` の 2 ケースは T-41 が足す（T-32 は `.llmProbe` だけを宣言する）。**これらの型の定義は本チケット（`Sources/VDPipeline/BacklogPlanner.swift`）に置く** → 00-api-map §11 に反映済み（整合修正 M-3）
4. PLAN §8.9.9 に「結果待ち（`delete_request_id` が在る。復旧で SOURCE_DELETE_PENDING に戻った Part は ID を持ったまま）は `not_deletable`（二重に要求しない）」「`source_path` が無い PENDING は `still_present`（無いと確かめられない）」「実行の時点で計画を立て直す」を足す
5. **（2026-09-22 利用者が承認し、T-41 の PR で地図に反映済み）** 00-api-map §11 の `BacklogFailure` は `public enum BacklogFailure: Error, Equatable, Sendable`（case が書かれていない）だが、本チケットは `public struct BacklogFailure: Error, Equatable, Sendable { public let message: String; public init(message: String) }`（`ErrorText.describe(error)` の 1 行をパネルに出す）。実装は本チケットに合わせた。地図の行を `struct … { message: String }` に直し、`BacklogKind`（`public enum BacklogKind: String, Sendable, Equatable { case backlog, resolveAbsent }`）も同じ行に足す提案（T-41 の実装で発見）
6. （記録。T-32 の既存の動き。別で扱う）ライセンスで止まった tick（`deps.license.allowsProcessing()` が偽）は `pauses.trip(.license)` で戻り、pendingJobs に返事をしない。後追いも DR-09 も、ライセンスが戻るまでパネルが「対象を調べています…」のままになる。設定エラー中と同じく `replyUnavailable` 相当で返すかは T-32 の側で決める
7. （記録）実行は計画を立て直す（§4.1 `handle`）ので、プレビューの後に新しく条件を満たした Part があれば、プレビューで見せた件数より多く実行しうる。実行した計画は結果に載せ（`BacklogExecution.plan`）、結果の 1 行は立て直した計画の件数で出す。プレビューの計画に限るかは PLAN §8.9.9 で決める
