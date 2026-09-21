// SystemMountInspector の検査（T-13 §5.1）。読み取りだけ（/ の statfs・getmntinfo・ボリューム名）。/Volumes には触れない。
import Foundation
import TestSupport
import Testing

@testable import VDDevice

@Suite("MountInspector")
struct MountInspectorTests {
    @Test("/ はマウント点")
    func rootIsAMountPoint() {
        #expect(SystemMountInspector().isMountPoint(path: "/"))
    }

    @Test("/. も realpath を通すとマウント点")
    func dotRootIsAMountPointAfterRealpath() {
        #expect(SystemMountInspector().isMountPoint(path: "/."))
    }

    @Test("一時ディレクトリはマウント点でない")
    func tempDirectoryIsNotAMountPoint() throws {
        let tmp = try TempDirectory()
        let dir = tmp.url.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(!SystemMountInspector().isMountPoint(path: dir.path(percentEncoded: false)))
    }

    @Test("/ の statfs が取れる")
    func mountInfoOfRootIsObserved() throws {
        let info = try #require(SystemMountInspector().mountInfo(path: "/"))
        #expect(info.mountOnName == "/")
        let free = try #require(info.freeBytes)
        #expect(free > 0)
    }

    @Test("無いパスは観測できない（nil）")
    func mountInfoOfMissingPathIsNil() {
        let path = ["", "nonexistent-" + UUID().uuidString].joined(separator: "/")
        #expect(SystemMountInspector().mountInfo(path: path) == nil)
    }

    @Test("getmntinfo に / が在る")
    func allMountsContainsRoot() {
        let roots = SystemMountInspector().allMounts().filter { $0.mountOnName == "/" }
        #expect(roots.count >= 1)
    }

    @Test("/ のボリューム名が取れる")
    func volumeNameOfRoot() throws {
        let name = try #require(SystemMountInspector().volumeName(path: "/"))
        #expect(!name.isEmpty)
    }
}
