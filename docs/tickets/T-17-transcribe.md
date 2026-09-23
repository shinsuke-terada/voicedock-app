# T-17 VDTranscribe: whisper-cli の起動・出力の正規化・無音判定

> （F-82・issue #119。2026-09-23）(1) アプリの終了で止めた whisper（`stoppedByTerminateAll` が真で終了 0 でない）と閉じた後の起動の拒否（ECANCELED）は失敗にせず、新しい `TranscribeOutcome.stopped` を返す（呼び手は行を動かさない）。(2) 起動の失敗は実行ファイルの問題（ENOENT・EACCES・EPERM・ENOEXEC・ENOTDIR・ELOOP・ENAMETOOLONG・EINVAL・EBADARCH・EBADEXEC・EBADMACHO）だけを `WHISPER_EXEC_MISSING`、ほかは `WHISPER_FAILED`（文言は同じ `spawn: errno <n>`）。(3) 利用者の決定「寛容に読む」: `WhisperOutputParser.parse` は読む前に `lenientText`（不正な UTF-8 を U+FFFD、文字列の中の生の制御文字を `\u00XX`。正常な JSON は 1 バイトも変えない。X-39）を通す。PLAN §8.4 手順 6・7。テストは `TranscriberStoppedTests.swift`・`WhisperOutputParserLenientTests.swift`。

> （F-76・issue #116。2026-09-23）`transcribe` は whisper を起動する前に staging の前回の `whisper.json` を `SafeUnlink.remove(…, under: .staging, missingOK: true)` で消す（落ちた前回の残りを成功として読まない。RK-34）。消せなければ起動せずに `WHISPER_FAILED`「前回の生 JSON を消せません: <HOME からの相対パス>」。テストは `Tests/VDTranscribeTests/TranscriberStaleJSONTests.swift`。

| 項目 | 値 |
|---|---|
| ID | T-17 |
| Phase | 4（変換と文字起こし） |
| 前提 | T-03（`Tests/Fixtures/whisper-cli-help.txt`）、T-10（`PartTranscript` / `PartTranscriptCodec`・`AppClock`・`SafeUnlink`・`AppPaths`・`TextLimit`・`FixedClock`）、T-12（`ProcessRunner`）、T-45（`PyText` / `PyJSON.decode` / `PyRound`）。T-06（`HomeLayout`・`AtomicFile`）・T-08（`StageFailure`）はその前提に含まれる。**T-09（`TranscriptionConfig`・`ModelCatalog`）も要る**（README の索引に無い。整合修正の報告に記載） |
| 見積もり | Sources 約 350 行、Tests 約 550 行（TestSupport の FakeWhisper を含む） |

## 1. 目的

16 kHz 音声を whisper-cli（Metal ビルド。バンドルの `Contents/Helpers/whisper-cli`）で文字起こしし、生 JSON を正規化 transcript
（`transcripts/parts/<slug>.json`）へ変換して保存する。無音を判定する。**状態遷移と DB 更新はしない**（呼び手 = T-18 の `ensureTranscribed`）。
whisper.cpp の知識（argv・JSON の形・`--help`）はこのモジュールの中だけに閉じる。

## 2. 参照

- PLAN §8.4（全体）、§8.2（`ProcessRunner`・`ProcessEnvironment`）、§5.7（`PyText` / `PyJSON` / Unicode スカラー数）、§6.2（`transcription.*`）、§10.2（FakeWhisper）、付録 A.3（WHISPER_* / NO_SPEECH_DETECTED）
- voicedock@d3d595e: `src/voicedock/transcribe.py`（全体）、`tests/fixtures/fake_whisper.py`、`tests/unit/test_transcribe.py`
- 移植メモ V4 §2・§4.1

## 3. 作るもの

| パス | 種別 |
|---|---|
| `Sources/VDTranscribe/WhisperArgs.swift` | `WhisperArgs` |
| `Sources/VDTranscribe/WhisperOutputParser.swift` | `WhisperOutputParser` |
| `Sources/VDTranscribe/Transcriber.swift` | `Transcriber` / `TranscribeRequest` / `TranscribeOutcome` / `TranscribeMetrics` / `TranscribePrerequisite` |
| `Sources/VDTranscribe/WhisperHelpCheck.swift` | `WhisperHelpCheck` |
| `Tests/TestSupport/FakeWhisper.swift` | 偽 whisper-cli（シェルスクリプトを書く） |
| `Tests/VDTranscribeTests/WhisperArgsTests.swift` | |
| `Tests/VDTranscribeTests/WhisperOutputParserTests.swift` | |
| `Tests/VDTranscribeTests/TranscriberTests.swift` | |
| `Tests/VDTranscribeTests/WhisperHelpCheckTests.swift` | |
| `Tests/VDTranscribeTests/FakeWhisperTests.swift` | 偽物自体のテスト（TEST-05） |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 13 キーを消す（§6.6） |

## 4. 仕様

パスの文字列化は `url.path(percentEncoded: false)` を使う（以下 `p(url)` と書く）。

### 4.1 丸め（`PyRound`。VDCore、T-45）

Python の `round(x, n)` と同じ丸めは VDCore の `PyRound.round(_:digits:)`（T-45）を使う。本モジュールに丸めの関数を作らない（PLAN §5.7。旧版の internal `PythonRound` は置き換えた）。
本チケットで使う値の固定例（Python 3.12 の実測。`PyRound` のテストは T-45）: `round(1.5 / 1000, 3) = 0.002`、`round(2 / 1000, 3) = 0.002`、`round(12345 / 1000, 3) = 12.345`、`round(0.4 / 1000, 3) = 0.0`、`round(2.5 / 1000, 3) = 0.003`、`round(1 / 3, 3) = 0.333`。

### 4.2 `WhisperArgs.swift`

```swift
// whisper-cli の argv（PLAN §8.4。voicedock transcribe.py の build_argv と同じ並び）。
import Foundation
import VDCore

public enum WhisperArgs {
    /// `transcription.threads == 0` のときの上限。
    public static let maxAutoThreads = 8

    /// argv[0] を含まない引数の配列（ProcessSpec.arguments にそのまま渡す）。
    public static func build(model: URL, input: URL, outputBase: URL, config: TranscriptionConfig,
                             vadModel: URL?, threads: Int) -> [String]
    /// 値が整数に等しく |x| < 1e15 なら整数の 10 進、そうでなければ Double.description（0.5→"0.5"、1.0→"1"）。
    public static func num(_ x: Double) -> String
    /// configured > 0 ならその値、0 なら min(ProcessInfo.processInfo.activeProcessorCount, 8)。
    public static func resolvedThreads(_ configured: Int) -> Int
}
```

