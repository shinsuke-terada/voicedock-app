# T-27 VDNotes: Daily ノート・警告行・Timeline・Vault 索引・リンク計画

| 項目 | 内容 |
|---|---|
| ID | T-27 |
| Phase | 6（ノート） |
| 前提 | T-26（Sanitize・NoteTemplate・Frontmatter・PyStr・ScalarText・RawNote）。T-08（PartStatus・ErrorCode・SkipReasons）、T-09（AppConfig・`GoldenConfig`）、T-10（Instant・ZonedTime・ISOWallClock・LocalDate・SessionTranscript）、T-45（PyText・`PyJSON.decode`）、T-25（golden）は T-26 の前提に含まれる |
| 見積もり | 本体 約 550 行、テスト 約 650 行（golden を除く） |

## 1. 目的

Daily ノート（整理済みのノート）の本文・frontmatter・警告行・Timeline・WikiLink を、voicedock@d3d595e と**バイト単位で同じ出力**になるように作る。
Timeline の保存形式（`<slug>.timeline.json`）の符号化と読み戻し、Vault 索引の構築、リンク計画もここで作る。ファイルへの書き込み・状態遷移は T-22 / T-29 が行う。

## 2. 参照

- PLAN §8.6（Daily ノート・警告行・Timeline・WikiLink）、§5.7、§8.5（指紋）、付録 C NOTE-05 / NOTE-10 / NOTE-11、付録 D X-15
- voicedock@d3d595e: `src/voicedock/daily.py:37-521`、`src/voicedock/wiki.py:28-310`、`src/voicedock/pipeline.py:1336-1400`（`_render_daily` / `_plan_links`）
- voicedock のテスト: `tests/unit/test_daily_render.py`、`tests/unit/test_wikilink.py`
- 00-api-map.md §9（`DailyNote` / `DailyWarnings` / `Timeline` / `VaultIndex` / `LinkPlanner`）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDNotes/DailyNote.swift` | `DailyInput`、`AnalysisView`、`ExcludedPart`、`DailyNote` |
| `Sources/VDNotes/Warnings.swift` | `DailyWarnings` |
| `Sources/VDNotes/Timeline.swift` | `TimelineBlock`、`Timeline` |
| `Sources/VDNotes/VaultIndex.swift` | `VaultIndex` |
| `Sources/VDNotes/LinkPlanner.swift` | `LinkPlan`、`LinkPlanner` |
| `Tests/VDNotesTests/DailyNoteTests.swift` | 本文・frontmatter の固定例 |
| `Tests/VDNotesTests/DailyWarningsTests.swift` | 警告行 |
| `Tests/VDNotesTests/TimelineTests.swift` | build・sentences・encode・decode |
| `Tests/VDNotesTests/VaultIndexTests.swift` | 索引 |
| `Tests/VDNotesTests/LinkPlannerTests.swift` | リンク計画 |
| `Tests/VDNotesTests/DailyNoteGoldenTests.swift` | golden とのバイト比較 |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 17 キーを消す（§5.7） |

## 4. 仕様

T-26 の「4.0 全体の規則」（スカラー単位・PyText・LF）をそのまま適用する。

### 4.1 `DailyNote.swift`

```swift
// Daily ノート（整理済み）の描画（PLAN §8.6。voicedock daily.py:189-369 とバイト一致）。
public struct AnalysisView: Sendable {
    public let title: String?
    public let summary: String?
    public let keyPoints: [String]?     // nil = その節が無い（無効な節）。空配列 = 何も無い
    public let decisions: [String]?
    public let ideas: [String]?
    public let tags: [String]?
    public let tasks: [(text: String, due: String?)]?
    public init(title: String?, summary: String?, keyPoints: [String]?, decisions: [String]?, ideas: [String]?, tags: [String]?, tasks: [(text: String, due: String?)]?)
}

public struct ExcludedPart: Sendable {
    public let partkey: String
    public let status: PartStatus          // FAILED か SKIPPED
    public let errorCode: ErrorCode?       // 既知のコード
    public let unknownCode: String?        // DB の error_code が ErrorCode に無い文字列のとき（errorCode は nil）
    public init(partkey: String, status: PartStatus, errorCode: ErrorCode?, unknownCode: String?)
    /// 理由の鍵: errorCode?.rawValue ?? unknownCode ?? ""（空文字も ""）
    var reasonKey: String { get }
}

public struct DailyInput: Sendable {
    public let analysis: AnalysisView
    public let day: LocalDate
    public let sessionKey: String
    public let recordingKeys: [String]     // included（FAILED / SKIPPED 以外）の partkey を started_at, partkey 順
    public let excluded: [ExcludedPart]    // FAILED / SKIPPED の Part を started_at, partkey 順
    public let recordedSeconds: Double?    // sessions.recorded_seconds（除外 Part も含む）
    public let blockCount: Int             // included で算出した Block の数
    public let timeline: [TimelineBlock]
    public let links: LinkPlan
    public let zone: ZonedTime             // Timeline の見出しの時刻に使う
    public init(…全フィールド…)
}

public enum DailyNote {
    public static let noteType = "voice-daily"
    public static let statusProcessed = "processed"
    public static let dueMark = "📅"                       // U+1F4C5
    public static let defaultSummaryHeading = "## Summary"
    public static func render(_ input: DailyInput, config: AppConfig) -> String
    public static func baseName(config: ObsidianConfig, day: LocalDate) -> String
    public static func folder(config: ObsidianConfig, day: LocalDate) -> String
    public static func tags(analysisTags: [String]?, defaults: [String]) -> [String]
    public static func recorded(_ seconds: Double?) -> String
    /// DN-8 の見出し: sections.summary.heading が nil か空でなければそれ、でなければ "## Summary"
    public static func summaryHeading(config: AppConfig) -> String
    /// `## Sources` のリンク先: raw_output_path の basename から ".md" を除いたもの。nil なら RawNote.baseName（X-15）
    public static func rawLinkName(rawOutputPath: String?, config: ObsidianConfig, day: LocalDate) -> String
}
```

- `DailyInput` に `zone` を足した（Timeline の `HH:MM` を作るため。§10 の提案）

**`baseName`** = `Sanitize.fileName(NoteTemplate.render(config.wiki.filenameTemplate, day: day), maxBytes: config.maxTitleBytes)`（既定 `2026-08-29 Voice`）
**`folder`** = `NoteTemplate.render(config.wiki.folderTemplate, day: day)`（既定 `Daily/Voice/Wiki/20260829`）

**`rawLinkName`**: `rawOutputPath` が nil なら `RawNote.baseName(config:day:)`。そうでなければ最後の `/` より後（`/` が無ければ全体）を取り、スカラー列が `.md` で終われば取り除く
（例 `Daily/Voice/Raw/20260829/2026-08-29 raw (2).md` → `2026-08-29 raw (2)`。voicedock は常に基本名だった。X-15）

**`recorded(seconds)`**（daily.py:364-369）: nil・負・`isFinite` でない → `"00:00:00"`。そうでなければ `t = Int(seconds)`（0 方向へ切り捨て）、
`String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)`（時は 2 桁を超えうる: `90061.7` → `25:01:01`、`34880.9` → `09:41:20`）

**`tags(analysisTags:defaults:)`**（daily.py:343-361）:
```text
values = defaults + (analysisTags ?? [])
seen = Set<String>(); kept = []
for v in values:
  cleaned = PyText.strip(v)、その後 U+0020 と U+3000 のスカラーを "-" に置換（この 2 つだけ）
  if cleaned.isEmpty { continue }
  k = PyText.casefold(cleaned); if seen.contains(k) { continue }
  seen.insert(k); kept.append(cleaned)
