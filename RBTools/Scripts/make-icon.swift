// Zeichnet das App-Icon (1024 × 1024) im Stil der Notizen-App: weißes Papier,
// gelber Streifen oben, darauf „RB“ in klarer Schrift.
// Aufruf: swift Scripts/make-icon.swift Ziel.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS-Icons lassen rundherum Rand; der Körper ist 824 groß mit runden Ecken.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Leichter Schatten unter dem Blatt
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Papier mit ganz leichtem Verlauf
shape.addClip()
NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.94, alpha: 1))!.draw(in: body, angle: -90)

// Gelber Streifen oben
let bandHeight: CGFloat = 190
let band = NSRect(x: body.minX, y: body.maxY - bandHeight, width: body.width, height: bandHeight)
NSGradient(starting: NSColor(red: 1.0, green: 0.84, blue: 0.20, alpha: 1),
           ending: NSColor(red: 0.98, green: 0.74, blue: 0.10, alpha: 1))!.draw(in: band, angle: -90)

// Feine Perforation unter dem Streifen
NSColor(white: 0.80, alpha: 1).setFill()
var x = body.minX + 40
while x < body.maxX - 30 {
    NSBezierPath(ovalIn: NSRect(x: x, y: band.minY - 20, width: 9, height: 9)).fill()
    x += 30
}

// Linien wie auf Notizpapier
NSColor(white: 0.88, alpha: 1).setFill()
for y in stride(from: body.minY + 150, to: band.minY - 80, by: 110) {
    NSBezierPath(rect: NSRect(x: body.minX + 70, y: y, width: body.width - 140, height: 5)).fill()
}

// „RB“
let font = NSFont.systemFont(ofSize: 330, weight: .bold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(white: 0.16, alpha: 1),
    .kern: -8,
]
let text = NSAttributedString(string: "RB", attributes: attributes)
let textSize = text.size()
let paperMidY = (body.minY + band.minY) / 2
text.draw(at: NSPoint(x: body.midX - textSize.width / 2, y: paperMidY - textSize.height / 2 + 10))

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
