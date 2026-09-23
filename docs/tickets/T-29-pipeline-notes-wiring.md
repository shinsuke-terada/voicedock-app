# T-29 VDPipeline: Raw / Daily ノートの工程・Timeline の保存・Vault 索引・tick の配線の完成

> （F-75・issue #115、2026-09-23。マージ後の追記）`ensureRawNote` は、トリガの Part が載せる Part に居なければ（transcript・started_at が読めない）Raw を書かずに `RAW_WRITING→FAILED`（`OBSIDIAN_RAW_WRITE_FAILED`）にする（手順 2 の「空 → false」をやめ、手順 6a を足した）。
> 書き込み先の既存の Raw ノートに RAW_SAVED 以降の Part の鍵が在るのに新しい内容から抜けるなら、書かずにトリガを FAILED にする（手順 9a）。`noMembersStaysTranscribed` は取り下げ、
> テストは `RawNoteTextProtectionTests.swift`（PLAN §8.6〜§8.8・X-38）。

| 項目 | 値 |
|---|---|
| ID | T-29 |
| Phase | 6（ノート） |
| 前提 | T-22（`SessionSteps` の本体・`loadAnalysis`・`FakeLLMServer`・`installLLM`）、T-27（`DailyNote`・`Timeline`・`VaultIndex`・`LinkPlanner`）、T-28（`VaultCheck`・`NoteWriter`・`NoteVerifier`・`OutputPathResolver`）。間接に T-18・T-26 |
| 見積もり | Sources 約 450 行、Tests 約 1,100 行 |

## 1. 目的

T-18 / T-22 が空の本体で置いた口を埋めて、Part を RAW_SAVED まで、Session を SAVED まで運ぶ: Raw ノート（`ensureRawNote`）、Daily ノート（`ensureDailyNote`）、
Timeline の保存（`saveTimeline`）、Vault 索引の TTL（段 `refreshVaultIndex`）、復旧時の Vault の一時ファイルの削除、`inboxRetain = raw_saved` の削除。
Raw の直後の削除評価は T-38 が中身を入れる空の関数を置く。BWF から Daily ノートの検証までを 1 本の結合テストで確かめる。

## 2. 参照

- PLAN §5.3（Vault の tmp）、§5.5（Part の処理）、§8.3 手順 7（raw_saved）、§8.5「成功時の書き込み」2、§8.6（Raw・Daily・Timeline・WikiLink）、§8.7（Vault の確認・書き込み・保存検証・失敗の写し方）、§8.8（既存ノート）、§8.9.5（Raw の直後の削除評価）
- voicedock@d3d595e: `src/voicedock/pipeline.py:467-623, 1229-1400`、`src/voicedock/worker.py:309-324`、
  `tests/unit/test_worker_loop.py:962-1015`、`tests/unit/test_session_analysis.py:601-656`
- 移植メモ V3 §1.7・§3.4・§5.4、V5（ノート）

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/VDPipeline/PartSteps+RawNote.swift`（本体を書く） | `ensureRawNote`・`rawParts` |
| `Sources/VDPipeline/PartSteps+Deletion.swift` | `requestDeletionsAfterRawNote`（**空。T-38 が書く**） |
| `Sources/VDPipeline/PartSteps.swift`（変更） | `process` から Raw の直後の削除評価を呼ぶ |
| `Sources/VDPipeline/SessionSteps+Daily.swift`（本体を書く） | `ensureDailyNote`・`dailyInput` |
| `Sources/VDPipeline/SessionSteps+Timeline.swift`（本体を書く） | `saveTimeline` |
| `Sources/VDPipeline/AnalysisView+AnalysisResult.swift` | `extension AnalysisView { init(_ r: AnalysisResult) }` |
| `Sources/VDPipeline/VaultPaths.swift` | `VaultPaths`（internal。Vault の URL・Vault からの相対・tmp の候補） |
| `Sources/VDPipeline/TickContext.swift`（変更） | `var vaultIndex: VaultIndex? = nil` を足す |
| `Sources/VDPipeline/Worker.swift`（変更） | 状態 `vaultIndex`・`vaultIndexPath` を足す |
| `Sources/VDPipeline/Worker+NoteStages.swift`（本体を書く） | `stageRefreshVaultIndex` |
| `Sources/VDPipeline/Worker+SessionStages.swift`（変更） | SessionSteps に索引を渡す |
| `Sources/VDPipeline/Recovery+VaultTmp.swift`（本体を書く） | `discardVaultTmp(part:)`・`discardVaultTmp(session:)` |
| `Tests/VDPipelineTests/PipelineFixtures.swift`（変更） | Vault の部品を足す |
| `Tests/VDPipelineTests/RawNoteStepTests.swift` ほか 5 本 | §6 |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 1 キーを消す（§6.8） |

## 4. 仕様

共通: `store`・`layout`・`cfg`・`zone`・`log` は T-18 / T-22 と同じ短縮。例外の扱いも同じ（`guarded` / `ctx.warnStore`）。
Vault の確認は必ず `VaultCheck.evaluate(path: cfg.vault.path, marker: cfg.vault.marker)`（**判定関数は 1 つ**。ガード・Raw・Daily・診断・削除条件が共有する。PLAN §8.7）。

### 4.1 `VaultPaths.swift`（internal）

```swift
// Vault の中のパスの組み立て（PLAN §2.3「ノートは Vault からの相対」・§5.3・§8.8）。文字列で組み立てない。
import Foundation
import VDContract
import VDNotes     // OutputPathResolver.maxSuffix

