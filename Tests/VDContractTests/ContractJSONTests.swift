// ContractJSON の検査（T-06 §5.10）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("ContractJSON")
struct ContractJSONTests {
    static let partkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    static let relpath = "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    /// PLAN §4.4 の例。
    static func fixture(mtime: Double = 1_787_000_000.0) -> DeleteRequest {
        DeleteRequest(
            requestID: "20260912T090000Z-a5d046dce76cfedc-a1b2c3", createdAt: "2026-09-12T18:00:00+09:00",
            deviceID: "DJIMIC3", partkey: partkey, sessionKey: "DJIMIC3:20260829",
            target: DeleteTarget(relpath: relpath, size: 345_600_000, mtime: mtime))
    }

    /// fixture を手書きした JSON。fields の値は JSON の断片（そのまま埋め込む）。
    static func requestJSON(
        replacing: [String: String] = [:], removing: String? = nil, adding: (String, String)? = nil
    ) -> Data {
        let target = #"{"relpath": "\#(relpath)", "size": 345600000, "mtime": 1787000000.0}"#
        var fields: [(String, String)] = [
            ("schema", "1"),
            ("request_id", #""20260912T090000Z-a5d046dce76cfedc-a1b2c3""#),
            ("created_at", #""2026-09-12T18:00:00+09:00""#),
            ("device_id", #""DJIMIC3""#),
            ("partkey", "\"\(partkey)\""),
            ("session_key", #""DJIMIC3:20260829""#),
            ("targets", "[\(target)]"),
        ]
        fields = fields.map { ($0.0, replacing[$0.0] ?? $0.1) }
        if let removing { fields.removeAll { $0.0 == removing } }
        if let adding { fields.append(adding) }
        let body = fields.map { "\"\($0.0)\": \($0.1)" }.joined(separator: ", ")
        return Data("{\(body)}".utf8)
    }

    static func target(_ size: String = "345600000", _ mtime: String = "1787000000.0", extra: String = "") -> String {
        #"[{"relpath": "\#(relpath)", "size": \#(size), "mtime": \#(mtime)\#(extra)}]"#
    }

    @Test("要求の符号化がバイト単位で決まる")
    func encodesRequestExactly() throws {
        let expected = """
            {
              "created_at" : "2026-09-12T18:00:00+09:00",
              "device_id" : "DJIMIC3",
              "partkey" : "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
              "request_id" : "20260912T090000Z-a5d046dce76cfedc-a1b2c3",
              "schema" : 1,
              "session_key" : "DJIMIC3:20260829",
              "targets" : [
                {
                  "mtime" : 1787000000,
                  "relpath" : "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
                  "size" : 345600000
                }
              ]
            }

            """
        #expect(try ContractJSON.encode(Self.fixture()) == Data(expected.utf8))
    }

    @Test("小数の mtime")
    func encodesFractionalMtime() throws {
        let data = try ContractJSON.encode(Self.fixture(mtime: 1_787_000_000.25))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(#""mtime" : 1787000000.25"#))
    }

    @Test("非有限の mtime は符号化しない")
    func rejectsNonFiniteMtime() {
        #expect(throws: ContractEncodeError.nonFiniteNumber) { try ContractJSON.encode(Self.fixture(mtime: .nan)) }
    }

    @Test("要求が往復する")
    func roundTripsRequest() throws {
        let data = try ContractJSON.encode(Self.fixture())
        #expect(ContractJSON.decodeRequest(data) == .success(Self.fixture()))
    }

    @Test("mtime は整数・小数の両方を受ける")
    func acceptsIntegerAndFractionalMtime() {
        let integer = Self.requestJSON(replacing: ["targets": Self.target("345600000", "1787000000")])
        #expect(ContractJSON.decodeRequest(integer) == .success(Self.fixture(mtime: 1_787_000_000)))
        let fractional = Self.requestJSON(replacing: ["targets": Self.target("345600000", "1787000000.5")])
        #expect(ContractJSON.decodeRequest(fractional) == .success(Self.fixture(mtime: 1_787_000_000.5)))
    }

    struct MalformedCase: Sendable, CustomTestStringConvertible {
        let label: String
        let data: Data
        let expected: ContractDecodeError
        var testDescription: String { label }
    }

    static let malformedRequests: [MalformedCase] = [
        MalformedCase(label: "バイト列 0xFF 0xFE", data: Data([0xFF, 0xFE]), expected: .notJSONObject),
        MalformedCase(label: "[]（配列）", data: Data("[]".utf8), expected: .notJSONObject),
        MalformedCase(label: "空のバイト列", data: Data(), expected: .notJSONObject),
        MalformedCase(
            label: "キー extra を足す", data: requestJSON(adding: ("extra", "1")), expected: .keySetMismatch),
        MalformedCase(
            label: "session_key を消す", data: requestJSON(removing: "session_key"), expected: .keySetMismatch),
        MalformedCase(
            label: "schema: true", data: requestJSON(replacing: ["schema": "true"]), expected: .wrongType("schema")),
        MalformedCase(
            label: "schema: \"1\"", data: requestJSON(replacing: ["schema": "\"1\""]), expected: .wrongType("schema")),
        MalformedCase(label: "schema: 1.0", data: requestJSON(replacing: ["schema": "1.0"]), expected: .badSchema),
        MalformedCase(label: "schema: 2", data: requestJSON(replacing: ["schema": "2"]), expected: .badSchema),
        MalformedCase(
            label: "request_id: 5", data: requestJSON(replacing: ["request_id": "5"]),
            expected: .wrongType("request_id")),
        MalformedCase(label: "targets: []", data: requestJSON(replacing: ["targets": "[]"]), expected: .badTargets),
        MalformedCase(
            label: "targets を 2 要素",
            data: requestJSON(replacing: [
                "targets": #"[{"relpath": "a.wav", "size": 1, "mtime": 1}, "#
                    + #"{"relpath": "b.wav", "size": 1, "mtime": 1}]"#
            ]),
            expected: .badTargets),
        MalformedCase(
            label: "targets: {…}（配列でない）",
            data: requestJSON(replacing: ["targets": #"{"relpath": "a.wav", "size": 1, "mtime": 1}"#]),
            expected: .badTargets),
        MalformedCase(
            label: "target にキー x を足す",
            data: requestJSON(replacing: ["targets": target(extra: #", "x": 1"#)]), expected: .badTargets),
        MalformedCase(
            label: "relpath: 1",
            data: requestJSON(replacing: ["targets": #"[{"relpath": 1, "size": 345600000, "mtime": 1787000000.0}]"#]),
            expected: .wrongType("targets.relpath")),
        MalformedCase(
            label: "size: -1", data: requestJSON(replacing: ["targets": target("-1")]),
            expected: .wrongType("targets.size")),
        MalformedCase(
            label: "size: 1.5", data: requestJSON(replacing: ["targets": target("1.5")]),
            expected: .wrongType("targets.size")),
        MalformedCase(
            label: "size: true", data: requestJSON(replacing: ["targets": target("true")]),
            expected: .wrongType("targets.size")),
        MalformedCase(
            label: "mtime: true", data: requestJSON(replacing: ["targets": target("345600000", "true")]),
            expected: .wrongType("targets.mtime")),
        MalformedCase(
            label: "mtime: \"1787000000\"",
            data: requestJSON(replacing: ["targets": target("345600000", "\"1787000000\"")]),
            expected: .wrongType("targets.mtime")),
    ]

    @Test("形の誤りを拒む（パラメータ化。各行は fixture から 1 か所だけ変えた手書き JSON）", arguments: malformedRequests)
    func rejectsMalformedRequests(_ c: MalformedCase) {
        #expect(ContractJSON.decodeRequest(c.data) == .failure(c.expected))
    }

    @Test("結果が往復する")
    func roundTripsResult() throws {
        let deleted = DeleteResult(
            requestID: "20260912T090000Z-a5d046dce76cfedc-a1b2c3", completedAt: "2026-09-12T18:00:05+09:00",
            reaperVersion: "1.0.0", deviceID: "DJIMIC3", partkey: Self.partkey, status: .deleted, detail: Self.relpath)
        #expect(ContractJSON.decodeResult(try ContractJSON.encode(deleted)) == .success(deleted))
        let mismatch = DeleteResult(
            requestID: "20260912T090000Z-a5d046dce76cfedc-a1b2c3", completedAt: "2026-09-12T18:00:05+09:00",
            reaperVersion: "1.0.0", deviceID: "DJIMIC3", partkey: Self.partkey, status: .sourceIdentityMismatch,
            detail: "size_mismatch")
        #expect(ContractJSON.decodeResult(try ContractJSON.encode(mismatch)) == .success(mismatch))
    }

    /// 結果を手書きした JSON。
    static func resultJSON(replacing: [String: String] = [:], adding: (String, String)? = nil) -> Data {
        var fields: [(String, String)] = [
            ("schema", "1"),
            ("request_id", #""20260912T090000Z-a5d046dce76cfedc-a1b2c3""#),
            ("completed_at", #""2026-09-12T18:00:05+09:00""#),
            ("reaper_version", #""1.0.0""#),
            ("device_id", #""DJIMIC3""#),
            ("partkey", "\"\(partkey)\""),
            ("status", #""DELETED""#),
            ("detail", "\"\(relpath)\""),
        ]
        fields = fields.map { ($0.0, replacing[$0.0] ?? $0.1) }
        if let adding { fields.append(adding) }
        let body = fields.map { "\"\($0.0)\": \($0.1)" }.joined(separator: ", ")
        return Data("{\(body)}".utf8)
    }

    @Test("結果の形の誤り")
    func rejectsMalformedResults() {
        let extra = Self.resultJSON(adding: ("extra", "1"))
        #expect(ContractJSON.decodeResult(extra) == .failure(.keySetMismatch))
        let badStatus = Self.resultJSON(replacing: ["status": #""OK""#])
        #expect(ContractJSON.decodeResult(badStatus) == .failure(.wrongType("status")))
        let badSchema = Self.resultJSON(replacing: ["schema": "2"])
        #expect(ContractJSON.decodeResult(badSchema) == .failure(.badSchema))
        let badDetail = Self.resultJSON(replacing: ["detail": "1"])
        #expect(ContractJSON.decodeResult(badDetail) == .failure(.wrongType("detail")))
    }
}
