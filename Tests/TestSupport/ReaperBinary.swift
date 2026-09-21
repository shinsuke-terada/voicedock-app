// ビルドした voicedock-reaper を実際に起動する（PLAN §10.5「reaper 層はビルドした実行ファイルを起動する」）。
// テストターゲット ReaperTests は voicedock-reaper に依存しているので、.xctest と同じディレクトリに実行ファイルが在る。
import Darwin
import Foundation
import Synchronization
import VDContract

/// 1 回の起動の結果。
public struct ReaperRun: Sendable, Equatable {
    /// シグナルで終わったときは 128 + シグナル番号
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public struct ReaperBinaryError: Error, CustomStringConvertible {
    public let description: String
}

/// ビルドした reaper の実行ファイルを見つけて起動する。`/Volumes` 配下には一切触れない（`home` は必ず一時ディレクトリの下）。
public enum ReaperBinary {
    /// ビルドした実行ファイルの場所（見つからなければ投げる。skip ではなく fail。PLAN §10.2）
    /// 起点はこのファイルが静的にリンクされたテストバンドル（`Bundle(for:)`）。`swift test` では `Bundle.main` が
    /// ツールチェーンの swiftpm-testing-helper を指すので使わない。
    public static func url() throws -> URL {
        let bundle = Bundle(for: ReaperProcess.self).bundleURL
        var dir = bundle
        if dir.pathExtension == "xctest" { dir = dir.deletingLastPathComponent() }
        for _ in 0...4 {
            let candidate = dir.appendingPathComponent(Contract.reaperFileName, isDirectory: false)
            if isExecutableFile(candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw ReaperBinaryError(
            description: "voicedock-reaper が見つかりません（swift build をしてください）: " + bundle.path(percentEncoded: false))
    }

    /// `--home <home>` で起動して終わりを待つ
    public static func run(home: URL) throws -> ReaperRun {
        try run(executable: url(), arguments: ["--home", home.path(percentEncoded: false)])
    }

    /// 任意の引数で起動する（`--version` と RV-00 のテスト用）
    public static func run(executable: URL, arguments: [String]) throws -> ReaperRun {
        try start(executable: executable, arguments: arguments).wait()
    }

    /// 起動して制御を返す（SIGTERM のテスト用）
    public static func start(executable: URL, arguments: [String]) throws -> ReaperProcess {
        try ReaperProcess(executable: executable, arguments: arguments)
    }

    /// lstat で通常ファイルかつ access(X_OK) が通る
    private static func isExecutableFile(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }
}

/// 起動中の reaper。stdout / stderr は別スレッドで読み切る（パイプの詰まりを避ける）。
public final class ReaperProcess: Sendable {
    private struct Output {
        var stdout = Data()
        var stderr = Data()
        var done = 0
    }

    private let process: Mutex<Process>
    private let output = Mutex<Output>(Output())
    private let finished = DispatchSemaphore(value: 0)

    init(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // 余計な環境を渡さない
        process.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        self.process = Mutex(process)
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        Thread.detachNewThread { [self] in
            let data = outHandle.readDataToEndOfFile()
            output.withLock {
                $0.stdout = data
                $0.done += 1
            }
            finished.signal()
        }
        Thread.detachNewThread { [self] in
            let data = errHandle.readDataToEndOfFile()
            output.withLock {
                $0.stderr = data
                $0.done += 1
            }
            finished.signal()
        }
    }

    /// SIGTERM
    public func sendTermination() {
        process.withLock { $0.terminate() }
    }

    /// 両方のパイプを読み終えてから終わりを待つ
    public func wait() -> ReaperRun {
        while output.withLock({ $0.done }) < 2 { finished.wait() }
        let (status, reason) = process.withLock { p -> (Int32, Process.TerminationReason) in
            p.waitUntilExit()
            return (p.terminationStatus, p.terminationReason)
        }
        let code = reason == .uncaughtSignal ? 128 + status : status
        let (out, err) = output.withLock { ($0.stdout, $0.stderr) }
        return ReaperRun(
            exitCode: code, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
    }
}