enum VaultPaths {
    /// cfg.vault.path のディレクトリの URL（`URL(fileURLWithPath: path, isDirectory: true)`）。
    static func root(_ path: String) -> URL
    /// Vault からの相対 POSIX パス（DB の raw_output_path / output_path とログの path）。
    /// `url.standardizedFileURL.path(percentEncoded: false)` が `vault.standardizedFileURL.path(percentEncoded: false)`（末尾に `/` が無ければ足す）で
    /// スカラー単位で始まればその後ろ、そうでなければ url のパス全体（起きない）。
    static func relative(_ url: URL, vault: URL) -> String
    /// DB の相対パスから URL（`vault.appendingPathComponent(relative)`）。
    static func url(_ relative: String, vault: URL) -> URL
    /// 復旧で消す一時ファイル（PLAN §5.3）。existing（DB の出力パス）があればその `.<名前>.tmp` 1 つ。
    /// 無ければ <folder>/<baseName>.md と <baseName> (2).md 〜 (99).md のそれぞれの `.<名前>.tmp`（**名前が完全一致するものだけ**）。
    static func tmpCandidates(vault: URL, existing: String?, folder: String, baseName: String) -> [URL]
}
```
- 一時ファイルの名前は `AtomicFile.tmpURL(for:)`（`.md` を含む。例 `.2026-08-29 raw.md.tmp`。voicedock notes.py:248 と同じ）
- 候補の名前は `baseName + ".md"`、`baseName + " (" + String(n) + ").md"`（n = 2…`OutputPathResolver.maxSuffix`）。OutputPathResolver の候補と同じ並び

### 4.2 `PartSteps+RawNote.swift`（PLAN §8.6・§8.7・§8.8 の呼び手の手順）

```swift
extension PartSteps {
    func ensureRawNote(_ row: RecordingRow) async -> Bool
    /// Raw に載せる Part（RawNoteMembership で絞る。検証側（§8.9.1）と同じ関数）。started_at, partkey 順。
    func rawParts(sessionKey: String) throws -> [RawPart]
}
```

`rawParts(sessionKey:)`（voicedock pipeline.py:592-623）:
1. `for p in try store.recordings(inSession: key)`（started_at, partkey 順）: `t = ctx.sessions.readTranscript(p.partkey)`（T-22。読めなければ nil）。
   `RawNoteMembership.isMember(status: p.status, transcriptReadable: t != nil)` が偽なら飛ばす。`guard let started = zone.parseISO(p.startedAt), let t` で取り出す
2. `RawPart(partkey: p.partkey, startedAt: p.startedAt, endedAt: p.endedAt, segments: t.segments.map { AbsoluteSegment(at: started.adding(milliseconds: SecondsToMillis.fromWhisperSeconds($0.start)), endAt: started.adding(milliseconds: SecondsToMillis.fromWhisperSeconds($0.end)), text: $0.text) }, zone: zone)`
   （**text は strip しない**。RawNote.render が strip する）

（`ctx.sessions` は `PartSteps.sessions`。T-18 §4.13）

**`ensureRawNote(_ row:)`**（この順。voicedock pipeline.py:467-547 ＋ v1.1 のガード）:
0. `PartStates.rawSavedOrBeyond.contains(row.status)` → true。`!PartStates.rawWritable.contains(row.status)` か `row.sessionKey == nil` → false。以降 `guarded`
1. `key = row.sessionKey`、`guard let session = try store.session(key), let day = LocalDate(dashed: session.dayDate) else { return false }`
2. `parts = try rawParts(sessionKey: key)`。~~空 → false（遷移しない。voicedock どおり）~~（F-75: 空でも止まらない。トリガが載らなければ手順 6a）
3. **ガード**: `status = VaultCheck.evaluate(path: cfg.vault.path, marker: cfg.vault.marker)`。`.available` でなければ
   `ctx.pauses.trip(status == .notConfigured ? .vaultNotConfigured : .vaultUnavailable)` → **遷移せず** false
4. `ctx.activity.set(.writingRawNote(sessionKey: key))`
5. `row.status == .transcribed` なら `TRANSCRIBED→RAW_WRITING`（RAW_WRITING から来たら記録しない）
6. **もう一度確かめる**: `status2 = VaultCheck.evaluate(…)`。`.available` でなければ
   `try fail(row, from: .rawWriting, code: .obsidianNotFound, message: status2.message(path: cfg.vault.path ?? "", marker: cfg.vault.marker), event: .rawNoteFailed, reason: "vault")` → false
6a. （F-75）トリガが `parts` に居なければ `fail(row, from: .rawWriting, code: .obsidianRawWriteFailed, message: <「文字起こしを読めません: <HOME 相対>」か「開始時刻を読めません: <started_at>」>, event: .rawNoteFailed, reason: "write")` → false
7. `vault = VaultPaths.root(cfg.vault.path!)`（`guard let`）、`content = RawNote.render(parts: parts, day: day, sessionKey: key, config: cfg.obsidian)`
8. `folder = try NoteFolder.ensure(relative: RawNote.folder(config: cfg.obsidian, day: day), vault: vault)`。投げたら
   `try fail(row, from: .rawWriting, code: .obsidianRawWriteFailed, message: NoteErrorText.describe(e), event: .rawNoteFailed, reason: "write")` → false
9. `owned = Set(try store.recordings(inSession: key).map(\.partkey))`（状態を問わず、この Session に属する全 Part）、
   `existing = session.rawOutputPath.map { VaultPaths.url($0, vault: vault) }`、
   `OutputPathResolver.resolve(folder: folder, baseName: RawNote.baseName(config: cfg.obsidian, day: day), existing: existing, sessionKey: key, ownedPartkeys: owned, kind: .raw)`。
   `.failure(f)`（99 超え）→ `fail(row, from: .rawWriting, code: f.code, message: f.message, event: .rawNoteFailed, reason: "write")` → false
9a. （F-75）`OutputPathResolver.keysLostByOverwrite(target, protectedKeys: <rawSavedOrBeyond の Part の鍵>, newKeys: <parts の鍵>)` が nil か空でなければ、書かずに
    `fail(… .obsidianRawWriteFailed, …, reason: "write")` → false（文言は PLAN §8.6）
10. `sha = try NoteWriter.write(content, to: target)`。投げたら `fail(… .obsidianRawWriteFailed, NoteErrorText.describe(e), reason: "write")` → false
11. `v = NoteVerifier.verify(url: target, kind: .raw, sessionKey: key, expectedSHA256: sha, expectedKeys: Set(parts.map(\.partkey)), summaryHeading: DailyNote.summaryHeading(config: cfg))`。
    `!v.passed` → `fail(… .obsidianRawVerifyFailed, v.failureMessage, reason: "verify")` → false（`落ちた規則: RN-1, RN-5` の形）
12. **全部合格してから** DB: `try store.updateSession(key, [.rawOutputPath(VaultPaths.relative(target, vault: vault)), .rawOutputSHA256(sha)])` → `RAW_WRITING→RAW_SAVED`
    （**DB 更新が成功するまで保存済みとみなさない**）
13. `log.info(.rawNoteSaved, [(.sessionKey, key), (.parts, .of(parts.count)), (.bytes, .of(content.utf8.count))])`
14. `cfg.audio.retain == .rawSaved` かつ `row.inboxPath` が在れば `try? SafeUnlink.remove(layout.url(relative: inboxPath), under: .inbox, layout: layout)`（§8.3 手順 7 の「同じ規則」: DB 更新の後・失敗は無視。**このトリガ Part の原本だけ**）
15. `_ = ctx.sessions.reopenSession(key)`（SAVED / 削除段 / COMPLETED の Session を MERGING へ。T-22）→ true

- **FAILED にするのはトリガの Part 1 件だけ**（SM-15）。同じ Raw に載るほかの TRANSCRIBED の Part は動かさない（次に自分の番で書き直す）
- `fail` はその Part の Session の再オープンも行う（T-18 §4.13）

### 4.3 `PartSteps+Deletion.swift` と `process` の変更（PLAN §5.5・§8.9.5）

```swift
// Raw ノートを保存した直後の削除評価（PLAN §5.5。その Part だけでなく Session の全 Part）。本体は T-38。
extension PartSteps {
    /// 書いた要求の数（T-38 が requestDeletions(session) を呼ぶ。snapshot の新鮮さは要求を書く直前に確かめる。DEL-20）。
    func requestDeletionsAfterRawNote(sessionKey: String) async -> Int { 0 }     // T-38 が中身を書く
}
```

`PartSteps.process(partkey:)` の最後を次にする（T-18 §4.13 からの差分）:
```text
guard let r2 = reload(partkey), await ensureRawNote(r2) else .stopped
if let key = reload(partkey)?.sessionKey { _ = await requestDeletionsAfterRawNote(sessionKey: key) }
return .readyForSession
```
（RAW_SAVED 以降の Part でも呼ぶ。voicedock pipeline.py:281 と同じ。SOURCE_DELETING と COMPLETED の Part を飛ばすのは T-38 の requestDeletions）

### 4.4 `AnalysisView+AnalysisResult.swift`

```swift
// 解析結果（VDLLM）を Daily の入力（VDNotes）へ写す。VDNotes は VDLLM を import できないので VDPipeline に置く。
import VDLLM
import VDNotes
extension AnalysisView {
    init(_ r: AnalysisResult) {
        self.init(title: r.title, summary: r.summary, keyPoints: r.keyPoints, decisions: r.decisions, ideas: r.ideas,
                  tags: r.tags, tasks: r.tasks?.map { (text: $0.text, due: $0.due) })
    }
}
```

### 4.5 `SessionSteps+Timeline.swift`（PLAN §8.5 書き込み 2・§8.6 Timeline）

```swift
extension SessionSteps {
    /// analysis/<slug>.timeline.json を書く。書けなくても失敗にしない（config_warning rule=timeline を出す）。
    func saveTimeline(sessionKey: String, summary: String?, partials: [AnalysisResult], chunks: [Chunk],
                      transcript: SessionTranscript, fingerprint: String)
}
```
1. `blocks = Timeline.build(partials: partials.map(AnalysisView.init), chunks: chunks.map { (start: $0.startAt, end: $0.endAt) }, transcript: transcript, summary: summary)`
   （Map-Reduce なら 1 段目の Map 結果とチャンクの組、単一パスなら summary の文を Session の各 Block に。規則は T-27）
2. `try AtomicFile.write(Timeline.encode(blocks, fingerprint: fingerprint, zone: zone), to: layout.timelineJSON(sessionSlug: KeySlug.of(sessionKey)))`。
   投げたら `log.warning(.configWarning, [(.rule, "timeline"), (.message, .string(ErrorText.describe(e)))])` で続ける（解析は成功のまま）

### 4.6 `SessionSteps+Daily.swift`（PLAN §5.6 末尾・§8.6・§8.7・§8.8 の呼び手の手順）

```swift
extension SessionSteps {
    func ensureDailyNote(_ key: String, _ t: SessionTranscript) async -> Bool
    /// Daily の入力（T-27 の DailyInput）。
    func dailyInput(row: SessionRow, analysis: AnalysisResult, parts: [RecordingRow], day: LocalDate, transcript: SessionTranscript) -> DailyInput
}
```

**`ensureDailyNote(key, t)`**（この順。voicedock pipeline.py:1229-1334 ＋ v1.1）:
0. `guard let row = try store.session(key) else false`。`SessionStates.savedOrBeyond.contains(row.status)` → true。
   `!SessionStates.writable.contains(row.status)` か `row.analysisPath == nil` → false。`guard let day = LocalDate(dashed: row.dayDate) else false`
1. **ガード**: `VaultCheck.evaluate(…)` が `.available` でなければ `vaultNotConfigured` / `vaultUnavailable` を trip → **遷移せず** false
2. `ctx.activity.set(.writingDailyNote(sessionKey: key, dayDate: row.dayDate))`
3. `row.status == .analyzed` なら `ANALYZED→WRITING`（**遷移を記録してから解析 JSON を読む**。WRITING から来たら記録しない）
4. `guard let analysis = loadAnalysis(key)`（T-22。最終形のスキーマで検証）でなければ
   `try failSession(key, from: .writing, code: .obsidianWriteFailed, message: "解析結果を読めません: \(row.analysisPath ?? "")", event: .obsidianFailed, reason: "write")` → false
5. **もう一度確かめる**: `.available` でなければ `failSession(key, from: .writing, code: .obsidianNotFound, message: status.message(path:marker:), event: .obsidianFailed, reason: "vault")` → false
6. `parts = try store.recordings(inSession: key)`、`input = dailyInput(row: row, analysis: analysis, parts: parts, day: day, transcript: t)`、`content = DailyNote.render(input, config: cfg)`
7. `vault = VaultPaths.root(…)`、`folder = try NoteFolder.ensure(relative: DailyNote.folder(config: cfg.obsidian, day: day), vault: vault)`。
   投げたら `failSession(… .obsidianWriteFailed, NoteErrorText.describe(e), event: .obsidianFailed, reason: "write")` → false
8. `OutputPathResolver.resolve(folder: folder, baseName: DailyNote.baseName(config: cfg.obsidian, day: day), existing: row.outputPath.map { VaultPaths.url($0, vault: vault) }, sessionKey: key, ownedPartkeys: Set(parts.map(\.partkey)), kind: .daily)`。
   `.failure(f)` → `failSession(… f.code, f.message, reason: "write")` → false
9. `sha = try NoteWriter.write(content, to: target)`。投げたら `failSession(… .obsidianWriteFailed, NoteErrorText.describe(e), reason: "write")` → false
10. `v = NoteVerifier.verify(url: target, kind: .daily, sessionKey: key, expectedSHA256: sha, expectedKeys: Set(input.recordingKeys), summaryHeading: DailyNote.summaryHeading(config: cfg))`。
    `!v.passed` → `failSession(… .obsidianVerifyFailed, v.failureMessage, reason: "verify")` → false（DN-7 は included の鍵と**完全一致**）
11. `rel = VaultPaths.relative(target, vault: vault)`、`try store.updateSession(key, [.outputPath(rel), .outputSHA256(sha), .errorCode(nil), .errorMessage(nil)])` → `WRITING→SAVED`
12. `log.info(.obsidianSaved, [(.sessionKey, key), (.path, .string(rel)), (.bytes, .of(content.utf8.count))])` → true

**`dailyInput(…)`**（voicedock pipeline.py:1336-1400）:
1. `included = parts.filter { $0.status != .failed && $0.status != .skipped }`、`excluded = parts.filter { $0.status == .failed || $0.status == .skipped }`（どちらも started_at, partkey 順のまま）
2. `fp = TranscriptFingerprint.of(transcript, zone: zone)`
3. Timeline: `blocks = Timeline.decode((try? Data(contentsOf: layout.timelineJSON(sessionSlug: KeySlug.of(key)))) ?? Data(), fingerprint: fp, zone: zone)`（**保存済みの Map 結果を優先**。読めない・指紋が違う → 空）。
   空なら代替経路 `Timeline.build(partials: [], chunks: [], transcript: transcript, summary: analysis.summary)`
4. リンク（`w = cfg.obsidian`）:
   ```swift
   LinkPlanner.plan(config: w, day: day, tags: analysis.tags ?? [], index: w.wiki.linkTags ? ctx.vaultIndex : nil,
                    selfName: DailyNote.baseName(config: w, day: day),
                    nameForDay: { DailyNote.baseName(config: w, day: $0) },
                    rawNames: [DailyNote.rawLinkName(rawOutputPath: row.rawOutputPath, config: w, day: day)])
   ```
   （タグの候補は**解析の tags そのもの**。Raw のリンク先は DB の raw_output_path の basename（X-15））
5. `DailyInput(analysis: AnalysisView(analysis), day: day, sessionKey: key, recordingKeys: included.map(\.partkey),
   excluded: excluded.map { ExcludedPart(partkey: $0.partkey, status: $0.status, errorCode: $0.errorCode,
                                           unknownCode: $0.errorCode == nil ? $0.errorCodeRaw : nil) },
   recordedSeconds: row.recordedSeconds, blockCount: transcript.blocks.count, timeline: blocks, links: plan, zone: zone)`
   （`recordedSeconds` は Session の列で**除外 Part も含む**。`RecordingRow.errorCode` は未知の文字列を nil に写すが、生の文字列は `errorCodeRaw` に残る（T-11）ので、未知のコードはそれを `unknownCode` に渡す。§11 の提案 3）

### 4.7 Vault 索引（`Worker+NoteStages.swift`・`TickContext`・`Worker`。PLAN §8.6 WikiLink・NOTE-11。voicedock worker.py:309-324）

- `TickContext` に `var vaultIndex: VaultIndex? = nil` を足す（既存の初期化の呼び出しは変えない）
- `Worker` に `var vaultIndex: VaultIndex? = nil`、`var vaultIndexPath: String? = nil` を足す

```text
func stageRefreshVaultIndex(_ ctx: TickContext) async:
  wiki = ctx.config.obsidian.wiki
  guard wiki.linkTags else { vaultIndex = nil; vaultIndexPath = nil; return }            // linkTags が偽なら作らない
  guard let path = ctx.config.vault.path, VaultCheck.evaluate(path: path, marker: ctx.config.vault.marker).isAvailable else return   // 使えない Vault では作り直さない（前の索引を保つ）
  now = ctx.deps.clock.uptime()                                                        // 単調時計（TIME-06）
  if let idx = vaultIndex, let built = vaultIndexPath, PyText.scalarsEqual(built, path), !idx.isStale(ttlSeconds: wiki.vaultIndexCacheSeconds, now: now): return   // パスの比較はスカラー単位
  vault = VaultPaths.root(path); prefix = VaultIndex.rawFolderPrefix(ctx.config.obsidian.raw.folderTemplate)
  guard let built = try? await BlockingIO.run({ VaultIndex.build(vault: vault, excludePrefixes: [prefix], builtAt: now) }) else return
  vaultIndex = built; vaultIndexPath = path
