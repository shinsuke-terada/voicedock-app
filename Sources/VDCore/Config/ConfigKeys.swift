// config.json の全葉のキーパスと、オブジェクトの子の名前（PLAN §6.2）。キー集合の照合と ConfigEffect の網羅テストが使う。
import Foundation

public enum ConfigKeys {
    /// 全葉のキーパス（§6.2 の JSON の出現順）。配列は葉。ConfigEffect の網羅テストと、読み込みの 2 段目が使う。
    public static let allKeyPaths: [String] = [
        "schemaVersion", "timeZone", "vault.path", "vault.marker",
        "device.includeVolumes", "device.excludeVolumes", "device.mountMode", "device.stabilityFastPathSeconds",
        "device.stabilityIntervalSeconds", "device.stabilityChecks", "device.maxScanDepth",
        "device.scanIntervalSeconds", "device.snapshotMaxAgeSeconds",
        "audio.timeoutFactor", "audio.minTimeoutSeconds", "audio.durationToleranceSeconds",
        "audio.freeSpaceMultiplier", "audio.freeSpaceMarginBytes", "audio.stagingMaxBytes", "audio.hashChunkBytes",
        "audio.inboxRetain",
        "session.blockGapSeconds", "session.idleCloseSeconds", "session.allowReopen", "session.maxParts",
        "session.maxDurationSeconds",
        "transcription.whisperModelID", "transcription.language", "transcription.threads",
        "transcription.timeoutFactor", "transcription.minTimeoutSeconds", "transcription.maxTimeoutSeconds",
        "transcription.minChars", "transcription.vad.enabled", "transcription.vad.modelID",
        "transcription.vad.threshold", "transcription.vad.minSpeechDurationMs",
        "transcription.vad.minSilenceDurationMs", "transcription.vad.speechPadMs",
        "llm.modelID", "llm.contextSize", "llm.temperature", "llm.topP", "llm.maxOutputTokens",
        "llm.requestTimeoutSeconds", "llm.maxCharsPerRequest", "llm.maxSecondsPerRequest", "llm.chunkOverlapChars",
        "llm.repairAttempts",
        "llm.analysis.sections.summary.enabled", "llm.analysis.sections.summary.heading",
        "llm.analysis.sections.timeline.enabled", "llm.analysis.sections.timeline.heading",
        "llm.analysis.sections.key_points.enabled", "llm.analysis.sections.key_points.heading",
        "llm.analysis.sections.key_points.maxItems",
        "llm.analysis.sections.tasks.enabled", "llm.analysis.sections.tasks.heading",
        "llm.analysis.sections.tasks.maxItems",
        "llm.analysis.sections.decisions.enabled", "llm.analysis.sections.decisions.heading",
        "llm.analysis.sections.decisions.maxItems",
        "llm.analysis.sections.ideas.enabled", "llm.analysis.sections.ideas.heading",
        "llm.analysis.sections.ideas.maxItems",
        "llm.analysis.sections.tags.enabled", "llm.analysis.sections.tags.heading",
        "llm.analysis.sections.tags.maxItems",
        "llm.analysis.order", "llm.analysis.customInstructions",
        "obsidian.maxTitleBytes", "obsidian.defaultTags", "obsidian.raw.folderTemplate",
        "obsidian.raw.filenameTemplate", "obsidian.raw.timestampIntervalSeconds", "obsidian.raw.partBoundaryHeading",
        "obsidian.wiki.folderTemplate", "obsidian.wiki.filenameTemplate", "obsidian.wiki.linkDailyNote",
        "obsidian.wiki.linkAdjacentDays", "obsidian.wiki.linkTags", "obsidian.wiki.linkOnlyExisting",
        "obsidian.wiki.vaultIndexCacheSeconds", "obsidian.wiki.maxLinks",
        "cleanup.deleteSourceAudio", "cleanup.deleteSkippedSource", "cleanup.deleteNormalizedAfterTranscribe",
        "cleanup.deleteEvaluationBackoffSeconds", "cleanup.deleteResultTimeoutSeconds",
        "retry.maxAttempts", "retry.backoffSeconds", "logging.level", "logging.unsafeLogContent",
    ]

    /// 葉でない（オブジェクトの）キーパス。`allKeyPaths` の各要素の真の接頭辞（`.` 区切り）から作る。
    public static let objectPaths: Set<String> = {
        var result: Set<String> = []
        for path in allKeyPaths {
            let parts = path.split(separator: ".").map(String.init)
            for count in stride(from: 1, to: parts.count, by: 1) {
                result.insert(parts.prefix(count).joined(separator: "."))
            }
        }
        return result
    }()

    /// あるオブジェクトの直下の子の名前。ルートは "" で引く。
    public static func children(of objectPath: String) -> Set<String> {
        let prefix = objectPath.isEmpty ? "" : objectPath + "."
        var result: Set<String> = []
        for path in allKeyPaths where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            result.insert(String(rest.prefix { $0 != "." }))
        }
        return result
    }

    public static func isObject(_ path: String) -> Bool { objectPaths.contains(path) }
}
