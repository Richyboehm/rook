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
}

/// Rook's own tab bar: a glass strip under the toolbar. Pinned tabs are small icons on the left,
/// normal tabs share the remaining width. Tabs can be dragged to reorder.
final class TabBarView: NSVisualEffectView {
    weak var delegate: TabBarDelegate?
    private var items: [TabItemView] = []
    private let plusButton = NSButton()
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
        [icon, label, closeButton].forEach(addSubview)
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
        toolTip = tab.displayURL?.absoluteString ?? title
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
            return
        }
        label.isHidden = false
        let showClose = isHovered || isSelected
        closeButton.isHidden = !showClose
        closeButton.frame = NSRect(x: 6, y: (h - 16) / 2, width: 16, height: 16)
        icon.frame = NSRect(x: showClose ? 26 : 10, y: (h - 16) / 2, width: 16, height: 16)
        let textX = icon.frame.maxX + 6
        label.frame = NSRect(x: textX, y: (h - 16) / 2, width: max(0, bounds.width - textX - 8), height: 16)
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

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsLayout = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsLayout = true; needsDisplay = true }

    @objc private func closeClicked() { bar?.delegate?.closeTab(at: index) }

    override func mouseDown(with event: NSEvent) {
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
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard isDragging, let bar else { return }
        isDragging = false
        layer?.zPosition = 0
        bar.dragFinished(from: index, to: bar.index(forDragAt: frame.midX, from: index))
    }

    /// Middle click closes the tab, like in other browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { bar?.delegate?.closeTab(at: index) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.delegate?.menuForTab(at: index) }
}