return kept
```
- sanitize は通さない。例: `defaults ["voice","voicedock"]`、tags `["VoiceDock","DJI Mic","a: b","c \"d\"","e\\f","  ","全角\u{3000}空白"]` →
  `["voice","voicedock","DJI-Mic","a:-b","c-\"d\"","e\\f","全角-空白"]`（`VoiceDock` は `voicedock` と casefold で重なるので落ちる）

**`summaryHeading(config:)`**: `config.llm.analysis.sections.summary.heading` が nil でなく空でなければそれ、でなければ `"## Summary"`

**`render(input, config)`** の手順:
1. `failed = excluded.filter { $0.status == .failed }`、`skipped = excluded.filter { $0.status != .failed }`（順序は保つ）
2. frontmatter（この順。`Frontmatter.render`）:
   ```swift
   [(Frontmatter.keyType, .string(DailyNote.noteType)),
    (Frontmatter.keySessionKey, .string(sessionKey)),
    (Frontmatter.keyRecordingKeys, .array(recordingKeys)),
    (Frontmatter.keyFailedParts, .array(failed.map(\.partkey))),
    (Frontmatter.keySkippedParts, .array(skipped.map(\.partkey))),
    ("date", .string(day.dashed)),
    ("recorded", .string(recorded(recordedSeconds))),
    ("parts", .int(recordingKeys.count)),
    ("blocks", .int(blockCount)),
    ("status", .string(DailyNote.statusProcessed)),
    ("tags", .array(tags(analysisTags: analysis.tags, defaults: config.obsidian.defaultTags)))]
   ```
3. `title = (analysis.title が nil でなく空でない) ? analysis.title! : day.dashed`（strip しない）。`lines = ["", "# " + title, ""]`
4. `for w in DailyWarnings.lines(failed: failed, skipped: skipped) { lines += [w, ""] }`
5. `for name in config.llm.analysis.order`:
   - `sec = config.llm.analysis.sections.section(named: name)`。nil か `!sec.enabled` なら次へ
   - `heading = (sec.heading が nil でなく空でない) ? sec.heading! : "## " + name`
   - `rendered = (name == "timeline") ? timelineLines(timeline, zone) : sectionLines(name, analysis)`
   - `rendered` が空なら次へ（見出しごと省く）。そうでなければ `lines += [heading, ""] + rendered`
6. `lines += sourcesLines(links) + linksLines(links)`
7. `body = ScalarText.trimTrailingLF(lines.joined(separator: "\n")) + "\n"`、返り値 `frontmatter + Frontmatter.escapeBody(body)`

`sectionLines(name, a)`:
| name | 結果 |
|---|---|
| `"summary"` | `t = PyText.strip(a.summary ?? "")`。空なら `[]`、でなければ `[t, ""]` |
| `"tasks"` | `a.tasks` が nil か空なら `[]`。そうでなければ各 task を `"- [ ] " + text + ((due が nil でなく空でない) ? " 📅 " + due! : "")` にし、最後に `""` |
| `"key_points"` / `"decisions"` / `"ideas"` / `"tags"` | 対応する配列が nil か空なら `[]`。そうでなければ各要素を `"- " + 要素`（strip しない）にし、最後に `""` |
| それ以外 | `[]` |

`timelineLines(blocks, zone)`: 各ブロックについて `["### " + hhmm(start) + "–" + hhmm(end), ""] + lines.map { "- " + $0 } + [""]` を順につなぐ（`–` は U+2013）。
`hhmm(i) = ISOWallClock.hhmm(zone.iso(i)) ?? ""`（**設定のタイムゾーンの規則で描く**。夏時間の切り替えをまたぐと voicedock（Part の固定オフセット）と違う値になる。夏時間の無い地域では一致。PLAN §5.7・X-32。Raw の見出しは固定オフセット（T-26）で、ここは違う）。

`sourcesLines(links)`: `links.raw` が空なら `[]`、でなければ `["## Sources", ""] + links.raw.map { "- " + $0 } + [""]`

`linksLines(links)`: `values = [links.dailyNote].compactMap { $0 }.filter { !$0.isEmpty } + links.adjacent.filter { !$0.isEmpty } + links.tags.filter { ScalarText.hasPrefix($0, "[[") }`。
空なら `[]`、でなければ `["## Links", ""] + values.map { "- " + $0 } + [""]`

- **Timeline は `order` の中の 1 節**（既定では summary の次）
- 文言・記号の逐語: `📅` は U+1F4C5、`–` は U+2013

### 4.2 `Warnings.swift`

```swift
// Daily ノートの警告行（PLAN §8.6 / NOTE-05。voicedock daily.py:300-340）。欠落を隠さない。SKIPPED に「再試行されます」と書かない。
public enum DailyWarnings {
    public static let failedLineTemplate: String    // 下の逐語
    public static let retryAction = "デバイスから採り直してください。"
    public static func lines(failed: [ExcludedPart], skipped: [ExcludedPart]) -> [String]
    public static func displayName(_ code: ErrorCode?) -> String
    /// 理由の鍵（ExcludedPart.reasonKey）から表示名へ
    static func displayName(reasonKey: String) -> String
    /// 理由の鍵の集合を並べる（宣言順、同順位は鍵のスカラー値の辞書順）
    static func orderedReasonKeys(_ keys: Set<String>) -> [String]
}
```

`lines` の手順:
1. `out = []`
2. `failed` が空でなければ: `"> ⚠ この日の録音のうち \(failed.count) 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。"`（`⚠` は U+26A0、その後に半角空白）
3. `skipped` が空でなければ:
   - `actionable = skipped.contains { $0.errorCode == nil || !SkipReasons.benign.contains($0.errorCode!) }`（未知のコード・理由なしは操作が要る側）
   - `mark = actionable ? "⚠ " : ""`、`action = actionable ? retryAction : ""`
   - `reasons = orderedReasonKeys(Set(skipped.map(\.reasonKey))).map(displayName(reasonKey:)).joined(separator: "・")`（`・` は U+30FB。表示名の重複は除かない）
   - `"> " + mark + "この日の録音のうち \(skipped.count) 本を除外しました（" + reasons + "）。自動では再試行されません。" + action`（括弧は全角）
4. 最大 2 行

`orderedReasonKeys`: 各鍵の順位 = `ErrorCode(rawValue: key)?.declarationIndex ?? Int.max`（未知・空は末尾）。順位の昇順、同じ順位は `Array(key.unicodeScalars.map(\.value))` の辞書順（voicedock は集合の順で非決定だった。PLAN §8.6）。

`displayName(reasonKey:)`: `"DUPLICATE_CONTENT"`→`重複`、`"SOURCE_MISSING"`→`元ファイルが見つかりません`、`"NORMALIZED_MISSING"`→`元ファイルが見つかりません`、`"NO_SPEECH_DETECTED"`→`無音`、
それ以外で空でなければ鍵そのもの（コード名のまま）、空なら `理由不明`。
`displayName(_ code: ErrorCode?)` は `displayName(reasonKey: code?.rawValue ?? "")`。
（コード名の文字列を書いてよいのは `ErrorCode.swift` だけなので（PT-06）、表は `[ErrorCode: String]`（`.duplicateContent: "重複"` など）で持ち、`ErrorCode(rawValue:)` で引く）

### 4.3 `Timeline.swift`

```swift
// Timeline の組み立て・保存形式（PLAN §8.6。voicedock daily.py:88-183, 440-521）。時刻は LLM に作らせない。
public struct TimelineBlock: Equatable, Sendable {
    public let start: Instant
    public let end: Instant
    public let lines: [String]
    public init(start: Instant, end: Instant, lines: [String])
}

