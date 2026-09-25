// 検査が空振りしないための「在るべきもの」の一覧（T-04。後続のチケットが足す）。

enum PolicyAnchors {
    /// PT-13 が必ず読むファイル（リポジトリのルートからの相対パス）。無ければ違反。
    /// T-09 が `Resources/ModelCatalog.json` を足す。
    static let requiredFiles: [String] = [
        "Package.swift", "Package.resolved", ".xcode-version", ".github/workflows/ci.yml", "Vendor/versions.env",
    ]

    /// PT-16 が必ず見つけるべき関数（`Sources/` からの相対パスと、`func` から始まる宣言の先頭）。
    /// T-15 が `("VDDevice/IngestService.swift", "func copyOne(")` を足す。
    static let requiredFunctions: [(path: String, declaration: String)] = []
}
