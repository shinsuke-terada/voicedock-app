// config.json の schemaVersion の移行（PLAN §6.1）。v1 は「1 ならそのまま」だけ。
import Foundation

public enum ConfigMigrator {
    public static let currentVersion = 1

    /// v1 は「1 ならそのまま」だけ（PLAN §6.1）。
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
        return .failure(violation("不正な schemaVersion（\(version)）"))
    }

    private static func violation(_ message: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: "schemaVersion", message: message)
    }
}
