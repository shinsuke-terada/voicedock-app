// whisper-cli --help に VAD の 6 フラグが逐語で在るか（DR-04。本アプリで強化）。
public enum WhisperHelpCheck {
    public static let vadFlags = [
        "--vad", "--vad-model", "--vad-threshold",
        "--vad-min-speech-duration-ms", "--vad-min-silence-duration-ms", "--vad-speech-pad-ms",
    ]

    /// 欠けたフラグを vadFlags の順で返す（空なら全部在る）。
    /// DR-04: トークン単位の完全一致。`--vad` は `--vad-model` の接頭辞なので部分一致では判定しない。
    public static func missingVADFlags(helpOutput: String) -> [String] {
        var tokens: Set<String> = []
        for token in helpOutput.split(whereSeparator: \.isWhitespace) {
            var word = String(token)
            if word.hasSuffix(",") { word.removeLast() }
            tokens.insert(word)
        }
        return vadFlags.filter { !tokens.contains($0) }
    }
}
