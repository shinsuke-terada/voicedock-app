# T-24 モデルカタログの確定と LLM 受け入れ試験

| 項目 | 値 |
|---|---|
| ID | T-24 |
| Phase | 5（LLM とモデル） |
| 前提 | T-22（`SessionSteps` の解析の工程・`FakeLLMServer`）、T-23（`ModelFiles` の在否。`Sources/VDModels` は使わない）。間接に T-19（`AnalysisCall` / `Prompts` / `AnalysisResult`）、T-20（`Analyzer` / `Chunker`）、T-21（`LlamaServerSupervisor` / `LoopbackChatTransport`）、T-03（`Vendor/build/bin/llama-server`）、T-09（`ModelCatalog`） |
| 見積もり | fixture 約 250,000 文字（9 本）、テストとスクリプト約 750 行、`docs/POC.md` 章 15 |
| 後続 | T-31（一覧に出す LLM は `verified: true` だけ）、T-44（v1.0 のリリースノートにモデルの版を書く） |

## 1. 目的

2 つを終わらせる。

1. **カタログの値を確定する**（PLAN §8.10）。`Resources/ModelCatalog.json` の URL のコミット SHA・sha256・bytes・license を **HF API でもう一度確かめ**、記録を残す
2. **LLM の受け入れ試験**（PLAN §10.6）を作って走らせ、合格した LLM だけを `verified: true` にする。結果（割合・時間・機種・モデルの sha256）を `docs/POC.md` に貼る

**この試験はローカルでだけ走る**（`VOICEDOCK_LLM_MODEL` が無ければ全部無効。CI では走らない）。カタログの確認は**開発者が手で行う**（アプリはボタンを押したときしかインターネットに出ない。PT-02。確認のスクリプトはアプリのコードではない）。

## 2. 参照

- PLAN §8.10（カタログの JSON・値を推測で埋めない・`verified: true` の条件・思考モード付きを載せない・`minMemoryGB`）、§10.6（受け入れ試験の 5 項目）、§10.1（`.enabled(if:)` と環境変数・`TestEnvironment` だけが環境変数を読む）、§8.5（Map-Reduce と修復）、§12.2 章 8（P0-07 の 220,000 文字の Map-Reduce）
- 00-api-map.md §2.2（`ModelCatalog` / `ModelEntry` / `ModelFiles`）、§8（`Analyzer` / `AnalysisCall` / `LlamaServerSupervisor` / `LoopbackChatTransport`）、§10（VDModels）、§14（`LLMAcceptance` ターゲット）、§15
- 移植メモ V7 §3（HF の実値。2026-09-18 取得）、V6（`docs/POC.md` の書き方）
- voicedock@d3d595e `scripts/fetch-models.sh`（モデル名の検査・`.part` へ落としてから rename）、`tests/unit/test_fetch_models.py`（検査の網羅のしかた）、`docs/POC.md`（§0 記録の規約・章の立て方）
- T-19 §4.8（`AnalysisCall.run` は修復の要求を `user: ""` で送る）、T-20 §4.3（`Analyzer.analyze` の流れ。Map はチャンクの順に 1 つずつ）

## 3. 作るもの

| パス | 中身 | リポジトリに入れるか |
|---|---|---|
| `scripts/check-catalog.sh` | HF API でカタログの値を確かめ、表と差分を出す（§4.1） | 入れる |
| `Resources/ModelCatalog.json` | 確認の結果で値を直し、合格した LLM を `verified: true` にする（§4.2） | 入れる（変更） |
| `Tests/Fixtures/llm-acceptance/s01-standup.json` 〜 `s09-allhands.json` | 合成した日本語の会話 9 本（§4.3） | 入れる |
| `Tests/LLMAcceptance/AcceptanceFixture.swift` | fixture の型・読み込み・長文の生成 | 入れる |
| `Tests/LLMAcceptance/AcceptanceHarness.swift` | llama-server の起動・`Analyzer` の実行・呼び出しの数え方 | 入れる |
| `Tests/LLMAcceptance/AcceptanceJudge.swift` | 判定の式（純関数） | 入れる |
| `Tests/LLMAcceptance/AcceptanceReport.swift` | `docs/POC.md` に貼る Markdown を作る | 入れる |
| `Tests/LLMAcceptance/AnalysisAcceptanceTests.swift` | 9 本の会話（§5.1） | 入れる |
| `Tests/LLMAcceptance/LongTranscriptAcceptanceTests.swift` | 220,000 文字 1 本（§5.2） | 入れる |
| `Tests/LLMAcceptance/AcceptanceJudgeTests.swift` | 判定の式の単体（モデル不要） | 入れる |
| `Tests/LLMAcceptance/AcceptanceFixtureLoaderTests.swift` | 読み込みと長文の生成の単体（モデル不要） | 入れる |
| `Tests/TestSupport/TestEnvironment+LLMAcceptance.swift` | `TestEnvironment` に fixture のディレクトリと報告の出力先を足す（作り手は T-01。extension で足す） | 入れる |
| `Tests/PolicyTests/AcceptanceFixturesTests.swift` | fixture の形を CI でも確かめる（§5.4） | 入れる |
| `Makefile`（変更） | `llm-acceptance` に報告の出力先を渡し、`acceptance-selftest` を足す（§4.7） | 入れる |
| `.gitignore`（変更） | `/llm-acceptance-*.md` を足す | 入れる |
| `docs/POC.md`（変更） | 目次に章 15 を足し、章 15 を書く（§4.8） | 入れる |
| `~/VoiceDockAcceptance/`（リポジトリの外） | 利用者の実録音から作った fixture を置く場合の置き場所（§4.3） | 入れない |

## 4. 仕様

### 4.1 カタログの再確認（`scripts/check-catalog.sh`）

**値を推測で埋めない**（PLAN §8.10）。次のスクリプトで HF API から取り、`Resources/ModelCatalog.json` と突き合わせる。

