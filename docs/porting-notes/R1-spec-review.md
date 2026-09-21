# R1: witty-gliding-clover.md（v1.1）独立レビュー

対象: /Users/terada/Projects/voicedock_app/tmp/witty-gliding-clover.md（全 2976 行を通読）。voicedock@d3d595e は pipeline.py / cleaner.py / session.py / db.py / notes.py / reaper / migrations を部分照合した。
機械照合の結果: 付録 C の教訓 ID・X・RK・F・T・E2E・P0・PT・PR・CR・SN・CV（欠番を除く）の参照切れは 0 件。本文中のログイベント名はすべて A.4 に在り、ErrorCode はすべて A.3 に在り、本文で使う遷移辺はすべて A.1 / A.2 に在る（A.2 の辺数 23 / 24 も一致）。key_slug の固定値 2 つも sha256 で再計算して一致した。
以下は、それ以外に見つかった問題である。

---

## 1. 矛盾

### 1-1【高】無効化フローが CV-30 の再検証に阻まれ、E2E-17 を満たせない
- 場所: §8.9.8「無効化」、§6.1、§6.4 CV-30
- 問題: §6.1 は「`ConfigStore.update(_:)` は書いた後に再検証し、違反なら書かない」、§8.9.8 の無効化は「config（false・ro）→ reaper.conf を false」の順。config を書く時点では reaper.conf がまだ `true` なので、CV-30（「両方読めて値が違う（どちら向きでも）」）に違反し、config は書かれない。「途中で失敗しても残りを続ける」ため reaper.conf は false になり reaper も消えるが、最後は config=true/rw と reaper.conf=false が食い違う。その結果、次に読み込んだとき設定エラーになって全停止し、`mountMode` も rw のままで ro へ再マウントされない（E2E-17 が落ちる）。有効化のほうも、reaper.conf→config の間に落ちると CV-30 の設定エラーで起動する。§6.1 の文自体も「書いた後に…違反なら書かない」で自己矛盾している。
- 修正案: §6.1 を「`update(_:reaperConf:)` は**書く前に**、これから書く reaper.conf の値を使って検証する」にする。§8.9.8 の無効化を「reaper.conf を false（fail-closed を先に）→ reaper を削除 → config を `update(_, reaperConf: false)` で書く → 要求の取り下げ → scanNow」にする。さらに「起動時に config と reaper.conf の片方だけが削除有効なら、両方を無効側に揃えて `config_warning rule=CV-30` を出す（設定エラーにしない）」を足す。

### 1-2【高】アプリ層 ND の正の対照が仕様どおりには成立しない
- 場所: §10.5 最終項「TargetIdentity の事前確認は FakeVolume で通す」と、§8.9.5 `preIdentityCheck` の「アプリも実ファイルに `TargetIdentity.openVolume`…をかける」、§4.6 の openVolume（`f_mntonname` の一致と `msdos` を要求）
- 問題: FakeVolume は普通の一時ディレクトリなので、openVolume は必ず `not_a_mount_point` を返す。この仕様のままでは `deletionActuallyHappensWhenEverythingIsValid` は緑にならない。実装者は「テストなら」分岐を入れる（CR-25 違反）か、各自の注入方法を作るかに割れる。
- 修正案: VDPipeline に `VolumeOpener` プロトコル（本番は `TargetIdentity.openVolume`、テストは `@testable` の `VolumeHandle` の init で平のディレクトリを包む実装）を置き、`preIdentityCheck` はこれを注入で受けると明記する。§10.5 の文も「FakeVolume ＋ `FakeVolumeOpener`」に直す。

### 1-3【中】§10.5 の層 3 の列挙と付録 B.1 の層の列が食い違う
- §10.5: 層 3 は「ND-18〜20・24・25・27〜29・37・39・44」
- B.1: ND-27（replayed）と ND-44（partkey_mismatch）は **R1 だけ**。一方で ND-23（A・R3）と ND-31（A・R3）は R3 を持つのに層 3 の列挙に無い
- 修正案: 層 3 は「ND-18〜20・23〜25・28・29・31・37・39」とする。ND-27 と ND-44 は層 1 へ移す。

