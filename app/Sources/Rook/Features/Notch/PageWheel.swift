import AppKit
import SwiftUI

/// Das Seiten-Rad der aufgeklappten Notch. Die Seiten hängen auf einem Kreis, dessen Mitte
/// etwa 15 cm über der Notch liegt. Beim Wischen dreht das Rad direkt mit den Fingern; beim
/// Loslassen zieht eine Feder es auf die nächste Seite oder zurück.
///
/// Alles hier läuft an SwiftUI vorbei: Die Seiten sind fertig gebaut, pro Fingerbewegung bzw.
/// pro Bild ändern sich nur Drehung und Deckkraft ihrer Ebenen (Core Animation).
@MainActor
final class PageWheel {
    /// Abstand der Kreismitte über den Seiten, in Punkten (auf dem MacBook rund 15 cm).
    static let pivot: CGFloat = 750
    /// Abstand von einer Seite zur nächsten, gemessen auf dem Kreis.
    static let spacing: CGFloat = 470

    private(set) var page: IslandModel.Page = .main
    /// Versatz in Punkten; negativ, wenn nach links gedreht.
    private(set) var offset: CGFloat = 0
    private var velocity: CGFloat = 0
    private(set) var settling = false
    weak var view: PageWheelView?
    /// Meldet eine neue Seite an das Modell (Punkte, Tastatur).
    var onPageChange: ((IslandModel.Page) -> Void)?

    var turning: Bool { offset != 0 || settling }

    /// Finger bewegt sich (negativ = nach links).
    func drag(by delta: CGFloat) {
        view?.stopSpring()
        settling = false
        offset += delta
        view?.apply()
    }

    /// Finger losgelassen: weit genug oder mit Schwung gewischt, dann eine Seite weiter,
    /// sonst zurück. `flick` ist die letzte Bewegung und gibt der Feder ihren Schwung mit.
    func end(flick: CGFloat) {
        var step = 0
        if offset < -Self.spacing * 0.22 || (flick < -6 && offset < 0) { step = 1 }
        if offset > Self.spacing * 0.22 || (flick > 6 && offset > 0) { step = -1 }
        turn(by: step, velocity: flick * 60)
    }

    /// Klick auf einen Punkt: auf kürzestem Weg dorthin drehen.
    func show(_ target: IslandModel.Page) {
        let count = IslandModel.Page.allCases.count
        var step = (target.rawValue - page.rawValue + count) % count
        if step > count / 2 { step -= count }
        guard step != 0 else { return }
        turn(by: step, velocity: 0)
    }

    /// Zugeklappt: ohne Animation zurück auf die normale Seite.
    func reset() {
        view?.stopSpring()
        settling = false
        offset = 0
        velocity = 0
        if page != .main {
            page = .main
            onPageChange?(.main)
        }
        view?.apply()
        view?.settled()
    }

    private func turn(by step: Int, velocity: CGFloat) {
        let count = IslandModel.Page.allCases.count
        if step != 0 {
            // Neue Seite, ohne dass etwas springt: Der Versatz gleicht die gedrehten Plätze aus.
            page = IslandModel.Page(rawValue: ((page.rawValue + step) % count + count) % count) ?? .main
            offset += CGFloat(step) * Self.spacing
            onPageChange?(page)
        }
        self.velocity = velocity
        settling = true
        view?.apply()
        view?.startSpring()
    }

    /// Ein Schritt der Feder; `false`, sobald das Rad ruht.
    func springStep(_ dt: CGFloat) -> Bool {
        let stiffness: CGFloat = 190, damping: CGFloat = 26
        velocity += (-stiffness * offset - damping * velocity) * dt
        offset += velocity * dt
        if abs(offset) < 0.4 && abs(velocity) < 8 {
            offset = 0
            velocity = 0
            settling = false
            return false
        }
        return true
    }
}

// MARK: - Ansicht

/// Hält jede Seite in einem eigenen Hosting-Controller und dreht deren Ebenen.
final class PageWheelView: NSView {
    private let wheel: PageWheel
    private var hosts: [IslandModel.Page: NSHostingController<AnyView>] = [:]
    private var heights: [IslandModel.Page: CGFloat] = [:]
    private var sizeObservers: [NSKeyValueObservation] = []
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    /// Höhe des Rads: Alle Seiten sind so hoch wie die höchste, damit die Notch beim Drehen
    /// ihre Größe nicht ändert.
    private(set) var restingHeight: CGFloat = 0
    private var visiblePages: Set<IslandModel.Page> = []

    override var isFlipped: Bool { true }

