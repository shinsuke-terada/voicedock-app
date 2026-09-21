# T-04 PolicyTests（静的ポリシーテスト PT-01〜PT-22）

| 項目 | 値 |
|---|---|
| ID | T-04 |
| 題 | PolicyTests の基盤（SourceScanner）と PT-01〜22、各 PT の自己テスト |
| Phase | 1 |
| 前提 | T-01、T-02（ci.yml を PT-13 が読む）、T-03（versions.env を PT-13 が読む） |
| 見積もり | 約 1,900 行（うち自己テストの fixture が約 570、SourceScanner と照合の仕組みが約 550）。600 行の目安を超えるが、検査の仕組みと自己テストは切り離すと「空振りしない証明」が別の PR になるので 1 つにする（PR 本文に理由を書く） |

## 目的

PLAN §9.4 の禁止事項を、**書いたら落ちる**静的検査にする。文字列検索が散文や説明のコメントに引っかかる失敗（voicedock TEST-09 / TEST-26）を避けるため、
コメントと文字列リテラルを取り除いた「コード」と「文字列リテラルの中身」を分けて見る簡易字句解析器を作り、照合はトークン単位で行う。
各 PT に「違反を仕込むと落ちる」「紛らわしい語では落ちない」の 2 本の自己テストを付け、検査の空振りと誤検知の両方を防ぐ（CR-17）。

## 参照

- PLAN §9.4（PT の表と照合の規則）、§9.2（CR-10・CR-17・SafeUnlink）、§9.3、§3.4（import の許可リスト）、§3.3（版の固定）、§10.3（SPEC 同期の読み方。MarkdownDocument が従う）
- voicedock@d3d595e `tests/unit/test_no_device_delete.py`（削除呼び出しの AST 検査。属性と裸の名前の両方）、`test_helper_portability.py:121-131`（検査自体の陽性・陰性の対照）、`test_version_pinning.py`（版の固定。`runs-on: ubuntu-latest` を見逃した穴）、`tests/spec_sync.py:34-68`（フェンスを見出しと扱わない節の切り出し）

## 作るもの

| パス | 役割 |
|---|---|
| `Tests/TestSupport/Markdown/MarkdownDocument.swift` | TestSupport。T-05 と後続の SPEC 同期のテストも使う |
| `Tests/PolicyTests/Scanner/SourceScanner.swift` | 字句解析 |
| `Tests/PolicyTests/Scanner/CodeTokenizer.swift` | トークン |
| `Tests/PolicyTests/Scanner/TokenPattern.swift` | トークン単位の照合 |
| `Tests/PolicyTests/Rules/SourceFile.swift` | 検査の対象 |
| `Tests/PolicyTests/Rules/PolicyRule.swift` | 規則・条項・違反・照合 |
| `Tests/PolicyTests/Rules/PolicyCatalog.swift` | PT-01〜22（専用の検査を除く） |
| `Tests/PolicyTests/Rules/ImportPolicy.swift` | PT-07 |
| `Tests/PolicyTests/Rules/PinningPolicy.swift` | PT-13 |
| `Tests/PolicyTests/Rules/OrderingPolicy.swift` | PT-16 |
| `Tests/PolicyTests/Rules/PolicyVocabulary.swift` | PT-06 の語 |
| `Tests/PolicyTests/Rules/PolicyAnchors.swift` | 空振りしないための在るべきもの |
| `Tests/PolicyTests/PolicyTests.swift` | リポジトリへの適用 |
| `Tests/PolicyTests/PolicySelfTests.swift` | 自己テスト |
| `Tests/PolicyTests/SourceScannerTests.swift` | 字句解析の固定テスト |

- 検査の仕組みは**テストのターゲットの中**に置く（本番のモジュールに入れない）。`MarkdownDocument` だけは後続の SPEC 同期のテスト（VDCoreTests など）も使うので TestSupport に置く
- 対象は `Sources/` 配下の全 `.swift`（`Tests/` は対象外。PLAN §9.4）
- T-01 の `Tests/PolicyTests/RepositoryLayoutTests.swift` はそのまま残す

## 仕様

### 1. 字句解析（SourceScanner）の状態機械

入力を Unicode スカラーの配列 `s[0..<n]` にし、同じ長さの出力 `out`（初期値はすべて空白）を作る。**改行は必ず出力にも改行として残す**（行番号を保つ）。文脈のスタックの初期値は `[.code(interpolationDepth: nil)]`。

| 文脈 | 入力 | 動き |
|---|---|---|
| code | `//` | 行末（改行の手前）まで読み飛ばす（出力は空白のまま） |
| code | `/*` | 深さ 1 で始め、`/*` で +1、`*/` で −1、0 で終わる。中の改行は残す |
| code | `#` が k 個続いて `"` | raw 文字列の開始（hashes = k）。`"""` なら複数行。区切りを空白にして string 文脈を積む |
| code | `"` | 通常の文字列の開始（hashes = 0）。`"""` なら複数行 |
| code（補間の中） | `(` | 深さ +1 して出力 |
| code（補間の中） | `)` | 深さ 0 なら補間を閉じて文脈を下ろす（`)` は空白）。そうでなければ深さ −1 して出力 |
| code | その他 | そのまま出力（`#if` の `#` もここ） |
| string | 閉じ（`"` か `"""` の後に `#` を hashes 個） | 開きの直後から閉じの直前までを `raw` としてリテラルに記録し、文脈を下ろす |
| string | `\` の後に `#` を hashes 個、その後が `(` | 補間の開始。`\#…(` を空白にして code（補間、深さ 0）を積む |
| string | `\` の後に `#` を hashes 個、その後が `(` 以外 | エスケープ。その 1 文字まで空白にして進む（raw 文字列の中の単独の `\` はエスケープではない） |
| string（1 行） | 改行 | 閉じていないリテラルとして行末で記録して文脈を下ろす（壊れたソースで先へ進めるため） |
| string | その他 | 空白にする（改行は残す） |

- 入力の終わりで開いている string 文脈はすべて記録する。リテラルの一覧は開きの位置の順に並べる
- 補間の中身はコードとして出力に残り、同時にリテラルの `raw` にもソースのまま入る（`raw` は区切りの間のソースそのもの）
- 限界（テストで保証しない）: Swift の正規表現リテラル（`/…/`・`#/…/#`）の中の `"` は文字列の開きと誤読しうる。正規表現リテラルは PT-20 で禁止しているので、実害は PT-20 の違反と同時にしか起きない

### 2. トークンと照合（CodeTokenizer・TokenPattern）

- トークン: 識別子（`[A-Za-z_][A-Za-z0-9_]*`。`` `x` `` は x）、数値（`[0-9][0-9A-Za-z_.]*`）、それ以外の 1 文字の記号。各トークンは行番号と「直前に空白・改行があったか」を持つ
- `TokenPattern` の要素は「識別子の完全一致」「識別子の接頭辞」「記号」。`adjacent` なら要素の間に空白を許さない（`try!`・`as!`・`#/`・`@unchecked`）
- `freeCall`（`.call(name)`）は自由関数の呼び出しだけを数える: `name` `(` の並びで、直前のトークンが `.` でない（`.` なら、その前が `Darwin` / `Foundation` / `Glibc` のときだけ数える）。直前が `func` なら宣言なので数えない
  - `SafeUnlink.remove(`・`Set.remove(`・`p.print()` は数えない。`Darwin.unlink(` は数える
- メンバーとして書く語（`removeItem`・`.write(to:` など）は修飾に関係なく数える

### 3. 規則（PLAN §9.4 の表の写し）

`PolicyClause` は「見る範囲 `scope`」「許す場所 `allowed`」「コードのパターン」「文字列の照合」を持ち、`scope` に入り `allowed` に入らないファイルで見つかったものを違反にする。
`PathSet` の要素は `/` で終われば接頭辞、それ以外はファイルの完全一致、`*` は全部。パスは `Sources/` からの相対パス。
表の各行の具体的な語と許可場所は下の `PolicyCatalog.swift` がすべて（PLAN §9.4 と一語ずつ対応させること）。PLAN の表の記述から次の点を補った:

- PT-02: `socket(` は `VDLLM/LoopbackHTTP.swift` だけ（`VDModels/` でも許さない）。`LoopbackHTTP.swift` の中では `URL(string:` を禁止
- PT-06: 状態名は `VDCore/States.swift`、エラーコード名は `VDCore/ErrorCode.swift` と `VDContract/DeleteResult.swift`、`\(…)/\(…)` は `VDContract/PartKey.swift` と `VDContract/RelPath.swift`。語は `[A-Z0-9_]` を語の文字として前後の境界で判定する（`WHISPER_FAILED` は状態名 `FAILED` に当たらない）。**語の一覧が空なら必ず違反**にする（空で緑にしない）
- PT-09: `ContinuousClock.now` と `SuspendingClock.now` も同じ意図で禁止する（表の `ContinuousClock()` と同じ現在時刻の取得）
- PT-17: 診断は `Store` を初期化子（`Store(`・`Store.init`）で開かない。読み取りは `ReadOnlyStore.open(url:)`（00-api-map §3）。PLAN の表の `Store.open(` は API 地図では `Store(url:…)` に当たる
- PT-07: 表に無いモジュールのディレクトリが `Sources/` にあれば違反。`Synchronization` はどのモジュールでも許す（PLAN §3.4 の表の上の文）。`import` の直後が `struct` などの種類の語なら、その次の識別子をモジュール名とする
- PT-13: `Package.swift` の各 `.package(…)` に `exact` があり、`from`・`branch`・`revision`・`upToNextMajor`・`upToNextMinor`・`path`・`..<`・`...` が無い。`Package.resolved` の各 pin が `x.y.z` の version と 40 桁の revision を持ち `branch` を持たない。
  `Vendor/versions.env` の 6 キーの形。`Resources/ModelCatalog.json`（在れば）の url が `https://huggingface.co/<org>/<repo>/resolve/<40hex>/<file>`。`.github/workflows/*.yml` の `uses:` が `<owner>/<repo>@<40hex>`（`#` 以降は無視）、`runs-on:` に `latest` を含まない。`.xcode-version` が 1 行。
  `PolicyAnchors.requiredFiles` のファイルが無ければ違反
- PT-16: `VDDevice/IngestService.swift` の `func copyOne(` の本体（最初の `{` から釣り合う `}`）で、最初の `commitPartial(` が最初の `registerCopied(` より前。どちらかが無ければ違反。ファイルや関数が無いのは `PolicyAnchors.requiredFunctions` に載っているときだけ違反（T-15 が載せる）

### 4. 空振りしないための仕掛け

- `PolicyTests.sourcesAreNotEmpty`: `Sources/` に `.swift` が 1 つ以上
- `PolicyTests.vocabularyIsNotEmpty`: PT-06 の語が空でない（T-04 では `docs/PLAN.md` の付録 A.1・A.3 から読む。T-05 で `docs/SPEC.md` に切り替える）
- `PolicyTests.catalogMatchesPlan`: カタログの ID の集合が PLAN §9.4 の表の ID の集合と一致（件数を直書きしない。TEST-01）
- `PolicyAnchors`: 後続のチケットが「在るべきファイル・関数」を足す（T-09 が `Resources/ModelCatalog.json`、T-15 が `("VDDevice/IngestService.swift", "func copyOne(")`）
- 自己テストの語の一覧は docs に依存させず固定の値を使う（`PolicySelfTests.vocabulary`）

### 5. ファイルの全文

以下はすべて `swift format` で整形済み（`make lint` を通る）。Xcode 27.0 で `swift build --build-tests` と `swift test --filter PolicyTests` が通ることを確かめ済み。
URL からパス文字列を取るところは 00-api-map §0 に合わせて `path(percentEncoded: false)` を使う（`SourceTree.load` はファイルを `root.appendingPathComponent(relative)` で読む。実装時に修正）。

#### `Tests/TestSupport/Markdown/MarkdownDocument.swift`