public enum Timeline {
    public static let schema = 2
    public static func build(partials: [AnalysisView], chunks: [(start: Instant, end: Instant)], transcript: SessionTranscript, summary: String?) -> [TimelineBlock]
    public static func sentences(_ text: String) -> [String]
    public static func encode(_ blocks: [TimelineBlock], fingerprint: String, zone: ZonedTime) -> Data
    public static func decode(_ data: Data, fingerprint: String, zone: ZonedTime) -> [TimelineBlock]
}
```

**`build`**（daily.py:125-161）:
1. `partials` と `chunks` が**両方とも空でなければ**: 2 つを先頭から組にし（短い方で打ち切り）、各組の `points(partial)` が空でないものだけ `TimelineBlock(start: chunk.start, end: chunk.end, lines: points)` にして返す
   - `points(p)`: `p.keyPoints` が nil でなく空でなければそれ、でなければ `sentences(p.summary ?? "")`
2. そうでなければ（単一パス・代替経路）: `s = sentences(summary ?? "")`。空なら `[]`
   - `blocks = transcript.blocks`。空なら、`transcript.segments` が空でなければ `[TimeBlock(start: segments[0].at, end: segments の endAt の最大)]`、segments も空なら `[]`
   - 各 block に**同じ `s` を付けて**返す

**`sentences(text)`**: `text` の `。` の直後にそれぞれ `\n` を入れる（`replacingOccurrences(of: "。", with: "。\n")`）→ `PyText.splitLines` → 各行を `PyText.strip` → 空を捨てる。
例 `"A。B。 C"` → `["A。","B。","C"]`、`"一文目。二文目。\n三文目 。 \n\n四"` → `["一文目。","二文目。","三文目 。","四"]`

**`encode`**（daily.py:449-482。書き込みは呼び手が `AtomicFile` で行い、失敗しても失敗にしない）:
```swift
PyJSON.fileData(.object([
  ("schema", .int(2)),
  ("transcript_sha256", .string(fingerprint)),
  ("blocks", .array(blocks.map { .object([("start_at", .string(zone.iso($0.start))), ("end_at", .string(zone.iso($0.end))), ("lines", .array($0.lines.map { .string($0) }))]) }))
]))
```
（indent 2 ＋ 末尾改行。キーはこの順）

**`decode`**（daily.py:485-521。読み取りは `PyJSON.decode`（T-45）。`JSONSerialization` を使わない。PLAN §5.7・F-45）:
1. `PyJSON.decode(data)` が `.object(top)` でなければ `[]`（不正な UTF-8・JSON でない・配列を含む）
2. `member(top, "schema")` が `.int(2)` か `.double(2.0)` でなければ `[]`（`2.0` も 2 として受ける。Python の `!=` と同じ。`.bool` は数として受けない）
3. `member(top, "transcript_sha256")` が `.string(s)` で `PyText.scalarsEqual(s, fingerprint)` でなければ `[]`
4. `member(top, "blocks")` が `.array(items)` でなければ `[]`
5. 各要素: `.object(o)` でない → 飛ばす。`member(o, "start_at")` / `member(o, "end_at")` が `.string` で `zone.parseISO` が nil でない、でなければ飛ばす。`member(o, "lines")` が `.array(ls)` でなければ飛ばす。`lines` の各要素は `PyStr.describe(要素.foundationObject)`
- `member(_ o: [(String, PyJSONValue)], _ key: String) -> PyJSONValue?`（internal）: `o.first { PyText.scalarsEqual($0.0, key) }?.1`（重複キーは `decode` が後勝ちで 1 つにしている）
- 例外を投げない。要素の不正は**その要素だけ**飛ばす
- voicedock は `fromisoformat` でオフセットの無い時刻も受けていた。本アプリは `parseISO` が受けるものだけ（自分で書いたファイルには常にオフセットがある）

**代替経路**（読み込みが空のとき）は呼び手（T-29）が `build(partials: [], chunks: [], transcript: 現在の統合結果, summary: 解析の summary)` を呼ぶ。

### 4.4 `VaultIndex.swift`

```swift
// Vault に実在する .md の basename の集合（PLAN §8.6 / NOTE-11。voicedock wiki.py:46-167）。例外を投げない。
public struct VaultIndex: Sendable {
    public let names: Set<String>          // normalize 済み
    public let builtAt: Duration           // AppClock.uptime()（単調時計）
    public let scannedDirectories: Int     // 走査したディレクトリの数（DEBUG ログ用）
    public init(names: Set<String>, builtAt: Duration, scannedDirectories: Int = 0)
    public static func build(vault: URL, excludePrefixes: [String], builtAt: Duration) -> VaultIndex
    public static func normalize(_ s: String) -> String
    public static func rawFolderPrefix(_ template: String) -> String
    public func contains(_ name: String) -> Bool
    public func isStale(ttlSeconds: Int, now: Duration) -> Bool
}
```

- **`normalize(s)`** = `PyText.casefold(PyText.nfc(s))`
- **`contains(name)`** = `names.contains(normalize(name))`
- **`isStale(ttlSeconds:now:)`** = `now - builtAt >= .seconds(ttlSeconds)`（等号で古い。voicedock の `is_stale` と同じ）
- **`rawFolderPrefix(template)`**: 最初の `{` より前を `head` とし、`{` が無ければ `PyText.strip(template, chars: ["/"])`、あれば `PyText.strip(head, chars: ["/"])`（既定 `Daily/Voice/Raw/{yyyymmdd}` → `Daily/Voice/Raw`、`Voice/Raw` → `Voice/Raw`）

**`build`**（深さ優先）:
1. `excluded = excludePrefixes.map { PyText.strip($0, chars: ["/"]) }.filter { !$0.isEmpty }`
2. `stack = [(vault, [])]`（URL と Vault からの相対の要素の列）、`names = []`、`scanned = 0`
3. `while let (dir, rel) = stack.popLast()`:
   - `FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))` が失敗 → 次へ（読めないディレクトリは飛ばす）。成功したら `scanned += 1`
   - 各 `name`: スカラー列が `.` で始まる → 無視（`.obsidian`・`.trash` を含む）
   - `lstat(dir/name)` が失敗 → 無視
   - ディレクトリ（`S_ISDIR`。**symlink は辿らない**）なら、`childRel = RelPath.join(rel + [name])` が `excluded` のどれかと等しいか `その接頭辞 + "/"` で始まる（スカラー単位）なら入らない。そうでなければ `stack.append((dir/name, rel + [name]))`
   - ディレクトリでないもの（通常ファイル・symlink・その他）: 名前のスカラー列が `.md`（大小区別）で終われば、`.md` を除いた名前を `normalize` して `names` に入れる
4. `VaultIndex(names: names, builtAt: builtAt, scannedDirectories: scanned)`
- Vault が存在しなければ空の索引。例外を投げない
- `linkTags == false` のときは呼び手（Worker。T-29）が作らない。TTL（`vaultIndexCacheSeconds`）で作り直すのも Worker

### 4.5 `LinkPlanner.swift`

```swift
// Daily ノートに付けるリンクを決める（PLAN §8.6 / NOTE-10 / PR-15。voicedock wiki.py:170-310）。文字列の差し込みはしない。例外を投げない。
public struct LinkPlan: Equatable, Sendable {
    public let dailyNote: String?          // "[[yyyy-MM-dd]]"
    public let adjacent: [String]          // 前日・翌日の "[[…]]"
    public let tags: [String]              // "[[名前]]" か "#名前"。入力の順
    public let raw: [String]               // Raw へのリンク。max_links の対象外
    public let dropped: [String]           // 落とした候補（DEBUG ログ用）
    public init(dailyNote: String?, adjacent: [String], tags: [String], raw: [String], dropped: [String])
    public static let empty: LinkPlan      // 全部 nil / 空
    /// max_links に数える本数（Raw を含めない）
    public var counted: Int { get }        // (dailyNote != nil ? 1 : 0) + adjacent.count + tags のうち "[[" で始まるものの数
}

