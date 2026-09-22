// SPEC 同期の拡張（issue #18。PLAN F-68）: S8 の理由語の列と、S10〜S13・S20〜S23 の表を型付きで読む。
// SpecDocument（T-05）の型に extension で足す（00-api-map §15）。照合のテストは実装を import できる各モジュールのテストに置く。
import Foundation

/// 保存検証の規則の種類（S12。値は ID の接頭辞）。
public enum SpecNoteKind: String, CaseIterable, Sendable {
    case raw = "RN"
    case daily = "DN"
}

/// S13 の 1 行（tick の段）。
public struct SpecTickStage: Equatable, Sendable {
    /// `TickStage` の case 名。
    public let name: String
    /// 「条件」の列（`—`・`snapshot が新鮮` など）。
    public let condition: String
}

/// S20 の 1 行（パネルの節）。
public struct SpecPanelSection: Equatable, Sendable {
    /// PLAN §8.12 の番号。
    public let number: Int
    public let title: String
    /// 主画面に出すか（「主画面」の列が `—` で始まらない）。
    public let onMain: Bool
    /// 別の画面の `PanelScreen` の case 名（無ければ nil）。
    public let screen: String?
}

/// S21 の 1 行（メニューバーのアイコン）。
public struct SpecIconRow: Equatable, Sendable {
    public let label: String
    /// `IconState` の case 名（並べて出す記号の行は nil）。
    public let state: String?
    public let symbol: String
}

/// S22 の 1 行（はじめにの項目）。
public struct SpecOnboardingStep: Equatable, Sendable {
    /// `①` 〜 `⑤`。
    public let mark: String
    /// パネルの文言。
    public let title: String
    /// `OnboardingStep` の case 名。
    public let step: String
}

/// S23 の 1 行（ui-state.json の鍵）。
public struct SpecJSONKey: Equatable, Sendable {
    public let key: String
    /// 「型」の列（`整数` / `真偽`）。
    public let type: String
    /// 「値」の列（そのまま）。
    public let value: String
}

extension SpecDocument {
    /// 拡張した節。SPEC.md と PLAN.md で探す鍵と、写した表の見出しの接頭辞。
    enum ExtendedSection {
        case patterns, whisperArgv, noteRules, tickStages, panelSections, icons, onboarding, uiState

        var specKeys: [String] {
            switch self {
            case .patterns: ["S10."]
            case .whisperArgv: ["S11."]
            case .noteRules: ["S12."]
            case .tickStages: ["S13."]
            case .panelSections: ["S20."]
            case .icons: ["S21."]
            case .onboarding: ["S22."]
            case .uiState: ["S23."]
            }
        }

        var planKeys: [String] {
            switch self {
            case .patterns: ["4.1", "4.4"]
            case .whisperArgv: ["8.4"]
            case .noteRules: ["8.7"]
            case .tickStages: ["5.4"]
            case .panelSections, .icons, .onboarding, .uiState: ["8.12"]
            }
        }

        /// 表の見出しの先頭のセル（tools/spec/make-spec.py の接頭辞と同じ表を指す）。
        var header: [String] {
            switch self {
            case .patterns: ["定数", "正規表現"]
            case .whisperArgv: []
            case .noteRules: ["#", "Raw（RN。voicedock R-n）", "Daily（DN。voicedock W-n）"]
            case .tickStages: ["#", "段"]
            case .panelSections: ["#", "節"]
            case .icons: ["状態", "IconState"]
            case .onboarding: ["#", "項目"]
            case .uiState: ["鍵", "型"]
            }
        }
    }

    var isSpecFile: Bool { keys.states == Keys.spec.states }

    /// 節の行（複数の節から写したものは順につなぐ）。
    func lines(of section: ExtendedSection) throws -> [String] {
        try (isSpecFile ? section.specKeys : section.planKeys).flatMap { try document.section($0) }
    }

    /// 見出しの先頭のセルが一致する表の行をつないで返す（1 つも無ければ空）。
    func rows(of section: ExtendedSection) throws -> [[String]] {
        let header = section.header
        return MarkdownDocument.tables(in: try lines(of: section))
            .filter { Array($0.header.prefix(header.count)) == header }
            .flatMap(\.rows)
    }

