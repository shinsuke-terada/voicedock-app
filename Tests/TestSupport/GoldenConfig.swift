// golden の入力の timeZone と overrides から AppConfig を作る（PLAN §10.4。規約は T-25、実装は T-09）。
import Foundation
import VDCore

/// golden のケースの設定。`AppConfig.defaults(timeZone:)` に `overrides` を JSON のキーパスで当てる。
public enum GoldenConfig {
    public enum Failure: Error, Equatable {
        case notAnObject
        case missingPath(String)
        case undecodable(String)
    }

    public static func make(_ item: GoldenCase) throws -> AppConfig {
        let base = AppConfig.defaults(timeZone: try item.string("timeZone"))
        guard var root = try JSONSerialization.jsonObject(with: ConfigLoader.encode(base)) as? [String: Any] else {
            throw Failure.notAnObject
        }
        for (key, value) in try item.overrides() {
            try set(&root, path: key.split(separator: ".").map(String.init)[...], value: value.foundationObject)
        }
        let data = try JSONSerialization.data(withJSONObject: root)
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw Failure.undecodable(item.testDescription)
        }
    }

    /// 途中のキーは既定の設定に在るオブジェクトでなければならない。最後のキーは無くてもよい（null を省く符号化のため）。
    static func set(_ object: inout [String: Any], path: ArraySlice<String>, value: Any) throws {
        guard let key = path.first else {
            throw Failure.missingPath("")
        }
        if path.count == 1 {
            object[key] = value
            return
        }
        guard var child = object[key] as? [String: Any] else {
            throw Failure.missingPath(path.joined(separator: "."))
        }
        try set(&child, path: path.dropFirst(), value: value)
        object[key] = child
    }
}
