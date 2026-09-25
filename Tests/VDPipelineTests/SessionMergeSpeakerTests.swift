// 統合結果と Raw の Part の区間に speaker を運ぶ（T-49 §5。PLAN §8.5・§8.6。F-89）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("SessionMergeSpeaker")
struct SessionMergeSpeakerTests {
    static let key = PipelineFixtures.sessionKey

    /// 9 時の READY の Session と、09:00:00 に始まる 60 秒の Part（segments の transcript）。
    static func world(_ segments: [TranscriptSegment]) async throws -> PipelineWorld {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addTimedPart(time: "09:00:00", stamp: "090000", segments: segments)
        return w
    }

    static let withSpeakers = [
        TranscriptSegment(start: 0, end: 1, text: "a", speaker: "A"),
        TranscriptSegment(start: 2, end: 3, text: "b", speaker: "B"),
    ]

    static let withoutSpeakers = [
        TranscriptSegment(start: 0, end: 1, text: "a"), TranscriptSegment(start: 2, end: 3, text: "b"),
    ]

    @Test("統合結果の区間に speaker が運ばれる")
    func mergeCarriesSpeaker() async throws {
        let w = try await Self.world(Self.withSpeakers)
        let t = try #require(try SessionSteps(ctx: try await w.context()).buildSessionTranscript(Self.key))
        #expect(t.segments.map(\.text) == ["a", "b"])
        #expect(t.segments.map(\.speaker) == ["A", "B"])
    }

    @Test("Raw の Part の区間に speaker が運ばれる")
    func rawPartCarriesSpeaker() async throws {
        let w = try await Self.world(Self.withSpeakers)
        let parts = try PartSteps(ctx: try await w.context()).rawParts(sessionKey: Self.key)
        #expect(parts.count == 1)
        #expect(parts.first?.segments.map(\.text) == ["a", "b"])
        #expect(parts.first?.segments.map(\.speaker) == ["A", "B"])
    }

    @Test("話者なしの統合結果は今と同じ")
    func withoutSpeakerIsUnchanged() async throws {
        let w = try await Self.world(Self.withoutSpeakers)
        let t = try #require(try SessionSteps(ctx: try await w.context()).buildSessionTranscript(Self.key))
        #expect(t.segments.map(\.speaker) == [nil, nil])
        // F-89 の前の定義の payload を手で書いて `shasum -a 256` した値:
        // {"blocks":[["2026-09-12T09:00:00+09:00","2026-09-12T09:01:00+09:00"]],"segments":[{"at":"2026-09-12T09:00:00+09:00",
        // "end_at":"2026-09-12T09:00:01+09:00","text":"a"},{"at":"2026-09-12T09:00:02+09:00","end_at":"2026-09-12T09:00:03+09:00",
        // "text":"b"}]}（改行は説明のため）
        #expect(
            TranscriptFingerprint.of(t, zone: PipelineFixtures.zone)
                == "f6c06597fb67d4373b440fb7a87d66b23560035cc60acdd380cab3ca30b58b3b")
    }

    @Test("区間 0 の Session（TEST-28）")
    func emptySession() async throws {
        let w = try await Self.world([])
        #expect(try SessionSteps(ctx: try await w.context()).buildSessionTranscript(Self.key) == nil)
    }
}