```bash
#!/bin/bash
# ModelCatalog.json の値を Hugging Face API で確かめる（PLAN §8.10。T-24）。
# **アプリのコードではない。**開発者が手で走らせる（アプリがインターネットに出るのは PLAN §8.10 の場合だけ。PT-02）。
# 使い方:
#   scripts/check-catalog.sh                 # Resources/ModelCatalog.json の全項目
#   scripts/check-catalog.sh <repo> <file>   # 候補を 1 つだけ調べる（例 unsloth/Qwen3-4B-Instruct-2507-GGUF Qwen3-4B-Instruct-2507-Q4_K_M.gguf）
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
catalog="$root/Resources/ModelCatalog.json"

api() {
    # $1 = repo。lastModified の commit・license・各 blob の oid（= sha256）と size を出す
    curl -fsS "https://huggingface.co/api/models/$1?blobs=true"
}

if [ "$#" -eq 2 ]; then
    api "$1" | python3 -c '
import json, sys
m = json.load(sys.stdin)
print("repo    :", m.get("id"))
print("commit  :", m.get("sha"))
print("license :", (m.get("cardData") or {}).get("license"))
want = sys.argv[1]
for f in m.get("siblings", []):
    if f.get("rfilename") == want:
        lfs = f.get("lfs") or {}
        print("file    :", want)
        print("size    :", lfs.get("size", f.get("size")))
        print("sha256  :", lfs.get("oid"))
' "$2"
    exit 0
fi

python3 - "$catalog" <<'PY'
import json, subprocess, sys, urllib.parse
catalog = json.load(open(sys.argv[1]))
bad = 0
for kind in ("whisper", "vad", "llm"):
    for e in catalog[kind]:
        url = urllib.parse.urlparse(e["url"])
        parts = url.path.strip("/").split("/")          # <org>/<repo>/resolve/<sha>/<file>
        repo, commit, name = "/".join(parts[:2]), parts[3], "/".join(parts[4:])
        meta = json.loads(subprocess.run(
            ["curl", "-fsS", f"https://huggingface.co/api/models/{repo}?blobs=true"],
            capture_output=True, check=True, text=True).stdout)
        blob = next((f for f in meta.get("siblings", []) if f.get("rfilename") == name), None)
        lfs = (blob or {}).get("lfs") or {}
        got = {"sha256": lfs.get("oid"), "bytes": lfs.get("size"),
               "license": (meta.get("cardData") or {}).get("license"), "head": meta.get("sha")}
        for key in ("sha256", "bytes"):
            if str(got[key]) != str(e[key]):
                bad += 1
                print(f"MISMATCH {e['id']} {key}: catalog={e[key]} hf={got[key]}")
        print(f"{e['id']}\t{repo}\tpinned={commit}\thead={got['head']}\tbytes={got['bytes']}\t"
              f"sha256={got['sha256']}\tlicense={got['license']}")
print("NG" if bad else "OK")
sys.exit(1 if bad else 0)
PY
```

手順（**利用者が行う。ネットワークに出る**）:
1. `scripts/check-catalog.sh | tee /tmp/catalog-check.txt` を走らせ、**出力をそのまま** `docs/POC.md` 章 15 に貼る（測定日も書く）
2. `MISMATCH` が出たら、**カタログを HF の値に直す**（HF が正。コミットで固定しているので値が変わるのは移植メモの写し間違いのとき）
3. `pinned` と `head` が違ってよい（コミットで固定しているから。`head` が進んでいても取り直さない）
4. `license` が `apache-2.0` / `mit` のように**利用者のダウンロードを許すもの**であることを目で確かめる。カードに license が無いリポジトリは**載せない**
5. 直したら `swift test --filter ModelCatalogTests` が緑であることを確かめる（T-09 の `bundledCatalogLoads` / `bundledURLsArePinned`）

2026-09-18 に確認した値（移植メモ V7 §3。この表と HF の応答が一致すればカタログは正しい。`large-v3-turbo-q8_0` の行は 2026-10-05 に HF API で確かめて足した。PLAN F-104）:

| id | repo | commit | bytes | sha256 | license |
|---|---|---|---|---|---|
| `large-v3-turbo-q8_0` | ggerganov/whisper.cpp | `5359861c739e955e79d9a303bcbc70fb988958b1` | 874,188,075 | `317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1` | mit |
| `large-v3-turbo-q5_0` | ggerganov/whisper.cpp | `5359861c739e955e79d9a303bcbc70fb988958b1` | 574,041,195 | `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` | mit |
| `silero-v5.1.2` | ggml-org/whisper-vad | `9ffd54a1e1ee413ddf265af9913beaf518d1639b` | 885,098 | `29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf` | mit |
| `qwen3-30b-a3b-instruct-2507-q4_k_m` | unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF | `eea7b2be5805a5f151f8847ede8e5f9a9284bf77` | 18,556,686,752 | `6c997b8af17debdfb01d890214400ccbab00db6acc0ba8da5de1cc906c4774d0` | apache-2.0 |
| `qwen3-4b-instruct-2507-q4_k_m` | unsloth/Qwen3-4B-Instruct-2507-GGUF | `a06e946bb6b655725eafa393f4a9745d460374c9` | 2,497,281,120 | `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597` | apache-2.0 |

### 4.2 LLM の候補の決め方と `verified`

**候補**（2026-09 時点。公式 Qwen の GGUF と ggml-org の Q4_K_M は無い。移植メモ V7 §3(c)(d)）:

| 候補 | 30B の license（カード） | 4B の license（カード） | 備考 |
|---|---|---|---|
| unsloth | apache-2.0 | apache-2.0 | **既定の候補**（両方に license がある） |
| lmstudio-community | apache-2.0 | （未記載） | 4B が載せられない |
| bartowski / MaziyarPanahi | （未記載） | （未記載） | 載せない |

