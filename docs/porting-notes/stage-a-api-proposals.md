# Stage A の API 地図への変更提案（統合待ち）

## A7 (T-16, T-17)
1. WhisperArgs.build から whisperCLI: を外す
2. Transcriber.init に clock: any AppClock
3. TranscribeOutcome.prerequisiteMissing(TranscribePrerequisite), Transcriber.missingPrerequisites()（rawValue は PauseReason と同語）
4. NormalizeRequest / TranscribeRequest / TranscribeMetrics に public init
5. PyRound（Python round 互換）を VDCore（T-45）へ。T-17 は暫定で internal PythonRound
6. T-05 に SpecDocument.codeBlock(heading:language:)
7. SteppingClock の uptime() も進める
8. T-17 の前提に T-03
仕様: sha256Helper nil の文言「（<sha16>… ≠ 記録なし）」、transcript 書き込み失敗 → WHISPER_FAILED「正規化 transcript を書けません: …」、URL.path(percentEncoded:false) 統一、ガードと Transcriber の両方で前提確認

## A3 (T-06, T-07)
1. RequestID.randomHex6()
2. ContractJSON.encode throws(ContractEncodeError) .nonFiniteNumber
3. ContractJSON.requestKeys/targetKeys/resultKeys public
4. ReaperConf public init, key constants, linePattern public
5. LocalDateTime.daysInMonth public
6. DeleteRequest/DeleteResult/DeleteTarget public init
7. FileLock.release(): LOCK_UN idempotent, fd closed in deinit
8. IdentityMismatch.init(_:) public
9. IdentityReason all 21 reaper reason words + all
10. SystemVolumeOpener.init() public
追加ファイル: PatternMatch.swift, PosixIO.swift（VDContract）
仕様: openVolume の EACCES/EPERM → .absent（チケットで決定）→ 仕様に明記要; T-06 は 600 行超え（A/B 群に分割済み）; PT-06 は a + "/" + b を素通り; 表の中の `|` は \| にエスケープ
実機注意: /Volumes/DJIMIC3 に実機がマウント中。テストは /Volumes に触れない

## A5 (T-11, T-12)
T-11: StoreError に corruptRow(String), invalidUpdate(String); migration("superseded"); updateRecordingIfStatus を Transitions.swift へ（PT-05）; Store の internal init(url:clock:zone:migrator:); RecordingField/SessionField Equatable; NewRecording の必須列を非 Optional; 後続: Store.partkeys(statuses:), ReadOnlyStore.awaitingDeleteResultCount(), ReadOnlyStore.partkeys(statuses:)
T-12: VDProcess に Synchronization を許可（Mutex）; SpawnError { spawnFailed(errno:), pipeFailed(errno:) }; ProcessSpec.init/Equatable; ProcessResult.init, stdoutText, stderrText, 上限定数; ProcessEnvironment.path; RunningProcess.stdoutTail(), waitForExit(); ProcessRunner.killGrace public
仕様: §7.1 prepareDatabase 後に writer が NORMAL に戻る → プール作成後に FULL を再設定し確認; §3.4 に Synchronization（VDProcess 以外も必要見込み）; §8.2 spawn は throws(SpawnError) に統一; insertRecording の PK 重複 → DatabaseError をそのまま投げる

## A9 (T-26, T-27, T-28)
T-26: Frontmatter のフィールド名定数 5 個 + stringList(_:_:); RawNote に noteType/sourceLabel/intro/title(_:); RawPart.zone は並べ替えのみ、### 時刻は started_at の固定オフセット
T-27: DailyInput に zone; DailyNote.summaryHeading(config:), rawLinkName(rawOutputPath:config:day:); baseName/folder の引数は ObsidianConfig; VaultIndex.contains/isStale(ttlSeconds:now:)/scannedDirectories; LinkPlan.counted; LinkPlanner.isLinkable/forbiddenScalars; 表示名は [ErrorCode: String]
T-28: VaultStatus.message(path:marker:), isAvailable; NoteWriter.write throws(AtomicFileError); NoteFolder.ensure(relative:vault:); NoteErrorText.describe; NoteVerification.results: [NoteRuleResult] + 計算プロパティ; OutputPathResolver.mayOverwrite public
仕様: RawNoteMembership.parts(of:) vs isMember → 仕様側を isMember に; §8.8 resolve の引数を API 地図に合わせる; Vault の stat EPERM/EACCES → .notReadable を明記; DST: Timeline 見出し・ZonedTime.iso は TZ 規則、voicedock は固定オフセット → 注記、golden は DST 無し TZ; 意図的差分（Yams 重複キー=読めない、検証中の読み取り失敗=規則 3 偽、timeline のオフセット無し時刻は受けない）を明記; golden 入力形式は T-25 に合わせる