public enum LinkPlanner {
    public static let forbiddenScalars: Set<Unicode.Scalar>   // "[", "]", "|", "#", "^"
    public static func plan(config: ObsidianConfig, day: LocalDate, tags: [String], index: VaultIndex?,
                            selfName: String, nameForDay: (LocalDate) -> String, rawNames: [String]) -> LinkPlan
    /// 00-api-map の形。形として使え（isWellFormed）、かつ自分自身（selfName）でないか
    public static func isLinkable(_ candidate: String, selfName: String) -> Bool
    /// internal。voicedock の is_linkable（空・禁止文字だけを見る。自己参照は見ない）。Raw の候補に使う
    static func isWellFormed(_ candidate: String) -> Bool
}
```

- **`isWellFormed(c)`**: `s = PyText.strip(c)`。空なら偽。`s` のスカラーに `forbiddenScalars` のどれかが含まれれば偽。それ以外は真
- **`isLinkable(c, selfName:)`** = `isWellFormed(c) && !PyText.scalarsEqual(VaultIndex.normalize(c), VaultIndex.normalize(selfName))`
- `link(n) = "[[" + n + "]]"`、`tag(n) = "#" + n`（**候補は strip せずそのまま**囲む。voicedock どおり）
- `usable(c)`: `!isLinkable(c, selfName: selfName)` → `dropped.append(c)`、偽。それ以外は真（voicedock `_usable` と同じ: 形の検査の後に自己参照）

**`plan`** の手順（`w = config.wiki`、`budget = w.maxLinks`、`dropped = []`）:
1. 日付: `w.linkDailyNote` なら `c = day.dashed`。`usable(c) && budget > 0` なら `dailyNote = link(c)`、`budget -= 1`（`usable` は先に評価する。予算切れのときは dropped に入れない）
2. 隣接日: `w.linkAdjacentDays` なら `for off in [-1, 1]`: `c = nameForDay(day.adding(days: off))`。`!usable(c)` → 次。`budget <= 0` → `dropped.append(c)`、次。そうでなければ `adjacent.append(link(c))`、`budget -= 1`。**実在は確かめない**
3. タグ: `for c in tags`: `!usable(c)` → 次（捨てる）。`existing = index?.contains(c) ?? false`、`wanted = w.linkTags && (existing || !w.linkOnlyExisting)`。
   `wanted && budget > 0` → `rendered.append(link(c))`、`budget -= 1`、次。`wanted` なら `dropped.append(c)`。`rendered.append(tag(c))`
4. Raw: `raw = rawNames.filter(isWellFormed).map(link)`（予算の対象外。自己参照の判定もしない。voicedock `is_linkable`）
5. `LinkPlan(dailyNote:, adjacent:, tags: rendered, raw:, dropped:)`

- 呼び手（T-29）が渡すもの: `tags` = **解析の `tags` そのもの**（既定タグ・空白置換・strip を通さない）、`selfName = DailyNote.baseName(config:day:)`、`nameForDay = { DailyNote.baseName(config: config, day: $0) }`、
  `rawNames = [DailyNote.rawLinkName(rawOutputPath: session.raw_output_path, config:, day:)]`、`index` = Worker の索引（`linkTags == false` なら nil）
- `#タグ` は本文の Links に出ない（`linksLines` が `[[` だけを拾う）

## 5. テスト

T-26 の `NotesFixtures` を使う。追加:
- `analysisFull = AnalysisView(title: "開発と打ち合わせの一日", summary: "VoiceDock の削除条件を整理した。午後に MVP の範囲を確定した。", keyPoints: ["削除の根拠をテキストの保全に置く"], decisions: ["MVP では GUI を作らない"], ideas: ["将来的に話者識別を追加する"], tags: ["VoiceDock", "DJI Mic", "a: b", "c \"d\"", "e\\f", "  ", "全角\u{3000}空白"], tasks: [("DJI Mic 3 のマウント構造を確認する", nil), ("Whisper の速度を実測する", "2026-09-05")])`
- `linksFull = LinkPlan(dailyNote: "[[2026-08-29]]", adjacent: ["[[2026-08-28 Voice]]", "[[2026-08-30 Voice]]"], tags: ["[[VoiceDock]]", "#DJI-Mic"], raw: ["[[2026-08-29 raw]]"], dropped: [])`
- `timelineFull = [TimelineBlock(start: at(7,12,0), end: at(11,12,0), lines: ["朝の移動中に整理した", "二点目"]), TimelineBlock(start: at(13,12,0), end: at(19,12,0), lines: ["MVP を確定した"])]`
- `excludedFull = [ExcludedPart("DJIMIC3/F/f_orig.wav", .failed, .whisperFailed, nil), ExcludedPart("DJIMIC3/S/s1_orig.wav", .skipped, .noSpeechDetected, nil), ExcludedPart("DJIMIC3/S/s2_orig.wav", .skipped, .duplicateContent, nil)]`
- 設定は `AppConfig.defaults(timeZone: "Asia/Tokyo")`

### 5.1 `DailyNoteTests.swift`

