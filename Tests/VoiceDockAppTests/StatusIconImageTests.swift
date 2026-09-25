// StatusIconImage と StatusIconBadge（メニューバーのアイコンと削除が有効な赤い点）のテスト（F-91）。
import AppKit
import Testing

@testable import VoiceDockApp

@Suite("StatusIconImage")
@MainActor
struct StatusIconImageTests {
    @Test("削除が有効でも無効でもテンプレート画像のまま（F-91）", arguments: [false, true])
    func alwaysTemplate(showsDeletionBadge: Bool) {
        for state in IconState.allCases {
            let image = StatusIconImage.make(state: state, showsDeletionBadge: showsDeletionBadge)
            #expect(image.isTemplate, "\(state)")
            #expect(image.size.width > 0, "\(state)")
        }
    }

    @Test("削除が有効なら読み上げの説明に「元音声の削除が有効です」を足す（F-91）")
    func accessibilityDescription() {
        #expect(
            StatusIconImage.make(state: .idle, showsDeletionBadge: true).accessibilityDescription
                == "待機中。元音声の削除が有効です")
        #expect(StatusIconImage.make(state: .idle, showsDeletionBadge: false).accessibilityDescription == "待機中")
    }

    @Test("赤い点は記号の右上（ボタンの中心から x は右、y は上へ。F-91）")
    func badgeOffset() {
        let offset = StatusIconBadge.centerOffset(imageSize: NSSize(width: 20, height: 16))
        #expect(offset.dx == 9)
        #expect(offset.dy == -7)
        #expect(StatusIconBadge.diameter == 6)
    }

    @Test("空の画像（0×0）でも点は中心に置かれ、負の幅にならない（TEST-28）")
    func badgeOffsetForEmptyImage() {
        let offset = StatusIconBadge.centerOffset(imageSize: NSSize(width: 0, height: 0))
        #expect(offset.dx == 0)
        #expect(offset.dy == 0)
    }

    @Test("赤い点はクリックを受けない（ボタンに届く）")
    func badgeIgnoresHits() {
        let badge = StatusIconBadge(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        #expect(badge.hitTest(NSPoint(x: 3, y: 3)) == nil)
    }
}
