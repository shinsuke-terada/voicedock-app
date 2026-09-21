# T-45 VDCore: Python 互換（PyText・PyJSON・PyRound・casefold の表）

| 項目 | 値 |
|---|---|
| ID | T-45 |
| 題 | Python 3.12 の `str`・`json`・`round` と同じに振る舞う部品を VDCore に 1 か所だけ置く（PLAN §5.7、CR-24） |
| Phase | 2 |
| 前提 | T-25（golden の `pytext`・`pyjson`・`pyjson_decode`・`pyround` と、TestSupport の `Golden`・`GoldenAssert`・`GoldenJSON`）。T-01 の VDCore ターゲット |
| 見積もり | 手で書く行 約 1180（本体 658、`gen-casefold.py` 84、テスト 378、`GoldenCase+PyJSON.swift` と そのテスト 約 60）。生成物 `PyCaseFoldTable.swift`（1552 行）と入手物 `CaseFolding-15.0.0.txt`（1624 行）は数えない |

## 1. 目的

golden（voicedock とのバイト一致）と解析の指紋を守るため、Python の振る舞いに合わせた文字列処理（`PyText`）・JSON の書き出しと読み取り（`PyJSON`）・丸め（`PyRound`）を VDCore に置き、
全コードポイントの列挙と voicedock の実出力（T-25 の golden）で固定する。後続のチケットは Swift 標準の近いもの（`CharacterSet`・`lowercased()`・`JSONSerialization`・`JSONEncoder`・`Double.description` 単独・`String.==`）を代わりに使わない。

## 2. 参照

- PLAN §5.7（Python 互換）、§5.2（文字数はスカラー数）、§8.4（転写の JSON）、§8.5（LLM の JSON）、§8.6（ノート）、§10.4（golden）、CR-24
- voicedock@d3d595e の使いどころ（Swift で同じ部品を使う箇所）:
  - `src/voicedock/session.py:74-91` 指紋 = `sha256(json.dumps(…, ensure_ascii=False, sort_keys=True, separators=(",", ":")))` → `PyJSON.dumpsCompact(_, sortKeys: true)`
  - `src/voicedock/transcribe.py:389`（`round(millis / 1000.0, 3)`）・`:396`（`json.dumps(…, indent=2) + "\n"`）・`:449`（`json.loads`）・`:476-479`（`round(…, 1)`・`round(…, 3)`）
  - `src/voicedock/llm.py:266`（LLM の出力の `json.loads`）・`:1007`（`_as_json` のコンパクト形式）・`:1021`（`NFKC` → `strip()` → `casefold()`）
  - `src/voicedock/daily.py:182`（`replace("。", "。\n").splitlines()` と `strip()`）・`:357-359`（`casefold()`）・`:479`（timeline の indent 2）・`:496`（`json.loads`）
  - `src/voicedock/wiki.py:53`（`NFC` → `casefold()`）、`src/voicedock/pipeline.py:1477`（解析結果の indent 2）、`src/voicedock/log.py:206`（コンパクト形式）
- Python 3.12 の `json`（`py_encode_basestring`・`JSONDecoder` の scanner）、`unicodedata`（Unicode 15.0.0）、`float.__repr__`（最短で元に戻る 10 進。`1e16` 以上と `1e-4` 未満は指数表記）
- Unicode 15.0.0 `CaseFolding.txt`: https://www.unicode.org/Public/15.0.0/ucd/CaseFolding.txt

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDCore/PyText.swift` | 下記の全文 |
| `Sources/VDCore/PyCaseFoldTable.swift` | 生成物（`gen-casefold.py` の出力。1552 行）。手で直さない |
| `Sources/VDCore/PyJSON.swift` | 下記の全文（`PyJSONValue` と `PyJSON`） |
| `Sources/VDCore/PyJSONParser.swift` | 下記の全文（`PyJSON.decode` と internal の `PyJSONParser`） |
| `Sources/VDCore/PyRound.swift` | 下記の全文 |
| `tools/unicode/gen-casefold.py` | 下記の全文。実行権 0755 |
| `tools/unicode/CaseFolding-15.0.0.txt` | unicode.org から入手したファイルそのまま（4.4） |
| `tools/unicode/CaseFolding-15.0.0.txt.sha256` | 入手物の sha256（4.4） |
| `Tests/VDCoreTests/PyTextTests.swift` | 下記の全文 |
| `Tests/VDCoreTests/PyJSONTests.swift` | 下記の全文 |
| `Tests/VDCoreTests/PyRoundTests.swift` | 下記の全文 |
| `Tests/VDCoreTests/PyCaseFoldTableTests.swift` | 下記の全文 |
| `Tests/TestSupport/GoldenCase+PyJSON.swift` | 下記の全文（T-25 の `GoldenCase` への extension。`orderedObject(_:)`。4.11） |
| `Tests/VDCoreTests/GoldenCasePyJSONTests.swift` | 下記の全文（`orderedObject(_:)` のテスト） |

## 4. 仕様

### 4.1 方針

- **Unicode スカラー単位で処理する。**Python の `str` はコードポイントの列。Swift の `Character`（書記素）は `\r\n` や結合文字の列を 1 つに数えるので、`for c in text`・`text.count`・`split(separator:)`・`trimmingCharacters(in:)` を使わず、`unicodeScalars` を使う
- **文字列の比較は `unicodeScalars` で行う。**Swift の `String.==`・`hashValue`・`Dictionary<String, _>` のキーは**正準等価**で、`<` は NFC に正規化した列で比べる（`"が"`（U+304C）と `"か"＋U+3099` が等しい）。Python は区別する。正規化の有無が意味を持つ場所（sanitize・重複除去・wiki の名前・JSON のキー）では `PyText.scalarsEqual` か、スカラー列を鍵にする
- **JSON は自前で書き、自前で読む。**`JSONEncoder` と `JSONSerialization` の書き出しは Python と書式が違う（`" : "`・`\/`・浮動小数の桁）。読み取りも `JSONSerialization` は**文字列の先頭の U+FEFF を黙って落とし**（Xcode 27.0 で確認。エスケープで書いても生で書いても落ちる）、`NaN`・`Infinity` を受けない。`PyJSON.parse` / `PyJSON.decode` を使う
- **浮動小数の表記は `PyJSON.formatDouble`。**`Double.description` は Python の `repr` とほぼ同じだが、絶対値が 2^53 を超え 1e16 未満の範囲だけ違う（Swift `9.007199254740994e+15`、Python `9007199254740994.0`）。`formatDouble` がその範囲を書き直す（115,222 個の値で `repr` と一致を確認。4.9）
- **丸めは `PyRound.round`。**`(x * 1000).rounded() / 1000` は掛け算の誤差で Python と変わる（`round(2.675, 2)` は Python で `2.67`）

### 4.2 Python と Swift の対応

| Python（voicedock） | Swift（本チケット） | 使ってはいけない近いもの |
|---|---|---|
| `c.isspace()`・`re` の `\s` | `PyText.isSpace(_:)` | `CharacterSet.whitespacesAndNewlines`（U+001C〜U+001F を含まない）、`Character.isWhitespace` |
| `s.strip()` | `PyText.strip(_:)` | `trimmingCharacters(in: .whitespacesAndNewlines)` |
| `s.strip(chars)` | `PyText.strip(_:chars:)` | `trimmingCharacters(in: CharacterSet(charactersIn:))`（書記素単位） |
| `s.splitlines()` | `PyText.splitLines(_:)` | `components(separatedBy: .newlines)`・`split(whereSeparator: \.isNewline)`（末尾の空要素・区切りの集合が違う） |
| `re.sub(r"\s+", " ", s)` | `PyText.collapseWhitespace(_:)` | `Regex`（PT-20） |
| `s.casefold()` | `PyText.casefold(_:)` | `lowercased()`・`folding(options: .caseInsensitive, …)` |
| `unicodedata.combining(c) != 0` | `PyText.isCombining(_:)` | `generalCategory == .nonspacingMark`（Mc・Me と結合クラス 0 の Mn で違う） |
| `unicodedata.normalize("NFC" / "NFKC", s)` | `PyText.nfc(_:)` / `PyText.nfkc(_:)` | — |
| `a == b`（`str`） | `PyText.scalarsEqual(a, b)` | `a == b`（正準等価） |
| `json.dumps(v, ensure_ascii=False, indent=2)` | `PyJSON.dumpsIndent2(_:)`（ファイルは `PyJSON.fileData(_:)` = ＋ `\n`） | `JSONEncoder`・`JSONSerialization.data` |
| `json.dumps(v, ensure_ascii=False, separators=(",", ":"), sort_keys=…)` | `PyJSON.dumpsCompact(_:sortKeys:)` | 同上 |
| JSON の文字列の中身 | `PyJSON.escape(_:)`（両端の `"` を含まない） | — |
| `repr(float)`（有限） | `PyJSON.formatDouble(_:)` | `Double.description` 単独、`String(format: "%g")` |
| `json.loads(text)` | `PyJSON.decode(_:)`（順序付きの `PyJSONValue?`）・`PyJSON.parse(_:)`（Foundation の値） | `JSONSerialization.jsonObject`・`JSONDecoder`（重複キー・U+FEFF・NaN の扱いが違う） |
| `isinstance(v, bool)` | `PyJSON.isBool(_:)` | `v as? Bool`（`NSNumber(1)` も通る） |
| `round(x, n)` | `PyRound.round(_:digits:)` | `(x * 10^n).rounded() / 10^n` |

### 4.3 `PyText`

- `isSpace` の集合は Python 3.12 の `str.isspace()` と全コードポイントで同じ 29 個。`splitLines` の区切りは `str.splitlines()` と同じ 10 個（`\r\n` は 2 つで 1 つ）。どちらも T-25 の golden `pytext/enumerations.json` で全スカラーを照合する
- `splitLines`: 空文字列は `[]`。末尾の区切りの後に空要素を作らない（`"a\n"` → `["a"]`、`"\n"` → `[""]`）
- `collapseWhitespace`: 前後を削らない（`" a "` → `" a "`）。ZWSP（U+200B）は空白ではない
- `casefold`: `PyCaseFoldTable.map` に在れば写像のスカラー列、無ければそのまま。語末シグマの規則は無い（`ΣΑΣ` → `σασ`）
- `isCombining`: `Unicode.Scalar.Properties.canonicalCombiningClass != .notReordered`。macOS の ICU の Unicode の版が 15.0 より新しくても、Unicode 15.0 で割り当て済みのスカラーでは Python と一致する（テストが割り当て済みの全スカラーで照合する。未割り当てのスカラーは比べない）
- `nfc` / `nfkc`: `precomposedStringWithCanonicalMapping` / `precomposedStringWithCompatibilityMapping`（golden で照合）

#### `Sources/VDCore/PyText.swift`（全文。133 行）

