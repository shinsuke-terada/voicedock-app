// Vault の中のパスの組み立て（PLAN §2.3「ノートは Vault からの相対」・§5.3・§8.8）。文字列で組み立てない。
import Foundation
import VDContract
import VDNotes

enum VaultPaths {
    /// cfg.vault.path のディレクトリの URL（`URL(fileURLWithPath: path, isDirectory: true)`）。
    static func root(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Vault からの相対 POSIX パス（DB の raw_output_path / output_path とログの path）。
    /// `url.standardizedFileURL.path` が `vault.standardizedFileURL.path + "/"` で始まればその後ろ、そうでなければ url のパス全体（起きない）。
    static func relative(_ url: URL, vault: URL) -> String {
        let full = url.standardizedFileURL.path(percentEncoded: false)
        // ディレクトリの URL は末尾に "/" が付くので、付いていなければ足す。比較はスカラー単位
        var base = Array(vault.standardizedFileURL.path(percentEncoded: false).unicodeScalars)
        if base.last != "/" { base.append("/") }
        let scalars = Array(full.unicodeScalars)
        guard scalars.count > base.count, Array(scalars[0..<base.count]) == base else { return full }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: scalars[base.count...])
        return String(rest)
    }

    /// DB の相対パスから URL（`vault.appendingPathComponent(relative)`）。
    static func url(_ relative: String, vault: URL) -> URL {
        vault.appendingPathComponent(relative)
    }

    /// 復旧で消す一時ファイル（PLAN §5.3）。existing（DB の出力パス）があればその `.<名前>.tmp` 1 つ。
    /// 無ければ <folder>/<baseName>.md と <baseName> (2).md 〜 (99).md のそれぞれの `.<名前>.tmp`（**名前が完全一致するものだけ**）。
    static func tmpCandidates(vault: URL, existing: String?, folder: String, baseName: String) -> [URL] {
        if let existing {
            return [AtomicFile.tmpURL(for: url(existing, vault: vault))]
        }
        let dir = folder.isEmpty ? vault : vault.appendingPathComponent(folder, isDirectory: true)
        var names = [baseName + ".md"]
        for n in 2...OutputPathResolver.maxSuffix {
            names.append(baseName + " (" + String(n) + ").md")
        }
        return names.map { AtomicFile.tmpURL(for: dir.appendingPathComponent($0, isDirectory: false)) }
    }
}
