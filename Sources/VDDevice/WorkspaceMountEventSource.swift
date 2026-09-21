// NSWorkspace の通知（didMount / didUnmount / didWake）を () に写す本番の MountEventSource（PLAN §8.1 の起動契機）。
import AppKit

/// Bootstrap（VoiceDockApp）が注入する。AppKit は NSWorkspace の通知だけに使う（§3.4）。Notification をストリームの外へ渡さない
public struct WorkspaceMountEventSource: MountEventSource {
    public init() {}

    public func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let names: [Notification.Name] = [
                NSWorkspace.didMountNotification,
                NSWorkspace.didUnmountNotification,
                NSWorkspace.didWakeNotification,
            ]
            let tasks = names.map { name in
                Task { @MainActor in
                    for await _ in NSWorkspace.shared.notificationCenter.notifications(named: name) {
                        continuation.yield(())
                    }
                }
            }
            continuation.onTermination = { _ in
                for task in tasks { task.cancel() }
            }
        }
    }
}