```swift
// Python 3.12 の str の振る舞い（strip・splitlines・\s・casefold）を Unicode スカラー単位で写す（PLAN §5.7、CR-24）。
import Foundation

/// Python 互換の文字列処理。golden（voicedock の Python 3.12 / unicodedata 15.0.0）とバイト単位で一致させる。
///
/// **`Character`（書記素）ではなく `Unicode.Scalar` で処理する。**Python の `str` はコードポイントの列であり、
/// `"\r\n"` や結合文字を 1 文字として扱う Swift の `Character` とは数え方が違う。
public enum PyText {
    /// `str.isspace()`（= `re` の `\s`）の対象。golden `pytext/enumerations.json` の `isspace` と一致する（29 個）。
    /// `CharacterSet.whitespacesAndNewlines` とは U+001C–U+001F の有無が違うので使わない。
    static let spaceScalars: Set<UInt32> = [
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x001C, 0x001D, 0x001E, 0x001F, 0x0020, 0x0085, 0x00A0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    /// `str.splitlines()` の区切り（10 個）。`\r\n` は 2 つで 1 つの区切りとして扱う（`splitLines` の中で）。
    static let lineBreakScalars: Set<UInt32> = [
        0x000A, 0x000B, 0x000C, 0x000D, 0x001C, 0x001D, 0x001E, 0x0085, 0x2028, 0x2029,
    ]

    /// Python の `str.isspace()`（1 文字）。
    public static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        spaceScalars.contains(scalar.value)
    }

    /// Python の `str.strip()`（引数なし）。前後の `isSpace` を除く。
    public static func strip(_ text: String) -> String {
        strip(text, where: isSpace)
    }

    /// Python の `str.strip(chars)`。前後の `chars` に含まれるスカラーを除く。
    public static func strip(_ text: String, chars: Set<Unicode.Scalar>) -> String {
        strip(text) { chars.contains($0) }
    }

    /// Python の `str.splitlines()`（`keepends=False`）。末尾の区切りの後に空要素を作らない。空文字列は空配列。
    public static func splitLines(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if lineBreakScalars.contains(scalar.value) {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                if scalar.value == 0x000D, index + 1 < scalars.count, scalars[index + 1].value == 0x000A {
                    index += 1
                }
            } else {
                current.append(scalar)
            }
            index += 1
        }
        if !current.isEmpty {
            lines.append(String(current))
        }
        return lines
    }

    /// Python の `re.sub(r"\s+", " ", text)`。`isSpace` の連続を U+0020 1 つに置き換える（前後は削らない）。
    public static func collapseWhitespace(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                if !inRun {
                    result.append(" ")
                    inRun = true
                }
            } else {
                result.append(scalar)
                inRun = false
            }
        }
        return String(result)
    }

    /// Python の `str.casefold()`（Unicode 15.0.0 の CaseFolding.txt の C + F）。語末シグマの規則は無い。
    /// `lowercased()` は使わない（`ß` が `ss` にならず、`ΣΑΣ` が `σας` になる）。
    public static func casefold(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let mapped = PyCaseFoldTable.map[scalar.value] {
                for value in mapped {
                    if let folded = Unicode.Scalar(value) {
                        result.append(folded)
                    }
                }
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Python の `unicodedata.combining(c) != 0`（正準結合クラスが 0 でない）。
    public static func isCombining(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.canonicalCombiningClass != .notReordered
    }

    /// Python の `unicodedata.normalize("NFC", text)`。
    public static func nfc(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    /// Python の `unicodedata.normalize("NFKC", text)`。
    public static func nfkc(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    /// 2 つの文字列が Unicode スカラー列として等しいか。
    /// **Swift の `==` は正準等価で比べる**（`"か\u{3099}" == "が"` が真）ので、正規化の有無を確かめるときはこれを使う。
    public static func scalarsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    static func strip(_ text: String, where predicate: (Unicode.Scalar) -> Bool) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, predicate(scalars[start]) {
            start += 1
        }
        while end > start, predicate(scalars[end - 1]) {
            end -= 1
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start..<end])
        return String(view)
    }
}
```


### 4.4 casefold の表（`PyCaseFoldTable`）

**入手と記録**（1 回だけ。版を上げるときも同じ手順）:

```bash
curl -fsSL https://www.unicode.org/Public/15.0.0/ucd/CaseFolding.txt -o tools/unicode/CaseFolding-15.0.0.txt
shasum -a 256 tools/unicode/CaseFolding-15.0.0.txt
# 出力が次と同じであることを確かめる（違えば止めて理由を調べる）:
# cdd49e55eae3bbf1f0a3f6580c974a0263cb86a6a08daa10fbf705b4808a56f7  tools/unicode/CaseFolding-15.0.0.txt
(cd tools/unicode && shasum -a 256 CaseFolding-15.0.0.txt > CaseFolding-15.0.0.txt.sha256)
python3 tools/unicode/gen-casefold.py tools/unicode/CaseFolding-15.0.0.txt Sources/VDCore/PyCaseFoldTable.swift
```

- `CaseFolding-15.0.0.txt` は入手したバイト列のままコミットする（改行を変えない。T-25 の `.gitattributes` が `tools/unicode/*.txt -text`）。1 行目は `# CaseFolding-15.0.0.txt`
- `CaseFolding-15.0.0.txt.sha256` は `shasum -a 256` の出力 1 行（`<64 桁の小文字 16 進><空白 2 つ>CaseFolding-15.0.0.txt<改行>`）:

```text
cdd49e55eae3bbf1f0a3f6580c974a0263cb86a6a08daa10fbf705b4808a56f7  CaseFolding-15.0.0.txt
```

- `gen-casefold.py` は sha256 と 1 行目の版を確かめ、status が `C` と `F` の行だけを取り（`S` と `T` は捨てる。Python の `casefold()` は完全ケースフォールディング）、元のスカラーの昇順で書く。同じスカラーが 2 回出たら止まる
- 生成物の先頭 2 行目に入力の sha256 を書く（`// source-sha256: …`）。`PyCaseFoldTableTests` が入手物・記録・生成物の 3 つの sha256 の一致を確かめる
- 表の形は「元のスカラー, 写像の長さ n, 写像のスカラー × n」を平らに並べた `[UInt32]`（辞書リテラル 1530 件より型検査が速い）と、それを 1 回だけ辞書にする `map`。件数 1530

#### `tools/unicode/gen-casefold.py`（全文。84 行）

```python
#!/usr/bin/env python3
"""CaseFolding-<版>.txt（status C と F）から VDCore/PyCaseFoldTable.swift を作る（PLAN §5.7）。

使い方: python3 tools/unicode/gen-casefold.py tools/unicode/CaseFolding-15.0.0.txt Sources/VDCore/PyCaseFoldTable.swift
入力の sha256 を tools/unicode/CaseFolding-15.0.0.txt.sha256 と照合し、違えば止まる。
"""
import hashlib
import sys
from pathlib import Path

EXPECTED_VERSION = "15.0.0"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: gen-casefold.py <CaseFolding.txt> <out.swift>", file=sys.stderr)
        return 2
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    data = src.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    expected = Path(str(src) + ".sha256").read_text(encoding="ascii").split()[0]
    if digest != expected:
        print(f"sha256 が一致しません: {digest} != {expected}", file=sys.stderr)
        return 1
    text = data.decode("utf-8")
    first = text.splitlines()[0]
    if first != f"# CaseFolding-{EXPECTED_VERSION}.txt":
        print(f"版が違います: {first}", file=sys.stderr)
        return 1
    table: dict[int, list[int]] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(";")]
        code, status, mapping = fields[0], fields[1], fields[2]
        if status not in ("C", "F"):
            continue
        cp = int(code, 16)
        if cp in table:
            print(f"重複: {code}", file=sys.stderr)
            return 1
        table[cp] = [int(x, 16) for x in mapping.split()]
    lines = [
        "// 生成物。tools/unicode/gen-casefold.py が CaseFolding-"
        + EXPECTED_VERSION
        + ".txt（status C と F）から作る。手で編集しない。",
        f"// source-sha256: {digest}",
        "// 形式: 1 件ごとに「元のスカラー, 写像の長さ n, 写像のスカラー × n」を並べる（PLAN §5.7）。",
        "enum PyCaseFoldTable {",
        f"    static let unicodeVersion = \"{EXPECTED_VERSION}\"",
        f"    static let entryCount = {len(table)}",
        "    static let packed: [UInt32] = [",
    ]
    for cp in sorted(table):
        mapped = table[cp]
        body = ", ".join(f"0x{x:04X}" for x in mapped)
        lines.append(f"        0x{cp:04X}, {len(mapped)}, {body},")
    lines += [
        "    ]",
        "",
        "    static let map: [UInt32: [UInt32]] = {",
        "        var result: [UInt32: [UInt32]] = [:]",
        "        result.reserveCapacity(entryCount)",
        "        var index = 0",
        "        while index < packed.count {",
        "            let source = packed[index]",
        "            let length = Int(packed[index + 1])",
        "            result[source] = Array(packed[(index + 2)..<(index + 2 + length)])",
        "            index += 2 + length",
        "        }",
        "        return result",
        "    }()",
        "}",
        "",
    ]
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"{len(table)} 件を書きました: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```


生成物 `Sources/VDCore/PyCaseFoldTable.swift` の先頭と末尾（中略。1552 行）:

```swift
// 生成物。tools/unicode/gen-casefold.py が CaseFolding-15.0.0.txt（status C と F）から作る。手で編集しない。
// source-sha256: cdd49e55eae3bbf1f0a3f6580c974a0263cb86a6a08daa10fbf705b4808a56f7
// 形式: 1 件ごとに「元のスカラー, 写像の長さ n, 写像のスカラー × n」を並べる（PLAN §5.7）。
enum PyCaseFoldTable {
    static let unicodeVersion = "15.0.0"
    static let entryCount = 1530
    static let packed: [UInt32] = [
        0x0041, 1, 0x0061,
        0x0042, 1, 0x0062,
        0x0043, 1, 0x0063,
        0x0044, 1, 0x0064,
        0x0045, 1, 0x0065,
        …
        0x1E921, 1, 0x1E943,
    ]

    static let map: [UInt32: [UInt32]] = {
        var result: [UInt32: [UInt32]] = [:]
        result.reserveCapacity(entryCount)
        var index = 0
        while index < packed.count {
            let source = packed[index]
            let length = Int(packed[index + 1])
            result[source] = Array(packed[(index + 2)..<(index + 2 + length)])
            index += 2 + length
        }
        return result
    }()
}
```

### 4.5 `PyJSON`（書き出し）

- `PyJSONValue.object` は `[(String, PyJSONValue)]`（順序付き）。キーの順は呼び手が決める。`sortKeys: true` のときだけキーを**スカラー値の辞書式順**に並べる（Python の `sort_keys=True`。Swift の `String.<` は NFC に正規化してから比べるので使わない）
- `dumpsIndent2`: 区切りは `,` と `: `、要素ごとに改行して 2 空白×深さで字下げ、空の配列は `[]`・空のオブジェクトは `{}`、末尾に改行なし。`fileData` は `dumpsIndent2 + "\n"` の UTF-8
- `dumpsCompact`: 区切りは `,` と `:`、空白なし
- 文字列: `"` → `\"`、`\` → `\\`、U+000A・000D・0009・0008・000C → `\n` `\r` `\t` `\b` `\f`、その他の U+0000〜001F → `\u00xx`（小文字の 16 進 4 桁）。`/`・U+007F・U+2028・非 ASCII・サロゲートの組になる文字はそのまま（UTF-8）
- 整数（`.int(Int64)`）は 10 進。浮動小数（`.double`）は `formatDouble`（有限は Python の `repr`、非有限は `NaN` / `Infinity` / `-Infinity`。Python の `json.dumps` の `allow_nan=True` と同じ）
- `PyJSONValue.==` は文字列をスカラー列で、浮動小数をビット列で（`0.0` と `-0.0` を区別、同じビットの NaN は等しい）、オブジェクトを順序付きで比べる
- `foundationObject` は `parse` の戻り値と `PyStr.describe`（T-26）のための Foundation の値。真偽値は `NSNumber(value: Bool)`（= `kCFBoolean…`）

#### `Sources/VDCore/PyJSON.swift`（全文。213 行）

```swift
// Python の json.dumps(ensure_ascii=False) と同じ書式の JSON を書く（PLAN §5.7、CR-24）。
import Foundation

/// 順序付きの JSON の値。オブジェクトのキーの順序は呼び手が決める（`sortKeys` のときだけ並べ替える）。
public indirect enum PyJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([PyJSONValue])
    case object([(String, PyJSONValue)])

    /// 文字列は Unicode スカラー列で、浮動小数はビット列で比べる（`-0.0` と `0.0` は書き出しが違うので区別する）。
    public static func == (lhs: PyJSONValue, rhs: PyJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.int(let a), .int(let b)):
            return a == b
        case (.double(let a), .double(let b)):
            return a.bitPattern == b.bitPattern
        case (.string(let a), .string(let b)):
            return a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case (.array(let a), .array(let b)):
            return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count
                && zip(a, b).allSatisfy { pair in
                    pair.0.0.unicodeScalars.elementsEqual(pair.1.0.unicodeScalars) && pair.0.1 == pair.1.1
                }
        default:
            return false
        }
    }
}

extension PyJSONValue {
    /// Foundation の値にする（真偽値は `NSNumber(value: Bool)` なので `PyJSON.isBool` が真になる）。
    /// オブジェクトは `[String: Any]` になるので、キーの順序は失われる。
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .int(let number): return NSNumber(value: number)
        case .double(let number): return NSNumber(value: number)
        case .string(let text): return text
        case .array(let items): return items.map(\.foundationObject)
        case .object(let pairs):
            var result: [String: Any] = [:]
            for (key, value) in pairs {
                result[key] = value.foundationObject
            }
            return result
        }
    }
}

