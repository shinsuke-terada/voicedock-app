// リポジトリのルートを求める（テストがリポジトリ内のファイルを読むため）。
import Foundation

/// リポジトリのルート（`Package.swift` のあるディレクトリ）。
public enum PackageRoot {
    /// このファイル（`Tests/TestSupport/PackageRoot.swift`）から 3 階層上。
    public static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// ルートからの相対パスを URL にする。
    public static func file(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }
}
