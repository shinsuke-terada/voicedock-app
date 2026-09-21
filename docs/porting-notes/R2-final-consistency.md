# R2 最終の整合確認（読むだけ。修正はしていない）

対象: `docs/tickets/` の 45 チケット＋`00-api-map.md`＋`README.md`、仕様 `tmp/witty-gliding-clover.md`（v1.1）。
機械的に全数確認したもの: ID の実在（CV/ND/RV/DR/PT/E2E/X/F/RK/CR/TEST/CONC/DEL）、ND/RV/CV/DR の層つき網羅、`Sources/`・`Tests/` のファイルの重複と欠落、ログイベント 48 件の使用、`reason=` の語、エラーコード 32 件と状態 12/13 件。
**ConfigEffect（`CE <keyPath>`）の網羅は対象外**（別エージェントが並行して追加中）。

---

## 良好だった点（食い違いなし）

- **ID の参照**: チケットが参照する CV/ND/RV/DR/PT/E2E/X/F/RK/CR/TEST/CONC/DEL の ID はすべて仕様に実在する（例外は T-05 の `ND-66` / `ND-77` / `ND-99`、T-43 の `DR-99` で、これらは「存在しない ID を SPEC 同期テストが弾く」ための意図的な偽 ID）。
- **ND の網羅**: B.1 の ND-01〜09・18〜29・31〜47 のすべてに、**層の列と一致する**テストが在る（`ND-nn [A]` / `[R1]` / `[R2]` / `[R3]`）。ND-30 は欠番のとおり無い。
- **RV の網羅**: RV-00〜13 のすべてに対応するテストが在る（RV-11 は T-07 の `rv11FilenameRule` / `rv11FolderRule` と T-37 の ND-29 / ND-37 で層 R2・R3 の両方）。
- **CV の網羅**: §6.4 の CV-01・08〜14・16〜19・22・29・30・32・33・39〜59 の全 38 件が T-09 のテスト表に在る。欠番（CV-02〜07・15・20・21・23〜28・31・34〜38）を使っているチケットは無い。
- **DR の網羅**: DR-01〜17 の全 17 件が T-32 にテストとして在り、順（`orderIsTheSpecOrder`）と `always`（DR-14 だけ）も固定されている。
- **エラーコード**: 付録 A.3 に無い ALL_CAPS のコードを使っているチケットは無い。T-08 の宣言順は A.3 と一致、廃止 3 件も注記付きで欠番。
- **ログイベント**: A.4 の 48 件はすべてどこかのチケットで使われており、登録外のイベント名は無い（T-37 の `started` / `completed` / `disabled` は reaper 専用ログで `LogEvent` の対象外）。
- **ファイルの重複**: 同じ `Sources/...` を 2 つのチケットが作る例は無い。重複に見えるものはすべて「（変更）」「（本体を書く）」「空（T-nn）」の注記で作り手が一意に決まっている。
- API 地図にあって作るチケットの無いファイルは無い（VDLLM・VDModels はディレクトリ見出し＋箇条書きで列挙されている）。

---

## 高（設計どおりに作ると、ビルドできないか順序が破綻する）

### H-1. T-25 の `GoldenCase.orderedObject` が T-45 の `PyJSONValue` / `PyJSON.decode` を使う（循環）
- 場所: `T-25-golden-tools.md` §4（`Tests/TestSupport/GoldenCase` の `orderedObject(_:)`、行 1998-2004）と ヘッダの「前提: T-01」/ `T-45-python-compat.md` ヘッダ「前提: T-25」。
- 問題: `orderedObject` の戻り値が `[(String, PyJSONValue)]`、本体が `PyJSON.decode` を呼ぶ。`PyJSONValue` / `PyJSON.decode` は **T-45 が VDCore に作る**。README の順は T-25 → …→ T-45 なので、T-25 の PR だけでは TestSupport がコンパイルできない。一方 T-45 は T-25 の golden 基盤に依存するため、入れ替えもできない。
- 修正案: `orderedObject` を T-25 の本文から外し、**T-45（または最初の利用者である T-19）が extension で足す**（§15 の「足したい機能は作り手のチケットの型に extension で足す」に沿う）。T-25 §4.13 の索引と T-19 §5.0 の「T-25 が足した」の記述も同時に直す。

