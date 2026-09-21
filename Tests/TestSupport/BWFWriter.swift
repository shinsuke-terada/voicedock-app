// テスト用の BWF（PLAN §10.2。voicedock tests/fixtures/make_wav.py と同じバイト列）。
import Foundation

public enum BWFFormat: String, Sendable, CaseIterable { case pcm24, float32, pcm16 }
public enum BWFContent: String, Sendable { case silence, speech }
public enum BWFError: Error, Equatable { case nonPositiveSeconds }

/// 実機と同じ構成の BWF を作る（ASR-15。ヘッダ約 32 KB）。作り手は T-14、T-16・T-18 も使う（00-api-map §15）。
public enum BWFWriter {
    public static let sampleRate = 48_000
    public static let channels = 1
    public static let bextSize = 602
    public static let ixmlSize = 1_092
    public static let cueSize = 28
    public static let bwfHeaderBytes = 32_776
    public static let minimalHeaderBytes = 44
    /// 32776 − (12 + 8 × 5 + 16 + 602 + 1092 + 28 + 8) = 30978
    public static let padSize = 30_978

    /// 発話区間の長さ（秒）
    static let speechOn = 0.8
    /// 無音区間の長さ（秒）
    static let speechOff = 0.4
    /// おおよそ −20 dBFS
    static let amplitude = 0.1

    /// pcm16 2, pcm24 3, float32 4
    public static func sampleWidth(_ f: BWFFormat) -> Int {
        switch f {
        case .pcm16: 2
        case .pcm24: 3
        case .float32: 4
        }
    }

    public static func byteRate(_ f: BWFFormat, sampleRate: Int = 48_000) -> Int {
        sampleRate * channels * sampleWidth(f)
    }

    public static func build(
        seconds: Double, format: BWFFormat = .pcm24, content: BWFContent = .silence,
        minimalHeader: Bool = false, toneHz: Double = 220, sampleRate: Int = 48_000
    ) throws(BWFError) -> Data {
        guard seconds > 0 else { throw .nonPositiveSeconds }
        let frames = Int((Double(sampleRate) * seconds).rounded(.toNearestOrEven))
        let data = encode(samples(frames: frames, content: content, toneHz: toneHz, sampleRate: sampleRate), format)
        var body = fmtChunk(format, sampleRate: sampleRate)
        if !minimalHeader {
            var ixml = Data("<BWFXML></BWFXML>".utf8)
            ixml.append(Data(repeating: 0x20, count: ixmlSize - ixml.count))
            body.append(chunk("bext", Data(count: bextSize)))
            body.append(chunk("iXML", ixml))
            body.append(chunk("cue ", Data(count: cueSize)))
            body.append(chunk("PAD ", Data(count: padSize)))
        }
        body.append(chunk("data", data))
        var blob = Data("RIFF".utf8)
        appendLE(UInt32(4 + body.count), to: &blob)
        blob.append(Data("WAVE".utf8))
        blob.append(body)
        return blob
    }

    @discardableResult
    public static func write(
        to url: URL, seconds: Double, format: BWFFormat = .pcm24, content: BWFContent = .silence,
        minimalHeader: Bool = false, toneHz: Double = 220, sampleRate: Int = 48_000
    ) throws -> URL {
        let blob = try build(
            seconds: seconds, format: format, content: content, minimalHeader: minimalHeader, toneHz: toneHz,
            sampleRate: sampleRate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.write(to: url)
        return url
    }

    /// −1.0〜1.0 の標本列（乱数を使わない。make_wav.py の _samples）
    static func samples(frames: Int, content: BWFContent, toneHz: Double, sampleRate: Int) -> [Double] {
        switch content {
        case .silence:
            return [Double](repeating: 0.0, count: frames)
        case .speech:
            let period = speechOn + speechOff
            var values: [Double] = []
            values.reserveCapacity(frames)
            for index in 0..<frames {
                let t = Double(index) / Double(sampleRate)
                if t.truncatingRemainder(dividingBy: period) >= speechOn {
                    values.append(0.0)
                    continue
                }
                let angle = 2.0 * Double.pi * toneHz * t
                values.append(amplitude * (sin(angle) + 0.5 * sin(2 * angle) + 0.25 * sin(4 * angle)))
            }
            return values
        }
    }

    /// リトルエンディアンの標本のバイト列（make_wav.py の _encode）
    static func encode(_ values: [Double], _ format: BWFFormat) -> Data {
        var out = Data()
        out.reserveCapacity(values.count * sampleWidth(format))
        for v in values {
            switch format {
            case .float32:
                appendLE(Float(v).bitPattern, to: &out)
            case .pcm16:
                appendLE(UInt16(bitPattern: Int16(max(-1.0, min(1.0, v)) * 32767.0)), to: &out)
            case .pcm24:
                let bits = UInt32(bitPattern: Int32(max(-1.0, min(1.0, v)) * 8_388_607.0))
                out.append(UInt8(truncatingIfNeeded: bits))
                out.append(UInt8(truncatingIfNeeded: bits >> 8))
                out.append(UInt8(truncatingIfNeeded: bits >> 16))
            }
        }
        return out
    }

    /// id（4 バイト ASCII）＋ サイズ（LE）＋ payload ＋（奇数長なら 0x00。サイズ欄に含めない）
    static func chunk(_ id: String, _ payload: Data) -> Data {
        var out = Data(id.utf8)
        appendLE(UInt32(payload.count), to: &out)
        out.append(payload)
        if payload.count % 2 == 1 { out.append(0x00) }
        return out
    }

    /// `<HHIIHH`: tag（float32 は 3、それ以外 1）・channels・sampleRate・byteRate・block align・bits
    static func fmtChunk(_ format: BWFFormat, sampleRate: Int) -> Data {
        let tag: UInt16 = format == .float32 ? 3 : 1
        let width = sampleWidth(format)
        var payload = Data()
        appendLE(tag, to: &payload)
        appendLE(UInt16(channels), to: &payload)
        appendLE(UInt32(sampleRate), to: &payload)
        appendLE(UInt32(byteRate(format, sampleRate: sampleRate)), to: &payload)
        appendLE(UInt16(width * channels), to: &payload)
        appendLE(UInt16(width * 8), to: &payload)
        return chunk("fmt ", payload)
    }

    static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
