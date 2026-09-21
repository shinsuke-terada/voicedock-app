# 第 2 段の「API 地図への変更提案」と仕様の問題（統合待ち）

## B1（T-18・T-22・T-29。完了）
API:
1. ConfigStore.init: locks: LockEvaluator ではなく observeReaperConf クロージャ（LockEvaluator は T-36 で後）。load() は async、didCreateDefaults()、setLock1Reconciler(_:) を足す
2. update(_:reaperConf:) のラベルを reaperConfObservation: に（PT-11 の語 reaperConf に当たる）
3. テスト用の差し替え口: WorkerDependencies.ingest を any IngestPort、llama を any LLMServerControl（新設の公開プロトコル）。zone は deps から外し tick ごとに設定から作る。ChatTransportFactory の型、physicalMemoryBytes を足す。TestSupport に FakeIngest（T-18）、FakeLLMServer（T-22）
4. ModelFiles は作り手のチケットが無かった → T-22 が作るとした（STATUS の「T-09 の追記」と整理が要る）
5. LlamaServerHandle に公開 init（T-21）
6. 名前の食い違い: 地図 §15 は Builders（T-11 は F1 で Builders に改名済み）。PyJSON.decode の引数: 地図は Data と String の両方（F1 後に追記済み）
7. WorkerJob と enqueue は T-32 が足す
仕様の問題:
- PT-11 と T-09 の衝突: ConfigLoader.load / ConfigValidator.validate の reaperConf: ラベルが PT-11 の語に当たる → ラベル改名か許可リスト
- §8.3・§8.4「同じトランザクションで needs_recopy = 1」: Store に遷移と列更新を 1 トランザクションで行う API が無い → updateRecordingIfStatus で列を遷移より先に書く手順にした（性質は保たれる）
- 付録 A.4: DB の例外を出すイベントが無い → config_warning rule=store で代用
- pendingStart の遅れた start では inbox の孤児とコピー中を見分けられない → 遅れた start では孤児を消さない
- voicedock の潜在バグ: 解析の再利用で analysis_path を書かない → 再利用でも書く（§5.6 に追記を提案）
- ExcludedPart.unknownCode は RecordingRow.errorCode が未知を nil に写すので常に nil
- pipeline_paused は WARNING、resumed は INFO（規定が無かった）

## B2（T-36・T-38・T-39・T-41。完了）
API:
1. LockEvaluator: init に log。nonisolated let reaper: ReaperRunner、observe(...) -> LockObservation、reaperStatus を足す。WorkerDependencies から reaper を外す（locks.reaper を使う）。T-36 は WorkerDependencies の末尾に locks と volumeOpener を足し、Bootstrap の { .missing } を locks.observeReaperConf() に替える
2. 事前確認のボリュームの親は reaper.conf の VOLUMES_ROOT から取る（WorkerDependencies に volumesRoot を足さない）
3. DeletionPolicy の引数を (DeletionCandidate, DeletionContext) に確定。TwinPart.load、RawNoteVerdict、DeletionReason、LockDisplay を足す
4. ReaperRunner.run() の戻りを ReaperRunOutcome に。署名検証などは T-36、run は T-38
5. VDCore に AppIdentity、ReaperSignature.production（T-01 の「渡し方は T-36 で決める」を確定）
6. BacklogPlan.skipped を [BacklogSkip]（タプルは Equatable にできない）。BacklogAction の reply は Result。WorkerJob の 2 case は T-41 が足す
7. README の T-41 の前提に T-30・T-32
8. 地図 §15 に足す部品: DeletionScene・StorePaths・ScriptedProcessRunner.version（T-36）、ScriptedIngest・installRealReaper（T-38）。ReaperBinary.url() の名前は T-37 と要確認
チケットの配置の変更: 正の対照 deletionActuallyHappensWhenEverythingIsValid は T-38 に置いた（requestDeletions があるため）。T-36 には式の段の対照
先行チケットに合わせたこと: 観測は IngestPort、依存は TickContext から、呼び出し口は requestDeletionsAfterRawNote と SessionSteps.deleteSourcesIfSafe
仕様の問題:
- 付録 A.4: reaper がシグナル終了・起動失敗・タイムアウトのときの exit の書き方が無い → 仮に 128+s・127・null
- §8.9.9 に追記が要る: 結果待ち（復旧後の PENDING は ID を持つ）の Part は後追いで二重に要求せず not_deletable、source_path が無い PENDING は still_present
- 根拠 B の手順に追加（式と同値）: readiness を先に見てだめなら 0、同じ周回で PENDING にした Part を飛ばす
- PLAN の `sourcePath != ""` は `sourcePath?.isEmpty == false` と書いた（文字列リテラルは PolicyTests のトークン照合で消えるため）
- 名前の食い違い: StoreFixtures と Builders（T-11 は F1 で Builders に改名済み）、T-26 の sessionKeyField 系と地図の keySessionKey 系（T-26 は F2 で地図の名前に修正済み）。T-36〜T-41 はどちらの名前も使わずに書いた → 統合時に確認

