// Part の文字起こしの工程と話者分離（T-49 §5。PLAN §8.4.1）。本物の ProcessRunner と FakeWhisper・FakeArgmax。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess
import VDStore

@testable import VDPipeline

@Suite("PartStepsDiarization", .serialized, .timeLimit(.minutes(1)))
struct PartStepsDiarizationTests {
    /// FakeWhisper の既定の 2 区間（0〜3.2 秒・5.5〜9.0 秒）を 2 人に分ける RTTM。
    static let twoSpeakers = [
        "SPEAKER audio16k 1 0.000 3.200 <NA> <NA> A <NA> <NA>",
        "SPEAKER audio16k 1 5.500 3.500 <NA> <NA> B <NA> <NA>",
    ]

    /// 話者分離のテストの世界。resources は TempDirectory の中（SpeakerModels を置けるように）、helpers は世界のもの。
    struct Scene {
        let world: PipelineWorld
        let partkey: String
        let paths: AppPaths

        var audio: URL { world.layout.normalizedAudio(slug: KeySlug.of(partkey)) }

        /// 世界の依存の paths だけを差し替えた TickContext。
        func context() async throws -> TickContext {
            let w = world
            guard let config = await w.configStore.current() else { throw PipelineFixtureError.noConfig }
            let chat = w.chat
            let deps = WorkerDependencies(
                layout: w.layout, paths: paths, store: w.store, config: w.configStore, ingest: w.ingest,
                runner: ProcessRunner(), llama: w.llm, chatTransportFactory: { _, _ in chat }, clock: w.clock,
                sleeper: w.sleeper, log: w.log, license: AlwaysAllowLicenseGate(), catalog: TestCatalogs.minimal,
                physicalMemoryBytes: w.physicalMemoryBytes, locks: w.locks, volumeOpener: FakeVolumeOpener())
            return TickContext(
                deps: deps, config: config, zone: Worker.zone(for: config), snapshot: nil,
                pauses: PauseBook(log: w.log), activity: ActivityBoard(assertion: w.assertion), stop: StopFlag(),
                undeletableStreaks: UndeletableStreaks())
        }

        func transcribe(ctx: TickContext? = nil) async throws -> Bool {
            let context: TickContext
            if let ctx {
                context = ctx
            } else {
                context = try await self.context()
            }
            return await PartSteps(ctx: context).ensureTranscribed(try world.part(partkey))
        }

        /// transcripts/parts/<slug>.json
        func transcript() throws -> PartTranscript {
            let data = try Data(contentsOf: world.layout.transcript(slug: KeySlug.of(partkey)))
            return try #require(PartTranscriptCodec.decode(data))
        }

        /// diarization_completed / diarization_failed の行
        func diarizationLines() -> [String] {
            world.lines("diarization_completed") + world.lines("diarization_failed")
        }
    }

