# T-05 docs/SPEC.md と SPEC 同期

| 項目 | 値 |
|---|---|
| ID | T-05 |
| 題 | docs/SPEC.md（付録 A・B と §6.4・§8.11 の表）と SPEC 同期テストの基盤 |
| Phase | 1 |
| 前提 | T-04（`MarkdownDocument`・`SourceScanner`・`PolicyVocabulary`） |
| 見積もり | 約 785 行（生成スクリプト約 110、SpecDocument 約 235、テスト約 340、Makefile 3 行）。`docs/SPEC.md`（約 340 行）は生成物で数えない |

## 目的

規範の表（状態・遷移・復旧写像・エラーコード・ログイベント・CV・DR・ND・RV・E2E）を `docs/SPEC.md` に集め、テストが読んで実装と突き合わせられるようにする。
SPEC.md は PLAN の表の**機械的な写し**にし（手で直さない）、写し忘れをテストで落とす。実装の enum との突き合わせは、その enum を作るチケットが足す（下の §5 の形で）。

## 参照

- PLAN §10.3（SPEC 同期の読み方）、§10.1（テストの表示名は ID で始める）、付録 A・B、§6.4、§8.11、CR-18（ID の重複と欠番の再利用）
- voicedock@d3d595e `tests/spec_sync.py`（SPEC が無ければ fail、フェンスの中を見出しとしない、打ち消しの行を除く、太字の ID を許す）、`tests/unit/test_runbook.py`（E2E の判定表）

## 作るもの

| パス | 役割 |
|---|---|
| `tools/spec/make-spec.py` | PLAN から SPEC.md を作る（下記の全文。実行権 0755） |
| `docs/SPEC.md` | `python3 tools/spec/make-spec.py` の出力（生成物。コミットする。手で直さない） |
| `Makefile` | `spec` のターゲットを足す（下記） |
| `Tests/TestSupport/Spec/SpecDocument.swift` | 規範の表の型付きの読み取り（TestSupport。後続の SPEC 同期のテストも使う） |
| `Tests/PolicyTests/Rules/PolicyVocabulary.swift` | T-04 のファイルを置き換える（読み先を SPEC.md に） |
| `Tests/PolicyTests/SpecSync/TestNameIndex.swift` | テストの表示名から ID を集める |
| `Tests/PolicyTests/SpecSync/SpecCoverage.swift` | 集合の一致を確かめる種類（後続が足す） |
| `Tests/PolicyTests/SpecSync/SpecStructureTests.swift` | SPEC.md の形 |
| `Tests/PolicyTests/SpecSync/SpecMatchesPlanTests.swift` | SPEC.md = PLAN の写し |
| `Tests/PolicyTests/SpecSync/SpecCoverageTests.swift` | テストの ID と SPEC の ID |
| `Tests/PolicyTests/SpecSync/SpecParserTests.swift` | 読み方の固定テスト |

## 仕様

### 1. docs/SPEC.md の構成

`tools/spec/make-spec.py` が次の順に PLAN の節を写す。見出しの `S1.`〜`S9.` がテストの鍵:

| SPEC の見出し | PLAN の節 | 写す範囲 |
|---|---|---|
| `## S1. 状態と復旧写像（PLAN 付録 A.1）` | 付録 A.1 | 節の本文すべて（前後の空行と `---` の行は除く） |
| `## S2. 遷移表（PLAN 付録 A.2）` | 付録 A.2 | 同上 |
| `## S3. エラーコード（PLAN 付録 A.3）` | 付録 A.3 | 同上 |
| `## S4. ログイベント（PLAN 付録 A.4）` | 付録 A.4 | 同上 |
| `## S5. 設定の検証 CV（PLAN §6.4）` | §6.4 | 同上 |
| `## S6. 診断 DR（PLAN §8.11）` | §8.11 | **DR の表だけ**（`\| ID \| 順 \|` で始まる行から表の終わりまで） |
| `## S7. 削除禁止テスト ND（PLAN 付録 B.1）` | 付録 B.1 | 節の本文すべて |
| `## S8. reaper の検証 RV（PLAN 付録 B.2）` | 付録 B.2 | 同上 |
| `## S9. 実機試験 E2E（PLAN 付録 B.3）` | 付録 B.3 | 同上 |

- 節の切り出しの規則は PLAN §10.3 と同じ: 見出しの本文が鍵で始まる最初の見出しの次の行から、次の `^#{1,6} (?:[0-9A-Z]|付録)` の行の手前まで。**コードフェンスの中の行は見出しとして扱わない**
- PT の表（PLAN §9.4）は写さない（T-04 の `catalogMatchesPlan` が PLAN から直接読む）

### 2. 読み方（SpecDocument。PLAN §10.3 の規則の実装）

| 読むもの | 節 | 規則 |
|---|---|---|
| 状態の名前（宣言順） | S1 | 見出しの列に「Part の状態」/「Session の状態」を持つ表の、先頭の列が数の行の 2 列目の `` `NAME` `` |
| 遷移表の辺 | S2 | 直前の空でない行が `Part:` / `Session:` の text フェンスの中の `([A-Z_]+)→([A-Z_]+)`（`★` と括弧の注記は正規表現が拾わない） |
| 復旧写像の辺（処理の順） | S1 | text フェンスの中の、行頭が `Part:` / `Session:` の行の `A→B` |
| エラーコード（宣言順）と再試行 | S3 | 見出しに「コード」を持つ表の、先頭の列が数の行の 2 列目（`` `CODE` ``）と 3 列目。`\| — \|` で始まる廃止の行は拾わない |
| ログイベント（登録順） | S4 | 最初の text フェンスを空白と改行で分けたもの |
| CV・DR・ND・RV・E2E の生きた ID | S5〜S9 | フェンスの外の行で式 R1（表の下） |
| 廃止した ID | 同上 | フェンスの外の行で式 R2（表の下）。ND-30 がこれ |
| ND の層 | S7 | 見出しの最後の列が「層」の表の、`ND-` で始まる行の最後の列を `・` で分けたもの |

