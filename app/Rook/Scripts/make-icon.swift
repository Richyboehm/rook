// Zeichnet aus dem Rook-Raben (Scripts/raven.png, schwarze Linien auf transparent) die Icons von Rook:
//   AppIcon.png                   1024 × 1024, weißer Rabe auf schwarzem Icon (Rook ist umgekehrt)
//   MenuBarIcon.png / @2x.png     18 pt, der Rabenkopf als gefüllte Silhouette
// Aufruf:
//   swift Scripts/make-icon.swift Scripts/raven.png Resources
//   mkdir AppIcon.iconset; für 16 32 128 256 512 je icon_NxN.png und @2x mit sips aus AppIcon.png,
//   dann iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let source = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let out = CommandLine.arguments[2]
let n = source.pixelsWide
func lineAlpha(_ p: Int) -> UInt8 { source.bitmapData![p * 4 + 3] }

func mask(_ value: (Int) -> UInt8) -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32)!
    for p in 0..<(n * n) {
        rep.bitmapData![p * 4] = 0; rep.bitmapData![p * 4 + 1] = 0; rep.bitmapData![p * 4 + 2] = 0
        rep.bitmapData![p * 4 + 3] = value(p)
    }
    let image = NSImage(size: NSSize(width: n, height: n))
    image.addRepresentation(rep)
    return image
}
func tinted(_ image: NSImage, _ color: NSColor, in rect: NSRect) {
    let copy = NSImage(size: rect.size)
    copy.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: rect.size))
    color.set()
    NSRect(origin: .zero, size: rect.size).fill(using: .sourceIn)
    copy.unlockFocus()
    copy.draw(in: rect)
}
func save(_ image: NSImage, pixels: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}

// Menüleiste: Außenbereich per Flutfüllung vom Rand; was übrig bleibt, ist der gefüllte Kopf.
var outside = [Bool](repeating: false, count: n * n)
var stack = [Int]()
for i in 0..<n { stack += [i, (n - 1) * n + i, i * n, i * n + n - 1] }
while let p = stack.popLast() {
    if outside[p] || lineAlpha(p) > 110 { continue }
    outside[p] = true
    let x = p % n, y = p / n
    if x > 0 { stack.append(p - 1) }; if x < n - 1 { stack.append(p + 1) }
    if y > 0 { stack.append(p - n) }; if y < n - 1 { stack.append(p + n) }
}
let menuBar = mask { outside[$0] ? 0 : 255 }
let menuImage = NSImage(size: NSSize(width: 18, height: 18))
menuImage.lockFocus()
menuBar.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
menuImage.unlockFocus()
save(menuImage, pixels: 18, "MenuBarIcon.png")
save(menuImage, pixels: 36, "MenuBarIcon@2x.png")

// App-Icon: macOS-Icons lassen rundherum Rand; der Körper ist 824 groß mit runden Ecken.
let size: CGFloat = 1024
let icon = NSImage(size: NSSize(width: size, height: size))
icon.lockFocus()
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
shadow.shadowBlurRadius = 22
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.set()
NSColor(white: 0.07, alpha: 1).setFill()
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()
NSGraphicsContext.restoreGraphicsState()
tinted(mask(lineAlpha), .white, in: body.insetBy(dx: body.width * 0.17, dy: body.width * 0.17))
icon.unlockFocus()
save(icon, pixels: 1024, "AppIcon.png")