/// Python の `json.dumps(value, ensure_ascii=False, …)` と同じ文字列を作る。
///
/// - `dumpsIndent2`: `indent=2`（区切り `,` と `: `、要素ごとに改行と 2 空白の字下げ、空の配列は `[]`、空のオブジェクトは `{}`）
/// - `dumpsCompact`: `separators=(",", ":")`
/// - 文字列は `"` `\` と U+0000–001F だけをエスケープする（`\n \r \t \b \f` は短い形、他は `\u00xx` の小文字 16 進）。
///   `/`・U+007F・U+2028・非 ASCII はそのまま
/// - 浮動小数は `Double.description`（Python の `repr` と同じ表記）。非有限は `NaN` / `Infinity` / `-Infinity`
/// - `sortKeys` はキーを Unicode スカラー値の辞書式順で並べる（Python の `sort_keys=True`。Swift の `<` は使わない）
public enum PyJSON {
    public static func dumpsIndent2(_ value: PyJSONValue) -> String {
        var out = ""
        write(value, indent: 2, level: 0, sortKeys: false, into: &out)
        return out
    }

    public static func dumpsCompact(_ value: PyJSONValue, sortKeys: Bool = false) -> String {
        var out = ""
        write(value, indent: nil, level: 0, sortKeys: sortKeys, into: &out)
        return out
    }

    /// ファイルに書く形（`dumpsIndent2` ＋ 末尾の `\n`）の UTF-8。
    public static func fileData(_ value: PyJSONValue) -> Data {
        Data((dumpsIndent2(value) + "\n").utf8)
    }

    /// JSON の文字列リテラルの中身（両端の `"` は含まない）。Python の `py_encode_basestring` から両端の `"` を除いたもの。
    public static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x00...0x1F: out += "\\u" + hex4(scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Python の `json.dumps` の浮動小数の表記（有限なら `repr(float)` と同じ。非有限は `NaN` / `Infinity` / `-Infinity`）。
    ///
    /// 桁は `Double.description`（最短で元に戻る 10 進）と同じ。ただし Swift は絶対値が 2^53 を超えると指数表記にし、
    /// Python は 1e16 未満なら固定小数点で書くので、その間（`9007199254740994.0`〜`9999999999999998.0`）だけ書き直す。
    public static func formatDouble(_ value: Double) -> String {
        if value.isNaN {
            return "NaN"
        }
        if value.isInfinite {
            return value < 0 ? "-Infinity" : "Infinity"
        }
        let text = value.description
        guard value.magnitude > 0x1p53, value.magnitude < 1e16, let marker = text.firstIndex(of: "e"),
            let exponent = Int(text[text.index(after: marker)...])
        else {
            return text
        }
        let sign = value < 0 ? "-" : ""
        let digits = text[..<marker].filter { $0.isNumber }
        return sign + digits + String(repeating: "0", count: max(0, exponent + 1 - digits.count)) + ".0"
    }

    /// UTF-8 の JSON を Python の `json.loads` と同じ規則で読み（`decode`）、Foundation の値
    /// （`[String: Any]` / `[Any]` / `String` / `NSNumber` / `NSNull`）にして返す。読めなければ nil。
    ///
    /// `JSONSerialization` は使わない: 文字列の先頭の U+FEFF を黙って落とし（Xcode 27.0 で確認）、`NaN` を受けないため。
    /// 不正な UTF-8 は nil（Python の `read_text(encoding="utf-8")` の失敗と同じ扱い）。
    public static func parse(_ data: Data) -> Any? {
        guard let text = String(validating: data, as: UTF8.self), let value = decode(text) else {
            return nil
        }
        return value.foundationObject
    }

    /// `parse` が返した値が真偽値か（真偽値の `NSNumber` は `as? Int` を通ってしまうので型 ID で区別する）。
    public static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else {
            return false
        }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// キーを Unicode スカラー値の辞書式順で比べる（Python の文字列の比較と同じ）。
    static func keyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.map(\.value).lexicographicallyPrecedes(rhs.unicodeScalars.map(\.value))
    }

    static func hex4(_ value: UInt32) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    static func write(_ value: PyJSONValue, indent: Int?, level: Int, sortKeys: Bool, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .int(let number):
            out += String(number)
        case .double(let number):
            out += formatDouble(number)
        case .string(let text):
            out += "\"" + escape(text) + "\""
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 {
                    out += ","
                }
                if let indent {
                    out += "\n" + String(repeating: " ", count: indent * (level + 1))
                }
                write(item, indent: indent, level: level + 1, sortKeys: sortKeys, into: &out)
            }
            if let indent {
                out += "\n" + String(repeating: " ", count: indent * level)
            }
            out += "]"
        case .object(let pairs):
            if pairs.isEmpty {
                out += "{}"
                return
            }
            let ordered = sortKeys ? pairs.sorted { keyPrecedes($0.0, $1.0) } : pairs
            out += "{"
            for (index, pair) in ordered.enumerated() {
                if index > 0 {
                    out += ","
                }
                if let indent {
                    out += "\n" + String(repeating: " ", count: indent * (level + 1))
                }
                out += "\"" + escape(pair.0) + "\""
                out += indent == nil ? ":" : ": "
                write(pair.1, indent: indent, level: level + 1, sortKeys: sortKeys, into: &out)
            }
            if let indent {
                out += "\n" + String(repeating: " ", count: indent * level)
            }
            out += "}"
        }
    }
}
```


### 4.6 `PyJSON.decode`（読み取り）

Python の `json.loads(text)` と同じものを受け、同じ値を返す。読めなければ `nil`（Python の `JSONDecodeError` / `ValueError` に当たる）:

1. 空白は U+0020・0009・000A・000D だけ（値の前後と区切りの前後）。U+3000 や U+FEFF で始まる文字列は `nil`
2. 値の後に空白以外が残れば `nil`（`"{} x"`）
3. リテラルは `true`・`false`・`null`・`NaN`・`Infinity`・`-Infinity`（後ろの 3 つは `.double`）
4. 数は `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`。小数部も指数部も無く Int64 に収まれば `.int`、それ以外は `.double(Double(文字列))`（`01`・`-`・`1.`・`.5` は `nil`）
5. 文字列のエスケープは `\"` `\\` `\/` `\b` `\f` `\n` `\r` `\t` と `\u` ＋ 16 進 4 桁（大文字小文字どちらも）。上位・下位サロゲートの組は 1 つのスカラーにし、対にならないサロゲートは U+FFFD にする（Python は対にならないサロゲートを `str` に持てるが、Swift の `String` は持てない。T-25 の golden も U+FFFD に写して比べる）。それ以外のエスケープ・4 桁に満たない `\u` は `nil`
6. 文字列の中の生の U+0000〜001F（タブを含む）は `nil`（Python の `strict=True`）
7. オブジェクトのキーは文字列だけ。同じキーが 2 回出たら値は後勝ち・位置は最初の出現（Python の `dict`）。キーの同一性はスカラー列で決める
8. 末尾のカンマは `nil`
9. 入れ物（配列・オブジェクト）の入れ子は 64 段まで。65 段目で `nil`（Python は約 1000 段まで読む。本計画の差分: 再帰下降のスタックを 512 KiB の協調スレッドで溢れさせないため。LLM の出力と設定は 4 段を超えない）

`PyJSON.parse(_ data: Data) -> Any?` は、不正な UTF-8 なら `nil`（Python の `read_text(encoding="utf-8")` の失敗）、そうでなければ `decode` して `foundationObject` にしたもの。オブジェクトは `[String: Any]` になるのでキーの順は失われる（順が要る場所は `decode` を使う）。

#### `Sources/VDCore/PyJSONParser.swift`（全文。303 行。`decode(_ data: Data)` は整合修正（2026-09-18）で足した）

```swift
// Python の json.loads と同じ規則で JSON を読み、キーの順序を保った PyJSONValue にする（PLAN §5.7、§8.5）。
import Foundation

extension PyJSON {
    /// 入れ物（配列・オブジェクト）の入れ子の上限。65 段目で nil。
    /// 再帰下降のスタックが 512 KiB のスレッド（Swift Concurrency の協調スレッド）でも溢れない深さ（Debug ビルドで
    /// 1 段あたり約 2.5 KiB）。Python は約 1000 段まで読むが、LLM の出力と設定ファイルは 4 段を超えない。
    static let maxDecodeDepth = 64

    /// Python の `json.loads(text)` と同じものを受け、同じ値を返す。読めなければ nil（例外を投げない）。
    ///
    /// - 前後と要素の間の空白は U+0020・U+0009・U+000A・U+000D だけ。値の後に空白以外が残れば nil。先頭の U+FEFF は nil
    /// - `true` / `false` / `null` と、`NaN` / `Infinity` / `-Infinity`（`.double`）を受ける
    /// - 数は `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`。小数部も指数部も無く `Int64` に収まれば `.int`、
    ///   それ以外は `.double(Double(文字列))`
    /// - 文字列のエスケープは `\" \\ \/ \b \f \n \r \t \uXXXX`（16 進は大小どちらも）。サロゲートの組は 1 つのスカラーにし、
    ///   対にならないサロゲートは U+FFFD にする。U+0000–U+001F の生の文字は nil
    /// - 同じキーが 2 回出たら、値は後勝ち・位置は最初の出現のまま（Python の dict）
    public static func decode(_ text: String) -> PyJSONValue? {
        var parser = PyJSONParser(scalars: Array(text.unicodeScalars))
        guard let value = parser.parseValue(depth: 0) else {
            return nil
        }
        parser.skipWhitespace()
        return parser.index == parser.scalars.count ? value : nil
    }

    /// UTF-8 のバイト列を `decode(_:)` で読む。不正な UTF-8 は nil（`parse` と同じ検査。00-api-map の `decode(_ data: Data)`）。
    public static func decode(_ data: Data) -> PyJSONValue? {
        guard let text = String(validating: data, as: UTF8.self) else {
            return nil
        }
        return decode(text)
    }
}

