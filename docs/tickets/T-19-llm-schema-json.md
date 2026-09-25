# T-19 VDLLM: スキーマ・schema_block・プロンプト・JSON の取り出し・切り詰め・検証・修復

| 項目 | 値 |
|---|---|
| ID | T-19 |
| Phase | 5（LLM とモデル） |
| 前提 | T-09（`AppConfig` の `LLMConfig` / `AnalysisSections` / `SectionConfig`・TestSupport の `GoldenConfig`）、T-45（`PyText` / `PyJSON` / `PyJSON.decode`・`GoldenCase.orderedObject` の extension）、T-25（golden の入力と期待値・`Golden` / `GoldenAssert`。§5.0）。T-10（`TextLimit`）・T-08（`StageFailure`）は T-09 の前提に含まれる |
| 見積もり | ソース約 600 行・テスト約 650 行・プロンプト 4 ファイル |
| 後続 | T-20（Map-Reduce）、T-21（ループバック HTTP）、T-22（解析工程）、T-27（Daily の解析の読み込み）、T-32（DR-09） |

## 1. 目的

LLM に渡すスキーマと system プロンプトを設定の `sections` から生成し、LLM の応答から JSON を取り出して、上限への切り詰め・検証・修復までを行う部品を VDLLM に作る（PLAN §8.5「スキーマ」「プロンプト」「JSON の取り出し」）。
**出力はすべて voicedock@d3d595e と同じにする**（schema_block・プロンプトはバイト一致、検証エラーの行は pydantic v2 の文言と同じ）。修復プロンプトだけは本計画の差分（X-12: スキーマを渡す）。

## 2. 参照

- PLAN §8.5（スキーマ・プロンプト・JSON の取り出し・切り詰め・修復）、§5.7（`PyText` / `PyJSON`、文字数はスカラー数）、§9.2（CR-23・CR-24）、§9.4（PT-20: Swift の `Regex` を使わない）、付録 A.3（`LLM_INVALID_JSON` / `LLM_UNAVAILABLE`）、付録 D X-12
- 00-api-map §8（VDLLM）、§2.4（PyJSON）
- voicedock@d3d595e:
  - `src/voicedock/llm.py:38-57`（定数）、`:59-131`（`Task` / `enabled_sections` / `build_schema` / `_list_field`）、`:134-184`（`render_schema_block` / `_example`）、`:189-232`（`load_prompt` / `system_prompt` / `repair_prompt`）、
    `:238-307`（`strip_think` / `extract_json` / `_object` / `_fenced` / `_balanced`）、`:460-544`（`analyze` の修復ループ）、`:547-616`（`_validate` / `coerce_limits` / `_errors_of`）、`:633-664`（`probe`）
  - `prompts/analyze_ja.txt`・`map_ja.txt`・`reduce_ja.txt`・`repair_json.txt`
  - `tests/unit/test_llm_schema.py`、`test_json_extract.py`、`test_llm_client.py:224-292, 320-350, 400-470`

## 3. 作るもの

ソース（`Sources/VDLLM/`。import は Foundation・Darwin・VDContract・VDCore だけ。PT-07）:
- `AnalysisSchema.swift`（`AnalysisSchema`・`SchemaField`・`AnalysisConfigView`・`AnalysisLimits`）
- `AnalysisResult.swift`（`AnalysisResult`・`AnalysisTask`）
- `SchemaBlock.swift`
- `Prompts.swift`（`Prompts`・`PromptKind`・`PromptsError`・`LLMProbe`・internal の `PromptText`）
- `JSONExtractor.swift`
- `AnalysisValidator.swift`（`AnalysisValidator`・`ValidationErrors`・`LLMValidationMessages`）
- `ChatTransport.swift`（`ChatTransport`・`ChatResult`）
- `AnalysisCall.swift`（`AnalysisCall`。1 回の要求 → 取り出し → 切り詰め → 検証 → 修復。00-api-map §8 で公開）

資源（`Resources/prompts/`。§4.5）:
- `analyze_ja.txt`、`map_ja.txt`、`reduce_ja.txt`（voicedock からバイト単位で複製）、`repair_json_ja.txt`（本計画の差分）

テストの部品（`Tests/TestSupport/`）:
- `FakeChatTransport.swift`

テスト（`Tests/VDLLMTests/`）:
- `AnalysisSchemaTests.swift`、`SchemaBlockTests.swift`、`PromptsTests.swift`、`JSONExtractorTests.swift`、`AnalysisValidatorTests.swift`、`AnalysisResultTests.swift`、`AnalysisCallTests.swift`

`Tests/PolicyTests/ConfigEffectPending.swift`（変更。§5.9）: 自分のキーの行を消す。

## 4. 仕様

各ファイルの先頭 1 行のコメントは括弧内の文を逐語で書く。

### 4.1 `AnalysisSchema.swift`（「// LLM の出力スキーマ。設定の sections から生成する（PLAN §8.5）。」）

```swift
/// 上限の定数（voicedock llm.py:42-44）。
public enum AnalysisLimits {
    public static let titleMaxScalars = 120
    public static let summaryMaxScalars = 4000
    public static let taskTextMaxScalars = 500
    /// 配列になる節の固定順（config の order ではない。voicedock LIST_SECTIONS）。
    public static let listSections: [String] = ["key_points", "tasks", "decisions", "ideas", "tags"]
}

/// スキーマの生成に使う設定の部分。
public struct AnalysisConfigView: Equatable, Sendable {
    public let sections: AnalysisSections
    public init(sections: AnalysisSections)
}

public struct SchemaField: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case text(maxScalars: Int)            // title / summary。最小 1 スカラー
        case stringList(maxItems: Int?)       // key_points / decisions / ideas / tags
        case taskList(maxItems: Int?)         // tasks
    }
    public let name: String                   // JSON のキー（snake_case）
    public let shape: Shape
    public let required: Bool                 // title と summary だけ true
    /// 切り詰めの上限（text は maxScalars、配列は maxItems。nil = 切らない）。
    public var trimLimit: Int? { get }
}

public struct AnalysisSchema: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case final, partial }
    public let kind: Kind
    public let fields: [SchemaField]          // 並び = analysis.json のキー順 = schema_block の行順 = 切り詰め・検証エラーの順
    public init(config: AnalysisConfigView, kind: Kind)
    public func field(named name: String) -> SchemaField?
    public var fieldNames: [String] { get }
}
```

`init(config:kind:)` の手順（voicedock `build_schema`）:
1. `s = config.sections`、`fields = []`
2. `s.summary.enabled` かつ `kind == .final` なら `SchemaField(name: "title", shape: .text(maxScalars: 120), required: true)` を足す
3. `s.summary.enabled` なら `SchemaField(name: "summary", shape: .text(maxScalars: 4000), required: true)` を足す
4. `AnalysisLimits.listSections` の順に、名前から節を引く（`key_points`→`s.keyPoints`、`tasks`→`s.tasks`、`decisions`→`s.decisions`、`ideas`→`s.ideas`、`tags`→`s.tags`。`switch` で書き、`section(named:)` の Optional を使わない）:
   - `enabled == false` なら飛ばす
   - `kind == .partial` かつ名前が `tags` なら飛ばす（中間形は `title` と `tags` を持たない）
   - `tasks` は `.taskList(maxItems: sec.maxItems)`、それ以外は `.stringList(maxItems: sec.maxItems)`、`required: false`
5. `timeline` は LLM の出力項目ではないので**どの場合も入れない**（voicedock `NOT_A_SECTION`）

- `trimLimit`: `.text(max)` → `max`、`.stringList(m)` / `.taskList(m)` → `m`
- `maxItems == nil` の節に上限を作らない（voicedock `_list_field`）

### 4.2 `AnalysisResult.swift`（「// 検証を通った解析結果（PLAN §8.5）。nil は無効な節。」）

