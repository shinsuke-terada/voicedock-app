// inbox の中身を数える（読むだけ。DR-15 と状態の詳細が共有する。#120。voicedock status.py:424-467）。
import Darwin
import Foundation
import VDContract

/// inbox の処理待ちと取り残しの件数とバイト数。
public struct InboxCounts: Equatable, Sendable {
    public let pendingCount: Int
    public let pendingBytes: Int64
    public let leftoverCount: Int
    public let leftoverBytes: Int64

    public static let empty = InboxCounts(pendingCount: 0, pendingBytes: 0, leftoverCount: 0, leftoverBytes: 0)
}

/// inbox の中身を数える（何も書かない）。取り残しの判定は DR-15 と状態の詳細でこの 1 か所（#120）。
public enum InboxScan {
    /// relativePaths は DB の inbox_path（<HOME> からの相対）。存在する通常ファイルだけを数える。
    public static func leftovers(layout: HomeLayout, relativePaths: [String]) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for rel in relativePaths {
            guard let size = regularFileSize(layout.url(relative: rel)) else { continue }
            count += 1
            bytes += size
        }
        return (count, bytes)
    }

    /// inbox 配下の *.wav を再帰で数え、leftovers に当たるものを除いたものを「処理待ち」にする。
    /// 名前が規則に合わないファイルも「ディスクは使っている」ので処理待ちに数える（voicedock と同じ）。
    public static func counts(layout: HomeLayout, leftoverRelativePaths: [String]) -> InboxCounts {
        let left = leftovers(layout: layout, relativePaths: leftoverRelativePaths)
        // 比べるパスは両側とも symlink を解決した絶対パス（/var と /private/var の食い違いで取り残しを処理待ちに数えない）
        let leftoverSet = Set(leftoverRelativePaths.map { resolved(layout.url(relative: $0)) })
        var pendingCount = 0
        var pendingBytes: Int64 = 0
        for (url, size) in regularFiles(under: layout.inbox) where url.lastPathComponent.hasSuffix(".wav") {
            if leftoverSet.contains(resolved(url)) { continue }
            pendingCount += 1
            pendingBytes += size
        }
        return InboxCounts(
            pendingCount: pendingCount, pendingBytes: pendingBytes, leftoverCount: left.count,
            leftoverBytes: left.bytes)
    }

    /// symlink を解決した絶対パス
    static func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    /// 通常ファイルのサイズの合計（再帰。読めないものは飛ばす）
    public static func directoryBytes(_ url: URL) -> Int64 {
        regularFiles(under: url).reduce(0) { $0 + $1.size }
    }

    /// 配下の通常ファイル（symlink は辿らない。読めないものは飛ばす）とサイズ。
    static func regularFiles(under root: URL) -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let items = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return [] }
        var found: [(url: URL, size: Int64)] = []
        for case let url as URL in items {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true,
                values.isRegularFile == true
            else { continue }
            found.append((url, Int64(values.fileSize ?? 0)))
        }
        return found
    }

    /// lstat で通常ファイルならサイズ、それ以外（無い・symlink・ディレクトリ）は nil
    static func regularFileSize(_ url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }
}