決め方（この順。最初に決まったところで止める）:
1. **カードに license があること**。無ければ落とす（PLAN §8.10「ライセンスが再配布ではなく利用者のダウンロードを許すこと」を確かめられない）
2. **思考モード付きを載せない**（`Thinking` / `-thinking` を名前に含むもの、既定で `<think>` を出すもの）。`Instruct-2507` は非思考
3. `scripts/check-catalog.sh <repo> <file>` で sha256・size・commit を取り、カタログに書く
4. §4.4 の受け入れ試験を**その量子化ファイルそのもの**で走らせる（`make llm-acceptance MODEL=<id>`）
5. §4.5 の 4 つの判定にすべて合格 → `verified: true`。1 つでも落ちたら `verified: false` のまま次の候補へ（unsloth → lmstudio-community）
6. 30B と 4B は**別々に判定する**（`minMemoryGB` が違うので、片方だけ `true` でもよい）

`verified: false` の項目は一覧に出ない（`ModelCatalog.listedLLMs`）。T-24 の PR では **1 つ以上の LLM が `verified: true`** になっていること（そうでないと利用者が LLM を選べない）。

**利用者の決定（2026-09-22）**: T-24 は試験の仕組み（コード・fixture・判定・スクリプト）だけで先にマージし、本物の llama-server とモデルでの受け入れ試験と `verified: true` への変更は、**後でカタログだけを直す別の PR** で行う（モデルは 30B が約 18.6 GB・4B が約 2.5 GB、試験は利用者が行う）。それまで一覧に出る LLM は 0 本で、T-31 の LLM の選択は空になる。**v1.0（T-44）の前に必ず行う**

### 4.3 transcript の fixture（10 本）

voicedock には LLM 応答の fixture が 2 本あるだけで、transcript の fixture は無い（PLAN §10.6）。**ここで作る。**

**形**（`Tests/Fixtures/llm-acceptance/<id>.json`。UTF-8・LF・末尾に改行 1 つ・インデント 2）:

```json
{
  "id": "s01-standup",
  "dayDate": "2026-08-29",
  "timeZone": "Asia/Tokyo",
  "startedAt": "2026-08-29T09:00:00+09:00",
  "segmentSeconds": 8,
  "segments": ["おはようございます。", "昨日の続きから話します。"],
  "expected": { "maxTasksWithDue": 1 }
}
```

- `segments` は 1 発話 1 要素（10〜200 スカラー）。`startedAt` から `segmentSeconds` 秒ずつ並べる（`at = startedAt + i × segmentSeconds`、`endAt = at + segmentSeconds`）
- `expected.maxTasksWithDue` = **本文に日付が明示されている依頼の数**（「9 月 5 日までに」など）。これを超える `due` が出たら不合格（PLAN §10.6 の 3「期限の無い task の due が null」を機械で判定できる形にしたもの）

**合成する 9 本**（`id` はファイル名と同じ。目安の文字数は `TextLimit.scalarCount` の合計。±20% まで許す）:

| id | 場面（話者） | 目安の文字数 | 入れるもの | `maxTasksWithDue` |
|---|---|---|---|---|
| `s01-standup` | 朝会（3 人） | 5,000 | 依頼 3・決定 1 | 1 |
| `s02-design-review` | 設計レビュー（2 人） | 8,000 | 決定 3・アイデア 2 | 0 |
| `s03-oneonone` | 1on1（2 人） | 12,000 | 依頼 2 | 1 |
| `s04-support-call` | 問い合わせ対応（2 人） | 16,000 | 依頼 4 | 2 |
| `s05-planning` | 計画（4 人） | 22,000 | 依頼 6・決定 2 | 3 |
| `s06-retrospective` | ふりかえり（4 人） | 28,000 | アイデア 5・依頼 3 | 0 |
| `s07-field-note` | 作業中の独り言（1 人） | 35,000 | 依頼 2・話題の転換を多く | 0 |
| `s08-workshop` | 勉強会（5 人） | 45,000 | 要点を多く・決定 0 | 0 |
| `s09-allhands` | 全体会（発表と質疑） | 60,000 | 決定 2・依頼 4 | 2 |

**書き方の規則**（PolicyTests が機械で確かめる。§5.4）:
- 実在の個人名・団体名・住所・電話番号・メールアドレスを書かない。話者は `Aさん` `Bさん` のように呼ぶ
- `[[` と `]]` を**入れない**（判定 3 の入力側を汚さない）
- 日付を明示するのは `maxTasksWithDue` の数だけ。それ以外の依頼には「近いうちに」「そのうち」「手が空いたら」のようにぼかした言い方だけを使う。「今日中」「明日」「今週」「来週」「来月」「今月中」「月末」「週末」「週明け」曜日、「〜までに」（「ここまでに」「ところまでに」を除く）は、日付を明示した要素の外に書かない（期限として読めるため。§5.4 `deadlinesOnlyInDatedSegments`）
- 文は句点（`。`）で終える（whisper-cli の日本語の出力に似せる）。フィラー（`えーと` `はい`）を 1 割ほど混ぜる
- 作り方: 人が書くか、LLM に下書きさせて**人が読み**、上の規則を満たすまで直す。**アプリのコードから生成しない**（実装を呼んで期待値を作らない。TEST-01）

**長文 1 本**（`L01-longday`。約 220,000 文字。**ファイルにしない。生成する**）:
- `AcceptanceFixture.longDay()`: 9 本を `id` の昇順に連結した `segments` を、要素ごとに足していき、合計が 220,000 スカラーに**達した時点で止める**。最後に足した要素も丸ごと入れる（切り詰めない。文の途中で切らない）。1 要素は 200 スカラー以下なので、合計は 220,000 以上 220,200 未満になる（§5.3 `longDayIsDeterministic`）
- `startedAt = 2026-08-29T07:00:00+09:00`、`segmentSeconds = 12`、`expected.maxTasksWithDue` = 9 本の合計 × 繰り返し回数（途中まで使った回も 1 回と数える）
- リポジトリに 1 MB の fixture を置かないためであり、**決定的**（同じ 9 本から同じ長文ができる）