## A6 (T-13, T-14, T-15)
1. MountInspector.isMountPoint(path:)
2. listEntries → ErrnoError; EntryKind, entryKind(_:)
3. detect() → DetectionResult / SkippedVolume(listingError); nameMatchesVolume public
4. CoexistenceGuard 公開定数
5. RecordingName.matchesFilePattern(_:)（T-06）
6. ScanListing.unparsable, complete; CopyError, ChunkReading; DeviceFileHandle.read throws(ErrnoError)
7. InboxWriter: writePartial / commitPartial / discardPartial
8. StabilityChecker stat を @escaping @Sendable
9. IngestDependencies.configProvider async; フィールド順固定; remounter, mountEvents
10. NewRecording の init 固定（T-11）
11. DiskutilRemounter.init に inspector
12. DeviceSnapshot.notListableErrno, 公開 init; Equatable; IngestActivity.idle; IngestState 4 値
仕様: copy_failed reason に write_error; サブディレクトリ列挙失敗 → complete=false のデバイスは not_listable; snapshot に errno（DR-11 の EPERM 判定）; 再マウント途中で外れたら観測しない; launchctl 失敗は「登録されていない」扱い
重複注意（TestSupport の作り手）: FakeVolume（T-07 と T-13）、DiskImageVolume（T-07 と T-15）、BWFWriter（T-14 と T-16）、FakeMountInspector（T-13）、ScriptedProcessRunner（T-13）。→ 統合で一意に決める

## A4 (T-08, T-09, T-10)
1. OSLogSink を Log.swift へ（PT-08）; LogSink.write(line:level:category:); AppLog.category, withCategory
2. 依存順: T-08 → T-45 → T-10 → T-09; T-08 は T-05 依存、T-09 は T-04・T-05 依存
3. ModelCatalog.rejected, entries(kind:), listedLLMs; CatalogError.unknownKey
4. DeviceConfig.mode, AudioConfig.retain, LogLevel.init?(configValue:)
5. LogValue リテラル準拠と of(_:); ZonedTime.localDateTime; LocalDate.init?(year:month:day:), init?(stamp:); Instant.init(date:), .date; SafeUnlinkError 全ケース; ErrorCode.countsAgainstMaxAttempts
6. SourceScanner の公開 API 未定（T-09 は SourceScanner(source:).stringLiterals と仮定）→ T-04 と合わせる
7. TestSupport に Synchronization を許可
8. RawNoteMembership は T-08 に入れた
仕様: §5.1 不変条件「InProgress ∩ Terminal = ∅」は誤り（Part の SOURCE_DELETING は両方）→ Terminal − {SOURCE_DELETING}; §5.1 の平らな名前 vs PartStates.terminal → §5.1 を直す; §8.15 の redaction 例外は「その行のレベルが DEBUG」; PT-06 は大小区別; 末尾改行付き値は必ず引用（voicedock との差）; transcript 読みは厳格（差）
ConfigEffect: テスト名 "CE <keyPath>"、未テスト 92 キーの担当表あり（T-09 内）

## A8 (T-19, T-20, T-21)
1. JSONExtractor.extractObject / AnalysisValidator.trim/validate を [(String, PyJSONValue)]（順序付き）に
2. PyJSON.decode(_:) -> PyJSONValue?（json.loads 互換、NaN 可、重複キー後勝ち・位置は最初）を T-45 に
3. ChatTransport / ChatResult / FakeChatTransport を T-19 へ
4. LoopbackEndpoint.init?(port:)（失敗可能）
5. LlamaServerSupervisor.init に portPicker
6. LlamaArgs.missingFlags（DR-07 と共有）, AnalyzeOutcome Equatable, Analyzer.reduceMaxDepth, SchemaField, LLMProbe, LLMValidationMessages 公開
7. T-12: 終了済みへの terminate は即返す; T-10: LogKey に port, elapsed_s; T-25: golden のファイル名を T-19 §5.0 の 7 本に
仕様: §8.5「JSONSerialization で辞書」→ 順序付き PyJSON.decode; 切り詰め記録は単一パスで前置無し; server_start_failed: <理由>: <stderr 末尾 150>; API キーファイルは停止・失敗で消す

## A1 (P0, T-01..T-05)
1. §14 テストターゲットに VDProcessTests, VoiceDockAppTests
2. BUNDLE_ID/TEAM_ID は identity.env から
3. TestSupport に Markdown/MarkdownDocument.swift, Spec/SpecDocument.swift; PolicyTests に Scanner/, Rules/, SpecSync/
4. OSLogSink は Log.swift（A4 と一致）
5. PT-17 の禁止語を Store(url:…) に合わせる（Store.open( ではない）
6. PolicyAnchors（T-09, T-15 が足す）, SpecCoverage.activated（T-09, T-32, T-37, T-39 が足す）
7. VDCoreTests に SpecSyncStatesTests（T-08）, SpecSyncLogEventsTests（T-10）; Makefile に spec
8. WorkerDependencies が ModelManager（VDModels）を持つのは §3.4 違反 → 要確認
仕様: §12.3 T-04 行を PT-01〜22; §3.2 ツリーに VDProcessTests, VoiceDockAppTests; T-04 の前提は T-01〜T-03; T-04 は 1900 行（分割しない）; 非公開リポジトリの無料プランではブランチ保護不可; --help fixture は --update-fixtures のときだけ更新; PT-09 に ContinuousClock.now / SuspendingClock.now; PT-06 語一覧が空なら違反; SPEC.md が無いと PT も落ちる（明記）
docs/SPEC.md は tools/spec/make-spec.py が PLAN から生成（S1〜S9）
