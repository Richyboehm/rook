import AppKit

protocol TabBarDelegate: AnyObject {
    var tabs: [BrowserTab] { get }
    var selectedIndex: Int { get }
    var isPrivate: Bool { get }
    func selectTab(at index: Int)
    func closeTab(at index: Int)
    func moveTab(from: Int, to: Int)
    func menuForTab(at index: Int) -> NSMenu
    func newTab()
    /// A tab was dragged out of the bar; true when it landed on a tab group in the sidebar.
    func dropTab(at index: Int, windowPoint: NSPoint) -> Bool
    /// While dragging: highlight the group under the pointer.
    func dragTab(over windowPoint: NSPoint)
}

/// Rook's own tab bar: a glass strip under the toolbar. Pinned tabs are small icons on the left,
/// normal tabs share the remaining width. Tabs can be dragged to reorder.
final class TabBarView: NSVisualEffectView {
    weak var delegate: TabBarDelegate?
    private var items: [TabItemView] = []
    private let plusButton = NSButton()
    /// The card with the address that appears while the pointer rests on a tab.
    let card = TabHoverCard()
    static let height: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Neuer Tab")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        plusButton.isBordered = false
        plusButton.wantsLayer = true
        plusButton.layer?.cornerRadius = 8
        plusButton.toolTip = "Neuer Tab (⌘T)"
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.target = self
        plusButton.action = #selector(plusClicked)
        addSubview(plusButton)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func plusClicked() { delegate?.newTab() }

