# T-22 VDPipeline: Session の工程（分組・閉じる・再オープン・統合・解析）と LLM のガード

| 項目 | 値 |
|---|---|
| ID | T-22 |
| Phase | 5（LLM） |
| 前提 | T-18（Worker の枠・`SessionSteps` の骨組み・`TickContext`・`InProcessRetry`・`PauseBook`・`FakeIngest`）、T-20（`Analyzer`）、T-21（`LlamaServerSupervisor`・`LlamaServerHandle`・`LoopbackChatTransport`）。間接に T-19（`FakeChatTransport`・`AnalysisSchema`・`AnalysisValidator`・`Prompts`） |
| 見積もり | Sources 約 650 行、Tests 約 1,300 行 |

## 1. 目的

T-18 が置いた `SessionSteps` の骨組みに本体を書く: Part の分組、OPEN を閉じる、再オープン（★削除段から 3 辺）、統合（`SessionTranscript`）、`ensureMerged`、
`ensureAnalysis`（解析の再利用 ★`MERGED→ANALYZED`、古い解析の検出 ★`ANALYZED→ANALYZING`・★`WRITING→ANALYZING`、書き込みの順、指紋）、
`processReadySessions` と llama-server の停止、解析の前のガード。Daily ノート（`ensureDailyNote`）と Timeline の保存は T-29、Session の削除段は T-38 が書く（ここでは空の口を置く）。

## 2. 参照

- PLAN §5.1（集合）、§5.4（processReadySessions・ガード）、§5.6（全体）、§8.5（ガード・成功時の書き込み・指紋）、付録 A.2 の ★ 6 辺、付録 A.4
- voicedock@d3d595e: `src/voicedock/session.py:60-423`、`src/voicedock/pipeline.py:551-590, 637-666, 1103-1227, 1402-1468`、`src/voicedock/worker.py:326-340, 391-412`、
  `tests/unit/test_session_group.py`、`test_session_reopen.py`、`test_session_resume.py`、`test_session_analysis.py`
- 移植メモ V3 §3.5、§4、§5.1〜§5.3、§9

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/VDPipeline/SessionSteps.swift`（本体を書き換える） | `groupNewParts`・`closeIdleSessions`・`reopenSession`・`process(sessionKey:)`・`failSession` |
| `Sources/VDPipeline/SessionSteps+Merge.swift` | `buildSessionTranscript`・`ensureMerged`・`readTranscript` |
| `Sources/VDPipeline/SessionSteps+Analysis.swift` | `ensureAnalysis`・`loadAnalysis`・`reusableAnalysis`・`sourceData` |
| `Sources/VDPipeline/SessionSteps+Timeline.swift` | `saveTimeline`（**空。T-29 が書く**） |
| `Sources/VDPipeline/SessionSteps+Daily.swift` | `ensureDailyNote`（**偽を返すだけ。T-29 が書く**） |
| `Sources/VDPipeline/SessionSteps+Deletion.swift` | `deleteSourcesIfSafe`（**空。T-38 が書く**） |
| `Sources/VDPipeline/LLMGuard.swift` | `LLMGuard`・`LLMTarget`（internal） |
| `Sources/VDPipeline/LLMServerControl.swift` | `LLMServerControl`・`ChatTransportFactory`・`extension LlamaServerSupervisor: LLMServerControl` |
| `Sources/VDPipeline/WorkerDependencies.swift`（変更） | 3 フィールドを足す |
| `Sources/VDPipeline/Worker+SessionStages.swift`（本体を書く） | `stageProcessReadySessions` |
| ~~`Sources/VDCore/ModelFiles.swift`~~ | **T-09 が作る**（00-api-map §2.2・T-09 §7.1）。このチケットでは作らず、使うだけ |
| `Tests/TestSupport/FakeLLMServer.swift` | `FakeLLMServer`（actor） |
| `Tests/VDPipelineTests/PipelineFixtures.swift`（変更） | LLM の部品を足す |
| `Tests/VDPipelineTests/SessionGroupTests.swift` ほか 7 本（`ModelFilesTests` は T-09） | §6 |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 7 キーを消す |

## 4. 仕様

共通: `store = ctx.deps.store`、`cfg = ctx.config`、`zone = ctx.zone`、`log = ctx.deps.log`、`layout = ctx.deps.layout`。
例外は各関数の中で捕まえる: `TransitionConflict` は「何も書かずに偽・次へ」、それ以外は `ctx.warnStore(e)` を出して偽（T-18 §4.7）。

### 4.1 `LLMServerControl.swift` と `WorkerDependencies` の追加

```swift
// Worker が llama-server に求めるもの（テストで FakeLLMServer に差し替える）。本番は LlamaServerSupervisor（T-21）。
import Foundation
import VDCore
import VDLLM

public protocol LLMServerControl: Sendable {
    func ensureRunning(model: URL, modelID: String, config: LLMConfig) async -> Result<LlamaServerHandle, StageFailure>
    func stop() async
}
extension LlamaServerSupervisor: LLMServerControl {}

/// 起動した llama-server への ChatTransport を作る。本番は
/// `{ h, c in LoopbackChatTransport(endpoint: h.endpoint, apiKey: h.apiKey, modelID: h.modelID, config: c, factory: EphemeralSessionFactory()) }`（Bootstrap が渡す）。
public typealias ChatTransportFactory = @Sendable (LlamaServerHandle, LLMConfig) -> any ChatTransport
```

`WorkerDependencies` に足す（並びは 00-api-map §11 の相対順が正。`llama`・`chatTransportFactory` は `runner` の後に挿し、`physicalMemoryBytes` は `catalog` の後に置く。init の引数も同じ順）:
```swift
    public let llama: any LLMServerControl
    public let chatTransportFactory: ChatTransportFactory
    /// ProcessInfo.processInfo.physicalMemory（Bootstrap が注入。ガードのテストで差し替える）
    public let physicalMemoryBytes: UInt64
```

### 4.2 `ModelFiles.swift`（VDCore。**T-09 §7.1 が作る。ここは参照のみ**）

```swift
// モデルファイルの置き場所と在否（PLAN §8.10。VDPipeline のガードと診断が使う。VDModels に依存しない）。
import Darwin
import Foundation
import VDContract

public enum ModelFiles {
    /// models/<kind>/<entry.file>
    public static func url(kind: ModelKind, entry: ModelEntry, layout: HomeLayout) -> URL
    /// custom:<sha256> なら models/llm/custom-<sha256 の先頭 16>.gguf。形が違えば nil。
    public static func customLLMURL(id: String, layout: HomeLayout) -> URL?
    /// stat（symlink を辿る）が成功し S_ISREG で st_size == entry.bytes。
    public static func isPresent(_ e: ModelEntry, kind: ModelKind, layout: HomeLayout) -> Bool
}
```
- `url` = `layout.modelFile(kind: kind.rawValue, file: entry.file)`
- `customLLMURL` = `CustomModelID.sha256(of: id).map { layout.modelFile(kind: ModelKind.llm.rawValue, file: CustomModelID.fileName(sha256: $0)) }`

### 4.3 `LLMGuard.swift`（PLAN §5.4・§8.5「解析の前のガード」）

```swift
struct LLMTarget: Equatable, Sendable { let model: URL; let modelID: String }

