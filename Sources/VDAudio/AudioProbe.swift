// 音声ファイルの長さ（秒）を調べる（PLAN §8.1 の登録。voicedock の ffprobe の代わり）。
import AVFoundation

public enum AudioProbe {
    /// AVAudioFile で開き length / fileFormat.sampleRate。開けない・sampleRate が 0 以下なら nil
    public static func durationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0 else { return nil }
        let seconds = Double(file.length) / rate
        return seconds.isFinite ? seconds : nil
    }
}
