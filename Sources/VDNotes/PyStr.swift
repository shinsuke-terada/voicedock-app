// Python の str() と同じ文字列化（frontmatter の鍵・timeline の行で使う）。YAML（Yams）と PyJSON.parse（T-45）の Foundation の値を受ける。
import Foundation
import VDCore

enum PyStr {
    /// 判定の順は String → Bool → 整数 → 浮動小数 → None → それ以外（Bool を整数より先に見る）。
    static func describe(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return "None" }
            return describe(child.value)
        }
        if let text = value as? String {
            return text
        }
        if PyJSON.isBool(value), let flag = value as? Bool {
            return flag ? "True" : "False"
        }
        if let number = value as? NSNumber {
            if CFNumberIsFloatType(number as CFNumber) {
                return float(number.doubleValue)
            }
            return String(number.int64Value)
        }
        if value is NSNull {
            return "None"
        }
        return String(describing: value)
    }

    /// Python の `str(float)`。有限なら repr（`PyJSON.formatDouble`）、非有限は `nan` / `inf` / `-inf`。
    static func float(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        return PyJSON.formatDouble(value)
    }
}