`build` の中身（逐語。この順）:

```swift
var argv = ["-m", p(model), "-f", p(input), "-l", config.language, "-t", String(threads)]
if config.vad.enabled {
    argv += [
        "--vad",
        "--vad-model", vadModel.map { p($0) } ?? "",
        "--vad-threshold", num(config.vad.threshold),
        "--vad-min-speech-duration-ms", String(config.vad.minSpeechDurationMs),
        "--vad-min-silence-duration-ms", String(config.vad.minSilenceDurationMs),
        "--vad-speech-pad-ms", String(config.vad.speechPadMs),
    ]
}
return argv + ["-oj", "-of", p(outputBase), "-np"]
```

- `vad.enabled == false` なら VAD の 6 フラグを 1 つも渡さない
- `vadModel == nil` で VAD 有効の組み合わせは `Transcriber` の前提の確認（§4.4 手順 2）で起きない。起きても空のパスで whisper が失敗し `WHISPER_FAILED` になる（消す側には倒れない）
- `num`: `if x.isFinite, x == x.rounded(.towardZero), abs(x) < 1e15 { return String(Int64(x)) }`、それ以外 `return x.description`
- Metal 用の追加フラグ（flash attention 系など）は足さない（PLAN §8.4）

### 4.3 `WhisperOutputParser.swift`

```swift
// whisper.cpp v1.9.4 の -oj の生 JSON を読む（PLAN §8.4 手順 7。voicedock transcribe.py:333-389）。
import Foundation
import VDCore

public enum WhisperOutputParser {
    /// JSON として読めない（またはトップレベルが null）なら nil。それ以外は壊れた要素を飛ばして必ず結果を返す。
    public static func parse(_ data: Data, fallbackLanguage: String) -> (language: String, text: String, segments: [TranscriptSegment])?
}
```

手順（読み取りは `PyJSON.decode`。`JSONSerialization` を使わない。PLAN §5.7・F-45）:
1. `PyJSON.decode(data)` が nil（不正な UTF-8・JSON でない）、または結果が `.null` → nil（Python の `json.loads` が None を返す場合も「読めない」と同じ扱い）
2. `body: [(String, PyJSONValue)]` = 結果が `.object(o)` なら `o`、でなければ `[]`（辞書でなければ空として続ける）
3. `language`: `member(body, "result")` が `.object(r)` で `member(r, "language")` が空でない `.string(s)` なら `s`、でなければ `fallbackLanguage`
4. `entries` = `member(body, "transcription")` が `.array(items)` なら `items`、でなければ `[]`。各要素について（壊れた要素は**その要素だけ**飛ばす。1 区間の不良で Part 全体を失わない）:
   - `.object(e)` でない、`member(e, "offsets")` が `.object(offsets)` でない、`member(e, "text")` が `.string(text)` でない → 飛ばす
   - `start = seconds(member(offsets, "from"))`、`end = seconds(member(offsets, "to"))`、どちらか nil → 飛ばす
   - `t = PyText.strip(text)`、空 → 飛ばす
   - `TranscriptSegment(start: start, end: end, text: t)` を加える
5. `text = PyText.strip(segments.map(\.text).joined())`（区切り文字なし）
6. `(language, text, segments)` を返す

`member(_ o: [(String, PyJSONValue)], _ key: String) -> PyJSONValue?`（internal）: `o.first { PyText.scalarsEqual($0.0, key) }?.1`（キーはスカラー列で比べる。重複キーは `decode` が後勝ちで 1 つにしている）。
`seconds(_ v: PyJSONValue?) -> Double?`（internal）: `.int(n)` → `ms = Double(n)`、`.double(d)` → `ms = d`、それ以外（`.bool`・`.string`・`.null`・nil など）→ nil。`return PyRound.round(ms / 1000.0, digits: 3)`（**offsets はミリ秒**。ASR-05。整数でも小数でも受ける。文字列・bool は nil）。
`timestamps`（`"00:00:03,200"`）は読まない。

### 4.4 `Transcriber.swift`

```swift
// whisper-cli を実行し正規化 transcript を保存する（PLAN §8.4）。状態遷移と DB 更新はしない。
import Foundation
import VDContract
import VDCore
import VDProcess

public enum TranscribePrerequisite: String, Sendable, CaseIterable, Equatable {
    case whisperMissing = "whisper_missing"        // PauseReason と同じ語（PLAN 付録 A.4）。ケース名は 00-api-map §7
    case modelMissing = "model_missing"
    case vadModelMissing = "vad_model_missing"
}

public struct TranscribeRequest: Sendable {
    public let partkey: String
    public let slug: String                  // KeySlug.of(partkey)
    public let input: URL                    // staging/<slug>/audio16k.wav
    public let durationSeconds: Double?
    public let startedAt: String             // Part の started_at（DB の文字列そのまま）
    public init(partkey: String, slug: String, input: URL, durationSeconds: Double?, startedAt: String)
}

public struct TranscribeMetrics: Equatable, Sendable {
    public let elapsedSeconds: Double        // 丸めない（ログで Python 互換の round(…, 1) をかける）
    public let chars: Int                    // text の Unicode スカラー数
    public let rtf: Double?                  // round(elapsed / duration, 3)。duration が nil か 0 以下なら nil
    public let speechRatio: Double?          // round(Σmax(0, end − start) / duration, 3)。同上
    public init(elapsedSeconds: Double, chars: Int, rtf: Double?, speechRatio: Double?)
}

public enum TranscribeOutcome: Equatable, Sendable {
    case transcribed(PartTranscript, metrics: TranscribeMetrics)
    case noSpeech(PartTranscript, message: String)
    case prerequisiteMissing(TranscribePrerequisite)   // 遷移せずに待つ（ガード。PLAN §5.4）
    case failure(StageFailure)
}

public struct Transcriber: Sendable {
    public init(runner: any ProcessRunning, paths: AppPaths, layout: HomeLayout,
                config: TranscriptionConfig, catalog: ModelCatalog, clock: any AppClock)
    /// ガード（T-18）が使う。前提の欠けを宣言順で返す。
    public func missingPrerequisites() -> [TranscribePrerequisite]
    public func transcribe(_ req: TranscribeRequest) async -> TranscribeOutcome

    /// Int(min(max(duration × timeoutFactor, minTimeoutSeconds), maxTimeoutSeconds))。duration 不明なら maxTimeoutSeconds（ASR-08）。
    static func timeoutSeconds(duration: Double?, config: TranscriptionConfig) -> Int
    /// ProcessResult.stderrTail を UTF-8（不正は置換）で読み、末尾 1000 Unicode スカラー。strip しない。
    static func stderrTail(_ data: Data) -> String
}
```

