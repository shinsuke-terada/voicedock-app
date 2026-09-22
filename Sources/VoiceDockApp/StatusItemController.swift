// メニューバーの項目とパネル（PLAN §8.12）。MenuBarExtra を使わない（プログラムから開けないため）。
import AppKit
import SwiftUI

/// メニューバーの項目とパネル（PLAN §8.12）。
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    static let panelWidth: CGFloat = 380

    private let item: NSStatusItem
    private let popover: NSPopover
    private let model: AppModel
    private var iconObserver: Task<Void, Never>?
    private var reopenAfterModal = false

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
        // 高さは PanelView が固定する（PanelStyle.maxHeight）。1 にすると ScrollView が潰れて開けない
        popover.contentSize = NSSize(width: Self.panelWidth, height: PanelStyle.maxHeight)
        super.init()
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.setButtonType(.momentaryChange)
        applyIcon()
        iconObserver = Task { @MainActor [weak self] in
            for await _ in model.iconChanges { self?.applyIcon() }
        }
    }

    func open() {
        guard let button = item.button else { return }
        model.panelDidOpen()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 入力欄にフォーカスを渡すため（PLAN §8.12）
        NSApp.activate()
    }

    func close() {
        // popoverDidClose が model.panelDidClose() を呼ぶ
        popover.performClose(nil)
    }

    /// NSOpenPanel など modal を出す前後で使う（PLAN §8.12「popover が閉じたら、終わった後に開き直す」）。
    func runModal<T>(_ body: @MainActor () -> T) -> T {
        let wasShown = popover.isShown
        if wasShown {
            reopenAfterModal = true
            popover.performClose(nil)
        }
        let result = body()
        if reopenAfterModal {
            reopenAfterModal = false
            open()
        }
        return result
    }

    func popoverDidClose(_ notification: Notification) {
        // reopenAfterModal はここで消さない（runModal が開き直す）
        model.panelDidClose()
    }

    @objc private func toggle(_ sender: Any?) {
        popover.isShown ? close() : open()
    }

    private func applyIcon() {
        item.button?.image = StatusIconImage.make(state: model.iconState, showsTrash: model.showsTrash)
        item.button?.toolTip = model.statusLine
    }
}
