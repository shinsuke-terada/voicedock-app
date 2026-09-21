// 16 kHz 出力の検証（PLAN §8.3 手順 6、ASR-01。voicedock audio.py:672-712）。
import AVFoundation
import Foundation

public enum OutputVerifier {
    static let expectedSampleRate: Double = 16_000
    static let expectedChannels: AVAudioChannelCount = 1

    /// 合格なら nil、不合格なら error_message の文言。例外を投げない。
    public static func verify(output: URL, inputDuration: Double?, tolerance: Double) -> String? {
        let path = output.path(percentEncoded: false)
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return "\(path) がありません"
        }
        if info.st_size == 0 {
            return "\(path) が 0 バイトです"
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: output)
        } catch {
            return "出力を読めません: \(ErrorText.describe(error))"
        }
        let fileFormat = file.fileFormat
        if fileFormat.sampleRate != expectedSampleRate {
            return "sample_rate が \(integerText(fileFormat.sampleRate))（期待 16000）"
        }
        if fileFormat.channelCount != expectedChannels {
            return "channels が \(fileFormat.channelCount)（期待 1）"
        }
        if fileFormat.commonFormat != .pcmFormatInt16 {
            return "sample_fmt が \(sampleFormatName(fileFormat.commonFormat))（期待 s16）"
        }
        guard let inputDuration else { return nil }
        guard fileFormat.sampleRate != 0 else { return nil }
        let outDuration = Double(file.length) / fileFormat.sampleRate
        let gap = abs(outDuration - inputDuration)
        if gap > tolerance {
            return "長さが入力と \(String(format: "%.2f", gap)) 秒ずれています（許容 \(tolerance.description) 秒）"
        }
        return nil
    }

    /// AVAudioCommonFormat を ffmpeg 風の名前へ（文言用）。
    static func sampleFormatName(_ f: AVAudioCommonFormat) -> String {
        switch f {
        case .pcmFormatInt16: return "s16"
        case .pcmFormatInt32: return "s32"
        case .pcmFormatFloat32: return "flt"
        case .pcmFormatFloat64: return "dbl"
        default: return "other"
        }
    }

    /// `Int(sampleRate)` の文言。Int に収まらない値（NaN・無限大・巨大）は `Double.description`（トラップしない。PT-19）。
    static func integerText(_ value: Double) -> String {
        guard let integer = Int(exactly: value.rounded(.towardZero)) else { return value.description }
        return String(integer)
    }
}