**利用者の実録音から作る場合**（PLAN §10.6）:
- リポジトリに入れない。`~/VoiceDockAcceptance/` に同じ形の JSON を置き、`VOICEDOCK_LLM_FIXTURES=~/VoiceDockAcceptance` を渡す
- そのディレクトリの `*.json` を `id` の昇順に読み、**10 本に満たなければ**合成の 9 本で埋める（長文は必ず生成する）。`*.json` が 0 本なら失敗にせず全部を合成の 9 本にする（`AcceptanceFixture.jsonCount(directory:)` が 0。ディレクトリが読めない・JSON が読めないときは失敗）

### 4.4 `Tests/LLMAcceptance/` の構成

```swift
// AcceptanceFixture.swift
/// `Result` の Failure は `Error` でなければならない（`String` は使えない）ので、メッセージを包む。
struct AcceptanceError: Error, Equatable, Sendable, CustomStringConvertible, ExpressibleByStringInterpolation {
    let message: String
    init(stringLiteral value: String)
    var description: String { message }
}

struct AcceptanceFixture: Sendable {
    let id: String
    let dayDate: LocalDate
    let zone: ZonedTime
    let startedAt: Instant
    let segmentSeconds: Int
    let segments: [String]
    let maxTasksWithDue: Int
    var scalarCount: Int                    // segments の TextLimit.scalarCount の合計
    /// PLAN §5.6 の形。blocks は BlockComputer.blocks(…, gapSeconds: config.session.blockGapSeconds)。録音は 1 本として塊を求める。
    func transcript(gapSeconds: Int) -> SessionTranscript
    static func load(_ url: URL) -> Result<AcceptanceFixture, AcceptanceError>
    /// ディレクトリの *.json を id の昇順に読む（読めないものは Result の失敗にする）。
    static func loadAll(directory: URL) -> Result<[AcceptanceFixture], AcceptanceError>
    /// ディレクトリの *.json の数（読めなければ nil）。
    static func jsonCount(directory: URL) -> Int?
    /// 9 本から約 220,000 スカラーの 1 本を作る（§4.3）。
    static func longDay(_ base: [AcceptanceFixture]) -> AcceptanceFixture
    static let longTargetScalars = 220_000
    static let longID = "L01-longday"
    static let longStartedAt = "2026-08-29T07:00:00+09:00"
    static let longSegmentSeconds = 12
    static let longTimeZone = "Asia/Tokyo"
}

// AcceptanceHarness.swift
struct AcceptanceHarness {
    /// リポジトリの Resources と Vendor/build/bin（手順 1）。
    static var paths: AppPaths
    /// 手順 3 のモデルの場所（本番の <HOME> を読むだけ。ファイルが無ければ失敗）。報告の sha256 にも使う。
    static func modelURL(modelID: String, paths: AppPaths) -> Result<URL, AcceptanceError>
    /// llama-server を 1 回だけ起動し、10 本を順に流す。終わったら必ず stop する。
    static func run(modelID: String, fixtures: [AcceptanceFixture]) async -> Result<[AcceptanceRun], AcceptanceError>
}
struct AcceptanceRun: Sendable {
    let fixtureID: String
    let scalarCount: Int
    let maxTasksWithDue: Int  // fixture の expected.maxTasksWithDue（J3 の判定は runs だけを受け取るので、ここに持たせる）
    let outcome: AnalyzeOutcome
    let calls: Int            // 本体の要求（user が空でないもの）
    let repairedCalls: Int    // 修復が 1 回以上入った本体の要求
    let repairs: Int          // 修復の要求の総数
    let elapsed: Duration
}

/// 要求を数えながら本物の transport へ流す（T-19 §4.8: 修復の要求は user が空）。
final class CountingChatTransport: ChatTransport, Sendable {
    init(_ inner: any ChatTransport)
    func complete(system: String, user: String) async -> ChatResult
    /// 送った順の記録（true = 修復の要求）。
    func record() -> [Bool]
    /// 記録から (calls, repairedCalls, repairs) を数える（手順 7）。
    static func count(_ record: [Bool]) -> (calls: Int, repairedCalls: Int, repairs: Int)
}
```

`AcceptanceHarness.run` の手順:
1. `root = PackageRoot.url`、`paths = AppPaths(resources: root/"Resources", helpers: root/"Vendor/build/bin")`
2. `tmp = TempDirectory()`、`layout = HomeLayout(root: tmp.url)`、`layout.createDirectories()`
   （**本番の `<HOME>` に書かない**。llama-server の API キーは `tmp/run/llama-api-key` に出る）
3. モデルの場所: `prod = HomeLayout.production()`（**読むだけ**）。`catalog = ModelCatalog.load(Data(contentsOf: paths.modelCatalog))`。
   `catalog.entry(kind: .llm, id: modelID)` が在れば `ModelFiles.url(kind: .llm, entry:, layout: prod)`、無ければ `ModelFiles.customLLMURL(id: modelID, layout: prod)`。どちらも無ければ `.failure("モデル <id> が見つかりません")`
4. `config = AppConfig.defaults(timeZone: "Asia/Tokyo")`（既定値で走らせる。**利用者の config.json を読まない**）
5. `supervisor = LlamaServerSupervisor(runner: ProcessRunner(), paths: paths, layout: layout, clock: SystemClock(), sleeper: TaskSleeper(), log: AppLog(sink: CapturingLogSink(), level: .info, unsafeContent: false, zone:, clock:), factory: EphemeralSessionFactory())`
   `handle = await supervisor.ensureRunning(model: modelURL, modelID: modelID, config: config.llm)`。失敗なら `.failure(<StageFailure.message>)`
   終わったら（失敗でも）`await supervisor.stop()`（`defer` の中では `await` できないので、起動から手順 7 までを別の関数にし、その後で呼ぶ）