## B4（T-23・T-24・T-33。完了）
API:
1. ModelDownloader.init に hashChunkBytes:、download の progress を @escaping
2. ModelManager.init(layout:catalog:downloader:cache:log:hashChunkBytes:)（clock: を外し ModelVerificationCache を注入）。download / cancel / importCustomLLM / static meetsMemory
3. ModelError に logReason・displayMessage
4. EphemeralDownloadSessionFactory（本番の実装）
5. §15 に ModelHostStub 一式（T-23）、BlockingSessionFactory: DownloadSessionFactory の extension、TestEnvironment.llmFixtureDirectory / llmReportURL(model:)、AcceptanceFixture ほか（T-24）
6. ImportedKeysScanner.init(store:log:)、ImportedKeysService + ImportedKeysScanReason を §11 に、WorkerDependencies 末尾に importedKeys
7. §14 の LLMAcceptance に「本番の EphemeralSessionFactory を使う唯一のテスト」と注記
仕様:
1. 付録 A.4 model_download_failed の reason に bad_url / bad_file_name / io を追加
2. §10.6-1 の判定は Analyzer.analyze の .success（LLMAcceptance は PipelineWorld を import できない）
3. §10.6-2 の割合は呼び出し単位。修復の回数は「修復の要求は user: ""」で数える
4. §10.6-3 の due は fixture の expected.maxTasksWithDue と YYYY-MM-DD 形式で判定
5. §8.13 に 2 行追記: Raw の接頭辞が空なら Vault 全体を走る／frontmatter の鍵が PartKey の形でなければ imported_keys に入れない
6. §8.10 にダウンロード開始前の isPresent で成功を返す規則
7. T-24 は本番の <HOME> に書かない

## B3（T-37・T-40。完了）
API:
T-37: (1) §13 に ReaperIO.swift（PosixIO が internal。代案: PosixIO を public 化）(2) main.swift は ReaperMain.run(arguments:) が返す ReaperExit を出力して exit (3) §15 の ReaperBinary に ReaperRun・ReaperProcess・ReaperBinaryError (4) PLAN §3.4 の reaper の import に Synchronization。_NSGetExecutablePath に MachO が要る場合は PT-07 も直す（実装時に確認）
T-40: §11 に DeletionEnabler の実シグネチャ・EnableError・DeletionStage・DeletionPanelState.swift。DeleteQueue.withdrawAllRequests(layout:) -> (removed:failed:)
仕様:
1. §8.9.8/§6.1: reconcileLock1 は reaper.conf だけを書く（設定エラー中は ConfigStore.update が失敗する。config 側は T-18 の load() 手順 3 が直す）→ 仕様の文を直す
2. §8.9.4 に書き込み失敗時の扱いを足す: processed.log の追記失敗は無視、結果を書けなければ要求を残して次へ（拒否なら source_delete_rejected も出さない／成功なら source_deleted は出す）、要求の unlink 失敗は無視
3. reaper_completed requests=0 も常に出す
4. ND-20/ND-25 の層 R3: msdos で symlink(2) が使えるか未検証。使えなければ付録 B.1 と SPEC S7 の層を R2・R3 → R2 に直す（T-37 §9 に手順）
5. §8.9.8 の trash の表示条件 = config.deleteSourceAudio || reaper.conf が有効
6. 付録 A.4 に deletion_enabled reason=skipped_source / deletion_disabled reason=<失敗した段>
7. PT-06 の灰色: RV-05 は文字列連結のまま（PartKey.make にすると ND-24 の理由語が変わる）