    func reload() {
        guard let delegate else { return }
        let tabs = delegate.tabs
        while items.count < tabs.count {
            let item = TabItemView()
            item.bar = self
            addSubview(item)
            items.append(item)
        }
        while items.count > tabs.count { items.removeLast().removeFromSuperview() }
        for (i, tab) in tabs.enumerated() {
            items[i].update(index: i, tab: tab, selected: i == delegate.selectedIndex, isPrivate: delegate.isPrivate)
        }
        card.refresh()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let tabs = delegate?.tabs else { return }
        // The "+" gets a large click area and always keeps distance to the right edge
        // (where the downloads button sits in the toolbar above).
        let inset: CGFloat = 8, gap: CGFloat = 4, pinnedWidth: CGFloat = 40, plusWidth: CGFloat = 34, rightReserve: CGFloat = 56
        let pinnedCount = CGFloat(tabs.filter(\.isPinned).count)
        let normalCount = CGFloat(tabs.count) - pinnedCount
        let available = bounds.width - inset - rightReserve - plusWidth - gap - pinnedCount * (pinnedWidth + gap)
        let normalWidth = normalCount > 0 ? min(240, max(60, (available - gap * normalCount) / normalCount)) : 0
        var x = inset
        let y: CGFloat = 4, h = bounds.height - 8
        // The list of tabs can be shorter for a moment (while a window closes); never read past its end.
        for (i, item) in items.enumerated() where i < tabs.count && !item.isDragging {
            let w = tabs[i].isPinned ? pinnedWidth : normalWidth
            item.frame = NSRect(x: x, y: y, width: w, height: h)
            x += w + gap
        }
        plusButton.frame = NSRect(x: min(x + 2, bounds.width - plusWidth - rightReserve), y: y, width: plusWidth, height: h)
        // A thin line at the bottom separates the bar from the page.
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Where a dragged tab would land.
    func index(forDragAt x: CGFloat, from index: Int) -> Int {
        var target = index
        for (i, item) in items.enumerated() where i != index && !item.isDragging {
            if x > item.frame.midX && i > index { target = i }
            if x < item.frame.midX && i < index { target = min(target, i) }
        }
        return target
    }

    fileprivate func dragFinished(from: Int, to: Int) {
        if from != to { delegate?.moveTab(from: from, to: to) } else { needsLayout = true }
    }
}

final class TabItemView: NSView {
    weak var bar: TabBarView?
    private(set) var index = 0
    private(set) var isDragging = false
    private var isSelected = false
    private var isPinned = false
    private var isPrivate = false
    private var isHovered = false
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// Speaker while the page plays sound; a click mutes the tab.
    private let audioButton = NSButton()
    private var dragStart: NSPoint?
    private var dragOffset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Tab schließen")
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        audioButton.isBordered = false
        audioButton.imageScaling = .scaleProportionallyDown
        audioButton.target = self
        audioButton.action = #selector(audioClicked)
        audioButton.isHidden = true
        [icon, label, closeButton, audioButton].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(index: Int, tab: BrowserTab, selected: Bool, isPrivate: Bool) {
        self.index = index
        isSelected = selected
        isPinned = tab.isPinned
        self.isPrivate = isPrivate
        let title = tab.title
        if tab.isUsingCameraOrMicrophone {
            let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemRed])
            text.append(NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.labelColor]))
            label.attributedStringValue = text
        } else {
            label.stringValue = title
            label.textColor = selected ? .labelColor : .secondaryLabelColor
        }
        icon.image = tab.favicon ?? NSImage(systemSymbolName: tab.isStartPage ? "house" : "globe", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        let showsAudio = tab.isPlayingAudio || tab.isMuted
        audioButton.isHidden = !showsAudio
        if showsAudio {
            let symbol = tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            let name = tab.isMuted ? "Ton wieder einschalten" : "Tab stummschalten"
            audioButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            audioButton.toolTip = name
            audioButton.contentTintColor = tab.isMuted ? .tertiaryLabelColor : .secondaryLabelColor
        }
        setAccessibilityLabel(title)
        setAccessibilityValue(selected)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        if isPinned {
            icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (h - 16) / 2, width: 16, height: 16)
            label.isHidden = true
            closeButton.isHidden = true
            audioButton.frame = NSRect(x: bounds.width - 14, y: h - 14, width: 12, height: 12)
            return
        }
        label.isHidden = false
        let showClose = isHovered || isSelected
        closeButton.isHidden = !showClose
        closeButton.frame = NSRect(x: 6, y: (h - 16) / 2, width: 16, height: 16)
        icon.frame = NSRect(x: showClose ? 26 : 10, y: (h - 16) / 2, width: 16, height: 16)
        let textX = icon.frame.maxX + 6
        let right: CGFloat = audioButton.isHidden ? 8 : 30
        audioButton.frame = NSRect(x: bounds.width - 26, y: (h - 16) / 2, width: 18, height: 16)
        label.frame = NSRect(x: textX, y: (h - 16) / 2, width: max(0, bounds.width - textX - right), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isSelected {
            let base = isPrivate ? NSColor.systemPurple.withAlphaComponent(0.28)
                                 : (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.9))
            base.setFill()
            path.fill()
            (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isHovered {
            (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.05)).setFill()
            path.fill()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsLayout = true
        needsDisplay = true
        bar?.card.pointerEntered(self)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsLayout = true
        needsDisplay = true
        bar?.card.pointerLeft()
    }

    /// The tab this view shows right now.
    var tab: BrowserTab? {
        guard let tabs = bar?.delegate?.tabs, tabs.indices.contains(index) else { return nil }
        return tabs[index]
    }

    @objc private func closeClicked() {
        bar?.card.hide()
        bar?.delegate?.closeTab(at: index)
    }

    @objc private func audioClicked() { tab?.toggleMute() }

    override func mouseDown(with event: NSEvent) {
        bar?.card.hide()
        bar?.delegate?.selectTab(at: index)
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let bar, let start = dragStart else { return }
        let point = bar.convert(event.locationInWindow, from: nil)
        if !isDragging {
            guard abs(convert(event.locationInWindow, from: nil).x - start.x) > 4 else { return }
            isDragging = true
            dragOffset = start.x
            layer?.zPosition = 10
        }
        frame.origin.x = min(max(0, point.x - dragOffset), bar.bounds.width - frame.width)
        bar.delegate?.dragTab(over: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard isDragging, let bar else { return }
        isDragging = false
        layer?.zPosition = 0
        if bar.delegate?.dropTab(at: index, windowPoint: event.locationInWindow) == true {
            bar.reload()
            return
        }
        bar.dragFinished(from: index, to: bar.index(forDragAt: frame.midX, from: index))
    }

    /// Middle click closes the tab, like in other browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { bar?.delegate?.closeTab(at: index) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        bar?.card.hide()
        return bar?.delegate?.menuForTab(at: index)
    }
}

