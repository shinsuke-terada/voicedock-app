# T-20 VDLLM: チャンク分割・Map-Reduce・重複除去

| 項目 | 値 |
|---|---|
| ID | T-20 |
| Phase | 5（LLM とモデル） |
| 前提 | T-19（`AnalysisSchema`・`AnalysisResult`・`Prompts`・`ChatTransport`・`AnalysisCall`・`FakeChatTransport`）。T-45 の `GoldenCase.orderedObject`（`Tests/TestSupport/GoldenCase+PyJSON.swift`）。T-10（`SessionTranscript`・`AbsoluteSegment`・`Instant`・`ZonedTime`・`TextLimit`）、T-45（`PyText`・`PyJSON`）、T-25（golden）、T-09（`GoldenConfig`）は T-19 の前提に含まれる |
| 見積もり | ソース約 300 行・テスト約 500 行 |
| 後続 | T-21（本番の `ChatTransport`）、T-22（解析工程）、T-27（Timeline が `partials` と `chunks` を使う）、T-24（受け入れ試験） |

## 1. 目的

Session の統合結果を LLM に渡せる大きさのチャンクへ分け、1 チャンクなら単一パス、2 チャンク以上なら Map → Reduce（必要なら多段）で最終の解析結果を作る（PLAN §8.5「Map-Reduce」）。
分割・束ね方・重複除去・切り詰めの記録は voicedock@d3d595e `llm.py:684-1066` と**同じ結果**にする。

## 2. 参照

- PLAN §8.5「Map-Reduce」、§5.7（`Instant`・`PyText`・`PyJSON`・文字数はスカラー数）、§9.2（CR-23・CR-24）、付録 A.3（`SESSION_MERGE_FAILED`・`LLM_INVALID_JSON`）、付録 C の LLM-05
- 00-api-map §8（`Chunk`・`Chunker`・`Dedupe`・`Analyzer`・`AnalyzeOutcome`）
- voicedock@d3d595e:
  - `src/voicedock/llm.py:670-698`（`REDUCE_MAX_DEPTH`・`DEDUPE_FIELDS`・`Chunk`）、`:700-786`（`split_chunks`・`_is_only_overlap`・`_limits`・`_overlap`・`_chunk`）、
    `:821-908`（`analyze_session`）、`:920-1011`（`reduce_phase`・`_bundles`・`_as_json`）、`:1015-1066`（`normalize_for_dedupe`・`dedupe`・`_deduped`・`_dedupe_tasks`）
  - `tests/unit/test_chunking.py`、`tests/unit/test_reduce.py`

## 3. 作るもの

ソース（`Sources/VDLLM/`）:
- `Chunker.swift`（`Chunk`・`Chunker`）
- `Dedupe.swift`
- `ReduceBundling.swift`（internal。Reduce の入力の JSON と束ね方）
- `Analyzer.swift`（`Analyzer`・`AnalyzeOutcome`）

テスト（`Tests/VDLLMTests/`）:
- `ChunkerTests.swift`、`DedupeTests.swift`、`ReduceBundlingTests.swift`、`AnalyzerTests.swift`
- `GoldenCase+List.swift`（T-25 の `GoldenCase` への internal な extension。`orderedList(_:)`。§5.0）

`ChatTransport`・`ChatResult`・`FakeChatTransport` は T-19 が作る（修復の流れのテストに要るため）。本チケットはそれを使う。

`Tests/PolicyTests/ConfigEffectPending.swift`（変更。§5.5）: 自分のキーの行を消す。

## 4. 仕様

### 4.1 `Chunker.swift`（「// 統合済みの segment をチャンクに分ける（voicedock llm.py:700-786 と同じ結果）。時刻は LLM に渡さない。」）

```swift
public struct Chunk: Equatable, Sendable {
    public let text: String               // segments の text を "\n" でつないだもの
    public let startAt: Instant           // segments[0].at
    public let endAt: Instant             // segments の endAt の最大
    public let segments: [AbsoluteSegment]
}

public enum Chunker {
    public static func chunk(_ segs: [AbsoluteSegment], maxChars: Int, maxSeconds: Int, overlapChars: Int) -> [Chunk]
}
```

