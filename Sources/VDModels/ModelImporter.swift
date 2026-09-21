// 利用者の .gguf を models/llm へ読みながら取り込む（PLAN §8.10「ファイルから読み込む」）。
import CryptoKit
import Foundation
import VDContract
import VDCore

public enum ModelImporter {
    /// これより小さい読みの単位は断る（CV-58 が 4096 以上を保証するが、直接呼ばれても壊れないように）。
    static let minimumChunkBytes = 4096

    /// source を読みながら SHA-256 を計算して models/llm/.custom-import-<16 hex>.gguf.part へ複製し、
    /// custom-<sha256 の先頭 16>.gguf へ rename する。既に在ればそれを使う。例外を投げない。
    public static func importGGUF(from source: URL, layout: HomeLayout, chunkBytes: Int)
        -> Result<(id: String, url: URL), ModelError>
    {
        guard chunkBytes >= minimumChunkBytes else { return .failure(.io("chunk_bytes")) }
        var info = stat()
        guard lstat(source.path(percentEncoded: false), &info) == 0 else {
            return .failure(.io(IOText.errno(errno)))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.io("not_a_regular_file")) }
        let tmpName = "custom-import-" + RandomHex.hex16() + ".gguf"
        let tmp = layout.modelPart(kind: ModelKind.llm.rawValue, file: tmpName)
        let sha: String
        switch copyHashing(source, to: tmp, chunkBytes: chunkBytes) {
        case .failure(let err):
            removeTmp(tmp, layout: layout)
            return .failure(err)
        case .success(let value):
            sha = value
        }
        let final = layout.modelFile(kind: ModelKind.llm.rawValue, file: CustomModelID.fileName(sha256: sha))
        var existing = stat()
        if stat(final.path(percentEncoded: false), &existing) == 0, (existing.st_mode & S_IFMT) == S_IFREG {
            removeTmp(tmp, layout: layout)
            return .success((CustomModelID.make(sha256: sha), final))
        }
        guard Darwin.rename(tmp.path(percentEncoded: false), final.path(percentEncoded: false)) == 0 else {
            let code = errno
            removeTmp(tmp, layout: layout)
            return .failure(.io(IOText.errno(code)))
        }
        return .success((CustomModelID.make(sha256: sha), final))
    }

    /// source を 1 回だけ読み、tmp へ書きながら SHA-256 を計算する。
    private static func copyHashing(_ source: URL, to tmp: URL, chunkBytes: Int) -> Result<String, ModelError> {
        guard let input = try? FileHandle(forReadingFrom: source) else { return .failure(.io("read")) }
        defer { try? input.close() }
        guard
            FileManager.default.createFile(
                atPath: tmp.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o644])
        else { return .failure(.io("create")) }
        guard let output = try? FileHandle(forWritingTo: tmp) else { return .failure(.io("create")) }
        defer { try? output.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                guard let d = try input.read(upToCount: chunkBytes), !d.isEmpty else { break }
                chunk = d
            } catch {
                return .failure(.io("read"))
            }
            hasher.update(data: chunk)
            do {
                try output.write(contentsOf: chunk)
            } catch {
                return .failure(.io("write"))
            }
        }
        try? output.synchronize()
        return .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// tmp を消す（.part を残さない）。
    private static func removeTmp(_ tmp: URL, layout: HomeLayout) {
        try? SafeUnlink.remove(tmp, under: .models, layout: layout, missingOK: true)
    }
}

/// 乱数の 16 進。
enum RandomHex {
    /// SystemRandomNumberGenerator の 8 バイトを小文字 16 進 16 桁に。
    static func hex16() -> String {
        var generator = SystemRandomNumberGenerator()
        let value: UInt64 = generator.next()
        return String(format: "%016llx", value)
    }
}

/// 入出力の失敗を機械の語にする。
enum IOText {
    /// strerror の文字列（"No such file or directory" など）。
    static func errno(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// Error から 1 行（NSError なら domain + code、それ以外は型の名前）。本文を混ぜない。
    static func describe(_ e: any Error) -> String {
        let n = e as NSError
        return "\(n.domain) \(n.code)"
    }
}
