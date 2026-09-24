// AppConfig の既定値と符号化のテスト（T-09）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("AppConfig")
struct AppConfigTests {
    /// PLAN §6.2 の JSON を逐語で（timeZone だけ "Asia/Tokyo"）。
    static let section62 = """
        {
          "schemaVersion": 2,
          "timeZone": "Asia/Tokyo",
          "vault": { "path": null, "marker": ".obsidian" },
          "device": {
            "includeVolumes": ["DJIMIC3"],
            "excludeVolumes": ["Macintosh HD", "com.apple.TimeMachine.*", ".*"],
            "mountMode": "ro",
            "stabilityFastPathSeconds": 60, "stabilityIntervalSeconds": 3, "stabilityChecks": 2,
            "maxScanDepth": 3, "scanIntervalSeconds": 300, "snapshotMaxAgeSeconds": 900
          },
          "audio": {
            "timeoutFactor": 0.5, "minTimeoutSeconds": 180, "durationToleranceSeconds": 1.0,
            "freeSpaceMultiplier": 2.0, "freeSpaceMarginBytes": 2147483648, "stagingMaxBytes": 5368709120,
            "hashChunkBytes": 1048576, "inboxRetain": "normalized"
          },
          "session": { "blockGapSeconds": 3600, "idleCloseSeconds": 1800, "allowReopen": true, "maxParts": 64, "maxDurationSeconds": 86400 },
          "transcription": {
            "whisperModelID": "large-v3-turbo-q5_0", "language": "ja", "threads": 0,
            "timeoutFactor": 3.0, "minTimeoutSeconds": 600, "maxTimeoutSeconds": 21600, "minChars": 1,
            "vad": { "enabled": true, "modelID": "silero-v5.1.2", "threshold": 0.5,
                     "minSpeechDurationMs": 250, "minSilenceDurationMs": 1000, "speechPadMs": 200 },
            "diarization": { "enabled": false }
          },
          "llm": {
            "modelID": null, "contextSize": 32768, "temperature": 0.1, "topP": 0.9, "maxOutputTokens": 8192,
            "requestTimeoutSeconds": 1800, "maxCharsPerRequest": 20000, "maxSecondsPerRequest": 3600,
            "chunkOverlapChars": 500, "repairAttempts": 1,
            "analysis": {
              "sections": {
                "summary":    { "enabled": true, "heading": "## Summary" },
                "timeline":   { "enabled": true, "heading": "## Timeline" },
                "key_points": { "enabled": true, "heading": "## Key Points", "maxItems": 20 },
                "tasks":      { "enabled": true, "heading": "## Tasks",      "maxItems": 50 },
                "decisions":  { "enabled": true, "heading": "## Decisions",  "maxItems": 30 },
                "ideas":      { "enabled": true, "heading": "## Ideas",      "maxItems": 30 },
                "tags":       { "enabled": true, "heading": null,            "maxItems": 15 }
              },
              "order": ["summary", "timeline", "key_points", "tasks", "decisions", "ideas"],
              "customInstructions": ""
            }
          },
          "obsidian": {
            "maxTitleBytes": 180, "defaultTags": ["voice", "voicedock"],
            "raw":  { "folderTemplate": "Daily/Voice/Raw/{yyyymmdd}", "filenameTemplate": "{date} raw",
                      "timestampIntervalSeconds": 300, "partBoundaryHeading": true },
            "wiki": { "folderTemplate": "Daily/Voice/Wiki/{yyyymmdd}", "filenameTemplate": "{date} Voice",
                      "linkDailyNote": true, "linkAdjacentDays": true, "linkTags": true, "linkOnlyExisting": true,
                      "vaultIndexCacheSeconds": 300, "maxLinks": 20 }
          },
          "cleanup": {
            "deleteSourceAudio": false, "deleteSkippedSource": false, "deleteNormalizedAfterTranscribe": true,
            "deleteEvaluationBackoffSeconds": [60, 300, 900, 3600], "deleteResultTimeoutSeconds": 3600
          },
          "retry": { "maxAttempts": 3, "backoffSeconds": [3, 10, 30] },
          "logging": { "level": "INFO", "unsafeLogContent": false }
        }
        """