**前提の確認（`missingPrerequisites`）**。この順に調べ、欠けたものを全部返す:
（VDTranscribe の import 許可リスト（PLAN §3.4・PT-07）に Darwin は無い。`stat` / `access` は Foundation 経由で使う。2 と 3 は T-09 の `ModelFiles.isPresent` / `ModelFiles.url` で書く。中身は下の条件と同じ）
1. `.whisperMissing`: `paths.whisperCLI` が通常ファイルで `access(p, X_OK) == 0`
2. `.modelMissing`: `catalog.entry(kind: .whisper, id: config.whisperModelID)` が在り、`layout.modelFile(kind: "whisper", file: entry.file)` が通常ファイルで size == `entry.bytes`
3. `.vadModelMissing`（`config.vad.enabled` のときだけ）: `catalog.entry(kind: .vad, id: config.vad.modelID)` が在り、`layout.modelFile(kind: "vad", file: entry.file)` が通常ファイルで size == `entry.bytes`

**`transcribe` の手順**（`target = layout.transcript(slug:)`、`rawJSON = layout.whisperJSON(slug:)`、`outBase = layout.whisperOutputBase(slug:)`）:
1. **冪等**: `target` が読めて `PartTranscriptCodec.decode` が合格し、`TextLimit.scalarCount(t.text) >= config.minChars` なら whisper を起動せず
   `.transcribed(t, metrics: metrics(t, elapsed: 0, duration: req.durationSeconds))` を返す
2. **前提**: `missingPrerequisites()` が空でなければ、先頭の要素で `.prerequisiteMissing(…)` を返す（whisper を起動しない。何も消さない）
3. ここから先は `defer { try? SafeUnlink.remove(rawJSON, under: .staging, layout: layout) }`（**どの経路でも whisper.json を消す**）
4. argv: `WhisperArgs.build(model: <whisper モデルの URL>, input: req.input, outputBase: outBase, config: config, vadModel: config.vad.enabled ? <VAD モデルの URL> : nil, threads: WhisperArgs.resolvedThreads(config.threads))`
5. `timeout = Transcriber.timeoutSeconds(duration: req.durationSeconds, config: config)`、`start = clock.uptime()`
6. `result = await runner.run(ProcessSpec(executable: paths.whisperCLI, arguments: argv, environment: ProcessEnvironment.standard), timeout: .seconds(timeout))`
7. `elapsed = clock.uptime() − start` を秒の Double に（`Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18`）
8. 結果の写し方（`tail = Transcriber.stderrTail(result.stderrTail)`）:

| `result.termination` | 返す値 |
|---|---|
| `.spawnFailed(errno: n)` | `.failure(StageFailure(.whisperExecMissing, "spawn: errno \(n)"))` |
| `.timedOut` | `.failure(StageFailure(.whisperTimeout, "\(timeout) 秒を超えました"))`（プロセスグループごと kill は ProcessRunner が行う） |
| `.exited(n)`（n ≠ 0） | `.failure(StageFailure(.whisperFailed, "終了コード \(n): \(tail)"))` |
| `.signaled(n)` | `.failure(StageFailure(.whisperFailed, "シグナル \(n): \(tail)"))` |
| `.exited(0)` | 手順 9 へ |

9. `rawJSON` を読む（`Data(contentsOf:)`）。読めない、または `WhisperOutputParser.parse` が nil →
   `.failure(StageFailure(.whisperFailed, "生 JSON を読めません: \(layout.relativePath(of: rawJSON) ?? p(rawJSON))"))`
   （**whisper.cpp は不明な引数・読めない音声でも終了コード 0 を返すことがある**。成功は「終了 0 かつ JSON が在って読める」。RK-34）
10. `t = PartTranscript(partkey: req.partkey, language: parsed.language, durationSeconds: req.durationSeconds, startedAt: req.startedAt, text: parsed.text, segments: parsed.segments)`
11. **無音判定より前に**保存する（根拠 B の証拠。ASR-09）: `AtomicFile.write(PartTranscriptCodec.encode(t), to: target)`。親ディレクトリが無ければ先に作る。
    失敗したら `.failure(StageFailure(.whisperFailed, "正規化 transcript を書けません: \(describe(error))"))`（`describe` は `"<型名>: <説明>"`）
12. `n = TextLimit.scalarCount(t.text)`。`n < config.minChars` → `.noSpeech(t, message: "\(n) 文字（min_chars=\(config.minChars)）")`（失敗ではない）
13. `.transcribed(t, metrics: metrics(t, elapsed: elapsed, duration: req.durationSeconds))`

`metrics(t, elapsed:, duration:)`: `chars = TextLimit.scalarCount(t.text)`。`duration` が nil か `<= 0` なら `rtf = nil, speechRatio = nil`。
そうでなければ `rtf = PyRound.round(elapsed / duration, digits: 3)`、`speech = Σ max(0, seg.end − seg.start)`、`speechRatio = PyRound.round(speech / duration, digits: 3)`。

- `timeoutSeconds`: `guard let d = duration else { return config.maxTimeoutSeconds }`、`return Int(min(max(d * config.timeoutFactor, Double(config.minTimeoutSeconds)), Double(config.maxTimeoutSeconds)))`
- `stderrTail`: `let s = String(decoding: data, as: UTF8.self)`、`String(String.UnicodeScalarView(s.unicodeScalars.suffix(1000)))`
- 16 kHz 音声の削除（`deleteNormalizedAfterTranscribe`）と `transcript_path` の記録は呼び手（T-18）が行う
- 起動前の「入力が在るか」の確認（ASR-04）と `renormalizeOrFail` は呼び手（T-18）が行う。Transcriber は入力を調べない

### 4.5 `WhisperHelpCheck.swift`