```swift
// Markdown の文書から節・表・コードフェンスを取り出す（PLAN §10.3 の SPEC 同期の読み方。T-04 で作り、T-05 が使う）。
import Foundation

/// 文書が読めないときの誤り。テストは skip せず fail にする（PLAN §10.3）。
public enum MarkdownError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case sectionNotFound(String)

    public var description: String {
        switch self {
        case .missing(let path): "\(path) が見つかりません"
        case .sectionNotFound(let key): "見出し \(key) が見つかりません"
        }
    }
}

/// Markdown の表 1 つ。
public struct MarkdownTable: Equatable, Sendable {
    /// 見出し行のセル。
    public let header: [String]
    /// 本文の行のセル（区切り行 `|---|` を除く）。
    public let rows: [[String]]
    /// 表の直前の空でない行（無ければ nil）。
    public let precedingLine: String?
}

/// Markdown の文書。
public struct MarkdownDocument: Sendable {
    public let lines: [String]

    public init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// リポジトリのルートからの相対パスで読む。無ければ `MarkdownError.missing`。
    public static func load(_ relativePath: String) throws -> MarkdownDocument {
        let url = PackageRoot.file(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw MarkdownError.missing(relativePath)
        }
        return MarkdownDocument(text: text)
    }

    /// コードフェンスの開きか閉じの行か（行頭の空白の後に ``` ）。
    public static func isFence(_ line: String) -> Bool {
        line.drop { $0 == " " || $0 == "\t" }.hasPrefix("```")
    }

    /// 見出し行なら `#` の後の本文を返す（`#` が 1〜6 個と空白 1 つ）。
    public static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }

    /// 次の節の始まりとみなす見出しか（本文が数字・英大文字・「付録」で始まる）。
    public static func isSectionBoundary(_ line: String) -> Bool {
        guard let text = headingText(line), let first = text.unicodeScalars.first else { return false }
        return (first >= "0" && first <= "9") || (first >= "A" && first <= "Z") || text.hasPrefix("付録")
    }

    /// 見出しの本文が `key` で始まる最初の節の行（見出しの次の行から、次の節の見出しの手前まで）。
    /// コードフェンスの中の行は見出しとして扱わない（`# 2026-…` で節が切れた事故。voicedock #13）。
    public func section(_ key: String) throws -> [String] {
        var inFence = false
        var start: Int?
        for (index, line) in lines.enumerated() {
            if Self.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let begin = start {
                if Self.isSectionBoundary(line) { return Array(lines[begin..<index]) }
            } else if let text = Self.headingText(line), text.hasPrefix(key) {
                start = index + 1
            }
        }
        guard let begin = start else { throw MarkdownError.sectionNotFound(key) }
        return Array(lines[begin...])
    }

    /// 表の行をセルに分ける（バッククォートの中の `|` と `\|` では分けない。前後の空白は除く）。
    public static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        let body = line.trimmingCharacters(in: .whitespaces)
        for ch in body.dropFirst() {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        return cells
    }

    /// `lines` の中の表をすべて返す（フェンスの中は見ない）。
    public static func tables(in lines: [String]) -> [MarkdownTable] {
        var tables: [MarkdownTable] = []
        var inFence = false
        var index = 0
        var lastNonEmpty: String?
        while index < lines.count {
            let line = lines[index]
            if isFence(line) {
                inFence.toggle()
                index += 1
                continue
            }
            if !inFence && line.hasPrefix("|") {
                let header = cells(line)
                var rows: [[String]] = []
                var j = index + 1
                while j < lines.count && lines[j].hasPrefix("|") {
                    let rowCells = cells(lines[j])
                    let isSeparator = rowCells.allSatisfy { cell in
                        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
                    }
                    if !isSeparator { rows.append(rowCells) }
                    j += 1
                }
                tables.append(MarkdownTable(header: header, rows: rows, precedingLine: lastNonEmpty))
                lastNonEmpty = lines[j - 1]
                index = j
                continue
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastNonEmpty = line }
            index += 1
        }
        return tables
    }

    /// `lines` の中のコードフェンスの中身（`language` が nil なら言語を問わない）。直前の空でない行も返す。
    public static func fences(in lines: [String], language: String?) -> [(precedingLine: String?, body: [String])] {
        var result: [(precedingLine: String?, body: [String])] = []
        var index = 0
        var lastNonEmpty: String?
        while index < lines.count {
            let line = lines[index]
            if isFence(line) {
                let info = line.drop { $0 == " " || $0 == "\t" }.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var j = index + 1
                while j < lines.count && !isFence(lines[j]) {
                    body.append(lines[j])
                    j += 1
                }
                if language == nil || info == language { result.append((lastNonEmpty, body)) }
                index = j + 1
                lastNonEmpty = nil
                continue
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastNonEmpty = line }
            index += 1
        }
        return result
    }
}
```

#### `Tests/PolicyTests/Scanner/SourceScanner.swift`

```swift
// Swift のソースを「コード」と「文字列リテラル」に分ける簡易字句解析器（PLAN §9.4。T-04）。
// コメントと文字列リテラルの中身を空白に置き換えたコードを作り、文字列リテラルの中身は別に集める。
// 行番号を保つため、改行は置き換えない。文字列補間 `\( … )` の中身はコードとして残す。

/// 文字列リテラル 1 つ。
struct StringLiteral: Equatable, Sendable {
    /// 開きの区切り（`#` を含む）の先頭の位置（Unicode スカラーの添字）。
    let offset: Int
    /// 開きの区切りがある行（1 始まり）。
    let line: Int
    /// 区切りの間のソースそのもの（エスケープは解かない。補間 `\(…)` もそのまま含む）。
    let raw: String
    /// `"""` の複数行リテラルか。
    let isMultiline: Bool
    /// raw 文字列の `#` の数（通常の文字列は 0）。
    let hashCount: Int
}

/// 字句解析の結果。
struct ScannedSource: Sendable {
    /// コメントと文字列リテラルを空白にしたソース（スカラーの数と改行の位置は元と同じ）。
    let code: [Unicode.Scalar]
    /// 文字列リテラルの一覧（出現順。補間の中の文字列も含む）。
    let literals: [StringLiteral]
    /// `code` を String にしたもの。
    var codeText: String {
        var s = String.UnicodeScalarView()
        s.append(contentsOf: code)
        return String(s)
    }
}

/// 簡易字句解析器。
enum SourceScanner {
    private enum Context {
        /// コード。`interpolationDepth` が nil なら最上位、そうでなければ補間の中（括弧の深さ）。
        case code(interpolationDepth: Int?)
        /// 文字列リテラルの中。
        case string(start: Int, offset: Int, line: Int, multiline: Bool, hashes: Int)
    }

    private static let newline: Unicode.Scalar = "\n"
    private static let space: Unicode.Scalar = " "
    private static let quote: Unicode.Scalar = "\""
    private static let hash: Unicode.Scalar = "#"
    private static let backslash: Unicode.Scalar = "\\"
    private static let slash: Unicode.Scalar = "/"
    private static let star: Unicode.Scalar = "*"
    private static let openParen: Unicode.Scalar = "("
    private static let closeParen: Unicode.Scalar = ")"

    /// `text` を字句解析する。
    static func scan(_ text: String) -> ScannedSource {
        let s = Array(text.unicodeScalars)
        let n = s.count
        var out = [Unicode.Scalar](repeating: space, count: n)
        var literals: [StringLiteral] = []
        var stack: [Context] = [.code(interpolationDepth: nil)]
        var line = 1
        var i = 0

        func starts(_ pattern: [Unicode.Scalar], at index: Int) -> Bool {
            guard index + pattern.count <= n else { return false }
            for k in 0..<pattern.count where s[index + k] != pattern[k] { return false }
            return true
        }
        /// index の文字を空白にする（改行は残し、行を数える）。
        func blank(_ index: Int) {
            if s[index] == newline {
                out[index] = newline
                line += 1
            }
        }
        /// index の文字をそのままコードに出す。
        func emit(_ index: Int) {
            out[index] = s[index]
            if s[index] == newline { line += 1 }
        }
        func raw(_ from: Int, _ to: Int) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: s[from..<to])
            return String(v)
        }

        while i < n {
            guard let top = stack.last else { break }
            switch top {
            case .code(let depth):
                if starts([slash, slash], at: i) {
                    while i < n && s[i] != newline { i += 1 }
                    continue
                }
                if starts([slash, star], at: i) {
                    var level = 0
                    while i < n {
                        if starts([slash, star], at: i) {
                            level += 1
                            i += 2
                        } else if starts([star, slash], at: i) {
                            level -= 1
                            i += 2
                            if level == 0 { break }
                        } else {
                            blank(i)
                            i += 1
                        }
                    }
                    continue
                }
                if s[i] == hash || s[i] == quote {
                    var hashes = 0
                    while i + hashes < n && s[i + hashes] == hash { hashes += 1 }
                    let q = i + hashes
                    if q < n && s[q] == quote {
                        let multiline = starts([quote, quote, quote], at: q)
                        let length = hashes + (multiline ? 3 : 1)
                        let startLine = line
                        for k in i..<(i + length) { blank(k) }
                        stack.append(
                            .string(start: i + length, offset: i, line: startLine, multiline: multiline, hashes: hashes)
                        )
                        i += length
                        continue
                    }
                }
                if let d = depth {
                    if s[i] == openParen {
                        stack[stack.count - 1] = .code(interpolationDepth: d + 1)
                        emit(i)
                        i += 1
                        continue
                    }
                    if s[i] == closeParen {
                        if d == 0 {
                            stack.removeLast()
                            i += 1
                            continue
                        }
                        stack[stack.count - 1] = .code(interpolationDepth: d - 1)
                        emit(i)
                        i += 1
                        continue
                    }
                }
                emit(i)
                i += 1
            case .string(let start, let offset, let startLine, let multiline, let hashes):
                let closing = (multiline ? [quote, quote, quote] : [quote]) + Array(repeating: hash, count: hashes)
                if starts(closing, at: i) {
                    literals.append(
                        StringLiteral(
                            offset: offset, line: startLine, raw: raw(start, i), isMultiline: multiline,
                            hashCount: hashes))
                    stack.removeLast()
                    for k in i..<(i + closing.count) { blank(k) }
                    i += closing.count
                    continue
                }
                let escape = [backslash] + Array(repeating: hash, count: hashes)
                if starts(escape, at: i) {
                    let j = i + escape.count
                    if j < n && s[j] == openParen {
                        for k in i...j { blank(k) }
                        stack.append(.code(interpolationDepth: 0))
                        i = j + 1
                        continue
                    }
                    for k in i..<min(j + 1, n) { blank(k) }
                    i = j + 1
                    continue
                }
                if !multiline && s[i] == newline {
                    literals.append(
                        StringLiteral(
                            offset: offset, line: startLine, raw: raw(start, i), isMultiline: false, hashCount: hashes))
                    stack.removeLast()
                    blank(i)
                    i += 1
                    continue
                }
                blank(i)
                i += 1
            }
        }
        for context in stack.reversed() {
            if case .string(let start, let offset, let startLine, let multiline, let hashes) = context {
                literals.append(
                    StringLiteral(
                        offset: offset, line: startLine, raw: raw(start, n), isMultiline: multiline, hashCount: hashes))
            }
        }
        literals.sort { $0.offset < $1.offset }
        return ScannedSource(code: out, literals: literals)
    }
}
```

#### `Tests/PolicyTests/Scanner/CodeTokenizer.swift`

```swift
// SourceScanner のコードを語（トークン）に分ける（PLAN §9.4。T-04）。

/// コードの語 1 つ。
struct CodeToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// 識別子とキーワード（`[A-Za-z_][A-Za-z0-9_]*`。`` `x` `` は x）。
        case identifier
        /// 数値（`[0-9][0-9A-Za-z_.]*`）。
        case number
        /// それ以外の 1 文字（`.` `(` `@` `#` `!` など）。
        case punctuation
    }
    let kind: Kind
    let text: String
    /// 1 始まりの行番号。
    let line: Int
    /// 直前のトークンとの間に空白・改行があったか（ファイルの先頭は true）。
    let spaceBefore: Bool
}