| 表示名 | 関数名 | 準備 → 期待 |
|---|---|---|
| `全部入りの Daily ノートは voicedock と同じ` | `fullNoteMatchesVoicedock` | `recordingKeys [keyA, keyB]`、`excludedFull`、`recordedSeconds 34880.9`、`blockCount 2`、`timelineFull`、`linksFull`、`analysisFull` → 下の「期待 B」とバイト一致 |
| `最小形の Daily ノートは voicedock と同じ` | `minimalNoteMatchesVoicedock` | `AnalysisView(title: "題", summary: "一文目。二文目。", keyPoints: [], decisions: [], ideas: [], tags: [], tasks: [])`、`recordingKeys []`、excluded = SKIPPED の 3 件（`errorCode: .sourceMissing`・`errorCode: nil, unknownCode: nil`・`errorCode: .llmFailed`。partkey は `DJIMIC3/S/s3_orig.wav`・`s4`・`s5`）、`recordedSeconds nil`、`blockCount 0`、timeline `[]`、links `.empty` → 下の「期待 C」とバイト一致 |
| `recorded は切り捨てで 2 桁を超えうる` | `recordedFormat` | `recorded(90061.7)` == `"25:01:01"`、`recorded(-1)` == `"00:00:00"`、`recorded(0)` == `"00:00:00"`、`recorded(nil)` == `"00:00:00"`、`recorded(.nan)` == `"00:00:00"` |
| `タグは既定タグと合わせて正規化する` | `tagsAreNormalized` | 4.1 の例 |
| `タグの重複は casefold で除く` | `tagsDedupeByCasefold` | defaults `["voice"]`、tags `["Voice", "STRASSE", "straße"]` → `["voice", "STRASSE"]` |
| `CE llm.analysis.order 節の順は設定の order` | `sectionOrderFollowsConfig` | order を `["ideas","summary"]` に変える → `## Ideas` が `## Summary` より前、`## Tasks` が無い |
| `CE llm.analysis.sections.summary.heading 見出しは設定から` | `headingsFromConfig` | `sections.summary.heading = "## 要約"` → `## 要約` を含み `## Summary` を含まない |
| `CE llm.analysis.sections.timeline.heading 見出しは設定から` | `ceTimelineHeading` | `sections.timeline.heading = "## 時系列"`、`timelineFull` → `## 時系列` を含み `## Timeline` を含まない |
| `CE llm.analysis.sections.key_points.heading 見出しは設定から` | `ceKeyPointsHeading` | `sections.key_points.heading = "## 要点"` → `## 要点` を含み `## Key Points` を含まない |
| `CE llm.analysis.sections.tasks.heading 見出しは設定から` | `ceTasksHeading` | `sections.tasks.heading = "## やること"` → `## やること` を含み `## Tasks` を含まない |
| `CE llm.analysis.sections.decisions.heading 見出しは設定から` | `ceDecisionsHeading` | `sections.decisions.heading = "## 決定"` → `## 決定` を含み `## Decisions` を含まない |
| `CE llm.analysis.sections.ideas.heading 見出しは設定から` | `ceIdeasHeading` | `sections.ideas.heading = "## 着想"` → `## 着想` を含み `## Ideas` を含まない |
| `CE llm.analysis.sections.tags.heading 見出しは設定から` | `ceTagsHeading` | order に `tags` を足し、`sections.tags.heading = "## タグ"` → `## タグ` を含む。heading を nil にすると `## tags`（節名からの既定）になる |
| `CE llm.analysis.sections.timeline.enabled false なら Timeline を出さない` | `ceTimelineEnabled` | `sections.timeline.enabled = false`、`timelineFull` → `## Timeline` が無く、ほかの節は「期待 B」と同じ順（既定の true では在る） |
| `無効な節は出さない` | `disabledSectionIsAbsent` | key_points・tasks・decisions・ideas・timeline のそれぞれを `enabled = false` にすると、その見出しが無い（パラメータ化） |
| `空の節は見出しごと省く` | `emptySectionOmitted` | key_points・tasks・decisions・ideas を空配列にすると、その見出しが無い（パラメータ化） |
| `空の summary は節を省く` | `emptySummaryOmitted` | `summary: "   "` → `## Summary` が無い |
| `期限のある task に 📅` | `taskWithDue` | `- [ ] Whisper の速度を実測する 📅 2026-09-05` を含む |
| `期限の無い task に印を付けない` | `taskWithoutDue` | `- [ ] DJI Mic 3 のマウント構造を確認する\n` を含み、その行に `📅` が無い |
| `Timeline は order の中の 1 節` | `timelineIsOneOfTheSections` | `## Summary` → `## Timeline` → `## Key Points` の順に現れる |
| `Timeline が空なら見出しも無い` | `emptyTimelineOmitted` | timeline `[]` → `## Timeline` が無い |
| `Sources は Raw へのリンク` | `sourcesLinkToRaw` | `## Sources\n\n- [[2026-08-29 raw]]` を含む |
| `Raw へのリンクが無ければ Sources も無い` | `noSourcesWithoutRaw` | links = `dailyNote` だけ → `## Sources` が無い |
| `Links に #タグ を並べない` | `plainTagsNotInLinks` | `## Links` 以降に `#DJI-Mic` が無く `[[VoiceDock]]` がある |
| `題に : があっても frontmatter は壊れない` | `titleWithColonIsSafe` | title `"a: b"` → `Frontmatter.parse` が nil でない、本文に `# a: b` |
| `崩れたタグでも frontmatter は読める` | `hostileTagsParse` | tags に `"a: b"`・`"#x"`・`"[y]"` → `Frontmatter.parse` の tags が文字列の配列 |
| `本文の行頭 --- は退避される` | `leadingDashesEscaped` | summary `"---\n本文"` → `\---` を含み `parse` が成功 |
| `ファイル名に題を使わない` | `fileNameNeverUsesTitle` | `baseName` == `2026-08-29 Voice`（題に依存しない） |
| `CE obsidian.wiki.filenameTemplate が Daily の基本名になる` | `ceWikiFilenameTemplate` | `wiki.filenameTemplate = "{yyyymmdd} 声"` → `DailyNote.baseName` == `20260829 声`（既定なら `2026-08-29 Voice`） |
| `CE obsidian.wiki.folderTemplate が Daily の置き場所になる` | `ceWikiFolderTemplate` | `wiki.folderTemplate = "Notes/{date}"` → `DailyNote.folder` == `Notes/2026-08-29`（既定なら `Daily/Voice/Wiki/20260829`） |
| `CE obsidian.defaultTags が frontmatter の tags に入る` | `ceDefaultTags` | `defaultTags = ["mytag"]`、analysis の tags は空 → frontmatter の `tags` が `["mytag"]`（既定なら `["voice", "voicedock"]`） |
| `Sources のリンク先は実際の Raw の名前（X-15）` | `rawLinkNameUsesActualBasename` | `rawLinkName("Daily/Voice/Raw/20260829/2026-08-29 raw (2).md", …)` == `2026-08-29 raw (2)`、`rawLinkName(nil, …)` == `2026-08-29 raw` |
| `DN-8 の見出しは設定から` | `summaryHeadingFromConfig` | 既定 → `## Summary`、`heading = "## 要約"` → `## 要約`、`heading = ""` → `## Summary` |

期待 B（`fullNoteMatchesVoicedock`。移植メモ V5 §4.5 の実出力。最後の行の後に `\n` が 1 つ）:
```text
---
type: "voice-daily"
voicedock_session_key: "DJIMIC3:20260829"
voicedock_recording_keys:
  - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
  - "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"
voicedock_failed_parts:
  - "DJIMIC3/F/f_orig.wav"
voicedock_skipped_parts:
  - "DJIMIC3/S/s1_orig.wav"
  - "DJIMIC3/S/s2_orig.wav"
date: "2026-08-29"
recorded: "09:41:20"
parts: 2
blocks: 2
status: "processed"
tags:
  - "voice"
  - "voicedock"
  - "DJI-Mic"
  - "a:-b"
  - "c-\"d\""
  - "e\\f"
  - "全角-空白"
---

# 開発と打ち合わせの一日

> ⚠ この日の録音のうち 1 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。

> この日の録音のうち 2 本を除外しました（重複・無音）。自動では再試行されません。

## Summary

VoiceDock の削除条件を整理した。午後に MVP の範囲を確定した。

## Timeline

### 07:12–11:12

- 朝の移動中に整理した
- 二点目

### 13:12–19:12

- MVP を確定した

## Key Points

- 削除の根拠をテキストの保全に置く

## Tasks

- [ ] DJI Mic 3 のマウント構造を確認する
- [ ] Whisper の速度を実測する 📅 2026-09-05

## Decisions

- MVP では GUI を作らない

## Ideas

- 将来的に話者識別を追加する

## Sources

- [[2026-08-29 raw]]

## Links

- [[2026-08-29]]
- [[2026-08-28 Voice]]
- [[2026-08-30 Voice]]
- [[VoiceDock]]
```

期待 C（`minimalNoteMatchesVoicedock`）:
```text
---
type: "voice-daily"
voicedock_session_key: "DJIMIC3:20260829"
voicedock_recording_keys: []
voicedock_failed_parts: []
voicedock_skipped_parts:
  - "DJIMIC3/S/s3_orig.wav"
  - "DJIMIC3/S/s4_orig.wav"
  - "DJIMIC3/S/s5_orig.wav"
date: "2026-08-29"
recorded: "00:00:00"
parts: 0
blocks: 0
status: "processed"
tags:
  - "voice"
  - "voicedock"
---

# 題

> ⚠ この日の録音のうち 3 本を除外しました（元ファイルが見つかりません・LLM_FAILED・理由不明）。自動では再試行されません。デバイスから採り直してください。

## Summary

一文目。二文目。
```
（理由の並びは宣言順で SOURCE_MISSING → LLM_FAILED → 空（未知・空は末尾）。`LLM_FAILED` は表示名の表に無いのでコード名のまま出る）

### 5.2 `DailyWarningsTests.swift`