## B5（T-30・T-31・T-32。完了）
API:
1. §12 に AppSnapshot / AppServices / StatusLine / StatusIconImage / PanelStyle / Onboarding / ModelChoices / FolderChooser / DownloadState / AppModel+* / AttentionTexts。Bootstrap を build() async -> Result<AppContext, BootFailure> に
2. §11 に StatusTexts.swift（T-30）、InboxScan.swift（T-32）、Diagnostics/LoginItemStatus.swift（T-30）。ErrorText を public に（T-18 は internal）
3. §2.3 に ModelMemory.swift（T-30）
4. ReadOnlyStore.inboxPaths(statuses:)、Store.migrationIdentifiers（DR-02）
5. §11 の Diagnostics/ を 7 ファイルに、AttentionItems を 15 ケース＋AttentionAction 6＋AttentionInput、StatusReport を具体形に
6. WorkerJob は T-32 が .llmProbe だけ宣言（.backlog / .resolveAbsent は T-41）
7. LLMReadiness.check(...) -> PauseReason?（T-22 のガードを公開し DR-09 と共有）
8. ModelManager.importGGUF(from:)（T-23 が正）
9. InboxMaintenance.leftovers() と SpaceCheck の staging 走査を InboxScan に一本化
仕様:
- §8.11 の要対応の表に toolMissing(ToolKind)（whisper-cli / llama-server が無いと完全に止まるのに表に無い）→ 1 行足す
- §8.12 の 3「はじめに」の「最上部」と並びの 3 番目が食い違う（3 のままにした）
- §8.12 の 2 の例の「再試行」は要対応の表に無い → 「詳細」に置いた
- DR-08 の「custom は notice」は場面が無い → .ok ＋ details に「動作保証外のモデルです」
- DR-03 の式は設定値から（SpaceCheck を duration 1800 で）
- §8.15 に「起動に失敗したとき」→ NSAlert 1 枚で終了
- §8.12 の「最終接続」は AppModel が in-memory で覚える
- CV-30 / CV-33 違反時は configInvalid と lockMismatch を両方出す
- DR-09 の <model> は llm.modelID

## B6（T-34・T-35・T-42・T-43・T-44。完了）
API:
1. §14 PolicyTests の中身に RunbookTests(T-35)・RunbookGateTests(T-42)・ReadmeTests(T-43)・ReleaseChecklistTests(T-44)・ReleaseBundleTests(T-34)
2. §14 の PolicyTests の依存に VDContract（AppVersion.components を使うため。CR-06）
3. §16 に Resources/bundle-manifest.txt（T-34）= バンドルに入ってよいファイルの唯一の出所
4. Resources/AppIcon.icns の作り手が未定 → T-30 とみなした（作り方は T-34 §4.10）。要決定
5. Runbook / RunbookGate / Readme / ReleaseDoc / DocumentedCounts は PolicyTests の中に置き §15 に載せない
仕様:
1. §12.4 に 5 番目の条件（削除 ON で E2E-01〜09 を再実行）
2. §11.1 の Info.plist に CFBundleIconFile（AppIcon）と CFBundleDevelopmentRegion（ja）
3. §11.3 の 1: 本体にも --identifier <BUNDLE_ID> を明示
4. §11.4 にリリースの作り方（v<VERSION> の注釈付きタグ、gh release create --verify-tag、非公開リポジトリの資産は匿名で配れない）
5. §8.9.8 の「直ちに ro へ再マウント」の観測手段（/sbin/mount と statfs MNT_RDONLY）
6. 付録 B.3 の判定記号 ✗ は U+2717（❌ / × と混ぜない）
7. 付録 B.3 の E2E-11 に注記（本アプリは削除 OFF でも Raw 検証を行うので backlog が 0 件にならない）
8. §11.1 の TCC の説明文 2 種が Info.plist と README に逐語で現れる（テストが照合）
9. §3.2 の木に docs/RELEASE.md と docs/release-notes/
10. T-32 に diagnosticsCountMatchesSpec（SPEC の DR 件数 ↔ 実装の検査数）を足す
11. §14 の RK に「README に載せる（07/18/28/31/32）」の注記
注意: T-34 の前提から T-37 を外した。T-42 の削除 ON の E2E は Developer ID 署名・公証済みの .app で行う（Apple Development 署名では reaper の署名要件が通らず試験が空振りする）
