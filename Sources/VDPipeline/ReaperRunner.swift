// <HOME>/bin/voicedock-reaper の検証と起動（PLAN §8.9.3・§8.9.6）。起動できる場所はここだけで、パスを引数に取らない。
// T-36 は検証の部分を書き、T-38 が run() を足す。
import Darwin
import Foundation
import VDContract
import VDProcess

public struct ReaperFileKey: Equatable, Sendable {
    public let inode: UInt64
    public let size: Int64
    public let mtimeSeconds: Int
    public let mtimeNanoseconds: Int
}

public enum ReaperInstallation: Equatable, Sendable {
    /// 無い・lstat が失敗・通常ファイルでない（symlink・ディレクトリを含む）
    case absent
    case present(ReaperFileKey)
}

public struct ReaperRunner: Sendable {
    public static let versionTimeout: Duration = .seconds(10)
    let layout: HomeLayout
    let runner: any ProcessRunning
    let verifier: any SignatureVerifier

    public init(layout: HomeLayout, runner: any ProcessRunning, verifier: any SignatureVerifier) {
        self.layout = layout
        self.runner = runner
        self.verifier = verifier
    }

    /// `lstat(p(layout.reaperExecutable))`。成功して S_IFREG なら .present(st_ino, st_size, st_mtimespec)、それ以外は .absent
    public func installation() -> ReaperInstallation {
        var st = stat()
        guard lstat(layout.reaperExecutable.path(percentEncoded: false), &st) == 0,
            (st.st_mode & S_IFMT) == S_IFREG
        else { return .absent }
        return .present(
            ReaperFileKey(
                inode: UInt64(st.st_ino), size: Int64(st.st_size), mtimeSeconds: Int(st.st_mtimespec.tv_sec),
                mtimeNanoseconds: Int(st.st_mtimespec.tv_nsec)))
    }

    /// `verifier.verify(url: layout.reaperExecutable)`
    public func signatureIsValid() -> Bool {
        verifier.verify(url: layout.reaperExecutable)
    }

    /// `voicedock-reaper --version` の stdout（ProcessResult.stdoutText のまま）。終了コード 0 でなければ nil。
    /// **署名の検証が済んだ後にだけ呼ぶ**（呼び手の責任。未検証のコードを実行しない。§8.9.3 の 5）
    public func runVersion() async -> String? {
        switch await versionRun() {
        case .stdout(let text): return text
        case .notLaunched: return nil
        }
    }

    /// `--version` の結果。ProcessRunner が閉じた後（アプリの終了の途中）で起動できなかったときは `.notLaunched`
    /// （版を観測できなかった。版の不一致として決着させない。F-76）。それ以外は runVersion と同じ stdout（0 でなければ nil）
    enum VersionRun: Equatable, Sendable {
        case stdout(String?)
        case notLaunched
    }

    /// `--version` を起動する（署名の検証が済んだ後にだけ呼ぶ）。
    func versionRun() async -> VersionRun {
        let spec = ProcessSpec(
            executable: layout.reaperExecutable, arguments: ["--version"], environment: ProcessEnvironment.standard)
        let result = await runner.run(spec, timeout: Self.versionTimeout)
        if result.termination == .spawnFailed(errno: ProcessRunner.closedErrno) { return .notLaunched }
        guard result.termination == .exited(0) else { return .stdout(nil) }
        return .stdout(result.stdoutText)
    }

    /// `await runVersion() == AppVersion.string + "\n"`
    public func versionMatches() async -> Bool {
        await runVersion() == AppVersion.string + "\n"
    }
}

public enum ReaperRunOutcome: Equatable, Sendable {
    /// DeletionReason.signature
    case notLaunched(reason: String)
    case finished(ProcessResult)
}

extension ReaperRunner {
    public static let runTimeout: Duration = .seconds(120)

    /// 起動の直前に署名を検証し（ND-41 の 2 層目）、<HOME>/bin/voicedock-reaper --home <HOME> を起動して終わりを待つ。パスを引数に取らない（§8.9.3 の 1）
    /// 版は runReaperIfNeeded の直前の readiness(useCache: false) が確かめる（子プロセスを 2 回起動しない）
    public func run() async -> ReaperRunOutcome {
        guard signatureIsValid() else { return .notLaunched(reason: DeletionReason.signature) }
        let spec = ProcessSpec(
            executable: layout.reaperExecutable, arguments: ["--home", layout.root.path(percentEncoded: false)],
            environment: ProcessEnvironment.standard)
        return .finished(await runner.run(spec, timeout: Self.runTimeout))
    }
}
