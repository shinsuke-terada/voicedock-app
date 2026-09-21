// デバイス上の relpath の健全性と結合（PLAN §4.3。RV-08 とアプリの事前確認で共有）。
import Foundation

public enum RelPath {
    public static let maxUTF8Bytes = 1024

    /// 生の文字列を "/" で分割して（空要素を省かない）検査する。1 つでも当たれば偽:
    /// 空文字 / "/" で始まる / 空要素（"//"・末尾の "/"）/ 要素が "." か ".." / 要素が "." で始まる /
    /// 制御文字（U+0000〜U+001F, U+007F）/ "\" を含む / UTF-8 で 1024 バイト超。
    ///
    /// voicedock の `is_safe_relpath` より厳しい。voicedock は `PurePosixPath` で正規化してから見ていたので
    /// `./a.wav` と `a//b.wav` を真にしていたが、ここでは生の文字列のまま見るのでどちらも偽になる。
    public static func isSafe(_ relpath: String) -> Bool {
        if relpath.isEmpty { return false }
        if relpath.hasPrefix("/") { return false }
        if relpath.utf8.count > maxUTF8Bytes { return false }
        for scalar in relpath.unicodeScalars {
            if scalar.value <= 0x1F || scalar.value == 0x7F { return false }
            if scalar == "\\" { return false }
        }
        for component in components(relpath) {
            if component.isEmpty { return false }
            if component == "." || component == ".." { return false }
            if component.hasPrefix(".") { return false }
        }
        return true
    }

    /// `relpath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)`
    public static func components(_ relpath: String) -> [String] {
        relpath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    /// components を "/" でつなぐ（検査しない。relpath の組み立てはこれだけで行う。PT-06）
    public static func join(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    /// 最後の要素を除いた部分（1 要素なら ""）
    public static func parent(_ relpath: String) -> String {
        join(Array(components(relpath).dropLast()))
    }

    /// 最後の要素（`components(relpath).last ?? ""`）
    public static func lastComponent(_ relpath: String) -> String {
        components(relpath).last ?? ""
    }
}
