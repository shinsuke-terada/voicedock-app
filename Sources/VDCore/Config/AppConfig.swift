// config.json の型と既定値（PLAN §6.1・§6.2）。既定値を書くのは `AppConfig.defaults(timeZone:)` の 1 か所だけ。
import Foundation

/// config.json の全体。プロパティ名は PLAN §6.2 の JSON キーと同じ綴り。
public struct AppConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var timeZone: String
    public var vault: VaultConfig
    public var device: DeviceConfig
    public var audio: AudioConfig
    public var session: SessionConfig
    public var transcription: TranscriptionConfig
    public var llm: LLMConfig
    public var obsidian: ObsidianConfig
    public var cleanup: CleanupConfig
    public var retry: RetryConfig
    public var logging: LoggingConfig

    public init(
        schemaVersion: Int, timeZone: String, vault: VaultConfig, device: DeviceConfig, audio: AudioConfig,
        session: SessionConfig, transcription: TranscriptionConfig, llm: LLMConfig, obsidian: ObsidianConfig,
        cleanup: CleanupConfig, retry: RetryConfig, logging: LoggingConfig
    ) {
        self.schemaVersion = schemaVersion
        self.timeZone = timeZone
        self.vault = vault
        self.device = device
        self.audio = audio
        self.session = session
        self.transcription = transcription
        self.llm = llm
        self.obsidian = obsidian
        self.cleanup = cleanup
        self.retry = retry
        self.logging = logging
    }

    /// PLAN §6.2 の JSON と同じ値。既定値はここにだけ書く（CR-06）。
    /// includeVolumes の既定は ["DJIMIC3"]（F-81。利用者の決定。ルートに DJI 形式のフォルダがある外付けを何でもデバイスと
    /// みなさない。既定値は config.json が無いときだけ書くので、既存の config.json の値は変わらない。§6.1）
    public static func defaults(timeZone: String) -> AppConfig {
        AppConfig(
            schemaVersion: 1,
            timeZone: timeZone,
            vault: VaultConfig(path: nil, marker: ".obsidian"),
            device: DeviceConfig(
                includeVolumes: ["DJIMIC3"], excludeVolumes: ["Macintosh HD", "com.apple.TimeMachine.*", ".*"],
                mountMode: "ro",
                stabilityFastPathSeconds: 60, stabilityIntervalSeconds: 3, stabilityChecks: 2,
                maxScanDepth: 3, scanIntervalSeconds: 300, snapshotMaxAgeSeconds: 900),
            audio: AudioConfig(
                timeoutFactor: 0.5, minTimeoutSeconds: 180, durationToleranceSeconds: 1.0,
                freeSpaceMultiplier: 2.0, freeSpaceMarginBytes: 2_147_483_648, stagingMaxBytes: 5_368_709_120,
                hashChunkBytes: 1_048_576, inboxRetain: "normalized"),
            session: SessionConfig(
                blockGapSeconds: 3600, idleCloseSeconds: 1800, allowReopen: true, maxParts: 64,
                maxDurationSeconds: 86_400),
            transcription: TranscriptionConfig(
                whisperModelID: "large-v3-turbo-q5_0", language: "ja", threads: 0,
                timeoutFactor: 3.0, minTimeoutSeconds: 600, maxTimeoutSeconds: 21_600, minChars: 1,
                vad: VADConfig(
                    enabled: true, modelID: "silero-v5.1.2", threshold: 0.5,
                    minSpeechDurationMs: 250, minSilenceDurationMs: 1000, speechPadMs: 200)),
            llm: LLMConfig(
                modelID: nil, contextSize: 32_768, temperature: 0.1, topP: 0.9, maxOutputTokens: 8192,
                requestTimeoutSeconds: 1800, maxCharsPerRequest: 20_000, maxSecondsPerRequest: 3600,
                chunkOverlapChars: 500, repairAttempts: 1,
                analysis: AnalysisConfig(
                    sections: AnalysisSections(
                        // F-54: summary と timeline の JSON に maxItems は無い（常に nil）
                        summary: SectionConfig(enabled: true, heading: "## Summary", maxItems: nil),
                        timeline: SectionConfig(enabled: true, heading: "## Timeline", maxItems: nil),
                        keyPoints: SectionConfig(enabled: true, heading: "## Key Points", maxItems: 20),
                        tasks: SectionConfig(enabled: true, heading: "## Tasks", maxItems: 50),
                        decisions: SectionConfig(enabled: true, heading: "## Decisions", maxItems: 30),
                        ideas: SectionConfig(enabled: true, heading: "## Ideas", maxItems: 30),
                        tags: SectionConfig(enabled: true, heading: nil, maxItems: 15)),
                    order: ["summary", "timeline", "key_points", "tasks", "decisions", "ideas"],
                    customInstructions: "")),
            obsidian: ObsidianConfig(
                maxTitleBytes: 180, defaultTags: ["voice", "voicedock"],
                raw: RawNoteConfig(
                    folderTemplate: "Daily/Voice/Raw/{yyyymmdd}", filenameTemplate: "{date} raw",
                    timestampIntervalSeconds: 300, partBoundaryHeading: true),
                wiki: WikiNoteConfig(
                    folderTemplate: "Daily/Voice/Wiki/{yyyymmdd}", filenameTemplate: "{date} Voice",
                    linkDailyNote: true, linkAdjacentDays: true, linkTags: true, linkOnlyExisting: true,
                    vaultIndexCacheSeconds: 300, maxLinks: 20)),
            cleanup: CleanupConfig(
                deleteSourceAudio: false, deleteSkippedSource: false, deleteNormalizedAfterTranscribe: true,
                deleteEvaluationBackoffSeconds: [60, 300, 900, 3600], deleteResultTimeoutSeconds: 3600),
            retry: RetryConfig(maxAttempts: 3, backoffSeconds: [3, 10, 30]),
            logging: LoggingConfig(level: "INFO", unsafeLogContent: false))
    }
}

