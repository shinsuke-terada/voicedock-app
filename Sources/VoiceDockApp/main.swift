// VoiceDock アプリの入口（PLAN §8.12 / §8.15）。SwiftUI の App ではなく AppKit のライフサイクルを自分で回す
// （MenuBarExtra はプログラムから開けないため。PLAN §8.12）。
import AppKit

let appDelegate = AppDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)  // Dock に出ない（Info.plist の LSUIElement と二重に効かせる）
application.delegate = appDelegate
application.run()