### H-2. T-30（Phase 7）の Bootstrap が T-36（Phase 8）の型を直接使っている
- 場所: `T-30-ui-shell.md` §4 Bootstrap 手順 6・7・12（`LockEvaluator` / `CodeSignatureVerifier` / `ReaperSignature.requirement` / `SystemVolumeOpener` / `WorkerDependencies(… locks:, volumeOpener:)`）。`T-36-deletion-policy.md` §3「`Sources/VoiceDockApp/Bootstrap.swift`（変更）| `LockEvaluator` を作り、ConfigStore と WorkerDependencies に渡す」。
- 問題: `LockEvaluator`・`SignatureVerifier`・`ReaperSignature` は T-36 が作る。T-30 の前提は T-29 だけで、README でも T-30 は T-36 より前。同じ Bootstrap の同じ行を 2 チケットが「作る」と書いており、T-30 単体ではビルドできない。
- 修正案: どちらかに寄せる。(a) T-30 は `observeReaperConf: { .missing }`・`locks`/`volumeOpener` 抜き（T-18 §11 の想定どおり）で書き、T-36 が差し替える、または (b) `LockEvaluator` を T-30 の前提に入れ、T-36 を Phase 7 の T-30 より前に動かす。(a) を推す（Phase の区切りを崩さない）。

### H-3. T-32（Phase 7）が T-36（Phase 8）の `LockEvaluator` / `LockDisplay` / `ReaperStatus` を必須で使う
- 場所: `T-32-diagnostics-attention.md` ヘッダ（「間接に … T-36」）、§4 `DiagnosticsDependencies.locks: LockEvaluator`（行 133）、`StatusReport.reaper: ReaperStatus = .notInstalled`（行 550）、DR-14（行 334-337）。README の T-32 の前提は T-30 だけ。
- 問題: Optional ではないフィールドなので、T-36 より前に T-32 をマージできない。DR-14 は「`LockEvaluator` を使い、式を書き直さない」と仕様（§8.11）が要求しているため回避もできない。
- 修正案: README と T-32 のヘッダの前提に **T-36 を明記し、T-32 を T-36 の後（Phase 8）へ動かす**か、T-36 の `LockEvaluator` / `LockDisplay` / `ReaperStatus` だけを Phase 7 に切り出す。H-2 と同じ判断で一括に決めるのがよい。

### H-4. `ConfigLoader.load` / `ConfigValidator.validate` のラベルが PT-11 に当たる
- 場所: `T-09-config.md` §4（行 270・306・297）は `reaperConf:`。`00-api-map.md` §11 は「**引数ラベルに `reaperConf` を使わない**（PT-11 の語に当たる）。`ConfigLoader.load` / `ConfigValidator.validate` も `reaperConfObservation:` にする」と既に決めている。`T-18-worker-part-steps.md` §4.2 の `read()` も `reaperConf:` で呼び、§11 提案 3 で「未解決」と書いている。
- 問題: PLAN §9.4 PT-11 は `reaperConf` という語を `HomeLayout.swift`・`DeletionEnabler.swift`・`ReaperRunner.swift`・`LockEvaluator.swift`・`voicedock-reaper/` だけに許す。`VDCore/Config/ConfigLoader.swift` / `ConfigValidator.swift` / `VDPipeline/ConfigStore.swift` に書くと PolicyTests が落ちる。優先順位（PLAN ＞ 地図 ＞ チケット）から、地図の決定に合わせるのが正。
- 修正案: T-09 の 2 つの宣言・手順・テストの呼び出しを `reaperConfObservation:` に直し、T-18 §4.2 の `read()` と §11 提案 3 も同じラベルに確定する（T-09 と T-18 と T-04 を同じ PR で）。

---

## 中（実装時に必ず衝突する。地図かチケットのどちらかを直す必要がある）