```swift
// whisper-cli --help に VAD の 6 フラグが逐語で在るか（DR-04。本アプリで強化）。
public enum WhisperHelpCheck {
    public static let vadFlags = ["--vad", "--vad-model", "--vad-threshold",
                                  "--vad-min-speech-duration-ms", "--vad-min-silence-duration-ms", "--vad-speech-pad-ms"]
    /// 欠けたフラグを vadFlags の順で返す（空なら全部在る）。
    public static func missingVADFlags(helpOutput: String) -> [String]
}
```

- `helpOutput` は stdout と stderr を連結したもの（呼び手 = T-32 の DR-04 が `--help` を実行して渡す）
- 照合は**トークン単位の完全一致**: 空白（`Character.isWhitespace`）で分けた各トークンの末尾の `,` を 1 つ除いたものの集合に、フラグが**そのまま**在るか。
  `--vad` は `--vad-model` の接頭辞なので部分一致では判定しない（voicedock の D-7 は部分一致で、`--vad` が無くても通っていた）

## 5. TestSupport: `FakeWhisper.swift`

voicedock `tests/fixtures/fake_whisper.py` の移植。**生 JSON の形は whisper.cpp v1.9.4 の `-oj` と同じ**（`offsets` はミリ秒。形を間違えると実機で時刻が 1000 倍になる）。

```swift
// 偽 whisper-cli（PLAN §10.2。voicedock tests/fixtures/fake_whisper.py）。
import Foundation
import VDCore

public struct FakeWhisperUtterance: Sendable, Equatable {
    public let start: Double; public let end: Double; public let text: String     // 秒で書き、出力時にミリ秒へ
    public init(_ start: Double, _ end: Double, _ text: String)
}
public enum FakeWhisperOutput: Sendable { case json, none, broken, custom(String) }

public enum FakeWhisper {
    public static let defaultUtterances: [FakeWhisperUtterance]   // (0.0, 3.2, " おはようございます。"), (5.5, 9.0, " 今日の予定を確認します。")
    public static let helpWithVAD: String
    public static let helpWithoutVAD: String
    /// Python の json.dumps(ensure_ascii=False) の既定（区切り ", " と ": "）と同じ 1 行の JSON。
    public static func rawDocument(_ utterances: [FakeWhisperUtterance] = defaultUtterances, language: String = "ja") -> String
    @discardableResult
    public static func write(to script: URL, utterances: [FakeWhisperUtterance] = defaultUtterances, language: String = "ja",
                             exitCode: Int32 = 0, stderr: String = "", sleepSeconds: Double = 0,
                             grandchildMarker: URL? = nil, selfSignal: Int32? = nil,
                             help: String = helpWithVAD, output: FakeWhisperOutput = .json) throws -> URL
    /// スクリプトが受け取った argv（`<script>.argv` の各行）。無ければ []。
    public static func recordedArgv(_ script: URL) -> [String]
}
```

`helpWithVAD`（逐語。末尾の改行は無し）:
```text
usage: whisper-cli [options] file0 file1 ...
  -m FNAME,  --model FNAME
  -f FNAME,  --file FNAME
  -oj,       --output-json
             --vad
             --vad-model FNAME
             --vad-threshold N
             --vad-min-speech-duration-ms N
             --vad-min-silence-duration-ms N
             --vad-speech-pad-ms N
```
`helpWithoutVAD` は上の先頭 4 行だけ。

`rawDocument` の形（既定の発話で、この 1 行に**バイト単位で一致**させる。voicedock の `json.dumps(raw_document(), ensure_ascii=False)` の実測）:
```text
{"systeminfo": "AVX = 0 | NEON = 1 |", "model": {"type": "large", "multilingual": true}, "params": {"model": "ggml-large-v3-turbo-q5_0.bin", "language": "ja"}, "result": {"language": "ja"}, "transcription": [{"timestamps": {"from": "00:00:00,000", "to": "00:00:03,200"}, "offsets": {"from": 0, "to": 3200}, "text": " おはようございます。"}, {"timestamps": {"from": "00:00:05,500", "to": "00:00:09,000"}, "offsets": {"from": 5500, "to": 9000}, "text": " 今日の予定を確認します。"}]}
```
- `offsets` = `Int((秒 × 1000).rounded(.toNearestOrEven))`（Python の `round`）
- `timestamps` = `whole = Int(秒)`、`millis = Int(((秒 − Double(whole)) × 1000).rounded(.toNearestOrEven))`、`String(format: "%02d:%02d:%02d,%03d", whole / 3600, whole / 60 % 60, whole % 60, millis)`
- 文字列は `"` + `PyJSON.escape(s)` + `"`

`write` が書くスクリプト（`<…>` を埋める。行の並び・空行もこのとおり）:
```sh
#!/bin/sh
printf '%s\n' "$@" > '<script のパス>.argv'
for arg in "$@"; do
  if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
    cat <<'HELP_EOF'
<help>
HELP_EOF
    exit 0
  fi
done
base=''
take=0
for arg in "$@"; do
  if [ "$take" = "1" ]; then base="$arg"; take=0; continue; fi
  if [ "$arg" = "-of" ]; then take=1; fi
done
<待ち>
<stderr>
<自分へのシグナル>
if [ -n "$base" ] && [ "<書くなら 1、書かないなら 0>" = "1" ]; then
  cat > "$base.json" <<'JSON_EOF'
<文書>
JSON_EOF
fi
exit <exitCode>
```
- `<待ち>`: `sleepSeconds == 0` なら空行。marker が無ければ `sleep <sleepSeconds.description>`、在れば 2 行 `( sleep <秒>; touch '<marker のパス>' ) &` と `wait`（孫プロセス。`sh` の直接の子ではないので、プロセスグループごと kill しないと生き残る）
- `<stderr>`: 空なら空行。そうでなければ `>&2 printf %s '<stderr の ' を '"'"' に置き換えたもの>'`
- `<自分へのシグナル>`: `selfSignal` が nil なら空行、在れば `kill -<n> $$`
- `output`: `.json` → 書く・文書は `rawDocument(utterances, language:)`、`.none` → 書かない、`.broken` → 書く・文書は `{"transcription": [`、`.custom(s)` → 書く・文書は s
- 書いた後 `FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath:)`

## 6. テスト

