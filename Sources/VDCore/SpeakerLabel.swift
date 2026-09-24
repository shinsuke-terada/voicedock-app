// 話者のラベルと表示（PLAN §8.4.1。F-89）。ラベルの規則を 1 か所に置く（CR-06）。
import Foundation

public enum SpeakerLabel {
    /// 表示の前置き（`話者A`）。
    public static let prefix = "話者"

    /// 0→"A" … 25→"Z"、26 以上→"S<index+1>"（27 人目は "S27"）。負は "A"。
    public static func label(index: Int) -> String {
        if index < 26 { return String(UnicodeScalar(UInt8(65 + max(0, index)))) }
        return "S\(index + 1)"
    }

    /// `話者` + label
    public static func display(_ label: String) -> String { prefix + label }
}
