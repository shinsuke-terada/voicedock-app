# T-26 VDNotes: sanitize・テンプレート・frontmatter・Raw ノート

> （F-83・issue #119、2026-09-23。マージ後の追記）`Frontmatter.quote` は YAML の読み手が拒む U+0080–0084・U+0086–009F・U+FFFE・U+FFFF を `\uXXXX`（大文字 16 進 4 桁）で書く（PLAN §8.6・X-39。値は読み戻せる。
> U+0085・U+2028・U+2029 とそれ以外の入力の出力は変わらない）。テストは `FrontmatterYAMLEscapeTests.swift`。

| 項目 | 内容 |
|---|---|
| ID | T-26 |
| Phase | 6（ノート） |
| 前提 | T-09（AppConfig・TestSupport の `GoldenConfig`）、T-25（golden・`Golden` / `GoldenAssert`）、T-45（PyText・PyJSON・`PyJSON.formatDouble`）。T-10（Instant・ZonedTime・`ZonedTime(fixedOffsetSeconds:)`・ISOWallClock・LocalDate）と T-08 は T-09 の前提に含まれる |
| 見積もり | 本体 約 450 行、テスト 約 550 行（golden を除く） |

## 1. 目的

Obsidian に書く**ファイル名の sanitize**、**フォルダ・ファイル名のテンプレート展開**、**frontmatter の書き出しと読み取り**、**Raw ノート（文字起こし生データ）のレンダリング**を、voicedock@d3d595e の実装と**バイト単位で同じ出力**になるように作る。
ここで作る `Frontmatter` の読み取り関数は、保存検証（T-28）と削除条件（T-36）が共有する（検証ロジックを 2 本にしない）。

## 2. 参照

- PLAN §8.6（パス・sanitize・frontmatter・Raw ノート）、§5.7（PyText・Instant）、§8.9.1（`frontmatterKeys`）、§10.4（golden）、付録 C NOTE-04 / NOTE-06 / NOTE-08
- voicedock@d3d595e: `src/voicedock/notes.py:42-220`（sanitize・frontmatter・escape_body・split・parse・frontmatter_keys）、`src/voicedock/raw.py:97-218`（テンプレート・Raw の描画）、`src/voicedock/pipeline.py:592-623`（Raw に載せる Part）
- voicedock のテスト: `tests/unit/test_sanitize.py`、`tests/unit/test_raw_render.py`、`tests/unit/test_verify.py:94-220`
- 00-api-map.md §9（`Sanitize` / `NoteTemplate` / `Frontmatter` / `RawNote`）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDNotes/Sanitize.swift` | `Sanitize.fileName(_:maxBytes:)`（SN-1〜SN-9） |
| `Sources/VDNotes/Templates.swift` | `NoteTemplate.render(_:day:)` |
| `Sources/VDNotes/Frontmatter.swift` | `FrontmatterValue`、`Frontmatter`（render / quote / escapeBody / split / parse / recordingKeys / stringList） |
| `Sources/VDNotes/PyStr.swift` | internal `PyStr.describe(_:)`（Python の `str()` と同じ文字列化。T-27・T-28 も使う） |
| `Sources/VDNotes/ScalarText.swift` | internal `ScalarText`（Unicode スカラー単位の前方一致・後方一致・行分割の補助） |
| `Sources/VDNotes/RawNote.swift` | `RawPart`、`RawNote`（render / baseName / folder） |
| `Tests/VDNotesTests/SanitizeTests.swift` | SN-1〜SN-9 |
| `Tests/VDNotesTests/NoteTemplateTests.swift` | テンプレート |
| `Tests/VDNotesTests/FrontmatterTests.swift` | 書き出し・読み取り・退避 |
| `Tests/VDNotesTests/RawNoteTests.swift` | Raw ノートの固定例 |
| `Tests/VDNotesTests/NotesFixtures.swift` | §5 の共通の準備（T-27・T-28 も使う） |
| `Tests/VDNotesTests/RawNoteGoldenTests.swift` | golden（T-25 の `sanitize`・`frontmatter`・`raw_note`・`note_filename`（`raw` / `rawFolder`））との比較 |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 4 キーを消す（§5.6） |

`Package.swift` の `VDNotes` ターゲットの依存は T-01 で `VDContract`, `VDCore`, `Yams` になっている（変更しない）。

## 4. 仕様

### 4.0 全体の規則（VDNotes の全ファイルに適用）

- **文字列の走査・前方一致・後方一致・長さは Unicode スカラー単位**で行う（`String.unicodeScalars`）。`Character`（書記素）単位の `hasPrefix` / `count` / `dropLast` を使わない
  （例: `"---\u{0301}"` は書記素では `"-́"` で終わるので `hasPrefix("---")` が偽になるが、Python の `^---` は一致する）
- 空白の判定・strip・空白の畳み込みは `PyText`（T-45）。Swift の `trimmingCharacters(in: .whitespacesAndNewlines)` を使わない
- 出力の改行は LF（`"\n"`）だけ。BOM を付けない
- この節の関数はすべて**純粋関数**（Raw ノートの描画はファイルを読み書きしない）。例外を投げない

### 4.1 `ScalarText.swift`（internal）

```swift
// Unicode スカラー単位の文字列補助（PLAN §5.7）。Character 単位の比較を VDNotes で使わないための 1 か所。
enum ScalarText {
    /// s のスカラー列が prefix のスカラー列で始まるか
    static func hasPrefix(_ s: String, _ prefix: String) -> Bool
    /// s のスカラー列が suffix のスカラー列で終わるか
    static func hasSuffix(_ s: String, _ suffix: String) -> Bool
    /// "\n"（U+000A）だけで分割する。空の部分列を省かない（"a\n" → ["a", ""]）
    static func splitLF(_ s: String) -> [String]
    /// 末尾の "\n"（U+000A）を全部取り除く（Python の s.rstrip("\n")）
    static func trimTrailingLF(_ s: String) -> String
    /// スカラー集合に含まれるスカラーを取り除く
    static func removing(_ s: String, _ set: Set<Unicode.Scalar>) -> String
    /// スカラーを置き換える（map に在るものを置換、他はそのまま）
    static func replacing(_ s: String, _ map: [Unicode.Scalar: Unicode.Scalar]) -> String
    /// スカラー列から文字列を作る（`String(String.UnicodeScalarView(scalars))`）
    static func string(_ scalars: [Unicode.Scalar]) -> String
}
```

- 実装はすべて `Array(s.unicodeScalars)` を作って比較・組み立てる。結果は `string(_:)`（= `String(String.UnicodeScalarView(scalars))`）で作る

### 4.2 `Sanitize.swift`

```swift
// ファイル名の sanitize（PLAN §8.6 の SN-1〜SN-9。voicedock notes.py:42-105 と同じ順）。ファイル名にだけ適用する。
public enum Sanitize {
    /// SN-8 の代替名
    public static let fallbackName = "Untitled"
    /// SN-9 の予約名（大文字）。22 個
    public static let reservedNames: Set<String>   // "CON","PRN","AUX","NUL","COM1"…"COM9","LPT1"…"LPT9"
    public static func fileName(_ name: String, maxBytes: Int) -> String
}
```

`fileName` の手順（**この順**。どれも前の結果に適用する）:

1. **SN-1**: `s = PyText.nfc(name)`
2. **SN-2**: U+0000〜U+001F と U+007F のスカラーを取り除く（U+0080〜U+009F は残す）
3. **SN-3**: `/` `\` `:` `*` `?` `"` `<` `>` `|` の各スカラーを `-`（U+002D）に置き換える
4. **SN-4**: `#` `^` `[` `]` のスカラーを取り除く
5. **SN-5**: `s = PyText.strip(PyText.collapseWhitespace(s))`（Python の `re.sub(r"\s+", " ", s).strip()`）
6. **SN-6**: `s = PyText.strip(s, chars: ["."])`（前後の ASCII `.` だけ）
7. **SN-7**: `scalars = Array(s.unicodeScalars)`。`while !scalars.isEmpty && utf8Bytes(scalars) > maxBytes { scalars.removeLast() }` の後、
   **削ったかどうかにかかわらず** `while let last = scalars.last, PyText.isCombining(last) { scalars.removeLast() }`。
   `utf8Bytes` は各スカラーの UTF-8 長（`<0x80`→1、`<0x800`→2、`<0x10000`→3、それ以外 4）の合計