```
- 索引は Worker が tick をまたいで持つ（毎回作らない。voicedock 変更 BK-3）。Vault の場所が変わったら TTL を待たずに作り直す

`Worker+SessionStages.swift`（T-22）の変更: `SessionSteps(ctx: ctx)` を `var c = ctx; c.vaultIndex = vaultIndex; SessionSteps(ctx: c)` にする（1 か所）。

### 4.8 `Recovery+VaultTmp.swift`（PLAN §5.3 の本計画の差分。voicedock は残していた）

```swift
extension Recovery {
    func discardVaultTmp(part row: RecordingRow)
    func discardVaultTmp(session row: SessionRow)
}
```
共通の前置き: `guard let path = config.vault.path, VaultCheck.evaluate(path: path, marker: config.vault.marker).isAvailable else { return }`（**Vault の確認が通ったときだけ**）、`vault = VaultPaths.root(path)`。

- `part`: `guard let key = row.sessionKey, let s = try? store.session(key) ?? nil, let day = LocalDate(dashed: s.dayDate) else return`、
  `targets = VaultPaths.tmpCandidates(vault: vault, existing: s.rawOutputPath, folder: RawNote.folder(config: config.obsidian, day: day), baseName: RawNote.baseName(config: config.obsidian, day: day))`
- `session`: `guard let day = LocalDate(dashed: row.dayDate)`、`targets = VaultPaths.tmpCandidates(vault: vault, existing: row.outputPath, folder: DailyNote.folder(config: config.obsidian, day: day), baseName: DailyNote.baseName(config: config.obsidian, day: day))`
- 各 target に `SafeUnlink.remove(target, under: .vaultTmp(vault: vault), layout: layout, missingOK: true)`。失敗は T-18 §4.9 と同じ `config_warning rule=recovery`（パスは Vault からの相対）で続ける

## 5. ログ（このチケットが出すもの）

| イベント | レベル | フィールド |
|---|---|---|
| `raw_note_saved` | INFO | `session_key`, `parts`, `bytes` |
| `raw_note_failed` | ERROR | `recording_key`, `error_code`, `reason`（`vault` / `write` / `verify`） |
| `obsidian_saved` | INFO | `session_key`, `path`（Vault からの相対）, `bytes` |
| `obsidian_failed` | ERROR | `session_key`, `error_code`, `reason`, `detail` |
| `config_warning` | WARNING | `rule=timeline` / `rule=recovery`, `message` |
| `pipeline_paused` / `pipeline_resumed` | WARNING / INFO | `reason=vault_not_configured` / `vault_unavailable` |

## 6. テスト

共通: T-18 / T-22 と同じ。`import VDNotes` を足す。

### 6.0 `PipelineFixtures.swift` への追加

- `var vaultURL: URL`（`tmp.url.appendingPathComponent("vault", isDirectory: true)`）、`var vaultPath: String`（`tmp.url.appendingPathComponent("vault").path(percentEncoded: false)`。末尾の `/` なし）
- `func installVault(marker: Bool = true) async throws -> URL`（`ConfigStore.update` が async なので async）: `vaultURL` を作り、`marker` なら `.obsidian/` も作る。`update { $0.vault.path = vaultPath }`（`.success` でなければ投げる）
- `typealias PartSpec = (relpath: String, startedAt: String, seconds: Double)`、`static let vaultSessionKey = "DJIMIC3:20260829"`
- `static let partA = (relpath: "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav", startedAt: "2026-08-29T07:12:04+09:00", seconds: 2.0)`
- `static let partB = (relpath: "TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav", startedAt: "2026-08-29T07:42:10+09:00", seconds: 3.0)`（A と違う長さにして SHA を変える。重複にしない）
- `static let partC = (relpath: "TX_MIC001_20260829_093000/TX01_MIC002_20260829_093000_orig.wav", startedAt: "2026-08-29T09:30:00+09:00", seconds: 2.0)`
- `static let whisperSegments = [TranscriptSegment(start: 0.0, end: 3.2, text: "おはようございます。"), TranscriptSegment(start: 5.5, end: 9.0, text: "今日の予定を確認します。")]`（FakeWhisper の既定と同じ）
- `func addPart(_ spec: (relpath: String, startedAt: String, seconds: Double), status: PartStatus, sessionKey: String = "DJIMIC3:20260829", segments: [TranscriptSegment]? = whisperSegments, inbox: Bool = false) throws -> String`:
  行を `registerRow` と同じ形で入れ（`inbox` なら BWF も書く）、`forcePart(pk, status:, sessionKey:)` → `store.refreshSessionAggregates(sessionKey)`（Session が在れば）→ `segments` が nil でなければ
  `PartTranscriptCodec.encode(PartTranscript(partkey: pk, language: "ja", durationSeconds: spec.seconds, startedAt: spec.startedAt, text: <segments の text を連結>, segments: segments))` を `layout.transcript(slug:)` に書く
- `func noteText(_ relative: String) throws -> String`: Vault の中のファイルを UTF-8 で読む

### 6.1 `RawNoteStepTests.swift`（`@Suite(.serialized)`）

準備（既定）: `installVault()`、`addSession(key: "DJIMIC3:20260829", day: "2026-08-29", status: .ready)`、`addPart(partA, status: .transcribed)`。`PartSteps(ctx: try await world.context())` で呼ぶ。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `writesVerifiedRawNote` / 「Raw を書いて検証し、DB の後に RAW_SAVED」 | 既定 | 真、RAW_SAVED、`raw_output_path == "Daily/Voice/Raw/20260829/2026-08-29 raw.md"`、`raw_output_sha256` == ファイルの SHA-256、中身が §6.6 の「期待 R1」とバイト一致、ログ `raw_note_saved session_key=DJIMIC3:20260829 parts=1 bytes=<期待 R1 の UTF-8 バイト数>` |
| `vaultNotConfiguredIsAGuard` / 「Vault 未設定なら遷移せずに待つ」 | vault.path nil | 偽、TRANSCRIBED、`pipeline_paused reason=vault_not_configured` |
| `missingMarkerIsAGuard` / 「目印が無ければ遷移せずに待つ（幻の Vault に書かない）」 | `installVault(marker: false)` | 偽、TRANSCRIBED、`reason=vault_unavailable`、Vault の中に何も作られない |
| `vaultLostAfterTransitionFails` / 「遷移の後に Vault が消えたら OBSIDIAN_NOT_FOUND」 | `world.context(assertion: RecordingSleepAssertion(onBegin: { .obsidian を消す }))` で `PartSteps` を作る | FAILED(OBSIDIAN_NOT_FOUND)、message `<vault> に .obsidian/ がありません（Vault が未マウントか、別の場所を指しています）`、`raw_note_failed recording_key=… error_code=OBSIDIAN_NOT_FOUND reason=vault` |
| `rawWritingEntryRecordsNoPhantom` / 「RAW_WRITING から入っても遷移を記録しない」（voicedock test_part_resume :207） | Part を RAW_WRITING に | RAW_SAVED、`TRANSCRIBED→RAW_WRITING` の events が無い |
| `membersUseTheSharedFunction` / 「載せる Part は RawNoteMembership（読めない transcript は載せない）」 | ほかに RAW_SAVED で transcript の無い Part と、TRANSCRIBING の Part | frontmatter の鍵は A だけ、検証は通る |
| ~~`noMembersStaysTranscribed` / 「載せる Part が無ければ何もしない」~~（F-75 で取り下げ。`RawNoteTextProtectionTests.unreadableTriggerAloneFails` へ） | A の transcript を消す | ~~偽、TRANSCRIBED、events 増えない~~ → 偽、FAILED(OBSIDIAN_RAW_WRITE_FAILED) |
| `existingOutputPathIsKept` / 「DB の出力パスがあればそこへ書く」 | `raw_output_path = "Daily/Voice/Raw/20260829/2026-08-29 raw (2).md"`（ファイル無し） | そのパスに書かれ、基本名のファイルは無い |
| `foreignNoteIsNotOverwritten` / 「X-11 DB に無い鍵を持つノートは上書きしない」 | `2026-08-29 raw.md` に同じ session_key で `DJIMIC3/other_orig.wav` を持つ frontmatter | 元のファイルは変わらず、` (2).md` に書かれる |
| `ownNoteIsOverwritten` / 「自分の鍵だけのノートは上書きする（rename の後に落ちた場合）」 | `2026-08-29 raw.md` に A の鍵だけ（raw_output_path は NULL） | 基本名のファイルが書き直される |
| `tooManyNamesFails` / 「99 を超えたら OBSIDIAN_RAW_WRITE_FAILED」 | 基本名と (2)〜(99) のすべてに他人のノート | FAILED、message `同名ファイルが多すぎます: 2026-08-29 raw.md`、`reason=write` |
| `writeFailureIsRawWriteFailed` / 「書けなければ OBSIDIAN_RAW_WRITE_FAILED（tmp を残さない）」 | `Daily/Voice/Raw/20260829` を作って 0o555 に | FAILED、message が `AtomicFileError: ` で始まる、フォルダに `.tmp` が無い |
| `onlyTheTriggerFails` / 「SM-15 FAILED にするのはトリガの Part だけ」 | 同じ Session の TRANSCRIBED の Part B も在る状態で、上の書けない条件 | A は FAILED、B は TRANSCRIBED のまま |
| `reopensAFinishedSession` / 「RAW_SAVED で確定済みの Session を再オープンする」（voicedock test_session_reopen :383） | Session を SAVED・SOURCE_DELETE_PENDING にしておく（パラメータ化） | MERGING、`session_reopened` |
| `ceAudioInboxRetainRawSavedReleases` / 「CE audio.inboxRetain raw_saved なら RAW_SAVED の直後に inbox を消す」 | raw_saved、A の inbox にファイル | RAW_SAVED の後に inbox が無い（normalized のときは Raw の工程で触らない: 別のファイルを置いて残ることを確かめる） |
| `rawSavedOrBeyondIsTrue` / 「RAW_SAVED 以降は真を返すだけ」（パラメータ化） | RAW_SAVED・SOURCE_DELETING・COMPLETED | 真、Vault を触らない |

### 6.2 `DailyNoteStepTests.swift`（`@Suite(.serialized)`。`installLLM()`・`installVault()`）

準備（既定）: `addSession(key: "DJIMIC3:20260829", day: "2026-08-29", status: .merged)`、`addPart(partA, status: .rawSaved)`（recorded_seconds 2.0 になる）、
`updateSession(… [.rawOutputPath("Daily/Voice/Raw/20260829/2026-08-29 raw.md")])`。`t = buildSessionTranscript("DJIMIC3:20260829")`、
`ensureAnalysis` を 1 回回して ANALYZED にし解析のファイルを作る（chat は `ANALYSIS`）。その後 `ensureDailyNote(key, t)` を呼ぶ。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `writesVerifiedDailyNote` / 「Daily を書いて検証し、SAVED」 | 既定 | 真、SAVED、`output_path == "Daily/Voice/Wiki/20260829/2026-08-29 Voice.md"`、`output_sha256` == SHA、中身が §6.6 の「期待 D1」とバイト一致、ログ `obsidian_saved session_key=DJIMIC3:20260829 path="Daily/Voice/Wiki/20260829/2026-08-29 Voice.md" bytes=<n>` |
| `guardsDoNotTransition` / 「Vault のガードは遷移しない」（パラメータ化） | vault.path nil／目印なし | 偽、ANALYZED のまま、理由 `vault_not_configured`／`vault_unavailable` |
| `unreadableAnalysisIsWriteFailed` / 「解析 JSON が読めなければ WRITING を記録してから FAILED」 | analysis.json を `{` に | events の最後 2 本 `(ANALYZED, WRITING)`・`(WRITING, FAILED)`、error `OBSIDIAN_WRITE_FAILED`、message `解析結果を読めません: analysis/<slug>.json`、ログ `obsidian_failed session_key=… error_code=OBSIDIAN_WRITE_FAILED reason=write detail="解析結果を読めません: …"` |
| `vaultLostAfterTransitionFails` / 「遷移の後に Vault が消えたら OBSIDIAN_NOT_FOUND」 | 6.1 と同じ注入 | FAILED(OBSIDIAN_NOT_FOUND)、`reason=vault` |
| `writingEntryRecordsNoPhantom` / 「WRITING から入っても ANALYZED→WRITING を書かない」（test_session_resume :326） | WRITING | SAVED、`ANALYZED→WRITING` が 1 本も増えない |
| `savedTimelineIsPreferred` / 「保存済みの Timeline を使う」（test_session_analysis :601） | timeline.json を正しい指紋・lines `["保存済みの点"]` で書く | 本文に `- 保存済みの点` を含み、`- 削除条件を整理した。` を含まない |
| `staleTimelineFallsBack` / 「指紋の違う Timeline は使わず summary の文へ落ちる」（:630） | timeline.json の指紋を `"0" × 64` に | 本文に `- 削除条件を整理した。` |
| `missingTimelineFallsBack` / 「Timeline が無ければ代替経路」 | timeline.json を消す | 同上 |
| `sourcesPointToActualRaw` / 「X-15 Sources は実際の Raw の名前」 | `raw_output_path = "Daily/Voice/Raw/20260829/2026-08-29 raw (2).md"` | `- [[2026-08-29 raw (2)]]` を含む |
| `tagLinksUseTheIndex` / 「タグのリンクは Vault 索引に在るものだけ」 | `ctx.vaultIndex = VaultIndex(names: [VaultIndex.normalize("VoiceDock")], builtAt: .zero)` と nil | 在れば Links に `- [[VoiceDock]]`、無ければ無い |
| `excludedPartsAreWarnedAndNotListed` / 「除外 Part は警告行に出て recording_keys に載らない（DN-7）」 | FAILED(WHISPER_FAILED) の Part と SKIPPED(NO_SPEECH_DETECTED) の Part を足す | `voicedock_recording_keys` は A だけ、`voicedock_failed_parts`・`voicedock_skipped_parts` に 1 つずつ、`> ⚠ この日の録音のうち 1 本が…` と `> この日の録音のうち 1 本を除外しました（無音）。…` を含む、検証が通る |
| `unknownErrorCodeIsShownAsRaw` / 「M-1 未知のエラーコードは生の文字列で警告に出る」 | **SKIPPED** の Part の `error_code` を `"FUTURE_CODE_X"`（`ErrorCode` に無い値）に直に書く（理由を行に出すのは SKIPPED の警告行だけ。FAILED の行は本数だけ。T-27 `DailyWarnings.lines`） | `ExcludedPart.errorCode == nil`・`unknownCode == "FUTURE_CODE_X"`、警告行 `> ⚠ この日の録音のうち 1 本を除外しました（FUTURE_CODE_X）。自動では再試行されません。デバイスから採り直してください。` が出る（`DailyWarnings.displayName` の既定。未知の理由は操作が要る側） |
| `ownDailyIsOverwritten` / 「DB の出力パスのノートは上書きする」 | 1 回書いた後、ANALYZED に強制してもう一度 | 同じ output_path、ファイルは 1 つ |
| `foreignDailyIsNotOverwritten` / 「他人の Daily は上書きしない」 | `2026-08-29 Voice.md` に DB に無い鍵 | ` (2).md` に書かれる |

### 6.3 `TimelineSaveTests.swift`

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `singlePassTimelineIsSaved` / 「単一パスは summary の文を Block ごとに」 | 6.2 の準備で ensureAnalysis | timeline.json が `{\n  "schema": 2,\n  "transcript_sha256": "<fp>",\n  "blocks": [\n    {\n      "start_at": "2026-08-29T07:12:04+09:00",\n      "end_at": "2026-08-29T07:12:06+09:00",\n      "lines": [\n        "削除条件を整理した。"\n      ]\n    }\n  ]\n}\n` |
| `mapReduceTimelineUsesPartials` / 「Map-Reduce は Map の結果とチャンクの時刻」 | Part A と Part C（RAW_SAVED。間隔が `maxSecondsPerRequest` の既定 3600 秒を超えるので 2 チャンク）、chat の応答を順に `{"summary":"朝","key_points":["朝の要点"]}`・`{"summary":"昼","key_points":[]}`・`ANALYSIS` | blocks 2 つ: `07:12:04`〜`07:12:13` の lines `["朝の要点"]`、`09:30:00`〜`09:30:09` の lines `["昼"]`（key_points が空なら summary の文） |
| `timelineWriteFailureIsNotFatal` / 「Timeline を書けなくても解析は成功」 | timeline.json の位置にディレクトリ | ANALYZED、ログ `config_warning rule=timeline` |

### 6.4 `VaultIndexStageTests.swift`（voicedock test_worker_loop :962-1015）

準備: `installVault()`、Vault に `Topics/VoiceDock.md` と `Daily/Voice/Raw/20260829/2026-08-29 raw.md` を置く。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `indexIsBuiltAndExcludesRaw` / 「索引を作り Raw のフォルダを除く」 | tick | 索引が `VoiceDock` を含み `2026-08-29 raw` を含まない |
| `indexIsKeptAcrossTicks` / 「TTL の間は作り直さない」（:962） | tick → `clock.advance(seconds: 299)` → tick | `builtAt` が同じ |
| `staleIndexIsRebuilt` / 「TTL が過ぎたら作り直す（等号で古い）」（:990） | tick → `advance(seconds: 300)` → tick | `builtAt` が進む |
| `ceVaultIndexCacheSeconds` / 「CE obsidian.wiki.vaultIndexCacheSeconds 0 なら毎回作る」 | 0、tick を 2 回（時計は動かさない） | 2 回目も作り直す（`Topics/New.md` を足すと 2 回目の索引に在る） |
| `linkTagsOffDropsIndex` / 「linkTags が偽なら索引を持たない」 | linkTags false | 索引が nil |
| `unavailableVaultKeepsIndex` / 「使えない Vault では前の索引を保つ」 | tick の後に `.obsidian` を消して TTL を過ぎてから tick | 索引は前のまま |
| `vaultChangeRebuilds` / 「Vault の場所が変われば作り直す」 | 別の Vault に替えて tick | 新しい Vault の名前の索引 |

### 6.5 `RecoveryVaultTmpTests.swift`

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `rawTmpByOutputPath` / 「raw_output_path があればその tmp だけ消す」 | RAW_WRITING の Part、Session の raw_output_path `Daily/Voice/Raw/20260829/2026-08-29 raw (2).md`、その `.2026-08-29 raw (2).md.tmp` と `.2026-08-29 raw.md.tmp` | 前者だけ消え、後者は残る |
| `rawTmpCandidates` / 「出力パスが無ければ候補名の tmp（完全一致だけ）を消す」 | raw_output_path NULL、`.2026-08-29 raw.md.tmp`・`.2026-08-29 raw (3).md.tmp`・`.2026-08-29 raw.md.tmp.bak`・`.other.md.tmp` | 前の 2 つだけ消える |
| `dailyTmpForWritingSession` / 「WRITING の Session は Daily の tmp」 | WRITING の Session、`Daily/Voice/Wiki/20260829/.2026-08-29 Voice.md.tmp` | 消える、Session は ANALYZED |
| `unavailableVaultIsNotTouched` / 「Vault の確認が通らなければ消さない」 | 目印なし | tmp が残る、Part は TRANSCRIBED に戻る |
| `symlinkTmpIsNotFollowed` / 「tmp が symlink なら消さない」 | `.2026-08-29 raw.md.tmp` が Vault の外のファイルへの symlink | symlink も外のファイルも残る、`config_warning rule=recovery` |

### 6.6 `PipelineIntegrationTests.swift`（`@Suite("BWF から Daily まで", .serialized)`。**本物の AVFoundation・本物の ProcessRunner と FakeWhisper・FakeChatTransport・FakeLLMServer**）

（注記・T-38: SAVED の直後の削除段が中身を持った後は、既定の設定（削除無効）で Part が COMPLETED、Session が SAVED→CLEANUP→COMPLETED まで進む。下の「期待」の状態は T-38 §6.12 が直した。）

準備: `PipelineWorld.make(chat: FakeChatTransport(responses: [.content(ANALYSIS), .content(ANALYSIS)]))`（時計は 2026-08-30T07:00:12+09:00）、
`installWhisper()`、`installLLM()`、`installVault()`、`registerPart(relpath: partA.relpath, startedAt: partA.startedAt, seconds: partA.seconds)`。

| 関数名 / 表示名 | 手順 | 期待 |
|---|---|---|
| `oneTickFromBWFToVerifiedDaily` / 「1 tick で BWF → 16 kHz → 文字起こし → Raw → 統合 → 解析 → Daily」 | `worker.start()` → `worker.tick()` | 下の「期待 1」 |
| `secondPartReopensAndRewrites` / 「同じ日の 2 本目で Raw を書き直し、再オープン・再解析して Daily を書き直す」 | 上の後に `registerPart(partB…)` → `tick()` | 下の「期待 2」 |
| `missingVaultPausesThenResumes` / 「Vault の目印が無い間は待ち、戻れば続きから進む」 | `installVault(marker: false)` で tick → `.obsidian` を作って tick | 1 回目: Part TRANSCRIBED、Session READY、`pipeline_paused reason=vault_unavailable`、Vault に何も無い。2 回目: Part RAW_SAVED、Session SAVED、`pipeline_resumed reason=vault_unavailable` |

**期待 1**:
- Part A: RAW_SAVED。events の to の列 `[DISCOVERED, NORMALIZING, NORMALIZED, TRANSCRIBING, TRANSCRIBED, RAW_WRITING, RAW_SAVED]`。inbox と `staging/<slug>/audio16k.wav` が無く、`transcripts/parts/<slug>.json` が在る
- Session `DJIMIC3:20260829`: SAVED。events の to の列 `[OPEN, OPEN, READY, MERGING, MERGED, ANALYZING, ANALYZED, WRITING, SAVED]`（2 つ目の OPEN は detail = Part A の鍵、READY は `stale_day`。F-66 で `stale_day` は廃止し、テストは今すぐ要約を入れて READY を `summarize_now` にした）。
  `raw_output_path == "Daily/Voice/Raw/20260829/2026-08-29 raw.md"`、`output_path == "Daily/Voice/Wiki/20260829/2026-08-29 Voice.md"`、`analysis_path == "analysis/<slug>.json"`、title `開発の一日`、regenerated_count 0
- Raw の中身 == 期待 R1、Daily の中身 == 期待 D1。`NoteVerifier.verify` を DB の SHA と鍵で呼び直して両方とも `passed`
- chat: 1 回、system == `prompts.analyze(最終形, custom: "")`、user == `おはようございます。\n今日の予定を確認します。`。`llm.ensureCalls.count == 1`、`llm.stopCount == 1`
- `analysis/<slug>.timeline.json` と `.source.json` が在る
- ログに（この順で）`normalize_completed`・`transcription_completed`・`raw_note_saved`・`session_merged … parts=1 excluded=0 chars=22`・`llm_completed … chunks=1`・`obsidian_saved`

**期待 R1**（Raw。最後の行の後に `\n` が 1 つ）:
```text
---
type: "voice-raw"
voicedock_session_key: "DJIMIC3:20260829"
voicedock_recording_keys:
  - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
date: "2026-08-29"
parts: 1
source: "DJI Mic 3"
---

# 2026-08-29 の文字起こし（生データ）

> 自動文字起こしの生データ。未編集。

## 07:12–07:12

### 07:12:04

おはようございます。 今日の予定を確認します。
```

**期待 D1**（Daily。最後の行の後に `\n` が 1 つ。`VoiceDock` タグは既定タグ `voicedock` と casefold で重なるので frontmatter に出ず、索引に無いので Links にも出ない）:
```text
---
type: "voice-daily"
voicedock_session_key: "DJIMIC3:20260829"
voicedock_recording_keys:
  - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
voicedock_failed_parts: []
voicedock_skipped_parts: []
date: "2026-08-29"
recorded: "00:00:02"
parts: 1
blocks: 1
status: "processed"
tags:
  - "voice"
  - "voicedock"
---

# 開発の一日

## Summary

削除条件を整理した。

## Timeline

### 07:12–07:12

- 削除条件を整理した。

## Key Points

- 論理式に落とした

## Tasks

- [ ] ND テストを書く

## Sources

- [[2026-08-29 raw]]

## Links

- [[2026-08-29]]
- [[2026-08-28 Voice]]
- [[2026-08-30 Voice]]
```

**期待 2**:
- Part B: RAW_SAVED。Part A は RAW_SAVED のまま
- Session: SAVED、regenerated_count 1。追加の events の to の列 `[MERGING(detail reopen), MERGED, ANALYZING, ANALYZED, WRITING, SAVED]`（分組は閉じた Session への追加なので events を書かない）
- chat: 2 回目が呼ばれる（指紋が変わった。`analysis_reused` が無い）。`llm.stopCount == 2`
- Raw: frontmatter の鍵が A・B の 2 つ、`parts: 2`、本文に `## 07:12–07:12` と `## 07:42–07:42` と `### 07:42:10`
- Daily: 同じ output_path（ファイルは 1 つ。` (2)` を作らない）、鍵 A・B、`recorded: "00:00:05"`、`parts: 2`、`blocks: 1`（間が 1804 秒 < 3600）、`### 07:12–07:42`。検証が通る

### 6.7 `PartStepsProcessTests.swift`

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `processReachesReadyForSession` / 「Raw の後に readyForSession を返す」 | 6.1 の既定 | `.readyForSession` |
| `rawSavedPartStillReturnsReady` / 「RAW_SAVED 以降の Part でも削除評価の口まで進む」 | Part を RAW_SAVED に | `.readyForSession`（T-38 の requestDeletions がここで呼ばれる） |
| `stoppedWhenRawFails` / 「Raw が偽なら stopped」 | Vault 未設定 | `.stopped` |

### 6.8 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`obsidian.wiki.vaultIndexCacheSeconds` の 1 行を消す（CE テストは `ceVaultIndexCacheSeconds`）。`audio.inboxRetain` は T-18 がすでに消している（`ceAudioInboxRetainRawSavedReleases` は 2 本目の CE テスト）。

## 7. 破壊による証明

| 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|
| ensureRawNote のガードを消す（遷移の後の確認だけにする） | `missingMarkerIsAGuard`、`missingVaultPausesThenResumes` |
| 遷移の後の Vault の再確認を消す | `vaultLostAfterTransitionFails`（6.1・6.2） |
| rawParts で transcript の読めない Part も載せる | `membersUseTheSharedFunction` |
| 検証（NoteVerifier）を呼ばずに RAW_SAVED にする | `writeFailureIsRawWriteFailed` は通るので、代わりに NoteVerifier に渡す期待 SHA を `""` にする壊し方で `writesVerifiedRawNote`（FAILED(OBSIDIAN_RAW_VERIFY_FAILED)・`落ちた規則: RN-4`）が落ちることを確かめる |
| Raw の失敗でほかの TRANSCRIBED の Part も FAILED にする | `onlyTheTriggerFails` |
| raw_saved の inbox の削除を消す | `ceAudioInboxRetainRawSavedReleases` |
| ensureDailyNote で解析 JSON を ANALYZED→WRITING の前に読む | `unreadableAnalysisIsWriteFailed`（events が ANALYZED→FAILED になり表に無い辺で投げる） |
| Daily の expectedKeys に除外 Part を含める | `excludedPartsAreWarnedAndNotListed` |
| `unknownCode` に常に nil を渡す | `unknownErrorCodeIsShownAsRaw` |
| Timeline の読み込みで指紋を見ない | `staleTimelineFallsBack` |
| rawLinkName に nil を渡す（常に基本名） | `sourcesPointToActualRaw` |
| LinkPlanner に既定タグ入りの tags を渡す | `tagLinksUseTheIndex`（索引に `voicedock` が在るので Links に `[[voicedock]]` が増える。結合テストの索引には `voice` / `voicedock` が無く `#tag` になって本文に出ないので、`oneTickFromBWFToVerifiedDaily` では捕まらない） |
| Vault 索引の TTL を `>` にする | `staleIndexIsRebuilt` |
| 索引の除外接頭辞を渡さない | `indexIsBuiltAndExcludesRaw` |
| 復旧の tmp の候補を `hasPrefix` で集める | `rawTmpCandidates` |
| saveTimeline の失敗で解析を失敗にする | `timelineWriteFailureIsNotFatal` |

### 結果（2026-09-22。コミット後の清潔な状態で 1 項目ずつ壊し、元のファイルに戻した）

| 壊し方 | 落ちたテスト |
|---|---|
| ensureRawNote のガードを消す | `missingMarkerIsAGuard`・`missingVaultPausesThenResumes`・`vaultNotConfiguredIsAGuard`・`stoppedWhenRawFails` |
| Raw の遷移の後の再確認を消す | `vaultLostAfterTransitionFails`（6.1） |
| Daily の遷移の後の再確認を消す | `vaultLostAfterTransitionFails`（6.2） |
| rawParts で transcript の読めない Part も載せる | `membersUseTheSharedFunction`・`noMembersStaysTranscribed` |
| NoteVerifier に渡す期待 SHA を `""` にする | `writesVerifiedRawNote` ほか Raw を保存する 11 本 |
| Raw の失敗でほかの TRANSCRIBED の Part も FAILED にする | `onlyTheTriggerFails` |
| raw_saved の inbox の削除を消す | `ceAudioInboxRetainRawSavedReleases` |
| 解析 JSON を ANALYZED→WRITING の前に読む | `unreadableAnalysisIsWriteFailed` |
| Daily の expectedKeys に除外 Part を含める | `excludedPartsAreWarnedAndNotListed`・`unknownErrorCodeIsShownAsRaw` |
| `unknownCode` に常に nil を渡す | `unknownErrorCodeIsShownAsRaw` |
| Timeline の読み込みで指紋を見ない | `staleTimelineFallsBack` |
| rawLinkName に nil を渡す | `sourcesPointToActualRaw` |
| LinkPlanner に既定タグ入りの tags を渡す | `tagLinksUseTheIndex` |
| Vault 索引の TTL を `>` にする | `staleIndexIsRebuilt`・`ceVaultIndexCacheSeconds` |
| 索引の除外接頭辞を渡さない | `indexIsBuiltAndExcludesRaw` |
| 復旧の tmp の候補を `hasPrefix` で集める | `rawTmpCandidates` |
| saveTimeline の失敗で解析を失敗にする | `timelineWriteFailureIsNotFatal` |

## 8. 受け入れ条件

- [ ] §3 のファイルがすべて在り、T-18 / T-22 の空の本体（Raw・Daily・Timeline・Vault 索引・Vault の tmp）が埋まっている。`requestDeletionsAfterRawNote` だけが空（T-38）
- [ ] Vault の確認がすべて `VaultCheck.evaluate` を通り、Vault のルートを作るコードが無い（NoteFolder は Vault の下だけを作る）
- [ ] 結合テスト（§6.6）が本物の AVFoundation で通る
- [ ] §6 のテストがすべて通る
- [ ] 破壊による証明の各項目で表のテストが落ちることを確かめ、PR 本文に貼った
- [ ] `make lint` が通る

## 9. SPEC の変更

なし（Raw・Daily のバイト列は T-26 / T-27 の golden が固定する。tick の順は T-18 が SPEC に載せ済みで、段は増えない）。

## 10. マージ後にやること

- T-30（UI）が `Worker.status()` の `writingRawNote` / `writingDailyNote` を状態の 1 行に写す
- T-38 が `requestDeletionsAfterRawNote` と `deleteSourcesIfSafe` の本体を書く

## 11. API 地図への変更提案

1. `TickContext` に `var vaultIndex: VaultIndex? = nil`、`Worker` に `vaultIndex` / `vaultIndexPath` の状態を足す（internal）
2. `PartSteps` の宣言に `requestDeletionsAfterRawNote(sessionKey:) async -> Int`（T-38 が本体）と `rawParts(sessionKey:)` を、`SessionSteps` に `dailyInput(…)` を足す
3. （整合修正 M-1・決着済み）`RecordingRow.errorCode` は未知の文字列を nil に写すため、生の文字列を残す `errorCodeRaw: String?` を `RecordingRow` に足した（T-11。列は 27 のままで `error_code` からの導出）→ 本チケットは `unknownCode: $0.errorCode == nil ? $0.errorCodeRaw : nil` を渡す。地図 §4 に反映済み（2026-09-21）
4. `AnalysisView.init(_ r: AnalysisResult)` を VDPipeline の extension として地図に載せる（VDNotes は VDLLM を import できない）
5. PLAN §8.5 書き込み 2（Timeline）の「書けなくても失敗にしない」の記録として `config_warning rule=timeline` を付録 A.4 の reason / rule の語に足す
