// 押すと別の画面へ移る 1 行（PLAN §8.12。F-65）。「› 元音声の削除  無効」の形。
import SwiftUI

/// 押すと別の画面へ移る 1 行。左にアイコン、右に値と「›」。
struct PanelRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let value: String?
    let action: () -> Void

    @State private var hovering = false

    init(
        systemImage: String, tint: Color = .secondary, title: String, value: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 8)
                if let value {
                    Text(value).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PanelStyle.cardPadding)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
                    .fill(.quaternary.opacity(hovering ? 0.8 : 0.5))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