8. **SN-8**: 空なら `"Untitled"`
9. **SN-9**: `s.uppercased()` が `reservedNames` に含まれるなら `s + "_"`（SN-7 の後なので上限を 1 バイト超えうる。voicedock どおり）

- `maxBytes` は `ObsidianConfig.maxTitleBytes`（1〜255。CV-16）。0 以下が渡されたら SN-7 は全部削る（結果は `Untitled`）
- タグ・リンク候補・フォルダには適用しない（呼び手の責任。T-27）

### 4.3 `Templates.swift`

```swift
// フォルダ名・ファイル名のテンプレート（PLAN §8.6。voicedock raw.py:97-116）。
public enum NoteTemplate {
    public static func render(_ template: String, day: LocalDate) -> String
}
```

- `template` の中の `{yyyymmdd}` を `day.stamp`（`20260829`）、`{date}` を `day.dashed`（`2026-08-29`）、`{time}` を `000000` に、**この順に**全部置換する（`replacingOccurrences(of:with:options: .literal)`）
- `.literal` を必ず付ける。既定の比較は正準等価・書記素単位で、`{date}\u{301}` のように結合文字が続くプレースホルダを置換しない（Python の `str.replace` は置換する。§4.0・PLAN §5.7。Xcode 27.0 で確認）
- それ以外の `{…}` は残す（CV-13 が起動時に弾く）。sanitize はしない

### 4.4 `PyStr.swift`（internal）

```swift
// Python の str() と同じ文字列化（frontmatter の鍵・timeline の行で使う）。YAML（Yams）と PyJSON.parse（T-45）の Foundation の値を受ける。
enum PyStr {
    static func describe(_ value: Any) -> String
}
```

| 値 | 結果 |
|---|---|
| `String` | そのまま |
| `Bool`（Swift の Bool、または `PyJSON.isBool` が真の `NSNumber`） | `"True"` / `"False"` |
| `Int`、または浮動小数でない `NSNumber` | 10 進（`String(int)`） |
| `Double`、または浮動小数の `NSNumber`（`CFNumberIsFloatType`） | 有限なら `PyJSON.formatDouble(v)`（T-45。Python の `repr` と一致: `1.0`、`1e+16`、`9007199254740994.0`。`Double.description` は 2^53〜1e16 で違うので使わない）。NaN → `"nan"`、+∞ → `"inf"`、−∞ → `"-inf"`（Python の `str(float)`。`formatDouble` の `NaN` / `Infinity` とは違う） |
| `NSNull` / nil | `"None"` |
| それ以外（配列・辞書） | `String(describing:)`（Python と一致しないが、partkey と一致することはない） |

判定の順は表の上から（`Bool` を `Int` より先に見る）。

### 4.5 `Frontmatter.swift`

```swift
// frontmatter の書き出し（自前）と読み取り（Yams）。PLAN §8.6 / NOTE-06。voicedock notes.py:108-220 と同じ出力。
import Foundation
import Yams

public enum FrontmatterValue: Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case null
    case array([String])
}

public enum Frontmatter {
    static let delimiter = "---"   // internal
    // フィールド名（00-api-map §9。書き手（T-26・T-27）と検証側（T-28・T-36）が同じ定数を使う）
    public static let keySessionKey = "voicedock_session_key"
    public static let keyRecordingKeys = "voicedock_recording_keys"
    public static let keyFailedParts = "voicedock_failed_parts"
    public static let keySkippedParts = "voicedock_skipped_parts"
    public static let keyType = "type"

    public static func render(_ fields: [(String, FrontmatterValue)]) -> String
    public static func quote(_ s: String) -> String
    public static func escapeBody(_ s: String) -> String
    public static func split(_ text: String) -> (front: String, body: String)?
    public static func parse(_ text: String) -> [String: Any]?
    public static func recordingKeys(ofFile url: URL) -> [String]
    /// doc[key] が配列なら各要素を PyStr.describe したもの。配列でなければ（無い・文字列など）空配列
    public static func stringList(_ doc: [String: Any], _ key: String) -> [String]
}
```