    init(wheel: PageWheel) {
        self.wheel = wheel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        wheel.view = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Neue Inhalte von SwiftUI (nur, wenn sich wirklich Daten ändern, nicht beim Drehen).
    func setPages(_ pages: [IslandModel.Page: AnyView]) {
        for (page, content) in pages {
            if let host = hosts[page] {
                host.rootView = content
            } else {
                let host = NSHostingController(rootView: content)
                host.sizingOptions = .preferredContentSize
                host.view.wantsLayer = true
                host.view.isHidden = page != wheel.page
                addSubview(host.view)
                hosts[page] = host
                // Wird eine Seite höher oder niedriger (z. B. Ablage erscheint), neu messen.
                sizeObservers.append(host.observe(\.preferredContentSize) { [weak self] _, _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.measure() } }
                })
            }
        }
        measure()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: restingHeight)
    }

    private var pageWidth: CGFloat { bounds.width > 0 ? bounds.width : IslandModel.expandedWidth - 40 }

    private func measure() {
        for (page, host) in hosts {
            heights[page] = host.sizeThatFits(in: CGSize(width: pageWidth, height: 10_000)).height.rounded(.up)
        }
        needsLayout = true
        updateRestingHeight()
    }

    private func updateRestingHeight() {
        let height = heights.values.max() ?? 0
        guard abs(height - restingHeight) > 0.5 else { return }
        restingHeight = height
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        for (page, host) in hosts {
            host.view.frame = NSRect(x: 0, y: 0, width: bounds.width, height: heights[page] ?? bounds.height)
        }
        apply()
    }

    /// Nur die aktuelle Seite reagiert auf Klicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let host = hosts[wheel.page], !host.view.isHidden else { return nil }
        return host.view.hitTest(convert(point, to: host.view.superview))
    }

    /// Stellt jede Seite auf ihren Platz am Kreis.
    func apply() {
        let pages = IslandModel.Page.allCases
        let count = pages.count
        var visibleNow: Set<IslandModel.Page> = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (page, host) in hosts {
            var relative = (page.rawValue - wheel.page.rawValue + count) % count
            if relative > count / 2 || (count % 2 == 0 && relative == count / 2 && wheel.offset > 0) { relative -= count }
            let position = CGFloat(relative) * PageWheel.spacing + wheel.offset
            let visible = page == wheel.page || (wheel.turning && abs(position) < PageWheel.spacing * 1.5)
            if host.view.isHidden == visible { host.view.isHidden = !visible }
            guard visible, let layer = host.view.layer else { continue }
            visibleNow.insert(page)
            layer.setAffineTransform(orbit(position, layer: layer))
            layer.opacity = Float(1 - min(abs(position) / PageWheel.spacing, 1) * 0.7)
        }
        CATransaction.commit()
        // Kommt eine Seite ins Bild (oder geht), Höhe einmal anpassen, damit nichts abgeschnitten ist.
        if visibleNow != visiblePages {
            visiblePages = visibleNow
            updateRestingHeight()
        }
    }

    /// Bewegung auf dem Kreis: Mitte der Seite wandert auf dem Bogen, die Seite neigt sich mit.
    private func orbit(_ position: CGFloat, layer: CALayer) -> CGAffineTransform {
        guard position != 0 else { return .identity }
        let theta = position / PageWheel.pivot
        let size = layer.bounds.size
        let radius = PageWheel.pivot + size.height / 2
        // Verschiebung der Seitenmitte (y nach unten): zur Seite und etwas nach oben.
        let dx = radius * sin(theta)
        let dy = radius * (cos(theta) - 1)
        let rotation = CGAffineTransform(rotationAngle: -theta)
        // Die Ebene dreht um ihren Ankerpunkt; so verrechnen, dass sie um ihre Mitte dreht.
        let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        let toCenter = CGPoint(x: size.width / 2 - anchor.x, y: size.height / 2 - anchor.y)
        let turned = toCenter.applying(rotation)
        return rotation.concatenating(CGAffineTransform(translationX: dx + toCenter.x - turned.x,
                                                        y: dy + toCenter.y - turned.y))
    }

    // MARK: Feder, im Takt des Bildschirms

    func startSpring() {
        guard link == nil else { return }
        lastFrame = 0
        let link = displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stopSpring() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrame == 0 ? 1.0 / 120 : min(now - lastFrame, 1.0 / 30)
        lastFrame = now
        let moving = wheel.springStep(CGFloat(dt))
        apply()
        if !moving {
            stopSpring()
            settled()
        }
    }

    /// Rad steht: Nachbarn ausblenden, Höhe der neuen Seite übernehmen.
    func settled() {
        apply()
        updateRestingHeight()
    }
}

/// SwiftUI-Hülle für das Rad.
struct PageWheelHost: NSViewRepresentable {
    let wheel: PageWheel
    let pages: [IslandModel.Page: AnyView]

    func makeNSView(context: Context) -> PageWheelView { PageWheelView(wheel: wheel) }

    func updateNSView(_ view: PageWheelView, context: Context) { view.setPages(pages) }
}
