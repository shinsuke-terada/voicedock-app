// partkey の組み立てと分解。partkey を作るのはここだけ（PLAN §4.2、PT-06）。
import Foundation

public enum PartKey {
    /// 期待値を書き換えて通すな。規則を変えると、それ以前に保存した録音が永久に削除対象外になる（DEL-01、RK-27）。
    ///
    /// 1. DeviceID.isValid が偽 → throw .invalidDeviceID
    /// 2. RelPath.isSafe が偽 → throw .unsafeRelpath
    /// 3. "\(deviceID)/\(relpath)"
    public static func make(deviceID: String, relpath: String) throws(KeyError) -> String {
        guard DeviceID.isValid(deviceID) else { throw .invalidDeviceID }
        guard RelPath.isSafe(relpath) else { throw .unsafeRelpath }
        return "\(deviceID)/\(relpath)"
    }

    /// 最初の "/" より前。"/" が無い・前が空なら nil。
    /// "/" は Unicode スカラー（UTF-8 の 0x2F）で探す。Character（書記素）で探すと、relpath が結合文字（U+0301 など）で
    /// 始まるときに "/" を見落とし、make で作った partkey を別の位置で分ける（F-81。RelPath と同じ。F-73）
    public static func deviceID(of partkey: String) -> String? {
        let scalars = partkey.unicodeScalars
        guard let slash = scalars.firstIndex(of: "/") else { return nil }
        let head = scalars[..<slash]
        return head.isEmpty ? nil : String(Substring(head))
    }

    /// 最初の "/"（Unicode スカラー。deviceID(of:) と同じ）より後。"/" が無い・後が空なら nil
    public static func relpath(of partkey: String) -> String? {
        let scalars = partkey.unicodeScalars
        guard let slash = scalars.firstIndex(of: "/") else { return nil }
        let tail = scalars[scalars.index(after: slash)...]
        return tail.isEmpty ? nil : String(Substring(tail))
    }
}