    /// Part を NORMALIZED にして 16 kHz を置く（PartStepsTranscribeTests.prepared と同じ）。
    /// argmax が nil なら argmax-cli を置かない。speakerModels が真なら resources/SpeakerModels/ に 1 ファイル置く。
    static func prepared(
        enabled: Bool, utterances: [FakeWhisperUtterance] = FakeWhisper.defaultUtterances,
        argmax: FakeArgmaxOutput? = .rttm(twoSpeakers), argmaxExit: Int32 = 0, speakerModels: Bool = true
    ) async throws -> Scene {
        let w = try await PipelineWorld.make { $0.transcription.diarization.enabled = enabled }
        try w.installWhisper(utterances: utterances)
        let pk = try w.insertPart()
        try w.movePart(pk, [.normalizing, .normalized])
        let audio = w.layout.normalizedAudio(slug: KeySlug.of(pk))
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 16).write(to: audio)
        try w.store.updateRecording(pk, [.normalizedPath(w.layout.relativePath(of: audio))])
        let paths = AppPaths(
            resources: w.tmp.url.appendingPathComponent("resources", isDirectory: true), helpers: w.paths.helpers)
        if speakerModels {
            try FileManager.default.createDirectory(at: paths.speakerModels, withIntermediateDirectories: true)
            try Data("m".utf8).write(to: paths.speakerModels.appendingPathComponent("model.mlmodelc"))
        }
        if let argmax {
            try FakeArgmax.write(to: paths.argmaxCLI, output: argmax, exitCode: argmaxExit)
        }
        return Scene(world: w, partkey: pk, paths: paths)
    }

    @Test("CE transcription.diarization.enabled false なら argmax-cli を起動しない")
    func offDoesNotLaunch() async throws {
        let s = try await Self.prepared(enabled: false)
        #expect(try await s.transcribe())
        #expect(try s.world.part(s.partkey).status == .transcribed)
        #expect(FakeArgmax.recordedArgv(s.paths.argmaxCLI).isEmpty)
        #expect(s.diarizationLines().isEmpty)
        let t = try s.transcript()
        #expect(t.segments.count == 2)
        #expect(t.segments.allSatisfy { $0.speaker == nil })
        let text = try String(contentsOf: s.world.layout.transcript(slug: KeySlug.of(s.partkey)), encoding: .utf8)
        #expect(!text.contains("\"speaker\""))
    }

    @Test("CE transcription.diarization.enabled true なら話者を付けて diarization_completed")
    func onLogsCompleted() async throws {
        let s = try await Self.prepared(enabled: true)
        #expect(try await s.transcribe())
        #expect(try s.world.part(s.partkey).status == .transcribed)
        let lines = s.world.sink.lines
        let completed = try #require(lines.firstIndex { $0.contains(" diarization_completed ") })
        let transcribed = try #require(lines.firstIndex { $0.contains(" transcription_completed ") })
        #expect(transcribed < completed)
        // FixedClock は進まないので経過は 0
        #expect(
            lines[completed].hasSuffix(
                "INFO  diarization_completed recording_key=\(PipelineFixtures.partkey) speakers=2 elapsed_s=0.0"))
        #expect(s.world.lines("diarization_failed").isEmpty)
        #expect(try s.transcript().segments.map(\.speaker) == ["A", "B"])
    }

    @Test("失敗しても TRANSCRIBED で diarization_failed")
    func onFailureLogsWarning() async throws {
        let s = try await Self.prepared(enabled: true, argmaxExit: 2)
        #expect(try await s.transcribe())
        let row = try s.world.part(s.partkey)
        #expect(row.status == .transcribed)
        #expect(row.errorCode == nil)
        #expect(
            s.world.lines("diarization_failed").contains {
                $0.hasSuffix("WARNING diarization_failed recording_key=\(PipelineFixtures.partkey) reason=exit_2")
            })
        #expect(s.world.lines("diarization_completed").isEmpty)
        #expect(try s.transcript().segments.allSatisfy { $0.speaker == nil })
    }

    @Test("argmax-cli が無くても止まらない")
    func onMissingHelper() async throws {
        let s = try await Self.prepared(enabled: true, argmax: nil)
        let ctx = try await s.context()
        #expect(try await s.transcribe(ctx: ctx))
        #expect(try s.world.part(s.partkey).status == .transcribed)
        #expect(
            s.world.lines("diarization_failed").contains {
                $0.hasSuffix(
                    "WARNING diarization_failed recording_key=\(PipelineFixtures.partkey) reason=helper_missing")
            })
        #expect(s.world.lines("pipeline_paused").isEmpty)
        #expect(ctx.pauses.paused.isEmpty)
    }

    @Test("話者分離の後に 16 kHz を消す")
    func stagingIsRemovedAfterDiarization() async throws {
        let s = try await Self.prepared(enabled: true, argmax: nil)
        // 起動された時点で --audio-path のファイルが在ったかを記録してから、本物の偽物（FakeArgmax）へ渡す
        let real = try FakeArgmax.write(
            to: s.paths.helpers.appendingPathComponent("argmax-real", isDirectory: false),
            output: .rttm(Self.twoSpeakers))
        let marker = s.world.tmp.url.appendingPathComponent("audio-seen", isDirectory: false)
        let wrapper = [
            "#!/bin/sh",
            "take=0",
            "for arg in \"$@\"; do",
            "  if [ \"$take\" = \"1\" ]; then",
            "    if [ -s \"$arg\" ]; then echo present > '\(marker.path(percentEncoded: false))';"
                + " else echo absent > '\(marker.path(percentEncoded: false))'; fi",
            "    take=0",
            "  fi",
            "  if [ \"$arg\" = \"--audio-path\" ]; then take=1; fi",
            "done",
            "exec '\(real.path(percentEncoded: false))' \"$@\"",
        ]
        try Data((wrapper.joined(separator: "\n") + "\n").utf8).write(to: s.paths.argmaxCLI)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: s.paths.argmaxCLI.path(percentEncoded: false))

        #expect(try await s.transcribe())
        #expect(!PipelineFixtures.exists(s.audio))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "present\n")
        let argv = FakeArgmax.recordedArgv(real)
        let i = try #require(argv.firstIndex(of: "--audio-path"))
        #expect(argv.indices.contains(i + 1))
        #expect(argv.dropFirst(i + 1).first == s.audio.path(percentEncoded: false))
        #expect(!s.world.lines("diarization_completed").isEmpty)
    }

    @Test("無音の Part は話者分離のログを出さない")
    func noSpeechDoesNotLog() async throws {
        let s = try await Self.prepared(enabled: true, utterances: [])
        #expect(try await s.transcribe() == false)
        #expect(try s.world.part(s.partkey).status == .skipped)
        #expect(s.diarizationLines().isEmpty)
        #expect(FakeArgmax.recordedArgv(s.paths.argmaxCLI).isEmpty)
    }
}