### M-1. `RecordingRow.errorCodeRaw` が地図に在り T-11 に無い
- 場所: `00-api-map.md` §3 `Rows.swift`（「27 列」と書きつつ `errorCodeRaw: String? /* 未知のコードの文字列も残す。Daily の警告行が使う */` を含む 28 個を列挙）。`T-11-store.md` §4 の `RecordingRow`（行 261-291）は 27 個で `errorCodeRaw` が無く、DDL にも `error_code_raw` 列が無い。
- 影響: `T-27` の `ExcludedPart.unknownCode` は T-29（行 207・500-501）が常に `nil` を渡すので、付録 A.3 の「未知はコードのまま」表示が実現しない。T-29 §11 提案 3 が「T-11 に足せ」と書いたまま未反映。
- 修正案: T-11 に `error_code_raw TEXT` 列（または `error_code` の生値の読み出し）と `errorCodeRaw` を足し、T-29 がそれを `ExcludedPart.unknownCode` に渡す。足さないなら地図から `errorCodeRaw` を消し、`ExcludedPart.unknownCode` も消す。地図の「27 列」という数も直す。

### M-2. `ChatTransportFactory` の型が地図とチケットで違う
- 場所: `00-api-map.md` §11 は `@Sendable (LlamaServerHandle) -> any ChatTransport`。`T-22` §4.1（行 64）・`T-30` Bootstrap（行 190）・`T-32` §4（行 448）・`T-22` §5 はすべて **2 引数** `(LlamaServerHandle, LLMConfig)`。
- 修正案: チケット 3 本が一致しているので**地図を 2 引数に直す**。

### M-3. `BacklogAction` / `BacklogPlan` 周りが地図とチケットで違う
- 場所: `00-api-map.md` §11 `BacklogPlanner.swift` は `BacklogAction { case preview(reply: (Result<BacklogPlan, Error>) -> Void), execute(reply: (Result<BacklogPlan, Error>) -> Void) }` のみ。`T-41-backlog.md` §4.1 は `BacklogKind`・`BacklogExecution`・`BacklogFailure` を新設し、`preview` は `Result<BacklogPlan, BacklogFailure>`、`execute` は `Result<BacklogExecution, BacklogFailure>`。
- 修正案: 地図を T-41 に合わせる（`Error` は `Equatable` にできないため T-41 の形が正しい）。§11 に `BacklogKind` / `BacklogExecution` / `BacklogFailure` の行を足す。

### M-4. `ConfigStore.init` の引数が地図・T-18・T-30 で三者三様
- 場所: 地図 §11 = `init(layout:catalog:observeReaperConf:)`。`T-18` §4.2 = `init(layout:catalog:log:observeReaperConf:defaultTimeZone:)`。`T-30` Bootstrap 手順 7 = `ConfigStore(layout:catalog:observeReaperConf:)`（`log:` なし）。`T-40` §5（行 357）は `log:` 付き。
- 修正案: T-18 の 5 引数を正として、地図 §11 と T-30 手順 7 を直す（`load()` の `config_warning` / `config_invalid` のログに `log` が要る）。

### M-5. `ModelManager` / `ModelDownloader` の init が地図・T-23・T-30 で食い違う
- 場所: 地図 §10 = `ModelDownloader(layout:factory:log:)`・`ModelManager(layout:catalog:downloader:clock:)`。`T-23` §4 = `ModelDownloader(layout:factory:log:hashChunkBytes:)`・`ModelManager(layout:catalog:downloader:cache:log:hashChunkBytes:)`（`clock:` は無い）。`T-30` Bootstrap 手順 14 は**地図の古い形**で呼んでいる。
- 修正案: T-23 を正として地図 §10 と T-30 手順 14 を直す（`ModelManager` の `download` / `cancel` / `importCustomLLM` / `meetsMemory` も地図に足す）。

