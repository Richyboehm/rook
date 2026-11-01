// Zeichnet das App-Icon (1024 × 1024): weißes Icon, darauf ein schwarz umrandeter
// Block mit versetzter Kante und „ry“.
// Aufruf: swift Scripts/make-icon.swift Ziel.png
import AppKit

let size: CGFloat = 1024
let ink = NSColor(white: 0.06, alpha: 1)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS-Icons lassen rundherum Rand; der Körper ist 824 groß mit runden Ecken.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
shadow.shadowBlurRadius = 22
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.set()
NSColor.white.setFill()
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()
NSGraphicsContext.restoreGraphicsState()

// Block in einem 100er-Raster innerhalb des Körpers
let u = body.width * 0.72 / 100
let o = NSPoint(x: body.minX + body.width * 0.14, y: body.minY + body.width * 0.14)
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: o.x + x * u, y: o.y + y * u, width: w * u, height: h * u)
}

ink.setFill()
NSBezierPath(roundedRect: rect(24, 16, 60, 60), xRadius: 12 * u, yRadius: 12 * u).fill()
let front = NSBezierPath(roundedRect: rect(16, 24, 60, 60), xRadius: 12 * u, yRadius: 12 * u)
NSColor.white.setFill()
front.fill()
front.lineWidth = 6 * u
ink.setStroke()
front.stroke()

let text = NSAttributedString(string: "ry", attributes: [
    .font: NSFont.systemFont(ofSize: 34 * u, weight: .heavy),
    .foregroundColor: ink,
    .kern: -1 * u,
])
let textSize = text.size()
// Das „y“ hat eine Unterlänge; etwas anheben, damit es optisch mittig sitzt.
text.draw(at: NSPoint(x: o.x + 46 * u - textSize.width / 2, y: o.y + 54 * u - textSize.height / 2 + 5 * u))

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