- 式 R1（生きた ID。太字を許す）: `^\| \*{0,2}(<接頭辞>-[0-9]+)\*{0,2} \|`
- 式 R2（廃止した ID。打ち消し線）: `^\| ~~(<接頭辞>-[0-9]+)~~ \|`
- 表のセルは縦棒で分けるが、バッククォートの中の縦棒では分けない（`MarkdownDocument` の規則。T-04）

- `docs/SPEC.md` が無い・節が無いときは誤りを投げる（テストは **skip ではなく fail**）
- PLAN.md も同じ型で読める（`SpecDocument.plan()`。鍵は `A.1`・`A.2`・`A.3`・`A.4`・`6.4`・`8.11`・`B.1`・`B.2`・`B.3`）
- 見出しの名前でコードブロックを取る `codeBlock(heading:language:)`（00-api-map §15。後続のチケットが SPEC に置く逐語のブロック（T-17 の whisper-cli の argv など）を実装と照合するため）。見出しは本文の完全一致、節の終わりは次の見出し（深さを問わない。フェンスの中は除く）

### 3. テストの表示名から ID を集める（TestNameIndex）

- `Tests/` 配下の全 `.swift` を `SourceScanner` にかけ、直前のコードが `@Test(`（空白は無視）である文字列リテラルだけを表示名とみなす（コメントの中・普通の文字列の中の ID は拾わない）
- 表示名の先頭が `^((?:ND|RV|CV|DR|E2E)-[0-9]+)(?: \[(A|R1|R2|R3)\])?(?: |$)` に一致したら、ID と層を集める（ND の層の書き方は PLAN §10.3: `ND-18 [R2] …`）

### 4. 段階的に有効にする集合の一致（SpecCoverage）

- **常に**: テストの表示名の ID はすべて SPEC の生きた ID（`testIDsExistInSpec`。表に無い ID のテストを作らない）
- **有効にした種類だけ**: SPEC の ID の集合 = テストの ID の集合（`activatedKindsMatchSpec`）。ND はさらに層ごとに 1 本以上（`ndLayersCovered`）
- 有効にするのは、その種類のテストを揃えるチケット: **T-09 が `.cv`、T-32 が `.dr`、T-37 が `.rv`、T-39 が `.nd`** を `SpecCoverage.activated` に足す（E2E は docs/E2E.md の判定表との一致を T-35 が確かめる）

### 5. 後続のチケットが足す SPEC 同期のテスト（形をここで決める）

**T-08** が `Tests/VDCoreTests/SpecSyncStatesTests.swift` を次の全文で足す:

```swift
// 状態・遷移・復旧写像・エラーコードが docs/SPEC.md の表と一致することの検査（PLAN §10.3。T-08）。
import TestSupport
import Testing

@testable import VDCore

@Suite("SpecSyncStates")
struct SpecSyncStatesTests {
    @Test("Part の状態の宣言順が SPEC と同じ")
    func partStatesMatchSpec() throws {
        #expect(try PartStatus.allCases.map(\.rawValue) == SpecDocument.load().stateNames(.part))
    }

    @Test("Session の状態の宣言順が SPEC と同じ")
    func sessionStatesMatchSpec() throws {
        #expect(try SessionStatus.allCases.map(\.rawValue) == SpecDocument.load().stateNames(.session))
    }

    @Test("Part の遷移表が SPEC と同じ（辺の集合）")
    func partTransitionsMatchSpec() throws {
        let implemented = Set(TransitionTable.part.map { SpecEdge(from: $0.from.rawValue, to: $0.to.rawValue) })
        #expect(try implemented == Set(SpecDocument.load().transitionEdges(.part)))
    }

    @Test("Session の遷移表が SPEC と同じ（辺の集合）")
    func sessionTransitionsMatchSpec() throws {
        let implemented = Set(TransitionTable.session.map { SpecEdge(from: $0.from.rawValue, to: $0.to.rawValue) })
        #expect(try implemented == Set(SpecDocument.load().transitionEdges(.session)))
    }

    @Test("Part の復旧写像が SPEC と同じ（順も）")
    func partRecoveryMatchesSpec() throws {
        let implemented = TransitionTable.partRecovery.map { SpecEdge(from: $0.from.rawValue, to: $0.to.rawValue) }
        #expect(try implemented == SpecDocument.load().recoveryEdges(.part))
    }

    @Test("Session の復旧写像が SPEC と同じ（順も）")
    func sessionRecoveryMatchesSpec() throws {
        let implemented = TransitionTable.sessionRecovery.map { SpecEdge(from: $0.from.rawValue, to: $0.to.rawValue) }
        #expect(try implemented == SpecDocument.load().recoveryEdges(.session))
    }

    @Test("エラーコードの宣言順と再試行が SPEC と同じ")
    func errorCodesMatchSpec() throws {
        let rows = try SpecDocument.load().errorCodes()
        #expect(ErrorCode.allCases.map(\.rawValue) == rows.map(\.code))
        for row in rows {
            let code = try #require(ErrorCode(rawValue: row.code))
            #expect(String(describing: code.retryPolicy) == row.retry, "\(row.code)")
        }
    }
}
```

**T-10** が `Tests/VDCoreTests/SpecSyncLogEventsTests.swift` を次の全文で足す:

```swift
// LogEvent の登録順が docs/SPEC.md の S4 と一致することの検査（PLAN §10.3。T-10）。
import TestSupport
import Testing

@testable import VDCore

@Suite("SpecSyncLogEvents")
struct SpecSyncLogEventsTests {
    @Test("LogEvent の宣言順が SPEC と同じ")
    func logEventsMatchSpec() throws {
        #expect(try LogEvent.allCases.map(\.rawValue) == SpecDocument.load().logEvents())
    }
}
```

**T-09 / T-32 / T-37 / T-39** は、各 ID のテストの表示名を ID で始め（`@Test("CV-08 …")`、ND は `@Test("ND-18 [R2] …")`）、`SpecCoverage.activated` に種類を足す。

### 6. `Makefile` に足す行

`.PHONY` の行の末尾に ` spec` を足し、`clean:` の前に次を足す（レシピ行はタブ）:

```make
# PLAN の規範の表を docs/SPEC.md に写す（PLAN を直したら同じ PR で実行する。T-05）
spec:
	python3 tools/spec/make-spec.py
```