### M-6. `WorkerDependencies` の末尾追加の順が三つ巴
- 場所: `T-33`（Phase 7）§3・§4.5 は「末尾に `importedKeys` を足す（T-36 が `locks`/`volumeOpener` を足したのと同じやり方）」と**T-36 が先に済んでいる前提**で書いている。`T-36`（Phase 8）§3・§4.8 は「末尾に `locks`・`volumeOpener` を足す」。`T-30`（T-33 より前）の Bootstrap は `locks:`・`volumeOpener:` を渡し `importedKeys:` を渡さない。
- 修正案: H-2 / H-3 の順序決定に合わせて、`WorkerDependencies` の最終の並びを 1 か所（地図 §11）に書き切り、T-30・T-33・T-36 の記述をそれに合わせる。

### M-7. README の「前提」とチケットのヘッダが食い違う
- `T-41`: README は `T-38` のみ。ヘッダは `T-38, T-30, T-32`（`WorkerJob`・`enqueue`・`stagePendingJobs`・`DetailsSection`）。→ README に T-30・T-32 を足す。
- `T-42`: README は `T-36〜T-41`。ヘッダは `T-34`（`make release`）・`T-35`（`docs/E2E.md` の書式）も含む。→ README に T-34・T-35 を足す。
- `T-44`: README は `T-43` のみ。ヘッダは `T-43, T-42, T-34`（推移的には満たされるが明記が望ましい）。
- `T-34`: README は `T-30, T-03`。ヘッダは `T-01`（`Makefile`・`identity.env`・`VERSION`）も含む。
- `T-32` / `T-30`: H-2 / H-3 のとおり T-36 が抜けている（**これが実害のある唯一の欠落**）。
- 循環は上記 H-1 以外に無い（`T-32` §2 の「先行チケット … T-41 §4.2」は**後続**の誤記。T-41 が `WorkerJob` に 2 ケースを足す側であり、T-32 は `.llmProbe` だけを宣言する、と T-32 §8・§11 が正しく書いている。見出しの語だけ直せばよい）。

### M-8. A.4 に無い `reason=` の語を 2 チケットが使う
- `T-18-worker-part-steps.md` 行 766・924: `normalize_failed … reason=input`。A.4 は `normalize_failed` の reason 語を 1 つも定義していない。
- `T-23-models.md` 行 310-312・447-450: `model_download_failed reason=http_404|network|sha256_mismatch`（§4 の表は「逐語。付録 A.4 の語」と書いているが、A.4 は `bad_url` / `bad_file_name` / `io` しか挙げていない）。
- 仕様は「新しい語を足すときはここに足す」と定めているので、**A.4（＝ `docs/SPEC.md`）に `normalize_failed: reason=input`、`model_download_failed: reason=http_<code>|network|sha256_mismatch|cancelled|bad_url|bad_file_name|io` を追記**し、T-18・T-23 の「SPEC の変更」節に書く。

### M-9. 地図 §15 の「TestSupport の部品の作り手」とチケットの置き場所が 3 か所ずれる
- `AppServices` の偽物・`FakeLoginItem`（§15 は T-30 が TestSupport に作る）→ `T-30` §3 は `Tests/VoiceDockAppTests/FakeServices.swift` に置き「**TestSupport には置かない**」と明記。`FakeLoginItem` はどのチケットにも無い。
- `AcceptanceFixture` / `Harness` / `Judge` / `Report` / `CountingChatTransport`（§15 は T-24 が TestSupport に作る）→ `T-24` §3 は `Tests/LLMAcceptance/` に `AcceptanceFixture` / `AcceptanceHarness` / `AcceptanceJudge` / `AcceptanceReport` として置き、§11 提案 1 で「TestSupport には置かない」と書いている。
- `BlockingSessionFactory`: §15 では T-23 の行に載るが、型そのものは `T-21` の `BlockingURLProtocol.swift` が作り、T-23 が作るのは `DownloadSessionFactory` 準拠の extension だけ。
- 修正案: §15 の該当 3 行を「置き場所」つきで書き直す（`Tests/VoiceDockAppTests/` / `Tests/LLMAcceptance/`）。`FakeLoginItem` は実体が無いので削るか T-30 に作らせる。`BlockingSessionFactory` を T-21 の行へ移し、T-23 の行は「extension」と注記する。
- あわせて §15 に載っていない共有部品が 2 つ在る: `Tags`（T-01）、`TestCatalogs`（T-09。T-13・T-18・T-22・T-40 が使う）。

