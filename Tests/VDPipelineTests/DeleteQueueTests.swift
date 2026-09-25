// queue/delete と queue/result の読み書き（PLAN §4.4・§8.9.6・§8.9.7。T-38 §6.2）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("DeleteQueue")
struct DeleteQueueTests {
    static let pk = "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    static let otherPK = "DJIMIC3/TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"

    static func layout(_ tmp: TempDirectory) throws -> HomeLayout {
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        return layout
    }

    static func request(_ id: String, partkey: String = pk) -> DeleteRequest {
        DeleteRequest(
            requestID: id, createdAt: "2026-09-12T12:00:00+09:00", deviceID: "DJIMIC3", partkey: partkey,
            sessionKey: "DJIMIC3:20260912",
            target: DeleteTarget(
                relpath: String(partkey.dropFirst("DJIMIC3/".count)), size: 4096, mtime: 1_789_171_260))
    }

    static func writeResult(_ id: String, partkey: String, layout: HomeLayout) throws {
        let data = try ContractJSON.encode(
            DeleteResult(
                requestID: id, completedAt: "2026-09-12T12:00:05+09:00", reaperVersion: AppVersion.string,
                deviceID: "DJIMIC3", partkey: partkey, status: .deleted,
                detail: String(partkey.dropFirst("DJIMIC3/".count))))
        try data.write(to: DeleteQueue.resultURL(id, layout: layout))
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test(". 始まりと .json 以外を無視し、バイト順に並べる")
    func namesIgnoreHiddenAndOtherFiles() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        for name in [".x.json", "a.txt", "b.json", "A.json"] {
            try Data("{}".utf8).write(to: layout.queueDelete.appendingPathComponent(name, isDirectory: false))
        }
        #expect(DeleteQueue.names(in: layout.queueDelete) == ["A.json", "b.json"])
    }

    @Test("空（TEST-28）")
    func emptyDirectoryHasNoNames() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        #expect(DeleteQueue.names(in: layout.queueDelete) == [])
        // F-79: 要求が在るかは宛先のデバイスの列で見る（hasPendingRequests は本番から使われなくなったので消した）
        #expect(DeleteQueue.requestedDeviceIDs(layout: layout) == [])
    }

    @Test("要求は ContractJSON の符号化で書く（tmp を残さない）")
    func writeUsesContractJSON() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        let id = "20260912T030000Z-8483e42457304a9d-abcdef"
        let request = Self.request(id)
        try DeleteQueue.write(request, layout: layout)
        let written = try Data(contentsOf: DeleteQueue.requestURL(id, layout: layout))
        #expect(written == (try ContractJSON.encode(request)))
        let names = try FileManager.default.contentsOfDirectory(atPath: layout.queueDelete.path(percentEncoded: false))
        #expect(names == [id + ".json"])
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    @Test("取り下げは同じ partkey の要求だけ")
    func withdrawOnlyThatPartkey() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        try DeleteQueue.write(Self.request("20260912T030000Z-8483e42457304a9d-aaaaaa"), layout: layout)
        try DeleteQueue.write(Self.request("20260912T030001Z-8483e42457304a9d-bbbbbb"), layout: layout)
        let other = "20260912T030002Z-0000000000000000-cccccc"
        try DeleteQueue.write(Self.request(other, partkey: Self.otherPK), layout: layout)
        let broken = layout.queueDelete.appendingPathComponent("broken.json", isDirectory: false)
        try Data("{".utf8).write(to: broken)
        #expect(DeleteQueue.withdrawRequests(partkey: Self.pk, layout: layout) == 2)
        #expect(
            DeleteQueue.names(in: layout.queueDelete) == [
                "20260912T030002Z-0000000000000000-cccccc.json", "broken.json",
            ])
    }

    @Test("結果も partkey で取り下げる")
    func withdrawResultsToo() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        try Self.writeResult("20260912T030000Z-8483e42457304a9d-aaaaaa", partkey: Self.pk, layout: layout)
        let other = "20260912T030002Z-0000000000000000-cccccc"
        try Self.writeResult(other, partkey: Self.otherPK, layout: layout)
        #expect(DeleteQueue.withdrawResults(partkey: Self.pk, layout: layout) == 1)
        #expect(DeleteQueue.names(in: layout.queueResult) == [other + ".json"])
    }

    @Test("64 KiB を超えるものと symlink は読まない（パラメータ化）", arguments: ["65_537 バイト", "symlink"])
    func readSmallFileRejectsLargeAndSymlink(_ kind: String) throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        let url = layout.queueResult.appendingPathComponent("x.json", isDirectory: false)
        if kind == "65_537 バイト" {
            try Data(repeating: 0x20, count: 65_537).write(to: url)
        } else {
            let target = tmp.url.appendingPathComponent("target.json", isDirectory: false)
            try Data("{}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(
                atPath: url.path(percentEncoded: false), withDestinationPath: target.path(percentEncoded: false))
        }
        #expect(DeleteQueue.readSmallFile(url) == nil)
    }

    @Test("読めない結果は result が nil")
    func undecodableResultIsNil() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        try Data("{".utf8).write(to: layout.queueResult.appendingPathComponent("x.json", isDirectory: false))
        let results = DeleteQueue.results(layout: layout)
        #expect(results.count == 1)
        #expect(results.first?.result == nil)
    }
}
