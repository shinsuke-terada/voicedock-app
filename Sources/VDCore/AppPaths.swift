// バンドル内の資源とヘルパーのパス（PLAN §3.4・§11.1）。PT-11: `bundledReaperURL` の定義。
import Foundation
import VDContract

/// バンドル内の資源とヘルパーのパス（PLAN §3.4・§11.1）。SwiftPM の Bundle.module は使わない。テストはリポジトリの Resources/ を注入する。
public struct AppPaths: Sendable, Equatable {
    public let resources: URL
    public let helpers: URL

    public init(resources: URL, helpers: URL) {
        self.resources = resources
        self.helpers = helpers
    }

    /// Bundle.main.bundleURL + "Contents/Resources" と "Contents/Helpers"。
    public static func fromMainBundle() -> AppPaths {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        return AppPaths(
            resources: contents.appendingPathComponent("Resources", isDirectory: true),
            helpers: contents.appendingPathComponent("Helpers", isDirectory: true))
    }

    /// resources/prompts
    public var promptsDirectory: URL { resources.appendingPathComponent("prompts", isDirectory: true) }
    /// resources/ModelCatalog.json
    public var modelCatalog: URL { resources.appendingPathComponent("ModelCatalog.json", isDirectory: false) }
    /// helpers/whisper-cli
    public var whisperCLI: URL { helpers.appendingPathComponent("whisper-cli", isDirectory: false) }
    /// helpers/llama-server
    public var llamaServer: URL { helpers.appendingPathComponent("llama-server", isDirectory: false) }
    /// helpers/argmax-cli（話者分離。PLAN §8.4.1。F-89）
    public var argmaxCLI: URL { helpers.appendingPathComponent("argmax-cli", isDirectory: false) }
    /// resources/SpeakerModels（話者分離のモデル。同梱。PLAN §11.2）
    public var speakerModels: URL { resources.appendingPathComponent("SpeakerModels", isDirectory: true) }
    /// バンドル内の reaper。**参照してよいのは DeletionEnabler だけ**（PT-11）。ここから実行しない（D-5）。
    public var bundledReaperURL: URL {
        helpers.appendingPathComponent(Contract.reaperFileName, isDirectory: false)
    }
}
