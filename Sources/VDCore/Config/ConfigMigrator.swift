// config.json の schemaVersion の移行（PLAN §6.1）。3 はそのまま、1 → 2 → 3 と 1 段ずつ上げる（F-89・F-92）。
import Foundation

public enum ConfigMigrator {
    public static let currentVersion = 3

    /// 3 はそのまま。1 は `transcription.diarization` を足して 2 に（F-89）、2 は `llm.analysis.prompts` を足して 3 にする
    /// （F-92）。1 段ずつ続けて上げる（PLAN §6.1）。ファイルは書き換えない。
    public static func migrate(_ object: [String: Any]) -> Result<[String: Any], ConfigViolation> {
        guard let value = object["schemaVersion"] else {
            return .failure(violation("キーがありません"))
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(number)
        else {
            return .failure(violation("整数であること"))
        }
        let version = number.intValue
        if version == currentVersion {
            return .success(object)
        }
        if version > currentVersion {
            return .failure(violation("この版のアプリより新しい設定です（schemaVersion \(version)）。アプリを更新してください"))
        }
        guard version >= 1 else {
            return .failure(violation("不正な schemaVersion（\(version)）"))
        }
        var object = object
        if version <= 1 {
            object = addDiarization(object)
        }
        if version <= 2 {
            object = addPrompts(object)
        }
        object["schemaVersion"] = currentVersion
        return .success(object)
    }

    /// 1 → 2（F-89）: transcription が辞書で diarization を持たなければ既定（無効）を入れる。辞書でなければ CV-39 に任せる
    private static func addDiarization(_ object: [String: Any]) -> [String: Any] {
        var object = object
        if var transcription = object["transcription"] as? [String: Any], transcription["diarization"] == nil {
            transcription["diarization"] = ["enabled": false]
            object["transcription"] = transcription
        }
        return object
    }

    /// 2 → 3（F-92）: llm.analysis が辞書で prompts を持たなければ既定（3 つとも null）を入れる。辞書でなければ CV-39 に任せる
    private static func addPrompts(_ object: [String: Any]) -> [String: Any] {
        var object = object
        if var llm = object["llm"] as? [String: Any], var analysis = llm["analysis"] as? [String: Any],
            analysis["prompts"] == nil
        {
            analysis["prompts"] = ["analyze": NSNull(), "map": NSNull(), "reduce": NSNull()]
            llm["analysis"] = analysis
            object["llm"] = llm
        }
        return object
    }

    private static func violation(_ message: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: "schemaVersion", message: message)
    }
}
