// ConfigValidator（PLAN §6.4 の CV-08〜60）のテスト（T-09）。既定値を 1 か所だけ変えて、違反の例と境界で通る例を見る。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ConfigValidator")
struct ConfigValidatorTests {
    /// 既定値（timeZone は Asia/Tokyo）を変えて検証する。
    static func check(
        _ observation: ReaperConfObservation = .missing, _ mutate: (inout AppConfig) -> Void
    ) -> [ConfigViolation] {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        mutate(&config)
        return ConfigValidator.validate(config, catalog: TestCatalogs.minimal, reaperConfObservation: observation)
    }

    static func one(
        _ rule: String, _ keyPath: String, _ message: String, code: ErrorCode = .configInvalidValue
    ) -> [ConfigViolation] {
        [ConfigViolation(rule: rule, code: code, keyPath: keyPath, message: message)]
    }

    // MARK: - CV-08〜19

    @Test("CV-08 blockGapSeconds が負なら違反")
    func cv08Violation() {
        #expect(
            Self.check { $0.session.blockGapSeconds = -1 }
                == Self.one("CV-08", "session.blockGapSeconds", "0 以上であること（-1）"))
    }

    @Test("CV-08 blockGapSeconds 0 は通る")
    func cv08Boundary() {
        #expect(Self.check { $0.session.blockGapSeconds = 0 }.isEmpty)
    }

    @Test("CV-09 backoffSeconds が maxAttempts より少なければ違反")
    func cv09Violation() {
        #expect(
            Self.check { $0.retry.maxAttempts = 4 }
                == Self.one("CV-09", "retry.backoffSeconds", "maxAttempts と同数以上の要素が必要（3 < 4）"))
    }

    @Test("CV-09 同数なら通る")
    func cv09Boundary() {
        #expect(Self.check { $0.retry.maxAttempts = 3 }.isEmpty)
    }

    @Test("CV-10 maxCharsPerRequest が overlap の 2 倍以下なら違反")
    func cv10Violation() {
        #expect(
            Self.check { $0.llm.chunkOverlapChars = 10_000 }
                == Self.one("CV-10", "llm.maxCharsPerRequest", "chunkOverlapChars の 2 倍より大きいこと（20000 <= 20000）"))
    }

    @Test("CV-10 overlap 9999 は通る")
    func cv10Boundary() {
        #expect(Self.check { $0.llm.chunkOverlapChars = 9999 }.isEmpty)
    }

    @Test("CV-11 絶対パスと .. の要素は違反")
    func cv11Violation() {
        #expect(
            Self.check { $0.obsidian.raw.folderTemplate = "/abs/{yyyymmdd}" }
                == Self.one("CV-11", "obsidian.raw.folderTemplate", "相対パスであること（/abs/{yyyymmdd}）"))
        #expect(
            Self.check { $0.obsidian.wiki.folderTemplate = "a/../b" }
                == Self.one("CV-11", "obsidian.wiki.folderTemplate", "'..' を含んではならない（a/../b）"))
    }

    @Test("CV-11 要素が ..b なら通る")
    func cv11Boundary() {
        #expect(Self.check { $0.obsidian.wiki.folderTemplate = "a/..b/c" }.isEmpty)
    }

    @Test("CV-12 raw と wiki の folderTemplate が同じなら違反")
    func cv12Violation() {
        #expect(
            Self.check { $0.obsidian.wiki.folderTemplate = $0.obsidian.raw.folderTemplate }
                == Self.one(
                    "CV-12", "obsidian.wiki.folderTemplate", "raw.folderTemplate と同一にできない（Daily/Voice/Raw/{yyyymmdd}）"))
    }

    @Test("CV-12 既定は通る")
    func cv12Boundary() {
        #expect(Self.check { _ in }.isEmpty)
    }

    @Test("CV-14 wiki の filenameTemplate に {title} があれば違反し、CV-13 は出ない")
    func cv14Violation() {
        #expect(
            Self.check { $0.obsidian.wiki.filenameTemplate = "{title}" }
                == Self.one(
                    "CV-14", "obsidian.wiki.filenameTemplate", "{title} を含んではならない（再生成のたびにファイルが増殖する）"))
    }

    @Test("CV-14 既定は通る")
    func cv14Boundary() {
        #expect(Self.check { $0.obsidian.wiki.filenameTemplate = "{date} Voice" }.isEmpty)
    }

    @Test("CV-13 未知のプレースホルダは違反")
    func cv13Violation() {
        #expect(
            Self.check { $0.obsidian.raw.filenameTemplate = "{date} {part}" }
                == Self.one(
                    "CV-13", "obsidian.raw.filenameTemplate", "未知のプレースホルダ {part}（使えるのは {yyyymmdd} {date} {time}）"))
        #expect(
            Self.check { $0.obsidian.raw.filenameTemplate = "{a{b}" }
                == Self.one(
                    "CV-13", "obsidian.raw.filenameTemplate", "未知のプレースホルダ {a{b}（使えるのは {yyyymmdd} {date} {time}）"))
    }

    @Test("CV-13 閉じない { と {time} は通る")
    func cv13Boundary() {
        #expect(Self.check { $0.obsidian.raw.filenameTemplate = "{date" }.isEmpty)
        #expect(Self.check { $0.obsidian.raw.filenameTemplate = "{time}" }.isEmpty)
    }

    @Test("CV-16 maxTitleBytes が 1〜255 の外なら違反")
    func cv16Violation() {
        #expect(
            Self.check { $0.obsidian.maxTitleBytes = 0 }
                == Self.one("CV-16", "obsidian.maxTitleBytes", "1〜255 であること（0）"))
        #expect(
            Self.check { $0.obsidian.maxTitleBytes = 256 }
                == Self.one("CV-16", "obsidian.maxTitleBytes", "1〜255 であること（256）"))
    }

    @Test("CV-16 1 と 255 は通る")
    func cv16Boundary() {
        #expect(Self.check { $0.obsidian.maxTitleBytes = 1 }.isEmpty)
        #expect(Self.check { $0.obsidian.maxTitleBytes = 255 }.isEmpty)
    }

    @Test("CV-17 sections に無い項目と重複は違反（この順）")
    func cv17Violation() {
        let expected =
            Self.one("CV-17", "llm.analysis.order", "sections に無い項目 [x]")
            + Self.one("CV-17", "llm.analysis.order", "重複がある [x]")
        #expect(Self.check { $0.llm.analysis.order = ["summary", "x", "x"] } == expected)
    }

    @Test("CV-17 空の order は通る")
    func cv17Boundary() {
        #expect(Self.check { $0.llm.analysis.order = [] }.isEmpty)
    }

    @Test("CV-18 summary.enabled が false なら違反")
    func cv18Violation() {
        #expect(
            Self.check { $0.llm.analysis.sections.summary.enabled = false }
                == Self.one("CV-18", "llm.analysis.sections.summary.enabled", "true でなければならない（要約の中核）"))
    }

    @Test("CV-18 既定は通る")
    func cv18Boundary() {
        #expect(Self.check { $0.llm.analysis.sections.summary.enabled = true }.isEmpty)
    }

    @Test("CV-19 order に載る節の heading が無い・# で始まらない・複数行なら違反")
    func cv19Violation() {
        let keyPath = "llm.analysis.sections.timeline.heading"
        #expect(
            Self.check { $0.llm.analysis.sections.timeline.heading = nil }
                == Self.one("CV-19", keyPath, "order に載っている項目は heading を持つこと"))
        #expect(
            Self.check { $0.llm.analysis.sections.timeline.heading = "Timeline" }
                == Self.one("CV-19", keyPath, "'#' で始まる 1 行であること"))
        #expect(
            Self.check { $0.llm.analysis.sections.timeline.heading = "# a\nb" }
                == Self.one("CV-19", keyPath, "'#' で始まる 1 行であること"))
    }

    @Test("CV-19 order に無い節は heading が無くても通る")
    func cv19Boundary() {
        let violations = Self.check {
            $0.llm.analysis.order = ["summary", "key_points", "tasks", "decisions", "ideas"]
            $0.llm.analysis.sections.timeline.heading = nil
        }
        #expect(violations.isEmpty)
    }

    // MARK: - CV-22〜45

    @Test("CV-22 stagingMaxBytes が margin 以下なら違反")
    func cv22Violation() {
        #expect(
            Self.check { $0.audio.stagingMaxBytes = 2_147_483_648 }
                == Self.one(
                    "CV-22", "audio.stagingMaxBytes", "freeSpaceMarginBytes より大きいこと（2147483648 <= 2147483648）"))
    }

    @Test("CV-22 margin + 1 は通る")
    func cv22Boundary() {
        #expect(Self.check { $0.audio.stagingMaxBytes = 2_147_483_649 }.isEmpty)
    }

    @Test("CV-29 inboxRetain が不正なら違反")
    func cv29Violation() {
        #expect(
            Self.check { $0.audio.inboxRetain = "none" }
                == Self.one("CV-29", "audio.inboxRetain", "normalized か raw_saved であること（none）"))
    }

    @Test("CV-29 raw_saved は通る")
    func cv29Boundary() {
        #expect(Self.check { $0.audio.inboxRetain = "raw_saved" }.isEmpty)
    }

    @Test("CV-30 reaper.conf と削除有効が食い違えば違反（どちら向きも）")
    func cv30Violation() {
        let enabled: (inout AppConfig) -> Void = {
            $0.cleanup.deleteSourceAudio = true
            $0.device.mountMode = "rw"
        }
        #expect(
            Self.check(.valid(ReaperConf(deleteSourceAudio: false)), enabled)
                == Self.one(
                    "CV-30", "cleanup.deleteSourceAudio",
                    "reaper.conf の DELETE_SOURCE_AUDIO（false）と食い違っている。片方だけの解除は事故のため処理を止める",
                    code: .configLockMismatch))
        #expect(
            Self.check(.valid(ReaperConf(deleteSourceAudio: true))) { _ in }
                == Self.one(
                    "CV-30", "cleanup.deleteSourceAudio",
                    "reaper.conf の DELETE_SOURCE_AUDIO（true）と食い違っている。片方だけの解除は事故のため処理を止める",
                    code: .configLockMismatch))
    }

    @Test("CV-30 reaper.conf が無い・読めないときは評価せず、両方 true なら通る")
    func cv30Boundary() {
        let enabled: (inout AppConfig) -> Void = {
            $0.cleanup.deleteSourceAudio = true
            $0.device.mountMode = "rw"
        }
        #expect(Self.check(.missing, enabled).isEmpty)
        #expect(Self.check(.invalid(.unreadable), enabled).isEmpty)
        #expect(Self.check(.valid(ReaperConf(deleteSourceAudio: true)), enabled).isEmpty)
    }

    @Test("CV-32 解決できないタイムゾーンは違反")
    func cv32Violation() {
        #expect(
            Self.check { $0.timeZone = "Mars/Base" } == Self.one("CV-32", "timeZone", "解決できないタイムゾーン（Mars/Base）"))
    }

    @Test("CV-32 UTC は通る")
    func cv32Boundary() {
        #expect(Self.check { $0.timeZone = "UTC" }.isEmpty)
    }

    @Test("CV-33 削除有効で mountMode が ro なら違反")
    func cv33Violation() {
        #expect(
            Self.check { $0.cleanup.deleteSourceAudio = true }
                == Self.one(
                    "CV-33", "cleanup.deleteSourceAudio", "device.mountMode が ro のままでは削除は 1 件も行われない（ロック 2-B）",
                    code: .configLockMismatch))
    }

    @Test("CV-33 mountMode rw なら通る")
    func cv33Boundary() {
        let violations = Self.check {
            $0.cleanup.deleteSourceAudio = true
            $0.device.mountMode = "rw"
        }
        #expect(violations.isEmpty)
    }

    @Test("CV-40 vault.path が絶対パスでなければ違反")
    func cv40Violation() {
        #expect(
            Self.check { $0.vault.path = "relative/vault" }
                == Self.one("CV-40", "vault.path", "絶対パスであること（relative/vault）"))
        #expect(Self.check { $0.vault.path = "" } == Self.one("CV-40", "vault.path", "絶対パスであること（）"))
    }

    @Test("CV-40 nil と絶対パスは通る")
    func cv40Boundary() {
        #expect(Self.check { $0.vault.path = nil }.isEmpty)
        #expect(Self.check { $0.vault.path = "/Users/x/Vault" }.isEmpty)
    }

    @Test("CV-41 vault.marker が空・/ を含む・. や .. なら違反")
    func cv41Violation() {
        for marker in ["", "a/b", ".", ".."] {
            #expect(
                Self.check { $0.vault.marker = marker }
                    == Self.one("CV-41", "vault.marker", "空でなく、/ を含まず、. と .. 以外であること（\(marker)）"))
        }
    }

    @Test("CV-41 .obsidian と obsidian は通る")
    func cv41Boundary() {
        #expect(Self.check { $0.vault.marker = ".obsidian" }.isEmpty)
        #expect(Self.check { $0.vault.marker = "obsidian" }.isEmpty)
    }

    @Test("CV-42 カタログに無い LLM の ID と大文字の custom は違反")
    func cv42Violation() {
        #expect(Self.check { $0.llm.modelID = "nope" } == Self.one("CV-42", "llm.modelID", "カタログに無い ID（nope）"))
        let upper = "custom:" + String(repeating: "A", count: 64)
        #expect(Self.check { $0.llm.modelID = upper } == Self.one("CV-42", "llm.modelID", "カタログに無い ID（\(upper)）"))
    }

    @Test("CV-42 nil・カタログの ID・custom の小文字 16 進は通る")
    func cv42Boundary() {
        #expect(Self.check { $0.llm.modelID = nil }.isEmpty)
        #expect(Self.check { $0.llm.modelID = "test-llm" }.isEmpty)
        #expect(Self.check { $0.llm.modelID = "custom:" + String(repeating: "0", count: 64) }.isEmpty)
    }

    @Test("CV-43 deleteSourceAudio が false で deleteSkippedSource が true なら違反")
    func cv43Violation() {
        #expect(
            Self.check { $0.cleanup.deleteSkippedSource = true }
                == Self.one("CV-43", "cleanup.deleteSkippedSource", "deleteSourceAudio が false のときは true にできない"))
    }

    @Test("CV-43 両方 true（mountMode rw）は通る")
    func cv43Boundary() {
        let violations = Self.check {
            $0.cleanup.deleteSkippedSource = true
            $0.cleanup.deleteSourceAudio = true
            $0.device.mountMode = "rw"
        }
        #expect(violations.isEmpty)
    }

    @Test("CV-44 カタログに無い Whisper モデルは違反")
    func cv44Violation() {
        #expect(
            Self.check { $0.transcription.whisperModelID = "tiny" }
                == Self.one("CV-44", "transcription.whisperModelID", "カタログに無い Whisper モデル（tiny）"))
    }

    @Test("CV-44 既定は通る")
    func cv44Boundary() {
        #expect(Self.check { $0.transcription.whisperModelID = "large-v3-turbo-q5_0" }.isEmpty)
    }

    @Test("CV-45 VAD が有効でカタログに無いモデルなら違反")
    func cv45Violation() {
        #expect(
            Self.check { $0.transcription.vad.modelID = "x" }
                == Self.one("CV-45", "transcription.vad.modelID", "カタログに無い VAD モデル（x）"))
    }

    @Test("CV-45 VAD が無効なら無いモデルでも通る")
    func cv45Boundary() {
        let violations = Self.check {
            $0.transcription.vad.enabled = false
            $0.transcription.vad.modelID = "x"
        }
        #expect(violations.isEmpty)
    }

    // MARK: - CV-46〜50

    @Test("CV-46 snapshotMaxAgeSeconds が scanInterval 以下なら違反")
    func cv46Violation() {
        #expect(
            Self.check { $0.device.snapshotMaxAgeSeconds = 300 }
                == Self.one("CV-46", "device.snapshotMaxAgeSeconds", "scanIntervalSeconds より大きいこと（300 <= 300）"))
    }

    @Test("CV-46 301 は通る")
    func cv46Boundary() {
        #expect(Self.check { $0.device.snapshotMaxAgeSeconds = 301 }.isEmpty)
    }

    @Test("CV-47 includeVolumes の空文字は違反")
    func cv47Violation() {
        #expect(
            Self.check { $0.device.includeVolumes = ["", "DJI*"] }
                == Self.one("CV-47", "device.includeVolumes.0", "空文字にできない"))
    }

    @Test("CV-47 空白 1 つは空文字ではない")
    func cv47Boundary() {
        #expect(Self.check { $0.device.includeVolumes = [" "] }.isEmpty)
    }

    @Test("CV-48 mountMode が ro / rw でなければ違反")
    func cv48Violation() {
        #expect(Self.check { $0.device.mountMode = "RO" } == Self.one("CV-48", "device.mountMode", "ro か rw であること（RO）"))
    }

    @Test("CV-48 rw は通る")
    func cv48Boundary() {
        #expect(Self.check { $0.device.mountMode = "rw" }.isEmpty)
    }

    static var cv49Keys: [(String, WritableKeyPath<DeviceConfig, Int>)] {
        [
            ("stabilityFastPathSeconds", \.stabilityFastPathSeconds),
            ("stabilityIntervalSeconds", \.stabilityIntervalSeconds), ("stabilityChecks", \.stabilityChecks),
            ("maxScanDepth", \.maxScanDepth),
        ]
    }

    @Test("CV-49 安定性と走査の深さが 0 なら違反")
    func cv49Violation() {
        for (name, key) in Self.cv49Keys {
            #expect(
                Self.check { $0.device[keyPath: key] = 0 } == Self.one("CV-49", "device.\(name)", "1 以上であること（0）"))
        }
    }

    @Test("CV-49 1 は通る")
    func cv49Boundary() {
        for (_, key) in Self.cv49Keys {
            #expect(Self.check { $0.device[keyPath: key] = 1 }.isEmpty)
        }
    }

    @Test("CV-50 scanIntervalSeconds が 60 未満なら違反")
    func cv50Violation() {
        #expect(
            Self.check { $0.device.scanIntervalSeconds = 59 }
                == Self.one("CV-50", "device.scanIntervalSeconds", "60 以上であること（59）"))
    }

    @Test("CV-50 60 は通る")
    func cv50Boundary() {
        #expect(Self.check { $0.device.scanIntervalSeconds = 60 }.isEmpty)
    }

    // MARK: - CV-51〜59

    @Test("CV-51 contextSize が足りなければ違反")
    func cv51Violation() {
        #expect(
            Self.check { $0.llm.contextSize = 30_239 }
                == Self.one(
                    "CV-51", "llm.contextSize", "maxCharsPerRequest + maxOutputTokens + 2048（30240）以上であること（30239）"))
    }

    @Test("CV-51 ちょうど 30240 は通る")
    func cv51Boundary() {
        #expect(Self.check { $0.llm.contextSize = 30_240 }.isEmpty)
    }

    @Test("CV-52 削除評価の backoff と結果の待ち時間の違反")
    func cv52Violation() {
        #expect(
            Self.check { $0.cleanup.deleteEvaluationBackoffSeconds = [] }
                == Self.one("CV-52", "cleanup.deleteEvaluationBackoffSeconds", "空にできない"))
        #expect(
            Self.check { $0.cleanup.deleteEvaluationBackoffSeconds = [60, -1] }
                == Self.one("CV-52", "cleanup.deleteEvaluationBackoffSeconds.1", "0 以上であること（-1）"))
        #expect(
            Self.check { $0.cleanup.deleteResultTimeoutSeconds = 59 }
                == Self.one("CV-52", "cleanup.deleteResultTimeoutSeconds", "60 以上であること（59）"))
    }

    @Test("CV-52 [0] と 60 は通る")
    func cv52Boundary() {
        #expect(Self.check { $0.cleanup.deleteEvaluationBackoffSeconds = [0] }.isEmpty)
        #expect(Self.check { $0.cleanup.deleteResultTimeoutSeconds = 60 }.isEmpty)
    }

    @Test("CV-53 maxAttempts 0 と負の backoff は違反")
    func cv53Violation() {
        #expect(Self.check { $0.retry.maxAttempts = 0 } == Self.one("CV-53", "retry.maxAttempts", "1 以上であること（0）"))
        #expect(
            Self.check { $0.retry.backoffSeconds = [3, -1, 30] }
                == Self.one("CV-53", "retry.backoffSeconds.1", "0 以上であること（-1）"))
    }

    @Test("CV-53 maxAttempts 1 は通る")
    func cv53Boundary() {
        #expect(Self.check { $0.retry.maxAttempts = 1 }.isEmpty)
    }

    @Test("CV-54 logging.level は大小を区別する")
    func cv54Violation() {
        #expect(
            Self.check { $0.logging.level = "info" }
                == Self.one("CV-54", "logging.level", "DEBUG / INFO / WARNING / ERROR のどれかであること（info）"))
    }

    @Test("CV-54 DEBUG は通る")
    func cv54Boundary() {
        #expect(Self.check { $0.logging.level = "DEBUG" }.isEmpty)
    }

    @Test("CV-55 transcription の数値と language の違反")
    func cv55Violation() {
        let cases: [((inout AppConfig) -> Void, String, String)] = [
            ({ $0.transcription.threads = -1 }, "transcription.threads", "0 以上であること（-1）"),
            ({ $0.transcription.timeoutFactor = 0 }, "transcription.timeoutFactor", "0 より大きいこと（0.0）"),
            ({ $0.transcription.minTimeoutSeconds = 0 }, "transcription.minTimeoutSeconds", "1 以上であること（0）"),
            (
                { $0.transcription.maxTimeoutSeconds = 599 }, "transcription.maxTimeoutSeconds",
                "minTimeoutSeconds 以上であること（599 < 600）"
            ),
            ({ $0.transcription.minChars = 0 }, "transcription.minChars", "1 以上であること（0）"),
            ({ $0.transcription.vad.threshold = 0 }, "transcription.vad.threshold", "0 より大きく 1 より小さいこと（0.0）"),
            ({ $0.transcription.vad.threshold = 1 }, "transcription.vad.threshold", "0 より大きく 1 より小さいこと（1.0）"),
            (
                { $0.transcription.vad.minSpeechDurationMs = -1 }, "transcription.vad.minSpeechDurationMs",
                "0 以上であること（-1）"
            ),
            (
                { $0.transcription.vad.minSilenceDurationMs = -1 }, "transcription.vad.minSilenceDurationMs",
                "0 以上であること（-1）"
            ),
            ({ $0.transcription.vad.speechPadMs = -1 }, "transcription.vad.speechPadMs", "0 以上であること（-1）"),
            ({ $0.transcription.language = "" }, "transcription.language", "空にできない"),
        ]
        for (mutate, keyPath, message) in cases {
            #expect(Self.check(.missing, mutate) == Self.one("CV-55", keyPath, message))
        }
    }

    @Test("CV-55 threads 0 と threshold 0.5 は通る")
    func cv55Boundary() {
        #expect(Self.check { $0.transcription.threads = 0 }.isEmpty)
        #expect(Self.check { $0.transcription.vad.threshold = 0.5 }.isEmpty)
    }

    @Test("CV-56 llm の数値と maxItems の違反")
    func cv56Violation() {
        let cases: [((inout AppConfig) -> Void, String, String)] = [
            ({ $0.llm.temperature = -0.1 }, "llm.temperature", "0〜2 であること（-0.1）"),
            ({ $0.llm.temperature = 2.1 }, "llm.temperature", "0〜2 であること（2.1）"),
            ({ $0.llm.topP = 0 }, "llm.topP", "0 より大きく 1 以下であること（0.0）"),
            ({ $0.llm.topP = 1.1 }, "llm.topP", "0 より大きく 1 以下であること（1.1）"),
            ({ $0.llm.maxOutputTokens = 0 }, "llm.maxOutputTokens", "1 以上であること（0）"),
            ({ $0.llm.requestTimeoutSeconds = 0 }, "llm.requestTimeoutSeconds", "1 以上であること（0）"),
            ({ $0.llm.maxSecondsPerRequest = 0 }, "llm.maxSecondsPerRequest", "1 以上であること（0）"),
            ({ $0.llm.chunkOverlapChars = -1 }, "llm.chunkOverlapChars", "0 以上であること（-1）"),
            ({ $0.llm.repairAttempts = -1 }, "llm.repairAttempts", "0 以上であること（-1）"),
            (
                { $0.llm.analysis.sections.keyPoints.maxItems = 0 }, "llm.analysis.sections.key_points.maxItems",
                "null か 1 以上であること（0）"
            ),
        ]
        for (mutate, keyPath, message) in cases {
            #expect(Self.check(.missing, mutate) == Self.one("CV-56", keyPath, message))
        }
    }

    @Test("CV-56 temperature 0 と 2、topP 1、maxItems nil は通る")
    func cv56Boundary() {
        #expect(Self.check { $0.llm.temperature = 0 }.isEmpty)
        #expect(Self.check { $0.llm.temperature = 2 }.isEmpty)
        #expect(Self.check { $0.llm.topP = 1 }.isEmpty)
        #expect(Self.check { $0.llm.analysis.sections.keyPoints.maxItems = nil }.isEmpty)
    }

    static var cv57Keys: [(String, WritableKeyPath<SessionConfig, Int>)] {
        [
            ("idleCloseSeconds", \.idleCloseSeconds), ("maxParts", \.maxParts),
            ("maxDurationSeconds", \.maxDurationSeconds),
        ]
    }

    @Test("CV-57 session の数値が 0 なら違反")
    func cv57Violation() {
        for (name, key) in Self.cv57Keys {
            #expect(
                Self.check { $0.session[keyPath: key] = 0 } == Self.one("CV-57", "session.\(name)", "1 以上であること（0）"))
        }
    }

    @Test("CV-57 1 は通る")
    func cv57Boundary() {
        for (_, key) in Self.cv57Keys {
            #expect(Self.check { $0.session[keyPath: key] = 1 }.isEmpty)
        }
    }

    @Test("CV-58 audio の数値が境界の外なら違反")
    func cv58Violation() {
        let cases: [((inout AppConfig) -> Void, String, String)] = [
            ({ $0.audio.timeoutFactor = 0 }, "audio.timeoutFactor", "0 より大きいこと（0.0）"),
            ({ $0.audio.minTimeoutSeconds = 0 }, "audio.minTimeoutSeconds", "1 以上であること（0）"),
            ({ $0.audio.durationToleranceSeconds = -0.1 }, "audio.durationToleranceSeconds", "0 以上であること（-0.1）"),
            ({ $0.audio.freeSpaceMultiplier = 0.9 }, "audio.freeSpaceMultiplier", "1 以上であること（0.9）"),
            ({ $0.audio.freeSpaceMarginBytes = -1 }, "audio.freeSpaceMarginBytes", "0 以上であること（-1）"),
            ({ $0.audio.hashChunkBytes = 4095 }, "audio.hashChunkBytes", "4096 以上であること（4095）"),
        ]
        for (mutate, keyPath, message) in cases {
            #expect(Self.check(.missing, mutate) == Self.one("CV-58", keyPath, message))
        }
    }

    @Test("CV-58 hashChunkBytes 4096 と freeSpaceMultiplier 1.0 は通る")
    func cv58Boundary() {
        #expect(Self.check { $0.audio.hashChunkBytes = 4096 }.isEmpty)
        #expect(Self.check { $0.audio.freeSpaceMultiplier = 1.0 }.isEmpty)
    }

    @Test("CV-59 obsidian の数値と空のタグの違反")
    func cv59Violation() {
        let cases: [((inout AppConfig) -> Void, String, String)] = [
            (
                { $0.obsidian.raw.timestampIntervalSeconds = -1 }, "obsidian.raw.timestampIntervalSeconds",
                "0 以上であること（-1）"
            ),
            (
                { $0.obsidian.wiki.vaultIndexCacheSeconds = -1 }, "obsidian.wiki.vaultIndexCacheSeconds",
                "0 以上であること（-1）"
            ),
            ({ $0.obsidian.wiki.maxLinks = -1 }, "obsidian.wiki.maxLinks", "0 以上であること（-1）"),
            ({ $0.obsidian.defaultTags = ["voice", ""] }, "obsidian.defaultTags.1", "空文字にできない"),
        ]
        for (mutate, keyPath, message) in cases {
            #expect(Self.check(.missing, mutate) == Self.one("CV-59", keyPath, message))
        }
    }

    @Test("CV-59 timestampInterval 0 と maxLinks 0 は通る")
    func cv59Boundary() {
        #expect(Self.check { $0.obsidian.raw.timestampIntervalSeconds = 0 }.isEmpty)
        #expect(Self.check { $0.obsidian.wiki.maxLinks = 0 }.isEmpty)
    }

    // MARK: - CV-60（F-92）

    /// 要る 2 つのプレースホルダを含む上書き
    static let validPrompt = "指示 {custom_instructions}\n\n{schema_block}"

    @Test("CV-60 {schema_block} が無い上書きは違反")
    func cv60MissingSchemaBlock() {
        #expect(
            Self.check { $0.llm.analysis.prompts.analyze = "指示 {custom_instructions}" }
                == Self.one("CV-60", "llm.analysis.prompts.analyze", "{schema_block} を含むこと"))
    }

    @Test("CV-60 {custom_instructions} が無い上書きは違反")
    func cv60MissingCustomInstructions() {
        #expect(
            Self.check { $0.llm.analysis.prompts.map = "指示\n{schema_block}" }
                == Self.one("CV-60", "llm.analysis.prompts.map", "{custom_instructions} を含むこと"))
    }

    @Test("CV-60 空文字の上書きは違反（TEST-28）")
    func cv60EmptyOverride() {
        #expect(
            Self.check { $0.llm.analysis.prompts.reduce = "" }
                == Self.one("CV-60", "llm.analysis.prompts.reduce", "{schema_block} を含むこと"))
    }

    @Test("CV-60 null（既定）と、2 つを含む上書きは通る")
    func cv60NullAndValidPass() {
        #expect(Self.check { $0.llm.analysis.prompts = PromptOverrides(analyze: nil, map: nil, reduce: nil) }.isEmpty)
        #expect(
            Self.check {
                $0.llm.analysis.prompts = PromptOverrides(
                    analyze: Self.validPrompt, map: Self.validPrompt, reduce: Self.validPrompt)
            }.isEmpty)
    }

    @Test("CV-60 1500 スカラーは通り 1501 は違反（Unicode スカラーで数える）")
    func cv60Length() {
        // validPrompt は 40 スカラー（指示・空白 3 + {custom_instructions} 21 + 改行 2 + {schema_block} 14）
        let at1500 = Self.validPrompt + String(repeating: "あ", count: 1460)
        let at1501 = at1500 + "e\u{301}"
        #expect(Self.check { $0.llm.analysis.prompts.analyze = at1500 }.isEmpty)
        #expect(
            Self.check { $0.llm.analysis.prompts.analyze = at1500 + "a" }
                == Self.one("CV-60", "llm.analysis.prompts.analyze", "1500 以下であること（1501）"))
        // 書記素では 1501 でもスカラーでは 1502
        #expect(
            Self.check { $0.llm.analysis.prompts.analyze = at1501 }
                == Self.one("CV-60", "llm.analysis.prompts.analyze", "1500 以下であること（1502）"))
    }

    @Test("CV-60 {schema_block} の直後に結合文字が続いてもスカラー列で見つける（F-83 と同じ照らし方）")
    func cv60ScalarMatch() {
        #expect(
            Self.check { $0.llm.analysis.prompts.analyze = "{custom_instructions}{schema_block}\u{301}" }.isEmpty)
    }

    @Test("CV-60 1 キーに 1 件（両方無ければ {schema_block} だけ）で、キーは analyze → map → reduce の順")
    func cv60OnePerKeyInOrder() {
        #expect(
            Self.check {
                $0.llm.analysis.prompts = PromptOverrides(analyze: "x", map: nil, reduce: "{schema_block}")
            }
                == [
                    ConfigViolation(
                        rule: "CV-60", code: .configInvalidValue, keyPath: "llm.analysis.prompts.analyze",
                        message: "{schema_block} を含むこと"),
                    ConfigViolation(
                        rule: "CV-60", code: .configInvalidValue, keyPath: "llm.analysis.prompts.reduce",
                        message: "{custom_instructions} を含むこと"),
                ])
    }

    // MARK: - 全体

    @Test("既定値は違反 0 件")
    func defaultsHaveNoViolations() {
        #expect(
            ConfigValidator.validate(
                AppConfig.defaults(timeZone: "Asia/Tokyo"), catalog: TestCatalogs.minimal,
                reaperConfObservation: .missing
            ).isEmpty)
    }

    @Test("違反は表の順に並ぶ（CV-14 は CV-13 より先）")
    func evaluationOrderFollowsTable() {
        let violations = Self.check {
            $0.session.blockGapSeconds = -1
            $0.obsidian.wiki.filenameTemplate = "{title}"
            $0.obsidian.raw.filenameTemplate = "{x}"
            $0.obsidian.wiki.maxLinks = -1
        }
        #expect(violations.map(\.rule) == ["CV-08", "CV-14", "CV-13", "CV-59"])
    }

    @Test("CV の表の全 ID にテストがある")
    func everyCVHasATest() throws {
        let specIDs = Set(try SpecDocument.load().ids(.cv))
        let regex = try NSRegularExpression(pattern: "@Test\\(\"(CV-[0-9]+) ")
        var tested: Set<String> = []
        for name in ["ConfigValidatorTests.swift", "ConfigLoaderTests.swift"] {
            let text = try String(contentsOf: PackageRoot.file("Tests/VDCoreTests/\(name)"), encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
                if let range = Range(match.range(at: 1), in: text) { tested.insert(String(text[range])) }
            }
        }
        #expect(!specIDs.isEmpty)
        #expect(specIDs.isSubset(of: tested), "テストの無い CV: \(specIDs.subtracting(tested).sorted())")
    }
}