public struct VaultConfig: Codable, Equatable, Sendable {
    public var path: String?
    public var marker: String

    public init(path: String?, marker: String) {
        self.path = path
        self.marker = marker
    }

    /// nil を `null` として書く（synthesized は nil のキーを省く）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(marker, forKey: .marker)
    }
}

public struct DeviceConfig: Codable, Equatable, Sendable {
    public var includeVolumes: [String]
    public var excludeVolumes: [String]
    public var mountMode: String
    public var stabilityFastPathSeconds: Int
    public var stabilityIntervalSeconds: Int
    public var stabilityChecks: Int
    public var maxScanDepth: Int
    public var scanIntervalSeconds: Int
    public var snapshotMaxAgeSeconds: Int

    public enum MountMode: String, Sendable {
        case ro
        case rw
    }

    /// 検証済みなら `mountMode` の値。不正な値は安全側の `.ro`（CR-04）。
    public var mode: MountMode { MountMode(rawValue: mountMode) ?? .ro }

    public init(
        includeVolumes: [String], excludeVolumes: [String], mountMode: String, stabilityFastPathSeconds: Int,
        stabilityIntervalSeconds: Int, stabilityChecks: Int, maxScanDepth: Int, scanIntervalSeconds: Int,
        snapshotMaxAgeSeconds: Int
    ) {
        self.includeVolumes = includeVolumes
        self.excludeVolumes = excludeVolumes
        self.mountMode = mountMode
        self.stabilityFastPathSeconds = stabilityFastPathSeconds
        self.stabilityIntervalSeconds = stabilityIntervalSeconds
        self.stabilityChecks = stabilityChecks
        self.maxScanDepth = maxScanDepth
        self.scanIntervalSeconds = scanIntervalSeconds
        self.snapshotMaxAgeSeconds = snapshotMaxAgeSeconds
    }
}

public struct AudioConfig: Codable, Equatable, Sendable {
    public var timeoutFactor: Double
    public var minTimeoutSeconds: Int
    public var durationToleranceSeconds: Double
    public var freeSpaceMultiplier: Double
    public var freeSpaceMarginBytes: Int
    public var stagingMaxBytes: Int
    public var hashChunkBytes: Int
    public var inboxRetain: String

    public enum InboxRetain: String, Sendable {
        case normalized = "normalized"
        case rawSaved = "raw_saved"
    }

    /// 不正な値は安全側（inbox を長く残す）の `.rawSaved`。
    public var retain: InboxRetain { InboxRetain(rawValue: inboxRetain) ?? .rawSaved }