/// `PyJSON.decode` の再帰下降パーサ。
struct PyJSONParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    mutating func skipWhitespace() {
        while index < scalars.count {
            switch scalars[index].value {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    func peek() -> UInt32? {
        index < scalars.count ? scalars[index].value : nil
    }

    mutating func consume(_ literal: String) -> Bool {
        let expected = Array(literal.unicodeScalars)
        guard index + expected.count <= scalars.count,
            Array(scalars[index..<(index + expected.count)]) == expected
        else {
            return false
        }
        index += expected.count
        return true
    }

    /// `depth` は外側にある入れ物（配列・オブジェクト）の数。入れ物は `maxDecodeDepth` 段まで。
    mutating func parseValue(depth: Int) -> PyJSONValue? {
        skipWhitespace()
        guard let first = peek() else {
            return nil
        }
        switch first {
        case 0x7B:  // {
            return depth < PyJSON.maxDecodeDepth ? parseObject(depth: depth) : nil
        case 0x5B:  // [
            return depth < PyJSON.maxDecodeDepth ? parseArray(depth: depth) : nil
        case 0x22:  // "
            return parseString().map { .string($0) }
        case 0x74:  // t
            return consume("true") ? .bool(true) : nil
        case 0x66:  // f
            return consume("false") ? .bool(false) : nil
        case 0x6E:  // n
            return consume("null") ? .null : nil
        case 0x4E:  // N
            return consume("NaN") ? .double(.nan) : nil
        case 0x49:  // I
            return consume("Infinity") ? .double(.infinity) : nil
        case 0x2D:  // -
            if consume("-Infinity") {
                return .double(-.infinity)
            }
            return parseNumber()
        case 0x30...0x39:
            return parseNumber()
        default:
            return nil
        }
    }

    mutating func parseObject(depth: Int) -> PyJSONValue? {
        index += 1  // {
        var pairs: [(String, PyJSONValue)] = []
        var positions: [String: Int] = [:]
        skipWhitespace()
        if peek() == 0x7D {
            index += 1
            return .object([])
        }
        while true {
            skipWhitespace()
            guard peek() == 0x22, let key = parseString() else {
                return nil
            }
            skipWhitespace()
            guard peek() == 0x3A else {
                return nil
            }
            index += 1
            guard let value = parseValue(depth: depth + 1) else {
                return nil
            }
            // Swift の String のハッシュは正準等価なので、スカラー列を鍵にする
            let identity = key.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
            if let position = positions[identity] {
                pairs[position].1 = value
            } else {
                positions[identity] = pairs.count
                pairs.append((key, value))
            }
            skipWhitespace()
            switch peek() {
            case 0x2C:
                index += 1
            case 0x7D:
                index += 1
                return .object(pairs)
            default:
                return nil
            }
        }
    }

    mutating func parseArray(depth: Int) -> PyJSONValue? {
        index += 1  // [
        var items: [PyJSONValue] = []
        skipWhitespace()
        if peek() == 0x5D {
            index += 1
            return .array([])
        }
        while true {
            guard let value = parseValue(depth: depth + 1) else {
                return nil
            }
            items.append(value)
            skipWhitespace()
            switch peek() {
            case 0x2C:
                index += 1
            case 0x5D:
                index += 1
                return .array(items)
            default:
                return nil
            }
        }
    }

    mutating func parseString() -> String? {
        index += 1  // "
        var out = String.UnicodeScalarView()
        while let value = peek() {
            index += 1
            switch value {
            case 0x22:
                return String(out)
            case 0x5C:
                guard let escape = peek() else {
                    return nil
                }
                index += 1
                switch escape {
                case 0x22: out.append("\"")
                case 0x5C: out.append("\\")
                case 0x2F: out.append("/")
                case 0x62: out.append(Unicode.Scalar(0x08))
                case 0x66: out.append(Unicode.Scalar(0x0C))
                case 0x6E: out.append("\n")
                case 0x72: out.append("\r")
                case 0x74: out.append("\t")
                case 0x75:
                    guard let unit = parseHex4() else {
                        return nil
                    }
                    out.append(decodeUnit(unit))
                default:
                    return nil
                }
            case 0x00...0x1F:
                return nil
            default:
                out.append(scalars[index - 1])
            }
        }
        return nil
    }

    /// `\u` の後の 4 桁。
    mutating func parseHex4() -> UInt32? {
        guard index + 4 <= scalars.count else {
            return nil
        }
        var result: UInt32 = 0
        for offset in 0..<4 {
            let value = scalars[index + offset].value
            let digit: UInt32
            switch value {
            case 0x30...0x39: digit = value - 0x30
            case 0x41...0x46: digit = value - 0x41 + 10
            case 0x61...0x66: digit = value - 0x61 + 10
            default: return nil
            }
            result = result * 16 + digit
        }
        index += 4
        return result
    }

    /// 1 つの UTF-16 単位を Unicode スカラーにする。上位サロゲートの直後に `\u` の下位サロゲートがあれば組にする。
    mutating func decodeUnit(_ unit: UInt32) -> Unicode.Scalar {
        let replacement: Unicode.Scalar = "\u{FFFD}"
        if (0xD800...0xDBFF).contains(unit) {
            let saved = index
            if consume("\\u"), let low = parseHex4(), (0xDC00...0xDFFF).contains(low) {
                let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                return Unicode.Scalar(combined) ?? replacement
            }
            index = saved
            return replacement
        }
        return Unicode.Scalar(unit) ?? replacement
    }

    mutating func parseNumber() -> PyJSONValue? {
        let start = index
        var isInteger = true
        if peek() == 0x2D {
            index += 1
        }
        guard let lead = peek(), (0x30...0x39).contains(lead) else {
            return nil
        }
        index += 1
        if lead != 0x30 {
            while let digit = peek(), (0x30...0x39).contains(digit) {
                index += 1
            }
        }
        if peek() == 0x2E {
            let dot = index
            index += 1
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                index = dot
                return finishNumber(start: start, isInteger: isInteger)
            }
            isInteger = false
            while let next = peek(), (0x30...0x39).contains(next) {
                index += 1
            }
        }
        if let marker = peek(), marker == 0x65 || marker == 0x45 {
            let exponentStart = index
            index += 1
            if let sign = peek(), sign == 0x2B || sign == 0x2D {
                index += 1
            }
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                index = exponentStart
                return finishNumber(start: start, isInteger: isInteger)
            }
            isInteger = false
            while let next = peek(), (0x30...0x39).contains(next) {
                index += 1
            }
        }
        return finishNumber(start: start, isInteger: isInteger)
    }

    func finishNumber(start: Int, isInteger: Bool) -> PyJSONValue? {
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars[start..<index])
        let literal = String(text)
        if isInteger, let integer = Int64(literal) {
            return .int(integer)
        }
        return Double(literal).map { .double($0) }
    }
}
```


### 4.7 `PyRound`

Python の `round(x, n)`（`n ≥ 0`）は x の**正確な 2 進値**を 10 進 n 桁へ最近接偶数で丸める。C の `%.nf` も同じ規則なので、`String(format: "%.nf", x)` を `Double` に戻せば同じ値になる（100,000 個の値と桁 0〜6 で Python とビット単位で一致を確認）。非有限と負の桁数はそのまま返す（本計画では使わない）。

#### `Sources/VDCore/PyRound.swift`（全文。17 行）

```swift
// Python の round(x, n)（浮動小数を小数 n 桁へ）と同じ丸め（PLAN §5.7、CR-24）。
import Foundation