struct LLMGuard {
    let ctx: TickContext
    /// ガードを通れば起動に使うモデル。通らなければ理由をすべて ctx.pauses.trip して nil（遷移しない）。
    func evaluate() -> LLMTarget?
}
```

`evaluate()` の手順（この順）:
1. `guard let id = cfg.llm.modelID else { trip(.llmNotSelected); return nil }`（未選択なら以降を見ない）
2. `reasons: [PauseReason] = []`、`model: URL?`
3. `if let e = ctx.deps.catalog.entry(kind: .llm, id: id)`: `model = ModelFiles.url(kind: .llm, entry: e, layout:)`。
   `!ModelFiles.isPresent(e, kind: .llm, layout:)` → `reasons.append(.llmModelMissing)`。
   `e.minMemoryGB` が在り、`let (need, overflow) = UInt64(clamping: gb).multipliedReportingOverflow(by: LLMGuard.bytesPerGB /* 1_073_741_824 */)` で `overflow || ctx.deps.physicalMemoryBytes < need` → `reasons.append(.llmInsufficientMemory)`（範囲外の値でトラップしない。溢れたら足りない側。CR-16。T-22 の実装で判明）
4. そうでなく `if let u = ModelFiles.customLLMURL(id: id, layout:)`: `model = u`。`!FileProbe.isNonEmptyRegularFile(u)` → `.llmModelMissing`。**メモリは確かめない**（カスタムの目安は分からない。警告は選ぶときの UI（T-31）が出す）
5. どちらでもない（CV-42 で起きない）→ `model = nil`、`.llmModelMissing`
6. `!FileProbe.isExecutableFile(ctx.deps.paths.llamaServer)` → `.llamaServerMissing`
7. `reasons` が空でなければ各々 `ctx.pauses.trip(r)` → nil。空なら `guard let model` → `LLMTarget(model: model, modelID: id)`

### 4.4 `SessionSteps.swift`（本体）

```swift
// Session の工程（PLAN §5.6・§8.5。voicedock session.py / pipeline.py:551-666, 1103-1227）。
import Foundation
import VDContract
import VDCore
import VDLLM
import VDStore

enum SessionStepResult: Equatable, Sendable { case stopped, empty, analyzed, saved }

struct SessionSteps {
    let ctx: TickContext
    init(ctx: TickContext)

    func groupNewParts() throws
    func closeIdleSessions() throws
    func reopenSession(_ sessionKey: String) -> Bool
    func process(sessionKey: String) async -> SessionStepResult

    /// → FAILED → <event>（ERROR）。Session の失敗では再オープンしない。
    func failSession(_ key: String, from: SessionStatus, code: ErrorCode, message: String,
                     event: LogEvent, reason: String? = nil) throws
}
```

**`groupNewParts()`**（PLAN §5.6。voicedock session.py:136-270）:
```text
for part in try store.ungroupedRecordings():                       // started_at, partkey 順
   guard let started = zone.parseISO(part.startedAt) else continue  // 自分で書いた ISO なので起きない。起きたら未分組のまま
   day = zone.localDate(started)                                    // 設定のタイムゾーンへ変換してから日付（TIME-02）
   guard let key = try? targetKey(part, day) else continue          // KeyError（device_id が不正）は分組しない
   if let s = try store.session(key): status = s.status
   else: try store.insertSession(NewSession(sessionKey: key, dayDate: day.dashed, deviceID: part.deviceID)); status = .open
   try store.updateRecording(part.partkey, [.sessionKey(key)])
   try store.refreshSessionAggregates(key)
   if status == .open: try store.recordSessionTransition(sessionKey: key, from: .open, to: .open, detail: part.partkey)   // 新規作成の直後も書く
```
- 閉じた Session（OPEN 以外）への追加は events を書かず、**再オープンもしない**（契機は RAW_SAVED / FAILED / SKIPPED。SM-11 / SM-12）

`targetKey(part, day) throws -> String`:
```text
key = try SessionKey.make(deviceID: part.deviceID, dayStamp: day.stamp)      // 1 本目は接尾辞なし
loop:
   guard let s = try store.session(key) else return key                      // まだ無い鍵
   if hasRoom(s, part) return key
   key = try SessionKey.nextOverflow(key)                                    // #2, #3, …（空きのある最も小さい n）
hasRoom(s, part) = s.partCount < cfg.session.maxParts && (s.recordedSeconds ?? 0) + (part.durationSeconds ?? 0) <= Double(cfg.session.maxDurationSeconds)
```

**`closeIdleSessions()`**（voicedock session.py:276-313）:
```text
now = ctx.deps.clock.now(); today = zone.today(now).dashed; idleBefore = now.adding(seconds: -cfg.session.idleCloseSeconds)
for s in try store.sessions(status: .open):                                  // session_key 順
   staleDay = s.dayDate != today
   idle = zone.parseISO(s.updatedAt).map { $0 <= idleBefore } ?? true        // 読めない updated_at は「古い」側
   if staleDay || idle:
      try store.recordSessionTransition(sessionKey: s.sessionKey, from: .open, to: .ready, detail: staleDay ? "stale_day" : "idle")
      （TransitionConflict は捕まえて次へ）
