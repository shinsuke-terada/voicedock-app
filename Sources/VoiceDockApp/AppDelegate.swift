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
                let alert = NSAlert()
                alert.messageText = Strings.bootFailureTitle
                alert.informativeText = f.message
                alert.addButton(withTitle: Strings.ok)
                alert.runModal()
                NSApp.terminate(nil)
                return
            case .success(let c):
                ctx = c
            }
            let model = AppModel(
                services: LiveServices(context: ctx), openFinder: NSWorkspaceFinder(), layout: ctx.layout,
                now: ctx.clock.now(), quit: { [weak self] in self?.requestTerminate() })
            let controller = StatusItemController(model: model)
            model.start()
            // 初回起動だけ自動で開く（PLAN §8.12）
            if await ctx.config.didCreateDefaults() { controller.open() }
            self?.context = ctx
            self?.model = model
            self?.statusItem = controller
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        guard let ctx = context else { return .terminateNow }
        Task { @MainActor in
            // 新しい工程を始めない（service_stopping はここで 1 回出る）
            await ctx.worker.requestStop()
            await ctx.ingest.stop()
            await ctx.llama.stop()
            // 実行中の子プロセスをプロセスグループごと（PLAN §8.2）
            await ctx.runner.terminateAll(grace: Self.terminateKillGrace)
            // 最大 10 秒。待ち切れなくても終了する（中途の状態は次回起動の復旧が戻す。PLAN §5.3）
            if let t = ctx.workerTask { _ = await withTimeout(Self.terminateTimeout) { await t.value } }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// パネルの「終了」ボタンから呼ぶ
    func requestTerminate() {
        NSApp.terminate(nil)
    }
}

/// 本体と timeout の眠りを競わせ、先に終わった方で抜ける。本体が先なら真。
/// withTaskGroup は抜ける前に子の終わりを待つ（`Task.value` の待ちは取り消しに応じない）ので、構造化しないタスク 2 つで競わせる。
private func withTimeout(_ timeout: Duration, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let (finished, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
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