**`quote(s)`**（notes.py:121-130）:
1. `\`（U+005C）を `\\` に置換（`replacingOccurrences(of:with:options: .literal)`。§4.3 と同じ理由で `.literal` を付ける）
2. `"` を `\"` に置換（同じく `.literal`）
3. U+0000〜U+001F と U+007F を取り除く（C1・U+2028・U+2029 は残す）
4. `"\"" + 結果 + "\""`

**`render(fields)`**（notes.py:133-161）:
```text
lines = ["---"]
for (key, value) in fields（渡された順）:
  .string(s) → key + ": " + quote(s)
  .bool(b)   → key + ": " + (b ? "true" : "false")
  .int(n)    → key + ": " + String(n)
  .null      → key + ": null"
  .array(a)  → a.isEmpty ? key + ": []" : key + ":" の行の後に、要素ごとに "  - " + quote(要素)
lines.append("---")
return lines.joined(separator: "\n") + "\n"
```

**`escapeBody(s)`**（notes.py:214-220。`re.sub(r"^---", r"\---", s, flags=re.M)` と同じ）:
`ScalarText.splitLF(s)` の各行について、行のスカラー列が `---` で始まるなら先頭に `\` を 1 つ足し、`"\n"` でつなぎ直す。
（`\r` の直後は対象外。`----x` → `\----x`、`a --- b` は変わらない）

**`split(text)`**（notes.py:164-175。Python の `re.search(r"^---\s*$", rest, re.M)` と同じ結果を正規表現を使わずに出す）:
1. `text` のスカラー列が `"---\n"` で始まらなければ nil
2. `rest` = 先頭の 4 スカラーを除いたスカラー列（配列 `r`、長さ `n`）
3. 行頭の位置 `p`（`p == 0` か `r[p-1] == "\n"`）を小さい順に見て、`r[p..<p+3] == "---"` のものについて:
   - `L` = 位置 `p+3` から続く `PyText.isSpace` のスカラーの個数（`\n` も空白に含む）
   - `k` の候補 = `0...L` のうち「`p+3+k == n`」か「`r[p+3+k] == "\n"`」を満たすもの。候補が無ければ次の `p` へ
   - 候補の最大を `kMax` として、`front = r[0..<p]`、`body = r[(p+3+kMax)..<n]` を返す
4. どの `p` でも見つからなければ nil

- 例: `"---\na: 1\n---   \nbody"` → `("a: 1\n", "\nbody")`。`"---\nunterminated\n"`・`" ---\na: 1\n---\n"`・`"--\na: 1\n--\n"`・`""` → nil
- `body` は検証では使わない（`split` が成功したかと `front` だけを使う）が、上の規則どおりに返す

**`parse(text)`**（notes.py:178-191）:
1. `split(text)` が nil なら nil
2. `do { let v = try Yams.load(yaml: front) } catch { return nil }`（Yams の例外は全部 nil。**重複したキーで Yams が投げる場合も nil**。PyYAML は後勝ちだったが、読めないものは安全側に倒す）
3. `v` が `[AnyHashable: Any]` なら、キーが `String` の要素だけを取り出した `[String: Any]` を返す。`[String: Any]` ならそのまま。それ以外（nil・配列・スカラー）は nil
- 例外を投げない。空の frontmatter（`"---\n---\n"`）は Yams が nil を返すので nil

**`recordingKeys(ofFile:)`**（notes.py:194-211。削除条件 §8.9.1 の `frontmatterKeys`）:
1. `Data(contentsOf: url)` が失敗 → `[]`
2. `String(validating: data, as: UTF8.self)` が nil → `[]`
3. `parse(text)` が nil → `[]`
4. `stringList(doc, keyRecordingKeys)` を返す

### 4.6 `RawNote.swift`

```swift
// Raw ノート（文字起こし生データ）の描画（PLAN §8.6。voicedock raw.py:135-218 とバイト一致）。
public struct RawPart: Sendable {
    public let partkey: String
    public let startedAt: String      // DB の recordings.started_at（オフセット付き ISO。例 2026-08-29T07:12:04+09:00）
    public let endedAt: String?       // DB の recordings.ended_at
    public let segments: [AbsoluteSegment]   // at = started_at + start（ミリ秒）、与えられた順に描く
    public let zone: ZonedTime        // startedAt を Instant に直すため（並べ替え）
    public init(partkey: String, startedAt: String, endedAt: String?, segments: [AbsoluteSegment], zone: ZonedTime)
}