### 1-4【中】SPEC 同期の読み取り規則が、付録の実際の書式と合わない
- 場所: §10.3「SPEC 同期の読み方」と、§8.11 の DR 表・付録 A.1・B.1
- DR 表は `| 1 | DR-01 |` と先頭の列が「順」なので、ID の正規表現 `^\| \*{0,2}(DR-…)` に 1 行も一致しない（DR の集合が空になり、空で緑になる）
- 状態の読み取りは表の行 `^\| …\`([A-Z_]+)\`` を探すが、A.1 の状態は箇条書き（`- Part: \`DISCOVERED, …\``）なので一致しない
- B.1 の `| ND-30 | （欠番…` は `~~` で始まらないので「生きた ID」として数えられ、存在しない ND-30 のテストを要求してしまう
- 「層 `A・R` は 2 本以上」は v1 の層名のまま残っている（今の層は A / R1 / R2 / R3）
- A.1 の復旧写像のフェンスは Part と Session が同じフェンスにあり、`SOURCE_DELETING→SOURCE_DELETE_PENDING` が両方に出る。エンティティの見分け方の規則が無い
- 修正案: DR 表は ID を先頭の列にする（順は 2 列目）。A.1 の状態は `| 1 | \`DISCOVERED\` |` 形式の表にする。ND-30 は `| ~~ND-30~~ |` にする。層の規則は「層の列に書いた層の数だけテストがある」に改める。フェンスの行頭の `Part:` / `Session:` でエンティティを分けると明記する。

### 1-5【低】小さな矛盾
- §3.2 の Makefile に「`make golden`（Docker が要る）」とあるが、§10.4 と F-35 では「ホストの uv。Docker 不要」。前者を「ホストの `uv` が要る」に直す。
- §8.9.6 の `reaper_failed exit=<n>` は A.4 の `reaper_failed reason=exit_<n>|timeout` と形が違う。A.4 に揃え、`reaper_run exit=<n>` は常に出す、と決める。
- 時計の名前が 4 通りある: §5.4「`Clock` プロトコル」、CR-08・T-10「`AppClock`」、PT-09「`SystemClock`」、§5.7「`ZonedClock`」。`Clock` は標準ライブラリの `Clock` プロトコルと衝突する。プロトコルは `AppClock`（`now()` と `uptime()`）、本番の実装は `SystemClock`、書式は `ZonedClock` に統一し、§5.4 を直す。
- §3.2 と T-11 は `recordTransition`、§5.2 は `recordPartTransition` / `recordSessionTransition`。後者に揃える。
- §8.1 のコピー手順 2 は「size/mtime が違えば見送り」（ログなし）。A.4 には `copy_failed reason=changed` がある。どちらかに揃える。
- §4.6 は「`VolumeHandle.readOnly` で RV-07 とアプリのロック 2-B を同じ値で観測する」と書くが、§8.1 と §8.9.2 はアプリ側を snapshot（`statfs(path)`）から取る。IngestService の観測にも `openVolume(...).readOnly` を使うと明記する。
- CV の表で書き方の向きが混ざっている。CV-30 と CV-33 は「違反の条件」、他は「満たすべき条件」で書かれている。CV-14 は「CV-13 より先に判定」とあるが、表の見出しは「この順に」。CV-33 は「`!(deleteSourceAudio && mountMode == "ro")`」の形に揃える。

## 2. 参照切れ

- 【中】**PT の許可リストが本文の要求を満たさない**
  - (a) IngestService が `state/reaper.lock` を開く `open(`／`O_CREAT` は PT-10(a) と PT-12 に反し、置ける場所が無い（reaper 側も ProcessedLog / ReaperLog / QueueFiles 以外では O_CREAT できない）。ロックファイルを誰が作るかも書かれていない
  - (b) CV-30 のために reaper.conf を読む ConfigStore / ConfigLoader の呼び手が PT-11（`reaperConf` の使用場所）に無い
  - (c) reaper が要求ファイルを unlink する場所が PT-01 に無い（Unlinker.swift はデバイス削除用として書かれている）
  - 修正案: VDContract に `ReaperLock.swift`（O_CREAT で開いて flock を掛ける）を置き、PT-10・PT-12 に足す。PT-11 に `VDCore/ConfigStore.swift` を足す。PT-01 に `voicedock-reaper/QueueFiles.swift` を足す（要求と `rejected/` の扱い）。
- 【中】**import の許可リスト違反**: §8.10 は「照合済みの `(path,size,mtime)` を ModelManager（VDModels）が覚え、診断で飛ばす」とするが、診断（VDPipeline/Diagnostics）は VDModels を import できない。VDAudio は VDContract を import できないのに、`<HOME>/staging` の場所と `SafeUnlink(layout: HomeLayout)` が要る。修正案: 照合キャッシュを VDCore の `ModelVerificationCache` に移す（または DR-12 と同じく値を注入する）。VDAudio には URL だけを渡すと明記する（または VDAudio の許可に VDContract を足す）。
- 【低中】「PT で検査」の先が無い。§10.5 の層 2 の「本番の reaper は `VolumeHandle` の init を呼ばない。PT で検査」に該当する PT が無い（PT-22 を新設する）。PT-07 の「Tests の各ターゲットも別の表で検査」の表も無い。
- 【低】`<HOME>/ui-state.json`（§8.12）が §2.3 の配置図と HomeLayout に無い。
- 【低】参照先の節の誤り:
  - 付録 C の SM-23「§8.9.7」→ 正しくは §8.9.5 の finishCleanup
  - §4.4「§8.9.5 の『待っている』の定義」→ 定義は §8.9.1 の末尾
  - §8.9.8 の「D-17」と §8.4 の「voicedock D-7」は §0.2 の D-n（決定事項）と衝突する → 「voicedock doctor D-17」と書く

