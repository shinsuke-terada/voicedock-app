// F-77 のテスト用に、WAV のバイト列を手で組み立てる（RIFF / RF64・fmt・data・後ろのチャンク）。一時ディレクトリにだけ書く。
import Foundation
import TestSupport

/// 48 kHz / 24 bit / mono を基本に、data のサイズの欄を実データと食い違わせた WAV を作る。
enum HandMadeWAV {
    /// 1 フレームのバイト数（24 bit mono）
    static let bytesPerFrame = 3
    /// BWF の data のサイズの欄の位置（data は 32776 から。その直前の 4 バイト）
    static let bwfDataSizeOffset = BWFWriter.bwfHeaderBytes - 4

    /// BWFWriter の実機どおりの BWF（speech）の、data のサイズの欄だけを `declared` に書き換える。
    static func bwf(seconds: Double, format: BWFFormat = .pcm24, declared: UInt32) throws -> Data {
        var blob = try BWFWriter.build(seconds: seconds, format: format, content: .speech)
        blob.replaceSubrange(bwfDataSizeOffset..<(bwfDataSizeOffset + 4), with: le32(declared))
        return blob
    }

    /// 24 bit mono 48 kHz の標本のバイト列（BWFWriter の最小ヘッダ 44 バイトを除いた data の中身）
    static func pcm24Samples(seconds: Double) throws -> Data {
        let blob = try BWFWriter.build(seconds: seconds, format: .pcm24, content: .speech, minimalHeader: true)
        return blob.subdata(in: BWFWriter.minimalHeaderBytes..<blob.count)
    }

    /// `form`（RIFF / RF64）＋ サイズ ＋ WAVE ＋ body。サイズを省くと 4 + body の長さ。
    static func riff(_ body: Data, form: String = "RIFF", size: UInt32? = nil) -> Data {
        var out = Data(form.utf8)
        out.append(le32(size ?? UInt32(4 + body.count)))
        out.append(Data("WAVE".utf8))
        out.append(body)
        return out
    }

    /// id ＋ サイズ ＋ payload ＋（奇数長なら 0x00。サイズに含めない）
    static func chunk(_ id: String, _ payload: Data) -> Data {
        var out = Data(id.utf8)
        out.append(le32(UInt32(payload.count)))
        out.append(payload)
        if payload.count % 2 == 1 { out.append(0x00) }
        return out
    }

    /// data チャンクのヘッダだけ（id ＋ 宣言したサイズ）。中身は後ろに別に足す。
    static func dataHeader(declared: UInt32) -> Data {
        var out = Data("data".utf8)
        out.append(le32(declared))
        return out
    }

    /// fmt 16 バイト（tag 1・1 ch・48000 Hz・144000 B/s・block align 3・24 bit）
    static func fmtPCM24() -> Data {
        var payload = Data()
        payload.append(le16(1))
        payload.append(le16(1))
        payload.append(le32(48_000))
        payload.append(le32(144_000))
        payload.append(le16(3))
        payload.append(le16(24))
        return chunk("fmt ", payload)
    }

    /// fmt 40 バイト（WAVE_FORMAT_EXTENSIBLE 0xFFFE・cbSize 22・有効 24 bit・チャンネルマスク 4・サブ形式 PCM）
    static func fmtExtensiblePCM24() -> Data {
        var payload = Data()
        payload.append(le16(0xFFFE))
        payload.append(le16(1))
        payload.append(le32(48_000))
        payload.append(le32(144_000))
        payload.append(le16(3))
        payload.append(le16(24))
        payload.append(le16(22))
        payload.append(le16(24))
        payload.append(le32(4))
        payload.append(
            Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]))
        return chunk("fmt ", payload)
    }

    /// ds64 28 バイト（riffSize・dataSize・sampleCount・table 0 件）
    static func ds64(riffSize: UInt64, dataSize: UInt64, sampleCount: UInt64) -> Data {
        var payload = Data()
        payload.append(le64(riffSize))
        payload.append(le64(dataSize))
        payload.append(le64(sampleCount))
        payload.append(le32(0))
        return chunk("ds64", payload)
    }

    /// data の後ろに置く LIST（INFO の ISFT "VDock" ＋ 内側のパッド。payload 18 バイト、チャンク全体 26 バイト）
    static func listChunk() -> Data {
        var payload = Data("INFOISFT".utf8)
        payload.append(le32(5))
        payload.append(Data("VDock".utf8))
        payload.append(0x00)
        return chunk("LIST", payload)
    }

    static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func le64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// 一時ディレクトリの `name` に書いて URL を返す。
    static func write(_ blob: Data, named name: String, in tmp: TempDirectory) throws -> URL {
        let url = tmp.url.appendingPathComponent(name, isDirectory: false)
        try blob.write(to: url)
        return url
    }
}