```swift
public struct AnalysisTask: Equatable, Sendable {
    public let text: String
    public let due: String?               // 無ければ nil（JSON では null）
    public init(text: String, due: String?)
}

public struct AnalysisResult: Equatable, Sendable {
    public let title: String?             // 中間形・summary 無効なら nil
    public let summary: String?
    public let keyPoints: [String]?       // 節が無効（スキーマに無い）なら nil。有効で欠落なら []
    public let tasks: [AnalysisTask]?
    public let decisions: [String]?
    public let ideas: [String]?
    public let tags: [String]?
    public init(title: String?, summary: String?, keyPoints: [String]?, tasks: [AnalysisTask]?,
                decisions: [String]?, ideas: [String]?, tags: [String]?)
    /// schema.fields の順にキーを並べた PyJSON のオブジェクト（voicedock の model_dump と同じ形）。
    public func pyJSON(schema: AnalysisSchema) -> PyJSONValue
}
```

`pyJSON(schema:)`: `schema.fields` の順に `(name, 値)` を並べた `.object`。値:
- `title` / `summary` → `.string(値)`（nil なら `.null`。同じスキーマで検証した結果なら nil にならない）
- `key_points` / `decisions` / `ideas` / `tags` → `.array(各要素を .string)`（nil なら `.array([])`）
- `tasks` → `.array(各要素を .object([("text", .string(text)), ("due", due.map { .string($0) } ?? .null)]))`（**due は nil でも必ず出す**）
- スキーマに無い節は出さない

これを `PyJSON.fileData` に通したものが analysis.json（T-22）、`PyJSON.dumpsCompact` に通したものが Reduce の入力（T-20）になる。

### 4.3 `SchemaBlock.swift`（「// プロンプトへ差し込む {schema_block}（voicedock llm.py:134-184 と同一）。」）

```swift
public enum SchemaBlock {
    public static func render(_ schema: AnalysisSchema) -> String
}
```

手順:
1. 各フィールドを `"  \"<name>\": <例>"` にする。例:
   - `title` → `"内容を表す簡潔な日本語（<max> 文字以内）"`（全角括弧 U+FF08 / U+FF09。`<max>` の前に空白なし、後に半角空白 1 つ。既定で `（120 文字以内）`）
   - `summary` → `"全体の要約（<max> 文字以内）"`（既定で `（4000 文字以内）`）
   - `tasks` → `[{"text": "やること", "due": "2026-08-30 または null"}]`
   - それ以外（配列の節）→ `["..."]`
   - **件数の上限（maxItems）はどこにも出さない**（LLM-01。見せると数を埋めに来る）
2. `lines = ["{", 手順 1 の行を ",\n" でつないだもの, "}"]` を `"\n"` でつなぐ（末尾改行なし）
3. フィールドが 0 個なら `"{\n\n}"`（CV-18 で起きないが、落とさない）

既定の設定での実出力（voicedock 実測。golden `Tests/Golden/expected/llm_schema_block/final_default.out` と一致すること）:

```text
{
  "title": "内容を表す簡潔な日本語（120 文字以内）",
  "summary": "全体の要約（4000 文字以内）",
  "key_points": ["..."],
  "tasks": [{"text": "やること", "due": "2026-08-30 または null"}],
  "decisions": ["..."],
  "ideas": ["..."],
  "tags": ["..."]
}
```

中間形（`llm_schema_block/partial_default.out`）:

```text
{
  "summary": "全体の要約（4000 文字以内）",
  "key_points": ["..."],
  "tasks": [{"text": "やること", "due": "2026-08-30 または null"}],
  "decisions": ["..."],
  "ideas": ["..."]
}
```

`tags` と `ideas` を無効にした最終形（`llm_schema_block/final_tags_ideas_disabled.out`）は、上の最終形から `"ideas"` と `"tags"` の行を除き、`"decisions": ["..."]` で終わるもの。

### 4.4 `Prompts.swift`（「// system プロンプトの読み込みと差し込み（PLAN §8.5「プロンプト」）。format 相当を使わず文字列置換だけで行う。」）

```swift
public enum PromptKind: Sendable, Equatable { case analyze, map, reduce }

public enum PromptsError: Error, Equatable, Sendable {
    case unreadable(String)               // ファイル名（例 "analyze_ja.txt"）
}

/// DR-09 の疎通確認（voicedock llm.py:651）。
public enum LLMProbe {
    public static let system = "{\"ok\": true} と返してください。"
    public static let user = "ping"
}

public struct Prompts: Equatable, Sendable {
    public static let fileNames = (analyze: "analyze_ja.txt", map: "map_ja.txt", reduce: "reduce_ja.txt", repair: "repair_json_ja.txt")
    /// directory 直下の 4 ファイルを UTF-8 で読む。どれか読めない（無い・UTF-8 でない）なら PromptsError.unreadable(そのファイル名)。
    public static func load(directory: URL) throws(PromptsError) -> Prompts
    public init(analyze: String, map: String, reduce: String, repair: String)   // テンプレートの本文（テスト用）

    public func analyze(schema: AnalysisSchema, custom: String) -> String
    public func map(schema: AnalysisSchema, custom: String) -> String
    public func reduce(schema: AnalysisSchema, custom: String) -> String
    public func system(_ kind: PromptKind, schema: AnalysisSchema, custom: String) -> String   // 上の 3 つへ振り分ける
    public func repair(schema: AnalysisSchema, errors: String, previousOutput: String) -> String
}
```

- `analyze` / `map` / `reduce`: テンプレートに `PromptText.replaceAll(t, "{schema_block}", SchemaBlock.render(schema))` → その結果に `PromptText.replaceAll(_, "{custom_instructions}", custom)` の**この順**で 1 回ずつ。
  スキーマは呼び手が渡す（Map は中間形、analyze / reduce は最終形。`AnalysisCall` が選ぶ。§4.8）
- `repair`: `{schema_block}` → `{errors}` → `{previous_output}` の**この順**（信用できない入力を最後にする。PLAN §8.5）
- `PromptText.replaceAll(_ text: String, _ placeholder: String, _ value: String) -> String`（internal）: `text.unicodeScalars` の上で、左から重ならないように `placeholder` の全出現を `value` に置き換える
  （Python の `str.replace` と同じ。Foundation の `replacingOccurrences` は正準等価で比べるので使わない。置き換えた `value` の中はもう一度走査しない）
- `load` の読み方: `Data(contentsOf:)` → `String(data:encoding: .utf8)`。末尾の改行を含めて**そのまま**持つ（trim しない）

### 4.5 プロンプトの資源（`Resources/prompts/`）

| ファイル | 作り方 | バイト数 | sha256 |
|---|---|---|---|
| `analyze_ja.txt` | `git -C /Users/terada/Projects/voicedock show d3d595e:prompts/analyze_ja.txt > Resources/prompts/analyze_ja.txt` | 924 | `6309c0c7b5dd51913f5f270162b278a094e7c678532b14851f82ac5a038c0a29` |
| `map_ja.txt` | 同じく `prompts/map_ja.txt` | 1027 | `ff99c78e2c88e5bb401b4461469c45ac51ee2af35d0382327afbb84d7e4d42e2` |
| `reduce_ja.txt` | 同じく `prompts/reduce_ja.txt` | 664 | `857e5b8b41608c731398c6bbb3c95f29dfa9522f643164773edae197e809e8a2` |
| `repair_json_ja.txt` | `(git -C … show d3d595e:prompts/repair_json.txt; printf '\n{schema_block}\n') > Resources/prompts/repair_json_ja.txt` | 320 | `c2c01a1c4a064cef3e9cb4a8237cd639355a95d9b34c9055b75d8db74d12c52d` |

- 複製した後に `shasum -a 256 Resources/prompts/*.txt` の出力を PR 本文に貼る。エディタで開いて保存しない（改行・末尾・BOM が変わる）
- `repair_json_ja.txt` の全文（LF。最終行 `{schema_block}` の後に改行 1 つ）:

```text
前回の出力は JSON として不正でした。

エラー内容:
{errors}

前回の出力:
{previous_output}

同じ内容を、指定されたスキーマに厳密に従う有効な JSON のみで出力し直してください。
説明文やコードフェンスを付けないでください。

{schema_block}
```

- 3 つの複製ファイルはどれも `{custom_instructions}` が独立した行、`{schema_block}` が最終行（その後に改行 1 つ）。`custom` が空なら空行が 2 つ続く（voicedock どおり）

