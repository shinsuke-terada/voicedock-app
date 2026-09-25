// TextLimit の検査（CR-23。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("TextLimit")
struct TextLimitTests {
    @Test("文字数は Unicode スカラー数（CR-23）")
    func scalarCount() {
        #expect(TextLimit.scalarCount("が") == 1)
        #expect(TextLimit.scalarCount("か\u{3099}") == 2)
        #expect(TextLimit.scalarCount("👨‍👩‍👧") == 5)
        #expect(TextLimit.scalarCount("") == 0)
        #expect(TextLimit.prefix("か\u{3099}き", scalars: 1) == "か")
        #expect(TextLimit.prefix("abc", scalars: 5) == "abc")
        #expect(TextLimit.prefix("", scalars: 3) == "")
    }

    @Test("200 文字の切り詰め")
    func truncate200() {
        let exact = String(repeating: "a", count: 200)
        #expect(TextLimit.truncate200(exact) == exact)
        #expect(TextLimit.truncate200("") == "")
        let over = String(repeating: "a", count: 201)
        #expect(TextLimit.truncate200(over) == String(repeating: "a", count: 199) + "…")
        #expect(TextLimit.truncate200(over).unicodeScalars.count == 200)
        // 198 スカラー + 家族の絵文字（5 スカラー）＝ 203 スカラー。先頭 199 スカラーは絵文字の 1 スカラー目で切れる
        let emoji = String(repeating: "a", count: 198) + "👨‍👩‍👧"
        #expect(TextLimit.truncate200(emoji) == String(repeating: "a", count: 198) + "👨" + "…")
        #expect(TextLimit.truncate200(emoji).unicodeScalars.count == 200)
    }
}