### 7. ファイルの全文

以下はすべて `swift format` で整形済み（`make lint` を通る）。Xcode 27.0 で `swift test --filter PolicyTests` が通ることを確かめ済み（T-01〜T-05 の分で 120 件）。

#### `tools/spec/make-spec.py`

```python
#!/usr/bin/env python3
"""docs/PLAN.md の規範の表を docs/SPEC.md に写す（PLAN §10.3。T-05）。

使い方: python3 tools/spec/make-spec.py
PLAN の表を直したら、同じ PR でこれを実行して SPEC.md を作り直す（SpecMatchesPlanTests が食い違いを落とす）。
標準ライブラリだけを使う。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PLAN = ROOT / "docs" / "PLAN.md"
SPEC = ROOT / "docs" / "SPEC.md"

FENCE = re.compile(r"^\s*```")
BOUNDARY = re.compile(r"^#{1,6} (?:[0-9A-Z]|付録)")
HEADING = re.compile(r"^#{1,6} (.*)$")

# (SPEC の見出し, PLAN の見出しの接頭辞, 写す範囲)
SECTIONS = [
    ("S1. 状態と復旧写像（PLAN 付録 A.1）", "A.1", "all"),
    ("S2. 遷移表（PLAN 付録 A.2）", "A.2", "all"),
    ("S3. エラーコード（PLAN 付録 A.3）", "A.3", "all"),
    ("S4. ログイベント（PLAN 付録 A.4）", "A.4", "all"),
    ("S5. 設定の検証 CV（PLAN §6.4）", "6.4", "all"),
    ("S6. 診断 DR（PLAN §8.11）", "8.11", "dr-table"),
    ("S7. 削除禁止テスト ND（PLAN 付録 B.1）", "B.1", "all"),
    ("S8. reaper の検証 RV（PLAN 付録 B.2）", "B.2", "all"),
    ("S9. 実機試験 E2E（PLAN 付録 B.3）", "B.3", "all"),
]

HEADER = """# VoiceDock 規範の表（docs/SPEC.md）

> この文書は `docs/PLAN.md` の規範の表の写しで、`tools/spec/make-spec.py` が作る。**手で直さない。**
> テスト（SPEC 同期）がこの文書を読み、実装の enum・定数・テストの表示名と突き合わせる。
> 表を変えるときは PLAN を直し、同じ PR で `python3 tools/spec/make-spec.py` を実行する（SpecMatchesPlanTests が食い違いを落とす）。
> 見出しの `S1.`〜`S9.` はテストが節を探す鍵なので変えない。
"""


def section(lines, key):
    in_fence = False
    start = None
    for index, line in enumerate(lines):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if start is not None:
            if BOUNDARY.match(line):
                return lines[start:index]
        else:
            match = HEADING.match(line)
            if match and match.group(1).startswith(key):
                start = index + 1
    if start is None:
        sys.exit(f"PLAN に見出し {key} がありません")
    return lines[start:]


def trim(lines):
    body = list(lines)
    while body and (body[-1].strip() == "" or body[-1].strip() == "---"):
        body.pop()
    while body and body[0].strip() == "":
        body.pop(0)
    return body


def dr_table(lines):
    for index, line in enumerate(lines):
        if line.startswith("| ID | 順 |"):
            end = index
            while end < len(lines) and lines[end].startswith("|"):
                end += 1
            return lines[index:end]
    sys.exit("PLAN §8.11 に DR の表がありません")


def main():
    plan = PLAN.read_text(encoding="utf-8").split("\n")
    out = HEADER.rstrip("\n").split("\n")
    for title, key, mode in SECTIONS:
        body = section(plan, key)
        body = dr_table(body) if mode == "dr-table" else trim(body)
        out += ["", f"## {title}", ""] + body
    SPEC.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"書きました: {SPEC.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
```

#### `Tests/TestSupport/Spec/SpecDocument.swift`

```swift
// 規範の表（docs/SPEC.md、比べる相手として docs/PLAN.md）を型付きで読む（PLAN §10.3 の SPEC 同期の読み方。T-05）。
import Foundation

/// 状態の表・遷移のフェンスのエンティティ。値は SPEC の見出し・行頭の語。
public enum SpecEntity: String, CaseIterable, Sendable {
    case part = "Part"
    case session = "Session"
}

/// ID で数える表の種類。値は ID の接頭辞。
public enum SpecIDKind: String, CaseIterable, Sendable {
    case cv = "CV"
    case dr = "DR"
    case nd = "ND"
    case rv = "RV"
    case e2e = "E2E"
}

/// 遷移の辺（`A→B`）。
public struct SpecEdge: Hashable, Sendable, CustomStringConvertible {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    public var description: String { "\(from)→\(to)" }
}

/// エラーコードの表の 1 行。
public struct SpecErrorCode: Equatable, Sendable {
    public let code: String
    /// 「再試行」の列の値（`none` / `nextPoll` / `nextConnect` / `attempts`）。
    public let retry: String
}

/// 規範の表を持つ文書。
public struct SpecDocument: Sendable {
    /// 節を探す鍵（SPEC.md と PLAN.md で見出しが違う）。
    public struct Keys: Sendable {
        let states, transitions, errors, events, cv, dr, nd, rv, e2e: String

        static let spec = Keys(
            states: "S1.", transitions: "S2.", errors: "S3.", events: "S4.", cv: "S5.", dr: "S6.", nd: "S7.",
            rv: "S8.", e2e: "S9.")
        static let plan = Keys(
            states: "A.1", transitions: "A.2", errors: "A.3", events: "A.4", cv: "6.4", dr: "8.11", nd: "B.1",
            rv: "B.2", e2e: "B.3")

        func key(for kind: SpecIDKind) -> String {
            switch kind {
            case .cv: cv
            case .dr: dr
            case .nd: nd
            case .rv: rv
            case .e2e: e2e
            }
        }
    }

    public let document: MarkdownDocument
    let keys: Keys

    /// `docs/SPEC.md` を読む。無ければ `MarkdownError.missing`（テストは skip せず fail にする）。
    public static func load() throws -> SpecDocument {
        SpecDocument(document: try MarkdownDocument.load("docs/SPEC.md"), keys: .spec)
    }

