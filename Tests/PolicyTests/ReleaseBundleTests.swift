// 配布スクリプト・Info.plist・エンタイトルメント・バンドルの許可リストの静的検査（PLAN §11.1〜§11.3。T-34・T-46）。
import Foundation
import TestSupport
import Testing

@Suite("ReleaseBundle")
struct ReleaseBundleTests {
    static let scripts = [
        "scripts/make-app.sh", "scripts/sign.sh", "scripts/notarize.sh",
        "scripts/make-dmg.sh", "scripts/release.sh", "scripts/verify-bundle.sh",
    ]

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: PackageRoot.file(relativePath), encoding: .utf8)
    }

    /// `KEY=VALUE` の行を並べたファイル（`identity.env`・`Vendor/versions.env`）の値。
    static func keyValues(_ relativePath: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for line in try text(relativePath).split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        return values
    }

    /// `identity.env` の `KEY=VALUE`。
    static func identity() throws -> [String: String] {
        try keyValues("identity.env")
    }

    /// `Vendor/speaker-models.sha256` の注釈でも空でもない行。
    static func speakerModelHashLines() throws -> [String] {
        try text("Vendor/speaker-models.sha256")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }

    /// `Vendor/speaker-models.sha256` の各行の相対パス（区切りの空白 2 つの後ろ）。
    static func speakerModelPaths() throws -> [String] {
        try speakerModelHashLines().compactMap { line in
            line.range(of: "  ").map { String(line[$0.upperBound...]) }
        }
    }

    static let speakerModelsPrefix = "Contents/Resources/SpeakerModels/"

    /// 許可リストの SpeakerModels の行と、モデルの相対パス + `NOTICE.txt` の食い違い（両方向。辞書順）。空なら一致。
    static func speakerModelMismatches(manifest: [String], modelPaths: [String]) -> [String] {
        let expected = Set((modelPaths + ["NOTICE.txt"]).map { speakerModelsPrefix + $0 })
        let listed = Set(manifest.filter { $0.hasPrefix(speakerModelsPrefix) })
        return expected.symmetricDifference(listed).sorted()
    }

    /// `Resources/bundle-manifest.txt` の注釈でない行。
    static func manifest() throws -> [String] {
        try text("Resources/bundle-manifest.txt")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }

    /// macOS の `/bin/bash`（3.2）に無い書き方。
    static let bash4Features = ["mapfile", "readarray", "declare -A", "&>>", "|&"]

    /// Info.plist の必須キー（PLAN §11.1）。`NSDesktopFolderUsageDescription` は `usageDescriptionsAreVerbatim` が回数で見る。
    static let requiredInfoPlistKeys = [
        "CFBundleIdentifier", "CFBundleName", "CFBundleExecutable", "CFBundlePackageType",
        "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "LSUIElement",
        "NSRemovableVolumesUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription",
    ]

    static let entitlements = ["Resources/VoiceDock.entitlements", "Resources/reaper.entitlements"]

    /// PLAN §11.3 の 4 の検査項目を表す語。
    static let requiredChecks = [
        "bundle-manifest.txt", "codesign --verify --deep --strict", "spctl -a -t exec",
        "spctl -a -t open --context context:primary-signature", "stapler validate", "check-linkage.sh", ".reaper",
    ]

    /// 1 行目が `#!/bin/bash` で、本文に `set -euo pipefail` の行が在るか。
    static func isStrictBash(_ script: String) -> Bool {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first == "#!/bin/bash" else { return false }
        return lines.contains { $0.trimmingCharacters(in: .whitespaces) == "set -euo pipefail" }
    }

    /// `rm -rf` を含む行がすべて `dist/` か `"$stage"` を含むか。
    static func removesOnlyInsideDist(_ script: String) -> Bool {
        script.split(separator: "\n")
            .filter { $0.contains("rm -rf") }
            .allSatisfy { $0.contains("dist/") || $0.contains("\"$stage\"") }
    }

    /// `needle` が `haystack` に現れる回数（重ならない数え方）。
    static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// `<key>…</key>` の次の行（前後の空白を除く）。キーが無ければ nil。
    static func valueLine(after key: String, in plist: String) -> String? {
        let lines = plist.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = lines.firstIndex(of: "<key>\(key)</key>"), index + 1 < lines.count else { return nil }
        return lines[index + 1]
    }

    /// `words` が `text` にこの順で現れるか（各語は直前の語より後ろから探す）。
    /// `hdiutil attach` の行が 1 つ以上在り、すべて `-nobrowse` と `-mountpoint` を伴い、
    /// 本文に `/Volumes`・`-srcfolder`・`makehybrid` が無いか。
    static func mountsOnlyOutsideVolumes(_ script: String) -> Bool {
        let attachLines = script.split(separator: "\n").filter { $0.contains("hdiutil attach") }
        guard !attachLines.isEmpty else { return false }
        let everyAttachIsPrivate = attachLines.allSatisfy { $0.contains("-nobrowse") && $0.contains("-mountpoint") }
        let forbidden = ["/Volumes", "-srcfolder", "makehybrid"]
        return everyAttachIsPrivate && !forbidden.contains { script.contains($0) }
    }

    static func appearInOrder(_ words: [String], in text: String) -> Bool {
        var searchStart = text.startIndex
        for word in words {
            guard let range = text.range(of: word, range: searchStart..<text.endIndex) else { return false }
            searchStart = range.upperBound
        }
        return true
    }

    @Test("配布スクリプトが在り実行できる", arguments: scripts)
    func everyScriptIsExecutable(_ script: String) throws {
        let path = PackageRoot.file(script).path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: path))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions & 0o111 != 0)
    }

    @Test("配布スクリプトは bash の strict モード", arguments: scripts)
    func everyScriptIsStrictBash(_ script: String) throws {
        #expect(Self.isStrictBash(try Self.text(script)))
    }

    @Test("配布スクリプトはカレントに依存しない", arguments: scripts)
    func everyScriptResolvesTheRootFromItsOwnPath(_ script: String) throws {
        #expect(try Self.text(script).contains("BASH_SOURCE[0]"))
    }

    @Test("配布スクリプトに BUNDLE_ID と TEAM_ID を直書きしない", arguments: scripts)
    func scriptsDoNotHardcodeTheIdentifiers(_ script: String) throws {
        let identity = try Self.identity()
        let bundleID = try #require(identity["BUNDLE_ID"])
        let teamID = try #require(identity["TEAM_ID"])
        #expect(!bundleID.isEmpty && !teamID.isEmpty)
        let body = try Self.text(script)
        #expect(!body.contains(bundleID))
        #expect(!body.contains(teamID))
    }

    @Test(
        "識別子を使うスクリプトは identity.env を読む",
        arguments: ["scripts/make-app.sh", "scripts/sign.sh", "scripts/verify-bundle.sh"])
    func scriptsThatNeedTheIdentitySourceIt(_ script: String) throws {
        #expect(try Self.text(script).contains("source \"$root/identity.env\""))
    }

    @Test("配布スクリプトは /Volumes に触れない", arguments: scripts)
    func noScriptMentionsVolumes(_ script: String) throws {
        #expect(try !Self.text(script).contains("/Volumes"))
    }

    @Test("配布スクリプトの `rm -rf` は dist の下だけ", arguments: scripts)
    func noScriptWritesOutsideDist(_ script: String) throws {
        #expect(Self.removesOnlyInsideDist(try Self.text(script)))
    }

    @Test("macOS の bash 3.2 で動く書き方だけを使う", arguments: scripts, bash4Features)
    func noScriptUsesBash4Features(_ script: String, _ feature: String) throws {
        #expect(try !Self.text(script).contains(feature))
    }

    @Test("Info.plist の必須キーが在る", arguments: requiredInfoPlistKeys)
    func infoPlistTemplateHasEveryRequiredKey(_ key: String) throws {
        #expect(try Self.text("Resources/Info.plist.template").contains("<key>\(key)</key>"))
    }

    @Test("Info.plist の固定値（逐語）")
    func infoPlistTemplateHasTheFixedValues() throws {
        let plist = try Self.text("Resources/Info.plist.template")
        #expect(Self.valueLine(after: "CFBundleName", in: plist) == "<string>VoiceDock</string>")
        #expect(Self.valueLine(after: "CFBundleExecutable", in: plist) == "<string>VoiceDock</string>")
        #expect(Self.valueLine(after: "CFBundlePackageType", in: plist) == "<string>APPL</string>")
        #expect(Self.valueLine(after: "LSMinimumSystemVersion", in: plist) == "<string>15.0</string>")
        #expect(Self.valueLine(after: "LSUIElement", in: plist) == "<true/>")
    }

    @Test("Info.plist は 3 つの記号で置換する")
    func infoPlistTemplateUsesPlaceholders() throws {
        let plist = try Self.text("Resources/Info.plist.template")
        let bundleID = try #require(try Self.identity()["BUNDLE_ID"])
        #expect(!bundleID.isEmpty)
        #expect(Self.occurrences(of: "@BUNDLE_ID@", in: plist) == 1)
        #expect(Self.occurrences(of: "@VERSION@", in: plist) == 1)
        #expect(Self.occurrences(of: "@BUILD@", in: plist) == 1)
        #expect(!plist.contains(bundleID))
    }

    @Test("TCC の説明文が PLAN の逐語")
    func usageDescriptionsAreVerbatim() throws {
        let plist = try Self.text("Resources/Info.plist.template")
        #expect(Self.occurrences(of: "録音デバイスから音声を読み込むために使います", in: plist) == 1)
        #expect(Self.occurrences(of: "Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います", in: plist) == 3)
    }

    @Test("エンタイトルメントは空で例外が無い", arguments: entitlements)
    func entitlementsAreEmpty(_ file: String) throws {
        let body = try Self.text(file)
        #expect(body.contains("<dict/>"))
        #expect(!body.contains("com.apple.security"))
    }

    @Test("許可リストは辞書順で重複が無い")
    func manifestIsSortedAndUnique() throws {
        let entries = try Self.manifest()
        #expect(!entries.isEmpty)
        let ascending = zip(entries, entries.dropFirst()).allSatisfy { previous, next in
            previous.unicodeScalars.lexicographicallyPrecedes(next.unicodeScalars)
        }
        #expect(ascending)
        #expect(Set(entries).count == entries.count)
    }

    @Test("許可リストの各行は Contents/ 配下の相対パス", arguments: try manifest())
    func manifestEntriesAreUnderContents(_ entry: String) {
        #expect(entry.hasPrefix("Contents/"))
        #expect(!entry.contains(".."))
        #expect(!entry.hasPrefix("/"))
    }

    @Test("許可リストにヘルパー 4 本が在る")
    func manifestListsTheFourHelpers() throws {
        let entries = try Self.manifest()
        #expect(entries.contains("Contents/Helpers/whisper-cli"))
        #expect(entries.contains("Contents/Helpers/llama-server"))
        #expect(entries.contains("Contents/Helpers/voicedock-reaper"))
        #expect(entries.contains("Contents/Helpers/argmax-cli"))
        #expect(entries.filter { $0.hasPrefix("Contents/Helpers/") }.count == 4)
    }

    @Test("許可リストの SpeakerModels が speaker-models.sha256 と NOTICE に一致")
    func manifestListsEverySpeakerModelFile() throws {
        let paths = try Self.speakerModelPaths()
        #expect(paths.count == 20)
        let entries = try Self.manifest()
        #expect(Self.speakerModelMismatches(manifest: entries, modelPaths: paths).isEmpty)
        #expect(entries.filter { $0.hasPrefix("Contents/Resources/SpeakerModels/") }.count == 21)
        #expect(entries.contains("Contents/Resources/SpeakerModels/NOTICE.txt"))
    }

    @Test("speaker-models.sha256 は 20 行で、各行が 64 桁の小文字 16 進と相対パス")
    func speakerModelHashesAreWellFormed() throws {
        let lines = try Self.speakerModelHashLines()
        #expect(lines.count == 20)
        let pattern = try NSRegularExpression(pattern: "^[0-9a-f]{64}  [^/][^ ]*$")
        for line in lines {
            #expect(Self.wholeMatch(pattern, line), "形が違う: \(line)")
            #expect(!line.contains(".."), "`..` を含む: \(line)")
        }
    }

    @Test("versions.env の SPEAKER_MODELS_SHA と ARGMAX_OSS_SHA は 40 桁")
    func speakerModelsArePinnedToACommit() throws {
        let versions = try Self.keyValues("Vendor/versions.env")
        let pattern = try NSRegularExpression(pattern: "^[0-9a-f]{40}$")
        for key in ["SPEAKER_MODELS_SHA", "ARGMAX_OSS_SHA"] {
            let value = try #require(versions[key], "\(key) が無い")
            #expect(Self.wholeMatch(pattern, value), "\(key) が 40 桁のコミットでない: \(value)")
        }
    }

    /// 文字列全体が正規表現に一致する（PLAN §4.1: 正規表現は NSRegularExpression で持つ）。
    static func wholeMatch(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        let whole = NSRange(location: 0, length: text.utf16.count)
        return pattern.firstMatch(in: text, range: whole)?.range == whole
    }

    @Test(
        "argmax-cli の --help の fixture に 4 つのフラグが在る",
        arguments: ["--audio-path", "--model-path", "--rttm-path", "--use-exclusive-reconciliation"])
    func argmaxHelpFixtureHasTheFlags(_ flag: String) throws {
        let help = try Self.text("Tests/Fixtures/argmax-cli-diarize-help.txt")
        #expect(try VendorFixtureTests.contains(help, flag: flag))
    }

    @Test("SpeakerModels の行が 0 のとき検査が落ちる（TEST-28）")
    func emptyManifestSectionIsRejected() throws {
        let paths = try Self.speakerModelPaths()
        #expect(!Self.speakerModelMismatches(manifest: [], modelPaths: paths).isEmpty)
        // モデルの一覧まで空でも、NOTICE.txt が足りないことを報告する
        let onlyNotice = Self.speakerModelMismatches(manifest: [], modelPaths: [])
        #expect(onlyNotice == ["Contents/Resources/SpeakerModels/NOTICE.txt"])
    }

    @Test("許可リストのプロンプトが Resources/prompts と一致")
    func manifestListsEveryPromptFile() throws {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: PackageRoot.file("Resources/prompts").path(percentEncoded: false)
        )
        .filter { $0.hasSuffix(".txt") }
        #expect(!names.isEmpty)
        let expected = Set(names.map { "Contents/Resources/prompts/\($0)" })
        let listed = Set(try Self.manifest().filter { $0.hasPrefix("Contents/Resources/prompts/") })
        #expect(listed == expected)
    }

    @Test("許可リストに `_CodeSignature/CodeResources` が在る")
    func manifestListsTheCodeSignature() throws {
        #expect(try Self.manifest().contains("Contents/_CodeSignature/CodeResources"))
    }

    @Test(
        "組み立てが許可リストの各ファイルを作る",
        arguments: try manifest().filter {
            $0 != "Contents/Info.plist" && $0 != "Contents/_CodeSignature/CodeResources"
        })
    func makeAppInstallsEveryManifestEntry(_ entry: String) throws {
        let makeApp = try Self.text("scripts/make-app.sh")
        #expect(!entry.isEmpty)
        let installedDirectly = makeApp.contains("\"$app/\(entry)\"")
        let installedByPromptLoop =
            entry.hasPrefix("Contents/Resources/prompts/") && makeApp.contains("Resources/prompts/*.txt")
            && makeApp.contains("\"$app/Contents/Resources/prompts/")
        let installedBySpeakerModelsCopy =
            entry.hasPrefix("Contents/Resources/SpeakerModels/")
            && makeApp.contains("ditto \"$root/Vendor/build/SpeakerModels\" \"$app/Contents/Resources/SpeakerModels\"")
        #expect(installedDirectly || installedByPromptLoop || installedBySpeakerModelsCopy)
    }

    @Test("verify-bundle が PLAN §11.3 の 4 の全項目を行う", arguments: requiredChecks)
    func verifyBundleRunsEveryRequiredCheck(_ check: String) throws {
        #expect(try Self.text("scripts/verify-bundle.sh").contains(check))
    }

    @Test("staple の後の検査だけが、stapler の足す Contents/CodeResources を許す")
    func verifyBundleAllowsTheStapledTicketOnlyAfterStapling() throws {
        let script = try Self.text("scripts/verify-bundle.sh")
        let guardLine = "if [ \"$files_only\" -eq 0 ]; then\n"
        let addLine = "  expected=\"$(printf '%s\\nContents/CodeResources\\n' \"$expected\""
        #expect(script.contains(guardLine + addLine))
        // 許可リスト自体には入れない（`--files-only` は staple の前に走るので、入れると足りなくて落ちる）
        #expect(!(try Self.manifest().contains("Contents/CodeResources")))
    }

    @Test("`--files-only` が在り、make-app が使う")
    func verifyBundleSupportsFilesOnly() throws {
        #expect(try Self.text("scripts/verify-bundle.sh").contains("--files-only"))
        #expect(try Self.text("scripts/make-app.sh").contains("verify-bundle.sh\" --files-only"))
    }

    @Test("reaper だけ `--identifier <BUNDLE_ID>.reaper` で署名する")
    func signUsesTheReaperIdentifier() throws {
        let sign = try Self.text("scripts/sign.sh")
        #expect(sign.contains("--identifier \"$BUNDLE_ID.reaper\""))
        #expect(sign.contains("--entitlements \"$root/Resources/reaper.entitlements\""))
    }

    @Test("DR-17 ad-hoc 署名をしない")
    func signNeverUsesAdhoc() throws {
        let sign = try Self.text("scripts/sign.sh")
        #expect(!sign.contains("--sign -"))
        #expect(sign.contains("--options runtime"))
    }

    @Test("dmg の作業用イメージは /Volumes の外にだけマウントする")
    func makeDmgMountsOnlyOutsideVolumes() throws {
        let makeDmg = try Self.text("scripts/make-dmg.sh")
        #expect(Self.mountsOnlyOutsideVolumes(makeDmg))
        #expect(makeDmg.contains("hdiutil convert"))
    }

    @Test("F-99 dmg のボリューム名に版を付け（実機の VOICEDOCK とマウント先をぶつけない）、ウィンドウの背景と表示設定を入れる")
    func makeDmgLaysOutTheWindow() throws {
        let makeDmg = try Self.text("scripts/make-dmg.sh")
        for word in [
            #"volname="VoiceDock $version""#, #"-volname "$volname""#, "tiffutil -cathidpicheck", "write-ds-store.py",
            #"ln -s /Applications "$mnt/Applications""#, "tools/dmg/requirements.txt",
        ] {
            #expect(makeDmg.contains(word), "\(word) が無い")
        }
        #expect(!makeDmg.contains("-volname VoiceDock "))
        // 背景は 1 倍と 2 倍の両方がある
        for name in ["background.png", "background@2x.png"] {
            let path = PackageRoot.file("Resources/dmg/" + name).path(percentEncoded: false)
            #expect(FileManager.default.fileExists(atPath: path), "\(name) が無い")
        }
        // 部品の版は固定する
        let requirements = try Self.text("tools/dmg/requirements.txt")
        #expect(requirements.contains("ds_store==") && requirements.contains("mac_alias=="))
    }

    @Test("公証はプロファイルを使い `--wait` する")
    func notarizeWaitsAndUsesTheProfile() throws {
        let notarize = try Self.text("scripts/notarize.sh")
        for word in ["VOICEDOCK_NOTARY", "--keychain-profile", "--wait", "stapler staple", "ditto -c -k --keepParent"] {
            #expect(notarize.contains(word), "\(word) が無い")
        }
    }

    @Test("release.sh の段の順（PLAN §11.3）")
    func releaseRunsTheStepsInOrder() throws {
        let release = try Self.text("scripts/release.sh")
        let steps = [
            "make-app.sh", "notarize.sh", "make-dmg.sh", "sign.sh\" developerid", "notarize.sh", "verify-bundle.sh",
        ]
        #expect(Self.appearInOrder(steps, in: release))
    }

    @Test("Makefile の app / release がこのスクリプトを呼ぶ")
    func makefileUsesTheseScripts() throws {
        let makefile = try Self.text("Makefile")
        #expect(makefile.contains("scripts/make-app.sh debug"))
        #expect(makefile.contains("scripts/release.sh"))
    }

    @Test("`dist/` はコミットしない")
    func distIsIgnored() throws {
        let lines = try Self.text(".gitignore").split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        #expect(lines.contains("dist/"))
    }

    @Test("陽性対照: 検査自体が効く")
    func theChecksWouldCatchABrokenScript() {
        #expect(!Self.isStrictBash(""))
        #expect(!Self.isStrictBash("#!/bin/sh\n"))
        #expect(!Self.isStrictBash("#!/bin/bash\nset -e\n"))
        #expect(Self.isStrictBash("#!/bin/bash\nset -euo pipefail"))
        #expect(!Self.removesOnlyInsideDist("rm -rf \"$root\"/*\n"))
        #expect(Self.removesOnlyInsideDist("rm -rf \"$root/dist/VoiceDock.app\"\n"))
        let swapped = "sign.sh\" developerid\nmake-dmg.sh\n"
        #expect(!Self.appearInOrder(["make-dmg.sh", "sign.sh\" developerid"], in: swapped))
        #expect(Self.appearInOrder(["notarize.sh", "notarize.sh"], in: "notarize.sh a\nnotarize.sh b\n"))
        #expect(!Self.appearInOrder(["notarize.sh", "notarize.sh"], in: "notarize.sh a\n"))
        #expect(!Self.mountsOnlyOutsideVolumes(""))
        #expect(!Self.mountsOnlyOutsideVolumes("hdiutil attach -nobrowse \"$rw\"\n"))
        #expect(!Self.mountsOnlyOutsideVolumes("hdiutil attach -nobrowse -mountpoint \"/Volumes/X\" \"$rw\"\n"))
        #expect(!Self.mountsOnlyOutsideVolumes("hdiutil create -srcfolder \"$stage\" \"$dmg\"\n"))
        #expect(Self.mountsOnlyOutsideVolumes("hdiutil attach -nobrowse -mountpoint \"$mnt\" \"$rw\"\n"))
    }
}
