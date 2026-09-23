// アプリのライフサイクル（PLAN §8.15）。起動・パネルの生成・終了。
import AppKit
import VDCore
import VDPipeline
import VDProcess

/// アプリのライフサイクル（PLAN §8.15）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: AppContext?
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var terminating = false

    static let terminateTimeout: Duration = .seconds(10)
    /// ProcessRunner.killGrace と同じ値（同じ値を 2 か所に書かない。CR-06）
    static let terminateKillGrace: Duration = ProcessRunner.killGrace

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            let ctx: AppContext
            switch await Bootstrap.build() {
            case .failure(let f):
                // 失敗したときは StatusItemController を作らない（アイコンの出ないゾンビにしない）
                // 別のインスタンスが動いている（F-76）なら何も出さずに終わる（パネルは先に起動したほうにある）
                guard let message = f.message else {
                    NSApp.terminate(nil)
                    return
                }
                // アクセサリのアプリは前面に出ていないので、先に前面に出してから警告を出す
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = Strings.bootFailureTitle
                alert.informativeText = message
                alert.addButton(withTitle: Strings.ok)
                alert.runModal()
                NSApp.terminate(nil)
                return
            case .success(let c):
                ctx = c
                // 以降の組み立ての途中で終了が来ても、applicationShouldTerminate が部品を止められるように先に持つ
                self?.context = ctx
            }
            // presentModal は呼ばれた時点の StatusItemController で包む（popover を閉じてから出し、終わったら開き直す）
            let model = AppModel(
                services: LiveServices(context: ctx), openFinder: NSWorkspaceFinder(), layout: ctx.layout,
                catalog: ctx.catalog, chooser: OpenPanelFolderChooser(), fileChooser: OpenPanelFileChooser(),
                presentModal: { [weak self] body in
                    guard let controller = self?.statusItem else { return body() }
                    return controller.runModal(body)
                },
                now: ctx.clock.now(), quit: { [weak self] in self?.requestTerminate() })
            let controller = StatusItemController(model: model)
            model.start()
            // 初回起動だけ自動で開く（PLAN §8.12）
            if await ctx.config.didCreateDefaults() { controller.open() }
            self?.model = model
            self?.statusItem = controller
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 応答（reply）を待っている間の 2 度目は取り消す（1 度目の後始末は最大 10 秒で終わり、そこで終了する）
        if terminating { return .terminateCancel }
        terminating = true
        guard let ctx = context else { return .terminateNow }
        let steps = Self.shutdownSteps(ctx)
        Task { @MainActor in
            // 後始末全体を最大 10 秒で打ち切る。超えたら残りを待たずに終了する
            // （中途の状態は次回起動の復旧が戻す。PLAN §5.3・§8.15・F-76）
            _ = await Self.shutDown(within: Self.terminateTimeout, steps)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 終了の後始末の順（PLAN §8.15・F-76）。子プロセスを閉じて止める段を、終わるまでに時間の掛かりうる段
    /// （llama-server の停止・Worker の終わりの待ち）より前に置く（打ち切られても子を残さない）。
    private static func shutdownSteps(_ ctx: AppContext) -> [@Sendable () async -> Void] {
        let worker = ctx.worker
        let runner = ctx.runner
        let ingest = ctx.ingest
        let llama = ctx.llama
        let workerTask = ctx.workerTask
        let killGrace = terminateKillGrace
        return [
            // 1. 新しい工程を始めない（service_stopping はここで 1 回出る）
            { await worker.requestStop() },
            // 2. ProcessRunner を閉じて（以後の起動を拒む）、実行中の子をプロセスグループごと止める
            //    （SIGTERM → 全部終われば戻る。最大 killGrace で SIGKILL。PLAN §8.2）
            { await runner.terminateAll(grace: killGrace) },
            // 3. 取り込みを止める（走査の中の diskutil は 2 で止めた）
            { await ingest.stop() },
            // 4. llama-server の後始末（起動の途中なら中止させる。鍵ファイルを消す。PLAN §8.5）
            { await llama.stop() },
            // 5. Worker のループの終わりを待つ（停止要求は Part・Session の区切りで見る）
            { _ = await workerTask?.value },
        ]
    }

    /// 終了の後始末（PLAN §8.15・F-76）。steps を順に await し、全体を timeout で打ち切る（超えたら残りを待たずに戻る）。
    /// 打ち切ったら実行中の段を取り消し、後の段は始めない。最後まで終われば真。
    nonisolated static func shutDown(within timeout: Duration, _ steps: [@Sendable () async -> Void]) async -> Bool {
        await withTimeout(timeout) {
            for step in steps {
                if Task.isCancelled { return }
                await step()
            }
        }
    }

    /// パネルの「終了」ボタンから呼ぶ
    func requestTerminate() {
        NSApp.terminate(nil)
    }
}

/// 本体と timeout の眠りを競わせ、先に終わった方で抜ける。本体が先なら真。
/// withTaskGroup は抜ける前に子の終わりを待つ（`Task.value` の待ちは取り消しに応じない）ので、構造化しないタスク 2 つで競わせる。
private func withTimeout(_ timeout: Duration, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let (finished, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingOldest(1))
    let work = Task {
        await body()
        continuation.yield(true)
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        continuation.yield(false)
    }
    var iterator = finished.makeAsyncIterator()
    let first = await iterator.next() ?? false
    timer.cancel()
    work.cancel()
    continuation.finish()
    return first
}