```
- ちょうど `idleCloseSeconds` 経ったものは閉じる（`<=`）
- **F-66（2026-09-23）で `staleDay` の枝を廃止した。**閉じるのは idle だけ（detail `idle`。日付が過去の OPEN も同じ）。PLAN §5.6

**`reopenSession(_:)`**（PLAN §5.6。voicedock pipeline.py:551-590 ＋ ★3 辺）:
1. `cfg.session.allowReopen` が偽 → false
2. `s = try store.session(key)`。nil か `!SessionStates.reopenable.contains(s.status)` → false
   （reopenable = SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, CLEANUP, COMPLETED。**v1.1 で削除段の 3 つを足した**。付録 A.2 の ★ 3 辺）
3. `try store.recordSessionTransition(sessionKey: key, from: s.status, to: .merging, detail: "reopen")`。`TransitionConflict` → false
4. `try store.updateSession(key, [.regeneratedCount(s.regeneratedCount + 1)])`
5. `log.info(.sessionReopened, [(.sessionKey, key), (.regeneratedCount, .of(s.regeneratedCount + 1))])` → true
- **削除待ちの Part の状態は動かさない**（SOURCE_DELETING / SOURCE_DELETE_PENDING の Part はそのまま。結果は §8.9.6 の全件回収が拾う）
- ほかの例外は `ctx.warnStore(e)` → false

**`process(sessionKey:)`**（voicedock pipeline.py:637-666）:
```text
guard let row = (try? store.session(key)) ?? nil else return .stopped
if SessionStates.savedOrBeyond.contains(row.status): await deleteSourcesIfSafe(key); return .saved
ctx.activity.set(.merging(sessionKey: key))
let t: SessionTranscript?
do { t = try buildSessionTranscript(key) } catch { ctx.warnStore(error); return .stopped }
guard ensureMerged(row, t) else { return ((try? store.session(key))??.status == .completed) ? .empty : .stopped }
guard let t else return .stopped                        // MERGED 以降なのに有効な segment が無い（transcript が後から読めなくなった）。進めない
guard await ensureAnalysis(key, t) else return .stopped
guard await ensureDailyNote(key, t) else return .analyzed   // T-29 まで常に偽
await deleteSourcesIfSafe(key)                           // SAVED の直後に backoff を見ずに 1 回（T-38）
return .saved
```

**`failSession`**:
1. `try store.recordSessionTransition(sessionKey: key, from: from, to: .failed, errorCode: code, errorMessage: message)`
2. `fields = [(.sessionKey, key), (.errorCode, code.rawValue)]`、`reason` があれば `(.reason, reason)`、
   `event != .sessionMergeFailed && !message.isEmpty` なら `(.detail, message)`（付録 A.4: `session_merge_failed` は error_code まで）→ `log.error(event, fields)`

### 4.5 `SessionSteps+Merge.swift`（PLAN §5.6「Block・統合」）

```swift
extension SessionSteps {
    /// 有効な segment が 0 件なら nil（session_empty）。
    func buildSessionTranscript(_ key: String) throws -> SessionTranscript?
    func ensureMerged(_ row: SessionRow, _ t: SessionTranscript?) -> Bool
    /// transcripts/parts/<slug>.json を読み PartTranscriptCodec.decode。読めなければ nil（列は見ない）。
    func readTranscript(_ partkey: String) -> PartTranscript?
}
```

`buildSessionTranscript(key)`（voicedock session.py:329-423）:
1. `guard let row = try store.session(key), let day = LocalDate(dashed: row.dayDate) else { return nil }`
2. `parts = try store.recordings(inSession: key)`（started_at, partkey 順）。`valid` = FAILED / SKIPPED 以外、`excluded` = FAILED / SKIPPED
3. `segments = []`。`valid` の順に: `guard let started = zone.parseISO(p.startedAt), let t = readTranscript(p.partkey) else continue`（読めない Part は飛ばす）。
   各 `seg`: `text = PyText.strip(seg.text)`、空なら捨てる。
   `AbsoluteSegment(at: started.adding(milliseconds: SecondsToMillis.fromWhisperSeconds(seg.start)), endAt: started.adding(milliseconds: SecondsToMillis.fromWhisperSeconds(seg.end)), text: text)`（**絶対時刻**。相対オフセットを足し込まない。TIME-01）
4. `segments` が空 → nil
5. `segments.sort { ($0.at, $0.endAt) < ($1.at, $1.endAt) }`（`at`・`endAt` の `epochMillis` の組で比べる。Swift の `sort` は安定）
6. `blocks = BlockComputer.blocks(valid.compactMap { p in zone.parseISO(p.startedAt).map { (startedAt: $0, endedAt: p.endedAt.flatMap(zone.parseISO)) } }, gapSeconds: cfg.session.blockGapSeconds)`（**transcript が読めない Part も含む**）
7. `SessionTranscript(dayDate: day, segments: segments, blocks: blocks, excludedPartkeys: excluded.map(\.partkey))`

`ensureMerged(row, t)`（voicedock pipeline.py:1103-1138）:
1. `SessionStates.mergedOrBeyond.contains(row.status)` → true。`!SessionStates.mergeable.contains(row.status)` → false
2. `parts = try store.recordings(inSession: key)`、`excluded` = FAILED / SKIPPED の数
3. `row.status == .ready` なら `READY→MERGING`（MERGING から来たら記録しない。再オープンの行もここから進む）
4. `t == nil` → `MERGING→COMPLETED` → `log.info(.sessionEmpty, [(.sessionKey, key), (.parts, .of(parts.count))])` → false（ノートを作らない。FAILED にしない）
5. `try store.updateSession(key, [.failedPartCount(excluded)])` → `MERGING→MERGED` →
   `log.info(.sessionMerged, [(.sessionKey, key), (.parts, .of(parts.count - excluded)), (.excluded, .of(excluded)), (.chars, .of(t.segments.reduce(0) { $0 + TextLimit.scalarCount($1.text) }))])` → true

### 4.6 `SessionSteps+Analysis.swift`（PLAN §5.6「解析の再利用」「古い解析」・§8.5「成功時の書き込み」）

```swift
extension SessionSteps {
    func ensureAnalysis(_ key: String, _ t: SessionTranscript) async -> Bool
    /// analysis/<slug>.json が読めて最終形のスキーマで検証を通れば、その結果（T-29 の ensureDailyNote も使う。判定を 2 か所に書かない）。
    func loadAnalysis(_ key: String) -> AnalysisResult?
    /// loadAnalysis が在り、.source.json の transcript_sha256 が fingerprint と一致すれば、その結果。
    func reusableAnalysis(_ key: String, fingerprint: String) -> AnalysisResult?
    /// .source.json の中身（PyJSON indent 2 ＋ 末尾改行。キーはこの順）。
    static func sourceData(fingerprint: String, transcript: SessionTranscript) -> Data
    static let reusedDetail = "analysis_reused"
    static let staleDetail = "stale_analysis"
}
```

`finalSchema = AnalysisSchema(config: AnalysisConfigView(sections: cfg.llm.analysis.sections), kind: .final)`、`slug = KeySlug.of(key)`、
`analysisRel = layout.relativePath(of: layout.analysisJSON(sessionSlug: slug))`（`"analysis/<slug>.json"`）。

**`ensureAnalysis(key, t)`**（この順。voicedock pipeline.py:1140-1227 ＋ v1.1 の ★）:
1. `guard let row = try store.session(key) else false`
2. `SessionStates.savedOrBeyond.contains(row.status)` → true
3. `status ∉ analyzable ∪ writable`（MERGED・ANALYZING・ANALYZED・WRITING 以外）→ false
4. `fp = TranscriptFingerprint.of(t, zone: zone)`、`reused = reusableAnalysis(key, fingerprint: fp)`
5. `SessionStates.writable.contains(row.status)`（ANALYZED / WRITING）で `reused != nil` → true（何も書かない）
6. `SessionStates.analyzable.contains(row.status)`（MERGED / ANALYZING）で `let r = reused`:
   `try store.updateSession(key, [.analysisPath(analysisRel), .title(r.title)])` → `try store.recordSessionTransition(sessionKey: key, from: row.status, to: .analyzed, detail: "analysis_reused")` → true
   （MERGED からなら ★`MERGED→ANALYZED`。analysis_path と title も書く: 解析を書いた後・DB を更新する前に落ちた Session は analysis_path が NULL のまま再利用され、Daily の工程（analysis_path 必須）に進めなくなるため。voicedock は書かなかった）
7. **ガード**: `guard let target = LLMGuard(ctx: ctx).evaluate() else { return false }`（**遷移しない**。ANALYZED / WRITING の古い解析もここで待つ）
8. 遷移: ANALYZED / WRITING なら `row.status → ANALYZING`（detail `stale_analysis`。★2 辺。解析 JSON が読めない場合もここへ来る。voicedock の `ANALYZED→FAILED`（表に無い辺）は起きない）。
   MERGED なら `MERGED→ANALYZING`。ANALYZING なら記録しない
9. `ctx.activity.set(.analyzing(sessionKey: key, dayDate: row.dayDate))`
10. `prompts = try Prompts.load(directory: ctx.deps.paths.promptsDirectory)`。投げたら `failSession(key, from: .analyzing, code: .llmFailed, message: ErrorText.describe(e), event: .llmFailed)` → false
11. `switch await ctx.deps.llama.ensureRunning(model: target.model, modelID: target.modelID, config: cfg.llm)`: `.failure(f)` → `failSession(key, from: .analyzing, code: f.code, message: f.message, event: .llmFailed)` → false
12. `transport = ctx.deps.chatTransportFactory(handle, cfg.llm)`、`t0 = clock.uptime()`、`outcome = await Analyzer(transport: transport, prompts: prompts, config: cfg.llm).analyze(t)`、`elapsed = DurationSeconds.of(clock.uptime() - t0)`
13. `.failure(f)` → `failSession(key, from: .analyzing, code: f.code, message: f.message, event: f.code == .sessionMergeFailed ? .sessionMergeFailed : .llmFailed)` → false
14. `.success(result, partials, chunks, trimmed)` — **書き込みはこの順**（LLM-03 / CONC-09）:
    1. `trimmed` が空でなければ `log.info(.analysisTrimmed, [(.sessionKey, key), (.fields, .string(trimmed.joined(separator: "; ")))])`
    2. `try AtomicFile.write(PyJSON.fileData(result.pyJSON(schema: finalSchema)), to: layout.analysisJSON(sessionSlug: slug))`。投げたら `failSession(…, code: .llmFailed, message: ErrorText.describe(e), event: .llmFailed)` → false（**指紋は書かれない**）
    3. `saveTimeline(sessionKey: key, summary: result.summary, partials: partials, chunks: chunks, transcript: t, fingerprint: fp)`（T-29。**書けなくても失敗にしない**）
    4. **最後に** `try AtomicFile.write(SessionSteps.sourceData(fingerprint: fp, transcript: t), to: layout.sourceJSON(sessionSlug: slug))`。投げたら 2 と同じ
    5. `try store.updateSession(key, [.analysisPath(analysisRel), .title(result.title), .errorCode(nil), .errorMessage(nil)])` → `ANALYZING→ANALYZED` →
       `log.info(.llmCompleted, [(.sessionKey, key), (.chunks, .of(chunks.count)), (.elapsedS, .double(PyRound.round(elapsed, digits: 1)))])` → true

`loadAnalysis(key)`（voicedock pipeline.py:1402-1411。**切り詰めずに**検証する。保存したものは切り詰め済み）:
1. `data = try? Data(contentsOf: layout.analysisJSON(sessionSlug: slug))`。nil → nil
2. `guard case .object(let obj)? = PyJSON.decode(data) else nil`
3. `guard case .success(let r) = AnalysisValidator.validate(obj, schema: finalSchema) else nil` → `r`

`reusableAnalysis(key, fingerprint:)`（voicedock pipeline.py:1413-1449）:
1. `guard let r = loadAnalysis(key) else nil`
2. `src = try? Data(contentsOf: layout.sourceJSON(sessionSlug: slug))`、`guard case .object(let s)? = src.flatMap(PyJSON.decode)`、
   `s.first(where: { $0.0 == "transcript_sha256" })?.1` が `.string(v)` で `v == fingerprint`（16 進の ASCII なので `==` でよい）でなければ nil（**指紋が無い・読めないときは作り直す**。旧版からの移行と、指紋の書き込みに失敗した場合）
3. `r`

`sourceData`（キーの順・値は逐語）:
```swift
PyJSON.fileData(.object([("schema", .int(1)), ("transcript_sha256", .string(fingerprint)),
                         ("segments", .int(Int64(transcript.segments.count))), ("blocks", .int(Int64(transcript.blocks.count)))]))
