// 偽の llama-server（シェルスクリプト）。起動の回数・引数・API キーファイルの中身を記録する（00-api-map §15。T-21）。
import Foundation

/// `<directory>/Helpers/llama-server` に置く偽物。`AppPaths(helpers: helpersDirectory)` で使う。
public struct FakeLlamaServer: Sendable {
    public enum Mode: Sendable, Equatable {
        /// exec /bin/sleep 600
        case stayAlive
        /// すぐ exit
        case exitImmediately(code: Int32)
        /// n 回目より前の起動は exit、n 回目以降は留まる
        case exitBeforeAttempt(Int, code: Int32)
    }

    private let directory: URL
    /// <directory>/Helpers（この中の llama-server を AppPaths(helpers:) に渡す）
    public let helpersDirectory: URL

    public init(directory: URL, mode: Mode) throws {
        self.directory = directory
        helpersDirectory = directory.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersDirectory, withIntermediateDirectories: true)
        let modeLines: String
        switch mode {
        case .stayAlive:
            modeLines = "exec /bin/sleep 600"
        case .exitImmediately(let code):
            modeLines = "exit \(code)"
        case .exitBeforeAttempt(let n, let code):
            modeLines = "if [ \"$N\" -lt \(n) ]; then exit \(code); fi\nexec /bin/sleep 600"
        }
        let script = """
            #!/bin/sh
            D="\(directory.path(percentEncoded: false))"
            N=$(cat "$D/count" 2>/dev/null || echo 0)
            N=$((N + 1))
            echo "$N" > "$D/count"
            : > "$D/argv.$N"
            for a in "$@"; do printf '%s\\n' "$a" >> "$D/argv.$N"; done
            K=""
            while [ $# -gt 0 ]; do
              if [ "$1" = "--api-key-file" ]; then K="$2"; fi
              shift
            done
            if [ -n "$K" ]; then cat "$K" > "$D/key.$N"; fi
            echo "fake llama-server attempt $N" 1>&2
            \(modeLines)

            """
        let executable = helpersDirectory.appendingPathComponent("llama-server", isDirectory: false)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
    }

    /// <directory>/count（無ければ 0）
    public func invocationCount() -> Int {
        guard let text = try? String(contentsOf: file("count"), encoding: .utf8) else { return 0 }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// <directory>/argv.<n> の行（1 始まり）
    public func arguments(ofInvocation n: Int) throws -> [String] {
        let text = try String(contentsOf: file("argv.\(n)"), encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// <directory>/key.<n> の中身
    public func apiKey(ofInvocation n: Int) throws -> String {
        try String(contentsOf: file("key.\(n)"), encoding: .utf8)
    }

    private func file(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }
}