手順（`segs` は統合済みで `(at, endAt)` の順。並べ替えない）:
```text
chunks = []; current = []
for seg in segs:
  current が空なら current = [seg]; continue
  chars = Σ scalarCount(current の各 text) + scalarCount(seg.text)      // 区切りの "\n" は数えない
  overChars = chars > maxChars
  overTime  = (seg.endAt − current[0].at) > Int64(maxSeconds) × 1000      // ミリ秒の整数で比べる
  overChars か overTime:
     chunks に make(current) を足す
     current = overTime ? [] : overlap(current, overlapChars)             // 実時間で超えたら重ねない（両方超えたときも重ねない。LLM-05）
  current.append(seg)
current が空でなく、かつ onlyOverlap(chunks, current) でなければ chunks に make(current) を足す
return chunks

overlap(current, limit):
  limit <= 0 なら []
  taken = []; total = 0
  for seg in current を末尾から:
     total + scalarCount(seg.text) > limit かつ taken が空でない → break
     taken の先頭に seg を入れる; total += scalarCount(seg.text)
  taken.count < current.count ? taken : Array(taken.dropFirst())       // 全部は重ねない（先頭の 1 つを落とす）

onlyOverlap(chunks, current):
  chunks が空なら false
  current のすべての要素が chunks.last!.segments のどれかと等しい（AbsoluteSegment の ==。値で比べる）なら true
  （`!` は使わない。`guard let last = chunks.last`）

make(segments):
  Chunk(text: segments.map(\.text) を "\n" でつなぐ, startAt: segments[0].at, endAt: segments.map(\.endAt).max, segments: segments)
```
- **segment の境界でだけ切る**。1 つの segment が上限を超えてもその segment だけで 1 チャンクにする
- 文字数は Unicode スカラー数（`TextLimit.scalarCount`）
- 空の入力は `[]`

### 4.2 `Dedupe.swift`（「// Reduce の結果の重複除去（voicedock llm.py:1015-1066）。曖昧一致はしない。」）

```swift
public enum Dedupe {
    /// 正規形 = casefold(strip(NFKC(s)))。この順（voicedock normalize_for_dedupe）。
    public static func key(_ s: String) -> String
    /// 順序を保ち、同じ key の 2 つ目以降を落とす。
    public static func strings(_ values: [String]) -> [String]
    /// tasks は text の key で比べる（due が違っても 1 件）。最初の要素を残す。
    public static func tasks(_ values: [AnalysisTask]) -> [AnalysisTask]
    /// key_points / decisions / ideas / tags（nil でなく空でないものだけ）と tasks（nil でなければ）に適用する。title と summary は変えない。
    public static func apply(_ r: AnalysisResult) -> AnalysisResult
}
```

- `key(s) = PyText.casefold(PyText.strip(PyText.nfkc(s)))`
- 実測（voicedock）: `" VoiceDock "`→`voicedock`、`"ＶｏｉｃｅＤｏｃｋ"`→`voicedock`、`"VOICEDOCK"`→`voicedock`、`"ﾃｽﾄ"`→`テスト`、`"Straße"`→`strasse`、`"ﬁle"`→`file`、`"ﬀ"`→`ff`、`"ΣΑΣ"`→`σασ`、
  `"ǅ"`→`dž`、`"İstanbul"`→`i̇stanbul`、`"\u{3000}全角空白\u{3000}"`→`全角空白`、`"\u{1c}X\u{1f}"`→`x`、`"\u{200b}X"`→`\u{200b}x`（ゼロ幅空白は空白ではない）
- `"削除条件を整理した"` と `"削除条件を整理する"` は別物（曖昧一致しない）

### 4.3 `ReduceBundling.swift`（internal。「// Reduce の入力（中間結果の JSON 配列）と束ね方（voicedock llm.py:986-1011）。」）

```swift
enum ReduceBundling {
    /// 中間形のスキーマで各結果を pyJSON にし、PyJSON のコンパクト形式（区切り "," ":"、非 ASCII はそのまま、sortKeys なし）で配列にした文字列。
    static func asJSON(_ partials: [AnalysisResult], schema: AnalysisSchema) -> String
    /// 時刻順のまま貪欲に詰める。current が空でなく asJSON(current + [item]) のスカラー数が limit を超えるなら current を確定し [item] から始める。
    static func bundles(_ partials: [AnalysisResult], schema: AnalysisSchema, limit: Int) -> [[AnalysisResult]]
}
```

- `asJSON` の形（voicedock `_as_json` と同じ）: キーは中間形のフィールドの並び（`summary, key_points, tasks, decisions, ideas` のうち有効なもの）、**空配列も `"due": null` も出す**、`/` はエスケープしない、制御文字は `\n \r \t \b \f` 以外 `\u00xx`（小文字）
- 実測: summary `"朝/昼\n\"引用\"\t\\\u{1}"`、key_points `["a"]`、tasks `[{"text":"x"}]` の 1 個 →
  `[{"summary":"朝/昼\n\"引用\"\t\\\u0001","key_points":["a"],"tasks":[{"text":"x","due":null}],"decisions":[],"ideas":[]}]`
