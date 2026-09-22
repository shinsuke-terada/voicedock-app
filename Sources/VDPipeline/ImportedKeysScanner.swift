// voicedock が書いた Raw ノートの録音の鍵を imported_keys に取り込む（PLAN §8.13）。
import Foundation
import VDContract
import VDCore
import VDNotes
import VDStore

/// voicedock が書いた Raw ノートの録音の鍵を imported_keys に取り込む（PLAN §8.13）。
public struct ImportedKeysScanner: Sendable {
    let store: Store
    let log: AppLog

    static let markdownSuffix = ".md"
    static let hiddenPrefix = "."

    public init(store: Store, log: AppLog) {
        self.store = store
        self.log = log
    }

    /// Raw フォルダの接頭辞の下の *.md を走り、DB に行が無い partkey を imported_keys に入れる。
    /// 戻りは**新しく入れた件数**。ブロックする（呼び手が BlockingIO.run で包む）。
    public func scan(vault: URL, config: ObsidianConfig) throws -> Int {
        let prefix = VaultIndex.rawFolderPrefix(config.raw.folderTemplate)
        let root =
            prefix.isEmpty
            ? vault
            : RelPath.components(prefix).reduce(vault) { $0.appendingPathComponent($1, isDirectory: true) }
        let files = ImportedKeysScanner.markdownFiles(root: root, base: prefix)
        if files.isEmpty { return 0 }
        var rows: [(partkey: String, sourceNote: String)] = []
        var seen: Set<String> = []
        for relative in files {
            let keys = Frontmatter.recordingKeys(ofFile: vault.appendingPathComponent(relative, isDirectory: false))
            for key in keys {
                // PLAN §8.13: PartKey の形でなければ入れない（PartKey.make で組み直して同じ鍵になること。
                // DeviceID.isValid と RelPath.isSafe の両方を通る）
                guard let deviceID = PartKey.deviceID(of: key), let relpath = PartKey.relpath(of: key),
                    (try? PartKey.make(deviceID: deviceID, relpath: relpath)) == key
                else { continue }
                if seen.insert(key).inserted {
                    rows.append((key, relative))
                }
            }
        }
        if rows.isEmpty { return 0 }
        let n = try store.insertImportedKeys(rows)
        if n > 0 {
            log.info(.importedKeysAdded, [(.count, .int(Int64(n)))])
        }
        return n
    }
}

extension ImportedKeysScanner {
    /// root の下の *.md を、Vault からの相対パス（base を頭に付けたもの）で返す。
    /// 深さ優先。`.` で始まる名前は無視し、symlink は辿らない。読めないディレクトリは飛ばす。例外を投げない。
    static func markdownFiles(root: URL, base: String) -> [String] {
        var stack: [(URL, [String])] = [(root, base.isEmpty ? [] : RelPath.components(base))]
        var out: [String] = []
        while let (dir, rel) = stack.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
            else { continue }
            for name in entries {
                if hasScalarPrefix(name, hiddenPrefix) { continue }
                let child = dir.appending(path: name, directoryHint: .notDirectory)
                var info = stat()
                guard lstat(child.path(percentEncoded: false), &info) == 0 else { continue }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFDIR {
                    stack.append((child, rel + [name]))
                    continue
                }
                // symlink のファイルは開かない（S_ISREG だけ）
                if kind == S_IFREG && hasScalarSuffix(name, markdownSuffix) {
                    out.append(RelPath.join(rel + [name]))
                }
            }
        }
        return out.sorted { Array($0.unicodeScalars).lexicographicallyPrecedes(Array($1.unicodeScalars)) }
    }

    /// スカラー列で前方一致（大小を区別する）
    static func hasScalarPrefix(_ s: String, _ prefix: String) -> Bool {
        s.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// スカラー列で後方一致（大小を区別する）
    static func hasScalarSuffix(_ s: String, _ suffix: String) -> Bool {
        s.unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
    }
}
