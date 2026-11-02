import AppKit

extension Notification.Name {
    /// Favorites were added on the start page or with ⌘D.
    static let rookFavoritesChanged = Notification.Name("RookFavoritesChanged")
}

/// The favorites bar like in Safari: a quiet row of names under the toolbar. A click opens the page,
/// ⌘-click or the middle button in a new tab. What does not fit goes into a » menu at the right.
/// The favorites themselves live on the start page; the bar shows what it last reported plus new ones.
final class FavoritesBar: NSView {
    static let height: CGFloat = 28
    /// Opens a favorite: in the current tab, or in a new tab when `newTab` is true.
    var open: ((URL, _ newTab: Bool) -> Void)?
    private var buttons: [FavoriteButton] = []
    private let overflowButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "Favoriten mit ⌘D hinzufügen")

    override init(frame: NSRect) {
        super.init(frame: frame)
        overflowButton.image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: "Weitere Favoriten")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        overflowButton.isBordered = false
        overflowButton.contentTintColor = .secondaryLabelColor
        overflowButton.target = self
        overflowButton.action = #selector(showOverflow)
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        [overflowButton, emptyLabel].forEach(addSubview)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Favoriten")
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .rookFavoritesChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Favorites in the order of the start page, new ones (not yet taken over by it) at the end.
    static var items: [Favorites.Item] {
        var seen = Set<String>()
        return (Favorites.known + Favorites.pending).filter { seen.insert($0.url).inserted }
    }

    @objc func reload() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = Self.items.compactMap { item in
            guard let url = URL(string: item.url) else { return nil }
            let button = FavoriteButton(name: item.name, url: url)
            button.bar = self
            addSubview(button)
            return button
        }
        emptyLabel.isHidden = !buttons.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8, gap: CGFloat = 2, h: CGFloat = 22, y = (bounds.height - h) / 2
        let overflowWidth: CGFloat = 26
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(x: inset + 6, y: (bounds.height - emptyLabel.frame.height) / 2)
        var x = inset
        var overflow = false
        for (i, button) in buttons.enumerated() {
            let w = min(160, button.intrinsicContentSize.width)
            // Keep room for the » button unless this is the very last favorite.
            let limit = bounds.width - inset - (i == buttons.count - 1 ? 0 : overflowWidth)
            if overflow || x + w > limit {
                overflow = true
                button.isHidden = true
                continue
            }
            button.isHidden = false
            button.frame = NSRect(x: x, y: y, width: w, height: h)
            x += w + gap
        }
        overflowButton.isHidden = !overflow
        overflowButton.frame = NSRect(x: bounds.width - inset - overflowWidth, y: y, width: overflowWidth, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func showOverflow() {
        let menu = NSMenu()
        for button in buttons where button.isHidden {
            let url = button.url
            menu.addItem(ClosureMenuItem(title: button.title) { [weak self] in self?.open?(url, false) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.height + 4), in: overflowButton)
    }

    fileprivate func menu(for button: FavoriteButton) -> NSMenu {
        let menu = NSMenu()
        let url = button.url
        menu.addItem(ClosureMenuItem(title: "Öffnen") { [weak self] in self?.open?(url, false) })
        menu.addItem(ClosureMenuItem(title: "In neuem Tab öffnen") { [weak self] in self?.open?(url, true) })
        menu.addItem(ClosureMenuItem(title: "Adresse kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        })
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Bearbeiten auf der Startseite", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        return menu
    }
}

/// One favorite in the bar: its name, a soft highlight under the pointer.
private final class FavoriteButton: NSButton {
    weak var bar: FavoritesBar?
    let url: URL

    init(name: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        title = name.isEmpty ? (url.host ?? url.absoluteString) : name
        font = .systemFont(ofSize: 12)
        isBordered = false
        lineBreakMode = .byTruncatingTail
        contentTintColor = .labelColor
        toolTip = url.absoluteString
        target = self
        action = #selector(clicked)
        wantsLayer = true
        layer?.cornerRadius = 6
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 16, height: size.height)
    }

    @objc private func clicked() {
        bar?.open?(url, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { bar?.open?(url, true) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: self) }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ on: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = on ? (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)).cgColor : nil
    }
}
