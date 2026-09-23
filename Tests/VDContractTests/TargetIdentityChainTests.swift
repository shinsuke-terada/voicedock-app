// openat 連鎖が途中の symlink を辿らないこと（PLAN §4.6・F-73・issue #113。層 R2）。"/" の直後に結合文字がある relpath と、
// 名前に "/" が紛れたときの O_NOFOLLOW_ANY を、それぞれ独立に確かめる（TEST-17）。ボリュームは一時ディレクトリ。
import Darwin
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("TargetIdentity の openat 連鎖（F-73）")
struct TargetIdentityChainTests {
    static let deviceID = "VDT0073"
    static let folder = "TX_MIC001_20260912_090000"
    static let file = "TX00_MIC001_20260912_090000_orig.wav"
    static let mtime = 1_787_000_000.0
    /// "A" の直後の "/" に結合文字 U+0301 が続く。書記素で分けると "A/\u{301}B" が 1 つの要素になる
    static let rel = "A/\u{301}B/" + folder + "/" + file

    struct Bench {
        let tmp: TempDirectory
        let fake: FakeVolume
        let volume: VolumeHandle

        init() throws {
            tmp = try TempDirectory()
            fake = try FakeVolume(in: tmp, deviceID: TargetIdentityChainTests.deviceID)
            let opened = FakeVolumeOpener().open(
                volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: TargetIdentityChainTests.deviceID)
            guard case .opened(let volume) = opened else {
                Issue.record("FakeVolumeOpener がベンチのボリュームを開けなかった")
                throw POSIXError(.ENOENT)
            }
            self.volume = volume
        }

        /// 失敗なら理由語、成功なら nil。body の呼び出し回数も返す
        func verify(_ relpath: String) -> (reason: String?, calls: Int) {
            var calls = 0
            let result = TargetIdentity.withVerifiedTarget(
                volume: volume, relpath: relpath, expectedSize: 4096, expectedMtime: TargetIdentityChainTests.mtime
            ) { _ in
                calls += 1
                return 0
            }
            if case .failure(let mismatch) = result { return (mismatch.reason, calls) }
            return (nil, calls)
        }
    }

    @Test("RV-09 「/」の直後に結合文字がある relpath でも、手前の要素の symlink を辿らずに path_contains_symlink")
    func rv09CombiningMarkAfterSlashDoesNotHideASymlink() throws {
        let bench = try Bench()
        let real = "REAL/\u{301}B/" + Self.folder + "/" + Self.file
        try bench.fake.addFile(real, mtime: Self.mtime)
        try bench.fake.addSymlink("A", destination: "REAL")
        let outcome = bench.verify(Self.rel)
        #expect(outcome.reason == "path_contains_symlink")
        #expect(outcome.calls == 0)
        #expect(bench.fake.fileStat(real) != nil)
    }

    @Test("RV-09 対照: 途中に symlink が無ければ「/」＋結合文字の要素を通って body が呼ばれる")
    func rv09CombiningMarkComponentReachesTheTarget() throws {
        let bench = try Bench()
        try bench.fake.addFile(Self.rel, mtime: Self.mtime)
        let outcome = bench.verify(Self.rel)
        #expect(outcome.reason == nil)
        #expect(outcome.calls == 1)
    }

    @Test("RV-09 連鎖の 1 段は名前に「/」が紛れても途中の symlink を辿らない（O_NOFOLLOW_ANY で ELOOP）")
    func rv09OpenDirectoryDoesNotFollowAnyIntermediateSymlink() throws {
        let bench = try Bench()
        try bench.fake.addDirectory("REAL/sub")
        try bench.fake.addSymlink("A", destination: "REAL")
        let fd = TargetIdentity.openDirectory(in: bench.volume.fd, named: "A/sub")
        let error = errno
        if fd >= 0 { close(fd) }
        #expect(fd == -1)
        #expect(error == ELOOP)
    }

    @Test("RV-09 対照: symlink の無い名前は連鎖の 1 段で開ける（O_NOFOLLOW と併せて EINVAL にしていない）")
    func rv09OpenDirectoryOpensPlainDirectories() throws {
        let bench = try Bench()
        try bench.fake.addDirectory("REAL/sub")
        for name in ["REAL", "REAL/sub"] {
            let fd = TargetIdentity.openDirectory(in: bench.volume.fd, named: name)
            #expect(fd >= 0, "\(name)")
            if fd >= 0 { close(fd) }
        }
    }

    @Test("RV-09 連鎖の 1 段に空の名前を渡しても開けない（TEST-28）")
    func rv09OpenDirectoryRejectsAnEmptyName() throws {
        let bench = try Bench()
        let fd = TargetIdentity.openDirectory(in: bench.volume.fd, named: "")
        let error = errno
        if fd >= 0 { close(fd) }
        #expect(fd == -1)
        #expect(error == ENOENT)
    }
}
