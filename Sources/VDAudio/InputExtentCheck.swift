// 入力の WAV のヘッダの長さと実データの量の照合（PLAN §8.3 手順 2・6。F-77）。
import AVFoundation
import Foundation

/// F-77: 変換は `AVAudioFile.length`（data チャンクの宣言したサイズから出る）で読むのを止め、入力の長さ（§8.1 の
/// `AudioProbe`）も同じ値から測るので、ヘッダが実データより短いと後半を欠いた出力が長さの照合（ASR-01）を通ってしまう。
/// ファイルのサイズから求めた data の量とヘッダの長さを照らし、実データが 1 フレーム以上多ければ不合格にする（消さない側）。
enum InputExtentCheck {
    /// data チャンクより前に辿るチャンクの数の上限（実機の BWF は fmt・bext・iXML・cue・PAD の 5 つ）
    static let maxChunksBeforeData = 1_000
    /// data の後ろに続くチャンクとして辿る数の上限
    static let maxTrailingChunks = 64
    /// RF64 の data チャンクのサイズの欄が「サイズは ds64 にある」を表す値
    static let rf64SizePlaceholder: UInt64 = 0xFFFF_FFFF
    static let riffID = Array("RIFF".utf8)
    static let rf64ID = Array("RF64".utf8)
    static let waveID = Array("WAVE".utf8)
    static let dataID = Array("data".utf8)
    static let ds64ID = Array("ds64".utf8)
    /// チャンクの id として認める 1 バイト（印字可能な ASCII）
    static let printableASCII: ClosedRange<UInt8> = 0x20...0x7E
    static let notLinearPCM = "リニア PCM ではありません"

    /// data チャンクの位置と量（バイト）。
    struct Layout: Equatable {
        /// data の中身の開始位置（data チャンクのヘッダの直後）
        let dataStart: UInt64
        /// data チャンクが宣言するサイズ（RF64 でサイズの欄が 0xFFFFFFFF なら ds64 の dataSize）
        let declaredBytes: UInt64
        /// ファイルのサイズ
        let fileBytes: UInt64
        /// 実データの量。宣言したサイズの後ろがチャンクの並びとしてファイルの終わりでちょうど閉じる（パッドだけも含む）なら
        /// 宣言したサイズ、そうでなければ data の開始位置からファイルの終わりまで（宣言がそれ以上のときも同じ）
        let actualBytes: UInt64
    }

    /// 構造を読めない理由（文言の括弧の中）。
    enum LayoutError: Error, Equatable {
        case notWave
        case noDataChunk
        case noDS64
        case io(String)

        var text: String {
            switch self {
            case .notWave: "RIFF / RF64 の WAVE ではありません"
            case .noDataChunk: "data チャンクがありません"
            case .noDS64: "RF64 に ds64 チャンクがありません"
            case .io(let message): message
            }
        }
    }