### 4.6 `JSONExtractor.swift`（「// LLM の応答から JSON オブジェクトを取り出す（voicedock llm.py:238-307 と同じ 4 段）。」）

```swift
public enum JSONExtractor {
    public static func stripThink(_ s: String) -> String
    /// 取り出せなければ nil。例外を投げない。戻り値のキーの並びは入力の順（重複キーは後勝ちで最初の位置）。
    public static func extractObject(_ text: String) -> [(String, PyJSONValue)]?
}
```

すべて `unicodeScalars` の上で処理する（Python の文字 = コードポイント）。Swift の `Regex` も `NSRegularExpression` も使わない（Python の `\s` と ICU の `\s` の違いを持ち込まないため。PT-20）。

**`stripThink`**（voicedock `THINK_RE = <think>.*?</think>`（DOTALL）の `sub("")` → `partition("<think>")`）:
1. `pos = 0`。次を繰り返す: `pos` 以降で最初の `<think>` を探す。無ければ終わり。在ればその後で最初の `</think>` を探す。無ければ終わり。在れば `<think>` の先頭から `</think>` の末尾までを取り除き、`pos` を取り除いた位置にして続ける
2. 結果に `<think>` が残っていれば、その**最初の**出現より前だけを返す。無ければ全体を返す
- 例: `"前<think>中</think>後"` → `"前後"`、`"<think>A</think>前置き<think>B</think>X"` → `"前置きX"`、`"<think>{\"a\":1}"` → `""`、`"<think>A<think>B</think>C"` → `"C"`

**`extractObject`**:
1. `cleaned = PyText.strip(stripThink(text))`
2. 候補を順に並べる: `[cleaned] + fenced(cleaned) + balanced(cleaned)`
3. 各候補を `PyJSON.decode`（T-45。§4.9）し、`.object(entries)` なら `entries` を返す。配列・数値・文字列・null・失敗なら次の候補へ
4. どれも駄目なら nil

**`fenced(s)`**（`re.findall(r"```(?:json)?\s*\n(.*?)\n?```", s, re.S)` と同じ結果を手で出す）:
```text
結果 = []; i = 0
while i < n:
  s[i..] が "```" で始まらなければ i += 1; continue
  m = matchAt(i)            // 下記。成功なら (group, end)
  m が nil なら i += 1; continue
  結果に group を足す; i = end
matchAt(i):
  for 前置き in ["json", ""]:                           // (?:json)? は先に「在る」を試す
     j = i + 3; 前置きが "json" なら s[j..] が "json" で始まらなければこの前置きは不成立、始まれば j += 4
     r = j; while r < n かつ PyText.isSpace(s[r]): r += 1   // 空白の連続 [j, r)
     k = [j, r) の中で最後の "\n" の位置。無ければこの前置きは不成立
     c = k + 1
     e = c から順に: s[e..] が "\n```" で始まれば (group = s[c..<e], end = e + 4) を返す
                     s[e..] が "```" で始まれば (group = s[c..<e], end = e + 3) を返す
     どの e でも見つからなければ nil を返す（前置き "" を試しても同じ結果なので終わる）
  nil
```
（`\n```` を `` ``` `` より先に調べるのは `\n?` が貪欲なため。`c` 以降に "```" が無ければ一致しない）