public enum RawNote {
    public static let noteType = "voice-raw"
    public static let sourceLabel = "DJI Mic 3"
    public static let intro = "> 自動文字起こしの生データ。未編集。"
    public static func title(_ day: LocalDate) -> String       // "# " + day.dashed + " の文字起こし（生データ）"（括弧は U+FF08 / U+FF09）
    public static func render(parts: [RawPart], day: LocalDate, sessionKey: String, config: ObsidianConfig) -> String
    public static func baseName(config: ObsidianConfig, day: LocalDate) -> String
    public static func folder(config: ObsidianConfig, day: LocalDate) -> String
}
```

**`baseName`** = `Sanitize.fileName(NoteTemplate.render(config.raw.filenameTemplate, day: day), maxBytes: config.maxTitleBytes)`（`.md` を含まない。既定 `2026-08-29 raw`）

**`folder`** = `NoteTemplate.render(config.raw.folderTemplate, day: day)`（Vault からの相対。sanitize しない。既定 `Daily/Voice/Raw/20260829`）

**`render`** の手順:
1. **並べ替え**: 各 Part の並べ替えの鍵を `(zone.parseISO(startedAt)?.epochMillis ?? Int64.min, partkey)` とし、昇順に安定ソートする（Python の `sorted(key=(started_at, partkey))`。瞬間で比べる）
2. **frontmatter**:
   ```swift
   Frontmatter.render([
       (Frontmatter.keyType, .string(RawNote.noteType)),
       (Frontmatter.keySessionKey, .string(sessionKey)),
       (Frontmatter.keyRecordingKeys, .array(ordered.map(\.partkey))),
       ("date", .string(day.dashed)),
       ("parts", .int(ordered.count)),
       ("source", .string(RawNote.sourceLabel)),
   ])
   ```
3. **本文の行**: `lines = ["", title(day), "", intro, ""]`。各 Part について順に:
   1. `config.raw.partBoundaryHeading` が真なら `lines += ["## " + range, ""]`。
      `range = hhmm(startedAt) + "–" + (endedAt.map(hhmm) ?? "")`（`–` は U+2013）。`hhmm(s) = ISOWallClock.hhmm(s) ?? ""`（**保存された文字列の壁時計**。秒は捨てる）
   2. 区間の描画（`interval = config.raw.timestampIntervalSeconds`）:
      ```text
      chunk = []; nextMark: Instant? = nil
      for seg in part.segments:
        text = PyText.strip(seg.text); if text.isEmpty { continue }
        if interval > 0 && (nextMark == nil || seg.at >= nextMark!):
          if !chunk.isEmpty { lines += [chunk.joined(separator: " "), ""]; chunk = [] }
          lines += ["### " + hhmmss(seg.at, fixed), ""]
          nextMark = seg.at.adding(seconds: interval)
        chunk.append(text)
      if !chunk.isEmpty { lines += [chunk.joined(separator: " "), ""] }
      ```
      - `###` の時刻は**実際の segment の時刻**（NOTE-04）。本文の無い Part でも `##` 見出しは出る
      - `fixed = ZonedTime(fixedOffsetSeconds: offsetOf(part.startedAt))`（Part ごとに 1 つ。T-10）。`hhmmss(instant, fixed) = ISOWallClock.hhmmss(fixed.iso(instant)) ?? ""`
        （**Part の started_at の固定オフセットでの壁時計**。voicedock は `started_at + timedelta` で固定オフセットのまま足していた。タイムゾーンの規則（夏時間）では計算しない。PLAN §5.7・X-32。golden `raw_note/dst_fixed_offset`）
      - `offsetOf(iso)`（internal）: 文字列の末尾が `Z` なら 0。末尾 6 スカラーが `±HH:MM` なら `±(HH*3600 + MM*60)`。どちらでもなければ 0
      - `nextMark` の比較は `Instant`（ミリ秒の整数）で行う（等号の境界を Python と同じにする）
4. **本文**: `body = ScalarText.trimTrailingLF(lines.joined(separator: "\n")) + "\n"`
5. 返り値 `frontmatter + Frontmatter.escapeBody(body)`

- 載せる Part の選別（`rawNoteMembers` かつ transcript が読める。`RawNoteMembership`）は呼び手（T-29）が行う。ここは渡されたものを全部描く
- `parts` が空でも描ける（`voicedock_recording_keys: []`、`parts: 0`、本文は導入行で終わる）

## 5. テスト

共通の準備（`Tests/VDNotesTests/NotesFixtures.swift` に置き、T-27・T-28 も使う）。強制アンラップ `!` は `swift format` の NeverForceUnwrap が落とすので、失敗しうるものは `get throws` の計算プロパティ・`throws` の関数にして `try #require(…)` で取り出す（呼び手は `try NotesFixtures.day` のように書く）:
- `NotesFixtures.jst = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))`（`get throws`）
- `NotesFixtures.day = try #require(LocalDate(year: 2026, month: 8, day: 29))`（`get throws`）、`sessionKey = "DJIMIC3:20260829"`
- `keyA = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"`、`keyB = "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"`
- `at(h, m, s) throws -> Instant` = `try #require(try jst.parseISO(String(format: "2026-08-29T%02d:%02d:%02d+09:00", h, m, s)))`
- `seg(_ at: Instant, _ text: String, secs: Int = 10) -> AbsoluteSegment(at: at, endAt: at.adding(seconds: secs), text: text)`
- `partA`（`get throws`）= `RawPart(partkey: keyA, startedAt: "2026-08-29T07:12:04+09:00", endedAt: "2026-08-29T07:42:04+09:00", segments: [seg(at(7,12,4), "おはようございます。"), seg(at(7,17,4), "削除条件を整理します。")], zone: jst)`
- `partB`（`get throws`）= `RawPart(partkey: keyB, startedAt: "2026-08-29T07:42:10+09:00", endedAt: "2026-08-29T08:12:10+09:00", segments: [seg(at(7,42,10), "続きです。")], zone: jst)`
- `config()` = `AppConfig.defaults(timeZone: "Asia/Tokyo").obsidian`（変更は `var` で書き換える）

### 5.1 `SanitizeTests.swift`（`@Suite("Sanitize")`）

入力 → 期待（`maxBytes` の指定が無ければ 180）。パラメータ化テストの引数は下の表をそのままコードに書く（実装を呼んで作らない）。