/// トークンへの分割。
enum CodeTokenizer {
    static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "_"
    }

    static func isIdentifierContinue(_ c: Unicode.Scalar) -> Bool {
        isIdentifierStart(c) || (c >= "0" && c <= "9")
    }

    static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }

    static func tokens(_ code: [Unicode.Scalar]) -> [CodeToken] {
        var result: [CodeToken] = []
        var i = 0
        var line = 1
        var sawSpace = true
        func text(_ from: Int, _ to: Int) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: code[from..<to])
            return String(v)
        }
        while i < code.count {
            let c = code[i]
            if isSpace(c) {
                if c == "\n" { line += 1 }
                sawSpace = true
                i += 1
                continue
            }
            if c == "`", i + 1 < code.count, isIdentifierStart(code[i + 1]) {
                var j = i + 1
                while j < code.count && isIdentifierContinue(code[j]) { j += 1 }
                if j < code.count && code[j] == "`" {
                    result.append(CodeToken(kind: .identifier, text: text(i + 1, j), line: line, spaceBefore: sawSpace))
                    sawSpace = false
                    i = j + 1
                    continue
                }
            }
            if isIdentifierStart(c) {
                var j = i
                while j < code.count && isIdentifierContinue(code[j]) { j += 1 }
                result.append(CodeToken(kind: .identifier, text: text(i, j), line: line, spaceBefore: sawSpace))
                sawSpace = false
                i = j
                continue
            }
            if isDigit(c) {
                var j = i
                while j < code.count && (isIdentifierContinue(code[j]) || code[j] == ".") { j += 1 }
                result.append(CodeToken(kind: .number, text: text(i, j), line: line, spaceBefore: sawSpace))
                sawSpace = false
                i = j
                continue
            }
            result.append(CodeToken(kind: .punctuation, text: text(i, i + 1), line: line, spaceBefore: sawSpace))
            sawSpace = false
            i += 1
        }
        return result
    }
}
```

#### `Tests/PolicyTests/Scanner/TokenPattern.swift`

```swift
// トークンの並びで禁止語を表す（PLAN §9.4 のトークン単位の照合。T-04）。

/// パターンの 1 要素。
enum PatternElement: Equatable, Sendable {
    /// 識別子が完全一致。
    case identifier(String)
    /// 識別子が接頭辞で一致（`URLSession` は `URLSessionConfiguration` にも当たる）。
    case identifierPrefix(String)
    /// 1 文字の記号。
    case punctuation(String)
}

/// 禁止するトークンの並び。
struct TokenPattern: Equatable, Sendable {
    /// 違反の表示に使う語（例 `remove(`）。
    let display: String
    let elements: [PatternElement]
    /// 要素の間に空白を許さない（`try!`・`as!`・`#/`）。
    let adjacent: Bool
    /// 自由関数の呼び出しとしてだけ数える（直前が `.` でない、または `Darwin.` / `Foundation.` / `Glibc.` で修飾されている。直前が `func` なら宣言なので数えない）。
    let freeCall: Bool

    /// 自由関数の呼び出し `name(`。
    static func call(_ name: String) -> TokenPattern {
        TokenPattern(
            display: "\(name)(", elements: [.identifier(name), .punctuation("(")], adjacent: false, freeCall: true)
    }

    /// 識別子 1 つ（完全一致）。
    static func word(_ name: String) -> TokenPattern {
        TokenPattern(display: name, elements: [.identifier(name)], adjacent: false, freeCall: false)
    }

    /// 識別子 1 つ（接頭辞）。
    static func prefix(_ name: String) -> TokenPattern {
        TokenPattern(display: "\(name)…", elements: [.identifierPrefix(name)], adjacent: false, freeCall: false)
    }

    /// 並び。`spec` は空白区切り（識別子は識別子、それ以外の 1 文字は記号）。例 `"Date . now"`。
    static func sequence(_ display: String, _ spec: String, adjacent: Bool = false) -> TokenPattern {
        let elements: [PatternElement] = spec.split(separator: " ").map { part in
            let text = String(part)
            if let first = text.unicodeScalars.first, CodeTokenizer.isIdentifierStart(first) {
                return .identifier(text)
            }
            return .punctuation(text)
        }
        return TokenPattern(display: display, elements: elements, adjacent: adjacent, freeCall: false)
    }

    /// 自由関数の呼び出しを修飾してよい名前。
    static let callQualifiers: Set<String> = ["Darwin", "Foundation", "Glibc"]

    /// `tokens` の中で一致した位置（先頭のトークンの添字）を返す。
    func matches(in tokens: [CodeToken]) -> [Int] {
        var found: [Int] = []
        guard !elements.isEmpty, tokens.count >= elements.count else { return found }
        for start in 0...(tokens.count - elements.count) where matchesAt(start, tokens) {
            found.append(start)
        }
        return found
    }

    private func matchesAt(_ start: Int, _ tokens: [CodeToken]) -> Bool {
        for (k, element) in elements.enumerated() {
            let token = tokens[start + k]
            if adjacent && k > 0 && token.spaceBefore { return false }
            switch element {
            case .identifier(let name):
                if token.kind != .identifier || token.text != name { return false }
            case .identifierPrefix(let name):
                if token.kind != .identifier || !token.text.hasPrefix(name) { return false }
            case .punctuation(let symbol):
                if token.kind != .punctuation || token.text != symbol { return false }
            }
        }
        if freeCall && start > 0 {
            let previous = tokens[start - 1]
            if previous.kind == .identifier && previous.text == "func" { return false }
            if previous.kind == .punctuation && previous.text == "." {
                guard start >= 2 else { return false }
                let qualifier = tokens[start - 2]
                return qualifier.kind == .identifier && Self.callQualifiers.contains(qualifier.text)
            }
        }
        return true
    }
}
```

#### `Tests/PolicyTests/Rules/SourceFile.swift`

```swift
// 検査の対象のソース（Sources/ からの相対パスと中身。字句解析の結果を持つ）（T-04）。
import Foundation
import TestSupport

/// 検査の対象の 1 ファイル。
struct SourceFile: Sendable {
    /// `Sources/` からの相対パス（例 `VDCore/SafeUnlink.swift`）。
    let relativePath: String
    let scanned: ScannedSource
    let tokens: [CodeToken]

    init(relativePath: String, text: String) {
        self.relativePath = relativePath
        scanned = SourceScanner.scan(text)
        tokens = CodeTokenizer.tokens(scanned.code)
    }

    /// 最初の要素（モジュールのディレクトリ名）。
    var module: String { String(relativePath.prefix { $0 != "/" }) }
}

/// `Sources/` 配下の全 `.swift` を読む。
enum SourceTree {
    static func load(root: URL = PackageRoot.file("Sources")) throws -> [SourceFile] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        var paths: [String] = []
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            paths.append(path)
        }
        return try paths.sorted().map { relative in
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            return SourceFile(relativePath: relative, text: text)
        }
    }
}
```

#### `Tests/PolicyTests/Rules/PolicyRule.swift`

```swift
// 静的ポリシーの規則と照合の仕組み（PLAN §9.4。T-04）。
import Foundation

/// パスの集合。`/` で終わる要素はディレクトリの接頭辞、それ以外はファイルの完全一致。`*` は全部。
struct PathSet: Sendable {
    let entries: [String]

    static let all = PathSet(entries: ["*"])
    static let none = PathSet(entries: [])

    func contains(_ relativePath: String) -> Bool {
        entries.contains { entry in
            if entry == "*" { return true }
            if entry.hasSuffix("/") { return relativePath.hasPrefix(entry) }
            return relativePath == entry
        }
    }
}

/// 文字列リテラルの中身に対する照合。
struct LiteralMatcher: Sendable {
    let display: String
    let matches: @Sendable (String) -> Bool

    /// 部分文字列を含む。
    static func contains(_ needle: String) -> LiteralMatcher {
        LiteralMatcher(display: needle) { $0.contains(needle) }
    }

    /// 正規表現に一致する部分がある。
    static func regex(_ display: String, _ pattern: String, caseInsensitive: Bool = false) -> LiteralMatcher {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        let expression = try? NSRegularExpression(pattern: pattern, options: options)
        return LiteralMatcher(display: display) { raw in
            guard let expression else { return true }  // 正規表現が壊れていたら必ず違反にする（空振りしない）
            return expression.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)) != nil
        }
    }

    /// 語（`[A-Z0-9_]` を語の文字とする）としてどれかを含む。語の一覧が空なら必ず違反にする（空で緑にしない）。
    static func words(_ display: String, _ words: [String]) -> LiteralMatcher {
        guard !words.isEmpty else { return LiteralMatcher(display: display) { _ in true } }
        let alternation = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return regex(display, "(?<![A-Z0-9_])(?:\(alternation))(?![A-Z0-9_])")
    }
}

/// 規則の 1 条項（どのファイルを見て、何を探し、どこなら許すか）。
struct PolicyClause: Sendable {
    let scope: PathSet
    let allowed: PathSet
    let code: [TokenPattern]
    let literals: [LiteralMatcher]

    init(scope: PathSet = .all, allowed: PathSet, code: [TokenPattern] = [], literals: [LiteralMatcher] = []) {
        self.scope = scope
        self.allowed = allowed
        self.code = code
        self.literals = literals
    }
}

/// 規則（PT-nn）。
struct PolicyRule: Sendable {
    let id: String
    let clauses: [PolicyClause]
}

/// 違反 1 件。
struct Violation: Equatable, Sendable, CustomStringConvertible {
    let rule: String
    let path: String
    let line: Int
    let what: String

    var description: String { "\(rule) \(path):\(line) \(what)" }
}

/// 規則をファイルの集合に当てる。
enum PolicyEngine {
    static func check(_ rule: PolicyRule, files: [SourceFile]) -> [Violation] {
        var violations: [Violation] = []
        for clause in rule.clauses {
            for file in files
            where clause.scope.contains(file.relativePath) && !clause.allowed.contains(file.relativePath) {
                for pattern in clause.code {
                    for index in pattern.matches(in: file.tokens) {
                        violations.append(
                            Violation(
                                rule: rule.id, path: file.relativePath, line: file.tokens[index].line,
                                what: pattern.display))
                    }
                }
                for matcher in clause.literals {
                    for literal in file.scanned.literals where matcher.matches(literal.raw) {
                        violations.append(
                            Violation(rule: rule.id, path: file.relativePath, line: literal.line, what: matcher.display)
                        )
                    }
                }
            }
        }
        return violations
    }
}
```

#### `Tests/PolicyTests/Rules/PolicyCatalog.swift`

```swift
// PT-01〜PT-22 の定義（PLAN §9.4 の表の写し。T-04）。PT-07・PT-13・PT-16 は別のファイルの専用の検査。
import Foundation

enum PolicyCatalog {
    /// PT-01 の削除の呼び出し（PT-17 も使う）。
    static let deletionPatterns: [TokenPattern] = [
        .word("removeItem"), .word("trashItem"), .call("unlink"), .call("unlinkat"), .call("rmdir"),
        .call("remove"), .call("removefile"),
    ]

    /// PT-12 の書き込みの呼び出し（PT-17 も使う）。
    static let writePatterns: [TokenPattern] = [
        .sequence(".write(to:", ". write ( to :"),
        .sequence("write(toFile:", "write ( toFile :"),
        .sequence("createFile(", "createFile ("),
        .sequence("FileHandle(forWritingTo:", "FileHandle ( forWritingTo"),
        TokenPattern(
            display: "FileHandle(forUpdating",
            elements: [.identifier("FileHandle"), .punctuation("("), .identifierPrefix("forUpdating")],
            adjacent: false, freeCall: false),
        .sequence("copyItem(", "copyItem ("),
        .sequence("moveItem(", "moveItem ("),
        .prefix("replaceItem"),
        .call("rename"),
        .call("renameat"),
        .word("O_CREAT"),
    ]

    /// VDContract 以外の VD モジュール（PT-15 が reaper の import を検査する）。
    static let nonContractModules = [
        "VDCore", "VDStore", "VDProcess", "VDAudio", "VDDevice", "VDTranscribe", "VDLLM", "VDNotes", "VDModels",
        "VDPipeline",
    ]