- ideas を無効にした中間形で summary `"s"`・tasks `[{"text":"a"}]` → `[{"summary":"s","key_points":[],"tasks":[{"text":"a","due":null}],"decisions":[]}]`
- 束ね方の実測（既定の中間形、summary `"s0"`〜`"s4"`、他は空。1 個・2 個・3 個の asJSON はそれぞれ 71・141・211 スカラー）:
  limit 70 → `[[s0],[s1],[s2],[s3],[s4]]`、141 → `[[s0,s1],[s2,s3],[s4]]`、142 → 同じ、212 → `[[s0,s1,s2],[s3,s4]]`
- 1 個で上限を超える要素も単独の束にする（空の current には必ず入れる）

### 4.4 `Analyzer.swift`（「// Session の解析: 単一パスか Map → Reduce（voicedock llm.py:821-1011）。例外を投げない。」）

```swift
public enum AnalyzeOutcome: Equatable, Sendable {
    /// partials: 1 段目の Map の結果（チャンクと同じ順。単一パスなら []）。Timeline の素材（T-27）。
    /// chunks: 分割したチャンク（llm_completed の chunks= と Timeline の時刻範囲に使う）。
    /// trimmed: 切り詰めの記録（段の前置き付き。単一パスは前置き無し）。呼び手が analysis_trimmed に出す。
    case success(AnalysisResult, partials: [AnalysisResult], chunks: [Chunk], trimmed: [String])
    case failure(StageFailure)
}

public struct Analyzer: Sendable {
    public static let reduceMaxDepth = 3            // voicedock REDUCE_MAX_DEPTH
    public init(transport: any ChatTransport, prompts: Prompts, config: LLMConfig)
    public func analyze(_ t: SessionTranscript) async -> AnalyzeOutcome
}
```

- `init` で `finalSchema = AnalysisSchema(config: .init(sections: config.analysis.sections), kind: .final)`、`partialSchema = …(kind: .partial)`、
  `call = AnalysisCall(transport:, prompts:, customInstructions: config.analysis.customInstructions, repairAttempts: config.repairAttempts)` を作って持つ

`analyze(_ t:)`:
```text
chunks = Chunker.chunk(t.segments, maxChars: config.maxCharsPerRequest, maxSeconds: config.maxSecondsPerRequest, overlapChars: config.chunkOverlapChars)
chunks が空 → .failure(StageFailure(.sessionMergeFailed, "チャンクが 0 個です（統合結果が空）"))
chunks が 1 個（単一パス）:
   r = await call.run(kind: .analyze, schema: finalSchema, body: chunks[0].text)
   失敗 → .failure(f)
   成功 → .success(r.result, partials: [], chunks: chunks, trimmed: r.trimmed)          // 重複除去しない。trimmed に前置きを付けない
2 個以上:
   partials = []; trimmed = []
   for chunk in chunks:                                                                  // チャンクの順に 1 つずつ（並行に投げない）
      r = await call.run(kind: .map, schema: partialSchema, body: chunk.text)
      失敗 → return .failure(f)                                                          // Map が 1 つでも落ちたら Reduce へ進まない
      trimmed += r.trimmed を各 "map: " + note に
      partials.append(r.result)
   red = await reduce(partials, depth: 1)
   red が失敗 → .failure(f)
   成功(result, notes) → .success(result, partials: partials, chunks: chunks, trimmed: trimmed + notes)

reduce(items, depth) -> Result<(AnalysisResult, [String]), StageFailure>:     // internal func reduce(_ items: [AnalysisResult], depth: Int) async（テストから直接呼ぶ）
   body = ReduceBundling.asJSON(items, schema: partialSchema)
   scalarCount(body) <= config.maxCharsPerRequest か items.count <= 1:
      r = await call.run(kind: .reduce, schema: finalSchema, body: body)                  // 最終形で検証
      失敗 → .failure(f)
      成功 → .success((Dedupe.apply(r.result), r.trimmed を各 "reduce: " + note に))
   depth >= Analyzer.reduceMaxDepth → .failure(StageFailure(.llmInvalidJSON, "多段 Reduce が上限 3 段に達しました"))
   folded = []; notes = []
   for bundle in ReduceBundling.bundles(items, schema: partialSchema, limit: config.maxCharsPerRequest):
      r = await call.run(kind: .map, schema: partialSchema, body: ReduceBundling.asJSON(bundle, schema: partialSchema))   // 中間段の出力は中間形
      失敗 → return .failure(f)
      notes += r.trimmed を各 "reduce\(depth): " + note に                               // 例 "reduce1: key_points: 25 -> 20"
      folded.append(r.result)
   deeper = await reduce(folded, depth: depth + 1)
   deeper の成功 → .success((result, notes + deeperNotes))、失敗 → そのまま
```
- 失敗の文言の「3」は `Analyzer.reduceMaxDepth` から作る（`"多段 Reduce が上限 \(reduceMaxDepth) 段に達しました"`）
- **原文 transcript を Reduce に再送しない**（Reduce の user は中間結果の JSON 配列だけ）
- **時刻は LLM に渡さない**（チャンクの本文に時刻を入れない）
- 例外を投げない。`LLM_UNAVAILABLE`（接続失敗）・`LLM_INVALID_JSON`（修復しても直らない・段数の上限）・`SESSION_MERGE_FAILED`（チャンク 0 個）のどれかを返す。
  `LLM_FAILED` は書き込みの失敗なので T-22 が作る