| テスト（表示名） | 関数名 | 入力 → 期待 |
|---|---|---|
| `SN-1 NFD を NFC に揃える` | `sn1NormalizesToNFC` | NFD の `がぎぐ`（`か\u{3099}き\u{3099}く\u{3099}`）→ `がぎぐ`（NFC） |
| `SN-2 制御文字を取り除く` | `sn2RemovesControlCharacters` | `a\u{0}b`・`a\u{1}b`・`a\u{1f}b`・`a\u{7f}b` → `ab`。`a\u{a0}b` は `ab` にならない（→ `a b`） |
| `SN-2 タブと改行は SN-5 より先に消える` | `sn2RemovesTabsBeforeSN5` | `a\t\tb` → `ab`、`a\nb` → `ab`、`a  b` → `a b` |
| `SN-3 パス区切りと Windows の禁止文字を - にする` | `sn3ReplacesForbiddenCharacters` | `a/b` `a\b` `a:b` `a*b` `a?b` `a"b` `a<b` `a>b` `a\|b` → `a-b`、`a/b:c*d?e"f<g>h\|i` → `a-b-c-d-e-f-g-h-i`、`a\|b<c>d*e?f"g\h` → `a-b-c-d-e-f-g-h` |
| `SN-3 は SN-5 より先` | `sn3RunsBeforeSN5` | `a / b` → `a - b`、`  a / b  ` → `a - b` |
| `SN-4 は SN-5 より先` | `sn4RunsBeforeSN5` | `a # b` → `a b`、`[ x ]` → `x`（逆順だと `a  b`・` x ` が残る） |
| `SN-4 Obsidian の記法文字を取り除く` | `sn4RemovesObsidianSyntax` | `a#b` `a^b` `a[b` `a]b` → `ab`、`[[Note]]` → `Note`、`a#b^c[d]e` → `abcde` |
| `SN-5 空白を畳んで前後を落とす` | `sn5CollapsesWhitespace` | `  a   b  ` → `a b`、`x\u{3000}\u{3000}y` → `x y`、`a\u{a0}b\u{200b}c` → `a b\u{200b}c`（ZWSP は空白でない） |
| `SN-6 前後の . を落とす` | `sn6StripsDots` | `.hidden.` → `hidden`、`...a...` → `a`、`..hidden..` → `hidden`、`a.b.c` → `a.b.c` |
| `SN-7 UTF-8 のバイト数で切る` | `sn7TruncatesByUTF8Bytes` | `あ`×80 → `あ`×60（180 バイト）、`あ`×70 → `あ`×60、`a`×178+`é` → そのまま（180 バイト）、`a`×179+`é` → `a`×179、`é`×100 → `é`×90、`short` → `short` |
| `SN-7 多バイト文字を割らない` | `sn7DoesNotSplitMultibyte` | `あ`×200（maxBytes 10）→ `あ`×3（9 バイト） |
| `SN-7 末尾の結合文字を必ず削る` | `sn7DropsTrailingCombiningMarks` | `q\u{301}` → `q`（切り詰め不要でも削る）、`あああ\u{301}`（maxBytes 11）→ `あああ`、`あああ\u{301}`（maxBytes 10）→ `あああ`（スカラー単位で結合文字だけを削る。書記素単位だと `ああ` になる） |
| `SN-7 結果が結合文字で終わらない` | `sn7NeverEndsWithCombiningMark` | NFD の `が`×5 を maxBytes 1〜19 で sanitize し、結果が `Untitled` でなければ末尾のスカラーが結合文字でない（NFC で合成されるので実際は `が` 単位で切れる） |
| `SN-8 空なら Untitled` | `sn8FallsBackWhenEmpty` | `""` `"   "` `"..."` `"###"` `"\u{0}\u{1}"` `"[[]]"` → `Untitled` |
| `SN-9 予約名に _ を付ける` | `sn9SuffixesReservedNames` | 22 個の予約名それぞれ → 名前 + `_` |
| `SN-9 大小を区別しない` | `sn9IsCaseInsensitive` | `con` `Con` `cOm1` `lpt9` → それぞれ + `_`、`Com1` → `Com1_`、`LPT9.` → `LPT9_`、`NUL ` → `NUL_` |
| `SN-9 予約名でないものは変えない` | `sn9LeavesNonReserved` | `CONSOLE` → `CONSOLE`、`COM10` → `COM10` |
| `SN-9 は SN-7 の後` | `sn9RunsAfterSN7` | `CON`（maxBytes 3）→ `CON_`（4 文字） |
| `予約名の一覧は 22 個` | `reservedNamesMatchPlan` | `Sanitize.reservedNames` が CON・PRN・AUX・NUL・COM1〜9・LPT1〜9 と一致 |
| `絵文字は残る` | `emojiSurvives` | `会議 🎤 メモ` → そのまま |
| `崩れた LLM のタグでも使える名前になる` | `realisticHostileTag` | ` #開発/設計: "VoiceDock" [メモ] ` → `開発-設計- -VoiceDock- メモ` |
| `テンプレートの結果を sanitize する` | `hostileTemplateIsSanitized` | `{date}:raw` → `{date}-raw`、`2026-08-29 raw` → そのまま、`tab\there\u{7f}` → `tabhere` |

### 5.2 `NoteTemplateTests.swift`

| 表示名 | 関数名 | 期待 |
|---|---|---|
| `プレースホルダを埋める` | `rendersPlaceholders` | `Daily/Voice/Raw/{yyyymmdd}` → `Daily/Voice/Raw/20260829`、`{date}` → `2026-08-29`、`x/{time}` → `x/000000`、`a/{yyyymmdd}/{date}` → `a/20260829/2026-08-29` |
| `未知のプレースホルダは残す` | `leavesUnknownPlaceholders` | `{date} raw {part}` → `2026-08-29 raw {part}` |
| `結合文字が続くプレースホルダも埋める（スカラー単位）` | `rendersPlaceholderBeforeCombiningMark` | `{date}\u{301}` → `2026-08-29\u{301}`（スカラー列で比べる） |
| `CE obsidian.raw.filenameTemplate が Raw の基本名になる` | `rawFolderAndBaseName` | 既定の設定で `RawNote.folder` → `Daily/Voice/Raw/20260829`、`RawNote.baseName` → `2026-08-29 raw`、`filenameTemplate = "{date}:raw"` で `2026-08-29-raw` |
| `CE obsidian.maxTitleBytes で基本名が切れる` | `ceMaxTitleBytes` | 既定の `filenameTemplate` のまま `maxTitleBytes = 10` → `RawNote.baseName` == `2026-08-29`（既定の 180 なら `2026-08-29 raw`） |

### 5.3 `FrontmatterTests.swift`

