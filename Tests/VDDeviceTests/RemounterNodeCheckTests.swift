// 再マウントは今の statfs の node とマウント点を照らしてから diskutil を呼ぶ（PLAN §8.1・F-73・issue #113）。
// ScriptedProcessRunner と FakeMountInspector だけ（本物の diskutil を動かさない）。パスは一時ディレクトリ（/Volumes ではない）。
import Foundation
import TestSupport
import Testing
import VDProcess

@testable import VDDevice

@Suite("DiskutilRemounter の node の照合（F-73）")
struct RemounterNodeCheckTests {
    /// 判定のとき（走査の始め）に観測した node。実在しない番号
    static let node = "/dev/disk99"

    struct Fixture {
        let tmp: TempDirectory
        /// <tmp>/Volumes/<name>。作ったときはその realpath（TempDirectory.url は /var/… のことがあるので realpath にしておく）
        let path: String

        init(createPath: Bool = true, name: String = "VDT0073") throws {
            tmp = try TempDirectory()
            let raw = tmp.url.appendingPathComponent("Volumes", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false).path(percentEncoded: false)
            if createPath { try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true) }
            path = SystemMountInspector.realPath(raw) ?? raw
        }

        /// 今の statfs（mountInfo(path:)）が mountOn / mountFrom を返す inspector。一覧には今の node の項目
        func inspector(mountOn: String? = nil, mountFrom: String = RemounterNodeCheckTests.node) -> FakeMountInspector {
            var inspector = FakeMountInspector()
            inspector.infos[path] = MountInfo(
                mountOnName: mountOn ?? path, mountFromName: mountFrom, fsTypeName: "msdos", readOnly: false,
                freeBytes: 1_000_000)
            inspector.mountPoints.insert(path)
            inspector.mounts = [
                MountInfo(
                    mountOnName: path, mountFromName: mountFrom, fsTypeName: "msdos", readOnly: true,
                    freeBytes: 1_000_000)
            ]
            return inspector
        }
    }

    static func runner() -> ScriptedProcessRunner {
        ScriptedProcessRunner(
            results: [ProcessResult.Termination.exited(0), .exited(0)].map {
                ProcessResult(termination: $0, stdoutTail: Data(), stderrTail: Data())
            })
    }

    @Test("F-73 今の node が判定のときの node と違えば（挿し直しで disk 番号が変わった）diskutil を 1 回も呼ばない")
    func f73ChangedNodeDoesNotRunDiskutil() async throws {
        let f = try Fixture()
        let runner = Self.runner()
        let sut = DiskutilRemounter(
            runner: runner, inspector: f.inspector(mountFrom: "/dev/disk98"), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "no_device_node"))
        #expect(await runner.recorded == [])
    }

    @Test("F-73 node は前方一致で見ない（/dev/disk99 と /dev/disk99s1 は別のもの）")
    func f73NodePrefixIsNotEnough() async throws {
        let f = try Fixture()
        let runner = Self.runner()
        let sut = DiskutilRemounter(
            runner: runner, inspector: f.inspector(mountFrom: "/dev/disk99s1"), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "no_device_node"))
        #expect(await runner.recorded == [])
    }

    @Test("F-73 マウント点はスカラー列で比べる（正準等価でもスカラーが違えば diskutil を 1 回も呼ばない）")
    func f73MountPointIsComparedByScalars() async throws {
        // 名前に NFC の「が」（U+304C）を含むディレクトリ。statfs の f_mntonname の側にだけ、スカラーの違う形を渡す
        let f = try Fixture(name: "VDT0073\u{304C}")
        let nfc = f.path.precomposedStringWithCanonicalMapping
        let nfd = f.path.decomposedStringWithCanonicalMapping
        let other = Array(f.path.unicodeScalars) == Array(nfc.unicodeScalars) ? nfd : nfc
        // 準備の確かめ: == では等しく、スカラー列では違う（これが成り立たなければテストが空振りする）
        try #require(other == f.path)
        try #require(Array(other.unicodeScalars) != Array(f.path.unicodeScalars))
        let runner = Self.runner()
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(mountOn: other), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "no_device_node"))
        #expect(await runner.recorded == [])
    }

    @Test("F-73 path がマウント点でない（外れて親の FS が見えている）なら diskutil を 1 回も呼ばない")
    func f73NotAMountPointDoesNotRunDiskutil() async throws {
        let f = try Fixture()
        let runner = Self.runner()
        let parent = f.tmp.url.path(percentEncoded: false)
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(mountOn: parent), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "no_device_node"))
        #expect(await runner.recorded == [])
    }

    @Test("F-73 path の realpath が取れない（もう無い）なら diskutil を 1 回も呼ばない")
    func f73MissingPathDoesNotRunDiskutil() async throws {
        let f = try Fixture(createPath: false)
        let runner = Self.runner()
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "no_device_node"))
        #expect(await runner.recorded == [])
    }

    @Test("F-73 今の statfs の node が空なら diskutil を 1 回も呼ばない（TEST-28）")
    func f73EmptyCurrentNodeDoesNotRunDiskutil() async throws {
        let f = try Fixture()
        let runner = Self.runner()
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(mountFrom: ""), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "no_device_node"))
        #expect(await runner.recorded == [])
    }

    @Test("F-73 対照: node もマウント点も今の statfs と合えば unmount → mount readOnly を呼ぶ")
    func f73MatchingNodeRemounts() async throws {
        let f = try Fixture()
        let runner = Self.runner()
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .remounted(newPath: f.path))
        let recorded = await runner.recorded
        #expect(recorded.map(\.arguments) == [["unmount", f.path], ["mount", "readOnly", "/dev/disk99"]])
    }
}
