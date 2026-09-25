// デバイス上の relpath の健全性と結合（PLAN §4.3。RV-08 とアプリの事前確認で共有）。
import Foundation

public enum RelPath {
    public static let maxUTF8Bytes = 1024

    /// 生の文字列を Unicode スカラーの "/"（UTF-8 の 0x2F）で分割して（空要素を省かない）検査する。1 つでも当たれば偽:
    /// 空文字 / "/" で始まる / 空要素（"//"・末尾の "/"）/ 要素が "." か ".." / 要素が "." で始まる /
    /// 制御文字（U+0000〜U+001F, U+007F）/ "\" を含む / UTF-8 で 1024 バイト超。
    ///
    /// 「"/" で始まる」「"." で始まる」も先頭のスカラーで見る。Character（書記素）で見ると、"/" や "." の直後に
    /// 結合文字（U+0301 など）が来たときに一致しない（F-73）。
    ///
    /// voicedock の `is_safe_relpath` より厳しい。voicedock は `PurePosixPath` で正規化してから見ていたので
    /// `./a.wav` と `a//b.wav` を真にしていたが、ここでは生の文字列のまま見るのでどちらも偽になる。
    public static func isSafe(_ relpath: String) -> Bool {
        if relpath.isEmpty { return false }
        if relpath.unicodeScalars.first == "/" { return false }
        if relpath.utf8.count > maxUTF8Bytes { return false }
        for scalar in relpath.unicodeScalars {
            if scalar.value <= 0x1F || scalar.value == 0x7F { return false }
            if scalar == "\\" { return false }
        }
        for component in components(relpath) {
            if component.isEmpty { return false }
            // "." と ".." もここで当たる
            if component.unicodeScalars.first == "." { return false }
        }
        return true
    }

    /// Unicode スカラーの "/"（UTF-8 の 0x2F）で分割する。空要素を省かない。
    /// カーネルと同じ区切り方（"/" の直後に結合文字が来ても区切る。F-73）。ASCII の入力では
    /// `relpath.split(separator: "/", omittingEmptySubsequences: false)` と同じ結果になる
    public static func components(_ relpath: String) -> [String] {
        relpath.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map { String(Substring($0)) }
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