    /// トークンと文字列で検査する規則（PT-07・PT-13・PT-16 を除く）。
    static func tokenRules(vocabulary: PolicyVocabulary) -> [PolicyRule] {
        [
            PolicyRule(
                id: "PT-01",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDCore/SafeUnlink.swift", "VDContract/AtomicFile.swift", "voicedock-reaper/Unlinker.swift",
                            "VDPipeline/DeletionEnabler.swift",
                        ]),
                        code: deletionPatterns)
                ]),
            PolicyRule(
                id: "PT-02",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDModels/", "VDLLM/LoopbackHTTP.swift"]),
                        code: [
                            .prefix("URLSession"), .sequence("import Network", "import Network"), .prefix("CFNetwork"),
                            .word("NWConnection"), .prefix("CFSocket"),
                        ]),
                    PolicyClause(allowed: PathSet(entries: ["VDLLM/LoopbackHTTP.swift"]), code: [.call("socket")]),
                    PolicyClause(
                        scope: PathSet(entries: ["VDLLM/LoopbackHTTP.swift"]), allowed: .none,
                        code: [.sequence("URL(string:", "URL ( string :")]),
                ]),
            PolicyRule(
                id: "PT-03",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDProcess/"]),
                        code: [
                            .prefix("posix_spawn"), .sequence("Process(", "Process ("), .word("NSTask"), .call("fork"),
                            .call("vfork"), .call("execv"), .call("execve"), .call("execvp"), .call("execvP"),
                            .call("execl"), .call("execle"), .call("execlp"),
                        ])
                ]),
            PolicyRule(
                id: "PT-04",
                clauses: [
                    PolicyClause(
                        allowed: .none, code: [.call("system"), .call("popen")],
                        literals: [
                            .contains("/bin/sh"), .contains("/bin/bash"), .contains("/bin/zsh"),
                            .contains("/usr/bin/env"),
                        ])
                ]),
            PolicyRule(
                id: "PT-05",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDStore/Transitions.swift"]),
                        literals: [
                            .regex(
                                "UPDATE … SET … status",
                                "(?=[\\s\\S]*\\bUPDATE\\b)(?=[\\s\\S]*\\bSET\\b)(?=[\\s\\S]*\\bstatus\\b)",
                                caseInsensitive: true),
                            .regex(
                                "INSERT INTO recordings", "\\bINSERT\\s+INTO\\s+recordings\\b", caseInsensitive: true),
                            .regex("INSERT INTO sessions", "\\bINSERT\\s+INTO\\s+sessions\\b", caseInsensitive: true),
                        ]),
                    PolicyClause(
                        allowed: .none, code: [.word("PersistableRecord"), .word("MutablePersistableRecord")]),
                ]),
            PolicyRule(
                id: "PT-06",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDCore/States.swift"]),
                        literals: [.words("状態名", vocabulary.stateNames)]),
                    PolicyClause(
                        allowed: PathSet(entries: ["VDCore/ErrorCode.swift", "VDContract/DeleteResult.swift"]),
                        literals: [.words("エラーコード名", vocabulary.errorCodeNames)]),
                    PolicyClause(
                        allowed: PathSet(entries: ["VDContract/PartKey.swift", "VDContract/RelPath.swift"]),
                        literals: [.regex("\\(…)/\\(…)", "\\\\\\([^)]*\\)/\\\\\\(")]),
                ]),
            PolicyRule(
                id: "PT-08",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDCore/Log.swift", "voicedock-reaper/ReaperLog.swift", "voicedock-reaper/main.swift",
                        ]),
                        code: [
                            .sequence("Logger(", "Logger ("), .call("os_log"), .call("NSLog"), .call("print"),
                            .call("debugPrint"), .call("dump"),
                        ])
                ]),
            PolicyRule(
                id: "PT-09",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDCore/Clock.swift", "voicedock-reaper/ReaperClock.swift"]),
                        code: [
                            .sequence("Date()", "Date ( )"), .sequence("Date.now", "Date . now"),
                            .sequence("Date(timeIntervalSinceNow:", "Date ( timeIntervalSinceNow"),
                            .call("CFAbsoluteTimeGetCurrent"), .sequence("DispatchTime.now(", "DispatchTime . now ("),
                            .sequence("ContinuousClock()", "ContinuousClock ( )"),
                            .sequence("ContinuousClock.now", "ContinuousClock . now"),
                            .sequence("SuspendingClock()", "SuspendingClock ( )"),
                            .sequence("SuspendingClock.now", "SuspendingClock . now"),
                            .call("gettimeofday"), .call("clock_gettime"), .sequence("time(nil)", "time ( nil )"),
                        ])
                ]),
            PolicyRule(
                id: "PT-10",
                clauses: [
                    PolicyClause(
                        scope: PathSet(entries: ["VDDevice/"]),
                        allowed: PathSet(entries: ["VDDevice/DeviceReader.swift", "VDDevice/InboxWriter.swift"]),
                        code: [
                            .call("open"), .call("openat"), .call("opendir"), .call("fopen"),
                            .sequence("FileHandle(", "FileHandle ("),
                            .sequence("Data(contentsOf:", "Data ( contentsOf :"),
                            .sequence("InputStream(", "InputStream ("),
                        ]),
                    PolicyClause(
                        scope: PathSet(entries: ["VDDevice/DeviceReader.swift", "VDContract/TargetIdentity.swift"]),
                        allowed: .none,
                        code: [
                            .word("O_WRONLY"), .word("O_RDWR"), .word("O_CREAT"), .word("O_TRUNC"), .word("O_APPEND"),
                            .prefix("forWriting"), .prefix("forUpdating"),
                        ]),
                ]),
            PolicyRule(
                id: "PT-11",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDCore/AppPaths.swift", "VDPipeline/DeletionEnabler.swift"]),
                        code: [.word("bundledReaperURL")]),
                    PolicyClause(
                        allowed: PathSet(entries: ["VDContract/HomeLayout.swift", "VDPipeline/DeletionEnabler.swift"]),
                        code: [.word("binDirectory")]),
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDContract/HomeLayout.swift", "VDPipeline/DeletionEnabler.swift",
                            "VDPipeline/ReaperRunner.swift",
                            "VDPipeline/LockEvaluator.swift", "voicedock-reaper/",
                        ]),
                        code: [.word("reaperExecutable"), .word("reaperConf")]),
                ]),
            PolicyRule(
                id: "PT-12",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDContract/AtomicFile.swift", "VDContract/FileLock.swift", "VDCore/LogFile.swift",
                            "VDDevice/InboxWriter.swift", "VDModels/ModelDownloader.swift",
                            "VDModels/ModelImporter.swift",
                            "VDAudio/Normalizer.swift", "voicedock-reaper/ProcessedLog.swift",
                            "voicedock-reaper/ReaperLog.swift", "voicedock-reaper/QueueFiles.swift",
                            "VDPipeline/DeletionEnabler.swift",
                        ]),
                        code: writePatterns)
                ]),
            PolicyRule(
                id: "PT-14",
                clauses: [
                    PolicyClause(
                        allowed: .none,
                        code: [
                            .sequence("@unchecked", "@ unchecked", adjacent: true),
                            .sequence("nonisolated(unsafe)", "nonisolated ( unsafe )"),
                        ])
                ]),
            PolicyRule(
                id: "PT-15",
                clauses: [
                    PolicyClause(
                        scope: PathSet(entries: ["voicedock-reaper/"]), allowed: .none,
                        code: [.word("Process"), .prefix("posix_spawn"), .prefix("URLSession"), .word("removeItem")]
                            + nonContractModules.map { .sequence("import \($0)", "import \($0)") },
                        literals: [.contains("diskutil")])
                ]),
            PolicyRule(
                id: "PT-17",
                clauses: [
                    PolicyClause(
                        scope: PathSet(entries: ["VDPipeline/Diagnostics/"]), allowed: .none,
                        code: deletionPatterns + writePatterns + [
                            .word("AtomicFile"), .sequence("Store(", "Store ("),
                            .sequence("Store.init", "Store . init"),
                        ])
                ]),
            PolicyRule(
                id: "PT-18",
                clauses: [
                    PolicyClause(
                        allowed: .none,
                        code: [
                            .sequence(
                                "ProcessInfo.processInfo.environment", "ProcessInfo . processInfo . environment"),
                            .call("getenv"), .call("setenv"),
                        ])
                ]),
            PolicyRule(
                id: "PT-19",
                clauses: [
                    PolicyClause(
                        allowed: .none,
                        code: [
                            .call("precondition"), .call("preconditionFailure"), .call("assert"),
                            .call("assertionFailure"), .call("fatalError"), .sequence("try!", "try !", adjacent: true),
                            .sequence("as!", "as !", adjacent: true),
                        ])
                ]),
            PolicyRule(
                id: "PT-20",
                clauses: [
                    PolicyClause(
                        allowed: .none,
                        code: [
                            .sequence("Regex<", "Regex <"), .sequence("Regex(", "Regex ("),
                            .sequence("#/", "# /", adjacent: true),
                        ])
                ]),
            PolicyRule(
                id: "PT-21",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDCore/States.swift", "VDStore/Transitions.swift", "VDPipeline/Recovery.swift",
                        ]),
                        code: [.sequence(".recovery", ". recovery")])
                ]),
            PolicyRule(
                id: "PT-22",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDContract/TargetIdentity.swift"]),
                        code: [.sequence("VolumeHandle(", "VolumeHandle (")])
                ]),
        ]
    }

    /// PLAN §9.4 の表の全 ID（専用の検査を含む）。
    static func allIDs(vocabulary: PolicyVocabulary) -> [String] {
        (tokenRules(vocabulary: vocabulary).map(\.id) + [ImportPolicy.id, PinningPolicy.id, OrderingPolicy.id]).sorted()
    }
}
```

#### `Tests/PolicyTests/Rules/ImportPolicy.swift`

```swift
// PT-07: Sources/ の各モジュールの import が PLAN §3.4 の許可リストに収まる（T-04）。

enum ImportPolicy {
    static let id = "PT-07"

    /// PLAN §3.4 の表の写し。
    static let allowed: [String: Set<String>] = [
        "VDContract": ["Foundation", "Darwin", "CryptoKit"],
        "VDCore": ["Foundation", "Darwin", "os", "CryptoKit", "VDContract"],
        "VDStore": ["Foundation", "VDContract", "VDCore", "GRDB"],
        "VDProcess": ["Foundation", "Darwin", "VDCore"],
        "VDDevice": [
            "Foundation", "Darwin", "AppKit", "CryptoKit", "VDContract", "VDCore", "VDProcess", "VDStore", "VDAudio",
        ],
        "VDAudio": ["Foundation", "AVFoundation", "CryptoKit", "VDContract", "VDCore"],
        "VDTranscribe": ["Foundation", "VDContract", "VDCore", "VDProcess"],
        "VDLLM": ["Foundation", "Darwin", "VDContract", "VDCore", "VDProcess"],
        "VDNotes": ["Foundation", "CryptoKit", "VDContract", "VDCore", "Yams"],
        "VDModels": ["Foundation", "CryptoKit", "VDContract", "VDCore"],
        "VDPipeline": [
            "Foundation", "Darwin", "Security", "CryptoKit", "VDContract", "VDCore", "VDStore", "VDProcess", "VDDevice",
            "VDAudio", "VDTranscribe", "VDLLM", "VDNotes",
        ],
        "VoiceDockApp": [
            "Foundation", "AppKit", "SwiftUI", "ServiceManagement", "os", "VDContract", "VDCore", "VDStore",
            "VDProcess", "VDDevice", "VDAudio", "VDTranscribe", "VDLLM", "VDNotes", "VDModels", "VDPipeline",
        ],
        "voicedock-reaper": ["Foundation", "Darwin", "VDContract"],
    ]

    /// すべてのモジュールで import してよいもの（PLAN §3.4。`Mutex` のため）。
    static let allowedEverywhere: Set<String> = ["Synchronization"]

    /// `import` の対象の前に来てよい種類の語（`import struct Foundation.Date` など）。
    static let importKinds: Set<String> = ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"]

    /// ファイルの import を（モジュール名, 行）で返す。
    static func imports(in file: SourceFile) -> [(module: String, line: Int)] {
        let tokens = file.tokens
        var result: [(module: String, line: Int)] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let isImport = token.kind == .identifier && token.text == "import"
            let previousIsDot = index > 0 && tokens[index - 1].text == "."
            if isImport && !previousIsDot, index + 1 < tokens.count {
                var next = index + 1
                if importKinds.contains(tokens[next].text), next + 1 < tokens.count { next += 1 }
                if tokens[next].kind == .identifier {
                    result.append((tokens[next].text, token.line))
                }
                index = next + 1
                continue
            }
            index += 1
        }
        return result
    }

    static func check(files: [SourceFile]) -> [Violation] {
        var violations: [Violation] = []
        for file in files {
            guard let allowedModules = allowed[file.module] else {
                violations.append(
                    Violation(rule: id, path: file.relativePath, line: 1, what: "表に無いモジュール \(file.module)"))
                continue
            }
            for item in imports(in: file)
            where !allowedModules.contains(item.module) && !allowedEverywhere.contains(item.module) {
                violations.append(
                    Violation(rule: id, path: file.relativePath, line: item.line, what: "import \(item.module)"))
            }
        }
        return violations
    }
}
```

#### `Tests/PolicyTests/Rules/PinningPolicy.swift`

```swift
// PT-13: 版・URL・action・ランナーの固定（PLAN §3.3・§9.4。T-04）。
import Foundation