| 表示名 | 関数名 | 入力 → 期待（行の逐語） |
|---|---|---|
| `FAILED だけ` | `failedOnly` | FAILED 1 件 → `["> ⚠ この日の録音のうち 1 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。"]` |
| `無音だけなら ⚠ を付けない` | `silenceAloneDoesNotWarn` | SKIPPED(NO_SPEECH) 1 件 → `["> この日の録音のうち 1 本を除外しました（無音）。自動では再試行されません。"]` |
| `無音と重複（順によらない）` | `benignPairIsOrdered` | SKIPPED(DUPLICATE)・SKIPPED(NO_SPEECH) をどちらの順で渡しても `["> この日の録音のうち 2 本を除外しました（重複・無音）。自動では再試行されません。"]` |
| `元ファイル不在は操作を促す` | `missingSourceIsActionable` | SKIPPED(SOURCE_MISSING) → `["> ⚠ この日の録音のうち 1 本を除外しました（元ファイルが見つかりません）。自動では再試行されません。デバイスから採り直してください。"]` |
| `1 件でも操作が要れば行全体に ⚠` | `oneActionableMarksLine` | NO_SPEECH と SOURCE_MISSING → `⚠ ` 付きで理由は `元ファイルが見つかりません・無音`（宣言順で SOURCE_MISSING が NO_SPEECH_DETECTED より先） |
| `未知の理由は操作が要る側` | `unknownReasonIsActionable` | `unknownCode: "SOMETHING_NEW"` → `⚠ ` 付き、理由 `SOMETHING_NEW` |
| `理由なしは「理由不明」` | `noReasonIsUnknown` | コード無し → 理由 `理由不明`、`⚠ ` 付き |
| `同じ順位はコードの辞書順` | `tiesAreSortedByCode` | 未知 `"ZZZ"` と `"AAA"` と理由なし → 理由 `理由不明・AAA・ZZZ`（`""` < `"AAA"` < `"ZZZ"`） |
| `表示名の重複は除かない` | `displayNamesAreNotDeduped` | SOURCE_MISSING と NORMALIZED_MISSING → `元ファイルが見つかりません・元ファイルが見つかりません` |
| `FAILED と SKIPPED は別の行` | `bothKindsGetOwnLine` | FAILED 1・SKIPPED(NO_SPEECH) 1 → 2 行（FAILED が先） |
| `SKIPPED に「再試行されます」と書かない` | `skippedNeverPromisesRetry` | どの SKIPPED の組み合わせでも行に `自動で再試行されます` を含まない |
| `benign は無音と重複の 2 つだけ` | `benignIsExactlyTwo` | `SkipReasons.benign == [.noSpeechDetected, .duplicateContent]` |
| `何も無ければ空` | `emptyInputs` | `lines(failed: [], skipped: [])` == `[]` |

### 5.3 `TimelineTests.swift`

| 表示名 | 関数名 | 期待 |
|---|---|---|
| `Map の結果があればチャンクごと` | `buildPrefersPartials` | partials `[{summary 朝, keyPoints [朝の点]}, {summary 夕, keyPoints [夕の点]}]`、chunks 2 つ → lines `[["朝の点"], ["夕の点"]]`、start・end はチャンクの値 |
| `key_points が無ければ summary の文` | `partialFallsBackToSummary` | partial `{summary "A。B。", keyPoints []}` → lines `["A。","B。"]` |
| `点の無い組は捨てる` | `emptyPointsDropped` | partial `{summary "", keyPoints []}` と通常の 1 つ → ブロック 1 つ |
| `短い方で打ち切る` | `zipTruncates` | partials 3・chunks 2 → ブロック 2 つ |
| `単一パスは Block ごとに全文を繰り返す` | `singlePassRepeatsSentences` | partials `[]`、blocks 2 つ（07:00–08:00、10:00–11:00）、summary `"A。B。 C"` → 2 ブロックとも lines `["A。","B。","C"]` |
| `Block が無ければ segment の範囲` | `fallbackBlockFromSegments` | blocks `[]`、segments `[07:12:00–07:12:05]` → ブロック 1 つ（07:12:00–07:12:05） |
| `summary が空なら空` | `emptySummaryIsEmpty` | summary `""` → `[]` |
| `文の分割` | `sentencesSplit` | `"一文目。二文目。\n三文目 。 \n\n四"` → `["一文目。","二文目。","三文目 。","四"]`、`"A。B。 C"` → `["A。","B。","C"]`、`""` → `[]` |
| `符号化は voicedock と同じ形` | `encodeMatchesVoicedock` | 1 ブロック（07:12:04–07:42:04、lines `["午前に作業した。","午後に会議。"]`）、fingerprint `"<fp>"` → `"{\n  \"schema\": 2,\n  \"transcript_sha256\": \"<fp>\",\n  \"blocks\": [\n    {\n      \"start_at\": \"2026-08-29T07:12:04+09:00\",\n      \"end_at\": \"2026-08-29T07:42:04+09:00\",\n      \"lines\": [\n        \"午前に作業した。\",\n        \"午後に会議。\"\n      ]\n    }\n  ]\n}\n"` |
| `符号化して読み戻せる` | `roundTrips` | `decode(encode(b, "FP"), "FP")` == `b` |
| `別の指紋は無視する` | `otherFingerprintIgnored` | `decode(encode(b, "FP"), "OTHER")` == `[]` |
| `指紋の無い形式は無視する` | `schemaOneIgnored` | `[{"start_at":…}]`（配列）・`{"schema":1,…}`・`{"schema":true,…}` → `[]` |
| `壊れた JSON は空` | `brokenIsEmpty` | `""`・`"not json"`・`"{"`・`"[]"` → `[]` |
| `壊れた要素だけ飛ばす` | `badEntriesSkipped` | blocks `[1, {"start_at":"x","end_at":"2026-…","lines":[]}, {"start_at":…,"end_at":…,"lines":"x"}, 正しい要素]` → 正しい 1 つだけ |
| `行の要素は str() で文字列化` | `linesStringified` | lines `[1, true, null, "a"]` → `["1","True","None","a"]` |
| `schema は 2.0 も受ける` | `schemaFloatAccepted` | `"schema": 2.0` → 読める |
| `行の先頭の U+FEFF を落とさない（PyJSON.decode）` | `leadingBOMInLineKept` | lines `["\ufeffa"]`（`\u` エスケープで書いた文書）→ `["\u{FEFF}a"]` |

### 5.4 `VaultIndexTests.swift`

一時ディレクトリに Vault を作る（`note(vault, "a/b.md")` = 中間を作って `"# x\n"` を書く）。

| 表示名 | 関数名 | 期待 |
|---|---|---|
| `.md の basename を集める` | `collectsMarkdownBasenames` | `VoiceDock.md`・`Projects/DJI.md`・`Projects/Deep/Nested.md`・`notes.txt` → `VoiceDock`・`DJI`・`Nested` を含み `notes` を含まない |
| `. で始まるディレクトリは見ない` | `dotDirectoriesExcluded` | `.obsidian/Template.md`・`.trash/Template.md` → `Template` を含まない |
| `Raw フォルダを除外する` | `rawFolderExcluded` | `Daily/Voice/Raw/20260912/2026-09-12 raw.md` と `VoiceDock.md`、除外 `["Daily/Voice/Raw"]` → raw を含まず VoiceDock を含む |
| `過去日の Raw も全部除外` | `everyPastRawExcluded` | Raw の 3 日分 → `names` が空 |
| `Wiki フォルダは除外しない` | `wikiFolderNotExcluded` | `Daily/Voice/Wiki/20260911/2026-09-11 Voice.md` を含む |
| `除外は接頭辞の境界で` | `prefixBoundary` | 除外 `Daily/Voice/Raw` のとき `Daily/Voice/RawNotes/x.md` は含む |
| `読めないディレクトリは飛ばす` | `unreadableSkipped` | `locked`（chmod 000）の中は含まず、他は含む。root ならスキップ（`geteuid() == 0`） |
| `Vault が無ければ空` | `missingVaultEmpty` | 存在しないパス → 空 |
| `symlink のディレクトリは辿らない` | `symlinkedDirectoriesNotFollowed` | Vault の外の `outside/Outside.md` への `link` → `Outside` を含まない |
| `NFC で突き合わせる` | `matchesNFC` | NFD の `がぎぐ.md` → `contains("がぎぐ")` |
| `大小を区別しない` | `ignoresCase` | `VoiceDock.md` → `voicedock`・`VOICEDOCK` を含む |
| `完全一致だけ` | `exactOnly` | `VoiceDock の設計.md` → `VoiceDock` を含まない |
| `casefold の難しい例` | `normalizeHardCases` | `normalize("Straße") == normalize("STRASSE")` |
| `rawFolderPrefix` | `rawFolderPrefixCases` | `Daily/Voice/Raw/{yyyymmdd}` → `Daily/Voice/Raw`、`Voice/Raw` → `Voice/Raw`、`/Voice/Raw/` → `Voice/Raw`、`{yyyymmdd}/x` → `""` |
| `TTL の境界は古い側` | `staleAtBoundary` | `builtAt .seconds(0)`、TTL 300: `now 299` → 新しい、`now 300` → 古い |
| `builtAt は渡した値` | `builtAtIsGiven` | `build(…, builtAt: .seconds(42)).builtAt == .seconds(42)` |
| `入れ子まで降りる` | `walksNested` | `a/b/c/Deep.md` → 含む、`scannedDirectories >= 4` |