```

### 4.7 後続が書く口（このチケットでは空）

```swift
// SessionSteps+Timeline.swift — Timeline の保存（PLAN §8.6。本体は T-29）。
extension SessionSteps {
    func saveTimeline(sessionKey: String, summary: String?, partials: [AnalysisResult], chunks: [Chunk],
                      transcript: SessionTranscript, fingerprint: String) {}          // T-29 が中身を書く
}
// SessionSteps+Daily.swift — Daily ノート（PLAN §8.6〜§8.8。本体は T-29）。
extension SessionSteps {
    func ensureDailyNote(_ key: String, _ t: SessionTranscript) async -> Bool { false } // T-29 が中身を書く
}
// SessionSteps+Deletion.swift — Session の削除段（PLAN §8.9.5 deleteSourcesIfSafe。本体は T-38）。
extension SessionSteps {
    func deleteSourcesIfSafe(_ key: String) async {}                                  // T-38 が中身を書く
}
```

### 4.8 `Worker+SessionStages.swift`（PLAN §5.4 processReadySessions。voicedock worker.py:326-340, 391-412）

```text
func stageProcessReadySessions(_ ctx: TickContext) async:
  keys = []
  do:
    for status in SessionStatus.allCases where SessionStates.processable.contains(status):   // 宣言順
       for row in try store.sessions(status: status):                                          // session_key 順
          parts = try store.recordings(inSession: row.sessionKey)
          if !parts.isEmpty && parts.allSatisfy({ PartStates.terminal.contains($0.status) }): keys.append(row.sessionKey)
  catch: ctx.warnStore(error)
  keys.sort { $0.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }   // 最終的な処理順は session_key（コードポイント）昇順
  steps = SessionSteps(ctx: ctx); retry = InProcessRetry(ctx: ctx)
  for key in keys:
     if ctx.stop.isSet: break
     await retry.run(entity: .session, key: key) { _ = await steps.process(sessionKey: key) }   // 工程内リトライ（毎回 Map からやり直す）
     ctx.activity.set(.idle)
  await ctx.deps.llama.stop()                    // **必ず止める**（空でも・停止要求で抜けても。18 GB を常駐させない。§2.1）
```
- 一覧は先に確定する。Part が 0 件の Session は対象にしない

### 4.9 `Tests/TestSupport/FakeLLMServer.swift`（00-api-map §15 に足す。作り手 T-22）

```swift
// LLMServerControl の偽物。プロセスを起動しない。
public actor FakeLLMServer: LLMServerControl {
    /// failure を渡すと ensureRunning は常にそれを返す。nil なら成功（port 40000、apiKey "0"×32、modelID は渡された値）。
    public init(failure: StageFailure? = nil)
    public func ensureRunning(model: URL, modelID: String, config: LLMConfig) async -> Result<LlamaServerHandle, StageFailure>
    public func stop() async
    public var ensureCalls: [(model: URL, modelID: String)] { get }
    public var stopCount: Int { get }
}
```
（`LlamaServerHandle` の公開の init が要る。§11 の提案 3）

## 5. ログ（このチケットが出すもの）

| イベント | レベル | フィールド |
|---|---|---|
| `session_reopened` | INFO | `session_key`, `regenerated_count` |
| `session_empty` | INFO | `session_key`, `parts` |
| `session_merged` | INFO | `session_key`, `parts`, `excluded`, `chars` |
| `analysis_trimmed` | INFO | `session_key`, `fields` |
| `llm_completed` | INFO | `session_key`, `chunks`, `elapsed_s` |
| `llm_failed` | ERROR | `session_key`, `error_code`, `detail` |
| `session_merge_failed` | ERROR | `session_key`, `error_code` |
| `pipeline_paused` / `pipeline_resumed` | WARNING / INFO | `reason`（llm_not_selected ほか。PauseBook） |

## 6. テスト

共通: T-18 §6 と同じ。`import VDLLM` を足す。

### 6.0 `PipelineFixtures.swift` への追加

- `PipelineWorld.make(configure:chat:llm:physicalMemoryBytes:)`: `chat: FakeChatTransport = FakeChatTransport(responses: [])`、`llm: FakeLLMServer = FakeLLMServer()`、`physicalMemoryBytes: UInt64 = 1 << 40`。
  deps の `chatTransportFactory` は `{ _, _ in chat }`
- `func installLLM() async throws`（`ConfigStore.update` が async のため）: `TestCatalogs.minimal` の `test-llm` のファイルを `ModelFiles.url` に `entry.bytes` の 0 で置き、`paths.llamaServer` に `#!/bin/sh\nexit 0\n`（0755）を置き、`update { $0.llm.modelID = "test-llm" }`
- `func addSessionPart(hour: Int, status: PartStatus = .rawSaved, text: String? = "おはようございます。", sessionKey: String = "DJIMIC3:20260912", day: String = "20260912") throws -> String`（voicedock test_session_analysis `add_part`）:
  relpath `TX_MIC001_<day>_<hh>0000/TX00_MIC001_<day>_<hh>0000_orig.wav`、started `<yyyy-MM-dd>T<hh>:00:00+09:00`、duration 60、ended `<hh>:01:00`。
  `insertRecording` の後、`forcePart(pk, status:, sessionKey:)`。`text` が nil でなければ `PartTranscriptCodec.encode(PartTranscript(partkey: pk, language: "ja", durationSeconds: 60.0, startedAt: started, text: text, segments: [TranscriptSegment(start: 0.0, end: 3.0, text: text)]))` を `layout.transcript(slug:)` に書く