---

## 低（誤解を招く記述。実装は止まらない）

1. **`00-api-map.md` §15 の `ReaperBinary` の行が重複**（T-37 の行が 2 つ。後の行だけが `ReaperRun` / `ReaperProcess` / `ReaperBinaryError` を含む）。前の行を消す。
2. **`T-13-device-detection.md` ヘッダ**: 「README の索引に T-07 が無いので足すべき」とあるが、README は既に `T-07, T-09, T-12` になっている。注記が古い。
3. **`T-22-session-steps.md` §11 提案 2**: 「`ModelFiles` を作るチケットが無い。本チケットが作る」は古い。§3 では既に「T-09 が作る」と取り消し線付きで正しく書かれている。提案 2 を消す。
4. **`T-45-python-compat.md` 行 1654**: 「地図の PyJSON の行には `parse(_:)` と `isBool(_:)` が載っていない」は古い。地図 §2.4 には両方載っている。
5. **`T-09-config.md`**: §7.1 が `Tests/VDCoreTests/ModelFilesTests.swift` に触れているのに §作るもの の表にその行が無い（テストの中身は T-22 §6.9 にある）。T-09 の表に足すか、T-22 §6.9 を T-09 へ移す。
6. **`T-09-config.md` の節見出し**が `## 作るもの`（番号なし）で、README「チケットの形」の 10 節の番号付けと揃っていない。
7. **`LockEvaluator` の `useCache:`**: `T-36` は `observe(config:snapshot:useCache:)` と `reaperStatus(useCache:)` を持つが、地図 §11 の行には `useCache:` が無い。地図に足す。
8. **`DeletionPolicy.textIsPreserved`**: 地図 §11 は「引数は 2 つに固定」と書くが、`T-36` の `textIsPreserved(_ part:_ session:_ parts:_ ctx:)` だけ 4 引数。地図の但し書きを「`canDeleteSource` など 5 つは 2 引数、`textIsPreserved` は 4 引数」に直す。
9. **`IngestService.remountAllReadOnly()`**（T-15 §4 / 地図 §5）は誰も呼んでいない。§8.9.8 の再マウントは `T-40` §4（行 261）が `ingest.scanNow()` で行う（`IngestPort` に `remountAllReadOnly` が無いため）。どちらかに寄せる（`scanNow` で足りるなら T-15 から消す）。
10. **`T-25` が T-01 の `Tests/TestSupport/TestEnvironment.swift` を全文で置き換える**（`goldenWriteActual` を足すため）。§15 の「作り手のチケットの型に extension で足す」規約に沿うなら `TestEnvironment+Golden.swift` にするのが一貫する（T-24 は extension で足している）。
11. **`T-31-ui-onboarding.md` §3** の `Panel/OnboardingSection.swift` ほか 3 本に「変更」印が無い（T-30 が空ファイルを作る）。T-32 は「T-30 の空を置き換え」と書いている。表記を揃える。
12. **`T-28-notes-write-verify.md` 行 217-218** のテスト用ノート組み立てが `"type"` / `"voicedock_session_key"` / `"voicedock_recording_keys"` を文字列リテラルで書いている（`Frontmatter.keyType` などの定数が在る。CR-06 の趣旨）。

---

## 参考: 既に `stage-b-api-proposals.md` に挙がっている項目

H-4（PT-11 とラベル）、M-1（`errorCodeRaw`）、M-2、M-3、M-5、M-7 の T-41 分、M-8 の `model_download_failed` 分は第 2 段の提案として記録済みで、**00-api-map への反映が未了**のものである。
H-1（T-25 と T-45 の循環）、H-2・H-3（T-30 / T-32 が T-36 を先取り）、M-4（`ConfigStore.init`）、M-6（`WorkerDependencies` の並び）、M-9（§15 の置き場所）は本確認で新たに見つかったもの。