- 経過時間は測らない（呼び手が `AppClock` で測り `llm_completed … elapsed_s=` に出す）

## 5. テスト

すべて `import Testing`、`@testable import VDLLM`、`import VDCore`、`import TestSupport`。

時刻の準備: `zone = ZonedTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)`（テストでは `!` を使ってよい）、`base = zone.parseISO("2026-08-29T07:12:04+09:00")!`、
`seg(text, s, dur = 5) = AbsoluteSegment(at: base.adding(seconds: s), endAt: base.adding(seconds: s + dur), text: text)`。期待の時刻は `zone.iso(_:)` の文字列で書く。

### 5.0 golden（T-25）

T-25 のグループを使う（名前と中身は T-25 §4.4・§4.5・§4.9 が正）。ケース名を列挙せず `try Golden.cases("<group>")` をパラメータ化テストの引数に渡し、グループごとに「ケースが在る」テストを 1 本置く（T-25 §4.11、TEST-28）。
`config = try GoldenConfig.make(item)`（T-09）、`partialSchema = AnalysisSchema(config: AnalysisConfigView(sections: config.llm.analysis.sections), kind: .partial)`、`finalSchema` は `.final`。
`PyJSONValue` を `GoldenJSON` にするのは `GoldenJSON(any: value.foundationObject)`。

| グループ（ケース数） | 期待値 | 実際の値 | テスト関数 / 表示名（スイート） |
|---|---|---|---|
| `llm_chunks`（9） | `.json` `[{texts, startMs, endMs, text}]` | `zone = ZonedTime(timeZone: TimeZone(identifier: item.string("timeZone"))!)`、`base = zone.parseISO(item.string("base"))!`、`segments` の各 `{atMs, endMs, text}` を `AbsoluteSegment(at: base.adding(milliseconds: atMs), endAt: base.adding(milliseconds: endMs), text:)` にし、`Chunker.chunk(_, maxChars: config.llm.maxCharsPerRequest, maxSeconds: config.llm.maxSecondsPerRequest, overlapChars: config.llm.chunkOverlapChars)` の各チャンクを `{"texts": segments の text, "startMs": startAt − base, "endMs": endAt − base, "text": text}` にした配列 | `goldenChunks(item:)` / 「golden llm_chunks」（ChunkerTests） |
| `llm_dedupe`（4） | `.json` | `kind` が `key` → `inputs` の各要素の `Dedupe.key`、`values` → `Dedupe.strings(inputs)`、`result` → `AnalysisValidator.validate(item.orderedObject("payload"), schema: finalSchema)` の成功の結果に `Dedupe.apply` をかけた `pyJSON(schema: finalSchema)` | `goldenDedupe(item:)` / 「golden llm_dedupe」（DedupeTests） |
| `llm_as_json`（3） | `.out` | `item.orderedList("partials")` の各要素を `partialSchema` で `validate` した結果（すべて成功すること）の `ReduceBundling.asJSON(_, schema: partialSchema)` | `goldenAsJSON(item:)` / 「golden llm_as_json」（ReduceBundlingTests） |
| `llm_bundles`（3） | `.json`（束ごとの partial の添字の配列） | 上と同じ partials を `ReduceBundling.bundles(_, schema: partialSchema, limit: item.int("limit"))` で束ね、束の大きさから入力の添字（0 から連番）の配列の配列にしたもの | `goldenBundles(item:)` / 「golden llm_bundles」（ReduceBundlingTests） |