6. `prompts = try Prompts.load(directory: paths.promptsDirectory)`
7. 各 fixture について（**順に 1 本ずつ**。並行に投げない）:
   - `counting = CountingChatTransport(LoopbackChatTransport(endpoint: handle.endpoint, apiKey: handle.apiKey, modelID: handle.modelID, config: config.llm, factory: EphemeralSessionFactory()))`
   - `analyzer = Analyzer(transport: counting, prompts: prompts, config: config.llm)`
   - `clock = ContinuousClock()`、`start = clock.now`、`outcome = await analyzer.analyze(f.transcript(gapSeconds: config.session.blockGapSeconds))`、`elapsed = clock.now - start`
   - `record = counting.record()` から `calls`（`false` の数）・`repairs`（`true` の数）・`repairedCalls`（`false` の直後に `true` が 1 つ以上続く回数）を数える
8. `.success([AcceptanceRun])`

- **`EphemeralSessionFactory`（本番のファクトリ）を使う唯一のテスト**（127.0.0.1 の自分の llama-server に出る。PLAN §10.1 の遮断はループバックを止めない）
- `AnalyzeOutcome.success` を「Session が ANALYZED になれる」と読む（§8 の 2 を参照）

### 4.5 判定の式（`AcceptanceJudge.swift`）

```swift
struct AcceptanceVerdict: Equatable, Sendable {
    let analyzed: Int            // .success の本数
    let total: Int
    let calls: Int
    let repairFreeCalls: Int
    let repairFreeRate: Double   // calls == 0 なら 0.0
    let repairedRate: Double     // 最終的に通った本体の要求の割合
    let wikiLinkHits: [String]   // "[[" を含んだ (fixture, 場所)
    let badDue: [String]         // due の形が不正、または maxTasksWithDue を超えた fixture
    let longSeconds: Double
    var passed: Bool
}
enum AcceptanceJudge {
    static let repairFreeThreshold = 0.90
    static let longLimitSeconds: Double = 1_800      // 30 分（PLAN §10.6 の 4）
    static let duePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    static func judge(_ runs: [AcceptanceRun], longID: String) -> AcceptanceVerdict
    /// AnalysisResult の全文字列（title・summary・各配列の要素・tasks の text と due）。
    static func strings(_ r: AnalysisResult) -> [String]
}
```

`passed` = 次の 4 つがすべて真（PLAN §10.6 の 1〜4）:

| 判定 | 式 |
|---|---|
| J1 | `analyzed == total`（10 本すべてが `.success`） |
| J2 | `repairFreeRate >= 0.90` **かつ** `repairedRate == 1.0` |
| J3 | `wikiLinkHits.isEmpty` **かつ** `badDue.isEmpty` |
| J4 | `longSeconds <= 1_800` |

- `repairFreeRate = Double(calls - repairedCalls の合計) / Double(calls の合計)`。`repairedRate = Double(最終的に成功した本体の要求) / Double(calls)`（`.failure` で終わった本体の要求があれば 1.0 未満になり、J1 も落ちる）。
  最終的に成功した本体の要求 = `.success` の run は `calls`、`.failure` の run は `max(0, calls - 1)`（`Analyzer` は最初の失敗で止まるので、落ちたのは最後の 1 要求）。`calls == 0` なら 0.0
- `wikiLinkHits`: `strings(result)` と `partials` の全文字列のどれかがスカラー列として `[[` を含めば、`"<fixtureID>: <先頭 40 スカラー>"` を入れる
- `badDue`: `tasks` の `due` が `nil` でなく `duePattern` に一致しない、または `due != nil` の数が `fixture.maxTasksWithDue` を超える
- `longSeconds` = `longID` の `elapsed` を秒にしたもの（`Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18`）。`longID` の run が無ければ `+∞`（J4 を落とす）
- `passed` と J1〜J4 は `AcceptanceVerdict` の計算プロパティ（`j1`〜`j4`。報告の判定の表にも使う）
- **時間の判定は長文 1 本だけ**（9 本の合計は見ない）

### 4.6 `TestEnvironment` への追加（`Tests/TestSupport/TestEnvironment+LLMAcceptance.swift`）

```swift
// LLM 受け入れ試験の環境変数（PLAN §10.1。環境変数を読むのは TestEnvironment だけ。PT-18）。
extension TestEnvironment {
    /// `VOICEDOCK_LLM_FIXTURES`。無ければ `<パッケージ>/Tests/Fixtures/llm-acceptance`。
    public static var llmFixtureDirectory: URL
    /// `VOICEDOCK_LLM_REPORT`。無ければ `NSTemporaryDirectory()/llm-acceptance-<model>.md`。
    public static func llmReportURL(model: String) -> URL
}
```

環境変数は `TestEnvironment.value(_:)`（T-01。internal）を通して読む。`ProcessInfo` を直接読まない（PLAN §10.1「環境変数は `Tests/TestSupport/TestEnvironment.swift` だけが読む」）。
`model` はファイル名に使う前に `[A-Za-z0-9._-]` 以外を `_` に置き換える。

### 4.7 `Makefile` と `.gitignore`

```make
LLM_REPORT ?= $(CURDIR)/llm-acceptance-$(MODEL).md

llm-acceptance: build
	@test -n "$(MODEL)" || { echo "ERROR: MODEL=<モデルの ID> を指定してください" >&2; exit 1; }
	VOICEDOCK_LLM_MODEL="$(MODEL)" VOICEDOCK_LLM_REPORT="$(LLM_REPORT)" $(SWIFT) test --skip-build --filter LLMAcceptance
	@echo "報告: $(LLM_REPORT)（docs/POC.md 章 15 に貼る）"

# 受け入れ試験の自前の部品だけ（モデルも llama-server も要らない）
acceptance-selftest: build
	$(SWIFT) test --skip-build --filter "AcceptanceJudgeTests|AcceptanceFixtureLoaderTests"
```
`.PHONY` に `acceptance-selftest` を足す。`.gitignore` に `/llm-acceptance-*.md` を足す。