    public init(
        timeoutFactor: Double, minTimeoutSeconds: Int, durationToleranceSeconds: Double, freeSpaceMultiplier: Double,
        freeSpaceMarginBytes: Int, stagingMaxBytes: Int, hashChunkBytes: Int, inboxRetain: String
    ) {
        self.timeoutFactor = timeoutFactor
        self.minTimeoutSeconds = minTimeoutSeconds
        self.durationToleranceSeconds = durationToleranceSeconds
        self.freeSpaceMultiplier = freeSpaceMultiplier
        self.freeSpaceMarginBytes = freeSpaceMarginBytes
        self.stagingMaxBytes = stagingMaxBytes
        self.hashChunkBytes = hashChunkBytes
        self.inboxRetain = inboxRetain
    }
}

public struct SessionConfig: Codable, Equatable, Sendable {
    public var blockGapSeconds: Int
    public var idleCloseSeconds: Int
    public var allowReopen: Bool
    public var maxParts: Int
    public var maxDurationSeconds: Int

    public init(blockGapSeconds: Int, idleCloseSeconds: Int, allowReopen: Bool, maxParts: Int, maxDurationSeconds: Int)
    {
        self.blockGapSeconds = blockGapSeconds
        self.idleCloseSeconds = idleCloseSeconds
        self.allowReopen = allowReopen
        self.maxParts = maxParts
        self.maxDurationSeconds = maxDurationSeconds
    }
}

public struct TranscriptionConfig: Codable, Equatable, Sendable {
    public var whisperModelID: String
    public var language: String
    public var threads: Int
    public var timeoutFactor: Double
    public var minTimeoutSeconds: Int
    public var maxTimeoutSeconds: Int
    public var minChars: Int
    public var vad: VADConfig

    public init(
        whisperModelID: String, language: String, threads: Int, timeoutFactor: Double, minTimeoutSeconds: Int,
        maxTimeoutSeconds: Int, minChars: Int, vad: VADConfig
    ) {
        self.whisperModelID = whisperModelID
        self.language = language
        self.threads = threads
        self.timeoutFactor = timeoutFactor
        self.minTimeoutSeconds = minTimeoutSeconds
        self.maxTimeoutSeconds = maxTimeoutSeconds
        self.minChars = minChars
        self.vad = vad
    }
}

public struct VADConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var modelID: String
    public var threshold: Double
    public var minSpeechDurationMs: Int
    public var minSilenceDurationMs: Int
    public var speechPadMs: Int

    public init(
        enabled: Bool, modelID: String, threshold: Double, minSpeechDurationMs: Int, minSilenceDurationMs: Int,
        speechPadMs: Int
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.threshold = threshold
        self.minSpeechDurationMs = minSpeechDurationMs
        self.minSilenceDurationMs = minSilenceDurationMs
        self.speechPadMs = speechPadMs
    }
}

public struct LLMConfig: Codable, Equatable, Sendable {
    public var modelID: String?
    public var contextSize: Int
    public var temperature: Double
    public var topP: Double
    public var maxOutputTokens: Int
    public var requestTimeoutSeconds: Int
    public var maxCharsPerRequest: Int
    public var maxSecondsPerRequest: Int
    public var chunkOverlapChars: Int
    public var repairAttempts: Int
    public var analysis: AnalysisConfig

    public init(
        modelID: String?, contextSize: Int, temperature: Double, topP: Double, maxOutputTokens: Int,
        requestTimeoutSeconds: Int, maxCharsPerRequest: Int, maxSecondsPerRequest: Int, chunkOverlapChars: Int,
        repairAttempts: Int, analysis: AnalysisConfig
    ) {
        self.modelID = modelID
        self.contextSize = contextSize
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maxCharsPerRequest = maxCharsPerRequest
        self.maxSecondsPerRequest = maxSecondsPerRequest
        self.chunkOverlapChars = chunkOverlapChars
        self.repairAttempts = repairAttempts
        self.analysis = analysis
    }