### 5.5 `LinkPlannerTests.swift`

既定の設定、`day = 2026-09-12`、`selfName = "2026-09-12 Voice"`、`nameForDay = { "\($0.dashed) Voice" }` を既定の引数にする。

| 表示名 | 関数名 | 期待 |
|---|---|---|
| `voicedock と同じ計画` | `planMatchesVoicedock` | day 2026-08-29、tags `["VoiceDock","none","a#b","2026-08-29 Voice"]`、index `{voicedock}`、selfName `2026-08-29 Voice`、rawNames `["2026-08-29 raw"]` → dailyNote `[[2026-08-29]]`、adjacent `[[2026-08-28 Voice]]`・`[[2026-08-30 Voice]]`、tags `["[[VoiceDock]]","#none"]`、raw `["[[2026-08-29 raw]]"]`、dropped `["a#b","2026-08-29 Voice"]` |
| `禁止文字を含む候補は落とす` | `forbiddenCharactersDropped` | `a[b` `a]b` `a\|b` `a#b` `a^b`（索引に在っても）→ tags 空、dropped に含む |
| `空白だけの候補は落とす` | `blankDropped` | `""`・`"   "`・`"\n"` → `isLinkable(_, selfName: "2026-09-12 Voice")` が偽、tags 空 |
| `自分自身は落とす（大小無視）` | `selfReferenceDropped` | tags `[selfName]`・`[selfName.uppercased()]` → tags 空 |
| `索引に在ればリンク` | `existingBecomesLink` | index `{voicedock}`、tags `["VoiceDock"]` → `["[[VoiceDock]]"]` |
| `索引に無ければ #タグ` | `missingStaysTag` | → `["#存在しない"]` |
| `順序は入力のまま` | `mixedKeepOrder` | `["存在しない","DJI","これも無い"]`（索引 `{dji}`）→ `["#存在しない","[[DJI]]","#これも無い"]` |
| `CE obsidian.wiki.linkOnlyExisting が偽なら全部リンク` | `linkOnlyExistingFalse` | → `["[[存在しない]]"]`（既定の true なら `["#存在しない"]`） |
| `CE obsidian.wiki.linkTags が偽ならタグのまま` | `linkTagsFalse` | index nil → `["#VoiceDock"]`（既定の true・索引在りなら `["[[VoiceDock]]"]`） |
| `日付は 1 つ` | `dateLinkedOnce` | dailyNote `[[2026-09-12]]` |
| `前日と翌日` | `adjacentDays` | `["[[2026-09-11 Voice]]","[[2026-09-13 Voice]]"]` |
| `月の境目` | `monthBoundary` | day 2026-03-01 → `["[[2026-02-28 Voice]]","[[2026-03-02 Voice]]"]` |
| `隣接日の名前は呼び手が決める` | `adjacentNamesFromCaller` | `nameForDay = { "Journal \($0.dashed)" }` → `["[[Journal 2026-09-11]]","[[Journal 2026-09-13]]"]` |
| `CE obsidian.wiki.linkDailyNote が偽なら日付のリンクを作らない` | `ceLinkDailyNoteOff` | `linkDailyNote = false` → `dailyNote == nil`（既定の true なら `[[2026-09-12]]`） |
| `CE obsidian.wiki.linkAdjacentDays が偽なら隣接日のリンクを作らない` | `ceLinkAdjacentDaysOff` | `linkAdjacentDays = false` → `adjacent == []`（既定の true なら 2 件） |
| `CE obsidian.wiki.maxLinks 上限で切る` | `capped` | maxLinks 5、Tag0〜Tag9 が索引に在る → counted 5、リンクは `[[Tag0]]`・`[[Tag1]]`、`tags[2] == "#Tag2"`（既定の 20 なら 10 件ともリンク） |
| `Raw は上限の対象外` | `rawNotCounted` | maxLinks 1、rawNames 32 本 → raw 32、counted 1 |
| `上限を超えたタグは #タグ で残す` | `capKeepsTags` | maxLinks 3、`Kept` が索引に在る → tags `["#Kept"]`、dropped に `Kept` |
| `maxLinks 0` | `zeroMaxLinks` | dailyNote nil、adjacent 空、tags `["#Tag"]`、raw `["[[raw]]"]` |
| `予算切れの日付は dropped に入れない` | `exhaustedDailyNotDropped` | maxLinks 0 → dropped に `2026-09-12` を含まない、`2026-09-11 Voice` は含む |

### 5.6 `DailyNoteGoldenTests.swift`（`@Suite("DailyNote golden")`）

T-25 のグループを使う（グループ名・ケース・入力のキーは T-25 §4.3〜§4.5・§4.9 が正）。ケース名を列挙せず `try Golden.cases("<group>")` をパラメータ化テストの引数に渡して**全部**回し、
グループごとに「ケースが在る」テストを置く（空で緑にしない。T-25 §4.11・TEST-28）。`.md` / `.out` は `GoldenAssert.matches`、`.json` は `GoldenAssert.matchesJSON`。
共通: `config = try GoldenConfig.make(item)`（T-09）、`zone = ZonedTime(timeZone: TimeZone(identifier: try item.string("timeZone"))!)`、`day = LocalDate(dashed: try item.string("day"))!`（`day` を持つグループだけ）、
時刻は `base = zone.parseISO(base の文字列)!` に `adding(milliseconds:)`（T-25 §4.3）。

