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
    /// Gerade wird eine Datei über die Insel gezogen (zwischen Eintreten und Verlassen bzw. Ablegen).
    private(set) var dragInside = false

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
        dragInside = true
        onDragChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragInside = false
        onDragChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragInside = false
        let urls = Self.fileURLs(sender)
        onDrop?(urls)
        onDragChange?(false)
        return !urls.isEmpty
    }

    static func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// Die unsichtbare Notch auf Bildschirmen ohne echte Notch (z. B. ein externer Monitor):
/// ein paar Punkte hoher Streifen oben in der Mitte, so breit wie die Notch des MacBooks.
/// Zu sehen ist nichts; kommt die Maus (oder eine gezogene Datei) dorthin, klappt die Insel
/// auf diesem Bildschirm auf.
final class NotchTrigger: NSPanel {
    static let height: CGFloat = 3

    let displayID: CGDirectDisplayID
    private let zone = TriggerView()

    var onEnter: (() -> Void)? {
        get { zone.onEnter }
        set { zone.onEnter = newValue }
    }
    var onDragEnter: (() -> Void)? {
        get { zone.onDragEnter }
        set { zone.onDragEnter = newValue }
    }
    var onDragExit: (() -> Void)? {
        get { zone.onDragExit }
        set { zone.onDragExit = newValue }
    }
    var onDrop: (([URL]) -> Void)? {
        get { zone.onDrop }
        set { zone.onDrop = newValue }
    }

    init(displayID: CGDirectDisplayID, level: NSWindow.Level) {
        self.displayID = displayID
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        // Ganz durchsichtige Fenster lässt macOS von der Maus durchfallen; 1 % Schwarz auf
        // 3 Punkten ist nicht zu sehen, fängt die Maus aber.
        backgroundColor = NSColor.black.withAlphaComponent(0.01)
        hasShadow = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        contentView = zone
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Dateien annehmen nur, wenn die Ablage an ist.
    func acceptsFiles(_ on: Bool) {
        if on { zone.registerForDraggedTypes([.fileURL]) } else { zone.unregisterDraggedTypes() }
    }

    /// Oben mittig auf den Bildschirm setzen.
    func place(on screen: NSScreen, width: CGFloat) {
        setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - Self.height,
                        width: width, height: Self.height), display: false)
        orderFrontRegardless()
    }
}

private final class TriggerView: NSView {
    var onEnter: (() -> Void)?
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = IslandContainer.fileURLs(sender)
        onDrop?(urls)
        onDragExit?()
        return !urls.isEmpty
    }
}
