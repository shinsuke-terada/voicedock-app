// テストごとの一時ディレクトリ（PLAN §10.1）。
import Foundation

/// テストごとに作る一時ディレクトリ。`remove()` か、参照が無くなったとき（deinit）に中身ごと消す。
public final class TempDirectory: Sendable {
    /// 作ったディレクトリ（realpath 済み。`/var` ではなく `/private/var`）。
    public let url: URL

    /// `NSTemporaryDirectory()` の下に `VoiceDockTests-<UUID>` を作る。
    public init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("VoiceDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir
    }

    deinit {
        remove()
    }

    /// 中身ごと消す（テストの後片付け。失敗は無視する。何度呼んでもよい）。
    /// テストが `chmod 000` などにしたディレクトリも消せるよう、先に権限を 0o755 に戻す。
    public func remove() {
        Self.restorePermissions(url)
        try? FileManager.default.removeItem(at: url)
    }

    /// ディレクトリを 0o755 にしてから中を回る（000 の中は列挙できないため）。symlink は辿らない。
    private static func restorePermissions(_ item: URL) {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: item.path),
            attributes[.type] as? FileAttributeType == .typeDirectory
        else { return }
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
        for child in (try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
            restorePermissions(child)
        }
    }
}