| 表示名 | 関数名 | 準備 → 期待 |
|---|---|---|
| `書き出しは voicedock と同じバイト列` | `renderMatchesVoicedockBytes` | `render([("s", .string("a\"b\\c\u{1}d\u{7f}e\u{85}f")), ("i", .int(3)), ("b", .bool(true)), ("n", .null), ("e", .array([])), ("l", .array(["x", "y\""]))])` == `"---\ns: \"a\\\"b\\\\cde\u{85}f\"\ni: 3\nb: true\nn: null\ne: []\nl:\n  - \"x\"\n  - \"y\\\"\"\n---\n"`（voicedock の実測から float の行を除いたもの） |
| `文字列は必ず二重引用符で囲む` | `stringsAreAlwaysQuoted` | `a: "plain"`、`voicedock_session_key: "DJIMIC3:20260829"` を含む |
| `制御文字は値から落とす` | `quoteStripsControlCharacters` | `quote("a\u{0}b\u{1f}c")` == `"\"abc\""` |
| `quote はスカラー単位で置換する（結合文字が続く \ と "）` | `quoteUsesScalars` | `quote("a\\\u{301}\"\u{301}")` == `"\"a\\\\\u{301}\\\"\u{301}\""`（スカラー列で比べる） |
| `崩れやすい値が書いて読んで戻る` | `trickyValuesRoundTrip` | `say "hi"`・`back\slash`・`colon: here`・`#hash`・`- dash`・`[bracket]`・`{brace}`・`@at` を `render([("tag", .string(v))]) + "body\n"` にして `parse(...)?["tag"] as? String == v` |
| `配列はブロック形式` | `listsAreBlockStyle` | `voicedock_recording_keys:\n` と `  - "<keyA>"\n` を含み、`[` を含まない |
| `空配列は []` | `emptyListIsBrackets` | `("k", .array([]))` → `k: []` |
| `形の崩れた frontmatter は nil` | `malformedFrontmatterIsNil` | `""`・`"no frontmatter\n"`・`"---\nunterminated\n"`・`"--\na: 1\n--\n"`・`" ---\na: 1\n---\n"` → `parse` が nil |
| `壊れた YAML は nil` | `brokenYAMLIsNil` | `"---\na: [unclosed\n---\nbody\n"` → nil |
| `辞書でない frontmatter は nil` | `nonMappingIsNil` | `"---\n- a\n- b\n---\nbody\n"` → nil |
| `split は閉じ行の後ろの空白を許す` | `splitAllowsTrailingSpaces` | `split("---\na: 1\n---   \nbody")` == `("a: 1\n", "\nbody")` |
| `recordingKeys はフィールドを読む` | `recordingKeysReadsField` | keyA・keyB を載せたノートを一時ファイルに書き（テストでは `Data.write` を使ってよい）、`[keyA, keyB]` |
| `読めないときは空` | `recordingKeysEmptyWhenUnreadable` | 中身 `broken`・`"---\na: 1\n---\nbody\n"`・`"---\n{}\n---\n"`・不正な UTF-8（`0xff 0xfe`）・存在しないファイル → `[]` |
| `鍵の要素は文字列化する` | `recordingKeysStringifiesElements` | `voicedock_recording_keys:\n  - 123\n  - true\n  - "x"` → `["123", "True", "x"]` |
| `浮動小数は Python の repr で文字列化する` | `pyStrUsesPythonRepr` | `PyStr.describe(9007199254740994.0)` == `"9007199254740994.0"`、`PyStr.describe(1.0)` == `"1.0"`、`PyStr.describe(Double.nan)` == `"nan"`、`PyStr.describe(-Double.infinity)` == `"-inf"` |
| `本文の行頭 --- を退避する` | `escapeBodyProtectsBoundary` | `escapeBody("a\n---\nb\n")` == `"a\n\\---\nb\n"`、`escapeBody("---\n")` == `"\\---\n"`、`escapeBody("---\na\n --- \n----x\n")` == `"\\---\na\n --- \n\\----x\n"` |
| `行中の --- は変えない` | `escapeBodyLeavesInlineDashes` | `"a --- b\n"` は変わらない。`"x\r---"` も変わらない |
| `結合文字が続く --- も退避する` | `escapeBodyUsesScalars` | `"---\u{301}x"` → `"\\---\u{301}x"` |
| `退避しない本文は境界を壊す` | `unescapedBodyBreaksBoundary` | `render([sessionKey]) + "body\n---\nmore\n"` の `split` の front に `body` が入らない（本文の `---` が境界になる）。`escapeBody` を通せば `parse` の session_key が一致 |

### 5.4 `RawNoteTests.swift`

固定例の期待値は voicedock@d3d595e の実出力（移植メモ V5 §3.4）をそのままリテラルで書く。

