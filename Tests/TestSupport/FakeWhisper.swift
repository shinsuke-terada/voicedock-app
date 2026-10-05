// 偽 whisper-cli（PLAN §10.2。voicedock tests/fixtures/fake_whisper.py）。
import Foundation
import VDCore

/// 生 JSON の 1 区間。秒で書き、出力時にミリ秒へ直す。
public struct FakeWhisperUtterance: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(_ start: Double, _ end: Double, _ text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// `-of` の先に何を書くか。
public enum FakeWhisperOutput: Sendable {
    case json, none, broken
    case custom(String)
}

/// 偽 whisper-cli。生 JSON の形は whisper.cpp v1.9.4 の `-oj` と同じ（`offsets` はミリ秒）。
public enum FakeWhisper {
    public static let defaultUtterances: [FakeWhisperUtterance] = [
        FakeWhisperUtterance(0.0, 3.2, " おはようございます。"),
        FakeWhisperUtterance(5.5, 9.0, " 今日の予定を確認します。"),
    ]

    public static let helpWithVAD = """
        usage: whisper-cli [options] file0 file1 ...
          -m FNAME,  --model FNAME
          -f FNAME,  --file FNAME
          -oj,       --output-json
                     --vad
                     --vad-model FNAME
                     --vad-threshold N
                     --vad-min-speech-duration-ms N
                     --vad-min-silence-duration-ms N
                     --vad-speech-pad-ms N
        """

    public static let helpWithoutVAD = """
        usage: whisper-cli [options] file0 file1 ...
          -m FNAME,  --model FNAME
          -f FNAME,  --file FNAME
          -oj,       --output-json
        """

    /// Python の json.dumps(ensure_ascii=False) の既定（区切り ", " と ": "）と同じ 1 行の JSON。
    public static func rawDocument(
        _ utterances: [FakeWhisperUtterance] = defaultUtterances, language: String = "ja"
    ) -> String {
        let items = utterances.map { u in
            "{\"timestamps\": {\"from\": \(quote(stamp(u.start))), \"to\": \(quote(stamp(u.end)))}, "
                + "\"offsets\": {\"from\": \(millis(u.start)), \"to\": \(millis(u.end))}, "
                + "\"text\": \(quote(u.text))}"
        }
        return "{\"systeminfo\": \"AVX = 0 | NEON = 1 |\", "
            + "\"model\": {\"type\": \"large\", \"multilingual\": true}, "
            + "\"params\": {\"model\": \"ggml-large-v3-turbo-q8_0.bin\", \"language\": \(quote(language))}, "
            + "\"result\": {\"language\": \(quote(language))}, "
            + "\"transcription\": [\(items.joined(separator: ", "))]}"
    }

    /// 偽 whisper-cli のシェルスクリプトを書き、実行権を付けて返す。
    @discardableResult
    public static func write(
        to script: URL, utterances: [FakeWhisperUtterance] = defaultUtterances, language: String = "ja",
        exitCode: Int32 = 0, stderr: String = "", sleepSeconds: Double = 0,
        grandchildMarker: URL? = nil, selfSignal: Int32? = nil,
        help: String = helpWithVAD, output: FakeWhisperOutput = .json
    ) throws -> URL {
        let scriptPath = script.path(percentEncoded: false)
        let wait: String
        if sleepSeconds == 0 {
            wait = ""
        } else if let marker = grandchildMarker {
            wait = "( sleep \(sleepSeconds.description); touch '\(marker.path(percentEncoded: false))' ) &\nwait"
        } else {
            wait = "sleep \(sleepSeconds.description)"
        }
        let stderrLine =
            stderr.isEmpty ? "" : ">&2 printf %s '\(stderr.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        let signalLine = selfSignal.map { "kill -\($0) $$" } ?? ""
        let (writes, document): (Bool, String)
        switch output {
        case .json: (writes, document) = (true, rawDocument(utterances, language: language))
        case .none: (writes, document) = (false, "")
        case .broken: (writes, document) = (true, "{\"transcription\": [")
        case .custom(let s): (writes, document) = (true, s)
        }
        let lines = [
            "#!/bin/sh",
            "printf '%s\\n' \"$@\" > '\(scriptPath).argv'",
            "for arg in \"$@\"; do",
            "  if [ \"$arg\" = \"--help\" ] || [ \"$arg\" = \"-h\" ]; then",
            "    cat <<'HELP_EOF'",
            help,
            "HELP_EOF",
            "    exit 0",
            "  fi",
            "done",
            "base=''",
            "take=0",
            "for arg in \"$@\"; do",
            "  if [ \"$take\" = \"1\" ]; then base=\"$arg\"; take=0; continue; fi",
            "  if [ \"$arg\" = \"-of\" ]; then take=1; fi",
            "done",
            wait,
            stderrLine,
            signalLine,
            "if [ -n \"$base\" ] && [ \"\(writes ? "1" : "0")\" = \"1\" ]; then",
            "  cat > \"$base.json\" <<'JSON_EOF'",
            document,
            "JSON_EOF",
            "fi",
            "exit \(exitCode)",
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return script
    }

    /// スクリプトが受け取った argv（`<script>.argv` の各行）。無ければ []。
    public static func recordedArgv(_ script: URL) -> [String] {
        let url = URL(fileURLWithPath: script.path(percentEncoded: false) + ".argv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Python の round(秒 × 1000)。
    private static func millis(_ seconds: Double) -> Int {
        Int((seconds * 1000).rounded(.toNearestOrEven))
    }

    /// `HH:MM:SS,mmm`（voicedock の _stamp）。
    private static func stamp(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let ms = Int(((seconds - Double(whole)) * 1000).rounded(.toNearestOrEven))
        return String(format: "%02d:%02d:%02d,%03d", whole / 3600, whole / 60 % 60, whole % 60, ms)
    }

    private static func quote(_ s: String) -> String { "\"" + PyJSON.escape(s) + "\"" }
}