/// Python の `round(x, digits)`。
///
/// Python は x の**正確な 2 進値**を 10 進で小数 `digits` 桁へ丸め（ちょうど半分なら偶数側）、それを浮動小数に戻す。
/// C の `%.nf` も正確な 2 進値を最近接偶数で丸めるので、その文字列を `Double` に戻せば同じ値になる
/// （`(x * 1000).rounded() / 1000` は掛け算の誤差で結果が変わりうるので使わない）。
public enum PyRound {
    public static func round(_ value: Double, digits: Int) -> Double {
        guard value.isFinite, digits >= 0 else {
            return value
        }
        let text = String(format: "%.\(digits)f", value)
        return Double(text) ?? value
    }
}
```


### 4.8 voicedock の実出力で確かめた書式（T-25 の golden。Python 3.12.13）

**コンパクト形式**（`json.dumps(value, ensure_ascii=False, separators=(",", ":"))`。見えない文字は ⟨U+XXXX⟩ で示す）:

| ケース | mode | 入力（型付きの値） | voicedock（Python 3.12）の出力 |
|---|---|---|---|
| `scalars_compact` | `compact` | `["a",[["n"],["b",true],["b",false],["i",0],["i",-7],["i",9007199254740993],["s",""]]]` | `[null,true,false,0,-7,9007199254740993,""]` |
| `floats_compact` | `compact` | `["a",[["f","0.0"],["f","-0.0"],["f","3.2"],["f","1800.0"],["f","12.345"],["f","1e-05"],["f","0.0001"],["f","1e+16"],["f","1000000000000000.0"],["f","1.5e+300"],["f","0.30000000000000004"],["f","123456789.123"],["f","1.2345678901234567e+19"],["f","5e-324"],["f","1.7976931348623157e+308"],["f","0.002"],["f","9.001"],["f","2.5e-05"],["f","100.0"],["f","1e+22"],["f","9007199254740992.0"],["f","9007199254740994.0"],["f","9500000000000000.0"],["f","-9999999999999998.0"],["f","9.999e-05"]]]` | `[0.0,-0.0,3.2,1800.0,12.345,1e-05,0.0001,1e+16,1000000000000000.0,1.5e+300,0.30000000000000004,123456789.123,1.2345678901234567e+19,5e-324,1.7976931348623157e+308,0.002,9.001,2.5e-05,100.0,1e+22,9007199254740992.0,9007199254740994.0,9500000000000000.0,-9999999999999998.0,9.999e-05]` |
| `string_escapes` | `compact` | `["s","x⟨U+007F⟩⟨U+2028⟩/\u0001\u001f\b\f\n\r\t\"\\é𝄞"]` | `"x⟨U+007F⟩⟨U+2028⟩/\u0001\u001f\b\f\n\r\t\"\\é𝄞"` |
| `order_preserved_compact` | `compact` | `["o",[["b",["i",1]],["a",["i",2]]]]` | `{"b":1,"a":2}` |
| `sort_keys_codepoint` | `compact_sorted` | `["o",[["b",["i",1]],["𝄞",["i",2]],["Ａ",["i",3]],["a",["i",4]],["ab",["i",5]],["a⟨U+0301⟩",["i",6]],["e",["i",7]],["é",["i",8]],["Z",["i",9]]]]` | `{"Z":9,"a":4,"ab":5,"a⟨U+0301⟩":6,"b":1,"e":7,"é":8,"Ａ":3,"𝄞":2}` |
| `sort_keys_nested` | `compact_sorted` | `["o",[["z",["o",[["y",["i",1]],["x",["i",2]]]]],["a",["a",[["o",[["d",["n"]],["c",["b",true]]]]]]]]]` | `{"a":[{"c":true,"d":null}],"z":{"x":2,"y":1}}` |

`pyjson/indent_nested.out`（mode `indent2`）:

```json
{⟨U+000A⟩  "a": [⟨U+000A⟩    1,⟨U+000A⟩    {⟨U+000A⟩      "b": []⟨U+000A⟩    }⟨U+000A⟩  ],⟨U+000A⟩  "c": {},⟨U+000A⟩  "d": "日本語"⟨U+000A⟩}
```
（末尾の改行なし）

`pyjson/indent_empty_containers.out`（mode `indent2`）:

```json
[⟨U+000A⟩  [],⟨U+000A⟩  {}⟨U+000A⟩]
```
（末尾の改行なし）

`pyjson/indent_top_scalar.out`（mode `indent2`）:

```json
"x"
```
（末尾の改行なし）

`pyjson/file_transcript_like.out`（mode `file`）:

```json
{⟨U+000A⟩  "partkey": "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",⟨U+000A⟩  "language": "ja",⟨U+000A⟩  "duration_seconds": 1800.0,⟨U+000A⟩  "started_at": "2026-08-29T07:12:04+09:00",⟨U+000A⟩  "text": "おはよう",⟨U+000A⟩  "segments": [⟨U+000A⟩    {⟨U+000A⟩      "start": 0.0,⟨U+000A⟩      "end": 3.2,⟨U+000A⟩      "text": "おはよう"⟨U+000A⟩    }⟨U+000A⟩  ]⟨U+000A⟩}⟨U+000A⟩
```
（末尾の改行 1 つまで含む）

`pyjson/file_source_json.out`（mode `file`）:

```json
{⟨U+000A⟩  "schema": 1,⟨U+000A⟩  "transcript_sha256": "894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f",⟨U+000A⟩  "segments": 2,⟨U+000A⟩  "blocks": 1⟨U+000A⟩}⟨U+000A⟩
```
（末尾の改行 1 つまで含む）

**指紋**（`session.transcript_fingerprint`。`fingerprint/v4_example.out` の 1 行目が `sha256` の入力、2 行目が voicedock の出力した指紋。PLAN §5.7 の `894a6142…b86f`）:

```text
{"blocks":[["2026-08-29T07:12:04+09:00","2026-08-29T07:42:04+09:00"]],"segments":[{"at":"2026-08-29T07:12:04+09:00","end_at":"2026-08-29T07:12:07+09:00","text":"おはようございます。"},{"at":"2026-08-29T07:12:13+09:00","end_at":"2026-08-29T07:12:16+09:00","text":"今日は/\"x\""}]}
894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f
```

Swift では `PyJSON.dumpsCompact(.object([("blocks", …), ("segments", …)]), sortKeys: true)` の UTF-8 の sha256（T-10）。キーは `sortKeys` で `blocks` → `segments`、各区間の中は `at` → `end_at` → `text` の順になる。

**読み取り**（`json.loads`。`pyjson_decode` の全ケース）:

| ケース | 入力の文字列 | `json.loads` | 値（型付き） |
|---|---|---|---|
| `object_basic` | `{"a": 1, "b": [true, false, null], "c": "x"}` | 読める | `["o",[["a",["i",1]],["b",["a",[["b",true],["b",false],["n"]]]],["c",["s","x"]]]]` |
| `duplicate_key_last_wins_first_position` | `{"b":1,"a":2,"b":3}` | 読める | `["o",[["b",["i",3]],["a",["i",2]]]]` |
| `numbers` | `[0, -0, 1.0, 1e5, 1E-5, -1.5e+2, 12345678901234567890, 9223372036854775807, -9223372036854775808, 9223372036854775808, 0.1, 1e400]` | 読める | `["a",[["i",0],["i",0],["f","1.0"],["f","100000.0"],["f","1e-05"],["f","-150.0"],["f","1.2345678901234567e+19"],["i",9223372036854775807],["i",-9223372036854775808],["f","9.223372036854776e+18"],["f","0.1"],["f","inf"]]]` |
| `constants` | `[NaN, Infinity, -Infinity]` | 読める | `["a",[["f","nan"],["f","inf"],["f","-inf"]]]` |
| `string_escapes` | `"\u3042\ud834\udd1e\n\/\\\"\b\f\r\t\u00E9"` | 読める | `["s","あ𝄞\n/\\\"\b\f\r\té"]` |
| `lone_surrogate` | `"\ud800x"` | 読める | `["s","�x"]` |
| `ascii_whitespace_around` | `⟨U+0020⟩⟨U+0009⟩⟨U+000A⟩⟨U+000D⟩{"a":1}⟨U+000D⟩⟨U+000A⟩⟨U+0020⟩` | 読める | `["o",[["a",["i",1]]]]` |
| `ideographic_space_rejected` | `⟨U+3000⟩{"a":1}` | **例外**（Swift は nil） | — |
| `extra_data_rejected` | `{"a":1} x` | **例外**（Swift は nil） | — |
| `empty_rejected` | （空文字列） | **例外**（Swift は nil） | — |
| `bom_rejected` | `⟨U+FEFF⟩{}` | **例外**（Swift は nil） | — |
| `raw_control_char_rejected` | `"a⟨U+0001⟩b"` | **例外**（Swift は nil） | — |
| `raw_tab_in_string_rejected` | `"a⟨U+0009⟩b"` | **例外**（Swift は nil） | — |
| `invalid_escape_rejected` | `"\x"` | **例外**（Swift は nil） | — |
| `short_unicode_escape_rejected` | `"\u12"` | **例外**（Swift は nil） | — |
| `non_string_key_rejected` | `{1: 2}` | **例外**（Swift は nil） | — |
| `trailing_comma_array_rejected` | `[1,]` | **例外**（Swift は nil） | — |
| `trailing_comma_object_rejected` | `{"a":1,}` | **例外**（Swift は nil） | — |
| `leading_zero_rejected` | `01` | **例外**（Swift は nil） | — |
| `minus_only_rejected` | `-` | **例外**（Swift は nil） | — |
| `dot_without_digits_rejected` | `1.` | **例外**（Swift は nil） | — |
| `leading_dot_rejected` | `.5` | **例外**（Swift は nil） | — |
| `nested_ten` | `[[[[[[[[[[1]]]]]]]]]]` | 読める | `["a",[["a",[["a",[["a",[["a",[["a",[["a",[["a",[["a",[["a",[["i",1]]]]]]]]]]]]]]]]]]]]]` |
| `top_string` | `"x"` | 読める | `["s","x"]` |
| `top_number` | `3` | 読める | `["i",3]` |
| `top_true` | `true` | 読める | `["b",true]` |
| `non_ascii_raw` | `{"日": "本⟨U+2028⟩"}` | 読める | `["o",[["日",["s","本⟨U+2028⟩"]]]]` |
| `empty_containers` | `{"a": [], "b": {}}` | 読める | `["o",[["a",["a",[]]],["b",["o",[]]]]]` |

**丸め**（`round(x, n)` の結果の `repr`。`pyround` の全ケース）:

| ケース | 桁 | 入力（repr） | `round` の結果（repr） |
|---|---|---|---|
| `digits3_ms` | 3 | `0.0015` | `0.002` |
| `digits3_ms` | 3 | `0.0005` | `0.001` |
| `digits3_ms` | 3 | `0.0025` | `0.003` |
| `digits3_ms` | 3 | `0.001` | `0.001` |
| `digits3_ms` | 3 | `1.2345` | `1.234` |
| `digits3_ms` | 3 | `12.3455` | `12.345` |
| `digits3_ms` | 3 | `0.0` | `0.0` |
| `digits3_ms` | 3 | `3.2` | `3.2` |
| `digits3_ms` | 3 | `9.001` | `9.001` |
| `digits3_ms` | 3 | `1234.5675` | `1234.568` |
| `digits3_ms` | 3 | `-0.0015` | `-0.002` |
| `digits3_ms` | 3 | `2.675` | `2.675` |
| `digits3_ratios` | 3 | `0.3333333333333333` | `0.333` |
| `digits3_ratios` | 3 | `0.6666666666666666` | `0.667` |
| `digits3_ratios` | 3 | `0.006944444444444444` | `0.007` |
| `digits3_ratios` | 3 | `0.0625` | `0.062` |
| `digits3_ratios` | 3 | `1.0005` | `1.0` |
| `digits3_ratios` | 3 | `123.4565` | `123.457` |
| `digits1` | 1 | `12.34` | `12.3` |
| `digits1` | 1 | `0.05` | `0.1` |
| `digits1` | 1 | `0.25` | `0.2` |
| `digits1` | 1 | `0.35` | `0.3` |
| `digits1` | 1 | `0.45` | `0.5` |
| `digits1` | 1 | `2.5` | `2.5` |
| `digits1` | 1 | `1e+16` | `1e+16` |
| `digits1` | 1 | `0.0` | `0.0` |

**文字列**（`pytext` の列挙以外の全ケース）:

| 種類 | 入力 | Python の結果 |
|---|---|---|
| strip | （空） | `""` |
| strip | `⟨U+0020⟩ a ⟨U+0020⟩` | `"a"` |
| strip | `⟨U+3000⟩a⟨U+3000⟩` | `"a"` |
| strip | `⟨U+001C⟩a⟨U+001F⟩` | `"a"` |
| strip | `⟨U+200B⟩a⟨U+200B⟩` | `"⟨U+200B⟩a⟨U+200B⟩"` |
| strip | `⟨U+0085⟩a⟨U+00A0⟩` | `"a"` |
| strip | `⟨U+0009⟩⟨U+000A⟩⟨U+000B⟩⟨U+000C⟩⟨U+000D⟩a b⟨U+000D⟩⟨U+000A⟩` | `"a b"` |
| strip | `a` | `"a"` |
| stripChars（chars `.`） | `..a..` | `"a"` |
| stripChars（chars `.`） | `a.b` | `"a.b"` |
| stripChars（chars `.`） | `...` | `""` |
| stripChars（chars `.`） | （空） | `""` |
| stripChars（chars `.`） | `. a .` | `" a "` |
| stripChars（chars `/`） | `/Daily/Voice/Raw/` | `"Daily/Voice/Raw"` |
| stripChars（chars `/`） | `Raw` | `"Raw"` |
| stripChars（chars `/`） | `//` | `""` |
| stripChars（chars `/`） | `/a//` | `"a"` |
| splitlines | （空） | `[]` |
| splitlines | `⟨U+000A⟩` | `[""]` |
| splitlines | `a⟨U+000A⟩` | `["a"]` |
| splitlines | `a` | `["a"]` |
| splitlines | `a⟨U+000D⟩⟨U+000A⟩b⟨U+000D⟩c⟨U+000A⟩⟨U+000A⟩d⟨U+000B⟩e⟨U+000C⟩f⟨U+001C⟩g⟨U+001D⟩h⟨U+001E⟩i⟨U+0085⟩j⟨U+2028⟩k⟨U+2029⟩l⟨U+000A⟩` | `["a", "b", "c", "", "d", "e", "f", "g", "h", "i", "j", "k", "l"]` |
| splitlines | `⟨U+000D⟩⟨U+000A⟩⟨U+000D⟩` | `["", ""]` |
| splitlines | `a⟨U+001F⟩b` | `["a\u001fb"]` |
| splitlines | `a⟨U+000D⟩⟨U+000D⟩⟨U+000A⟩b` | `["a", "", "b"]` |
| collapse | `a  b` | `"a b"` |
| collapse | `a⟨U+0009⟩⟨U+0009⟩b` | `"a b"` |
| collapse | `a⟨U+3000⟩⟨U+3000⟩b` | `"a b"` |
| collapse | `⟨U+0020⟩a⟨U+0020⟩` | `" a "` |
| collapse | `a⟨U+200B⟩b` | `"a⟨U+200B⟩b"` |
| collapse | `a⟨U+001C⟩⟨U+001D⟩b` | `"a b"` |
| collapse | `a⟨U+00A0⟩b` | `"a b"` |
| casefold | `Straße` | `"strasse"` |
| casefold | `ǅ` | `"ǆ"` |
| casefold | `ΣΑΣ` | `"σασ"` |
| casefold | `İ` | `"i⟨U+0307⟩"` |
| casefold | `ﬁ` | `"fi"` |
| casefold | `ΐ` | `"ι⟨U+0308⟩⟨U+0301⟩"` |
| casefold | `ＡＢＣ` | `"ａｂｃ"` |
| casefold | `ẞ` | `"ss"` |
| casefold | `Ǆ` | `"ǆ"` |
| casefold | `ﬀ` | `"ff"` |
| casefold | `ŉ` | `"ʼn"` |
| casefold | `abc` | `"abc"` |
| nfc | `か⟨U+3099⟩` | `"が"` |
| nfc | `e⟨U+0301⟩` | `"é"` |
| nfc | `Å` | `"Å"` |
| nfc | `한` | `"한"` |
| nfkc | `ﾃｽﾄ` | `"テスト"` |
| nfkc | `Ｖｏｉｃｅ` | `"Voice"` |
| nfkc | `①` | `"1"` |
| nfkc | `㍍` | `"メートル"` |
| nfkc | `ﬁ` | `"fi"` |
| nfkc | `⟨U+3000⟩` | `" "` |

**列挙**（`pytext/enumerations.json`。Python 3.12 / unicodedata 15.0.0 で全コードポイントを調べたもの）:

- `unicodeVersion`: `15.0.0`
- `isspace`（29 個）: U+0009, U+000A, U+000B, U+000C, U+000D, U+001C, U+001D, U+001E, U+001F, U+0020, U+0085, U+00A0, U+1680, U+2000, U+2001, U+2002, U+2003, U+2004, U+2005, U+2006, U+2007, U+2008, U+2009, U+200A, U+2028, U+2029, U+202F, U+205F, U+3000
- `splitlinesSeparators`（10 個。`\r\n` は 2 つで 1 つの区切り）: U+000A, U+000B, U+000C, U+000D, U+001C, U+001D, U+001E, U+0085, U+2028, U+2029
- `casefold`: 1 文字の `casefold()` が自分と違うスカラー 1530 個（うち 2 スカラー以上に写るもの 104 個）。CaseFolding.txt の C と F の件数（1530）と一致する
- `combining`: 結合クラスが 0 でないスカラー 922 個（割り当て済みの範囲 707 個の中で）

### 4.9 Swift 標準との違い（確かめた落とし穴）

| 落とし穴 | 確かめたこと | 本チケットの対処 |
|---|---|---|
| `JSONSerialization.jsonObject` が文字列の先頭の U+FEFF を落とす | `{"d": "<U+FEFF>x"}` を読むと `"x"`（Xcode 27.0。エスケープで書いても同じ）。`JSONDecoder` は保つ | `PyJSON.parse` は `decode` で読む（`parseKeepsBOMAndBooleans`） |
| `Double.description` と `repr` の違い | 全指数域の乱数と閾値（2^53・1e16・1e-4 など）の前後の 51,722 個で比べ、違いは 2^53 < \|x\| < 1e16 の 106 個だけ（小さい側の `1e-4` の境は同じ） | `formatDouble` がその範囲を固定小数点に直す。`formatDouble` は閾値の前後 2,000 個ずつ・乱数のビット列を足した 115,222 個で `repr` と全一致（`formatDoubleRules`・golden `floats_compact`） |
| `String.==` は正準等価 | `"\u{304C}" == "\u{304B}\u{3099}"` が真 | `scalarsEqual`・`PyJSONValue.==`・重複キーの判定はスカラー列 |
| `sorted()` の `String.<` は NFC に正規化してから比べる | `"a\u{301}"` と `"e"` の順が Python と逆（Swift は U+00E1 と U+0065 を比べる） | `keyPrecedes` はスカラー値の辞書式順（`sortKeysByScalarValue`） |
| `lowercased()` は casefold ではない | `"Straße".lowercased()` は `straße`、`"ΣΑΣ".lowercased()` は `σας` | `PyCaseFoldTable` |
| 再帰下降のスタック | Debug ビルドのテスト（512 KiB のスレッド）で、入れ子のオブジェクト 256 段で SIGBUS、192 段で無事 | 入れ子の上限 64（`decodeDepthLimit`） |

### 4.10 後続のチケットへの注意

- T-10: 指紋は `PyJSON.dumpsCompact(value, sortKeys: true)` の UTF-8 の SHA-256。`Transcript` の JSON は `PyJSON.fileData`。秒は `PyRound.round(Double(ms) / 1000, digits: 3)`
- T-17: `round(elapsed, 1)`・`round(x, 3)` は `PyRound`。JSON の文字列の埋め込みは `"\"" + PyJSON.escape(s) + "\""`（`escape` は両端の `"` を含まない）
- T-19・T-20: LLM の出力の JSON は `PyJSON.decode`（キーの順・重複キー・U+FEFF・NaN が Python と同じ）。`_as_json` は `dumpsCompact`
- T-26: `PyStr.describe` の浮動小数は `Double.description` ではなく `PyJSON.formatDouble`（有限のとき）を使う（2^53〜1e16 で違う）。Python の `str(float)` の非有限は `nan` / `inf` / `-inf` なので、そこだけ `formatDouble` と違う
- T-26・T-27: 名前の突き合わせ・重複除去は `PyText.casefold`・`nfc`・`nfkc` と、スカラー列を鍵にした集合