    /// 比べる相手として `docs/PLAN.md` を読む。
    public static func plan() throws -> SpecDocument {
        SpecDocument(document: try MarkdownDocument.load("docs/PLAN.md"), keys: .plan)
    }

    /// 文字列から作る（パーサのテスト用。鍵は SPEC.md のもの）。
    public init(text: String) {
        self.init(document: MarkdownDocument(text: text), keys: .spec)
    }

    init(document: MarkdownDocument, keys: Keys) {
        self.document = document
        self.keys = keys
    }

    /// `` `NAME` `` から NAME を取り出す（形が違えば nil）。
    static func unquote(_ cell: String) -> String? {
        guard cell.count >= 3, cell.hasPrefix("`"), cell.hasSuffix("`") else { return nil }
        return String(cell.dropFirst().dropLast())
    }

    /// 状態の名前（表の出現順 = 宣言順）。見出しの列が「Part の状態」「Session の状態」の表から読む。
    public func stateNames(_ entity: SpecEntity) throws -> [String] {
        let header = "\(entity.rawValue) の状態"
        return MarkdownDocument.tables(in: try document.section(keys.states))
            .filter { $0.header.contains(header) }
            .flatMap { table in
                table.rows.compactMap { row -> String? in
                    guard row.count >= 2, Int(row[0]) != nil else { return nil }
                    return Self.unquote(row[1])
                }
            }
    }

    /// `A→B` の辺をすべて取り出す（`★` と括弧の注記は無視する）。
    static func edges(in line: Substring) -> [SpecEdge] {
        let text = String(line)
        guard let regex = try? NSRegularExpression(pattern: "([A-Z_]+)→([A-Z_]+)") else { return [] }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let from = Range(match.range(at: 1), in: text), let to = Range(match.range(at: 2), in: text) else {
                return nil
            }
            return SpecEdge(from: String(text[from]), to: String(text[to]))
        }
    }

    /// 遷移表の辺（出現順）。直前の段落が `Part:` / `Session:` の text フェンスから読む。
    public func transitionEdges(_ entity: SpecEntity) throws -> [SpecEdge] {
        let label = "\(entity.rawValue):"
        return MarkdownDocument.fences(in: try document.section(keys.transitions), language: "text")
            .filter { $0.precedingLine?.trimmingCharacters(in: .whitespaces) == label }
            .flatMap { fence in fence.body.flatMap { Self.edges(in: Substring($0)) } }
    }

    /// 復旧写像の辺（処理の順）。状態の節の text フェンスの、行頭が `Part:` / `Session:` の行から読む。
    public func recoveryEdges(_ entity: SpecEntity) throws -> [SpecEdge] {
        let label = "\(entity.rawValue):"
        return MarkdownDocument.fences(in: try document.section(keys.states), language: "text")
            .flatMap { fence in fence.body.filter { $0.hasPrefix(label) } }
            .flatMap { Self.edges(in: $0.dropFirst(label.count)) }
    }

    /// エラーコード（宣言順）と再試行の列。見出しに「コード」を持つ表の、先頭の列が数の行から読む。
    public func errorCodes() throws -> [SpecErrorCode] {
        MarkdownDocument.tables(in: try document.section(keys.errors))
            .filter { $0.header.contains("コード") }
            .flatMap { table in
                table.rows.compactMap { row -> SpecErrorCode? in
                    guard row.count >= 3, Int(row[0]) != nil, let code = Self.unquote(row[1]) else { return nil }
                    return SpecErrorCode(code: code, retry: row[2])
                }
            }
    }

    /// ログイベント（登録順）。イベントの節の最初の text フェンスを空白と改行で分ける。
    public func logEvents() throws -> [String] {
        guard let fence = MarkdownDocument.fences(in: try document.section(keys.events), language: "text").first else {
            return []
        }
        return fence.body.flatMap { $0.split(separator: " ").map(String.init) }.filter { !$0.isEmpty }
    }

    /// 表の行の ID（`| ND-18 |` や `| **ND-24** |`）を出現順に返す。`live` なら打ち消し（`~~`）の行を除き、偽なら打ち消しの行だけを返す。
    func rowIDs(_ kind: SpecIDKind, live: Bool) throws -> [String] {
        let prefix = NSRegularExpression.escapedPattern(for: kind.rawValue)
        let pattern = live ? "^\\| \\*{0,2}(\(prefix)-[0-9]+)\\*{0,2} \\|" : "^\\| ~~(\(prefix)-[0-9]+)~~ \\|"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var inFence = false
        var ids: [String] = []
        for line in try document.section(keys.key(for: kind)) {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            let range = NSRange(location: 0, length: line.utf16.count)
            if let match = regex.firstMatch(in: line, range: range), let id = Range(match.range(at: 1), in: line) {
                ids.append(String(line[id]))
            }
        }
        return ids
    }

    /// 生きている ID（出現順）。
    public func ids(_ kind: SpecIDKind) throws -> [String] { try rowIDs(kind, live: true) }

    /// 廃止した（打ち消しの行の）ID。
    public func retiredIDs(_ kind: SpecIDKind) throws -> [String] { try rowIDs(kind, live: false) }

    /// 見出しの本文が `heading` と等しい節（見出しの次の行から、次の見出し（深さを問わない。フェンスの中は見出しとしない）の手前まで）の、
    /// 最初の `language` のコードフェンスの中身を改行でつないで返す（`language` が nil なら言語を問わない）。
    /// SPEC に置いた逐語のブロック（T-17 の whisper-cli の argv など）と実装の照合に使う。見出しが無ければ `sectionNotFound`、フェンスが無ければ nil。
    public func codeBlock(heading: String, language: String?) throws -> String? {
        var inFence = false
        var start: Int?
        var end = document.lines.count
        for (index, line) in document.lines.enumerated() {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            guard let text = MarkdownDocument.headingText(line) else { continue }
            if start != nil {
                end = index
                break
            }
            if text == heading { start = index + 1 }
        }
        guard let begin = start else { throw MarkdownError.sectionNotFound(heading) }
        let fences = MarkdownDocument.fences(in: Array(document.lines[begin..<end]), language: language)
        return fences.first.map { $0.body.joined(separator: "\n") }
    }

    /// ND の各行の「層」の列（最後の列）を `・` で分けたもの。
    public func ndLayers() throws -> [String: [String]] {
        var layers: [String: [String]] = [:]
        for table in MarkdownDocument.tables(in: try document.section(keys.nd)) where table.header.last == "層" {
            for row in table.rows {
                guard let id = row.first, id.hasPrefix("ND-"), let last = row.last else { continue }
                layers[id] = last.split(separator: "・").map(String.init)
            }
        }
        return layers
    }
}
```

#### `Tests/PolicyTests/Rules/PolicyVocabulary.swift`

```swift
// PT-06 が探す状態名とエラーコード名（docs/SPEC.md の S1・S3 から読む。T-04 で作り、T-05 で読み先を SPEC に替えた）。
import TestSupport