enum PinningPolicy {
    static let id = "PT-13"

    /// `root`（リポジトリのルート）の下を検査する。`requiredFiles` のファイルが無ければ違反。
    static func check(root: URL, requiredFiles: [String]) -> [Violation] {
        var violations: [Violation] = []
        for path in requiredFiles
        where !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path(percentEncoded: false)) {
            violations.append(Violation(rule: id, path: path, line: 1, what: "ファイルがありません"))
        }
        violations += checkPackageSwift(root: root)
        violations += checkPackageResolved(root: root)
        violations += checkVersionsEnv(root: root)
        violations += checkModelCatalog(root: root)
        violations += checkWorkflows(root: root)
        violations += checkXcodeVersion(root: root)
        return violations
    }

    static func read(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range)?.range == range
    }

    /// Package.swift の `.package(` ごとに `exact:` があり、`from:` などの範囲指定が無い。
    static func checkPackageSwift(root: URL) -> [Violation] {
        guard let text = read(root, "Package.swift") else { return [] }
        let tokens = CodeTokenizer.tokens(SourceScanner.scan(text).code)
        let forbidden: Set<String> = ["from", "branch", "revision", "upToNextMajor", "upToNextMinor", "path"]
        var violations: [Violation] = []
        var index = 0
        while index + 2 < tokens.count {
            guard tokens[index].text == ".", tokens[index + 1].text == "package", tokens[index + 2].text == "(" else {
                index += 1
                continue
            }
            var depth = 0
            var end = index + 2
            var body: [CodeToken] = []
            while end < tokens.count {
                if tokens[end].text == "(" { depth += 1 }
                if tokens[end].text == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(tokens[end])
                end += 1
            }
            let words = Set(body.filter { $0.kind == .identifier }.map(\.text))
            let texts = body.map(\.text).joined()
            if !words.contains("exact") || !words.isDisjoint(with: forbidden) || texts.contains("..<")
                || texts.contains("...")
            {
                violations.append(
                    Violation(rule: id, path: "Package.swift", line: tokens[index].line, what: ".package( が exact: でない")
                )
            }
            index = end + 1
        }
        return violations
    }

    /// Package.resolved の各 pin が version（x.y.z）と 40 桁の revision を持ち、branch を持たない。
    static func checkPackageResolved(root: URL) -> [Violation] {
        guard let text = read(root, "Package.resolved"), let data = text.data(using: .utf8) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pins = object["pins"] as? [[String: Any]]
        else {
            return [Violation(rule: id, path: "Package.resolved", line: 1, what: "JSON を読めません")]
        }
        var violations: [Violation] = []
        for pin in pins {
            let identity = pin["identity"] as? String ?? "?"
            let state = pin["state"] as? [String: Any] ?? [:]
            let version = state["version"] as? String ?? ""
            let revision = state["revision"] as? String ?? ""
            if !matches("[0-9]+\\.[0-9]+\\.[0-9]+", version) || !matches("[0-9a-f]{40}", revision)
                || state["branch"] != nil
            {
                violations.append(
                    Violation(rule: id, path: "Package.resolved", line: 1, what: "\(identity) が版で固定されていない"))
            }
        }
        return violations
    }

    /// versions.env の REF がタグ、SHA が 40 桁、REPO が ggml-org の GitHub。
    static func checkVersionsEnv(root: URL) -> [Violation] {
        guard let text = read(root, "Vendor/versions.env") else { return [] }
        let rules: [String: String] = [
            "WHISPER_CPP_REPO": "https://github\\.com/ggml-org/whisper\\.cpp\\.git",
            "WHISPER_CPP_REF": "v[0-9]+\\.[0-9]+\\.[0-9]+",
            "WHISPER_CPP_SHA": "[0-9a-f]{40}",
            "LLAMA_CPP_REPO": "https://github\\.com/ggml-org/llama\\.cpp\\.git",
            "LLAMA_CPP_REF": "b[0-9]+",
            "LLAMA_CPP_SHA": "[0-9a-f]{40}",
        ]
        var values: [String: String] = [:]
        var violations: [Violation] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let equals = trimmed.firstIndex(of: "=") else {
                violations.append(
                    Violation(rule: id, path: "Vendor/versions.env", line: offset + 1, what: "KEY=VALUE でない"))
                continue
            }
            values[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
        }
        for (key, pattern) in rules.sorted(by: { $0.key < $1.key }) where !matches(pattern, values[key] ?? "") {
            violations.append(Violation(rule: id, path: "Vendor/versions.env", line: 1, what: "\(key) の形が違う"))
        }
        return violations
    }

    /// ModelCatalog.json（在れば）の各 url が huggingface.co のコミット SHA 固定。
    static func checkModelCatalog(root: URL) -> [Violation] {
        guard let text = read(root, "Resources/ModelCatalog.json"), let data = text.data(using: .utf8) else {
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [Violation(rule: id, path: "Resources/ModelCatalog.json", line: 1, what: "JSON を読めません")]
        }
        var violations: [Violation] = []
        for kind in ["whisper", "vad", "llm"] {
            for entry in object[kind] as? [[String: Any]] ?? [] {
                let url = entry["url"] as? String ?? ""
                if !matches("https://huggingface\\.co/[^/]+/[^/]+/resolve/[0-9a-f]{40}/[^/]+", url) {
                    violations.append(
                        Violation(rule: id, path: "Resources/ModelCatalog.json", line: 1, what: "url が固定されていない: \(url)")
                    )
                }
            }
        }
        return violations
    }

    /// .github/workflows/*.yml の uses: が 40 桁の SHA、runs-on: に latest が無い。
    static func checkWorkflows(root: URL) -> [Violation] {
        let directory = root.appendingPathComponent(".github/workflows")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        var violations: [Violation] = []
        for name in names.sorted() where name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
            let path = ".github/workflows/\(name)"
            guard let text = read(root, path) else { continue }
            for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
                let body = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                if body.hasPrefix("uses:") {
                    let value = body.dropFirst("uses:".count).trimmingCharacters(in: .whitespaces)
                    if !matches("[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}", value) {
                        violations.append(
                            Violation(rule: id, path: path, line: offset + 1, what: "uses: が SHA で固定されていない"))
                    }
                }
                if body.hasPrefix("runs-on:") && body.lowercased().contains("latest") {
                    violations.append(Violation(rule: id, path: path, line: offset + 1, what: "runs-on: に latest"))
                }
            }
        }
        return violations
    }

    /// .xcode-version がちょうど 1 行。
    static func checkXcodeVersion(root: URL) -> [Violation] {
        guard let text = read(root, ".xcode-version") else { return [] }
        return matches("[0-9]+\\.[0-9]+(\\.[0-9]+)?\\n", text)
            ? [] : [Violation(rule: id, path: ".xcode-version", line: 1, what: "1 行でない")]
    }
}
```

#### `Tests/PolicyTests/Rules/OrderingPolicy.swift`

```swift
// PT-16: 「本体が先、記録が後」（DEV-16）。copyOne の本体で commitPartial( が registerCopied( より前にある（T-04）。

enum OrderingPolicy {
    static let id = "PT-16"
    static let path = "VDDevice/IngestService.swift"
    static let function = "copyOne"
    static let first = "commitPartial"
    static let second = "registerCopied"

    /// `func <name>(` の本体（最初の `{` から釣り合う `}` まで）のトークン。見つからなければ nil。
    static func body(of name: String, in tokens: [CodeToken]) -> ArraySlice<CodeToken>? {
        guard tokens.count >= 3 else { return nil }
        for start in 0..<(tokens.count - 2)
        where tokens[start].text == "func" && tokens[start + 1].text == name && tokens[start + 2].text == "(" {
            guard let open = tokens[(start + 3)...].firstIndex(where: { $0.kind == .punctuation && $0.text == "{" })
            else { return nil }
            var depth = 0
            for index in open..<tokens.count where tokens[index].kind == .punctuation {
                if tokens[index].text == "{" { depth += 1 }
                if tokens[index].text == "}" {
                    depth -= 1
                    if depth == 0 { return tokens[open...index] }
                }
            }
            return nil
        }
        return nil
    }

    /// 本体の中で `name(` が最初に現れるトークンの位置。
    static func firstCall(_ name: String, in body: ArraySlice<CodeToken>) -> Int? {
        for index in body.indices where index + 1 < body.endIndex {
            if body[index].kind == .identifier && body[index].text == name && body[index + 1].text == "(" {
                return index
            }
        }
        return nil
    }

    /// `required` が真なら、ファイルや関数が見つからないことも違反にする。
    static func check(files: [SourceFile], required: Bool) -> [Violation] {
        guard let file = files.first(where: { $0.relativePath == path }) else {
            return required ? [Violation(rule: id, path: path, line: 1, what: "ファイルがありません")] : []
        }
        guard let body = body(of: function, in: file.tokens) else {
            return required ? [Violation(rule: id, path: path, line: 1, what: "func \(function)( がありません")] : []
        }
        let commit = firstCall(first, in: body)
        let register = firstCall(second, in: body)
        guard let commit, let register else {
            return [Violation(rule: id, path: path, line: body.first?.line ?? 1, what: "\(first)( か \(second)( がありません")]
        }
        if commit < register { return [] }
        return [Violation(rule: id, path: path, line: body[register].line, what: "\(second)( が \(first)( より前")]
    }
}
```

#### `Tests/PolicyTests/Rules/PolicyVocabulary.swift`

```swift
// PT-06 が探す状態名とエラーコード名（計画書の付録 A から読む。T-05 で docs/SPEC.md に切り替える）（T-04）。
import TestSupport

struct PolicyVocabulary: Sendable {
    let stateNames: [String]
    let errorCodeNames: [String]

    /// `docs/PLAN.md` の付録 A.1（「Part の状態」「Session の状態」の表）と A.3（エラーコードの表）から読む。
    static func load() throws -> PolicyVocabulary {
        let plan = try MarkdownDocument.load("docs/PLAN.md")
        let states = MarkdownDocument.tables(in: try plan.section("A.1"))
            .filter { table in table.header.contains { $0 == "Part の状態" || $0 == "Session の状態" } }
            .flatMap { $0.rows.compactMap { $0.count >= 2 ? unquote($0[1]) : nil } }
        let codes = MarkdownDocument.tables(in: try plan.section("A.3"))
            .filter { $0.header.contains("コード") }
            .flatMap { table in
                table.rows.compactMap { row -> String? in
                    guard row.count >= 2, Int(row[0]) != nil else { return nil }
                    return unquote(row[1])
                }
            }
        return PolicyVocabulary(stateNames: Array(Set(states)).sorted(), errorCodeNames: codes)
    }

    /// `` `NAME` `` から NAME を取り出す（形が違えば nil）。
    static func unquote(_ cell: String) -> String? {
        guard cell.count >= 3, cell.hasPrefix("`"), cell.hasSuffix("`") else { return nil }
        return String(cell.dropFirst().dropLast())
    }
}
```

#### `Tests/PolicyTests/Rules/PolicyAnchors.swift`

```swift
// 検査が空振りしないための「在るべきもの」の一覧（T-04。後続のチケットが足す）。

enum PolicyAnchors {
    /// PT-13 が必ず読むファイル（リポジトリのルートからの相対パス）。無ければ違反。
    /// T-09 が `Resources/ModelCatalog.json` を足す。
    static let requiredFiles: [String] = [
        "Package.swift", "Package.resolved", ".xcode-version", ".github/workflows/ci.yml", "Vendor/versions.env",
    ]

    /// PT-16 が必ず見つけるべき関数（`Sources/` からの相対パスと、`func` から始まる宣言の先頭）。
    /// T-15 が `("VDDevice/IngestService.swift", "func copyOne(")` を足す。
    static let requiredFunctions: [(path: String, declaration: String)] = []
}
```

#### `Tests/PolicyTests/PolicyTests.swift`

```swift
// PT-01〜PT-22 をリポジトリの Sources/ に当てる（PLAN §9.4。T-04）。
import Foundation
import TestSupport
import Testing

@Suite("Policy")
struct PolicyTests {
    struct MissingRule: Error, CustomStringConvertible {
        let id: String
        var description: String { "規則 \(id) がカタログに無い" }
    }