- `func addSession(key: String = "DJIMIC3:20260912", day: String = "2026-09-12", status: SessionStatus, regenerated: Int = 0) throws`: `insertSession` → `forceSession(key, status:, regeneratedCount:)`
- `func registerRow(folder: String = "TX_MIC001_20260912_120950", name: String = "TX00_MIC001_20260912_120950_orig.wav", started: String = "2026-09-12T12:09:50+09:00", duration: Double? = 1800.0, device: String = "DJIMIC3", status: PartStatus = .discovered) throws -> String`
  （voicedock test_session_group `part`）: `relpath = RelPath.join([folder, name])`（folder が空なら name）、`NewRecording(… transmitterID: <name の先頭 4 文字>, micIndex: 1, startedAt: started, durationSeconds: duration, endedAt: duration の分を足した ISO（nil なら nil）, sourcePath: relpath, sourceSize: 1, sourceMtime: 1.0, sha256Helper: "a" × 64, inboxPath: <layout.inboxFile の HOME 相対>)`。inbox のファイルは作らない。`status` が DISCOVERED 以外なら `forcePart`
- `func addTimedPart(time:stamp:duration:ended:status:segments:sessionKey:day:) throws -> String`: 任意の時刻（`hh:mm:ss`）に始まる Part（`addSessionPart` はこれを呼ぶ）。`segments` が nil なら transcript を書かない、`ended` が偽なら ended_at は NULL（§6.4 の 09:00:05 開始・ended NULL などに使う）
- `forcePart` / `forceSession`: `@testable import VDStore` の `store.pool.write` で `UPDATE recordings SET status = ?, session_key = ? WHERE partkey = ?` / `UPDATE sessions SET status = ?, regenerated_count = ? WHERE session_key = ?`（テストだけの近道。Tests/ は PT-05 の対象外。**本番のコードは使わない**）
- `ANALYSIS`（voicedock test_session_analysis の固定値。1 行の JSON 文字列）:
  `{"title": "開発の一日", "summary": "削除条件を整理した。", "key_points": ["論理式に落とした"], "tasks": [{"text": "ND テストを書く", "due": null}], "decisions": [], "ideas": [], "tags": ["VoiceDock"]}`
- `ANALYSIS_FILE`（`ANALYSIS` を既定の最終形で保存したときの analysis.json。末尾に改行 1 つ）:
```json
{
  "title": "開発の一日",
  "summary": "削除条件を整理した。",
  "key_points": [
    "論理式に落とした"
  ],
  "tasks": [
    {
      "text": "ND テストを書く",
      "due": null
    }
  ],
  "decisions": [],
  "ideas": [],
  "tags": [
    "VoiceDock"
  ]
}
```

### 6.1 `SessionGroupTests.swift`（時計 `1_789_221_600_000` = 2026-09-12T23:00:00+09:00。voicedock test_session_group）

Part は `registerRow(folder:name:started:duration:device:)`（行だけを DISCOVERED で入れる。inbox は作らない）で作る。既定 folder `TX_MIC001_20260912_120950`、name `TX00_MIC001_20260912_120950_orig.wav`、started `2026-09-12T12:09:50+09:00`、duration 1800。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `sameDayIsOneSession` / 「送信機・フォルダが違っても同じ日は 1 Session」 | 既定と `TX_MIC009_20260912_160000/TX03_MIC009_20260912_160000_orig.wav`（16:00） | Session は `DJIMIC3:20260912` の 1 つ、part_count 2、OPEN |
| `partSpanningMidnightBelongsToStartDay` / 「TIME-02 23:50 開始の Part は開始日」 | 23:50:00 開始・1800 秒 | `DJIMIC3:20260912` |
| `ceTimeZone` / 「CE timeZone 日付は設定のタイムゾーンで取る」 | started_at `2026-09-12T15:30:00+00:00` の行。timeZone `Asia/Tokyo` と `UTC` | `DJIMIC3:20260913`（Tokyo）と `DJIMIC3:20260912`（UTC） |
| `differentDayOrDevice` / 「日付違い・デバイス違いは別」 | 09-13 09:00 の Part、device `NO NAME` の Part | Session が 3 つ（`DJIMIC3:20260912`・`DJIMIC3:20260913`・`NO NAME:20260912`） |
| `onlyUngroupedParts` / 「対象は session_key が NULL の Part だけ」 | 2 回呼ぶ | 2 回目は events が増えない |
| `columnsAreRecounted` / 「集計列を数え直す」 | 600 秒の Part と、16:00 開始 1200 秒の SKIPPED の Part | part_count 2、failed_part_count 1、recorded_seconds 1800.0、started_at `2026-09-12T12:09:50+09:00`、ended_at `2026-09-12T16:20:00+09:00`、day_date `2026-09-12` |
| `addingToOpenIsATransition` / 「SM-02 OPEN への追加は OPEN→OPEN」 | 2 件 | events `[(nil, OPEN, nil), (OPEN, OPEN, <pk1>), (OPEN, OPEN, <pk2>)]`（from, to, detail） |
| `addingToClosedWritesNoEvent` / 「閉じた Session への追加は events を書かず再オープンしない」 | 1 件で分組 → OPEN→READY → 2 件目で分組 → SAVED に強制 → 3 件目で分組（READY は再オープン元でないので、「分組で再オープンする」壊し方は SAVED でしか見えない） | 2 件目の session_key が同じ、events 増えない、READY のまま、part_count 2。3 件目も同じ鍵、events 増えない、SAVED のまま、regenerated_count 0 |
| `emptyGroupsNothing` / 「未分組が無ければ何もしない」（TEST-28） | Part 0 件 | Session 0 件 |

上限（時計 `1_789_257_600_000` = 2026-09-13T09:00+09:00。voicedock test_session_reopen `add_part`: 09:00 から 1 分ずつ、60 秒。`K = "DJIMIC3:20260912"`）:

| 関数名 / 表示名 | 設定 | 期待（started_at 順の session_key） |
|---|---|---|
| `belowLimitSharesOne` / 「上限に達しなければ 1 つ」 | maxParts 4、4 件 | 全部 `K` |
| `ceSessionMaxParts` / 「CE session.maxParts 超えた分は #2・#3 へ」 | maxParts 2、5 件 | `[K, K, K#2, K#2, K#3]` |
| `ceSessionMaxDurationSeconds` / 「CE session.maxDurationSeconds でも割れる」 | maxDuration 120、maxParts 99、3 件 | `[K, K, K#2]` |
| `unknownDurationCountsAsZero` / 「長さ不明は 0 として数える」 | 同上、duration nil | 全部 `K` |
| `secondPassFillsTheFirstRoom` / 「空きのある最も小さい n を選ぶ」 | maxParts 2、3 件で分組 → 4 件目で分組 | 4 件目は `K#2` |

### 6.2 `SessionCloseTests.swift`（分組の時点 2026-09-12T23:00+09:00）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `pastDayBecomesReady` / 「日付が過去の OPEN は stale_day で閉じる」 | 分組 → 時計 +1 日 | READY、detail `stale_day`（F-66 で廃止。`dayChangeAloneDoesNotClose`・`pastDayClosesByIdle`・`startClosesIdlePastDay` に置き換えた） |
| `idleSameDayBecomesReady` / 「当日でも idle 経過で閉じる」 | +1801 秒 | READY、detail `idle` |
| `exactlyIdleCloses` / 「ちょうど idleCloseSeconds で閉じる」 | +1800 秒 | READY |
| `recentStaysOpen` / 「idle 未満は OPEN」 | +1799 秒 | OPEN |
| `ceSessionIdleCloseSeconds` / 「CE session.idleCloseSeconds 60 なら 61 秒で閉じる」 | idleClose 60、+61 秒 | READY（既定の 1800 なら OPEN のまま） |
| `closingIsIdempotent` / 「2 回目は何もしない」 | 2 回 | events 増えない |
| `noOpenSessions` / 「OPEN が無ければ何もしない」 | 空 | 例外なし |