共通の準備（`TranscriberTests`）: `TempDirectory()` の下に `HomeLayout(root:)`（`createDirectories()`）、`AppPaths(resources: <tmp>/resources, helpers: <tmp>/helpers)`。
`FakeWhisper.write(to: paths.whisperCLI, …)`。カタログはテスト内の JSON（whisper `large-v3-turbo-q5_0` / file `ggml-large-v3-turbo-q5_0.bin` / bytes 4、vad `silero-v5.1.2` / file `ggml-silero-v5.1.2.bin` / bytes 4）を
`ModelCatalog.load` で読み、両方のモデルファイルを 4 バイトで作る。CE のテスト（`ceWhisperModelID`・`ceVADModelID`）のために、この JSON には
2 つ目の whisper（`medium-q5_0` / file `ggml-medium-q5_0.bin` / bytes 4）と 2 つ目の vad（`silero-v4` / file `ggml-silero-v4.bin` / bytes 4）も入れ、
その 2 つのファイルも 4 バイトで作る。`config = AppConfig.defaults(timeZone: "Asia/Tokyo").transcription`。
`PARTKEY = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"`、`SLUG = KeySlug.of(PARTKEY)`、`STARTED_AT = "2026-08-29T07:12:04+09:00"`、`DURATION = 1800.0`、
入力は `layout.normalizedAudio(slug: SLUG)` に `RIFF....WAVEfmt ` の 16 バイト（偽 whisper は読まない）。ランナーは本物の `ProcessRunner()`、時計は `FixedClock`（uptime が動かないので elapsed = 0）。

### 6.1 `WhisperArgsTests.swift`（`@Suite("WhisperArgs")`）

| 関数名 / 表示名 | 入力 | 期待 |
|---|---|---|
| `argvMatchesPlan` / 「argv が PLAN §8.4 と逐語一致」 | 既定の config、model `<H>/models/whisper/ggml-large-v3-turbo-q5_0.bin`、input `<H>/staging/<slug>/audio16k.wav`、outputBase `<H>/staging/<slug>/whisper`、vadModel `<H>/models/vad/ggml-silero-v5.1.2.bin`、threads 6 | `["-m", "<H>/models/whisper/ggml-large-v3-turbo-q5_0.bin", "-f", "<H>/staging/<slug>/audio16k.wav", "-l", "ja", "-t", "6", "--vad", "--vad-model", "<H>/models/vad/ggml-silero-v5.1.2.bin", "--vad-threshold", "0.5", "--vad-min-speech-duration-ms", "250", "--vad-min-silence-duration-ms", "1000", "--vad-speech-pad-ms", "200", "-oj", "-of", "<H>/staging/<slug>/whisper", "-np"]` |
| `ceVADThreshold` / 「CE transcription.vad.threshold の値が --vad-threshold に渡る」 | threshold 0.25 | `--vad-threshold` の次が `0.25`（既定なら `0.5`） |
| `ceVADMinSpeechDurationMs` / 「CE transcription.vad.minSpeechDurationMs の値が渡る」 | 100 | `--vad-min-speech-duration-ms` の次が `100`（既定なら `250`） |
| `ceVADMinSilenceDurationMs` / 「CE transcription.vad.minSilenceDurationMs の値が渡る」 | 500 | `--vad-min-silence-duration-ms` の次が `500`（既定なら `1000`） |
| `ceVADSpeechPadMs` / 「CE transcription.vad.speechPadMs の値が渡る」 | 50 | `--vad-speech-pad-ms` の次が `50`（既定なら `200`） |
| `ceTranscriptionLanguage` / 「CE transcription.language が -l に渡る」 | `language = "en"` | `-l` の次が `en`（既定なら `ja`） |
| `vadDisabledPassesNoVadFlag` / 「CE transcription.vad.enabled false なら VAD のフラグを 1 つも渡さない」 | `vad.enabled = false`（既定の true では 6 つ渡る） | `--vad` で始まる要素が無い |
| `numFormat` / 「数値の書式」（パラメータ化） | 0.5, 1.0, 0.25, 2.0, 0.1 | "0.5", "1", "0.25", "2", "0.1" |
| `threadsFromConfig` / 「CE transcription.threads > 0 はそのまま -t に渡る」（パラメータ化） | 4, 16 | 4, 16（`-t` の次がその値） |
| `zeroThreadsIsCapped` / 「threads = 0 は論理 CPU 数と 8 の小さい方」 | 0 | `min(ProcessInfo.processInfo.activeProcessorCount, 8)`、かつ ≤ 8 |

### 6.2 `WhisperOutputParserTests.swift`（`@Suite("WhisperOutputParser")`）

| 関数名 / 表示名 | 入力 | 期待 |
|---|---|---|
| `parsesDefaultDocument` / 「既定の生 JSON を読む」 | `FakeWhisper.rawDocument()` | language `ja`、segments `[(0.0, 3.2, "おはようございます。"), (5.5, 9.0, "今日の予定を確認します。")]`、text `おはようございます。今日の予定を確認します。` |
| `offsetsAreMilliseconds` / 「ASR-05 offsets はミリ秒」 | 発話 (12.5, 20.25, " 正午すぎ") | segments `[(12.5, 20.25, "正午すぎ")]` |
| `fractionalMillisecondsAreRoundedLikePython` / 「小数のミリ秒は Python と同じ丸め」 | `{"transcription":[{"offsets":{"from":1.5,"to":2},"text":"a"}]}` | start 0.002、end 0.002 |
| `boolOffsetsAreSkipped` / 「bool の offsets は飛ばす」 | `{"from": true, "to": 1}` の要素と正常な要素 | 正常な要素だけ |
| `onlyBadEntryIsSkipped` / 「壊れた要素だけ飛ばす」 | 正常・`{"offsets":{"from":null,"to":null},"text":"壊れている"}`・正常 | 正常な 2 つだけ（`よい`、`もよい`） |
| `usesReportedLanguage` / 「result.language を使う」 | language `en` の文書 | `en` |
| `unparseableIsNil` / 「JSON でなければ nil」（パラメータ化） | `{"transcription": [`、`null`、空 | nil |
| `neverCrashes` / 「形が崩れても結果を返す」（パラメータ化） | `{}`、`{"transcription":"not a list"}`、`{"transcription":[1,2,3]}`、`{"transcription":[{"offsets":{"from":"x","to":1},"text":"a"}]}`、`{"transcription":[{"text":"offsets が無い"}]}`、`"string"` | nil でない、language `ja`、segments 空、text 空 |
| `textIsStrippedAndEmptyDropped` / 「text は strip し、空の区間は捨てる」 | text が `"  "`、`"\u{3000}x\u{3000}"` の 2 区間 | segments は `x` の 1 つ |

