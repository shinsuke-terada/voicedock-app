// パネルの部品の純関数（T-30 §4.13・F-65）。ビューは作らない。要対応の件数の切り方・Vault の名前・状態の色。
import SwiftUI
import Testing
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("PanelParts")
struct PanelPartsTests {
    static let three: [AttentionItem] = [.configInvalid, .vaultNotConfigured, .diskSpaceLow]

    @Test("主画面の要対応は先頭の 2 件と「ほか n 件」")
    func mainShowsTheFirstTwo() {
        let (shown, rest) = AttentionSection.split(Self.three, limit: AttentionSection.mainLimit)
        #expect(AttentionSection.mainLimit == 2)
        #expect(shown == [.configInvalid, .vaultNotConfigured])
        #expect(rest == 1)
    }

    @Test("2 件以下なら全部出し、「ほか」は出さない")
    func twoOrFewerAreAllShown() {
        let (shown, rest) = AttentionSection.split(Array(Self.three.prefix(2)), limit: 2)
        #expect(shown == [.configInvalid, .vaultNotConfigured])
        #expect(rest == 0)
    }

    @Test("要対応の画面（limit なし）は全件")
    func attentionScreenShowsAll() {
        let (shown, rest) = AttentionSection.split(Self.three, limit: nil)
        #expect(shown == Self.three)
        #expect(rest == 0)
    }

    @Test("TEST-28 要対応が 0 件なら何も出さない")
    func noAttention() {
        let (shown, rest) = AttentionSection.split([], limit: 2)
        #expect(shown == [])
        #expect(rest == 0)
    }

    @Test("Vault の行はフォルダ名、未選択は「まだ選ばれていません」")
    func vaultDisplayName() {
        #expect(VaultSection.displayName("/Users/me/Documents/VoiceDockTestVault") == "VoiceDockTestVault")
        #expect(VaultSection.displayName("/Users/me/Vault/") == "Vault")
        #expect(VaultSection.displayName(nil) == "まだ選ばれていません")
        #expect(VaultSection.displayName("") == "まだ選ばれていません")
    }

    @Test("状態の色: 待機＝緑、取り込み・処理中＝青、要対応＝橙")
    func tintFollowsTheState() {
        #expect(PanelStyle.tint(.idle) == .green)
        #expect(PanelStyle.tint(.ingesting) == .blue)
        #expect(PanelStyle.tint(.processing) == .blue)
        #expect(PanelStyle.tint(.attention) == .orange)
    }

    @Test("幅は 380pt、別の画面の高さの上限は 560pt")
    func sizes() {
        #expect(PanelStyle.width == 380)
        #expect(PanelStyle.maxScreenHeight == 560)
    }
}
