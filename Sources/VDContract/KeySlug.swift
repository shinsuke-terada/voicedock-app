// key_slug = sha256(key の UTF-8) の 16 進の先頭 16 文字（PLAN §4.2）。
import CryptoKit
import Foundation

public enum KeySlug {
    /// CryptoKit の SHA256.hash(data: Data(key.utf8)) を小文字 16 進にし、先頭 16 文字。
    public static func of(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
