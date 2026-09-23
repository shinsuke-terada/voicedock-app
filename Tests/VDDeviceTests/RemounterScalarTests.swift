// 再マウントの後、マウント一覧から node をスカラー列で探す（PLAN §8.1・F-81・issue #119）。
// ScriptedProcessRunner と FakeMountInspector だけ（本物の diskutil を動かさない）。パスは一時ディレクトリ（/Volumes ではない）。
import Foundation
import TestSupport
import Testing
import VDProcess

@testable import VDDevice

@Suite("DiskutilRemounter のマウント一覧の node の照合（F-81）")
struct RemounterScalarTests {
    /// 今の statfs が path と node を返し、マウント一覧は mounts の inspector
    static func inspector(path: String, node: String, mounts: [MountInfo]) -> FakeMountInspector {
        var inspector = FakeMountInspector()
        inspector.infos[path] = MountInfo(
            mountOnName: path, mountFromName: node, fsTypeName: "msdos", readOnly: false, freeBytes: 1_000_000)
        inspector.mountPoints.insert(path)
        inspector.mounts = mounts
        return inspector
    }

    static func listed(_ path: String, from node: String) -> MountInfo {
        MountInfo(mountOnName: path, mountFromName: node, fsTypeName: "msdos", readOnly: true, freeBytes: 1_000_000)
    }

    /// unmount と mount がどちらも 0 で終わる
    static func runner() -> ScriptedProcessRunner {
        ScriptedProcessRunner(
            results: [ProcessResult.Termination.exited(0), .exited(0)].map {
                ProcessResult(termination: $0, stdoutTail: Data(), stderrTail: Data())
            })
    }

    @Test("F-81 対照: ASCII の node はマウント一覧に同じ綴りの項目があれば remounted")
    func asciiNodeIsFound() async throws {
        let f = try RemounterNodeCheckTests.Fixture()
        let node = "/dev/disk99"
        let sut = DiskutilRemounter(
            runner: Self.runner(),
            inspector: Self.inspector(path: f.path, node: node, mounts: [Self.listed(f.path, from: node)]),
            useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: node) == .remounted(newPath: f.path))
    }

    @Test("F-81 マウント一覧の node が正準等価でもスカラーが違えば mount_failed（別の項目に当てない）")
    func canonicallyEqualNodeIsNotFound() async throws {
        let f = try RemounterNodeCheckTests.Fixture()
        let node = "/dev/disk\u{304C}"
        let decomposed = "/dev/disk\u{304B}\u{3099}"
        // 準備の確かめ: == では等しく、スカラー列では違う（これが成り立たなければテストが空振りする）
        try #require(decomposed == node)
        try #require(Array(decomposed.unicodeScalars) != Array(node.unicodeScalars))
        let runner = Self.runner()
        let sut = DiskutilRemounter(
            runner: runner,
            inspector: Self.inspector(path: f.path, node: node, mounts: [Self.listed(f.path, from: decomposed)]),
            useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: node) == .failed(reason: "mount_failed"))
        #expect(await runner.recorded.map(\.arguments) == [["unmount", f.path], ["mount", "readOnly", node]])
    }

    @Test("F-81 mount の後のマウント一覧が空なら mount_failed（TEST-28）")
    func emptyMountListIsMountFailed() async throws {
        let f = try RemounterNodeCheckTests.Fixture()
        let node = "/dev/disk99"
        let sut = DiskutilRemounter(
            runner: Self.runner(), inspector: Self.inspector(path: f.path, node: node, mounts: []),
            useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: node) == .failed(reason: "mount_failed"))
    }
}