    static func rule(_ id: String) throws -> PolicyRule {
        guard let rule = PolicyCatalog.tokenRules(vocabulary: try PolicyVocabulary.load()).first(where: { $0.id == id })
        else {
            throw MissingRule(id: id)
        }
        return rule
    }

    static func violations(_ id: String) throws -> [Violation] {
        let files = try SourceTree.load()
        switch id {
        case ImportPolicy.id: return ImportPolicy.check(files: files)
        case PinningPolicy.id:
            return PinningPolicy.check(root: PackageRoot.url, requiredFiles: PolicyAnchors.requiredFiles)
        case OrderingPolicy.id:
            let required = PolicyAnchors.requiredFunctions.contains { $0.path == OrderingPolicy.path }
            return OrderingPolicy.check(files: files, required: required)
        default: return PolicyEngine.check(try rule(id), files: files)
        }
    }

    @Test("PT の一覧が PLAN §9.4 の表と一致する")
    func catalogMatchesPlan() throws {
        let plan = try MarkdownDocument.load("docs/PLAN.md")
        let ids = MarkdownDocument.tables(in: try plan.section("9.4"))
            .flatMap { table in table.rows.compactMap { row in row.first.flatMap { $0.hasPrefix("PT-") ? $0 : nil } } }
        #expect(!ids.isEmpty)
        #expect(ids.sorted() == PolicyCatalog.allIDs(vocabulary: try PolicyVocabulary.load()))
    }

    @Test("Sources に Swift のファイルがある（空で緑にしない）")
    func sourcesAreNotEmpty() throws {
        #expect(!(try SourceTree.load()).isEmpty)
    }

    @Test("PT-06 の語の一覧が空でない（空で緑にしない）")
    func vocabularyIsNotEmpty() throws {
        let vocabulary = try PolicyVocabulary.load()
        #expect(!vocabulary.stateNames.isEmpty)
        #expect(!vocabulary.errorCodeNames.isEmpty)
    }