    /// nil の `modelID` を `null` として書く（synthesized は nil のキーを省く）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(contextSize, forKey: .contextSize)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(topP, forKey: .topP)
        try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encode(requestTimeoutSeconds, forKey: .requestTimeoutSeconds)
        try container.encode(maxCharsPerRequest, forKey: .maxCharsPerRequest)
        try container.encode(maxSecondsPerRequest, forKey: .maxSecondsPerRequest)
        try container.encode(chunkOverlapChars, forKey: .chunkOverlapChars)
        try container.encode(repairAttempts, forKey: .repairAttempts)
        try container.encode(analysis, forKey: .analysis)
    }
}

public struct AnalysisConfig: Codable, Equatable, Sendable {
    public var sections: AnalysisSections
    public var order: [String]
    public var customInstructions: String

    public init(sections: AnalysisSections, order: [String], customInstructions: String) {
        self.sections = sections
        self.order = order
        self.customInstructions = customInstructions
    }
}

public struct AnalysisSections: Codable, Equatable, Sendable {
    public var summary: SectionConfig
    public var timeline: SectionConfig
    public var keyPoints: SectionConfig
    public var tasks: SectionConfig
    public var decisions: SectionConfig
    public var ideas: SectionConfig
    public var tags: SectionConfig

    enum CodingKeys: String, CodingKey {
        case summary, timeline
        case keyPoints = "key_points"
        case tasks, decisions, ideas, tags
    }

    public init(
        summary: SectionConfig, timeline: SectionConfig, keyPoints: SectionConfig, tasks: SectionConfig,
        decisions: SectionConfig, ideas: SectionConfig, tags: SectionConfig
    ) {
        self.summary = summary
        self.timeline = timeline
        self.keyPoints = keyPoints
        self.tasks = tasks
        self.decisions = decisions
        self.ideas = ideas
        self.tags = tags
    }

    /// 節名（JSON のキー。`SectionName.all` のどれか）で引く。無い名前は nil。
    public func section(named name: String) -> SectionConfig? {
        switch name {
        case "summary": return summary
        case "timeline": return timeline
        case "key_points": return keyPoints
        case "tasks": return tasks
        case "decisions": return decisions
        case "ideas": return ideas
        case "tags": return tags
        default: return nil
        }
    }

    /// F-54: `summary` と `timeline` の JSON には `maxItems` が無い（`maxItems` を持つのは 5 節だけ。PLAN §6.2）。
    /// この 2 つだけ `HeadingOnlySection` で符号化・復号し、`SectionConfig.maxItems` は常に nil になる。
    private struct HeadingOnlySection: Codable, Equatable, Sendable {
        var enabled: Bool
        var heading: String?

        /// nil の `heading` を `null` として書く（書き出した config.json を読み直すと CV-39 にならないように）。
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(enabled, forKey: .enabled)
            try container.encode(heading, forKey: .heading)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let summaryOnly = try container.decode(HeadingOnlySection.self, forKey: .summary)
        let timelineOnly = try container.decode(HeadingOnlySection.self, forKey: .timeline)
        summary = SectionConfig(enabled: summaryOnly.enabled, heading: summaryOnly.heading, maxItems: nil)
        timeline = SectionConfig(enabled: timelineOnly.enabled, heading: timelineOnly.heading, maxItems: nil)
        keyPoints = try container.decode(SectionConfig.self, forKey: .keyPoints)
        tasks = try container.decode(SectionConfig.self, forKey: .tasks)
        decisions = try container.decode(SectionConfig.self, forKey: .decisions)
        ideas = try container.decode(SectionConfig.self, forKey: .ideas)
        tags = try container.decode(SectionConfig.self, forKey: .tags)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(HeadingOnlySection(enabled: summary.enabled, heading: summary.heading), forKey: .summary)
        try container.encode(
            HeadingOnlySection(enabled: timeline.enabled, heading: timeline.heading), forKey: .timeline)
        try container.encode(keyPoints, forKey: .keyPoints)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(ideas, forKey: .ideas)
        try container.encode(tags, forKey: .tags)
    }
}

/// `maxItems` は `key_points` / `tasks` / `decisions` / `ideas` / `tags` の 5 節だけが持つ（F-54）。
/// `summary` / `timeline` では常に nil（JSON に書いたら CV-01）。
public struct SectionConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var heading: String?
    public var maxItems: Int?

    public init(enabled: Bool, heading: String?, maxItems: Int?) {
        self.enabled = enabled
        self.heading = heading
        self.maxItems = maxItems
    }

    /// nil の `heading` / `maxItems` を `null` として書く（synthesized は nil のキーを省く）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(heading, forKey: .heading)
        try container.encode(maxItems, forKey: .maxItems)
    }
}

