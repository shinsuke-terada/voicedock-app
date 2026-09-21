// 設定の意味の検証（PLAN §6.4 の CV-08〜59）。表の順に全部評価し、1 つ目で止めない（CV-14 だけ CV-13 より先）。
import Foundation
import VDContract

public enum ConfigValidator {
    /// CV-13 で許すプレースホルダ。
    static let allowedPlaceholders: Set<String> = ["yyyymmdd", "date", "time"]
    /// CV-54 で許すログの水準（大小区別）。
    static let allowedLevels: Set<String> = ["DEBUG", "INFO", "WARNING", "ERROR"]
    /// CV-56 で `maxItems` を見る節（F-54。`SectionName.all` の順のうち `maxItems` を持つ 5 つ）。
    static let sectionsWithMaxItems: [String] = ["key_points", "tasks", "decisions", "ideas", "tags"]

    /// PLAN §6.4 の CV-08〜59 を表の順に全部評価する（CV-14 だけ CV-13 より先）。1 つ目で止めない。
    public static func validate(_ c: AppConfig, catalog: ModelCatalog, reaperConfObservation: ReaperConfObservation)
        -> [ConfigViolation]
    {
        var out = Collector()
        checkNotesAndSession(c, &out)
        checkAnalysis(c, &out)
        checkLocksAndPaths(c, catalog: catalog, reaperConfObservation: reaperConfObservation, &out)
        checkDevice(c, &out)
        checkNumbers(c, &out)
        return out.violations
    }

    /// 違反を積む。
    struct Collector {
        var violations: [ConfigViolation] = []

        mutating func add(_ rule: String, _ keyPath: String, _ message: String, code: ErrorCode = .configInvalidValue) {
            violations.append(ConfigViolation(rule: rule, code: code, keyPath: keyPath, message: message))
        }
    }

    /// 順 1〜8: CV-08・09・10・11・12・14・13・16。
    private static func checkNotesAndSession(_ c: AppConfig, _ out: inout Collector) {
        if !(c.session.blockGapSeconds >= 0) {
            out.add("CV-08", "session.blockGapSeconds", "0 以上であること（\(c.session.blockGapSeconds)）")
        }
        if !(c.retry.backoffSeconds.count >= c.retry.maxAttempts) {
            out.add(
                "CV-09", "retry.backoffSeconds",
                "maxAttempts と同数以上の要素が必要（\(c.retry.backoffSeconds.count) < \(c.retry.maxAttempts)）")
        }
        if !(c.llm.maxCharsPerRequest > c.llm.chunkOverlapChars * 2) {
            out.add(
                "CV-10", "llm.maxCharsPerRequest",
                "chunkOverlapChars の 2 倍より大きいこと（\(c.llm.maxCharsPerRequest) <= \(c.llm.chunkOverlapChars * 2)）")
        }
        let raw = c.obsidian.raw
        let wiki = c.obsidian.wiki
        checkFolderTemplate(raw.folderTemplate, keyPath: "obsidian.raw.folderTemplate", &out)
        checkFolderTemplate(wiki.folderTemplate, keyPath: "obsidian.wiki.folderTemplate", &out)
        if !(raw.folderTemplate != wiki.folderTemplate) {
            out.add("CV-12", "obsidian.wiki.folderTemplate", "raw.folderTemplate と同一にできない（\(wiki.folderTemplate)）")
        }
        let wikiFilenameHasTitle = wiki.filenameTemplate.contains("{title}")
        if wikiFilenameHasTitle {
            out.add("CV-14", "obsidian.wiki.filenameTemplate", "{title} を含んではならない（再生成のたびにファイルが増殖する）")
        }
        var templates: [(String, String)] = [
            ("obsidian.raw.folderTemplate", raw.folderTemplate),
            ("obsidian.raw.filenameTemplate", raw.filenameTemplate),
            ("obsidian.wiki.folderTemplate", wiki.folderTemplate),
        ]
        if !wikiFilenameHasTitle {
            templates.append(("obsidian.wiki.filenameTemplate", wiki.filenameTemplate))
        }
        for (keyPath, template) in templates {
            if let name = firstUnknownPlaceholder(template) {
                out.add("CV-13", keyPath, "未知のプレースホルダ {\(name)}（使えるのは {yyyymmdd} {date} {time}）")
            }
        }
        if !(1 <= c.obsidian.maxTitleBytes && c.obsidian.maxTitleBytes <= 255) {
            out.add("CV-16", "obsidian.maxTitleBytes", "1〜255 であること（\(c.obsidian.maxTitleBytes)）")
        }
    }