### 4.8 `docs/POC.md` 章 15 の書式

目次の表（P0 の §0 の下）に 1 行足す:

```markdown
| 15 | — | LLM 受け入れ試験（10 本・修復率・220,000 文字の時間） | PLAN §8.10・§10.6、T-24 | ⬜ |
```

章の本体（`AcceptanceReport.render(...)` が同じ形の Markdown を作り、それを貼る）:

```swift
// AcceptanceReport.swift
struct AcceptanceReportContext: Sendable {
    let date: String          // yyyy-MM-dd
    let modelID: String
    let file: String
    let sha256: String        // FileHasher.sha256(of:chunkBytes: 1_048_576)
    let machine: String       // sysctl machdep.cpu.brand_string
    let memoryBytes: UInt64   // sysctl hw.memsize
    let llamaRef: String      // Vendor/versions.env の LLAMA_CPP_REF
}
enum AcceptanceReport {
    static func context(modelID: String, modelURL: URL, date: String) -> AcceptanceReportContext
    /// 15.1 は scripts/check-catalog.sh の出力を人が貼るので、`<出力をそのまま>` と `⬜ 未実施` のまま出す。
    static func render(_ c: AcceptanceReportContext, runs: [AcceptanceRun], verdict: AcceptanceVerdict) -> String
}
```

````markdown
## 15. LLM 受け入れ試験（PLAN §10.6）

測定日 **<yyyy-MM-dd>**。参照機は章 1 の機種。

### 15.1 カタログの再確認

`scripts/check-catalog.sh` の生の出力:

```text
<出力をそのまま>
```

判定: ✅ PASS（MISMATCH なし）／✗ FAIL（直した項目を書く）

### 15.2 受け入れ試験

| 項目 | 値 |
|---|---|
| モデル | `<id>` |
| ファイル | `<file>` |
| sha256 | `<64 桁>`（`FileHasher.sha256(of:chunkBytes: 1_048_576)` の実測） |
| 機種 / メモリ | `<machdep.cpu.brand_string>` / `<hw.memsize>` |
| llama.cpp | `<LLAMA_CPP_REF>`（`Vendor/versions.env`） |
| コマンド | `make llm-acceptance MODEL=<id>` |

| fixture | 文字数 | 結果 | 本体の要求 | 修復の入った要求 | 所要 |
|---|---|---|---|---|---|
| s01-standup | 5,012 | success | 1 | 0 | 8.2 s |
| …（10 行） | | | | | |

| 判定 | 基準 | 実測 | 結果 |
|---|---|---|---|
| J1 ANALYZED | 10 / 10 | <n> | ✅ / ✗ |
| J2 修復なしの割合 | ≥ 90% | <x>% | ✅ / ✗ |
| J2 修復込みの割合 | 100% | <x>% | ✅ / ✗ |
| J3 `[[` と due | 0 件 | <n> 件 | ✅ / ✗ |
| J4 220,000 文字 | ≤ 30 分 | <x> 分 | ✅ / ✗ |

判定: ✅ PASS → `Resources/ModelCatalog.json` の `<id>` を `verified: true` にした（コミット `<sha>`）
````

記録の規約（POC.md §0）に従う: **コマンドと生の出力をそのまま**貼り、判定を `✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外` で始める。

## 5. テスト

`Tests/LLMAcceptance/` は `import Testing`、`import VDCore`、`import VDContract`、`import VDLLM`、`import TestSupport`（**`VDModels` は import しない**。`LLMAcceptance` の依存は T-01 の `VDPipeline` / `VDLLM` / `TestSupport` のまま）。
`AcceptanceHarness.swift` だけは `ProcessRunner` のために `import VDProcess`（`VDPipeline` の依存として見える）と、`CountingChatTransport` の `Mutex` のために `import Synchronization` を足す。`AcceptanceReport.swift` は `sysctlbyname` のために `import Darwin`。

### 5.1 `AnalysisAcceptanceTests.swift`（`@Suite("LLM 受け入れ試験", .serialized)`）

すべて `.enabled(if: TestEnvironment.llmModel != nil)`、`.tags(.realTools, .slow)`。スイート全体で **llama-server を 1 回だけ**起動するため、`static let runs` を `Task` で 1 回だけ作る（`@Suite` の `init` で `AcceptanceHarness.run` を呼び、10 本ぶんの結果を持つ）。
`static let runs = Task<AcceptanceSession?, Never> { await AcceptanceSession.make() }`。`AcceptanceSession`（同じファイル）は `modelID`・`runs: Result<[AcceptanceRun], AcceptanceError>`・`verdict` を持ち、`fixtures()` で §4.3 の 10 本（`llmFixtureDirectory` の *.json を id の昇順・9 本に満たなければ合成の fixture で埋める・最後に `longDay`）を組む。§5.2 も同じ `AnalysisAcceptanceTests.runs` を待つ（起動は 1 回）。

| 関数名 / 表示名 | 期待 |
|---|---|
| `allFixturesAreAnalyzed` / 「10 本すべてが解析できる（§10.6-1）」 | `verdict.analyzed == verdict.total`、失敗した fixture の ID と `StageFailure.message` を `#expect` の説明に出す |
| `repairFreeRateIsAtLeast90` / 「修復なしで 90% 以上（§10.6-2）」 | `verdict.repairFreeRate >= 0.90` |
| `everyCallEventuallyValidates` / 「修復込みで 100%（§10.6-2）」 | `verdict.repairedRate == 1.0` |
| `noWikiLinksInOutput` / 「出力に `[[` が無い（§10.6-3）」 | `verdict.wikiLinkHits.isEmpty` |
| `dueIsNullWithoutADate` / 「期限の無い task の due は null（§10.6-3）」 | `verdict.badDue.isEmpty` |
| `reportIsWritten` / 「報告を書き出す」 | `TestEnvironment.llmReportURL(model:)` に §4.8 の Markdown が在る（最後に走らせるため関数名の順に注意し、`.serialized` の最後に置く） |

