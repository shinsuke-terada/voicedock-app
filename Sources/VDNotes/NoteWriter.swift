// ノートの atomic な書き込み（PLAN §8.7。voicedock notes.py:223-288 と同じ手順）。
import Foundation
import VDContract
import VDCore

public enum NoteWriter {
    /// content を UTF-8 で書き、書いた内容の SHA-256（小文字 16 進）を返す。
    /// tmp は同じディレクトリの `.<ファイル名>.tmp`。失敗したら tmp を消して元のエラーを投げる（NOTE-14）。
    /// F-83: F_FULLFSYNC で書き出す（`fullSync: true`。Raw ノートは原本の削除の根拠（§8.9.1）で、macOS の `fsync` は
    /// ドライブのキャッシュまでは流さない。PolicyTests が字句で固定する）。読み手（`Frontmatter.readNote`）の上限
    /// `Frontmatter.maxNoteBytes` を超える内容は書く前に `.write(errno: EFBIG)` で断る（書いても検証が読めず ` (2)` が増えるだけ）
    public static func write(_ content: String, to url: URL) throws(AtomicFileError) -> String {
        let data = Data(content.utf8)
        guard data.count <= Frontmatter.maxNoteBytes else { throw .write(errno: EFBIG) }
        let sha = FileHasher.sha256(data)
        try AtomicFile.write(data, to: url, permissions: 0o644, verifyReadBack: true, fullSync: true)
        return sha
    }
}

/// ノートのフォルダを作る（Vault の確認の後に呼ぶ。Vault のルートは作らない）
public enum NoteFolder {
    public static func ensure(relative: String, vault: URL) throws -> URL {
        if relative.isEmpty {
            return vault
        }
        // CV-11 がテンプレートの `..` を弾くが、ここでも確かめる
        guard RelPath.isSafe(relative) else {
            throw NoteFolderError.unsafeRelative
        }
        // 1 段ずつ作る（withIntermediateDirectories: false）。確認の後に Vault のルートが消えていても、
        // ルートやその上の階層を作り直さない（最初の段が ENOENT で失敗する）。T-29 のレビューで判明
        // F-83: `/` で分けるのはスカラー単位（書記素単位だと `a/\u{301}b` の `/` を見落とし、中間を作らずに ENOENT で落ちる。F-73 と同じ）
        var dir = vault
        for component in relative.unicodeScalars.split(separator: "/") {
            dir = dir.appendingPathComponent(ScalarText.string(Array(component)), isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path(percentEncoded: false), isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                continue
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        }
        return dir
    }
}

public enum NoteFolderError: Error, Equatable, Sendable {
    case unsafeRelative
}

/// 例外を「<型名>: <説明>」の 1 行にする（error_message 用。voicedock の f"{type(exc).__name__}: {exc}" に相当）
public enum NoteErrorText {
    public static func describe(_ error: any Error) -> String {
        "\(type(of: error)): \(error)"
    }
}