- `GoldenCase.orderedList(_ key: String) throws -> [[(String, PyJSONValue)]]`（`Tests/VDLLMTests/GoldenCase+List.swift`。internal。T-45 の `GoldenCase.orderedObject` と同じ読み方（入力を `PyJSON.decode` で読み直す）で、値が `.array` で各要素が `.object` のもの。違えば `GoldenError.typeMismatch(group:name:key:expected: "array of object")`）。
  （実装で修正: T-19 は自前の `GoldenPayload` を作らず T-45 の `orderedObject` を使った（T-19 §8 の 7）ので、`GoldenPayload` は存在しない）

### 5.1 `ChunkerTests.swift`（`@Suite("Chunker") struct ChunkerTests`）

`chunkCases(case:)` / 「チャンクの境界が voicedock と一致」（パラメータ化。期待は voicedock@d3d595e の `split_chunks` の実測）:

| # | 設定（maxChars / maxSeconds / overlap） | segment（text@秒、長さ 5 秒。指定があればその長さ） | 期待（各チャンクの text の列・startAt・endAt） |
|---|---|---|---|
| V | 10 / 3600 / 4 | aaa@0, bbb@10, ccc@20, dd@30, eeeee@40, ff@5000 | [aaa,bbb,ccc] 07:12:04–07:12:29 ／ [ccc,dd,eeeee] 07:12:24–07:12:49 ／ [ff] 08:35:24–08:35:29 |
| A | 10 / 3600 / 4 | aa@0, bb@10, ccccccccc@20 | [aa,bb] 07:12:04–07:12:19 ／ [bb,ccccccccc] 07:12:14–07:12:29（重なりが全部になるので先頭を落とした） |
| B | 20000 / 3600 / 500 | a@0, b@100, c@4000, d@4100 | [a,b] 07:12:04–07:13:49 ／ [c,d] 08:18:44–08:20:29（時間で割れ、重ねない） |
| C | 8 / 3600 / 0 | aaaa@0, bbbb@10, cccc@20 | [aaaa,bbbb] 07:12:04–07:12:19 ／ [cccc] 07:12:24–07:12:29 |
| D | 8 / 3600 / 3 | aaaa@0, bb@10, cccccc@20 | [aaaa,bb] 07:12:04–07:12:19 ／ [bb,cccccc] 07:12:14–07:12:29 |
| E | 20000 / 3600 / 500 | あいう@0, えお@10 | [あいう,えお] 07:12:04–07:12:19（単一チャンク） |
| F1 | 10 / 3600 / 0 | aaaaa@0, bbbbb@3595 | [aaaaa,bbbbb] 07:12:04–08:12:04（ちょうど 3600 秒と 10 文字は超えない） |
| F2 | 10 / 3600 / 0 | aaaaa@0, bbbbb@3595（長さ 6） | [aaaaa] 07:12:04–07:12:09 ／ [bbbbb] 08:11:59–08:12:05 |
| G | 10 / 3600 / 4 | x×15@0, y@10 | [x×15] 07:12:04–07:12:09 ／ [y] 07:12:14–07:12:19（1 つで超える segment は単独） |
| H | 3 / 3600 / 1 | が（U+304C の 1 スカラー）@0, 👍🏽（2 スカラー）@10, e+U+0301（2 スカラー）@20 | [が,👍🏽] 07:12:04–07:12:19 ／ [👍🏽,é] 07:12:14–07:12:29（スカラーで数える） |
| I | 100 / 3600 / 0 | aa@0（長さ 100）, bb@10 | [aa,bb] 07:12:04–07:13:44（endAt は最大値） |
| J | 4 / 3600 / 1 | aa@0, bb@10, bb@10（まったく同じ値の segment） | [aa,bb] 07:12:04–07:12:19 だけ（重なりだけの末尾は捨てる） |
| K | 10 / 3600 / 4 | aaaa@0, bbbb@10, cccccccc@4000 | [aaaa,bbbb] 07:12:04–07:12:19 ／ [cccccccc] 08:18:44–08:18:49（両方超えたら重ねない） |

各チャンクの `text` は text を `"\n"` でつないだもの（例 V の 1 つ目は `"aaa\nbbb\nccc"`）。

| 関数名 / 表示名 | 期待 |
|---|---|
| `emptyInputHasNoChunks` / 「空の入力は 0 チャンク」 | `[]` |
| `everySegmentAppears` / 「すべての segment がどこかに現れる」 | 30 本の segment（長さの違う文字列）を 200 / 3600 / 50 で分けたとき、全部がどれかのチャンクに在る |
| `chunksAreInTimeOrder` / 「チャンクは時刻順」 | 上と同じ入力で startAt が単調非減少 |
| `textCarriesNoTimestamps` / 「本文に時刻を入れない」 | 各チャンクの text が segments の text を `"\n"` でつないだものと等しい |
| `goldenChunks(item:)` / 「golden llm_chunks」 | §5.0 の表（`GoldenAssert.matchesJSON`） |
| `goldenChunksHasCases` / 「golden llm_chunks のケースが在る」 | 空でない |

