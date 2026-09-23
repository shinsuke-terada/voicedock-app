// device_id（= /Volumes 直下の名前）の健全性（PLAN §4.2）。
import Foundation

public enum DeviceID {
    /// 空・"/" を含む・":" を含む・"." で始まる・制御文字（U+0000〜U+001F, U+007F）を含む → 偽。空白は可（"NO NAME"）。
    /// どれも Unicode スカラーで見る。「"." で始まる」を Character（書記素）で見ると、"." の直後に結合文字（U+0301 など）が
    /// 来たときに一致しない（F-81。RelPath と同じ。F-73）
    public static func isValid(_ id: String) -> Bool {
        if id.isEmpty { return false }
        if id.unicodeScalars.first == "." { return false }
        for scalar in id.unicodeScalars {
            if scalar == "/" || scalar == ":" { return false }
            if scalar.value <= 0x1F || scalar.value == 0x7F { return false }
        }
        return true
    }
}
