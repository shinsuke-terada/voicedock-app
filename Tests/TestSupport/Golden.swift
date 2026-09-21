// golden（voicedock@d3d595e の出力）の入力と期待値を読む（PLAN §10.4、T-25）。
import Foundation
import Testing

/// golden の読み込みで起きる誤り（テストの準備の誤り。期待値の不一致ではない）。
public enum GoldenError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case malformedInput(String)
    case noSuchCase(group: String, name: String)
    case expectedMissing(group: String, name: String)
    case expectedAmbiguous(group: String, name: String)
    case missingKey(group: String, name: String, key: String)
    case typeMismatch(group: String, name: String, key: String, expected: String)

    public var description: String {
        switch self {
        case .unreadable(let path): return "golden を読めません: \(path)"
        case .malformedInput(let path): return "golden の入力の形が不正です: \(path)"
        case .noSuchCase(let group, let name): return "golden のケースがありません: \(group)/\(name)"
        case .expectedMissing(let group, let name): return "golden の期待値がありません: \(group)/\(name)"
        case .expectedAmbiguous(let group, let name): return "golden の期待値が 2 つ以上あります: \(group)/\(name)"
        case .missingKey(let group, let name, let key): return "golden の入力に \(key) がありません: \(group)/\(name)"
        case .typeMismatch(let group, let name, let key, let expected):
            return "golden の入力の \(key) が \(expected) ではありません: \(group)/\(name)"
        }
    }
}

/// golden の 1 ケース（`Tests/Golden/inputs/<group>.json` の `cases` の 1 要素）。
public struct GoldenCase: Sendable, CustomTestStringConvertible {
    public let group: String
    public let name: String
    public let fields: [String: GoldenJSON]

    public var testDescription: String { "\(group)/\(name)" }

    public subscript(_ key: String) -> GoldenJSON? { fields[key] }

    public func value(_ key: String) throws -> GoldenJSON {
        guard let value = fields[key] else {
            throw GoldenError.missingKey(group: group, name: name, key: key)
        }
        return value
    }

    public func string(_ key: String) throws -> String {
        guard let text = try value(key).stringValue else { throw mismatch(key, "文字列") }
        return text
    }

    // orderedObject(_:)（キーの順を保ったオブジェクト）は **本チケットには書かない**。`PyJSONValue` を使うので
    // T-45 が `Tests/TestSupport/GoldenCase+PyJSON.swift` の extension で足す（`GoldenCase` 自体は VDCore に依存しない）。

    /// null なら nil。
    public func optionalString(_ key: String) throws -> String? {
        let json = try value(key)
        if json.isNull { return nil }
        guard let text = json.stringValue else { throw mismatch(key, "文字列か null") }
        return text
    }

    public func int(_ key: String) throws -> Int {
        guard let integer = try value(key).intValue else { throw mismatch(key, "整数") }
        return integer
    }

    public func double(_ key: String) throws -> Double {
        guard let number = try value(key).doubleValue else { throw mismatch(key, "数") }
        return number
    }

    /// null なら nil。
    public func optionalDouble(_ key: String) throws -> Double? {
        let json = try value(key)
        if json.isNull { return nil }
        guard let number = json.doubleValue else { throw mismatch(key, "数か null") }
        return number
    }

    public func bool(_ key: String) throws -> Bool {
        guard let flag = try value(key).boolValue else { throw mismatch(key, "真偽値") }
        return flag
    }

    public func array(_ key: String) throws -> [GoldenJSON] {
        guard let items = try value(key).arrayValue else { throw mismatch(key, "配列") }
        return items
    }

    public func strings(_ key: String) throws -> [String] {
        let items = try array(key)
        let texts = items.compactMap(\.stringValue)
        guard texts.count == items.count else { throw mismatch(key, "文字列の配列") }
        return texts
    }

    public func object(_ key: String) throws -> [String: GoldenJSON] {
        guard let pairs = try value(key).objectValue else { throw mismatch(key, "オブジェクト") }
        return pairs
    }