### 5.2 `DedupeTests.swift`

| 関数名 / 表示名 | 期待 |
|---|---|
| `keyMeasured(input:expected:)` / 「正規形が voicedock と一致」 | §4.2 の実測の全例 |
| `keepsTheFirstOccurrence` / 「最初に現れたものを残す」 | `strings(["a","b","a","c","b"]) == ["a","b","c"]` |
| `normalizesBeforeComparing` / 「NFKC・strip・casefold で比べる」 | `(" VoiceDock ","VoiceDock")`・`("ＶｏｉｃｅＤｏｃｋ","VoiceDock")`・`("VOICEDOCK","voicedock")`・`("ﾃｽﾄ","テスト")` の各組で `strings([左, 右]) == [左]` |
| `doesNotMatchLoosely` / 「曖昧一致しない」 | `["削除条件を整理した","削除条件を整理する"]` と `["VoiceDock","VoiceDock の設計"]` はそのまま |
| `tasksAreDedupedByText` / 「tasks は text で比べる」 | `[確認する(nil), " 確認する "(2026-09-01), 別(nil)]` → `[確認する(nil), 別(nil)]` |
| `applyMatchesVoicedock` / 「結果全体への適用が voicedock と一致」 | 入力 `{"title":"t","summary":"s","key_points":["A","a"," A ","Ａ"],"tasks":[…上の 3 件…],"decisions":["x"],"ideas":[],"tags":["VoiceDock","voicedock","Straße","STRASSE","ΣΑΣ","σας"]}` → key_points `["A"]`、tasks 2 件、decisions `["x"]`、ideas `[]`、tags `["VoiceDock","Straße","ΣΑΣ"]`、title と summary は同じ |
| `nilSectionsStayNil` / 「無効な節は nil のまま」 | ideas が nil の結果に apply しても nil |
| `goldenDedupe(item:)` / 「golden llm_dedupe」 | §5.0 の表 |
| `goldenDedupeHasCases` / 「golden llm_dedupe のケースが在る」 | 空でない |

### 5.3 `ReduceBundlingTests.swift`

| 関数名 / 表示名 | 期待 |
|---|---|
| `asJSONMatchesVoicedock` / 「Reduce の入力の JSON が voicedock と一致」 | §4.3 の 1 つ目の実測（Swift の raw 文字列 `#"…"#` で書く） |
| `asJSONWithDisabledSection` / 「無効な節は出さない」 | §4.3 の 2 つ目 |
| `bundlesMeasured(limit:expected:)` / 「束ね方が voicedock と一致」 | §4.3 の 4 例、asJSON の長さ 71・141・211 |
| `bundlesKeepOrder` / 「並べ替えない」 | 束をつなぎ直すと入力と同じ順 |
| `oversizedItemIsItsOwnBundle` / 「1 個で超える要素は単独」 | limit 10 で 3 個 → 3 束 |
| `goldenAsJSON(item:)` / 「golden llm_as_json」 | §5.0 の表（`GoldenAssert.matches`） |
| `goldenBundles(item:)` / 「golden llm_bundles」 | §5.0 の表 |
| `goldenBundlingGroupsHaveCases` / 「golden llm_as_json・llm_bundles のケースが在る」 | 空でない |

### 5.4 `AnalyzerTests.swift`（`FakeChatTransport(handler:)` を使う。`.serialized` は不要）