## 3. 実装者で結果が割れる曖昧さ

### 削除の安全・状態機械
- 【中】**Session の再オープンに穴がある**（§5.6 と A.2）: 同じ日の Part は閉じた Session にも入る（「閉じた Session への追加は events を書かない」）。しかし再オープンの契機は SAVED / COMPLETED だけである。削除 ON で Session が SOURCE_DELETING / SOURCE_DELETE_PENDING / CLEANUP の間に追加された Part は、Raw には載るが Daily には永久に載らない（X-13 と同じ型の潜在バグ）。修正案: ★辺 `SOURCE_DELETING→MERGING`・`SOURCE_DELETE_PENDING→MERGING`・`CLEANUP→MERGING` を足して `reopenable` を広げる。または `CLEANUP→COMPLETED` の直後に「rawNoteMembers の鍵 ⊄ Daily の鍵なら →MERGING」を置く。
- 【中】**reaper.lock の待ち方が決まっていない**（§8.1 手順 2 と §8.9.4）: IngestService は走査が終わるまで（コピーを含めて約 11 分）ロックを持つ。reaper が `flock` で待つ設計だと、ProcessRunner の 120 秒タイムアウトで reaper が殺される。flock にはタイムアウトが無いので「130 秒で諦める」の実装も割れる。`scanNow()` が見送り（ロックの待ち切れ・共存ガード）になったとき何の generation を返すかも無い。修正案:
  - reaper は `LOCK_EX|LOCK_NB` で取り、取れなければ `reaper_busy` を出して終了コード 4 で何もせず終わる
  - IngestService は `LOCK_NB` を 1 秒間隔で最大 130 回試す
  - `scanNow()` は「呼び出しの後に開始し、完了した走査」の generation を返し、見送りのときは nil を返す（nil なら回収を残す）
- 【中】**requeueRecopied（契機 4）の中身が無い**: detail、`resetRetry`、ログのどれも決まっていない。`retry_count=3` のまま戻すと、工程内リトライが 1 回で終わる。修正案: 「detail `recopied`、`resetRetry: true`、戻した件数を `recovery_completed requeued=<n>` で出す」。
- 【中】**actor 内の同期ブロッキング**: IngestService（actor）の中で 11 分の同期コピーを、ProcessRunner（actor）の中で `waitpid` を同期で行うと、`latestSnapshot()` や他の `run` が数時間待たされる（whisper の実行中に diskutil / launchctl が止まる）。修正案: 「actor の中で長い同期 I/O・`waitpid` をしない。コピーは nonisolated の関数でタスクとして走らせ、actor は公開状態だけを持つ。子の終了は `DispatchSource.makeProcessSource` と continuation で待つ」と明記する（Mutex を使うなら §3.4 の許可に Synchronization を足す）。
- 【中低】**`LockEvaluator.readiness()` の費用**: `readiness()` は Session ごと・tick ごとに呼ばれるが、そのたびに署名検証と `--version` の起動を行うのかが書かれていない。修正案: 「`(inode, size, mtime)` が変わらない限り、署名と版の結果を actor にキャッシュする。reaper を起動する直前だけは毎回検証する」。
- 【中低】**RV-04 リプレイが既存の結果を上書きする**: 結果を書いた後・要求を消す前に落ちると、次の回に `replayed` の MISMATCH 結果が同じ名前で DELETED 結果を上書きし、実際には消えた Part が PENDING になる。修正案: 「replayed のとき、同じ名前の結果ファイルが在れば書かず、要求だけ消す」。
- 【低中】**Worker.start() と設定エラー**: 設定エラー状態（タイムゾーン不正を含む）でも復旧・closeStaleOpenSessions・孤児の削除を走らせるのかが無い。修正案: 「設定エラー中は start() も何もしない（復旧は解除後の最初の tick で行う）」。
- 【低中】**RetryPolicy の意味**（A.3）: `none` の説明「再評価の契機まで待たない」は逆の意味にも読める。requeueFailed は全 FAILED を戻すので、`none` と `nextConnect` の振る舞いの差が無い。修正案: requeue が RetryPolicy を見ないのであれば、`none` と `nextConnect` を 1 つにまとめ、「工程内リトライの対象かどうか」だけを表す列にする。
- 【低】§8.9.5 の「消し損ね」: readiness が disabled の間に `delete_request_id` を持っていた RAW_SAVED の Part は、期限切れで ID が外れた後、COMPLETED の Session の中で RAW_SAVED のまま残る（過去分の対象にも入らない）。`completeWithoutDeleting` は「期限切れ後の RAW_SAVED も COMPLETED にする」と明記する。

