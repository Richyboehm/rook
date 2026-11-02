import AppKit
import Combine
import SwiftUI

/// Rahmenloses Fenster, das den Fokus nur nimmt, solange die Schnellnotiz offen ist.
final class IslandPanel: NSPanel {
    var allowsKeyboard = false
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// Hält die SwiftUI-Insel und erkennt die Maus über eine Tracking-Area: Eintreten zählt
/// nur direkt an der Notch, Verlassen erst außerhalb der großen Insel. Das System
/// meldet nur Ein- und Austritt, es wird keine Mausbewegung mitverfolgt.
/// Außerdem nimmt es Dateien an, die auf die Notch gezogen werden.
final class IslandContainer: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onDragChange: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var hotZone: NSRect = .zero { didSet { if hotZone != oldValue { updateTrackingAreas() } } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: hotZone, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragChange?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop?(urls)
        onDragChange?(false)
        return !urls.isEmpty
    }
}
