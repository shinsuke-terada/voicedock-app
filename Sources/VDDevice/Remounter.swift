// 読み取り専用での再マウントと、再走査の契機の購読（PLAN §8.1。ロック 2-B の実施側）。diskutil の出力文言は使わない。
import Foundation
import VDCore
import VDProcess

/// 読み取り専用での再マウントの結果（PLAN §8.1）。
public enum RemountOutcome: Equatable, Sendable {
    /// 既に ro。何もしなかった（DEL-31）
    case alreadyReadOnly
    /// unmount → mount readOnly が成功し、マウント一覧に node が在った
    case remounted(newPath: String)
    /// no_device_node（statfs が取れない・node が /dev/ で始まらない・今の statfs の node やマウント点と合わない。F-73）/
    /// unmount_failed / mount_failed
    case failed(reason: String)

    /// unmount は成功し、mount readOnly が失敗した（か、成功と言いながらマウント一覧に node が無い）ときの理由語。
    /// デバイスはアンマウントされたまま残りうるので、走査は snapshot の unavailable に載せる（F-81）。
    /// 診断（DR-11）と要対応が unavailable の値をこれと比べるので公開する
    public static let mountFailedReason = "mount_failed"
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
        // 判定のときの node と、今の statfs（上の 1 回）を照らす（F-73）。path がそれ自身マウント点で、その f_mntfromname が
        // node のときだけ diskutil を呼ぶ。判定から今までに挿し直されて disk 番号が変わった・外れて親の FS が見えている、
        // のどちらでも別のディスクを unmount / mount しない。比べるのはスカラー列（00-api-map §0）
        guard PyText.scalarsEqual(info.mountFromName, node),
            let real = SystemMountInspector.realPath(path), PyText.scalarsEqual(info.mountOnName, real)
        else { return .failed(reason: "no_device_node") }
        let unmount = await runner.run(
            ProcessSpec(
                executable: Self.diskutil, arguments: ["unmount", path], environment: ProcessEnvironment.cLocale),
            timeout: Self.timeout)
        guard unmount.termination == .exited(0) else { return .failed(reason: "unmount_failed") }
        let arguments = useMountPoint ? ["mount", "readOnly", "-mountPoint", path, node] : ["mount", "readOnly", node]
        let mount = await runner.run(
            ProcessSpec(executable: Self.diskutil, arguments: arguments, environment: ProcessEnvironment.cLocale),
            timeout: Self.timeout)
        guard mount.termination == .exited(0) else { return .failed(reason: RemountOutcome.mountFailedReason) }
        // node はスカラー列で探す（00-api-map §0。正準等価で別の項目に当てない。F-81）
        guard
            let newPath = inspector.allMounts().first(where: { PyText.scalarsEqual($0.mountFromName, node) })?
                .mountOnName
        else { return .failed(reason: RemountOutcome.mountFailedReason) }
        return .remounted(newPath: newPath)
    }
}

/// 再走査の契機（マウント・アンマウント・スリープ復帰）。種類は走査の側で区別しないので要素は Void
public protocol MountEventSource: Sendable {
    /// 購読ごとに新しいストリーム。マウント・アンマウント・スリープ復帰のたびに () を 1 つ流す。ストリームが終われば購読をやめる
    func events() -> AsyncStream<Void>
}