### ノートのバイト列・ファイル
- 【中】**`.<basename>.tmp` の basename に `.md` を含むか**: voicedock の notes.py:248 は `.{target.name}.tmp`（`.md` を含む）。一方 §8.6 は「basename = `.md` を含まない名前」と定義している。§5.3 の復旧で消す tmp の名前（「完全一致」）が実装者によって変わる。修正案: 「`.<基本名>.md.tmp`」と逐語で書く。
- 【低中】**`inboxRetain = raw_saved` の動作が無い**（CV-29 は受理するのに、どこでも使われない）。voicedock でもこの経路で inbox を消すことはない。修正案: 「raw_saved は inbox を自動では消さない」と書き、ConfigEffectTests の対象として明記する。
- 【低】Raw の書き手と検証側で集合が違う: 書き手は「transcript が**読める**」、`verifyRawNote` の期待値は「`transcript_path` が**在る**」。transcript が壊れた Part が 1 本あると、RN-6 が永久に偽になる（安全側に倒れるが、Session の評価が回り続ける）。voicedock と同じだが、§9.1 原則 2 の型なので注記するか揃える。

### DB・その他
- 【低中】§5.6 の集計 SQL `status IN (FAILED, SKIPPED)` を文字どおりに書くと列名として解釈されて SQL エラーになる。PT-06 とも衝突する。「`IN (?, ?)` に rawValue を束縛する」と明記する。
- 【低】§8.3 手順 2 の `disk_space_low` が tick ごとに WARNING を出すと、§5.4 の「ガードの出入りだけ 1 回」と矛盾する。出入りの 1 回だけにする。
- 【低】§8.4 の結果の写し方の表に `signaled(n)`（クラッシュ）が無い。`WHISPER_FAILED`「シグナル <n>: <stderr>」を足す。
- 【低】`unparsable_filename`・`scan_completed`・`transcription_failed`・`llm_failed`・`session_merge_failed`・`diagnostics_completed` は登録されているが、出す場所とフィールドが本文に無い（例: 規則に一致するが日付が不正な名前 → `unparsable_filename relpath=…`）。
- 【低】PT-06 の文字列 `\(…)/\(…)` 検査は、relpath や inbox パスの組み立てでも誤検知する（CR-17）。relpath の結合は `RelPath.join` だけで行う、と決める。

## 4. 明らかな誤り

- 【中】**PT の字句照合が誤検知する**（CR-17 違反）:
  - PT-01 の `remove(` は `SafeUnlink.remove(` の全呼び出しと `Set.remove(` に当たる
  - PT-15 の `Process` は reaper 自身の `ProcessedLog` と `ProcessInfo` に当たる
  - PT-11 の `reaperConf` は `Contract.reaperConfSchema`（§4.5）に当たる
  - PT-21 の `.recovery` は `LogEvent.recoveryCompleted` に当たる
  - 修正案: 「識別子のトークン単位で完全一致させる（前後が識別子文字でない）。`remove(` は修飾なし、または `Darwin.` / `Foundation.` / `Glibc.` で修飾されたものだけを対象にする」と SourceScanner の仕様に書く。
- 【中】**AVAudioFile に Int16 を書く方法**（§8.3 手順 4）: `AVAudioFile(forWriting:settings:)` の processingFormat は Float32 の非インターリーブなので、自前で `clamp(lrint(x×32768))` した Int16 のバッファは書けない（形式の不一致）。Float のまま渡すと、丸めが AVFoundation 任せになる。修正案: `AVAudioFile(forWriting:settings:commonFormat: .pcmFormatInt16, interleaved: true)` と明記する。
- 【低中】**モデル取り込みの名前の順序**（§8.10）: 「読みながら SHA を計算して `.custom-<sha 先頭16>.gguf.part` へコピー」は、SHA が分かる前にその名前を使うことになる。修正案: `.custom-import-<乱数>.gguf.part` へコピーし、SHA が出た後に `custom-<sha16>.gguf` へ rename する（既に在れば `.part` を消して再利用する）。
- 【低】`SecCSFlags(rawValue: kSecCSCheckAllArchitectures)` は Swift では `UInt32(...)` への変換が要る。§8.2 と §9.2 の `func` 宣言は public が無いので、他のモジュールから呼べない（チケットで補う旨を書く）。
