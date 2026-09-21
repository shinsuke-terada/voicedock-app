// 読み取り専用での再マウントと、再走査の契機の購読（PLAN §8.1。ロック 2-B の実施側）。diskutil の出力文言は使わない。
import Foundation
import VDProcess

/// 読み取り専用での再マウントの結果（PLAN §8.1）。
public enum RemountOutcome: Equatable, Sendable {
    /// 既に ro。何もしなかった（DEL-31）
    case alreadyReadOnly
    /// unmount → mount readOnly が成功し、マウント一覧に node が在った
    case remounted(newPath: String)
    /// no_device_node / unmount_failed / mount_failed
    case failed(reason: String)
}

public protocol Remounter: Sendable {
    func remountReadOnly(path: String, node: String) async -> RemountOutcome
}

/// diskutil で読み取り専用に再マウントする。still_writable の判定はここでしない（呼び手が statfs の観測で判定する。DEL-31）
public struct DiskutilRemounter: Remounter {
    public static let diskutil = URL(fileURLWithPath: "/usr/sbin/diskutil")
    public static let timeout: Duration = .seconds(60)

    let runner: any ProcessRunning
    let inspector: any MountInspector
    /// 本番は false（P0-02。-mountPoint 付きの mount は実機で毎回失敗した）。テストのディスクイメージは true
    let useMountPoint: Bool

    public init(runner: any ProcessRunning, inspector: any MountInspector, useMountPoint: Bool) {
        self.runner = runner
        self.inspector = inspector
        self.useMountPoint = useMountPoint
    }

    public func remountReadOnly(path: String, node: String) async -> RemountOutcome {
        guard let info = inspector.mountInfo(path: path) else { return .failed(reason: "no_device_node") }
        // 毎回 unmount し直さない。DiskArbitration は ro の unmount を拒むことがある（DEL-31・#107）
        if info.readOnly { return .alreadyReadOnly }
        guard node.hasPrefix("/dev/") else { return .failed(reason: "no_device_node") }
        let unmount = await runner.run(
            ProcessSpec(
                executable: Self.diskutil, arguments: ["unmount", path], environment: ProcessEnvironment.cLocale),
            timeout: Self.timeout)
        guard unmount.termination == .exited(0) else { return .failed(reason: "unmount_failed") }
        let arguments = useMountPoint ? ["mount", "readOnly", "-mountPoint", path, node] : ["mount", "readOnly", node]
        let mount = await runner.run(
            ProcessSpec(executable: Self.diskutil, arguments: arguments, environment: ProcessEnvironment.cLocale),
            timeout: Self.timeout)
        guard mount.termination == .exited(0) else { return .failed(reason: "mount_failed") }
        guard let newPath = inspector.allMounts().first(where: { $0.mountFromName == node })?.mountOnName else {
            return .failed(reason: "mount_failed")
        }
        return .remounted(newPath: newPath)
    }
}

/// 再走査の契機（マウント・アンマウント・スリープ復帰）。種類は走査の側で区別しないので要素は Void
public protocol MountEventSource: Sendable {
    /// 購読ごとに新しいストリーム。マウント・アンマウント・スリープ復帰のたびに () を 1 つ流す。ストリームが終われば購読をやめる
    func events() -> AsyncStream<Void>
}