/// The card under a tab while the pointer rests on it, like in Chrome: the page title and its full
/// address as text that can be selected and copied. Next to the address one button copies it in a
/// click and "…" opens the tab's menu. Moving from tab to tab while it is open switches at once.
final class TabHoverCard: NSPanel {
    private static let width: CGFloat = 300
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let addressField = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private let moreButton = NSButton()
    private weak var item: TabItemView?
    private var url: URL?
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var pointerInside = false
    private var menuOpen = false
    private var hiddenAt = Date.distantPast

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: nil))
        contentView = background

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.isSelectable = false
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = Self.width - 24

        addressField.font = .systemFont(ofSize: 11)
        addressField.textColor = .secondaryLabelColor
        addressField.isSelectable = true
        addressField.maximumNumberOfLines = 3
        addressField.lineBreakMode = .byCharWrapping
        addressField.preferredMaxLayoutWidth = Self.width - 24 - 2 * 22 - 8
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.setAccessibilityLabel("Adresse")

        for (button, symbol, name, action) in [(copyButton, "doc.on.doc", "Adresse kopieren", #selector(copyClicked)),
                                               (moreButton, "ellipsis.circle", "Weitere Aktionen", #selector(moreClicked))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            button.toolTip = name
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }

        let addressRow = NSStackView(views: [addressField, copyButton, moreButton])
        addressRow.alignment = .centerY
        addressRow.spacing = 4
        let stack = NSStackView(views: [titleLabel, addressRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            addressRow.widthAnchor.constraint(equalToConstant: Self.width - 24),
        ])
    }

    // Becomes key only when the address is clicked, so its text can be selected.
    override var canBecomeKey: Bool { true }

    // MARK: Showing and hiding

    func pointerEntered(_ item: TabItemView) {
        hideTimer?.invalidate()
        showTimer?.invalidate()
        // Once a card is open, gliding over the other tabs follows without waiting again.
        if isVisible || Date().timeIntervalSince(hiddenAt) < 0.4 {
            show(for: item)
        } else {
            showTimer = .scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self, weak item] _ in
                guard let self, let item else { return }
                self.show(for: item)
            }
        }
    }

    func pointerLeft() {
        showTimer?.invalidate()
        scheduleHide()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        hideTimer?.invalidate()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        // A short grace time to move the pointer from the tab down into the card.
        hideTimer = .scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, !self.pointerInside, !self.menuOpen else { return }
            self.hide()
        }
    }

    func hide() {
        showTimer?.invalidate()
        hideTimer?.invalidate()
        guard isVisible else { return }
        let owner = parent
        let wasKey = isKeyWindow
        owner?.removeChildWindow(self)
        orderOut(nil)
        hiddenAt = Date()
        item = nil
        pointerInside = false
        if wasKey { owner?.makeKey() }
    }

    /// The tabs changed (title loaded, tab closed): update or close the card.
    func refresh() {
        guard isVisible else { return }
        if let item, item.superview != nil, item.tab != nil { fill(from: item) } else { hide() }
    }

    private func show(for item: TabItemView) {
        guard let window = item.window, !item.isDragging, fill(from: item) else { hide(); return }
        self.item = item
        let size = contentView?.fittingSize ?? frame.size
        let tabRect = window.convertToScreen(item.convert(item.bounds, to: nil))
        var origin = NSPoint(x: tabRect.minX, y: tabRect.minY - 4 - size.height)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        guard !isVisible || parent !== window else { return }
        parent?.removeChildWindow(self)
        alphaValue = 0
        window.addChildWindow(self, ordered: .above)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    /// Puts the tab's title and address into the card; false for tabs without an address (new tab).
    @discardableResult
    private func fill(from item: TabItemView) -> Bool {
        guard let tab = item.tab, let url = tab.displayURL else { return false }
        if url != self.url { copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Adresse kopieren") }
        self.url = url
        titleLabel.stringValue = tab.title
        addressField.stringValue = url.absoluteString
        contentView?.layoutSubtreeIfNeeded()
        return true
    }

    // MARK: Actions

    @objc private func copyClicked() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Kopiert")
    }

    @objc private func moreClicked() {
        guard let item, let menu = item.bar?.delegate?.menuForTab(at: item.index) else { return }
        menuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton)
        menuOpen = false
        hide()
    }
}