### 6.3 `SessionReopenTests.swift`（時計 2026-09-13T09:00+09:00）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `reopenableStatesReopen` / 「★ 再オープン元 5 状態」（パラメータ化） | SAVED・SOURCE_DELETING・SOURCE_DELETE_PENDING・CLEANUP・COMPLETED、regenerated 1 | true、MERGING、regenerated_count 2、最後の events `(<元>, MERGING, "reopen")`、ログ `session_reopened session_key=DJIMIC3:20260912 regenerated_count=2` |
| `unfinishedStatesAreNotReopened` / 「確定前は戻さない」（パラメータ化） | OPEN・READY・MERGING・MERGED・ANALYZING・ANALYZED・WRITING・FAILED | false、状態そのまま、ログ無し |
| `ceSessionAllowReopen` / 「CE session.allowReopen false なら何もしない」 | allowReopen false、SAVED | false、SAVED、regenerated 0 |
| `missingSessionIsNotAnError` / 「無い Session は偽」 | Session 無し | false |
| `skippedPartReopensItsSession` / 「SKIPPED に落ちた Part が Session を再オープンする」（voicedock :474） | SAVED の Session と、その Session の DISCOVERED の Part（`text: nil`、inbox 無し） → `PartSteps(ctx: ctx).ensureNormalized(row)` | Part SKIPPED(SOURCE_MISSING)、Session MERGING |
| `failedPartReopensItsSession` / 「FAILED に落ちた Part も」（:453） | SAVED の Session と TRANSCRIBING の Part → `PartSteps(ctx: ctx).fail(row, from: .transcribing, code: .whisperFailed, message: "x", event: .transcriptionFailed)` | Part FAILED、Session MERGING |
| `unfinishedSessionUntouchedByFailure` / 「確定前の Session は Part の失敗で動かない」（:494） | READY の Session | READY |
| `partWithoutSessionDoesNotCrash` / 「session_key の無い Part の失敗」（:514） | session_key NULL | 例外なし |
| `deletingPartsKeepTheirState` / 「削除待ちの Part は動かさない」 | SOURCE_DELETING の Session と、その SOURCE_DELETING・RAW_SAVED の Part | Session MERGING、Part は SOURCE_DELETING と RAW_SAVED のまま |

### 6.4 `SessionMergeTests.swift`

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `excludesFailedAndSkipped` / 「FAILED / SKIPPED を除外する」 | 09 時 RAW_SAVED（「朝」）・10 時 FAILED（「昼」）・11 時 SKIPPED（「夜」）、どれも transcript 在り | segments の text `["朝"]`、excludedPartkeys `[10 時, 11 時]` |
| `absoluteTimes` / 「TIME-01 絶対時刻 = started_at + offset」 | 09:00:00 開始の Part に segment (1.0, 1.2)・(1.5, 3.2)（前の segment に足し込む壊れ方でも値が変わるよう、先に 1 つ置く） | (1.5, 3.2) の at = `2026-09-12T09:00:01+09:00` の Instant + 500 ms、endAt = 09:00:00 + 3200 ms（`epochMillis` で比べる） |
| `textIsStrippedAndEmptyDropped` / 「text を Python 互換 strip し空を捨てる」 | segments `" a "`, `"\u{3000}"`, `"\u{1c}b\u{1f}"` | `["a", "b"]` |
| `sortedByAtThenEndAt` / 「(at, end_at) で安定ソート」 | 09:00 の Part に (10, 20, "x")、09:00:05 開始の Part に (0, 30, "y")・(5, 8, "z") | text の順 `["y", "z", "x"]`（y は 09:00:05。z と x は同じ 09:00:10 で end の早い z が先） |
| `unreadableTranscriptIsSkipped` / 「読めない transcript は飛ばすが Block には数える」 | 09 時（読める）と 09:30（transcript 無し） | segments は 1 件、blocks は 1 つで end が 09:31:00 |
| `blockGapExactlyDoesNotSplit` / 「ちょうど閾値は区切らない」 | 09:00〜09:01 と 10:01:00 開始 | blocks 1 |
| `blockGapPlusOneSplits` / 「1 秒超えで区切る」 | 10:01:01 開始 | blocks 2 |
| `ceSessionBlockGapSeconds` / 「CE session.blockGapSeconds 60 なら 2 分の空きで区切る」 | blockGap 60、09:00〜09:01 と 09:02:01 開始 | blocks 2（既定なら 1） |
| `unknownEndAlwaysSplits` / 「ended_at が無い Part の後は必ず区切る」 | 09:00（ended NULL）と 09:00:30 | blocks 2、1 つ目は start == end == 09:00:00 |
| `emptyMergeCompletes` / 「有効な segment が 0 なら COMPLETED（session_empty）」 | READY、Part 2 件とも SKIPPED | `.empty`、COMPLETED、events `READY→MERGING`・`MERGING→COMPLETED`、ログ `session_empty session_key=… parts=2`、analysis.json が無い |
| `noPartsCompletes` / 「Part 0 件の Session を直接処理しても COMPLETED」（TEST-28） | READY、Part 0 | `.empty` |
| `mergedIsLogged` / 「session_merged の数」 | RAW_SAVED 1（「おはようございます。」）・FAILED 1 | failed_part_count 1、ログ `session_merged session_key=… parts=1 excluded=1 chars=10` |
| `mergingEntryRecordsNoPhantom` / 「MERGING から入っても READY→MERGING を書かない」 | MERGING の Session（再オープン後） | MERGED、`READY→MERGING` の events が無い |