public enum SectionName {
    /// LLM の JSON のキーと同じ節名。この順が CV-17 のメッセージと CV-56 の検査の順。
    public static let all: [String] = ["summary", "timeline", "key_points", "tasks", "decisions", "ideas", "tags"]
}

public struct ObsidianConfig: Codable, Equatable, Sendable {
    public var maxTitleBytes: Int
    public var defaultTags: [String]
    public var raw: RawNoteConfig
    public var wiki: WikiNoteConfig

    public init(maxTitleBytes: Int, defaultTags: [String], raw: RawNoteConfig, wiki: WikiNoteConfig) {
        self.maxTitleBytes = maxTitleBytes
        self.defaultTags = defaultTags
        self.raw = raw
        self.wiki = wiki
    }
}

public struct RawNoteConfig: Codable, Equatable, Sendable {
    public var folderTemplate: String
    public var filenameTemplate: String
    public var timestampIntervalSeconds: Int
    public var partBoundaryHeading: Bool

    public init(
        folderTemplate: String, filenameTemplate: String, timestampIntervalSeconds: Int, partBoundaryHeading: Bool
    ) {
        self.folderTemplate = folderTemplate
        self.filenameTemplate = filenameTemplate
        self.timestampIntervalSeconds = timestampIntervalSeconds
        self.partBoundaryHeading = partBoundaryHeading
    }
}

public struct WikiNoteConfig: Codable, Equatable, Sendable {
    public var folderTemplate: String
    public var filenameTemplate: String
    public var linkDailyNote: Bool
    public var linkAdjacentDays: Bool
    public var linkTags: Bool
    public var linkOnlyExisting: Bool
    public var vaultIndexCacheSeconds: Int
    public var maxLinks: Int

    public init(
        folderTemplate: String, filenameTemplate: String, linkDailyNote: Bool, linkAdjacentDays: Bool, linkTags: Bool,
        linkOnlyExisting: Bool, vaultIndexCacheSeconds: Int, maxLinks: Int
    ) {
        self.folderTemplate = folderTemplate
        self.filenameTemplate = filenameTemplate
        self.linkDailyNote = linkDailyNote
        self.linkAdjacentDays = linkAdjacentDays
        self.linkTags = linkTags
        self.linkOnlyExisting = linkOnlyExisting
        self.vaultIndexCacheSeconds = vaultIndexCacheSeconds
        self.maxLinks = maxLinks
    }
}

public struct CleanupConfig: Codable, Equatable, Sendable {
    public var deleteSourceAudio: Bool
    public var deleteSkippedSource: Bool
    public var deleteNormalizedAfterTranscribe: Bool
    public var deleteEvaluationBackoffSeconds: [Int]
    public var deleteResultTimeoutSeconds: Int

    public init(
        deleteSourceAudio: Bool, deleteSkippedSource: Bool, deleteNormalizedAfterTranscribe: Bool,
        deleteEvaluationBackoffSeconds: [Int], deleteResultTimeoutSeconds: Int
    ) {
        self.deleteSourceAudio = deleteSourceAudio
        self.deleteSkippedSource = deleteSkippedSource
        self.deleteNormalizedAfterTranscribe = deleteNormalizedAfterTranscribe
        self.deleteEvaluationBackoffSeconds = deleteEvaluationBackoffSeconds
        self.deleteResultTimeoutSeconds = deleteResultTimeoutSeconds
    }
}

public struct RetryConfig: Codable, Equatable, Sendable {
    public var maxAttempts: Int
    public var backoffSeconds: [Int]

    public init(maxAttempts: Int, backoffSeconds: [Int]) {
        self.maxAttempts = maxAttempts
        self.backoffSeconds = backoffSeconds
    }
}

public struct LoggingConfig: Codable, Equatable, Sendable {
    public var level: String
    public var unsafeLogContent: Bool

    public init(level: String, unsafeLogContent: Bool) {
        self.level = level
        self.unsafeLogContent = unsafeLogContent
    }
}
