// config.json の schemaVersion の移行（PLAN §6.1）。2 はそのまま、1 は diarization を足して 2 にする（F-89）。
import Foundation

public enum ConfigMigrator {
    public static let currentVersion = 2

    /// 2 はそのまま、1 は `transcription.diarization` を足して 2 にする（PLAN §6.1。F-89）。ファイルは書き換えない。
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
        if version == 1 {
            var object = object
            // transcription が辞書で diarization を持たなければ既定（無効）を入れる。辞書でなければ CV-39 に任せる
            if var transcription = object["transcription"] as? [String: Any], transcription["diarization"] == nil {
                transcription["diarization"] = ["enabled": false]
                object["transcription"] = transcription
            }
            object["schemaVersion"] = currentVersion
            return .success(object)
        }
        if version > currentVersion {
            return .failure(violation("この版のアプリより新しい設定です（schemaVersion \(version)）。アプリを更新してください"))
        }
        return .failure(violation("不正な schemaVersion（\(version)）"))
    }

    private static func violation(_ message: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: "schemaVersion", message: message)
    }
}
