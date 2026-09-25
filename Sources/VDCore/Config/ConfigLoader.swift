// config.json の読み込み（4 段）と書き出し（PLAN §6.1）。違反は例外にせず `ConfigLoadResult.invalid` で返す。
import Foundation
import VDContract

public enum ConfigLoader {
    /// ファイル全体の違反の keyPath（`ConfigViolation.keyPath`）。F-83: ConfigStore も使う 1 か所（CR-06）
    public static let fileKeyPath = "<file>"

    /// PLAN §6.1 の読み込みの手順（JSON・移行・キー照合・型・意味の検証）。段ごとに違反があればそこで止め、意味の検証だけは全 CV を評価する。
    public static func load(data: Data, catalog: ModelCatalog, reaperConfObservation: ReaperConfObservation)
        -> ConfigLoadResult
    {
        let structure = decodeStructure(data: data)
        guard case .valid(let config) = structure else { return structure }
        let violations = ConfigValidator.validate(
            config, catalog: catalog, reaperConfObservation: reaperConfObservation)
        return violations.isEmpty ? .valid(config) : .invalid(violations)
    }

    /// PLAN §6.1 の読み込みの手順 1〜3（JSON・移行・キー照合・型）だけ。`.valid` は「構造が正しい」で、**意味の検証（CV）はしていない**。
    /// F-83: `ConfigStore` が書く前に今の config.json を読み直すとき・CV-30 の修復で読むときも、load と同じこの厳密な経路で読む（CR-06）
    public static func decodeStructure(data: Data) -> ConfigLoadResult {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return .invalid([fileViolation("JSON として読めません")])
        }
        guard let dict = parsed as? [String: Any] else {
            return .invalid([fileViolation("JSON のオブジェクトではありません")])
        }
        let migrated: [String: Any]
        switch ConfigMigrator.migrate(dict) {
        case .failure(let violation): return .invalid([violation])
        case .success(let object): migrated = object
        }
        var keyViolations: [ConfigViolation] = []
        checkKeys(migrated, prefix: "", into: &keyViolations)
        if !keyViolations.isEmpty {
            return .invalid(keyViolations)
        }
        // 今の版なら移行は値を変えないので元の data を、旧版からの移行（1 → 2 → 3。F-89・F-92）で値を足したときは移行後の値を復号する。
        // 移行した値はメモリの上だけで、ファイルは書き換えない（PLAN §6.1）。
        let source: Data
        if (dict["schemaVersion"] as? NSNumber)?.intValue == ConfigMigrator.currentVersion {
            source = data
        } else if let migratedData = try? JSONSerialization.data(withJSONObject: migrated) {
            source = migratedData
        } else {
            return .invalid([fileViolation("読めません")])
        }
        do {
            return .valid(try JSONDecoder().decode(AppConfig.self, from: source))
        } catch let error as DecodingError {
            return .invalid([decodingViolation(error, object: migrated)])
        } catch {
            return .invalid([
                ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: fileKeyPath, message: "読めません")
            ])
        }
    }

    /// config.json の書き出し。JSONEncoder（[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]）＋ 末尾 "\n"。
    /// F-83: 符号化できなければ投げる（以前は空の Data を返し、呼び手がそれを config.json に書いた）。
    public static func encode(_ config: AppConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(config)
        data.append(contentsOf: Array("\n".utf8))
        return data
    }

    /// キー集合の照合（全階層）。未知のキー・型（昇順、子の再帰を含む）→ 欠けたキー（昇順）の順に積む。
    static func checkKeys(_ object: [String: Any], prefix: String, into violations: inout [ConfigViolation]) {
        let expected = ConfigKeys.children(of: prefix)
        for key in object.keys.sorted() {
            let path = prefix.isEmpty ? key : prefix + "." + key
            if !expected.contains(key) {
                violations.append(
                    ConfigViolation(rule: "CV-01", code: .configUnknownKey, keyPath: path, message: "未知のキーです"))
                continue
            }
            if ConfigKeys.isObject(path) {
                guard let child = object[key] as? [String: Any] else {
                    violations.append(
                        ConfigViolation(
                            rule: "CV-39", code: .configInvalidValue, keyPath: path, message: "オブジェクトであること"))
                    continue
                }
                checkKeys(child, prefix: path, into: &violations)
            }
        }
        // JSON の null は NSNull なので「在る」。
        for key in expected.sorted() where object[key] == nil {
            violations.append(
                ConfigViolation(
                    rule: "CV-39", code: .configInvalidValue, keyPath: prefix.isEmpty ? key : prefix + "." + key,
                    message: "キーがありません"))
        }
    }

    /// `DecodingError` を 1 件の違反（CV-39）に写す。
    /// JSONDecoder は整数の位置の `1.5` を codingPath の空の `dataCorrupted` で報告するので、そのときだけ
    /// `unrepresentableNumberPath(in:)` でキーのパスを補う（PLAN §6.1「型違い → CV-39、キーのパスを添える」）。
    static func decodingViolation(_ error: DecodingError, object: [String: Any]) -> ConfigViolation {
        let codingPath: [CodingKey]
        var message: String
        switch error {
        case .typeMismatch(_, let context):
            codingPath = context.codingPath
            message = "型が違います"
        case .valueNotFound(_, let context):
            codingPath = context.codingPath
            message = "null にできません"
        case .keyNotFound(let key, let context):
            codingPath = context.codingPath + [key]
            message = "キーがありません"
        case .dataCorrupted(let context):
            codingPath = context.codingPath
            message = "値が不正です"
        @unknown default:
            codingPath = []
            message = "読めません"
        }
        var joined = codingPath.map { key in key.intValue.map { String($0) } ?? key.stringValue }
            .joined(separator: ".")
        if joined.isEmpty, case .dataCorrupted = error, let path = unrepresentableNumberPath(in: object) {
            // 整数の位置の小数（1.5 など）は型違いと同じ表示にする（利用者の判断。2026-09-21）
            joined = path
            message = "型が違います"
        }
        return ConfigViolation(
            rule: "CV-39", code: .configInvalidValue, keyPath: joined.isEmpty ? fileKeyPath : joined, message: message)
    }

    /// 整数の位置に置かれた整数でない数（`1.5` など）のキーのパス（配列の要素は末尾に添字）。`allKeyPaths` の順で最初のもの。
    /// 整数の位置かどうかは、既定値の JSON の同じ位置に `1.5` を置いて復号できないことで判定する（型を 2 か所に書かない）。
    static func unrepresentableNumberPath(in object: [String: Any]) -> String? {
        for keyPath in ConfigKeys.allKeyPaths {
            let parts = keyPath.split(separator: ".").map(String.init)
            guard let value = leaf(object, parts) else { continue }
            let elements: [(String, Any)] =
                (value as? [Any]).map { items in
                    items.enumerated().map { (keyPath + "." + String($0.offset), $0.element) }
                }
                ?? [(keyPath, value)]
            for (path, element) in elements where isNonIntegralNumber(element) {
                if !acceptsFraction(parts, inArray: value is [Any]) { return path }
            }
        }
        return nil
    }

    private static func leaf(_ object: [String: Any], _ parts: [String]) -> Any? {
        var current: Any = object
        for key in parts {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    private static func isNonIntegralNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            CFNumberIsFloatType(number)
        else { return false }
        return Int(exactly: number.doubleValue) == nil
    }

    /// 既定値の JSON のその位置に `1.5`（配列なら `[1.5]`）を置いて、`AppConfig` に復号できるか。
    private static func acceptsFraction(_ parts: [String], inArray: Bool) -> Bool {
        guard
            var root = try? JSONSerialization.jsonObject(with: encode(AppConfig.defaults(timeZone: "UTC")))
                as? [String: Any]
        else { return false }
        let probe: Any = inArray ? [1.5] : 1.5
        func put(_ dict: inout [String: Any], _ rest: ArraySlice<String>) {
            guard let key = rest.first else { return }
            if rest.count == 1 {
                dict[key] = probe
                return
            }
            var child = dict[key] as? [String: Any] ?? [:]
            put(&child, rest.dropFirst())
            dict[key] = child
        }
        put(&root, parts[...])
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return false }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) != nil
    }

    private static func fileViolation(_ message: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: fileKeyPath, message: message)
    }
}
