//
//  iTermAgentSessionsPanel.swift
//  iTerm2
//
//  A collapsible, resizable list of recent Copilot and Claude Code sessions
//  shown beneath the left tab bar. Clicking a row resumes the session.
//

import AppKit

@objc(iTermAgentSessionsPanelDelegate)
protocol iTermAgentSessionsPanelDelegate: AnyObject {
    func agentSessionsPanelDidChangeHeight(_ panel: iTermAgentSessionsPanel)
    func agentSessionsPanel(_ panel: iTermAgentSessionsPanel, openSession session: iTermAgentSession)
}

@objc(iTermAgentSessionsPanel)
final class iTermAgentSessionsPanel: NSView {
    @objc static let headerHeight: CGFloat = 28
    private static let minimumExpandedHeight: CGFloat = 90
    private static let defaultExpandedHeight: CGFloat = 260
    private static let resizeStripHeight: CGFloat = 5
    private static let collapsedKey = "NoSyncAgentSessionsPanelCollapsed"
    private static let heightKey = "NoSyncAgentSessionsPanelHeight"

    @objc weak var delegate: iTermAgentSessionsPanelDelegate?

    @objc var backgroundColor: NSColor = .clear {
        didSet {
            needsDisplay = true
        }
    }

    @objc var textColor: NSColor = .labelColor {
        didSet {
            guard textColor != oldValue else {
                return
            }
            applyTextColor()
            tableView.reloadData()
        }
    }

    @objc private(set) var collapsed: Bool {
        get { iTermUserDefaults.userDefaults().bool(forKey: Self.collapsedKey) }
        set { iTermUserDefaults.userDefaults().set(newValue, forKey: Self.collapsedKey) }
    }

    private var expandedHeight: CGFloat {
        get {
            let value = iTermUserDefaults.userDefaults().double(forKey: Self.heightKey)
            return value > 0 ? CGFloat(value) : Self.defaultExpandedHeight
        }
        set {
            iTermUserDefaults.userDefaults().set(Double(newValue), forKey: Self.heightKey)
        }
    }

    private let header = iTermAgentSessionsHeaderView()
    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var sessions = [iTermAgentSession]()
    private var timer: Timer?
    private var dragStart: (mouseY: CGFloat, height: CGFloat)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // The height to use when at most `available` points are free.
    @objc func height(forAvailableHeight available: CGFloat) -> CGFloat {
        if collapsed {
            return Self.headerHeight
        }
        return max(Self.headerHeight, min(expandedHeight, available))
    }

    private func setUp() {
        wantsLayer = true

        separator.boxType = .separator
        addSubview(separator)

        header.onClick = { [weak self] in
            self?.toggleCollapsed()
        }
        addSubview(header)

        chevron.imageScaling = .scaleProportionallyDown
        header.addSubview(chevron)

        titleLabel.stringValue = String(localized: "AgentSessions.Title",
                                        defaultValue: "Agent Sessions",
                                        comment: "Header of the left tab bar panel listing recent Copilot and Claude Code sessions")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(titleLabel)

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        header.addSubview(countLabel)

        let reloadTitle = String(localized: "AgentSessions.Reload",
                                 defaultValue: "Reload",
                                 comment: "Button that rescans recent Copilot and Claude Code sessions")
        refreshButton.image = NSImage.it_image(forSymbolName: SFSymbol.arrowClockwise.rawValue,
                                               accessibilityDescription: reloadTitle)
        refreshButton.imageScaling = .scaleProportionallyDown
        refreshButton.isBordered = false
        refreshButton.bezelStyle = .regularSquare
        refreshButton.toolTip = reloadTitle
        refreshButton.target = self
        refreshButton.action = #selector(reload(_:))
        header.addSubview(refreshButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.rowHeight = 36
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.menu = makeContextMenu()

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        emptyLabel.stringValue = String(localized: "AgentSessions.Empty",
                                        defaultValue: "No sessions in the last 30 days",
                                        comment: "Shown when there are no recent Copilot or Claude Code sessions")
        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(storeDidUpdate(_:)),
                                               name: iTermAgentSessionStore.didUpdateNotification,
                                               object: nil)
        sessions = iTermAgentSessionStore.shared.sessions
        applyTextColor()
        updateChevron()
        updateCount()
    }