### 5.2 `LongTranscriptAcceptanceTests.swift`（`@Suite("220,000 文字の Map-Reduce", .serialized)`）

| 関数名 / 表示名 | 期待 |
|---|---|
| `longDayFitsIn30Minutes` / 「220,000 文字が 30 分以内（§10.6-4）」 | `verdict.longSeconds <= 1_800`、`AnalyzeOutcome` が `.success`、`chunks.count >= 2`（Map-Reduce に入っている） |

### 5.3 `AcceptanceJudgeTests.swift` / `AcceptanceFixtureLoaderTests.swift`（**モデル不要**）

`AcceptanceJudgeTests`（`AcceptanceRun` を手で組み立てる。LLM を呼ばない）:

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `passesWhenEverythingIsClean` | 10 本 success・修復 0・長文 600 秒 | `passed`、`repairFreeRate == 1.0` |
| `rateIsExactlyAtTheThreshold` | 10 本のうち 1 本に修復 1 回（本体 10 要求） | `repairFreeRate == 0.9`、`passed` |
| `justBelowTheThresholdFails` | 20 要求のうち 3 要求に修復 | `repairFreeRate == 0.85`、`passed == false` |
| `oneFailureBreaksBoth` | 1 本が `.failure` | `analyzed == 9`、`repairedRate < 1.0`、`passed == false` |
| `wikiLinkIsFound` | `summary` に `これは [[別のノート]] です` | `wikiLinkHits.count == 1`、`passed == false` |
| `wikiLinkInPartialsIsFound` | partials の `key_points` に `[[x]]` | 同上 |
| `badDueFormatFails` | `due = "2026/09/05"` | `badDue.count == 1` |
| `tooManyDuesFail` | `maxTasksWithDue = 0` の fixture で `due = "2026-09-05"` | `badDue.count == 1` |
| `nullDueIsFine` | すべて `due = nil` | `badDue.isEmpty` |
| `justOver30MinutesFails` | 長文 1,801 秒 | `passed == false` |
| `emptyRunsDoNotCrash` | `[]`（TEST-28） | `analyzed == 0`、`repairFreeRate == 0.0`、`passed == false` |

`AcceptanceFixtureLoaderTests`:

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `loadsTheNineFixtures` | 既定のディレクトリ | 9 本、`id` が §4.3 の表と同じ・昇順 |
| `segmentsBecomeAbsoluteTimes` | `s01` | 最初の `AbsoluteSegment.at` が `startedAt`、i 番目が `startedAt + i × segmentSeconds`、`endAt - at == segmentSeconds × 1000` |
| `longDayIsDeterministic` | `longDay` を 2 回と、入力を逆順にして 1 回 | 3 つとも同じ `segments`、先頭が 9 本を §4.3 の表の `id` の順に連結したもの、`scalarCount >= 220_000` かつ `< 220_000 + 200` |
| `longDayCountsDues` | `longDay` | `maxTasksWithDue == 18`（9 本の合計 1+0+1+2+3+0+0+0+2 = 9 × 繰り返し 2 回。9 本で約 201,000 スカラー） |
| `longDayKeepsWholeSegments` | `longDay` | どの要素も元の 9 本のどれかの要素と**完全に一致**（途中で切らない） |
| `badJSONIsAnError` | キーが足りない JSON | `.failure`、メッセージにファイル名が入る |
| `emptyDirectoryIsAnError` | 空のディレクトリ（TEST-28） | `.failure` |

### 5.4 `Tests/PolicyTests/AcceptanceFixturesTests.swift`（**CI で走る**）

`PackageRoot.url/Tests/Fixtures/llm-acceptance` を直接読む（`LLMAcceptance` を import しない。JSON は `PyJSON.decode` ではなく `JSONSerialization` でよい。資源の検査なので）。

| 関数名 / 表示名 | 期待 |
|---|---|
| `nineFixturesExist` | §4.3 の 9 つの `id` の `.json` が在る（ほかのファイルが無い） |
| `eachFixtureHasTheRequiredKeys` | `id`・`dayDate`・`timeZone`・`startedAt`・`segmentSeconds`・`segments`・`expected.maxTasksWithDue` が在り、`id` がファイル名と一致 |
| `scalarCountsAreInRange` | 合計が §4.3 の目安の ±20% に収まる |
| `segmentsAreSentences` | 各要素が 10〜200 スカラー、空でない、末尾が `。` `？` `！` のどれか |
| `noWikiLinkMarkersInFixtures` | どの要素にも `[[` と `]]` が無い |
| `noObviousPersonalData` | `@` を含む要素が無い、`0[0-9]{1,3}-[0-9]{2,4}-[0-9]{4}` に一致する部分が無い |
| `deadlinesOnlyInDatedSegments` | 日付（`[0-9]+月[0-9]+日`）を含まない要素に §4.3 の期限として読める語と「までに」（`(?<!ここ)(?<!ところ)までに`）が無い。日付を含む要素の数が `maxTasksWithDue` と等しい |
| `startedAtParses` | `ZonedTime(timeZone: TimeZone(identifier: timeZone)!).parseISO(startedAt)` が nil でなく、`dayDate` と同じ日 |

## 6. 破壊による証明