| 表示名 | 関数名 | 準備 → 期待 |
|---|---|---|
| `2 Part の Raw ノートは voicedock と同じ` | `twoPartsMatchVoicedock` | `render(parts: [partB, partA], …)` == 下の「期待 A」（渡す順によらない） |
| `終了時刻が無い Part` | `partWithoutEnd` | `RawPart(keyA, "2026-08-29T07:12:04+09:00", nil, [seg(at(7,12,4),"  x  "), seg(at(7,13,0),"   "), seg(at(7,13,4),"---"), seg(at(7,18,3),"y"), seg(at(7,18,4),"z")])` の本文が `"## 07:12–\n\n### 07:12:04\n\nx ---\n\n### 07:18:03\n\ny z\n"` で終わる |
| `CE obsidian.raw.partBoundaryHeading false で Part の ## 見出しが消える` | `cePartBoundaryHeading` | `partBoundaryHeading = false` だけを変えて `[partA, partB]` → `^## ` の行が無く、`### ` の行は「期待 A」と同じ数だけ在る（既定の true では `## 07:12–07:42` が在る） |
| `CE obsidian.raw.timestampIntervalSeconds を変えると ### の刻みが変わる` | `ceTimestampIntervalSeconds` | §5.4 の `timestampIntervalUsesActualTimes` と同じ入力（`07:00` から 2 分刻みの 10 区間）を `timestampIntervalSeconds = 600` で → `### ` の行が `07:00:00`・`07:10:00` の 2 つ（`07:10:00 >= 07:00:00 + 600 秒`）（既定の 300 なら 4 つ）。`0` なら `### ` が 1 つも無い |
| `見出しを無効にした設定` | `headingsDisabled` | `timestampIntervalSeconds = 0`、`partBoundaryHeading = false` で `[partA, partB]` → 本文が `"> 自動文字起こしの生データ。未編集。\n\nおはようございます。 削除条件を整理します。\n\n続きです。\n"` で終わる。`^## ` も `### ` も無い |
| `Part が 0 件でも描ける` | `noPartsStillRenders` | frontmatter が `voicedock_recording_keys: []` と `parts: 0` を含み、本文が導入行で終わる（`"…\n\n> 自動文字起こしの生データ。未編集。\n"`） |
| `本文の無い Part でも ## は出る` | `partWithoutTextKeepsHeading` | `[partA, partB の区間を "   " だけにしたもの]` → 全体が `"## 07:42–08:12\n"` で終わる |
| `300 秒ごとの見出しは実際の区間の時刻` | `timestampIntervalUsesActualTimes` | `07:00` から 2 分刻みの 10 区間（`"<m> 分"`）→ `### ` の行が `07:00:00`・`07:06:00`・`07:12:00`・`07:18:00` の 4 つ |
| `ちょうど 300 秒で次の見出し` | `boundaryIsInclusive` | 区間 `07:00:00` と `07:05:00` → 見出しが 2 つ（`seg.at >= nextMark`） |
| `ミリ秒の境界` | `millisecondBoundary` | 区間 `07:00:00.000` と `07:04:59.999` → 見出し 1 つ、`07:05:00.000` を足すと 2 つ |
| `同じ見出しの下は半角空白でつなぐ` | `segmentsJoinWithSingleSpace` | 見出しの下に `"### 07:12:04\n\nおはようございます。\n\n### 07:17:04\n\n削除条件を整理します。"` を含む |
| `空の区間は見出しを作らない` | `emptySegmentsAreDropped` | `[seg(07:00, "   "), seg(07:00:30, "本文")]` → `### ` が 1 つ |
| `本文は加工しない（strip だけ）` | `bodyIsNotProcessed` | 区間 `"  えーと、あの… 「テスト」だ。  "` → 本文に `えーと、あの… 「テスト」だ。` を含む |
| `行頭 --- の区間は退避される` | `leadingDashesAreEscaped` | 区間 `"---"` → `\---` を含み、`Frontmatter.parse` の session_key が一致 |
| `frontmatter の項目` | `frontmatterFields` | `Frontmatter.parse` で `type == "voice-raw"`、鍵 == `[keyA, keyB]`、`date == "2026-08-29"`、`parts == 2`、`source == "DJI Mic 3"`、`voicedock_session_id` を含まない |
| `見出しの時刻は保存文字列のオフセット` | `wallClockUsesStoredOffset` | `startedAt = "2026-08-29T07:12:04+09:00"`・`zone` を UTC にした RawPart でも `## 07:12–` と `### 07:12:04` になる |
| `決定的` | `deterministic` | 同じ入力で 2 回描いて同じ |

期待 A（`twoPartsMatchVoicedock`。改行は `\n`）:
```text
---
type: "voice-raw"
voicedock_session_key: "DJIMIC3:20260829"
voicedock_recording_keys:
  - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
  - "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"
date: "2026-08-29"
parts: 2
source: "DJI Mic 3"
---

# 2026-08-29 の文字起こし（生データ）

> 自動文字起こしの生データ。未編集。

## 07:12–07:42

### 07:12:04

おはようございます。

### 07:17:04

削除条件を整理します。

## 07:42–08:12

### 07:42:10

続きです。
```
（最後の行の後に `\n` が 1 つ。リテラルは `"""` で書き、末尾の改行を含める）

### 5.5 `RawNoteGoldenTests.swift`（`@Suite("RawNote golden")`）

T-25 のグループを使う（グループ名・ケース・入力のキーは T-25 §4.3〜§4.5・§4.9 が正）。ケース名を列挙せず `try Golden.cases("<group>")` をパラメータ化テストの引数に渡して**全部**回し、
グループごとに「ケースが在る」テスト（`#expect(!(try Golden.cases("<group>")).isEmpty)`）を置く（空で緑にしない。T-25 §4.11・TEST-28）。`.md` / `.out` は `GoldenAssert.matches`、`.json` は `GoldenAssert.matchesJSON`（違えば unified diff）。
共通: `config = try GoldenConfig.make(item)`（T-09）、`day = LocalDate(dashed: try item.string("day"))!`、`zone = ZonedTime(timeZone: TimeZone(identifier: try item.string("timeZone"))!)`。

| 関数名 / 表示名 | グループ（ケース数） | 実際の値 |
|---|---|---|
| `goldenSanitize(item:)` / 「golden sanitize」 | `sanitize`（38、`.out`） | `Sanitize.fileName(try item.string("input"), maxBytes: try item.int("maxBytes"))` |
| `goldenFrontmatter(item:)` / 「golden frontmatter」 | `frontmatter`（12） | `kind` が `render` → `Frontmatter.render(fields)`（`fields` の各 `[キー, 型付きの値]` を `["s", 文字列]` → `.string`・`["i", 整数]` → `.int`・`["b", 真偽]` → `.bool`・`["n"]` → `.null`・`["a", [文字列…]]` → `.array` に写す。順は配列のまま）、`quote` → `Frontmatter.quote(text)`、`escapeBody` → `Frontmatter.escapeBody(text)`（以上 `.out`）、`split` → `Frontmatter.split(text)` を `{"front": …, "body": …}` か `null` にした `.json` |
| `goldenRawNote(item:)` / 「golden raw_note」 | `raw_note`（9、`.md`） | `parts` の各 `{partkey, startedAt, endedAt, segments}` を `RawPart(partkey:, startedAt:, endedAt:, segments: 各 {startMs, endMs, text} → AbsoluteSegment(at: base.adding(milliseconds: startMs), endAt: base.adding(milliseconds: endMs), text:), zone: zone)`（`base = zone.parseISO(startedAt)!`）にし、`RawNote.render(parts:day:sessionKey: try item.string("sessionKey"), config: config.obsidian)` |
| `goldenRawNoteFilename(item:)` / 「golden note_filename（Raw）」 | `note_filename`（8 のうち `kind` が `raw` / `rawFolder`。`.out`） | `raw` → `RawNote.baseName(config: config.obsidian, day:)`、`rawFolder` → `RawNote.folder(config: config.obsidian, day:)`。`daily` / `dailyFolder` は何もせずに返す（T-27 の `goldenDailyFilename` が確かめる） |
| `goldenGroupsHaveCases` / 「golden sanitize・frontmatter・raw_note・note_filename のケースが在る」 | 4 グループ | どれも空でない |

