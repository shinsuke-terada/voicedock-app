// 偽 argmax-cli（PLAN §8.4.1。F-89）。FakeWhisper と同じ作り。
import Foundation

/// `--rttm-path` の先に何を書くか。
public enum FakeArgmaxOutput: Sendable {
    case rttm([String])
    case none
    case custom(String)
}

/// 偽 argmax-cli。argv を `<script>.argv` に書き、`--help` で help を出して 0、`--rttm-path` の次の値へ出力を書く。
public enum FakeArgmax {
    /// Tests/Fixtures/argmax-cli-diarize-help.txt と同じフラグを持つ短い help。
    public static let help = """
        OVERVIEW: Speaker diarization tool

        USAGE: argmax-cli diarize --audio-path <audio-path> [--rttm-path <rttm-path>] [--model-path <model-path>] [--use-exclusive-reconciliation]

        OPTIONS:
          --audio-path <audio-path>
                                  Path to the audio file to process
          --rttm-path <rttm-path> Path to save the diarization output as RTTM
          --model-path <model-path>
                                  Path of local model files (skips download)
          --use-exclusive-reconciliation
                                  Use exclusive reconciliation in post processing
          -h, --help              Show help information.
        """

    /// 偽 argmax-cli のシェルスクリプトを書き、実行権を付けて返す。
    @discardableResult
    public static func write(
        to script: URL, output: FakeArgmaxOutput = .rttm(["SPEAKER audio16k 1 0.000 2.000 <NA> <NA> A <NA> <NA>"]),
        exitCode: Int32 = 0, sleepSeconds: Double = 0, selfSignal: Int32? = nil
    ) throws -> URL {
        let scriptPath = script.path(percentEncoded: false)
        let wait = sleepSeconds == 0 ? "" : "sleep \(sleepSeconds.description)"
        let signalLine = selfSignal.map { "kill -\($0) $$" } ?? ""
        let body: [String]
        switch output {
        case .rttm(let lines) where lines.isEmpty:
            body = ["  : > \"$out\""]
        case .rttm(let lines):
            body = ["  cat > \"$out\" <<'RTTM_EOF'"] + lines + ["RTTM_EOF"]
        case .none:
            body = ["  :"]
        case .custom(let s):
            body = ["  cat > \"$out\" <<'RTTM_EOF'", s, "RTTM_EOF"]
        }
        let lines =
            [
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
                "out=''",
                "take=0",
                "for arg in \"$@\"; do",
                "  if [ \"$take\" = \"1\" ]; then out=\"$arg\"; take=0; continue; fi",
                "  if [ \"$arg\" = \"--rttm-path\" ]; then take=1; fi",
                "done",
                wait,
                signalLine,
                "if [ -n \"$out\" ]; then",
            ] + body + [
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
}