    /// 合格なら nil、不合格なら error_message の文言。例外を投げない。入力には書き込まない。
    static func check(input: URL) -> String? {
        let layout: Layout
        do {
            layout = try readLayout(input)
        } catch {
            return unreadable(error.text)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: input)
        } catch {
            return unreadable(ErrorText.describe(error))
        }
        let description = file.fileFormat.streamDescription.pointee
        let bytesPerFrame = UInt64(description.mBytesPerFrame)
        guard description.mFormatID == kAudioFormatLinearPCM, bytesPerFrame > 0 else {
            return unreadable(notLinearPCM)
        }
        let headerFrames = min(UInt64(max(file.length, 0)), layout.declaredBytes / bytesPerFrame)
        let actualFrames = layout.actualBytes / bytesPerFrame
        guard actualFrames <= headerFrames else {
            return "入力のヘッダの長さと実データの量が合いません（ヘッダ \(headerFrames) フレーム、実データ \(actualFrames) フレーム）"
        }
        return nil
    }

    /// 構造を読めないときの文言。
    static func unreadable(_ reason: String) -> String {
        "入力の WAV の構造を読めません（\(reason)）"
    }

    /// RIFF / RF64 の WAVE のチャンクを先頭から辿り、data の位置と量を読む。
    static func readLayout(_ url: URL) throws(LayoutError) -> Layout {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try walk(Reader(handle: handle, size: try handle.seekToEnd()))
        } catch let error as LayoutError {
            throw error
        } catch {
            throw .io(ErrorText.describe(error))
        }
    }

    /// 位置を指定して読む（読み取り専用の FileHandle）。
    private struct Reader {
        let handle: FileHandle
        let size: UInt64

        /// offset から最大 count バイト（ファイルの終わりで短くなる）
        func bytes(at offset: UInt64, count: Int) throws -> [UInt8] {
            guard offset < size else { return [] }
            try handle.seek(toOffset: offset)
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        }
    }

    private static func walk(_ reader: Reader) throws -> Layout {
        let head = try reader.bytes(at: 0, count: 12)
        guard head.count == 12, fourCC(head) == riffID || fourCC(head) == rf64ID, Array(head[8..<12]) == waveID else {
            throw LayoutError.notWave
        }
        let isRF64 = fourCC(head) == rf64ID
        var position: UInt64 = 12
        var ds64DataBytes: UInt64?
        for _ in 0..<maxChunksBeforeData {
            let header = try reader.bytes(at: position, count: 8)
            guard header.count == 8 else { break }
            let size = UInt64(littleEndian32(header, at: 4))
            let payload = position + 8
            if fourCC(header) == dataID {
                guard isRF64, size == rf64SizePlaceholder else {
                    return try layout(reader, dataStart: payload, declared: size)
                }
                guard let ds64DataBytes else { throw LayoutError.noDS64 }
                return try layout(reader, dataStart: payload, declared: ds64DataBytes)
            }
            if isRF64, fourCC(header) == ds64ID {
                // ds64: riffSize(8) dataSize(8) sampleCount(8) …
                let body = try reader.bytes(at: payload, count: 16)
                if body.count == 16 { ds64DataBytes = littleEndian64(body, at: 8) }
            }
            position = payload + size + (size & 1)
        }
        throw LayoutError.noDataChunk
    }

    private static func layout(_ reader: Reader, dataStart: UInt64, declared: UInt64) throws -> Layout {
        let available = reader.size > dataStart ? reader.size - dataStart : 0
        var actual = available
        if declared < available {
            let tail = dataStart + declared + (declared & 1)
            if try tail >= reader.size || chunksClose(reader, from: tail) {
                actual = declared
            }
        }
        return Layout(dataStart: dataStart, declaredBytes: declared, fileBytes: reader.size, actualBytes: actual)
    }

    /// tail から後ろが、チャンク（id は印字可能な ASCII 4 文字）の並びとしてファイルの終わりでちょうど閉じるか。
    /// 最後のチャンクの奇数長のパッドは無くてよい。
    private static func chunksClose(_ reader: Reader, from tail: UInt64) throws -> Bool {
        var position = tail
        for _ in 0..<maxTrailingChunks {
            if position == reader.size { return true }
            let header = try reader.bytes(at: position, count: 8)
            guard header.count == 8, header[0..<4].allSatisfy({ printableASCII.contains($0) }) else { return false }
            let size = UInt64(littleEndian32(header, at: 4))
            let end = position + 8 + size
            if end == reader.size { return true }
            position = end + (size & 1)
            if position > reader.size { return false }
        }
        return position == reader.size
    }

    private static func fourCC(_ bytes: [UInt8]) -> [UInt8] {
        Array(bytes.prefix(4))
    }

    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, index in value | UInt32(bytes[offset + index]) << (8 * UInt32(index)) }
    }

    private static func littleEndian64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { value, index in value | UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
    }
}