準備: 既定の `LLMConfig`（指定があればその値だけ変える）、`prompts` は `Resources/prompts` から読む。handler は `call.system` を `prompts.analyze(最終形,"")` / `prompts.map(中間形,"")` / `prompts.reduce(最終形,"")` / `prompts.repair(…)` と比べて種類を判定し、テストごとの応答を返す。
`PARTIAL(s, kp = [])` は `{"summary": s, "key_points": kp}` の JSON 文字列、`FINAL(…)` は `{"title": "題", "summary": …}` を含む JSON 文字列。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `emptyTranscriptIsMergeFailure` / 「チャンク 0 個は SESSION_MERGE_FAILED」 | segment 0 本 | `.failure(StageFailure(.sessionMergeFailed, "チャンクが 0 個です（統合結果が空）"))`、呼び出し 0 回 |
| `singleChunkUsesTheAnalyzePrompt` / 「1 チャンクなら analyze 1 回」 | segment 2 本（短い） | 呼び出し 1 回、system == analyze、user == chunk.text、partials `[]`、chunks 1 個 |
| `singleChunkIsNotDeduped` / 「単一パスは重複除去しない」 | analyze の応答の key_points `["A","a"]` | 結果の key_points `["A","a"]` |
| `singleChunkTrimmedHasNoPrefix` / 「単一パスの切り詰めの記録は前置き無し」 | 応答の tags 20 個 | trimmed `["tags: 20 -> 15"]` |
| `multipleChunksRunMapThenReduce` / 「2 チャンク以上は Map → Reduce」 | 「朝の話」@0 と「夜の話」@5000（時間で 2 チャンク）、Map の応答 `PARTIAL("朝")`・`PARTIAL("夜")`、Reduce の応答は FINAL | 呼び出し 3 回（map・map・reduce の順）、map の user はチャンクの text、reduce の user == `[{"summary":"朝","key_points":[],"tasks":[],"decisions":[],"ideas":[]},{"summary":"夜","key_points":[],"tasks":[],"decisions":[],"ideas":[]}]`、partials は 2 個で順も同じ |
| `reduceNeverResendsTheTranscript` / 「Reduce に原文を再送しない」 | 上と同じ | reduce の user に「朝の話」「夜の話」を含まない |
| `reduceResultIsDeduped` / 「Reduce の結果は重複除去する」 | Reduce の応答が §5.2 `applyMatchesVoicedock` の入力 | 結果が同じ期待値 |
| `trimmedNotesArePrefixed` / 「切り詰めの記録に段を前置する」 | 1 つ目の Map の応答の key_points 25 個、Reduce の応答の tags 20 個 | trimmed `["map: key_points: 25 -> 20", "reduce: tags: 20 -> 15"]` |
| `mapFailureStopsBeforeReduce` / 「Map が落ちたら Reduce へ進まない」 | 2 つ目の Map が `.failure(unavailable)` | その failure、呼び出し 2 回 |
| `mapUsesThePartialSchema` / 「Map の応答の title は未知キー」 | Map の応答が FINAL（title を持つ）→ 修復の応答で PARTIAL | 修復の要求が 1 回あり、errors に `- title: Extra inputs are not permitted` |
| `singlePartialSkipsBundling` / 「中間結果が 1 個なら束ねない」 | `reduce` を直接（`@testable`）: 1 個で本文が maxChars を超える | reduce の要求 1 回だけ |
| `oversizedReduceInputFoldsFirst` / 「大きすぎる Reduce の入力は先に束ねる」 | maxChars 150・overlap 0、100 スカラーの segment 3 本（3 チャンク）、Map の応答 `PARTIAL("s1")`〜`("s3")`（asJSON は 3 個で 211 > 150）、束の Map の応答 `PARTIAL("f1")`・`PARTIAL("f2")`、最後に FINAL | 呼び出し 6 回（map×3 → 束の map×2（束は `[s1,s2]`（141）と `[s3]`）→ reduce）、束の map の system は中間形の map、user は `[` で始まる中間結果の配列 |
| `foldTrimmedNotesArePrefixed` / 「束の Map の切り詰めは reduce1: を前置する」 | maxChars 400・overlap 0、300 スカラーの segment 3 本、Map の応答は summary 150 スカラーの PARTIAL（1 個で 219、2 個で 437 > 400 なので 3 束）、束の Map の応答は 1 つ目が `PARTIAL("f1", kp: ["k"]×25)`、2・3 つ目が `PARTIAL("f2")`・`("f3")`（切り詰め後の 3 個の asJSON は 290 ≤ 400）、最後に FINAL | 呼び出し 7 回、trimmed `["reduce1: key_points: 25 -> 20"]` |
| `depthLimitStopsRecursion` / 「段数の上限で LLM_INVALID_JSON」 | maxChars 50・overlap 0、40 スカラーの segment 3 本、すべての Map の応答が summary 60 スカラーの PARTIAL | `.failure(StageFailure(.llmInvalidJSON, "多段 Reduce が上限 3 段に達しました"))`、呼び出し 9 回（3 + 3 + 3）、reduce の要求 0 回 |
| `transportFailureInReduceIsReturned` / 「Reduce の接続失敗はそのまま」 | Reduce が `.failure(unavailable)` | その failure |
| `ceMaxCharsPerRequest` / 「CE llm.maxCharsPerRequest を小さくすると Map → Reduce になる」 | 5 スカラーの segment 2 本（時刻は近い）を、既定（20000）と `maxCharsPerRequest = 5` で | 既定は呼び出し 1 回（analyze）、5 では 2 チャンクになり、最初の 2 回がチャンクの map（user はそれぞれの segment の text）。（実装で修正: Reduce の入力（141 スカラー）も 5 を超えるので §4.4 どおり束の Map へ進み、「呼び出し 3 回」にはならない。総数は問わない） |
| `ceMaxSecondsPerRequest` / 「CE llm.maxSecondsPerRequest を小さくすると時間で割れる」 | 短い segment を 0 秒と 1800 秒に置き、既定（3600）と `maxSecondsPerRequest = 600` で | 既定は呼び出し 1 回、600 では 3 回（map・map・reduce） |
| `ceChunkOverlapChars` / 「CE llm.chunkOverlapChars が次のチャンクの重なりを決める」 | `maxCharsPerRequest = 10`、`aaaa@0`・`bb@10`・`cccccc@20`、`chunkOverlapChars = 3` と `0` | 3 では 2 つ目の map の user が `bb\ncccccc`、0 では `cccccc`（§5.1 の D・C と同じ境界） |