    static func encodedObject(_ config: AppConfig) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: ConfigLoader.encode(config))
        return try #require(object as? [String: Any])
    }

    static func object(_ root: [String: Any], _ path: String) -> [String: Any]? {
        var current: Any = root
        for key in path.split(separator: ".").map(String.init) {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current as? [String: Any]
    }

    @Test("既定値は PLAN §6.2 の JSON と同じ")
    func defaultsMatchSection62() {
        let result = ConfigLoader.load(
            data: Data(Self.section62.utf8), catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
        #expect(result == .valid(AppConfig.defaults(timeZone: "Asia/Tokyo")))
    }

    @Test("符号化は null を省かない")
    func encodeWritesNullsExplicitly() throws {
        let text = try #require(String(data: ConfigLoader.encode(AppConfig.defaults(timeZone: "UTC")), encoding: .utf8))
        #expect(text.contains(#""path" : null"#))
        #expect(text.contains(#""modelID" : null"#))
        #expect(text.contains(#""heading" : null"#))
    }

    @Test("F-54 summary と timeline に maxItems のキーが無い")
    func summaryAndTimelineHaveNoMaxItems() throws {
        let root = try Self.encodedObject(AppConfig.defaults(timeZone: "UTC"))
        for name in ["summary", "timeline"] {
            let section = try #require(Self.object(root, "llm.analysis.sections.\(name)"))
            #expect(section.keys.sorted() == ["enabled", "heading"])
        }
        for name in ["key_points", "tasks", "decisions", "ideas", "tags"] {
            let section = try #require(Self.object(root, "llm.analysis.sections.\(name)"))
            #expect(section.keys.sorted() == ["enabled", "heading", "maxItems"])
        }
        #expect(!ConfigKeys.allKeyPaths.contains("llm.analysis.sections.summary.maxItems"))
        #expect(!ConfigKeys.allKeyPaths.contains("llm.analysis.sections.timeline.maxItems"))
    }

    @Test("符号化はキーの昇順で末尾改行 1 つ")
    func encodeEndsWithNewlineAndSortsKeys() throws {
        let text = try #require(String(data: ConfigLoader.encode(AppConfig.defaults(timeZone: "UTC")), encoding: .utf8))
        #expect(text.hasPrefix("{\n  \"audio\" : {"))
        #expect(text.hasSuffix("}\n"))
        #expect(!text.hasSuffix("\n\n"))
    }

    @Test("符号化は / をエスケープしない")
    func encodeDoesNotEscapeSlashes() throws {
        let text = try #require(String(data: ConfigLoader.encode(AppConfig.defaults(timeZone: "UTC")), encoding: .utf8))
        #expect(text.contains("Daily/Voice/Raw/{yyyymmdd}"))
    }

    @Test("書いて読むと同じ値")
    func roundTrip() throws {
        let defaults = AppConfig.defaults(timeZone: "Asia/Tokyo")
        let result = ConfigLoader.load(
            data: try ConfigLoader.encode(defaults), catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
        #expect(result == .valid(defaults))
    }

    @Test("F-54 summary の heading が nil でも null で書き、読み直せる")
    func headingOnlySectionWritesNull() throws {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.llm.analysis.order = ["timeline", "key_points"]
        config.llm.analysis.sections.summary.heading = nil
        let result = ConfigLoader.load(
            data: try ConfigLoader.encode(config), catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
        #expect(result == .valid(config))
    }

    @Test("section(named:) は 7 つの節を引ける")
    func sectionNamedLooksUpAllSeven() {
        let sections = AppConfig.defaults(timeZone: "UTC").llm.analysis.sections
        #expect(SectionName.all == ["summary", "timeline", "key_points", "tasks", "decisions", "ideas", "tags"])
        for name in ["summary", "timeline", "key_points", "tasks", "decisions", "ideas", "tags"] {
            #expect(sections.section(named: name) != nil, "\(name)")
        }
        #expect(sections.section(named: "unknown") == nil)
        #expect(sections.section(named: "") == nil)
    }

    @Test("不正な mountMode / inboxRetain は安全側に倒す")
    func modeAccessorsFallBackToSafeSide() {
        var config = AppConfig.defaults(timeZone: "UTC")
        config.device.mountMode = "x"
        config.audio.inboxRetain = "x"
        #expect(config.device.mode == .ro)
        #expect(config.audio.retain == .rawSaved)
        config.device.mountMode = "rw"
        config.audio.inboxRetain = "normalized"
        #expect(config.device.mode == .rw)
        #expect(config.audio.retain == .normalized)
    }

    @Test("allKeyPaths は既定値の符号化の葉と一致する")
    func allKeyPathsMatchDefaultsEncoding() throws {
        let root = try Self.encodedObject(AppConfig.defaults(timeZone: "UTC"))
        var leaves: Set<String> = []
        func walk(_ object: [String: Any], _ prefix: String) {
            for (key, value) in object {
                let path = prefix.isEmpty ? key : prefix + "." + key
                if let child = value as? [String: Any] {
                    walk(child, path)
                } else {
                    leaves.insert(path)
                }
            }
        }
        walk(root, "")
        #expect(leaves == Set(ConfigKeys.allKeyPaths))
        #expect(Set(ConfigKeys.allKeyPaths).count == ConfigKeys.allKeyPaths.count)
    }

    @Test("CE schemaVersion 3 にすると CV-39 で読めない")
    func ceSchemaVersion() throws {
        var root = try Self.encodedObject(AppConfig.defaults(timeZone: "Asia/Tokyo"))
        root["schemaVersion"] = 3
        let data = try JSONSerialization.data(withJSONObject: root)
        let result = ConfigLoader.load(data: data, catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
        #expect(
            result
                == .invalid([
                    ConfigViolation(
                        rule: "CV-39", code: .configInvalidValue, keyPath: "schemaVersion",
                        message: "この版のアプリより新しい設定です（schemaVersion 3）。アプリを更新してください")
                ]))
    }
}
