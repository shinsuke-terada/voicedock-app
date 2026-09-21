// DiskutilRemounter の手順と argv（T-15 §5.2）。ScriptedProcessRunner と FakeMountInspector だけ（本物の diskutil を動かさない）。
import Foundation
import TestSupport
import Testing
import VDProcess

@testable import VDDevice

@Suite("DiskutilRemounter")
struct RemounterTests {
    /// 実在しない番号
    static let node = "/dev/disk99"

    struct Fixture {
        let tmp: TempDirectory
        /// <tmp>/Volumes/DJIMIC3（/Volumes ではない）
        let path: String

        init() throws {
            tmp = try TempDirectory()
            path = tmp.url.appendingPathComponent("Volumes", isDirectory: true)
                .appendingPathComponent("DJIMIC3", isDirectory: false).path(percentEncoded: false)
        }

        /// path を rw で観測できる inspector。mounts には node の項目（mountOnName = mountedOn）
        func inspector(readOnly: Bool = false, mountedOn: String? = nil, listed: Bool = true) -> FakeMountInspector {
            var inspector = FakeMountInspector()
            let info = MountInfo(
                mountOnName: path, mountFromName: RemounterTests.node, fsTypeName: "msdos", readOnly: readOnly,
                freeBytes: 1_000_000)
            inspector.infos[path] = info
            inspector.mountPoints.insert(path)
            if listed {
                inspector.mounts = [
                    MountInfo(
                        mountOnName: mountedOn ?? path, mountFromName: RemounterTests.node, fsTypeName: "msdos",
                        readOnly: true, freeBytes: 1_000_000)
                ]
            }
            return inspector
        }
    }

    static func results(_ codes: [ProcessResult.Termination]) -> [ProcessResult] {
        codes.map { ProcessResult(termination: $0, stdoutTail: Data(), stderrTail: Data()) }
    }

    @Test("既に ro なら diskutil を 1 度も呼ばない（DEL-31）")
    func alreadyReadOnlyDoesNotUnmount() async throws {
        let f = try Fixture()
        let runner = ScriptedProcessRunner(results: Self.results([.exited(0), .exited(0)]))
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(readOnly: true), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .alreadyReadOnly)
        #expect(await runner.recorded == [])
    }

    @Test("unmount と mount readOnly の argv・環境・タイムアウト")
    func argvIsExact() async throws {
        let f = try Fixture()
        let runner = ScriptedProcessRunner(results: Self.results([.exited(0), .exited(0)]))
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .remounted(newPath: f.path))
        let recorded = await runner.recorded
        try #require(recorded.count == 2)
        let diskutil = URL(fileURLWithPath: "/usr/sbin/diskutil")
        #expect(recorded[0].executable == diskutil)
        #expect(recorded[0].arguments == ["unmount", f.path])
        #expect(recorded[1].executable == diskutil)
        #expect(recorded[1].arguments == ["mount", "readOnly", "/dev/disk99"])
        let cLocale = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        #expect(recorded[0].environment == cLocale)
        #expect(recorded[1].environment == cLocale)
        #expect(await runner.recordedTimeouts == [.seconds(60), .seconds(60)])
    }

    @Test("useMountPoint なら -mountPoint を付ける")
    func mountPointArgv() async throws {
        let f = try Fixture()
        let runner = ScriptedProcessRunner(results: Self.results([.exited(0), .exited(0)]))
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(), useMountPoint: true)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .remounted(newPath: f.path))
        let recorded = await runner.recorded
        try #require(recorded.count == 2)
        #expect(recorded[1].arguments == ["mount", "readOnly", "-mountPoint", f.path, "/dev/disk99"])
    }

    @Test("node が /dev/ で始まらなければ no_device_node（diskutil を呼ばない）", arguments: ["", "disk99"])
    func missingNodeIsNoDeviceNode(node: String) async throws {
        let f = try Fixture()
        let runner = ScriptedProcessRunner(results: Self.results([.exited(0), .exited(0)]))
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: node) == .failed(reason: "no_device_node"))
        #expect(await runner.recorded == [])
    }

    @Test("statfs が取れなければ no_device_node")
    func unobservableMountIsNoDeviceNode() async throws {
        let f = try Fixture()
        let runner = ScriptedProcessRunner(results: Self.results([.exited(0), .exited(0)]))
        let sut = DiskutilRemounter(runner: runner, inspector: FakeMountInspector(), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "no_device_node"))
        #expect(await runner.recorded == [])
    }

    @Test("unmount の失敗は unmount_failed（mount を呼ばない）")
    func unmountFailure() async throws {
        let f = try Fixture()
        let runner = ScriptedProcessRunner(results: Self.results([.exited(1)]))
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "unmount_failed"))
        #expect(await runner.recorded.count == 1)
    }

    @Test("mount の失敗は mount_failed")
    func mountFailure() async throws {
        let f = try Fixture()
        let runner = ScriptedProcessRunner(results: Self.results([.exited(0), .exited(1)]))
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "mount_failed"))
        #expect(await runner.recorded.count == 2)
    }

    @Test("タイムアウトも失敗")
    func timeoutIsFailure() async throws {
        let f = try Fixture()
        let runner = ScriptedProcessRunner(results: Self.results([.timedOut]))
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "unmount_failed"))
        #expect(await runner.recorded.count == 1)
    }

    @Test("成功してもマウント一覧に無ければ mount_failed")
    func mountedButNotListed() async throws {
        let f = try Fixture()
        let runner = ScriptedProcessRunner(results: Self.results([.exited(0), .exited(0)]))
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(listed: false), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .failed(reason: "mount_failed"))
    }

    @Test("再マウントでパスが変われば新しいパスを返す")
    func changedPathIsReported() async throws {
        let f = try Fixture()
        let moved = f.tmp.url.appendingPathComponent("Volumes", isDirectory: true)
            .appendingPathComponent("DJIMIC3 1", isDirectory: false).path(percentEncoded: false)
        let runner = ScriptedProcessRunner(results: Self.results([.exited(0), .exited(0)]))
        let sut = DiskutilRemounter(runner: runner, inspector: f.inspector(mountedOn: moved), useMountPoint: false)
        #expect(await sut.remountReadOnly(path: f.path, node: Self.node) == .remounted(newPath: moved))
        #expect(moved.hasSuffix("/Volumes/DJIMIC3 1"))
    }
}
