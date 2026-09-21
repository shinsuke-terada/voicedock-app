// 照合済みのモデルの SHA-256 のメモリ上の記録（PLAN §8.10）。
import Foundation

/// 照合済みのモデルの SHA-256 を覚える（PLAN §8.10）。(path, inode, size, mtime) が変わっていなければ照合を飛ばせる。メモリだけ（何も書かない。診断が使う）。
public actor ModelVerificationCache {
    private var entries: [String: (inode: UInt64, size: Int64, mtime: Double, sha256: String)] = [:]

    public init() {}

    /// 4 つが全部一致したときだけ sha256 を返す。
    public func verifiedSHA256(path: String, inode: UInt64, size: Int64, mtime: Double) -> String? {
        guard let entry = entries[path], entry.inode == inode, entry.size == size, entry.mtime == mtime else {
            return nil
        }
        return entry.sha256
    }

    /// 上書き。
    public func record(path: String, inode: UInt64, size: Int64, mtime: Double, sha256: String) {
        entries[path] = (inode: inode, size: size, mtime: mtime, sha256: sha256)
    }
}