struct PolicyVocabulary: Sendable {
    let stateNames: [String]
    let errorCodeNames: [String]

    /// `docs/SPEC.md` の状態（Part と Session）とエラーコードから読む。
    static func load() throws -> PolicyVocabulary {
        let spec = try SpecDocument.load()
        let states = try SpecEntity.allCases.flatMap { try spec.stateNames($0) }
        let codes = try spec.errorCodes().map(\.code)
        return PolicyVocabulary(stateNames: Array(Set(states)).sorted(), errorCodeNames: codes)
    }
}
```

#### `Tests/PolicyTests/SpecSync/TestNameIndex.swift`

```swift
// テストの表示名から規範の ID（ND・RV・CV・DR・E2E）を集める（PLAN §10.1・§10.3。T-05）。
import Foundation
import TestSupport

/// 表示名の先頭の ID と層（`ND-18 [R2] …` の R2）。
struct TestNameEntry: Equatable, Sendable {
    let id: String
    let layer: String?
    /// `Tests/` からの相対パス。
    let path: String
}

enum TestNameIndex {
    /// 表示名の先頭の形。ID の後は空白か終わり、層は ID の直後の `[A]` / `[R1]` / `[R2]` / `[R3]`。
    static let pattern = "^((?:ND|RV|CV|DR|E2E)-[0-9]+)(?: \\[(A|R1|R2|R3)\\])?(?: |$)"

    /// 文字列リテラルの直前のコードが `@Test(` か（空白は無視する）。
    static func isTestDisplayName(_ literal: StringLiteral, in code: [Unicode.Scalar]) -> Bool {
        var index = literal.offset - 1
        func skipSpaces() {
            while index >= 0 && CodeTokenizer.isSpace(code[index]) { index -= 1 }
        }
        skipSpaces()
        guard index >= 0, code[index] == "(" else { return false }
        index -= 1
        skipSpaces()
        let word: [Unicode.Scalar] = ["T", "e", "s", "t"]
        guard index - 3 >= 0, Array(code[(index - 3)...index]) == word else { return false }
        index -= 4
        guard index >= 0, code[index] == "@" else { return false }
        return true
    }

    /// 1 つのソースから集める。
    static func entries(in text: String, path: String) -> [TestNameEntry] {
        let scanned = SourceScanner.scan(text)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return scanned.literals.compactMap { literal in
            guard isTestDisplayName(literal, in: scanned.code) else { return nil }
            let raw = literal.raw
            let range = NSRange(location: 0, length: raw.utf16.count)
            guard let match = regex.firstMatch(in: raw, range: range), let id = Range(match.range(at: 1), in: raw)
            else { return nil }
            let layer = Range(match.range(at: 2), in: raw).map { String(raw[$0]) }
            return TestNameEntry(id: String(raw[id]), layer: layer, path: path)
        }
    }

    /// `Tests/` 配下の全 `.swift` から集める。
    static func load() throws -> [TestNameEntry] {
        let root = PackageRoot.file("Tests")
        guard let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        var result: [TestNameEntry] = []
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            result += entries(in: text, path: path)
        }
        return result.sorted { ($0.path, $0.id) < ($1.path, $1.id) }
    }
}
```

#### `Tests/PolicyTests/SpecSync/SpecCoverage.swift`

```swift
// どの種類の ID について「SPEC の表 = テストの表示名」を確かめるか（T-05。後続のチケットが足す）。
import TestSupport

enum SpecCoverage {
    /// 表とテストが揃ったので、ID の集合の一致を確かめる種類。
    /// T-09 が `.cv`、T-32 が `.dr`、T-37 が `.rv`、T-39 が `.nd` を足す（E2E は docs/E2E.md の側で T-35 が確かめる）。
    static let activated: Set<SpecIDKind> = []
}
```

#### `Tests/PolicyTests/SpecSync/SpecStructureTests.swift`

```swift
// docs/SPEC.md が読め、各節が空でなく、ID が重ならないことの検査（PLAN §10.3・CR-18。T-05）。
import TestSupport
import Testing

@Suite("SpecStructure")
struct SpecStructureTests {
    @Test("docs/SPEC.md が在る（無ければ skip ではなく fail）")
    func specExists() throws {
        _ = try SpecDocument.load()
    }

    @Test("状態・遷移・復旧写像が Part と Session の両方で空でない", arguments: SpecEntity.allCases)
    func statesAndEdgesAreNotEmpty(_ entity: SpecEntity) throws {
        let spec = try SpecDocument.load()
        #expect(!(try spec.stateNames(entity)).isEmpty)
        #expect(!(try spec.transitionEdges(entity)).isEmpty)
        #expect(!(try spec.recoveryEdges(entity)).isEmpty)
    }

    @Test("エラーコードとログイベントが空でない")
    func errorCodesAndEventsAreNotEmpty() throws {
        let spec = try SpecDocument.load()
        #expect(!(try spec.errorCodes()).isEmpty)
        #expect(!(try spec.logEvents()).isEmpty)
    }

