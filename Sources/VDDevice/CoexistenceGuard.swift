// voicedock の Helper との共存ガード（PLAN §8.1 手順 1・DR-13）。
import Foundation
import VDProcess

public struct CoexistenceGuard: Sendable {
    public static let label = "com.voicedock.ingest"
    public static let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    public static let timeout: Duration = .seconds(10)

    let runner: any ProcessRunning
    let uid: uid_t

    public init(runner: any ProcessRunning, uid: uid_t) {
        self.runner = runner
        self.uid = uid
    }

    /// LaunchAgent が「登録されている」か（今動いているかではない）。
    /// 終了コード 0 だけが真。0 以外の終了・シグナル・タイムアウト・起動失敗は偽（原因の分からない沈黙を避ける。PLAN §8.1）
    public func isVoicedockHelperLoaded() async -> Bool {
        let spec = ProcessSpec(
            executable: Self.launchctl, arguments: Self.arguments(uid: uid), environment: ProcessEnvironment.cLocale)
        let result = await runner.run(spec, timeout: Self.timeout)
        return result.termination == .exited(0)
    }

    /// argv（テストでも使う）
    public static func arguments(uid: uid_t) -> [String] {
        ["print", ["gui", String(uid), Self.label].joined(separator: "/")]
    }
}