### 4.11 `Tests/TestSupport/GoldenCase+PyJSON.swift`（`GoldenCase.orderedObject`。全文）

T-25 の `GoldenCase` は **VDCore に依存しない**（`fields` は `[String: GoldenJSON]` で、辞書なのでキーの順を持たない）。
キーの順を保った payload が要るのは T-19 の `llm_validate` / `llm_trim` / `analysis_json` だけなので、
`PyJSONValue` を作る**本チケットが extension で足す**（00-api-map §15。T-25 の本体に置くと T-25 → T-45 の循環になる）。

```swift
// golden の入力をキーの順のまま読む（T-25 の GoldenCase への extension。PyJSONValue は VDCore なのでここに置く。00-api-map §15）。
import Foundation
import VDCore

extension GoldenCase {
    /// キーの順を保ったオブジェクト。`fields` は辞書で順を持たないので、
    /// 入力 `Tests/Golden/inputs/<group>.json` を `PyJSON.decode` で読み直し、このケースの `key` の値を返す。
    /// 重複キーの扱い（位置は最初・値は後勝ち）も `PyJSON.decode` のまま（4.6）。
    public func orderedObject(_ key: String) throws -> [(String, PyJSONValue)] {
        let url = Golden.inputsDirectory.appendingPathComponent("\(group).json")
        guard let data = try? Data(contentsOf: url) else {
            throw GoldenError.unreadable(url.path)
        }
        guard let document = PyJSON.decode(data), case .object(let top) = document,
            let casesValue = Self.member(top, "cases"), case .array(let items) = casesValue
        else {
            throw GoldenError.malformedInput(url.path)
        }
        for item in items {
            guard case .object(let itemFields) = item,
                let nameValue = Self.member(itemFields, "name"), case .string(let itemName) = nameValue
            else {
                throw GoldenError.malformedInput(url.path)
            }
            guard PyText.scalarsEqual(itemName, name) else { continue }
            guard let found = Self.member(itemFields, key) else {
                throw GoldenError.missingKey(group: group, name: name, key: key)
            }
            guard case .object(let pairs) = found else {
                throw mismatch(key, "オブジェクト")
            }
            return pairs
        }
        throw GoldenError.noSuchCase(group: group, name: name)
    }

    /// キーの突き合わせはスカラー列（4.1。Swift の `==` は正準等価）。最初に一致したものを返す。
    private static func member(_ pairs: [(String, PyJSONValue)], _ key: String) -> PyJSONValue? {
        pairs.first { PyText.scalarsEqual($0.0, key) }?.1
    }
}
```

- `Golden.inputsDirectory`・`GoldenError`・`GoldenCase.mismatch(_:_:)`（internal）は T-25 のもの。同じ TestSupport ターゲットなので届く
- 期待値の側（`.json`）は今までどおり `GoldenJSON`。順が要るのは**入力の payload だけ**
- このファイルだけは `VDCore` を import する（本チケットのほかのファイルは `Foundation` だけ。受け入れ条件）

## 5. テスト

### `Tests/VDCoreTests/PyTextTests.swift`（`@Suite("PyText")`）

| 関数名 | 表示名 | 確かめること |
|---|---|---|
| `goldenUnicodeVersion` | golden は unicodedata 15.0.0 で作られている | golden と表がどちらも Unicode 15.0.0 |
| `isSpaceMatchesPython` | isSpace は Python の str.isspace と全スカラーで一致する | U+0000〜U+10FFFF のスカラー全部で `isSpace` と Python の `isspace` の集合（29 個）が一致 |
| `lineBreaksMatchPython` | splitLines の区切りは Python の str.splitlines と全スカラーで一致する | 全スカラーで `"a" + c + "b"` が 2 行になるかが Python と一致（10 個） |
| `casefoldTableMatchesPython` | casefold の表は Python の str.casefold と完全に一致する | 表の 1530 件が Python の `casefold()` の全写像と完全に一致 |
| `combiningMatchesPython` | isCombining は Unicode 15.0 で割り当て済みの全スカラーで Python と一致する | Unicode 15.0 で割り当て済みの全スカラー（28 万以上）で `isCombining` が一致 |
| `goldenCases` | golden の各ケース（strip・stripChars・splitlines・collapse・casefold・nfc・nfkc） | `pytext` の 8 ケースの全入力が期待値と値で一致 |
| `casefoldFixedExamples` | PLAN §5.7 の固定例 | PLAN §5.7 の 4 例（`Straße`・`ΣΑΣ`・`İ`・`ﬁ`） |
| `sentenceSplitExample` | PLAN §5.7 の文分割の例を部品で組む（関数そのものは T-27 の DailyNote） | PLAN §5.7 の `"A。B。 C"` → `["A。","B。","C"]` を `splitLines` と `strip` で組む |
| `stripRemovesInformationSeparators` | strip は U+001C〜U+001F も空白として除く（CharacterSet と違う） | U+001C・U+001F を除き、U+200B は除かない。空文字列 |
| `collapseKeepsZeroWidthSpace` | collapseWhitespace は NBSP を空白として畳み、ZWSP は残す | NBSP を畳み ZWSP を残す（PLAN §5.7 の例）。前後を削らない |
| `splitLinesEdges` | splitLines の端の扱い | 空・`\n`・末尾の区切り・`\r\n` と `\r` の組み合わせ |
| `scalarsEqualDistinguishesNormalization` | scalarsEqual は正準等価でも違うスカラー列を区別する（Swift の == は区別しない） | Swift の `==` が真でも `scalarsEqual` は偽。`nfc` の後は真 |

### `Tests/VDCoreTests/PyJSONTests.swift`（`@Suite("PyJSON")`）

| 関数名 | 表示名 | 確かめること |
|---|---|---|
| `goldenDumps` | golden pyjson: dumps の書式が Python と一致する | `pyjson` の 11 ケース（コンパクト・並べ替え・indent 2・ファイル）がバイト列で一致 |
| `goldenDecode` | golden pyjson_decode: decode が Python の json.loads と同じ値を返す（読めないものは nil） | `pyjson_decode` の 28 ケースで、読めるか否かと値（型付き）が一致 |
| `escapeRules` | escape は " \ と U+0000〜U+001F だけをエスケープし、両端の " を付けない | エスケープする文字・しない文字（`/`・U+007F・U+2028・`é`）と、U+0001・U+001F の小文字 16 進 |
| `formatDoubleRules` | 浮動小数は Python の repr と同じ表記。非有限は NaN / Infinity / -Infinity | `1800.0`・`1e-05`・`1e+16`・`9007199254740994.0`・`-9500000000000000.0`・`9.999e-05`・`-0.0`・`NaN`・`-Infinity` |
| `sortKeysByScalarValue` | sortKeys はスカラー値の順（Swift の < ではない） | `a`＋U+0301・`e`・`é` の並び |
| `indentEmptyContainers` | indent 2 の空の入れ物と、fileData の末尾改行 | `[\n  [],\n  {}\n]` と `fileData` の末尾改行 |
| `parseKeepsBOMAndBooleans` | parse は文字列の先頭の U+FEFF を保ち、真偽値を区別する | 先頭の U+FEFF を保つ。`true` は `isBool`、`1` は違う |
| `parseRejects` | parse は先頭の BOM・不正な UTF-8・余分な文字を受けない | 先頭の BOM・不正な UTF-8・余分な文字で `nil` |
| `decodeDepthLimit` | decode の入れ物の入れ子は 64 段まで（65 段で nil。とても深くてもスタックは溢れない） | 64 段は読める・65 段は `nil`・10 万段の `[` でもクラッシュしない |
| `decodeDuplicateKeys` | decode の同じキーは値が後勝ち、位置は最初 | `{"b":1,"a":2,"b":3}` → `[(b, 3), (a, 2)]` |
| `equalityRules` | PyJSONValue の == は文字列をスカラー列で、浮動小数をビット列で比べる | NFC と NFD・`0.0` と `-0.0` を区別する |

### `Tests/VDCoreTests/PyRoundTests.swift`（`@Suite("PyRound")`）

| 関数名 | 表示名 | 確かめること |
|---|---|---|
| `goldenCases` | golden pyround: Python の round と同じ値（ビット列で一致） | `pyround` の 3 ケースの全入力で `repr` が一致 |
| `roundsExactBinaryValue` | 掛け算の丸めではなく、正確な 2 進値を 10 進で丸める | `round(2.675, 2) == 2.67`・`round(0.0005, 3) == 0.001`・`round(0.25, 1) == 0.2` |
| `passthrough` | 非有限と負の桁数はそのまま返す | 無限大・NaN・負の桁数はそのまま |

### `Tests/VDCoreTests/PyCaseFoldTableTests.swift`（`@Suite("PyCaseFoldTable")`）

| 関数名 | 表示名 | 確かめること |
|---|---|---|
| `sourceHashIsRecorded` | 生成元の sha256 が記録どおりで、表の見出しにも同じ値がある | 入手物の sha256 が `.sha256` の記録と、生成物の `// source-sha256:` の行と一致 |
| `entryCountAndStatuses` | C と F の写像の数（1530）と、S と T を含めないこと | 1530 件。`ẞ`（F）が `ss`、`I` が `i`（T の `ı` ではない） |

#### `Tests/VDCoreTests/PyTextTests.swift`（全文。157 行）

