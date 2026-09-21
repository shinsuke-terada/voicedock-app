// PT-01〜PT-22 の定義（PLAN §9.4 の表の写し。T-04）。PT-07・PT-13・PT-16 は別のファイルの専用の検査。
import Foundation

enum PolicyCatalog {
    /// PT-01 の削除の呼び出し（PT-17 も使う）。
    static let deletionPatterns: [TokenPattern] = [
        .word("removeItem"), .word("trashItem"), .call("unlink"), .call("unlinkat"), .call("rmdir"),
        .call("remove"), .call("removefile"),
    ]

    /// PT-12 の書き込みの呼び出し（PT-17 も使う）。
    static let writePatterns: [TokenPattern] = [
        .sequence(".write(to:", ". write ( to :"),
        .sequence("write(toFile:", "write ( toFile :"),
        .sequence("createFile(", "createFile ("),
        .sequence("FileHandle(forWritingTo:", "FileHandle ( forWritingTo"),
        TokenPattern(
            display: "FileHandle(forUpdating",
            elements: [.identifier("FileHandle"), .punctuation("("), .identifierPrefix("forUpdating")],
            adjacent: false, freeCall: false),
        .sequence("copyItem(", "copyItem ("),
        .sequence("moveItem(", "moveItem ("),
        .prefix("replaceItem"),
        .call("rename"),
        .call("renameat"),
        .word("O_CREAT"),
    ]

    /// VDContract 以外の VD モジュール（PT-15 が reaper の import を検査する）。
    static let nonContractModules = [
        "VDCore", "VDStore", "VDProcess", "VDAudio", "VDDevice", "VDTranscribe", "VDLLM", "VDNotes", "VDModels",
        "VDPipeline",
    ]