### 5.5 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`llm.maxCharsPerRequest`・`llm.maxSecondsPerRequest`・`llm.chunkOverlapChars` の 3 行を消す（CE テストは §5.4）。

## 6. 破壊による証明

| 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|
| `Chunker` で区切りの `"\n"` も文字数に数える | `chunkCases`（V・C） |
| 実時間で割れたときも重なりを持ち越す | `chunkCases`（B・K） |
| `overlap` で全部になったときに先頭を落とさない | `chunkCases`（A） |
| `onlyOverlap` の判定を消す | `chunkCases`（J） |
| 実時間の比較を `>=` にする | `chunkCases`（F1） |
| 文字数を `String.count` で数える | `chunkCases`（H） |
| `Dedupe.key` を `lowercased()` にする | `keyMeasured`（`Straße`）、`goldenDedupe`、`applyMatchesVoicedock`、`reduceResultIsDeduped` |
| （参考）`Dedupe.key` の strip を casefold の後にする | 落ちるテストは無い（実装で判明: Unicode の case folding は空白を作らず消さないので、strip と casefold は可換。等価な変更） |
| 単一パスでも重複除去する | `singleChunkIsNotDeduped` |
| Reduce の user に transcript を入れる | `reduceNeverResendsTheTranscript` |
| 束の Map を最終形のスキーマで検証する | `oversizedReduceInputFoldsFirst` |
| `reduceMaxDepth` の比較を `>` にする | `depthLimitStopsRecursion` |
| `asJSON` で `due: null` を省く | `asJSONMatchesVoicedock`、`goldenAsJSON` |

## 7. 受け入れ条件

- [ ] §3 のファイルがあり、`make lint` と `make test` が通る
- [ ] §5.1 の 13 例が voicedock の実測どおり
- [ ] golden（T-25 の `llm_chunks`・`llm_dedupe`・`llm_as_json`・`llm_bundles`）と一致
- [ ] Map の要求はチャンクの順に 1 つずつ（並行にしない）
- [ ] 破壊による証明の各項目で、表のテストが落ちることを確かめ、PR 本文に貼った

## 8. API 地図への変更提案

1. `AnalyzeOutcome` に `Equatable` を足す（テストで比べるため。要素はすべて Equatable）→ 00-api-map に反映済み（2026-09-18）
2. `Analyzer.reduceMaxDepth`（公開の定数）と `Dedupe.strings` / `Dedupe.tasks` を追記 → `reduceMaxDepth` は 00-api-map に反映済み（2026-09-18）。`Dedupe.strings` / `Dedupe.tasks` は地図に無い（追記が要る。モジュールの外で使わないなら internal でもよい）
3. `ChatTransport` / `ChatResult` / `FakeChatTransport` の作成は T-19（本チケットは使うだけ）→ 00-api-map §8・§15 に反映済み（2026-09-18）
4. `ReduceBundling` は internal（地図には載せない）
5. （実装で追記）テスト補助の `GoldenPayload` は T-19 が作らなかった（T-45 の `GoldenCase.orderedObject` を使う）。本チケットの配列版は `Tests/VDLLMTests/GoldenCase+List.swift` の internal な `GoldenCase.orderedList(_:)`（VDLLMTests の中だけで使うので 00-api-map §15 には載せない）
6. （実装で確認）`Dedupe.strings` / `Dedupe.tasks` は §4.2 どおり public で実装した。00-api-map §16（地図に行の無い公開 API の索引）の VDLLM の行に載っているので、地図の変更は要らない（上の 2 の「地図に無い」は §8 の行のこと）

## 9. SPEC の変更

なし

## 10. マージ後にやること

なし
