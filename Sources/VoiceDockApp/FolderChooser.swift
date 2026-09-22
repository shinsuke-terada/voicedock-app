// NSOpenPanel の包み（テストで差し替える）。popover を閉じてから出し、終わったら開き直す（PLAN §8.12）。
import AppKit

/// フォルダを 1 つ選ばせる口。
protocol FolderChooser: Sendable {
    /// 選ばれたフォルダの URL。取り消しなら nil
    @MainActor func chooseFolder(message: String, prompt: String) -> URL?
}

/// ファイルを 1 つ選ばせる口。
protocol FileChooser: Sendable {
    @MainActor func chooseFile(message: String, prompt: String, allowedExtensions: [String]) -> URL?
}

/// 本番の FolderChooser（NSOpenPanel）。
@MainActor
struct OpenPanelFolderChooser: FolderChooser {
    func chooseFolder(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Vault を作らせない（DEL-06）
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// 本番の FileChooser（NSOpenPanel）。
@MainActor
struct OpenPanelFileChooser: FileChooser {
    func chooseFile(message: String, prompt: String, allowedExtensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false
        panel.message = message
        panel.prompt = prompt
        // 拡張子で絞る（UTType は import の許可リストに無い（PT-07）ので allowedContentTypes は使わない。空なら制限しない）
        let filter = ExtensionFilter(extensions: allowedExtensions)
        if !allowedExtensions.isEmpty { panel.delegate = filter }
        let picked = panel.runModal() == .OK ? panel.url : nil
        // delegate は weak なので runModal の間 filter を生かしておく
        withExtendedLifetime(filter) {}
        return picked
    }
}

/// NSOpenPanel で、ディレクトリと指定の拡張子（大小を区別しない）のファイルだけを選べるようにする。
@MainActor
private final class ExtensionFilter: NSObject, NSOpenSavePanelDelegate {
    let extensions: Set<String>

    init(extensions: [String]) {
        self.extensions = Set(extensions.map { $0.lowercased() })
    }

    /// フォルダ（パッケージでないもの）は入れるように有効にする。パッケージはファイルとして扱い、拡張子で決める。
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        if values.isDirectory == true && values.isPackage != true { return true }
        return extensions.contains(url.pathExtension.lowercased())
    }
}