    /// 設定の上書き（`overrides` の各キーと値。キーの昇順）。許されないキーがあれば誤り。
    /// キーは AppConfig の JSON のキーパス（`obsidian.raw.timestampIntervalSeconds` など。PLAN §6.2）。
    public func overrides() throws -> [(key: String, value: GoldenJSON)] {
        guard let pairs = fields["overrides"]?.objectValue else {
            return []
        }
        for key in pairs.keys where !Golden.isAllowedOverride(key) {
            throw mismatch("overrides." + key, "許された設定の上書き")
        }
        return pairs.map { (key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
    }

    func mismatch(_ key: String, _ expected: String) -> GoldenError {
        GoldenError.typeMismatch(group: group, name: name, key: key, expected: expected)
    }
}

/// golden の入力と期待値。
///
/// - 入力: `Tests/Golden/inputs/<group>.json`（`{"schema": 1, "group": <group>, "cases": [{"name": …}, …]}`）
/// - 期待値: `Tests/Golden/expected/<group>/<name>.<ext>`。`.md` / `.out` はバイト列、`.json` は値で比べる
public enum Golden {
    /// バイト列で比べる期待値の拡張子。
    public static let byteExtensions: Set<String> = ["md", "out"]
    /// 値で比べる期待値の拡張子。
    public static let jsonExtension = "json"

    /// golden の入力で上書きしてよい設定のキー（tools/golden/generate.py の ALLOWED_OVERRIDES と同じ）。
    public static let allowedOverrideKeys: Set<String> = [
        "obsidian.maxTitleBytes", "obsidian.defaultTags", "obsidian.raw.folderTemplate",
        "obsidian.raw.filenameTemplate", "obsidian.raw.timestampIntervalSeconds", "obsidian.raw.partBoundaryHeading",
        "obsidian.wiki.folderTemplate", "obsidian.wiki.filenameTemplate", "obsidian.wiki.linkDailyNote",
        "obsidian.wiki.linkAdjacentDays", "obsidian.wiki.linkTags", "obsidian.wiki.linkOnlyExisting",
        "obsidian.wiki.maxLinks", "llm.maxCharsPerRequest", "llm.maxSecondsPerRequest", "llm.chunkOverlapChars",
        "llm.analysis.order", "llm.analysis.customInstructions", "session.blockGapSeconds",
    ]
    /// `llm.analysis.sections.<節>.<項目>` の上書きで許す節と項目。
    public static let overridableSections: Set<String> = [
        "summary", "timeline", "key_points", "tasks", "decisions", "ideas", "tags",
    ]
    public static let overridableSectionFields: Set<String> = ["enabled", "heading", "maxItems"]
    /// `maxItems` を持つ節（PLAN §6.2・付録 F の F-54。`summary` / `timeline` には無い）。
    public static let sectionsWithMaxItems: Set<String> = [
        "key_points", "tasks", "decisions", "ideas", "tags",
    ]

    public static func isAllowedOverride(_ key: String) -> Bool {
        if allowedOverrideKeys.contains(key) {
            return true
        }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "llm", parts[1] == "analysis", parts[2] == "sections",
            overridableSections.contains(parts[3]), overridableSectionFields.contains(parts[4])
        else {
            return false
        }
        // summary / timeline に maxItems は無い（書けば CV-01。PLAN §6.2・F-54）。
        return parts[4] != "maxItems" || sectionsWithMaxItems.contains(parts[3])
    }

    public static var root: URL { PackageRoot.file("Tests/Golden") }
    public static var inputsDirectory: URL { root.appendingPathComponent("inputs", isDirectory: true) }
    public static var expectedDirectory: URL { root.appendingPathComponent("expected", isDirectory: true) }

    /// 入力のあるグループの名前（ファイル名の昇順）。
    public static func groupNames() throws -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: inputsDirectory.path)
        } catch {
            throw GoldenError.unreadable(inputsDirectory.path)
        }
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// そのグループの全ケース（入力の順）。
    public static func cases(_ group: String) throws -> [GoldenCase] {
        let url = inputsDirectory.appendingPathComponent("\(group).json")
        guard let data = try? Data(contentsOf: url) else {
            throw GoldenError.unreadable(url.path)
        }
        let document: GoldenJSON
        do {
            document = try JSONDecoder().decode(GoldenJSON.self, from: data)
        } catch {
            throw GoldenError.malformedInput(url.path)
        }
        guard let top = document.objectValue, top["schema"]?.intValue == 1, top["group"]?.stringValue == group,
            let items = top["cases"]?.arrayValue
        else {
            throw GoldenError.malformedInput(url.path)
        }
        var result: [GoldenCase] = []
        for item in items {
            guard let fields = item.objectValue, let name = fields["name"]?.stringValue else {
                throw GoldenError.malformedInput(url.path)
            }
            result.append(GoldenCase(group: group, name: name, fields: fields))
        }
        return result
    }

    /// 名前で 1 ケースを引く。
    public static func testCase(_ group: String, _ name: String) throws -> GoldenCase {
        guard let found = try cases(group).first(where: { $0.name == name }) else {
            throw GoldenError.noSuchCase(group: group, name: name)
        }
        return found
    }

    /// 期待値のファイル（`<name>.md` / `.out` / `.json` のちょうど 1 つ）。
    public static func expectedFile(_ group: String, _ name: String) throws -> URL {
        let directory = expectedDirectory.appendingPathComponent(group, isDirectory: true)
        let candidates = (byteExtensions.sorted() + [jsonExtension]).map {
            directory.appendingPathComponent("\(name).\($0)")
        }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = existing.first else {
            throw GoldenError.expectedMissing(group: group, name: name)
        }
        guard existing.count == 1 else {
            throw GoldenError.expectedAmbiguous(group: group, name: name)
        }
        return first
    }

    public static func expectedBytes(_ group: String, _ name: String) throws -> Data {
        let url = try expectedFile(group, name)
        guard let data = try? Data(contentsOf: url) else {
            throw GoldenError.unreadable(url.path)
        }
        return data
    }

    public static func expectedJSON(_ group: String, _ name: String) throws -> GoldenJSON {
        let url = try expectedFile(group, name)
        guard url.pathExtension == jsonExtension, let data = try? Data(contentsOf: url) else {
            throw GoldenError.unreadable(url.path)
        }
        do {
            return try JSONDecoder().decode(GoldenJSON.self, from: data)
        } catch {
            throw GoldenError.unreadable(url.path)
        }
    }
}
