// モデルの入手・選択・取り込み・キャンセル（PLAN §8.10 / §8.12 の 5）。ダウンロードは AppServices 越しに VDModels が行う。
import Foundation
import VDCore
import VDModels

extension AppModel {
    /// 1 件ダウンロードする（進行中なら始めない。失敗の後はもう一度始められる）。進捗は downloads[slot] に写す。
    /// 開始時の世代を覚え、世代が変わった（やめた・入手し直した）後の結果と進捗は書かない。
    func fetchModel(_ slot: ModelSlot) async {
        guard !isBusy(slot) else { return }
        guard let (kind, entry) = entryFor(slot) else { return }
        let generation = (downloadGenerations[slot] ?? 0) + 1
        downloadGenerations[slot] = generation
        downloads[slot] = .running(received: 0, total: entry.bytes)
        modelError = nil
        // やめた直後の入手し直し: 前の download が ModelManager から抜けるまで待つ（抜ける前に呼ぶと内部の「実行中」が返る）
        if let previous = downloadTasks[slot] { _ = await previous.value }
        guard downloadGenerations[slot] == generation else { return }
        let services = self.services
        let task = Task {
            await services.download(kind: kind, entry: entry) { received, total in
                Task { @MainActor in self.progress(slot, generation, received, total) }
            }
        }
        downloadTasks[slot] = task
        let r = await task.value
        if downloadTasks[slot] == task { downloadTasks[slot] = nil }
        // 世代が変わった後（やめた・入手し直した）は結果を書かない（.failure(.cancelled) を .failed にしない）
        if downloadGenerations[slot] == generation, case .running = downloads[slot] {
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

    /// 先に .idle にして世代を進めてから取り消す（遅れた進捗と結果を捨てるため）。
    func cancelModel(_ slot: ModelSlot) async {
        guard case .running = downloads[slot], let (_, entry) = entryFor(slot) else { return }
        downloads[slot] = .idle
        downloadGenerations[slot] = (downloadGenerations[slot] ?? 0) + 1
        await services.cancelDownload(id: entry.id)
    }

    /// 選べる選択肢だけを設定に書く（メモリ不足・一覧に無い ID は書かない）。
    func selectLLM(_ id: String) async {
        guard let choice = snapshot.llmChoices.first(where: { $0.id == id }), choice.selectable else { return }
        let r = await services.updateConfig { $0.llm.modelID = id }
        switch r {
        case .failure(let v): modelError = Strings.configRejected(v)
        case .success:
            modelError = nil
            modelNotice = nil
        }
        await refresh()
    }

    /// 利用者が選んだ .gguf を取り込み、custom:<sha256> を設定に書く（PLAN §8.10「ファイルから読み込む」）。
    func importLLMFromFile() async {
        // 取り込み中はもう一度読み込まない
        guard !isBusy(.customImport) else { return }
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
            // CV-42 が custom:<64 桁> を通す。弾かれたら捨てずに出す
            if case .failure(let v) = await services.updateConfig({ $0.llm.modelID = got.id }) {
                modelError = Strings.configRejected(v)
                await refresh()
                return
            }
            modelError = nil
            // メモリの確認は警告だけ（PLAN §8.10）
            modelNotice = Strings.customModelUnsupported
            await refresh()
        }
    }

    /// 進行中（ダウンロード中・取り込み中）か
    private func isBusy(_ slot: ModelSlot) -> Bool {
        switch downloads[slot] {
        case .running, .importing: true
        case .idle, .failed, nil: false
        }
    }

    /// 進捗の通知。世代が違う（やめた後・前の入手の）通知と、値が小さくなる通知（Task の実行順の入れ替わり）は捨てる。
    private func progress(_ slot: ModelSlot, _ generation: Int, _ received: Int64, _ total: Int64) {
        guard downloadGenerations[slot] == generation, case .running(let shown, _) = downloads[slot] else { return }
        guard received >= shown else { return }
        downloads[slot] = .running(received: received, total: total)
    }

    /// 枠 → 入手する項目。custom は入手できないので nil。
    private func entryFor(_ slot: ModelSlot) -> (ModelKind, ModelEntry)? {
        switch slot {
        case .whisper: snapshot.whisperEntry.map { (.whisper, $0) }
        case .vad: snapshot.vadEntry.map { (.vad, $0) }
        case .llm(let id): catalog.entry(kind: .llm, id: id).map { (.llm, $0) }
        }
    }
}