    @Test("ID の表が空でなく、ID が重ならない", arguments: SpecIDKind.allCases)
    func idsAreUniqueAndNotEmpty(_ kind: SpecIDKind) throws {
        let ids = try SpecDocument.load().ids(kind)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count, "重複: \(ids)")
    }

    @Test("廃止した ID を生きた ID として再利用しない", arguments: SpecIDKind.allCases)
    func retiredIDsAreNotReused(_ kind: SpecIDKind) throws {
        let spec = try SpecDocument.load()
        #expect(Set(try spec.ids(kind)).isDisjoint(with: try spec.retiredIDs(kind)))
    }

    @Test("状態・エラーコード・イベントの名前が重ならない")
    func namesAreUnique() throws {
        let spec = try SpecDocument.load()
        for entity in SpecEntity.allCases {
            let names = try spec.stateNames(entity)
            #expect(Set(names).count == names.count)
        }
        let codes = try spec.errorCodes().map(\.code)
        #expect(Set(codes).count == codes.count)
        let events = try spec.logEvents()
        #expect(Set(events).count == events.count)
    }

    @Test("遷移と復旧写像の辺は状態の表に在る状態だけを使う", arguments: SpecEntity.allCases)
    func edgesUseKnownStates(_ entity: SpecEntity) throws {
        let spec = try SpecDocument.load()
        let states = Set(try spec.stateNames(entity))
        for edge in try spec.transitionEdges(entity) + spec.recoveryEdges(entity) {
            #expect(states.contains(edge.from) && states.contains(edge.to), "\(entity.rawValue) の \(edge)")
        }
    }

    @Test("エラーコードの再試行の列は 4 つの値のどれか")
    func retryColumnValues() throws {
        let allowed: Set<String> = ["none", "nextPoll", "nextConnect", "attempts"]
        for row in try SpecDocument.load().errorCodes() {
            #expect(allowed.contains(row.retry), "\(row.code): \(row.retry)")
        }
    }

    @Test("ND の層の列は A・R1・R2・R3 の組み合わせ")
    func ndLayersAreKnown() throws {
        let spec = try SpecDocument.load()
        let layers = try spec.ndLayers()
        for id in try spec.ids(.nd) {
            let value = try #require(layers[id], "\(id) の層が無い")
            #expect(!value.isEmpty && Set(value).isSubset(of: ["A", "R1", "R2", "R3"]), "\(id): \(value)")
        }
    }
}
```

#### `Tests/PolicyTests/SpecSync/SpecMatchesPlanTests.swift`

```swift
// docs/SPEC.md が docs/PLAN.md の表の写しであることの検査（PLAN を直して SPEC を作り直し忘れたら落ちる。T-05）。
import TestSupport
import Testing

@Suite("SpecMatchesPlan")
struct SpecMatchesPlanTests {
    @Test("状態・遷移・復旧写像が PLAN と同じ", arguments: SpecEntity.allCases)
    func statesAndEdgesMatchPlan(_ entity: SpecEntity) throws {
        let spec = try SpecDocument.load()
        let plan = try SpecDocument.plan()
        #expect(try spec.stateNames(entity) == plan.stateNames(entity))
        #expect(try spec.transitionEdges(entity) == plan.transitionEdges(entity))
        #expect(try spec.recoveryEdges(entity) == plan.recoveryEdges(entity))
    }

    @Test("エラーコードとログイベントが PLAN と同じ")
    func errorCodesAndEventsMatchPlan() throws {
        let spec = try SpecDocument.load()
        let plan = try SpecDocument.plan()
        #expect(try spec.errorCodes() == plan.errorCodes())
        #expect(try spec.logEvents() == plan.logEvents())
    }

    @Test("ID の表が PLAN と同じ", arguments: SpecIDKind.allCases)
    func idsMatchPlan(_ kind: SpecIDKind) throws {
        let spec = try SpecDocument.load()
        let plan = try SpecDocument.plan()
        #expect(try spec.ids(kind) == plan.ids(kind))
        #expect(try spec.retiredIDs(kind) == plan.retiredIDs(kind))
    }

    @Test("ND の層が PLAN と同じ")
    func ndLayersMatchPlan() throws {
        #expect(try SpecDocument.load().ndLayers() == SpecDocument.plan().ndLayers())
    }
}
```

#### `Tests/PolicyTests/SpecSync/SpecCoverageTests.swift`

```swift
// テストの表示名の ID が SPEC の表に在ること、有効にした種類では集合が一致することの検査（PLAN §10.3。T-05）。
import TestSupport
import Testing

@Suite("SpecCoverage")
struct SpecCoverageTests {
    @Test("テストの表示名の ID はすべて SPEC の表の生きた ID")
    func testIDsExistInSpec() throws {
        let spec = try SpecDocument.load()
        var live: Set<String> = []
        for kind in SpecIDKind.allCases { live.formUnion(try spec.ids(kind)) }
        for entry in try TestNameIndex.load() {
            #expect(live.contains(entry.id), "\(entry.path) の \(entry.id) は SPEC の表に無い")
        }
    }

    @Test("有効にした種類では SPEC の ID の集合とテストの ID の集合が一致する")
    func activatedKindsMatchSpec() throws {
        let spec = try SpecDocument.load()
        let entries = try TestNameIndex.load()
        for kind in SpecCoverage.activated {
            let specIDs = Set(try spec.ids(kind))
            let testIDs = Set(entries.map(\.id).filter { $0.hasPrefix(kind.rawValue + "-") })
            #expect(
                specIDs == testIDs,
                "\(kind.rawValue): SPEC だけ \(specIDs.subtracting(testIDs).sorted())、テストだけ \(testIDs.subtracting(specIDs).sorted())"
            )
        }
    }

    @Test("ND を有効にしたら、各 ND の層ごとに 1 本以上のテストがある")
    func ndLayersAreCovered() throws {
        guard SpecCoverage.activated.contains(.nd) else { return }
        let spec = try SpecDocument.load()
        let entries = try TestNameIndex.load().filter { $0.id.hasPrefix("ND-") }
        for (id, layers) in try spec.ndLayers() {
            for layer in layers {
                #expect(entries.contains { $0.id == id && $0.layer == layer }, "\(id) [\(layer)] のテストが無い")
            }
        }
    }
}
```

#### `Tests/PolicyTests/SpecSync/SpecParserTests.swift`

```swift
// MarkdownDocument・SpecDocument・TestNameIndex の読み方の固定テスト（PLAN §10.3。T-05）。
import TestSupport
import Testing