### 6.5 `SessionAnalysisTests.swift`（`installLLM()`。chat は `FakeChatTransport(responses: [.content(ANALYSIS)])` を既定とする）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `readySessionReachesAnalyzed` / 「READY → ANALYZED（Daily は T-29）」 | READY、09 時の Part 1 件 | `.analyzed`、最後の 4 本の events の to `[MERGING, MERGED, ANALYZING, ANALYZED]`、analysis.json が `ANALYSIS_FILE` とバイト一致、`analysis_path == "analysis/<slug>.json"`、title `開発の一日`、error_code NULL、ログ `llm_completed session_key=DJIMIC3:20260912 chunks=1 elapsed_s=0.0` |
| `sourceJSONIsExact` / 「.source.json の形」 | 同上 | 中身が `{\n  "schema": 1,\n  "transcript_sha256": "<fp>",\n  "segments": 1,\n  "blocks": 1\n}\n`（fp は `TranscriptFingerprint.of`。値そのものは T-10 の golden が固定） |
| `llmGetsTheTranscript` / 「analyze のプロンプトと本文」 | 同上 | chat の呼び出し 1 回、system == `prompts.analyze(最終形, custom: "")`、user == `おはようございます。` |
| `serverIsStartedWithTheModel` / 「選んだモデルで llama-server を起動する」 | 同上 | `llm.ensureCalls == [(ModelFiles.url(.llm, test-llm), "test-llm")]` |
| `validAnalysisIsReused` / 「★ 指紋が一致すれば LLM を呼ばず MERGED→ANALYZED」 | MERGED、analysis.json と正しい .source.json を置く、analysis_path NULL | chat 0 回、ensureRunning 0 回、最後の events `(MERGED, ANALYZED, "analysis_reused")`、analysis_path と title が書かれる |
| `reuseFromAnalyzing` / 「ANALYZING からの再利用」 | ANALYZING | `(ANALYZING, ANALYZED, "analysis_reused")` |
| `missingFingerprintReanalyzes` / 「指紋が無ければ作り直す」（voicedock :388） | analysis.json だけ | chat 1 回 |
| `differentTranscriptReanalyzes` / 「別の transcript の解析は作り直す」（:408） | .source.json の sha が別の値 | chat 1 回 |
| `brokenAnalysisReanalyzes` / 「壊れた解析は作り直す」（:444） | analysis.json が `{` | chat 1 回 |
| `staleAnalysisFromAnalyzed` / 「★ ANALYZED で指紋が違えば ANALYZED→ANALYZING（stale_analysis）」 | 09 時の Part で解析済み（ANALYZED、正しいファイル）→ 09:30 開始の RAW_SAVED の Part を足す（10 時だと 09:00:00〜10:00:03 が `maxSecondsPerRequest` 3600 を超えて 2 チャンクになり、chat が Map 2 回 ＋ Reduce 1 回になる）→ `ensureAnalysis` | events `(ANALYZED, ANALYZING, "stale_analysis")`・`(ANALYZING, ANALYZED)`、chat 1 回、.source.json の segments 2 |
| `staleAnalysisFromWriting` / 「★ WRITING でも同じ（WRITING→ANALYZING）」 | 同上で WRITING | `(WRITING, ANALYZING, "stale_analysis")` |
| `brokenAnalysisInAnalyzedIsRedone` / 「ANALYZED で解析 JSON が読めなければ作り直す（FAILED にしない）」 | ANALYZED、analysis.json が `{` | ANALYZED、FAILED を経ない |
| `matchingAnalyzedIsKept` / 「ANALYZED で一致すれば何もしない」 | ANALYZED、正しいファイル | true、events 増えない、chat 0 |
| `llmFailureIsFailed` / 「LLM の失敗は ANALYZING→FAILED」（:477, :510） | chat `[.failure(StageFailure(.llmUnavailable, "URLError -1004"))]` | FAILED(LLM_UNAVAILABLE)、message `URLError -1004`、ログ `llm_failed session_key=… error_code=LLM_UNAVAILABLE detail="URLError -1004"`、analysis.json も .source.json も無い |
| `invalidJSONIsFailed` / 「直らない JSON は LLM_INVALID_JSON」 | chat 2 回とも `{"title":"t"}` | FAILED(LLM_INVALID_JSON)、message `- summary: Field required` |
| `serverStartFailureIsFailed` / 「起動の失敗は LLM_UNAVAILABLE」 | `FakeLLMServer(failure: StageFailure(.llmUnavailable, "server_start_failed: no_port"))` | FAILED、message `server_start_failed: no_port`、chat 0 回 |
| `analysisWriteFailureLeavesNoFingerprint` / 「解析を書けなければ LLM_FAILED で指紋は書かない」（:727） | analysis.json の位置にディレクトリを置く（`layout.analysis` を 0o555 にすると同じディレクトリの .source.json も書けず、「.source.json を先に書く」壊し方が見えない） | FAILED(LLM_FAILED)、message が `AtomicFileError: ` で始まる、.source.json が無い |
| `sourceWriteFailureIsLLMFailed` / 「指紋を書けなければ LLM_FAILED」 | `.source.json` の位置にディレクトリを置く | FAILED(LLM_FAILED)、次の `ensureAnalysis`（FAILED→ANALYZING に戻した後）で chat がもう一度呼ばれる |
| `trimmedIsLogged` / 「切り詰めを記録する」 | ANALYSIS の tags を 20 個に | ログ `analysis_trimmed session_key=… fields="tags: 20 -> 15"` |
| `reopenedSessionIsReanalyzed` / 「再オープン後は再解析」（:754） | chat は `ANALYSIS` を 2 回。1 回処理して ANALYZED → SAVED に強制 → 09:30 開始の RAW_SAVED の Part を足し（1 チャンクに収める。`staleAnalysisFromAnalyzed` と同じ理由）`reopenSession` → `process` | chat 2 回目が呼ばれる |
| `unchangedReopenIsReused` / 「新しい segment が無ければ再解析しない」（:780） | 1 回処理 → SAVED に強制 → SKIPPED の Part を足し `reopenSession` → `process` | chat は 1 回のまま、`analysis_reused` |
| `guardFailureDoesNotTransition` / 「ガードで止まれば遷移しない」 | llm.modelID nil、MERGED | false、MERGED のまま、`pipeline_paused reason=llm_not_selected`、chat 0 |
| `staleWaitsOnGuard` / 「古い解析もガードで待つ（遷移しない）」 | ANALYZED・指紋違い・llama-server を消す | ANALYZED のまま、`paused` に `.llamaServerMissing` |

### 6.6 `LLMGuardTests.swift`

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `ceLlmModelID` / 「CE llm.modelID 未選択なら llm_not_selected、選べば通る」 | nil と `test-llm`（installLLM） | nil で `[.llmNotSelected]`、`test-llm` で `LLMTarget(model: ModelFiles.url(…), modelID: "test-llm")` |
| `missingModel` / 「ファイルが無ければ llm_model_missing」 | ファイルを消す | `[.llmModelMissing]` |
| `wrongSizeIsMissing` / 「大きさが違えば無いのと同じ」 | bytes + 1 | `[.llmModelMissing]` |
| `insufficientMemory` / 「メモリが足りなければ llm_insufficient_memory」 | physicalMemoryBytes 0 | `[.llmInsufficientMemory]` |
| `missingServer` / 「llama-server が無い・実行できなければ llama_server_missing」 | 消す／0o644 にする | `[.llamaServerMissing]` |
| `allIndependentReasonsAreReported` / 「独立した理由は全部出す」 | モデルと llama-server を消し、メモリ 0 | `paused == [.llmModelMissing, .llmInsufficientMemory, .llamaServerMissing]` |
| `customModelSkipsMemory` / 「custom はメモリを見ない」 | `custom:` + `"0"` × 64、`models/llm/custom-0000000000000000.gguf` に 1 バイト、メモリ 0 | 通る |
| `customModelMissing` / 「custom のファイルが無ければ llm_model_missing」 | ファイル無し | `[.llmModelMissing]` |

### 6.7 `ProcessReadySessionsTests.swift`（`@Suite(.serialized)`。`installLLM()`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `needsEveryPartTerminal` / 「Part が全部終端でなければ処理しない」（voicedock :547） | READY、Part RAW_SAVED と TRANSCRIBED | READY のまま |
| `terminalMixIsReady` / 「FAILED を含んでも全部終端なら処理する」（:571） | RAW_SAVED と FAILED | ANALYZED |
| `sessionWithoutPartsIsNotReady` / 「Part 0 件は対象外」（:588） | READY、Part 0 | READY のまま |
| `scansEveryProcessableState` / 「processable の 6 状態を全部拾う」（test_session_resume :166） | READY・MERGING・MERGED・ANALYZING・ANALYZED・WRITING の Session（鍵の日付を 09-01〜09-06 に変える）に RAW_SAVED の Part 1 件ずつ、chat は常に `ANALYSIS` を返す handler | 6 つとも ANALYZED（ANALYZED・WRITING は解析ファイルが無いので stale_analysis 経由） |
| `ignoresOtherStates` / 「processable 以外は触らない」（:198） | OPEN・SAVED・COMPLETED・FAILED | 変わらない |
| `orderIsBySessionKey` / 「処理順は session_key 昇順」 | `DJIMIC3:20260913`（READY）と `DJIMIC3:20260912`（MERGED） | 0912 の最初の events の id が小さい |
| `serverIsAlwaysStopped` / 「終わりで必ず llama-server を止める」（パラメータ化） | 対象あり（1 件）・対象なし・2 件のうち 1 件目の処理中に停止要求（`world.context(stop: flag)` で作った ctx で `worker.stageProcessReadySessions(ctx)` を呼び、chat の handler が `flag.set()` してから `ANALYSIS` を返す） | どれも `llm.stopCount == 1`。停止要求の例では 2 件目が READY のまま |
| `sessionIsRetriedInProcess` / 「解析の失敗は工程内で 3 回（毎回やり直す）」 | chat が常に `.failure(LLM_UNAVAILABLE)` | FAILED、retry_count 3、sleeper `[3, 10]`、chat 3 回 |
| `invalidJSONIsNotRetriedInProcess` / 「LLM_INVALID_JSON は工程内で回さない」 | chat が常に `{"title":"t"}` | chat 2 回（修復 1 回）、sleeper `[]` |