### 6.3 `TranscriberTests.swift`（`@Suite("Transcriber", .serialized)`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `writesNormalizedTranscriptBytes` / 「正規化 transcript が voicedock と同じバイト列」 | 既定の偽 whisper | `.transcribed`、`layout.transcript(slug: SLUG)` の中身が下の「期待するファイル」と**バイト一致** |
| `argvIsPassedAsArray` / 「argv が配列で渡る」 | 同上 | `FakeWhisper.recordedArgv` が §6.1 の形（パスは実際の `<H>`）と一致 |
| `rawJSONIsRemovedAfterSuccess` / 「成功後に whisper.json が残らない」 | 同上 | `layout.whisperJSON(slug:)` が無い。`transcripts/parts/` には `<SLUG>.json` だけ |
| `existingTranscriptIsReused` / 「読める transcript があれば whisper を起動しない」 | 1 回目の後に `<script>.argv` を消し、もう一度 | `.transcribed`、`recordedArgv` が空 |
| `brokenTranscriptIsRegenerated` / 「壊れた transcript は作り直す」 | transcript に `{` を置く | whisper が起動し `.transcribed` |
| `shortTranscriptIsRegenerated` / 「minChars 未満の transcript は作り直す」 | text が空の transcript を置く | whisper が起動する |
| `nonzeroExitIsWhisperFailed` / 「終了コード ≠ 0 は WHISPER_FAILED」 | exitCode 3、stderr `boom` | `.failure(.whisperFailed, "終了コード 3: boom")`、whisper.json が無い |
| `stderrTailIsKept` / 「stderr の末尾 1000 字を残す」 | exitCode 1、stderr = `"x" × 4000 + "REAL_CAUSE"` | 文言が `REAL_CAUSE` で終わり、`終了コード 1: ` の後がちょうど 1000 スカラー |
| `signalIsWhisperFailed` / 「シグナルで終わると WHISPER_FAILED」 | selfSignal 9 | `.failure(.whisperFailed)`、文言が `シグナル 9: ` で始まる |
| `spawnFailureIsExecMissing` / 「起動できなければ WHISPER_EXEC_MISSING」 | whisper-cli を実行権付きの `not a script`（シバン無し）にする | `.failure(.whisperExecMissing, "spawn: errno 8")`（ENOEXEC） |
| `exitZeroWithoutJSONIsFailed` / 「終了 0 でも JSON が無ければ WHISPER_FAILED」（RK-34） | output `.none` | `.failure(.whisperFailed, "生 JSON を読めません: staging/<SLUG>/whisper.json")` |
| `brokenJSONIsFailed` / 「壊れた JSON は WHISPER_FAILED」 | output `.broken` | 同上の文言、whisper.json が無い |
| `timeoutKillsProcessGroup` / 「タイムアウトで孫まで消える」（ASR-07） | `minTimeoutSeconds = 1`、`maxTimeoutSeconds = 1`、sleepSeconds 3、grandchildMarker `<tmp>/marker` | `.failure(.whisperTimeout, "1 秒を超えました")`、戻るまで 10 秒未満、戻った後 4 秒待っても marker が無い |
| `timeoutRemovesPartialOutput` / 「タイムアウトで whisper.json を消す」 | 同上、実行前に whisper.json を置く | whisper.json が無い |
| `noSpeechIsNotFailure` / 「発話なしは失敗ではない」 | utterances 空 | `.noSpeech(t, "0 文字（min_chars=1）")`、`t.text == ""` |
| `noSpeechStillWritesTranscript` / 「ASR-09 無音でも transcript を先に書く」 | 同上 | transcript のファイルが在り、decode でき、text が空 |
| `minCharsIsRespected` / 「CE transcription.minChars を守る」 | 発話 `(0, 1, " あ")`、minChars 1（既定）と 2 | 1 → `.transcribed`、2 → `.noSpeech(_, "1 文字（min_chars=2）")`。結合文字の発話 `(0, 1, " か\u{3099}")`（2 スカラー・1 書記素）は minChars 2 で `.transcribed`（§7 の最後の行） |
| `ceWhisperModelID` / 「CE transcription.whisperModelID を変えると -m のパスが変わる」 | `whisperModelID = "medium-q5_0"` | `recordedArgv` の `-m` の次が `<H>/models/whisper/ggml-medium-q5_0.bin`（既定なら `ggml-large-v3-turbo-q5_0.bin`） |
| `ceVADModelID` / 「CE transcription.vad.modelID を変えると --vad-model のパスが変わる」 | `vad.modelID = "silero-v4"` | `--vad-model` の次が `<H>/models/vad/ggml-silero-v4.bin`（既定なら `ggml-silero-v5.1.2.bin`） |
| `missingCLIIsPrerequisite` / 「whisper-cli が無ければ前提の欠け」 | whisper-cli を消す | `.prerequisiteMissing(.whisperMissing)`、何も書かない |
| `missingModelIsPrerequisite` / 「モデルが無い・大きさが違えば前提の欠け」 | whisper モデルを 3 バイトにする | `.prerequisiteMissing(.modelMissing)` |
| `missingVADModelIsPrerequisiteOnlyWhenEnabled` / 「VAD モデルは VAD 有効のときだけ要る」 | VAD モデルを消す。enabled true / false | true → `.prerequisiteMissing(.vadModelMissing)`、false → `.transcribed` |
| `missingPrerequisitesListsAll` / 「欠けを全部返す」 | CLI とモデルと VAD モデルを消す | `[.whisperMissing, .modelMissing, .vadModelMissing]` |
| `timeoutTable` / 「タイムアウトの式」（パラメータ化） | duration nil, 10, 199.9, 200, 1800, 7200, 1_000_000 | 21600, 600, 600, 600, 5400, 21600, 21600 |
| `ceTranscriptionTimeoutFactor` / 「CE transcription.timeoutFactor を 1.0 にすると上限が縮む」 | duration 1800、`timeoutFactor = 1.0` | `1800`（既定の 3.0 なら `5400`） |
| `ceTranscriptionMinTimeoutSeconds` / 「CE transcription.minTimeoutSeconds が下限になる」 | duration 10、`minTimeoutSeconds = 60` | `60`（既定の 600 なら `600`） |
| `ceTranscriptionMaxTimeoutSeconds` / 「CE transcription.maxTimeoutSeconds が上限（duration 不明のときの値）」 | duration nil と 7200、`maxTimeoutSeconds = 900` | どちらも `900`（既定の 21600 なら `21600`） |
| `metricsMatchSpec` / 「メトリクス」 | 既定の発話、DURATION 1800、FixedClock | chars 22、rtf 0.0、speechRatio 0.004（(3.2 + 3.5) / 1800 を 3 桁） |
| `metricsDoNotDivideByZero` / 「duration が nil か 0 なら rtf と speechRatio は nil」 | duration nil と 0 | どちらも nil |