```swift
// PyText が Python 3.12 の str と同じに振る舞うこと（PLAN §5.7、T-45）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("PyText")
struct PyTextTests {
    /// golden `pytext/enumerations.json`（Python 3.12 / unicodedata 15.0.0 で全コードポイントを調べたもの）。
    static func enumerations() throws -> [String: GoldenJSON] {
        guard let object = try Golden.expectedJSON("pytext", "enumerations").objectValue else {
            throw GoldenError.malformedInput("pytext/enumerations")
        }
        return object
    }

    static func scalarSet(_ json: GoldenJSON?) -> Set<UInt32> {
        Set((json?.arrayValue ?? []).compactMap(\.intValue).map(UInt32.init))
    }

    static var allScalars: [Unicode.Scalar] {
        (UInt32(0)...0x10FFFF).compactMap(Unicode.Scalar.init)
    }

    @Test("golden は unicodedata 15.0.0 で作られている")
    func goldenUnicodeVersion() throws {
        #expect(try Self.enumerations()["unicodeVersion"]?.stringValue == "15.0.0")
        #expect(PyCaseFoldTable.unicodeVersion == "15.0.0")
    }

    @Test("isSpace は Python の str.isspace と全スカラーで一致する")
    func isSpaceMatchesPython() throws {
        let expected = Self.scalarSet(try Self.enumerations()["isspace"])
        #expect(expected.count == 29)
        for scalar in Self.allScalars {
            #expect(PyText.isSpace(scalar) == expected.contains(scalar.value), "U+\(String(scalar.value, radix: 16))")
        }
    }

    @Test("splitLines の区切りは Python の str.splitlines と全スカラーで一致する")
    func lineBreaksMatchPython() throws {
        let expected = Self.scalarSet(try Self.enumerations()["splitlinesSeparators"])
        #expect(expected.count == 10)
        for scalar in Self.allScalars {
            var text = String.UnicodeScalarView()
            text.append(contentsOf: ["a", scalar, "b"])
            let isBreak = PyText.splitLines(String(text)).count == 2
            #expect(isBreak == expected.contains(scalar.value), "U+\(String(scalar.value, radix: 16))")
        }
    }

    @Test("casefold の表は Python の str.casefold と完全に一致する")
    func casefoldTableMatchesPython() throws {
        guard let expected = try Self.enumerations()["casefold"]?.objectValue else {
            Issue.record("casefold がありません")
            return
        }
        #expect(expected.count == PyCaseFoldTable.map.count)
        for (key, value) in expected {
            let source = UInt32(key) ?? 0
            let mapped = (value.arrayValue ?? []).compactMap(\.intValue).map(UInt32.init)
            #expect(PyCaseFoldTable.map[source] == mapped, "U+\(String(source, radix: 16))")
        }
    }

    @Test("isCombining は Unicode 15.0 で割り当て済みの全スカラーで Python と一致する")
    func combiningMatchesPython() throws {
        let enumerations = try Self.enumerations()
        let expected = Self.scalarSet(enumerations["combining"])
        var checked = 0
        for range in enumerations["assignedRanges"]?.arrayValue ?? [] {
            let bounds = (range.arrayValue ?? []).compactMap(\.intValue)
            guard bounds.count == 2 else {
                Issue.record("assignedRanges の形が不正です")
                continue
            }
            for value in UInt32(bounds[0])...UInt32(bounds[1]) {
                guard let scalar = Unicode.Scalar(value) else { continue }
                checked += 1
                #expect(PyText.isCombining(scalar) == expected.contains(value), "U+\(String(value, radix: 16))")
            }
        }
        #expect(checked > 280_000)
    }

    @Test("golden の各ケース（strip・stripChars・splitlines・collapse・casefold・nfc・nfkc）")
    func goldenCases() throws {
        let cases = try Golden.cases("pytext").filter { $0.name != "enumerations" }
        #expect(!cases.isEmpty)
        for item in cases {
            let inputs = try item.strings("inputs")
            let kind = try item.string("kind")
            let outputs: [GoldenJSON]
            switch kind {
            case "strip": outputs = inputs.map { .string(PyText.strip($0)) }
            case "stripChars":
                let chars = Set(try item.string("chars").unicodeScalars)
                outputs = inputs.map { .string(PyText.strip($0, chars: chars)) }
            case "splitlines": outputs = inputs.map { .array(PyText.splitLines($0).map(GoldenJSON.string)) }
            case "collapse": outputs = inputs.map { .string(PyText.collapseWhitespace($0)) }
            case "casefold": outputs = inputs.map { .string(PyText.casefold($0)) }
            case "nfc": outputs = inputs.map { .string(PyText.nfc($0)) }
            case "nfkc": outputs = inputs.map { .string(PyText.nfkc($0)) }
            default:
                Issue.record("未知の kind: \(kind)")
                continue
            }
            GoldenAssert.matchesJSON(.array(outputs), group: "pytext", name: item.name)
        }
    }

    @Test(
        "PLAN §5.7 の固定例",
        arguments: [
            ("Stra\u{DF}e", "strasse"), ("\u{3A3}\u{391}\u{3A3}", "\u{3C3}\u{3B1}\u{3C3}"), ("\u{130}", "i\u{307}"),
            ("\u{FB01}", "fi"),
        ])
    func casefoldFixedExamples(input: String, expected: String) {
        #expect(PyText.scalarsEqual(PyText.casefold(input), expected))
    }

    @Test("PLAN §5.7 の文分割の例を部品で組む（関数そのものは T-27 の DailyNote）")
    func sentenceSplitExample() {
        let pieces = PyText.splitLines("A。B。 C".replacingOccurrences(of: "。", with: "。\n")).map(PyText.strip)
        #expect(pieces.filter { !$0.isEmpty } == ["A。", "B。", "C"])
    }

    @Test("strip は U+001C〜U+001F も空白として除く（CharacterSet と違う）")
    func stripRemovesInformationSeparators() {
        #expect(PyText.strip("\u{1C}X\u{1F}") == "X")
        #expect(PyText.strip("\u{200B}a\u{200B}") == "\u{200B}a\u{200B}")
        #expect(PyText.strip("") == "")
    }

    @Test("collapseWhitespace は NBSP を空白として畳み、ZWSP は残す")
    func collapseKeepsZeroWidthSpace() {
        #expect(PyText.scalarsEqual(PyText.collapseWhitespace("a\u{A0}b\u{200B}c"), "a b\u{200B}c"))
        #expect(PyText.collapseWhitespace(" a ") == " a ")
    }

    @Test("splitLines の端の扱い")
    func splitLinesEdges() {
        #expect(PyText.splitLines("") == [])
        #expect(PyText.splitLines("\n") == [""])
        #expect(PyText.splitLines("a\n") == ["a"])
        #expect(PyText.splitLines("\r\n\r") == ["", ""])
        #expect(PyText.splitLines("a\r\r\nb") == ["a", "", "b"])
    }

    @Test("scalarsEqual は正準等価でも違うスカラー列を区別する（Swift の == は区別しない）")
    func scalarsEqualDistinguishesNormalization() {
        #expect("\u{304C}" == "\u{304B}\u{3099}")
        #expect(!PyText.scalarsEqual("\u{304C}", "\u{304B}\u{3099}"))
        #expect(PyText.scalarsEqual(PyText.nfc("\u{304B}\u{3099}"), "\u{304C}"))
    }
}
```

#### `Tests/VDCoreTests/PyJSONTests.swift`（全文。155 行）

```swift
// PyJSON が Python の json.dumps / json.loads と同じに振る舞うこと（PLAN §5.7、T-45）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("PyJSON")
struct PyJSONTests {
    /// golden の型付きの値（`["s", 文字列]` など。T-25）を PyJSONValue にする。
    static func value(fromTagged json: GoldenJSON) throws -> PyJSONValue {
        guard let items = json.arrayValue, let kind = items.first?.stringValue else {
            throw GoldenError.malformedInput("型付きの値ではありません: \(json)")
        }
        let payload = items.count > 1 ? items[1] : GoldenJSON.null
        switch kind {
        case "n": return .null
        case "b": return .bool(payload.boolValue ?? false)
        case "i":
            guard case .integer(let integer) = payload else { throw GoldenError.malformedInput("i: \(payload)") }
            return .int(integer)
        case "f":
            guard let text = payload.stringValue, let number = Double(text) else {
                throw GoldenError.malformedInput("f: \(payload)")
            }
            return .double(number)
        case "s": return .string(payload.stringValue ?? "")
        case "a": return .array(try (payload.arrayValue ?? []).map(value(fromTagged:)))
        case "o":
            return .object(
                try (payload.arrayValue ?? []).map { pair in
                    guard let parts = pair.arrayValue, parts.count == 2, let key = parts[0].stringValue else {
                        throw GoldenError.malformedInput("o: \(pair)")
                    }
                    return (key, try value(fromTagged: parts[1]))
                })
        default: throw GoldenError.malformedInput("未知の型: \(kind)")
        }
    }

    /// PyJSONValue を golden の型付きの値にする（浮動小数は Python の repr: 非有限は nan / inf / -inf）。
    static func tagged(_ value: PyJSONValue) -> GoldenJSON {
        switch value {
        case .null: return ["n"]
        case .bool(let flag): return ["b", .bool(flag)]
        case .int(let integer): return ["i", .integer(integer)]
        case .double(let number):
            let text =
                number.isNaN ? "nan" : number.isInfinite ? (number < 0 ? "-inf" : "inf") : PyJSON.formatDouble(number)
            return ["f", .string(text)]
        case .string(let text): return ["s", .string(text)]
        case .array(let items): return ["a", .array(items.map(tagged))]
        case .object(let pairs): return ["o", .array(pairs.map { [.string($0.0), tagged($0.1)] })]
        }
    }

    @Test("golden pyjson: dumps の書式が Python と一致する")
    func goldenDumps() throws {
        let cases = try Golden.cases("pyjson")
        #expect(!cases.isEmpty)
        for item in cases {
            let value = try Self.value(fromTagged: try item.value("value"))
            let mode = try item.string("mode")
            switch mode {
            case "compact": GoldenAssert.matches(PyJSON.dumpsCompact(value), group: "pyjson", name: item.name)
            case "compact_sorted":
                GoldenAssert.matches(PyJSON.dumpsCompact(value, sortKeys: true), group: "pyjson", name: item.name)
            case "indent2": GoldenAssert.matches(PyJSON.dumpsIndent2(value), group: "pyjson", name: item.name)
            case "file": GoldenAssert.matches(bytes: PyJSON.fileData(value), group: "pyjson", name: item.name)
            default: Issue.record("未知の mode: \(mode)")
            }
        }
    }

    @Test("golden pyjson_decode: decode が Python の json.loads と同じ値を返す（読めないものは nil）")
    func goldenDecode() throws {
        let cases = try Golden.cases("pyjson_decode")
        #expect(!cases.isEmpty)
        for item in cases {
            let result = PyJSON.decode(try item.string("text"))
            let actual: GoldenJSON = ["ok": .bool(result != nil), "value": result.map(Self.tagged) ?? .null]
            GoldenAssert.matchesJSON(actual, group: "pyjson_decode", name: item.name)
        }
    }

    @Test("escape は \" \\ と U+0000〜U+001F だけをエスケープし、両端の \" を付けない")
    func escapeRules() {
        #expect(PyJSON.escape("a\"b\\c") == #"a\"b\\c"#)
        #expect(PyJSON.escape("\n\r\t\u{8}\u{C}") == #"\n\r\t\b\f"#)
        #expect(PyJSON.escape("\u{1}\u{1F}") == "\\" + "u0001" + "\\" + "u001f")
        #expect(PyJSON.escape("/\u{7F}\u{2028}\u{E9}") == "/\u{7F}\u{2028}\u{E9}")
    }

    @Test("浮動小数は Python の repr と同じ表記。非有限は NaN / Infinity / -Infinity")
    func formatDoubleRules() {
        #expect(PyJSON.formatDouble(1800) == "1800.0")
        #expect(PyJSON.formatDouble(1e-5) == "1e-05")
        #expect(PyJSON.formatDouble(1e16) == "1e+16")
        #expect(PyJSON.formatDouble(9_007_199_254_740_994) == "9007199254740994.0")
        #expect(PyJSON.formatDouble(-9.5e15) == "-9500000000000000.0")
        #expect(PyJSON.formatDouble(9.999e-5) == "9.999e-05")
        #expect(PyJSON.formatDouble(-0.0) == "-0.0")
        #expect(PyJSON.formatDouble(.nan) == "NaN")
        #expect(PyJSON.formatDouble(-.infinity) == "-Infinity")
    }

    @Test("sortKeys はスカラー値の順（Swift の < ではない）")
    func sortKeysByScalarValue() {
        let value = PyJSONValue.object([("e", .int(1)), ("a\u{301}", .int(2)), ("\u{E9}", .int(3))])
        #expect(PyJSON.dumpsCompact(value, sortKeys: true) == "{\"a\u{301}\":2,\"e\":1,\"\u{E9}\":3}")
    }

    @Test("indent 2 の空の入れ物と、fileData の末尾改行")
    func indentEmptyContainers() {
        #expect(PyJSON.dumpsIndent2(.array([.array([]), .object([])])) == "[\n  [],\n  {}\n]")
        #expect(PyJSON.fileData(.object([])) == Data("{}\n".utf8))
    }

    @Test("parse は文字列の先頭の U+FEFF を保ち、真偽値を区別する")
    func parseKeepsBOMAndBooleans() throws {
        let data = Data("{\"a\": true, \"b\": 1, \"c\": [NaN], \"d\": \"\u{FEFF}x\"}".utf8)
        let object = try #require(PyJSON.parse(data) as? [String: Any])
        #expect(PyJSON.isBool(try #require(object["a"])))
        #expect(!PyJSON.isBool(try #require(object["b"])))
        #expect((object["d"] as? String)?.unicodeScalars.first?.value == 0xFEFF)
    }

    @Test("parse は先頭の BOM・不正な UTF-8・余分な文字を受けない")
    func parseRejects() {
        #expect(PyJSON.parse(Data([0xEF, 0xBB, 0xBF, 0x7B, 0x7D])) == nil)
        #expect(PyJSON.parse(Data([0x22, 0xFF, 0x22])) == nil)
        #expect(PyJSON.parse(Data("{} x".utf8)) == nil)
        #expect(PyJSON.decode(Data([0x22, 0xFF, 0x22])) == nil)
        #expect(PyJSON.decode(Data("{\"k\": 1}".utf8)) == .object([("k", .int(1))]))
    }

    @Test("decode の入れ物の入れ子は 64 段まで（65 段で nil。とても深くてもスタックは溢れない）")
    func decodeDepthLimit() {
        let ok = String(repeating: "{\"a\":", count: 63) + "[1]" + String(repeating: "}", count: 63)
        let tooDeep = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        #expect(PyJSON.decode(ok) != nil)
        #expect(PyJSON.decode(tooDeep) == nil)
        #expect(PyJSON.decode(String(repeating: "[", count: 100_000)) == nil)
    }

    @Test("decode の同じキーは値が後勝ち、位置は最初")
    func decodeDuplicateKeys() {
        #expect(PyJSON.decode(#"{"b":1,"a":2,"b":3}"#) == .object([("b", .int(3)), ("a", .int(2))]))
    }

    @Test("PyJSONValue の == は文字列をスカラー列で、浮動小数をビット列で比べる")
    func equalityRules() {
        #expect(PyJSONValue.string("\u{304C}") != .string("\u{304B}\u{3099}"))
        #expect(PyJSONValue.double(0.0) != .double(-0.0))
        #expect(PyJSONValue.object([("a", .null)]) == .object([("a", .null)]))
    }
}
```

#### `Tests/VDCoreTests/PyRoundTests.swift`（全文。37 行）

