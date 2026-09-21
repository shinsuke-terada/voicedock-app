// ノートの atomic な書き込み（PLAN §8.7。voicedock notes.py:223-288 と同じ手順）。
import Foundation
import VDContract
import VDCore

public enum NoteWriter {
    /// content を UTF-8 で書き、書いた内容の SHA-256（小文字 16 進）を返す。
    /// tmp は同じディレクトリの `.<ファイル名>.tmp`。失敗したら tmp を消して元のエラーを投げる（NOTE-14）。
    public static func write(_ content: String, to url: URL) throws(AtomicFileError) -> String {
        let data = Data(content.utf8)
        let sha = FileHasher.sha256(data)
        try AtomicFile.write(data, to: url, permissions: 0o644, verifyReadBack: true)
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
        let dir = vault.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
