// モデルの入手・選択・取り込み・キャンセル（PLAN §8.10 / §8.12 の 5）。ダウンロードは AppServices 越しに VDModels が行う。
import Foundation
import VDCore
import VDModels

extension AppModel {
    /// 1 件ダウンロードする（二重に始めない）。進捗は downloads[slot] に写す。
    func fetchModel(_ slot: ModelSlot) async {
        guard downloads[slot] == nil || downloads[slot] == .idle else { return }
        guard let (kind, entry) = entryFor(slot) else { return }
        downloads[slot] = .running(received: 0, total: entry.bytes)
        modelError = nil
        let r = await services.download(kind: kind, entry: entry) { received, total in
            Task { @MainActor in self.progress(slot, received, total) }
        }
        // 取り消した後（.running でない）は結果を書かない（.failure(.cancelled) を .failed にしない）
        if case .running = downloads[slot] {
            switch r {
            case .success:
                downloads[slot] = .idle
            case .failure(let e):
                downloads[slot] = .failed(Strings.modelError(e))
                modelError = Strings.modelError(e)
            }
        }
        await refresh()
    }

    /// 先に .idle にしてから取り消す（遅れた進捗と結果を捨てるため）。
    func cancelModel(_ slot: ModelSlot) async {
        guard case .running = downloads[slot], let (_, entry) = entryFor(slot) else { return }
        downloads[slot] = .idle
        await services.cancelDownload(id: entry.id)
    }

    /// 選べる選択肢だけを設定に書く（メモリ不足・一覧に無い ID は書かない）。
    func selectLLM(_ id: String) async {
        guard let choice = snapshot.llmChoices.first(where: { $0.id == id }), choice.selectable else { return }
        let r = await services.updateConfig { $0.llm.modelID = id }
        switch r {
        case .failure(let v): modelError = Strings.configRejected(v)
        case .success: modelError = nil
        }
        await refresh()
    }

    /// 利用者が選んだ .gguf を取り込み、custom:<sha256> を設定に書く（PLAN §8.10「ファイルから読み込む」）。
    func importLLMFromFile() async {
        let picked = presentModal {
            fileChooser.chooseFile(
                message: Strings.chooseGGUFMessage, prompt: Strings.chooseGGUFPrompt, allowedExtensions: ["gguf"])
        }
        guard let url = picked else { return }
        downloads[.customImport] = .importing
        let r = await services.importGGUF(from: url)
        switch r {
        case .failure(let e):
            downloads[.customImport] = .failed(Strings.modelError(e))
            modelError = Strings.modelError(e)
            return
        case .success(let got):
            downloads[.customImport] = .idle
            // CV-42 が custom:<64 桁> を通す
            _ = await services.updateConfig { $0.llm.modelID = got.id }
            // メモリの確認は警告だけ（PLAN §8.10）
            modelNotice = Strings.customModelUnsupported
            await refresh()
        }
    }

    /// 進捗の通知。取り消した後の遅れた通知は捨てる。
    func progress(_ slot: ModelSlot, _ received: Int64, _ total: Int64) {
        guard case .running = downloads[slot] else { return }
        downloads[slot] = .running(received: received, total: total)
    }

    /// 枠 → 入手する項目。custom は入手できないので nil。
    func entryFor(_ slot: ModelSlot) -> (ModelKind, ModelEntry)? {
        switch slot {
        case .whisper: snapshot.whisperEntry.map { (.whisper, $0) }
        case .vad: snapshot.vadEntry.map { (.vad, $0) }
        case .llm(let id): catalog.entry(kind: .llm, id: id).map { (.llm, $0) }
        }
    }
}