    /// 表のセルの `\|` を `|` に戻す（GFM の表ではコードの中の `|` をこう書く）。
    static func unescapePipes(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\\|", with: "|")
    }

    /// `—` で始まるセルは「無い」。
    static func isNone(_ cell: String) -> Bool { cell.hasPrefix("—") }

    /// S8（付録 B.2）の「理由語」の列のバッククォートの語を出現順に（重複は最初の 1 回だけ）。`IdentityReason.all` と照合する。
    public func reasonWords() throws -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "`([a-z0-9_]+)`") else { return [] }
        var words: [String] = []
        for table in MarkdownDocument.tables(in: try document.section(keys.rv)) {
            guard let column = table.header.firstIndex(of: "理由語") else { continue }
            for row in table.rows where row.count > column {
                let cell = row[column]
                let range = NSRange(location: 0, length: cell.utf16.count)
                for match in regex.matches(in: cell, range: range) {
                    guard let word = Range(match.range(at: 1), in: cell) else { continue }
                    let text = String(cell[word])
                    if !words.contains(text) { words.append(text) }
                }
            }
        }
        return words
    }

    /// S10 の名前の正規表現（定数名 → 正規表現。`\|` は `|` に戻す）。
    public func namePatterns() throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try rows(of: .patterns) {
            guard row.count >= 2, let name = Self.unquote(row[0]), let pattern = Self.unquote(row[1]) else { continue }
            result[name] = Self.unescapePipes(pattern)
        }
        return result
    }

    /// S11 の whisper-cli の argv（最初の `text` フェンスを空白と改行で分けた語。先頭は実行ファイル）。
    public func whisperArgv() throws -> [String] {
        guard let fence = MarkdownDocument.fences(in: try lines(of: .whisperArgv), language: "text").first else {
            return []
        }
        return fence.body.flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
    }

    /// S12 の保存検証の規則 ID（`RN-1` …。「#」の列の番号に接頭辞を付け、`—` の欄は除く）。
    public func noteRules(_ kind: SpecNoteKind) throws -> [String] {
        let column = kind == .raw ? 1 : 2
        return try rows(of: .noteRules).compactMap { row -> String? in
            guard row.count >= 3, let number = Int(row[0]), !Self.isNone(row[column]) else { return nil }
            return "\(kind.rawValue)-\(number)"
        }
    }

    /// S13 の tick の段（表の順）。
    public func tickStages() throws -> [SpecTickStage] {
        try rows(of: .tickStages).compactMap { row -> SpecTickStage? in
            guard row.count >= 4, Int(row[0]) != nil, let name = Self.unquote(row[1]) else { return nil }
            return SpecTickStage(name: name, condition: row[3])
        }
    }

    /// S20 のパネルの節（表の順）。
    public func panelSections() throws -> [SpecPanelSection] {
        try rows(of: .panelSections).compactMap { row -> SpecPanelSection? in
            guard row.count >= 4, let number = Int(row[0]) else { return nil }
            return SpecPanelSection(
                number: number, title: row[1], onMain: !Self.isNone(row[2]), screen: Self.unquote(row[3]))
        }
    }

    /// S21 のメニューバーのアイコン（表の順）。
    public func iconRows() throws -> [SpecIconRow] {
        try rows(of: .icons).compactMap { row -> SpecIconRow? in
            guard row.count >= 3, let symbol = Self.unquote(row[2]) else { return nil }
            return SpecIconRow(label: row[0], state: Self.unquote(row[1]), symbol: symbol)
        }
    }

    /// S22 のはじめにの項目（表の順）。
    public func onboardingSteps() throws -> [SpecOnboardingStep] {
        try rows(of: .onboarding).compactMap { row -> SpecOnboardingStep? in
            guard row.count >= 4, let step = Self.unquote(row[2]) else { return nil }
            return SpecOnboardingStep(mark: row[0], title: row[1], step: step)
        }
    }

    /// S23 の ui-state.json の鍵（表の順）。
    public func uiStateKeys() throws -> [SpecJSONKey] {
        try rows(of: .uiState).compactMap { row -> SpecJSONKey? in
            guard row.count >= 3, let key = Self.unquote(row[0]) else { return nil }
            return SpecJSONKey(key: key, type: row[1], value: row[2])
        }
    }
}