期待するファイル（`writesNormalizedTranscriptBytes`。voicedock の `json.dumps(…, ensure_ascii=False, indent=2) + "\n"` の実測。末尾に改行が 1 つ）:
```json
{
  "partkey": "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
  "language": "ja",
  "duration_seconds": 1800.0,
  "started_at": "2026-08-29T07:12:04+09:00",
  "text": "おはようございます。今日の予定を確認します。",
  "segments": [
    {
      "start": 0.0,
      "end": 3.2,
      "text": "おはようございます。"
    },
    {
      "start": 5.5,
      "end": 9.0,
      "text": "今日の予定を確認します。"
    }
  ]
}
```

### 6.4 `WhisperHelpCheckTests.swift`（`@Suite("WhisperHelpCheck")`）

| 関数名 / 表示名 | 入力 | 期待 |
|---|---|---|
| `helpWithVADHasAllFlags` / 「VAD ありの help は欠けなし」 | `FakeWhisper.helpWithVAD` | `[]` |
| `helpWithoutVADMissesAll` / 「VAD なしの help は 6 つ全部欠ける」 | `FakeWhisper.helpWithoutVAD` | `vadFlags` と同じ配列 |
| `prefixIsNotEnough` / 「--vad-model だけでは --vad を満たさない」 | `"  --vad-model FNAME\n"` | `--vad` を含む（`--vad-model` は含まない） |
| `trailingCommaIsIgnored` / 「末尾の , を除いて照合する」 | `"-vm FNAME, --vad-model FNAME\n  --vad,"` | `--vad` と `--vad-model` を含まない |
| `realHelpFixtureHasAllFlags` / 「DR-04 固定した whisper-cli の help に 6 フラグが在る」 | `Tests/Fixtures/whisper-cli-help.txt`（T-03。`PackageRoot` から読む。無ければ fail） | `[]` |

### 6.5 `FakeWhisperTests.swift`（`@Suite("FakeWhisper", .serialized)`）

| 関数名 / 表示名 | 期待 |
|---|---|
| `rawDocumentMatchesVoicedock` / 「生 JSON が voicedock の偽物と同じ 1 行」 | §5 の 1 行とバイト一致 |
| `rawDocumentForNoonUtterance` / 「発話 (12.5, 20.25) の JSON」 | `…"transcription": [{"timestamps": {"from": "00:00:12,500", "to": "00:00:20,250"}, "offsets": {"from": 12500, "to": 20250}, "text": " 正午すぎ"}]}` で終わる |
| `recordsArgv` / 「argv を 1 行ずつ記録する」 | `ProcessRunner` で `["-of", "<tmp>/x", "-np"]` を渡すと `recordedArgv == ["-of", "<tmp>/x", "-np"]`、`<tmp>/x.json` が生 JSON |
| `helpPrintsHelpText` / 「--help で help を出して 0」 | stdout が `helpWithVAD` ＋改行、終了 0、JSON を書かない |
| `outputNoneWritesNothing` / 「output .none は JSON を書かない」 | `<base>.json` が無い |
| `exitCodeAndStderr` / 「終了コードと stderr」 | exitCode 5・stderr `it's bad` → `.exited(5)`、stderr が `it's bad` |
| `grandchildTouchesMarker` / 「孫プロセスが marker を作る」（kill しない場合の陰性対照） | sleep 1 と marker、タイムアウト 10 秒 → 終了後に marker が在る |

### 6.6 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`transcription.*` の 13 行（`whisperModelID`・`language`・`threads`・`timeoutFactor`・`minTimeoutSeconds`・`maxTimeoutSeconds`・`minChars`・`vad.enabled`・`vad.modelID`・`vad.threshold`・`vad.minSpeechDurationMs`・`vad.minSilenceDurationMs`・`vad.speechPadMs`）を消す（CE テストは §6.1・§6.3）。

## 7. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `seconds()` の `/ 1000.0` を消す | `offsetsAreMilliseconds`、`writesNormalizedTranscriptBytes` |
| 手順 9 の「JSON が無ければ失敗」を消し、空の transcript で続ける | `exitZeroWithoutJSONIsFailed` |
| 手順 11（保存）を手順 12（無音判定）の後へ動かし、無音なら保存しない | `noSpeechStillWritesTranscript` |
| `defer` の whisper.json の削除を消す | `rawJSONIsRemovedAfterSuccess`、`timeoutRemovesPartialOutput` |
| 冪等の確認を消す | `existingTranscriptIsReused` |
| `vad.enabled` の分岐を消して常に VAD のフラグを渡す | `vadDisabledPassesNoVadFlag` |
| `num` を常に `description` にする | `numFormat`（`argvMatchesPlan` は落ちない。既定の argv で `num` を通るのは threshold の 0.5 だけで、`description` でも `"0.5"`。実装時に確認） |
| `missingVADFlags` を部分一致（`contains`）にする | `prefixIsNotEnough` |
| `.signaled` の分岐を `.exited` と同じ文言にする | `signalIsWhisperFailed` |
| `TextLimit.scalarCount` を `String.count` にする（結合文字を含む text で） | `minCharsIsRespected`（結合文字の例 `"か\u{3099}"` は 2 スカラー・1 書記素。§6.3 の行に含めた） |

## 8. 受け入れ条件

- [ ] §3 のファイルがすべて在り、公開宣言が 00-api-map.md §7（と下の変更提案）に一致する
- [ ] 正規化 transcript のバイト列が voicedock と一致する（§6.3）
- [ ] whisper.json はどの経路でも残らない
- [ ] 子プロセスの起動は `ProcessRunning` 経由だけ（PT-03）。シェルを通さない（PT-04。FakeWhisper は Tests の中なので対象外）
- [ ] §6 のテストがすべて通る
- [ ] `make lint` が通る

