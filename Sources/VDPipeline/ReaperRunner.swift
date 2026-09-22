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
        let spec = ProcessSpec(
            executable: layout.reaperExecutable, arguments: ["--version"], environment: ProcessEnvironment.standard)
        let result = await runner.run(spec, timeout: Self.versionTimeout)
        guard result.termination == .exited(0) else { return nil }
        return result.stdoutText
    }

    /// `await runVersion() == AppVersion.string + "\n"`
    public func versionMatches() async -> Bool {
        await runVersion() == AppVersion.string + "\n"
    }
}
