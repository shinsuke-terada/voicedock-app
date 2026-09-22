// Part の工程の最後（Raw → 削除評価の口）のテスト（T-29 §6.7。PLAN §5.5）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("PartStepsProcess", .serialized, .timeLimit(.minutes(1)))
struct PartStepsProcessTests {
    /// 6.1 の既定（Vault、READY の Session、status の Part A）。
    static func world(vault: Bool = true, status: PartStatus = .transcribed) async throws -> (PipelineWorld, String) {
        let w = try await PipelineWorld.make()
        if vault { try await w.installVault() }
        try w.addSession(key: PipelineFixtures.vaultSessionKey, day: "2026-08-29", status: .ready)
        let pk = try w.addPart(PipelineFixtures.partA, status: status)
        return (w, pk)
    }

    @Test("Raw の後に readyForSession を返す")
    func processReachesReadyForSession() async throws {
        let (w, pk) = try await Self.world()
        #expect(await PartSteps(ctx: try await w.context()).process(partkey: pk) == .readyForSession)
        #expect(try w.part(pk).status == .rawSaved)
    }

    @Test("RAW_SAVED 以降の Part でも削除評価の口まで進む")
    func rawSavedPartStillReturnsReady() async throws {
        let (w, pk) = try await Self.world(status: .rawSaved)
        #expect(await PartSteps(ctx: try await w.context()).process(partkey: pk) == .readyForSession)
    }

    @Test("Raw が偽なら stopped")
    func stoppedWhenRawFails() async throws {
        let (w, pk) = try await Self.world(vault: false)
        #expect(await PartSteps(ctx: try await w.context()).process(partkey: pk) == .stopped)
        #expect(try w.part(pk).status == .transcribed)
    }
}