    /// トークンと文字列で検査する規則（PT-07・PT-13・PT-16 を除く）。
    static func tokenRules(vocabulary: PolicyVocabulary) -> [PolicyRule] {
        [
            PolicyRule(
                id: "PT-01",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDCore/SafeUnlink.swift", "VDContract/AtomicFile.swift", "voicedock-reaper/Unlinker.swift",
                            "VDPipeline/DeletionEnabler.swift",
                        ]),
                        code: deletionPatterns)
                ]),
            PolicyRule(
                id: "PT-02",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDModels/", "VDLLM/LoopbackHTTP.swift"]),
                        code: [
                            .prefix("URLSession"), .sequence("import Network", "import Network"), .prefix("CFNetwork"),
                            .word("NWConnection"), .prefix("CFSocket"),
                        ]),
                    PolicyClause(allowed: PathSet(entries: ["VDLLM/LoopbackHTTP.swift"]), code: [.call("socket")]),
                    PolicyClause(
                        scope: PathSet(entries: ["VDLLM/LoopbackHTTP.swift"]), allowed: .none,
                        code: [.sequence("URL(string:", "URL ( string :")]),
                ]),
            PolicyRule(
                id: "PT-03",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDProcess/"]),
                        code: [
                            .prefix("posix_spawn"), .sequence("Process(", "Process ("), .word("NSTask"), .call("fork"),
                            .call("vfork"), .call("execv"), .call("execve"), .call("execvp"), .call("execvP"),
                            .call("execl"), .call("execle"), .call("execlp"),
                        ])
                ]),
            PolicyRule(
                id: "PT-04",
                clauses: [
                    PolicyClause(
                        allowed: .none, code: [.call("system"), .call("popen")],
                        literals: [
                            .contains("/bin/sh"), .contains("/bin/bash"), .contains("/bin/zsh"),
                            .contains("/usr/bin/env"),
                        ])
                ]),
            PolicyRule(
                id: "PT-05",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDStore/Transitions.swift"]),
                        literals: [
                            .regex(
                                "UPDATE … SET … status",
                                "(?=[\\s\\S]*\\bUPDATE\\b)(?=[\\s\\S]*\\bSET\\b)(?=[\\s\\S]*\\bstatus\\b)",
                                caseInsensitive: true),
                            .regex(
                                "INSERT INTO recordings", "\\bINSERT\\s+INTO\\s+recordings\\b", caseInsensitive: true),
                            .regex("INSERT INTO sessions", "\\bINSERT\\s+INTO\\s+sessions\\b", caseInsensitive: true),
                        ]),
                    PolicyClause(
                        allowed: .none, code: [.word("PersistableRecord"), .word("MutablePersistableRecord")]),
                ]),
            PolicyRule(
                id: "PT-06",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDCore/States.swift"]),
                        literals: [.words("状態名", vocabulary.stateNames)]),
                    PolicyClause(
                        allowed: PathSet(entries: ["VDCore/ErrorCode.swift", "VDContract/DeleteResult.swift"]),
                        literals: [.words("エラーコード名", vocabulary.errorCodeNames)]),
                    PolicyClause(
                        allowed: PathSet(entries: ["VDContract/PartKey.swift", "VDContract/RelPath.swift"]),
                        literals: [.regex("\\(…)/\\(…)", "\\\\\\([^)]*\\)/\\\\\\(")]),
                ]),
            PolicyRule(
                id: "PT-08",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDCore/Log.swift", "voicedock-reaper/ReaperLog.swift", "voicedock-reaper/main.swift",
                        ]),
                        code: [
                            .sequence("Logger(", "Logger ("), .call("os_log"), .call("NSLog"), .call("print"),
                            .call("debugPrint"), .call("dump"),
                        ])
                ]),
            PolicyRule(
                id: "PT-09",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDCore/Clock.swift", "voicedock-reaper/ReaperClock.swift"]),
                        code: [
                            .sequence("Date()", "Date ( )"), .sequence("Date.now", "Date . now"),
                            .sequence("Date(timeIntervalSinceNow:", "Date ( timeIntervalSinceNow"),
                            .call("CFAbsoluteTimeGetCurrent"), .sequence("DispatchTime.now(", "DispatchTime . now ("),
                            .sequence("ContinuousClock()", "ContinuousClock ( )"),
                            .sequence("ContinuousClock.now", "ContinuousClock . now"),
                            .sequence("SuspendingClock()", "SuspendingClock ( )"),
                            .sequence("SuspendingClock.now", "SuspendingClock . now"),
                            .call("gettimeofday"), .call("clock_gettime"), .sequence("time(nil)", "time ( nil )"),
                        ])
                ]),
            PolicyRule(
                id: "PT-10",
                clauses: [
                    PolicyClause(
                        scope: PathSet(entries: ["VDDevice/"]),
                        allowed: PathSet(entries: ["VDDevice/DeviceReader.swift", "VDDevice/InboxWriter.swift"]),
                        code: [
                            .call("open"), .call("openat"), .call("opendir"), .call("fopen"),
                            .sequence("FileHandle(", "FileHandle ("),
                            .sequence("Data(contentsOf:", "Data ( contentsOf :"),
                            .sequence("InputStream(", "InputStream ("),
                        ]),
                    PolicyClause(
                        scope: PathSet(entries: ["VDDevice/DeviceReader.swift", "VDContract/TargetIdentity.swift"]),
                        allowed: .none,
                        code: [
                            .word("O_WRONLY"), .word("O_RDWR"), .word("O_CREAT"), .word("O_TRUNC"), .word("O_APPEND"),
                            .prefix("forWriting"), .prefix("forUpdating"),
                        ]),
                ]),
            PolicyRule(
                id: "PT-11",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDCore/AppPaths.swift", "VDPipeline/DeletionEnabler.swift"]),
                        code: [.word("bundledReaperURL")]),
                    PolicyClause(
                        allowed: PathSet(entries: ["VDContract/HomeLayout.swift", "VDPipeline/DeletionEnabler.swift"]),
                        code: [.word("binDirectory")]),
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDContract/HomeLayout.swift", "VDPipeline/DeletionEnabler.swift",
                            "VDPipeline/ReaperRunner.swift",
                            "VDPipeline/LockEvaluator.swift", "voicedock-reaper/",
                        ]),
                        code: [.word("reaperExecutable"), .word("reaperConf")]),
                ]),
            PolicyRule(
                id: "PT-12",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDContract/AtomicFile.swift", "VDContract/FileLock.swift", "VDCore/LogFile.swift",
                            "VDDevice/InboxWriter.swift", "VDModels/ModelDownloader.swift",
                            "VDModels/ModelImporter.swift",
                            "VDAudio/Normalizer.swift", "voicedock-reaper/ProcessedLog.swift",
                            "voicedock-reaper/ReaperLog.swift", "voicedock-reaper/QueueFiles.swift",
                            "VDPipeline/DeletionEnabler.swift",
                        ]),
                        code: writePatterns)
                ]),
            PolicyRule(
                id: "PT-14",
                clauses: [
                    PolicyClause(
                        allowed: .none,
                        code: [
                            .sequence("@unchecked", "@ unchecked", adjacent: true),
                            .sequence("nonisolated(unsafe)", "nonisolated ( unsafe )"),
                        ])
                ]),
            PolicyRule(
                id: "PT-15",
                clauses: [
                    PolicyClause(
                        scope: PathSet(entries: ["voicedock-reaper/"]), allowed: .none,
                        code: [.word("Process"), .prefix("posix_spawn"), .prefix("URLSession"), .word("removeItem")]
                            + nonContractModules.map { .sequence("import \($0)", "import \($0)") },
                        literals: [.contains("diskutil")])
                ]),
            PolicyRule(
                id: "PT-17",
                clauses: [
                    PolicyClause(
                        scope: PathSet(entries: ["VDPipeline/Diagnostics/"]), allowed: .none,
                        code: deletionPatterns + writePatterns + [
                            .word("AtomicFile"), .sequence("Store(", "Store ("),
                            .sequence("Store.init", "Store . init"),
                        ])
                ]),
            PolicyRule(
                id: "PT-18",
                clauses: [
                    PolicyClause(
                        allowed: .none,
                        code: [
                            .sequence(
                                "ProcessInfo.processInfo.environment", "ProcessInfo . processInfo . environment"),
                            .call("getenv"), .call("setenv"),
                        ])
                ]),
            PolicyRule(
                id: "PT-19",
                clauses: [
                    PolicyClause(
                        allowed: .none,
                        code: [
                            .call("precondition"), .call("preconditionFailure"), .call("assert"),
                            .call("assertionFailure"), .call("fatalError"), .sequence("try!", "try !", adjacent: true),
                            .sequence("as!", "as !", adjacent: true),
                        ])
                ]),
            PolicyRule(
                id: "PT-20",
                clauses: [
                    PolicyClause(
                        allowed: .none,
                        code: [
                            .sequence("Regex<", "Regex <"), .sequence("Regex(", "Regex ("),
                            .sequence("#/", "# /", adjacent: true),
                        ])
                ]),
            PolicyRule(
                id: "PT-21",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: [
                            "VDCore/States.swift", "VDStore/Transitions.swift", "VDPipeline/Recovery.swift",
                        ]),
                        code: [.sequence(".recovery", ". recovery")])
                ]),
            PolicyRule(
                id: "PT-22",
                clauses: [
                    PolicyClause(
                        allowed: PathSet(entries: ["VDContract/TargetIdentity.swift"]),
                        code: [.sequence("VolumeHandle(", "VolumeHandle (")])
                ]),
        ]
    }

    /// PLAN §9.4 の表の全 ID（専用の検査を含む）。
    static func allIDs(vocabulary: PolicyVocabulary) -> [String] {
        (tokenRules(vocabulary: vocabulary).map(\.id) + [ImportPolicy.id, PinningPolicy.id, OrderingPolicy.id]).sorted()
    }
}