    private func applyTextColor() {
        titleLabel.textColor = textColor.withAlphaComponent(0.7)
        countLabel.textColor = textColor.withAlphaComponent(0.5)
        emptyLabel.textColor = textColor.withAlphaComponent(0.5)
        chevron.contentTintColor = textColor.withAlphaComponent(0.6)
        refreshButton.contentTintColor = textColor.withAlphaComponent(0.6)
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        separator.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        header.frame = NSRect(x: 0, y: 1, width: width, height: Self.headerHeight - 1)
        let midY = header.bounds.midY
        chevron.frame = NSRect(x: 10, y: midY - 5, width: 10, height: 10)
        refreshButton.frame = NSRect(x: width - 26, y: midY - 8, width: 16, height: 16)
        countLabel.sizeToFit()
        let countWidth = countLabel.frame.width
        countLabel.frame = NSRect(x: refreshButton.frame.minX - 6 - countWidth,
                                  y: midY - countLabel.frame.height / 2,
                                  width: countWidth,
                                  height: countLabel.frame.height)
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(x: 26,
                                  y: midY - titleHeight / 2,
                                  width: max(0, countLabel.frame.minX - 32),
                                  height: titleHeight)

        let listFrame = NSRect(x: 0,
                               y: Self.headerHeight,
                               width: width,
                               height: max(0, bounds.height - Self.headerHeight))
        scrollView.frame = listFrame
        scrollView.isHidden = collapsed
        emptyLabel.isHidden = collapsed || !sessions.isEmpty
        let emptyHeight = emptyLabel.intrinsicContentSize.height
        emptyLabel.frame = NSRect(x: 8, y: listFrame.minY + 12, width: max(0, width - 16), height: emptyHeight)
        tableView.sizeLastColumnToFit()
    }

    // MARK: - Refreshing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard let window else {
            return
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification,
                                               object: window)
        // Keeps the ages current and notices sessions that started or ended.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.periodicRefresh()
        }
        iTermAgentSessionStore.shared.refresh(minimumInterval: 5)
    }

    private func periodicRefresh() {
        guard !collapsed, window?.isVisible == true else {
            return
        }
        iTermAgentSessionStore.shared.refresh(minimumInterval: 20)
        tableView.reloadData()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard !collapsed else {
            return
        }
        iTermAgentSessionStore.shared.refresh(minimumInterval: 10)
    }

    @objc private func storeDidUpdate(_ notification: Notification) {
        sessions = iTermAgentSessionStore.shared.sessions
        tableView.reloadData()
        updateCount()
        needsLayout = true
    }

    @objc private func reload(_ sender: Any?) {
        iTermAgentSessionStore.shared.refresh()
    }

    private func updateCount() {
        countLabel.stringValue = sessions.isEmpty ? "" : "\(sessions.count)"
        needsLayout = true
    }

    // MARK: - Collapsing and resizing

    private func toggleCollapsed() {
        collapsed.toggle()
        updateChevron()
        if !collapsed {
            iTermAgentSessionStore.shared.refresh(minimumInterval: 5)
        }
        needsLayout = true
        delegate?.agentSessionsPanelDidChangeHeight(self)
    }

    private func updateChevron() {
        let symbol = collapsed ? SFSymbol.chevronRight : SFSymbol.chevronDown
        chevron.image = NSImage.it_image(forSymbolName: symbol.rawValue, accessibilityDescription: nil)
        header.toolTip = collapsed
            ? String(localized: "AgentSessions.Expand", defaultValue: "Show recent sessions", comment: "Tooltip on the collapsed Agent Sessions header")
            : String(localized: "AgentSessions.Collapse", defaultValue: "Hide recent sessions", comment: "Tooltip on the expanded Agent Sessions header")
    }

    private var resizeStrip: NSRect {
        return NSRect(x: 0, y: 0, width: bounds.width, height: Self.resizeStripHeight)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !collapsed {
            addCursorRect(resizeStrip, cursor: .resizeUpDown)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !collapsed && resizeStrip.contains(local) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard !collapsed else {
            return
        }
        dragStart = (mouseY: event.locationInWindow.y, height: bounds.height)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else {
            return
        }
        // Window coordinates grow upward, so dragging up makes the panel taller.
        let proposed = dragStart.height + (event.locationInWindow.y - dragStart.mouseY)
        expandedHeight = max(Self.minimumExpandedHeight, round(proposed))
        delegate?.agentSessionsPanelDidChangeHeight(self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    // MARK: - Actions

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < sessions.count else {
            return
        }
        delegate?.agentSessionsPanel(self, openSession: sessions[row])
        tableView.deselectAll(nil)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "AgentSessions.Resume", defaultValue: "Resume in New Tab", comment: "Context menu item that resumes a Copilot or Claude Code session"),
                     action: #selector(resumeFromMenu(_:)),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "AgentSessions.CopyCommand", defaultValue: "Copy Resume Command", comment: "Context menu item that copies the command that resumes a session"),
                     action: #selector(copyCommand(_:)),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "AgentSessions.CopyID", defaultValue: "Copy Session ID", comment: "Context menu item that copies a Copilot or Claude Code session ID"),
                     action: #selector(copySessionID(_:)),
                     keyEquivalent: "").target = self
        return menu
    }

    private var clickedSession: iTermAgentSession? {
        let row = tableView.clickedRow
        guard row >= 0, row < sessions.count else {
            return nil
        }
        return sessions[row]
    }

    @objc private func resumeFromMenu(_ sender: Any?) {
        if let session = clickedSession {
            delegate?.agentSessionsPanel(self, openSession: session)
        }
    }

    @objc private func copyCommand(_ sender: Any?) {
        copyToPasteboard(clickedSession?.resumeCommand)
    }

    @objc private func copySessionID(_ sender: Any?) {
        copyToPasteboard(clickedSession?.sessionID)
    }

    private func copyToPasteboard(_ string: String?) {
        guard let string else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // A short age like “now”, “15m ago”, or “3d ago”.
    static func ageString(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 {
            return String(localized: "AgentSessions.Now", defaultValue: "now", comment: "Age of a session that was active less than a minute ago")
        }
        let minutes = Int(seconds / 60)
        let value: String
        if minutes < 60 {
            value = "\(minutes)m"
        } else if minutes < 24 * 60 {
            value = "\(minutes / 60)h"
        } else if minutes < 14 * 24 * 60 {
            value = "\(minutes / (24 * 60))d"
        } else {
            value = "\(minutes / (7 * 24 * 60))w"
        }
        return String(format: String(localized: "AgentSessions.Ago", defaultValue: "%@ ago", comment: "Age of a session, such as “15m ago”. The argument is an abbreviated duration such as 15m, 3h, or 3d."), value)
    }
}