| 関数名 / 表示名 | グループ（ケース数） | 実際の値 |
|---|---|---|
| `goldenDailyNote(item:)` / 「golden daily_note」 | `daily_note`（20、`.md`） | `DailyNote.render(DailyInput(…), config: config)`。`analysis` → `AnalysisView`（`title`・`summary` は文字列、配列の節は入力に在ればその要素・無ければ `[]`（節が無効なら nil）、`tasks` は各 `{text, due}`）、`recordingKeys`、`excluded` の各 `{partkey, status, errorCode}` → `ExcludedPart(partkey:, status: PartStatus(rawValue: status)!, errorCode: ErrorCode(rawValue:)（null・未知は nil）, unknownCode: 未知のコードの文字列（既知か null なら nil）)`、`recordedSeconds`（`optionalDouble`）、`blockCount`、`timeline` の `{base, blocks: [{startMs, endMs, lines}]}` → `TimelineBlock`、`links` の `{dailyNote, adjacent, tags, raw}` → `LinkPlan(…, dropped: [])`、`sessionKey`、`zone` |
| `goldenDailyParts(item:)` / 「golden daily_parts」 | `daily_parts`（6、`.json`） | `kind` が `recorded` → `inputs` の各値（null は nil）の `DailyNote.recorded`、`tags` → `DailyNote.tags(analysisTags: tags（null は nil）, defaults: defaults)`、`warnings` → `sets` の各組を `failed`（status が FAILED）と `skipped`（それ以外）に分けた `DailyWarnings.lines(failed:skipped:)` の配列、`sentences` → `inputs` の各値の `Timeline.sentences` |
| `goldenTimeline(item:)` / 「golden timeline」 | `timeline`（8、`.out`） | `partials` の各 `{summary, key_points}` を `AnalysisView`（`key_points` が無ければ `[]`）に、`chunks` の各 `{startMs, endMs}` を `(start, end)` に、`transcript` を `SessionTranscript(dayDate: day, segments: 各 {atMs, endMs, text} → AbsoluteSegment, blocks: 各 {startMs, endMs} → TimeBlock, excludedPartkeys: [])` にして、`Timeline.encode(Timeline.build(partials:chunks:transcript:summary:), fingerprint:, zone:)` を UTF-8 の文字列にしたもの |
| `goldenTimelineDecode(item:)` / 「golden timeline_decode」 | `timeline_decode`（7、`.json`） | `Timeline.decode(Data(document.utf8), fingerprint:, zone:)` の各ブロックを `{"start": zone.iso(start), "end": zone.iso(end), "lines": lines}` にした配列 |
| `goldenWiki(item:)` / 「golden wiki」 | `wiki`（15） | `kind` が `normalize` → `inputs` の各値の `VaultIndex.normalize`（`.json`）、`plan` → `index` = `indexNames` が null なら nil、そうでなければ `VaultIndex(names: Set(各値の normalize), builtAt: .zero)` として `LinkPlanner.plan(config: config.obsidian, day:, tags:, index:, selfName: DailyNote.baseName(config: config.obsidian, day: day), nameForDay: { DailyNote.baseName(config: config.obsidian, day: $0) }, rawNames:)` の結果を `{"dailyNote", "adjacent", "tags", "raw", "dropped"}` にしたもの（`.json`）、`buildIndex` → `TempDirectory` の下に `files` を空ファイルで作り、`symlinkDirs` の各 `[link, target]` を `symlink(<root>/target, <root>/link)` で作って `VaultIndex.build(vault:, excludePrefixes: [VaultIndex.rawFolderPrefix(config.obsidian.raw.folderTemplate)], builtAt: .zero).names` をスカラー値の辞書順に並べた配列（`.json`。Python の `sorted`）、`rawPrefix` → `VaultIndex.rawFolderPrefix(config.obsidian.raw.folderTemplate)`（`.out`） |
| `goldenDailyFilename(item:)` / 「golden note_filename（Daily）」 | `note_filename`（8 のうち `kind` が `daily` / `dailyFolder`。`.out`） | `daily` → `DailyNote.baseName(config: config.obsidian, day:)`、`dailyFolder` → `DailyNote.folder(config: config.obsidian, day:)`。`raw` / `rawFolder` は何もせずに返す（T-26 が確かめる） |
| `goldenGroupsHaveCases` / 「golden daily_note・daily_parts・timeline・timeline_decode・wiki のケースが在る」 | 5 グループ | どれも空でない |

- **本計画の差分（X-15）**は golden を上書きしない。`rawLinkNameUsesActualBasename` だけが差分を固定する
- golden は Asia/Tokyo で作られている（夏時間の差 X-32 は現れない）

### 5.7 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`llm.analysis.sections.*.heading`（7 行）・`llm.analysis.sections.timeline.enabled`・`llm.analysis.order`・`obsidian.defaultTags`・`obsidian.wiki.folderTemplate`・`obsidian.wiki.filenameTemplate`・`obsidian.wiki.linkDailyNote`・`obsidian.wiki.linkAdjacentDays`・`obsidian.wiki.linkTags`・`obsidian.wiki.linkOnlyExisting`・`obsidian.wiki.maxLinks` の計 17 行を消す（CE テストは §5.1・§5.5）。`obsidian.wiki.vaultIndexCacheSeconds` は T-29 が消す。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| Timeline を order の外（Sources の前）に出す | `fullNoteMatchesVoicedock`、`timelineIsOneOfTheSections` |
| 警告行の許可リストを「SOURCE_MISSING なら ⚠」の拒否リストにする | `unknownReasonIsActionable`、`noReasonIsUnknown` |
| 理由を出現順に並べる | `benignPairIsOrdered`、`oneActionableMarksLine` |
| 同順位の並びを入力順にする | `tiesAreSortedByCode` |
| 表示名の重複を除く | `displayNamesAreNotDeduped` |
| SKIPPED の行に「次にデバイスを接続したときに自動で再試行されます」と書く | `skippedNeverPromisesRetry` |
| タグの正規化で U+3000 を置換しない | `tagsAreNormalized` |
| タグの重複除去を `lowercased()` にする | `tagsDedupeByCasefold` |
| `recorded` を四捨五入にする | `recordedFormat` / `fullNoteMatchesVoicedock` |
| `linksLines` で `#タグ` も並べる | `plainTagsNotInLinks` |
| `rawLinkName` で常に基本名を返す | `rawLinkNameUsesActualBasename` |
| `decode` で指紋を比べない | `otherFingerprintIgnored` |
| `decode` で壊れた要素があれば全部捨てる | `badEntriesSkipped` |
| `decode` を `JSONSerialization` で読む | `leadingBOMInLineKept` |
| 索引で symlink のディレクトリを辿る | `symlinkedDirectoriesNotFollowed` |
| 除外を `hasPrefix(prefix)`（`/` 無し）にする | `prefixBoundary` |
| `isStale` を `>` にする | `staleAtBoundary` |
| 日付リンクで予算切れのとき dropped に入れる | `exhaustedDailyNotDropped` |
| 自己参照の比較を normalize せずに行う | `selfReferenceDropped` |
| Raw リンクを予算に数える | `rawNotCounted` |

## 7. 受け入れ条件

- [ ] 5 章のテストが全部通る（golden を含む）
- [ ] 期待 B・期待 C が voicedock の実出力とバイト一致している
- [ ] VDNotes に `Character` 単位の比較・`lowercased()` による比較が無い
- [ ] `VaultIndex.build` / `Timeline.decode` / `LinkPlanner.plan` が例外を投げない
- [ ] `make lint` が通る。PT-06（コード名の文字列は `ErrorCode.swift` だけ）に違反しない
- [ ] 破壊による証明の結果を PR 本文に貼った

## 8. SPEC の変更

なし（警告行の文言は PLAN §8.6 にある。SPEC 同期の対象にはしない）

## 9. マージ後にやること

なし

## 10. API 地図への変更提案

- `DailyInput` に `zone: ZonedTime` を追加（Timeline の見出し `HH:MM` を作るため）→ 00-api-map に反映済み（2026-09-18）
- `DailyNote` に `summaryHeading(config:)`・`rawLinkName(rawOutputPath:config:day:)`・定数（`noteType` など）を追加。`baseName` / `folder` の `config` の型は `ObsidianConfig` → 関数と引数の型は 00-api-map に反映済み（2026-09-18）。定数（`noteType`・`statusProcessed`・`dueMark`・`defaultSummaryHeading`）は地図に無い
- `ExcludedPart` に `reasonKey`（internal でよい）→ internal のまま（地図に載せない）
- `VaultIndex` に `scannedDirectories`・`contains(_:)`・`isStale(ttlSeconds:now:)` を追加（Worker（T-29）が TTL を判定するため。判定を 2 か所に書かない）→ 00-api-map に反映済み（2026-09-18）
- `LinkPlan` に `counted`、`LinkPlanner` に `isLinkable(_:)`・`forbiddenScalars` を追加 → 形を変えて 00-api-map に反映済み（2026-09-18）: 地図の `isLinkable(_ c: String, selfName: String)` に合わせ、voicedock の `is_linkable`（自己参照を見ない）は internal の `isWellFormed` にした（Raw の候補に使う）
- `DailyWarnings` の表示名は `[ErrorCode: String]` で持つ（PT-06）→ 反映済み（2026-09-18。表は internal）