| 壊し方（1 か所だけ） | 落ちるべきテスト | 走らせ方 |
|---|---|---|
| `AcceptanceJudge.repairFreeThreshold` を 0.8 にする | `justBelowTheThresholdFails` | `make acceptance-selftest` |
| `repairFreeRate` の分母を「修復を含む全要求」にする | `rateIsExactlyAtTheThreshold` | 同上 |
| `judge` で `partials` を見ない | `wikiLinkInPartialsIsFound` | 同上 |
| `duePattern` を `.*` にする | `badDueFormatFails` | 同上 |
| `maxTasksWithDue` の比較を消す | `tooManyDuesFail` | 同上 |
| `longLimitSeconds` を 3,600 にする | `justOver30MinutesFails` | 同上 |
| `longDay` で最後の要素を切り詰める | `longDayKeepsWholeSegments` | 同上 |
| `longDay` の連結の順を `Set` にする | `longDayIsDeterministic` | 同上 |
| `s05-planning.json` に `[[テスト]]` を 1 か所入れる | `noWikiLinkMarkersInFixtures` | `make test-policy` |
| `s07-field-note.json` の要素に「明日の朝に出す」を入れる | `deadlinesOnlyInDatedSegments` | `make test-policy` |
| `s01-standup.json` の `id` を変える | `eachFixtureHasTheRequiredKeys`（`nineFixturesExist` はファイル名を見るので落ちない。ファイル名を変えたときに落ちる） | 同上 |
| `Resources/ModelCatalog.json` の sha256 を 1 文字変える | `scripts/check-catalog.sh` が `MISMATCH` で終了コード 1（出力を PR に貼る） | 手で |

## 7. 受け入れ条件

- [ ] `scripts/check-catalog.sh` の生の出力を `docs/POC.md` 章 15.1 に貼り、`MISMATCH` が無い（または直した）
- [ ] `Resources/ModelCatalog.json` の 4 項目が §4.1 の表と一致し、T-09 の `bundledCatalogLoads` / `bundledURLsArePinned` が緑
- [ ] LLM のうち**少なくとも 1 つ**が `verified: true`。`true` にしたものは §4.5 の 4 判定にすべて合格している（→ 利用者の決定で別の PR。§4.2 の注記）
- [ ] 9 本の fixture が `Tests/Fixtures/llm-acceptance/` に在り、`make test-policy` が緑
- [ ] `make acceptance-selftest` が緑（モデルが無くても走る）
- [ ] `make llm-acceptance MODEL=<id>` が緑で、報告が `docs/POC.md` 章 15.2 に貼られている（機種・メモリ・llama.cpp の版・モデルの sha256 を含む）
- [ ] 受け入れ試験は**本番の `<HOME>` に何も書かない**（`TempDirectory` の `HomeLayout` を使い、モデルのファイルは読むだけ）
- [ ] `make test`（CI と同じ）で `LLMAcceptance` が 1 本も走らない
- [ ] 破壊による証明の各項目で、表のテストが落ちることを確かめ、PR 本文に貼った

## 8. API 地図への変更提案

1. 00-api-map §15 に `AcceptanceFixture` / `AcceptanceHarness` / `AcceptanceJudge` / `CountingChatTransport`（作り手 T-24、`Tests/LLMAcceptance/` 内。TestSupport には置かない）と、`TestEnvironment` への追加（`llmFixtureDirectory`・`llmReportURL(model:)`。作り手は T-01、extension は T-24）を足す → 00-api-map §15 に反映済み（整合修正 M-9。Acceptance の一式は `Tests/LLMAcceptance/` に置き、TestSupport に置くのは `TestEnvironment` の extension だけ）
2. **仕様の読み替え**（PLAN §10.6 の 1）: 「10 セッション分の transcript fixture をすべて ANALYZED にできる」を `Analyzer.analyze` が `.success` を返すことで判定する。`LLMAcceptance` ターゲットは `VDPipelineTests`（`PipelineWorld`・`installVault` など）を import できず、DB と Vault を組むと試験がモデルの品質以外で落ちるため。Session の遷移そのものは T-22 / T-29 が偽物で確かめている
3. `Analyzer` は修復の回数を返さない（`AnalyzeOutcome` に無い）。本チケットは `CountingChatTransport` で要求の列から数える（修復の要求は `user == ""`。T-19 §4.8）。`AnalyzeOutcome` に `repairs` を足す案は採らない（本番のコードを試験のために変えない）
4. `LlamaServerSupervisor` を**本番のファクトリ**（`EphemeralSessionFactory`）で使う唯一のテストであることを 00-api-map §14 の `LLMAcceptance` の行に注記する
5. （実装で追加）00-api-map §15 の T-24 の行に、同じ `Tests/LLMAcceptance/` 内の補助の型 `AcceptanceError`（`Result` の Failure。`String` は `Error` でないため）・`AcceptanceRun`・`AcceptanceVerdict`・`AcceptanceReportContext`・`AcceptanceSession` を足す。どれも internal で、ほかのターゲットからは使わない（実装に不可欠ではない。索引の網羅のため）
6. （実装で追加）CI に `make acceptance-selftest` を足す。いまの `make test` は `--skip "…|LLMAcceptance"` でターゲットごと外すので、判定の式と fixture の読み込みの自己テスト（モデル不要）も CI で走らない（`.github/workflows/` と `Makefile` の `test` は T-02 / T-01 の持ち物なので、本チケットでは変えない）

## 9. SPEC の変更

なし（受け入れ試験は規範の表を持たない。結果は `docs/POC.md`）

## 10. マージ後にやること

- **【利用者が行う】受け入れ試験（docs/POC.md 章 15 の手順 1〜5）を行い、合格した LLM を `verified: true` にするカタログだけの PR を出す。v1.0（T-44）の前に必ず**

- `verified: false` のまま残った LLM は一覧に出ない。後で合格したら**カタログだけ**を直す PR を出し、そのときも章 15 に追記する（測定日・機種・sha256 を必ず書く）
- T-31 は `ModelCatalog.listedLLMs` だけを一覧に出す（`verified` を見ない実装にしない）
- 参照機を変えたら J4 の実測が変わる。章 15 に**機種を必ず書く**（PLAN §10.6 の 4「参照機で 30 分以内」）