    @Test("PT-01 削除の呼び出しは許可した場所だけ")
    func pt01Holds() throws {
        let violations = try Self.violations("PT-01")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-02 ネットワークは VDModels と LoopbackHTTP だけ")
    func pt02Holds() throws {
        let violations = try Self.violations("PT-02")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-03 子プロセスの起動は VDProcess だけ")
    func pt03Holds() throws {
        let violations = try Self.violations("PT-03")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-04 シェル経由の起動をしない")
    func pt04Holds() throws {
        let violations = try Self.violations("PT-04")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-05 status を書く SQL と行の作成は Transitions.swift だけ")
    func pt05Holds() throws {
        let violations = try Self.violations("PT-05")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-06 状態名・エラーコード名・partkey の手組みを文字列に書かない")
    func pt06Holds() throws {
        let violations = try Self.violations("PT-06")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-07 import が許可リストに収まる")
    func pt07Holds() throws {
        let violations = try Self.violations("PT-07")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-08 ログと print は Log.swift と reaper のログだけ")
    func pt08Holds() throws {
        let violations = try Self.violations("PT-08")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-09 現在時刻は Clock.swift と ReaperClock.swift だけ")
    func pt09Holds() throws {
        let violations = try Self.violations("PT-09")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-10 デバイス上のファイルを開くのは DeviceReader と InboxWriter だけ")
    func pt10Holds() throws {
        let violations = try Self.violations("PT-10")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-11 reaper の複製と bin/ は DeletionEnabler だけ")
    func pt11Holds() throws {
        let violations = try Self.violations("PT-11")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-12 ファイルの書き込みは許可した場所だけ")
    func pt12Holds() throws {
        let violations = try Self.violations("PT-12")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-13 版・URL・action・ランナーが固定されている")
    func pt13Holds() throws {
        let violations = try Self.violations("PT-13")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-14 @unchecked Sendable と nonisolated(unsafe) を使わない")
    func pt14Holds() throws {
        let violations = try Self.violations("PT-14")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-15 reaper は子プロセス・ネットワーク・再帰削除・他の VD モジュールを使わない")
    func pt15Holds() throws {
        let violations = try Self.violations("PT-15")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-16 copyOne は本体を確定してから記録する")
    func pt16Holds() throws {
        let violations = try Self.violations("PT-16")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-17 診断は書き込み・削除をしない")
    func pt17Holds() throws {
        let violations = try Self.violations("PT-17")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-18 本番のコードは環境変数を読まない")
    func pt18Holds() throws {
        let violations = try Self.violations("PT-18")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-19 precondition・assert・fatalError・try!・as! を使わない")
    func pt19Holds() throws {
        let violations = try Self.violations("PT-19")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-20 Swift の Regex を使わない")
    func pt20Holds() throws {
        let violations = try Self.violations("PT-20")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-21 .recovery は復旧の場所だけ")
    func pt21Holds() throws {
        let violations = try Self.violations("PT-21")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("PT-22 VolumeHandle を作るのは TargetIdentity だけ")
    func pt22Holds() throws {
        let violations = try Self.violations("PT-22")
        #expect(violations.isEmpty, "\(violations)")
    }
}
```

#### `Tests/PolicyTests/PolicySelfTests.swift`

```swift
// PT の自己テスト: 違反を仕込むと落ち、コメント・文字列（文字列の検査はコード）では落ちない（PLAN §9.4・CR-17。T-04）。
import Foundation
import TestSupport
import Testing

@Suite("PolicySelf")
struct PolicySelfTests {
    /// 自己テストの語の一覧（docs に依存させない）。
    static let vocabulary = PolicyVocabulary(
        stateNames: ["FAILED", "RAW_SAVED"], errorCodeNames: ["SOURCE_IDENTITY_MISMATCH", "WHISPER_FAILED"])

    /// PT ごとの（違反を仕込んだファイル, 紛らわしいが違反でないファイル）。
    static let fixtures: [String: (violating: [SourceFile], decoy: [SourceFile])] = [
        "PT-01": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Bad.swift", text: "func f(_ p: String) { unlink(p) }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Bad.swift",
                    text:
                        "// unlink(p) で消す\nlet note = \"FileManager.default.removeItem(at:)\"\nfunc g(_ s: inout Set<Int>) { s.remove(1); SafeUnlink.remove(x) }\n"
                )
            ]
        ),
        "PT-02": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let s = URLSession.shared\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift", text: "// URLSession を使わない\nlet t = \"URLSession.shared\"\n")
            ]
        ),
        "PT-03": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let p = Process()\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text:
                        "// Process() を使わない\nlet name = \"Process()\"\nstruct ProcessedLog {}\nlet x = ProcessInfo.processInfo\n"
                )
            ]
        ),
        "PT-04": (
            violating: [
                SourceFile(relativePath: "VDProcess/Bad.swift", text: "let a = [\"/bin/sh\", \"-c\", \"ls\"]\n")
            ],
            decoy: [
                SourceFile(relativePath: "VDProcess/Bad.swift", text: "// /bin/sh を使わない\nlet flag = \"-c\"\n")
            ]
        ),
        "PT-05": (
            violating: [
                SourceFile(
                    relativePath: "VDStore/Queries.swift",
                    text: "let sql = \"UPDATE recordings SET status = ? WHERE partkey = ?\"\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDStore/Queries.swift",
                    text:
                        "// UPDATE recordings SET status = ?\nlet sql = \"SELECT partkey FROM recordings WHERE status = ?\"\n"
                )
            ]
        ),
        "PT-06": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Bad.swift", text: "let s = \"RAW_SAVED\"\n"),
                SourceFile(relativePath: "VDPipeline/Key.swift", text: "let k = \"\\(deviceID)/\\(relpath)\"\n"),
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Bad.swift",
                    text: "// RAW_SAVED にする\nlet t = PartStatus.rawSaved\nlet u = \"WHISPER_FAILED_X\"\n")
            ]
        ),
        "PT-07": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "import VDStore\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text: "// import VDStore\nimport Foundation\nimport Synchronization\nlet s = \"import VDStore\"\n")
            ]
        ),
        "PT-08": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "func f() { print(\"x\") }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text:
                        "// print(\"x\")\nlet s = \"print(1)\"\nstruct Printer { func print() {} }\nfunc g(_ p: Printer) { p.print() }\n"
                )
            ]
        ),
        "PT-09": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let now = Date()\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text: "// Date() を使わない\nlet s = \"Date()\"\nlet d = Date(timeIntervalSince1970: 0)\n")
            ]
        ),
        "PT-10": (
            violating: [
                SourceFile(relativePath: "VDDevice/Scanner.swift", text: "let fd = open(path, O_RDONLY)\n"),
                SourceFile(relativePath: "VDDevice/DeviceReader.swift", text: "let flags = O_WRONLY\n"),
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDDevice/Scanner.swift",
                    text: "// open(path) はしない\nlet s = \"open(path)\"\nfunc g(_ h: Handle) { h.open() }\n")
            ]
        ),
        "PT-11": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Worker.swift", text: "let u = layout.binDirectory\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Worker.swift",
                    text: "// binDirectory に書かない\nlet s = \"binDirectory\"\nlet v = Contract.reaperConfSchema\n")
            ]
        ),
        "PT-12": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Bad.swift", text: "func f() throws { try data.write(to: url) }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Bad.swift",
                    text:
                        "// data.write(to: url)\nlet s = \"write(to:)\"\nfunc g() throws { try file.write(from: buffer) }\n"
                )
            ]
        ),
        "PT-14": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "final class A: @unchecked Sendable {}\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift", text: "// @unchecked Sendable は使わない\nlet s = \"@unchecked\"\n")
            ]
        ),
        "PT-15": (
            violating: [
                SourceFile(relativePath: "voicedock-reaper/Bad.swift", text: "import VDCore\n"),
                SourceFile(relativePath: "voicedock-reaper/Tool.swift", text: "let s = \"diskutil\"\n"),
            ],
            decoy: [
                SourceFile(
                    relativePath: "voicedock-reaper/Bad.swift",
                    text: "// diskutil を呼ばない\nstruct ProcessedLog {}\nlet info = ProcessInfo.processInfo\n")
            ]
        ),
        "PT-16": (
            violating: [
                SourceFile(
                    relativePath: "VDDevice/IngestService.swift",
                    text: "func copyOne() {\n    registerCopied()\n    commitPartial()\n}\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDDevice/IngestService.swift",
                    text: "// registerCopied( を先に呼ばない\nfunc copyOne() {\n    commitPartial()\n    registerCopied()\n}\n"
                )
            ]
        ),
        "PT-17": (
            violating: [
                SourceFile(
                    relativePath: "VDPipeline/Diagnostics/Checks.swift",
                    text: "func f() throws { try AtomicFile.write(d, to: u) }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Diagnostics/Checks.swift",
                    text: "// AtomicFile.write をしない\nlet s = \"AtomicFile\"\nlet r = ReadOnlyStore.open(url: u)\n")
            ]
        ),
        "PT-18": (
            violating: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift", text: "let e = ProcessInfo.processInfo.environment[\"X\"]\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text:
                        "// ProcessInfo.processInfo.environment を読まない\nlet s = \"getenv(X)\"\nlet c = ProcessInfo.processInfo.activeProcessorCount\n"
                )
            ]
        ),
        "PT-19": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let x = try! f()\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text: "// try! は使わない\nlet s = \"fatalError()\"\nlet y = try? f()\nlet z = try !flag()\n")
            ]
        ),
        "PT-20": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let r = try Regex(\"a+\")\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text: "// Regex は使わない\nlet s = \"Regex<Substring>\"\nlet t = NSRegularExpression.self\n")
            ]
        ),
        "PT-21": (
            violating: [
                SourceFile(
                    relativePath: "VDPipeline/Worker.swift",
                    text: "func f() throws { try store.record(kind: .recovery) }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Worker.swift",
                    text: "// .recovery を使わない\nlet s = \".recovery\"\nfunc g() { log(.recoveryCompleted) }\n")
            ]
        ),
        "PT-22": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Deletion.swift", text: "let h = VolumeHandle(fd: 3)\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Deletion.swift",
                    text: "// VolumeHandle( を作らない\nlet s = \"VolumeHandle(fd:)\"\nlet t: VolumeHandle? = nil\n")
            ]
        ),
    ]

    struct MissingFixture: Error {}

    static func check(_ id: String, _ files: [SourceFile]) -> [Violation] {
        switch id {
        case ImportPolicy.id: return ImportPolicy.check(files: files)
        case OrderingPolicy.id: return OrderingPolicy.check(files: files, required: true)
        default:
            let rule = PolicyCatalog.tokenRules(vocabulary: vocabulary).first { $0.id == id }
            return rule.map { PolicyEngine.check($0, files: files) } ?? [
                Violation(rule: id, path: "-", line: 0, what: "規則が無い")
            ]
        }
    }

    /// 違反のファイルそれぞれで 1 件以上見つかる（どのファイルも空振りしない）。
    static func expectDetects(_ id: String) throws {
        let fixture = try #require(fixtures[id])
        for file in fixture.violating {
            let found = check(id, [file])
            #expect(
                found.contains { $0.rule == id && $0.path == file.relativePath }, "\(id) が \(file.relativePath) で空振りした")
        }
    }

    static func expectIgnoresDecoys(_ id: String) throws {
        let fixture = try #require(fixtures[id])
        let found = check(id, fixture.decoy)
        #expect(found.isEmpty, "\(id) が誤検知した: \(found)")
    }

    @Test("PT-01 自己テスト: 違反を仕込むと検出する")
    func pt01DetectsViolation() throws {
        try Self.expectDetects("PT-01")
    }

    @Test("PT-01 自己テスト: コメント・文字列の中の語では検出しない")
    func pt01IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-01")
    }

    @Test("PT-02 自己テスト: 違反を仕込むと検出する")
    func pt02DetectsViolation() throws {
        try Self.expectDetects("PT-02")
    }

    @Test("PT-02 自己テスト: コメント・文字列の中の語では検出しない")
    func pt02IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-02")
    }

    @Test("PT-03 自己テスト: 違反を仕込むと検出する")
    func pt03DetectsViolation() throws {
        try Self.expectDetects("PT-03")
    }

    @Test("PT-03 自己テスト: コメント・文字列の中の語では検出しない")
    func pt03IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-03")
    }

    @Test("PT-04 自己テスト: 違反を仕込むと検出する")
    func pt04DetectsViolation() throws {
        try Self.expectDetects("PT-04")
    }

    @Test("PT-04 自己テスト: コメント・文字列の中の語では検出しない")
    func pt04IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-04")
    }

    @Test("PT-05 自己テスト: 違反を仕込むと検出する")
    func pt05DetectsViolation() throws {
        try Self.expectDetects("PT-05")
    }

    @Test("PT-05 自己テスト: コメント・文字列の中の語では検出しない")
    func pt05IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-05")
    }

    @Test("PT-06 自己テスト: 違反を仕込むと検出する")
    func pt06DetectsViolation() throws {
        try Self.expectDetects("PT-06")
    }

    @Test("PT-06 自己テスト: コメント・文字列の中の語では検出しない")
    func pt06IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-06")
    }

    @Test("PT-07 自己テスト: 違反を仕込むと検出する")
    func pt07DetectsViolation() throws {
        try Self.expectDetects("PT-07")
    }

    @Test("PT-07 自己テスト: コメント・文字列の中の語では検出しない")
    func pt07IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-07")
    }

    @Test("PT-08 自己テスト: 違反を仕込むと検出する")
    func pt08DetectsViolation() throws {
        try Self.expectDetects("PT-08")
    }

    @Test("PT-08 自己テスト: コメント・文字列の中の語では検出しない")
    func pt08IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-08")
    }

    @Test("PT-09 自己テスト: 違反を仕込むと検出する")
    func pt09DetectsViolation() throws {
        try Self.expectDetects("PT-09")
    }

    @Test("PT-09 自己テスト: コメント・文字列の中の語では検出しない")
    func pt09IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-09")
    }

    @Test("PT-10 自己テスト: 違反を仕込むと検出する")
    func pt10DetectsViolation() throws {
        try Self.expectDetects("PT-10")
    }

    @Test("PT-10 自己テスト: コメント・文字列の中の語では検出しない")
    func pt10IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-10")
    }

    @Test("PT-11 自己テスト: 違反を仕込むと検出する")
    func pt11DetectsViolation() throws {
        try Self.expectDetects("PT-11")
    }

    @Test("PT-11 自己テスト: コメント・文字列の中の語では検出しない")
    func pt11IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-11")
    }

    @Test("PT-12 自己テスト: 違反を仕込むと検出する")
    func pt12DetectsViolation() throws {
        try Self.expectDetects("PT-12")
    }

    @Test("PT-12 自己テスト: コメント・文字列の中の語では検出しない")
    func pt12IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-12")
    }

    @Test("PT-14 自己テスト: 違反を仕込むと検出する")
    func pt14DetectsViolation() throws {
        try Self.expectDetects("PT-14")
    }

    @Test("PT-14 自己テスト: コメント・文字列の中の語では検出しない")
    func pt14IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-14")
    }

    @Test("PT-15 自己テスト: 違反を仕込むと検出する")
    func pt15DetectsViolation() throws {
        try Self.expectDetects("PT-15")
    }

    @Test("PT-15 自己テスト: コメント・文字列の中の語では検出しない")
    func pt15IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-15")
    }

    @Test("PT-16 自己テスト: 違反を仕込むと検出する")
    func pt16DetectsViolation() throws {
        try Self.expectDetects("PT-16")
    }

    @Test("PT-16 自己テスト: コメント・文字列の中の語では検出しない")
    func pt16IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-16")
    }

    @Test("PT-17 自己テスト: 違反を仕込むと検出する")
    func pt17DetectsViolation() throws {
        try Self.expectDetects("PT-17")
    }

    @Test("PT-17 自己テスト: コメント・文字列の中の語では検出しない")
    func pt17IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-17")
    }

    @Test("PT-18 自己テスト: 違反を仕込むと検出する")
    func pt18DetectsViolation() throws {
        try Self.expectDetects("PT-18")
    }

    @Test("PT-18 自己テスト: コメント・文字列の中の語では検出しない")
    func pt18IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-18")
    }

    @Test("PT-19 自己テスト: 違反を仕込むと検出する")
    func pt19DetectsViolation() throws {
        try Self.expectDetects("PT-19")
    }

    @Test("PT-19 自己テスト: コメント・文字列の中の語では検出しない")
    func pt19IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-19")
    }

    @Test("PT-20 自己テスト: 違反を仕込むと検出する")
    func pt20DetectsViolation() throws {
        try Self.expectDetects("PT-20")
    }

    @Test("PT-20 自己テスト: コメント・文字列の中の語では検出しない")
    func pt20IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-20")
    }

    @Test("PT-21 自己テスト: 違反を仕込むと検出する")
    func pt21DetectsViolation() throws {
        try Self.expectDetects("PT-21")
    }

    @Test("PT-21 自己テスト: コメント・文字列の中の語では検出しない")
    func pt21IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-21")
    }

    @Test("PT-22 自己テスト: 違反を仕込むと検出する")
    func pt22DetectsViolation() throws {
        try Self.expectDetects("PT-22")
    }

    @Test("PT-22 自己テスト: コメント・文字列の中の語では検出しない")
    func pt22IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-22")
    }

    /// PT-13 の自己テスト用のリポジトリを一時ディレクトリに作る。
    static func makeRoot(_ files: [String: String]) throws -> TempDirectory {
        let directory = try TempDirectory()
        for (path, text) in files {
            let url = directory.url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return directory
    }

    static let pinnedFiles: [String: String] = [
        "Package.swift":
            "// from: \"1.0.0\" は使わない\nlet p = [.package(url: \"https://github.com/a/b.git\", exact: \"1.0.0\")]\n",
        "Package.resolved":
            "{\"pins\": [{\"identity\": \"b\", \"state\": {\"revision\": \"0123456789abcdef0123456789abcdef01234567\", \"version\": \"1.0.0\"}}], \"version\": 3}\n",
        ".xcode-version": "27.0\n",
        ".github/workflows/ci.yml":
            "jobs:\n  check:\n    runs-on: xcode-27  # latest ではない\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n",
        "Vendor/versions.env":
            "WHISPER_CPP_REPO=https://github.com/ggml-org/whisper.cpp.git\nWHISPER_CPP_REF=v1.9.4\nWHISPER_CPP_SHA=927cfce34f31707e17f2bff35c349632fb9e2c3a\nLLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp.git\nLLAMA_CPP_REF=b11033\nLLAMA_CPP_SHA=8ed1a55efcd7424d2c592f6cbc9f97756db1d74d\n",
        "Resources/ModelCatalog.json":
            "{\"whisper\": [{\"url\": \"https://huggingface.co/a/b/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/m.bin\"}]}\n",
    ]

    @Test("PT-13 自己テスト: 固定されていない版・URL・action・ランナーを検出する")
    func pt13DetectsViolation() throws {
        var files = Self.pinnedFiles
        files["Package.swift"] = "let p = [.package(url: \"https://github.com/a/b.git\", from: \"1.0.0\")]\n"
        files["Package.resolved"] =
            "{\"pins\": [{\"identity\": \"b\", \"state\": {\"branch\": \"main\", \"revision\": \"0123456789abcdef0123456789abcdef01234567\"}}], \"version\": 3}\n"
        files["Vendor/versions.env"] = files["Vendor/versions.env", default: ""].replacingOccurrences(
            of: "REF=b11033", with: "REF=master")
        files["Resources/ModelCatalog.json"] =
            "{\"whisper\": [{\"url\": \"https://huggingface.co/a/b/resolve/main/m.bin\"}]}\n"
        files[".github/workflows/ci.yml"] =
            "jobs:\n  check:\n    runs-on: macos-latest\n    steps:\n      - uses: actions/checkout@v7.0.1\n"
        files[".xcode-version"] = "27.0\n\n"
        let root = try Self.makeRoot(files)
        defer { root.remove() }
        let found = PinningPolicy.check(root: root.url, requiredFiles: PolicyAnchors.requiredFiles)
        let paths = Set(found.map(\.path))
        #expect(
            paths == [
                "Package.swift", "Package.resolved", "Vendor/versions.env", "Resources/ModelCatalog.json",
                ".github/workflows/ci.yml", ".xcode-version",
            ])
        #expect(found.filter { $0.path == ".github/workflows/ci.yml" }.count == 2)
    }

    @Test("PT-13 自己テスト: コメントの中の語と固定された値では検出しない")
    func pt13IgnoresDecoy() throws {
        let root = try Self.makeRoot(Self.pinnedFiles)
        defer { root.remove() }
        let found = PinningPolicy.check(root: root.url, requiredFiles: PolicyAnchors.requiredFiles)
        #expect(found.isEmpty, "\(found)")
    }

    @Test("PT-13 自己テスト: 在るべきファイルが無ければ検出する")
    func pt13DetectsMissingRequiredFile() throws {
        var files = Self.pinnedFiles
        files["Vendor/versions.env"] = nil
        let root = try Self.makeRoot(files)
        defer { root.remove() }
        let found = PinningPolicy.check(root: root.url, requiredFiles: PolicyAnchors.requiredFiles)
        #expect(found.contains { $0.path == "Vendor/versions.env" && $0.what == "ファイルがありません" })
    }

    @Test("PT-16 自己テスト: 必須にした関数が無ければ検出する")
    func pt16DetectsMissingFunction() {
        let file = SourceFile(relativePath: "VDDevice/IngestService.swift", text: "func other() {}\n")
        #expect(!OrderingPolicy.check(files: [file], required: true).isEmpty)
        #expect(OrderingPolicy.check(files: [file], required: false).isEmpty)
    }

    @Test("PT-06 自己テスト: 語の一覧が空なら必ず違反にする（空で緑にしない）")
    func pt06EmptyVocabularyAlwaysFails() {
        let rule = PolicyCatalog.tokenRules(vocabulary: PolicyVocabulary(stateNames: [], errorCodeNames: []))
            .first { $0.id == "PT-06" }
        let file = SourceFile(relativePath: "VDCore/A.swift", text: "let s = \"anything\"\n")
        #expect(rule.map { !PolicyEngine.check($0, files: [file]).isEmpty } == true)
    }
}
```

#### `Tests/PolicyTests/SourceScannerTests.swift`

```swift
// SourceScanner と CodeTokenizer の固定テスト（T-04）。
import Testing

@Suite("SourceScanner")
struct SourceScannerTests {
    static func code(_ text: String) -> String { SourceScanner.scan(text).codeText }

