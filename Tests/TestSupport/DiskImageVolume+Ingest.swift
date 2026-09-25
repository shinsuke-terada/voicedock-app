// T-07 の DiskImageVolume への extension（T-15。00-api-map §15）。.diskImage のテスト専用。
import Foundation
import VDDevice

extension DiskImageVolume {
    static let uniqueNameAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// 実機と重ならないボリューム名 "VDT" + 4 桁（A–Z・0–9 から SystemRandomNumberGenerator で選ぶ）
    public static func uniqueName() -> String {
        var generator = SystemRandomNumberGenerator()
        var name = "VDT"
        for _ in 0..<4 {
            if let character = uniqueNameAlphabet.randomElement(using: &generator) { name.append(character) }
        }
        return name
    }

    /// SystemMountInspector().mountInfo(path: mountPoint の path)?.mountFromName（例 "/dev/disk7"）
    public var node: String? {
        SystemMountInspector().mountInfo(path: mountPoint.path(percentEncoded: false))?.mountFromName
    }
}
