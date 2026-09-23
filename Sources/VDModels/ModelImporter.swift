// 利用者の .gguf を models/llm へ読みながら取り込む（PLAN §8.10「ファイルから読み込む」）。
import CryptoKit
import Foundation
import VDContract
import VDCore

public enum ModelImporter {
    /// これより小さい読みの単位は断る（CV-58 が 4096 以上を保証するが、直接呼ばれても壊れないように）。
    static let minimumChunkBytes = 4096
    /// 取り込みの途中のファイル名 `custom-import-<16 hex>.gguf` の頭と尻（.part の名前は `HomeLayout.modelPart`）。
    static let tmpPrefix = "custom-import-"
    static let tmpSuffix = ".gguf"
    /// 乱数の 16 進の桁数（`RandomHex.hex16`）。
    static let tmpHexDigits = 16

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
        let tmpName = tmpPrefix + RandomHex.hex16() + tmpSuffix
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
        // F-83: rename を残す（中身は copyHashing が書き出した）
        ModelFileSync.syncParent(of: final)
        return .success((CustomModelID.make(sha256: sha), final))
    }

    /// F-83: 前回の取り込みが途中で終わって残った `models/llm/.custom-import-<16 桁の小文字 16 進>.gguf.part` を消す
    /// （数 GB が残り続けた）。名前がこの形に完全に一致する通常ファイルだけ（SafeUnlink の `.models`。symlink は消さない）。
    /// 呼び手は、取り込みが 1 本も走っていないとき（ModelManager）。消せた数を返す（読めない・消せないものは飛ばす）。
    @discardableResult
    static func discardStaleParts(layout: HomeLayout) -> Int {
        let dir = layout.models(kind: ModelKind.llm.rawValue)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else {
            return 0
        }
        var removed = 0
        for name in names where isStalePartName(name, layout: layout) {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            do {
                try SafeUnlink.remove(url, under: .models, layout: layout, missingOK: true)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    /// name が取り込みの途中のファイル名（`HomeLayout.modelPart` の形の `.custom-import-<16 桁の小文字 16 進>.gguf.part`）か。
    /// 比較はスカラー単位（書記素・正準等価で比べない）
    static func isStalePartName(_ name: String, layout: HomeLayout) -> Bool {
        let marker: Unicode.Scalar = "#"
        let template = layout.modelPart(kind: ModelKind.llm.rawValue, file: tmpPrefix + String(marker) + tmpSuffix)
            .lastPathComponent.unicodeScalars
        guard let at = template.firstIndex(of: marker) else { return false }
        let head = Array(template[..<at])
        let tail = Array(template[template.index(after: at)...])
        let scalars = Array(name.unicodeScalars)
        guard scalars.count == head.count + tmpHexDigits + tail.count else { return false }
        guard scalars.starts(with: head), Array(scalars.suffix(tail.count)) == tail else { return false }
        return scalars[head.count..<(head.count + tmpHexDigits)].allSatisfy { s in
            ("0"..."9").contains(s) || ("a"..."f").contains(s)
        }
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
        var failure: ModelError?
        // F-83: 1 回の読みごとに autoreleasepool で包む（数 GB を読む間、読んだ Data が溜まり続けない）
        while failure == nil {
            let more: Bool = autoreleasepool {
                let chunk: Data
                do {
                    guard let d = try input.read(upToCount: chunkBytes), !d.isEmpty else { return false }
                    chunk = d
                } catch {
                    failure = .io("read")
                    return false
                }
                hasher.update(data: chunk)
                do {
                    try output.write(contentsOf: chunk)
                } catch {
                    failure = .io("write")
                    return false
                }
                return true
            }
            if !more { break }
        }
        if let failure { return .failure(failure) }
        // F-83: rename の前にドライブまで書き出す。失敗は失敗として返す（以前は synchronize の失敗を無視していた）
        guard AtomicFile.fullFsync(output.fileDescriptor) == nil else {
            return .failure(.io(ModelFileSync.fsyncFailure))
        }
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
