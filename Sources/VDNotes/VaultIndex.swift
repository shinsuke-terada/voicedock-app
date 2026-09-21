// Vault に実在する .md の basename の集合（PLAN §8.6 / NOTE-11。voicedock wiki.py:46-167）。例外を投げない。
import Foundation
import VDContract
import VDCore

public struct VaultIndex: Sendable {
    /// normalize 済み
    public let names: Set<String>
    /// AppClock.uptime()（単調時計）
    public let builtAt: Duration
    /// 走査したディレクトリの数（DEBUG ログ用）
    public let scannedDirectories: Int

    static let markdownSuffix = ".md"
    static let hiddenPrefix = "."

    public init(names: Set<String>, builtAt: Duration, scannedDirectories: Int = 0) {
        self.names = names
        self.builtAt = builtAt
        self.scannedDirectories = scannedDirectories
    }

    /// 深さ優先で Vault を走査する。読めないディレクトリは飛ばし、symlink は辿らない。Vault が無ければ空。
    public static func build(vault: URL, excludePrefixes: [String], builtAt: Duration) -> VaultIndex {
        let excluded = excludePrefixes.map { PyText.strip($0, chars: ["/"]) }.filter { !$0.unicodeScalars.isEmpty }
        var stack: [(URL, [String])] = [(vault, [])]
        var names = Set<String>()
        var scanned = 0
        while let (dir, rel) = stack.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
            else { continue }
            scanned += 1
            for name in entries {
                if ScalarText.hasPrefix(name, hiddenPrefix) { continue }
                let child = dir.appendingPathComponent(name)
                var info = stat()
                guard lstat(child.path(percentEncoded: false), &info) == 0 else { continue }
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    let childRel = RelPath.join(rel + [name])
                    if !isExcluded(childRel, excluded) {
                        stack.append((child, rel + [name]))
                    }
                    continue
                }
                if ScalarText.hasSuffix(name, markdownSuffix) {
                    let scalars = Array(name.unicodeScalars)
                    let stem = ScalarText.string(
                        Array(scalars[0..<(scalars.count - markdownSuffix.unicodeScalars.count)]))
                    names.insert(normalize(stem))
                }
            }
        }
        return VaultIndex(names: names, builtAt: builtAt, scannedDirectories: scanned)
    }

    /// 除外の接頭辞と等しいか、`接頭辞 + "/"` で始まるか（スカラー単位）
    static func isExcluded(_ rel: String, _ excluded: [String]) -> Bool {
        excluded.contains { prefix in
            PyText.scalarsEqual(rel, prefix) || ScalarText.hasPrefix(rel, prefix + "/")
        }
    }

    /// 突き合わせ用の正規形（NFC + casefold）
    public static func normalize(_ s: String) -> String {
        PyText.casefold(PyText.nfc(s))
    }

    /// Raw フォルダの除外接頭辞（テンプレートの最初の `{` より前を `/` で strip したもの）
    public static func rawFolderPrefix(_ template: String) -> String {
        let scalars = Array(template.unicodeScalars)
        guard let brace = scalars.firstIndex(of: "{") else {
            return PyText.strip(template, chars: ["/"])
        }
        return PyText.strip(ScalarText.string(Array(scalars[0..<brace])), chars: ["/"])
    }

    public func contains(_ name: String) -> Bool {
        names.contains(Self.normalize(name))
    }

    /// TTL を過ぎたか（等号で古い。voicedock の is_stale と同じ）
    public func isStale(ttlSeconds: Int, now: Duration) -> Bool {
        now - builtAt >= .seconds(ttlSeconds)
    }
}
