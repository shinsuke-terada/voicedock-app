// メニューバーのアイコンの右上に重ねる赤い点（PLAN §8.9.8 の常時表示。F-91）。
import AppKit

/// 削除が有効な間、状態の記号の右上に重ねる赤い点（F-91）。
/// テンプレート画像は色を持てないので、画像に描かずボタンに重ねたビューで描く（NSStatusItem は 1 つのまま）。
@MainActor
final class StatusIconBadge: NSView {
    static let diameter: CGFloat = 6
    /// 点の中心を記号の右上の角から内側へ寄せる量
    static let inset: CGFloat = 1

    private var centerX: NSLayoutConstraint?
    private var centerY: NSLayoutConstraint?

    /// ボタンの中心から点の中心までのずれ。Auto Layout の向き（x は右、y は下が正）。
    /// 記号はボタンの中央に置かれるので、記号の右上の角は (幅/2, -高さ/2)。
    static func centerOffset(imageSize: NSSize) -> CGVector {
        CGVector(
            dx: max(imageSize.width / 2 - inset, 0),
            dy: -max(imageSize.height / 2 - inset, 0))
    }

    func attach(to button: NSStatusBarButton) {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        // 読み上げはボタンの画像の説明が担う（Strings.iconDescriptionWithDeletion）
        setAccessibilityElement(false)
        button.addSubview(self)
        let x = centerXAnchor.constraint(equalTo: button.centerXAnchor)
        let y = centerYAnchor.constraint(equalTo: button.centerYAnchor)
        NSLayoutConstraint.activate([
            x, y,
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
        ])
        centerX = x
        centerY = y
    }

    func update(visible: Bool, imageSize: NSSize) {
        let offset = Self.centerOffset(imageSize: imageSize)
        centerX?.constant = offset.dx
        centerY?.constant = offset.dy
        isHidden = !visible
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