@Suite("SpecParser")
struct SpecParserTests {
    @Test("コードフェンスの中の # 行で節が切れない")
    func fenceDoesNotEndSection() throws {
        let doc = MarkdownDocument(text: "## S1. 状態\n\n```bash\n# 2026-09-18 に実行\n```\nafter\n## S2. 次\nnext\n")
        let lines = try doc.section("S1.")
        #expect(lines.contains("after"))
        #expect(!lines.contains("next"))
    }

    @Test("見出しが無ければ誤りを投げる（skip しない）")
    func missingSectionThrows() {
        #expect(throws: MarkdownError.sectionNotFound("S9.")) {
            try MarkdownDocument(text: "## S1. a\n").section("S9.")
        }
    }

    @Test("太字の ID を読み、打ち消しの行を生きた ID に数えない")
    func boldAndStruckIDs() throws {
        let spec = SpecDocument(
            text:
                "## S7. ND\n\n| # | 故障 | 期待 | 層 |\n|---|---|---|---|\n| **ND-24** | a | b | R2 |\n| ~~ND-30~~ | ~~c~~ | — | — |\n| ND-31 | d | e | A・R3 |\n"
        )
        #expect(try spec.ids(.nd) == ["ND-24", "ND-31"])
        #expect(try spec.retiredIDs(.nd) == ["ND-30"])
        #expect(try spec.ndLayers()["ND-31"] == ["A", "R3"])
    }

    @Test("見出しの名前でコードブロックを取り、次の見出しの先のフェンスは取らない")
    func codeBlockByHeading() throws {
        let text = "## S9. E2E\n\n## whisper-cli の argv\n\n```text\n-m a -f b\n```\n## 次\n```text\nother\n```\n"
        let spec = SpecDocument(text: text)
        #expect(try spec.codeBlock(heading: "whisper-cli の argv", language: "text") == "-m a -f b")
        #expect(try spec.codeBlock(heading: "S9. E2E", language: "text") == nil)
        #expect(throws: MarkdownError.sectionNotFound("無い")) {
            try spec.codeBlock(heading: "無い", language: nil)
        }
    }

    @Test("表のセルはバッククォートの中の | で分けない")
    func cellsKeepPipeInCode() {
        #expect(MarkdownDocument.cells("| `a|b` | c |") == ["`a|b`", "c"])
    }

    @Test("遷移は直前の段落 Part: / Session: で分け、★ と括弧の注記を無視する")
    func transitionFences() throws {
        let text = "## S2. 遷移\n\nPart:\n```text\nA→B | B→C(注記)\n```\nSession:\n```text\n★ X→Y\n```\n"
        let spec = SpecDocument(text: text)
        #expect(try spec.transitionEdges(.part) == [SpecEdge(from: "A", to: "B"), SpecEdge(from: "B", to: "C")])
        #expect(try spec.transitionEdges(.session) == [SpecEdge(from: "X", to: "Y")])
    }

    @Test("テストの表示名から ID と層を集め、@Test でない文字列と文中の ID は拾わない")
    func testNameIndex() {
        let source = """
            @Test("ND-18 [R2] サイズが変わる") func a() {}
            @Test("CV-08 境界") func b() {}
            let note = "ND-99 これはテスト名ではない"
            @Test("説明の中の ND-77 は先頭ではない") func c() {}
            // @Test("ND-66 コメント")
            """
        let entries = TestNameIndex.entries(in: source, path: "X.swift")
        #expect(entries.map(\.id) == ["ND-18", "CV-08"])
        #expect(entries.first?.layer == "R2")
    }
}
```

## テスト

| ファイル | 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|---|
| `SpecStructureTests.swift` | `specExists()` | docs/SPEC.md が在る（無ければ skip ではなく fail） | — | 読める |
| 同上 | `statesAndEdgesAreNotEmpty(_:)` | 状態・遷移・復旧写像が Part と Session の両方で空でない | 2 エンティティ | 3 つとも空でない |
| 同上 | `errorCodesAndEventsAreNotEmpty()` | エラーコードとログイベントが空でない | — | 空でない |
| 同上 | `idsAreUniqueAndNotEmpty(_:)` | ID の表が空でなく、ID が重ならない | 5 種類 | 空でなく重複なし |
| 同上 | `retiredIDsAreNotReused(_:)` | 廃止した ID を生きた ID として再利用しない | 5 種類 | 交わらない（CR-18） |
| 同上 | `namesAreUnique()` | 状態・エラーコード・イベントの名前が重ならない | — | 重複なし |
| 同上 | `edgesUseKnownStates(_:)` | 遷移と復旧写像の辺は状態の表に在る状態だけを使う | 2 エンティティ | すべて表に在る |
| 同上 | `retryColumnValues()` | エラーコードの再試行の列は 4 つの値のどれか | — | none / nextPoll / nextConnect / attempts |
| 同上 | `ndLayersAreKnown()` | ND の層の列は A・R1・R2・R3 の組み合わせ | — | 全 ND に層があり既知の値 |
| `SpecMatchesPlanTests.swift` | `statesAndEdgesMatchPlan(_:)` | 状態・遷移・復旧写像が PLAN と同じ | PLAN と SPEC | 一致 |
| 同上 | `errorCodesAndEventsMatchPlan()` | エラーコードとログイベントが PLAN と同じ | 同上 | 一致 |
| 同上 | `idsMatchPlan(_:)` | ID の表が PLAN と同じ | 同上 | 生きた ID と廃止した ID が一致 |
| 同上 | `ndLayersMatchPlan()` | ND の層が PLAN と同じ | 同上 | 一致 |
| `SpecCoverageTests.swift` | `testIDsExistInSpec()` | テストの表示名の ID はすべて SPEC の表の生きた ID | `Tests/` 全体 | すべて在る |
| 同上 | `activatedKindsMatchSpec()` | 有効にした種類では SPEC の ID の集合とテストの ID の集合が一致する | `SpecCoverage.activated`（T-05 では空） | 一致 |
| 同上 | `ndLayersAreCovered()` | ND を有効にしたら、各 ND の層ごとに 1 本以上のテストがある | 同上（T-39 から効く） | 層ごとに在る |
| `SpecParserTests.swift` | `fenceDoesNotEndSection()` | コードフェンスの中の # 行で節が切れない | 文字列の Markdown | フェンスの後の行が節に入る |
| 同上 | `missingSectionThrows()` | 見出しが無ければ誤りを投げる（skip しない） | 同上 | `sectionNotFound("S9.")` |
| 同上 | `boldAndStruckIDs()` | 太字の ID を読み、打ち消しの行を生きた ID に数えない | 同上 | 生きた ID・廃止・層 |
| 同上 | `codeBlockByHeading()` | 見出しの名前でコードブロックを取り、次の見出しの先のフェンスは取らない | 文字列の Markdown | `"-m a -f b"`、フェンスの無い節（`S9. E2E`）は次の見出しの先のフェンスを取らず nil、無い見出しは `sectionNotFound("無い")` |
| 同上 | `cellsKeepPipeInCode()` | 表のセルはバッククォートの中の \| で分けない | — | セルは 2 つ。1 つ目はバッククォートで囲んだ `a` 縦棒 `b` のまま |
| 同上 | `transitionFences()` | 遷移は直前の段落 Part: / Session: で分け、★ と括弧の注記を無視する | 同上 | 辺の列 |
| 同上 | `testNameIndex()` | テストの表示名から ID と層を集め、@Test でない文字列と文中の ID は拾わない | 文字列のソース | `["ND-18", "CV-08"]`、層 R2 |

## 破壊による証明

下の 7 項目は、T-01〜T-05 の全文を置いた作業用のパッケージで実際に壊し、右の列のテストが落ちる（ほかは通る）ことを確かめ済み。

| 壊し方 | 落ちるべきもの |
|---|---|
| `docs/SPEC.md` の S3 の表から `DISK_SPACE_LOW` の行を消す | `errorCodesAndEventsMatchPlan()` |
| `docs/SPEC.md` を消す | `specExists()` をはじめ SPEC を読むテストすべてと、PT-01〜22（`PolicyVocabulary` が SPEC を読むため）。どれも skip にならず fail |
| `MarkdownDocument.section` の `if inFence { continue }` の行を消す | `fenceDoesNotEndSection()` |
| `SpecDocument.rowIDs` の式 R1 の `\*{0,2}` を 2 か所とも `[*~]{0,2}` にして、打ち消しの行も拾う | `boldAndStruckIDs()`、`retiredIDsAreNotReused(_:)`（.nd）、`ndLayersAreKnown()` |
| `TestNameIndex.isTestDisplayName` の先頭に `if literal.offset >= 0 { return true }` を足す（常に真。到達しないコードの警告を避ける書き方） | `testNameIndex()`、`testIDsExistInSpec()` |
| `docs/PLAN.md` の付録 A.4 のフェンスにイベントを 1 つ足し、SPEC を作り直さない | `errorCodesAndEventsMatchPlan()` |
| `SpecCoverage.activated` を `[.cv]` にする（CV のテストがまだ無い） | `activatedKindsMatchSpec()` |
| `SpecDocument.codeBlock` の `end = index; break` を消す（次の見出しで止まらない） | `codeBlockByHeading()`（整合修正で足した項目。未検証） |

## 受け入れ条件

- [ ] `python3 tools/spec/make-spec.py` で `docs/SPEC.md` を作り、コミットした（もう一度実行して `git diff --quiet docs/SPEC.md` が真。生成が再現する）
- [ ] `make lint` と `make test` が通る
- [ ] `PolicyVocabulary` が SPEC.md から読むようになり、T-04 の PT-06 のテストが通る
- [ ] 破壊による証明の 7 項目の結果を PR に貼った

## SPEC の変更

`docs/SPEC.md` を新しく作る（中身は PLAN の表の写し）。

## マージ後にやること

- T-08 で `SpecSyncStatesTests.swift`、T-10 で `SpecSyncLogEventsTests.swift` を §5 の全文で足す
- T-09・T-32・T-37・T-39 で `SpecCoverage.activated` に種類を足す
- 以後、PLAN の規範の表を直す PR は `make spec` を実行して SPEC.md も同じ PR で更新する（PLAN §12.1）


## API 地図への変更提案

- §14 の TestSupport に `Spec/SpecDocument.swift`（`SpecDocument`・`SpecEntity`・`SpecIDKind`・`SpecEdge`・`SpecErrorCode`）を足す。後続の SPEC 同期のテストはこれだけで表を読む → 00-api-map に反映済み（2026-09-18。§14・§15。§15 の `codeBlock(heading:language:)` は整合修正で §7 の全文に足した）
- §14 の PolicyTests に `SpecSync/`（`TestNameIndex`・`SpecCoverage`・3 つのテストの型と `SpecParserTests`）を足す。`SpecCoverage.activated` に種類を足すのは T-09（.cv）・T-32（.dr）・T-37（.rv）・T-39（.nd） → 地図 §14 は PolicyTests の中身を「PT・SPEC 同期・文書テスト」とだけ書く（テストのターゲットの中の型は地図の対象外。このチケットで決定）
- VDCoreTests に `SpecSyncStatesTests.swift`（T-08）と `SpecSyncLogEventsTests.swift`（T-10）を足す（§5 の全文） → 地図の対象外（テストのファイル）。T-08・T-10 のチケットを §5 の置き場所と名前に合わせた
- Makefile のターゲットに `spec` を足す → 地図の対象外（このチケットで決定）
- （整合修正で追記）00-api-map §15 は `Markdown/MarkdownDocument` の作り手を T-05 と書くが、作るのは T-04（本チケットは使うだけ）。地図を T-04 に直すことを提案する
- （実装時に発見・決定）00-api-map §0 は「`URL` からパス文字列を取るときは `url.path(percentEncoded: false)` だけを使う」とするが、§7 の `TestNameIndex.load()` は `root.path` を使っていた。上位の地図に合わせて `root.path(percentEncoded: false)` にした（T-04 の `SourceTree.load` と同じ書き方）。地図の変更は不要
