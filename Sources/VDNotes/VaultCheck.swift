// Vault の確認（PLAN §8.7 手順 0 / DEL-06）。ガード・Raw・Daily・診断・削除条件が共有する唯一の判定関数。Vault のルートを作らない。
import Foundation
import VDCore

public enum VaultStatus: Equatable, Sendable {
    case notConfigured
    case missingRoot
    case notReadable(errno: Int32)
    case missingMarker
    case available

    /// self == .available
    public var isAvailable: Bool { self == .available }

    /// 利用者に見せる 1 行（括弧は全角。path は渡された文字列のまま）
    public func message(path: String, marker: String) -> String {
        switch self {
        case .notConfigured:
            return "Vault が選ばれていません"
        case .missingRoot:
            return path + " がありません"
        case .notReadable(let code):
            return path + " を読めません（errno " + String(code) + "）"
        case .missingMarker:
            return path + " に " + marker + "/ がありません（Vault が未マウントか、別の場所を指しています）"
        case .available:
            return ""
        }
    }
}

public enum VaultCheck {
    /// 最初に当たった状態を返す。書き込みの権限は見ない（DR-10 は T-32）。ファイルもフォルダも作らない（NOTE-16）。
    public static func evaluate(path: String?, marker: String) -> VaultStatus {
        guard let path else { return .notConfigured }
        var st = stat()
        if stat(path, &st) != 0 {
            let code = errno
            if code == EPERM || code == EACCES {
                return .notReadable(errno: code)
            }
            return .missingRoot
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            return .missingRoot
        }
        // EPERM は TCC（書類フォルダ・iCloud Drive の Vault で起こる）
        guard let dir = opendir(path) else {
            return .notReadable(errno: errno)
        }
        closedir(dir)
        // X-18: 空の目印で検査を無効にしない（CV-41 が弾くが、ここでも fail-closed）
        if PyText.strip(marker).unicodeScalars.isEmpty || marker.unicodeScalars.contains("/")
            || PyText.scalarsEqual(marker, ".") || PyText.scalarsEqual(marker, "..")
        {
            return .missingMarker
        }
        let markerPath = URL(fileURLWithPath: path).appendingPathComponent(marker, isDirectory: false)
            .path(percentEncoded: false)
        var markerStat = stat()
        if stat(markerPath, &markerStat) != 0 || (markerStat.st_mode & S_IFMT) != S_IFDIR {
            return .missingMarker
        }
        return .available
    }
}
