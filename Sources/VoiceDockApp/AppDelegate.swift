// アプリのライフサイクル（PLAN §8.15）。起動・パネルの生成・終了。
import AppKit
import VDCore
import VDModels
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
        // 後始末の最中の 2 度目は取り消さない（ログアウト・システムの終了を中断させない）。1 度目の後始末の終わりの reply
        // （最大 10 秒）で終わる。なお AppKit は、.terminateLater の応答待ちの間の 2 度目の terminate ではここを呼ばずに
        // 直ちに終了する（applicationWillTerminate だけが呼ばれる。macOS 26 で確かめた。F-76）
        if terminating { return .terminateLater }
        terminating = true
        guard let ctx = context else { return .terminateNow }
        let steps = Self.shutdownSteps(Self.shutdownParts(ctx))
        Task { @MainActor in
            // 後始末全体を最大 10 秒で打ち切る。超えたら残りを待たずに終了する
            // （中途の状態は次回起動の復旧が戻す。PLAN §5.3・§8.15・F-76）
            _ = await Self.shutDown(within: Self.terminateTimeout, steps)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 終了の直前（F-76）。後始末が 10 秒で打ち切られたときも、2 度目の終了要求で AppKit が後始末を飛ばして終わるときも、
    /// 子プロセスを残さない: ProcessRunner を閉じ、残った子のプロセスグループに SIGTERM → 直ちに SIGKILL（最大 lastKillTimeout 待つ）。
    func applicationWillTerminate(_ notification: Notification) {
        guard let runner = context?.runner else { return }
        _ = Self.killChildrenBeforeExit(runner, within: Self.lastKillTimeout)
    }

    /// 終了の後始末の段の中身（本番は AppContext から作る。テストは記録する偽物で順を確かめる。F-76）。
    struct ShutdownParts: Sendable {
        /// 新しい工程を始めない（Worker.requestStop。service_stopping はここで 1 回出る）
        let requestStop: @Sendable () async -> Void
        /// ProcessRunner を閉じて（以後の起動を拒む）、実行中の子をプロセスグループごと止める（terminateAll）
        let terminateChildren: @Sendable () async -> Void
        /// 取り込みを止める（走査の中の diskutil は terminateChildren で止めた）
        let stopIngest: @Sendable () async -> Void
        /// モデルのダウンロードを止め、再開データを `models/.<file>.resume` に書き終える
        /// （`ModelDownloader.stopAllKeepingResumeData`。次の起動のダウンロードはそこから再開する。F-83）
        let keepDownloadResumeData: @Sendable () async -> Void
        /// llama-server の後始末（起動の途中なら中止させる。鍵ファイルを消す。PLAN §8.5）
        let stopLLM: @Sendable () async -> Void
        /// Worker のループの終わりを待つ（停止要求は Part・Session の区切りで見る）
        let awaitWorker: @Sendable () async -> Void
    }

    /// 終了の後始末の順（PLAN §8.15・F-76）。子プロセスを閉じて止める段を、終わるまでに時間の掛かりうる段
    /// （llama-server の停止・Worker の終わりの待ち）より前に置く（打ち切られても子を残さない）。
    /// ダウンロードの再開データを残す段（F-83）は取り込みを止めた後・llama-server の後始末より前（PLAN §8.15 の終了の順）
    nonisolated static func shutdownSteps(_ parts: ShutdownParts) -> [@Sendable () async -> Void] {
        [
            parts.requestStop, parts.terminateChildren, parts.stopIngest, parts.keepDownloadResumeData, parts.stopLLM,
            parts.awaitWorker,
        ]
    }

    /// 本番の段の中身。
    private static func shutdownParts(_ ctx: AppContext) -> ShutdownParts {
        let worker = ctx.worker
        let runner = ctx.runner
        let ingest = ctx.ingest
        let downloader = ctx.downloader
        let llama = ctx.llama
        let workerTask = ctx.workerTask
        let killGrace = terminateKillGrace
        return ShutdownParts(
            requestStop: { await worker.requestStop() },
            terminateChildren: { await runner.terminateAll(grace: killGrace) },
            stopIngest: { await ingest.stop() },
            keepDownloadResumeData: { await downloader.stopAllKeepingResumeData() },
            stopLLM: { await llama.stop() },
            awaitWorker: { _ = await workerTask?.value })
    }

    /// 終了の直前に子を止める待ちの上限（applicationWillTerminate は戻ると終了するので、呼び手のスレッドを止めて待つ）
    static let lastKillTimeout: Duration = .seconds(1)

    /// `runner.terminateAll(grace: .zero)` を別のタスクで行い、終わるか timeout まで呼び手のスレッドを止めて待つ（F-76）。
    /// ProcessRunner は main の外で動くので、main を止めても進む。終わったら真。
    nonisolated static func killChildrenBeforeExit(_ runner: ProcessRunner, within timeout: Duration) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await runner.terminateAll(grace: .zero)
            done.signal()
        }
        let parts = timeout.components
        let nanoseconds = parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
        return done.wait(timeout: .now() + .nanoseconds(Int(nanoseconds))) == .success
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