    @Test("行コメントの中身はコードに残らない")
    func lineCommentIsBlanked() {
        let code = Self.code("let a = 1 // unlink(x)\nlet b = 2\n")
        #expect(!code.contains("unlink"))
        #expect(code.contains("let b = 2"))
    }

    @Test("入れ子のブロックコメントの中身はコードに残らない")
    func nestedBlockCommentIsBlanked() {
        let code = Self.code("/* a /* b */ unlink(x) */ let c = 2\n")
        #expect(!code.contains("unlink"))
        #expect(code.contains("let c = 2"))
    }

    @Test("文字列の中身はコードに残らず、リテラルとして集まる")
    func stringLiteralIsCollected() {
        let scanned = SourceScanner.scan("let s = \"unlink(x)\"\n")
        #expect(!scanned.codeText.contains("unlink"))
        #expect(scanned.literals.map(\.raw) == ["unlink(x)"])
        #expect(scanned.literals.first?.line == 1)
    }

    @Test("エスケープした引用符で文字列が終わらない")
    func escapedQuoteDoesNotCloseString() {
        let scanned = SourceScanner.scan("let s = \"a\\\"b\"\nlet t = 1\n")
        #expect(scanned.literals.map(\.raw) == ["a\\\"b"])
        #expect(scanned.codeText.contains("let t = 1"))
    }

    @Test("文字列補間の中身はコードとして残り、リテラルの raw にもそのまま入る")
    func interpolationStaysInCode() {
        let scanned = SourceScanner.scan("let s = \"x\\(unlink(p))y\"\n")
        #expect(scanned.codeText.contains("unlink(p)"))
        #expect(scanned.literals.map(\.raw) == ["x\\(unlink(p))y"])
    }

    @Test("補間の中の文字列も別のリテラルとして集まる")
    func stringInsideInterpolationIsCollected() {
        let scanned = SourceScanner.scan("let s = \"a\\(\"b\")c\"\n")
        #expect(scanned.literals.map(\.raw) == ["a\\(\"b\")c", "b"])
    }

    @Test("複数行の文字列は 1 つのリテラルで、中の引用符で終わらない")
    func multilineString() {
        let scanned = SourceScanner.scan("let s = \"\"\"\nline1 \"quote\"\n\"\"\"\nlet t = 1\n")
        #expect(scanned.literals.count == 1)
        #expect(scanned.literals.first?.isMultiline == true)
        #expect(scanned.literals.first?.raw == "\nline1 \"quote\"\n")
        #expect(scanned.codeText.contains("let t = 1"))
    }

    @Test("raw 文字列の中の引用符とバックスラッシュは特別扱いしない")
    func rawString() {
        let scanned = SourceScanner.scan("let s = #\"a\"b\\(x)\"#\n")
        #expect(scanned.literals.map(\.raw) == ["a\"b\\(x)"])
        #expect(scanned.literals.first?.hashCount == 1)
        #expect(!scanned.codeText.contains("(x)"))
    }

    @Test("raw 文字列の補間 \\#( はコードとして残る")
    func rawStringInterpolation() {
        let scanned = SourceScanner.scan("let s = #\"a\\#(yy)b\"#\n")
        #expect(scanned.codeText.contains("yy"))
    }

    @Test("行番号が保たれる")
    func lineNumbersArePreserved() {
        let text = "let s = \"\"\"\na\nb\n\"\"\"\nlet z = 1\n"
        let tokens = CodeTokenizer.tokens(SourceScanner.scan(text).code)
        #expect(tokens.first { $0.text == "z" }?.line == 5)
    }

    @Test("#if は文字列として扱わない")
    func compilerDirectiveIsCode() {
        #expect(Self.code("#if DEBUG\nlet a = 1\n#endif\n").contains("#if DEBUG"))
    }

    @Test("閉じていない 1 行の文字列は行末で終わる")
    func unterminatedStringEndsAtLineEnd() {
        let scanned = SourceScanner.scan("let s = \"abc\nlet t = 1\n")
        #expect(scanned.literals.map(\.raw) == ["abc"])
        #expect(scanned.codeText.contains("let t = 1"))
    }

    @Test("トークンは直前の空白の有無を持つ")
    func tokensRecordSpaceBefore() {
        let tokens = CodeTokenizer.tokens(SourceScanner.scan("try! f()\ntry !g()\n").code)
        let bangs = tokens.filter { $0.text == "!" }
        #expect(bangs.map(\.spaceBefore) == [false, true])
    }

    @Test("バッククォートの識別子は中身の名前になる")
    func backtickIdentifier() {
        let tokens = CodeTokenizer.tokens(SourceScanner.scan("let `default` = 1\n").code)
        #expect(tokens.map(\.text) == ["let", "default", "=", "1"])
    }

    @Test("空のソース")
    func emptySource() {
        let scanned = SourceScanner.scan("")
        #expect(scanned.code.isEmpty)
        #expect(scanned.literals.isEmpty)
        #expect(CodeTokenizer.tokens(scanned.code).isEmpty)
    }
}
```

## テスト

| ファイル | 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|---|
| `PolicyTests.swift` | `catalogMatchesPlan()` | PT の一覧が PLAN §9.4 の表と一致する | `docs/PLAN.md` の §9.4 | ID の集合が一致、空でない |
| 同上 | `sourcesAreNotEmpty()` | Sources に Swift のファイルがある（空で緑にしない） | リポジトリ | 1 件以上 |
| 同上 | `vocabularyIsNotEmpty()` | PT-06 の語の一覧が空でない（空で緑にしない） | `docs/PLAN.md` の付録 A | 状態名とエラーコード名がどちらも空でない |
| 同上 | `pt01Holds()` 〜 `pt22Holds()`（22 本） | `PT-nn <規則の題>` | リポジトリの `Sources/` | 違反 0 件（あれば違反の一覧をメッセージに出す） |
| `PolicySelfTests.swift` | `ptNNDetectsViolation()`（PT-13 を除く 21 本） | `PT-nn 自己テスト: 違反を仕込むと検出する` | `fixtures[id].violating` の各ファイル | ファイルごとに 1 件以上の違反（どのファイルも空振りしない） |
| 同上 | `ptNNIgnoresDecoy()`（PT-13 を除く 21 本） | `PT-nn 自己テスト: コメント・文字列の中の語では検出しない` | `fixtures[id].decoy` | 違反 0 件 |
| 同上 | `pt13DetectsViolation()` | PT-13 自己テスト: 固定されていない版・URL・action・ランナーを検出する | 一時ディレクトリに固定されていない 6 ファイル | 6 つのファイルすべてで違反、ci.yml は 2 件（uses と runs-on） |
| 同上 | `pt13IgnoresDecoy()` | PT-13 自己テスト: コメントの中の語と固定された値では検出しない | 固定された 6 ファイル（コメントに `from:` と `latest`） | 違反 0 件 |
| 同上 | `pt13DetectsMissingRequiredFile()` | PT-13 自己テスト: 在るべきファイルが無ければ検出する | versions.env だけ無い | 「ファイルがありません」 |
| 同上 | `pt16DetectsMissingFunction()` | PT-16 自己テスト: 必須にした関数が無ければ検出する | copyOne の無いファイル | 必須なら違反、必須でなければ違反なし |
| 同上 | `pt06EmptyVocabularyAlwaysFails()` | PT-06 自己テスト: 語の一覧が空なら必ず違反にする（空で緑にしない） | 語が空 | 違反あり |
| `SourceScannerTests.swift` | 15 本（下の表） | — | 文字列のソース | 下の表 |

`SourceScannerTests` の 15 本: `lineCommentIsBlanked`・`nestedBlockCommentIsBlanked`・`stringLiteralIsCollected`・`escapedQuoteDoesNotCloseString`・`interpolationStaysInCode`・
`stringInsideInterpolationIsCollected`・`multilineString`・`rawString`・`rawStringInterpolation`・`lineNumbersArePreserved`・`compilerDirectiveIsCode`・`unterminatedStringEndsAtLineEnd`・
`tokensRecordSpaceBefore`・`backtickIdentifier`・`emptySource`（入力と期待は上の全文のとおり）。

## 破壊による証明

| 壊し方 | 落ちるべきもの（確かめ済みのものに ✓） |
|---|---|
| `SourceScanner.swift` の行コメントの読み飛ばし（`while i < n && s[i] != newline { i += 1 }`）を、中身を `emit(i)` する形に変える | ✓ PT-02・03・07・08・10・11・12・14・19・21・22 などの `…IgnoresDecoy`、`lineCommentIsBlanked` |
| `TokenPattern.matchesAt` の freeCall の判定（直前が `.` の扱い）を消す | `pt01IgnoresDecoy`（`s.remove(1)`・`SafeUnlink.remove(x)`）、`pt08IgnoresDecoy`（`p.print()`） |
| `PolicyCatalog` の PT-01 の `.call("unlink")` を消す | `pt01DetectsViolation` |
| `LiteralMatcher.words` の空の一覧の扱いを `{ _ in false }` にする | `pt06EmptyVocabularyAlwaysFails` |
| `PinningPolicy.checkWorkflows` の `runs-on` の検査を消す | `pt13DetectsViolation`（ci.yml が 1 件になる） |
| `OrderingPolicy.check` の `commit < register` を `>` にする | `pt16DetectsViolation`・`pt16IgnoresDecoy` |
| `ImportPolicy.allowed` の VDCore に `VDStore` を足す | `pt07DetectsViolation` |
| `ImportPolicy.allowedEverywhere` を空にする | `pt07IgnoresDecoy`（decoy の `import Synchronization`） |
| `Sources/VDCore/PyRound.swift`（17 行）の末尾に `let x = try! f()` を足す（本番の木に違反を仕込む。T-01 の `ModuleMarker.swift` は T-45 で消えた） | `pt19Holds`（違反の一覧に `VDCore/PyRound.swift:18 try!` が出る） |

## 受け入れ条件

- [ ] 上の全ファイルが全文のとおりに在り、`make lint` と `make test` が通る
- [ ] `swift test --filter PolicyTests` の出力の件数を PR に貼る（パラメータ化を含めて 100 件前後。T-01〜T-03 のテストを含む）
- [ ] 破壊による証明の表の 9 項目を行い、落ちたテスト名を PR に貼った
- [ ] PLAN §9.4 の表の各行（語と許可場所）と `PolicyCatalog.swift` を 1 行ずつ突き合わせたことを PR に書いた（食い違いがあれば PLAN を正として直す）

## SPEC の変更

なし（PT の表は PLAN §9.4 にある。`docs/SPEC.md` は T-05）。

## マージ後にやること

- T-05 で `PolicyVocabulary.load()` の読み先を `docs/SPEC.md` の S1・S3 に切り替える
- T-09 で `PolicyAnchors.requiredFiles` に `"Resources/ModelCatalog.json"` を足す
- T-15 で `PolicyAnchors.requiredFunctions` に `(path: "VDDevice/IngestService.swift", declaration: "func copyOne(")` を足す
- 各モジュールの最初の実ファイルを足すチケットは、そのファイルが PT を満たすことを `make test` で確かめる（PT は `Sources/` 全体に常に掛かる）

## API 地図への変更提案

- PT-08 の許可場所は `VDCore/Log.swift` だけだが、00-api-map §2.3 は `OSLogSink`（`os.Logger` を作る）を `LogFile.swift` に置いている。**`OSLogSink` を `Log.swift` に移す**か、PLAN §9.4 の PT-08 に `VDCore/LogFile.swift` を足す（どちらかに揃える。T-04 は PLAN のとおり `Log.swift` だけを許している） → 00-api-map に反映済み（2026-09-18。`OSLogSink` は `Log.swift`）
- PT-17 の「`Store.open(`（`openReadOnly` 以外）」は API 地図の形（`Store(url:clock:zone:)` と `ReadOnlyStore.open(url:)`）に合わせて「`Store(` と `Store.init`」を禁じた。PLAN §9.4 の PT-17 の文面を API 地図に合わせて直す → PLAN §9.4 に反映済み（2026-09-18。F-49）
- （整合修正で追記）PLAN §3.4 が `Synchronization` をすべてのモジュールに許した（F-48）ので、`ImportPolicy.allowedEverywhere` に入れた
- （整合修正で追記）`MarkdownDocument` の作り手は本チケット（PT-06 の語を読むのに要り、T-05 は本チケットに依存する）。00-api-map §15 は `Markdown/MarkdownDocument` の作り手を T-05 と書いているので、T-04 に直すことを提案する

