// AVFoundation で 16 kHz / 1 ch / Int16 の WAV を書く（PLAN §8.3 手順 4）。
import AVFoundation
import Foundation
import VDCore

enum AudioConversionError: Error, Equatable {
    case cannotCreateConverter
    case cannotAllocateBuffer
    case converterFailed(String)
    case deadlineExceeded
}

enum AudioConversion {
    static let outputSampleRate: Double = 16_000
    static let inputFramesPerBuffer: AVAudioFrameCount = 65_536

    /// 出力ファイルの settings（逐語。キーの意味は PLAN §8.3）。
    /// `[String: Any]` は Sendable でないため、static let ではなく計算プロパティで持つ（Swift 6）。
    static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVAudioFileTypeKey: kAudioFileWAVEType,
        ]
    }

    /// `input` を読み、`tmpOutput` に 16 kHz / 1 ch / Int16 の WAV を書いて閉じる。rename はしない。
    static func convert(input: URL, tmpOutput: URL, deadline: Deadline) throws {
        let inFile = try AVAudioFile(forReading: input)  // processingFormat は Float32・非インターリーブ
        let inFormat = inFile.processingFormat
        guard
            let floatFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: floatFormat)
        else {
            throw AudioConversionError.cannotCreateConverter
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.downmix = inFormat.channelCount >= 2
        // 入力の sampleRate が 1 Hz 未満だと容量が UInt32 に収まらない（トラップしない。CR-16）。
        guard inFormat.sampleRate >= 1 else { throw AudioConversionError.cannotAllocateBuffer }
        let outFile = try AVAudioFile(
            forWriting: tmpOutput, settings: outputSettings,
            commonFormat: .pcmFormatInt16, interleaved: true)
        let outCapacity =
            AVAudioFrameCount((Double(inputFramesPerBuffer) * outputSampleRate / inFormat.sampleRate).rounded(.up))
            + 1024
        var readError: (any Error)?
        var finished = false
        while !finished {
            if deadline.isExceeded() { throw AudioConversionError.deadlineExceeded }
            guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: outCapacity) else {
                throw AudioConversionError.cannotAllocateBuffer
            }
            var conversionError: NSError?
            let status = converter.convert(to: floatBuffer, error: &conversionError) { _, inputStatus in
                // 末尾で read(into:) を呼ぶと nilError を投げる（T-16 で実測）。読む前に終わりを確かめる。
                if inFile.framePosition >= inFile.length {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inputFramesPerBuffer) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try inFile.read(into: inBuffer, frameCount: inputFramesPerBuffer)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let readError { throw readError }
            switch status {
            case .error:
                throw AudioConversionError.converterFailed(conversionError.map { ErrorText.describe($0) } ?? "unknown")
            case .endOfStream:
                finished = true
            case .haveData, .inputRanDry:
                break
            @unknown default:
                throw AudioConversionError.converterFailed("unknown status \(status.rawValue)")
            }
            if floatBuffer.frameLength > 0 {
                try writeInt16(floatBuffer, to: outFile)
            }
        }
        outFile.close()  // macOS 15 以上
        let fd = open(tmpOutput.path(percentEncoded: false), O_RDONLY)
        if fd >= 0 {
            _ = fsync(fd)
            _ = close(fd)
        }
    }

    static func writeInt16(_ floatBuffer: AVAudioPCMBuffer, to outFile: AVAudioFile) throws {
        let frames = floatBuffer.frameLength
        guard let source = floatBuffer.floatChannelData?[0],
            let intBuffer = AVAudioPCMBuffer(pcmFormat: outFile.processingFormat, frameCapacity: frames),
            let destination = intBuffer.int16ChannelData?[0]
        else {
            throw AudioConversionError.cannotAllocateBuffer
        }
        intBuffer.frameLength = frames
        for index in 0..<Int(frames) {
            // PLAN §8.3: clamp(lrint(x × 32768), −32768, 32767)
            destination[index] = Int16(clamping: lrint(Double(source[index]) * 32_768.0))
        }
        try outFile.write(from: intBuffer)
    }
}