```swift
// PyRound が Python の round(x, n) と同じ値を返すこと（PLAN §5.7、T-45）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("PyRound")
struct PyRoundTests {
    @Test("golden pyround: Python の round と同じ値（ビット列で一致）")
    func goldenCases() throws {
        let cases = try Golden.cases("pyround")
        #expect(!cases.isEmpty)
        for item in cases {
            let digits = try item.int("digits")
            let outputs = try item.strings("inputs").map { text -> GoldenJSON in
                guard let value = Double(text) else { return .null }
                return .string(PyJSON.formatDouble(PyRound.round(value, digits: digits)))
            }
            GoldenAssert.matchesJSON(.array(outputs), group: "pyround", name: item.name)
        }
    }

    @Test("掛け算の丸めではなく、正確な 2 進値を 10 進で丸める")
    func roundsExactBinaryValue() {
        #expect(PyRound.round(2.675, digits: 2) == 2.67)
        #expect(PyRound.round(0.0005, digits: 3) == 0.001)
        #expect(PyRound.round(0.25, digits: 1) == 0.2)
    }

    @Test("非有限と負の桁数はそのまま返す")
    func passthrough() {
        #expect(PyRound.round(.infinity, digits: 3) == .infinity)
        #expect(PyRound.round(.nan, digits: 3).isNaN)
        #expect(PyRound.round(1.25, digits: -1) == 1.25)
    }
}
```

#### `Tests/VDCoreTests/PyCaseFoldTableTests.swift`（全文。29 行）

```swift
// casefold の表が生成元（CaseFolding-15.0.0.txt）と一致し、手で編集されていないこと（PLAN §5.7、T-45）。
import CryptoKit
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("PyCaseFoldTable")
struct PyCaseFoldTableTests {
    @Test("生成元の sha256 が記録どおりで、表の見出しにも同じ値がある")
    func sourceHashIsRecorded() throws {
        let source = try Data(contentsOf: PackageRoot.file("tools/unicode/CaseFolding-15.0.0.txt"))
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let recorded = try String(
            contentsOf: PackageRoot.file("tools/unicode/CaseFolding-15.0.0.txt.sha256"), encoding: .utf8)
        #expect(recorded.split(separator: " ").first.map(String.init) == digest)
        let table = try String(contentsOf: PackageRoot.file("Sources/VDCore/PyCaseFoldTable.swift"), encoding: .utf8)
        #expect(table.contains("// source-sha256: \(digest)\n"))
    }

    @Test("C と F の写像の数（1530）と、S と T を含めないこと")
    func entryCountAndStatuses() {
        #expect(PyCaseFoldTable.entryCount == 1530)
        #expect(PyCaseFoldTable.map.count == PyCaseFoldTable.entryCount)
        #expect(PyCaseFoldTable.map[0x1E9E] == [0x73, 0x73])  // ẞ（F）
        #expect(PyCaseFoldTable.map[0x0049] == [0x69])  // I（C。T の 0x0131 ではない）
    }
}
```


### `Tests/VDCoreTests/GoldenCasePyJSONTests.swift`（`@Suite("GoldenCase.orderedObject")`。全文）

```swift
// GoldenCase.orderedObject がキーの順を保つことを golden の入力で確かめる（T-45 4.11）。
import Foundation
import TestSupport
import Testing
import VDCore

@Suite("GoldenCase.orderedObject") struct GoldenCasePyJSONTests {
    @Test("入力の payload をキーの順のまま読む")
    func keepsKeyOrder() throws {
        let item = try Golden.testCase("llm_validate", "multi_order")
        let pairs = try item.orderedObject("payload")
        #expect(pairs.map(\.0) == ["mood", "summary", "tags", "zzz"])
    }

    @Test("辞書の GoldenJSON と同じ中身（順だけが違う）")
    func sameContentAsFields() throws {
        let item = try Golden.testCase("llm_validate", "ok_full")
        let pairs = try item.orderedObject("payload")
        let fields = try item.object("payload")
        #expect(Set(pairs.map(\.0)) == Set(fields.keys))
        #expect(pairs.count == fields.count)
    }

    @Test("全 23 ケースで投げない")
    func allValidateCasesDecode() throws {
        for item in try Golden.cases("llm_validate") {
            #expect(throws: Never.self) { try item.orderedObject("payload") }
        }
    }

    @Test("無いキーは missingKey、オブジェクトでなければ typeMismatch")
    func reportsErrors() throws {
        let item = try Golden.testCase("llm_validate", "ok_minimal")
        #expect(throws: GoldenError.missingKey(group: "llm_validate", name: "ok_minimal", key: "nope")) {
            try item.orderedObject("nope")
        }
        #expect(
            throws: GoldenError.typeMismatch(group: "llm_validate", name: "ok_minimal", key: "name", expected: "オブジェクト")
        ) {
            try item.orderedObject("name")
        }
    }
}
```


## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `PyText.spaceScalars` から `0x001C` を消す | `isSpaceMatchesPython`・`stripRemovesInformationSeparators`・`goldenCases`（PyText） |
| `PyText.lineBreakScalars` から `0x0085` を消す | `lineBreaksMatchPython`・`goldenCases`（PyText） |
| `splitLines` の `scalar.value == 0x000D` を `0xFFFF` にする（`\r\n` を 2 つの区切りにする） | `splitLinesEdges`・`goldenCases`（PyText） |
| `casefold` の先頭で `return text.lowercased()` する | `casefoldFixedExamples`・`goldenCases`（PyText） |
| `isCombining` を `generalCategory == .nonspacingMark` にする | `combiningMatchesPython` |
| `keyPrecedes` を `lhs < rhs` にする | `sortKeysByScalarValue`・`goldenDumps` |
| `escape` の `case 0x00...0x1F:` を `case 0x00...0x1F, 0x7F:` にする | `escapeRules`・`goldenDumps` |
| `hex4` を `String(value, radix: 16, uppercase: true)` にする | `escapeRules`・`goldenDumps` |
| `formatDouble` の `"NaN"` を `"nan"` にする | `formatDoubleRules` |
| `formatDouble` の `guard value.magnitude > 0x1p53` を `> .infinity` にする（2^53〜1e16 の書き直しを止める） | `formatDoubleRules`・`goldenDumps` |
| `parse` を `try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])` にする | `parseKeepsBOMAndBooleans`・`parseRejects` |
| 重複キーで `pairs.remove(at: position)` して末尾に足す | `decodeDuplicateKeys`・`goldenDecode` |
| `decodeUnit` の置換文字を `"?"` にする | `goldenDecode` |
| `maxDecodeDepth` を `1_000_000` にする | `decodeDepthLimit`（スタックが溢れてテストのプロセスが落ちる） |
| `PyRound.round` を `(value * pow(10, Double(digits))).rounded() / pow(10, Double(digits))` にする | `roundsExactBinaryValue`・`goldenCases`（PyRound） |
| `CaseFolding-15.0.0.txt.sha256` の 1 文字を変える | `sourceHashIsRecorded` |
| `orderedObject` を `fields` から作る（`[String: GoldenJSON]` を `map` して返す） | `keepsKeyOrder`（T-19 の `goldenValidate` / `goldenTrim` / `goldenAnalysisJSON` も落ちる） |

（すべて手元で行い、落ちることを確かめてある。）

## 7. 受け入れ条件

- [ ] `python3 tools/unicode/gen-casefold.py tools/unicode/CaseFolding-15.0.0.txt Sources/VDCore/PyCaseFoldTable.swift` をもう一度実行しても `git diff --quiet Sources/VDCore/PyCaseFoldTable.swift` が真
- [ ] `shasum -a 256 tools/unicode/CaseFolding-15.0.0.txt` が `cdd49e55eae3bbf1f0a3f6580c974a0263cb86a6a08daa10fbf705b4808a56f7`
- [ ] `make test` が通る（`PyText`・`PyJSON`・`PyRound`・`PyCaseFoldTable` の全テスト。golden の 4 グループの全ケース）
- [ ] `make lint` が通る（生成物を含む）。PolicyTests（PT-07・PT-19・PT-20。本チケットの `Sources/` のファイルの import は `Foundation` だけ。`Tests/TestSupport/GoldenCase+PyJSON.swift` だけは `Foundation` と `VDCore`）が通る
- [ ] `GoldenCase.orderedObject(_:)` が `Tests/TestSupport/GoldenCase+PyJSON.swift` に在り、`llm_validate` の 23 ケースで投げない（T-19 の前提。00-api-map §15）
- [ ] 6 章の破壊による証明を行い、落ちたテスト名を PR 本文に貼った
- [ ] `Sources/` に `JSONSerialization`・`JSONEncoder` で内部 JSON を書く箇所・`lowercased()` で名前を突き合わせる箇所が無い（後続のチケットのレビュー項目。本チケットでは VDCore の 5 ファイルだけ）

## 8. SPEC の変更

なし（`docs/SPEC.md` の表は変わらない）。PLAN の本文の直しは 10 章。

## 9. マージ後にやること

- T-26 の `PyStr.describe` の浮動小数を `PyJSON.formatDouble` に直す（4.10）
- T-19 の前提の「`PyJSON.decode` が T-45 に無ければ本チケットで足す」を「T-45 の `PyJSON.decode`」に直す

## 10. API 地図への変更提案

`00-api-map.md` の VDCore の行を次に直す（本チケットの宣言と同じ）。→ 00-api-map に反映済み（2026-09-18。`parse(_:) -> Any?` と `isBool(_:)` も地図 §2.4 に載っている）。`decode` は地図の `decode(_ data: Data)` に合わせて Data 版も作る:

- `PyText.swift`: 既存の 9 関数に `static func scalarsEqual(_ lhs: String, _ rhs: String) -> Bool` を足す
- `PyCaseFoldTable.swift`: `enum PyCaseFoldTable { static let unicodeVersion: String; static let entryCount: Int; static let packed: [UInt32]; static let map: [UInt32: [UInt32]] }`（internal。生成物）
- `PyJSON.swift`: `PyJSONValue` に `var foundationObject: Any` と、スカラー列・ビット列で比べる `==`。`PyJSON` の `escape` は「両端の `"` を含まない中身」と明記。`static func formatDouble(_ value: Double) -> String` を足す。`parse` の注記を「`JSONSerialization` は使わない（U+FEFF を落とす）。`decode` ＋ `foundationObject`」に直す。`dumpsIndent2` に `sortKeys` は無い
- `PyJSONParser.swift`（新規）: `extension PyJSON { static func decode(_ text: String) -> PyJSONValue?; static func decode(_ data: Data) -> PyJSONValue? }`（`json.loads` と同じ規則。入れ子 64 段まで）、internal `struct PyJSONParser`
- `PyRound.swift`（新規）: `public enum PyRound { static func round(_ value: Double, digits: Int) -> Double }`
- README の索引: T-45 の前提は T-25 だけ（T-06 の型を使わない） → README に反映済み
- （整合修正で追記 → 反映済み）`PyJSON.parse(_:) -> Any?`・`PyJSON.isBool(_:)`・`PyJSON.decode(_ text: String)` は T-10（同じ VDCore）と T-26（VDNotes の `PyStr.describe`）が使う。地図 §2.4 に載っている
- （整合修正で追記）`GoldenCase.orderedObject(_:)`（`Tests/TestSupport/GoldenCase+PyJSON.swift`。4.11）を本チケットが足す。00-api-map §15 の「作り手 T-45 / 使い手 T-19」に反映済み

PLAN §5.7 への変更提案（本チケットは PLAN を直さない。親が反映する） → PLAN §5.7 に反映済み（2026-09-18。F-45。読み取りは `PyJSON.decode`、浮動小数は `formatDouble`、比較はスカラー列、`PyRound`。PLAN は `PyJSON.parse` の名前を書かない）:

- 「読み取りは `JSONSerialization` でよいが…」を「読み取りも `PyJSON.decode` / `PyJSON.parse`（`JSONSerialization` は文字列の先頭の U+FEFF を落とし、NaN を受けない）」に直す
- 「浮動小数は Swift の `Double.description`（Python の `repr` と一致）」を「`PyJSON.formatDouble`（`Double.description` は 2^53 < \|x\| < 1e16 で `repr` と違う）」に直す
- 「`sortKeys: true` のときはキーを UTF-16 ではなくコードポイント順」に「Swift の `String.<`（NFC に正規化してから比べる）も使わない」を足す
- 文字列の比較・集合・辞書の鍵はスカラー列で行う（Swift の `String.==` は正準等価）旨を §5.7 の文字列の節に足す
- `round(x, n)` は `PyRound.round`（`String(format: "%.nf")` の往復）と §5.7 に足す
