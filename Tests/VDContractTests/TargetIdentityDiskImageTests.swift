// TargetIdentity をディスクイメージの上で検査する（T-07 §5.2。.diskImage。VOICEDOCK_DISK_TESTS=1 のときだけ）。
// イメージは一時ディレクトリの下にだけ attach する（/Volumes には触れない）。
import Darwin
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("TargetIdentity on disk image", .serialized, .enabled(if: TestEnvironment.diskTests), .tags(.diskImage))
struct TargetIdentityDiskImageTests {
    static let folder = "TX_MIC001_20260912_090000"
    static let file = "TX00_MIC001_20260912_090000_orig.wav"
    static let rel = folder + "/" + file

    /// VolumeOpenResult を比べられる文字列にする（opened / absent / 理由語）
    static func describe(_ result: VolumeOpenResult) -> String {
        switch result {
        case .opened: return "opened"
        case .absent: return "absent"
        case .rejected(let mismatch): return mismatch.reason
        }
    }

    static func open(_ volume: DiskImageVolume) -> VolumeOpenResult {
        TargetIdentity.openVolume(
            volumesRoot: volume.volumesRoot.path(percentEncoded: false), deviceID: volume.deviceID)
    }

    /// マウントしたイメージに REL を 4096 バイトで置き、mtime を設定する
    static func place(_ volume: DiskImageVolume, mtime: Int) throws -> URL {
        let url = volume.mountPoint.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FakeVolume.standardContent.write(to: url)
        var times = [timeval(tv_sec: mtime, tv_usec: 0), timeval(tv_sec: mtime, tv_usec: 0)]
        #expect(utimes(url.path(percentEncoded: false), &times) == 0)
        return url
    }

    @Test("RV-06 FAT32 のマウント点は開ける")
    func rv06Fat32IsOpened() throws {
        let tmp = try TempDirectory()
        let volume = try DiskImageVolume(in: tmp, filesystem: .fat32)
        defer { volume.detach() }
        let result = Self.open(volume)
        guard case .opened(let handle) = result else {
            Issue.record("開けなかった: \(Self.describe(result))")
            return
        }
        let root = try #require(PosixIO.realpath(volume.volumesRoot.path(percentEncoded: false)))
        #expect(handle.readOnly == false)
        #expect(handle.mountPath == root + "/VDT0007")
    }

    @Test("RV-06 HFS+ は unexpected_fs")
    func rv06HfsIsUnexpectedFS() throws {
        let tmp = try TempDirectory()
        let volume = try DiskImageVolume(in: tmp, filesystem: .hfsPlus)
        defer { volume.detach() }
        #expect(Self.describe(Self.open(volume)) == "unexpected_fs")
    }

    @Test("RV-07 読み取り専用のマウントを観測する")
    func rv07ReadOnlyIsObserved() throws {
        let tmp = try TempDirectory()
        let volume = try DiskImageVolume(in: tmp, filesystem: .fat32)
        defer { volume.detach() }
        try volume.reattach(readOnly: true)
        let result = Self.open(volume)
        guard case .opened(let handle) = result else {
            Issue.record("開けなかった: \(Self.describe(result))")
            return
        }
        #expect(handle.readOnly == true)
    }

    @Test("FAT の上で検証が通る")
    func fullChainOnFat() throws {
        let tmp = try TempDirectory()
        let volume = try DiskImageVolume(in: tmp, filesystem: .fat32)
        defer { volume.detach() }
        let url = try Self.place(volume, mtime: 1_787_000_000)
        var st = stat()
        #expect(lstat(url.path(percentEncoded: false), &st) == 0)
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let result = Self.open(volume)
        guard case .opened(let handle) = result else {
            Issue.record("開けなかった: \(Self.describe(result))")
            return
        }
        let verified = TargetIdentity.withVerifiedTarget(
            volume: handle, relpath: Self.rel, expectedSize: 4096, expectedMtime: mtime
        ) { _ in 42 }
        #expect(verified == .success(42))
    }

    @Test("RV-12 FAT の mtime の 2 秒分解能でも一致する")
    func rv12FatTwoSecondResolution() throws {
        let tmp = try TempDirectory()
        let volume = try DiskImageVolume(in: tmp, filesystem: .fat32)
        defer { volume.detach() }
        _ = try Self.place(volume, mtime: 1_787_000_001)
        let result = Self.open(volume)
        guard case .opened(let handle) = result else {
            Issue.record("開けなかった: \(Self.describe(result))")
            return
        }
        let verified = TargetIdentity.withVerifiedTarget(
            volume: handle, relpath: Self.rel, expectedSize: 4096, expectedMtime: 1_787_000_001
        ) { _ in 42 }
        #expect(verified == .success(42))
    }
}
