// ConfigLoader.encode が符号化できない値で投げること・ファイル全体の keyPath の定数のテスト（F-83。PLAN §6.1。issue #119 の H7・H8）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ConfigLoader（F-83）")
struct ConfigLoaderEncodeTests {
    @Test("F-83 検証を通る値でも JSON にできなければ投げる（空の Data を返さない）")
    func nonFiniteNumberThrows() {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.audio.freeSpaceMultiplier = .infinity
        // CV-58 は `freeSpaceMultiplier >= 1` だけを見るので、無限大は検証を通る
        #expect(
            ConfigValidator.validate(config, catalog: TestCatalogs.minimal, reaperConfObservation: .missing).isEmpty)
        #expect(throws: EncodingError.self) { try ConfigLoader.encode(config) }
    }

    @Test("F-83 既定値は符号化でき、末尾は改行 1 つ")
    func defaultsEncode() throws {
        let data = try ConfigLoader.encode(AppConfig.defaults(timeZone: "Asia/Tokyo"))
        #expect(data.last == 0x0A)
        #expect(data.dropLast().last != 0x0A)
    }

    @Test("F-83 ファイル全体の違反の keyPath は <file>（空の入力は JSON として読めない。TEST-28）")
    func fileKeyPath() {
        #expect(ConfigLoader.fileKeyPath == "<file>")
        #expect(
            ConfigLoader.load(data: Data(), catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
                == .invalid([
                    ConfigViolation(
                        rule: "CV-39", code: .configInvalidValue, keyPath: "<file>", message: "JSON として読めません")
                ]))
    }
}
