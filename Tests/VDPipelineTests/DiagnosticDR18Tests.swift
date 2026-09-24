// DR-18 話者分離の診断（T-49 §5。PLAN §8.4.1・§8.11）。helpers・resources は TempDirectory の中だけ。runner は台本。
import Foundation
import TestSupport
import Testing
import VDCore
import VDProcess

@testable import VDPipeline

@Suite("DR-18 話者分離")
struct DiagnosticDR18Tests {
    /// 話者分離をオンにした世界。argmax が真なら helpers/argmax-cli に FakeArgmax を、models が真なら SpeakerModels/ に 1 ファイル置く。
    static func world(help: ProcessResult?, argmax: Bool = true, models: Bool = true) async throws -> DiagnosticsWorld {
        let w = try await DiagnosticsWorld.make(
            configure: { $0.transcription.diarization.enabled = true }, results: help.map { [$0] } ?? [])
        if argmax {
            try FakeArgmax.write(to: w.paths.argmaxCLI)
        }
        if models {
            try FileManager.default.createDirectory(at: w.paths.speakerModels, withIntermediateDirectories: true)
            try Data("m".utf8).write(to: w.paths.speakerModels.appendingPathComponent("model.mlmodelc"))
        }
        return w
    }

    static func context(_ w: DiagnosticsWorld) -> DiagnosticsContext {
        var config = DiagnosticsWorld.baseConfig()
        config.transcription.diarization.enabled = true
        return w.context(config: config)
    }

    @Test("DR-18 オフなら skip")
    func offIsSkip() async throws {
        let w = try await DiagnosticsWorld.make()
        try FakeArgmax.write(to: w.paths.argmaxCLI)
        let r = await DiagnosticChecks.dr18(w.context())
        #expect(r == DiagnosticResult(id: "DR-18", status: .skip, label: "話者分離", details: ["オフです"]))
        #expect(await w.runner.recorded.isEmpty)
    }

    @Test("DR-18 揃っていれば ok")
    func allPresentIsOK() async throws {
        let w = try await Self.world(help: DiagnosticsWorld.help(FakeArgmax.help))
        let r = await DiagnosticChecks.dr18(Self.context(w))
        #expect(
            r == DiagnosticResult(id: "DR-18", status: .ok, label: "話者分離", details: ["argmax-cli とモデルが揃っています"]))
        let spec = try #require(await w.runner.recorded.first)
        #expect(spec.executable == w.paths.argmaxCLI)
        #expect(spec.arguments == ["diarize", "--help"])
        #expect(await w.runner.recordedTimeouts == [.seconds(20)])
    }

    @Test("DR-18 モデルが無ければ notice")
    func missingModelsIsNotice() async throws {
        let w = try await Self.world(help: DiagnosticsWorld.help(FakeArgmax.help), models: false)
        let r = await DiagnosticChecks.dr18(Self.context(w))
        #expect(r.status == .notice)
        #expect(r.details == ["話者分離の部品がありません（SpeakerModels）。話者なしで文字起こしします"])
    }

    @Test("DR-18 --help にフラグが無ければ notice")
    func missingFlagIsNotice() async throws {
        let help = FakeArgmax.help.replacingOccurrences(of: "--rttm-path", with: "")
        let w = try await Self.world(help: DiagnosticsWorld.help(help))
        let r = await DiagnosticChecks.dr18(Self.context(w))
        #expect(r.status == .notice)
        #expect(r.details == ["話者分離の部品がありません（--rttm-path）。話者なしで文字起こしします"])
    }

    @Test("DR-18 空の help（TEST-28）")
    func emptyHelpIsNotice() async throws {
        let w = try await Self.world(help: DiagnosticsWorld.help(""))
        let r = await DiagnosticChecks.dr18(Self.context(w))
        #expect(r.status == .notice)
        #expect(
            r.details == [
                "話者分離の部品がありません（--audio-path、--model-path、--rttm-path、--use-exclusive-reconciliation）。"
                    + "話者なしで文字起こしします"
            ])
    }
}