### 5.6 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`obsidian.maxTitleBytes`・`obsidian.raw.filenameTemplate`・`obsidian.raw.timestampIntervalSeconds`・`obsidian.raw.partBoundaryHeading` の 4 行を消す（CE テストは §5.2・§5.4）。`obsidian.raw.folderTemplate` は T-33 が消す（T-33 は取り下げ）。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| SN-3 と SN-5 の順を入れ替える | （落ちない。SN-3 は空白でないスカラーを `-` に 1 対 1 で置き換え、SN-5 は空白だけに作用するので、2 つは可換。実装時に確認。`sn3RunsBeforeSN5` は voicedock の docstring の例の写し） |
| SN-4 を SN-5 の後に移す | `sn4RunsBeforeSN5` |
| SN-7 の「削ったかどうかにかかわらず」をやめ、切り詰めたときだけ結合文字を削る | `sn7DropsTrailingCombiningMarks` |
| SN-7 をスカラーではなく `Character` 単位で削る | `sn7DropsTrailingCombiningMarks`（`あああ\u{301}`・maxBytes 10） |
| SN-9 を SN-7 の前に移す | `sn9RunsAfterSN7` |
| SN-5 で前後の strip をやめる | `sn5CollapsesWhitespace` |
| `quote` で `\` と `"` の置換順を逆にする | `renderMatchesVoicedockBytes` |
| `quote` で C1（U+0085）も取り除く | `renderMatchesVoicedockBytes` |
| 空配列を `key:` だけにする | `emptyListIsBrackets` |
| `escapeBody` を `Character` の `hasPrefix` で書く | `escapeBodyUsesScalars` |
| `quote` の置換から `options: .literal` を外す | `quoteUsesScalars` |
| `NoteTemplate.render` の置換から `options: .literal` を外す | `rendersPlaceholderBeforeCombiningMark` |
| `split` で閉じ行の後ろの空白を許さない | `splitAllowsTrailingSpaces` |
| Raw の並べ替えから `partkey` を外し、渡された順のままにする | `twoPartsMatchVoicedock` |
| `seg.at >= nextMark` を `>` にする | `boundaryIsInclusive` |
| `###` の時刻を `zone`（タイムゾーンの規則）で計算する | `wallClockUsesStoredOffset`、`goldenRawNote`（`dst_fixed_offset`） |
| `PyStr.describe` の浮動小数を `Double.description` にする | `pyStrUsesPythonRepr` |
| 本文末尾の `\n` を落とさない | `noPartsStillRenders` |

## 7. 受け入れ条件

- [ ] 5 章のテストが全部通る（golden を含む）
- [ ] `Frontmatter.parse` / `recordingKeys` が例外を投げない（不正な入力のテストがある）
- [ ] VDNotes のソースに `Character` 単位の `hasPrefix` / `hasSuffix` / `count` / `dropLast` / `trimmingCharacters` が無い（レビューで確かめる）
- [ ] `make lint` が通る。PT-01〜22 に違反しない（VDNotes はファイルを書かない）
- [ ] 破壊による証明の結果を PR 本文に貼った

## 8. SPEC の変更

なし。

- （実装時に変更）当初は「`docs/SPEC.md` に SN-1〜SN-9 の表を足し、SPEC 同期テストの対象に SN を加える」と書いていたが、上位の PLAN に合わせて外した。理由: (1) PLAN §10.3 の SPEC 同期の表の対象（状態・遷移・復旧写像・エラーコード・CV・ND・RV・DR・ログイベント）に SN が無い、
  (2) `docs/SPEC.md` は `tools/spec/make-spec.py` の生成物で、SN を足すには make-spec.py・`SpecDocument`（TestSupport）・`SpecIDKind`・`TestNameIndex.pattern`・`SpecCoverage` の変更が要り、どれも §3「作るもの」に無い（T-05 の持ち物）。
  いまの `TestNameIndex.pattern` は SN を拾わないので、表示名 `SN-n` は SPEC 同期に違反しない。SN を SPEC 同期に加えるなら、PLAN §10.3 を直したうえで別の issue にする

## 9. マージ後にやること

なし

## 10. API 地図への変更提案

- `VDNotes`: `Frontmatter` に定数（`sessionKeyField` など 5 個）と `stringList(_:_:)` を追加（T-27・T-28・T-36 が同じ名前を使うため）→ 00-api-map に反映済み（2026-09-18）。名前は地図の `keySessionKey`・`keyRecordingKeys`・`keyFailedParts`・`keySkippedParts`・`keyType` に合わせた（`delimiter` は internal）
- `RawNote` に `noteType` / `sourceLabel` / `intro` / `title(_:)` の定数と関数を追加（テストと T-29 の突き合わせ用）→ 00-api-map に反映済み（2026-09-18）
- `RawPart.zone` は並べ替えのための `parseISO` にだけ使う。`###` の時刻は started_at の固定オフセットで計算する（DST のある地域で voicedock と一致させるため）→ 00-api-map に反映済み（2026-09-18）。PLAN §5.7 に合わせ `ZonedTime(fixedOffsetSeconds:)` で描く形に直した
- （実装時）§4.5 の `FrontmatterValue` は `Sendable, Equatable` だったが、00-api-map §9 は `Sendable` だけで、使い手も無いので `Sendable` にそろえた（地図の変更は要らない）
- （実装時・未反映）`Sanitize.fallbackName` と `Sanitize.reservedNames`（§4.2 の public 定数）が 00-api-map §9 の Sanitize の行にも §16 にも無い。§9 の行に足す（実装に不可欠ではない）
- （実装時・利用者に確認）`recordingKeys(ofFile:)` は voicedock の `read_text(encoding="utf-8")` と違い、改行を統一しない。そのため `---\r\n` で始まる CRLF のノートは `[]` になる（削除が起きない側への差）。PLAN 付録 D の X 項目に無い差分なので、意図した差分として足すかどうかを決める
