// dmg のウィンドウの背景画像を作る（PLAN §11.3 の 3・F-99）。左にアプリ、右に Applications、間に矢印と案内。
// 大きさと位置は tools/dmg/write-ds-store.py と同じ値（ウィンドウ 660×400 pt、アイコンの中心 (170, 190) と (490, 190)）。
// 使い方: swift tools/dmg/make-background.swift <出力.png> <倍率 1|2>
// 出力は Resources/dmg/background.png（1 倍）と background@2x.png（2 倍）。画像を変えるときだけ実行してコミットする
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("使い方: make-background.swift <出力.png> <倍率>\n".utf8))
    exit(2)
}
let size = CGSize(width: 660, height: 400)
let pixels = (Int(size.width * scale), Int(size.height * scale))
guard
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels.0, pixelsHigh: pixels.1, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// 座標は左上を原点にする（Finder の配置と同じ向き）
let flip = NSAffineTransform()
flip.translateX(by: 0, yBy: size.height)
flip.scaleX(by: 1, yBy: -1)
flip.concat()

// 背景（白からごく薄い灰色へ）
NSGradient(
    starting: NSColor(calibratedWhite: 1.0, alpha: 1), ending: NSColor(calibratedWhite: 0.93, alpha: 1)
)?.draw(in: NSRect(origin: .zero, size: size), angle: 90)

// 矢印（アイコンの中心 y = 190。アイコン 128 pt の端から少し離す）
let arrowColor = NSColor(calibratedWhite: 0.55, alpha: 1)
arrowColor.setStroke()
arrowColor.setFill()
let shaft = NSBezierPath()
shaft.lineWidth = 6
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 262, y: 190))
shaft.line(to: NSPoint(x: 382, y: 190))
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 402, y: 190))
head.line(to: NSPoint(x: 376, y: 172))
head.line(to: NSPoint(x: 376, y: 208))
head.close()
head.fill()

// 案内（アイコンの名前の下）
func draw(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    // 文字は反転した座標のままだと上下が逆になるので、その行だけ戻して描く
    NSGraphicsContext.saveGraphicsState()
    let unflip = NSAffineTransform()
    unflip.translateX(by: 0, yBy: y)
    unflip.scaleX(by: 1, yBy: -1)
    unflip.translateX(by: 0, yBy: -y)
    unflip.concat()
    NSAttributedString(string: text, attributes: attributes)
        .draw(in: NSRect(x: 0, y: y - font.pointSize * 1.3, width: size.width, height: font.pointSize * 1.6))
    NSGraphicsContext.restoreGraphicsState()
}
draw(
    "VoiceDock を Applications フォルダへドラッグしてください", y: 318,
    font: .systemFont(ofSize: 17, weight: .semibold), color: NSColor(calibratedWhite: 0.2, alpha: 1))
draw(
    "コピーが終わったら、この窓を閉じてディスクイメージを取り出してください", y: 350,
    font: .systemFont(ofSize: 12), color: NSColor(calibratedWhite: 0.45, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: arguments[1]))
} catch {
    FileHandle.standardError.write(Data("書けません: \(error)\n".utf8))
    exit(1)
}