    /// CV-11: `/` で始まらず、かつ（前が真のときだけ）`/` で分けた要素（空要素は除く）に `..` が無い。
    private static func checkFolderTemplate(_ template: String, keyPath: String, _ out: inout Collector) {
        if template.hasPrefix("/") {
            out.add("CV-11", keyPath, "相対パスであること（\(template)）")
        } else if template.split(separator: "/").contains("..") {
            out.add("CV-11", keyPath, "'..' を含んではならない（\(template)）")
        }
    }

    /// CV-13 のプレースホルダの走査（voicedock の `\{([^}]*)\}` と同じ結果）。許可に無い最初の名前、無ければ nil。
    static func firstUnknownPlaceholder(_ template: String) -> String? {
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { return nil }
            let name = String(rest[afterOpen..<close])
            if !allowedPlaceholders.contains(name) { return name }
            rest = rest[rest.index(after: close)...]
        }
        return nil
    }

    /// 順 9〜11: CV-17・18・19。
    private static func checkAnalysis(_ c: AppConfig, _ out: inout Collector) {
        let analysis = c.llm.analysis
        var unknown: [String] = []
        var seen: Set<String> = []
        var duplicated: [String] = []
        for name in analysis.order {
            if !SectionName.all.contains(name) && !unknown.contains(name) {
                unknown.append(name)
            }
            if seen.contains(name) {
                if !duplicated.contains(name) { duplicated.append(name) }
            } else {
                seen.insert(name)
            }
        }
        if !unknown.isEmpty {
            out.add("CV-17", "llm.analysis.order", "sections に無い項目 [\(unknown.joined(separator: ", "))]")
        }
        if !duplicated.isEmpty {
            out.add("CV-17", "llm.analysis.order", "重複がある [\(duplicated.joined(separator: ", "))]")
        }
        if !(analysis.sections.summary.enabled == true) {
            out.add("CV-18", "llm.analysis.sections.summary.enabled", "true でなければならない（要約の中核）")
        }
        for name in analysis.order {
            guard let section = analysis.sections.section(named: name) else { continue }
            let keyPath = "llm.analysis.sections.\(name).heading"
            guard let heading = section.heading else {
                out.add("CV-19", keyPath, "order に載っている項目は heading を持つこと")
                continue
            }
            if !(heading.hasPrefix("#") && !heading.contains("\n") && !heading.contains("\r")) {
                out.add("CV-19", keyPath, "'#' で始まる 1 行であること")
            }
        }
    }

    /// 順 12〜22: CV-22・29・30・32・33・40・41・42・43・44・45。
    private static func checkLocksAndPaths(
        _ c: AppConfig, catalog: ModelCatalog, reaperConfObservation: ReaperConfObservation, _ out: inout Collector
    ) {
        if !(c.audio.stagingMaxBytes > c.audio.freeSpaceMarginBytes) {
            out.add(
                "CV-22", "audio.stagingMaxBytes",
                "freeSpaceMarginBytes より大きいこと（\(c.audio.stagingMaxBytes) <= \(c.audio.freeSpaceMarginBytes)）")
        }
        if !(c.audio.inboxRetain == AudioConfig.InboxRetain.normalized.rawValue
            || c.audio.inboxRetain == AudioConfig.InboxRetain.rawSaved.rawValue)
        {
            out.add("CV-29", "audio.inboxRetain", "normalized か raw_saved であること（\(c.audio.inboxRetain)）")
        }
        if case .valid(let observed) = reaperConfObservation,
            !(c.cleanup.deleteSourceAudio == observed.deleteSourceAudio)
        {
            out.add(
                "CV-30", "cleanup.deleteSourceAudio",
                "reaper.conf の DELETE_SOURCE_AUDIO（\(observed.deleteSourceAudio)）と食い違っている。片方だけの解除は事故のため処理を止める",
                code: .configLockMismatch)
        }
        if TimeZone(identifier: c.timeZone) == nil {
            out.add("CV-32", "timeZone", "解決できないタイムゾーン（\(c.timeZone)）")
        }
        if c.cleanup.deleteSourceAudio && c.device.mountMode == DeviceConfig.MountMode.ro.rawValue {
            out.add(
                "CV-33", "cleanup.deleteSourceAudio", "device.mountMode が ro のままでは削除は 1 件も行われない（ロック 2-B）",
                code: .configLockMismatch)
        }
        if let path = c.vault.path, !path.hasPrefix("/") {
            out.add("CV-40", "vault.path", "絶対パスであること（\(path)）")
        }
        let marker = c.vault.marker
        if !(!marker.isEmpty && !marker.contains("/") && marker != "." && marker != "..") {
            out.add("CV-41", "vault.marker", "空でなく、/ を含まず、. と .. 以外であること（\(marker)）")
        }
        if let modelID = c.llm.modelID, catalog.entry(kind: .llm, id: modelID) == nil,
            CustomModelID.sha256(of: modelID) == nil
        {
            out.add("CV-42", "llm.modelID", "カタログに無い ID（\(modelID)）")
        }
        if !(!c.cleanup.deleteSkippedSource || c.cleanup.deleteSourceAudio) {
            out.add("CV-43", "cleanup.deleteSkippedSource", "deleteSourceAudio が false のときは true にできない")
        }
        let whisperID = c.transcription.whisperModelID
        if catalog.entry(kind: .whisper, id: whisperID) == nil {
            out.add("CV-44", "transcription.whisperModelID", "カタログに無い Whisper モデル（\(whisperID)）")
        }
        let vad = c.transcription.vad
        if !(!vad.enabled || catalog.entry(kind: .vad, id: vad.modelID) != nil) {
            out.add("CV-45", "transcription.vad.modelID", "カタログに無い VAD モデル（\(vad.modelID)）")
        }
    }

    /// 順 23〜27: CV-46・47・48・49・50。
    private static func checkDevice(_ c: AppConfig, _ out: inout Collector) {
        let d = c.device
        if !(d.snapshotMaxAgeSeconds > d.scanIntervalSeconds) {
            out.add(
                "CV-46", "device.snapshotMaxAgeSeconds",
                "scanIntervalSeconds より大きいこと（\(d.snapshotMaxAgeSeconds) <= \(d.scanIntervalSeconds)）")
        }
        for (i, name) in d.includeVolumes.enumerated() where name.isEmpty {
            out.add("CV-47", "device.includeVolumes.\(i)", "空文字にできない")
        }
        for (i, name) in d.excludeVolumes.enumerated() where name.isEmpty {
            out.add("CV-47", "device.excludeVolumes.\(i)", "空文字にできない")
        }
        if DeviceConfig.MountMode(rawValue: d.mountMode) == nil {
            out.add("CV-48", "device.mountMode", "ro か rw であること（\(d.mountMode)）")
        }
        atLeast(
            "CV-49", 1, prefix: "device.",
            [
                ("stabilityFastPathSeconds", d.stabilityFastPathSeconds),
                ("stabilityIntervalSeconds", d.stabilityIntervalSeconds), ("stabilityChecks", d.stabilityChecks),
                ("maxScanDepth", d.maxScanDepth),
            ], &out)
        atLeast("CV-50", 60, prefix: "device.", [("scanIntervalSeconds", d.scanIntervalSeconds)], &out)
    }

    /// 順 28〜36: CV-51〜59。
    private static func checkNumbers(_ c: AppConfig, _ out: inout Collector) {
        let llm = c.llm
        let sum = llm.maxCharsPerRequest + llm.maxOutputTokens + 2048
        if !(llm.contextSize >= sum) {
            out.add(
                "CV-51", "llm.contextSize",
                "maxCharsPerRequest + maxOutputTokens + 2048（\(sum)）以上であること（\(llm.contextSize)）")
        }
        let cleanup = c.cleanup
        if cleanup.deleteEvaluationBackoffSeconds.isEmpty {
            out.add("CV-52", "cleanup.deleteEvaluationBackoffSeconds", "空にできない")
        }
        atLeast(
            "CV-52", 0, prefix: "cleanup.deleteEvaluationBackoffSeconds.",
            indexed(cleanup.deleteEvaluationBackoffSeconds), &out)
        atLeast(
            "CV-52", 60, prefix: "cleanup.", [("deleteResultTimeoutSeconds", cleanup.deleteResultTimeoutSeconds)], &out)
        atLeast("CV-53", 1, prefix: "retry.", [("maxAttempts", c.retry.maxAttempts)], &out)
        atLeast("CV-53", 0, prefix: "retry.backoffSeconds.", indexed(c.retry.backoffSeconds), &out)
        if !allowedLevels.contains(c.logging.level) {
            out.add("CV-54", "logging.level", "DEBUG / INFO / WARNING / ERROR のどれかであること（\(c.logging.level)）")
        }
        checkTranscription(c.transcription, &out)
        checkLLMNumbers(llm, &out)
        let s = c.session
        atLeast(
            "CV-57", 1, prefix: "session.",
            [
                ("idleCloseSeconds", s.idleCloseSeconds), ("maxParts", s.maxParts),
                ("maxDurationSeconds", s.maxDurationSeconds),
            ],
            &out)
        checkAudioNumbers(c.audio, &out)
        let o = c.obsidian
        atLeast(
            "CV-59", 0, prefix: "obsidian.raw.", [("timestampIntervalSeconds", o.raw.timestampIntervalSeconds)], &out)
        atLeast(
            "CV-59", 0, prefix: "obsidian.wiki.",
            [("vaultIndexCacheSeconds", o.wiki.vaultIndexCacheSeconds), ("maxLinks", o.wiki.maxLinks)], &out)
        for (i, tag) in o.defaultTags.enumerated() where tag.isEmpty {
            out.add("CV-59", "obsidian.defaultTags.\(i)", "空文字にできない")
        }
    }

    /// CV-55。
    private static func checkTranscription(_ t: TranscriptionConfig, _ out: inout Collector) {
        atLeast("CV-55", 0, prefix: "transcription.", [("threads", t.threads)], &out)
        if !(t.timeoutFactor > 0) {
            out.add("CV-55", "transcription.timeoutFactor", "0 より大きいこと（\(t.timeoutFactor)）")
        }
        atLeast("CV-55", 1, prefix: "transcription.", [("minTimeoutSeconds", t.minTimeoutSeconds)], &out)
        if !(t.maxTimeoutSeconds >= t.minTimeoutSeconds) {
            out.add(
                "CV-55", "transcription.maxTimeoutSeconds",
                "minTimeoutSeconds 以上であること（\(t.maxTimeoutSeconds) < \(t.minTimeoutSeconds)）")
        }
        atLeast("CV-55", 1, prefix: "transcription.", [("minChars", t.minChars)], &out)
        if !(0 < t.vad.threshold && t.vad.threshold < 1) {
            out.add("CV-55", "transcription.vad.threshold", "0 より大きく 1 より小さいこと（\(t.vad.threshold)）")
        }
        atLeast(
            "CV-55", 0, prefix: "transcription.vad.",
            [
                ("minSpeechDurationMs", t.vad.minSpeechDurationMs),
                ("minSilenceDurationMs", t.vad.minSilenceDurationMs), ("speechPadMs", t.vad.speechPadMs),
            ], &out)
        if t.language.isEmpty {
            out.add("CV-55", "transcription.language", "空にできない")
        }
    }

    /// CV-56。
    private static func checkLLMNumbers(_ llm: LLMConfig, _ out: inout Collector) {
        if !(0 <= llm.temperature && llm.temperature <= 2) {
            out.add("CV-56", "llm.temperature", "0〜2 であること（\(llm.temperature)）")
        }
        if !(0 < llm.topP && llm.topP <= 1) {
            out.add("CV-56", "llm.topP", "0 より大きく 1 以下であること（\(llm.topP)）")
        }
        atLeast(
            "CV-56", 1, prefix: "llm.",
            [
                ("maxOutputTokens", llm.maxOutputTokens), ("requestTimeoutSeconds", llm.requestTimeoutSeconds),
                ("maxSecondsPerRequest", llm.maxSecondsPerRequest),
            ], &out)
        atLeast(
            "CV-56", 0, prefix: "llm.",
            [("chunkOverlapChars", llm.chunkOverlapChars), ("repairAttempts", llm.repairAttempts)], &out)
        for name in sectionsWithMaxItems {
            guard let maxItems = llm.analysis.sections.section(named: name)?.maxItems, !(maxItems >= 1) else {
                continue
            }
            out.add("CV-56", "llm.analysis.sections.\(name).maxItems", "null か 1 以上であること（\(maxItems)）")
        }
    }

    /// CV-58。
    private static func checkAudioNumbers(_ a: AudioConfig, _ out: inout Collector) {
        if !(a.timeoutFactor > 0) {
            out.add("CV-58", "audio.timeoutFactor", "0 より大きいこと（\(a.timeoutFactor)）")
        }
        atLeast("CV-58", 1, prefix: "audio.", [("minTimeoutSeconds", a.minTimeoutSeconds)], &out)
        if !(a.durationToleranceSeconds >= 0) {
            out.add("CV-58", "audio.durationToleranceSeconds", "0 以上であること（\(a.durationToleranceSeconds)）")
        }
        if !(a.freeSpaceMultiplier >= 1) {
            out.add("CV-58", "audio.freeSpaceMultiplier", "1 以上であること（\(a.freeSpaceMultiplier)）")
        }
        atLeast("CV-58", 0, prefix: "audio.", [("freeSpaceMarginBytes", a.freeSpaceMarginBytes)], &out)
        atLeast("CV-58", 4096, prefix: "audio.", [("hashChunkBytes", a.hashChunkBytes)], &out)
    }

    /// 整数の下限の検査。違反するキーごとに `<n> 以上であること（<v>）` を 1 件ずつ、並びの順に出す。
    private static func atLeast(
        _ rule: String, _ minimum: Int, prefix: String, _ values: [(String, Int)], _ out: inout Collector
    ) {
        for (name, value) in values where !(value >= minimum) {
            out.add(rule, prefix + name, "\(minimum) 以上であること（\(value)）")
        }
    }

    /// 配列の要素を `(添字, 値)` にする（keyPath の末尾が添字になる）。
    private static func indexed(_ values: [Int]) -> [(String, Int)] {
        values.enumerated().map { (String($0.offset), $0.element) }
    }
}
