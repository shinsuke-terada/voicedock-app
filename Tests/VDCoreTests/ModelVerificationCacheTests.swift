// ModelVerificationCache の検査（PLAN §8.10。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ModelVerificationCache")
struct ModelVerificationCacheTests {
    @Test("4 つが全部一致したときだけ返す")
    func returnsOnlyWhenAllMatch() async {
        let cache = ModelVerificationCache()
        #expect(await cache.verifiedSHA256(path: "/m/a.bin", inode: 1, size: 10, mtime: 1.5) == nil)
        await cache.record(path: "/m/a.bin", inode: 1, size: 10, mtime: 1.5, sha256: "aa")
        #expect(await cache.verifiedSHA256(path: "/m/a.bin", inode: 1, size: 10, mtime: 1.5) == "aa")
        #expect(await cache.verifiedSHA256(path: "/m/a.bin", inode: 2, size: 10, mtime: 1.5) == nil)
        #expect(await cache.verifiedSHA256(path: "/m/a.bin", inode: 1, size: 11, mtime: 1.5) == nil)
        #expect(await cache.verifiedSHA256(path: "/m/a.bin", inode: 1, size: 10, mtime: 1.6) == nil)
        #expect(await cache.verifiedSHA256(path: "/m/b.bin", inode: 1, size: 10, mtime: 1.5) == nil)
        await cache.record(path: "/m/a.bin", inode: 2, size: 10, mtime: 1.5, sha256: "bb")
        #expect(await cache.verifiedSHA256(path: "/m/a.bin", inode: 1, size: 10, mtime: 1.5) == nil)
        #expect(await cache.verifiedSHA256(path: "/m/a.bin", inode: 2, size: 10, mtime: 1.5) == "bb")
    }
}
