// 本体のライセンスと、同梱物の著作権表示の検査（F-93）。
// 同梱物の版を上げたのに THIRD_PARTY_NOTICES.md が古いまま、を落とす。
import Foundation
import TestSupport
import Testing

@Suite("LicenseFiles")
struct LicenseFilesTests {
    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: PackageRoot.file(relativePath), encoding: .utf8)
    }

    /// `required` のうち `text` に現れないもの（並びは `required` のまま）。
    static func missingMentions(in text: String, required: [String]) -> [String] {
        required.filter { !text.contains($0) }
    }

    /// `Vendor/versions.env` の版とコミット（先頭 7 桁）。THIRD_PARTY_NOTICES.md の表に載っていなければならない。
    static func vendorMentions() throws -> [String] {
        let values = try ReleaseBundleTests.keyValues("Vendor/versions.env")
        var mentions: [String] = []
        for key in ["WHISPER_CPP", "LLAMA_CPP", "ARGMAX_OSS"] {
            mentions.append(try #require(values[key + "_REF"]))
            mentions.append(String(try #require(values[key + "_SHA"]).prefix(7)))
        }
        mentions.append(String(try #require(values["SPEAKER_MODELS_SHA"]).prefix(7)))
        return mentions
    }

    /// `Package.resolved` の GRDB と Yams の版。
    static func packageVersions() throws -> [String] {
        let data = try Data(contentsOf: PackageRoot.file("Package.resolved"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try #require(root["pins"] as? [[String: Any]])
        return try ["grdb.swift", "yams"].map { identity in
            let pin = try #require(pins.first { ($0["identity"] as? String) == identity })
            let state = try #require(pin["state"] as? [String: Any])
            return try #require(state["version"] as? String)
        }
    }

    static let bundledDocuments = ["LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"]

    @Test("空の必須語からは何も欠けない")
    func nothingIsMissingFromAnEmptyList() {
        #expect(Self.missingMentions(in: "", required: []).isEmpty)
    }

    @Test("陽性対照: 無い語を欠けとして返す")
    func aMissingWordIsReported() {
        #expect(Self.missingMentions(in: "whisper.cpp v1.9.4", required: ["v1.9.4", "b11033"]) == ["b11033"])
    }

    @Test("LICENSE が Apache License 2.0 の全文")
    func theLicenseIsApache2() throws {
        let license = try Self.text("LICENSE")
        #expect(license.contains("Apache License"))
        #expect(license.contains("Version 2.0, January 2004"))
        #expect(license.contains("END OF TERMS AND CONDITIONS"))
    }

    @Test("NOTICE が著作権者と THIRD_PARTY_NOTICES.md を示す")
    func theNoticeNamesTheHolderAndTheThirdPartyFile() throws {
        let notice = try Self.text("NOTICE")
        #expect(notice.contains("Copyright 2026 Shinsuke Terada"))
        #expect(notice.contains("THIRD_PARTY_NOTICES.md"))
    }

    @Test("THIRD_PARTY_NOTICES.md が versions.env の版とコミットを載せている")
    func theNoticesCarryTheVendorVersions() throws {
        let notices = try Self.text("THIRD_PARTY_NOTICES.md")
        #expect(Self.missingMentions(in: notices, required: try Self.vendorMentions()).isEmpty)
    }

    @Test("THIRD_PARTY_NOTICES.md が GRDB と Yams の版を載せている")
    func theNoticesCarryThePackageVersions() throws {
        let notices = try Self.text("THIRD_PARTY_NOTICES.md")
        #expect(Self.missingMentions(in: notices, required: try Self.packageVersions()).isEmpty)
    }

    @Test("THIRD_PARTY_NOTICES.md が同梱物ごとのライセンス文を載せている")
    func theNoticesCarryEveryLicenseText() throws {
        let notices = try Self.text("THIRD_PARTY_NOTICES.md")
        let required = [
            "Copyright (c) 2023-2026 The ggml authors",  // whisper.cpp・llama.cpp
            "Copyright (c) 2024 argmax, inc.",  // argmax-oss-swift
            "Copyright 2024 Mozilla Foundation",  // llamafile の sgemm（llama-server）
            "Jeffrey Quesnelle and Bowen Peng",  // YaRN の RoPE（ggml）
            "Gwendal Roué",  // GRDB.swift
            "Copyright (c) 2016 JP Simard.",  // Yams
            "Kirill Simonov",  // LibYAML
            "Yann Collet",  // xxHash
            "Runtime Library Exception",  // swift-argument-parser
            "Creative Commons Attribution 4.0 International",  // 話者分離のモデル
        ]
        #expect(Self.missingMentions(in: notices, required: required).isEmpty)
    }

    @Test("make-app.sh が 3 つの文書を Resources に入れる", arguments: bundledDocuments)
    func theAppBundlesTheDocument(_ name: String) throws {
        let script = try Self.text("scripts/make-app.sh")
        let manifest = try ReleaseBundleTests.manifest()
        #expect(script.contains("install -m 0644 \"$root/\(name)\" \"$app/Contents/Resources/\(name)\""))
        #expect(manifest.contains("Contents/Resources/" + name))
        #expect(FileManager.default.fileExists(atPath: PackageRoot.file(name).path))
    }
}
