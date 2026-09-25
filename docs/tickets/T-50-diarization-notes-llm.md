# T-50 VDNotes / VDLLM: Raw の話者の行とチャンクの前置き

> （F-90、2026-09-24。コードレビューを受けた利用者の決定）チャンクの切り方と重なりは、LLM に送る行（`話者A: ` の前置きを含む。`Chunker.line`）の文字数で数えるように変えた。下の §4.2 の「文字数の計算と重なりは変えない（text だけを数える）」と §5・§6 の `countsOnlyText` は、`countsSpeakerPrefix`・`overlapCountsSpeakerPrefix`（ChunkerSpeakerTests）に置き換えた。話者なしの出力は変わらない。

| 項目 | 値 |
|---|---|
| ID | T-50 |
| Phase | 8.5（話者分離。F-89） |
| 前提 | T-47（`AbsoluteSegment.speaker`・`SpeakerLabel`） |
| 見積もり | Sources 約 60 行、Tests 約 250 行 |

## 1. 目的

区間に `speaker` が在る Part の Raw ノートを、話者の替わり目で `**話者A**: …` の行に分けて書く（PLAN §8.6）。
LLM に渡すチャンクの本文で、話者つきの区間の前に `話者A: ` を付ける（PLAN §8.5）。**話者の無い入力の出力はバイト単位で変えない**（golden）。

## 2. 参照

- PLAN §8.6（Raw の擬似コードと話者分離の段落・例）、§8.5（チャンク本文の話者分離の行）、§8.4.1、付録 D X-45
- 00-api-map §8・§9（`Chunker`・`RawNote`。公開 API は変えない）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDNotes/RawNote.swift`（変更） | `segmentLines` の話者の分岐 |
| `Sources/VDLLM/Chunker.swift`（変更） | `make` の前置き |
| `Tests/VDNotesTests/RawNoteSpeakerTests.swift` | |
| `Tests/VDLLMTests/ChunkerSpeakerTests.swift` | |

## 4. 仕様

### 4.1 `RawNote.segmentLines`

1. `part.segments` に `speaker != nil` が 1 つも無ければ、今のコードのまま（変更しない）
2. 在れば、`chunk: [String]` の代わりに `turns: [(speaker: String?, texts: [String])]` を持つ。
   - 区間ごとに `text = PyText.strip(seg.text)`、空なら飛ばす（今と同じ）
   - `###` の差し込みの条件は今と同じ。差し込む前に `turns` が空でなければ「塊を書き出す」
   - `turns.last` が在り、その `speaker` が `seg.speaker` と等しい（両方 nil も等しい。比べ方は `==`）なら、その `texts` に足す。違えば新しい turn
3. 「塊を書き出す」: 各 turn を 1 行にする — `speaker` が在れば `"**" + SpeakerLabel.display(s) + "**: " + texts.joined(separator: " ")`、無ければ `texts.joined(separator: " ")`。
   行をそのまま `lines` に足し（空行を挟まない）、最後に `""` を 1 つ足す。`turns = []`
4. ループの後、`turns` が空でなければ書き出す

### 4.2 `Chunker.make`

`text: segments.map(\.text).joined(separator: "\n")` を `segments.map(Self.line).joined(separator: "\n")` にする:

```swift
    /// 話者つきの区間は `話者A: <text>`（PLAN §8.5。F-89）。話者なしは text のまま。
    static func line(_ seg: AbsoluteSegment) -> String {
        guard let speaker = seg.speaker else { return seg.text }
        return SpeakerLabel.display(speaker) + ": " + seg.text
    }
```

チャンクを切る文字数の計算（`chunk` の中の `TextLimit.scalarCount($1.text)`）と重なりは変えない（text だけを数える）。

## 5. テスト

`Tests/VDNotesTests/RawNoteSpeakerTests.swift`（期待は PLAN §8.6 の例から手で書く。TEST-01）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `planExample` | PLAN §8.6 の例と同じ行になる | 1 Part、区間 A・B・A（interval 300） | `### 10:15:02`、空行、`**話者A**: 今日の打ち合わせを始めます。`・`**話者B**: よろしくお願いします。資料は…`・`**話者A**: では最初の議題から。`、空行 |
| `sameSpeakerJoinsWithSpace` | 続けて同じ話者の区間は 1 行に半角空白でつなぐ | A・A・B | 1 行目 `**話者A**: x y` |
| `unlabeledSegmentIsPlainLine` | 話者なしの区間は text だけの行 | A・nil・A | 3 行（2 行目にラベルなし） |
| `timestampBreaksTurns` | ### の差し込みで行が切れる | A の区間が 300 秒をまたぐ | `###` の前後で `**話者A**:` の行が 2 つ |
| `partWithoutSpeakersIsUnchanged` | 話者の無い Part は F-89 の前と同じ | 既存の Raw の golden の入力 | 既存の golden とバイト一致 |
| `mixedParts` | 話者の無い Part と在る Part が同じノートに並ぶ | Part 1 は話者なし、Part 2 は話者つき | Part 1 は段落、Part 2 は行 |
| `emptySpeakerPart` | 話者つきでも text が全部空なら本文なし（TEST-28） | speaker `"A"` の区間の text が空白だけ | `##` 見出しだけ（`###` も無い） |
| `intervalZero` | interval 0 でも話者の行になる | timestampIntervalSeconds 0 | `###` 無しで行が並び、最後に空行 |

`Tests/VDLLMTests/ChunkerSpeakerTests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `prefixesSpeaker` | 話者つきの区間は 話者A: を前に付ける | A・B の 2 区間 | text が `"話者A: x\n話者B: y"` |
| `withoutSpeakerUnchanged` | 話者なしのチャンクは F-89 の前と同じ | 既存の Chunker の golden の入力 | 既存の期待とバイト一致 |
| `countsOnlyText` | 切り方は text の文字数だけで決まる | maxChars ちょうどの 2 区間（話者つき） | 話者なしと同じ位置で切れる |
| `empty` | 区間 0 はチャンク 0（TEST-28） | `[]` | `[]` |

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| 話者の分岐に入る条件を「全区間に話者」にする | `unlabeledSegmentIsPlainLine`・`mixedParts` |
| 行の間に空行を挟む | `planExample` |
| 同じ話者の区間を別の行にする | `sameSpeakerJoinsWithSpace` |
| `**` を落とす | `planExample` |
| Chunker で話者なしにも `": "` を付ける | `withoutSpeakerUnchanged` |
| 前置きの文字数を数えに入れる | `countsOnlyText` |

## 7. 受け入れ条件

- [ ] Raw・Daily・Chunker の既存の golden が 1 バイトも変わらない
- [ ] `make lint && make test` が通る

## 8. SPEC の変更

なし（Raw の規則の表 S12 は保存検証のもので、書式は変えていない）

## 9. マージ後にやること

なし