## 9. SPEC の変更

`docs/SPEC.md` は `tools/spec/make-spec.py` の生成物なので、**その表に 1 行足して**（`("S10. whisper-cli の argv", "8.4", "text-fence")`。PLAN §8.4 の `text` フェンス（argv）をそのまま写す）次の節を出し、PolicyTests の SPEC 同期に `whisperArgvMatchesSpec`（`WhisperArgs.build` の結果が節のブロックと逐語一致。`<HOME>` と `<slug>` はそのままの文字列を渡す）を足す
（voicedock が §10.6 の bash ブロックと argv を照合していたのと同じ。SPEC だけ変わって実装が変わらない事故を防ぐ）。見出しは **`S` で始める**（T-05 の節の区切りは `^#{1,6} (?:[0-9A-Z]|付録)` なので、小文字で始めると前の節に飲み込まれる）:

````markdown
## S10. whisper-cli の argv

```text
-m <HOME>/models/whisper/ggml-large-v3-turbo-q5_0.bin -f <HOME>/staging/<slug>/audio16k.wav -l ja -t 6 --vad --vad-model <HOME>/models/vad/ggml-silero-v5.1.2.bin --vad-threshold 0.5 --vad-min-speech-duration-ms 250 --vad-min-silence-duration-ms 1000 --vad-speech-pad-ms 200 -oj -of <HOME>/staging/<slug>/whisper -np
```
````

**実装の注記（T-17 の実装時）**: この節は T-17 の PR では実装していない。(1) `PolicyTests` のターゲットは `TestSupport` にしか依存せず（`Package.swift`。T-01 の持ち物）、`WhisperArgs.build` を呼べない。(2) 上のブロックは PLAN §8.4 の `text` フェンス（先頭に `<bundle>/Contents/Helpers/whisper-cli`、`-t <threads>`、5 行に折り返し）と逐語で一致せず、「そのまま写す」と両立しない。どちらも利用者の判断が要る（末尾の変更提案 9）。 → GitHub issue #18（SPEC 同期の拡張。T-06・T-07 の分と同じ）に切り出した。当面は `argvMatchesPlan` が PLAN §8.4 の argv を固定値で照合する
→ **SPEC 同期は #18 で足した**（PLAN F-68）: 上のブロック（1 行）ではなく、PLAN §8.4 の `text` フェンスを**そのまま**（先頭の実行ファイル・`-t <threads>`・5 行の折り返しごと）SPEC の `S11. whisper-cli の argv（PLAN §8.4）` に写す（`make-spec.py` の `("fence", "text")`）。照合は PolicyTests ではなく `Tests/VDTranscribeTests/SpecSyncWhisperArgsTests.swift` の `whisperArgvMatchesSpec`（「argv が SPEC S11 と逐語で同じ（先頭の実行ファイルを除く）」）。SPEC の語から先頭の実行ファイルを除き、`<HOME>`・`<slug>`・`<threads>` を置き換えて `WhisperArgs.build` の既定値と比べる。`argvMatchesPlan` は二重の守りとして残す

## 10. マージ後にやること

なし。

## API 地図への変更提案

1. `WhisperArgs.build` から `whisperCLI:` を外す（argv[0] を含まないので使わない。実行ファイルは `ProcessSpec.executable` で渡す）。新しい形は
   `build(model:input:outputBase:config:vadModel:threads:)` → 00-api-map に反映済み（2026-09-18）
2. `Transcriber.init` に `clock: any AppClock` を足す（elapsed の計測。`ContinuousClock` を直接使えない。PT-09）→ 00-api-map に反映済み（2026-09-18）
3. `TranscribeOutcome` に `case prerequisiteMissing(TranscribePrerequisite)` を、`Transcriber` に `func missingPrerequisites() -> [TranscribePrerequisite]` を足す。
   `TranscribePrerequisite` の rawValue は `PauseReason` の `whisper_missing` / `model_missing` / `vad_model_missing` と同じ語（T-18 のガードがこれで理由を出す。
   モデルの欠けを行に書かない。PLAN 付録 A.3 の WHISPER_MODEL_MISSING の扱い）→ 00-api-map に反映済み（2026-09-18）。ケース名は地図の `whisperMissing` / `modelMissing` / `vadModelMissing` に合わせた
4. `TranscribeRequest` / `TranscribeMetrics` に公開の init が要る（地図に記載が無い）→ 00-api-map に反映済み（2026-09-18）
5. Python の `round(x, n)` 互換の丸め（`PythonRound`）は T-18 のログ（`elapsed_s` の小数 1 桁）でも要る。VDCore（T-45）に `PyRound.round(_:digits:)` として置き、
   このチケットの internal の `PythonRound` はそれに置き換えるのがよい → 00-api-map に反映済み（2026-09-18）。本文を `PyRound` に置き換え、`PythonRound.swift` を作るものから外した
6. PolicyTests（T-05）の SPEC 読み取りに「見出しの名前でコードブロックを取る」関数（例 `SpecDocument.codeBlock(heading:language:)`）が要る（§9 の SPEC 同期）→ 00-api-map §15 に反映済み（2026-09-18）
7. T-17 の前提に T-03 を足す（`Tests/Fixtures/whisper-cli-help.txt`。ファイル名は T-03 で確定させる）→ README の索引に反映済み（2026-09-18）
8. （整合修正で追加）生 JSON の読み取りを `PyJSON.decode`（`PyJSONValue`）にした（PLAN §5.7・F-45）。T-09 を README の前提に足す必要がある（`TranscriptionConfig`・`ModelCatalog`）
9. （T-17 の実装時）§9 の SPEC 同期は未実装。決めることは 2 つ: (a) `whisperArgvMatchesSpec` を置く場所（`PolicyTests` に `VDTranscribe` への依存を足す＝`Package.swift` の変更か、`VDTranscribeTests` に置くか）、(b) SPEC の S10 の中身（PLAN §8.4 のフェンスを写すなら、比べる前に argv[0] を落とし `<threads>` を置き換え、空白で区切って比べる規則が要る。§9 の 1 行のブロックにするなら PLAN §8.4 にそのブロックを足す）