### 6.8 `SessionStateHandlerTests.swift`（SM-07。voicedock test_session_resume :125-165）

| 関数名 / 表示名 | 期待 |
|---|---|
| `everyResumeTargetHasAHandler` / 「SM-07 Session の FAILED の戻り先に受け手がいる」 | `SessionStates.retryableFromFailed ⊆ mergeable ∪ analyzable ∪ writable` |
| `recoveryTargetsHaveHandlers` / 「SM-07 復旧の戻り先に受け手がいる」 | READY・MERGED・ANALYZED ∈ processable、SAVED・SOURCE_DELETE_PENDING ∈ deleteEvaluated（削除段が受ける） |
| `reopenTargetIsMergeable` / 「再オープンの行き先は MERGING」 | `mergeable.contains(.merging)`、reopenable の各状態から MERGING への辺が遷移表に在る |
| `analyzingResumesWithoutPhantom` / 「ANALYZING から再開し MERGED→ANALYZING を書かない」（:227, :247） | ANALYZING の Session を処理すると ANALYZED になり、`MERGED→ANALYZING` の events が無い |

### 6.9 `ModelFilesTests.swift`（VDCoreTests）

| 関数名 / 表示名 | 期待 |
|---|---|
| `urlIsUnderModels` / 「models/<kind>/<file>」 | `ModelFiles.url(kind: .llm, entry: e, layout:)` の HOME 相対が `models/llm/<e.file>` |
| `customURL` / 「custom の置き場所」 | `custom:` + `"ab"` × 32 → `models/llm/custom-abababababababab.gguf`、`custom:XYZ` → nil |
| `presentNeedsExactSize` / 「在否は大きさの一致で」 | bytes と同じ → true、1 違う → false、無い → false、ディレクトリ → false |

### 6.10 `ConfigEffectPending.swift`

`timeZone`、`session.blockGapSeconds`、`session.idleCloseSeconds`、`session.allowReopen`、`session.maxParts`、`session.maxDurationSeconds`、`llm.modelID` の 7 行を消す。

## 7. 破壊による証明

| 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|
| 分組の日付を started_at の文字列の先頭 10 文字から取る（タイムゾーン変換をしない） | `ceTimeZone` |
| `hasRoom` を `<` にする（maxDuration ちょうどを入れない） | `ceSessionMaxDurationSeconds` |
| overflow で常に新しい鍵を作る（空きのある最小の n を探さない） | `secondPassFillsTheFirstRoom` |
| 閉じた Session への追加でも OPEN→OPEN を書く | `addingToClosedWritesNoEvent` |
| closeIdleSessions の比較を `<` にする | `exactlyIdleCloses` |
| `SessionStates.reopenable` を SAVED・COMPLETED だけにする（voicedock のまま） | `reopenableStatesReopen`（削除段の 3 つ） |
| 分組で再オープンする | `addingToClosedWritesNoEvent` |
| buildSessionTranscript で segment の offset を Part の先頭ではなく前の segment に足す | `absoluteTimes`、`sortedByAtThenEndAt` |
| Block の入力から読めない transcript の Part を除く | `unreadableTranscriptIsSkipped` |
| ensureAnalysis の ANALYZED / WRITING の指紋の確認を消す（voicedock のまま） | `staleAnalysisFromAnalyzed`、`staleAnalysisFromWriting` |
| .source.json を analysis.json より先に書く | `analysisWriteFailureLeavesNoFingerprint` |
| 再利用で analysis_path を書かない | `validAnalysisIsReused` |
| ガードを MERGED→ANALYZING の後に置く | `guardFailureDoesNotTransition` |
| processReadySessions の終わりの `llama.stop()` を対象があるときだけにする | `serverIsAlwaysStopped`（対象なし・停止要求） |
| processReadySessions で Part 0 件の Session も対象にする | `sessionWithoutPartsIsNotReady` |

## 8. 受け入れ条件

- [ ] §3 のファイルがすべて在り、公開宣言が 00-api-map（と §11 の提案）に一致する
- [ ] 付録 A.2 の ★ 6 辺のうち、`MERGED→ANALYZED`・`ANALYZED→ANALYZING`・`WRITING→ANALYZING`・削除段からの再オープン 3 辺をテストで通った（`reopenableStatesReopen`・`validAnalysisIsReused`・`staleAnalysis*`）
- [ ] `processReadySessions` がどの経路でも llama-server を止める
- [ ] §6 のテストがすべて通り、ConfigEffectCoverage が緑
- [ ] 破壊による証明の各項目で表のテストが落ちることを確かめ、PR 本文に貼った
- [ ] `make lint` が通る

## 9. SPEC の変更

なし（状態・遷移・ログの表は付録 A のまま。★ 辺は T-08 が SPEC に載せ済み）。

## 10. マージ後にやること

- T-24（LLM 受け入れ試験）が本物の llama-server で `SessionSteps.process` を回す。T-30 の Bootstrap が `llama: LlamaServerSupervisor(…)`・`chatTransportFactory`・`physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory` を渡す

## 11. API 地図への変更提案

1. `WorkerDependencies.llama: LlamaServerSupervisor` → `any LLMServerControl`（新設の公開プロトコル。`extension LlamaServerSupervisor: LLMServerControl`）。`chatTransportFactory` の型を `public typealias ChatTransportFactory = @Sendable (LlamaServerHandle, LLMConfig) -> any ChatTransport` と定める。`physicalMemoryBytes: UInt64` を足す → 00-api-map §11 に反映済み（`ChatTransportFactory` は 2 引数で確定。整合修正 M-2）
2. `ModelFiles`（§2.2）は **T-09 が `Sources/VDCore/ModelFiles.swift` に作る**（地図 §2 のとおり）。本チケットは使うだけ。§4.2 の 3 関数はその仕様
3. `LlamaServerHandle` に `public init(endpoint:apiKey:modelID:)` を足す（T-21。FakeLLMServer が作るため）
4. §15 に `FakeLLMServer`（作り手 T-22、使う T-29）を足す
5. `SessionSteps` の宣言を地図に書く: `groupNewParts() throws`・`closeIdleSessions() throws`・`reopenSession(_:) -> Bool`・`process(sessionKey:) async -> SessionStepResult`・`ensureMerged(_:_:) -> Bool`・`ensureAnalysis(_:_:) async -> Bool`・`ensureDailyNote(_:_:) async -> Bool`（T-29）・`saveTimeline(…)`（T-29）・`deleteSourcesIfSafe(_:) async`（T-38）。`SessionStepResult { stopped, empty, analyzed, saved }`
6. PLAN §5.6 の「解析の再利用」に「再利用するときも analysis_path と title を書く」を足す（書かないと、解析の書き込みの後・DB 更新の前に落ちた Session が ANALYZED のまま Daily の工程に進めない。voicedock の潜在バグ）
7. `PyJSON.decode` は地図では `(_ data: Data)`、T-19 §4.9 では `(_ text: String)`。本チケットは地図の `Data` 版を使う

- （実装で追記）VDModels の `ModelManager.meetsMemory`（T-23）は、同じ判定を `UInt64(gb) * 1_073_741_824` のトラップしうる形で持っている。UI（T-31）とガード（T-22）で書き方をそろえるため、`meetsMemory` も飽和演算にすることを提案する（値の上で違いが出るのは溢れる場合だけ）
