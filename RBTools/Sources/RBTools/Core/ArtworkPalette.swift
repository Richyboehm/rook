import AppKit
import SwiftUI

/// Die zwei prägenden Farben eines Covers für Leuchten und Glas-Tönung.
struct ArtworkPalette: Equatable {
    var primary: Color
    var secondary: Color

    static let neutral = ArtworkPalette(primary: .white.opacity(0.25), secondary: .white.opacity(0.15))

    /// Wird einmal pro Song im Hintergrund berechnet: Das Cover wird auf 16 × 16 Pixel
    /// verkleinert, die Pixel werden nach Farbton sortiert und nach Kräftigkeit gewichtet.
    static func from(_ image: NSImage) -> ArtworkPalette? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }

        struct Bin { var r = 0.0, g = 0.0, b = 0.0, weight = 0.0, hue = 0.0 }
        let binCount = 12
        var bins = [Bin](repeating: Bin(), count: binCount)
        var average = Bin()

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            average.r += r; average.g += g; average.b += b; average.weight += 1

            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.2, brightness > 0.25 else { continue } // Grau, Schwarz, Weiß zählen nicht
            let weight = Double(saturation * brightness * brightness)
            let index = min(Int(hue * CGFloat(binCount)), binCount - 1)
            bins[index].r += r * weight
            bins[index].g += g * weight
            bins[index].b += b * weight
            bins[index].weight += weight
            bins[index].hue = Double(index)
        }

        func color(_ bin: Bin) -> Color {
            let ns = NSColor(srgbRed: bin.r / bin.weight, green: bin.g / bin.weight, blue: bin.b / bin.weight, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            ns.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            // Etwas aufhellen und sättigen, damit es auf dem dunklen Sperrbildschirm leuchtet.
            return Color(hue: hue, saturation: min(saturation * 1.15, 1), brightness: max(brightness, 0.7))
        }

        let ranked = bins.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard let first = ranked.first, first.weight > 1.5 else {
            // Kaum Farbe im Cover (z. B. schwarz-weiß): dezent in der Durchschnittsfarbe.
            let grey = color(average).opacity(0.35)
            return ArtworkPalette(primary: grey, secondary: grey)
        }
        // Zweite Farbe: kräftigster Ton, der sich deutlich vom ersten unterscheidet.
        let second = ranked.dropFirst().first { bin in
            let distance = abs(bin.hue - first.hue)
            return min(distance, Double(binCount) - distance) >= 2 && bin.weight > first.weight * 0.12
        }
        return ArtworkPalette(primary: color(first), secondary: color(second ?? first))
    }
}
