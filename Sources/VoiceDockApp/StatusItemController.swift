// メニューバーの項目とパネル（PLAN §8.12）。MenuBarExtra を使わない（プログラムから開けないため）。
import AppKit
import SwiftUI

/// メニューバーの項目とパネル（PLAN §8.12）。
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover: NSPopover
    private let model: AppModel
    /// 削除が有効な間の赤い点（F-91）
    private let badge = StatusIconBadge()
    private var iconObserver: Task<Void, Never>?
    /// 状態の 1 行が変わったらツールチップを書き直す（F-84。アイコンが変わらない間も古いまま残さない）
    private var statusLineObserver: Task<Void, Never>?
    private var reopenAfterModal = false
    /// 要約プロンプトの編集の窓（F-92。初めて開くときに作る）
    private var promptEditor: PromptEditorWindowController?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let hosting = NSHostingController(rootView: PanelView(model: model))
        // 高さは中身に合わせる（F-65）。SwiftUI の理想の大きさを preferredContentSize に写し、popover がそれに追従する。
        // 主画面に ScrollView は無く、別の画面の ScrollView は中身を測った高さを持つので、1pt に潰れない（PR #100）
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        super.init()
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.setButtonType(.momentaryChange)
        if let button = item.button { badge.attach(to: button) }
        applyIcon()
        iconObserver = Task { @MainActor [weak self] in
            for await _ in model.iconChanges { self?.applyIcon() }
        }
        statusLineObserver = Task { @MainActor [weak self] in
            for await _ in model.statusLineChanges { self?.applyToolTip() }
        }
    }

    func open() {
        guard let button = item.button else { return }
        model.panelDidOpen()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // パネルの操作（Menu・トグル・長押し）に最初のクリックから反応させるため（PLAN §8.12）
        NSApp.activate()
    }

    func close() {
        // popoverDidClose が model.panelDidClose() を呼ぶ
        popover.performClose(nil)
    }

    /// 要約プロンプトの編集の窓を出す（F-92）。パネルは閉じる（transient の popover は窓の前に残らない）
    func showPromptEditor() {
        close()
        let editor = promptEditor ?? PromptEditorWindowController(model: model)
        promptEditor = editor
        editor.show()
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
        // reopenAfterModal はここで消さない（runModal が開き直す）。モーダルのために閉じたときは要対応の枠を残す（F-84）
        model.panelDidClose(reopening: reopenAfterModal)
    }

    @objc private func toggle(_ sender: Any?) {
        popover.isShown ? close() : open()
    }

    private func applyIcon() {
        let image = StatusIconImage.make(state: model.iconState, showsDeletionBadge: model.showsTrash)
        item.button?.image = image
        badge.update(visible: model.showsTrash, imageSize: image.size)
        applyToolTip()
    }

    private func applyToolTip() {
        item.button?.toolTip = model.statusLine
    }
}
