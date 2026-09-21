// device_id（= /Volumes 直下の名前）の健全性（PLAN §4.2）。
import Foundation

public enum DeviceID {
    /// 空・"/" を含む・":" を含む・"." で始まる・制御文字（U+0000〜U+001F, U+007F）を含む → 偽。空白は可（"NO NAME"）。
    public static func isValid(_ id: String) -> Bool {
        if id.isEmpty { return false }
        if id.hasPrefix(".") { return false }
        for scalar in id.unicodeScalars {
            if scalar == "/" || scalar == ":" { return false }
            if scalar.value <= 0x1F || scalar.value == 0x7F { return false }
        }
        return true
    }
}