extension iTermAgentSessionsPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return sessions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("AgentSessionCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? iTermAgentSessionCellView)
            ?? iTermAgentSessionCellView(identifier: identifier)
        cell.configure(session: sessions[row], textColor: textColor)
        return cell
    }
}

private final class iTermAgentSessionsHeaderView: NSView {
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Handled on mouse up so a press can be cancelled by dragging away.
    }
}

private final class iTermAgentSessionCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        ageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        ageLabel.alignment = .right
        detailLabel.font = NSFont.systemFont(ofSize: 10.5)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        for label in [titleLabel, ageLabel, detailLabel] {
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    func configure(session: iTermAgentSession, textColor: NSColor) {
        titleLabel.stringValue = session.title
        titleLabel.textColor = textColor
        ageLabel.stringValue = iTermAgentSessionsPanel.ageString(since: session.lastActive)
        ageLabel.textColor = textColor.withAlphaComponent(0.55)
        var detail = session.agentName
        if let directory = session.workingDirectory {
            detail += " · " + (directory as NSString).abbreviatingWithTildeInPath
        }
        detailLabel.stringValue = detail
        detailLabel.textColor = textColor.withAlphaComponent(0.55)
        toolTip = [session.title, session.workingDirectory, session.resumeCommand]
            .compactMap { $0 }
            .joined(separator: "\n")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 10
        let width = bounds.width
        ageLabel.sizeToFit()
        let ageWidth = ageLabel.frame.width
        let titleHeight = titleLabel.intrinsicContentSize.height
        let detailHeight = detailLabel.intrinsicContentSize.height
        let top = max(0, (bounds.height - titleHeight - detailHeight) / 2)
        // NSTableCellView isn't flipped, so place the title above the detail.
        let titleY = bounds.height - top - titleHeight
        ageLabel.frame = NSRect(x: width - inset - ageWidth, y: titleY, width: ageWidth, height: titleHeight)
        titleLabel.frame = NSRect(x: inset, y: titleY, width: max(0, ageLabel.frame.minX - inset - 6), height: titleHeight)
        detailLabel.frame = NSRect(x: inset, y: titleY - detailHeight, width: max(0, width - 2 * inset), height: detailHeight)
    }
}
