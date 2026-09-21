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
