// 話者のラベルと表示の検査（PLAN §8.4.1。F-89。T-47）。
import Foundation
import Testing

@testable import VDCore

@Suite("SpeakerLabel")
struct SpeakerLabelTests {
    @Test("0〜25 は A〜Z")
    func firstLabels() {
        #expect(SpeakerLabel.label(index: 0) == "A")
        #expect(SpeakerLabel.label(index: 1) == "B")
        #expect(SpeakerLabel.label(index: 25) == "Z")
    }

    @Test("27 人目からは S27")
    func beyondZ() {
        #expect(SpeakerLabel.label(index: 26) == "S27")
        #expect(SpeakerLabel.label(index: 27) == "S28")
    }

    @Test("負の index は A")
    func negativeIsA() {
        #expect(SpeakerLabel.label(index: -1) == "A")
    }

    @Test("表示は 話者 + ラベル")
    func display() {
        #expect(SpeakerLabel.display("A") == "話者A")
        #expect(SpeakerLabel.display("") == "話者")
    }
}
