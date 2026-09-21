// 検査の対象のソース（Sources/ からの相対パスと中身。字句解析の結果を持つ）（T-04）。
import Foundation
import TestSupport

/// 検査の対象の 1 ファイル。
struct SourceFile: Sendable {
    /// `Sources/` からの相対パス（例 `VDCore/SafeUnlink.swift`）。
    let relativePath: String
    let scanned: ScannedSource
    let tokens: [CodeToken]

    init(relativePath: String, text: String) {
        self.relativePath = relativePath
        scanned = SourceScanner.scan(text)
        tokens = CodeTokenizer.tokens(scanned.code)
    }

    /// 最初の要素（モジュールのディレクトリ名）。
    var module: String { String(relativePath.prefix { $0 != "/" }) }
}

/// `Sources/` 配下の全 `.swift` を読む。
enum SourceTree {
    static func load(root: URL = PackageRoot.file("Sources")) throws -> [SourceFile] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        var paths: [String] = []
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            paths.append(path)
        }
        return try paths.sorted().map { relative in
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            return SourceFile(relativePath: relative, text: text)
        }
    }
}