**`balanced(s)`**（1 個か 0 個）:
```text
start = 最初の "{" の位置。無ければ []
depth = 0; inString = false; escaped = false
for idx in start..<n:
  ch = s[idx]
  escaped なら escaped = false; continue
  ch == "\\" かつ inString なら escaped = true; continue
  ch == "\"" なら inString.toggle(); continue
  inString なら continue
  ch == "{" なら depth += 1
  ch == "}" なら depth -= 1; depth == 0 なら [s[start...idx]] を返す
[]
```
- 一重引用符は文字列として扱わない（`{'single': 'quotes'}` は候補になるが JSON として読めず nil）
- 例（voicedock 実測）: `'<think>x</think> {"a":1}'`→`[("a",1)]`、`'pre {"a":"}"} post'`→`[("a","}")]`、`'[{"a":1}]'`→`[("a",1)]`（配列は捨てられ balanced が中の最初のオブジェクトを拾う）、
  `'<think>{"a":1}'`→nil、`"```\nnot json\n```\n{\"b\":2}"`→`[("b",2)]`、`"```json\n[1]\n```\n```json\n{\"c\":3}\n```"`→`[("c",3)]`、`'{"a": NaN}'`→`[("a", .double(nan))]`、`'{"a":1,"a":2}'`→`[("a",2)]`

### 4.7 `AnalysisValidator.swift`（「// 上限への切り詰めと、pydantic v2 と同じ文言の検証（PLAN §8.5、LLM-02・LLM-09）。」）

```swift
public struct ValidationErrors: Error, Equatable, Sendable {
    public let lines: [String]            // "- <loc>: <msg>"
    public var rendered: String { get }   // lines を "\n" でつないだもの
}

/// pydantic v2 の文言（voicedock の検証エラーと同じ。変えない）。
public enum LLMValidationMessages {
    public static let fieldRequired = "Field required"
    public static let extraForbidden = "Extra inputs are not permitted"
    public static let notString = "Input should be a valid string"
    public static let notList = "Input should be a valid list"
    public static let notTask = "Input should be a valid dictionary or instance of Task"
    public static func tooShort(_ min: Int) -> String      // "String should have at least <min> character"（min != 1 なら "characters"）
    public static func tooLong(_ max: Int) -> String       // "String should have at most <max> characters"（max == 1 なら "character"）
    public static func tooManyItems(_ max: Int, _ actual: Int) -> String   // "List should have at most <max> items after validation, not <actual>"（max == 1 なら "item"）
    /// JSON を取り出せなかったときの失敗文（行形式ではない）。
    public static let notExtracted = "応答から JSON を抽出できませんでした"
}

public enum AnalysisValidator {
    public static func trim(_ obj: [(String, PyJSONValue)], schema: AnalysisSchema) -> (obj: [(String, PyJSONValue)], trimmed: [String])
    public static func validate(_ obj: [(String, PyJSONValue)], schema: AnalysisSchema) -> Result<AnalysisResult, ValidationErrors>
}
```

**`trim`**（voicedock `coerce_limits`。検証の**前**に行う。LLM-02）:
1. `schema.fields` の順に、`trimLimit` が nil でなく、`obj` にその名前のキーが在るフィールドだけを見る
2. 値が `.string(s)` で `TextLimit.scalarCount(s) > limit` → `.string(TextLimit.prefix(s, scalars: limit))` に置き換え、`"<name>: <元のスカラー数> -> <limit>"` を記録
3. 値が `.array(a)` で `a.count > limit` → `.array(a の先頭 limit 個)` に置き換え、`"<name>: <a.count> -> <limit>"` を記録
4. それ以外の型・上限以下は触らない（**フィールドの形に関係なく、文字列なら文字数で・配列なら個数で切る**。`key_points` に文字列が来たら文字列として切り、検証で「valid list」になる。voicedock どおり）
5. 入れ子（`tasks` の各 `text`）は切らない。最小長は扱わない（足りないものは作れない）
6. キーの並びは変えない。戻り値の `trimmed` はこの順

**`validate`**（pydantic v2 の `model_validate` と同じ判定・同じ順・同じ文言）:
```text
errors = []; values = [:]
names = schema.fieldNames の集合
for field in schema.fields:
  v = obj の field.name の値（無ければ nil）
  v が nil:
     field.required なら errors += "- <name>: Field required"
     そうでなければ既定値（配列は []）
     continue
  switch field.shape:
   .text(max):
     .string(s) でなければ "- <name>: Input should be a valid string"
     n = scalarCount(s); n < 1 → "- <name>: " + tooShort(1)；n > max → "- <name>: " + tooLong(max)（trim の後なので通常は起きない）
   .stringList(maxItems):
     .array(items) でなければ "- <name>: Input should be a valid list"
     各 (i, item): .string でなければ "- <name>.<i>: Input should be a valid string"
     要素の誤りが無く maxItems があり items.count > maxItems → "- <name>: " + tooManyItems(maxItems, items.count)（trim の後なので通常は起きない）
   .taskList(maxItems):
     .array(items) でなければ "- <name>: Input should be a valid list"
     各 (i, item):
       .object(entries) でなければ "- <name>.<i>: Input should be a valid dictionary or instance of Task"; continue
       text: 無ければ "- <name>.<i>.text: Field required"、.string でなければ "…text: Input should be a valid string"、
             スカラー数 < 1 → "…text: " + tooShort(1)、> 500 → "…text: " + tooLong(500)
       due:  無い・.null → nil、.string(d) → d、それ以外 → "- <name>.<i>.due: Input should be a valid string"
       entries のうち "text" と "due" 以外のキーを入力の順に → "- <name>.<i>.<key>: Extra inputs are not permitted"
     要素の誤りが無く件数超過なら tooManyItems（同上）
obj のうち names に無いキーを**入力の順に** → "- <key>: Extra inputs are not permitted"
errors が空なら .success(AnalysisResult(…))、そうでなければ .failure(ValidationErrors(lines: errors))
```
- **bool は文字列でも数でもない**（`PyJSONValue.bool` は `.string` と別）。数（`.int` / `.double`、NaN を含む）も文字列ではない
- **入力値をエラーの文に入れない**（LLM-09）。キー名だけが loc に入る
- 成功時の `AnalysisResult`: スキーマに在るフィールドだけを埋め、無いものは nil。有効で欠けた配列は `[]`、`due` の欠落は nil。**要素は strip しない**

voicedock 実測のエラー行（`AnalysisValidatorTests` の表。すべて既定の最終形スキーマ。`multi` は `{"mood":1,"summary":3,"tags":[1],"zzz":2}`）:

| 入力（JSON の本文。キーの順も入力のとおり） | `rendered` |
|---|---|
| `{"title":"t"}` | `- summary: Field required` |
| `{}` | `- title: Field required\n- summary: Field required` |
| `{"title":"t","summary":"s","mood":"x"}` | `- mood: Extra inputs are not permitted` |
| `{"title":"t","summary":""}` | `- summary: String should have at least 1 character` |
| `{"title":"","summary":"s"}` | `- title: String should have at least 1 character` |
| `{"title":"t","summary":"s","key_points":"文字列"}` | `- key_points: Input should be a valid list` |
| `{"title":"t","summary":"s","key_points":{"a":1}}` | `- key_points: Input should be a valid list` |
| `{"title":"t","summary":"s","key_points":["a",1]}` | `- key_points.1: Input should be a valid string` |
| `{"title":"t","summary":"s","key_points":[null,true,1.5,"ok"]}` | `- key_points.0: Input should be a valid string\n- key_points.1: Input should be a valid string\n- key_points.2: Input should be a valid string` |
| `{"title":"t","summary":"s","tasks":[{"due":null}]}` | `- tasks.0.text: Field required` |
| `{"title":"t","summary":"s","tasks":["x"]}` | `- tasks.0: Input should be a valid dictionary or instance of Task` |
| `{"title":"t","summary":"s","tasks":[{"text":"a","x":1}]}` | `- tasks.0.x: Extra inputs are not permitted` |
| `{"title":"t","summary":"s","tasks":[{"text":"a","due":3}]}` | `- tasks.0.due: Input should be a valid string` |
| `{"title":"t","summary":"s","tasks":[{"text":""}]}` | `- tasks.0.text: String should have at least 1 character` |
| `{"title":"t","summary":"s","tasks":[{"text":"あ"×501}]}` | `- tasks.0.text: String should have at most 500 characters` |
| `{"title":"t","summary":"s","tasks":[{"x":1,"due":3}]}` | `- tasks.0.text: Field required\n- tasks.0.due: Input should be a valid string\n- tasks.0.x: Extra inputs are not permitted` |
| `{"title":"t","summary":"s","tasks":[{"text":5,"due":true},"y"]}` | `- tasks.0.text: Input should be a valid string\n- tasks.0.due: Input should be a valid string\n- tasks.1: Input should be a valid dictionary or instance of Task` |
| `{"title":"t","summary":"s","tasks":null}` | `- tasks: Input should be a valid list` |
| `{"title":5,"summary":"s"}` / `{"title":true,"summary":"s"}` | `- title: Input should be a valid string` |
| `{"title":"t","summary":null}` | `- summary: Input should be a valid string` |
| `{"title":["t"],"summary":{"a":1}}` | `- title: Input should be a valid string\n- summary: Input should be a valid string` |
| `{"title":"t","summary":"s","tags":null}` | `- tags: Input should be a valid list` |
| `{"zzz":1,"title":"t","summary":"s","aaa":2}` | `- zzz: Extra inputs are not permitted\n- aaa: Extra inputs are not permitted`（**入力の順**。辞書順ではない） |
| multi | `- title: Field required\n- summary: Input should be a valid string\n- tags.0: Input should be a valid string\n- mood: Extra inputs are not permitted\n- zzz: Extra inputs are not permitted` |
| 中間形に `{"title":"t","summary":"s","tags":["a"]}` | `- title: Extra inputs are not permitted\n- tags: Extra inputs are not permitted` |

切り詰めの実測（既定の最終形）: `{"title": "あ"×121, "summary": 5, "key_points": "x"×30, "tags": [0..19], "tasks": [{"text":"a"}]×60}` → trimmed `["title: 121 -> 120", "key_points: 30 -> 20", "tasks: 60 -> 50", "tags: 20 -> 15"]`、
`title` は 120 スカラー、`key_points` は `"x"×20`（文字列のまま）。`{"title":"t","summary":"s"×4001}` → `["summary: 4001 -> 4000"]`。

### 4.8 `ChatTransport.swift` と `AnalysisCall.swift`（修復の流れ）

`ChatTransport.swift`（「// LLM への 1 回の要求の抽象（PLAN §8.5「HTTP」）。本番は LoopbackChatTransport（T-21）。」）:

```swift
public enum ChatResult: Equatable, Sendable {
    case content(String)                  // choices[0].message.content。外形が壊れていれば ""（修復へ回す）
    case failure(StageFailure)            // LLM_UNAVAILABLE（接続失敗・HTTP 2xx 以外。3xx を含む。F-79 で「HTTP 400 以上」から直した。T-21）
}
public protocol ChatTransport: Sendable {
    func complete(system: String, user: String) async -> ChatResult
}
```

`AnalysisCall.swift`（00-api-map §8 の `public struct AnalysisCall`。「// 1 回の解析要求: 送信 → 取り出し → 切り詰め → 検証 → 修復（voicedock llm.py:460-544）。」）:

```swift
public struct AnalysisCall: Sendable {
    public let transport: any ChatTransport
    public let prompts: Prompts
    public let customInstructions: String
    public let repairAttempts: Int
    public init(transport: any ChatTransport, prompts: Prompts, customInstructions: String, repairAttempts: Int)
    public struct Success: Equatable, Sendable { public let result: AnalysisResult; public let trimmed: [String]; public let repairs: Int }
    /// kind に応じて system を作り、body を user として送る。例外を投げない。
    public func run(kind: PromptKind, schema: AnalysisSchema, body: String) async -> Result<Success, StageFailure>
    /// 1 つの生の応答を評価する（取り出し → 切り詰め → 検証）。internal
    static func evaluate(_ raw: String, schema: AnalysisSchema) -> (result: AnalysisResult?, failure: String, trimmed: [String])
}
```

`evaluate`:
1. `JSONExtractor.extractObject(raw)` が nil → `(nil, LLMValidationMessages.notExtracted, [])`
2. `(obj2, trimmed) = AnalysisValidator.trim(obj, schema:)`
3. `validate(obj2, schema:)` が成功 → `(result, "", trimmed)`、失敗 → `(nil, errors.rendered, trimmed)`

`run`（**スキーマは呼び手が渡す**。analyze / reduce は最終形、map は中間形。修復プロンプトにも同じスキーマを使う）:
```text
system = prompts.system(kind, schema: schema, custom: customInstructions)
first = await transport.complete(system: system, user: body)
first が .failure(f) → return .failure(f)
raw = first の content
for attempt in 0...repairAttempts:
   (r, failure, trimmed) = evaluate(raw, schema)
   r が在れば return .success(Success(result: r, trimmed: trimmed, repairs: attempt))
   attempt == repairAttempts なら return .failure(StageFailure(.llmInvalidJSON, failure))
   retry = await transport.complete(system: prompts.repair(schema: schema, errors: failure, previousOutput: raw), user: "")   // transcript を再送しない
   retry が .failure(f) → return .failure(f)                          // 修復の途中で落ちたら LLM_UNAVAILABLE のまま（LLM_INVALID_JSON にしない）
   raw = retry の content
```
- `repairAttempts` は CV-56 で 0 以上。0 なら修復しない
- 呼び手は T-20 の `Analyzer`（と T-22 の解析の再利用の検証）

### 4.9 `PyJSON.decode`（T-45 が作る。本チケットでは作らない）

LLM の応答の読み取りは VDCore の `PyJSON.decode(_ text: String) -> PyJSONValue?`（T-45 §4.6。Python の `json.loads` 互換）だけを使う。`JSONSerialization` を使わない（PLAN §5.7・§8.5、F-45）。本チケットが頼る性質:
- 前後と要素の間の空白は U+0020・U+0009・U+000A・U+000D だけ。値の後に空白以外が残れば nil。先頭の U+FEFF は nil
- `NaN` / `Infinity` / `-Infinity` を `.double` で受ける。真偽値は `.bool`（数・文字列と別）
- 同じキーが 2 回出たら値は後勝ち、位置は最初の出現のまま。戻り値の `.object` はこの並び
- 入れ子は 64 段まで（65 段目で nil。X-33）

## 5. テスト

すべて `import Testing`、`@testable import VDLLM`、`import VDCore`、`import TestSupport`。

### 5.0 golden と共有の準備

golden は T-25 のグループを使う（名前と中身は T-25 §4.4・§4.5・§4.9 が正）。ケース名を列挙せず、`try Golden.cases("<group>")` をパラメータ化テストの引数に渡して全ケースを回し、
グループごとに「ケースが在る」テスト（`#expect(!(try Golden.cases("<group>")).isEmpty)`）を 1 本置く（T-25 §4.11、TEST-28）。`.out` は `GoldenAssert.matches`、`.json` は `GoldenAssert.matchesJSON` で比べる。

| グループ（ケース数） | 期待値 | 実際の値 | テスト関数 / 表示名（スイート） |
|---|---|---|---|
| `llm_schema_block`（5） | `.out` | `SchemaBlock.render(schema(item))` | `goldenSchemaBlock(item:)` / 「golden llm_schema_block」（SchemaBlockTests） |
| `llm_prompt`（6） | `.out` | `prompts.system(kind, schema: kind == .map ? 中間形 : 最終形, custom: config.llm.analysis.customInstructions)`（`kind` は `item.string("kind")` の `analyze` / `map` / `reduce`） | `goldenSystemPrompt(item:)` / 「golden llm_prompt」（PromptsTests） |
| `llm_repair_prompt`（3） | `.out` | `prompts.repair(schema: schema(item), errors: item.string("errors"), previousOutput: item.string("previousOutput"))` | `goldenRepairPrompt(item:)` / 「golden llm_repair_prompt」（PromptsTests） |
| `prompt_files`（4） | `.out` | `Resources/prompts/<name>.txt` のバイト列（`matches(bytes:)`）。`repair_json` だけは `repair_json_ja.txt` のバイト列 = 期待値のバイト列 + `"\n{schema_block}\n"` を `#expect` で確かめる（X-12） | `goldenPromptFiles(item:)` / 「golden prompt_files」（PromptsTests） |
| `llm_extract`（14） | `.json`（値か `null`） | `JSONExtractor.extractObject(item.string("text")).map { GoldenJSON(any: PyJSONValue.object($0).foundationObject) } ?? .null` | `goldenExtract(item:)` / 「golden llm_extract」（JSONExtractorTests） |
| `llm_strip_think`（5） | `.out` | `JSONExtractor.stripThink(item.string("text"))` | `goldenStripThink(item:)` / 「golden llm_strip_think」（JSONExtractorTests） |
| `llm_validate`（23） | `.json` `{ok, errors, result}` | `AnalysisValidator.validate(item.orderedObject("payload"), schema: schema(item))`。成功 → `{"ok": true, "errors": null, "result": <result.pyJSON(schema:)>}`、失敗 → `{"ok": false, "errors": <errors.rendered>, "result": null}` | `goldenValidate(item:)` / 「golden llm_validate」（AnalysisValidatorTests） |
| `llm_trim`（5） | `.json` `{trimmed, result}` | `AnalysisValidator.trim(item.orderedObject("payload"), schema: schema(item))` → `{"trimmed": <trimmed>, "result": <.object(obj)>}` | `goldenTrim(item:)` / 「golden llm_trim」（AnalysisValidatorTests） |
| `analysis_json`（4） | `.out` | 最終形で `validate(item.orderedObject("payload"), …)` が成功した結果の `PyJSON.fileData(result.pyJSON(schema:))`（`matches(bytes:)`） | `goldenAnalysisJSON(item:)` / 「golden analysis_json」（AnalysisResultTests） |

- `config = try GoldenConfig.make(item)`（T-09 が TestSupport に足す。入力の `timeZone` と `overrides` から `AppConfig`）。`schema(item) = AnalysisSchema(config: AnalysisConfigView(sections: config.llm.analysis.sections), kind: try item.bool("partial") ? .partial : .final)`
- `PyJSONValue` を `GoldenJSON` にするのは `GoldenJSON(any: value.foundationObject)`（T-25・T-45）
- キーの順を保った payload は **`item.orderedObject("payload")`**（**T-45** が `Tests/TestSupport/GoldenCase+PyJSON.swift` に extension で足す。T-45 §4.11。`GoldenCase` の `fields` は辞書でキーの順を持たないので、入力ファイルを `PyJSON.decode` で読み直す。T-25 の `GoldenCase` 本体は VDCore に依存しないので `orderedObject` を持たない）。
  未知キーのエラーは入力の順に並ぶ（例 `llm_validate/partial_with_title_tags` は `title` → `tags` の順で、辞書順とは逆）
- 既定の設定は `AppConfig.defaults(timeZone: "Asia/Tokyo")`。節の変更はそこから値を変えて作る
- `Prompts` は `Prompts.load(directory: PackageRoot.url.appendingPathComponent("Resources/prompts"))`
- JSON の本文から `[(String, PyJSONValue)]` を作るときは `PyJSON.decode`（テストの入力もキーの順が意味を持つ）

### 5.1 `AnalysisSchemaTests.swift`（`@Suite("AnalysisSchema") struct AnalysisSchemaTests`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `defaultFinalFields` / 「既定の最終形のフィールドと並び」 | 既定 | 名前が `["title","summary","key_points","tasks","decisions","ideas","tags"]`、形が `.text(120)`・`.text(4000)`・`.stringList(20)`・`.taskList(50)`・`.stringList(30)`・`.stringList(30)`・`.stringList(15)`、required は title・summary だけ |
| `defaultPartialFields` / 「中間形は title と tags を持たない」 | 既定、`.partial` | `["summary","key_points","tasks","decisions","ideas"]` |
| `timelineIsNeverAField` / 「timeline はスキーマに入らない」 | 既定（timeline は有効） | どちらの形にも `timeline` が無い |
| `ceKeyPointsEnabled` / 「CE llm.analysis.sections.key_points.enabled false でスキーマから消える」 | key_points を無効 | `key_points` が無く、残りの並びは変わらない（既定では在る） |
| `ceTasksEnabled` / 「CE llm.analysis.sections.tasks.enabled false でスキーマから消える」 | tasks を無効 | 同上 |
| `ceDecisionsEnabled` / 「CE llm.analysis.sections.decisions.enabled false でスキーマから消える」 | decisions を無効 | 同上 |
| `ceIdeasEnabled` / 「CE llm.analysis.sections.ideas.enabled false でスキーマから消える」 | ideas を無効 | 同上 |
| `ceTagsEnabled` / 「CE llm.analysis.sections.tags.enabled false でスキーマから消える」 | tags を無効 | 同上（最終形だけに在る節） |
| `maxItemsNilHasNoLimit` / 「CE llm.analysis.sections.ideas.maxItems が null の節には上限が無い」 | ideas の maxItems を nil（既定は 30） | `ideas` の形が `.stringList(maxItems: nil)`、`trimLimit == nil`。`maxItems = 3` なら `.stringList(maxItems: 3)` |
| `ceKeyPointsMaxItems` / 「CE llm.analysis.sections.key_points.maxItems が形に入る」 | key_points の maxItems を 3 | `.stringList(maxItems: 3)`、`trimLimit == 3`（既定は 20） |
| `ceTasksMaxItems` / 「CE llm.analysis.sections.tasks.maxItems が形に入る」 | tasks の maxItems を 3 | `.taskList(maxItems: 3)`、`trimLimit == 3`（既定は 50） |
| `ceDecisionsMaxItems` / 「CE llm.analysis.sections.decisions.maxItems が形に入る」 | decisions の maxItems を 3 | `.stringList(maxItems: 3)`（既定は 30） |
| `ceTagsMaxItems` / 「CE llm.analysis.sections.tags.maxItems が形に入る」 | tags の maxItems を 3 | `.stringList(maxItems: 3)`（既定は 15） |
| `listOrderIgnoresConfigOrder` / 「配列の節の並びは order に従わない」 | order を `["ideas","summary","tasks"]` に | 並びは既定と同じ |
| `summaryDisabledRemovesTitleAndSummary` / 「CE llm.analysis.sections.summary.enabled false なら title も summary も無い」 | summary を無効（CV-18 違反だがスキーマは作れる） | 先頭が `key_points`（既定では `title`・`summary`） |

### 5.2 `SchemaBlockTests.swift`

| 関数名 / 表示名 | 期待 |
|---|---|
| `goldenSchemaBlock(item:)` / 「golden llm_schema_block」（`arguments: try Golden.cases("llm_schema_block")`） | §5.0 の表（`final_default` は §4.3 の全文とも一致） |
| `goldenSchemaBlockHasCases` / 「golden llm_schema_block のケースが在る」 | 空でない |
| `finalMatchesPlanText` / 「既定の最終形が §4.3 の全文と一致」 | 既定の設定の最終形が §4.3 のコードブロックと一致 |
| `itemLimitIsNotShown` / 「件数の上限を見せない（LLM-01）」 | ideas の maxItems を 7 にしても、`"ideas"` の行に `7` が無く、全体に `最大 7 件` が無い |
| `characterLimitIsShown` / 「文字数の上限は見せる」 | 全体に `文字以内` が在る |
| `noTrailingNewline` / 「末尾に改行が無い」 | 最後の文字が `}` |

### 5.3 `PromptsTests.swift`

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `resourceFilesAreExactCopies` / 「プロンプトの資源が固定の sha256 と一致」 | `Resources/prompts/` の 4 ファイル | sha256 が §4.5 の表の値（4 本とも） |
| `goldenSystemPrompt(item:)` / 「golden llm_prompt」 | `Golden.cases("llm_prompt")`（analyze / map / reduce、custom の有無・複数行・プレースホルダ入り） | §5.0 の表のとおり一致 |
| `goldenRepairPrompt(item:)` / 「golden llm_repair_prompt」 | `Golden.cases("llm_repair_prompt")` | 一致 |
| `goldenPromptFiles(item:)` / 「golden prompt_files」 | `Golden.cases("prompt_files")` | 一致（`repair_json` は §5.0 の表の規則） |
| `goldenPromptGroupsHaveCases` / 「golden llm_prompt・llm_repair_prompt・prompt_files のケースが在る」 | 3 グループ | どれも空でない |
| `mapHasNoTitleOrTags` / 「map の system は中間形（title と tags が無い）」 | 中間形 | `"title"` と `"tags"` を含まない |
| `placeholdersAreFilled(kind:)` / 「差し込み後にプレースホルダが残らない」 | 3 種 | `{schema_block}`・`{custom_instructions}` を含まない、`summary` を含む |
| `repairIncludesTheSchema` / 「修復プロンプトの末尾にスキーマ（X-12）」 | 最終形、errors `- summary: Field required`、previous `{"title": "t"}` | `"前回の出力は JSON として不正でした。\n\nエラー内容:\n- summary: Field required\n\n前回の出力:\n{\"title\": \"t\"}\n\n同じ内容を、指定されたスキーマに厳密に従う有効な JSON のみで出力し直してください。\n説明文やコードフェンスを付けないでください。\n\n" + <llm_schema_block/final_default.out の中身> + "\n"` と一致 |
| `repairUsesThePartialSchemaForMap` / 「Map の修復は中間形のスキーマ」 | 中間形 | 末尾が `llm_schema_block/partial_default.out の中身 + "\n"` |
| `substitutionOrderIsFixed` / 「差し込みの順が固定」 | custom に `{schema_block}`、previousOutput に `{errors}` を入れる | custom の `{schema_block}` はそのまま残る。previousOutput の `{errors}` もそのまま残る |
| `replaceIsLiteralOnScalars` / 「置換はスカラーの完全一致（Python の str.replace と同じ）」 | `repair(最終形, errors: "{previous_output}\u{301}", previousOutput: "P")`（`}` の直後に結合文字。Character 単位の検索では一致しない） | 結果が `"エラー内容:\nP\u{301}\n"` を含む（errors の中のプレースホルダも置換される。voicedock と同じ） |
| `loadFailsForMissingFile` / 「ファイルが無ければ unreadable」 | 3 本だけ置いた一時ディレクトリ | `PromptsError.unreadable("repair_json_ja.txt")` |
| `probeConstants` / 「疎通確認の文言」 | — | `LLMProbe.system == "{\"ok\": true} と返してください。"`、`LLMProbe.user == "ping"`（user は 100 スカラー未満） |
| `noPromptAsksForWikilinks` / 「リンクを作らせない（PR-15）」 | 3 本 | それぞれ `本文に [[ ]] 形式のリンクを書かないでください。` を含む。repair には `[[` が無い |

### 5.4 `JSONExtractorTests.swift`

`VALID = {"title": "一日", "summary": "まとめ", "tasks": []}`（`\u` エスケープの本文で渡す場合も含む。voicedock のテストは `json.dumps` 既定の ASCII エスケープだった）。期待は `extractObject` の戻り値を `.object` に包んで `PyJSONValue` として比べる。

| 関数名 / 表示名 | 入力 | 期待 |
|---|---|---|
| `bareJSON` | `VALID` | VALID |
| `fencedJSON` | "```json\n" + VALID + "\n```" | VALID |
| `fenceWithoutLanguage` | "```\n" + VALID + "\n```" | VALID |
| `proseAroundTheJSON` | `"はい、整理しました。\n\n" + VALID + "\n\n以上です。"` | VALID |
| `thinkingTagsAreRemoved` | `"<think>まず何を出すか考える</think>\n" + VALID` | VALID |
| `unusableOutputReturnsNil(text:)` | `""`、`"ただの文章です"`、`"{"`、`"{'single': 'quotes'}"`、`"[1, 2, 3]"`、`"\"文字列\""`、`"null"` | nil |
| `topLevelArrayYieldsFirstObject` | `[{"title": "t", "summary": "s"}]` | `{"title":"t","summary":"s"}` |
| `jsonInsideThinkIsNotTaken` | `<think>{"title": "下書き", "summary": "捨てる"}</think>` + VALID | VALID |
| `unclosedThinkSwallowsTheRest` | `<think>{"title": "途中"` | nil |
| `multipleThinkBlocksAreRemoved` | `<think>A</think>前置き<think>B</think>` + VALID | VALID |
| `stripThinkLeavesOtherText` | `stripThink("前<think>中</think>後")` | `"前後"` |
| `braceInsideAStringIsNotTheEnd` | `"説明\n" + {"summary": "閉じ括弧 } を含む文", "tasks": []} + "\n以上"` | その辞書 |
| `escapedQuoteInsideAString` | `前` + `{"summary": "引用 \" を含む"}` + `後` | その辞書 |
| `backslashBeforeClosingQuote` | `x` + `{"summary": "末尾が \\ で終わる"}` + `y` | その辞書 |
| `nestedObjects` | `"説明\n" + {"tasks": [{"text": "a", "due": null}], "summary": "s"}` | その辞書（キーの順も） |
| `trailingTextAfterTheObject` | VALID + `"\n\nこれで完了です。"` | VALID |
| `firstObjectWins` | `{"summary": "1 本目"}\n{"summary": "2 本目"}` | 1 本目 |
| `fenceIsPreferredOverBalanced` | `"前置きに { があります\n```json\n" + VALID + "\n```"` | VALID |
| `voicedockMeasuredCases(input:)` | §4.6 の 8 例 | §4.6 の値（NaN は `isNaN` で確かめる） |
| `goldenExtract(item:)` / 「golden llm_extract」 | `Golden.cases("llm_extract")` | §5.0 の表 |
| `goldenStripThink(item:)` / 「golden llm_strip_think」 | `Golden.cases("llm_strip_think")` | §5.0 の表 |
| `goldenExtractGroupsHaveCases` / 「golden llm_extract・llm_strip_think のケースが在る」 | 2 グループ | 空でない |
| `keyOrderIsPreserved` | `{"b":1,"a":2,"b":3}` | `[("b", .int(3)), ("a", .int(2))]` |
| `fenceNeedsANewline` | "```json {\"a\":1}```" | `[("a",1)]`（フェンスは不成立、balanced が拾う） |
| `emptyInput` | `""` | nil |

### 5.5 `AnalysisValidatorTests.swift`

| 関数名 / 表示名 | 期待 |
|---|---|
| `errorLines(input:expected:)` / 「検証エラーの行が pydantic と同じ」 | §4.7 の表の全行（`PyJSON.decode` した入力を `validate`、`rendered` が一致） |
| `goldenValidate(item:)` / 「golden llm_validate」 | `Golden.cases("llm_validate")` の全 23 ケースが §5.0 の表のとおり一致 |
| `goldenTrim(item:)` / 「golden llm_trim」 | `Golden.cases("llm_trim")` の全 5 ケース |
| `goldenValidatorGroupsHaveCases` / 「golden llm_validate・llm_trim のケースが在る」 | 空でない |
| `validPayloadPasses` / 「正しい入力は通る」 | `{"title":"開発と打ち合わせの一日","summary":"削除条件を整理した。","key_points":["整理した"],"tasks":[{"text":"確認する","due":null}],"decisions":["GUI は作らない"],"ideas":["話者識別"],"tags":["VoiceDock"]}` → 成功、各値が一致 |
| `missingListsDefaultToEmpty` / 「欠けた配列は空配列」 | `{"title":"t","summary":"s"}` → 5 つの配列が `[]` |
| `missingDueIsNil` / 「due の欠落は nil」 | `tasks: [{"text":"a"}]` → `due == nil` |
| `disabledSectionIsRejected` / 「無効な節を出したら未知キー」 | ideas 無効で `ideas: ["x"]` → `- ideas: Extra inputs are not permitted` |
| `boolIsNotAString` / 「bool を文字列として受けない」 | `title: true` → `- title: Input should be a valid string` |
| `valuesAreNotLeaked` / 「エラーに入力値を入れない（LLM-09）」 | `{"title":"t","summary":"秘密の本文","tasks":[{"text":"秘密のタスク","x":"秘密の値"}],"mood":"秘密"}` → `rendered` に `秘密` を含まない |
| `trimMeasured` / 「切り詰めの実測」 | §4.7 の 2 例の `trimmed` と値 |
| `trimmingThenValidating` / 「切り詰めてから検証する」 | tags 20 個・title 121 スカラー → `trim` の後 `validate` が成功、tags 15 個 |
| `exactlyAtLimitIsNotTrimmed` / 「上限ちょうどは切らない」 | tags 15 個・title 120 スカラー → `trimmed == []` |
| `taskTextIsNotTrimmed` / 「tasks の text は切らない」 | text 501 スカラー → `trimmed == []`、検証で `at most 500` |
| `emptySummaryIsNotFixed` / 「最小長は切り詰めで直さない」 | summary `""` → `trimmed == []`、`at least 1` |
| `noLimitMeansNoTrim` / 「上限の無い節は切らない」 | ideas の maxItems nil、200 個 → `trimmed == []`、成功で 200 個 |
| `countsScalarsNotCharacters` / 「文字数はスカラーで数える」 | title = `"が"`（U+304B U+3099 の 2 スカラー）× 61 → 122 スカラーなので `title: 122 -> 120` |

### 5.6 `AnalysisResultTests.swift`

| 関数名 / 表示名 | 期待 |
|---|---|
| `analysisJSONMatchesVoicedock` / 「analysis.json の形が voicedock と一致」 | `{"title":"t","summary":"s","tasks":[{"text":"x","due":"2026-09-20"}]}` を検証した結果の `PyJSON.fileData(pyJSON(schema:))` が次の全文（末尾改行あり）とバイト一致: `{\n  "title": "t",\n  "summary": "s",\n  "key_points": [],\n  "tasks": [\n    {\n      "text": "x",\n      "due": "2026-09-20"\n    }\n  ],\n  "decisions": [],\n  "ideas": [],\n  "tags": []\n}\n` |
| `nullDueIsWritten` / 「due が nil でも null として出す」 | `"due": null` を含む |
| `partialHasNoTitleOrTags` / 「中間形の pyJSON に title と tags が無い」 | キーが `summary, key_points, tasks, decisions, ideas` |
| `goldenAnalysisJSON(item:)` / 「golden analysis_json」 | `Golden.cases("analysis_json")` の全 4 ケースがバイト一致 |
| `goldenAnalysisJSONHasCases` / 「golden analysis_json のケースが在る」 | 空でない |

### 5.7 `AnalysisCallTests.swift`（`FakeChatTransport` を使う）

準備: 既定の設定、`GOOD = {"title":"t","summary":"s"}`、`BODY = "文字起こしの本文です"`、`repairAttempts = 1`（指定の無い限り）。

| 関数名 / 表示名 | 応答の列 | 期待 |
|---|---|---|
| `validFirstResponse` / 「1 回目で通る」 | `[.content(GOOD)]` | 成功、repairs 0、呼び出し 1 回、system == `prompts.analyze(最終形, "")`、user == BODY |
| `invalidThenRepaired` / 「1 回で直る」 | `[.content("{\"title\":\"t\"}"), .content(GOOD)]` | 成功、repairs 1、2 回目の system == `prompts.repair(最終形, errors: "- summary: Field required", previousOutput: "{\"title\":\"t\"}")`、user == `""` |
| `twoFailuresAreInvalidJSON` / 「直らなければ LLM_INVALID_JSON」 | 2 回とも `{"title":"t"}` | `.failure(StageFailure(.llmInvalidJSON, "- summary: Field required"))`、呼び出し 2 回 |
| `repairAttemptsZero` / 「CE llm.repairAttempts 0 は修復しない」 | 1 回目が不正、`repairAttempts = 0`（既定の 1 なら 2 回呼ぶ） | 呼び出し 1 回、LLM_INVALID_JSON |
| `ceCustomInstructions` / 「CE llm.analysis.customInstructions が system に差し込まれる」 | `customInstructions = "箇条書きは短く。"` と `""`、`[.content(GOOD)]` | 1 回目の system が前者では `箇条書きは短く。` を含み、後者では含まない。どちらも `{custom_instructions}` を含まない |
| `repairAttemptsTwo` / 「repairAttempts 2 は 2 回修復する」 | 3 回とも不正 | 呼び出し 3 回 |
| `transportFailureIsReturned` / 「接続失敗はそのまま返す」 | `[.failure(StageFailure(.llmUnavailable, "URLError -1004"))]` | 同じ failure、呼び出し 1 回 |
| `repairThatCannotConnectStops` / 「修復の途中の接続失敗は LLM_UNAVAILABLE」 | `[.content("x"), .failure(unavailable)]` | LLM_UNAVAILABLE |
| `malformedEnvelopeGoesToRepair` / 「外形が壊れた応答（空文字）は修復へ回る」 | `[.content(""), .content("")]` | LLM_INVALID_JSON、メッセージ `応答から JSON を抽出できませんでした`、2 回目の errors が同じ文 |
| `repairNeverResendsTheTranscript` / 「修復要求に本文を入れない」 | 不正 → GOOD | 2 回目の system と user のどちらにも BODY を含まない |
| `mapUsesThePartialSchema` / 「map は中間形で検証する」 | kind `.map`、`[.content(GOOD)]` | `- title: Extra inputs are not permitted` で修復へ回る（2 回目の system の末尾が中間形の schema_block） |
| `trimmedNotesPropagate` / 「切り詰めの記録を返す」 | tags 20 個の応答 | 成功、trimmed `["tags: 20 -> 15"]` |

### 5.8 `FakeChatTransport`（`Tests/TestSupport/FakeChatTransport.swift`）

```swift
public actor FakeChatTransport: ChatTransport {
    public struct Call: Equatable, Sendable { public let system: String; public let user: String }
    /// 応答を順に返す。尽きたら .failure(StageFailure(.llmUnavailable, "FakeChatTransport: 応答がありません"))。
    public init(responses: [ChatResult])
    /// 呼び出しごとに handler で応答を決める（T-20 の Map / Reduce の振り分け用）。
    public init(handler: @escaping @Sendable (Call) -> ChatResult)
    public func complete(system: String, user: String) async -> ChatResult
    public var calls: [Call] { get }
}
```

### 5.9 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`llm.repairAttempts`・`llm.analysis.customInstructions`・summary・key_points・tasks・decisions・ideas・tags の `enabled`（6 行）・key_points・tasks・decisions・ideas・tags の `maxItems`（5 行）の計 13 行を消す（CE テストは §5.1・§5.7）。`timeline.enabled` は T-27 が消す。`summary.maxItems` と `timeline.maxItems` は**キーそのものが無い**（F-54）ので `owners` に載っていない（T-09 §9）。

## 6. 破壊による証明

| 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|
| `SchemaBlock` の ideas の例に `（最大 \(n) 件）` を足す | `itemLimitIsNotShown`、`goldenSchemaBlock` |
| `AnalysisSchema` の配列の節を config の order で並べる（`AnalysisConfigView` は `order` を持たないので、`listSections` の代わりに `listOrderIgnoresConfigOrder` の order の並び `["ideas", "tasks", "key_points", "decisions", "tags"]` を直書きして代える） | `listOrderIgnoresConfigOrder`、`goldenSchemaBlock` |
| 中間形で tags を除かない | `defaultPartialFields`、`goldenSchemaBlock`（`partial_default`）、`goldenSystemPrompt`（`map_default`） |
| `Prompts` の置換を `{custom_instructions}` → `{schema_block}` の順にする | `substitutionOrderIsFixed` |
| `repair_json_ja.txt` の末尾の `{schema_block}` の行を消す | `resourceFilesAreExactCopies`、`repairIncludesTheSchema` |
| `stripThink` を取り出しの後に回す（balanced を先に） | `jsonInsideThinkIsNotTaken` |
| `balanced` で文字列の中の `}` も数える | `braceInsideAStringIsNotTheEnd` |
| `trim` で文字数を `String.count` で数える | `countsScalarsNotCharacters` |
| `validate` で未知キーを辞書順に並べる | `errorLines`（`zzz` / `aaa` の行）、`goldenValidate`（`partial_with_title_tags`） |
| `validate` で `.bool` を文字列として受ける | `boolIsNotAString`、`errorLines`（`title_bool`） |
| `AnalysisCall` の修復要求の user に body を渡す | `repairNeverResendsTheTranscript` |
| `AnalysisCall` で修復の接続失敗を LLM_INVALID_JSON に写す | `repairThatCannotConnectStops` |

## 7. 受け入れ条件

- [ ] §3 のファイルがすべてあり、`make lint` と `make test` が通る
- [ ] 4 つのプロンプトの sha256 が §4.5 の値と一致し、PR 本文に `shasum` の出力が貼ってある
- [ ] golden（T-25 の 9 グループ: `llm_schema_block`・`llm_prompt`・`llm_repair_prompt`・`prompt_files`・`llm_extract`・`llm_strip_think`・`llm_validate`・`llm_trim`・`analysis_json`）と一致
- [ ] §4.7 の表の全行がテストで固定されている
- [ ] Swift の `Regex`・`NSRegularExpression`・`JSONSerialization`（取り出しと検証）を使っていない
- [ ] 破壊による証明の各項目で、表のテストが落ちることを確かめ、PR 本文に貼った

## 8. API 地図への変更提案

1. `JSONExtractor.extractObject` の戻り値を `[String: Any]?` から `[(String, PyJSONValue)]?` に（`[String: Any]` はキーの順を失い、未知キーのエラーの順が決まらない）→ 00-api-map に反映済み（2026-09-18）
2. `AnalysisValidator.trim` / `validate` の引数・戻り値を `[(String, PyJSONValue)]` に（同上）→ 00-api-map に反映済み（2026-09-18）
3. `PyJSON.decode(_ text: String) -> PyJSONValue?`（Python `json.loads` 互換。§4.9）を T-45 に足す。PLAN §8.5 の「検証は JSONSerialization で辞書にしてから」とも食い違うので PLAN も直す → 00-api-map（T-45）と PLAN §5.7・§8.5（F-45）に反映済み（2026-09-18）。本チケットの予備の `PyJSON+Decode.swift` は外した（入れ子の上限は T-45 の 64 段）
4. `SchemaField`（形の enum）・`AnalysisLimits`・`PromptKind`・`PromptsError`・`LLMProbe`・`LLMValidationMessages`・`AnalysisSchema.Kind` の公開を追記 → `SchemaField`・`LLMProbe`・`LLMValidationMessages`・`AnalysisSchema.Kind`・`AnalysisCall`（公開）は 00-api-map に反映済み（2026-09-18。`AnalysisCall` は地図に合わせて public にした）。`AnalysisLimits`・`PromptKind`・`PromptsError`・`Prompts.system(_:schema:custom:)` は地図に無い（`AnalysisCall.run` の引数に `PromptKind` が要るので追記が要る）
5. `ChatTransport` / `ChatResult` の作成は T-20 ではなく本チケット（修復の流れのテストに要るため）。`FakeChatTransport`（TestSupport）も本チケット → 00-api-map §8・§15 に反映済み（2026-09-18）
6. golden のファイル名（§5.0）を T-25 に取り決める。比較の補助は T-25 の `GoldenAssert` → 形を変えて反映済み（2026-09-18）: T-25 のグループ（`llm_schema_block` ほか 9 つ）と `Golden.cases` を使う形に §5.0 を直した
7. （整合修正で追加 → **採用済み**）`GoldenCase.orderedObject(_:)`（キーの順を保った `[(String, PyJSONValue)]`）は **T-45** が `Tests/TestSupport/GoldenCase+PyJSON.swift` に extension で足す（00-api-map §15。`PyJSONValue` / `PyJSON.decode` は T-45 が作るので、T-25 の本体に置くと T-25 → T-45 の循環になる）。本チケットはそれを使う（自前の `GoldenPayload` は作らない）
8. （実装で発見。**未反映・利用者の承認待ち。実装には不要**）00-api-map §8 の `AnalysisValidator.swift` の行に載っている `AnalysisCall` と `LLMProbe` は、本チケット §3 どおり `AnalysisCall.swift` と `Prompts.swift` に置いた。地図の `Prompts.load(directory:) throws` は本チケットの `throws(PromptsError)` に、地図の `AnalysisSchema` / `Kind` にも `Equatable` を足すよう、地図の行を直すことを提案する

## 9. SPEC の変更

なし（検証の文言・プロンプトの sha256 は SPEC の表ではなくテストが固定する）

## 10. マージ後にやること

なし
