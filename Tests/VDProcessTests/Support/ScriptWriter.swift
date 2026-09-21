// テスト用のシェルスクリプトを書く補助と、孫の消滅を待つ補助（T-12）。
import Darwin
import Foundation

enum ScriptWriter {
    /// `#!/bin/sh\n` + body を書いて chmod 0755 する
    static func write(_ body: String, name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }
}

/// `kill(pid, 0) == -1 && errno == ESRCH` になるまで 50 ms ごとに待つ（ゾンビの間は kill が成功するため）。消えれば true
func waitUntilGone(pid: pid_t, within: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: within)
    while true {
        if kill(pid, 0) == -1 && errno == ESRCH { return true }
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

/// スクリプトが pid ファイルに書いた孫の pid を読む
func readPID(_ url: URL) throws -> pid_t? {
    let text = try String(contentsOf: url, encoding: .utf8)
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}
