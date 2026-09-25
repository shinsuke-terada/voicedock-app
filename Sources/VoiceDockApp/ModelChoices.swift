// LLM の選択肢と、モデルの在否（PLAN §8.10 / §8.12 の 5）。純関数。
import Foundation
import VDContract
import VDCore

/// LLM の Picker の 1 行。
struct LLMChoice: Equatable, Sendable, Identifiable {
    /// カタログの ID か custom:<sha256>
    let id: String
    let displayName: String
    let minMemoryGB: Int?
    let present: Bool
    let selectable: Bool
    /// 選べない理由、または custom の注意書き。選べて注意も無ければ nil
    let note: String?
    let isCustom: Bool
}

/// LLM の選択肢と在否（純関数）。メモリの条件は ModelMemory を呼ぶ（CR-06）。
enum ModelChoices {
    /// verified のカタログの LLM をカタログの順に。メモリ不足は選べないだけで一覧から消さない（PLAN §8.10）。
    /// currentID が custom:<64 桁> なら末尾に 1 件足す。
    static func llm(
        catalog: ModelCatalog, physicalMemoryBytes: UInt64, currentID: String?, layout: HomeLayout
    ) -> [LLMChoice] {
        var choices = catalog.listedLLMs.map { entry -> LLMChoice in
            let selectable = ModelMemory.hasEnough(
                minMemoryGB: entry.minMemoryGB, physicalMemoryBytes: physicalMemoryBytes)
            return LLMChoice(
                id: entry.id, displayName: entry.displayName, minMemoryGB: entry.minMemoryGB,
                present: ModelFiles.isPresent(entry, kind: .llm, layout: layout), selectable: selectable,
                note: selectable
                    ? nil
                    : Strings.notEnoughMemory(
                        required: entry.minMemoryGB ?? 0, actual: ModelMemory.gb(physicalMemoryBytes)),
                isCustom: false)
        }
        if let id = currentID, let sha = CustomModelID.sha256(of: id) {
            choices.append(
                LLMChoice(
                    id: id, displayName: Strings.customModelName(String(sha.prefix(8))), minMemoryGB: nil,
                    present: customFileExists(id: id, layout: layout), selectable: true,
                    note: Strings.customModelUnsupported, isCustom: true))
        }
        return choices
    }

    /// id が nil なら偽。custom: ならファイルの有無、そうでなければカタログの項目の在否（ModelFiles.isPresent）。
    static func llmIsPresent(id: String?, catalog: ModelCatalog, layout: HomeLayout) -> Bool {
        guard let id else { return false }
        if id.hasPrefix(CustomModelID.prefix) { return customFileExists(id: id, layout: layout) }
        guard let entry = catalog.entry(kind: .llm, id: id) else { return false }
        return ModelFiles.isPresent(entry, kind: .llm, layout: layout)
    }

    /// ModelFiles.customLLMURL(id:layout:) のファイルが在るか（形が違えば偽）。
    private static func customFileExists(id: String, layout: HomeLayout) -> Bool {
        guard let url = ModelFiles.customLLMURL(id: id, layout: layout) else { return false }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
